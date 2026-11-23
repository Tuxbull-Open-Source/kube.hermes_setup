# Host-supervised maintenance

The 2.8.0 candidate adds this workflow; see the [release notes](../CHANGELOG.md#v280---unreleased)
and [2.7.8/2.7.9 migration steps](../README.md#existing-installations-maintenance-and-upgrade).
The feature is merged into `main`, but is not a published release. `maintain.sh` remains canonical;
`maintenance.sh` is its compatibility launcher, not a second implementation.
The old `upgrade` command merely restarted existing images; it did not update the
installer or image pins. It now fails closed without a validated checkout binding
and prepared plan. `restart` remains a separate legacy operation.

## Operator interface

```bash
./maintenance.sh --help
./maintenance.sh status
./maintenance.sh plan --latest-stable
./maintenance.sh logs PLAN_ID
# Downtime: cold backup followed by installer rollout, independently of this shell.
./maintenance.sh upgrade PLAN_ID
```

Use the exact plan ID printed by `plan`, not the example above. `render` is an
alias for preparation without cluster writes. Both commands create protected host
artifacts; they are not filesystem-read-only. `status` and `logs` are read-only.
One checkout owns exactly one namespace. Its existing root `hermes.env` or
wizard-generated `current_config/hermes.env` is authoritative. Host maintenance
requires exactly one of these files and explicit namespace/authentication settings.
It does not accept a namespace selector or environment-file override. If the source
says `hermes` but the protected target differs, it fails before cluster writes;
there is no automatic discovery or fallback to another namespace. Reconcile the
existing configuration with operator approval, including persistent wizard answers
where applicable, rather than adding a second configuration mechanism. Do not
attribute a mismatch to a person without evidence.

Host commands are `status`, `plan [--latest-stable]`, `render [--latest-stable]`,
`upgrade PLAN`, and `logs PLAN`. There are no `--execute`, `--dry-run`, `--force`,
or automatic-rollback flags. Do not prefix the checkout launcher with sudo: it
calls the fixed installed helper through existing sudo rights. Existing explicit
credential operations remain separate from upgrades.

## Administrator provisioning and trust boundary

Install **reviewed committed code**, not symlinks into a user-writable checkout.
Before target-file changes: check free space (at least 10% reserve), archive
existing files under root-only `/srv/backup`, and record scope in `/CHANGES.md`.
Do not automatically pull, reset, or switch a user's dirty working tree.

Export the reviewed commit using `git archive COMMIT`, inspect the archive, and
install it under a new root-owned `/usr/local/lib/hermes-maintenance/COMMIT/`.
The helper dynamically imports the source snapshot's `scripts/stable_images.py`
and the configured recovery backend as privileged Python code. They are trusted
administrator-reviewed code, not sandboxed plugins; ownership checks are not a
code audit. The separately installed helper itself must also be reviewed and kept
consistent with that source revision. All parents and files must be root-owned
and not group/other writable; reject
symlinks. Install `scripts/host_maintenance.py` as a regular root-owned executable
`/usr/local/libexec/hermes-maintenance.py`. Required host tools: Python 3 with
PyYAML, Bash, kubectl, systemd, and the existing operator recovery backend.
No pip/npm changes inside application containers are involved.

Create a root-only internal binding named `checkout-SHA256_PREFIX.json` under
`/etc/hermes-maintenance/`, where SHA256_PREFIX is the first 24 hex characters of
the canonical checkout path SHA-256. This deterministic name is not a selectable
profile. Bind that checkout and its sole configuration file explicitly:

```json
{
  "checkout": "/home/operator/git/kube.hermes_setup",
  "config_path": "/home/operator/git/kube.hermes_setup/current_config/hermes.env",
  "namespace": "assistant",
  "cluster_uid": "REPLACE_WITH_KUBE_SYSTEM_NAMESPACE_UID",
  "namespace_uid": "REPLACE_FROM_READ_ONLY_CLUSTER_INVENTORY",
  "pvc_uids": {
    "hermes-home": "REPLACE_FROM_READ_ONLY_CLUSTER_INVENTORY",
    "hermes-workspace": "REPLACE_FROM_READ_ONLY_CLUSTER_INVENTORY"
  },
  "source": "/usr/local/lib/hermes-maintenance/REVIEWED_COMMIT",
  "source_revision": "REVIEWED_COMMIT",
  "env_file": "/etc/hermes-maintenance/assistant.env",
  "kubeconfig": "/etc/rancher/k3s/k3s.yaml",
  "protected_namespaces": [],
  "recovery_backend": "/usr/local/libexec/operator-velero.py"
}
```

Keep an exact reviewed snapshot of the checkout environment on the host, mode
0600. Every command compares it with the source configuration as data, never
executes operator-writable code. Configuration changes invalidate prepared plans.
Reconcile it against live
OIDC references, UID/GID, resources, PVC sizes/storage class, and enabled components.
Use `HERMES_BOOTSTRAP_MODE=disabled`, empty `HERMES_ADDON_REQUIREMENTS`, and exact
image tags plus digests. Do not copy credentials into Git or an agent workspace.
An installer-source change requires a new reviewed root snapshot and binding;
a subsequent plan seals all source files by SHA-256. No detached job executes
from the operator's checkout, and no new sudo rule is installed.

## Preparation and execution

`plan --latest-stable` queries each publisher's official GitHub stable release
metadata and verifies the registry manifest bytes against their digest. It rejects
prereleases and non-semantic/experimental tags, and records exact targets. Plain
`plan` verifies the configuration's selected release tags and registry digests instead.
A stable release is not a compatibility qualification. Do not chase a moving latest
tag during an already approved transaction. Agent/Dashboard share the Agent image;
Node/browser-controller updates follow that image's installer-managed preparation,
not ad-hoc package upgrades in live PVCs. A newer Node release alone does not make
this image bundle current at every embedded package level.

Preparation renders using the installer's library path, without applying. It
compares namespace/PVC identities, authentication environment, volume mounts,
security context, resource settings and PVC contracts. A mismatch blocks rather
than silently adopting defaults or shrinking claims. The plan seals source,
configuration and rendered manifest. Execute only the reviewed plan ID. Drift
requires a new plan, not an override flag. Raw logs and configuration stay under
`/srv/backup/hermes-maintenance/`; normal output is concise YAML.

Upgrade runs a host systemd service and shares the recovery backend's operation
lock. It takes a fresh cold backup, validates eligibility, retains exact backup
and original replica/PVC metadata, invokes the pinned installer, and checks image,
Secret and identity preservation. Failures retain evidence and do not automatically
roll back data or repeat installation. `logs PLAN` shows durable phase, backup and
unit handles. A completed rollout still requires application acceptance: login,
API, browser/CDP, user configuration and logical-data preservation. The tool does
not claim those checks merely from Ready Pods.

## Retained bootstrap archives

An existing `hermes-bootstrap-archive` is a normal result of installation, not
permission to replay old settings or replace installed addons during an image
upgrade. Do not delete this Secret merely to make planning pass.

The coordinator seals `HERMES_MAINTENANCE_UPGRADE=true` into its candidate env.
This is an internal installer mode, not a new target selector or a substitute
for checkout enrollment. It requires disabled bootstrap and empty addon
requirements. It suppresses archive generation even when Ansible is enabled,
leaves the Kubernetes Secret untouched, and prevents the init job from extracting
or consuming the retained archive. Runtime SSH/Ansible settings remain unchanged.
Normal installation and deliberate bootstrap reconfiguration retain their existing
behavior outside maintenance mode.

Plans report whether an archive is retained or absent, without displaying its
contents. Existing sealed-plan checks reject live Secret-data drift before
execution; post-install checks require preservation. These checks do not grant
permission to rotate or delete archives. Cold backups and operator-controlled
recovery remain mandatory parts of the host workflow.

Regression commands:

```bash
python3 tests/maintenance-bootstrap.py
# Disposable cluster ONLY. Seed using the baseline installer, then install the
# candidate source revision before verify. Synthetic data; never production PVCs.
python3 tests/maintenance-bootstrap-live.py seed --allow-disposable-cluster
python3 tests/maintenance-bootstrap-live.py verify --allow-disposable-cluster
```

The live fixture checks full-stack readiness, Secret UID/resourceVersion/data,
PVC identities, a customized bootstrap marker, and a second unchanged installer
run. It is not a full Velero-backed coordinator upgrade or browser-login test.
See [the recorded qualification and limitations](qa-bootstrap-retention.md).

## Recovery ownership

Recovery remains operator-owned Velero; this repository does not install Velero,
change its retention, or reintroduce an archive/restore subsystem. The administrator
selects the already reviewed root-owned Python backend implementing `ROOT`,
`backup(namespace, folder) -> (name, metadata)`, `eligible(name, namespace)`, and
`diagnostics(namespace, folder)`. It must expose its kubectl and Velero argv as
`K` and `V`, each containing one explicit `--kubeconfig PATH`; the coordinator binds
both to the binding's protected kubeconfig. If the cluster's usual configuration
has operator-writable parent directories, provision a reviewed root-only credential
snapshot instead; do not loosen that directory or add executable auth plugins.
`ROOT/operation.lock` must be the same lock used
by its public recovery CLI. Eligibility must require a sealed, unexpired, clean
completed cold backup with both PVC identities and completed volume records.
Cold-backup cleanup must remove the helper and resume the saved replica map,
including on failure. Failed resume metadata must remain available to the operator.
Never substitute scheduled namespace selection for demonstrated volume coverage.

Use that backend's `list-backups`, `backup`, and `restore EXACT_NAME
--accept-data-loss` interface. Do not stack extra execute/confirmation flags on
restore. Restoration can replace namespace/PVC identities and discard subsequent
writes; re-enroll identities only after independently verifying recovery. Backup
selection is by exact name, not newest/second-newest ordering. Do not call `verify`
without inspecting its documented storage/downtime effects.

## Proportionate qualification and isolated rehearsal

Routine same-stream patches need release review, contract checks and targeted
runtime acceptance. A full data clone is **not** imposed on every patch. Perform
recovery drills after Velero upgrades, at the operator's cadence, on migration
risk, or when explicitly requested. The repository's live QA requirements still
apply to changes in installer behavior; unavailable gates must be reported blocked.

For an authorized real-data rehearsal, first budget actual allocated bytes and
backup bytes plus image/migration overhead and the 10% reserve. Establish default
deny in a fresh test namespace and prove ingress/egress denial repeatedly with
reachable positive controls **before** restoring any data. Restore both PVCs from
one eligible coherent backup via Velero namespace mapping. Never mount production
claims into a rehearsal. Quarantine copied tokens, SSH, environment/configuration,
cron, plugins, hooks and gateway integrations before starting applications. Use
synthetic credentials and no production OIDC Secrets or ingress.

`HERMES_ISOLATED_TEST=true` is an installer rendering option restricted to dedicated
`hermes-test-*` (or existing recovery-backend test-prefix) namespaces. It omits
Ingress, Middleware and vendor NetworkPolicies and sets WebUI `UV_OFFLINE=true`.
Before any cluster mutation, a read-only preflight rejects existing Ingresses,
Traefik Middleware/routes (both supported Traefik API groups), and NetworkPolicies
whose names occur in the **unfiltered rendered manifest**, regardless of their
spec. It refuses rather than deleting or pruning. Missing optional Traefik APIs
are determined by successful discovery; permission errors, timeouts, unexpected
responses and failed discovery/list requests stop installation. A nonexistent
namespace may proceed to fresh creation. Do not race other writers against this
preflight: it is not an atomic admission policy.

Unrelated operator-managed policies are left unchanged; their names do not prove
that they deny traffic. This limited managed-exposure guard is **not** a complete
inventory of every controller/route type or proof of ingress/egress isolation:
Kubernetes NetworkPolicies are additive, so an unrelated allow policy can defeat
a default-deny policy. The operator must inspect all policies/routes and prove
the actual boundary with network probes before restoring data.
It does **not** establish or prove isolation itself. The operator must manage the
default-deny and same-namespace-only policy independently. Prestage dependencies
from clean credential-free images and prove offline startup before the expensive
restore. Then test old health -> final maintenance upgrade -> new health, auth/API,
browser and preserved logical data. Backups reflect backup time, not newer writes.
Retain backup/evidence; remove only recorded fixture namespace/PVC/PV paths after
acceptance. A manual earlier rollout does not validate a later script revision.
