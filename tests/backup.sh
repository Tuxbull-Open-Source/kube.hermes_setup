#!/usr/bin/env bash
# Purpose: Verify encrypted backup helper contracts without a Kubernetes cluster.
# Scope: Test age passphrase delivery through a PTY, password-file permissions, strict
#        restore archive validation, Kubernetes snapshot normalization, full-restore dry-run,
#        K3s version mismatch refusal, and explicit --force handling.
# Requirements: Bash, Python 3, tar, sha256sum, and repository scripts.
# Usage: ./tests/backup.sh
# Exit status: 0 means all backup contracts passed; non-zero identifies a failure.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d -t hermes-backup-test.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/bin" "$TMP_DIR/input"
printf 'payload\n' > "$TMP_DIR/input/plain.txt"
printf 'correct horse battery staple\n' > "$TMP_DIR/password"
chmod 600 "$TMP_DIR/password"

cat > "$TMP_DIR/bin/age" <<'AGE'
#!/usr/bin/env bash
set -euo pipefail
# Fake age for test: reads passphrase from PTY (twice for encrypt, once for decrypt)
if [[ " $* " == *' --passphrase '* ]] && [[ " $* " != *' --decrypt '* ]]; then
  read -r prompt1
  read -r prompt2
  [[ "$prompt1" == "$prompt2" ]]
  prompt="$prompt1"
else
  read -r prompt
fi
[[ "$prompt" == "${FAKE_AGE_EXPECTED_PASSPHRASE:-correct horse battery staple}" ]]
case "${FAKE_AGE_EMIT_PASSPHRASE:-false}" in
  stdout) printf '%s\n' "$prompt" ;;
  stderr) printf '%s\n' "$prompt" >&2 ;;
  prefix-stdout) printf 'Enter passphrase: %s\n' "$prompt" ;;
  prefix-stderr) printf 'Enter passphrase: %s\n' "$prompt" >&2 ;;
  prefix-trailing) printf 'Enter passphrase: %s [authentication failed]\n' "$prompt" ;;
  prefix-ansi) printf 'Enter passphrase: \033[31m%s\033[0m\n' "$prompt" ;;
  prefix-before-colon) printf 'Enter password %s:\n' "$prompt" ;;
  arbitrary-inline) printf 'diagnostic value=%s unavailable\n' "$prompt" ;;
  benign-prompt) printf 'Enter passphrase:\n' ;;
  benign-long-prompt) printf 'Enter passphrase (leave empty to autogenerate a secure one):\n' ;;
  benign-status) printf 'age: routine diagnostic output\n' ;;
esac
if [[ -n "${FAKE_AGE_EXIT_CODE:-}" ]]; then
  exit "$FAKE_AGE_EXIT_CODE"
fi
if [[ " $* " == *' --decrypt '* ]]; then
  while (($#)); do
    [[ "$1" == --output ]] && { output="$2"; shift 2; continue; }
    input="$1"
    shift
  done
  cp "$input" "$output" 2>/dev/null || true
fi
echo 'fake age completed'
AGE
chmod 700 "$TMP_DIR/bin/age"
PATH="$TMP_DIR/bin:$PATH" python3 "$ROOT_DIR/scripts/age_passphrase.py" "$TMP_DIR/password" -- age --passphrase --output "$TMP_DIR/fake.age" "$TMP_DIR/input/plain.txt" > "$TMP_DIR/age.out"
[[ ! -s "$TMP_DIR/age.out" ]]

for disclosure_stream in stdout stderr prefix-stdout prefix-stderr prefix-trailing prefix-ansi prefix-before-colon arbitrary-inline; do
  set +e
  FAKE_AGE_EMIT_PASSPHRASE="$disclosure_stream" PATH="$TMP_DIR/bin:$PATH" \
    python3 "$ROOT_DIR/scripts/age_passphrase.py" "$TMP_DIR/password" -- \
    age --passphrase --output "$TMP_DIR/disclosure-$disclosure_stream.age" "$TMP_DIR/input/plain.txt" > "$TMP_DIR/disclosure-guard-$disclosure_stream.out" 2>&1
  disclosure_rc=$?
  set -e
  [[ "$disclosure_rc" == 0 ]]
  [[ ! -s "$TMP_DIR/disclosure-guard-$disclosure_stream.out" ]]
done

printf 'passphrase\n' > "$TMP_DIR/password-benign-prompt"
chmod 600 "$TMP_DIR/password-benign-prompt"
FAKE_AGE_EXPECTED_PASSPHRASE=passphrase FAKE_AGE_EMIT_PASSPHRASE=benign-prompt \
  PATH="$TMP_DIR/bin:$PATH" python3 "$ROOT_DIR/scripts/age_passphrase.py" \
  "$TMP_DIR/password-benign-prompt" -- age --passphrase --output "$TMP_DIR/benign-prompt.age" "$TMP_DIR/input/plain.txt" \
  > "$TMP_DIR/benign-prompt.out"
[[ ! -s "$TMP_DIR/benign-prompt.out" ]]

printf 'secure\n' > "$TMP_DIR/password-benign-long-prompt"
chmod 600 "$TMP_DIR/password-benign-long-prompt"
FAKE_AGE_EXPECTED_PASSPHRASE=secure FAKE_AGE_EMIT_PASSPHRASE=benign-long-prompt \
  PATH="$TMP_DIR/bin:$PATH" python3 "$ROOT_DIR/scripts/age_passphrase.py" \
  "$TMP_DIR/password-benign-long-prompt" -- age --passphrase --output "$TMP_DIR/benign-long-prompt.age" "$TMP_DIR/input/plain.txt" \
  > "$TMP_DIR/benign-long-prompt.out"
[[ ! -s "$TMP_DIR/benign-long-prompt.out" ]]

printf 'age\n' > "$TMP_DIR/password-benign-status"
chmod 600 "$TMP_DIR/password-benign-status"
FAKE_AGE_EXPECTED_PASSPHRASE=age FAKE_AGE_EMIT_PASSPHRASE=benign-status \
  PATH="$TMP_DIR/bin:$PATH" python3 "$ROOT_DIR/scripts/age_passphrase.py" \
  "$TMP_DIR/password-benign-status" -- age --passphrase --output "$TMP_DIR/benign-status.age" "$TMP_DIR/input/plain.txt" \
  > "$TMP_DIR/benign-status.out"
[[ ! -s "$TMP_DIR/benign-status.out" ]]

set +e
PATH="$TMP_DIR/bin:$PATH" python3 "$ROOT_DIR/scripts/age_passphrase.py" \
  "$TMP_DIR/password" -- age --passphrase "$TMP_DIR/input/plain.txt" \
  > "$TMP_DIR/missing-output.out" 2>&1
missing_output_rc=$?
set -e
[[ "$missing_output_rc" != 0 ]]
grep -Fq 'requires --output' "$TMP_DIR/missing-output.out"

set +e
FAKE_AGE_EXIT_CODE=23 PATH="$TMP_DIR/bin:$PATH" \
  python3 "$ROOT_DIR/scripts/age_passphrase.py" "$TMP_DIR/password" -- \
  age --passphrase --output "$TMP_DIR/child-failure.age" "$TMP_DIR/input/plain.txt" > "$TMP_DIR/child-failure.out" 2>&1
child_rc=$?
set -e
[[ "$child_rc" == 23 ]]
grep -Fq 'age command failed with exit status 23' "$TMP_DIR/child-failure.out"
! grep -Fq 'correct horse battery staple' "$TMP_DIR/child-failure.out"

if chmod 644 "$TMP_DIR/password"; then
  if PATH="$TMP_DIR/bin:$PATH" python3 "$ROOT_DIR/scripts/age_passphrase.py" "$TMP_DIR/password" -- age --passphrase "$TMP_DIR/input/plain.txt" >/dev/null 2>&1; then
    printf 'insecure password file unexpectedly accepted\n' >&2
    exit 1
  fi
fi
chmod 600 "$TMP_DIR/password"

mkdir -p "$TMP_DIR/archive-root/opt/data" "$TMP_DIR/archive-root/workspace" "$TMP_DIR/archive-root/metadata"
printf ok > "$TMP_DIR/archive-root/opt/data/file"
printf config > "$TMP_DIR/archive-root/metadata/hermes.env"
printf answers > "$TMP_DIR/archive-root/metadata/configuration_answers"
printf info > "$TMP_DIR/archive-root/metadata/backup-info.txt"
mkdir -p "$TMP_DIR/archive-root/metadata/bootstrap/skills"
printf bootstrap > "$TMP_DIR/archive-root/metadata/bootstrap/SOUL.md"
printf skill > "$TMP_DIR/archive-root/metadata/bootstrap/skills/example.md"
tar -czf "$TMP_DIR/good.tgz" -C "$TMP_DIR/archive-root" opt/data workspace metadata
HERMES_MAINTAIN_LIB_ONLY=true bash -c 'source "$1/maintain.sh"; validate_backup_archive "$2"' _ "$ROOT_DIR" "$TMP_DIR/good.tgz"
PATH="$TMP_DIR/bin:$PATH" ./maintain.sh extract "$TMP_DIR/good.tgz" --output-dir "$TMP_DIR/recovery-bootstrap" --component bootstrap --password-file "$TMP_DIR/password"
[[ -f "$TMP_DIR/recovery-bootstrap/bootstrap/SOUL.md" && -f "$TMP_DIR/recovery-bootstrap/bootstrap/skills/example.md" ]]
[[ ! -e "$TMP_DIR/recovery-bootstrap/hermes.env" ]]
PATH="$TMP_DIR/bin:$PATH" ./maintain.sh extract "$TMP_DIR/good.tgz" --output-dir "$TMP_DIR/recovery-config" --component config --password-stdin <<< 'correct horse battery staple'
[[ -f "$TMP_DIR/recovery-config/hermes.env" && -f "$TMP_DIR/recovery-config/configuration_answers" ]]
PATH="$TMP_DIR/bin:$PATH" ./maintain.sh extract "$TMP_DIR/good.tgz" --output-dir "$TMP_DIR/recovery-dry" --full --password-file "$TMP_DIR/password" --dry-run
[[ ! -e "$TMP_DIR/recovery-dry" ]]
mkdir -p "$TMP_DIR/bad-root/outside"
tar -czf "$TMP_DIR/bad.tgz" -C "$TMP_DIR/bad-root" outside
if HERMES_MAINTAIN_LIB_ONLY=true bash -c 'source "$1/maintain.sh"; validate_backup_archive "$2"' _ "$ROOT_DIR" "$TMP_DIR/bad.tgz" >/dev/null 2>&1; then
  printf 'outside archive path unexpectedly accepted\n' >&2
  exit 1
fi
ln -s ../outside "$TMP_DIR/archive-root/opt/data/link"
tar -czf "$TMP_DIR/link.tgz" -C "$TMP_DIR/archive-root" opt/data workspace metadata
if HERMES_MAINTAIN_LIB_ONLY=true bash -c 'source "$1/maintain.sh"; validate_backup_archive "$2"' _ "$ROOT_DIR" "$TMP_DIR/link.tgz" >/dev/null 2>&1; then
  printf 'archive symlink unexpectedly accepted\n' >&2
  exit 1
fi

mkdir -p "$TMP_DIR/raw"
cat > "$TMP_DIR/raw/namespace.json" <<'JSON'
{"apiVersion":"v1","kind":"Namespace","metadata":{"name":"bob","uid":"drop-me"},"status":{"phase":"Active"}}
JSON
for resource in pvc deployment service job ingress networkpolicy serviceaccount middleware; do
  cat > "$TMP_DIR/raw/$resource.json" <<JSON
{"apiVersion":"v1","kind":"${resource^}","metadata":{"name":"hermes-$resource","namespace":"bob","uid":"drop-me","resourceVersion":"drop-me"},"spec":{},"status":{"phase":"drop-me"}}
JSON
done
api_key_b64="$(printf '%s' 'restored-api-key-long-enough' | base64 -w0)"
cat > "$TMP_DIR/raw/secret.json" <<JSON
{"apiVersion":"v1","kind":"List","items":[{"apiVersion":"v1","kind":"Secret","metadata":{"name":"hermes-dashboard-auth","namespace":"bob","uid":"drop-me"},"data":{"password":"REDACTED-TEST-DATA"}},{"apiVersion":"v1","kind":"Secret","metadata":{"name":"hermes-api-server","namespace":"bob","uid":"drop-me"},"data":{"api-key":"$api_key_b64"}}]}
JSON
cat > "$TMP_DIR/raw/cluster-version.txt" <<'EOF'
v1.31.0+k3s1
EOF
python3 "$ROOT_DIR/scripts/kube_snapshot.py" snapshot "$TMP_DIR/raw" "$TMP_DIR/resources.json" bob
python3 "$ROOT_DIR/scripts/kube_snapshot.py" split "$TMP_DIR/resources.json" "$TMP_DIR/namespace.json" "$TMP_DIR/resources-list.json"
python3 - "$TMP_DIR/resources.json" "$TMP_DIR/resources-list.json" <<'PY'
import json, sys
snapshot = json.load(open(sys.argv[1]))
resources = json.load(open(sys.argv[2]))
assert len(snapshot['items']) == 11
assert resources['items']
assert all('uid' not in item.get('metadata', {}) for item in snapshot['items'])
assert all('status' not in item for item in snapshot['items'])
assert any(item['kind'] == 'Secret' for item in snapshot['items'])
PY

HERMES_MAINTAIN_LIB_ONLY=true bash -c 'source "$1"; validate_snapshot_api_key "$2"' _ "$ROOT_DIR/maintain.sh" "$TMP_DIR/resources.json"
python3 - "$TMP_DIR/resources.json" "$TMP_DIR" <<'PY'
import base64, copy, json, sys
source, output_dir = sys.argv[1:]
data=json.load(open(source))
secret=next(item for item in data['items'] if item.get('kind')=='Secret' and item.get('metadata',{}).get('name')=='hermes-api-server')

def write(name, value):
    payload=copy.deepcopy(data)
    if name == 'missing':
        payload['items']=[item for item in payload['items'] if not (item.get('kind')=='Secret' and item.get('metadata',{}).get('name')=='hermes-api-server')]
    elif name == 'duplicate':
        payload['items'].append(copy.deepcopy(secret))
    else:
        target=next(item for item in payload['items'] if item.get('kind')=='Secret' and item.get('metadata',{}).get('name')=='hermes-api-server')
        target['data']['api-key']=value
    json.dump(payload,open(f'{output_dir}/resources-invalid-{name}.json','w'))

write('missing', None)
write('duplicate', None)
write('malformed-base64', '%%%')
write('non-ascii', base64.b64encode(b'\xff'*16).decode())
write('short', base64.b64encode(b'short').decode())
write('dotenv-unsafe', base64.b64encode(b'1234567890123456 #suffix').decode())
write('tilde-unsafe', base64.b64encode(b'~1234567890123456').decode())
PY
for invalid_case in missing duplicate malformed-base64 non-ascii short dotenv-unsafe tilde-unsafe; do
  if HERMES_MAINTAIN_LIB_ONLY=true bash -c 'source "$1"; validate_snapshot_api_key "$2"' _ "$ROOT_DIR/maintain.sh" "$TMP_DIR/resources-invalid-$invalid_case.json" >/dev/null 2>&1; then
    printf 'snapshot validator unexpectedly accepted %s API key case\n' "$invalid_case" >&2
    exit 1
  fi
done
mkdir -p "$TMP_DIR/snapshot-fail-bin" "$TMP_DIR/snapshot-fail-raw"
cat > "$TMP_DIR/snapshot-fail-bin/kubectl" <<'KUBECTL_FAIL'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == version ]]; then
  printf '{"serverVersion":{"gitVersion":"v1.31.0+k3s1"}}\n'
elif [[ "$1" == get && "$2" == namespace ]]; then
  printf '{"apiVersion":"v1","kind":"Namespace","metadata":{"name":"bob"}}\n'
elif [[ " $* " == *' get secret '* ]]; then
  exit 1
elif [[ "$1" == -n && "$3" == get ]]; then
  printf '{"apiVersion":"v1","kind":"List","items":[]}\n'
fi
KUBECTL_FAIL
chmod 700 "$TMP_DIR/snapshot-fail-bin/kubectl"
if PATH="$TMP_DIR/snapshot-fail-bin:$PATH" HERMES_NAMESPACE=bob HERMES_MAINTAIN_LIB_ONLY=true \
  bash -c 'source "$1"; snapshot_kubernetes_state "$2" "$3" "$4"' _ "$ROOT_DIR/maintain.sh" \
  "$TMP_DIR/snapshot-fail-raw" "$TMP_DIR/snapshot-fail.json" "$TMP_DIR/snapshot-fail-version.json" >/dev/null 2>&1; then
  printf 'snapshot unexpectedly succeeded without Secret read access\n' >&2
  exit 1
fi
[[ ! -e "$TMP_DIR/snapshot-fail.json" ]]
python3 - "$ROOT_DIR/maintain.sh" <<'PY'
from pathlib import Path
import sys
body=Path(sys.argv[1]).read_text().split('restore_kubernetes_snapshot() {',1)[1].split('\n}',1)[0]
assert body.index('validate_snapshot_api_key') < body.index('kubectl apply -f "$namespace_json"')
assert body.index('validate_snapshot_api_key') < body.index('kubectl apply -f "$resources_json"')
PY

python3 - "$TMP_DIR/resources.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
for name in ('hermes-agent', 'hermes-dashboard', 'hermes-webui'):
    data['items'].append({
        'apiVersion': 'apps/v1',
        'kind': 'Deployment',
        'metadata': {'name': name, 'namespace': 'bob'},
        'spec': {'replicas': 1, 'template': {'metadata': {'annotations': {
            'kube-hermes-setup.example.com/api-key-revision': 'stale-backup-revision'
        }}}},
    })
json.dump(data, open(path, 'w'))
PY

rm -f "$TMP_DIR/archive-root/opt/data/link"
mkdir -p "$TMP_DIR/full-root/metadata/kubernetes"
cp -a "$TMP_DIR/archive-root/." "$TMP_DIR/full-root/"
cp "$TMP_DIR/resources.json" "$TMP_DIR/full-root/metadata/kubernetes/resources.json"
printf 'v1.31.0+k3s1\n' > "$TMP_DIR/full-root/metadata/kubernetes/cluster-version.txt"
tar -czf "$TMP_DIR/full.tgz" -C "$TMP_DIR/full-root" opt/data workspace metadata
cat > "$TMP_DIR/bin/kubectl" <<'KUBECTL'
#!/usr/bin/env bash
set -euo pipefail
[[ -z "${FAKE_KUBECTL_CALLS:-}" ]] || printf '%s\n' "$*" >> "$FAKE_KUBECTL_CALLS"
if [[ "$1" == version ]]; then
  printf '{"serverVersion":{"gitVersion":"%s"}}\n' "${FAKE_K3S_VERSION:-v1.31.0+k3s1}"
elif [[ "$1" == get && "$2" == namespace ]]; then
  printf 'namespace/bob\n'
elif [[ " $* " == *' get secret hermes-api-server '* && " $* " == *"jsonpath={.data['api-key']}"* ]]; then
  printf '%s' 'restored-api-key-long-enough' | base64
elif [[ " $* " == *' get secret hermes-api-server '* && " $* " == *'jsonpath={.metadata.resourceVersion}'* ]]; then
  printf 'restored-resource-version'
elif [[ " $* " == *' get deploy '* && " $* " == *'jsonpath={.spec.replicas}'* ]]; then
  printf '1'
elif [[ " $* " == *' cp '* && "${FAKE_CP_FAIL:-false}" == true ]]; then
  exit 42
elif [[ " $* " == *' exec -i hermes-restore '* ]]; then
  cat > "${FAKE_RESTORED_KEY_INPUT:?}"
fi
KUBECTL
chmod 700 "$TMP_DIR/bin/kubectl"
PATH="$TMP_DIR/bin:$PATH" HERMES_NAMESPACE=bob FAKE_K3S_VERSION=v1.31.0+k3s1 ./maintain.sh restore "$TMP_DIR/full.tgz" --full --dry-run --password-file "$TMP_DIR/password"
if PATH="$TMP_DIR/bin:$PATH" HERMES_NAMESPACE=bob FAKE_K3S_VERSION=v1.32.0+k3s1 ./maintain.sh restore "$TMP_DIR/full.tgz" --full --dry-run --password-file "$TMP_DIR/password" > "$TMP_DIR/mismatch.out" 2>&1; then
  printf 'K3s version mismatch unexpectedly accepted\n' >&2
  exit 1
fi
grep -Fq 'K3s version mismatch' "$TMP_DIR/mismatch.out"
if PATH="$TMP_DIR/bin:$PATH" HERMES_NAMESPACE=bob FAKE_K3S_VERSION=v1.31.0 ./maintain.sh restore "$TMP_DIR/full.tgz" --full --dry-run --force --password-file "$TMP_DIR/password" > "$TMP_DIR/non-k3s.out" 2>&1; then
  :
else
  printf 'forced non-K3s restore unexpectedly refused\n' >&2
  exit 1
fi
grep -Fq 'continuing because --force' "$TMP_DIR/non-k3s.out"
PATH="$TMP_DIR/bin:$PATH" HERMES_NAMESPACE=other FAKE_K3S_VERSION=v1.31.0+k3s1 ./maintain.sh restore "$TMP_DIR/full.tgz" --full --dry-run --force --password-file "$TMP_DIR/password" > "$TMP_DIR/namespace-force.out" 2>&1
grep -Fq 'Forcing restore into backup Namespace: backup=bob configured=other' "$TMP_DIR/namespace-force.out"
rm -f "$TMP_DIR/full-root/metadata/kubernetes/cluster-version.txt"
tar -czf "$TMP_DIR/no-version.tgz" -C "$TMP_DIR/full-root" opt/data workspace metadata
PATH="$TMP_DIR/bin:$PATH" HERMES_NAMESPACE=bob FAKE_K3S_VERSION=v1.31.0+k3s1 ./maintain.sh restore "$TMP_DIR/no-version.tgz" --full --dry-run --force --password-file "$TMP_DIR/password" > "$TMP_DIR/no-version.out" 2>&1
grep -Fq 'no K3s version metadata' "$TMP_DIR/no-version.out"
PATH="$TMP_DIR/bin:$PATH" HERMES_NAMESPACE=bob FAKE_K3S_VERSION=v1.32.0+k3s1 ./maintain.sh restore "$TMP_DIR/full.tgz" --full --dry-run --force --password-file "$TMP_DIR/password" >/dev/null

: > "$TMP_DIR/kubectl.calls"
PATH="$TMP_DIR/bin:$PATH" HERMES_NAMESPACE=bob FAKE_K3S_VERSION=v1.31.0+k3s1 FAKE_KUBECTL_CALLS="$TMP_DIR/kubectl.calls" FAKE_RESTORED_KEY_INPUT="$TMP_DIR/restored-key.input" \
  ./maintain.sh restore "$TMP_DIR/full.tgz" --full --password-file "$TMP_DIR/password" >/dev/null
for deployment in hermes-agent hermes-dashboard hermes-webui; do
  grep -Fq "patch deployment $deployment --type=merge" "$TMP_DIR/kubectl.calls"
done
grep -Fq 'restored-resource-version' "$TMP_DIR/kubectl.calls"
grep -Fq 'get secret hermes-api-server' "$TMP_DIR/kubectl.calls"
grep -Fq 'exec -i hermes-restore' "$TMP_DIR/kubectl.calls"
grep -qx 'restored-api-key-long-enough' "$TMP_DIR/restored-key.input"

: > "$TMP_DIR/failure.calls"
if PATH="$TMP_DIR/bin:$PATH" HERMES_NAMESPACE=bob FAKE_K3S_VERSION=v1.31.0+k3s1 \
  FAKE_KUBECTL_CALLS="$TMP_DIR/failure.calls" FAKE_RESTORED_KEY_INPUT="$TMP_DIR/failure-key.input" FAKE_CP_FAIL=true \
  ./maintain.sh restore "$TMP_DIR/full.tgz" --full --password-file "$TMP_DIR/password" >/dev/null 2>&1; then
  printf 'injected pre-destructive restore failure unexpectedly succeeded\n' >&2
  exit 1
fi
for deployment in hermes-agent hermes-dashboard hermes-webui; do
  grep -Eq "scale .*deploy/$deployment.*--replicas=0" "$TMP_DIR/failure.calls"
  grep -Fq "scale deploy/$deployment --replicas=1" "$TMP_DIR/failure.calls"
done
! grep -Fq 'find /opt/data /workspace' "$TMP_DIR/failure.calls"

python3 - "$ROOT_DIR/maintain.sh" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
body = text.split('restore() {', 1)[1].split('\nprompt_secret() {', 1)[0]
prepare = body.index('prepare_restored_api_key_sync')
copy = body.index('kubectl -n "$HERMES_NAMESPACE" cp "$plain"')
destructive = body.index('find /opt/data /workspace')
sync = body.index('sync_restored_api_key')
scale_down = body.index('log "Scaling down write-heavy deployments"')
scale_up = body.index('log "Scaling deployments up"')
cleanup_enabled_before = body.index('RESTORE_SCALE_UP_ON_CLEANUP=true', 0, scale_down)
cleanup_disabled = body.index('RESTORE_SCALE_UP_ON_CLEANUP=false', copy, destructive)
cleanup_enabled_after = body.index('RESTORE_SCALE_UP_ON_CLEANUP=true', sync, scale_up)
assert prepare < copy < cleanup_disabled < destructive < sync < cleanup_enabled_after < scale_up
assert cleanup_enabled_before < scale_down
assert 'local RESTORE_SCALE_UP_ON_CLEANUP' not in body
assert 'if [[ "${RESTORE_SCALE_UP_ON_CLEANUP:-false}" == true ]]' in body
assert body.index('trap - EXIT') < body.index('unset RESTORE_SCALE_UP_ON_CLEANUP')
assert 'RESTORE_DEPLOYMENTS=("${deployments[@]}")' in body
assert 'declare -gA RESTORE_ORIGINAL_REPLICAS=()' in body
assert 'for d in "${RESTORE_DEPLOYMENTS[@]:-}"' in body
assert 'unset RESTORE_SCALE_UP_ON_CLEANUP RESTORE_DEPLOYMENTS RESTORE_ORIGINAL_REPLICAS' in body
PY

sync_script="$(HERMES_MAINTAIN_LIB_ONLY=true bash -c 'source "$1"; restored_api_key_sync_script' _ "$ROOT_DIR/maintain.sh")"
grep -Fq 'mktemp "${env_file}.XXXXXX"' <<<"$sync_script"
grep -Fq 'ln "$env_file" "$source_env"' <<<"$sync_script"
grep -Fq 'done < "$source_env" > "$tmp_env"' <<<"$sync_script"
valid_encoded="$(printf '%s' 'restored-api-key-long-enough' | base64 -w0)"
HERMES_MAINTAIN_LIB_ONLY=true bash -c 'source "$1"; validate_encoded_api_key "$2"' _ "$ROOT_DIR/maintain.sh" "$valid_encoded"
punctuation_encoded="$(printf '%s' '1234567890123456._:/+=@%-' | base64 -w0)"
HERMES_MAINTAIN_LIB_ONLY=true bash -c 'source "$1"; validate_encoded_api_key "$2"' _ "$ROOT_DIR/maintain.sh" "$punctuation_encoded"
python3 - "$TMP_DIR" <<'PY'
import base64, pathlib, sys
root=pathlib.Path(sys.argv[1])
cases={
    'nul': b'restored-api-key-long-enough\0',
    'short': b'short',
    'non-ascii': b'\xff'*16,
    'unsafe-ascii': b'1234567890123456 #suffix',
}
for name,value in cases.items():
    (root/f'encoded-invalid-{name}').write_text(base64.b64encode(value).decode())
(root/'encoded-invalid-malformed').write_text('%%%')
PY
for invalid_case in nul short non-ascii unsafe-ascii malformed; do
  if HERMES_MAINTAIN_LIB_ONLY=true bash -c 'source "$1"; validate_encoded_api_key "$2"' _ \
    "$ROOT_DIR/maintain.sh" "$(<"$TMP_DIR/encoded-invalid-$invalid_case")"; then
    printf 'encoded-key validator unexpectedly accepted %s case\n' "$invalid_case" >&2
    exit 1
  fi
done
sync_env="$TMP_DIR/restored-runtime.env"
printf '%s\n' 'UNRELATED_SETTING=keep-me' 'API_SERVER_KEY=stale-one' 'API_SERVER_KEY=stale-two' > "$sync_env"
cp "$sync_env" "$TMP_DIR/validate-only.before"
printf '%s' 'restored-api-key-long-enough' | sh -c "$sync_script" sh "$(id -u)" "$(id -g)" "$sync_env" validate-only
cmp -s "$sync_env" "$TMP_DIR/validate-only.before"
printf '%s' 'restored-api-key-long-enough' | sh -c "$sync_script" sh "$(id -u)" "$(id -g)" "$sync_env"
grep -qx 'UNRELATED_SETTING=keep-me' "$sync_env"
grep -qx 'API_SERVER_KEY=restored-api-key-long-enough' "$sync_env"
[[ "$(grep -c '^API_SERVER_KEY=' "$sync_env")" == 1 ]]
[[ "$(stat -c %a "$sync_env")" == 600 ]]
cp "$sync_env" "$TMP_DIR/restored-runtime.before"
if printf 'bad\rkey-value-long-enough' | sh -c "$sync_script" sh "$(id -u)" "$(id -g)" "$sync_env"; then
  printf 'restore sync unexpectedly accepted carriage return\n' >&2
  exit 1
fi
cmp -s "$sync_env" "$TMP_DIR/restored-runtime.before"
if printf 'bad\nkey-value-long-enough' | sh -c "$sync_script" sh "$(id -u)" "$(id -g)" "$sync_env"; then
  printf 'restore sync unexpectedly accepted newline\n' >&2
  exit 1
fi
cmp -s "$sync_env" "$TMP_DIR/restored-runtime.before"
if printf 'short' | sh -c "$sync_script" sh "$(id -u)" "$(id -g)" "$sync_env"; then
  printf 'restore sync unexpectedly accepted weak API key\n' >&2
  exit 1
fi
cmp -s "$sync_env" "$TMP_DIR/restored-runtime.before"
if printf '1234567890123456 #suffix' | sh -c "$sync_script" sh "$(id -u)" "$(id -g)" "$sync_env"; then
  printf 'restore sync unexpectedly accepted dotenv-unsafe API key\n' >&2
  exit 1
fi
cmp -s "$sync_env" "$TMP_DIR/restored-runtime.before"
if printf 'bad-key-value-long-enough\n' | sh -c "$sync_script" sh "$(id -u)" "$(id -g)" "$sync_env"; then
  printf 'restore sync unexpectedly accepted trailing newline\n' >&2
  exit 1
fi
cmp -s "$sync_env" "$TMP_DIR/restored-runtime.before"

symlink_target="$TMP_DIR/symlink-target"
symlink_env="$TMP_DIR/symlink-runtime.env"
printf '%s\n' 'DO_NOT_REPLACE=target' > "$symlink_target"
ln -s "$symlink_target" "$symlink_env"
if printf '%s' 'restored-api-key-long-enough' | sh -c "$sync_script" sh "$(id -u)" "$(id -g)" "$symlink_env" validate-only; then
  printf 'restore sync validation unexpectedly accepted an env-file symlink\n' >&2
  exit 1
fi
if printf '%s' 'restored-api-key-long-enough' | sh -c "$sync_script" sh "$(id -u)" "$(id -g)" "$symlink_env"; then
  printf 'restore sync unexpectedly followed an env-file symlink\n' >&2
  exit 1
fi
[[ -L "$symlink_env" ]]
grep -qx 'DO_NOT_REPLACE=target' "$symlink_target"

printf 'encrypted backup helper tests passed\n'

# ---------------------------------------------------------------------------
# --data-only backup/restore contract: curated Hermes-state paths only, no
# reproducible runtime software, no destructive PVC wipe on restore, no
# Kubernetes resource snapshot, and no API-key Secret sync (the archive never
# carries /opt/data/.env or a Secret, so there is nothing valid to sync from).
# ---------------------------------------------------------------------------

# DATA_ONLY_PATHS must exist, must include curated Hermes state, and must
# exclude reproducible runtime software that a fresh install.sh rebuilds.
HERMES_MAINTAIN_LIB_ONLY=true bash -c '
  source "$1/maintain.sh"
  printf "%s\n" "${DATA_ONLY_PATHS[@]}" > "$2/data-only-paths.txt"
' _ "$ROOT_DIR" "$TMP_DIR"
for expected in 'opt/data/webui/sessions' 'opt/data/profiles' 'opt/data/skills' 'opt/data/memories' 'opt/data/cron' 'opt/data/state.db' 'opt/data/home' 'workspace'; do
  grep -qxF "$expected" "$TMP_DIR/data-only-paths.txt" || { printf 'DATA_ONLY_PATHS missing expected entry: %s\n' "$expected" >&2; exit 1; }
done
for excluded in 'opt/data/addon-venv' 'opt/data/node' 'opt/data/uv' 'opt/data/lsp' 'opt/data/node_modules' 'opt/data/cache' 'opt/data/hermes-managed' 'opt/data/lazy-packages'; do
  grep -qxF "$excluded" "$TMP_DIR/data-only-paths.txt" && { printf 'DATA_ONLY_PATHS unexpectedly includes reproducible software path: %s\n' "$excluded" >&2; exit 1; }
done
# The archive never carries a runtime .env or Secret-derived credential; a
# data-only restore must not silently reintroduce a stale API key from a
# different instance's Secret onto the destination.
grep -qxF 'opt/data/.env' "$TMP_DIR/data-only-paths.txt" && { printf 'DATA_ONLY_PATHS unexpectedly includes opt/data/.env (credential convergence hazard)\n' >&2; exit 1; }

# --full and --data-only are mutually exclusive on restore.
set +e
PATH="$TMP_DIR/bin:$PATH" HERMES_NAMESPACE=bob ./maintain.sh restore "$TMP_DIR/full.tgz" --full --data-only --password-file "$TMP_DIR/password" > "$TMP_DIR/mutex.out" 2>&1
mutex_rc=$?
set -e
[[ "$mutex_rc" != 0 ]]
grep -Fq 'mutually exclusive' "$TMP_DIR/mutex.out"

# Fake helper-pod kubectl: backs create_storage_helper_pod/wait/exec/cp/delete
# for the restore --data-only dry-run and mutex checks above. A full
# end-to-end backup --data-only run against a real cluster is covered by live
# K3s acceptance (AGENTS.md live validation protocol), not this hermetic
# contract suite, matching how --full backup/restore's cluster-mutating steps
# are exercised here only through static assertions plus the fake-kubectl
# restore path already covered above.
python3 - "$ROOT_DIR/maintain.sh" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
backup_body = text.split('backup() {', 1)[1].split('\nextract_backup() {', 1)[0]
assert 'data_only' in backup_body
assert 'DATA_ONLY_PATHS' in backup_body
assert 'tar --no-recursion -T - -czf /tmp/hermes-backup.tgz' in backup_body
# Full snapshot/metadata-kubernetes staging must be skipped for data-only.
assert 'if [[ "$data_only" != true ]]; then' in backup_body
restore_body = text.split('\nrestore() {', 1)[1].split('\nprompt_secret() {', 1)[0]
assert '--data-only' in restore_body
# The destructive full-namespace wipe must never run in the data-only branch:
# it must be gated behind an explicit non-data-only else-branch.
assert 'find /opt/data /workspace -mindepth 1 -maxdepth 1 -exec rm -rf' in restore_body
wipe_index = restore_body.index('find /opt/data /workspace -mindepth 1 -maxdepth 1 -exec rm -rf')
data_only_branch = restore_body.index('if [[ "$data_only" == true ]]; then')
else_branch = restore_body.index('else', data_only_branch)
assert data_only_branch < else_branch < wipe_index, 'destructive wipe must sit in the non-data-only else branch'
# API-key Secret sync must be skipped entirely for data-only restores.
prepare_guard = restore_body.index('if [[ "$data_only" != true ]]; then\n    prepare_restored_api_key_sync')
sync_guard = restore_body.index('if [[ "$data_only" != true ]]; then\n    sync_restored_api_key')
assert prepare_guard >= 0 and sync_guard >= 0
PY

# DATA_ONLY_PATHS contains directories and their descendants.  Tar must not
# recurse again for every listed directory or it duplicates the payload and can
# exhaust the backup volume on a live workspace.
mkdir -p "$TMP_DIR/nonrecursive-stage/opt/data/sessions"
printf payload > "$TMP_DIR/nonrecursive-stage/opt/data/sessions/one.txt"
(
  cd "$TMP_DIR/nonrecursive-stage"
  printf '%s\n' opt opt/data opt/data/sessions opt/data/sessions/one.txt | \
    tar --no-recursion -T - -czf "$TMP_DIR/nonrecursive.tgz"
)
[[ "$(tar -tzf "$TMP_DIR/nonrecursive.tgz" | grep -cx 'opt/data/sessions/one.txt')" == 1 ]]

# restore --data-only --dry-run must not require kubectl at all (no cluster
# mutation, no cluster read) and must list archive contents. The fake `age`
# fixture only implements --decrypt by copying bytes through (see the shared
# fixture above), so the "encrypted" input can be the plaintext tarball itself.
mkdir -p "$TMP_DIR/data-only-archive-root/opt/data/skills" "$TMP_DIR/data-only-archive-root/workspace" "$TMP_DIR/data-only-archive-root/metadata"
printf skill > "$TMP_DIR/data-only-archive-root/opt/data/skills/example.md"
printf ws > "$TMP_DIR/data-only-archive-root/workspace/file.txt"
printf 'namespace=bob\ncreated_at=2026-01-01T00:00:00Z\nscope=data-only\n' > "$TMP_DIR/data-only-archive-root/metadata/backup-info.txt"
tar -czf "$TMP_DIR/data-only.tgz" -C "$TMP_DIR/data-only-archive-root" opt/data workspace metadata
PATH="$TMP_DIR/bin:$PATH" HERMES_NAMESPACE=bob \
  ./maintain.sh restore "$TMP_DIR/data-only.tgz" --data-only --dry-run --password-file "$TMP_DIR/password" \
  > "$TMP_DIR/data-only-dry-run.out" 2>&1
grep -Fq 'Dry run' "$TMP_DIR/data-only-dry-run.out"
grep -Fq 'opt/data/skills/example.md' "$TMP_DIR/data-only-dry-run.out"

printf 'data-only backup/restore contract tests passed\n'
