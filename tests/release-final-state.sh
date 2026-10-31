#!/usr/bin/env bash
# Enforce the supported v2.7.9 release shape and reject experimental PoC artifacts.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

[[ "$(<VERSION)" == 2.7.9 ]]
grep -Fq '## [v2.7.9] - 2026-10-31' CHANGELOG.md
grep -Fq '## [v2.7.8] - 2026-10-31' CHANGELOG.md
grep -Fq '## [v2.7.7] - 2026-10-31' CHANGELOG.md
grep -Fq '## [v2.7.6] - 2026-10-31' CHANGELOG.md
grep -Fq '## [v2.7.5] - 2026-09-04' CHANGELOG.md
grep -Fq '## [v2.7.3] - 2026-08-29' CHANGELOG.md
grep -Fq '## [v2.7.2] - 2026-08-29' CHANGELOG.md
grep -Fq '## [v2.7.1] - 2026-08-28' CHANGELOG.md
grep -Fq '## [v2.7.0] - 2026-08-28' CHANGELOG.md
grep -Fq '[Issue #98]' CHANGELOG.md
grep -Fq '[PR #111]' CHANGELOG.md
grep -Fq '[PR #112, follow-up to PR #111]' CHANGELOG.md

# A release branch must not ship disconnected proof-of-concept source or docs.
if git ls-files | grep -Eq '(^|/)poc(/|$)|software-generations-poc'; then
  printf 'tracked PoC artifact remains in final release\n' >&2
  git ls-files | grep -E '(^|/)poc(/|$)|software-generations-poc' >&2
  exit 1
fi
! grep -Eqi 'experimental immutable software-generation|software-generation PoC|under `poc/' README.md CHANGELOG.md docs/*.md

# Issue #98 is fixed in the supported WebUI Deployment path.
grep -Fq 'node_root=/opt/data/node' manifests/hermes.yaml.tpl
grep -Fq 'runtime_stage="$runtimes/.$runtime_key.$$"' manifests/hermes.yaml.tpl
grep -Fq 'mv -fT "$current_tmp" "$node_root/current"' manifests/hermes.yaml.tpl
grep -Fq 'runtime="$(readlink -f "$node_root/current")"' manifests/hermes.yaml.tpl
grep -Fq 'NODE_LAUNCHER' manifests/hermes.yaml.tpl
grep -Fq 'NPM_LAUNCHER' manifests/hermes.yaml.tpl
grep -Fq 'NPX_LAUNCHER' manifests/hermes.yaml.tpl
grep -Fq 'current="$(printenv LD_LIBRARY_PATH 2>/dev/null || true)"' manifests/hermes.yaml.tpl
! grep -Fq '        - name: LD_LIBRARY_PATH' manifests/hermes.yaml.tpl

# The production regression is part of the normal repository test tree.
[[ -x tests/node-runtime-launcher.sh ]]

# Password-file automation must never echo the passphrase through the PTY.
grep -Fq '"--echo",' scripts/age_passphrase.py
grep -Fq '"never",' scripts/age_passphrase.py
grep -Fq 'age passphrase helper requires --output PATH' scripts/age_passphrase.py
grep -Fq 'Never forward the captured' scripts/age_passphrase.py
grep -Fq 'age command failed with exit status' scripts/age_passphrase.py

# v2.7.2 persistent-software architecture guide must exist and stay linked.
[[ -f docs/persistent-software.md ]]
grep -Fq 'docs/persistent-software.md' README.md
grep -Fq 'persistent-software.md' docs/operations.md
grep -Fq 'persistent-software.md' docs/pvc-and-containers.md

# v2.7.3 data-only backup/restore must exist and stay documented.
grep -Fq 'DATA_ONLY_PATHS' maintain.sh
grep -Fq -- '--data-only' maintain.sh
grep -Fq -- '--data-only' docs/operations.md

# v2.7.4 session policy must remain wired and described with precise semantics.
grep -Fq 'HERMES_AUTH_SESSION_MAX_TTL_SECONDS=43200' examples/hermes.env.example
grep -Fq 'HERMES_AUTH_SESSION_IDLE_TTL_SECONDS=7200' examples/hermes.env.example
grep -Fq 'value: "${HERMES_AUTH_SESSION_MAX_TTL_SECONDS}"' manifests/hermes.yaml.tpl
grep -Fq 'HERMES_WEBUI_SESSION_TTL "$HERMES_AUTH_SESSION_MAX_TTL_SECONDS"' doctor.sh
grep -Fq '| Hermes Dashboard OIDC ID-token contract | Not supported | 12h |' docs/authelia-freeipa-sso-overview.md
grep -Fq 'Dashboard OIDC ID token reaches its configured 12-hour lifetime' docs/authelia-freeipa-sso-setup-guide.md
! grep -Fq 'WebUI and Dashboard application sessions expire after 12 hours' docs/authelia-freeipa-sso-setup-guide.md

printf 'v2.7.9 final-state contract passed\n'
