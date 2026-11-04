#!/usr/bin/env bash
# Purpose: Operate and inspect an existing Hermes Kubernetes/K3s deployment.
# Scope: Provide status, restart/upgrade, credential display and rotation,
#        while keeping operations constrained to the configured namespace.
# Requirements: Bash, kubectl, Python 3, base64, OpenSSL, and standard coreutils.
# Usage: ./maintain.sh {status|show-passwords|restart|upgrade|reconcile-api-key|reconcile-browser-token|rotate-passwords|rotate-browser-token}
# Exit status: 0 means the requested operation completed; non-zero identifies a failure.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Rotation input passed explicitly in the process environment must survive
# sourcing an env file that intentionally keeps generated values blank.
PROCESS_DASHBOARD_AUTH_USER_SET="${DASHBOARD_AUTH_USER+x}"
PROCESS_DASHBOARD_AUTH_USER="${DASHBOARD_AUTH_USER-}"
PROCESS_DASHBOARD_AUTH_PASSWORD_SET="${DASHBOARD_AUTH_PASSWORD+x}"
PROCESS_DASHBOARD_AUTH_PASSWORD="${DASHBOARD_AUTH_PASSWORD-}"
PROCESS_BROWSER_TOKEN_SET="${BROWSER_TOKEN+x}"
PROCESS_BROWSER_TOKEN="${BROWSER_TOKEN-}"
DEFAULT_ENV_FILE="$ROOT_DIR/hermes.env"
if [[ ! -f "$DEFAULT_ENV_FILE" && -f "$ROOT_DIR/current_config/hermes.env" ]]; then
  DEFAULT_ENV_FILE="$ROOT_DIR/current_config/hermes.env"
fi
ENV_FILE="${ENV_FILE:-$DEFAULT_ENV_FILE}"
parse_env_file() {
  local key encoded value
  while IFS=$'\t' read -r key encoded; do
    [[ -n "$key" ]] || continue
    value="$(printf '%s' "$encoded" | base64 -d)" || { printf 'ERROR: unable to decode environment setting %s\n' "$key" >&2; exit 1; }
    printf -v "$key" '%s' "$value"
    export "$key"
  done < <(python3 - "$ENV_FILE" <<'PY'
import base64, shlex, sys
path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as stream:
        for number, line in enumerate(stream, 1):
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            try:
                fields = shlex.split(stripped, comments=True, posix=True)
            except ValueError as exc:
                raise SystemExit(f"invalid environment syntax at line {number}: {exc}")
            if len(fields) != 1 or "=" not in fields[0]:
                raise SystemExit(f"invalid environment assignment at line {number}")
            key, value = fields[0].split("=", 1)
            if not key or not (key[0].isalpha() or key[0] == "_") or not all(c.isalnum() or c == "_" for c in key):
                raise SystemExit(f"invalid environment variable name at line {number}")
            if key in {"BASH_ENV", "ENV", "CDPATH", "PATH", "SHELLOPTS", "BASHOPTS", "GLOBIGNORE", "PYTHONPATH", "PYTHONINSPECT"} or key.startswith("LD_"):
                raise SystemExit(f"unsafe environment variable at line {number}")
            print(f"{key}\t{base64.b64encode(value.encode()).decode()}")
except OSError as exc:
    raise SystemExit(f"unable to read environment file: {exc}")
PY
  )
}
[[ -f "$ENV_FILE" ]] && {
  command -v python3 >/dev/null 2>&1 || { printf 'ERROR: Missing required command: python3\n' >&2; exit 1; }
  command -v base64 >/dev/null 2>&1 || { printf 'ERROR: Missing required command: base64\n' >&2; exit 1; }
  parse_env_file
}
[[ -z "$PROCESS_DASHBOARD_AUTH_USER_SET" ]] || DASHBOARD_AUTH_USER="$PROCESS_DASHBOARD_AUTH_USER"
[[ -z "$PROCESS_DASHBOARD_AUTH_PASSWORD_SET" ]] || DASHBOARD_AUTH_PASSWORD="$PROCESS_DASHBOARD_AUTH_PASSWORD"
[[ -z "$PROCESS_BROWSER_TOKEN_SET" ]] || BROWSER_TOKEN="$PROCESS_BROWSER_TOKEN"
HERMES_NAMESPACE="${HERMES_NAMESPACE:-hermes}"
HERMES_DASHBOARD_ENABLED="${HERMES_DASHBOARD_ENABLED:-true}"
HERMES_WEBUI_ENABLED="${HERMES_WEBUI_ENABLED:-true}"
HERMES_BROWSER_ENABLED="${HERMES_BROWSER_ENABLED:-true}"
HERMES_AUTH_MODE="${HERMES_AUTH_MODE:-local-password}"
HERMES_RENDER_DIR="${HERMES_RENDER_DIR:-$ROOT_DIR/.rendered}"
HERMES_RUNTIME_UID="${HERMES_RUNTIME_UID:-10000}"
HERMES_RUNTIME_GID="${HERMES_RUNTIME_GID:-10000}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
require_cmd() {
  local command_name="$1" install_hint
  command -v "$command_name" >/dev/null 2>&1 && return 0
  case "$command_name" in
    kubectl) install_hint='Install kubectl or k3s, then ensure kubectl is in PATH' ;;
    python3) install_hint='Install it with: dnf install python3' ;;
    base64) install_hint='Install it with: dnf install coreutils' ;;
    *) install_hint="Install the package providing '$command_name' and ensure it is in PATH" ;;
  esac
  fail "Missing required command: $command_name. $install_hint."
}
rand_hex() { openssl rand -hex "${1:-32}"; }
generate_password() { openssl rand -base64 "${1:-36}" | tr -d '\n'; }
validate_browser_token_value() {
  local value="$1"
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || fail "BROWSER_TOKEN must be a single-line value"
  [[ -n "$value" ]] || fail "BROWSER_TOKEN must not be empty"
  [[ "$value" =~ ^[A-Za-z0-9._:/=@-]+$ ]] || fail "BROWSER_TOKEN contains characters that cannot be safely persisted in the runtime environment file"
}
is_truthy() { [[ "${1:-}" =~ ^(1|true|TRUE|yes|YES|y|Y|on|ON)$ ]]; }
enabled_deployments() {
  printf '%s\n' hermes-agent
  is_truthy "$HERMES_DASHBOARD_ENABLED" && printf '%s\n' hermes-dashboard
  is_truthy "$HERMES_WEBUI_ENABLED" && printf '%s\n' hermes-webui
  is_truthy "$HERMES_BROWSER_ENABLED" && printf '%s\n' hermes-browser
}
enabled_write_deployments() {
  printf '%s\n' hermes-agent
  is_truthy "$HERMES_DASHBOARD_ENABLED" && printf '%s\n' hermes-dashboard
  is_truthy "$HERMES_WEBUI_ENABLED" && printf '%s\n' hermes-webui
}

usage() {
  cat <<'EOF'
Usage:
  ./maintain.sh status
  ./maintain.sh restart
  ./maintain.sh upgrade
  ./maintain.sh reconcile-api-key --source secret
  ./maintain.sh reconcile-browser-token --source secret
  ./maintain.sh show-passwords
  ./maintain.sh rotate-passwords [--lab] [--prompt|--generate|--from-env]
  ./maintain.sh rotate-browser-token [--generate|--from-env]

Environment:
  ENV_FILE=./hermes.env
  HERMES_NAMESPACE=hermes
  HERMES_PASSWORD_POLICY=production|lab
  DASHBOARD_AUTH_USER/DASHBOARD_AUTH_PASSWORD for Dashboard/WebUI auth
EOF
}

status() {
  kubectl -n "$HERMES_NAMESPACE" get pods,svc,ingress,networkpolicy -o wide
}

get_secret_value() {
  local secret="$1" key="$2" encoded
  encoded="$(kubectl -n "$HERMES_NAMESPACE" get secret "$secret" -o "jsonpath={.data['$key']}")"
  [[ -n "$encoded" ]] || fail "Missing credential: secret=$secret key=$key"
  printf '%s' "$encoded" | base64 -d || fail "Unable to decode credential: secret=$secret key=$key"
}
show_secret_value() {
  local label="$1" secret="$2" key="$3" value
  value="$(get_secret_value "$secret" "$key")"
  printf '%s: %s\n' "$label" "$value"
}

show_passwords() {
  command -v base64 >/dev/null 2>&1 || fail "Missing required command: base64"
  printf '%s\n' "Credentials for namespace $HERMES_NAMESPACE:"
  if [[ "$HERMES_AUTH_MODE" == local-password ]]; then
    show_secret_value "Dashboard/WebUI password" hermes-dashboard-auth password
  else
    printf 'Dashboard/WebUI password: not configured (auth mode %s)\n' "$HERMES_AUTH_MODE"
  fi
  show_secret_value "API server key" hermes-api-server api-key
  show_secret_value "Browserless token" hermes-browser-token token
}

restart() {
  local deployments=() d
  mapfile -t deployments < <(enabled_deployments)
  kubectl -n "$HERMES_NAMESPACE" rollout restart "${deployments[@]/#/deploy/}"
  for d in "${deployments[@]}"; do
    kubectl -n "$HERMES_NAMESPACE" rollout status "deploy/$d" --timeout=600s
  done
}

upgrade() {
  log "Pulling fresh images by restarting deployments. Pin image tags in hermes.env for controlled production upgrades."
  restart
}

create_storage_helper_pod() {
  local name="$1" container="$2"
  cat <<JSON | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  namespace: ${HERMES_NAMESPACE}
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  containers:
  - name: ${container}
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
    volumeMounts:
    - name: home
      mountPath: /opt/data
    - name: workspace
      mountPath: /workspace
  volumes:
  - name: home
    persistentVolumeClaim:
      claimName: hermes-home
  - name: workspace
    persistentVolumeClaim:
      claimName: hermes-workspace
JSON
}

# Shared with reconcile-api-key; retained independently of retired restore commands.
restored_api_key_sync_script() {
  cat <<'SH'
set -eu
umask 077
uid="$1"
gid="$2"
env_file="${3:-/opt/data/.env}"
mode="${4:-write}"
api_key_with_sentinel="$(cat; printf X)"
api_key="${api_key_with_sentinel%X}"
unset api_key_with_sentinel
[ -n "$api_key" ] || exit 1
[ "${#api_key}" -ge 16 ] || exit 1
newline="$(printf '\nX')"
newline="${newline%X}"
carriage_return="$(printf '\rX')"
carriage_return="${carriage_return%X}"
case "$api_key" in *"$newline"*|*"$carriage_return"*) exit 1 ;; esac
case "$api_key" in *[!A-Za-z0-9._:/+=@%-]*) exit 1 ;; esac
source_env="$(mktemp "${env_file}.source.XXXXXX")"
tmp_env=''
trap 'rm -f "${tmp_env:-}" "$source_env"' 0 1 2 15
rm -f "$source_env"
have_source=false
if ln "$env_file" "$source_env" 2>/dev/null; then
  [ -f "$source_env" ] && [ ! -L "$source_env" ] || { rm -f "$source_env"; exit 1; }
  have_source=true
elif [ -e "$env_file" ] || [ -L "$env_file" ]; then
  exit 1
fi
if [ "$mode" = validate-only ]; then
  rm -f "$source_env"
  trap - 0 1 2 15
  exit 0
fi
tmp_env="$(mktemp "${env_file}.XXXXXX")"
found=false
if [ "$have_source" = true ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      API_SERVER_KEY=*)
        if [ "$found" = false ]; then
          printf 'API_SERVER_KEY=%s\n' "$api_key"
          found=true
        fi
        ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$source_env" > "$tmp_env"
fi
if [ "$found" = false ]; then
  printf 'API_SERVER_KEY=%s\n' "$api_key" >> "$tmp_env"
fi
chmod 600 "$tmp_env"
chown "$uid:$gid" "$tmp_env"
mv -f "$tmp_env" "$env_file"
rm -f "$source_env"
trap - 0 1 2 15
SH
}

validate_encoded_api_key() {
  printf '%s' "$1" | python3 -c '
import base64
import binascii
import re
import sys

try:
    raw = base64.b64decode(sys.stdin.read(), validate=True)
    key = raw.decode("ascii")
except (binascii.Error, UnicodeDecodeError):
    raise SystemExit(1)
if len(key) < 16 or not re.fullmatch(r"[A-Za-z0-9._:/+=@%-]+", key):
    raise SystemExit(1)
'
}

browser_cdp_sync_script() {
  cat <<'SH'
set -eu
umask 077
uid="$1"
gid="$2"
home_dir="${3:-/opt/data}"
mode="${4:-write}"
cdp_with_sentinel="$(cat; printf X)"
cdp_url="${cdp_with_sentinel%X}"
unset cdp_with_sentinel
case "$cdp_url" in
  ws://hermes-browser:3000/chromium\?token=*) ;;
  *) exit 1 ;;
esac
token="${cdp_url#ws://hermes-browser:3000/chromium?token=}"
[ -n "$token" ] || exit 1
newline="$(printf '\nX')"
newline="${newline%X}"
carriage_return="$(printf '\rX')"
carriage_return="${carriage_return%X}"
case "$cdp_url" in *"$newline"*|*"$carriage_return"*) exit 1 ;; esac
case "$token" in *[!A-Za-z0-9._:/=@-]*) exit 1 ;; esac
[ -d "$home_dir" ] && [ ! -L "$home_dir" ] || exit 1
[ "$mode" = validate-only ] && exit 0
[ "$mode" = write ] || exit 1

sync_env_file() {
  env_file="$1"
  only_if_present="$2"
  source_env="$(mktemp "${env_file}.source.XXXXXX")"
  tmp_env=''
  trap 'rm -f "${tmp_env:-}" "$source_env"' 0 1 2 15
  rm -f "$source_env"
  have_source=false
  if ln "$env_file" "$source_env" 2>/dev/null; then
    [ -f "$source_env" ] && [ ! -L "$source_env" ] || { rm -f "$source_env"; exit 1; }
    have_source=true
  elif [ -e "$env_file" ] || [ -L "$env_file" ]; then
    exit 1
  fi
  if [ "$only_if_present" = true ]; then
    [ "$have_source" = true ] || { rm -f "$source_env"; trap - 0 1 2 15; return 0; }
    grep -q '^BROWSER_CDP_URL=' "$source_env" || { rm -f "$source_env"; trap - 0 1 2 15; return 0; }
  fi
  tmp_env="$(mktemp "${env_file}.XXXXXX")"
  found=false
  if [ "$have_source" = true ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        BROWSER_CDP_URL=*)
          if [ "$found" = false ]; then
            printf 'BROWSER_CDP_URL=%s\n' "$cdp_url"
            found=true
          fi
          ;;
        *) printf '%s\n' "$line" ;;
      esac
    done < "$source_env" > "$tmp_env"
  fi
  if [ "$found" = false ]; then
    printf 'BROWSER_CDP_URL=%s\n' "$cdp_url" >> "$tmp_env"
  fi
  chmod 600 "$tmp_env"
  chown "$uid:$gid" "$tmp_env"
  mv -f "$tmp_env" "$env_file"
  rm -f "$source_env"
  trap - 0 1 2 15
}

profiles_root="$home_dir/profiles"
if [ -e "$profiles_root" ] || [ -L "$profiles_root" ]; then
  [ -d "$profiles_root" ] && [ ! -L "$profiles_root" ] || exit 1
  for profile_dir in "$profiles_root"/*; do
    if [ ! -e "$profile_dir" ] && [ ! -L "$profile_dir" ]; then
      continue
    fi
    [ -d "$profile_dir" ] && [ ! -L "$profile_dir" ] || exit 1
    [ ! -L "$profile_dir/.env" ] || exit 1
  done
fi

sync_env_file "$home_dir/.env" false
if [ -d "$profiles_root" ]; then
  for profile_dir in "$profiles_root"/*; do
    [ -d "$profile_dir" ] || continue
    env_file="$profile_dir/.env"
    [ -f "$env_file" ] || continue
    sync_env_file "$env_file" true
  done
fi
SH
}

reconcile_api_key() {
  local source='' encoded script revision current_revision reconcile_request secret_snapshot patch app pod runtime_health attempt stable=false
  local helper_pod=hermes-api-key-reconcile
  local -a deployments=()
  while (($#)); do
    case "$1" in
      --source)
        [[ $# -ge 2 ]] || fail '--source requires secret'
        source="$2"; shift 2 ;;
      --source=*) source="${1#*=}"; shift ;;
      *) fail "unknown reconcile-api-key option: $1" ;;
    esac
  done
  [[ "$source" == secret ]] || fail 'reconcile-api-key requires --source secret'
  require_cmd kubectl
  require_cmd python3
  require_cmd base64
  require_cmd openssl
  mapfile -t deployments < <(enabled_write_deployments)
  ((${#deployments[@]} > 0)) || fail 'no internal API-key consumers are enabled'
  [[ "$HERMES_RUNTIME_UID" =~ ^[0-9]+$ ]] || fail 'HERMES_RUNTIME_UID must be numeric'
  [[ "$HERMES_RUNTIME_GID" =~ ^[0-9]+$ ]] || fail 'HERMES_RUNTIME_GID must be numeric'
  for app in "${deployments[@]}"; do
    kubectl -n "$HERMES_NAMESPACE" get deployment "$app" >/dev/null \
      || fail "required internal API consumer Deployment is missing: $app"
  done
  script="$(restored_api_key_sync_script)"

  reconcile_api_key_cleanup() {
    kubectl -n "$HERMES_NAMESPACE" delete pod hermes-api-key-reconcile --ignore-not-found=true --wait=true >/dev/null 2>&1 || true
    unset encoded
  }
  trap reconcile_api_key_cleanup EXIT
  kubectl -n "$HERMES_NAMESPACE" delete pod "$helper_pod" --ignore-not-found=true --wait=true >/dev/null 2>&1 || true
  create_storage_helper_pod "$helper_pod" reconcile
  kubectl -n "$HERMES_NAMESPACE" wait --for=condition=Ready "pod/$helper_pod" --timeout=120s >/dev/null

  for attempt in 1 2 3; do
    secret_snapshot="$(kubectl -n "$HERMES_NAMESPACE" get secret hermes-api-server -o json | python3 -c '
import json
import sys

document = json.load(sys.stdin)
revision = document.get("metadata", {}).get("resourceVersion", "")
encoded = document.get("data", {}).get("api-key", "")
if not isinstance(revision, str) or not isinstance(encoded, str):
    raise SystemExit(1)
print(f"{revision}\t{encoded}", end="")
')" || fail 'Unable to read one consistent API server key Secret snapshot'
    IFS=$'\t' read -r revision encoded <<<"$secret_snapshot"
    unset secret_snapshot
    [[ "$revision" =~ ^[A-Za-z0-9._:-]+$ ]] || fail 'API server key Secret revision is empty or unsafe'
    [[ -n "$encoded" ]] || fail 'API server key Secret is empty'
    validate_encoded_api_key "$encoded" || fail 'API server key Secret is invalid; refusing to replace persistent data'
    printf '%s' "$encoded" | base64 -d | kubectl -n "$HERMES_NAMESPACE" exec -i "$helper_pod" -- \
      sh -c "$script" sh "$HERMES_RUNTIME_UID" "$HERMES_RUNTIME_GID" /opt/data/.env validate-only \
      || fail 'API server key Secret is invalid; refusing to replace persistent data'
    printf '%s' "$encoded" | base64 -d | kubectl -n "$HERMES_NAMESPACE" exec -i "$helper_pod" -- \
      sh -c "$script" sh "$HERMES_RUNTIME_UID" "$HERMES_RUNTIME_GID" /opt/data/.env \
      || fail 'Unable to synchronize API server key into persistent runtime environment'
    unset encoded
    current_revision="$(kubectl -n "$HERMES_NAMESPACE" get secret hermes-api-server -o jsonpath='{.metadata.resourceVersion}')" \
      || fail 'Unable to recheck API server key Secret revision'
    if [[ "$current_revision" == "$revision" ]]; then
      stable=true
      break
    fi
    warn "API server key Secret changed during reconciliation attempt $attempt; retrying from the new Secret snapshot"
  done
  [[ "$stable" == true ]] || fail 'API server key Secret kept changing during reconciliation; no workloads were restarted'
  reconcile_request="$(openssl rand -hex 16)" || fail 'Unable to generate an API key reconciliation request ID'
  [[ "$reconcile_request" =~ ^[a-f0-9]{32}$ ]] || fail 'Generated API key reconciliation request ID is invalid'
  patch="$(printf '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"kube-hermes-setup.example.com/api-key-revision\":\"%s\",\"kube-hermes-setup.example.com/api-key-reconcile-request\":\"%s\"}}}}}' "$revision" "$reconcile_request")"
  for app in "${deployments[@]}"; do
    kubectl -n "$HERMES_NAMESPACE" patch deployment "$app" --type=merge -p "$patch" >/dev/null
  done
  for app in "${deployments[@]}"; do
    kubectl -n "$HERMES_NAMESPACE" rollout status "deploy/$app" --timeout=600s
  done

  for app in "${deployments[@]}"; do
    pod="$(kubectl -n "$HERMES_NAMESPACE" get pods -l app="$app" --field-selector=status.phase=Running -o json | \
      API_KEY_REVISION="$revision" API_KEY_RECONCILE_REQUEST="$reconcile_request" python3 -c '
import json
import os
import sys

revision = os.environ["API_KEY_REVISION"]
reconcile_request = os.environ["API_KEY_RECONCILE_REQUEST"]
for pod in json.load(sys.stdin).get("items", []):
    metadata = pod.get("metadata", {})
    annotations = metadata.get("annotations", {})
    status = pod.get("status", {})
    statuses = status.get("containerStatuses", [])
    pod_ready = any(item.get("type") == "Ready" and item.get("status") == "True" for item in status.get("conditions", []))
    if annotations.get("kube-hermes-setup.example.com/api-key-revision") == revision and annotations.get("kube-hermes-setup.example.com/api-key-reconcile-request") == reconcile_request and pod_ready and statuses and all(item.get("ready") for item in statuses):
        print(metadata.get("name", ""), end="")
        break
')"
    [[ -n "$pod" ]] || fail "no Ready $app Pod carrying the current API key revision and reconciliation request for authentication verification"
    runtime_health="$(kubectl -n "$HERMES_NAMESPACE" exec "$pod" -- sh -c '
      PY="$(command -v python3 || command -v python || true)"
      [ -n "$PY" ] || PY=/opt/hermes/.venv/bin/python
      [ -x "$PY" ] || PY=/app/venv/bin/python
      "$PY" -c '\''
import os
from urllib.request import Request, urlopen
value = os.environ.get("API_SERVER_KEY", os.environ.get("HERMES_API_KEY", ""))
url = os.environ.get("HERMES_API_URL", os.environ.get("GATEWAY_HEALTH_URL", "http://hermes-agent:8642")).rstrip("/") + "/health/detailed"
request = Request(url, headers={"Authorization": f"Bearer {value}"})
with urlopen(request, timeout=10) as response:
    if response.status != 200:
        raise SystemExit(f"health endpoint returned HTTP {response.status}")
print("ok")
'\''
    ' 2>/dev/null || true)"
    [[ "$runtime_health" == ok ]] || fail "$app internal API bearer authentication failed after reconciliation"
  done

  current_revision="$(kubectl -n "$HERMES_NAMESPACE" get secret hermes-api-server -o jsonpath='{.metadata.resourceVersion}')" \
    || fail 'Unable to perform final API server key Secret revision check'
  [[ "$current_revision" == "$revision" ]] \
    || fail 'API server key Secret changed during rollout verification; rerun reconciliation to converge the newer Secret revision'

  trap - EXIT
  reconcile_api_key_cleanup
  unset revision current_revision reconcile_request patch
  log 'Internal API key reconciled from Kubernetes Secret; all enabled consumers authenticate successfully.'
}

reconcile_browser_token() {
  local source='' snapshot token_revision cdp_revision encoded_url current_token_revision current_cdp_revision
  local script reconcile_request patch app pod runtime_result attempt stable=false
  local helper_pod=hermes-browser-token-reconcile
  local -a deployments=()
  while (($#)); do
    case "$1" in
      --source)
        [[ $# -ge 2 ]] || fail '--source requires secret'
        source="$2"; shift 2 ;;
      --source=*) source="${1#*=}"; shift ;;
      *) fail "unknown reconcile-browser-token option: $1" ;;
    esac
  done
  [[ "$source" == secret ]] || fail 'reconcile-browser-token requires --source secret'
  is_truthy "$HERMES_BROWSER_ENABLED" || fail 'Browser component is disabled'
  require_cmd kubectl
  require_cmd python3
  require_cmd base64
  require_cmd openssl
  [[ "$HERMES_RUNTIME_UID" =~ ^[0-9]+$ ]] || fail 'HERMES_RUNTIME_UID must be numeric'
  [[ "$HERMES_RUNTIME_GID" =~ ^[0-9]+$ ]] || fail 'HERMES_RUNTIME_GID must be numeric'
  mapfile -t deployments < <(enabled_deployments)
  for app in "${deployments[@]}"; do
    kubectl -n "$HERMES_NAMESPACE" get deployment "$app" >/dev/null \
      || fail "required Browserless consumer Deployment is missing: $app"
  done
  script="$(browser_cdp_sync_script)"

  reconcile_browser_token_cleanup() {
    kubectl -n "$HERMES_NAMESPACE" delete pod "$helper_pod" --ignore-not-found=true --wait=true >/dev/null 2>&1 || true
    unset encoded_url
  }
  trap reconcile_browser_token_cleanup EXIT
  kubectl -n "$HERMES_NAMESPACE" delete pod "$helper_pod" --ignore-not-found=true --wait=true >/dev/null 2>&1 || true
  create_storage_helper_pod "$helper_pod" reconcile
  kubectl -n "$HERMES_NAMESPACE" wait --for=condition=Ready "pod/$helper_pod" --timeout=120s >/dev/null

  for attempt in 1 2 3; do
    snapshot="$(kubectl -n "$HERMES_NAMESPACE" get secret hermes-browser-token hermes-browser-cdp -o json | python3 -c '
import base64
import binascii
import json
import re
import sys
from urllib.parse import parse_qs, urlsplit

items = {item.get("metadata", {}).get("name"): item for item in json.load(sys.stdin).get("items", [])}
if set(items) != {"hermes-browser-token", "hermes-browser-cdp"}:
    raise SystemExit(1)
token_item = items["hermes-browser-token"]
cdp_item = items["hermes-browser-cdp"]
try:
    token = base64.b64decode(token_item.get("data", {}).get("token", ""), validate=True).decode("ascii")
    encoded_url = cdp_item.get("data", {}).get("BROWSER_CDP_URL", "")
    url = base64.b64decode(encoded_url, validate=True).decode("ascii")
except (binascii.Error, UnicodeDecodeError):
    raise SystemExit(1)
parsed = urlsplit(url)
query = parse_qs(parsed.query, keep_blank_values=True)
if parsed.scheme != "ws" or parsed.hostname != "hermes-browser" or parsed.port != 3000 or parsed.path != "/chromium":
    raise SystemExit(1)
if set(query) != {"token"} or len(query["token"]) != 1 or not token or query["token"][0] != token:
    raise SystemExit(1)
if re.fullmatch(r"[A-Za-z0-9._:/=@-]+", token) is None:
    raise SystemExit(1)
token_revision = token_item.get("metadata", {}).get("resourceVersion", "")
cdp_revision = cdp_item.get("metadata", {}).get("resourceVersion", "")
if not all(isinstance(value, str) and value for value in (token_revision, cdp_revision, encoded_url)):
    raise SystemExit(1)
print(f"{token_revision}\t{cdp_revision}\t{encoded_url}", end="")
')" || fail 'Browserless token and CDP Secrets are malformed or disagree'
    IFS=$'\t' read -r token_revision cdp_revision encoded_url <<<"$snapshot"
    unset snapshot
    [[ "$token_revision" =~ ^[A-Za-z0-9._:-]+$ && "$cdp_revision" =~ ^[A-Za-z0-9._:-]+$ ]] \
      || fail 'Browserless Secret revision is empty or unsafe'
    printf '%s' "$encoded_url" | base64 -d | kubectl -n "$HERMES_NAMESPACE" exec -i "$helper_pod" -- \
      sh -c "$script" sh "$HERMES_RUNTIME_UID" "$HERMES_RUNTIME_GID" /opt/data validate-only \
      || fail 'Browserless CDP Secret is unsafe; refusing to replace persistent data'
    printf '%s' "$encoded_url" | base64 -d | kubectl -n "$HERMES_NAMESPACE" exec -i "$helper_pod" -- \
      sh -c "$script" sh "$HERMES_RUNTIME_UID" "$HERMES_RUNTIME_GID" /opt/data write \
      || fail 'Unable to synchronize Browserless CDP URL into persistent runtime/profile environment'
    unset encoded_url
    current_token_revision="$(kubectl -n "$HERMES_NAMESPACE" get secret hermes-browser-token -o jsonpath='{.metadata.resourceVersion}')" \
      || fail 'Unable to recheck Browserless token Secret revision'
    current_cdp_revision="$(kubectl -n "$HERMES_NAMESPACE" get secret hermes-browser-cdp -o jsonpath='{.metadata.resourceVersion}')" \
      || fail 'Unable to recheck Browserless CDP Secret revision'
    if [[ "$current_token_revision" == "$token_revision" && "$current_cdp_revision" == "$cdp_revision" ]]; then
      stable=true
      break
    fi
    warn "Browserless Secrets changed during reconciliation attempt $attempt; retrying from the new Secret snapshot"
  done
  [[ "$stable" == true ]] || fail 'Browserless Secrets kept changing during reconciliation; no workloads were restarted'
  reconcile_request="$(openssl rand -hex 16)" || fail 'Unable to generate a Browserless reconciliation request ID'
  [[ "$reconcile_request" =~ ^[a-f0-9]{32}$ ]] || fail 'Generated Browserless reconciliation request ID is invalid'
  patch="$(printf '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"kube-hermes-setup.example.com/browser-token-revision\":\"%s\",\"kube-hermes-setup.example.com/browser-cdp-revision\":\"%s\",\"kube-hermes-setup.example.com/browser-token-reconcile-request\":\"%s\"}}}}}' "$token_revision" "$cdp_revision" "$reconcile_request")"
  for app in "${deployments[@]}"; do
    kubectl -n "$HERMES_NAMESPACE" patch deployment "$app" --type=merge -p "$patch" >/dev/null
  done
  for app in "${deployments[@]}"; do
    kubectl -n "$HERMES_NAMESPACE" rollout status "deploy/$app" --timeout=600s
  done

  for app in "${deployments[@]}"; do
    pod="$(kubectl -n "$HERMES_NAMESPACE" get pods -l app="$app" --field-selector=status.phase=Running -o json | \
      BROWSER_TOKEN_REVISION="$token_revision" BROWSER_CDP_REVISION="$cdp_revision" BROWSER_RECONCILE_REQUEST="$reconcile_request" python3 -c '
import json
import os
import sys
expected = {
    "kube-hermes-setup.example.com/browser-token-revision": os.environ["BROWSER_TOKEN_REVISION"],
    "kube-hermes-setup.example.com/browser-cdp-revision": os.environ["BROWSER_CDP_REVISION"],
    "kube-hermes-setup.example.com/browser-token-reconcile-request": os.environ["BROWSER_RECONCILE_REQUEST"],
}
for item in json.load(sys.stdin).get("items", []):
    metadata = item.get("metadata", {})
    status = item.get("status", {})
    statuses = status.get("containerStatuses", [])
    ready = any(condition.get("type") == "Ready" and condition.get("status") == "True" for condition in status.get("conditions", []))
    if ready and statuses and all(entry.get("ready") for entry in statuses) and all(metadata.get("annotations", {}).get(key) == value for key, value in expected.items()):
        print(metadata.get("name", ""), end="")
        break
')"
    [[ -n "$pod" ]] || fail "no Ready $app Pod carrying the current Browserless reconciliation annotations"
    [[ "$app" != hermes-browser ]] || continue
    runtime_result="$(kubectl -n "$HERMES_NAMESPACE" exec "$pod" -- sh -c '
      PY=""
      for candidate in /app/venv/bin/python /opt/hermes/.venv/bin/python "$(command -v python3 || true)" "$(command -v python || true)"; do
        if [ -n "$candidate" ] && [ -x "$candidate" ]; then PY="$candidate"; break; fi
      done
      [ -n "$PY" ] || exit 1
      "$PY" - <<'\''PY'\''
import asyncio
import json
import os
import websockets

async def main():
    async with websockets.connect(os.environ["BROWSER_CDP_URL"], open_timeout=20, close_timeout=2, max_size=1048576) as websocket:
        await websocket.send(json.dumps({"id": 1, "method": "Browser.getVersion"}))
        for _ in range(20):
            payload = json.loads(await asyncio.wait_for(websocket.recv(), 5))
            if payload.get("id") == 1 and payload.get("result", {}).get("product"):
                print("ok")
                return
        raise SystemExit(1)

asyncio.run(main())
PY
    ' 2>/dev/null || true)"
    [[ "$runtime_result" == ok ]] || fail "$app Browserless CDP Browser.getVersion verification failed"
  done

  current_token_revision="$(kubectl -n "$HERMES_NAMESPACE" get secret hermes-browser-token -o jsonpath='{.metadata.resourceVersion}')" \
    || fail 'Unable to perform final Browserless token Secret revision check'
  current_cdp_revision="$(kubectl -n "$HERMES_NAMESPACE" get secret hermes-browser-cdp -o jsonpath='{.metadata.resourceVersion}')" \
    || fail 'Unable to perform final Browserless CDP Secret revision check'
  [[ "$current_token_revision" == "$token_revision" && "$current_cdp_revision" == "$cdp_revision" ]] \
    || fail 'Browserless Secrets changed during rollout verification; rerun reconciliation'

  trap - EXIT
  reconcile_browser_token_cleanup
  unset token_revision cdp_revision current_token_revision current_cdp_revision reconcile_request patch
  log 'Browserless token reconciled from Kubernetes Secrets; persistent profile state and enabled consumers are healthy.'
}

prompt_secret() {
  local label="$1"
  [[ -t 0 ]] || fail "$label requires an interactive TTY. Use --from-env with exported variables or --generate for non-interactive rotation."
  local first second
  while true; do
    read -r -s -p "$label: " first; printf '
' >&2
    read -r -s -p "Confirm $label: " second; printf '
' >&2
    [[ "$first" == "$second" ]] || { printf 'Passwords did not match. Try again.
' >&2; continue; }
    [[ -n "$first" ]] || { printf 'Password must not be empty.
' >&2; continue; }
    printf '%s' "$first"
    return 0
  done
}

secret_from_env() {
  local var_name="$1" value=""
  value="$(printenv "$var_name" 2>/dev/null || true)"
  [[ -n "$value" ]] || fail "$var_name is required with --from-env. Export it before running maintain.sh."
  printf '%s' "$value"
}

password_is_strong() {
  local pass="$1"
  [[ ${#pass} -ge 14 ]] || return 1
  [[ "$pass" =~ [a-z] ]] || return 1
  [[ "$pass" =~ [A-Z] ]] || return 1
  [[ "$pass" =~ [0-9] ]] || return 1
  [[ "$pass" =~ [^a-zA-Z0-9] ]] || return 1
}

allow_weak_password() {
  local mode="${HERMES_PASSWORD_POLICY:-production}"
  [[ "$mode" == "lab" ]] && return 0
  is_truthy "${HERMES_ALLOW_WEAK_PASSWORD:-}" && return 0
  return 1
}

confirm_weak_password_if_interactive() {
  local label="$1" pass="$2" mode="${HERMES_PASSWORD_POLICY:-production}"
  if password_is_strong "$pass"; then
    return 0
  fi
  if allow_weak_password; then
    warn "Weak $label accepted because HERMES_PASSWORD_POLICY=$mode or HERMES_ALLOW_WEAK_PASSWORD is set. Use this only for labs."
    return 0
  fi
  if [[ -t 0 ]]; then
    warn "$label does not meet the production recommendation: >=14 chars with lower/upper/digit/symbol."
    read -r -p "Accept weak $label for a lab/test install? Type 'lab' to continue: " answer
    if [[ "$answer" == "lab" ]]; then
      export HERMES_PASSWORD_POLICY=lab
      warn "Proceeding in lab password mode for this run."
      return 0
    fi
  fi
  fail "Weak $label rejected. Use a stronger value, or set HERMES_PASSWORD_POLICY=lab / HERMES_ALLOW_WEAK_PASSWORD=true for lab systems."
}

apply_dashboard_auth_secret() {
  local user="$1" pass="$2" tmpdir
  tmpdir="$(mktemp -d)"
  chmod 700 "$tmpdir"
  trap 'rm -rf -- "$tmpdir"' ERR
  printf '%s' "$user" > "$tmpdir/username"
  printf '%s' "$pass" > "$tmpdir/password"
  kubectl -n "$HERMES_NAMESPACE" create secret generic hermes-dashboard-auth \
    --from-file=username="$tmpdir/username" \
    --from-file=password="$tmpdir/password" \
    --dry-run=client -o yaml | kubectl apply -f -
  trap - ERR
  rm -rf -- "$tmpdir"
}

rotate_passwords() {
  [[ "$HERMES_AUTH_MODE" == local-password ]] || fail "rotate-passwords is available only in local-password mode; current mode is $HERMES_AUTH_MODE"
  local input_mode="auto"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --lab) export HERMES_PASSWORD_POLICY=lab ;;
      --generate) input_mode="generate" ;;
      --prompt) input_mode="prompt" ;;
      --from-env|--env) input_mode="env" ;;
      --help|-h)
        cat <<'EOF'
Usage:
  ./maintain.sh rotate-passwords [--lab] [--prompt|--generate|--from-env]

Passwords controlled:
  Dashboard + WebUI: DASHBOARD_AUTH_USER / DASHBOARD_AUTH_PASSWORD

Input modes:
  --prompt    Always ask with hidden interactive prompts. This is the default when stdin is a TTY.
  --generate  Generate a new random password and store it only in the Kubernetes Secret.
  --from-env  Read DASHBOARD_AUTH_PASSWORD from environment variables. Use this for CI/non-interactive automation.

Important:
  Values present in hermes.env are NOT silently reused in interactive mode. This prevents a "rotation" that applies the old password again.
  Production policy rejects weak passwords by default. For labs, use --lab or:
    HERMES_PASSWORD_POLICY=lab ./maintain.sh rotate-passwords
EOF
        return 0 ;;
      *) fail "unknown rotate-passwords option: $1" ;;
    esac
    shift
  done

  if [[ "$input_mode" == "auto" ]]; then
    if [[ -t 0 ]]; then
      input_mode="prompt"
    else
      input_mode="env"
    fi
  fi

  local dashboard_user="${DASHBOARD_AUTH_USER:-admin}"
  local dashboard_pass=""

  case "$input_mode" in
    generate)
      dashboard_pass="$(generate_password 36)"
      ;;
    env)
      dashboard_pass="$(secret_from_env DASHBOARD_AUTH_PASSWORD)"
      ;;
    prompt)
      dashboard_pass="$(prompt_secret 'Dashboard/WebUI password')"
      ;;
    *) fail "unsupported password input mode: $input_mode" ;;
  esac

  confirm_weak_password_if_interactive "Dashboard/WebUI password" "$dashboard_pass"
  local auth_deployments=() d
  is_truthy "$HERMES_DASHBOARD_ENABLED" && auth_deployments+=(deploy/hermes-dashboard)
  is_truthy "$HERMES_WEBUI_ENABLED" && auth_deployments+=(deploy/hermes-webui)
  ((${#auth_deployments[@]} > 0)) || fail "Dashboard and WebUI are both disabled; there is no application password to rotate"
  apply_dashboard_auth_secret "$dashboard_user" "$dashboard_pass"
  kubectl -n "$HERMES_NAMESPACE" rollout restart "${auth_deployments[@]}"
  for d in "${auth_deployments[@]}"; do
    kubectl -n "$HERMES_NAMESPACE" rollout status "$d" --timeout=300s
  done

  cat <<EOF
Rotated Dashboard/WebUI password secret.
Input mode:          $input_mode
Dashboard/WebUI:     updated for dashboard user '$dashboard_user'; WebUI password uses the same secret

Plaintext passwords were not printed. Store env-provided/generated values in your password manager.
The generated password is stored only in Kubernetes Secret hermes-dashboard-auth.
Show the current credentials with:
  ./maintain.sh show-passwords
For lab passwords use --lab or HERMES_PASSWORD_POLICY=lab explicitly.
EOF
}
apply_browser_secret_file() {
  local secret="$1" key="$2" source_file="$3"
  kubectl -n "$HERMES_NAMESPACE" create secret generic "$secret" \
    --from-file="$key=$source_file" \
    --dry-run=client -o yaml | kubectl apply -f -
}

restore_browser_secret_pair() {
  local old_token_file="$1" old_cdp_file="$2" restored=true
  apply_browser_secret_file hermes-browser-token token "$old_token_file" || restored=false
  apply_browser_secret_file hermes-browser-cdp BROWSER_CDP_URL "$old_cdp_file" || restored=false
  [[ "$restored" == true ]]
}

apply_browser_secret_pair() {
  local new_token_file="$1" new_cdp_file="$2" workdir="$3"
  local old_token_file="$workdir/old-token" old_cdp_file="$workdir/old-BROWSER_CDP_URL"
  install -d -m 0700 "$workdir"
  get_secret_value hermes-browser-token token > "$old_token_file" \
    || fail 'Unable to snapshot the current Browserless token Secret before rotation'
  get_secret_value hermes-browser-cdp BROWSER_CDP_URL > "$old_cdp_file" \
    || fail 'Unable to snapshot the current Browserless CDP Secret before rotation'
  chmod 600 "$old_token_file" "$old_cdp_file"
  local old_token old_cdp
  old_token="$(<"$old_token_file")"
  old_cdp="$(<"$old_cdp_file")"
  validate_browser_token_value "$old_token"
  [[ "$old_cdp" == "ws://hermes-browser:3000/chromium?token=${old_token}" ]] \
    || fail 'Current Browserless token and CDP Secrets disagree; refusing rotation before any update'
  unset old_token old_cdp

  if ! apply_browser_secret_file hermes-browser-token token "$new_token_file"; then
    if restore_browser_secret_pair "$old_token_file" "$old_cdp_file"; then
      fail 'Browserless token Secret update failed; the previous pair was restored'
    fi
    fail 'CRITICAL: Browserless token Secret update and rollback both failed; restore the pair from backup before restarting workloads'
  fi
  if ! apply_browser_secret_file hermes-browser-cdp BROWSER_CDP_URL "$new_cdp_file"; then
    if restore_browser_secret_pair "$old_token_file" "$old_cdp_file"; then
      fail 'Browserless CDP Secret update failed; the previous pair was restored'
    fi
    fail 'CRITICAL: Browserless CDP Secret update and rollback both failed; restore the pair from backup before restarting workloads'
  fi
}

rotate_browser_token() {
  is_truthy "$HERMES_BROWSER_ENABLED" || fail "Browser component is disabled"
  local input_mode=generate token='' tmpdir
  while (($#)); do
    case "$1" in
      --generate) input_mode=generate ;;
      --from-env) input_mode=env ;;
      *) fail "unknown rotate-browser-token option: $1" ;;
    esac
    shift
  done
  case "$input_mode" in
    generate) token="$(rand_hex 32)" ;;
    env)
      [[ -n "$PROCESS_BROWSER_TOKEN_SET" && -n "$PROCESS_BROWSER_TOKEN" ]] \
        || fail 'rotate-browser-token --from-env requires BROWSER_TOKEN in the process environment'
      token="$PROCESS_BROWSER_TOKEN"
      ;;
  esac
  validate_browser_token_value "$token"
  local cdp="ws://hermes-browser:3000/chromium?token=${token}"
  tmpdir="$(mktemp -d -t hermes-browser-token.XXXXXX)"
  chmod 700 "$tmpdir"
  trap 'rm -rf -- "$tmpdir"' EXIT
  printf '%s' "$token" > "$tmpdir/token"
  printf '%s' "$cdp" > "$tmpdir/BROWSER_CDP_URL"
  chmod 600 "$tmpdir/token" "$tmpdir/BROWSER_CDP_URL"
  apply_browser_secret_pair "$tmpdir/token" "$tmpdir/BROWSER_CDP_URL" "$tmpdir/rollback"
  trap - EXIT
  rm -rf -- "$tmpdir"
  reconcile_browser_token --source secret
  echo "Rotated Browserless token. CDP endpoint: ws://hermes-browser:3000/chromium?token=<redacted>"
}

if [[ "${HERMES_MAINTAIN_LIB_ONLY:-false}" != true ]]; then
  cmd="${1:-}"
  shift || true
  case "$cmd" in
    status) status "$@" ;;
    show-passwords) show_passwords "$@" ;;
    restart) restart "$@" ;;
    upgrade) upgrade "$@" ;;
    reconcile-api-key) reconcile_api_key "$@" ;;
    reconcile-browser-token) reconcile_browser_token "$@" ;;
    rotate-passwords) rotate_passwords "$@" ;;
    rotate-browser-token) rotate_browser_token "$@" ;;
    -h|--help|help|"") usage ;;
    *) usage; fail "unknown command: $cmd" ;;
  esac
fi
