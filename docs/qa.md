# QA and live acceptance

The policy follows established QA practice: define representative test data and explicit graders/acceptance criteria before evaluating behavior ([OpenAI eval guidance](https://developers.openai.com/api/docs/guides/evals)); validate the actual deployed system rather than only generated artifacts; and use small, isolated deployments with explicit evaluation before broader rollout ([Google SRE canarying guidance](https://sre.google/workbook/canarying-releases/)).

This repository deploys a multi-container application. Static shell, Python, and YAML tests are necessary but do not prove that the deployed images start or that the user-facing system works.

## Mandatory test policy

For any change affecting `configure.sh`, `install.sh`, `maintain.sh`, `doctor.sh`, `manifests/`, bootstrap profiles, Secrets, PVCs, optional components, ingress, authentication, Browserless, WebUI, Ansible, or SSH:

- run the repository-local tests;
- run a real deployment on a fresh disposable Linux/K3s VM or an explicitly named real test VM;
- test every enabled component, not only `hermes-agent`;
- inspect startup logs and Kubernetes events for every deployment;
- rerun the installer unchanged and verify stable persistent state;
- report any skipped live gate as **blocked**, never as passed.

An Agent-only deployment is valid only for a change that is explicitly limited to Agent-only behavior and has no effect on shared manifests, credentials, bootstrap, optional components, or installer sequencing.

## Required evidence

Record the following in the PR, redacting private names, addresses, credentials, tokens, and OAuth data:

- repository commit under test;
- target type: fresh disposable VM or named real test VM;
- OS, Kubernetes/k3s version, CPU, memory, storage, and image tags;
- namespace and PVC scope, with private identifiers redacted in public text;
- readiness of node, DNS, storage provisioner, and ingress dependencies;
- init-job completion and `get deploy,pods,svc,pvc` output summary;
- logs for every enabled component, including previous container logs after a crash;
- effective non-secret environment and mounted configuration paths;
- authentication result: invalid credentials rejected and valid credentials accepted;
- browser result using real Chromium, including clean authenticated console and screenshot inspection when WebUI is enabled;
- second installer run, rollout result, PVC identity, and a hash of a persisted test artifact;
- cleanup result or explicit retained-lab decision.

## Minimum component matrix

The full acceptance run must cover these cases on clean storage:

| Case | Components | Required checks |
|---|---|---|
| agent-only | Agent | API/gateway readiness, CLI, mounted config, persistence |
| dashboard | Agent + Dashboard | dashboard rollout, login rejection/acceptance, files endpoint |
| webui | Agent + WebUI | WebUI rollout, startup logs, login rejection/acceptance, real Chromium |
| browser | Agent + Browserless | CDP URL shape, token rejection/acceptance, pressure/health |
| full | Agent + Dashboard + WebUI + Browserless | all checks together, NetworkPolicy and ingress |
| reinstall | same as full | unchanged reinstall, Secret hashes, PVC identity/data |
| failure | one invalid input or dependency | fail before destructive apply, no silent credential rotation |

A test that disables WebUI, Dashboard, and Browserless cannot be cited as evidence for the full or WebUI-enabled matrix.

## Maintenance command contract

```bash
python3 tests/maintenance-contract.py
./tests/api-key-sync.sh
./tests/reconcile-api-key.sh
./tests/browser-cdp-convergence.sh
```

The local contract rejects removed backup/restore/extract commands without cluster
calls or archive changes. Credential reconciliation and rotation remain supported.
Velero recovery drills are operator-owned; this repository neither configures nor
tests Velero. See [backup ownership](operations.md#backup-and-recovery-operator-owned-velero).
These local checks do not replace the mandatory live gates above.

## Startup failures

A WebUI Pod in `CrashLoopBackOff` is a hard failure even when Agent and Dashboard are healthy. Check both current and previous logs:

```bash
kubectl -n "$HERMES_NAMESPACE" get pods -o wide
kubectl -n "$HERMES_NAMESPACE" logs deploy/hermes-webui --all-containers=true --tail=250
kubectl -n "$HERMES_NAMESPACE" logs deploy/hermes-webui --all-containers=true --previous --tail=250
kubectl -n "$HERMES_NAMESPACE" get events --sort-by=.lastTimestamp | tail -80
```

For packaging or image compatibility failures, identify the exact failing command and compare it with the upstream WebUI and Agent source. Do not mask a startup failure by disabling an option unless that option is proven to be honored by the image actually under test.

## Credential acceptance

For ordinary reinstall tests:

- explicit values win;
- existing Kubernetes Secrets are reused when configuration values are blank;
- missing Secrets generate values;
- malformed, empty, missing-key, RBAC, connectivity, and weak-key errors fail closed;
- compare hashes or source classifications only; never print values;
- verify that no local credential-capture file is created; compare only Kubernetes Secret source classifications, hashes, metadata, and status.

## Recommended command sequence

```bash
# Preconditions: fresh/approved test VM, working kubectl, isolated namespace.
./tests/profile-composition.sh
./tests/configure.sh
./tests/matrix.sh
./tests/ssh-identity.sh
./tests/credentials.sh
./tests/browser-cdp-convergence.sh

# Live run, with an explicitly isolated namespace and generated env file.
ENV_FILE=./current_config/hermes.env HERMES_RENDER_DIR=./current_config/artifacts ./install.sh
./doctor.sh
kubectl -n "$HERMES_NAMESPACE" get deploy,pods,svc,pvc -o wide

# Reinstall without changing the env file.
ENV_FILE=./current_config/hermes.env HERMES_RENDER_DIR=./current_config/artifacts ./install.sh
./doctor.sh
```

The exact live commands may vary by lab, but the evidence requirements do not.

## Quality rule

Do not write “tested successfully” when only syntax, fake-`kubectl`, render, or Agent-only tests passed. Use separate labels:

- `static/local`: source and hermetic tests;
- `render/schema`: generated manifest validation;
- `live/cluster`: real Kubernetes deployment;
- `runtime/acceptance`: logs, CLI, auth, browser, persistence, and reinstall.

The final status is successful only when every gate required by the change scope is green.
