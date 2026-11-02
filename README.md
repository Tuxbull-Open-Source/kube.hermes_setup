# kube.hermes_setup

Production-oriented Kubernetes/K3s installer for a [Hermes Agent](https://github.com/nousresearch/hermes-agent) stack:

- **Hermes Agent** — mandatory API/gateway runtime
- **Hermes Dashboard** — optional administrative dashboard
- **Hermes WebUI** — optional browser chat interface
- **Browserless Chromium** — optional internal browser/CDP backend

The repository is template-driven. Deployment-specific configuration, credentials, OAuth state, kubeconfigs, rendered artifacts, and backups must remain outside Git.

## Requirements

The administrative workstation needs:

- `git`, `kubectl`, `openssl`, `bash`, `python3`, GNU `tar`, `gzip`, and standard coreutils (including `base64`); tests also use `sha256sum`
- a working Kubernetes context
- permission to manage the target namespace and rendered resources
- an Ingress controller when Dashboard or WebUI should be publicly reachable

GNU `tar` and `gzip` are retained for bootstrap artifacts. Backup/recovery is
operator-owned through Velero; the installer does not configure or test it.
See [recovery ownership](docs/operations.md#backup-and-recovery-operator-owned-velero).

## Quick start

```bash
git clone https://github.com/Bitbull-Ideas/kube.hermes_setup.git
cd kube.hermes_setup
./configure.sh --no-install
```

The configurator writes Git-ignored deployment files under `current_config/`. Review them before installation. Use [`examples/hermes.env.example`](examples/hermes.env.example) as the complete configuration-variable reference.

For production use, read the security, operations, and QA guides before continuing:

```bash
./install.sh
./doctor.sh
```

## Bootstrap profiles

- `personal-assistant`
- `universal-system-architect`
- `universal-system-administrator`

Profiles seed the persistent Hermes home and workspace with a curated identity, configuration, skills, and optional tooling. The configuration wizard resolves profile-controlled settings through one typed model with this precedence: the operator's interactive choice, a reused or replayed saved answer, an explicit process/environment value, the selected profile's `defaults.conf`, then the setting's global fallback. Enabling Ansible still implies SSH. After profile selection, the wizard displays the effective Ansible and SSH presets with their source. The final summary reports provenance for those boolean settings and whether addon packages are enabled; it does not currently display the addon requirements path or its origin. Secret values are never included in provenance output.

## Persistent software and addons

The containers are replaceable; durable software and tool state use the `hermes-home` or `hermes-workspace` PVC according to ownership. The supported model has explicit layers:

- **Python addons** are declared by the selected profile's `requirements.txt` or `HERMES_ADDON_REQUIREMENTS` and installed into a uv-managed environment under `/opt/data/addon-venv`.
- **Node.js, npm, and npx** are baseline infrastructure in every profile. WebUI receives an installer-managed, content-addressed Node/npm/npx runtime under `/opt/data/node`; `/opt/data/.npm` persists npm/npx cache data.
- **Project dependencies** may live under `/workspace`, but the installer does not treat a project `node_modules` or virtual environment as a shared managed runtime.
- **Native OS packages and libraries** belong in a custom container image. Installing them interactively inside a running container is not persistent.

Installing software does not automatically make it an Agent capability. Reusable CLI or library workflows normally also need a skill, native Hermes tool, MCP server, or plugin that defines when and how Hermes should invoke the software. A bootstrap profile composes the dependency layer and the selected skills.

Persistence does not mean every path is immutable: installer-managed runtimes are validated, repaired, updated, or rebuilt from declarative inputs and trusted images. See [Persistent software and addon architecture](docs/persistent-software.md) for ownership, paths, consumers, skill/tool integration, upgrade behavior, backup boundaries, and supported installation methods.

## Documentation

| Guide | Purpose |
|---|---|
| [`docs/operations.md`](docs/operations.md) | Installation lifecycle, maintenance, upgrades, operator-owned Velero recovery, credentials, bootstrap behavior, and persistent tooling |
| [`docs/persistent-software.md`](docs/persistent-software.md) | Persistent Python addons, Node/npm/npx runtime, caches, project dependencies, custom-image boundary, upgrades, and backup behavior |
| [`docs/security.md`](docs/security.md) | Secrets, authentication, TLS, container security, Browserless/CDP controls, and backup protection |
| [`docs/sso-integration.md`](docs/sso-integration.md) | Native SSO with standalone kube.authelia_setup, exact callbacks, supported settings, and compatibility gates |
| [`docs/qa.md`](docs/qa.md) | Required local, render, cluster, reinstall, maintenance, credential, and runtime acceptance checks |
| [`docs/troubleshooting.md`](docs/troubleshooting.md) | Common deployment, PVC, ingress, WebUI, Browserless, Dashboard, and authentication failures |
| [`docs/pvc-and-containers.md`](docs/pvc-and-containers.md) | PVC layout, container mounts, environment variables, and persistence boundaries |
| [`docs/codex-auth.md`](docs/codex-auth.md) | OpenAI Codex OAuth pairing and persistence |
| [`docs/mcp.md`](docs/mcp.md) | MCP server configurations and setup instructions shared with Hermes users and agents |
| [`docs/ansible.md`](docs/ansible.md) | Persistent Ansible environment, SSH integration, roles, and collections |

Additional references:

- [`CHANGELOG.md`](CHANGELOG.md) — release history
- [`AGENTS.md`](AGENTS.md) — maintainer and validation guidance

## Main commands

| Command | Purpose |
|---|---|
| `./configure.sh` | Create or intentionally regenerate local configuration |
| `./install.sh` | Validate, render, apply, and verify the stack |
| `./maintain.sh` | Inspect and maintain an installation |
| `./doctor.sh` | Run deployment diagnostics |

## Acknowledgements

- **[Chris Rüttimann (`joe-speedboat`)](https://github.com/joe-speedboat)** — project maintainer
- **[Nicolas Eberle (`archham`)](https://github.com/archham)** — operational ideas, use cases, and reusable-skill inspiration
- **[Hermes Agent (`hermes-speedboat`)](https://github.com/hermes-speedboat)** — automation identity represented in repository history

## License

MIT. See [LICENCE](LICENCE).
