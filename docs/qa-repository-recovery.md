# Repository-owned recovery qualification

## Scope and tested revision

Executed the real operator entrypoints at commit
`cb90633652646081a9355f75530767995f6b932b` on a disposable Ubuntu 24.04 VM,
K3s `v1.36.4+k3s1`, Velero server `v1.18.0`, Kopia node-agent and a
fixture-only S3-compatible store. Production installations were not changed.
The fixture used synthetic data and generated fixture-only credentials, not a
production PVC clone. Private identifiers, configuration, logs and archives are
not published in this repository.

## Real execution

The ordinary non-root fixture operator invoked the actual repository launchers:

```bash
./provision-host.sh --revision REVIEWED_COMMIT
./maintenance.sh status
./maintenance.sh backup
./maintenance.sh list-backups
./maintenance.sh restore EXACT_ELIGIBLE_BACKUP --accept-data-loss
./provision-host.sh --revision REVIEWED_COMMIT
./maintenance.sh plan --latest-stable
./maintenance.sh upgrade EXACT_PREPARED_PLAN
./maintenance.sh logs EXACT_OPERATION
./maintenance.sh plan
```

Observed results:

- Reviewed archive staging and protected binding creation succeeded. Repeated
  identical enrollment succeeded without changing application resources.
- Concurrent enrollment during a native backup was rejected by the operation
  protections; no helper replacement occurred.
- A cold backup produced exactly two Completed Kopia PVBs and a successful-resume
  seal. Original replicas were restored and all four components were available.
- Synthetic SQLite and workspace values were changed **after** the selected
  backup. The final native restore first took a new safety backup, then created
  fresh namespace/PVC identities and completed both PVRs. The helper verified
  sampled hashes, modes and ownership before resuming applications.
- Namespace labels/annotations matched their backup-time contract. The original
  SQLite value and workspace content returned; `PRAGMA quick_check` returned `ok`.
- Explicit identity reenrollment succeeded after the namespace/PVC replacement.
- The native image upgrade took another eligible cold backup before installation.
  Its final phase was `rollout-complete; application acceptance required`.
- The actual upgrade path was Agent `0.23.1 -> 0.23.3`, WebUI
  `0.52.678 -> 0.52.732`, and Browserless `2.63.1 -> 2.64.3`, using verified
  publisher manifest digests for the prepared targets.
- After upgrade, all four Deployments had one available replica, authenticated
  Agent `/health/detailed` returned HTTP 200, and a real Browserless CDP
  `Browser.getVersion` call returned `Chrome/159.0.8154.6`.
- SQLite integrity and the restored synthetic values still passed after upgrade.
- A subsequent **configured** `plan` without `--latest-stable` selected those same
  upgraded pins. The successful upgrade therefore did not leave an implicit
  downgrade in the authoritative private configuration.

The final successful restore and upgrade used the repository's systemd workers;
there was no alternate backup job or manually substituted restore operation.
Failed disposable namespace instances were reset through explicit fixture cleanup
and the normal installer, rather than bypassing a failed recovery gate.

## Failures found and corrected

1. The first lab setup lacked Traefik Middleware CRDs. The normal installer stopped
   before application deployment. The disposable K3s prerequisites were corrected
   through the vendor installer; the application installer was not weakened.
2. The first coordinator progress reader passed nested rather than flat kubectl
   arguments. Progress and restore pin reconciliation now have real argument-
   contract regression tests.
3. Fixed sample filenames failed on a valid workspace without `AGENTS.md`.
   Sampling now chooses deterministic existing files without disclosing filenames
   or contents, handles no-regular-file cases and avoids following symlinks.
   The failed backup resumed all original replicas; no usable seal was claimed.
4. Excluding the PV resource type during Restore suppressed PVR creation although
   Velero reported Completed. The exact two-PVR gate caught it and kept application
   writers stopped. PV manifests are excluded during backup, but the Restore
   permits the PV/PVC types required by Velero's FSB implementation.
5. Cluster-resource omission lost Namespace metadata. The native backup now admits
   only the selected Namespace as a cluster-scoped resource, explicitly excludes
   other discovered cluster resources and privately checks the downloaded metadata
   archive for unexpected scope and the namespace contract.
6. Velero additional-item actions included a related Traefik CRD despite the
   inclusion list. Explicit cluster exclusions plus archive inspection caught and
   corrected this; arbitrary cluster objects are never accepted for restoration.
7. Velero automatically adds CSI snapshot exclusions when snapshots are disabled.
   Eligibility permits only these specific additional exclusions, not arbitrary
   exclusions such as Secrets.
8. Restore logs contain duplicate item warnings and endpoint annotation chatter
   not included in `status.warnings`. Classification now matches the controller's
   persisted warning result records, requires exact count agreement and permits
   only missing recorded source PV manifests and the known regenerated root-CA
   ConfigMap difference. Unknown warnings still fail closed.
9. Restoring older tag-only workloads must not replace already reviewed digest
   pins with unpinned values. Matching reviewed pins are retained, including
   Docker's implicit-registry alias; different legacy tags require explicit review.

The data gates caught incomplete/incorrect recovery before applications resumed.
A Velero Completed phase alone was never treated as proof of recovered data.

## Local regression evidence

The private-artifact boundary, provisioning, coordinator, Velero recovery,
bootstrap-retention, maintenance-contract, configuration/profile and component
matrix tests were exercised. These are mocked/local tests except for the live
steps explicitly listed above. CI runs the non-cluster contracts; it does not
claim to run this disposable-cluster rehearsal.

The first hosted CI run exposed a fixture precondition hidden by the local umask:
its restore operation directory had not been explicitly created with mode 0700.
The production coordinator already creates that private directory. The fixture now
models that contract explicitly, and a negative test still rejects mode 0755
without silently changing permissions. All contract suites are exercised with
both umask 022 and 077. This follow-up changes tests/CI/documentation, not the
operational scripts qualified by the live rehearsal.

## Limits and production acceptance

- This is synthetic same-cluster recovery, not a production restore drill,
  cross-cluster migration or complete disaster-recovery proof.
- Namespace/PVC identity and sampled data checks do not replace verification of
  actual user histories, sessions, provider authentication or inference.
- Production OIDC, private MCPs, external integrations and real provider
  credentials were not exercised in this disposable fixture.
- WebUI `0.52.732` release notes describe a provider-name/URL credential-pairing
  issue, context-meter limitations and non-persistent session approvals. Review
  applicability to the intended production configuration before deployment.
- Existing production backup coverage and restore freshness must be assessed
  separately. Deploying the new host workflow requires its own reviewed source
  staging/enrollment and an explicit production change authorization.

## Versioned controller isolation follow-up

At revision `75825d205a590ea77aceae1a0437ad2b004be2f2`, the disposable
operator launcher rejected an outdated installed provisioner before enrollment.
After administrator bootstrap of the reviewed provisioner, enrollment, status
and a native two-volume backup succeeded using the version-2 controller path.
The legacy controller's recorded SHA256 remained unchanged before enrollment,
after enrollment and after the completed backup. Unit tests additionally check
its inode, timestamp and permissions and preserve an unrelated legacy binding.
This follow-up changes controller placement/handshake, not the tested recovery
algorithm; it does not authorize changing existing production legacy controls.

## Failed-workload recovery release qualification

Executable revision `c8764ec9389efa1fe75f8abb4c0b5675fe70ab17` was exercised through
the ordinary operator entrypoint in the disposable fixture. A fresh normal cold
checkpoint completed with both filesystem volumes and its successful-resume seal.
After that point, only synthetic SQLite/workspace data was changed and the Agent
Deployment was assigned an unavailable image.

Native `restore EXACT_BACKUP --accept-data-loss` then captured a complete two-volume
safety-only checkpoint without attempting to start the failing current image. The
selected good checkpoint restored successfully, with both PVRs, restored image pins
and new identities. Actual SQLite integrity and the original logical row/workspace
marker were checked afterward, as were authenticated API HTTP 200 and a real
Chromium CDP request. Reenrollment succeeded and all four Deployments were ready.
Listing accepted the good checkpoint and rejected the completed, unsealed
safety-only checkpoint as a normal restore target.

This qualifies an unready application with its owned namespace, claims and keys
still present. It does not qualify missing/foreign namespace adoption, arbitrary
node loss, every historical recovery point or external provider/MCP behavior.
Safety checkpoints and operation evidence remain private and retained for review;
no teardown or production rollout is implied by this release test.

## Vendor references

- [Velero restore reference](https://velero.io/docs/v1.18/restore-reference/)
- [Velero resource filtering](https://velero.io/docs/v1.18/resource-filtering/)
- [Matching restore implementation](https://github.com/vmware-tanzu/velero/blob/v1.18.0/pkg/restore/restore.go)
- [Agent release](https://github.com/NousResearch/hermes-agent/releases/tag/v0.23.3)
- [WebUI release](https://github.com/nesquena/hermes-webui/releases/tag/v0.52.732)
- [Browserless release](https://github.com/browserless/browserless/releases/tag/v2.64.3)
