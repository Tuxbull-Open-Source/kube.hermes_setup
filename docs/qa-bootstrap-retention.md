# Bootstrap retention regression: qualification evidence

## Scope

This regression fixes host-maintenance rejection of an existing bootstrap Secret.
It is not an application image update, a new recovery backend, or a qualification
of arbitrary future publisher releases. `VERSION` remains the unreleased 2.8.0
candidate; this is a corrective change within that candidate.

## Local checks executed

- `python3 tests/maintenance-bootstrap.py`: 7 tests passed.
- `python3 tests/host-maintenance.py`: 12 tests passed.
- `python3 tests/maintenance-safety.py`: 35 tests passed.
- `python3 tests/maintenance-contract.py`: 3 tests passed.
- `bash tests/matrix.sh`: 8 component combinations and 24 profile/Ansible/requirements combinations passed.
- `bash tests/profile-composition.sh`: passed.
- `bash tests/bootstrap-soul.sh`: passed. Its path substitution fixture now also works when TMPDIR is below a production-like mount prefix; extraction stays within the fixture.
- `bash tests/credentials.sh`: passed.
- `bash tests/reconcile-api-key.sh`: passed.
- `bash tests/release-final-state.sh`: passed.
- Shell syntax checks and `git diff --check`: passed.

The new tests cover archive present/absent, Ansible enabled/disabled, sealed
maintenance selection, no archive generation, no bootstrap Secret mutation,
stale-archive rejection before cluster writes, invalid mode/requirements rejection,
and continued rejection of retained-archive data drift.

## Real disposable cluster

A fresh Ubuntu 24.04.4 VM with K3s v1.36.4+k3s1 was used. No production claims,
credentials, hostnames or datasets were cloned into it. The baseline installer
was commit `2462105843b7dde0ad728b50dda767b4679e4ab9`.

The full stack used Agent v0.23.1, WebUI 0.52.678 and Browserless v2.63.1.
The baseline installed a custom synthetic bootstrap, with Ansible enabled and
empty explicit addon requirements. After bootstrap, a fixture file was changed
to an operator-owned value.

`tests/maintenance-bootstrap-live.py` then exercised the candidate installer and
an unchanged second run with maintenance mode selected. Both passed:

- Four application Deployments Ready.
- Retained bootstrap Secret UID, resourceVersion and opaque data digest unchanged.
- Both PVC UIDs unchanged.
- Customized fixture file preserved, proving no bootstrap replay.
- No new bootstrap archive generated despite enabled Ansible.
- Final application Pods had zero restarts.

The host-side test service exited successfully. This tests real Kubernetes writes
through `install.sh`; it is not a fake-kubectl result. Planning behavior and sealed
mode selection are separately covered by the coordinator regression tests.

## Separate baseline finding

The first fresh fixture used the installer's special offline isolated-test mode.
WebUI startup failed because Python 3.14 had not been pre-staged. That attempt was
stopped and its synthetic namespace removed. The successful baseline used the
normal online installation mode on the disposable VM, with reserved example
Ingress hostnames. No production isolation policy was weakened. Offline fixture
pre-staging remains a separate requirement, not a claimed fix in this change.

## Acceptance limitations

- No production deployment or protected maintenance binding was changed to this candidate.
- No complete `maintenance.sh upgrade PLAN` transaction with a real Velero backend was executed in this disposable test.
- No Velero restore drill or claim of restore-tested production recovery.
- No end-to-end browser-login test or real provider/model request in this fixture.
- No automatic merge, release tag or production upgrade.

After review, provision the exact reviewed source snapshot and matching host
helper using the existing enrollment procedure, re-prepare the affected instance's
plan, and execute only after its existing backup/recovery and application-acceptance
gates are satisfied. Never delete the retained archive to bypass planning.
