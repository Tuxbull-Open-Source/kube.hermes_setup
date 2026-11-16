# kube.hermes_setup

> [!WARNING]
> **Proof of concept — lab and agent experimentation only. Never use in production environments.**
> This project is intended for rapid deployment and evaluation of setups, not as a turnkey production platform. Upgrading an existing, customized Hermes Agent installation can require substantial experience with Kubernetes and Hermes Agent. Do not use this project unless you are willing to learn how the underlying system works.

Lab-oriented Kubernetes/K3s installer for a [Hermes Agent](https://github.com/nousresearch/hermes-agent) stack:

- **Hermes Agent** — mandatory API/gateway runtime
- **Hermes Dashboard** — optional administrative dashboard
- **Hermes WebUI** — optional browser chat interface
- **Browserless Chromium** — optional internal browser/CDP backend

The repository is template-driven. Deployment-specific configuration, credentials, OAuth state, kubeconfigs, rendered artifacts, and backups must remain outside Git.

**Installer candidate: 2.8.0** (see [`VERSION`](VERSION) and the
[release notes](CHANGELOG.md#v280---unreleased)). PR #127 is still under review;
this is not a published release. Installer versions are separate from application
image versions, and updating this checkout does not upgrade a running instance.

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
git clone https://github.com/Tuxbull-Open-Source/kube.hermes_setup.git
cd kube.hermes_setup
./configure.sh --no-install
```

The configurator writes Git-ignored deployment files under `current_config/`. Review them before installation. Use [`examples/hermes.env.example`](examples/hermes.env.example) as the complete configuration-variable reference.

For production use, read the security, operations, and QA guides before continuing:

```bash
./install.sh
./doctor.sh
```

## Existing installations: maintenance and upgrade

For an existing 2.7.8 or 2.7.9 installation, **do not rerun the wizard** to adopt
this feature. Retain the private configuration and recovery tools. The canonical
implementation is `maintain.sh`; the literal `maintenance.sh` is its compatibility
launcher. Bare `upgrade` now refuses to act instead of merely restarting images.

To review the **unmerged 2.8.0 candidate**, use a separate checkout (choose an
unused directory); pulling `main` does not obtain this PR:

```bash
git clone --branch feat/explicit-maintenance-upgrade --single-branch \
  https://github.com/Tuxbull-Open-Source/kube.hermes_setup.git kube.hermes_setup-review
cd kube.hermes_setup-review
git log -1 --oneline
./maintenance.sh --help
```

Review the exact PR head before provisioning it. This only obtains source and
shows help: it installs no host helper and changes no cluster resources. After
merge/release, use the maintainer-approved revision instead of assuming this
review branch is a published tag.

An administrator must first provision the [root-owned helper, source snapshot,
checkout binding and existing recovery backend](docs/host-maintenance.md#administrator-provisioning-and-trust-boundary).
Then run as the ordinary operator with existing sudo rights, on that host:

```bash
./maintenance.sh status
./maintenance.sh plan --latest-stable
# Review exact image digests, source revision and compatibility before continuing.
# Replace PLAN_ID with the full checkout-bound ID returned above.
./maintenance.sh logs PLAN_ID
# Explicit maintenance window: cold backup and rollout cause downtime.
./maintenance.sh upgrade PLAN_ID
./maintenance.sh logs PLAN_ID
./maintenance.sh status
```

`status` reports resource availability, not application acceptance. `logs` reports
durable phase, backup, systemd unit and protected log location; it is not a log-tail
command. The host service survives loss of the terminal or Agent session, **not**
loss of the host. A launch result means started, not completed.

One checkout manages exactly one namespace from its existing `hermes.env` or
`current_config/hermes.env`. Host maintenance rejects missing or ambiguous files
and any mismatch with the protected snapshot. It never discovers another namespace
or bypasses an incorrect `hermes` default. Correct the existing configuration after
review; do not introduce a selector or alternate maintenance profile. The internal
root-owned binding seals namespace/PVC identities, authentication, configuration,
protected kubeconfig and reviewed source. No new sudoers rule is needed.

`plan` (or `render`) creates protected host artifacts without cluster writes.
`--latest-stable` resolves publisher releases and registry digests **at preparation**;
plain `plan` verifies configured pins. Neither changes running versions nor proves
compatibility. Execute the exact reviewed sealed plan; source/configuration/live
state drift requires a new plan. The helper imports privileged resolver/recovery
Python code from reviewed root-owned paths; these are trusted code, not sandboxed
plugins. See [architecture and trust boundaries](docs/host-maintenance.md).

**Recovery warning:** upgrade uses a fresh eligible operator-owned Velero cold
backup. There is no automatic rollback, data rewind, or blind retry after failure.
An image downgrade alone does not undo data migrations. Inspect protected evidence
and the exact backup before an operator-authorized restore; restoring can discard
later writes. Legacy `backup`, `restore`, and `extract` are no longer provided by
this installer; keep historical tools/archives under the operator retention policy.

The [2.8.0 qualification record](CHANGELOG.md#v280---unreleased) distinguishes the
runtime-tested frozen bundle from newer prepared-only targets. Perform application
login, API, browser/CDP and logical-data acceptance after rollout; Ready Pods alone
are insufficient.

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
| [`docs/host-maintenance.md`](docs/host-maintenance.md) | Explicit instance enrollment, sealed stable-image plans, privileged host service, logs and recovery boundaries |
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
| `./maintain.sh` | Canonical maintenance implementation; checkout-bound upgrades or legacy ENV_FILE operations |
| `./maintenance.sh --help` | Compatibility launcher: host status, plan/render, upgrade PLAN, logs PLAN |
| `./doctor.sh` | Run deployment diagnostics |

## Acknowledgements

- **[Chris Rüttimann (`joe-speedboat`)](https://github.com/joe-speedboat)** — project maintainer
- **[Nicolas Eberle (`archham`)](https://github.com/archham)** — operational ideas, use cases, and reusable-skill inspiration
- **[Hermes Agent (`hermes-speedboat`)](https://github.com/hermes-speedboat)** — automation identity represented in repository history

## License

MIT. See [LICENCE](LICENCE).
