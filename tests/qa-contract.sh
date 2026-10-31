#!/usr/bin/env bash
# Purpose: Enforce the repository's documented quality-assurance acceptance contract.
# Scope: Ensure AGENTS.md and docs/qa.md require real Linux/K3s validation, full-stack
#        coverage, failure-state checks, reinstall checks, and explicit blocked-gate handling.
# Requirements: Bash, grep, and repository documentation.
# Usage: ./tests/qa-contract.sh
# Exit status: 0 means the required QA contract is documented; non-zero identifies a gap.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENTS="$ROOT_DIR/AGENTS.md"
QA_DOC="$ROOT_DIR/docs/qa.md"
MANIFEST="$ROOT_DIR/manifests/hermes.yaml.tpl"
SOFTWARE_DOC="$ROOT_DIR/docs/persistent-software.md"
SSO_SETUP_DOC="$ROOT_DIR/docs/authelia-freeipa-sso-setup-guide.md"

# The executable external-OIDC migration preflight must honor an operator's
# configured session maximum instead of silently assuming the default 43200.
grep -Fq 'python3 - "$render_dir/hermes.yaml" "$deploy" "$HERMES_AUTH_SESSION_MAX_TTL_SECONDS"' "$SSO_SETUP_DOC"
grep -Fq 'manifest, wanted, expected_session_ttl = sys.argv[1:]' "$SSO_SETUP_DOC"
grep -Fq 'env.get("HERMES_WEBUI_SESSION_TTL") != expected_session_ttl' "$SSO_SETUP_DOC"
! grep -Fq 'env.get("HERMES_WEBUI_SESSION_TTL") != "43200"' "$SSO_SETUP_DOC"

# The WebUI image must receive a complete, runnable Node/npm/npx toolchain
# from the Agent image without replacing the WebUI image's own loader path.
# Candidate runtimes are validated off-path and activated through one pointer.
grep -Fq 'cp -a "$npm_source" "$runtime_stage/lib/node_modules/npm"' "$MANIFEST"
grep -Fq 'runtime_stage="$runtimes/.$runtime_key.$$"' "$MANIFEST"
grep -Fq 'LD_LIBRARY_PATH="$runtime_stage/lib" "$runtime_stage/libexec/node" --version' "$MANIFEST"
grep -Fq 'mv -fT "$current_tmp" "$node_root/current"' "$MANIFEST"
grep -Fq 'runtime="$(readlink -f "$node_root/current")"' "$MANIFEST"
grep -Fq 'NODE_LAUNCHER' "$MANIFEST"
grep -Fq 'NPM_LAUNCHER' "$MANIFEST"
grep -Fq 'NPX_LAUNCHER' "$MANIFEST"
grep -Fq 'current="$(printenv LD_LIBRARY_PATH 2>/dev/null || true)"' "$MANIFEST"
! grep -Fq '        - name: LD_LIBRARY_PATH' "$MANIFEST"
grep -Fq 'name: npm_config_yes' "$MANIFEST"
! grep -Fq 'HERMES_NPX_SETUP' "$MANIFEST"

# Persistent-software docs must retain exact implementation boundaries.
for needle in \
  'changes versions only when required by current constraints' \
  'does not proactively upgrade satisfying requirements-managed versions' \
  'pip itself is upgraded on every addon-enabled run' \
  'checks only whether `bin/python` is executable and the `.hermes-uv-managed` marker exists' \
  'other corruption can fail later package operations and requires a controlled manual rebuild' \
  '`/usr/local/bin/node`' \
  '`npm root -g`' \
  'hard compatibility contract for a custom Agent image' \
  'must be a self-contained real directory tree' \
  'must be relative and resolve to a target inside the npm tree' \
  'Absolute symlinks are unsupported even when their source target is inside that tree' \
  'forbid absolute and out-of-tree npm symlinks'; do
  grep -Fq -- "$needle" "$SOFTWARE_DOC"
done

# Persistent-software documentation must retain implementation boundaries that
# are easy to overstate when installer behavior evolves.
for needle in \
  'does not otherwise seek newer releases' \
  'explicitly uninstalls `ansible` and `ansible-core`' \
  'only `libatomic.so.1`' \
  'previous rollback history is discarded' \
  "cat >> hermes.env <<'EOF'"; do
  grep -Fq -- "$needle" "$SOFTWARE_DOC"
done

# Agent and Dashboard use startup probes to gate prompt readiness without
# exposing traffic early or starting liveness before slow startup completes.
python3 - "$MANIFEST" <<'PY'
from pathlib import Path
import re,sys
text=Path(sys.argv[1]).read_text()
for name in ('hermes-agent','hermes-dashboard'):
    start=text.index(f'kind: Deployment\nmetadata:\n  name: {name}\n')
    end=text.find('\n---\n',start)
    block=text[start:end if end >= 0 else None]
    startup=re.search(r'startupProbe:\n(?P<body>(?:.*\n){1,10})',block)
    assert startup, (name,'startupProbe')
    period=re.search(r'periodSeconds:\s*(\d+)',startup.group('body'))
    failures=re.search(r'failureThreshold:\s*(\d+)',startup.group('body'))
    assert period and failures and int(period.group(1))*int(failures.group(1)) >= 120, (name,'startupBudget')
    readiness=re.search(r'readinessProbe:\n(?:.*\n){0,8}?\s+initialDelaySeconds:\s*(\d+)',block)
    assert readiness and int(readiness.group(1)) <= 5, (name,'readinessDelay')
    liveness=re.search(r'livenessProbe:\n(?:.*\n){0,8}?\s+initialDelaySeconds:\s*(\d+)',block)
    assert liveness and int(liveness.group(1)) <= 5, (name,'livenessDelay')
PY

# Required maintainer guidance must remain present in AGENTS.md.
for needle in \
  'live Linux/K3s or real-VM test is mandatory' \
  'static rendering, fake-`kubectl`, or Agent-only deployment is never sufficient' \
  'full-stack case is mandatory' \
  'CrashLoopBackOff' \
  '--previous' \
  'Secret hash stability' \
  'mark unavailable gates as blocked'; do
  grep -Fqi -- "$needle" "$AGENTS"
done

# Required acceptance coverage must remain present in docs/qa.md.
for needle in \
  'fresh disposable Linux/K3s VM' \
  'Agent-only' \
  'Dashboard' \
  'WebUI' \
  'Browserless' \
  'full' \
  'reinstall' \
  'CrashLoopBackOff' \
  'invalid credentials rejected' \
  'real Chromium'; do
  grep -Fqi "$needle" "$QA_DOC"
done

# Doctor must validate optional WebUI dependencies only when their features are enabled.
python3 - "$ROOT_DIR/doctor.sh" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")
webui_source = text.split("check_webui_agent_source() {", 1)[1].split("\n}", 1)[0]
addon_runtime = text.split("check_addon_python_runtime() {", 1)[1].split("\n}", 1)[0]

assert 'is_truthy "$HERMES_BROWSER_ENABLED" || return 0' in webui_source
assert 'webui agent source mount exists' in webui_source
assert 'webui BROWSER_CDP_URL configured' in webui_source
assert 'is_truthy "${HERMES_ANSIBLE_SETUP:-false}" || return 0' in addon_runtime
PY

printf 'QA contract checks passed\n'
