#!/usr/bin/env bash
# Purpose: Render, validate, and install the Hermes Kubernetes/K3s stack.
# Scope: Parse configuration, compose bootstrap data, manage Kubernetes Secrets, render
#        manifests, apply resources, and verify enabled deployment rollouts.
# Requirements: Bash, kubectl, Python 3, OpenSSL, base64, GNU tar, gzip, and a configured cluster.
# Usage: ENV_FILE=./hermes.env ./install.sh
# Exit status: 0 means installation completed; non-zero stops before claiming success.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_ENV_FILE="$ROOT_DIR/hermes.env"
if [[ ! -f "$DEFAULT_ENV_FILE" && -f "$ROOT_DIR/current_config/hermes.env" ]]; then
  DEFAULT_ENV_FILE="$ROOT_DIR/current_config/hermes.env"
fi
ENV_FILE="${ENV_FILE:-$DEFAULT_ENV_FILE}"
RENDER_DIR="${HERMES_RENDER_DIR:-$ROOT_DIR/.rendered}"
MANIFEST_OUT="$RENDER_DIR/hermes.yaml"
BOOTSTRAP_ARCHIVE="$RENDER_DIR/bootstrap.tar.gz"
BOOTSTRAP_STAGE="$RENDER_DIR/bootstrap-stage"
# Explicit credential values from the process environment take precedence over
# blank or different values loaded from the selected env file.
PROCESS_DASHBOARD_AUTH_USER_SET="${DASHBOARD_AUTH_USER+x}"
PROCESS_DASHBOARD_AUTH_USER="${DASHBOARD_AUTH_USER-}"
PROCESS_DASHBOARD_AUTH_PASSWORD_SET="${DASHBOARD_AUTH_PASSWORD+x}"
PROCESS_DASHBOARD_AUTH_PASSWORD="${DASHBOARD_AUTH_PASSWORD-}"
PROCESS_API_SERVER_KEY_SET="${API_SERVER_KEY+x}"
PROCESS_API_SERVER_KEY="${API_SERVER_KEY-}"
PROCESS_BROWSER_TOKEN_SET="${BROWSER_TOKEN+x}"
PROCESS_BROWSER_TOKEN="${BROWSER_TOKEN-}"
PROCESS_PROFILE_REQUIREMENTS_SELECTED_SET="${HERMES_PROFILE_REQUIREMENTS_SELECTED+x}"
PROCESS_PROFILE_REQUIREMENTS_SELECTED="${HERMES_PROFILE_REQUIREMENTS_SELECTED-}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"; }
rand_hex() { openssl rand -hex "${1:-32}"; }
generate_password() { openssl rand -base64 "${1:-36}" | tr -d '\n'; }
remove_local_credential_captures() {
  rm -f "$RENDER_DIR/generated-credentials.txt" "$RENDER_DIR"/.generated-credentials.*
  rm -f "$RENDER_DIR"/rotated-credentials-*.txt
}

load_env() {
  HERMES_PROFILE_REQUIREMENTS_SELECTED=false
  if [[ ! -f "$ENV_FILE" ]]; then
    warn "Missing env file: $ENV_FILE. Using environment variables only."
    [[ -z "$PROCESS_PROFILE_REQUIREMENTS_SELECTED_SET" ]] || HERMES_PROFILE_REQUIREMENTS_SELECTED="$PROCESS_PROFILE_REQUIREMENTS_SELECTED"
    return 0
  fi
  require_cmd python3
  require_cmd base64
  local key encoded value parsed
  if ! parsed="$(python3 - "$ENV_FILE" <<'PY'
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
)"; then
    fail "Unable to parse environment file $ENV_FILE"
  fi
  while IFS=$'\t' read -r key encoded; do
    [[ -n "$key" ]] || continue
    value="$(printf '%s' "$encoded" | base64 -d)" || fail "Unable to decode environment setting $key"
    printf -v "$key" '%s' "$value"
    export "$key"
  done <<< "$parsed"
  [[ -z "$PROCESS_DASHBOARD_AUTH_USER_SET" ]] || DASHBOARD_AUTH_USER="$PROCESS_DASHBOARD_AUTH_USER"
  [[ -z "$PROCESS_DASHBOARD_AUTH_PASSWORD_SET" ]] || DASHBOARD_AUTH_PASSWORD="$PROCESS_DASHBOARD_AUTH_PASSWORD"
  [[ -z "$PROCESS_API_SERVER_KEY_SET" ]] || API_SERVER_KEY="$PROCESS_API_SERVER_KEY"
  [[ -z "$PROCESS_BROWSER_TOKEN_SET" ]] || BROWSER_TOKEN="$PROCESS_BROWSER_TOKEN"
  [[ -z "$PROCESS_PROFILE_REQUIREMENTS_SELECTED_SET" ]] || HERMES_PROFILE_REQUIREMENTS_SELECTED="$PROCESS_PROFILE_REQUIREMENTS_SELECTED"
}

prepare_paths() {
  RENDER_DIR="${HERMES_RENDER_DIR:-$ROOT_DIR/.rendered}"
  MANIFEST_OUT="$RENDER_DIR/hermes.yaml"
  BOOTSTRAP_ARCHIVE="$RENDER_DIR/bootstrap.tar.gz"
  BOOTSTRAP_STAGE="$RENDER_DIR/bootstrap-stage"
}

is_truthy() {
  [[ "${1:-}" =~ ^(1|true|TRUE|yes|YES|on|ON)$ ]]
}

read_existing_secret_value() {
  local secret="$1" key="$2" name encoded decoded status
  if ! name="$(kubectl -n "$HERMES_NAMESPACE" get secret "$secret" --ignore-not-found -o jsonpath='{.metadata.name}')"; then
    warn "Unable to inspect Kubernetes Secret $secret"
    return 2
  fi
  [[ -n "$name" ]] || return 1
  if ! encoded="$(kubectl -n "$HERMES_NAMESPACE" get secret "$secret" -o "jsonpath={.data['$key']}")"; then
    warn "Unable to read Kubernetes Secret $secret key $key"
    return 2
  fi
  [[ -n "$encoded" ]] || {
    warn "Kubernetes Secret $secret is missing required key $key"
    return 2
  }
  if (( ${#encoded} % 4 != 0 )) || [[ ! "$encoded" =~ ^[A-Za-z0-9+/]+={0,2}$ ]]; then
    warn "Kubernetes Secret $secret key $key is malformed or empty"
    return 2
  fi
  status=0
  decoded="$(ENCODED_SECRET_VALUE="$encoded" python3 - <<'PY'
import base64
import binascii
import os

encoded = os.environ["ENCODED_SECRET_VALUE"]
try:
    raw = base64.b64decode(encoded, validate=True)
    value = raw.decode("utf-8")
except (binascii.Error, UnicodeDecodeError):
    raise SystemExit(1)
if not value or "\n" in value or "\r" in value or "\0" in value:
    raise SystemExit(1)
print(value, end="")
PY
)" || status=$?
  if [[ "$status" -ne 0 || -z "$decoded" ]]; then
    warn "Kubernetes Secret $secret key $key is malformed or empty"
    return 2
  fi
  printf '%s' "$decoded"
}

validate_api_server_key() {
  [[ "$API_SERVER_KEY" != *$'\n'* && "$API_SERVER_KEY" != *$'\r'* ]] || fail "API_SERVER_KEY must be a single-line value"
  [[ ${#API_SERVER_KEY} -ge 16 ]] || fail "API_SERVER_KEY must be at least 16 characters"
  [[ "$API_SERVER_KEY" =~ ^[A-Za-z0-9._:/+=@%-]+$ ]] || fail "API_SERVER_KEY contains characters that cannot be safely persisted in the runtime environment file"
}

validate_browser_token() {
  is_truthy "${HERMES_BROWSER_ENABLED:-true}" || return 0
  [[ "$BROWSER_TOKEN" != *$'\n'* && "$BROWSER_TOKEN" != *$'\r'* ]] || fail "BROWSER_TOKEN must be a single-line value"
  [[ -n "$BROWSER_TOKEN" ]] || fail "BROWSER_TOKEN must not be empty when Browserless is enabled"
  [[ "$BROWSER_TOKEN" =~ ^[A-Za-z0-9._:/=@-]+$ ]] || fail "BROWSER_TOKEN contains characters that cannot be safely persisted in the runtime environment file"
}

resolve_runtime_credentials() {
  local namespace_exists existing status need_lookup=false
  local dashboard_enabled="${HERMES_DASHBOARD_ENABLED:-true}"
  local webui_enabled="${HERMES_WEBUI_ENABLED:-true}"
  local browser_enabled="${HERMES_BROWSER_ENABLED:-true}"
  CREDENTIAL_SOURCE_DASHBOARD="explicit"
  CREDENTIAL_SOURCE_API="explicit"
  CREDENTIAL_SOURCE_BROWSER="explicit"

  [[ -n "${DASHBOARD_AUTH_PASSWORD:-}" ]] || CREDENTIAL_SOURCE_DASHBOARD=""
  [[ -n "${API_SERVER_KEY:-}" ]] || CREDENTIAL_SOURCE_API=""
  [[ -n "${BROWSER_TOKEN:-}" ]] || CREDENTIAL_SOURCE_BROWSER=""

  if [[ "$HERMES_AUTH_MODE" == local-password ]] && { is_truthy "$dashboard_enabled" || is_truthy "$webui_enabled"; } && [[ -z "${DASHBOARD_AUTH_PASSWORD:-}" ]]; then
    need_lookup=true
  fi
  [[ -n "${API_SERVER_KEY:-}" ]] || need_lookup=true
  if is_truthy "$browser_enabled" && [[ -z "${BROWSER_TOKEN:-}" ]]; then
    need_lookup=true
  fi

  if [[ "$need_lookup" == false ]]; then
    validate_api_server_key
    validate_browser_token
    if is_truthy "$browser_enabled"; then
      BROWSER_CDP_URL="ws://hermes-browser:3000/chromium?token=${BROWSER_TOKEN}"
    else
      BROWSER_CDP_URL=""
    fi
    export DASHBOARD_AUTH_USER DASHBOARD_AUTH_PASSWORD API_SERVER_KEY BROWSER_TOKEN BROWSER_CDP_URL
    return 0
  fi

  require_cmd kubectl
  require_cmd openssl
  require_cmd python3
  if ! namespace_exists="$(kubectl get namespace "$HERMES_NAMESPACE" --ignore-not-found -o jsonpath='{.metadata.name}')"; then
    fail "Unable to inspect namespace $HERMES_NAMESPACE; refusing to generate replacement credentials"
  fi

  if [[ -n "$namespace_exists" ]]; then
    if [[ "$HERMES_AUTH_MODE" == local-password && -z "${DASHBOARD_AUTH_PASSWORD:-}" ]] && { is_truthy "$dashboard_enabled" || is_truthy "$webui_enabled"; }; then
      status=0
      existing="$(read_existing_secret_value hermes-dashboard-auth password)" || status=$?
      case "$status" in
        0) DASHBOARD_AUTH_PASSWORD="$existing"; CREDENTIAL_SOURCE_DASHBOARD=reused ;;
        1) DASHBOARD_AUTH_PASSWORD="$(generate_password 36)"; CREDENTIAL_SOURCE_DASHBOARD=generated ;;
        *) fail "Unable to safely resolve Dashboard/WebUI credentials" ;;
      esac
      if [[ "${DASHBOARD_AUTH_USER_EXPLICIT:-false}" != true && "$CREDENTIAL_SOURCE_DASHBOARD" == reused ]]; then
        status=0
        existing="$(read_existing_secret_value hermes-dashboard-auth username)" || status=$?
        [[ "$status" -eq 0 ]] || fail "Unable to safely reuse Dashboard/WebUI username"
        DASHBOARD_AUTH_USER="$existing"
      fi
    fi
    if [[ -z "${API_SERVER_KEY:-}" ]]; then
      status=0
      existing="$(read_existing_secret_value hermes-api-server api-key)" || status=$?
      case "$status" in
        0) API_SERVER_KEY="$existing"; CREDENTIAL_SOURCE_API=reused ;;
        1) API_SERVER_KEY="$(rand_hex 32)"; CREDENTIAL_SOURCE_API=generated ;;
        *) fail "Unable to safely resolve API server key" ;;
      esac
    fi
    if is_truthy "$browser_enabled" && [[ -z "${BROWSER_TOKEN:-}" ]]; then
      status=0
      existing="$(read_existing_secret_value hermes-browser-token token)" || status=$?
      case "$status" in
        0) BROWSER_TOKEN="$existing"; CREDENTIAL_SOURCE_BROWSER=reused ;;
        1) BROWSER_TOKEN="$(rand_hex 32)"; CREDENTIAL_SOURCE_BROWSER=generated ;;
        *) fail "Unable to safely resolve Browserless token" ;;
      esac
    fi
  else
    if [[ "$HERMES_AUTH_MODE" == local-password && -z "${DASHBOARD_AUTH_PASSWORD:-}" ]] && { is_truthy "$dashboard_enabled" || is_truthy "$webui_enabled"; }; then
      DASHBOARD_AUTH_PASSWORD="$(generate_password 36)"
      CREDENTIAL_SOURCE_DASHBOARD=generated
    fi
    if [[ -z "${API_SERVER_KEY:-}" ]]; then
      API_SERVER_KEY="$(rand_hex 32)"
      CREDENTIAL_SOURCE_API=generated
    fi
    if is_truthy "$browser_enabled"; then
      if [[ -z "${BROWSER_TOKEN:-}" ]]; then
        BROWSER_TOKEN="$(rand_hex 32)"
        CREDENTIAL_SOURCE_BROWSER=generated
      fi
    else
      BROWSER_TOKEN=""
    fi
  fi

  validate_api_server_key
  validate_browser_token
  if is_truthy "$browser_enabled"; then
    BROWSER_CDP_URL="ws://hermes-browser:3000/chromium?token=${BROWSER_TOKEN}"
  else
    BROWSER_CDP_URL=""
  fi
  export DASHBOARD_AUTH_USER DASHBOARD_AUTH_PASSWORD API_SERVER_KEY BROWSER_TOKEN BROWSER_CDP_URL
}

enabled_deployments() {
  printf '%s\n' hermes-agent
  is_truthy "$HERMES_DASHBOARD_ENABLED" && printf '%s\n' hermes-dashboard
  is_truthy "$HERMES_WEBUI_ENABLED" && printf '%s\n' hermes-webui
  is_truthy "$HERMES_BROWSER_ENABLED" && printf '%s\n' hermes-browser
}

validate_external_oidc_urls() {
  python3 - <<'PY'
import os
import re
from urllib.parse import urlsplit


def parse_https(name):
    value = os.environ.get(name, "")
    parsed = urlsplit(value)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
        raise SystemExit(f"ERROR: {name} must be an HTTPS URL without embedded credentials")
    if parsed.hostname.lower().endswith(".invalid"):
        raise SystemExit(f"ERROR: {name} must not use a reserved .invalid placeholder hostname")
    if parsed.fragment:
        raise SystemExit(f"ERROR: {name} must not contain a URL fragment")
    return parsed


def expect_host(name, host):
    parsed = parse_https(name)
    if parsed.hostname.lower() != host.lower():
        raise SystemExit(f"ERROR: {name} hostname must match {host}")
    return parsed

for name in ("HERMES_DASHBOARD_OIDC_ISSUER", "HERMES_WEBUI_OIDC_ISSUER"):
    if os.environ.get(name):
        parsed = parse_https(name)
        if parsed.query:
            raise SystemExit(f"ERROR: {name} must not contain a query string")

if os.environ.get("HERMES_DASHBOARD_PUBLIC_URL"):
    parsed = expect_host("HERMES_DASHBOARD_PUBLIC_URL", os.environ["DASHBOARD_HOST"])
    if parsed.port not in {None, 443} or parsed.path not in {"", "/"} or parsed.query:
        raise SystemExit("ERROR: HERMES_DASHBOARD_PUBLIC_URL must be the exact HTTPS Dashboard origin without a path, query string, or non-default port")

if os.environ.get("HERMES_WEBUI_OIDC_REDIRECT_URI"):
    parsed = expect_host("HERMES_WEBUI_OIDC_REDIRECT_URI", os.environ["WEBUI_HOST"])
    if parsed.port not in {None, 443} or parsed.path != "/api/auth/oidc/callback" or parsed.query:
        raise SystemExit("ERROR: HERMES_WEBUI_OIDC_REDIRECT_URI must use the exact HTTPS WebUI origin and /api/auth/oidc/callback path without a query string or non-default port")

for name in ("HERMES_DASHBOARD_OIDC_CLIENT_ID", "HERMES_WEBUI_OIDC_CLIENT_ID"):
    value = os.environ.get(name, "")
    if value and not re.fullmatch(r"[A-Za-z0-9._:@/-]+", value):
        raise SystemExit(f"ERROR: {name} contains unsupported characters")

for name in ("HERMES_DASHBOARD_OIDC_SCOPES", "HERMES_WEBUI_OIDC_SCOPES"):
    value = os.environ.get(name, "")
    if value and ("openid" not in value.split() or not re.fullmatch(r"[A-Za-z0-9._:-]+(?: [A-Za-z0-9._:-]+)*", value)):
        raise SystemExit(f"ERROR: {name} must be a space-separated scope list containing openid")

claim = os.environ.get("HERMES_WEBUI_OIDC_ALLOW_CLAIM", "")
if claim and not re.fullmatch(r"[A-Za-z0-9_.-]+", claim):
    raise SystemExit("ERROR: HERMES_WEBUI_OIDC_ALLOW_CLAIM contains unsupported characters")
PY
}

validate() {
  require_cmd kubectl
  require_cmd openssl
  require_cmd tar
  require_cmd gzip
  local tar_version
  tar_version="$(tar --version 2>/dev/null)" || fail "Unable to inspect tar implementation"
  [[ "$tar_version" == *"GNU tar"* ]] || fail "GNU tar is required for reproducible bootstrap archives"
  local scalar scalar_name
  for scalar_name in HERMES_NAMESPACE WEBUI_HOST DASHBOARD_HOST TLS_SECRET_NAME STORAGE_CLASS_NAME MODEL_PROVIDER MODEL_NAME HERMES_AGENT_IMAGE HERMES_WEBUI_IMAGE HERMES_BROWSER_IMAGE HERMES_IMAGE_PULL_POLICY HERMES_SSH_KEY_PATH HERMES_UV_DIR HERMES_ADDON_VENV; do
    scalar="${!scalar_name-}"
    [[ "$scalar" != *$'\n'* && "$scalar" != *$'\r'* && "$scalar" != *$'\t'* ]] || fail "$scalar_name must not contain control characters"
  done
  [[ -n "${HERMES_NAMESPACE:-}" ]] || fail "HERMES_NAMESPACE is required"
  [[ "$HERMES_NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || fail "HERMES_NAMESPACE must be a DNS-compatible Kubernetes name"
  [[ "${MODEL_PROVIDER:-}" =~ ^[A-Za-z0-9._:/-]+$ ]] || fail "MODEL_PROVIDER contains unsupported YAML characters"
  [[ "${MODEL_NAME:-}" =~ ^[A-Za-z0-9._:/-]+$ ]] || fail "MODEL_NAME contains unsupported YAML characters"
  [[ "${HERMES_IMAGE_PULL_POLICY:-}" == IfNotPresent || "${HERMES_IMAGE_PULL_POLICY:-}" == Always ]] || fail "HERMES_IMAGE_PULL_POLICY must be IfNotPresent or Always"
  for image in "$HERMES_AGENT_IMAGE" "$HERMES_WEBUI_IMAGE" "$HERMES_BROWSER_IMAGE"; do
    [[ "$image" =~ ^[A-Za-z0-9._/@:-]+$ ]] || fail "container image reference contains unsupported YAML characters"
  done
  is_truthy "$HERMES_AGENT_ENABLED" || fail "HERMES_AGENT_ENABLED must remain true; the Agent is mandatory"
  if is_truthy "$HERMES_WEBUI_ENABLED"; then
    [[ -n "${WEBUI_HOST:-}" ]] || fail "WEBUI_HOST is required when WebUI is enabled"
    [[ "$WEBUI_HOST" != *example.com ]] || warn "WEBUI_HOST still uses example.com"
  fi
  if is_truthy "$HERMES_DASHBOARD_ENABLED"; then
    [[ -n "${DASHBOARD_HOST:-}" ]] || fail "DASHBOARD_HOST is required when Dashboard is enabled"
    [[ "$DASHBOARD_HOST" != *example.com ]] || warn "DASHBOARD_HOST still uses example.com"
  fi
}

prepare_defaults() {
  export HERMES_PROFILE_REQUIREMENTS_SELECTED="${HERMES_PROFILE_REQUIREMENTS_SELECTED:-false}"
  case "$HERMES_PROFILE_REQUIREMENTS_SELECTED" in
    true|false) ;;
    *) fail "HERMES_PROFILE_REQUIREMENTS_SELECTED must be boolean" ;;
  esac
  export HERMES_BOOTSTRAP_PROFILE="${HERMES_BOOTSTRAP_PROFILE-personal-assistant}"
  apply_profile_defaults "$HERMES_BOOTSTRAP_PROFILE"
  export HERMES_AGENT_ENABLED="${HERMES_AGENT_ENABLED:-true}"
  export HERMES_DASHBOARD_ENABLED="${HERMES_DASHBOARD_ENABLED:-true}"
  export HERMES_WEBUI_ENABLED="${HERMES_WEBUI_ENABLED:-true}"
  export HERMES_BROWSER_ENABLED="${HERMES_BROWSER_ENABLED:-true}"
  export HERMES_AUTH_MODE="${HERMES_AUTH_MODE:-local-password}"
  export HERMES_OIDC_ISSUER="${HERMES_OIDC_ISSUER:-}"
  export HERMES_DASHBOARD_OIDC_ISSUER="${HERMES_DASHBOARD_OIDC_ISSUER:-${HERMES_OIDC_ISSUER}}"
  export HERMES_WEBUI_OIDC_ISSUER="${HERMES_WEBUI_OIDC_ISSUER:-${HERMES_OIDC_ISSUER}}"
  export HERMES_DASHBOARD_OIDC_CLIENT_ID="${HERMES_DASHBOARD_OIDC_CLIENT_ID:-}"
  export HERMES_WEBUI_OIDC_CLIENT_ID="${HERMES_WEBUI_OIDC_CLIENT_ID:-}"
  export HERMES_DASHBOARD_OIDC_SCOPES="${HERMES_DASHBOARD_OIDC_SCOPES:-openid profile email groups}"
  export HERMES_WEBUI_OIDC_SCOPES="${HERMES_WEBUI_OIDC_SCOPES:-openid profile email groups}"
  export HERMES_DASHBOARD_PUBLIC_URL="${HERMES_DASHBOARD_PUBLIC_URL:-}"
  export HERMES_WEBUI_OIDC_REDIRECT_URI="${HERMES_WEBUI_OIDC_REDIRECT_URI:-}"
  export HERMES_WEBUI_OIDC_ALLOW_CLAIM="${HERMES_WEBUI_OIDC_ALLOW_CLAIM:-}"
  export HERMES_WEBUI_OIDC_ALLOW_VALUES="${HERMES_WEBUI_OIDC_ALLOW_VALUES:-}"
  export HERMES_AUTH_SESSION_MAX_TTL_SECONDS="${HERMES_AUTH_SESSION_MAX_TTL_SECONDS:-43200}"
  export HERMES_AUTH_SESSION_IDLE_TTL_SECONDS="${HERMES_AUTH_SESSION_IDLE_TTL_SECONDS:-7200}"
  export HERMES_NAMESPACE="${HERMES_NAMESPACE:-hermes}"
  export INGRESS_CLASS_NAME="${INGRESS_CLASS_NAME:-traefik}"
  export TRAEFIK_ENTRYPOINT="${TRAEFIK_ENTRYPOINT:-websecure}"
  export TLS_ENABLED="${TLS_ENABLED:-true}"
  export TLS_SECRET_NAME="${TLS_SECRET_NAME:-}"
  export HERMES_AGENT_IMAGE="${HERMES_AGENT_IMAGE:-nousresearch/hermes-agent:v0.22.5}"
  export HERMES_WEBUI_IMAGE="${HERMES_WEBUI_IMAGE:-ghcr.io/nesquena/hermes-webui:0.52.602}"
  export HERMES_BROWSER_IMAGE="${HERMES_BROWSER_IMAGE:-ghcr.io/browserless/chromium:v2.58.1}"
  export HERMES_IMAGE_PULL_POLICY="${HERMES_IMAGE_PULL_POLICY:-IfNotPresent}"
  export HERMES_HOME_STORAGE_SIZE="${HERMES_HOME_STORAGE_SIZE:-10Gi}"
  export HERMES_WORKSPACE_STORAGE_SIZE="${HERMES_WORKSPACE_STORAGE_SIZE:-20Gi}"
  export HERMES_RUNTIME_UID="${HERMES_RUNTIME_UID:-10000}"
  export HERMES_RUNTIME_GID="${HERMES_RUNTIME_GID:-10000}"
  export HERMES_WEBUI_MAX_UPLOAD_MB="${HERMES_WEBUI_MAX_UPLOAD_MB:-220}"
  export HERMES_BOOTSTRAP_DIR="${HERMES_BOOTSTRAP_DIR:-}"
  export HERMES_BOOTSTRAP_MODE="${HERMES_BOOTSTRAP_MODE:-missing}"
  export HERMES_BOOTSTRAP_INCLUDE_AUTH="${HERMES_BOOTSTRAP_INCLUDE_AUTH:-false}"
  export HERMES_ADDON_REQUIREMENTS="${HERMES_ADDON_REQUIREMENTS:-}"
  # Hard-coded addon runtime facts. Keep these out of hermes.env examples unless the chart changes.
  export HERMES_ADDON_PYTHON_MODE="uv"
  export HERMES_UV_DIR="/opt/data/uv"
  export HERMES_ADDON_VENV="/opt/data/addon-venv"
  export HERMES_ADDON_PYTHON_VERSION="${HERMES_ADDON_PYTHON_VERSION:-3.13}"
  export HERMES_ANSIBLE_SETUP="${HERMES_ANSIBLE_SETUP:-false}"
  export HERMES_ANSIBLE_VERSION="${HERMES_ANSIBLE_VERSION:-14.1.0}"
  if is_truthy "$HERMES_ANSIBLE_SETUP"; then
    export HERMES_SSH_SETUP=true
  fi
  if [[ -z "${HERMES_ANSIBLE_CONFIG+x}" ]]; then
    if [[ "$HERMES_ANSIBLE_SETUP" =~ ^(1|true|TRUE|yes|YES|on|ON)$ ]]; then
      export HERMES_ANSIBLE_CONFIG="/workspace/ansible/ansible.cfg"
    else
      export HERMES_ANSIBLE_CONFIG=""
    fi
  fi
  export HERMES_SSH_SETUP="${HERMES_SSH_SETUP:-true}"
  export HERMES_SSH_GENERATE_KEY="${HERMES_SSH_GENERATE_KEY:-${HERMES_SSH_SETUP}}"
  export HERMES_SSH_KEY_TYPE="${HERMES_SSH_KEY_TYPE:-ed25519}"
  export HERMES_SSH_KEY_PATH="${HERMES_SSH_KEY_PATH:-/opt/data/.ssh/id_ed25519}"
  export HERMES_AGENT_CPU_REQUEST="${HERMES_AGENT_CPU_REQUEST:-100m}"
  export HERMES_AGENT_MEMORY_REQUEST="${HERMES_AGENT_MEMORY_REQUEST:-256Mi}"
  export HERMES_AGENT_CPU_LIMIT="${HERMES_AGENT_CPU_LIMIT:-1}"
  export HERMES_AGENT_MEMORY_LIMIT="${HERMES_AGENT_MEMORY_LIMIT:-1Gi}"
  export HERMES_DASHBOARD_CPU_REQUEST="${HERMES_DASHBOARD_CPU_REQUEST:-100m}"
  export HERMES_DASHBOARD_MEMORY_REQUEST="${HERMES_DASHBOARD_MEMORY_REQUEST:-96Mi}"
  export HERMES_DASHBOARD_CPU_LIMIT="${HERMES_DASHBOARD_CPU_LIMIT:-1}"
  export HERMES_DASHBOARD_MEMORY_LIMIT="${HERMES_DASHBOARD_MEMORY_LIMIT:-1Gi}"
  export HERMES_WEBUI_CPU_REQUEST="${HERMES_WEBUI_CPU_REQUEST:-100m}"
  export HERMES_WEBUI_MEMORY_REQUEST="${HERMES_WEBUI_MEMORY_REQUEST:-256Mi}"
  export HERMES_WEBUI_CPU_LIMIT="${HERMES_WEBUI_CPU_LIMIT:-1}"
  export HERMES_WEBUI_MEMORY_LIMIT="${HERMES_WEBUI_MEMORY_LIMIT:-2Gi}"
  export HERMES_BROWSER_CPU_REQUEST="${HERMES_BROWSER_CPU_REQUEST:-100m}"
  export HERMES_BROWSER_MEMORY_REQUEST="${HERMES_BROWSER_MEMORY_REQUEST:-128Mi}"
  export HERMES_BROWSER_CPU_LIMIT="${HERMES_BROWSER_CPU_LIMIT:-1}"
  export HERMES_BROWSER_MEMORY_LIMIT="${HERMES_BROWSER_MEMORY_LIMIT:-1Gi}"
  export STORAGE_CLASS_NAME="${STORAGE_CLASS_NAME:-}"
  export MODEL_PROVIDER="${MODEL_PROVIDER:-openai-codex}"
  export MODEL_NAME="${MODEL_NAME:-gpt-5.6-luna}"
  if [[ "$HERMES_AUTH_MODE" == local-password ]] && (is_truthy "$HERMES_DASHBOARD_ENABLED" || is_truthy "$HERMES_WEBUI_ENABLED"); then
    if [[ -n "${DASHBOARD_AUTH_USER:-}" ]]; then
      export DASHBOARD_AUTH_USER_EXPLICIT=true
    else
      export DASHBOARD_AUTH_USER_EXPLICIT=false
    fi
    export DASHBOARD_AUTH_USER="${DASHBOARD_AUTH_USER:-admin}"
    export DASHBOARD_AUTH_PASSWORD="${DASHBOARD_AUTH_PASSWORD:-}"
  else
    export DASHBOARD_AUTH_USER=""
    export DASHBOARD_AUTH_PASSWORD=""
  fi
  export API_SERVER_KEY="${API_SERVER_KEY:-}"
  if is_truthy "$HERMES_BROWSER_ENABLED"; then
    export BROWSER_TOKEN="${BROWSER_TOKEN:-}"
  else
    export BROWSER_TOKEN=""
  fi
  export BROWSER_CONCURRENT="${BROWSER_CONCURRENT:-4}"
  export BROWSER_QUEUED="${BROWSER_QUEUED:-10}"
  export BROWSER_TIMEOUT_MS="${BROWSER_TIMEOUT_MS:-30000}"
  [[ "$BROWSER_CONCURRENT" =~ ^[0-9]+$ ]] || fail "BROWSER_CONCURRENT must be numeric"
  [[ "$BROWSER_QUEUED" =~ ^[0-9]+$ ]] || fail "BROWSER_QUEUED must be numeric"
  [[ "$BROWSER_TIMEOUT_MS" =~ ^[0-9]+$ ]] || fail "BROWSER_TIMEOUT_MS must be numeric"
  [[ "$HERMES_AUTH_SESSION_MAX_TTL_SECONDS" =~ ^[0-9]{1,8}$ ]] || fail "HERMES_AUTH_SESSION_MAX_TTL_SECONDS must be 1 to 8 decimal digits"
  [[ "$HERMES_AUTH_SESSION_IDLE_TTL_SECONDS" =~ ^[0-9]{1,8}$ ]] || fail "HERMES_AUTH_SESSION_IDLE_TTL_SECONDS must be 1 to 8 decimal digits"
  (( 10#$HERMES_AUTH_SESSION_MAX_TTL_SECONDS >= 60 && 10#$HERMES_AUTH_SESSION_MAX_TTL_SECONDS <= 31536000 )) \
    || fail "HERMES_AUTH_SESSION_MAX_TTL_SECONDS must be between 60 and 31536000 seconds"
  (( 10#$HERMES_AUTH_SESSION_IDLE_TTL_SECONDS >= 60 )) \
    || fail "HERMES_AUTH_SESSION_IDLE_TTL_SECONDS must be at least 60 seconds"
  (( 10#$HERMES_AUTH_SESSION_IDLE_TTL_SECONDS <= 10#$HERMES_AUTH_SESSION_MAX_TTL_SECONDS )) \
    || fail "HERMES_AUTH_SESSION_IDLE_TTL_SECONDS must not exceed HERMES_AUTH_SESSION_MAX_TTL_SECONDS"
  if (( BROWSER_CONCURRENT < 4 )); then
    warn "BROWSER_CONCURRENT=$BROWSER_CONCURRENT is below the repo default 4; parallel WebUI screenshot/browser workflows can queue and time out during CDP handshakes."
  fi
  if is_truthy "$HERMES_BROWSER_ENABLED"; then
    export BROWSER_CDP_URL=""
  else
    export BROWSER_CDP_URL=""
  fi
  case "$HERMES_BOOTSTRAP_MODE" in
    disabled|missing|overwrite) ;;
    *) fail "HERMES_BOOTSTRAP_MODE must be one of: disabled, missing, overwrite" ;;
  esac
  if [[ -n "$HERMES_BOOTSTRAP_DIR" && "$HERMES_BOOTSTRAP_MODE" != "disabled" ]]; then
    require_cmd tar
    [[ -d "$HERMES_BOOTSTRAP_DIR" ]] || fail "HERMES_BOOTSTRAP_DIR does not exist or is not a directory: $HERMES_BOOTSTRAP_DIR"
  fi
  if [[ -z "$HERMES_BOOTSTRAP_DIR" && -n "$HERMES_BOOTSTRAP_PROFILE" && "$HERMES_BOOTSTRAP_MODE" != "disabled" ]]; then
    require_cmd tar
    compose_profile_bootstrap "$HERMES_BOOTSTRAP_PROFILE"
  fi
  if [[ -n "$HERMES_ADDON_REQUIREMENTS" ]]; then
    require_cmd tar
    [[ -f "$HERMES_ADDON_REQUIREMENTS" ]] || fail "HERMES_ADDON_REQUIREMENTS does not exist or is not a file: $HERMES_ADDON_REQUIREMENTS"
  fi
  [[ "$HERMES_ADDON_PYTHON_MODE" = "uv" ]] || fail "HERMES_ADDON_PYTHON_MODE is fixed to uv"
  [[ "$HERMES_UV_DIR" = /opt/data/* ]] || fail "HERMES_UV_DIR must be under /opt/data for PVC persistence"
  [[ "$HERMES_ADDON_VENV" = /opt/data/* ]] || fail "HERMES_ADDON_VENV must be under /opt/data for PVC persistence"
  [[ "$HERMES_ADDON_PYTHON_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || fail "HERMES_ADDON_PYTHON_VERSION must look like 3.13 or 3.13.5"
  case "$HERMES_AUTH_MODE" in
    local-password|external-oidc) ;;
    disabled|external-proxy) fail "HERMES_AUTH_MODE=$HERMES_AUTH_MODE is documentation-only and is not implemented" ;;
    *) fail "HERMES_AUTH_MODE must be one of: local-password, external-oidc" ;;
  esac
  if [[ "$HERMES_AUTH_MODE" == external-oidc ]]; then
    if is_truthy "$HERMES_DASHBOARD_ENABLED"; then
      [[ -n "$HERMES_DASHBOARD_OIDC_ISSUER" ]] || fail "HERMES_DASHBOARD_OIDC_ISSUER is required when Dashboard is enabled in external-oidc mode"
      [[ -n "$HERMES_DASHBOARD_OIDC_CLIENT_ID" ]] || fail "HERMES_DASHBOARD_OIDC_CLIENT_ID is required when Dashboard is enabled in external-oidc mode"
      [[ -n "$HERMES_DASHBOARD_PUBLIC_URL" ]] || fail "HERMES_DASHBOARD_PUBLIC_URL is required when Dashboard is enabled in external-oidc mode"
    fi
    if is_truthy "$HERMES_WEBUI_ENABLED"; then
      [[ -n "$HERMES_WEBUI_OIDC_ISSUER" ]] || fail "HERMES_WEBUI_OIDC_ISSUER is required when WebUI is enabled in external-oidc mode"
      [[ -n "$HERMES_WEBUI_OIDC_CLIENT_ID" ]] || fail "HERMES_WEBUI_OIDC_CLIENT_ID is required when WebUI is enabled in external-oidc mode"
      [[ -n "$HERMES_WEBUI_OIDC_REDIRECT_URI" ]] || fail "HERMES_WEBUI_OIDC_REDIRECT_URI is required when WebUI is enabled in external-oidc mode"
      [[ -n "$HERMES_WEBUI_OIDC_ALLOW_CLAIM" ]] || fail "HERMES_WEBUI_OIDC_ALLOW_CLAIM is required when WebUI is enabled in external-oidc mode"
      [[ -n "$HERMES_WEBUI_OIDC_ALLOW_VALUES" ]] || fail "HERMES_WEBUI_OIDC_ALLOW_VALUES is required when WebUI is enabled in external-oidc mode"
    fi
    validate_external_oidc_urls
  fi
  case "$HERMES_SSH_SETUP" in true|false|TRUE|FALSE|1|0|yes|no|YES|NO|on|off|ON|OFF) ;; *) fail "HERMES_SSH_SETUP must be boolean" ;; esac
  case "$HERMES_ANSIBLE_SETUP" in true|false|TRUE|FALSE|1|0|yes|no|YES|NO|on|off|ON|OFF) ;; *) fail "HERMES_ANSIBLE_SETUP must be boolean" ;; esac
  for component_value in "$HERMES_AGENT_ENABLED" "$HERMES_DASHBOARD_ENABLED" "$HERMES_WEBUI_ENABLED" "$HERMES_BROWSER_ENABLED"; do
    case "$component_value" in true|false|TRUE|FALSE|1|0|yes|no|YES|NO|on|off|ON|OFF) ;; *) fail "component enablement values must be boolean" ;; esac
  done
  if is_truthy "$HERMES_ANSIBLE_SETUP"; then
    [[ "$HERMES_ANSIBLE_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || fail "HERMES_ANSIBLE_VERSION must look like 14.1.0"
  fi
  case "$HERMES_SSH_GENERATE_KEY" in true|false|TRUE|FALSE|1|0|yes|no|YES|NO|on|off|ON|OFF) ;; *) fail "HERMES_SSH_GENERATE_KEY must be boolean" ;; esac
  case "$HERMES_SSH_KEY_TYPE" in ed25519|rsa|ecdsa) ;; *) fail "HERMES_SSH_KEY_TYPE must be one of: ed25519, rsa, ecdsa" ;; esac
  [[ "$HERMES_SSH_KEY_PATH" = /opt/data/.ssh/* ]] || fail "HERMES_SSH_KEY_PATH must be under /opt/data/.ssh for PVC persistence"
  [[ "$HERMES_RUNTIME_UID" =~ ^[0-9]+$ ]] || fail "HERMES_RUNTIME_UID must be numeric"
  [[ "$HERMES_RUNTIME_GID" =~ ^[0-9]+$ ]] || fail "HERMES_RUNTIME_GID must be numeric"
  [[ "$HERMES_WEBUI_MAX_UPLOAD_MB" =~ ^[0-9]+$ ]] || fail "HERMES_WEBUI_MAX_UPLOAD_MB must be numeric"
}

bootstrap_enabled() {
  [[ -n "${HERMES_BOOTSTRAP_DIR:-}" && "${HERMES_BOOTSTRAP_MODE:-disabled}" != "disabled" ]]
}

addon_requirements_enabled() {
  [[ -n "${HERMES_ADDON_REQUIREMENTS:-}" ]]
}

apply_profile_defaults() {
  [[ -n "$HERMES_BOOTSTRAP_PROFILE" ]] || return 0
  local prof="$1"
  local profiledir="$ROOT_DIR/examples/bootstrap-profiles/$prof"
  [[ -d "$profiledir" ]] || fail "Unknown bootstrap profile: $prof. Available profiles: $(cd "$ROOT_DIR/examples/bootstrap-profiles" 2>/dev/null && printf '%s ' */ | tr -d '/')"
  local defaults="$profiledir/defaults.conf"
  [[ -f "$defaults" ]] || fail "Profile $prof is missing defaults.conf"
  # defaults.conf is repository-controlled and may define only HERMES_PROFILE_DEFAULT_* values.
  if grep -Ev '^[[:space:]]*(#.*|$|HERMES_PROFILE_DEFAULT_[A-Z0-9_]+=[^[:space:]]*)$' "$defaults" | grep -q .; then
    fail "Profile $prof has invalid entries in defaults.conf"
  fi
  # shellcheck disable=SC1090
  source "$defaults"
  if [[ -z "${HERMES_SSH_SETUP+x}" ]]; then
    export HERMES_SSH_SETUP="${HERMES_PROFILE_DEFAULT_SSH_SETUP:-true}"
  fi
  if [[ -z "${HERMES_ANSIBLE_SETUP+x}" ]]; then
    export HERMES_ANSIBLE_SETUP="${HERMES_PROFILE_DEFAULT_ANSIBLE_SETUP:-false}"
  fi
  if [[ -z "${HERMES_ADDON_REQUIREMENTS+x}" && -n "${HERMES_PROFILE_DEFAULT_ADDON_REQUIREMENTS:-}" ]]; then
    export HERMES_ADDON_REQUIREMENTS="$profiledir/$HERMES_PROFILE_DEFAULT_ADDON_REQUIREMENTS"
    export HERMES_PROFILE_REQUIREMENTS_SELECTED=true
  fi
}

compose_profile_bootstrap() {
  local prof="$1"
  local shared="$ROOT_DIR/examples/bootstrap-shared"
  local shared_skills="$shared/skills"
  local profiledir="$ROOT_DIR/examples/bootstrap-profiles/$prof"
  [[ -f "$profiledir/SOUL.md" ]] || fail "Profile $prof is missing SOUL.md"
  [[ -f "$profiledir/memories/USER.md" ]] || warn "Profile $prof has no memories/USER.md"
  [[ -f "$profiledir/skills.txt" ]] || fail "Profile $prof is missing skills.txt"
  local stage="$RENDER_DIR/bootstrap-profile/$prof"
  rm -rf "$stage"
  mkdir -p "$stage"
  if [[ -d "$shared" ]]; then
    log "Composing bootstrap profile $prof"
    find "$shared" -mindepth 1 -maxdepth 1 ! -name skills -exec cp -a {} "$stage"/ \;
  fi
  mkdir -p "$stage/skills"
  local skill
  while IFS= read -r skill || [[ -n "$skill" ]]; do
    skill="${skill%%#*}"
    skill="${skill//[[:space:]]/}"
    [[ -n "$skill" ]] || continue
    [[ "$skill" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || fail "Invalid skill name '$skill' in profile $prof"
    [[ -d "$shared_skills/$skill" ]] || fail "Profile $prof selects missing shared skill: $skill"
    [[ ! -e "$stage/skills/$skill" ]] || fail "Profile $prof selects duplicate skill: $skill"
    cp -a "$shared_skills/$skill" "$stage/skills/$skill"
  done < "$profiledir/skills.txt"
  cp -a "$profiledir"/. "$stage"/
  rm -f "$stage/defaults.conf" "$stage/skills.txt" "$stage/requirements.txt"
  if [[ ! "$HERMES_ANSIBLE_SETUP" =~ ^(1|true|TRUE|yes|YES|on|ON)$ ]]; then
    rm -rf "$stage/workspace/ansible"
  fi
  export HERMES_BOOTSTRAP_DIR="$stage"
}

archive_enabled() {
  bootstrap_enabled || addon_requirements_enabled || is_truthy "$HERMES_ANSIBLE_SETUP"
}

copy_bootstrap_path() {
  local src="$1" dest="$2"
  [[ -e "$src" ]] || return 0
  mkdir -p "$(dirname "$dest")"
  if [[ -d "$src" ]]; then
    mkdir -p "$dest"
    cp -a "$src"/. "$dest"/
  else
    cp -a "$src" "$dest"
  fi
}

create_bootstrap_archive() {
  rm -f "$BOOTSTRAP_ARCHIVE"
  rm -rf "$BOOTSTRAP_STAGE"
  if ! archive_enabled; then
    return 0
  fi

  mkdir -p "$BOOTSTRAP_STAGE/opt-data" "$BOOTSTRAP_STAGE/workspace" "$BOOTSTRAP_STAGE/addons"

  if bootstrap_enabled; then
    log "Preparing bootstrap archive from $HERMES_BOOTSTRAP_DIR"
    copy_bootstrap_path "$HERMES_BOOTSTRAP_DIR/SOUL.md" "$BOOTSTRAP_STAGE/opt-data/SOUL.md"
    copy_bootstrap_path "$HERMES_BOOTSTRAP_DIR/config.yaml" "$BOOTSTRAP_STAGE/opt-data/config.yaml"
    copy_bootstrap_path "$HERMES_BOOTSTRAP_DIR/.env" "$BOOTSTRAP_STAGE/opt-data/.env"
    copy_bootstrap_path "$HERMES_BOOTSTRAP_DIR/memories" "$BOOTSTRAP_STAGE/opt-data/memories"
    copy_bootstrap_path "$HERMES_BOOTSTRAP_DIR/skills" "$BOOTSTRAP_STAGE/opt-data/skills"
    copy_bootstrap_path "$HERMES_BOOTSTRAP_DIR/plugins" "$BOOTSTRAP_STAGE/opt-data/plugins"
    copy_bootstrap_path "$HERMES_BOOTSTRAP_DIR/cron" "$BOOTSTRAP_STAGE/opt-data/cron"
    copy_bootstrap_path "$HERMES_BOOTSTRAP_DIR/workspace" "$BOOTSTRAP_STAGE/workspace"

    if [[ "$HERMES_BOOTSTRAP_INCLUDE_AUTH" =~ ^(1|true|TRUE|yes|YES|on|ON)$ ]]; then
      copy_bootstrap_path "$HERMES_BOOTSTRAP_DIR/auth.json" "$BOOTSTRAP_STAGE/opt-data/auth.json"
    elif [[ -e "$HERMES_BOOTSTRAP_DIR/auth.json" ]]; then
      warn "bootstrap/auth.json exists but HERMES_BOOTSTRAP_INCLUDE_AUTH is false; auth.json was not included."
    fi
  fi

  if addon_requirements_enabled; then
    log "Including addon Python requirements from $HERMES_ADDON_REQUIREMENTS"
    copy_bootstrap_path "$HERMES_ADDON_REQUIREMENTS" "$BOOTSTRAP_STAGE/addons/requirements.txt"
  fi

  if is_truthy "$HERMES_ANSIBLE_SETUP" || [[ "${HERMES_PROFILE_REQUIREMENTS_SELECTED:-false}" == true ]]; then
    python3 "$ROOT_DIR/scripts/prepare_requirements.py" \
      "$BOOTSTRAP_STAGE/addons/requirements.txt" \
      "$HERMES_ANSIBLE_SETUP" \
      "$HERMES_ANSIBLE_VERSION" \
      "${HERMES_PROFILE_REQUIREMENTS_SELECTED:-false}"
  fi

  if ! find "$BOOTSTRAP_STAGE" -type f -print -quit | grep -q .; then
    warn "bootstrap/addon archive requested but no supported files were found."
    rm -rf "$BOOTSTRAP_STAGE"
    return 0
  fi

  # Keep the archive byte-reproducible so unchanged bootstrap content does not
  # churn the Kubernetes Secret on every installer rerun.
  tar -C "$BOOTSTRAP_STAGE" \
    --sort=name \
    --mtime='@0' \
    --owner=0 \
    --group=0 \
    --numeric-owner \
    --mode='u+rwX,go+rX,go-w' \
    -cf - . | gzip -n > "$BOOTSTRAP_ARCHIVE"
  chmod 600 "$BOOTSTRAP_ARCHIVE"
}

render_manifest() {
  [[ -n "${API_SERVER_KEY_REVISION:-}" ]] || fail "API server key Secret revision is required before rendering"
  mkdir -p "$RENDER_DIR"
  python3 "$ROOT_DIR/scripts/render_template.py" \
    "$ROOT_DIR/manifests/hermes.yaml.tpl" \
    "$MANIFEST_OUT"
}

preflight_manifest() {
  (
    export API_SERVER_KEY_REVISION=preflight-resource-version
    render_manifest
  )
}

render_pre_init_manifest() {
  local output="$RENDER_DIR/pre-init.yaml"
  python3 - "$MANIFEST_OUT" "$output" <<'PY'
import re
import sys
from pathlib import Path

source, output = map(Path, sys.argv[1:])
documents = source.read_text().split("\n---\n")
selected = []
for document in documents:
    kind = re.search(r"(?m)^kind:\s*(\S+)\s*$", document)
    if not kind or kind.group(1) != "Deployment":
        selected.append(document)
output.write_text("\n---\n".join(selected))
PY
  printf '%s' "$output"
}

create_namespace_and_secrets() {
  log "Creating namespace and secrets"
  kubectl create namespace "$HERMES_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

  if [[ -f "$BOOTSTRAP_ARCHIVE" ]]; then
    kubectl -n "$HERMES_NAMESPACE" create secret generic hermes-bootstrap-archive       --from-file=bootstrap.tar.gz="$BOOTSTRAP_ARCHIVE"       --dry-run=client -o yaml | kubectl apply -f -
  else
    kubectl -n "$HERMES_NAMESPACE" delete secret hermes-bootstrap-archive --ignore-not-found=true >/dev/null
  fi

  if [[ "$HERMES_AUTH_MODE" == local-password ]] && (is_truthy "$HERMES_DASHBOARD_ENABLED" || is_truthy "$HERMES_WEBUI_ENABLED"); then
    local dash_tmpdir
    dash_tmpdir="$(mktemp -d)"
    chmod 700 "$dash_tmpdir"
    trap 'rm -rf -- "$dash_tmpdir"' ERR
    printf '%s' "$DASHBOARD_AUTH_USER" > "$dash_tmpdir/username"
    printf '%s' "$DASHBOARD_AUTH_PASSWORD" > "$dash_tmpdir/password"
    kubectl -n "$HERMES_NAMESPACE" create secret generic hermes-dashboard-auth \
      --from-file=username="$dash_tmpdir/username" \
      --from-file=password="$dash_tmpdir/password" \
      --dry-run=client -o yaml | kubectl apply -f -
    trap - ERR
    rm -rf -- "$dash_tmpdir"
  else
    # During a local-password -> external-oidc migration, retain the old Secret
    # until both OIDC workloads have rolled out successfully. apply_and_wait
    # deletes it after the rollout; this keeps the previous Pods restartable if
    # rendering/apply/readiness fails before cutover completes.
    if ! is_truthy "$HERMES_DASHBOARD_ENABLED" && ! is_truthy "$HERMES_WEBUI_ENABLED"; then
      kubectl -n "$HERMES_NAMESPACE" delete secret hermes-dashboard-auth --ignore-not-found=true >/dev/null
    fi
  fi

  local secret_tmpdir
  secret_tmpdir="$(mktemp -d)"
  chmod 700 "$secret_tmpdir"
  trap 'rm -rf -- "$secret_tmpdir"' ERR
  printf '%s' "$API_SERVER_KEY" > "$secret_tmpdir/api-key"
  printf '%s' "$BROWSER_TOKEN" > "$secret_tmpdir/token"
  printf '%s' "$BROWSER_CDP_URL" > "$secret_tmpdir/BROWSER_CDP_URL"

  kubectl -n "$HERMES_NAMESPACE" create secret generic hermes-api-server \
    --from-file=api-key="$secret_tmpdir/api-key" \
    --dry-run=client -o yaml | kubectl apply -f -

  if is_truthy "$HERMES_BROWSER_ENABLED"; then
    kubectl -n "$HERMES_NAMESPACE" create secret generic hermes-browser-token \
      --from-file=token="$secret_tmpdir/token" \
      --dry-run=client -o yaml | kubectl apply -f -
  else
    kubectl -n "$HERMES_NAMESPACE" delete secret hermes-browser-token --ignore-not-found=true >/dev/null
  fi

  kubectl -n "$HERMES_NAMESPACE" create secret generic hermes-browser-cdp \
    --from-file=BROWSER_CDP_URL="$secret_tmpdir/BROWSER_CDP_URL" \
    --dry-run=client -o yaml | kubectl apply -f -
  trap - ERR
  rm -rf -- "$secret_tmpdir"
}

resolve_api_key_revision() {
  API_SERVER_KEY_REVISION="$(kubectl -n "$HERMES_NAMESPACE" get secret hermes-api-server -o jsonpath='{.metadata.resourceVersion}')" || fail "Unable to read API server key Secret revision"
  [[ "$API_SERVER_KEY_REVISION" =~ ^[A-Za-z0-9._:-]+$ ]] || fail "API server key Secret revision is empty or unsafe to render"
  export API_SERVER_KEY_REVISION
}

deployment_template_digest() {
  local deployment="$1" document
  document="$(kubectl -n "$HERMES_NAMESPACE" get deployment "$deployment" --ignore-not-found -o json)"
  [[ -n "$document" ]] || return 0
  printf '%s' "$document" | python3 -c '
import hashlib, json, sys
document = json.load(sys.stdin)
template = json.dumps(document["spec"]["template"], sort_keys=True, separators=(",", ":"))
print(hashlib.sha256(template.encode()).hexdigest())
'
}

apply_and_wait() {
  local pre_init_manifest d template_after
  local deployments=() restart_deployments=()
  declare -A template_before=()

  log "Recreating init job if it already exists"
  kubectl -n "$HERMES_NAMESPACE" delete job hermes-init-config --ignore-not-found=true --wait=true >/dev/null

  pre_init_manifest="$(render_pre_init_manifest)"
  log "Applying non-Deployment resources and init job"
  kubectl apply -f "$pre_init_manifest"

  is_truthy "$HERMES_DASHBOARD_ENABLED" || kubectl -n "$HERMES_NAMESPACE" delete deploy,svc,ingress hermes-dashboard --ignore-not-found=true >/dev/null
  is_truthy "$HERMES_DASHBOARD_ENABLED" || kubectl -n "$HERMES_NAMESPACE" delete ingress hermes-dashboard-login --ignore-not-found=true >/dev/null
  is_truthy "$HERMES_DASHBOARD_ENABLED" || kubectl -n "$HERMES_NAMESPACE" delete middleware hermes-dashboard-login-rewrite --ignore-not-found=true >/dev/null 2>&1 || true
  if [[ "$HERMES_AUTH_MODE" != local-password ]]; then
    kubectl -n "$HERMES_NAMESPACE" delete ingress hermes-dashboard-login --ignore-not-found=true >/dev/null
    kubectl -n "$HERMES_NAMESPACE" delete middleware hermes-dashboard-login-rewrite --ignore-not-found=true >/dev/null 2>&1 || true
  fi
  is_truthy "$HERMES_WEBUI_ENABLED" || kubectl -n "$HERMES_NAMESPACE" delete deploy,svc,ingress hermes-webui --ignore-not-found=true >/dev/null
  if ! is_truthy "$HERMES_BROWSER_ENABLED"; then
    kubectl -n "$HERMES_NAMESPACE" delete deploy,svc hermes-browser --ignore-not-found=true >/dev/null
    kubectl -n "$HERMES_NAMESPACE" delete networkpolicy hermes-browser-restrict --ignore-not-found=true >/dev/null
  fi

  log "Waiting for init config job"
  kubectl -n "$HERMES_NAMESPACE" wait --for=condition=complete job/hermes-init-config --timeout=300s

  mapfile -t deployments < <(enabled_deployments)
  for d in "${deployments[@]}"; do
    template_before["$d"]="$(deployment_template_digest "$d")"
  done

  log "Applying initialized workloads"
  kubectl apply -f "$MANIFEST_OUT"

  for d in "${deployments[@]}"; do
    template_after="$(deployment_template_digest "$d")"
    if [[ -n "${template_before[$d]}" && "$template_after" == "${template_before[$d]}" ]]; then
      restart_deployments+=("deploy/$d")
    fi
  done
  if ((${#restart_deployments[@]} > 0)); then
    log "Restarting unchanged deployments to pick up refreshed secrets"
    kubectl -n "$HERMES_NAMESPACE" rollout restart "${restart_deployments[@]}" >/dev/null
  fi

  log "Waiting for rollouts"
  for d in "${deployments[@]}"; do
    kubectl -n "$HERMES_NAMESPACE" rollout status "deploy/$d" --timeout=600s
  done

  # Delete the old shared app-password Secret only after all external-OIDC
  # workloads are Ready. Before this point it remains available to the previous
  # ReplicaSets for fail-safe restart/rollback if cutover fails.
  if [[ "$HERMES_AUTH_MODE" == external-oidc ]]; then
    kubectl -n "$HERMES_NAMESPACE" delete secret hermes-dashboard-auth --ignore-not-found=true >/dev/null
  fi
}

print_summary() {
  cat <<EOF

Hermes Kubernetes setup applied.

Namespace:        $HERMES_NAMESPACE
WebUI host:       ${WEBUI_HOST:-disabled}
Dashboard host:   ${DASHBOARD_HOST:-disabled}
Browser enabled:  $HERMES_BROWSER_ENABLED
Authentication:    $HERMES_AUTH_MODE
Rendered file:    $MANIFEST_OUT

Runtime credentials were applied through Kubernetes Secrets.
No credential values were stored locally or printed during installation.
Show the credentials later, when needed, with the administrator-only maintenance command:

  ./maintain.sh show-passwords
EOF
  if [[ "$HERMES_AUTH_MODE" == local-password ]]; then
    cat <<'EOF'

Rotate the local Dashboard/WebUI password later with:

  ./maintain.sh rotate-passwords
EOF
  fi
  cat <<EOF

Next step for OpenAI Codex OAuth:

  kubectl -n "$HERMES_NAMESPACE" exec -it deploy/hermes-agent -- /bin/bash
  hermes model

Run diagnostics:

  ./doctor.sh
EOF
}

main() {
  load_env
  prepare_paths
  remove_local_credential_captures
  prepare_defaults
  resolve_runtime_credentials
  validate
  create_bootstrap_archive
  preflight_manifest
  create_namespace_and_secrets
  resolve_api_key_revision
  render_manifest
  apply_and_wait
  print_summary
}

if [[ "${HERMES_INSTALL_LIB_ONLY:-false}" != "true" ]]; then
  main "$@"
fi
