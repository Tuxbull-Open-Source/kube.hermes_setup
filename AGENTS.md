# Agent maintainer guide for `kube.hermes_setup`

This file is for coding agents and human maintainers working on this repository. It captures project context, repository rules, validation commands, and hard-won pitfalls from real K3s/Hermes deployments.

Public `AGENTS.md` guidance describes this kind of file as a "README for agents": keep it concrete, repo-local, testable, and focused on what future agents must not rediscover the painful way. Tools that support repository-level agent instructions should load this file automatically.

## Repository purpose

This repository packages a proof-of-concept Kubernetes/K3s installer for lab use and agent experimentation only. Never use it in production environments. It deploys a multi-container Hermes Agent stack:

- `hermes-agent` — Hermes Gateway/API runtime from `nousresearch/hermes-agent`.
- `hermes-dashboard` — Hermes Dashboard from the same Agent image.
- `hermes-webui` — chat WebUI from `ghcr.io/nesquena/hermes-webui`.
- `hermes-browser` — internal Browserless Chromium/CDP backend from `ghcr.io/browserless/chromium`.

The repo is template-driven. It must remain safe for public GitHub: no real hostnames, passwords, tokens, OAuth state, kubeconfigs, generated manifests with real secrets, or backups.

## Current repo defaults

Keep these defaults in source unless the maintainer explicitly asks otherwise:

```bash
MODEL_PROVIDER=openai-codex
MODEL_NAME=gpt-5.6-luna
BROWSER_CONCURRENT=4
BROWSER_QUEUED=10
BROWSER_TIMEOUT_MS=30000
HERMES_RUNTIME_UID=10000
HERMES_RUNTIME_GID=10000
HERMES_WEBUI_MAX_UPLOAD_MB=220
```

Rationale:

- `gpt-5.6-luna` + `openai-codex` is the preferred model/provider default.
- Browserless concurrency `4` leaves capacity for parallel CDP checks and user sessions; keep docs and tests aligned with that default.
- Runtime UID/GID `10000:10000` is the manifest's shared PVC ownership contract across init containers and WebUI runtime mapping.

## Important files

```text
README.md                         User-facing overview and quick start
VERSION                           Current release version
LICENCE                           MIT license
configure.sh                      Interactive current_config generator and installer handoff
install.sh                        Render/apply installer, secret creation, rollout waits
maintain.sh                       Status, backup/restore, restart, password/token rotation
doctor.sh                         Health/diagnostic checks
examples/hermes.env.example       Public example env; no real values
manifests/hermes.yaml.tpl         Kubernetes template
scripts/render_template.py        Env-driven renderer with optional blocks
docs/operations.md                Day-2 runbook
docs/security.md                  Security model and secret-handling rules
docs/troubleshooting.md           Known failure modes and fixes
docs/codex-auth.md                Manual Codex OAuth pairing
examples/bootstrap-shared/skills/ Shared reusable skills for all profiles
examples/bootstrap-shared/workspace/ Shared workspace instructions
examples/bootstrap-profiles/      Profile-specific SOUL, memories, requirements, workspace
```

Generated/local files that must not be committed:

```text
hermes.env
current_config/
configuration_answers
*.env
.rendered/
backups/
*.tgz
kubeconfig*
auth.json
```

## Security rules — do not violate these

1. Never commit or print real credentials, API keys, OAuth tokens, `auth.json`, kubeconfig contents, generated BasicAuth values, Browserless tokens, or backup archives.
2. Never paste generated credential file contents into chat or docs. You may report metadata such as path, mode, and size.
3. Use placeholders in docs/examples:
   - `hermes.example.com`
   - `hermes-admin.example.com`
   - `example.com`
   - `[REDACTED]`
   - `CHANGE_ME`
4. Do not put a real `BROWSER_CDP_URL` in `config.yaml`; it contains a token. Keep it as a Kubernetes Secret-backed environment variable.
5. Treat backups as sensitive. They include `/opt/data` and may contain OAuth state, sessions, memories, skills, credentials, and workspace files.
6. Before every commit, run a leak scan for private hostnames and common secret patterns.

Recommended leak-scan pattern:

```bash
# Define these locally for your environment. Do not hard-code private hostnames here.
SECRET_REGEX='<common-token-or-private-key-regex>'
PRIVATE_HOST_REGEX='<your-private-domain-regex>'

grep -RInE "$SECRET_REGEX|$PRIVATE_HOST_REGEX" . \
  --exclude-dir=.git \
  --exclude-dir=.rendered \
  --exclude='hermes.env' \
  --exclude='her-test.env' \
  && { echo 'possible leak found' >&2; exit 1; } \
  || true
```

## Standard validation commands

Run these before committing normal repo changes:

```bash
bash -n configure.sh install.sh maintain.sh doctor.sh
python3 -m py_compile scripts/render_template.py scripts/prepare_requirements.py
./tests/profile-composition.sh
./tests/bootstrap-soul.sh
./tests/agent-instructions-safety.sh
./tests/configure.sh
./tests/matrix.sh
./tests/ssh-identity.sh
./tests/credentials.sh
./tests/reconcile-api-key.sh
./tests/backup.sh
rm -rf scripts/__pycache__
```

When bootstrap skills change, verify that every `SKILL.md` starts with YAML frontmatter, has matching `name` and directory values, contains a non-empty body, and that each `metadata.hermes.related_skills` entry is classified as `bundled`, `external-runtime`, or `optional-reference`. Only entries classified as `bundled` must resolve under the repository's bootstrap skill tree.

Render validation:

```bash
out=/tmp/hermes-rendered.yaml
set -a
. examples/hermes.env.example
set +a
export WEBUI_HOST=hermes.example.com
export DASHBOARD_HOST=hermes-admin.example.com
export DASHBOARD_AUTH_PASSWORD='Strong-Test-Password-2!'
export API_SERVER_KEY='test-api-key-1234567890'
export BROWSER_TOKEN='test-browser-token'
export BROWSER_CDP_URL='ws://hermes-browser:3000/chromium?token=test-browser-token'
python3 scripts/render_template.py manifests/hermes.yaml.tpl "$out"
python3 - <<'PY' "$out"
import sys, yaml
for doc in yaml.safe_load_all(open(sys.argv[1])):
    pass
print('yaml ok')
PY
kubectl create --dry-run=client --validate=false -f "$out" >/dev/null
```

If a live cluster is reachable, also run:

```bash
./doctor.sh
```

For purely repo-local documentation changes with no executable examples or behavior claims, a live deployment is not required. For every change that can affect installer behavior, rendered Kubernetes resources, bootstrap, credentials, optional components, authentication, WebUI, Browserless, SSH, Ansible, PVCs, or rollout sequencing, a live Linux/K3s or real-VM test is mandatory. If the required target is unavailable, the work is **blocked**, not successful; do not downgrade the result to a static-only pass.

## Live K3s profile validation protocol

Changes to profile composition, defaults, bootstrap archives, init behavior, SSH, Ansible, addon requirements, ingress, authentication, credentials, Browserless, or WebUI wiring require a disposable Linux/K3s test or an explicitly approved real test VM. Static rendering, fake-`kubectl`, or Agent-only deployment is never sufficient for these changes.

1. Start from a fresh disposable Linux VM. Record the OS, Kubernetes version, container images, repository commit, CPU, memory, storage, and ingress controller without publishing private hostnames or addresses.
2. Install K3s, wait for the node, DNS, storage provisioner, metrics server, and Traefik to become ready, and use a lab-only TLS certificate whose names are public-safe placeholders in any committed report.
3. Deploy the minimum required matrix from clean namespaces/PVCs: Agent-only, Dashboard, WebUI, Browserless, and full stack. For any change touching shared manifests or installer sequencing, the full-stack case is mandatory. Require every enabled deployment and the init job to become ready; a single healthy Agent does not satisfy this gate.
4. After every rollout, inspect `get pods`, events, current logs, and `--previous` logs for each enabled deployment. A `CrashLoopBackOff`, startup exit, failed readiness probe, or image/package build failure is a hard failure even if other components are healthy.
5. Verify the personal runtime has exactly `markdown-pdf` and `hermes-workspace-manager`, exactly one persistent SSH key selected by OpenSSH from every runtime account home, no `/workspace/ansible`, an empty `ANSIBLE_CONFIG`, and no Ansible package. Exercise the Markdown-to-PDF renderer and validate the produced PDF header, page count, and extracted text.
6. Run the Hermes CLI directly in the Agent container (`hermes --version`) and exercise any changed interactive CLI path through a real TTY. Do not use `sh -lc` as proof of CLI absence because login shells can reset the image `PATH`.
7. Use real Chromium against the deployed HTTPS ingress whenever WebUI is enabled. Verify the login page, rejection of an invalid password, acceptance of the configured password, authenticated UI content, a clean authenticated browser console, and a visually inspected screenshot. Curl-only checks do not satisfy WebUI validation.
8. Rerun `install.sh` unchanged for the same deployment and prove rollout success, Secret hash stability, PVC identity preservation, and persistence of a test artifact.
9. Remove the personal namespace, deploy `universal-system-architect` from clean PVCs, and run `doctor.sh`. Verify all selected skills, persistent SSH key permissions and matching fingerprints, `ANSIBLE_CONFIG`, Ansible version/config, `ansible localhost -m ping`, and compatibility/imports for the full addon requirements.
10. Repeat the CLI, TLS, invalid/valid Chromium login, authenticated console, and screenshot checks for the architect profile.
11. Test defaults and explicit overrides separately. At minimum cover environment-only installation with a missing `ENV_FILE`, `HERMES_SSH_SETUP=false`, `HERMES_ANSIBLE_SETUP=false`, custom `HERMES_ANSIBLE_CONFIG`, and explicit-empty `HERMES_ADDON_REQUIREMENTS=`. On a fresh PVC, disabled Ansible must leave no `/workspace/ansible`, no addon Ansible binary, and an empty `ANSIBLE_CONFIG`.
12. Test an invalid profile and confirm installation fails before Kubernetes resources are changed. Test a custom `HERMES_BOOTSTRAP_DIR` to ensure profile composition does not replace operator-owned bootstrap content.
13. Delete temporary namespaces and sensitive generated files. Destroy the disposable VM when it is no longer needed. Update the PR with sanitized environment facts, exact pass/fail evidence, fixes made, and remaining limitations; never include internal DNS names, IP addresses, passwords, tokens, certificate keys, or generated credential contents.

The PR description must distinguish `static/local`, `render/schema`, `live/cluster`, and `runtime/acceptance` evidence. It must name every required gate and mark unavailable gates as blocked. Never leave an outdated statement such as "No live cluster changed" after performing live validation, and never claim overall success from static or Agent-only evidence when WebUI/optional components are in scope. See [`docs/qa.md`](docs/qa.md) for the repository QA contract.

See [`docs/qa.md`](docs/qa.md) for the mandatory live acceptance matrix, evidence requirements, WebUI crash-loop handling, and explicit blocked-state rules.

## Git workflow expectations

- Start from the current `origin/main`, but use a scoped branch and pull request for changes because `main` is protected.
- Keep commits small and descriptive.
- Do not commit generated files.
- Commit and push repo fixes once validated unless the maintainer explicitly says not to.
- Mention exact commit SHA in the final response.

## Release preparation

Preparing a release means updating `CHANGELOG.md`, validating render/syntax checks, and leaving the branch/PR ready to merge. Do not create or push Git tags unless the maintainer explicitly asks to tag after merge.

## Installer behavior that matters

`install.sh` must be re-runnable:

- It uses explicit `ENV_FILE` first, then root `hermes.env`, then wizard-generated `current_config/hermes.env`.
- It creates/generates Kubernetes Secrets.
- It renders `manifests/hermes.yaml.tpl` to `$HERMES_RENDER_DIR/hermes.yaml` (`current_config/artifacts` for wizard installs, `.rendered` by manual default).
- It deletes/recreates the one-shot `hermes-init-config` Job before apply. Kubernetes Jobs are immutable enough to make repeat applies painful otherwise.
- It restarts deployments after refreshing Secret-backed env values because Kubernetes does not reload env vars into running Pods.

Keep this restart behavior. It prevents Browserless token mismatch and stale dashboard/WebUI password env values.

## Authentication model

There are two app auth layers:

1. Dashboard internal BasicAuth.
   - Configured when Dashboard is enabled.
   - Uses `secret/hermes-dashboard-auth`.
2. WebUI built-in password auth.
   - Configured when WebUI is enabled.
   - `HERMES_WEBUI_PASSWORD` is read from `secret/hermes-dashboard-auth:password`.
   - Therefore WebUI password == `DASHBOARD_AUTH_PASSWORD`.

Do not set `HERMES_WEBUI_ONBOARDING_OPEN=1` as a steady-state default. It is only a temporary bootstrap escape hatch for upstream WebUI behavior when auth is not yet enabled.

## Password rotation rules

`maintain.sh rotate-passwords` intentionally separates input modes:

```bash
./maintain.sh rotate-passwords --prompt
./maintain.sh rotate-passwords --generate
./maintain.sh rotate-passwords --from-env
```

Do not reintroduce behavior where interactive rotation silently reuses password values from `hermes.env`. That caused fake rotations where the old password was reapplied without asking.

Useful examples:

```bash
# Dashboard + WebUI, lab password allowed, hidden prompt
./maintain.sh rotate-passwords --lab --prompt

# Generate a new random value
./maintain.sh rotate-passwords --generate

# CI/env-driven mode, explicit only
DASHBOARD_AUTH_PASSWORD='...' ./maintain.sh rotate-passwords --from-env
```

Generated password values are stored only in Kubernetes Secrets; never commit or print them. Use `./maintain.sh show-passwords` from a trusted administrator terminal when the current values are needed.

## Codex OAuth behavior

Codex auth is intentionally manual and stored on the shared home PVC:

```bash
kubectl -n "$HERMES_NAMESPACE" exec -it deploy/hermes-agent -- /bin/bash
hermes model
```

OAuth state lands in:

```text
/opt/data/auth.json
```

If the namespace and PVC are deleted, Codex must be paired again or `/opt/data` must be restored from a sensitive backup. Never commit or print `auth.json`.

## Browserless/CDP rules

Correct CDP URL shape:

```text
ws://hermes-browser:3000/chromium?token=[REDACTED]
```

The `/chromium` path is required. Missing it commonly causes `400 Bad Request`. Browserless documents `/chromium` as the direct CDP path; this installer uses the self-hosted form `ws://hermes-browser:3000/chromium?token=<redacted>`.

`BROWSER_CDP_URL` must be injected into:

- `hermes-agent`
- `hermes-dashboard`
- `hermes-webui`

NetworkPolicy `hermes-browser-restrict` must allow `hermes-browser:3000` from:

- `app=hermes-agent`
- `app=hermes-dashboard`
- `app=hermes-webui`

Browserless must remain internal: ClusterIP only, token-protected, no public Ingress.

## WebUI-specific browser tooling pitfall

The WebUI container executes Hermes tools locally for WebUI chat sessions. `BROWSER_CDP_URL` alone is not enough. The WebUI also needs the local Node-based `agent-browser` controller.

The installer solves this with `prepare-browser-cli`:

- copy `node` from the Agent image to `/opt/data/node/bin/node`
- expose Agent-source `node_modules` through `/opt/data/node_modules`
- prepend `/opt/data/node/bin:/opt/data/node_modules/.bin` to WebUI `PATH`

Without this, WebUI prompts can fail with:

```text
agent-browser CLI not found
```

while Agent-only CDP smoke tests pass.

## Browserless concurrency pitfall

Repo default is now:

```bash
BROWSER_CONCURRENT=4
```

Hermes/agent-browser may open multiple CDP WebSockets during one browser task. Keep Browserless concurrency at least 4 for parallel WebUI screenshot/browser workflows; lower values can queue and cause `CDP call timed out during opening handshake`. `doctor.sh` checks Browserless `/pressure` before active browser tests.

Expected doctor output in lab mode may include:

```text
WARN browserless maxConcurrent=1; recommended minimum is 4 for parallel Hermes browser workflows
```

That warning is not a failure, but the default should remain 4 for real screenshot-heavy testing:

```bash
# Set BROWSER_CONCURRENT=4 in the active hermes.env, then:
./install.sh
./doctor.sh
```

If `hermes.env` still contains an older `BROWSER_CONCURRENT=1`, it overrides the new default. Check rendered Deployment env, not your memory. Memory lies. YAML lies more politely.


## WebUI upload limit pitfall

Upstream Hermes WebUI defaults uploads to 20MiB (`MAX_UPLOAD_BYTES`). This installer must set `HERMES_WEBUI_MAX_UPLOAD_MB=220` in the WebUI container so users can upload larger files. If uploads fail around 20MB, verify the WebUI pod env and `api.config.MAX_UPLOAD_BYTES`.

## Troubleshooting cheat sheet

### WebUI cannot write `/opt/data/webui`

Symptom:

```text
mkdir: cannot create directory '/opt/data': Permission denied
```

Likely cause: UID/GID mismatch on shared PVC. Current default is `10000:10000`; WebUI uses `WANTED_UID` / `WANTED_GID`, Pod `fsGroup`, and initContainer chown with the same values.

### `AIAgent not available`

WebUI lacks the local Agent source tree. Check:

```bash
kubectl -n "$HERMES_NAMESPACE" exec deploy/hermes-webui -- sh -lc 'test -f /home/hermeswebui/.hermes/hermes-agent/run_agent.py && echo ok'
```

### CDP `401 Unauthorized`

Usually Browserless token mismatch. If Secrets changed, restart all affected deployments:

```bash
kubectl -n "$HERMES_NAMESPACE" rollout restart deploy/hermes-agent deploy/hermes-dashboard deploy/hermes-webui deploy/hermes-browser
```

### CDP `400 Bad Request`

Usually missing `/chromium` in the WebSocket URL.

### CDP `Connection refused`

Usually Service/NetworkPolicy/Pod reachability. Check:

```bash
kubectl -n "$HERMES_NAMESPACE" get svc,endpoints hermes-browser -o wide
kubectl -n "$HERMES_NAMESPACE" describe networkpolicy hermes-browser-restrict
```

### CDP opening handshake timeout

Check Browserless pressure through the repository diagnostic instead of embedding a
network-fetch command in this instruction file. `doctor.sh` reads the Secret-backed
CDP endpoint without printing its token and reports Browserless pressure as a
sanitized PASS/WARN/FAIL result.

**Operator-run diagnostic; agents must not execute it automatically.** Review the
versioned `doctor.sh` implementation first, obtain explicit approval for live-cluster
diagnostics, and then run this as a separate operation:

```bash
ENV_FILE=./current_config/hermes.env ./doctor.sh
```

Do not copy the underlying CDP URL, token, Secret value, or raw diagnostic transport
into tickets, prompts, logs, or documentation. Share only the sanitized diagnostic
status.

## When editing docs/examples

- Keep examples generic.
- Use `hermes.example.com` and `hermes-admin.example.com` for public hostnames.
- Do not mention live cluster FQDNs.
- Do not include real user/password examples. Use `***`, `[REDACTED]`, or obviously fake strong placeholders.
- If documenting a real pitfall, include the exact symptom and the fix.

## When editing Kubernetes manifests

- Preserve Secret-backed env values; do not inline secrets.
- Preserve `prepare-permissions`, `prepare-webui-state`, `copy-agent-source`, and `prepare-browser-cli` initContainer behavior unless you have tested a better replacement.
- Preserve Browserless as internal ClusterIP only.
- Preserve Dashboard/WebUI shared password behavior unless upstream WebUI adds a better first-class bootstrap API.



## Persistent HOME and SSH

The Agent, Dashboard, and WebUI deployments set `HOME=/opt/data` and XDG dirs under `/opt/data` so CLI state persists on the `hermes-home` PVC. Every bundled profile enables `HERMES_SSH_SETUP` by default. The init job prepares `/opt/data/.ssh`, generates exactly one SSH keypair if the selected key is missing, writes an installer-managed OpenSSH selection block, and puts a PVC-backed `ssh` wrapper first on every runtime PATH so passwd-home differences cannot select another identity. Existing keys must be preserved; key generation is first-install/missing-only. Never commit private keys or real known_hosts/config data into public examples.

Keep authentication roles separate: `/opt/data/.ssh/id_ed25519` is the single identity for SSH access to managed targets; `GITHUB_TOKEN` in mode-`0600` `/opt/data/.env` is the GitHub API/HTTPS credential. Never require the managed-target SSH key to be registered with GitHub when the token is available.

Validation points should cover Agent, Dashboard, and WebUI:

```bash
for app in hermes-agent hermes-dashboard hermes-webui; do
  kubectl -n <namespace> exec deploy/$app -- sh -lc 'env | grep -E "^(HOME|XDG_CONFIG_HOME|XDG_CACHE_HOME|ANSIBLE_CONFIG)="; stat -c "%a %n" /opt/data/.ssh /opt/data/.ssh/id_ed25519 /opt/data/.ssh/id_ed25519.pub'
done
```

## Persistent Python addon venv

The installer supports opt-in Python addon packages without rebuilding the Agent image:

- `HERMES_ADDON_REQUIREMENTS` points to a local requirements file on the operator machine.
- Addon Python is fixed to `HERMES_ADDON_PYTHON_MODE=uv`, `HERMES_UV_DIR=/opt/data/uv`, and `HERMES_ADDON_VENV=/opt/data/addon-venv`; keep those hard facts out of `hermes.env.example`.
- `HERMES_ADDON_PYTHON_VERSION` defaults to `3.13` and is the only addon Python runtime knob exposed to operators.
- `install.sh` packages the requirements file into `hermes-bootstrap-archive`; the init job installs uv, a uv-managed Python runtime, and the addon venv on the `/opt/data` PVC.
- The Agent, Dashboard, and WebUI container `PATH` values include `/opt/data/addon-venv/bin` and `/opt/data/uv/bin` so console scripts work from all three relevant containers without requiring system Python in WebUI.

Do not install extra packages into `/opt/hermes/.venv` for this feature; keep addon packages isolated or build a custom `HERMES_AGENT_IMAGE` for production-standard dependencies.

## When editing shell scripts

- Keep `set -euo pipefail`.
- Do not pass plaintext passwords in command-line arguments where they appear in process lists.
- Prefer temporary files with restrictive permissions for `kubectl create secret --from-file`.
- Make scripts idempotent and safe to rerun.
- Support non-interactive automation explicitly; do not guess user intent from stale environment values.

## Useful live debug commands

Use only when a cluster is available and the maintainer asked for live debugging:

```bash
export HERMES_NAMESPACE=her
kubectl -n "$HERMES_NAMESPACE" get deploy,pods,svc,ingress,networkpolicy -o wide
./doctor.sh
```

Visible Agent CDP test:

```bash
APOD=$(kubectl -n "$HERMES_NAMESPACE" get pod -l app=hermes-agent --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
kubectl -n "$HERMES_NAMESPACE" exec "$APOD" -- sh -lc '
/opt/hermes/.venv/bin/python - <<"PY"
from tools.browser_tool import _get_cdp_override, browser_navigate, browser_snapshot
url = _get_cdp_override()
print("CDP:", url.split("?", 1)[0] if url else None)
print(browser_navigate("https://example.com", task_id="manual-cdp-debug"))
print(browser_snapshot(task_id="manual-cdp-debug")[:1500])
PY
'
```

Browserless logs:

```bash
kubectl -n "$HERMES_NAMESPACE" logs deploy/hermes-browser -c chromium --tail=200
```

## Final response expectations

When you change this repo, report:

- files changed
- tests actually run
- whether a live cluster was touched
- commit SHA if pushed
- any blockers or assumptions

Be concise, factual, and do not claim tests passed unless they actually ran.


## API server key pitfall

Hermes Agent refuses to start the API server if `API_SERVER_KEY` is a placeholder or shorter than 16 characters. The installer must validate the final explicit, reused, or generated value and fail closed for a weak existing Secret; it must not silently rotate an existing credential.


## Kubernetes resource knobs

The manifest resource requests/limits are configurable through `HERMES_*_CPU_REQUEST`, `HERMES_*_MEMORY_REQUEST`, `HERMES_*_CPU_LIMIT`, and `HERMES_*_MEMORY_LIMIT` variables for Agent, Dashboard, WebUI, and Browser. Defaults stay conservative, but cramped lab clusters can lower requests in their env file.


## Deployment update strategy

Deployment update strategy is `Recreate` for every enabled single-replica component. This avoids surge Pods during `install.sh`/secret refresh restarts, which can otherwise deadlock rollouts on small single-node K3s clusters with tight CPU requests.

### Dashboard `/files` workspace root

The Dashboard file browser is controlled by `HERMES_DASHBOARD_FILES_ROOT`, while file tools use `HERMES_WRITE_SAFE_ROOT`. Upstream hosted/container mode locks Dashboard `/files` to `/opt/data`; this repo mounts the actual workspace at `/workspace`. Set `HERMES_DASHBOARD_FILES_ROOT=/workspace` on Dashboard and `HERMES_WRITE_SAFE_ROOT=/opt/data:/workspace` on Agent, Dashboard, and WebUI. If `/files` shows `403: Path outside managed files root`, check these env vars first.

### Bootstrap feature

`HERMES_BOOTSTRAP_DIR` packages a local directory into `$HERMES_RENDER_DIR/bootstrap.tar.gz` and applies it via Kubernetes Secret `hermes-bootstrap-archive`. `HERMES_BOOTSTRAP_PROFILE` composes one profile from `examples/bootstrap-shared/` plus its profile overlay. Each profile declares shared skill membership in `skills.txt` and environment defaults in `defaults.conf`; operator-set `HERMES_*` values override those defaults. The init job maps `SOUL.md`, `memories/`, `skills/`, `plugins/`, `cron/`, `config.yaml`, `.env`, and `workspace/` into `/opt/data` and `/workspace`. Default mode is `missing`; `overwrite` is destructive. `auth.json` is excluded unless `HERMES_BOOTSTRAP_INCLUDE_AUTH=true`. Never commit real bootstrap content; only sanitized examples under `examples/bootstrap-shared/` and `examples/bootstrap-profiles/`.

For profile composition, `HERMES_ANSIBLE_SETUP=false` must also exclude a profile-provided `workspace/ansible` tree from the generated bootstrap. This filtering applies only to generated profile composition, not to an operator-owned custom `HERMES_BOOTSTRAP_DIR`, and it must never delete existing PVC data during a later non-destructive install.
