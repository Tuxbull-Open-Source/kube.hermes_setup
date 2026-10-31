#!/usr/bin/env bash
# Purpose: Operate and inspect an existing Hermes Kubernetes/K3s deployment.
# Scope: Provide status, restart/upgrade, backup/restore, credential display and rotation,
#        while keeping operations constrained to the configured namespace.
# Requirements: Bash, kubectl, age, Python 3, base64, OpenSSL, and sha256sum where applicable.
# Usage: ./maintain.sh {status|show-passwords|restart|upgrade|backup|extract|restore|reconcile-api-key|reconcile-browser-token|rotate-passwords|rotate-browser-token}
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
    age) install_hint='Install it on Fedora/RHEL with: dnf install age' ;;
    kubectl) install_hint='Install kubectl or k3s, then ensure kubectl is in PATH' ;;
    python3) install_hint='Install it with: dnf install python3' ;;
    sha256sum) install_hint='Install it with: dnf install coreutils' ;;
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
validate_backup_archive() {
  local archive="$1"
  python3 - "$archive" <<'PY'
import posixpath
import sys
import tarfile

archive = sys.argv[1]
allowed = ("opt/data", "workspace", "metadata")
try:
    with tarfile.open(archive, "r:gz") as stream:
        for member in stream.getmembers():
            name = member.name.replace("\\", "/")
            if name.startswith("/") or any(part in {".", ".."} for part in name.split("/")):
                raise SystemExit(f"unsafe archive path: {member.name}")
            normalized = posixpath.normpath(name)
            if not any(normalized == root or normalized.startswith(root + "/") for root in allowed):
                raise SystemExit(f"archive path outside allowed roots: {member.name}")
            if member.issym() or member.islnk():
                raise SystemExit(f"links are not allowed in backup archives: {member.name}")
            if not (member.isdir() or member.isfile()):
                raise SystemExit(f"unsupported archive entry: {member.name}")
except (OSError, tarfile.TarError) as exc:
    raise SystemExit(f"invalid backup archive: {exc}")
PY
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
  ./maintain.sh backup <backup.age> [--data-only] [--password-prompt|--password-file PATH|--password-stdin]
  ./maintain.sh reconcile-api-key --source secret
  ./maintain.sh reconcile-browser-token --source secret
  ./maintain.sh restore <backup.age> [--full|--data-only] [--dry-run] [--force]
      [--password-prompt|--password-file PATH|--password-stdin]
  ./maintain.sh extract <backup.age> --output-dir PATH [--component data|config|bootstrap|full]
      [--password-prompt|--password-file PATH|--password-stdin] [--dry-run]
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

prepare_backup_password() {
  local mode=prompt password='' password_source=''
  BACKUP_PASSWORD_TMP="$(mktemp -d -t hermes-backup-password.XXXXXX)"
  chmod 700 "$BACKUP_PASSWORD_TMP"
  while (($#)); do
    case "$1" in
      --password-prompt) mode=prompt; shift ;;
      --password-stdin) mode=stdin; shift ;;
      --password-file)
        [[ $# -ge 2 ]] || fail '--password-file requires a path'
        mode=file; password_source="$2"; shift 2 ;;
      --password-file=*) mode=file; password_source="${1#*=}"; shift ;;
      *) fail "unknown backup password option: $1" ;;
    esac
  done
  case "$mode" in
    prompt)
      [[ -t 0 ]] || fail 'interactive password prompt requires a TTY; use --password-stdin or --password-file for automation'
      read -r -s -p 'Backup passphrase: ' password
      printf '\n' >&2
      ;;
    stdin) IFS= read -r password || true ;;
    file)
      [[ -f "$password_source" ]] || fail "password file not found: $password_source"
      local file_mode
      file_mode="$(stat -c '%a' "$password_source")"
      [[ "$file_mode" =~ ^6[04]0$ ]] || fail "password file must be owner-readable only (mode 600 or 640)"
      IFS= read -r password < "$password_source" || true
      ;;
  esac
  [[ -n "$password" ]] || fail 'backup encryption password must not be empty'
  printf '%s\n' "$password" > "$BACKUP_PASSWORD_TMP/password"
  chmod 600 "$BACKUP_PASSWORD_TMP/password"
  unset password
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

snapshot_kubernetes_state() {
  local raw_dir="$1" snapshot="$2" version_json="$3" resource
  mkdir -p "$raw_dir"
  kubectl version -o json > "$version_json" || fail 'Unable to read Kubernetes server version'
  python3 - "$version_json" "$raw_dir/cluster-version.txt" <<'PY'
import json, sys
from pathlib import Path
data = json.loads(Path(sys.argv[1]).read_text())
version = data.get('serverVersion', {}).get('gitVersion', '')
if not version or '+k3s' not in version:
    raise SystemExit('Kubernetes server is not a K3s version; full rollback requires a K3s server')
Path(sys.argv[2]).write_text(version + '\n')
PY
  kubectl get namespace "$HERMES_NAMESPACE" -o json > "$raw_dir/namespace.json"
  for resource in pvc deployment service job ingress networkpolicy serviceaccount secret; do
    if [[ "$resource" == secret ]]; then
      kubectl -n "$HERMES_NAMESPACE" get "$resource" -o json > "$raw_dir/$resource.json" || fail 'Unable to read Kubernetes Secrets for a recoverable backup'
    else
      kubectl -n "$HERMES_NAMESPACE" get "$resource" -o json --ignore-not-found > "$raw_dir/$resource.json" || true
    fi
  done
  kubectl -n "$HERMES_NAMESPACE" get middleware -o json --ignore-not-found > "$raw_dir/middleware.json" || true
  python3 "$ROOT_DIR/scripts/kube_snapshot.py" snapshot "$raw_dir" "$snapshot" "$HERMES_NAMESPACE"
  validate_snapshot_api_key "$snapshot" || fail 'Backup snapshot API server key validation failed'
}

# Hermes-specific state included by `backup --data-only` / `restore --data-only`.
# Deliberately excludes reproducible runtime software that a fresh install.sh
# rebuilds on its own: addon-venv, node/npm/npx, uv, LSP servers, hermes-managed
# wrapper bin, and disposable caches/logs. Paths are relative to the PVC roots
# (opt/data, workspace) exactly like the full-backup archive layout.
readonly DATA_ONLY_PATHS=(
  "opt/data/config.yaml"
  "opt/data/SOUL.md"
  "opt/data/auth.json"
  "opt/data/install_id"
  "opt/data/webui/sessions"
  "opt/data/webui/settings.json"
  "opt/data/webui/shares"
  "opt/data/webui/workspaces.json"
  "opt/data/webui/extensions"
  "opt/data/webui/extension-overrides.json"
  "opt/data/webui/extension-install-manifest.json"
  "opt/data/webui/last_workspace.txt"
  "opt/data/webui/media_snapshots"
  "opt/data/profiles"
  "opt/data/skills"
  "opt/data/memories"
  "opt/data/cron"
  "opt/data/plugin-data"
  "opt/data/hooks"
  "opt/data/plans"
  "opt/data/kanban"
  "opt/data/kanban.db"
  "opt/data/state.db"
  "opt/data/projects.db"
  "opt/data/response_store.db"
  "opt/data/verification_evidence.db"
  "opt/data/home"
  "opt/data/pairing"
  "opt/data/channel_directory.json"
  "opt/data/.ssh"
  "workspace"
)

backup() {
  local out='' plain checksum tmpdir snapshot data_only=false
  local -a password_args=()
  while (($#)); do
    case "$1" in
      --data-only) data_only=true; shift ;;
      --password-prompt|--password-stdin|--password-file|--password-file=*) password_args+=("$1"); [[ "$1" == '--password-file' ]] && { [[ $# -ge 2 ]] || fail '--password-file requires a path'; password_args+=("$2"); shift; }; shift ;;
      -*) fail "unknown backup option: $1" ;;
      *) [[ -z "$out" ]] || fail 'backup path specified more than once'; out="$1"; shift ;;
    esac
  done
  [[ -n "$out" ]] || fail 'backup path required'
  require_cmd age
  require_cmd sha256sum
  require_cmd kubectl
  require_cmd python3
  mkdir -p "$(dirname "$out")"
  checksum="${out}.sha256"
  tmpdir="$(mktemp -d -t hermes-backup.XXXXXX)"
  plain="$tmpdir/hermes-backup.tgz"
  prepare_backup_password "${password_args[@]}"
  backup_cleanup() {
    kubectl -n "$HERMES_NAMESPACE" delete pod hermes-backup --ignore-not-found=true --wait=true >/dev/null 2>&1 || true
    rm -rf -- "$tmpdir" "$BACKUP_PASSWORD_TMP"
  }
  backup_on_exit() {
    local status=$?
    backup_cleanup
    trap - EXIT
    exit "$status"
  }
  trap backup_on_exit EXIT
  kubectl -n "$HERMES_NAMESPACE" delete pod hermes-backup --ignore-not-found=true --wait=true >/dev/null 2>&1 || true
  create_storage_helper_pod hermes-backup backup
  kubectl -n "$HERMES_NAMESPACE" wait --for=condition=Ready pod/hermes-backup --timeout=120s >/dev/null
  if [[ "$data_only" == true ]]; then
    printf '%s\n' "${DATA_ONLY_PATHS[@]}" | kubectl -n "$HERMES_NAMESPACE" exec -i hermes-backup -- sh -c 'umask 077; rm -rf /tmp/hermes-backup-stage; mkdir -p /tmp/hermes-backup-stage; cd /; while IFS= read -r p; do [ -e "$p" ] || continue; mkdir -p "/tmp/hermes-backup-stage/$(dirname "$p")"; cp -a "$p" "/tmp/hermes-backup-stage/$p"; done; cd /tmp/hermes-backup-stage; find . -mindepth 1 -print | sed "s#^\./##" | tar --no-recursion -T - -czf /tmp/hermes-backup.tgz; chmod 600 /tmp/hermes-backup.tgz'
  else
    kubectl -n "$HERMES_NAMESPACE" exec hermes-backup -- sh -c 'umask 077; rm -rf /tmp/hermes-backup-stage; mkdir -p /tmp/hermes-backup-stage; cd /; find opt/data workspace -type f -exec sh -c '\''source="$1"; target="/tmp/hermes-backup-stage/$source"; mkdir -p "$(dirname "$target")"; cat "$source" > "$target"'\'' sh {} \;; cd /tmp/hermes-backup-stage; find . -type f -print | tar -T - -czf /tmp/hermes-backup.tgz; chmod 600 /tmp/hermes-backup.tgz'
  fi
  kubectl -n "$HERMES_NAMESPACE" cp hermes-backup:/tmp/hermes-backup.tgz "$tmpdir/cluster.tgz" -c backup >/dev/null
  chmod 600 "$tmpdir/cluster.tgz"
  mkdir -p "$tmpdir/stage/metadata"
  tar -xzf "$tmpdir/cluster.tgz" -C "$tmpdir/stage"
  if [[ "$data_only" != true ]]; then
    mkdir -p "$tmpdir/stage/metadata/kubernetes"
    snapshot="$tmpdir/stage/metadata/kubernetes/resources.json"
    snapshot_kubernetes_state "$tmpdir/raw" "$snapshot" "$tmpdir/version.json"
    cp "$tmpdir/raw/cluster-version.txt" "$tmpdir/stage/metadata/kubernetes/cluster-version.txt"
  fi
  if [[ -f "$ROOT_DIR/current_config/hermes.env" ]]; then
    cp -a "$ROOT_DIR/current_config/hermes.env" "$tmpdir/stage/metadata/hermes.env"
  elif [[ -f "$ROOT_DIR/hermes.env" ]]; then
    cp -a "$ROOT_DIR/hermes.env" "$tmpdir/stage/metadata/hermes.env"
  fi
  [[ -f "$ROOT_DIR/configuration_answers" ]] && cp -a "$ROOT_DIR/configuration_answers" "$tmpdir/stage/metadata/configuration_answers"
  [[ -d "$ROOT_DIR/current_config/bootstrap" ]] && cp -a "$ROOT_DIR/current_config/bootstrap" "$tmpdir/stage/metadata/bootstrap"
  printf 'namespace=%s\ncreated_at=%s\nscope=%s\n' "$HERMES_NAMESPACE" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$([[ "$data_only" == true ]] && echo data-only || echo full)" > "$tmpdir/stage/metadata/backup-info.txt"
  chmod -R go-rwx "$tmpdir/stage/metadata"
  tar -czf "$plain" -C "$tmpdir/stage" opt/data workspace metadata
  chmod 600 "$plain"
  # The wrapper supplies the passphrase through a private PTY, never argv or logs.
  python3 "$ROOT_DIR/scripts/age_passphrase.py" "$BACKUP_PASSWORD_TMP/password" -- \
    age --passphrase --armor --output "$out" "$plain"
  chmod 600 "$out"
  sha256sum "$out" > "$checksum"
  chmod 600 "$checksum"
  sha256sum -c "$checksum"
  trap - EXIT
  backup_cleanup
  ls -lh "$out" "$checksum"
}

extract_backup() {
  local in='' output_dir='' component='' dry_run=false tmpdir='' plain='' arg
  local -a password_args=()
  while (($#)); do
    case "$1" in
      --output-dir)
        [[ $# -ge 2 ]] || fail '--output-dir requires a path'
        output_dir="$2"; shift 2 ;;
      --output-dir=*) output_dir="${1#*=}"; shift ;;
      --component)
        [[ $# -ge 2 ]] || fail '--component requires data, config, or bootstrap'
        component="$2"; shift 2 ;;
      --component=*) component="${1#*=}"; shift ;;
      --full) component=full; shift ;;
      --dry-run) dry_run=true; shift ;;
      --password-prompt|--password-stdin|--password-file|--password-file=*)
        password_args+=("$1")
        if [[ "$1" == '--password-file' ]]; then
          [[ $# -ge 2 ]] || fail '--password-file requires a path'
          password_args+=("$2"); shift
        fi
        shift ;;
      *)
        [[ -z "$in" ]] || fail 'backup path specified more than once'
        in="$1"; shift ;;
    esac
  done
  [[ -f "$in" ]] || fail 'backup file required'
  [[ -n "$output_dir" ]] || fail '--output-dir is required for extract'
  [[ "$component" == data || "$component" == config || "$component" == bootstrap || "$component" == full ]] || fail '--component or --full is required for extract'
  require_cmd age
  require_cmd python3
  tmpdir="$(mktemp -d -t hermes-extract.XXXXXX)"
  plain="$tmpdir/hermes-backup.tgz"
  extract_cleanup() { rm -rf -- "$tmpdir" "$BACKUP_PASSWORD_TMP"; }
  extract_on_exit() { local status=$?; extract_cleanup; trap - EXIT; exit "$status"; }
  trap extract_on_exit EXIT
  prepare_backup_password "${password_args[@]}"
  python3 "$ROOT_DIR/scripts/age_passphrase.py" "$BACKUP_PASSWORD_TMP/password" -- \
    age --decrypt --output "$plain" "$in" >/dev/null
  validate_backup_archive "$plain" || fail 'backup archive validation failed'
  if [[ -e "$output_dir" && ! -d "$output_dir" ]]; then
    fail "extract output path is not a directory: $output_dir"
  fi
  if [[ "$dry_run" != true ]] && [[ -d "$output_dir" ]] && [[ -n "$(find "$output_dir" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    fail "extract output directory is not empty: $output_dir"
  fi
  if [[ "$dry_run" == true ]]; then
    printf 'Backup: valid\nMode: extract\nComponent: %s\nOutput directory: %s\nNo files written: dry-run\n' "$component" "$output_dir"
    trap - EXIT
    extract_cleanup
    return 0
  fi
  mkdir -p "$output_dir"
  chmod 700 "$output_dir"
  python3 - "$plain" "$output_dir" "$component" <<'PY'
import os
import shutil
import sys
import tarfile

archive, destination, component = sys.argv[1:]
selected = {
    "data": ("opt/data", "workspace"),
    "config": ("metadata/hermes.env", "metadata/configuration_answers", "metadata/backup-info.txt"),
    "bootstrap": ("metadata/bootstrap",),
    "full": ("opt/data", "workspace", "metadata"),
}[component]

def choose(name):
    return any(name == root or name.startswith(root + "/") for root in selected)

def mapped(name):
    if name.startswith("metadata/"):
        return name[len("metadata/"):]
    return name

with tarfile.open(archive, "r:gz") as stream:
    for member in stream.getmembers():
        if not choose(member.name):
            continue
        target = os.path.join(destination, mapped(member.name))
        if member.isdir():
            os.makedirs(target, mode=0o700, exist_ok=True)
            continue
        if not member.isfile():
            raise SystemExit(f"unsupported selected archive entry: {member.name}")
        os.makedirs(os.path.dirname(target), mode=0o700, exist_ok=True)
        source = stream.extractfile(member)
        if source is None:
            raise SystemExit(f"unable to read selected archive entry: {member.name}")
        with open(target, "wb") as output:
            shutil.copyfileobj(source, output)
        os.chmod(target, member.mode & 0o700 or 0o600)
PY
  printf 'Extracted component %s to %s\n' "$component" "$output_dir"
  trap - EXIT
  extract_cleanup
}
validate_snapshot_api_key() {
  python3 - "$1" <<'PY'
import base64
import binascii
import json
import re
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
matches = [
    item for item in data.get("items", [])
    if item.get("kind") == "Secret" and item.get("metadata", {}).get("name") == "hermes-api-server"
]
if len(matches) != 1:
    raise SystemExit("Kubernetes snapshot must contain exactly one hermes-api-server Secret")
encoded = matches[0].get("data", {}).get("api-key", "")
try:
    raw = base64.b64decode(encoded, validate=True)
    key = raw.decode("ascii")
except (binascii.Error, UnicodeDecodeError):
    raise SystemExit("Kubernetes snapshot API server key is malformed")
if len(key) < 16:
    raise SystemExit("Kubernetes snapshot API server key is shorter than 16 characters")
if not re.fullmatch(r"[A-Za-z0-9._:/+=@%-]+", key):
    raise SystemExit("Kubernetes snapshot API server key cannot be safely persisted")
PY
}

restore_kubernetes_snapshot() {
  local snapshot="$1" tmpdir="$2" force="$3" dry_run="$4" backup_version='' current_version namespace_json resources_json backup_namespace namespace_state
  validate_snapshot_api_key "$snapshot/resources.json" || fail 'Kubernetes snapshot API server key validation failed before apply'
  if [[ -f "$snapshot/cluster-version.txt" ]]; then
    backup_version="$(tr -d '[:space:]' < "$snapshot/cluster-version.txt")"
  elif [[ "$force" == true ]]; then
    warn 'K3s version metadata is missing; continuing because --force was specified'
    backup_version='unknown'
  else
    fail 'K3s version metadata is missing from the backup'
  fi
  current_version="$(kubectl version -o json | python3 -c 'import json,sys; print(json.load(sys.stdin).get("serverVersion", {}).get("gitVersion", ""))')" || fail 'Unable to read Kubernetes server version'
  if [[ -z "$current_version" || "$current_version" != *+k3s* ]]; then
    if [[ "$force" == true ]]; then
      warn "Kubernetes server is not a detectable K3s version; continuing because --force was specified"
    else
      fail 'Kubernetes server is not a detectable K3s version; full rollback requires K3s'
    fi
  elif [[ "$backup_version" != unknown && "$current_version" != "$backup_version" ]]; then
    if [[ "$force" == true ]]; then
      warn "Forcing full rollback across K3s versions: backup=$backup_version current=$current_version"
    else
      fail "K3s version mismatch: backup=$backup_version current=$current_version; rerun with --force to override the compatibility gate"
    fi
  fi
  namespace_json="$tmpdir/namespace.json"
  resources_json="$tmpdir/resources.json"
  python3 "$ROOT_DIR/scripts/kube_snapshot.py" split "$snapshot/resources.json" "$namespace_json" "$resources_json"
  backup_namespace="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["metadata"]["name"])' "$namespace_json")" || fail 'Kubernetes snapshot Namespace is malformed'
  if [[ "$backup_namespace" != "$HERMES_NAMESPACE" ]]; then
    if [[ "$force" == true ]]; then
      warn "Forcing restore into backup Namespace: backup=$backup_namespace configured=$HERMES_NAMESPACE"
      HERMES_NAMESPACE="$backup_namespace"
    else
      fail "backup namespace=$backup_namespace does not match configured namespace=$HERMES_NAMESPACE; rerun with --force to override the namespace gate"
    fi
  fi
  if [[ "$dry_run" == true ]]; then
    local namespace_state
    namespace_state="$(kubectl get namespace "$HERMES_NAMESPACE" --ignore-not-found -o name)"
    printf 'Full rollback preflight: valid\nK3s backup version: %s\nK3s current version: %s\nNamespace: %s\nResources: %s\nNo Kubernetes changes: dry-run\n' "$backup_version" "$current_version" "${namespace_state:-absent; would create}" "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["items"]))' "$resources_json")"
    return 0
  fi
  kubectl apply -f "$namespace_json" >/dev/null
  kubectl apply -f "$resources_json" >/dev/null
  log "Applied encrypted Kubernetes resource and credential snapshot"
}

refresh_restored_api_key_revisions() {
  local revision d patch
  revision="$(kubectl -n "$HERMES_NAMESPACE" get secret hermes-api-server -o jsonpath='{.metadata.resourceVersion}')" || fail 'Unable to read restored API server key Secret revision'
  [[ "$revision" =~ ^[A-Za-z0-9._:-]+$ ]] || fail 'Restored API server key Secret revision is empty or unsafe'
  patch="$(printf '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"kube-hermes-setup.example.com/api-key-revision\":\"%s\"}}}}}' "$revision")"
  for d in "$@"; do
    case "$d" in
      hermes-agent|hermes-dashboard|hermes-webui)
        kubectl -n "$HERMES_NAMESPACE" patch deployment "$d" --type=merge -p "$patch" >/dev/null
        ;;
    esac
  done
}

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

prepare_restored_api_key_sync() {
  local encoded script
  encoded="$(kubectl -n "$HERMES_NAMESPACE" get secret hermes-api-server -o "jsonpath={.data['api-key']}")" || fail 'Unable to read restored API server key Secret'
  [[ -n "$encoded" ]] || fail 'Restored API server key Secret is empty'
  validate_encoded_api_key "$encoded" || fail 'Restored API server key Secret is invalid; refusing to replace persistent data'
  script="$(restored_api_key_sync_script)"
  printf '%s' "$encoded" | base64 -d | kubectl -n "$HERMES_NAMESPACE" exec -i hermes-restore -- sh -c "$script" sh "$HERMES_RUNTIME_UID" "$HERMES_RUNTIME_GID" /opt/data/.env validate-only \
    || fail 'Restored API server key Secret is invalid; refusing to replace persistent data'
  RESTORED_API_KEY_ENCODED="$encoded"
}

sync_restored_api_key() {
  local encoded script
  encoded="${RESTORED_API_KEY_ENCODED:-}"
  [[ -n "$encoded" ]] || fail 'Restored API server key was not validated before persistent data replacement'
  script="$(restored_api_key_sync_script)"
  printf '%s' "$encoded" | base64 -d | kubectl -n "$HERMES_NAMESPACE" exec -i hermes-restore -- sh -c "$script" sh "$HERMES_RUNTIME_UID" "$HERMES_RUNTIME_GID" \
    || fail 'Unable to synchronize restored API server key into persistent runtime environment'
  unset RESTORED_API_KEY_ENCODED
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

restore() {
  local in='' plain='' tmpdir='' arg full=false dry_run=false force=false data_only=false
  local -a password_args=()
  while (($#)); do
    case "$1" in
      --full) full=true; shift ;;
      --data-only) data_only=true; shift ;;
      --dry-run) dry_run=true; shift ;;
      --force) force=true; shift ;;
      --password-prompt|--password-stdin|--password-file|--password-file=*) password_args+=("$1"); [[ "$1" == '--password-file' ]] && { [[ $# -ge 2 ]] || fail '--password-file requires a path'; password_args+=("$2"); shift; }; shift ;;
      -*) fail "unknown restore option: $1" ;;
      *) [[ -z "$in" ]] || fail 'restore path specified more than once'; in="$1"; shift ;;
    esac
  done
  [[ -f "$in" ]] || fail "backup file required"
  [[ "$full" == true && "$data_only" == true ]] && fail '--full and --data-only are mutually exclusive'
  require_cmd age
  require_cmd python3
  require_cmd base64
  if [[ "$full" == true || "$dry_run" == true ]] && ! [[ "$data_only" == true && "$dry_run" == true ]]; then
    require_cmd kubectl
  fi
  [[ "$dry_run" == false || "$full" == true || "$data_only" == true ]] || fail '--dry-run for restore requires --full or --data-only'
  tmpdir="$(mktemp -d -t hermes-restore.XXXXXX)"
  plain="$tmpdir/hermes-backup.tgz"
  prepare_backup_password "${password_args[@]}"
  restore_local_cleanup() { rm -rf -- "$tmpdir" "$BACKUP_PASSWORD_TMP"; }
  restore_local_on_exit() { local status=$?; restore_local_cleanup; trap - EXIT; exit "$status"; }
  trap restore_local_on_exit EXIT
  python3 "$ROOT_DIR/scripts/age_passphrase.py" "$BACKUP_PASSWORD_TMP/password" -- \
    age --decrypt --output "$plain" "$in"
  validate_backup_archive "$plain" || fail "decrypted backup archive validation failed"
  mkdir -p "$tmpdir/payload"
  if [[ "$full" == true ]]; then
    tar -xzf "$plain" -C "$tmpdir/payload" opt/data workspace metadata/kubernetes
    [[ -f "$tmpdir/payload/metadata/kubernetes/resources.json" ]] || fail 'full rollback requires an encrypted Kubernetes resource snapshot'
    if [[ ! -f "$tmpdir/payload/metadata/kubernetes/cluster-version.txt" ]]; then
      if [[ "$force" == true ]]; then
        warn 'full rollback archive has no K3s version metadata; continuing because --force was specified'
      else
        fail 'full rollback requires K3s version metadata'
      fi
    fi
    restore_kubernetes_snapshot "$tmpdir/payload/metadata/kubernetes" "$tmpdir" "$force" "$dry_run"
    if [[ "$dry_run" == true ]]; then
      trap - EXIT
      restore_local_cleanup
      return 0
    fi
  elif [[ "$data_only" == true && "$dry_run" == true ]]; then
    log 'Dry run: not extracting or scaling anything. Archive contents:'
    tar -tzf "$plain" -- opt/data workspace 2>/dev/null | head -50
    printf '... (truncated)\n'
    trap - EXIT
    restore_local_cleanup
    return 0
  else
    tar -xzf "$plain" -C "$tmpdir/payload" opt/data workspace
  fi
  tar -czf "$tmpdir/restore-payload.tgz" -C "$tmpdir/payload" opt/data workspace
  plain="$tmpdir/restore-payload.tgz"
  [[ "$HERMES_RUNTIME_UID" =~ ^[0-9]+$ ]] || fail "HERMES_RUNTIME_UID must be numeric"
  [[ "$HERMES_RUNTIME_GID" =~ ^[0-9]+$ ]] || fail "HERMES_RUNTIME_GID must be numeric"
  local deployments=() d replicas
  if [[ "$full" == true ]]; then
    mapfile -t deployments < <(python3 -c 'import json,sys; data=json.load(open(sys.argv[1])); print("\n".join(item["metadata"]["name"] for item in data["items"] if item.get("kind") == "Deployment"))' "$tmpdir/resources.json")
  else
    mapfile -t deployments < <(enabled_write_deployments)
  fi
  ((${#deployments[@]} > 0)) || fail 'no restorable write-capable Deployments found'
  declare -A original_replicas=()
  for d in "${deployments[@]}"; do
    replicas="$(kubectl -n "$HERMES_NAMESPACE" get deploy "$d" -o jsonpath='{.spec.replicas}')"
    original_replicas["$d"]="${replicas:-1}"
  done
  RESTORE_DEPLOYMENTS=("${deployments[@]}")
  unset RESTORE_ORIGINAL_REPLICAS
  declare -gA RESTORE_ORIGINAL_REPLICAS=()
  for d in "${deployments[@]}"; do
    RESTORE_ORIGINAL_REPLICAS["$d"]="${original_replicas[$d]}"
  done
  RESTORE_SCALE_UP_ON_CLEANUP=false
  restore_cleanup() {
    kubectl -n "$HERMES_NAMESPACE" delete pod hermes-restore --ignore-not-found=true --wait=true >/dev/null 2>&1 || true
    if [[ "${RESTORE_SCALE_UP_ON_CLEANUP:-false}" == true ]]; then
      for d in "${RESTORE_DEPLOYMENTS[@]:-}"; do
        kubectl -n "$HERMES_NAMESPACE" scale "deploy/$d" --replicas="${RESTORE_ORIGINAL_REPLICAS[$d]}" >/dev/null 2>&1 || true
      done
    fi
    restore_local_cleanup
  }
  restore_on_exit() {
    local status=$?
    restore_cleanup
    trap - EXIT
    exit "$status"
  }
  trap restore_on_exit EXIT
  RESTORE_SCALE_UP_ON_CLEANUP=true
  log "Scaling down write-heavy deployments"
  kubectl -n "$HERMES_NAMESPACE" scale "${deployments[@]/#/deploy/}" --replicas=0
  kubectl -n "$HERMES_NAMESPACE" rollout status deploy/hermes-agent --timeout=120s >/dev/null 2>&1 || true
  if [[ "$full" == true ]]; then
    refresh_restored_api_key_revisions "${deployments[@]}"
  fi
  kubectl -n "$HERMES_NAMESPACE" delete pod hermes-restore --ignore-not-found=true --wait=true >/dev/null 2>&1 || true
  create_storage_helper_pod hermes-restore restore
  kubectl -n "$HERMES_NAMESPACE" wait --for=condition=Ready pod/hermes-restore --timeout=120s >/dev/null
  # data-only restores never touch /opt/data/.env or Kubernetes Secrets, so the
  # API-key convergence dance is neither needed nor safe to skip validating for:
  # it would read a Secret this restore mode never wrote. After restoring data
  # onto a *different* instance's Secret, run `reconcile-api-key --source
  # secret` (and reconcile-browser-token, if applicable) to converge explicitly.
  if [[ "$data_only" != true ]]; then
    prepare_restored_api_key_sync
  fi
  kubectl -n "$HERMES_NAMESPACE" cp "$plain" hermes-restore:/tmp/hermes-backup.tgz -c restore >/dev/null
  RESTORE_SCALE_UP_ON_CLEANUP=false
  if [[ "$data_only" == true ]]; then
    # Overlay only: unlike the full/non-full paths, do not wipe /opt/data and
    # /workspace first. A data-only archive intentionally omits reproducible
    # runtime software (addon-venv, node/npm/npx, uv, LSP servers); wiping the
    # PVC first would delete that software with nothing in the archive to
    # replace it, breaking the Pod until the init Job reruns from scratch.
    kubectl -n "$HERMES_NAMESPACE" exec hermes-restore -- sh -c "tar xzf /tmp/hermes-backup.tgz -C /; chown -R ${HERMES_RUNTIME_UID}:${HERMES_RUNTIME_GID} /opt/data /workspace"
  else
    kubectl -n "$HERMES_NAMESPACE" exec hermes-restore -- sh -c "find /opt/data /workspace -mindepth 1 -maxdepth 1 -exec rm -rf {} +; tar xzf /tmp/hermes-backup.tgz -C /; chown -R ${HERMES_RUNTIME_UID}:${HERMES_RUNTIME_GID} /opt/data /workspace"
  fi
  if [[ "$data_only" != true ]]; then
    sync_restored_api_key
  fi
  RESTORE_SCALE_UP_ON_CLEANUP=true
  log "Scaling deployments up"
  for d in "${deployments[@]}"; do
    kubectl -n "$HERMES_NAMESPACE" scale "deploy/$d" --replicas="${original_replicas[$d]}"
  done
  for d in "${deployments[@]}"; do
    if [[ "${original_replicas[$d]}" -gt 0 ]]; then
      kubectl -n "$HERMES_NAMESPACE" rollout status "deploy/$d" --timeout=600s
    fi
  done
  RESTORE_SCALE_UP_ON_CLEANUP=false
  trap - EXIT
  restore_cleanup
  unset RESTORE_SCALE_UP_ON_CLEANUP RESTORE_DEPLOYMENTS RESTORE_ORIGINAL_REPLICAS
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
    backup) backup "$@" ;;
    extract) extract_backup "$@" ;;
    reconcile-api-key) reconcile_api_key "$@" ;;
    reconcile-browser-token) reconcile_browser_token "$@" ;;
    restore) restore "$@" ;;
    rotate-passwords) rotate_passwords "$@" ;;
    rotate-browser-token) rotate_browser_token "$@" ;;
    -h|--help|help|"") usage ;;
    *) usage; fail "unknown command: $cmd" ;;
  esac
fi
