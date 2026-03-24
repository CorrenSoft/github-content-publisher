# Content Publisher (GitHub Action)

Publish content to GitHub surfaces with modes `add | upsert | replace | append`, and optional garbage collection of duplicates.  

Channels supported:

- `pull-request` → sticky or non-sticky **PR comment**.
- `summary` → **Job Summary** (`$GITHUB_STEP_SUMMARY`) of the current job.
- `check-run` → always **upsert** a **Check Run** output for the current commit (uses the body as the check’s summary).

## Inputs

- `channel` (required): `pull-request | summary | check-run`
- `mode` (required): `add | upsert | replace | append`
  - For `check-run`, the effective mode is always `upsert`.
- `body` (optional): inline content (Markdown).
- `body-file` (optional): file path to read the content from. If both `body` and `body-file` are set, `body` wins.
- `marker-id` (optional): used to identify the message (sticky). If not set, an auto-generated marker is used.
- `pr-number` (optional): overrides PR autodetection.
- `append-separator` (optional, default `\n\n---\n\n`): used in `append` mode.
- `garbage-collector` (optional, default `false`): when `true`, removes duplicate entries with the same marker (keeps the most recent). Not applicable to `check-run` bacause deletion is not supported by the API.
- `fail-on-error` (optional, default `true`)
- `github-token` (optional): override token; by default uses `GITHUB_TOKEN`.

## Outputs

- `published`: `true|false`
- `channel`: echo of the selected channel
- `resource-id`: `comment_id` or `check_run_id` when applicable
- `mode-effective`: the resolved mode (`upsert` for `check-run`)

## Permissions

- `pull-request`: default `GITHUB_TOKEN` is enough in same-repo PRs. For PRs from forks, use safe patterns (`pull_request_target`) if you need to comment with write permissions.
- `check-run`: requires `permissions: checks: write`.

## Examples

### PR sticky upsert (recommended with body-file)

```yaml
- name: Publish PR comment (sticky upsert)
uses: CorrenSoft/github-content-publisher@v0
with:
  channel: pull-request
  mode: upsert
  marker-id: plan
  body-file: ./out/plan.md
```

### PR Append

```yaml
- name: Append section to PR comment
  uses: CorrenSoft/github-content-publisher@v0
  with:
    channel: pull-request
    mode: append
    marker-id: coverage
    append-separator: |
     

    body: |
      - Added coverage for module X
```

### Job Summary

```yaml
- name: Publish Job Summary
  uses: CorrenSoft/github-content-publisher@v0
  with:
    channel: summary
    mode: add
    body-file: ./out/report.md
```

### Check Run

```yaml
permissions:
  contents: read
  checks: write

steps:
  - name: Publish Check Run
    uses: CorrenSoft/github-content-publisher@v0
    with:
      channel: check-run
      mode: upsert            # ignored; always upsert
      body: |
        All the tasks werre completed.
```

## Notes

- The marker is only added at the beginning on the first publication; subsequent append operations keep a single marker and add the separator + new content.
- The Action do not attempt to parse or manipulate the content; it simply adds the marker and separator (when applies). Neither control the lenght of the content, which may cause API rejections if too long.
