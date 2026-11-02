# Security notes

## Do not commit secrets

Never commit:

- `hermes.env`
- `configuration_answers`
- generated configuration and artifacts under `current_config/` or `.rendered/`
- backups
- kubeconfigs
- OAuth files such as `auth.json`
- tokens/passwords/API keys

Environment files are parsed as non-executable `KEY=value` data. Comments, blank lines, and shell-style quoting are supported; command substitutions, function definitions, and unsafe shell control variables are not executed or accepted. Use literal values in `hermes.env` rather than shell expressions such as `${...}`.

The repository `.gitignore` excludes the common local files, but operators are still responsible for review before commit.
## Container security contexts

All workload Pods disable automatic Kubernetes ServiceAccount-token mounting and use the `RuntimeDefault` seccomp profile. The running application containers also set `allowPrivilegeEscalation: false`.

The contexts are intentionally image-specific:

- Browserless runs as numeric UID/GID `999` (`blessuser`), drops all Linux capabilities, and remains `runAsNonRoot`.
- Hermes Agent, Dashboard, and WebUI retain their current root-startable container behavior because the upstream s6/WebUI startup paths perform UID/GID and persistent-volume initialization before starting application services.
- Their init containers retain the privileges required for `chown`, `chmod`, SSH-key setup, and addon-runtime preparation.

Do not turn this into a Pod-wide `runAsNonRoot`, `readOnlyRootFilesystem`, or `drop: [ALL]` policy without rebuilding and testing the images. The live acceptance checks must cover Hermes CLI, addon Python/YAML, Ansible localhost ping, SSH permissions, WebUI health, and Browserless CDP/WebSocket behavior.

## Browserless/CDP

Browserless is powerful: it can fetch websites from inside your cluster. This repository therefore:

- exposes Browserless as `ClusterIP` only;
- uses a token;
- stores the CDP URL in a Kubernetes Secret;
- injects `BROWSER_CDP_URL` into Hermes containers;
- restricts access using NetworkPolicy.

The expected redacted endpoint is:

```text
ws://hermes-browser:3000/chromium?token=<redacted>
```

This follows Browserless' documented direct CDP connection path. The endpoint is generated from `BROWSER_TOKEN`, stored in Secret `hermes-browser-cdp`, and injected into each enabled Hermes runtime component. Never print the full value in logs or docs. See the [Browserless connection URL patterns](https://docs.browserless.io/baas/connection-url-patterns).

## Authentication

`./maintain.sh show-passwords` retrieves and decodes the three credential Secrets for an authorized administrator. It prints the values to the terminal and therefore must only be used from a trusted terminal; never capture, paste, log, or share its output. The command does not write credentials to local files.

The setup supports mutually exclusive local-password and external-OIDC application authentication:

| Layer | Scope | Controlled by | Notes |
|---|---|---|---|
| Hermes Dashboard BasicAuth | Dashboard application login | `DASHBOARD_AUTH_USER` / `DASHBOARD_AUTH_PASSWORD` | Configured when Dashboard is enabled |
| Hermes WebUI password auth | WebUI application login | `HERMES_WEBUI_PASSWORD` from `secret/hermes-dashboard-auth:password` | Configured when WebUI is enabled |
| External OIDC | Dashboard and WebUI human login | External IdP plus `HERMES_*_OIDC_*` | Omits local application password variables |

### Session lifetime policy

`HERMES_AUTH_SESSION_MAX_TTL_SECONDS=43200` sets the WebUI absolute
maximum through `HERMES_WEBUI_SESSION_TTL`, not a universal SSO lifetime.
The external provider cookie and Dashboard ID token have independent lifetimes.
See [SSO integration](sso-integration.md) for provider settings and current
claims/lifespan integration gaps.

`HERMES_AUTH_SESSION_IDLE_TTL_SECONDS=7200` is the Authelia-only two-hour
sliding inactivity policy. Dashboard and WebUI do not currently expose
equivalent sliding-idle settings. Configure Authelia with `remember_me: -1`;
otherwise remember-me can override the normal cookie expiration. The installer
validates that both values are numeric, at least 60 seconds, and that idle does
not exceed the absolute maximum.

## TLS

Terminate TLS at your Ingress controller. This template supports Ingress TLS references but does not manage certificates.

## Backups

Backups include OAuth state and possibly user/session data. `maintain.sh backup` creates an `age`-encrypted archive and a SHA-256 checksum, both with mode `0600`. The encrypted metadata preserves the installer ENV, saved non-secret answers, generated bootstrap inputs, the exact K3s server version, and a normalized snapshot of repository-owned Kubernetes resources. The snapshot includes the four application Secrets required for a full rollback; their values remain encrypted and are never printed. Restore validates the archive before changing the namespace. Without `--force`, `restore --full` enforces K3s identity, exact version, and Namespace matching. `--force` overrides those compatibility/targeting gates, but never cryptographic, archive, schema, API, or apply failures.

## Password policy

`maintain.sh rotate-passwords` defaults to production policy:

- minimum 14 characters;
- lower-case, upper-case, digit, and symbol required;
- weak values are rejected unless lab mode is explicit.

For lab systems only:

```bash
./maintain.sh rotate-passwords --lab
# or
HERMES_PASSWORD_POLICY=lab ./maintain.sh rotate-passwords
```

The scripts avoid passing plaintext passwords as command-line arguments to `openssl` or `kubectl`.

## Credential storage

`install.sh` and generated-password rotation do not write plaintext credentials to local files and do not print credential values. Credentials are stored only in Kubernetes Secrets. Authorized operators can retrieve the current values when needed, for example:

```bash
./maintain.sh show-passwords
```

`current_config/`, `configuration_answers`, and `.rendered/` remain Git-ignored because they can contain other sensitive configuration, but they must not be used as credential stores.



## WebUI first-password bootstrap

Current Hermes WebUI intentionally blocks unauthenticated remote first-password setup unless the operator sets:

```bash
HERMES_WEBUI_ONBOARDING_OPEN=1
```

This installer does **not** set that escape hatch by default. Instead, it enables WebUI password auth at process start by injecting:

```yaml
HERMES_WEBUI_PASSWORD <- secret/hermes-dashboard-auth:password
```

The WebUI password is therefore the same value as `DASHBOARD_AUTH_PASSWORD`. `HERMES_WEBUI_ONBOARDING_OPEN=1` should only be used as a temporary, operator-controlled bootstrap exception when you intentionally manage WebUI password setup yourself.


## Upload size

`HERMES_WEBUI_MAX_UPLOAD_MB` controls the WebUI upload cap. The default is 220MiB in this installer. Larger caps increase memory/disk pressure because uploads are parsed server-side; raise deliberately and monitor resource usage.


## API server key length

Hermes Agent refuses to start the API server when `API_SERVER_KEY` is a placeholder or shorter than 16 characters. `install.sh` requires the final explicit, reused, or generated value to be at least 16 characters. Use a high-entropy value such as `openssl rand -hex 32` for explicit production configuration.

Because the resolved values are persisted as unquoted dotenv/shell assignments on the shared PVC, explicit, reused, and reconciled API keys are restricted to `[A-Za-z0-9._:/+=@%-]`, while Browserless tokens use the URL-query-safe subset `[A-Za-z0-9._:/=@-]`. Whitespace, `#`, `~`, `+`, `%`, control characters, non-ASCII bytes, command substitutions, and other shell- or query-sensitive characters are rejected rather than normalized. Dashboard passwords and usernames are not subject to this persistence-specific alphabet restriction.

External OIDC authenticates human access to Dashboard and WebUI; it does not replace the Bearer key used by those consumers to call the internal Agent API. After a manual or external PVC migration, run `maintain.sh reconcile-api-key --source secret` so a migrated `/opt/data/.env` cannot keep an older API key authoritative after the Kubernetes Secret has been rotated. The reconciliation path never renders or prints the key and verifies real authenticated API access after the coordinated rollout.

Browserless has the same persistent-precedence boundary across both `/opt/data/.env` and profile `.env` files. After an external PVC migration, run `maintain.sh reconcile-browser-token --source secret`. It first proves `hermes-browser-token` and `hermes-browser-cdp` agree, rejects symlinked profile roots/directories/`.env` targets, then synchronizes existing persistent overrides without exposing the URL/token and verifies `Browser.getVersion` from each enabled consumer. `rotate-browser-token` invokes this path automatically.

## Bootstrap data

`HERMES_BOOTSTRAP_DIR` can contain SOUL.md, memories, skills, plugins, cron jobs, `.env`, and optionally `auth.json`. Treat real bootstrap directories and `$HERMES_RENDER_DIR/bootstrap.tar.gz` as sensitive. The repo ignores local `bootstrap/`, `current_config/`, `configuration_answers`, and `.rendered/`; commit sanitized examples under `examples/bootstrap-shared/` and `examples/bootstrap-profiles/`.

`HERMES_BOOTSTRAP_INCLUDE_AUTH=false` is the default. Enable it only when you deliberately restore OAuth state from a protected source.
