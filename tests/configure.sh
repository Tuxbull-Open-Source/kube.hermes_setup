#!/usr/bin/env bash
# Purpose: Exercise the interactive configuration wizard and generated artifacts.
# Scope: Verify prompts, defaults, answer replay, validation, bootstrap composition,
#        safe environment parsing, and rendered-manifest security contracts.
# Requirements: Bash, Python 3, standard POSIX utilities, and repository scripts.
# Usage: ./tests/configure.sh
# Exit status: 0 means every configuration contract passed; non-zero identifies a failure.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d -t hermes-configure-test.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

TEST_TMP_DIR="$TMP_DIR/interactive-profile-defaults" python3 "$ROOT_DIR/tests/interactive-profile-defaults.py"
python3 "$ROOT_DIR/tests/profile-resolution-model.py"

profile_output="$TMP_DIR/profile-output"
# Exercise the interactive wizard with deterministic answers and inspect its output.
# Accept the profile, provider, image, pull-policy, and SSH defaults while
# explicitly disabling unrelated optional components.
printf '\n\n\n\n\n\n\n\nn\nn\nn\nn\n\nn\nn\n' | \
  "$ROOT_DIR/configure.sh" --no-install \
    --config-dir "$TMP_DIR/profile-config" \
    --answers-file "$TMP_DIR/profile-answers" > "$profile_output"
# Profile menu is now dynamically discovered; verify at least all expected profiles appear.
grep -qx 'Bootstrap profile:' "$profile_output"
grep -E '^  [0-9]+\) personal-assistant$' "$profile_output"
grep -E '^  [0-9]+\) universal-system-architect$' "$profile_output"
grep -E '^  [0-9]+\) universal-system-administrator$' "$profile_output"
grep -Fqx '  Credentials: Kubernetes Secrets only; values are not stored locally or printed' "$profile_output"
# The default interactive personal-assistant profile must carry its profile SSH
# default through the wizard when the SSH prompt is accepted unchanged.
# shellcheck disable=SC1090
source "$TMP_DIR/profile-config/hermes.env"
[[ "$HERMES_BOOTSTRAP_PROFILE" == personal-assistant ]]
[[ "$HERMES_SSH_SETUP" == true ]]

# Verify operational-script environment-file fallback and process-variable precedence.
# Operational scripts prefer an existing root hermes.env, then discover the
# wizard-generated current_config/hermes.env when no root file exists.
fallback_root="$TMP_DIR/env-fallback"
mkdir -p "$fallback_root/current_config"
cp "$ROOT_DIR/install.sh" "$ROOT_DIR/maintain.sh" "$ROOT_DIR/doctor.sh" "$fallback_root/"
printf '%s\n' 'DASHBOARD_AUTH_PASSWORD=' 'BROWSER_TOKEN=' > "$fallback_root/current_config/hermes.env"
resolved_env="$(HERMES_INSTALL_LIB_ONLY=true bash -c 'source "$1/install.sh"; printf "%s" "$ENV_FILE"' _ "$fallback_root")"
[[ "$resolved_env" == "$fallback_root/current_config/hermes.env" ]]
maintain_env="$(SCRIPT_ROOT="$fallback_root" bash -c 'set -- help; source "$SCRIPT_ROOT/maintain.sh" >/dev/null; printf "%s" "$ENV_FILE"')"
[[ "$maintain_env" == "$fallback_root/current_config/hermes.env" ]]
rotation_inputs="$(DASHBOARD_AUTH_PASSWORD='process-password' BROWSER_TOKEN='process-token' SCRIPT_ROOT="$fallback_root" bash -c 'set -- help; source "$SCRIPT_ROOT/maintain.sh" >/dev/null; printf "%s,%s" "$(secret_from_env DASHBOARD_AUTH_PASSWORD)" "$(secret_from_env BROWSER_TOKEN)"')"
[[ "$rotation_inputs" == 'process-password,process-token' ]]
for script in install.sh maintain.sh doctor.sh; do
  grep -Fq 'DEFAULT_ENV_FILE="$ROOT_DIR/current_config/hermes.env"' "$fallback_root/$script"
done
grep -Fq 'chown -R ${HERMES_RUNTIME_UID}:${HERMES_RUNTIME_GID} /opt/data /workspace' "$ROOT_DIR/maintain.sh"
! grep -Fq 'chown -R 1000:1000' "$ROOT_DIR/maintain.sh"
grep -Fq 'find /opt/data /workspace -mindepth 1 -maxdepth 1 -exec rm -rf {} +' "$ROOT_DIR/maintain.sh"
! grep -Fq -- '--from-literal' "$ROOT_DIR/maintain.sh"
grep -Fq 'apply_browser_secret_file() {' "$ROOT_DIR/maintain.sh"
grep -Fq -- '--from-file="$key=$source_file"' "$ROOT_DIR/maintain.sh"
grep -Fq 'restore_browser_secret_pair() {' "$ROOT_DIR/maintain.sh"
grep -Fq 'apply_browser_secret_pair() {' "$ROOT_DIR/maintain.sh"
grep -Fq 'chmod 600 "$out"' "$ROOT_DIR/maintain.sh"
grep -Fq 'chmod 600 "$checksum"' "$ROOT_DIR/maintain.sh"
grep -Fq 'umask 077' "$ROOT_DIR/maintain.sh"
grep -Fq 'trap '\''rm -rf -- "$tmpdir"'\'' ERR' "$ROOT_DIR/maintain.sh"
grep -Fq 'trap '\''rm -rf -- "$dash_tmpdir"'\'' ERR' "$ROOT_DIR/install.sh"
grep -Fq 'trap '\''rm -rf -- "$secret_tmpdir"'\'' ERR' "$ROOT_DIR/install.sh"
grep -Fq 'uv pip install --python "$HERMES_ADDON_VENV/bin/python" -r /tmp/hermes-bootstrap/addons/requirements.txt' "$ROOT_DIR/manifests/hermes.yaml.tpl"
grep -Fq 'uv pip uninstall --python "$HERMES_ADDON_VENV/bin/python" ansible ansible-core' "$ROOT_DIR/manifests/hermes.yaml.tpl"
! grep -Fq 'uv pip install --exact' "$ROOT_DIR/manifests/hermes.yaml.tpl"
! grep -Fq 'uv pip compile --python' "$ROOT_DIR/manifests/hermes.yaml.tpl"
! grep -Fq 'uv pip sync --python' "$ROOT_DIR/manifests/hermes.yaml.tpl"
mkdir -p "$TMP_DIR/uv-policy-bin" "$TMP_DIR/uv-policy-venv/bin"
python3 - "$ROOT_DIR/manifests/hermes.yaml.tpl" "$TMP_DIR/uv-policy-snippet.sh" <<'PY'
from pathlib import Path
import sys, textwrap
source, output = map(Path, sys.argv[1:])
text = source.read_text()
start = text.index('              uv pip install --python')
end = text.index('              fi\n', start) + len('              fi\n')
output.write_text('set -eu\n' + textwrap.dedent(text[start:end]))
PY
cat > "$TMP_DIR/uv-policy-bin/uv" <<'UV'
#!/usr/bin/env sh
printf '%s\n' "$*" >> "${UV_POLICY_CALLS:?}"
if [ "${UV_POLICY_FAIL_UNINSTALL:-false}" = true ]; then
  case " $* " in *' pip uninstall '*) exit 42 ;; esac
fi
UV
chmod 700 "$TMP_DIR/uv-policy-bin/uv"
: > "$TMP_DIR/uv-policy-venv/bin/python"
chmod 700 "$TMP_DIR/uv-policy-venv/bin/python"
for provenance in false true; do
  for ansible_setup in false true; do
    calls="$TMP_DIR/uv-policy-$provenance-$ansible_setup.calls"
    PATH="$TMP_DIR/uv-policy-bin:$PATH" UV_POLICY_CALLS="$calls" \
      HERMES_ADDON_VENV="$TMP_DIR/uv-policy-venv" \
      HERMES_PROFILE_REQUIREMENTS_SELECTED="$provenance" HERMES_ANSIBLE_SETUP="$ansible_setup" \
      sh "$TMP_DIR/uv-policy-snippet.sh"
    grep -Fq 'pip install --python' "$calls"
    if [[ "$provenance" == true && "$ansible_setup" == false ]]; then
      grep -Fq 'pip uninstall --python' "$calls"
    else
      ! grep -Fq 'pip uninstall --python' "$calls"
    fi
  done
done
if PATH="$TMP_DIR/uv-policy-bin:$PATH" UV_POLICY_CALLS="$TMP_DIR/uv-policy-failure.calls" \
  UV_POLICY_FAIL_UNINSTALL=true HERMES_ADDON_VENV="$TMP_DIR/uv-policy-venv" \
  HERMES_PROFILE_REQUIREMENTS_SELECTED=true HERMES_ANSIBLE_SETUP=false \
  sh "$TMP_DIR/uv-policy-snippet.sh" >/dev/null 2>&1; then
  printf 'Ansible cleanup failure unexpectedly ignored\n' >&2
  exit 1
fi
grep -Fq 'pip uninstall --python' "$TMP_DIR/uv-policy-failure.calls"
grep -Fq 'trap backup_on_exit EXIT' "$ROOT_DIR/maintain.sh"
grep -Fq 'show-passwords) show_passwords' "$ROOT_DIR/maintain.sh"
! grep -Fq 'get secret hermes-dashboard-auth -o jsonpath' "$ROOT_DIR/install.sh"
! grep -Fq 'get secret hermes-api-server -o jsonpath' "$ROOT_DIR/install.sh"
! grep -Fq 'get secret hermes-browser-token -o jsonpath' "$ROOT_DIR/install.sh"
grep -Fq 'show_secret_value "Dashboard/WebUI password" hermes-dashboard-auth password' "$ROOT_DIR/maintain.sh"
grep -Fq 'show_secret_value "API server key" hermes-api-server api-key' "$ROOT_DIR/maintain.sh"
grep -Fq 'show_secret_value "Browserless token" hermes-browser-token token' "$ROOT_DIR/maintain.sh"
grep -Fq 'generate_password() { openssl rand -base64' "$ROOT_DIR/install.sh"
grep -Fq 'generate_password() { openssl rand -base64' "$ROOT_DIR/maintain.sh"
for credential_script in "$ROOT_DIR/install.sh" "$ROOT_DIR/maintain.sh"; do
  ! grep -E -n 'md5sum|md5\(' "$credential_script" >/dev/null
done
password_test="$(HERMES_INSTALL_LIB_ONLY=true bash -c 'source "$1/install.sh"; generate_password 36' _ "$ROOT_DIR")"
[[ "${#password_test}" -eq 48 ]]
[[ "$password_test" =~ ^[A-Za-z0-9+/=]+$ ]]
grep -Fq 'parse_env_file' "$ROOT_DIR/maintain.sh"
grep -Fq 'parse_env_file' "$ROOT_DIR/doctor.sh"
grep -Fq 'reject_control_chars' "$ROOT_DIR/scripts/render_template.py"
grep -Fq 'require_pattern' "$ROOT_DIR/scripts/render_template.py"
! grep -Fq 'source "$ENV_FILE"' "$ROOT_DIR/install.sh"
! grep -Fq 'source "$ENV_FILE"' "$ROOT_DIR/maintain.sh"
! grep -Fq 'source "$ENV_FILE"' "$ROOT_DIR/doctor.sh"

grep -Fq 'trap restore_on_exit EXIT' "$ROOT_DIR/maintain.sh"
grep -Fq 'original_replicas' "$ROOT_DIR/maintain.sh"
grep -Fq 'replicas="${original_replicas[$d]}"' "$ROOT_DIR/maintain.sh"
touch "$fallback_root/hermes.env"
resolved_env="$(HERMES_INSTALL_LIB_ONLY=true bash -c 'source "$1/install.sh"; printf "%s" "$ENV_FILE"' _ "$fallback_root")"
[[ "$resolved_env" == "$fallback_root/hermes.env" ]]
touch "$fallback_root/explicit.env"
resolved_env="$(ENV_FILE="$fallback_root/explicit.env" HERMES_INSTALL_LIB_ONLY=true bash -c 'source "$1/install.sh"; printf "%s" "$ENV_FILE"' _ "$fallback_root")"
[[ "$resolved_env" == "$fallback_root/explicit.env" ]]

# configure.sh sources install.sh as a function library, but must not leak that
# mode into the installer process selected at the final prompt.
if grep -A3 'source "$ROOT_DIR/install.sh"' "$ROOT_DIR/configure.sh" | grep -q '^unset HERMES_INSTALL_LIB_ONLY$'; then
  :
else
  printf 'configure.sh does not clear installer library mode\n' >&2
  exit 1
fi
grep -q 'HERMES_INSTALL_LIB_ONLY=false ENV_FILE=' "$ROOT_DIR/configure.sh"

config_one="$TMP_DIR/current-one"
answers_one="$TMP_DIR/answers-one"
printf '\n\n\n\n\n\n\n\nn\nn\nn\ny\n13.4.0\nn\ny\n' | \
  "$ROOT_DIR/configure.sh" --no-install --config-dir "$config_one" --answers-file "$answers_one" >/dev/null

[[ -f "$config_one/hermes.env" ]]
[[ -f "$config_one/bootstrap/SOUL.md" ]]
[[ -f "$config_one/bootstrap/config.yaml" ]]
[[ ! -e "$config_one/artifacts/bootstrap-profile" ]]
[[ "$(stat -c %a "$config_one/hermes.env")" == 600 ]]
[[ "$(stat -c %a "$answers_one")" == 600 ]]
! grep -Eq 'DASHBOARD_AUTH_PASSWORD|API_SERVER_KEY|BROWSER_TOKEN' "$answers_one"
# shellcheck disable=SC1090
source "$config_one/hermes.env"
[[ "$HERMES_AGENT_ENABLED" == true ]]
[[ "$HERMES_DASHBOARD_ENABLED" == false ]]
[[ "$HERMES_WEBUI_ENABLED" == false ]]
[[ "$HERMES_BROWSER_ENABLED" == false ]]
[[ "$HERMES_ANSIBLE_SETUP" == true ]]
[[ "$HERMES_ANSIBLE_VERSION" == 13.4.0 ]]
[[ "$HERMES_SSH_SETUP" == true ]]
[[ "$HERMES_BOOTSTRAP_MODE" == overwrite ]]
[[ "$MODEL_PROVIDER" == openai-codex ]]
[[ "$MODEL_NAME" == gpt-5.6-luna ]]
[[ "$HERMES_IMAGE_PULL_POLICY" == IfNotPresent ]]
(
  export HERMES_INSTALL_LIB_ONLY=true
  export ENV_FILE="$config_one/hermes.env"
  # shellcheck disable=SC1090
  source "$ROOT_DIR/install.sh"
  load_env
  HERMES_ANSIBLE_SETUP=false
  prepare_paths
  prepare_defaults
  create_bootstrap_archive
  if tar -xOf "$BOOTSTRAP_ARCHIVE" ./addons/requirements.txt 2>/dev/null | grep -Eq '^ansible(==|$)'; then
    printf 'disabled Ansible remained in profile-owned generated requirements\n' >&2
    exit 1
  fi
)
(
  export HERMES_INSTALL_LIB_ONLY=true
  unset HERMES_PROFILE_REQUIREMENTS_SELECTED
  # shellcheck disable=SC1090
  source "$ROOT_DIR/install.sh"
  first_env="$TMP_DIR/provenance-first.env"
  second_env="$TMP_DIR/provenance-second.env"
  printf '%s\n' 'HERMES_BOOTSTRAP_PROFILE=personal-assistant' \
    'HERMES_PROFILE_REQUIREMENTS_SELECTED=true' > "$first_env"
  printf '%s\n' 'HERMES_BOOTSTRAP_PROFILE=personal-assistant' \
    'HERMES_ANSIBLE_SETUP=false' \
    "HERMES_ADDON_REQUIREMENTS=$TMP_DIR/operator-requirements.txt" > "$second_env"
  printf '%s\n' 'custom-package==1.0' 'ansible==99.0.0' > "$TMP_DIR/operator-requirements.txt"
  ENV_FILE="$first_env"
  load_env
  prepare_defaults
  [[ "$HERMES_PROFILE_REQUIREMENTS_SELECTED" == true ]]
  ENV_FILE="$second_env"
  load_env
  prepare_defaults
  [[ "$HERMES_PROFILE_REQUIREMENTS_SELECTED" == false ]]
  [[ "$HERMES_ADDON_REQUIREMENTS" == "$TMP_DIR/operator-requirements.txt" ]]
  create_bootstrap_archive
  tar -xOf "$BOOTSTRAP_ARCHIVE" ./addons/requirements.txt | grep -qx 'ansible==99.0.0'
)
if HERMES_INSTALL_LIB_ONLY=true HERMES_PROFILE_REQUIREMENTS_SELECTED=invalid \
  bash -c 'source "$1"; prepare_defaults' _ "$ROOT_DIR/install.sh" >/dev/null 2>&1; then
  printf 'invalid requirements provenance unexpectedly accepted\n' >&2
  exit 1
fi
python3 - "$config_one/bootstrap/config.yaml" <<'PY'
import sys, yaml
config = yaml.safe_load(open(sys.argv[1]))
assert config["provider"] == "openai-codex"
assert config["model"] == "gpt-5.6-luna"
assert config["terminal"]["cwd"] == "/workspace"
assert config["gateway"] == {"host": "0.0.0.0", "port": 8642}
PY
(
  export HERMES_INSTALL_LIB_ONLY=true
  # shellcheck disable=SC1090
  source "$ROOT_DIR/install.sh"
  prepare_paths
  prepare_defaults
  create_bootstrap_archive
  tar -xOf "$BOOTSTRAP_ARCHIVE" ./opt-data/config.yaml | grep -qx 'provider: openai-codex'
)

touch "$config_one/stale-marker"
"$ROOT_DIR/configure.sh" --from-answers --no-install --config-dir "$config_one" --answers-file "$answers_one" >/dev/null
[[ ! -e "$config_one/stale-marker" ]]
[[ -f "$config_one/bootstrap/SOUL.md" ]]
grep -qx 'provider: openai-codex' "$config_one/bootstrap/config.yaml"

reuse_output="$TMP_DIR/reuse-output"
initial_reuse_config="$TMP_DIR/initial-reuse"
python3 - <<'PY' | "$ROOT_DIR/configure.sh" --no-install --config-dir "$initial_reuse_config" --answers-file "$answers_one" > "$reuse_output" 2>&1
print("y")
print("\n" * 15, end="")
PY
grep -Fq 'Configuration created.' "$reuse_output"

# Verify Y pre-seeds non-secret answers while blank input accepts them.
answers_reuse="$TMP_DIR/answers-reuse"
cp "$answers_one" "$answers_reuse"
python3 - "$answers_reuse" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
values = {
    "HERMES_NAMESPACE": "reuse.example",
    "HERMES_BOOTSTRAP_PROFILE": "universal-system-architect",
    "HERMES_DASHBOARD_ENABLED": "true",
    "HERMES_WEBUI_ENABLED": "true",
    "HERMES_BROWSER_ENABLED": "false",
    "WEBUI_HOST": "webui.reuse.example",
    "DASHBOARD_HOST": "dashboard.reuse.example",
    "DASHBOARD_AUTH_USER": "reuse-admin",
    "MODEL_PROVIDER": "reuse-provider",
    "MODEL_NAME": "reuse-model",
    "HERMES_AGENT_IMAGE": "agent:reuse",
    "HERMES_WEBUI_IMAGE": "webui:reuse",
    "HERMES_BROWSER_IMAGE": "browser:reuse",
    "HERMES_IMAGE_PULL_POLICY": "Always",
    "HERMES_ANSIBLE_SETUP": "false",
    "HERMES_ADDON_PYTHON_VERSION": "3.13",
    "HERMES_ANSIBLE_VERSION": "",
    "HERMES_SSH_SETUP": "true",
    "HERMES_BOOTSTRAP_MODE": "missing",
}
lines = []
seen = set()
for line in path.read_text().splitlines():
    if "=" in line:
        key = line.split("=", 1)[0]
        if key in values:
            line = f"{key}={values[key]}"
            seen.add(key)
    lines.append(line)
for key, value in values.items():
    if key not in seen:
        lines.append(f"{key}={value}")
path.write_text("\n".join(lines) + "\n")
PY
reuse_config="$TMP_DIR/current-reuse"
python3 - <<'PY' | "$ROOT_DIR/configure.sh" --no-install --config-dir "$reuse_config" --answers-file "$answers_reuse" >/dev/null 2>&1
print("y")
print("\n" * 21, end="")
PY
# shellcheck disable=SC1090
source "$reuse_config/hermes.env"
[[ "$HERMES_NAMESPACE" == reuse.example ]]
[[ "$HERMES_BOOTSTRAP_PROFILE" == universal-system-architect ]]
[[ "$HERMES_DASHBOARD_ENABLED" == true && "$HERMES_WEBUI_ENABLED" == true && "$HERMES_BROWSER_ENABLED" == false ]]
[[ "$WEBUI_HOST" == webui.reuse.example && "$DASHBOARD_HOST" == dashboard.reuse.example ]]
[[ "$DASHBOARD_AUTH_USER" == reuse-admin ]]
[[ "$MODEL_PROVIDER" == reuse-provider && "$MODEL_NAME" == reuse-model ]]
[[ "$HERMES_IMAGE_PULL_POLICY" == Always ]]
[[ "$HERMES_ANSIBLE_SETUP" == false && "$HERMES_SSH_SETUP" == true ]]
[[ "$HERMES_BOOTSTRAP_MODE" == missing ]]

unowned="$TMP_DIR/unowned"
mkdir -p "$unowned"
touch "$unowned/must-survive"
if "$ROOT_DIR/configure.sh" --from-answers --no-install --config-dir "$unowned" --answers-file "$answers_one" >/dev/null 2>&1; then
  printf 'unsafe replay unexpectedly succeeded\n' >&2
  exit 1
fi
[[ -f "$unowned/must-survive" ]]

config_two="$TMP_DIR/current-two"
answers_two="$TMP_DIR/answers-two"
printf '\n\nopenrouter\nopenai/gpt-5.6\n\n\n\n\ny\ny\ny\nchat.example.com\nadmin.example.com\n\noperator\n\nn\nn\nn\nn\n' | \
  "$ROOT_DIR/configure.sh" --no-install --config-dir "$config_two" --answers-file "$answers_two" >/dev/null
# shellcheck disable=SC1090
source "$config_two/hermes.env"
[[ "$HERMES_DASHBOARD_ENABLED" == true ]]
[[ "$HERMES_WEBUI_ENABLED" == true ]]
[[ "$HERMES_BROWSER_ENABLED" == true ]]
[[ "$WEBUI_HOST" == chat.example.com ]]
[[ "$DASHBOARD_HOST" == admin.example.com ]]
[[ "$DASHBOARD_AUTH_USER" == operator ]]
DASHBOARD_AUTH_PASSWORD="${DASHBOARD_AUTH_PASSWORD:-}"
[[ -z "$DASHBOARD_AUTH_PASSWORD" ]]
[[ "$HERMES_ANSIBLE_SETUP" == false ]]
[[ "$HERMES_SSH_SETUP" == false ]]
[[ "$HERMES_BOOTSTRAP_MODE" == missing ]]
[[ "$MODEL_PROVIDER" == openrouter ]]
[[ "$MODEL_NAME" == openai/gpt-5.6 ]]
[[ "$HERMES_IMAGE_PULL_POLICY" == IfNotPresent ]]
[[ "$HERMES_AUTH_MODE" == local-password ]]
grep -qx 'provider: openrouter' "$config_two/bootstrap/config.yaml"
grep -qx 'model: openai/gpt-5.6' "$config_two/bootstrap/config.yaml"
(
  # shellcheck disable=SC1090
  source "$config_two/hermes.env"
  unset DASHBOARD_AUTH_PASSWORD API_SERVER_KEY BROWSER_TOKEN
  export HERMES_INSTALL_LIB_ONLY=true
  # shellcheck disable=SC1090
  source "$ROOT_DIR/install.sh"
  prepare_paths
  prepare_defaults
  DASHBOARD_AUTH_PASSWORD='test-dashboard-password'
  API_SERVER_KEY='test-api-key-long-enough'
  BROWSER_TOKEN='test-browser-token'
  resolve_runtime_credentials
  [[ ! -e "$config_two/artifacts/generated-credentials.txt" ]]
)

# external-oidc wizard path: prompt must appear only once, must skip the
# Dashboard username/password prompts entirely, and the resulting env must
# satisfy install.sh's own validate_external_oidc_urls (no duplicated
# validation logic in the wizard).
config_oidc="$TMP_DIR/current-oidc"
answers_oidc="$TMP_DIR/answers-oidc"
printf '\n\n\n\n\n\n\n\ny\ny\nn\nchat.example.com\nadmin.example.com\nexternal-oidc\nhttps://sso.example.com\nhermes-dashboard\nhttps://admin.example.com\nhermes-webui\nhttps://chat.example.com/api/auth/oidc/callback\ngroups\nhermes-users\nn\nn\nn\nn\n' | \
  "$ROOT_DIR/configure.sh" --no-install --config-dir "$config_oidc" --answers-file "$answers_oidc" >/dev/null
# shellcheck disable=SC1090
source "$config_oidc/hermes.env"
[[ "$HERMES_AUTH_MODE" == external-oidc ]]
[[ -z "${DASHBOARD_AUTH_USER:-}" ]]
! grep -Eq 'DASHBOARD_AUTH_PASSWORD' "$answers_oidc"
[[ "$HERMES_OIDC_ISSUER" == https://sso.example.com ]]
[[ "$HERMES_DASHBOARD_OIDC_CLIENT_ID" == hermes-dashboard ]]
[[ "$HERMES_DASHBOARD_PUBLIC_URL" == https://admin.example.com ]]
[[ "$HERMES_WEBUI_OIDC_CLIENT_ID" == hermes-webui ]]
[[ "$HERMES_WEBUI_OIDC_REDIRECT_URI" == https://chat.example.com/api/auth/oidc/callback ]]
[[ "$HERMES_WEBUI_OIDC_ALLOW_CLAIM" == groups ]]
[[ "$HERMES_WEBUI_OIDC_ALLOW_VALUES" == hermes-users ]]
[[ "$HERMES_AUTH_SESSION_MAX_TTL_SECONDS" == 43200 ]]
[[ "$HERMES_AUTH_SESSION_IDLE_TTL_SECONDS" == 7200 ]]
grep -Fqx 'HERMES_AUTH_SESSION_MAX_TTL_SECONDS=43200' "$answers_oidc"
grep -Fqx 'HERMES_AUTH_SESSION_IDLE_TTL_SECONDS=7200' "$answers_oidc"
(
  export HERMES_INSTALL_LIB_ONLY=true
  export ENV_FILE="$config_oidc/hermes.env"
  # shellcheck disable=SC1090
  source "$ROOT_DIR/install.sh"
  load_env
  prepare_defaults
)
# Selecting external-oidc must skip the local-password prompts even when
# only WebUI (not Dashboard) is enabled.
config_oidc_webui_only="$TMP_DIR/current-oidc-webui-only"
answers_oidc_webui_only="$TMP_DIR/answers-oidc-webui-only"
printf '\n\n\n\n\n\n\n\nn\ny\nn\nchat.example.com\nexternal-oidc\nhttps://sso.example.com\nhermes-webui\nhttps://chat.example.com/api/auth/oidc/callback\ngroups\nhermes-users\nn\nn\nn\nn\n' | \
  "$ROOT_DIR/configure.sh" --no-install --config-dir "$config_oidc_webui_only" --answers-file "$answers_oidc_webui_only" >/dev/null
# shellcheck disable=SC1090
source "$config_oidc_webui_only/hermes.env"
[[ "$HERMES_AUTH_MODE" == external-oidc ]]
[[ -z "${HERMES_DASHBOARD_OIDC_CLIENT_ID:-}" ]]
[[ "$HERMES_WEBUI_OIDC_CLIENT_ID" == hermes-webui ]]

requirements="$TMP_DIR/requirements.txt"
printf '%s\n' 'Markdown' 'ansible==14.1.0' > "$requirements"
python3 "$ROOT_DIR/scripts/prepare_requirements.py" "$requirements" true 12.2.0 false
grep -qx 'ansible==12.2.0' "$requirements"
! grep -qx 'ansible==14.1.0' "$requirements"
python3 "$ROOT_DIR/scripts/prepare_requirements.py" "$requirements" false 12.2.0 true
! grep -qi '^ansible' "$requirements"
grep -qx 'Markdown' "$requirements"

printf '%s\n' 'ansible @ https://example.com/ansible.whl' 'ansible  # inline comment' > "$requirements"
python3 "$ROOT_DIR/scripts/prepare_requirements.py" "$requirements" true 12.2.0 false
[[ "$(grep -Eci '^ansible' "$requirements")" == 1 ]]
grep -qx 'ansible==12.2.0' "$requirements"

rendered="$TMP_DIR/agent-only.yaml"
export HERMES_DASHBOARD_ENABLED=false HERMES_WEBUI_ENABLED=false HERMES_BROWSER_ENABLED=false
export HERMES_NAMESPACE=hermes WEBUI_HOST= DASHBOARD_HOST= INGRESS_CLASS_NAME=traefik TRAEFIK_ENTRYPOINT=websecure
export TLS_ENABLED=true TLS_SECRET_NAME= STORAGE_CLASS_NAME= HERMES_HOME_STORAGE_SIZE=10Gi HERMES_WORKSPACE_STORAGE_SIZE=20Gi
export HERMES_RUNTIME_UID=10000 HERMES_RUNTIME_GID=10000 HERMES_AGENT_IMAGE=agent:test HERMES_WEBUI_IMAGE=webui:test HERMES_BROWSER_IMAGE=browser:test
export HERMES_BOOTSTRAP_MODE=missing HERMES_ADDON_PYTHON_MODE=uv HERMES_UV_DIR=/opt/data/uv HERMES_ADDON_VENV=/opt/data/addon-venv HERMES_ADDON_PYTHON_VERSION=3.13
export HERMES_SSH_SETUP=false HERMES_SSH_GENERATE_KEY=false HERMES_SSH_KEY_TYPE=ed25519 HERMES_SSH_KEY_PATH=/opt/data/.ssh/id_ed25519
export BROWSER_CDP_URL=ws://hermes-browser:3000/chromium HERMES_ANSIBLE_SETUP=false HERMES_ANSIBLE_CONFIG=
export MODEL_PROVIDER=openai-codex MODEL_NAME=test HERMES_WEBUI_MAX_UPLOAD_MB=220
export HERMES_AGENT_CPU_REQUEST=100m HERMES_AGENT_MEMORY_REQUEST=256Mi HERMES_AGENT_CPU_LIMIT=1 HERMES_AGENT_MEMORY_LIMIT=1Gi
export HERMES_DASHBOARD_CPU_REQUEST=100m HERMES_DASHBOARD_MEMORY_REQUEST=96Mi HERMES_DASHBOARD_CPU_LIMIT=1 HERMES_DASHBOARD_MEMORY_LIMIT=1Gi
export HERMES_WEBUI_CPU_REQUEST=100m HERMES_WEBUI_MEMORY_REQUEST=256Mi HERMES_WEBUI_CPU_LIMIT=1 HERMES_WEBUI_MEMORY_LIMIT=2Gi
export HERMES_BROWSER_CPU_REQUEST=100m HERMES_BROWSER_MEMORY_REQUEST=128Mi HERMES_BROWSER_CPU_LIMIT=1 HERMES_BROWSER_MEMORY_LIMIT=1Gi
export API_SERVER_KEY=test BROWSER_CONCURRENT=4 BROWSER_QUEUED=10 BROWSER_TIMEOUT_MS=30000
python3 "$ROOT_DIR/scripts/render_template.py" "$ROOT_DIR/manifests/hermes.yaml.tpl" "$rendered"
python3 - "$rendered" <<'PY'
import sys, yaml
documents = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
resources = {(d.get('kind'), d.get('metadata', {}).get('name')) for d in documents}
assert ('Deployment', 'hermes-agent') in resources
for name in ('hermes-dashboard', 'hermes-webui', 'hermes-browser'):
    assert ('Deployment', name) not in resources
    assert ('Service', name) not in resources
PY

rendered_all="$TMP_DIR/all-components.yaml"
export HERMES_DASHBOARD_ENABLED=true HERMES_WEBUI_ENABLED=true HERMES_BROWSER_ENABLED=true
export WEBUI_HOST=webui.example.com DASHBOARD_HOST=dashboard.example.com
python3 "$ROOT_DIR/scripts/render_template.py" "$ROOT_DIR/manifests/hermes.yaml.tpl" "$rendered_all"
python3 - "$rendered_all" <<'PY'
import sys, yaml
for document in yaml.safe_load_all(open(sys.argv[1])):
    if document and document.get('kind') == 'Deployment' and document.get('metadata', {}).get('name') == 'hermes-webui':
        env = {item['name']: item.get('value') for item in document['spec']['template']['spec']['containers'][0]['env']}
        assert env['HERMES_NIX_BUILD'] == '1'
        assert document['spec']['template']['spec']['containers'][0]['resources']['limits']['memory'] == '2Gi'
        assert document['spec']['template']['spec']['automountServiceAccountToken'] is False
        assert document['spec']['template']['spec']['securityContext']['seccompProfile']['type'] == 'RuntimeDefault'
        assert document['spec']['template']['spec']['containers'][0]['securityContext']['allowPrivilegeEscalation'] is False
        break
else:
    raise AssertionError('hermes-webui Deployment missing')

for document in yaml.safe_load_all(open(sys.argv[1])):
    if not document or document.get('kind') != 'Deployment':
        continue
    pod = document['spec']['template']['spec']
    assert pod['automountServiceAccountToken'] is False
    assert pod['securityContext']['seccompProfile']['type'] == 'RuntimeDefault'
    if document['metadata']['name'] in ('hermes-agent', 'hermes-dashboard', 'hermes-webui'):
        assert pod['securityContext']['fsGroupChangePolicy'] == 'Always'
    if document['metadata']['name'] == 'hermes-browser':
        assert 'fsGroupChangePolicy' not in pod['securityContext']
        container = pod['containers'][0]
        assert container['securityContext']['runAsUser'] == 999
        assert container['securityContext']['runAsGroup'] == 999
        assert container['securityContext']['runAsNonRoot'] is True
        assert container['securityContext']['allowPrivilegeEscalation'] is False
        assert container['securityContext']['capabilities']['drop'] == ['ALL']
    elif document['metadata']['name'] in ('hermes-agent', 'hermes-dashboard'):
        assert pod['containers'][0]['securityContext']['allowPrivilegeEscalation'] is False
PY

printf 'configure and component tests passed\n'
