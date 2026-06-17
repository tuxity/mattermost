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
# shellcheck disable=SC2016  # $(BUILD_ENTERPRISE_DIR) is a Make variable, not a shell expansion
if grep -qF 'work use $(BUILD_ENTERPRISE_DIR)' "$MAKEFILE"; then
  info "Makefile already patched, skipping"
elif grep -qF 'work use ../../enterprise' "$MAKEFILE"; then
  # shellcheck disable=SC2016  # $(BUILD_ENTERPRISE_DIR) is a Make variable, not a shell expansion
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
