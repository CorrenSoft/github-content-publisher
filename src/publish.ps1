param(
  [Parameter(Mandatory = $true)][ValidateSet('pull-request', 'summary', 'check-run')]
  [string]$Channel,
  [Parameter(Mandatory = $true)][ValidateSet('add', 'upsert', 'replace', 'append')]
  [string]$Mode,
  [string]$AppendSeparator = "",
  [string]$Body,
  [string]$BodyFile,
  [bool]$FailOnError = $true,
  [bool]$GarbageCollector = $false,
  [string]$MarkerId,
  [string]$PrNumber
)

# ----- Helpers -----
function Add-Marker {
  param([string]$Content)
  $marker = Get-MarkerLine
  return "$marker`n$Content"
}

function Find-PRCommentByMarker {
  param([int]$Number, [string]$Marker)
  Write-Host "Looking for comments."
  $page = 1; $per = 100
  $found = $null
  $dups = @()
  while ($true) {
    $route = "repos/$env:GITHUB_REPOSITORY/issues/$Number/comments?per_page=$per&page=$page"
    $items = Invoke-GhApi -Method 'GET' -Route $route -Fields @{}
    if (-not $items -or $items.Count -eq 0) { break }
    foreach ($c in $items) {
      if ($c.body -and $c.body.StartsWith($Marker)) {
        if (-not $found) { $found = $c } else { $dups += $c }
      }
    }
    if ($items.Count -lt $per) { break }
    $page++
  }
  Write-Host "Found: $found"
  return , @($found, $dups) 
}

function Get-EventPayload {
  $content = $null
  if (Test-Path -Path $env:GITHUB_EVENT_PATH) {
    try { 
      $content = (Get-Content -Raw -Path $env:GITHUB_EVENT_PATH | ConvertFrom-Json -Depth 10) 
    }
    catch { 
      Write-ErrorOrWarning "Unable to retrieve the event details: $_"
    }
  }
  return $content
}

function Get-MarkerLine {
  if ( $MarkerId) {
    $id = $MarkerId 
  }
  else {
    $id = "WORKFLOW: $env:GITHUB_REPOSITORY"
  }
  return "<!-- content-publisher: $id -->" 
}

function Get-RepoContext {
  $owner, $repo = $env:GITHUB_REPOSITORY -split '/'
  if (-not $owner -or -not $repo) { Write-ErrorOrWarning "GITHUB_REPOSITORY is empty"; return $null }
  [pscustomobject]@{ Owner = $owner; Repo = $repo }
}

function Invoke-GhApi {
  param([string]$Method, [string]$Route, [hashtable]$Fields)
  $arguments = @('api', $Route, '--method', $Method, '--header', 'Accept: application/vnd.github+json')
  if ($Fields) {
    foreach ($k in $Fields.Keys) {
      $v = $Fields[$k]
      if ($null -ne $v) { $arguments += @('--field', "$k=$v") }
    }
  }
  
  $json = & gh @arguments 2>&1
  if ($LASTEXITCODE -ne 0) {
    Write-ErrorOrWarning "gh api failed ($Method $Route):`n$json"
    return $null
  }
  if ($json -and ($json.Trim().StartsWith('{') -or $json.Trim().StartsWith('['))) {
    return $json | ConvertFrom-Json
  }
  return $null
}

function Read-Body {
  if ($Body -and $Body.Trim().Length -gt 0) { return $Body }
  if ($BodyFile) {
    if (-not (Test-Path -Path $BodyFile)) { Write-ErrorOrWarning "body-file '$BodyFile' not found"; return "" }
    return (Get-Content -Raw -Path $BodyFile)
  }
  return ""
}

function Write-ErrorOrWarning {
  param([string]$Message)
  if ($FailOnError) { throw $Message } else { Write-Warning $Message }
}

function Write-OutputVar {
  param([string]$Name, [string]$Value)
  if (-not [string]::IsNullOrEmpty($env:GITHUB_OUTPUT)) {
    "$Name=$Value" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding UTF8
  }
}

# ----- Channel implementations -----
function Publish-Summary {
  $content = Read-Body

  if ([string]::IsNullOrEmpty($content)) { 
    Write-ErrorOrWarning "Empty body for summary"
    return 
  }

  if (-not $env:GITHUB_STEP_SUMMARY) { 
    Write-ErrorOrWarning "GITHUB_STEP_SUMMARY not available"
    return 
  }

  $content | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding UTF8

  Write-OutputVar -Name 'published' -Value 'true'
  Write-OutputVar -Name 'channel'   -Value 'summary'
  Write-OutputVar -Name 'mode-effective' -Value $Mode
}

function Publish-PR {
  Write-Host "::group::PullRequest"
  $ctx = Get-RepoContext; if (-not $ctx) { return }

  if ( $PrNumber) {
    $pr = $PrNumber 
  }
  else {
    if ($env:GITHUB_EVENT_NAME -in @('pull_request', 'pull_request_target')) {
      $payload = Get-EventPayload
      $pr = $payload.number
    }
  }
  if (-not $pr) {
    Write-ErrorOrWarning "Cannot resolve PR number. Pass 'pr-number'."
    return 
  }

  $raw = Read-Body

  if ([string]::IsNullOrEmpty($raw)) { 
    Write-ErrorOrWarning "Empty body for pull-request"
    return 
  }

  $createBody = Add-Marker $raw 
  if ($Mode -eq 'add') {
    $created = Invoke-GhApi -Method 'POST' -Route "repos/$env:GITHUB_REPOSITORY/issues/$pr/comments" -Fields @{ 'body' = $createBody }
    if ($created) {
      Write-OutputVar 'published' 'true'
      Write-OutputVar 'resource-id' "$($created.id)"
    }
    Write-OutputVar 'channel' 'pull-request'
    Write-OutputVar 'mode-effective' 'add'
    return
  }

  $found, $duplicates = Find-PRCommentByMarker -Number $pr -Marker Get-MarkerLine 
  if ($GarbageCollector) {
    foreach ($d in $duplicates) {
      Write-Host "Deleting duplicates."
      Invoke-GhApi -Method 'DELETE' -Route "repos/$env:GITHUB_REPOSITORY/issues/comments/$($d.id)" -Fields @{}
    }
  }

  $rsp = $null
  switch ($Mode) {
    'upsert' {
      if ($found) {
        Write-Host "Editing Comment."
        $rsp = Invoke-GhApi -Method 'PATCH' -Route "repos/$env:GITHUB_REPOSITORY/issues/comments/$($found.id)" -Fields @{ 'body' = $createBody }
      }
      else {
        Write-Host "Inserting Comment."
        $rsp = Invoke-GhApi -Method 'POST' -Route "repos/$env:GITHUB_REPOSITORY/issues/$pr/comments" -Fields @{ 'body' = $createBody }
      }
      if ($rsp) { 
        Write-OutputVar 'resource-id' "$($rsp.id)"
        Write-OutputVar 'published' 'true'
      }
      Write-OutputVar 'mode-effective' 'upsert'
    }
    'replace' {
      Write-Host "Replacing Comment."
      if ($found) { 
        Invoke-GhApi -Method 'DELETE' -Route "repos/$env:GITHUB_REPOSITORY/issues/comments/$($found.id)" -Fields @{} 
      }
      $rsp = Invoke-GhApi -Method 'POST' -Route "repos/$env:GITHUB_REPOSITORY/issues/$pr/comments" -Fields @{ 'body' = $createBody }
      if ($rsp) { 
        Write-OutputVar 'resource-id' "$($rsp.id)"
        Write-OutputVar 'published' 'true' 
      }
      Write-OutputVar 'mode-effective' 'replace'
    }
    'append' {
      if ($found) {
        $existing = $found.body
        if (([string]::IsNullOrEmpty($AppendSeparator)) ) {
          $separator = "`n`n---`n`n"
        }
        else {
          $separator = $AppendSeparator
        }
        $newBody = "$existing$separator$raw"
        $rsp = Invoke-GhApi -Method 'PATCH' -Route "repos/$env:GITHUB_REPOSITORY/issues/comments/$($found.id)" -Fields @{ 'body' = $newBody }
      }
      else {
        $rsp = Invoke-GhApi -Method 'POST' -Route "repos/$env:GITHUB_REPOSITORY/issues/$pr/comments" -Fields @{ 'body' = $createBody }
      }
      if ($rsp) { 
        Write-OutputVar 'resource-id' "$($rsp.id)"
        Write-OutputVar 'published' 'true' 
      }
      Write-OutputVar 'mode-effective' 'append'
    }
    default {
      Write-ErrorOrWarning "Unsupported mode '$Mode' for pull-request"
    }
  }

  Write-OutputVar 'channel' 'pull-request'
  Write-Host "::endgroup::"
}

function Publish-CheckRun {
  Write-Host "::group::CheckRun"

  $summary = Read-Body
  if ([string]::IsNullOrEmpty($summary)) { 
    Write-ErrorOrWarning "Empty body for check-run"
    return 
  }

  # Effective mode is always upsert
  $effMode = 'upsert'

  $jobs = Invoke-GhApi -Method 'GET' -Route "repos/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID/attempts/$env:GITHUB_RUN_ATTEMPT/jobs" 

  # Try to find the matching job
  $match = $jobs.jobs |
  Where-Object {
    (($_.name.ToLower()) -eq ($env:GITHUB_JOB.ToLower()))
  } |
  Select-Object -First 1

  if ($match) {
    $job_id = $match.id
  }
  else {
    $job_id = $jobs.jobs[0].id
  }

  $crt = Invoke-GhApi -Method 'PATCH' -Route "repos/$env:GITHUB_REPOSITORY/check-runs/$job_id" -Fields @{
    "output[title]"   = $summary;
    "output[summary]" = $summary
  }

  if ($crt) {
    Write-OutputVar 'published' 'true'
    Write-OutputVar 'resource-id' "$($crt.id)"
  }
  
  Write-OutputVar 'channel' 'check-run'
  Write-OutputVar 'mode-effective' $effMode
  Write-Host "::endgroup::"
}

# ----- Dispatcher -----

try {
  switch ($Channel) {
    'summary' { Publish-Summary }
    'pull-request' { Publish-PR }
    'check-run' { Publish-CheckRun }
    default { Write-ErrorOrWarning "Unknown channel '$Channel'" }
  }
}
catch {
  Write-Error $_
  if ($FailOnError) { exit 1 } else { exit 0 }
}
