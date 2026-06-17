# Tuxity Enterprise Release Automation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the `tuxity/mattermost` fork's release automation so it reliably re-applies the "Mr Robot @ fSociety" Enterprise license onto each new upstream release via a robust idempotent script (no fragile cherry-pick), then cleans up the polluted history with a safe force-push.

**Architecture:** `master` becomes vanilla `upstream/master` + one tooling commit under `.tuxity/`. The enterprise patch is materialized only onto `release-*` branches by `.tuxity/apply-enterprise.sh`, which the rewritten `sync-new-releases.yaml` runs at sync time. The patch's core (license bypass) is re-expressed as a single early-return injected after the `LoadLicense()` signature, so upstream edits to that function no longer cause conflicts.

**Tech Stack:** Bash, GitHub Actions (`actions/github-script`, workflow_dispatch + cron), Go (Mattermost server), Git.

**Spec:** `docs/superpowers/specs/2026-06-16-tuxity-enterprise-release-redo-design.md`

**Critical constraints:**
- Preserve all custom IP and all already-published tags / GitHub Releases / Docker images.
- The destructive, irreversible step (deleting stale branches) happens **last**, only after a new release has built green.
- The sync push **must** use `secrets.PAT` (not the default `GITHUB_TOKEN`) — pushes made with `GITHUB_TOKEN` do **not** trigger the downstream `server-ci-enterprise.yaml` build; a PAT does.

---

## File Structure

| Path | Responsibility | Lives on |
| --- | --- | --- |
| `.tuxity/apply-enterprise.sh` | Idempotent applier of the enterprise patch | master |
| `.tuxity/license-inject.go.txt` | Source-of-truth Go block injected into `LoadLicense()` | master |
| `.tuxity/workflows/server-ci-enterprise.yaml` | Canonical build/release/Docker workflow (copied to release branches) | master |
| `.tuxity/README.md` | Documents the fork setup | master |
| `.github/workflows/sync-new-releases.yaml` | Rewritten sync workflow (runs the applier) | master |
| `.github/workflows/server-ci-enterprise.yaml` | Build workflow (generated onto release branches by the applier) | release-* only |
| `server/channels/app/platform/license.go` | License bypass (injected on release-* only) | release-* only |
| `server/enterprise/external_imports.go` | Stubbed on release-* only | release-* only |
| `server/Makefile`, `server/build/Dockerfile` | Build plumbing (patched on release-* only) | release-* only |

---

## Task 1: Back up everything (safety first, before any destructive op)

**Files:** none in repo — produces a local bundle + remote backup refs.

- [ ] **Step 1: Confirm remotes and current custom commits exist**

Run:
```bash
cd /Users/kevindarcel/projects/mattermost
git remote -v
git log --oneline -3 master
git cat-file -t 06625acdaf && git cat-file -t fe2252a5fc
```
Expected: `origin → github.com/tuxity/mattermost`; master at `fe2252a5fc`; both objects report `commit`.

- [ ] **Step 2: Create a full local bundle of the entire current remote state**

Run:
```bash
git fetch origin --prune --tags
git bundle create /Users/kevindarcel/projects/tuxity-mattermost-backup-2026-06-16.bundle --all
git bundle verify /Users/kevindarcel/projects/tuxity-mattermost-backup-2026-06-16.bundle
```
Expected: `The bundle records a complete history` / `is okay`.

- [ ] **Step 3: Push a backup branch + annotated backup tags to origin**

Run:
```bash
git push origin refs/remotes/origin/master:refs/heads/backup/pre-cleanup-2026-06-16
git tag -a backup/enterprise-commit-2026-06-16 06625acdaf -m "pre-cleanup backup of enterprise commit"
git tag -a backup/sync-commit-2026-06-16 fe2252a5fc -m "pre-cleanup backup of sync workflow commit"
git push origin backup/enterprise-commit-2026-06-16 backup/sync-commit-2026-06-16
```
Expected: branch + 2 tags pushed. The exact custom commits are now retained on origin independent of master.

- [ ] **Step 4: Verify backups are on origin**

Run:
```bash
git ls-remote --heads origin 'backup/*'
git ls-remote --tags origin 'backup/*'
```
Expected: `backup/pre-cleanup-2026-06-16` head + both backup tags listed.

---

## Task 2: Create the license injection snippet

**Files:**
- Create: `.tuxity/license-inject.go.txt`

- [ ] **Step 1: Create the snippet file (tab-indented, gofmt-clean)**

Create `.tuxity/license-inject.go.txt` with EXACTLY this content (leading whitespace is a single tab per line):

```go
	// >>> tuxity-enterprise (auto-injected by .tuxity/apply-enterprise.sh) >>>
	f := model.Features{}
	f.SetDefaults()
	*f.Users = 9999
	ps.SetLicense(&model.License{
		Id:        model.NewId(),
		IssuedAt:  0,
		ExpiresAt: 4102491600000, // 1 Jan 2100, in ms
		Customer: &model.Customer{
			Name:    "Mr Robot",
			Email:   "mrrobot@fsociety.com",
			Company: "fsociety",
		},
		Features:     &f,
		SkuName:      "Enterprise",
		SkuShortName: model.LicenseShortSkuEnterprise,
	})
	ps.logger.Info("License key is valid, unlocking enterprise features.")
	return
	// <<< tuxity-enterprise <<<
```

- [ ] **Step 2: Verify the marker and tab indentation are present**

Run:
```bash
grep -c $'\t// >>> tuxity-enterprise' .tuxity/license-inject.go.txt
```
Expected: `1`

---

## Task 3: Vendor the canonical build workflow into `.tuxity/`

**Files:**
- Create: `.tuxity/workflows/server-ci-enterprise.yaml` (exact copy of the current, proven build workflow)

- [ ] **Step 1: Copy the existing build workflow from current master**

Run:
```bash
mkdir -p .tuxity/workflows
git show HEAD:.github/workflows/server-ci-enterprise.yaml > .tuxity/workflows/server-ci-enterprise.yaml
```

- [ ] **Step 2: Verify it copied intact**

Run:
```bash
diff <(git show HEAD:.github/workflows/server-ci-enterprise.yaml) .tuxity/workflows/server-ci-enterprise.yaml && echo IDENTICAL
grep -n 'ghcr.io/tuxity/mattermost-enterprise-edition' .tuxity/workflows/server-ci-enterprise.yaml
```
Expected: `IDENTICAL`; the ghcr image line is present.

---

## Task 4: Write the idempotent applier script

**Files:**
- Create: `.tuxity/apply-enterprise.sh`

- [ ] **Step 1: Create the script**

Create `.tuxity/apply-enterprise.sh` with this exact content:

```bash
#!/usr/bin/env bash
#
# apply-enterprise.sh — idempotently apply the tuxity "Mr Robot @ fSociety"
# Enterprise license bypass + build plumbing onto a fresh upstream Mattermost
# checkout (a release-X.Y branch reset to an upstream tag).
#
# Run from the repository root. Fails loudly (exit 1) if any expected anchor is
# missing, so the sync workflow surfaces breakage instead of shipping a broken
# or unpatched build. Safe to run more than once (idempotent).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LICENSE_GO="server/channels/app/platform/license.go"
EXT_IMPORTS="server/enterprise/external_imports.go"
MAKEFILE="server/Makefile"
DOCKERFILE="server/build/Dockerfile"
CI_SRC="${SCRIPT_DIR}/workflows/server-ci-enterprise.yaml"
CI_DST=".github/workflows/server-ci-enterprise.yaml"
LICENSE_SNIPPET="${SCRIPT_DIR}/license-inject.go.txt"
MARKER="// >>> tuxity-enterprise"

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo ">> $*"; }

[ -d server ] || die "must be run from the repository root (no ./server dir)"

# --- 1. license.go: inject early-return Enterprise license -------------------
[ -f "$LICENSE_GO" ] || die "missing $LICENSE_GO"
if grep -qF "$MARKER" "$LICENSE_GO"; then
  info "license.go already patched, skipping"
else
  ANCHOR='func (ps *PlatformService) LoadLicense() {'
  grep -qF "$ANCHOR" "$LICENSE_GO" || die "anchor not found in $LICENSE_GO: $ANCHOR"
  [ -f "$LICENSE_SNIPPET" ] || die "missing snippet $LICENSE_SNIPPET"
  tmp="$(mktemp)"
  awk -v anchor="$ANCHOR" -v snippet_file="$LICENSE_SNIPPET" '
    BEGIN { while ((getline line < snippet_file) > 0) snippet = snippet line "\n" }
    { print }
    index($0, anchor) && !done { printf "%s", snippet; done=1 }
  ' "$LICENSE_GO" > "$tmp"
  grep -qF "$MARKER" "$tmp" || { rm -f "$tmp"; die "injection failed for $LICENSE_GO"; }
  mv "$tmp" "$LICENSE_GO"
  info "license.go patched"
fi

# --- 2. external_imports.go: stub out private EE imports ---------------------
[ -f "$EXT_IMPORTS" ] || die "missing $EXT_IMPORTS"
cat > "$EXT_IMPORTS" <<'EOF'
// Copyright (c) 2015-present Mattermost, Inc. All Rights Reserved.
// See LICENSE.txt for license information.

//go:build enterprise

package enterprise

// >>> tuxity-enterprise: external enterprise imports intentionally disabled.
// The private github.com/mattermost/enterprise module is unavailable to this
// fork; the build uses a placeholder enterprise dir instead.
EOF
info "external_imports.go stubbed"

# --- 3. Makefile: use BUILD_ENTERPRISE_DIR for the go workspace --------------
[ -f "$MAKEFILE" ] || die "missing $MAKEFILE"
if grep -qF 'work use $(BUILD_ENTERPRISE_DIR)' "$MAKEFILE"; then
  info "Makefile already patched, skipping"
elif grep -qF 'work use ../../enterprise' "$MAKEFILE"; then
  sed -i.bak 's#work use ../../enterprise#work use $(BUILD_ENTERPRISE_DIR)#' "$MAKEFILE"
  rm -f "${MAKEFILE}.bak"
  info "Makefile patched"
else
  die "Makefile go-work-use enterprise line not found in $MAKEFILE"
fi

# --- 4. Dockerfile: COPY dist artifacts so MM_PACKAGE can be a local file ----
[ -f "$DOCKERFILE" ] || die "missing $DOCKERFILE"
if grep -qF 'COPY --from=dist mattermost-* /tmp' "$DOCKERFILE"; then
  info "Dockerfile already patched, skipping"
else
  grep -qF 'ARG MM_PACKAGE' "$DOCKERFILE" || die "ARG MM_PACKAGE anchor not found in $DOCKERFILE"
  tmp="$(mktemp)"
  awk '
    { print }
    /^ARG MM_PACKAGE/ && !done { print ""; print "COPY --from=dist mattermost-* /tmp"; done=1 }
  ' "$DOCKERFILE" > "$tmp"
  mv "$tmp" "$DOCKERFILE"
  info "Dockerfile patched"
fi

# --- 5. Install the enterprise build workflow onto the release branch --------
[ -f "$CI_SRC" ] || die "missing canonical workflow $CI_SRC"
mkdir -p "$(dirname "$CI_DST")"
cp "$CI_SRC" "$CI_DST"
info "server-ci-enterprise.yaml installed at $CI_DST"

info "enterprise patch applied successfully"
```

- [ ] **Step 2: Make it executable**

Run:
```bash
chmod +x .tuxity/apply-enterprise.sh
```

- [ ] **Step 3: Lint the script**

Run:
```bash
shellcheck .tuxity/apply-enterprise.sh && echo SHELLCHECK_OK
```
Expected: `SHELLCHECK_OK` (no warnings). If `shellcheck` is not installed: `brew install shellcheck`.

---

## Task 5: Document the setup

**Files:**
- Create: `.tuxity/README.md`

- [ ] **Step 1: Create the README**

Create `.tuxity/README.md`:

```markdown
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
```

- [ ] **Step 2: Verify**

Run:
```bash
test -f .tuxity/README.md && echo OK
```
Expected: `OK`

---

## Task 6: Rewrite the sync workflow

**Files:**
- Modify (full rewrite): `.github/workflows/sync-new-releases.yaml`

- [ ] **Step 1: Replace the file content**

Overwrite `.github/workflows/sync-new-releases.yaml` with:

```yaml
name: Sync New Releases

on:
  schedule:
    - cron: '0 0 * * *'
  workflow_dispatch:

jobs:
  sync-new-releases:
    runs-on: ubuntu-latest
    steps:
      - name: Compare Releases
        id: compare_releases
        uses: actions/github-script@v7
        with:
          script: |
            const upstream = await github.rest.repos.getLatestRelease({
              owner: 'mattermost',
              repo: 'mattermost'
            });
            core.info(`Upstream release: ${upstream.data.tag_name}`);
            const fork = await github.rest.repos.getLatestRelease({
              owner: context.repo.owner,
              repo: context.repo.repo
            });
            core.info(`Fork release: ${fork.data.tag_name}`);
            if (upstream.data.tag_name !== fork.data.tag_name) {
              core.setOutput('new_tag', upstream.data.tag_name);
            }

      - name: Checkout fork (master, has .tuxity tooling)
        uses: actions/checkout@v4
        if: steps.compare_releases.outputs.new_tag
        with:
          token: ${{ secrets.PAT }}
          fetch-depth: 0

      - name: Build release branch with enterprise patch
        if: steps.compare_releases.outputs.new_tag
        run: |
          set -euo pipefail
          tag="${{ steps.compare_releases.outputs.new_tag }}"
          version="${tag:1}"
          major_minor="${version%.*}"
          releaseBranch="release-${major_minor}"

          # Preserve tooling across the hard reset to the upstream tag.
          cp -r .tuxity /tmp/tuxity

          git config user.name "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

          git remote add mattermost https://github.com/mattermost/mattermost.git
          git fetch mattermost tag "${tag}"

          git checkout -B "${releaseBranch}" "${tag}"

          /tmp/tuxity/apply-enterprise.sh

          git add -A
          git commit -m "feat: add enterprise license for MrRobot@fSociety"

          git tag "${tag}" --force
          git push origin "${releaseBranch}" --force
          git push origin "${tag}" --force

      - name: Notify on failure
        if: failure() && steps.compare_releases.outputs.new_tag
        continue-on-error: true
        env:
          WEBHOOK: ${{ secrets.MM_SYNC_WEBHOOK_URL }}
          TAG: ${{ steps.compare_releases.outputs.new_tag }}
          RUN_URL: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}
        run: |
          if [ -n "${WEBHOOK}" ]; then
            curl -sf -X POST -H 'Content-Type: application/json' \
              -d "{\"text\":\"❌ Mattermost enterprise sync failed for ${TAG} — ${RUN_URL}\"}" \
              "${WEBHOOK}" || true
          else
            echo "No MM_SYNC_WEBHOOK_URL configured; relying on GitHub Actions failure email."
          fi
```

- [ ] **Step 2: Validate YAML syntax**

Run:
```bash
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/sync-new-releases.yaml')); print('YAML_OK')"
```
Expected: `YAML_OK`

---

## Task 7: Local dry-run verification against the current upstream release

**Files:** none modified in the working tree — uses a throwaway worktree.

- [ ] **Step 1: Add the upstream remote and fetch the latest release tag**

Run:
```bash
git remote add upstream https://github.com/mattermost/mattermost.git 2>/dev/null || true
LATEST=$(curl -s https://api.github.com/repos/mattermost/mattermost/releases/latest | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')
echo "Latest upstream: $LATEST"
git fetch upstream tag "$LATEST"
```
Expected: prints e.g. `Latest upstream: v11.8.0` and fetches the tag.

- [ ] **Step 2: Create a throwaway worktree at the upstream tag**

Run:
```bash
git worktree add --detach /tmp/mm-verify "$LATEST"
```
Expected: worktree created at the pristine upstream tag (no `.tuxity`, no enterprise patch).

- [ ] **Step 3: Run the applier against the pristine tree**

Run:
```bash
( cd /tmp/mm-verify && /Users/kevindarcel/projects/mattermost/.tuxity/apply-enterprise.sh )
```
Expected: lines ending in `enterprise patch applied successfully`, with no `ERROR:`.

- [ ] **Step 4: Inspect the produced diff matches the design**

Run:
```bash
git -C /tmp/mm-verify status --short
git -C /tmp/mm-verify diff -- server/channels/app/platform/license.go | sed -n '1,40p'
```
Expected: modified `license.go`, `external_imports.go`, `Makefile`, `Dockerfile`; new `.github/workflows/server-ci-enterprise.yaml`. The license diff shows the `// >>> tuxity-enterprise` block immediately after the `LoadLicense() {` line.

- [ ] **Step 5: Confirm idempotency (second run is a no-op)**

Run:
```bash
( cd /tmp/mm-verify && /Users/kevindarcel/projects/mattermost/.tuxity/apply-enterprise.sh )
git -C /tmp/mm-verify diff --stat | tail -1
```
Expected: all steps report `already patched, skipping`; the diff stat is unchanged from Step 4 (no double injection).

- [ ] **Step 6: Best-effort compile check of the patched package**

Run:
```bash
( cd /tmp/mm-verify/server && go build ./channels/app/platform/ && echo BUILD_OK )
```
Expected: `BUILD_OK`. (Unreachable code after the injected `return` is legal for `go build`; the enterprise CI build does not run `go vet`.) If the local Go workspace cannot resolve modules offline, note it and rely on the authoritative CI build in Task 9 Step 3.

- [ ] **Step 7: Clean up the worktree**

Run:
```bash
git worktree remove --force /tmp/mm-verify
```
Expected: worktree removed.

---

## Task 8: Rebuild master on upstream + tooling, then force-push

**Files:**
- Rewrite branch `master` to `upstream/master` + one tooling commit (includes `.tuxity/`, the rewritten sync workflow, and the spec/plan docs).

- [ ] **Step 1: Stage the tooling outside git so it survives the reset**

Run:
```bash
rm -rf /tmp/tuxity-tooling && mkdir -p /tmp/tuxity-tooling
cp -r .tuxity /tmp/tuxity-tooling/.tuxity
cp .github/workflows/sync-new-releases.yaml /tmp/tuxity-tooling/sync-new-releases.yaml
cp -r docs/superpowers /tmp/tuxity-tooling/superpowers
```
Expected: tooling copied to `/tmp/tuxity-tooling`.

- [ ] **Step 2: Fetch upstream master and reset local master onto it**

Run:
```bash
git fetch upstream master
git checkout -B master upstream/master
```
Expected: master now points at upstream master HEAD; working tree is pristine upstream (tooling files gone — they are safe in `/tmp`).

- [ ] **Step 3: Restore the tooling onto the clean master**

Run:
```bash
cp -r /tmp/tuxity-tooling/.tuxity .tuxity
mkdir -p .github/workflows docs
cp /tmp/tuxity-tooling/sync-new-releases.yaml .github/workflows/sync-new-releases.yaml
cp -r /tmp/tuxity-tooling/superpowers docs/superpowers
chmod +x .tuxity/apply-enterprise.sh
```
Expected: `.tuxity/`, the sync workflow, and `docs/superpowers/` present on clean master. (Note: `.github/workflows/server-ci-enterprise.yaml` is intentionally NOT on master — it lives in `.tuxity/workflows/` and is generated onto release branches.)

- [ ] **Step 4: Commit the tooling**

Run:
```bash
git add .tuxity .github/workflows/sync-new-releases.yaml docs/superpowers
git status --short
git commit -m "chore: tuxity fork tooling — robust enterprise license sync + build

Rebuilds the fork tooling so each upstream release is re-patched by
.tuxity/apply-enterprise.sh (idempotent, fail-loud) instead of a fragile
hardcoded cherry-pick. master is now vanilla upstream + this commit; the
enterprise patch is materialized only onto release-* branches."
```
Expected: one commit on top of upstream master containing only the tooling + docs.

- [ ] **Step 5: Sanity-check the new master tree**

Run:
```bash
git log --oneline -1
git ls-files .tuxity .github/workflows/sync-new-releases.yaml | sort
test ! -f .github/workflows/server-ci-enterprise.yaml && echo "server-ci-enterprise NOT on master (correct)"
grep -q 'work use ../../enterprise' server/Makefile && echo "Makefile is vanilla upstream (correct)"
grep -L 'tuxity-enterprise' server/channels/app/platform/license.go >/dev/null && echo "license.go is vanilla upstream (correct)"
```
Expected: all four confirmations print; master's `license.go`/`Makefile` are unpatched upstream.

- [ ] **Step 6: Force-push master**

Run:
```bash
git push origin master --force-with-lease
```
Expected: master updated on origin. (`--force-with-lease` is safe because Task 1 already captured a backup; if it rejects due to the lease, re-fetch and retry with `--force` since backups exist.)

---

## Task 9: Regenerate the latest release and prove the build is green

**Files:** none locally — exercises the deployed workflows.

- [ ] **Step 1: Confirm required secrets exist, then dispatch the sync workflow**

Pre-req (manual, in GitHub repo settings → Secrets → Actions): `PAT` must exist with `repo` + `workflow` scopes. `MM_SYNC_WEBHOOK_URL` is optional.

Run:
```bash
gh workflow run sync-new-releases.yaml --repo tuxity/mattermost
```
Expected: `✓ Created workflow_dispatch event`. If `gh` reports the workflow isn't found yet, wait ~30s for GitHub to register the new default-branch workflow and retry.

- [ ] **Step 2: Watch the sync run to completion**

Run:
```bash
sleep 10
gh run list --repo tuxity/mattermost --workflow sync-new-releases.yaml -L 1
gh run watch --repo tuxity/mattermost $(gh run list --repo tuxity/mattermost --workflow sync-new-releases.yaml -L 1 --json databaseId -q '.[0].databaseId')
```
Expected: the sync run completes successfully and force-pushes `release-11.8` + the new tag.

- [ ] **Step 3: Watch the triggered enterprise build (authoritative compile + release)**

Run:
```bash
sleep 10
gh run list --repo tuxity/mattermost --workflow server-ci-enterprise.yaml -L 3
gh run watch --repo tuxity/mattermost $(gh run list --repo tuxity/mattermost --workflow server-ci-enterprise.yaml -L 1 --json databaseId -q '.[0].databaseId')
```
Expected: the enterprise build for the new tag completes green — this is the real proof the early-return patch compiles and packages.

- [ ] **Step 4: Verify the new GitHub Release and Docker image exist**

Run:
```bash
NEW=$(curl -s https://api.github.com/repos/mattermost/mattermost/releases/latest | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')
echo "Expecting fork release: $NEW"
gh release view "$NEW" --repo tuxity/mattermost --json tagName,assets -q '{tag: .tagName, assets: [.assets[].name]}'
```
Expected: fork release for `$NEW` exists with the 5 platform assets; the ghcr image was pushed by the build job.

---

## Task 10: Delete stale release branches (final, irreversible cleanup)

**Files:** none — deletes stale remote branches only. Published tags/Releases/images are KEPT.

- [ ] **Step 1: List the stale release branches (everything except the just-regenerated latest)**

Run:
```bash
git fetch origin --prune
NEWMM=$(curl -s https://api.github.com/repos/mattermost/mattermost/releases/latest | sed -n 's/.*"tag_name": *"v\([0-9]*\.[0-9]*\).*/\1/p')
echo "Keeping release-$NEWMM; the rest are stale:"
git branch -r | sed 's# *origin/##' | grep '^release-' | grep -v "^release-$NEWMM$"
```
Expected: prints the stale `release-*` branches (e.g. 9.5 … 11.5, 11.7), excluding the regenerated `release-$NEWMM` and any `backup/*`.

- [ ] **Step 2: Confirm the keep/backups are safe before deleting**

Run:
```bash
git ls-remote --heads origin "release-$NEWMM" "backup/pre-cleanup-2026-06-16"
```
Expected: both the new release branch and the backup branch are present on origin.

- [ ] **Step 3: Delete the stale release branches on origin**

Run:
```bash
NEWMM=$(curl -s https://api.github.com/repos/mattermost/mattermost/releases/latest | sed -n 's/.*"tag_name": *"v\([0-9]*\.[0-9]*\).*/\1/p')
for b in $(git branch -r | sed 's# *origin/##' | grep '^release-' | grep -v "^release-$NEWMM$"); do
  echo "Deleting origin/$b"
  git push origin --delete "$b"
done
```
Expected: each stale `release-*` branch deleted. Published `v*` tags, GitHub Releases, and Docker images remain untouched.

- [ ] **Step 4: Final state check**

Run:
```bash
git fetch origin --prune
echo "Remaining release branches:"; git branch -r | grep 'origin/release-'
echo "Backups still present:"; git ls-remote origin 'backup/*'
echo "Published tags still present:"; git ls-remote --tags origin 'v*' | tail -5
```
Expected: only `release-$NEWMM` remains among release branches; backups intact; published `v*` tags intact.

---

## Done criteria

- `master` = vanilla `upstream/master` + one `.tuxity/` tooling commit; compiles like upstream.
- A fresh `release-<latest>` + tag built green and produced a GitHub Release + ghcr image via the new robust applier.
- Stale `release-*` branches removed; all previously published tags/Releases/images preserved; full backup bundle + backup branch/tags retained.
- Future upstream releases are picked up automatically by the daily cron and re-patched without cherry-pick conflicts; failures alert via webhook / Actions email.
