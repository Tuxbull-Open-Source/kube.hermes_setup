# Changelog

All notable changes to this project are documented in this file.

## [v2.7.9] - 2026-10-31

### Fixed

- Makes `backup --data-only` create its archive with `tar --no-recursion`.
  The selected state paths include parent directories and descendants; allowing
  tar to recurse for each listed parent duplicated payload data and could
  exhaust backup storage on a large workspace.

### Verification

- Adds a regression fixture that feeds both a directory and its child to the
  archive command and asserts the child is stored exactly once.

## [v2.7.8] - 2026-10-31

### Fixed

- Resolves the npm payload for WebUI's managed Node runtime through `npm root -g`
  in `HERMES_AGENT_IMAGE` instead of assuming the legacy
  `/usr/local/lib/node_modules/npm` prefix. This supports Hermes Agent v0.22.5's
  bundled Node layout and prevents `prepare-browser-cli` from blocking WebUI
  startup.

### Verification

- Adds a launcher regression assertion for global npm-root discovery. Live QA
  covers the v0.22.5 Agent image and the complete WebUI startup path.

## [v2.7.7] - 2026-10-31

### Changed

- Replaces mutable container-image defaults with verified release tags:
  `nousresearch/hermes-agent:v0.22.5`,
  `ghcr.io/nesquena/hermes-webui:0.52.602`, and
  `ghcr.io/browserless/chromium:v2.58.1`.
- Keeps `HERMES_IMAGE_PULL_POLICY=IfNotPresent`; operators can still override
  an image reference deliberately for a reviewed upgrade.

### Verification

- Confirmed each selected tag resolves to an OCI/Docker registry manifest before
  release preparation. Live K3s acceptance remains required before merge.

## [v2.7.6] - 2026-10-31

### Fixed

- Uses `fsGroupChangePolicy: Always` for the PVC-consuming Hermes Agent,
  Dashboard, and WebUI Deployments. This ensures kubelet applies group
  ownership and permissions after a filesystem restore even when the PVC root
  already has the expected GID but retains restrictive mode bits that block a
  restore-injected init container.
- Restores mode `0600` for the exact configured `HERMES_SSH_KEY_PATH` in every
  PVC-consuming Deployment init container. This preserves OpenSSH-compatible
  private-key permissions for supported custom key basenames after kubelet's
  mount-time fsGroup permission pass.

### Verification

- Adds rendered-manifest assertions for the `Always` policy on the
  PVC-consuming Deployments and confirms that the stateless Browserless
  Deployment does not receive an fsGroup policy.
- Extends the SSH identity regression test with a custom key basename and a
  simulated group-readable mode before a repeated initialization.

### Documentation

- Documents Authelia's filesystem notifier as a test/diagnostic provider that
  writes plain-text notification bodies to the configured storage file rather
  than sending email.
- Documents the mutual exclusion of filesystem and SMTP notification providers
  and the need to reconcile complete Kubernetes environment and volume lists so
  stale SMTP wiring cannot survive a provider change and prevent startup.

## [v2.7.5] - 2026-09-04

### Added

- Adds the `ansible-role-template` bootstrap skill to the shared skill library.
  It documents how to create and maintain reusable OS-aware Ansible roles from
  `joe-speedboat/ansible.template`, including deterministic distribution/version
  dispatch, `rhelAll` grouping, numbered task basenames, first-match shadowing,
  strict shared-task neutrality, certificate handling, role-path test harnesses,
  live QA, and disposable lab cleanup.
- Enables `ansible-role-template` for both the `universal-system-administrator`
  and `universal-system-architect` bootstrap profiles.

### Verification

- Validates the new skill frontmatter, related-skill classifications, and
  non-empty body through the repository profile-composition contract.
- Validates that both profiles compose the new skill from the canonical shared
  skill tree without duplicate or profile-local copies.
- Passes the release-final-state contract for v2.7.5.

## [v2.7.4] - 2026-08-31

### Added

- Adds `HERMES_AUTH_SESSION_MAX_TTL_SECONDS`, defaulting to `43200`, as the shared 12-hour absolute session maximum. The installer maps it directly to WebUI's upstream `HERMES_WEBUI_SESSION_TTL`; the external Authelia contract uses the same value for SSO cookie expiration and the Dashboard/WebUI OIDC client ID-token lifespan.
- Adds `HERMES_AUTH_SESSION_IDLE_TTL_SECONDS`, defaulting to `7200`, for the externally managed Authelia two-hour sliding inactivity policy. Documentation explicitly distinguishes this from the absolute/token lifetimes used by Dashboard and WebUI.
- Adds `doctor.sh` drift detection for the rendered WebUI session TTL and persists both policy values through interactive configuration and answer replay.

### Security

- Disables Authelia remember-me in the documented chart configuration so it cannot override the 12-hour maximum.
- Fails closed on malformed, below-minimum, above-maximum, idle-greater-than-maximum, and oversized numeric timeout values before Bash arithmetic; this prevents integer-overflow values from bypassing the declared range.

### Verification

- Extends configurator, render-matrix, and authentication-diagnostic tests for defaults, persistence, rendered WebUI TTL, drift, invalid boundaries, and oversized integer regression coverage.
- Passes the complete repository shell/Python and local test suite, external-OIDC manifest rendering, secret/private-host scanning, and independent code review.
- Lints and renders the pinned Authelia chart `0.11.6`, structurally verifying two-hour inactivity, 12-hour expiration, disabled remember-me, and the named 12-hour OIDC client lifespan.
- Passes the mandatory clean-storage live K3s matrix on Ubuntu 24.04 with K3s `v1.31.12+k3s1`: Agent-only, Dashboard, WebUI, Browserless, and full-stack cases each reached Ready with zero restarts, no previous crash logs, and no fatal/traceback log matches. The WebUI and full-stack cases rendered `HERMES_WEBUI_SESSION_TTL=43200`.
- Passes unchanged full-stack reinstall with stable application and Browserless Secret hashes, stable PVC identities, a preserved workspace canary, all four rollouts Ready, Browserless pressure and CDP handshakes healthy from Agent/Dashboard/WebUI, and the WebUI timeout still `43200`. Real Chromium before and after reinstall rejected invalid WebUI/Dashboard credentials, accepted valid credentials, rendered authenticated interfaces with clean consoles, and measured 43,197 seconds remaining on the new WebUI cookie.

## [v2.7.3] - 2026-08-29

### Added

- Adds `maintain.sh backup --data-only`, which archives only Hermes-specific state — WebUI sessions, `config.yaml`, `SOUL.md`, `auth.json`, profiles, skills, memories, cron jobs, plugin data, kanban/state/projects/response-store databases, `/opt/data/home`, and `/workspace` — while excluding reproducible runtime software (`addon-venv`, Node/npm/npx, `uv`, LSP servers) and disposable caches/logs that a fresh `install.sh` rebuilds on its own. The archive also omits the Kubernetes resource snapshot and `/opt/data/.env`, making it namespace-agnostic.
- Adds `maintain.sh restore --data-only`, a non-destructive overlay counterpart: unlike normal and `--full` restore, it does not wipe `/opt/data`/`workspace` before extracting, so it can run safely against an already-installed target. It skips the Kubernetes API-key Secret-sync step entirely, since a data-only archive never carries `/opt/data/.env` or a Secret snapshot to sync from. `--data-only --dry-run` lists archive contents without requiring `kubectl` or touching the cluster. `--full` and `--data-only` are mutually exclusive.
- Documents the `backup --data-only` / `restore --data-only` migration workflow in `docs/operations.md`: take a data-only backup on the source, run a fresh `install.sh` on the destination (new namespace, new PVCs, or a newer release), then overlay the data-only archive — giving fresh runtime software with restored sessions/workspace/config/skills/memories, and doubling as a namespace/instance migration path independent of the Kubernetes resource snapshot used by `--full` restore.

### Verification

- Extends `tests/backup.sh` with a hermetic contract suite for `--data-only`: asserts `DATA_ONLY_PATHS` includes curated Hermes state and excludes reproducible runtime software and `/opt/data/.env`; asserts `--full`/`--data-only` mutual exclusion on restore; statically verifies the destructive full-namespace wipe is gated behind the non-data-only restore branch and that API-key Secret sync is skipped for data-only restores; exercises `restore --data-only --dry-run` end to end against a real (unencrypted, via the existing fake-`age` fixture) archive and confirms it lists archive contents without invoking `kubectl`.
- Confirmed via sabotage runs that the new destructive-wipe-guard and `DATA_ONLY_PATHS` exclusion assertions fail when the corresponding code is reverted, then pass again on the fix.
- Passes `bash -n` on all shell entrypoints and the full local test suite (`profile-composition`, `bootstrap-soul`, `agent-instructions-safety`, `configure`, `matrix`, `ssh-identity`, `credentials`, `reconcile-api-key`, `backup`). Render-validates `manifests/hermes.yaml.tpl` (unchanged by this PR) as well-formed YAML.
- Passes live K3s acceptance on `v1.36.3+k3s1` against a real running WebUI/Dashboard/Agent/Browserless stack: `backup --data-only` completed against live Pods via the helper-pod/`kubectl exec`/`cp` path, produced a checksum-verified encrypted archive, and left zero leftover helper Pods or restart-count drift. `restore --data-only` (non-dry-run) was exercised end to end with a deliberately deleted curated file (a skill's `SKILL.md`) and a canary file planted inside the excluded `/opt/data/node` runtime directory: the restore correctly recovered the deleted curated file while leaving the canary — and the entire Node runtime, including its `current` symlink and `runtimes/` generation directory — completely untouched, proving the overlay semantics (no destructive wipe) hold against a real PVC. `doctor.sh` reported all mandatory checks passing after the restore, confirming API-key/Browserless Secret convergence was undisturbed as designed.

## [v2.7.2] - 2026-08-29

### Documentation

- Adds `docs/persistent-software.md`, a dedicated architecture guide covering every persistent/managed software layer: Python addons under `/opt/data/addon-venv`, the always-on Node/npm/npx runtime under `/opt/data/node`, npm/npx cache, user-local executables, project dependencies, native OS packages, and skills/plugins — with location, ownership, consumers, and persistence/lifecycle for each. [PR #111]
- Adds a README "Persistent software and addons" section summarizing the layer model and linking to the new guide from the documentation table; cross-links `docs/operations.md` and `docs/pvc-and-containers.md` to the same guide for the addon-package, NPX/Node, and PVC/container sections.
- Documents the exact `install.sh` reinstall contract for Python addons: reruns install missing packages and change versions only as needed to satisfy current requirements-managed declarations; they do not proactively upgrade already-satisfying versions; `pip` itself is upgraded unconditionally on every addon-enabled run via `pip install --upgrade pip`, which is called out as an explicit exception to the no-proactive-upgrade guarantee. Documents the `HERMES_ANSIBLE_SETUP=false` pruning exception (Ansible packages are explicitly uninstalled) as the only supported pruning behavior.
- Documents the exact automatic-recreation trigger for a corrupt managed Python venv (checks only that `bin/python` is executable and the `.hermes-uv-managed` marker exists) instead of implying general corruption is self-healing; other corruption requires a controlled manual rebuild.
- Documents the `prepare-browser-cli` Node/npm source contract precisely: Node is read from `/usr/local/bin/node` and npm from `/usr/local/lib/node_modules/npm` in `HERMES_AGENT_IMAGE`, which is a hard compatibility contract for custom Agent images. Because the copy uses `cp -a`, any retained symlink inside the npm tree must be relative and resolve to a target inside the tree; absolute symlinks are unsupported even when their target is inside the tree (the absolute source pathname is preserved and is unavailable in the WebUI container), and links to any target outside the tree are unsupported in either form.
- Corrects the corrupt-managed-runtime and unchanged-reinstall rows in the upgrade/repair/rollback behavior table to match the above precise contracts. [PR #112, follow-up to PR #111]

### Verification

- Extends `tests/qa-contract.sh` with grep-based assertions that `docs/persistent-software.md` retains the exact implementation-boundary language above (pip-upgrade exception, corrupt-venv detection scope, Node/npm source paths, and relative-in-tree vs. absolute/out-of-tree npm symlink rules), so future edits cannot silently drift from installer behavior.
- Passes `bash -n` on all shell entrypoints, `python3 -m py_compile` on renderer scripts, and the full local test suite (`profile-composition`, `bootstrap-soul`, `agent-instructions-safety`, `configure`, `matrix`, `ssh-identity`, `credentials`, `reconcile-api-key`, `backup`, `qa-contract`, `release-final-state`). Separately renders `manifests/hermes.yaml.tpl` with `examples/hermes.env.example` and placeholder secrets via `scripts/render_template.py` and validates the output as well-formed multi-document YAML; `kubectl` is unavailable in this sandbox, so client-side dry-run was skipped. Documentation-only change with no executable installer behavior modified.

## [v2.7.1] - 2026-08-28

### Security

- Disables terminal input echo in the `age` pseudo-terminal used by `--password-file` backup, extract, and restore automation, preventing the supplied passphrase from being copied into captured stdout, logs, or automation transcripts.
- Requires the internal `age` invocation to write payload data through `--output` and never forwards the captured pseudo-terminal transcript. This removes echoed-input, terminal-formatting, cross-stream reconstruction, benign substring-collision, and stdout-corruption failure classes; nonzero child status is preserved with a generic credential-free diagnostic.

### Fixed

- Propagates the real `age` child exit status through util-linux `script --return` instead of allowing a failed encryption or decryption command to appear successful.

### Verification

- Extends `tests/backup.sh` with bare, prompt-prefixed, pre-colon, trailing-text, ANSI-wrapped, and arbitrary-inline passphrase disclosure through stdout or stderr; benign short-passphrase prompt/status collisions; missing-output refusal; child exit-status propagation; and normal non-disclosure cases. Successful operations remain successful while all captured transcript output stays private.
- Passes isolated live K3s acceptance on `v1.36.3+k3s1` for output-file-only behavior commit `86748f7`: real password-file encrypted backup, checksum validation, full extraction, and `restore --full --dry-run`; preserves resource, Secret, PVC, marker, Pod identity, and zero-restart state; reports zero passphrase disclosures; removes helper Pods, the disposable Namespace, and both local-path PVs; and leaves unrelated workloads unchanged.

## [v2.7.0] - 2026-08-28

### Added

- `configure.sh` now asks for the authentication mode (`local-password` or `external-oidc`) directly whenever Dashboard or WebUI is enabled, instead of always asking for a local username/password regardless of the intended `HERMES_AUTH_MODE`. Selecting `local-password` asks the existing username/password questions; selecting `external-oidc` asks for the issuer, Dashboard/WebUI OIDC client IDs, public/redirect URLs, and allow claim/values instead — the two question sets are mutually exclusive, matching the mutually exclusive manifest wiring. All wizard-collected values are written to `hermes.env` and the answers file and pass through `install.sh`'s existing `validate_external_oidc_urls`/`HERMES_AUTH_MODE` validation unchanged; no validation logic is duplicated in the wizard.
- Adds `maintain.sh reconcile-api-key --source secret` for finalizing manual/external PVC migrations: validates the existing Kubernetes Secret without printing it, atomically synchronizes only `API_SERVER_KEY` into persistent `/opt/data/.env`, rolls all enabled internal API consumers together, verifies real Bearer authentication, and removes its helper Pod on success or failure. [Issue #101]
- Adds `maintain.sh reconcile-browser-token --source secret` to converge the Kubernetes Browserless token/CDP Secrets, persistent root and profile `.env` files, and every enabled consumer without printing credentials. Verification accepts only Ready Pods carrying the exact Secret revisions and a fresh reconciliation request, then executes `Browser.getVersion` from each consumer.

### Changed

- Node.js, npm, and npx are now installed unconditionally in every profile and every installation, replacing the `HERMES_NPX_SETUP` toggle. The npm cache directory (`/opt/data/.npm`), `npm_config_yes=true` (Agent, WebUI, and the terminal profile hook), and the WebUI `prepare-browser-cli` npm/npx copy no longer depend on any conditional; they are part of the baseline runtime.
- Removes `HERMES_NPX_SETUP` and `HERMES_PROFILE_DEFAULT_NPX_SETUP` from `install.sh`, `configure.sh` (interactive prompt, answers file, validation), `scripts/render_template.py` (boolean validation), all three bootstrap profile `defaults.conf` files, and `examples/hermes.env.example`. Operators upgrading from an installation with `HERMES_NPX_SETUP=false` in `hermes.env` are unaffected: the variable is simply ignored by the new installer/renderer.
- Updates `docs/operations.md` and `docs/pvc-and-containers.md` to describe Node/npm/npx as always-on infrastructure rather than a toggle.
- Updates `tests/qa-contract.sh`, `tests/profile-composition.sh`, `tests/configure.sh`, `tests/interactive-profile-defaults.py`, `tests/profile-resolution-model.py`, `tests/ssh-identity.sh`, and `tests/bootstrap-soul.sh` to drop the NPX matrix dimension; `tests/qa-contract.sh` now asserts `HERMES_NPX_SETUP` is absent from the rendered manifest.
- Fixes `tests/ssh-identity.sh`'s SSH-init-block extraction, which located the end of the block via a `HERMES_NPX_SETUP`-conditional string that no longer exists; it now anchors on `installer_default_soul() {`, the next stable marker in the init job script.

### Fixed

- Forces each internal API-key reconciliation to create exactly one real consumer rollout by adding a fresh non-secret request annotation alongside the Secret revision, then verifies only Ready Pods carrying both values. This prevents an already-current revision annotation from turning reconciliation into a no-op rollout while the Agent keeps an older in-memory key. [Issue #101]
- Reads an existing `/opt/data/.env` through an atomic same-directory hard-link snapshot, rejects symlinked/non-regular targets, and disables service-account-token automounting for storage helper Pods so restore/reconciliation cannot follow a raced credential-file substitution into container credentials.
- Carries forward the WebUI `prepare-browser-cli` fixes from the in-review `fix/persist-node-npm-npx-runtime` branch: resolves the actual `libatomic.so.1` linked by `/usr/local/bin/node` via `ldd` (previously the first `libatomic.so.1*` basename match under `/lib`/`/usr/lib`, which could select an incompatible ELF on images with multiple implementations), and sets `npm_config_yes=true` on the WebUI deployment so WebUI-launched `npx` invocations are non-interactive.
- Preserves a custom `HERMES_WEBUI_IMAGE` loader environment instead of replacing its `LD_LIBRARY_PATH` with the copied Node runtime directory. `prepare-browser-cli` builds and validates a content-addressed Node/npm/npx runtime under `/opt/data/node/runtimes/<hash>`, then atomically switches `/opt/data/node/current`; stable launchers prepend only the selected runtime's private library directory, preserve inherited paths without duplication, and leave the active runtime unchanged when a candidate dependency or npm payload fails validation. `libatomic.so.1` remains optional unless the source ELF resolves or requires it. [Issue #98]
- Gates Agent and Dashboard readiness/liveness with a 180-second startup-probe budget, allowing readiness to restore traffic immediately after startup succeeds without exposing traffic early or racing slow full-stack restarts.
- Prevents migrated profile `.env` files from overriding the current Kubernetes `BROWSER_CDP_URL` with an older Browserless token. Installer reruns now update existing profile-level Browserless overrides, `rotate-browser-token` uses the same convergence path, and `doctor.sh` reports root/profile persistence drift instead of checking only the Pod base environment. Explicit, reused, and reconciled Browserless tokens now fail closed unless they use the shell- and URL-query-safe persistence alphabet `[A-Za-z0-9._:/=@-]`; profile roots, profile directories, and `.env` targets must also be non-symlinked.
- Makes bare `rotate-browser-token` generate a fresh token unconditionally instead of silently reusing `BROWSER_TOKEN` loaded from `hermes.env`; deliberate automation values now require process-scoped `BROWSER_TOKEN` plus `--from-env`.
- Restores the previous matching Browserless Secret pair if either Secret update fails during rotation, and makes `doctor.sh` fail when the token and CDP Secrets are missing, malformed, or disagree.

### Documentation

- Updates PVC architecture and troubleshooting guidance for the Node payload/launcher split and custom WebUI image loader-path preservation.

### Verification

- Passes focused Node-launcher tests for unset, inherited, and already-present loader paths; argument and exit-code propagation; npm/npx traversal; optional `libatomic.so.1` handling; trusted execute-bit repair; malformed active-pointer recovery; unexpected-library and same-key content-corruption rebuild; repair idempotency; failed dependency and malformed npm refresh preservation; and validated v1-to-v3 atomic activation with current/previous retention.
- Passes the component/profile matrix, QA contract, full repository shell/Python validation, credential-preservation tests, and encrypted backup tests.
- Passes fresh-PVC transactional QA at code commit `f026107`: malformed-pointer recovery, unexpected-library and payload-corruption rebuild, immediate repair idempotency, forced dependency failure preservation, inherited loader behavior, zero restarts/unexpected warnings, and cleanup.
- Passes the clean live K3s Agent-only, Dashboard, WebUI, Browserless, and full-stack matrix at `f026107`; startup probes reported only expected not-ready events and readiness/liveness produced zero warnings.
- Passes trusted external HTTPS Chromium before and after unchanged reinstall: invalid password rejected, configured password accepted, authenticated screenshots captured, and authenticated consoles clean.
- Passes unchanged reinstall with Secret hash stability, PVC identity preservation, marker integrity, successful rollouts, and complete route/namespace/PV cleanup.
- **Validation limitation:** the live test injects the inherited loader value through the test Pod. Static rendering proves the WebUI Deployment no longer overrides it, but a separately built custom WebUI image with Dockerfile-defined `ENV LD_LIBRARY_PATH` was not available.
- Adds `tests/browser-cdp-convergence.sh` covering Secret-pair mismatch refusal, partial-rotation rollback, doctor pair diagnostics, unsafe-token rejection, numeric identity preflight, symlink-boundary protection, atomic root/profile synchronization, consumer rollout annotations, redaction, profile drift diagnostics, and fresh token rotation.

## [v2.6.0] - 2026-08-25

### Added

- Adds `HERMES_AUTH_MODE` with backward-compatible `local-password` and native `external-oidc` application wiring. `disabled` and `external-proxy` remain documentation-only and fail closed when selected. [Issue #95]
- Adds separate Dashboard and WebUI OIDC issuer, client, scope, public/callback URL, and WebUI allow-claim settings. External OIDC rendering removes the shared local password environment references and Dashboard password-login rewrite resources. [Issue #95]
- Adds architecture/maintenance and step-by-step Authelia + FreeIPA documentation, including exact OIDC clients/callbacks, Secret handling, claims policies, migration from an existing local-password installation, rollback, upgrade, backup boundaries, and QA cleanup. [Issue #95]
- Adds `doctor.sh` authentication-mode reporting and external-OIDC drift/conflict checks for live workload environments, local password Secrets, and password-login routing resources.

### Changed

- Makes local Dashboard/WebUI credential generation and `hermes-dashboard-auth` Secret creation conditional on `local-password`, while preserving API-server and Browserless credential behavior in every mode.
- Extends manifest rendering with mutually exclusive local-password and external-OIDC authentication blocks.
- Documents FreeIPA OTP-over-LDAP as an explicit compatibility gate: existing OTP reuse must prove the required FreeIPA bind control/credential path and replay rejection rather than assuming password-plus-OTP concatenation.

### Security

- Prevents `external-oidc` from retaining a weaker local Hermes password path or password-login Ingress.
- Rejects incomplete OIDC settings, non-HTTPS/mismatched callback and public URLs, and unsupported `disabled`/`external-proxy` modes before apply.
- Retains the previous local-password Secret until external-OIDC workloads are Ready, then removes it; failed cutovers leave the previous ReplicaSets restartable.

### Verification

- Passes Bash syntax, Python compilation, component matrix, credential preservation, interactive configuration, authentication-mode doctor, and QA contract tests.
- Passes one isolated full-stack live K3s external-OIDC installation and unchanged reinstall with Agent, Dashboard, and WebUI Ready; verifies OIDC-only workload environment names, absence of `hermes-dashboard-auth`, and absence of the Dashboard password-login Ingress.
- Passes a separate fresh Authelia chart deployment with FreeIPA CA verification, service/user LDAPS binds, Authelia readiness, HTTP health, and OIDC discovery; temporary Namespaces were backed up and removed after validation.
- **Blocked release gate:** the mandatory clean Agent-only, Dashboard, WebUI, Browserless, and full-stack live matrix from `AGENTS.md` has not yet been completed for this branch. Do not release v2.6.0 until that matrix and required Chromium/runtime acceptance checks pass and are recorded.

## [v2.5.0] - 2026-08-24

### Removed

- Removes the deprecated `setup.sh` compatibility wrapper; existing users and automation must invoke `configure.sh` directly. [PR #92]

## [v2.4.0] - 2026-08-23

### Added

- Adds `graylog-api-search` to the canonical shared bootstrap skill catalog: a REST-API-based Graylog log search/aggregation/triage skill that works without a native Graylog MCP connector. Implements `search`, `aggregate`, `fields`, and `trend` (mirroring Graylog 7.1's `search_messages`/`aggregate_messages`/`list_fields` MCP tools), plus `events` (triggered Alerts/Events lookup) and `patterns` (client-side log-pattern clustering) and a `search --count-only` cheap existence check, cherry-picked from comparable Elastic, Grafana/Loki, AWS CloudWatch Logs, and Datadog MCP servers. [PR #90]
- Enables `graylog-api-search` by default for the `universal-system-administrator` profile. [PR #90]
- Adds `tests/api-key-convergence.sh` to verify `hermes-api-server` Secret rotations converge to the same opaque `resourceVersion` across Agent, Dashboard, and WebUI Deployments, and that each runtime can authenticate to `/health/detailed` with the new key. [PR #81, #84]
- Adds `tests/interactive-profile-defaults.py`, a dynamically-discovered real-PTY regression matrix covering Ansible, SSH, and NPX defaults across every bootstrap profile, blank input, explicit true/false answers, saved-answer reuse, and `--from-answers` replay (67 cases across 3 profiles at introduction). Replaces the narrower, now-removed `tests/interactive-ansible-defaults.py` and `tests/interactive-npx-defaults.py`. [PR #82, #85, #86, #87, #88]
- Adds `tests/profile-resolution-model.py`, an architecture contract test that fails if a profile-controlled setting (Ansible/SSH/NPX/addon requirements) is wired through feature-specific plumbing instead of the shared typed resolution model. [PR #87]
- Adds effective-preset display to the interactive wizard: immediately after profile selection, shows the resolved Ansible, SSH, and NPX presets and their origin (selected profile, global fallback, current environment, reused/replayed answer, explicit answer, or Ansible-implies-SSH dependency). The final summary reports the same provenance; secret values are never included. [PR #88]
- Adds `tests/agent-instructions-safety.sh`, a regression that fails if root `AGENTS.md` reintroduces a `wget`/`http://` remote-fetch snippet or any curl/wget piped-to-shell / download-then-execute pattern, and asserts the file's operator-only safety markers are present. [PR #89]

### Changed

- Converges API-key rollout: `install.sh` preflight-renders before writing to Kubernetes, applies `hermes-api-server`, reads its opaque `resourceVersion`, and renders that same non-secret revision annotation into the Agent, Dashboard, and WebUI Deployment templates so an interrupted refresh can no longer leave runtimes authenticating with different keys. `doctor.sh` gained revision-drift diagnostics that never print credential values. [PR #81]
- Restricts explicit/restored `API_SERVER_KEY` values to `[A-Za-z0-9._:/+=@%-]` (rejected rather than normalized) because the resolved key is persisted as an unquoted dotenv/shell assignment on the shared PVC; Dashboard passwords, Browserless tokens, and usernames are unaffected by this API-key-specific restriction. [PR #84]
- Centralizes every profile-controlled wizard setting (Ansible, SSH, NPX, addon requirements) behind one typed declarative resolution model with a single precedence order — interactive choice, reused/replayed saved answer, explicit process/environment value, the selected profile's `defaults.conf`, then the global fallback — replacing duplicated feature-specific prompt/persistence/summary logic and a late `apply_profile_defaults` mutation pass. [PR #87]
- Updates `hermes-workspace-ansible` to `2.0.2`: before deleting, replacing, or archiving Ansible inventory during workspace cleanup, preserves verified non-secret connection metadata (hostname/alias, non-default `ansible_host`, SSH port, verified account, privilege model, confirmed interpreter) for hosts confirmed to persist, while explicitly excluding disposable/temporary/decommissioned targets and never copying credentials, keys, or raw SSH config into inventory. Requires `ansible-inventory --graph` (without `--vars`) validation after consolidation. [PR #80]
- Updates root `AGENTS.md`'s Browserless-pressure diagnostic to reference the existing sanitized `doctor.sh` check instead of an inline `wget`/`http://` snippet that common agent/security scanners flag as a remote-fetch pattern, and marks it explicitly as operator-run rather than for automatic agent execution. [PR #89]

### Fixed

- Fixes the configuration wizard always falling back to a disabled Ansible default on blank input, ignoring the selected bootstrap profile; blank input now resolves through the profile's `defaults.conf`, with Ansible-implies-SSH preserved and saved/explicit answers still taking precedence. [PR #82]
- Fixes the same hard-coded-disabled fallback for the NPX default on blank input. [PR #85]
- Fixes authenticated health checks failing on a clean PVC despite matching Secret/Pod revisions: the init Job now receives `hermes-api-server/api-key` via `secretKeyRef` and atomically upserts `API_SERVER_KEY` (and `BROWSER_CDP_URL`) into the persistent `/opt/data/.env` — preserving unrelated entries, collapsing duplicate managed entries, `umask 077`, mode `0600`, and a same-directory atomic rename. [PR #84]

### Documentation

- Documents the API-key persistence alphabet restriction in `docs/security.md`. [PR #84]
- Updates the README profile-settings paragraph to describe the typed precedence model, Ansible-implies-SSH, and (after PR #88) the effective-preset provenance display shown by the wizard. [PR #87, #88]

## [v2.3.1] - 2026-08-19

### Fixed

- Classifies every non-empty bootstrap `related_skills` reference as `bundled`, `external-runtime`, or `optional-reference` while preserving the loader-compatible string lists.
- Validates the complete shared and profile-local bootstrap skill tree: valid YAML frontmatter, non-empty body, matching name/directory, non-empty unique related-skill names, exact classification parity, allowed classification values, and resolution of every bundled reference.

## [v2.3.0] - 2026-08-19

### Added

- Adds `hetzner-ansible-lab` to the canonical shared bootstrap skill catalog with exact upstream provenance, sanitized reporting requirements, labelled temporary-resource cleanup, and mandatory provider-console SSH host-key verification through a run-specific `known_hosts` file.
- Enables `hetzner-ansible-lab` by default for the `universal-system-architect` and `universal-system-administrator` profiles.
- Adds Markdown/PDF runtime packages and `pyvim` to the administrator profile's persistent addon environment.

### Changed

- Moves `ansible-fleet-change`, `linux-change-safety`, and `linux-triage` from profile-local storage into the canonical shared skill catalog while keeping them selected only by `universal-system-administrator`.
- Describes `universal-system-architect` as a curated shared-skill profile instead of claiming that it installs every shared skill.
- Raises the WebUI memory limit default from `1Gi` to `2Gi` in both the public example and the installer fallback.

### Fixed

- Makes WebUI diagnostics require `BROWSER_CDP_URL` only when Browserless is enabled and run WebUI Ansible login-shell checks only when Ansible setup is enabled.
- Adds regression coverage for shared-skill locations and allowlists, imported-skill frontmatter, administrator addon requirements, the WebUI memory fallback/rendered limit, and optional WebUI diagnostic gates.

### Verification

- Passes the complete local test suite and 24 profile/Ansible/requirements matrix combinations.
- Passes isolated live K3s acceptance for Agent-only, Dashboard, WebUI, Browserless, full Architect, full Administrator, invalid-profile failure, and unchanged reinstall cases.
- Verifies real Chromium authentication with trusted TLS and a clean console, Browserless token/CDP/WebSocket behavior, persistent PVC and Secret identity, installed profile skill sets, and complete namespace/PV cleanup.

## [v2.2.3] - 2026-08-15

### Fixed

- Enables persistent SSH setup by default for every bundled profile so fresh installations create one ED25519 identity under `$HOME/.ssh/` without profile-specific surprises.
- Makes ordinary `ssh` select `/opt/data/.ssh/id_ed25519` with `IdentitiesOnly yes` through a PVC-backed wrapper on every runtime PATH, independent of container passwd-home differences, while preserving operator-managed SSH config content.
- Preserves the existing private-key fingerprint across installer reruns and adds doctor checks for effective identity selection, safe permissions, and matching private/public fingerprints.
- Adds a hermetic SSH identity regression test covering first run, unchanged rerun, one-key count, no Kubernetes `subPath` dependency, and effective ordinary `ssh -G` output.
- Keeps the Browserless CDP credential out of the rendered PodSpec; the init Job now expands the `secretKeyRef`-backed environment variable only inside the running container.
- Documents the complete PVC/container architecture, persistent directories, init-container mounts, service wiring, and repository-injected environment variables.
- Makes the interactive wizard honor the selected profile's SSH default, while retaining explicit yes/no overrides.
- Preserves system-wide OpenSSH configuration and inherited helper paths for `ProxyCommand`, `LocalCommand`, and `KnownHostsCommand` without allowing the managed wrapper to recurse.
- Makes a selected bootstrap profile's SOUL effective in `missing` mode when the PVC contains only a recognized generic Hermes/installer identity, while preserving customized, symlinked, and multiply linked `SOUL.md` files and disabled-bootstrap behavior; bootstrap archives are now byte-reproducible so unchanged reruns do not churn the Kubernetes Secret.
- Sets `CODEX_HOME=/opt/data` in every Hermes workload so the Codex CLI uses the persisted OAuth state instead of reporting `Not logged in` after reinstall or Pod replacement.

## [v2.2.2] - 2026-08-12

### Fixed

- Clarifies that the universal system administrator's production Linux controls apply to separately managed targets, not routine self-maintenance inside the installer-provided Hermes Agent, Dashboard, or WebUI containers.
- Prevents GitHub access setup from inventing `/srv/backup`, `/CHANGES.md`, root, `systemd`, or target-host change-management prerequisites when the active `/opt/data` profile PVC is directly writable.
- Documents live runtime-path detection for hardened containers that omit `/.dockerenv` and Kubernetes ServiceAccount mounts, while preserving explicit authorization for cluster, credential, access, availability, and PVC lifecycle changes.
- Adds profile-composition regression checks for the runtime-versus-target scope boundary.

## [v2.2.1] - 2026-08-11

### Fixed

- **configure.sh wizard now dynamically discovers bootstrap profiles.** The profile selection menu was hardcoded to only two entries (personal-assistant, universal-system-architect) — the universal-system-administrator profile was never offered. Replaced with a filesystem scanner that lists all directories under `examples/bootstrap-profiles/`. Selection by number or by exact profile name. [PR #65]
- **Missing HERMES_PROFILE_DEFAULT_ADDON_REQUIREMENTS in universal-system-administrator defaults.conf** — caused `unbound variable` in profile-composition tests. [PR #65]
- Updated all tests (`tests/configure.sh`, `tests/profile-composition.sh`, `tests/matrix.sh`) to cover the new dynamic profile discovery and the universal-system-administrator profile.

## [v2.2.0] - 2026-08-11

### Highlights

One minor bump consolidating:
- The **universal-system-administrator** bootstrap profile (PR #60)
- Two coaching skills for the **personal-assistant** profile (PRs #61, #62)
- The interactive `configure.sh` wizard, encrypted full-rollback snapshots, and significant security hardening (accumulated on `main` since v2.1.2)

### Added

**New bootstrap profile**
- Adds `universal-system-administrator` profile — a Linux sysadmin identity (RHCE skill level) for RHEL-family and Debian-family systems. Read-only investigation by default, per-change authorization, `/srv/backup` backup discipline, and `/CHANGES.md` audit trail. Ships three profile-specific skills:
  - `linux-triage` — what-changed reconstruction on existing systems (dual-family package history, log timeline, SELinux/AppArmor, journald)
  - `linux-change-safety` — backup, restore, `/CHANGES.md` entry, SELinux restorecon, rollback
  - `ansible-fleet-change` — canary-first multi-host changes with playbook-generated audit entries

**New coaching skills for personal-assistant profile**
- Adds `systemische-psychologie` skill — professionally researched, neutral systemic/hypnosystemic coaching framework based on Gunther Schmidt. Ships three references: question catalogue, role/safety matrix, and verified sources (DBVC, DGSF, ICF, BDP).
- Adds `coaching-recurring-patterns` skill — values discovery, recurring pattern resolution, resource activation, and daily practice structure with light mode and standard mode. Adaptation vs. change distinction included.
- Adds `POST_SETUP.md` recipe for daily cron-based coaching practice with copy/paste-ready `hermes cron create` examples.

**Infrastructure**
- Adds encrypted full-rollback snapshots: repository-owned Kubernetes resources, application Secrets, normalized metadata, and the exact K3s server version stored inside the age archive. `restore --full` recreates an absent Namespace and enforces K3s/version/Namespace gates; `--force` overrides gates while retaining data-integrity and API failures.
- Adds `restore --full --dry-run` preflight output without Kubernetes or PVC changes.
- Adds configurable `HERMES_IMAGE_PULL_POLICY` with `IfNotPresent` default and explicit `Always` option.
- Adds independently selectable Dashboard, WebUI, and Browser components while keeping Agent mandatory.
- Adds versioned Ansible package installation through `HERMES_ANSIBLE_VERSION`.
- Adds isolated backup-helper regression tests.
- Adds `maintain.sh show-passwords` — retrieves and decodes Kubernetes credential Secrets for an authorized administrator without writing them to local files.

**Configuration wizard**
- Adds an interactive `configure.sh` wizard that stores the complete selected bootstrap and `hermes.env` under Git-ignored `current_config/`, then directs installer artifacts to `current_config/artifacts` during handoff.
- Adds declarative profile skill allowlists and profile environment defaults with operator overrides.
- Generates native Hermes `config.yaml` from the wizard and injects it through bootstrap into persistent `/opt/data/config.yaml`.
- Displays bootstrap profile choices on separate lines for terminal readability.
- Preserves the configuration wizard interactivity when reusing `configuration_answers`: `y` pre-seeds saved non-secret answers, `n` uses built-in defaults, and blank passwords are never stored or offered as defaults.

### Changed

**Profiles and workspace**
- Integrates the generic workspace manager with the existing Git and Ansible workspace skills by defining specialized placement precedence and preventing duplicate topic folders.
- Replaces duplicate root/non-root SSH key installation recipes in the Ansible workspace skill with one idempotent account-aware example.
- Makes `personal-assistant` select `markdown-pdf` and `hermes-workspace-manager` without duplicating canonical skill sources, disable SSH setup by default, and activate its own addon requirements.
- Makes `universal-system-architect` select all shared skills, enable SSH setup, and activate its Ansible-oriented addon requirements by default.
- Makes `HERMES_ANSIBLE_SETUP=false` exclude a profile-provided Ansible workspace from bootstrap content on fresh deployments.
- Adds `universal-system-administrator` row and updates `personal-assistant` with the two new coaching skills in the README profile table.
- Updates the bootstrap workspace instructions, SOUL profile, and README to describe the combined workspace lifecycle.

**Documentation**
- Condenses and reorganizes README around a documented `universal-system-architect` lifecycle: configure, customize `current_config`, install, debug, reconfigure, backup, delete/rebuild, and restore.
- Adds section headers and inline comments to `examples/hermes.env.example` for production readability.
- Uses `configure.sh` as the canonical documented entrypoint while retaining `setup.sh` as a compatibility wrapper.
- Corrects credential, render, and bootstrap artifact paths for both wizard and manual installations.
- Corrects optional-component authentication and deployment claims, conditional SSH preparation, and duplicated operational guidance.

**Installer**
- Makes `install.sh`, `doctor.sh`, and `maintain.sh` automatically discover wizard-generated `current_config/hermes.env` when no root `hermes.env` or explicit `ENV_FILE` is present.
- Removes the temporary composed-profile stage after copying it into the canonical generated bootstrap directory.
- Clears installer library mode before the wizard hands off to `install.sh`, so answering yes starts the deployment.
- Clears internal profile-requirements state before each installer default-resolution pass so sourced or inherited state cannot alter custom requirements.
- Preserves explicit `--from-env` password and browser-token rotation inputs when the active env file contains blank wizard placeholders.
- Changes the default model provider from `codex` to `openai-codex` across the wizard, installer defaults, example configuration, config tests, and maintainer documentation.

**Backup and restore**
- Makes restore remove hidden as well as visible PVC entries and reapplies the configured runtime UID/GID instead of hardcoded `1000:1000` ownership.
- Protects backup archives and generated SHA-256 checksum files with mode `0600`.
- Adds backup/restore cleanup traps and restores each enabled deployment to its original replica count after success or failure.

### Fixed

**Security hardening**
- Adds image-specific Kubernetes security contexts: RuntimeDefault seccomp and disabled ServiceAccount-token automounting for all workloads; no privilege escalation for application containers; numeric non-root Browserless with all capabilities dropped.
- Adds a live-tested security exception for current Agent/Dashboard/WebUI root-start initialization and privileged init-container volume preparation.
- Moves Browserless token rotation from `kubectl --from-literal` process arguments to mode-restricted temporary files passed with `--from-file`, with cleanup traps.
- Adds cleanup traps for all installer and maintenance temporary Secret staging directories, including failed Kubernetes Secret-apply paths.
- Replaces executable `ENV_FILE` sourcing in installer, maintenance, and diagnostics with a non-executing parser for quoted `KEY=value` assignments; unsafe shell environment controls are rejected.
- Ensures the wizard and installer never store or print plaintext credentials; authorized retrieval uses `./maintain.sh show-passwords`.
- Uses native cryptographic password generation via `openssl rand -base64` for Dashboard/WebUI passwords; API keys and Browserless tokens remain hex secrets, no MD5-based generation.
- Updates QA credential acceptance to require Secret-only storage and explicitly reject obsolete local credential-capture-file expectations.
- Validates values crossing YAML and embedded-shell boundaries — Kubernetes names, hosts, image references, resource sizes, numeric settings, paths, and control-character rejection.

**Configuration**
- Preserves existing Dashboard/WebUI, API server, and Browserless credentials during ordinary reinstalls when configuration values are blank; explicit maintenance commands remain the rotation path.
- Preserves an explicit `HERMES_ANSIBLE_CONFIG` override and makes diagnostics validate the configured path rather than requiring the default path.
- Ensures the wizard offers configurable Agent, WebUI, and Browserless image references while retaining `latest` as the default.
- Sets `HERMES_NIX_BUILD=1` for the current WebUI image so its Agent-source dependency installation remains compatible with recent Hermes Agent images that reject normal wheel/sdist builds.

**Documentation**
- Corrects the production walkthrough's bootstrap refresh, answer replay, credential retention, backup validation, namespace deletion, rebuild, and restore semantics.

## [v2.1.2] - 2026-08-05

### Added

- NPX setup is now asked interactively in the `configure.sh` wizard. When
  replaying saved answers (`--from-answers`), the profile default is used.
- Python addon version is now asked in the wizard with version format validation.
  Accepts values like `3.13` or `3.13.5`.
- Both `HERMES_NPX_SETUP` and `HERMES_ADDON_PYTHON_VERSION` are written to
  `hermes.env` and saved to `configuration_answers` for durable replay.

### Changed

- README: adds full reference tables for `scripts/`, `tests/`, and `docs/`
  directories, documenting the purpose of every file in each directory.
- README: documents the three-step profile default resolution chain (explicit
  answer → profile default → hardcoded fallback) with a reference table
  covering SSH, Ansible, NPX, and Python version. [PR #58]

### Fixed

- Minor documentation syntax fixes.

## [v2.1.1] - 2026-08-05

### Fixed

- Fixes `configure.sh` crashing with `HERMES_NPX_SETUP: unbound variable` when running the interactive wizard. The wizard did not resolve profile-owned variables — adds `apply_profile_defaults()` call after wizard questions so `HERMES_NPX_SETUP` (and any future profile-default variables) are populated from the selected profile's `defaults.conf` before writing the env file and composing bootstrap. [PR #56]

## [v2.1.0] - 2026-08-05

### Added

- Adds `HERMES_NPX_SETUP` toggle for npx/npm cache support. When enabled, the init job pre-creates the npm cache directory at `/opt/data/.npm` with correct `hermes:hermes` ownership, and `npm_config_yes=true` is injected into the agent container environment and the terminal profile hook. This prevents `npx`-based MCP servers and skill installers from blocking on interactive prompts or failing with `EACCES` when the agent runs subprocesses as the unprivileged runtime user.
- Adds `HERMES_PROFILE_DEFAULT_NPX_SETUP` to profile defaults: `true` for `universal-system-architect`, `false` for `personal-assistant`.
- Adds `HERMES_NPX_SETUP` validation in `install.sh`, `render_template.py`, and `configure.sh`.

### Changed

- Updates the init job script in `hermes.yaml.tpl` to seed the npm cache directory before the bootstrap chown step.
- Adds `npm_config_yes=true` to the agent deployment env vars in `hermes.yaml.tpl`.
- Adds `export npm_config_yes=true` to the terminal environment hook so login shells inherit the setting.
- Updates `examples/hermes.env.example` with the new `HERMES_NPX_SETUP` section.
- Updates the profile table in README to include the NPX column.

## [v2.0.1] - 2026-07-20

### Fixed

- Makes the Markdown PDF skill honor `--no-cover` when using the default `fpdf2` backend and corrects its no-cover usage example.
- Neutralizes the reusable team-policy post-setup recipe by replacing repository-specific organization values with explicit `ASK_USER_AND_CHANGE` markers.
- Requires Hermes to resolve every organization marker with the requesting user before installing the adapted policy.

### Changed

- Raises every bundled bootstrap skill version to `2.0.1` for the v2.0.1 release.

## [v2.0.0] - 2026-07-20

### Added

- Adds `VERSION` as the release-version source of truth.
- Adds bootstrap skills for general Git workspace lifecycle, Ansible-native workspace lifecycle, and least-privilege public GitHub pull-request access.
- Adds concise post-setup recipes for activating bootstrap skills and adapting a mandatory Hermes team policy.
- Adds contributor and inspiration acknowledgements, including Nicolas Eberle's structured operational use cases and reusable Hermes policy-skill work.

### Changed

- Renames the Ansible workspace skill to `hermes-workspace-ansible` for consistent workspace-skill naming.
- Raises every bundled bootstrap skill version to `2.0.0` for the v2 release line.
- Sets Browserless concurrency to four with a 30-second session timeout and persists/verifies CDP configuration across Hermes components.

## [v1.2.2] - 2026-07-13

### Added

- Extends persistent HOME/XDG, SSH, addon Python, and Ansible runtime parity to the Dashboard container, matching Agent and WebUI behavior.
- Extends `doctor.sh` to validate HOME/XDG, `ANSIBLE_CONFIG`, SSH key permissions, addon Python, and `ansible localhost -m ping` across Agent, Dashboard, and WebUI.

### Changed

- Simplifies authentication by removing the optional Traefik middleware BasicAuth layer; Dashboard and WebUI application auth remain configured by default.
- Changes the default model to `gpt-5.6-luna`.
- Makes persistent `HOME=/opt/data` and XDG directories the fixed default for Agent, Dashboard, and WebUI instead of a configurable `HERMES_HOME_AS_HOME` toggle.
- Simplifies `maintain.sh rotate-passwords` to rotate the shared Dashboard/WebUI password only.
- Keeps operator-managed `config.yaml` intact while replacing only the untouched Agent image default config during init.
- Sets the Browserless default concurrency to `BROWSER_CONCURRENT=4` and session timeout to `BROWSER_TIMEOUT_MS=30000`.
- Documents and persists the Browserless CDP URL in the shared `/opt/data/.env` while retaining Secret-backed `BROWSER_CDP_URL` injection in Agent, Dashboard, and WebUI.

## [v1.2.1] - 2026-07-11

### Added

- Sets persistent HOME/XDG and UTF-8 locale for Python addon CLIs in WebUI so uv-managed Ansible can run there.
- Adds a uv-managed persistent addon Python runtime under `/opt/data/uv` so addon CLIs like Ansible work from both Agent and WebUI containers.
- Ensures `/workspace/ansible` is created by default, sets `ANSIBLE_CONFIG`, and documents container mount locations plus visible roles/collections install paths.
- Adds persistent Ansible control-node examples and documentation using the addon venv, workspace bootstrap, and persistent SSH setup.
- Adds persistent Agent HOME/XDG and SSH keypair setup with safe `/opt/data/.ssh` permissions and missing-only key generation.
- Adds opt-in persistent Python addon venv support via `HERMES_ADDON_REQUIREMENTS` and `HERMES_ADDON_VENV`, including manual install documentation.
- Replaces the placeholder bootstrap skill with a reusable `markdown-pdf` skill, including a pip-only renderer, editorial CSS theme, and container-focused verification notes.
- Adds example addon requirements for the bundled `markdown-pdf` workflow and `pyvim`.

### Changed

- Removes duplicate Markdown PDF dependency entries from the example bootstrap requirements file.

## [v1.2.0] - 2026-07-11

### Changed

- Tunes installer and example resource defaults for small K3s/lab deployments: 100m CPU requests, 1 CPU limits, 256Mi Agent/WebUI memory requests, 96Mi Dashboard memory request, 128Mi Browserless memory request, and 1Gi memory limits.
- Expands the bundled bootstrap `SOUL.md` browser/CDP guidance for direct CDP usage, screenshot validation, and clear fallback behavior when the default CDP endpoint is unavailable.

## [v1.1.0] - 2026-07-10

### Added

- Adds opt-in bootstrap support through `HERMES_BOOTSTRAP_DIR` for `SOUL.md`, durable memories, skills, plugins, cron configuration, workspace files, and optional authentication state.
- Adds a reusable universal systems-architect bootstrap profile covering platform operations, architecture, research, QA, and software development.
- Exposes the mounted workspace through the Dashboard file browser and configures safe write roots for Agent, Dashboard, and WebUI.

### Changed

- Raises the default WebUI upload limit for large documents.
- Tunes public-example resource requests and limits for practical lab deployments.

### Upgrade notes

- Bootstrap is opt-in. Use `HERMES_BOOTSTRAP_MODE=missing` for normal upgrades.
- `HERMES_BOOTSTRAP_MODE=overwrite` replaces bootstrap-managed data and should be used only after review.

## [v1.0.0] - 2026-07-09

### Added

- Initial public release of the production-oriented Kubernetes/K3s installer for the Hermes Agent stack.
- Adds template-driven manifests for Hermes Agent Gateway, Hermes Dashboard, Hermes WebUI, and internal Browserless Chromium/CDP support.
- Provides `install.sh` for repeatable namespace-scoped installation, manifest rendering, secret creation, rollout waits, and upgrades.
- Provides `maintain.sh` for status checks, backup/restore, restart, upgrade, password rotation, and Browserless token rotation.
- Provides `doctor.sh` health checks for Kubernetes resources, service readiness, ingress access, WebUI agent wiring, Browserless/CDP connectivity, NetworkPolicy reachability, and Codex OAuth state.
- Documents operations, security, troubleshooting, Codex OAuth pairing, and agent maintainer workflows.
- Includes safe public examples and templates without real hostnames, passwords, tokens, OAuth state, kubeconfig, or generated secrets.
