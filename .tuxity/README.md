# .tuxity — fork tooling

This directory holds everything that makes `tuxity/mattermost` differ from
upstream `mattermost/mattermost`. `master` is otherwise vanilla upstream.

## What it does

1. `.github/workflows/sync-new-releases.yaml` (cron + manual) detects a new
   upstream GitHub Release, creates `release-X.Y` reset to the upstream tag, and
   runs `apply-enterprise.sh` to materialize the enterprise patch as one commit.
2. The force-pushed tag triggers `server-ci-enterprise.yaml` (vendored here,
   copied onto each release branch) which builds the enterprise edition, creates
   a GitHub Release with artifacts, and pushes a Docker image to
   `ghcr.io/tuxity/mattermost-enterprise-edition`.

## Files

- `apply-enterprise.sh` — idempotent, fail-loud applier. Run from repo root.
- `license-inject.go.txt` — the Go block injected at the top of
  `PlatformService.LoadLicense()` (grants a permanent Enterprise license).
- `workflows/server-ci-enterprise.yaml` — canonical build workflow.

## Required secrets (repo settings)

- `PAT` — personal access token with `repo` + `workflow` scope. Used by the sync
  workflow to push branches/tags AND to trigger the downstream build (the default
  `GITHUB_TOKEN` does not trigger other workflows).
- `MM_SYNC_WEBHOOK_URL` — optional Mattermost incoming webhook for failure alerts.

## Re-running by hand

```bash
git checkout -B release-X.Y vX.Y.Z
/path/to/.tuxity/apply-enterprise.sh
```
