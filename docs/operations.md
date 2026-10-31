# Operations guide

## Status

```bash
./maintain.sh status
./doctor.sh
```

## Restart

```bash
./maintain.sh restart
```

## Upgrade

The example configuration and configurator default to release-tested image tags.
For a newer reviewed release, update the three image references in
`current_config/hermes.env`, then run:

```bash
./install.sh
./doctor.sh
```

`install.sh` is re-runnable. It recreates the one-shot `hermes-init-config` Job before applying the manifest so Kubernetes Job immutability does not break upgrades/retries.

For an explicitly selected image update, use:

```bash
./maintain.sh upgrade
```

## Backup

```bash
mkdir -p backups
./maintain.sh backup ./backups/hermes-$(date -u +%Y%m%dT%H%M%SZ).age
```

The archive is encrypted with `age`. Install it on Fedora/RHEL hosts with:

```bash
dnf install age
```

By default, backup and restore prompt for the passphrase without echoing it. For automation use `--password-stdin` or `--password-file PATH`; the latter requires mode `0600` or `0640`. Password-file mode supplies the value through a no-echo pseudo-terminal, requires the internal `age` command to write payload data through `--output`, and never forwards the captured terminal transcript. Nonzero `age` status is preserved with a generic credential-free diagnostic. This mode requires a util-linux `script` implementation with `--echo` support; older implementations reject the operation before `age` is invoked.

### Data-only backup (sessions, workspace, config, skills — no runtime software)

`--data-only` backs up only Hermes-specific state: WebUI sessions, `config.yaml`, `SOUL.md`, `auth.json`, profiles, skills, memories, cron jobs, plugin data, kanban/state/projects/response-store databases, `/opt/data/home`, and the full `/workspace`. It deliberately excludes reproducible runtime software that a fresh `install.sh` rebuilds on its own: the `addon-venv` Python environment, `node`/`npm`/`npx`, `uv`, LSP servers, and disposable caches/logs. It also omits the Kubernetes resource snapshot and `/opt/data/.env`, so it is namespace-agnostic and safe to restore into a different instance (see [Migrating instance/namespace data with `--data-only`](#migrating-instancenamespace-data-with---data-only) below).

```bash
./maintain.sh backup ./backups/hermes-data-$(date -u +%Y%m%dT%H%M%SZ).age --data-only
```

A data-only archive is typically a small fraction of a full backup's size, since it skips gigabytes of installed packages and virtual environments.

## Extracting backup components

`extract` writes selected backup content to a new or empty local directory. It never changes Kubernetes resources or PVCs:

```bash
./maintain.sh extract backup.age \
  --output-dir ./recovery \
  --component bootstrap
```

Supported components are:

```text
data       opt/data and workspace
config     hermes.env, configuration_answers, backup-info.txt
bootstrap  the saved bootstrap directory
full       all currently supported components
```

Examples:

```bash
./maintain.sh extract backup.age --output-dir ./recovery --component data
./maintain.sh extract backup.age --output-dir ./recovery --component config
./maintain.sh extract backup.age --output-dir ./recovery --component bootstrap
./maintain.sh extract backup.age --output-dir ./recovery --full
./maintain.sh extract backup.age --output-dir ./recovery --full --dry-run
```

The output directory must be empty unless `--dry-run` is used. Existing files are never overwritten. The `full` extraction includes the encrypted snapshot metadata; use it only in a mode-0700 recovery directory because it contains base64-encoded Kubernetes Secret data. Full rollback should normally use `restore --full` rather than manually applying extracted resources.

For bootstrap recovery, review the extracted files first and then apply them through the normal installer path, for example:

```bash
HERMES_BOOTSTRAP_DIR=./recovery/bootstrap \
ENV_FILE=./recovery/hermes.env \
./install.sh
```

Password input for extraction:

```bash
./maintain.sh extract backup.age --output-dir ./recovery --full --password-prompt
printf '%s\n' "$BACKUP_PASSWORD" | ./maintain.sh extract backup.age --output-dir ./recovery --full --password-stdin
./maintain.sh extract backup.age --output-dir ./recovery --full --password-file /secure/hermes-backup.pass
```

`--dry-run` decrypts and validates the archive, checks the destination, and reports the selected mode without writing files.


## Restore

A normal restore requires the Namespace, Deployments, and PVCs to exist and restores only the encrypted PVC payload:

```bash
./maintain.sh restore ./backups/hermes-YYYYmmddTHHMMSSZ.age
./doctor.sh
```

For rollback after the Namespace or installation has been removed, use full mode:

```bash
./maintain.sh restore ./backups/hermes-YYYYmmddTHHMMSSZ.age --full
```

The backup contains a normalized, encrypted snapshot of the repository-owned Namespace, PVCs, Hermes workloads, Services, Jobs, Ingresses, NetworkPolicies, Middleware, ServiceAccounts, and application Secrets. Full mode recreates the Namespace if absent, applies those resources and Secrets, then restores the PVC payload.

Before applying anything, use:

```bash
./maintain.sh restore ./backups/hermes-YYYYmmddTHHMMSSZ.age \
  --full --dry-run --password-file /secure/hermes-backup.pass
```

Full mode requires a readable Kubernetes API server, but `--force` overrides all compatibility and targeting policy gates: missing/unknown backup K3s version, non-K3s detection, K3s version mismatch, and configured-vs-backup Namespace mismatch. With a Namespace mismatch, the restore targets the Namespace recorded in the backup. `--force` does not bypass cryptographic, archive, snapshot-schema, Kubernetes API, or resource-application failures:

```bash
./maintain.sh restore ./backups/hermes-YYYYmmddTHHMMSSZ.age --full --force
```

The helper Pod is removed on success or failure, and restored write-capable Deployments return to their snapshot replica counts. Local `hermes.env`, answers, and bootstrap metadata are not silently written into the host checkout; review them through `extract --component config|bootstrap`.

### Migrating instance/namespace data with `--data-only`

`restore --data-only` overlays the curated Hermes-specific paths from a `backup --data-only` archive onto an **already-installed** target — it does not wipe `/opt/data`/`workspace` first (unlike normal and `--full` restore), and it does not touch Kubernetes resources, Secrets, or `/opt/data/.env`. This makes it the right tool for moving sessions, workspace, profiles, skills, and memories into a fresh instance, a different namespace, or a newer release, while letting `install.sh` provide the runtime software (Node/npm/npx, the addon Python venv, `uv`, LSP servers) fresh:

```bash
# 1. On the source instance, stop writers and take a data-only backup.
./maintain.sh backup ./backups/hermes-data-source.age --data-only

# 2. Install the destination fresh (new namespace, new PVCs, or a newer release).
HERMES_NAMESPACE=new-namespace ./install.sh

# 3. Overlay the data-only archive onto the freshly installed destination.
HERMES_NAMESPACE=new-namespace ./maintain.sh restore ./backups/hermes-data-source.age --data-only

# 4. The destination's own API key/Browserless token are already correct
#    (install.sh generated them); no reconcile step is needed unless you
#    separately copied /opt/data by hand outside restore --data-only.
./doctor.sh
```

Preview an archive's contents without extracting or scaling anything:

```bash
./maintain.sh restore ./backups/hermes-data-source.age --data-only --dry-run --password-file /secure/hermes-backup.pass
```

`--data-only` and `--full` are mutually exclusive. Because a data-only archive never carries `/opt/data/.env` or a Kubernetes Secret snapshot, `restore --data-only` skips the API-key Secret-sync step entirely — it neither reads nor writes `Secret/hermes-api-server`. If you separately copy other files onto `/opt/data` outside of `restore --data-only` (for example, restoring a data-only archive gathered by hand rather than through `backup --data-only`), converge the API key afterward with [`reconcile-api-key --source secret`](#reconcile-the-internal-api-key-after-an-external-pvc-migration).

## Reconcile the internal API key after an external PVC migration

Normal installs and `maintain.sh restore` synchronize `Secret/hermes-api-server` into persistent `/opt/data/.env`. A manual or external PVC migration can copy an older `.env` **after** that synchronization step. Hermes intentionally loads the persistent file with user configuration precedence, so the Agent may accept the migrated key while Agent, Dashboard, and WebUI Pods still receive the current Kubernetes Secret. External OIDC does not replace this internal Bearer credential.

After copying PVC data by any path other than `maintain.sh restore`, make the Kubernetes Secret authoritative with:

```bash
./maintain.sh reconcile-api-key --source secret
./doctor.sh
```

The explicit source is required; the command never guesses between two valid credentials and never generates a new key. It validates the Secret without printing it, atomically replaces only `API_SERVER_KEY` in `/opt/data/.env`, and preserves unrelated entries with mode `0600`. It then applies one Pod-template mutation containing both the non-secret Secret revision and a fresh non-secret reconciliation request ID to every enabled Agent API consumer. The request ID guarantees a real rollout even when the Secret revision annotation was already current. Verification accepts only Ready Pods carrying both exact annotations, probes `/health/detailed`, rechecks the authoritative Secret revision after verification, and removes the helper Pod on success or failure. If the Secret changes at any point, the command retries before rollout or fails without reporting convergence after rollout; rerun it to converge the newer revision. Expect a brief interruption while those Deployments roll out.

Before a production reconciliation, create an encrypted application backup. The archive preserves both the Kubernetes Secret snapshot and the pre-change persistent `.env` without writing either credential source to a separate plaintext host file:

```bash
umask 077
rollback_dir="./backups/api-key-reconcile-$(date -u +%Y%m%dT%H%M%SZ)"
install -d -m 0700 "$rollback_dir"

./maintain.sh backup "$rollback_dir/hermes.age"
```

Keep the passphrase outside the checkout. The encrypted archive belongs in the ignored `backups/` directory and must not be committed. The operation is idempotent: if a Deployment patch, rollout, or verification step fails after persistent `.env` was synchronized, correct the reported Kubernetes problem and rerun the same command to converge every consumer to the still-authoritative Secret. Do not rotate or edit either key as an ad-hoc recovery step. A normal restore intentionally normalizes the saved Secret into persistent `.env`; prefer rerunning `reconcile-api-key --source secret` when the goal is service recovery. If forensic reproduction of the deliberately inconsistent pre-change state is required, use `maintain.sh extract --full` only in a temporary mode-`0700` recovery directory, restore the Secret snapshot and `opt/data/.env` separately under an approved incident procedure, then securely remove the decrypted recovery directory.

## Reconcile Browserless after an external PVC migration

A copied `/opt/data/.env` or `/opt/data/profiles/<name>/.env` can retain the source installation's `BROWSER_CDP_URL`. Profile loading gives those persistent files precedence over the Pod's Secret-backed base environment, so ordinary Kubernetes checks can look healthy while Hermes browser tools receive HTTP 401 from Browserless.

After any manual or external PVC migration, make the destination Browserless Secrets authoritative:

```bash
./maintain.sh reconcile-browser-token --source secret
./doctor.sh
```

The command requires `hermes-browser-token` and `hermes-browser-cdp` to contain the same non-empty token, the expected internal `/chromium` URL, and the shell- and URL-query-safe token alphabet `[A-Za-z0-9._:/=@-]`. It writes no credential to the operator host and prints no token. A storage helper atomically updates `/opt/data/.env` plus existing profile `.env` files that already override `BROWSER_CDP_URL`, preserving unrelated entries and mode `0600`. It then rolls Browserless plus Agent, Dashboard, and WebUI with both Secret revisions and a fresh reconciliation request, accepts only Ready Pods carrying those annotations, executes `Browser.getVersion` from every enabled client, rechecks both Secret revisions, and removes the helper Pod. Expect a brief interruption during the Recreate rollouts.

## Bootstrap agent configuration

The recommended configuration lifecycle is:

```bash
./configure.sh --no-install
# Later, only when intentionally regenerating from saved answers:
./configure.sh --from-answers --no-install
```

`current_config/` is wizard-owned and contains the composed bootstrap, `hermes.env`, and installer artifacts. Replay safely replaces this directory only when its ownership marker is present, but it discards manual changes made after the wizard; reapply required customization before installing. The wizard writes the Agent-native configuration to `current_config/bootstrap/config.yaml`; the installer injects it as `/opt/data/config.yaml` on the persistent `hermes-home` PVC, so a Pod restart preserves it. The root-level `configuration_answers` file preserves non-password answers with mode `0600`; plaintext passwords are never written there or to `hermes.env`. Both paths are Git-ignored. Bootstrap mode `missing` seeds absent PVC files and upgrades only exact stock Hermes/installer `SOUL.md` content to the selected bootstrap identity; every customized `SOUL.md` remains untouched. `overwrite` replaces same-path files and merges source directories, while destination-only entries remain until removed separately.

When `configuration_answers` already exists, starting `./configure.sh` interactively offers to reuse it. Answer `y` to pre-seed the interactive questions with the saved non-secret answers; pressing Enter accepts each saved value, while entering a new value overrides it. Answer `n` to use the normal built-in defaults instead. In both cases the questions remain interactive. Use `--from-answers` only for non-interactive replay without the questions.

The operational scripts resolve configuration in this order: an explicit `ENV_FILE`, root `hermes.env` when it exists, then wizard-generated `current_config/hermes.env`. Therefore bare `./doctor.sh` and `./maintain.sh` commands work after the wizard while preserving compatibility with manual root configuration.

## Authentication mode

The wizard asks for an authentication mode (`local-password` or `external-oidc`) whenever Dashboard or WebUI is enabled, and only asks the follow-up questions for the mode selected — local-password prompts (username, password) and external-oidc prompts (issuer, client IDs, public/redirect URLs, allow claim/values) never both fire. This is the same `HERMES_AUTH_MODE` value validated and consumed by `install.sh`; see [`authelia-freeipa-sso-setup-guide.md`](authelia-freeipa-sso-setup-guide.md) for the fields required in `external-oidc` mode and how to configure an external identity provider.

## Initial generated credentials

When the wizard password prompt is left empty, the password is generated only when `install.sh` runs. It is intentionally absent from `hermes.env` and `configuration_answers`. The installer applies generated and reused values directly to Kubernetes Secrets; it does not store or print plaintext credentials locally. Authorized operators can retrieve all configured credentials with:

```bash
./maintain.sh show-passwords
```

On the first installation, missing credentials are generated. On later installations, blank values reuse existing Kubernetes Secrets; explicit non-empty values override them. Kubernetes lookup or malformed-Secret errors fail closed rather than rotating credentials implicitly. Use the maintenance rotation commands for deliberate changes.

Use `HERMES_BOOTSTRAP_DIR` to seed SOUL, memory, skills, plugins, cron jobs, config, and workspace context into the persistent PVCs. This is useful for repeatable installations where the Agent should start with known behavior.

```bash
# Use a profile to bootstrap SOUL, memory, selected skills, requirements, and workspace
# (personal-assistant is the default)
echo 'HERMES_BOOTSTRAP_PROFILE=universal-system-architect' >> hermes.env
./install.sh
```

```bash
# Or build a fully custom bootstrap directory from shared + profile:
cp -a examples/bootstrap-shared ./bootstrap
cp -a examples/bootstrap-profiles/personal-assistant/. ./bootstrap/
${EDITOR:-vi} ./bootstrap/SOUL.md
cat >> hermes.env <<'EOF'
HERMES_BOOTSTRAP_DIR=./bootstrap
HERMES_BOOTSTRAP_MODE=missing
HERMES_BOOTSTRAP_INCLUDE_AUTH=false
EOF
./install.sh
```

The profile workflow uses one canonical shared skill source plus `skills.txt` selection. Profile defaults from `defaults.conf` are applied only when the operator has not set the corresponding variable. For generated profile composition, `HERMES_ANSIBLE_SETUP=false` excludes the profile's `workspace/ansible` tree as well as disabling Ansible initialization. This is non-destructive: it does not remove files already stored on a workspace PVC, and it does not filter an operator-owned custom `HERMES_BOOTSTRAP_DIR`.

Mapping:

```text
SOUL.md                  -> /opt/data/SOUL.md
memories/USER.md         -> /opt/data/memories/USER.md
memories/MEMORY.md       -> /opt/data/memories/MEMORY.md
skills/                  -> /opt/data/skills/
plugins/                 -> /opt/data/plugins/
cron/                    -> /opt/data/cron/
config.yaml              -> /opt/data/config.yaml
.env                     -> /opt/data/.env
workspace/               -> /workspace/
auth.json                -> /opt/data/auth.json only with HERMES_BOOTSTRAP_INCLUDE_AUTH=true
```

Use `HERMES_BOOTSTRAP_MODE=missing` for normal installs/upgrades. In this mode, a selected bootstrap profile replaces only recognized generic Hermes or installer SOUL text (ignoring trailing newline characters); any operator content or other customization is preserved. Use `overwrite` only when you intentionally want the bootstrap source to replace all existing same-path files. Bootstrap data, `current_config/`, and `configuration_answers` can contain personal data or credentials; keep them out of Git.

## Credential status

Use the following command to check all three Kubernetes credential Secrets:

```bash
./maintain.sh show-passwords
```

It runs one `kubectl get secret` query for each of the Dashboard/WebUI password, API server key, and Browserless token, decodes the values, and prints them. Use this only from a trusted administrator terminal; terminal history, scrollback, logs, screen sharing, and transcripts can expose the credentials. The command does not write the values to local files.

## Password rotation

`maintain.sh rotate-passwords` rotates the shared password for the enabled Dashboard and/or WebUI components and supports three explicit input modes:

1. **Interactive hidden prompts** with `--prompt` — default when stdin is a TTY.
2. **Generated value** with `--generate` — stores the new random value only in the Kubernetes Secret.
3. **Environment variables** with `--from-env` — intended for automation/CI.

Important: interactive rotation does **not** silently reuse password values from `hermes.env`. If a password is present in the env file and you want to apply exactly that value, say so explicitly with `--from-env`.

Interactive rotation:

```bash
./maintain.sh rotate-passwords --prompt
```

Dashboard + WebUI, lab password allowed:

```bash
./maintain.sh rotate-passwords --lab --prompt
```

Generate a new random value:

```bash
./maintain.sh rotate-passwords --generate
```

Environment-driven rotation:

```bash
DASHBOARD_AUTH_USER=admin DASHBOARD_AUTH_PASSWORD='use-a-long-random-value' ./maintain.sh rotate-passwords --from-env
```

Production policy rejects weak passwords by default. Use `--lab`, `HERMES_PASSWORD_POLICY=lab`, or `HERMES_ALLOW_WEAK_PASSWORD=true` only for lab systems.

Plaintext passwords are not stored locally or printed for any rotation mode. The generated value is stored only in Kubernetes Secret `hermes-dashboard-auth`. Use `./maintain.sh show-passwords` from a trusted administrator terminal when the current values are needed.

## Browser token rotation

```bash
./maintain.sh rotate-browser-token
./doctor.sh
```

Bare `rotate-browser-token` and explicit `--generate` always generate a fresh random token; they never reuse `BROWSER_TOKEN` loaded from `hermes.env`. Non-interactive automation may provide a deliberate value only through the process environment and `--from-env`:

```bash
BROWSER_TOKEN='use-a-url-safe-random-value' ./maintain.sh rotate-browser-token --from-env
```

Rotation snapshots the previous matching Secret values into private temporary files before updating either resource. If either Kubernetes update fails, it restores both previous values and does not restart workloads; a rollback failure is reported as critical and requires restoration from the protected application backup. After a successful pair update, rotation invokes the same persistent/profile convergence and verified rollout path as `reconcile-browser-token`; it also recreates Browserless so the new server token and all consumers become active together. Do not patch one Browserless Secret independently.

## Codex re-authentication

```bash
kubectl -n "$HERMES_NAMESPACE" exec -it deploy/hermes-agent -- /bin/bash
hermes model
```

See `docs/codex-auth.md`.


## WebUI CDP browser-tool dependency

WebUI chat sessions execute Hermes tools inside the WebUI container. The installer therefore includes a `prepare-browser-cli` initContainer that makes Node and `agent-browser` available under `/opt/data/node/bin` and `/opt/data/node_modules/.bin`. If browser tools fail in WebUI with `agent-browser CLI not found`, rerun `./install.sh` and wait for the WebUI rollout.


## Browserless resource knobs

Repo defaults are lab-friendly:

```bash
BROWSER_CONCURRENT=4
BROWSER_QUEUED=10
BROWSER_TIMEOUT_MS=30000
MODEL_NAME=gpt-5.6-luna
```

With `BROWSER_CONCURRENT=4`, `doctor.sh` can perform active CDP checks while leaving capacity for parallel browser sessions. `BROWSER_QUEUED=10` bounds waiting sessions, and `BROWSER_TIMEOUT_MS=30000` limits one Browserless session to 30 seconds. For screenshot-heavy workflows, increase the concurrency deliberately if Browserless pressure shows sustained queueing.


## WebUI password uses the Dashboard password secret

The WebUI container receives:

```yaml
HERMES_WEBUI_PASSWORD <- secret/hermes-dashboard-auth:password
```

So the WebUI login password is the same value as `DASHBOARD_AUTH_PASSWORD`. This avoids the remote first-password setup gate safely because WebUI auth is enabled at startup. When `maintain.sh rotate-passwords` rotates the dashboard password, it also restarts `hermes-webui` so the env-backed Secret value is reloaded.

## Authentication session lifetimes

The default policy is:

```dotenv
HERMES_AUTH_SESSION_MAX_TTL_SECONDS=43200
HERMES_AUTH_SESSION_IDLE_TTL_SECONDS=7200
```

The 12-hour maximum is injected into WebUI as
`HERMES_WEBUI_SESSION_TTL`. For external OIDC, apply the same 12-hour value to
Authelia's session expiration and the Dashboard client's ID-token lifespan.
The two-hour idle value applies only to Authelia; Dashboard and WebUI currently
use absolute/token lifetimes rather than sliding inactivity. Disable Authelia
remember-me with `remember_me: -1`.

After changing either value, rerun `./install.sh` and `./doctor.sh`. Because
Authelia is externally managed, update and verify it through its own deployment
process as well. Existing WebUI sessions retain the expiry assigned when they
were created; log out or invalidate existing sessions when an immediate policy
cutover is required.


## WebUI upload size

The installer sets:

```bash
HERMES_WEBUI_MAX_UPLOAD_MB=220
```

This overrides the upstream WebUI default of 20MiB. Change the value in `hermes.env` and rerun `./install.sh` to update the WebUI deployment.


## Kubernetes resource knobs

The manifest resource requests/limits are configurable through `HERMES_*_CPU_REQUEST`, `HERMES_*_MEMORY_REQUEST`, `HERMES_*_CPU_LIMIT`, and `HERMES_*_MEMORY_LIMIT` variables for Agent, Dashboard, WebUI, and Browser. Defaults stay conservative, but cramped lab clusters can lower requests in their env file.


## Deployment update strategy

Deployment update strategy is `Recreate` for every enabled single-replica component. This avoids surge Pods during `install.sh`/secret refresh restarts, which can otherwise deadlock rollouts on small single-node K3s clusters with tight CPU requests.

### Dashboard workspace file browser

The Dashboard `/files` view must be able to browse `/workspace`. The upstream dashboard locks to `/opt/data` in hosted/container mode unless `HERMES_DASHBOARD_FILES_ROOT` is set, so the installer sets:

```bash
HERMES_DASHBOARD_FILES_ROOT=/workspace
HERMES_WRITE_SAFE_ROOT=/opt/data:/workspace
```

Keep `HERMES_WRITE_SAFE_ROOT` on Agent, Dashboard, and WebUI so file tools use the same safe roots; keep `HERMES_DASHBOARD_FILES_ROOT` on Dashboard for the UI file browser.

## Persistent Python addon packages

For the complete software-layer model—including what is installer-managed, cache-only, project-local, or image-owned—see [`persistent-software.md`](persistent-software.md).

The selected profile activates its own `requirements.txt` by default. Set `HERMES_ADDON_REQUIREMENTS` to override it, or set `HERMES_ADDON_REQUIREMENTS=` explicitly to disable addon packages. The requirements file is packaged into the same init Secret mechanism as bootstrap data and installed into a uv-managed Python runtime under `/opt/data`.

```bash
cat >> hermes.env <<'EOF'
HERMES_ADDON_REQUIREMENTS=./requirements.txt
HERMES_ADDON_PYTHON_VERSION=3.13
EOF
ENV_FILE=./hermes.env ./install.sh
```

Operational properties:

- Persistent: the uv runtime and addon venv live on the `/opt/data` PVC and survive Pod recreation.
- Cross-container: the same Python, `ansible`, and other addon CLIs are usable from `hermes-agent`, `hermes-dashboard`, and `hermes-webui` even if the WebUI image has no system Python.
- Re-runnable but additive: rerunning `install.sh` installs missing packages and changes versions only as needed to satisfy current requirements; it does not otherwise seek newer releases. Packages removed from requirements are not automatically pruned, and empty requirements do not remove an existing venv.
- Ansible exception: with profile-provided requirements and `HERMES_ANSIBLE_SETUP=false`, the generated requirements omit Ansible and the init Job explicitly uninstalls `ansible` and `ansible-core` from an existing addon venv.
- Isolated: Hermes' own `/opt/hermes/.venv` remains first in the Agent `PATH`; do not install ad-hoc packages there.
- Migrating: if an older non-uv addon venv exists, the init job replaces it with a uv-managed venv.
- Python-version changes: changing `HERMES_ADDON_PYTHON_VERSION` installs that managed Python, but a healthy marked addon venv is not automatically rebuilt onto the new interpreter.
- Manual installs are possible after the runtime exists, but they are unmanaged and non-reproducible. Use them for investigation only; put required packages in the requirements file:

```bash
kubectl -n <namespace> exec -it deploy/hermes-agent -- /bin/bash
/opt/data/addon-venv/bin/python -m pip install <package>
```

Use absolute paths for the addon interpreter when required:

```bash
/opt/data/addon-venv/bin/python -c "import <package>; print('ok')"
```

If an interactive `kubectl exec` shell resets `PATH`, export the addon path manually for that shell:

```bash
export PATH=/opt/data/addon-venv/bin:/opt/data/uv/bin:$PATH
```

## Persistent HOME and SSH

Agent, Dashboard, and WebUI always use `/opt/data` as persistent Unix home on the `hermes-home` PVC.

SSH setup defaults to `true` for every bundled profile so a fresh setup has one usable persistent identity out of the box. Override it explicitly with `HERMES_SSH_SETUP=false` when a profile must not have an SSH identity:

```bash
HERMES_SSH_SETUP=true
HERMES_SSH_KEY_TYPE=ed25519
HERMES_SSH_KEY_PATH=/opt/data/.ssh/id_ed25519
```

Operational behavior:

- `HOME=/opt/data`, `XDG_CONFIG_HOME=/opt/data/.config`, and `XDG_CACHE_HOME=/opt/data/.cache` are set on Agent, Dashboard, and WebUI processes.
- If `HERMES_SSH_SETUP=true`, `/opt/data/.ssh` is created with mode `700`, `known_hosts` is created with mode `644`, and the init job generates the key only when `HERMES_SSH_KEY_PATH` does not already exist. Existing keys are preserved.
- Private keys are forced to mode `600`; public keys are forced to mode `644`.
- `/opt/data/.ssh/config` selects the persistent key with `IdentitiesOnly yes` and includes `/etc/ssh/ssh_config`, preserving image/site-wide OpenSSH policy. A PVC-backed wrapper at `/opt/data/hermes-managed/bin/ssh` is first on the Agent, Dashboard, WebUI, and terminal subprocess PATH. It resolves the system `ssh` on a recursion-safe lookup path, then executes it without replacing the inherited runtime PATH, so `ProxyCommand`, `LocalCommand`, and `KnownHostsCommand` helpers remain discoverable. Ordinary `ssh` therefore uses the same persistent config independently of passwd-home differences. No `.ssh` Kubernetes `subPath` mount is required.
- Do not bypass the wrapper with `/usr/bin/ssh` or a sanitized `PATH` that excludes `/opt/data/hermes-managed/bin`. OpenSSH derives its default `~/.ssh` location from the runtime account's passwd entry rather than relying only on the overridden `HOME=/opt/data`; a direct system-client invocation can therefore search the image account home and miss the PVC identity.
- Rerunning the installer updates only its marked SSH config block, preserves operator-managed config lines, and never rotates an existing key.

Fetch the generated public key:

```bash
kubectl -n <namespace> exec deploy/hermes-agent -- cat /opt/data/.ssh/id_ed25519.pub
```

Do not run `ssh-keygen` merely because a shell reports a different passwd home. Verify the effective identity first:

```bash
kubectl -n <namespace> exec deploy/hermes-agent -- \
  ssh -G example.invalid | grep -E '^(identityfile|identitiesonly) '
```

If SSH is explicitly disabled, a fresh PVC receives no SSH key or wrapper; on an existing PVC the installer removes only its managed wrapper and preserves existing key/config data. Generating, replacing, rotating, importing, or deleting an existing key is a separate credential-lifecycle action and must be intentional.

The SSH key is for SSH access to managed target systems. GitHub access is separate: use `GITHUB_TOKEN` from mode-`0600` `/opt/data/.env` for GitHub API and HTTPS Git operations. Do not add the managed-target SSH key to GitHub merely to make repository access work, and never put either private keys or token values in Git, remote URLs, logs, or PR text.

Keep host key checking enabled. Prefer maintaining `/opt/data/.ssh/known_hosts` or using reviewed per-host `accept-new` entries in `/opt/data/.ssh/config`; do not use global `StrictHostKeyChecking=no` as a default.

## NPX / Node.js package support

Node/npm/npx persistence and lifecycle boundaries are described in [`persistent-software.md`](persistent-software.md). In particular, the managed WebUI runtime, npm cache, project-local packages, and global npm installs have different guarantees.

Node.js, npm, and npx are always available in every profile: the init job creates the npm cache directory at `/opt/data/.npm` with correct `hermes:hermes` ownership, and the agent container receives `npm_config_yes=true` in its environment. This allows `npx`-based MCP servers and skill installers to run without blocking on interactive prompts or failing with `EACCES` on the cache directory.

Operational behavior:

- The npm cache directory lives on the PVC at `/opt/data/.npm` and survives Pod recreation.
- `npm_config_yes=true` is set in the agent and WebUI deployment environments and in the terminal profile hook (`/opt/data/home/.hermes-terminal-env`), so the gateway process, WebUI browser tooling, and interactive login shells all inherit it.
- No npm packages are pre-installed. The infrastructure only prepares the ground for `npx` to work without interactive prompts.

Manual `npx` usage works from any context:

```bash
kubectl -n <namespace> exec deploy/hermes-agent -- npx --yes <package>
```

Because the agent `npm_config_yes=true` is set, adding `--yes` is technically redundant but keeps the command self-documenting for manual use.
