# Repository-owned host maintenance and recovery

The 2.9.0 candidate keeps **all project-specific execution code in this repository**.
`maintain.sh` is canonical; `maintenance.sh` is its compatibility launcher.
There is no configurable external Python recovery backend. Root-protected installed
copies are built from an explicitly reviewed commit, not maintained separately.

## Prerequisites and boundaries

- Existing Kubernetes and Velero with a version-pinned stable 1.18+ server,
  Kopia node-agent, a writable Available BackupStorageLocation and dynamic
  filesystem PVC provisioning. This repository does not install or upgrade Velero,
  provision buckets, manage storage credentials or change existing schedules.
- Host kubectl, Velero CLI, Python 3.9+ with PyYAML, Bash, systemd, sudo, Git and
  standard Linux utilities. The recovery helper Pod uses BusyBox 1.37.0; it never
  starts application entrypoints or mounts a ServiceAccount token.
- An independent host must remain available while the application is stopped.
  Use existing sudo rights; no sudo policy is installed or relaxed.
- One checkout owns exactly one namespace, through exactly one `hermes.env` at
  the checkout root OR `current_config/hermes.env`. No `--instance`, namespace
  selector or host-maintenance `ENV_FILE` override is accepted.
- Stop concurrent GitOps/administrator reconciliation for a mutating operation.
  Native operations share a lock; direct third-party cluster writes cannot be
  serialized by a local host lock.

The repository supports the Hermes `hermes-home` and `hermes-workspace` filesystem
claims and Deployment-managed workloads. Unsupported controllers, active Jobs,
unmanaged live Pods, identity changes or incomplete volume coverage fail closed.
Provider namespaces such as Authelia need their own coverage.

## Private configuration, not Git content

Keep namespace, URLs, image pins, storage choices, answers, credentials, bindings,
rendered resources, plans, diagnostics and recovery metadata OUT of Git. The
existing private configuration must include:

```dotenv
HERMES_NAMESPACE=assistant
HERMES_AUTH_MODE=external-oidc
HERMES_BOOTSTRAP_MODE=disabled
HERMES_ADDON_REQUIREMENTS=
HERMES_VELERO_NAMESPACE=velero
HERMES_VELERO_STORAGE_LOCATION=YOUR_EXISTING_BACKUP_STORAGE_LOCATION
HERMES_VELERO_BACKUP_TTL=720h
KUBECONFIG=/protected/existing/kubeconfig
```

Use the real reviewed authentication settings, all three exact image tags plus
SHA256 digests, component choices, PVC sizes, resources and runtime UID/GID. The
example is not a complete install configuration. The kubeconfig must already be
a regular root-owned file beneath protected parents. Provisioning records its
location; it never opens, prints, hashes or copies its contents.

The configurator preserves the three Velero settings from saved answers or its
process environment; initial deployment may leave the storage location empty,
but maintenance enrollment refuses to guess it. Normal generated credentials
remain in Kubernetes Secrets. A protected env snapshot is internal execution
state, not a second user-selectable target.

`.gitignore` excludes known private artifacts, and
`python3 tests/private-artifact-boundary.py` checks both ignore coverage and the
tracked tree. CI runs the guard. These controls supplement review; they do not
make arbitrary secrets pasted into a source file safe. Never force-add private data.

## Administrator provisioning and trust boundary

A privileged process must not import or execute operator-writable checkout code.
The initial trust decision is therefore explicit and administrator-owned; it is
not hidden in an automatic download or a sudo of the checkout launcher.

1. Review a clean committed revision. As the operator, export it with
   `git --no-replace-objects archive --format=tar --output=current_config/source.tar COMMIT`.
   Use the full commit ID, not a moving branch. An administrator independently
   reviews provenance/content and copies the archive to a root-only staging path.
2. For first bootstrap only, independently review the repository's
   `scripts/provision_host.py` and install that exact file as the regular root-owned
   executable `/usr/local/libexec/hermes-provision-host.py`. Protect every parent.
   Check space, back up a replaced helper under `/srv/backup`, and audit this
   initial installation in `/CHANGES.md`. Do not execute checkout Python as root.
3. Stage the reviewed archive with the **installed repository provisioner**:

   ```bash
   sudo /usr/local/libexec/hermes-provision-host.py \
     --stage-archive /root/reviewed/source.tar \
     --archive-sha256 REVIEWED_ARCHIVE_SHA256 \
     --revision FULL_REVIEWED_COMMIT
   ```

   The digest is an administrator attestation, not a signature. Staging validates
   the Git archive commit marker, digest, safe member types/paths and content
   hashes. Source snapshots under `/usr/local/lib/hermes-maintenance/COMMIT` are
   immutable; links, special files, duplicate members and overwrite are rejected.
4. As the normal checkout operator, enroll each configured checkout:

   ```bash
   ./provision-host.sh --revision FULL_REVIEWED_COMMIT
   # Only when no KUBECONFIG is set in the authoritative private configuration:
   ./provision-host.sh --revision FULL_REVIEWED_COMMIT --kubeconfig /protected/existing/kubeconfig
   ./maintenance.sh status
   ./maintenance.sh list-backups
   ```

Enrollment queries cluster/namespace/PVC identities read-only. It creates a
version-2 protected binding and env snapshot under `/etc/hermes-maintenance`,
installs both repository helpers, and creates private recovery state. It backs
up replaced control files, checks the ten-percent disk reserve, audits changes,
verifies readback, preserves unrelated bindings and refuses active operations.
It never changes application resources or sudoers. Reenrollment cannot silently
retarget an existing checkout to a different namespace or cluster.

A provision lock excludes helper replacement while native commands run; backup,
restore and upgrade also share the same recovery operation lock. Snapshot imports
disable bytecode writes so reviewed source receipts remain valid. The installed
maintenance helper must match its enrolled source exactly.

For subsequent source updates, stage a newly reviewed commit and reenroll the
checkouts. Enrollment updates the provisioner itself from that same snapshot.
Do not hand-edit installed helpers or execute an old prepared plan after changing
code/configuration. Legacy external-backend bindings are preserved as data but
rejected by the new workflow until reenrolled; old independent recovery entrypoints
are neither deleted nor rewritten automatically.

## Operator commands

Run as the normal operator in the intended checkout, without prefixing the
user-writable launcher with sudo:

```bash
./maintenance.sh --help
./maintenance.sh status
./maintenance.sh list-backups
./maintenance.sh plan --latest-stable
./maintenance.sh logs PLAN_ID
./maintenance.sh upgrade PLAN_ID
./maintenance.sh backup
./maintenance.sh logs OPERATION_ID
./maintenance.sh restore EXACT_BACKUP_NAME --accept-data-loss
```

Use the actual IDs printed by the command. `status`, `list-backups` and `logs`
are read-only. `plan`/`render` perform read-only cluster checks but write protected
host artifacts. `backup`, `restore` and `upgrade` launch independent systemd
services and return **started, not completed**. Inspect durable phase and volume
progress with `logs`. No-argument launchers display help. No implicit restore,
force override or stacked execution confirmations exist.

### Upgrade

Preparation validates recovery prerequisites before producing a plan, verifies
publisher release tags/registry manifest digests, renders without applying and
compares protected runtime/PVC/authentication contracts. `--latest-stable` rejects
prereleases; plain `plan` verifies the configured pins. A stable label is not
application compatibility evidence. Review the release and execute only the
frozen plan; source/config/resource drift requires a new plan.

The worker takes a cold two-PVC Velero backup, checks eligibility, runs the pinned
installer, and verifies image/Secret/identity preservation. After a verified
rollout it publishes exact resulting image pins to the existing private config
and its protected snapshot, preserving other settings and ownership. Concurrent
operator edits cause a failure, not an overwrite. Private pre-update copies are
retained. The next configured plan therefore does not silently select old images.

A completed rollout still needs application acceptance: login, authenticated API,
browser/CDP, logical data, profiles and required tools. Failure does not automatically
roll back data or replay installation. Phase output distinguishes an applied
rollout with failed post-checks from a pre-install failure.

### Cold backup and listing

The backend freezes the recorded replica map, waits for writers to terminate,
mounts both claims read-only in a credential-free helper, captures sampled hashes
and creates a namespace-scoped Velero FSB backup. It requires exactly two Completed
Kopia records with matching helper/PVC identities and checks that the cold samples
did not change. It removes the helper and resumes the original replicas even on
failure. A completion seal is added only after successful resume. If helper
absence or safe resume cannot be established, writers remain stopped and private
recovery metadata identifies the interrupted operation.

The listing distinguishes namespace selection, completed filesystem volume records
and eligibility for this repository's recovery protocol. Cluster-wide/scheduled
backups may select the namespace without being eligible. Unsealed, incomplete,
expired, foreign-instance or incompatible legacy backups are never silently
adopted. Listings do not claim application-level restore testing.

### Restore and recovery limits

`restore EXACT_BACKUP_NAME --accept-data-loss` is destructive and loses writes
since that recovery point. It first validates the exact name, captures diagnostics
and creates a fresh eligible safety backup. It then stops writers, deletes the
bound namespace, restores namespaced resources with Deployment replicas at zero,
excludes source PV manifests and uses Velero resource modifiers for fresh dynamic
PVC binding. PVR coverage, new identities and sampled hash/mode/owner equality
must pass before application replicas resume. No automatic destructive retry occurs.

The **backup** includes only the selected Namespace as a cluster-scoped resource,
plus that namespace's resources; source PV manifests are explicitly excluded.
Its downloaded native metadata archive is checked privately for foreign resources
and for the original Namespace identity, labels and annotations. The **restore**
must still allow the PV and PVC resource types. Velero gates FSB/PVR creation on
those filters and can
otherwise report a Completed resource restore with no volume restores. The exact
PVR coverage gate must not be weakened. See the upstream
[restore implementation](https://github.com/vmware-tanzu/velero/blob/v1.18.0/pkg/restore/restore.go).

Kopia samples are not a complete logical-data or application-recovery proof.
On a failure after deletion, preserve the safety backup and private stage records;
do not run the operation again blindly. Never delete retained backups just to
make a gate pass. Use normal Velero backup deletion, not direct CR/object deletion.

Successful restore reconciles image pins with the restored deployments and reports
new namespace/PVC identities. Verify the application and any non-image host
configuration, then explicitly reenroll the same checkout. A backup remains tied
to its original cluster, namespace and checkout lineage; it is not made foreign
merely because a successful restore replaced its PVC IDs. Arbitrary cross-cluster
migration or automatic namespace remapping is not offered by this operator CLI.

## Retained bootstrap archives

Maintenance seals `HERMES_MAINTENANCE_UPGRADE=true` internally with disabled
bootstrap and empty addon requirements. It neither creates, deletes nor replays
the existing bootstrap archive, even with Ansible enabled. Runtime SSH/Ansible
settings remain unchanged. Normal installation/bootstrap reconfiguration is a
separate explicit operation. Never delete a retained Secret to bypass planning.
See [bootstrap regression evidence](qa-bootstrap-retention.md) for the earlier
installer-only test and its limitations.

## Qualification and isolated rehearsal

Routine application patches need release review and targeted acceptance; they do
not automatically require a full data clone. New recovery machinery requires a
real disposable backup/restore test, not just mocked tests. Verify the exact final
repository entrypoints as the normal operator, including failure handling and an
unchanged second run. Distinguish code tests, live resource health, restored data
and human acceptance in the report.

For any actual-data rehearsal, budget both PVCs plus overhead and reserve. Prove
network denial with reachable positive controls before restoring credentials.
Never mount production PVCs read-write in a test environment. Quarantine copied
credentials, cron, plugins, hooks and outbound integrations before startup.
`HERMES_ISOLATED_TEST=true` omits managed ingress/policies and makes WebUI offline;
it does not establish isolation itself. Its preflight rejects existing managed
exposure, never prunes it. Prestage clean dependencies and prove offline startup
before restoring data. Synthetic tests may instead use normal online installation
on a separate disposable VM. Remove only recorded test resources after retaining
sanitized evidence; do not claim a manual earlier run validates later code.
