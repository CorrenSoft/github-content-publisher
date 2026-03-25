param(
  [Parameter(Mandatory = $true)][ValidateSet('pull-request', 'summary', 'check-run')]
  [string]$Channel,

  [Parameter(Mandatory = $true)][ValidateSet('add', 'upsert', 'replace', 'append')]
  [string]$Mode,

  [string]$Body,
  [string]$BodyFile,
  [string]$MarkerId,
  [string]$PrNumber,
  [string]$AppendSeparator = "`n`n---`n`n",
  [bool]$GarbageCollector = $false,
  [bool]$FailOnError = $true
)

# ----- Helpers -----

function Write-OutputVar {
  param([string]$Name, [string]$Value)
  if (-not [string]::IsNullOrEmpty($env:GITHUB_OUTPUT)) {
    "$Name=$Value" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding UTF8
  }
}

function Write-ErrorOrWarning {
  param([string]$Message)
  if ($FailOnError) { throw $Message } else { Write-Warning $Message }
}

function Get-RepoContext {
  $owner, $repo = $env:GITHUB_REPOSITORY -split '/'
  if (-not $owner -or -not $repo) { Write-ErrorOrWarning "GITHUB_REPOSITORY is empty"; return $null }
  [pscustomobject]@{ Owner = $owner; Repo = $repo }
}

function Get-EventPayload {
  if (Test-Path -Path $env:GITHUB_EVENT_PATH) {
    try { 
      return (Get-Content -Raw -Path $env:GITHUB_EVENT_PATH | ConvertFrom-Json -Depth 10) 
    }
    catch { 
      Write-ErrorOrWarning "Unable to retrieve the event details: $_"
    }
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

function Add-Marker {
  param([string]$Content)
  $marker = Get-MarkerLine
  return "$marker`n$Content"
}

function Remove-DuplicatedMarker {
  param([string]$Content)
  if ([string]::IsNullOrEmpty($MarkerId)) { return $Content }
  $marker = "<!-- content-publisher: $MarkerId -->"
  # Keep only the very first marker occurrence
  $lines = $Content -split "`n"
  $seen = $false
  $result = foreach ($l in $lines) {
    if ($l -eq $marker) {
      if (-not $seen) { $seen = $true; $l }
      # skip duplicated markers
    }
    else {
      $l
    }
  }
  return ($result -join "`n")
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

# ----- Channel implementations -----
function Publish-Summary {
  $ctx = Get-RepoContext; if (-not $ctx) { return }
  $content = Read-Body
  if ([string]::IsNullOrEmpty($content)) { Write-ErrorOrWarning "Empty body for summary"; return }
  if (-not $env:GITHUB_STEP_SUMMARY) { Write-ErrorOrWarning "GITHUB_STEP_SUMMARY not available"; return }
  $content | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding UTF8
  Write-OutputVar -Name 'published' -Value 'true'
  Write-OutputVar -Name 'channel'   -Value 'summary'
  Write-OutputVar -Name 'mode-effective' -Value $Mode
}

function Find-PRCommentByMarker {
  param([string]$Owner, [string]$Repo, [int]$Number, [string]$Marker)
  # Paginate comments until we find the first starting with the marker
  $page = 1; $per = 100
  $found = $null
  $dups = @()
  while ($true) {
    $route = "repos/$Owner/$Repo/issues/$Number/comments?per_page=$per&page=$page"
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
  return , @($found, $dups)  # tuple
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
      Write-Host $Payload
      Write-Host $payload.number
      Write-Host $pr
    }
  }
  if (-not $pr) { Write-ErrorOrWarning "Cannot resolve PR number. Pass 'pr-number'."; return }

  Write-Host $Mode
  $raw = Read-Body
  if ([string]::IsNullOrEmpty($raw)) { Write-ErrorOrWarning "Empty body for pull-request"; return }

  $createBody = Add-Marker $raw 
  if ($Mode -eq 'add') {
    $created = Invoke-GhApi -Method 'POST' -Route "repos/$($ctx.Owner)/$($ctx.Repo)/issues/$pr/comments" -Fields @{ 'body' = $createBody }
    if ($created) {
      Write-OutputVar 'published' 'true'
      Write-OutputVar 'resource-id' "$($created.id)"
    }
    Write-OutputVar 'channel' 'pull-request'
    Write-OutputVar 'mode-effective' 'add'
    return
  }

  $found, $dups = Find-PRCommentByMarker -Owner $ctx.Owner -Repo $ctx.Repo -Number $pr -Marker $markerLine
  if ($GarbageCollector) {
    foreach ($d in $Duplicates) {
      Write-Host "Deleting duplicates."
      Invoke-GhApi -Method 'DELETE' -Route "repos/$($ctx.Owner)/$($ctx.Repo)/issues/comments/$($d.id)" -Fields @{}
    }
  }

  $rsp = $null
  switch ($Mode) {
    'upsert' {
      if ($found) {
        $rsp = Invoke-GhApi -Method 'PATCH' -Route "repos/$($ctx.Owner)/$($ctx.Repo)/issues/comments/$($found.id)" -Fields @{ 'body' = $createBody }
      }
      else {
        $rsp = Invoke-GhApi -Method 'POST' -Route "repos/$($ctx.Owner)/$($ctx.Repo)/issues/$pr/comments" -Fields @{ 'body' = $createBody }
      }
      if ($rsp) { Write-OutputVar 'resource-id' "$($rsp.id)"; Write-OutputVar 'published' 'true' }
      Write-OutputVar 'mode-effective' 'upsert'
    }
    'replace' {
      if ($found) { Invoke-GhApi -Method 'DELETE' -Route "repos/$($ctx.Owner)/$($ctx.Repo)/issues/comments/$($found.id)" -Fields @{} }
      $rsp = Invoke-GhApi -Method 'POST' -Route "repos/$($ctx.Owner)/$($ctx.Repo)/issues/$pr/comments" -Fields @{ 'body' = $createBody }
      if ($rsp) { Write-OutputVar 'resource-id' "$($rsp.id)"; Write-OutputVar 'published' 'true' }
      Write-OutputVar 'mode-effective' 'replace'
    }
    'append' {
      if ($found) {
        $existing = $found.body
        $newBody = "$existing$AppendSeparator$raw"
        $rsp = Invoke-GhApi -Method 'PATCH' -Route "repos/$($ctx.Owner)/$($ctx.Repo)/issues/comments/$($found.id)" -Fields @{ 'body' = $newBody }
      }
      else {
        $rsp = Invoke-GhApi -Method 'POST' -Route "repos/$($ctx.Owner)/$($ctx.Repo)/issues/$pr/comments" -Fields @{ 'body' = $createBody }
      }
      if ($rsp) { Write-OutputVar 'resource-id' "$($rsp.id)"; Write-OutputVar 'published' 'true' }
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
  $ctx = Get-RepoContext; if (-not $ctx) { return }

  $raw = Read-Body
  if ([string]::IsNullOrEmpty($raw)) { Write-ErrorOrWarning "Empty body for check-run"; return }

  # Effective mode is always upsert
  $effMode = 'upsert'

  # Compute content
  $summary = $raw 
  # if ($MarkerId) { Add-Marker $raw } else { $raw }

  $sha = $env:GITHUB_SHA
  $checkName = "Content Publisher"

  # Try to find existing check run for this commit & name
  $list = Invoke-GhApi -Method 'GET' -Route "repos/$($ctx.Owner)/$($ctx.Repo)/commits/$sha/check-runs?check_name=$([uri]::EscapeDataString($checkName))" -Fields @{}
  $existing = $null
  if ($list?.check_runs) {
    # If marker is present, prefer the one whose output.summary starts with the marker (requires extra fetch if summary isn't in list)
    if ($MarkerId) {
      $marker = "<!-- content-publisher: $MarkerId -->"
      foreach ($cr in $list.check_runs) {
        # Fetch details to inspect summary
        $det = Invoke-GhApi -Method 'GET' -Route "repos/$($ctx.Owner)/$($ctx.Repo)/check-runs/$($cr.id)" -Fields @{}
        if ($det?.output?.summary -and $det.output.summary.StartsWith($marker)) {
          $existing = $det; break
        }
      }
    }
    if (-not $existing -and $list.check_runs.Count -gt 0) {
      # Fallback to most recent with same name
      $existing = $list.check_runs | Sort-Object created_at -Descending | Select-Object -First 1
    }
  }

  # Determine conclusion from job status (best-effort)
  $conclusion = 'success'

  if ($existing) {
    Write-Host "Patching repos/$($ctx.Owner)/$($ctx.Repo)/check-runs/$($existing.id)"
    $upd = Invoke-GhApi -Method 'PATCH' -Route "repos/$($ctx.Owner)/$($ctx.Repo)/check-runs/$($existing.id)" -Fields @{
      "status"          = "completed";
      "conclusion"      = $conclusion;
      "output[title]"   = $checkName;
      "output[summary]" = $summary
    }
    if ($upd) {
      Write-OutputVar 'published' 'true'
      Write-OutputVar 'resource-id' "$($existing.id)"
    }
  }
  else {
    Write-Host "Creating..."
    $crt = Invoke-GhApi -Method 'POST' -Route "repos/$($ctx.Owner)/$($ctx.Repo)/check-runs" -Fields @{
      "name"            = $checkName;
      "head_sha"        = $sha;
      "status"          = "completed";
      "conclusion"      = $conclusion;
      "output[title]"   = $summary;
      "output[summary]" = $summary
    }
    Write-Host $crt
    if ($crt) {
      Write-OutputVar 'published' 'true'
      Write-OutputVar 'resource-id' "$($crt.id)"
    }
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
