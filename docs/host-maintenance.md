# Host-supervised maintenance

`maintenance.sh` is the stable spelling of `maintain.sh`, not a second implementation.
The old `upgrade` command merely restarted existing images; it did not update the
installer or image pins. It now fails closed without an explicitly selected host
instance and prepared plan. `restart` remains a separate legacy operation.

## Operator interface

```bash
./maintenance.sh --instance assistant status
./maintenance.sh --instance assistant plan --latest-stable
./maintenance.sh --instance assistant logs assistant-PLAN_ID
# Downtime: cold backup followed by installer rollout, independently of this shell.
./maintenance.sh --instance assistant upgrade assistant-PLAN_ID
```

Use the exact plan ID printed by `plan`, not the example above. `render` is an
alias for preparation without cluster writes. Both commands create protected host
artifacts; they are not filesystem-read-only. `status` and `logs` are read-only.
No arguments display help. To save only an instance name in an operator checkout:

```bash
(umask 077; printf '%s\n' assistant > .maintenance-instance)
./maintenance.sh status
```

The selected profile bypasses unrelated `current_config/hermes.env` defaults.
It never rewrites that wizard configuration. A checkout whose default namespace
is `hermes` with `local-password` cannot infer a different instance's OIDC setup.
This is a selection problem, not grounds to change ownership, sudoers, or passwords.
Do not prefix the checkout launcher with sudo: it calls the fixed installed helper
through existing sudo rights. Credential rotation remains an explicit `ENV_FILE`
legacy operation, from a checkout without a saved host instance.

## Administrator provisioning and trust boundary

Install **reviewed committed code**, not symlinks into a user-writable checkout.
Before target-file changes: check free space (at least 10% reserve), archive
existing files under root-only `/srv/backup`, and record scope in `/CHANGES.md`.
Do not automatically pull, reset, or switch a user's dirty working tree.

Export the reviewed commit using `git archive COMMIT`, inspect the archive, and
install it under a new root-owned `/usr/local/lib/hermes-maintenance/COMMIT/`.
All parents and files must be root-owned and not group/other writable; reject
symlinks. Install `scripts/host_maintenance.py` as a regular root-owned executable
`/usr/local/libexec/hermes-maintenance.py`. Required host tools: Python 3 with
PyYAML, Bash, kubectl, systemd, and the existing operator recovery backend.
No pip/npm changes inside application containers are involved.

Create root-only `/etc/hermes-maintenance/assistant.json` with explicit values:

```json
{
  "namespace": "assistant",
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

Keep the instance environment on the host, mode 0600. Reconcile it against live
OIDC references, UID/GID, resources, PVC sizes/storage class, and enabled components.
Use `HERMES_BOOTSTRAP_MODE=disabled`, empty `HERMES_ADDON_REQUIREMENTS`, and exact
image tags plus digests. Do not copy credentials into Git or an agent workspace.
An installer-source change requires a new reviewed root snapshot and profile;
a subsequent plan seals all source files by SHA-256. No detached job executes
from the operator's checkout, and no new sudo rule is installed.

## Preparation and execution

`plan --latest-stable` queries each publisher's official GitHub stable release
metadata and verifies the registry manifest bytes against their digest. It rejects
prereleases and non-semantic/experimental tags, and records exact targets. Plain
`plan` verifies the profile's selected release tags and registry digests instead.
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

## Recovery ownership

Recovery remains operator-owned Velero; this repository does not install Velero,
change its retention, or reintroduce an archive/restore subsystem. The administrator
selects the already reviewed root-owned Python backend implementing `ROOT`,
`backup(namespace, folder) -> (name, metadata)`, `eligible(name, namespace)`, and
`diagnostics(namespace, folder)`. It must expose its kubectl and Velero argv as
`K` and `V`, each containing one explicit `--kubeconfig PATH`; the coordinator binds
both to the profile's protected kubeconfig. If the cluster's usual configuration
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
It does **not** establish or prove isolation itself. The operator must manage the
default-deny and same-namespace-only policy independently. Prestage dependencies
from clean credential-free images and prove offline startup before the expensive
restore. Then test old health -> final maintenance upgrade -> new health, auth/API,
browser and preserved logical data. Backups reflect backup time, not newer writes.
Retain backup/evidence; remove only recorded fixture namespace/PVC/PV paths after
acceptance. A manual earlier rollout does not validate a later script revision.
