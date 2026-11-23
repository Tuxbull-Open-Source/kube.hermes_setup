# Hermes installer 2.9.0 release preparation

This document prepares an installer release. It does not publish the `v2.9.0`
tag or a GitHub Release and does not change application images automatically.
The project's lab-only/experimental warning remains in force.

## Release scope

2.9.0 consolidates the previously unpublished 2.8.0 maintenance candidate and
subsequent repository-owned recovery work. `VERSION` already identifies 2.9.0;
this is not a request to manufacture another patch number merely for publication.
Historical changelog entries remain evidence of their original scope.

- One authoritative checkout/configuration per instance.
- Stable-release planning with immutable image references and protected host jobs.
- Native Velero backup, eligibility listing and exact-name restore.
- Mandatory completed cold backup before an image upgrade.
- Bootstrap archive retention without recreation, deletion or replay.
- Reviewed privileged source staging and explicit operator enrollment.
- A versioned `hermes-maintenance-v2.py` controller and provisioner handshake,
  leaving unrelated legacy controllers and bindings intact.
- Persistent image pins, namespace/PVC identity guards and private-artifact tests.

The Authelia identity service is maintained in its own repository; this installer
neither upgrades that service nor changes directory MFA or external HTTPS policy.

## Upgrade from published 2.7.x or an older candidate

Read [host maintenance](host-maintenance.md) before changing a working checkout.
Preserve private configuration, credentials and recovery evidence. An administrator
must review and stage the exact source and install the matching provisioner before
normal operator enrollment. A Git pull alone does not replace privileged code.

After that bootstrap, from each approved instance's own checkout:

```bash
./provision-host.sh --revision FULL_REVIEWED_COMMIT
./maintain.sh status
./maintain.sh plan --latest-stable
./maintain.sh upgrade EXACT_PREPARED_PLAN
./maintain.sh logs EXACT_OPERATION
```

Only switch to `v2.9.0` after that tag actually exists. Until publication, use the
explicitly reviewed commit from the merged release PR, not a guessed tag or moving
branch. Do not use an unsupported old provisioner as a self-updater.

## Recovery and limits

Use exact qualified backup names and the documented data-loss acknowledgment.
Restoring an image without its compatible data/configuration is not database
rollback. A full restore replaces namespace/PVC identities; explicit reenrollment
is required afterward. Preserve failure evidence before another action.

A successful synthetic rehearsal does not prove every production backup,
application login, external model or private MCP. Existing keys and stored data
are sensitive; operation artifacts and instance configuration must never enter Git.

## Publication gates

- Read the exact executable revisions and scope in
  [recovery qualification](qa-repository-recovery.md).
- Run the maintenance, provisioning, bootstrap and private-artifact regressions
  under both permissive and restrictive umasks.
- Qualify any recovery behavior changed by the release through the actual operator
  entrypoint in a disposable fixture, including failed-workload recovery.
- Verify every required hosted CI job against the current release PR head.
- Review version, changelog, migration guidance and links together.
- Publish the tag/release only as a separately authorized release action.
