#!/usr/bin/env bash
# Purpose: Verify profile bootstrap SOUL activation without overwriting customized identities.
# Scope: Execute the rendered init Job against temporary PVC/bootstrap paths.
# Requirements: Bash, Python 3 with PyYAML, and repository scripts.
# Usage: ./tests/bootstrap-soul.sh
# Exit status: 0 means generic seeds upgrade and customized SOUL files remain preserved.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d -t hermes-bootstrap-soul-test.XXXXXX)"
trap 'if [[ "${KEEP_TMP:-false}" == true ]]; then printf "kept test fixture: %s\\n" "$TMP_DIR" >&2; else rm -rf "$TMP_DIR"; fi' EXIT

bootstrap_source="$TMP_DIR/bootstrap-source"
mkdir -p "$bootstrap_source"
cp "$ROOT_DIR/examples/bootstrap-profiles/universal-system-administrator/SOUL.md" \
  "$bootstrap_source/SOUL.md"
expected_soul="$bootstrap_source/SOUL.md"

render_case() {
  local mode="$1"
  local mask="${2:-022}"
  (
    umask "$mask"
    set -a
    # shellcheck disable=SC1091
    source "$ROOT_DIR/examples/hermes.env.example"
    set +a
    export HERMES_INSTALL_LIB_ONLY=true
    # shellcheck disable=SC1091
    source "$ROOT_DIR/install.sh"
    export HERMES_BOOTSTRAP_PROFILE=
    export HERMES_BOOTSTRAP_DIR="$bootstrap_source"
    export HERMES_BOOTSTRAP_MODE="$mode"
    export HERMES_ADDON_REQUIREMENTS=
    export HERMES_ANSIBLE_SETUP=false
    export HERMES_SSH_SETUP=false
    export HERMES_RENDER_DIR="$TMP_DIR/render-$mode"
    prepare_paths
    prepare_defaults
    create_bootstrap_archive
    API_SERVER_KEY_REVISION=test-resource-version
    render_manifest
  )
}

render_case missing 022
render_case overwrite 077
render_case disabled

# Rendering identical bootstrap content under different caller umasks must be
# byte-reproducible so an idempotent install does not churn the Kubernetes Secret.
cmp -s "$TMP_DIR/render-missing/bootstrap.tar.gz" "$TMP_DIR/render-overwrite/bootstrap.tar.gz"

make_runner() {
  local mode="$1"
  local root="$2"
  mkdir -p "$root/home" "$root/workspace" "$root/bootstrap"
  if [[ -f "$TMP_DIR/render-$mode/bootstrap.tar.gz" ]]; then
    cp "$TMP_DIR/render-$mode/bootstrap.tar.gz" "$root/bootstrap/bootstrap.tar.gz"
  fi
  python3 - "$TMP_DIR/render-$mode/hermes.yaml" "$root" > "$root/run-init.sh" <<'PY'
import sys
from pathlib import Path
import yaml

manifest, root = sys.argv[1:]
docs = [doc for doc in yaml.safe_load_all(open(manifest)) if doc]
job = next(doc for doc in docs if doc.get("kind") == "Job" and doc["metadata"]["name"] == "hermes-init-config")
container = job["spec"]["template"]["spec"]["containers"][0]
script = container["args"][0]
# Preserve the init Job's private extraction tree while redirecting only mounted paths.
script = script.replace("/tmp/hermes-bootstrap", "__HERMES_EXTRACT__")
script = script.replace("/bootstrap/bootstrap.tar.gz", "__HERMES_ARCHIVE__")
script = script.replace("/opt/data", "__HERMES_HOME__")
script = script.replace("/workspace", "__HERMES_WORKSPACE__")
# Resolve sentinels last: TMPDIR may itself live beneath /opt/data or /workspace.
script = script.replace("__HERMES_ARCHIVE__", f"{root}/bootstrap/bootstrap.tar.gz")
script = script.replace("__HERMES_HOME__", f"{root}/home")
script = script.replace("__HERMES_WORKSPACE__", f"{root}/workspace")
script = script.replace("__HERMES_EXTRACT__", f"{root}/extracted-bootstrap")
# The production Job runs as root. The fixture is already owned by the test user.
script = "\n".join(
    ": # test fixture owns temporary paths" if line.strip().startswith("chown -R ") else line
    for line in script.splitlines()
)
print("#!/bin/sh")
print(script)
PY
  chmod 700 "$root/run-init.sh"
}

upstream_generic='You are Hermes Agent, an intelligent AI assistant created by Nous Research. You are helpful, knowledgeable, and direct. You assist users with a wide range of tasks including answering questions, writing and editing code, analyzing information, creative work, and executing actions via your tools. You communicate clearly, admit uncertainty when appropriate, and prioritize being genuinely useful over being verbose unless otherwise directed below. Be targeted and efficient in your exploration and investigations.'
installer_generic='You are Hermes Agent, an intelligent AI assistant. Be helpful, direct, technically precise, and security-conscious.

## Browser usage policy
A real Chromium browser is available through Hermes browser tools via the `BROWSER_CDP_URL` environment variable. Use browser tools for real UI/web verification, especially WebUI issues, JavaScript-rendered pages, login flows, Ingress checks, screenshots, browser console errors, and reproducing frontend problems. Use curl for HTTP status/headers/health endpoints, but do not rely only on curl for UI problems. Never print the full `BROWSER_CDP_URL`; it contains a token.'
custom_soul='# Operator identity

Preserve this customized identity exactly.'
export BROWSER_CDP_URL='ws://browser.example.invalid/chromium?token=test-only'
export API_SERVER_KEY='test-api-server-key-long-enough'

# A fresh install on an empty PVC must finish with the selected profile SOUL.
root="$TMP_DIR/fresh"
make_runner missing "$root"
"$root/run-init.sh"
cmp -s "$expected_soul" "$root/home/SOUL.md"

# A generic SOUL seeded by Hermes must not block the selected bootstrap profile.
root="$TMP_DIR/upstream-generic"
make_runner missing "$root"
printf '%s\n' "$upstream_generic" > "$root/home/SOUL.md"
"$root/run-init.sh"
cmp -s "$expected_soul" "$root/home/SOUL.md"

# The installer's own generic fallback must also upgrade to the selected profile.
root="$TMP_DIR/installer-generic"
make_runner missing "$root"
printf '%s\n' "$installer_generic" > "$root/home/SOUL.md"
"$root/run-init.sh"
cmp -s "$expected_soul" "$root/home/SOUL.md"

# A genuinely customized identity remains operator-owned in missing mode.
root="$TMP_DIR/customized"
make_runner missing "$root"
printf '%s\n' "$custom_soul" > "$root/home/SOUL.md"
custom_before="$(sha256sum "$root/home/SOUL.md" | cut -d' ' -f1)"
"$root/run-init.sh"
[[ "$(sha256sum "$root/home/SOUL.md" | cut -d' ' -f1)" == "$custom_before" ]]
grep -Fqx '# Operator identity' "$root/home/SOUL.md"

# Stock text plus any operator content is customized and must be preserved.
root="$TMP_DIR/near-match"
make_runner missing "$root"
printf '%s\n%s\n' "$upstream_generic" '# Operator extension' > "$root/home/SOUL.md"
near_match_before="$(sha256sum "$root/home/SOUL.md" | cut -d' ' -f1)"
"$root/run-init.sh"
[[ "$(sha256sum "$root/home/SOUL.md" | cut -d' ' -f1)" == "$near_match_before" ]]
grep -Fqx '# Operator extension' "$root/home/SOUL.md"

# Missing mode must not follow or replace an operator-created SOUL symlink.
root="$TMP_DIR/symlink"
make_runner missing "$root"
printf '%s\n' "$upstream_generic" > "$root/operator-soul"
ln -s ../operator-soul "$root/home/SOUL.md"
"$root/run-init.sh"
[[ -L "$root/home/SOUL.md" ]]
[[ "$(readlink "$root/home/SOUL.md")" == ../operator-soul ]]
[[ "$(cat "$root/operator-soul")" == "$upstream_generic" ]]

# A multiply linked SOUL is also operator-owned and must be preserved.
root="$TMP_DIR/hardlink"
make_runner missing "$root"
printf '%s\n' "$upstream_generic" > "$root/operator-soul"
ln "$root/operator-soul" "$root/home/SOUL.md"
"$root/run-init.sh"
[[ "$(stat -c '%h' "$root/home/SOUL.md")" == 2 ]]
[[ "$(cat "$root/operator-soul")" == "$upstream_generic" ]]

# Rerunning after profile activation is idempotent.
profile_before="$(sha256sum "$TMP_DIR/upstream-generic/home/SOUL.md" | cut -d' ' -f1)"
"$TMP_DIR/upstream-generic/run-init.sh"
[[ "$(sha256sum "$TMP_DIR/upstream-generic/home/SOUL.md" | cut -d' ' -f1)" == "$profile_before" ]]

# Explicit overwrite mode continues to replace a customized identity.
root="$TMP_DIR/overwrite"
make_runner overwrite "$root"
printf '%s\n' "$custom_soul" > "$root/home/SOUL.md"
"$root/run-init.sh"
cmp -s "$expected_soul" "$root/home/SOUL.md"

# Disabled bootstrap mode never changes an existing SOUL.
root="$TMP_DIR/disabled"
make_runner disabled "$root"
printf '%s\n' "$upstream_generic" > "$root/home/SOUL.md"
disabled_before="$(sha256sum "$root/home/SOUL.md" | cut -d' ' -f1)"
"$root/run-init.sh"
[[ "$(sha256sum "$root/home/SOUL.md" | cut -d' ' -f1)" == "$disabled_before" ]]

printf 'bootstrap SOUL tests passed: generic seeds upgrade, customized identities follow missing/overwrite policy, disabled mode is unchanged\n'
