#!/usr/bin/env bash
# Purpose: Create an isolated Hermes configuration and optionally run the installer.
# Scope: Drive interactive configuration, answer replay, profile composition, and
#        generation of hermes.env, bootstrap files, and installer artifacts.
# Requirements: Bash, Python 3, standard utilities, and repository bootstrap sources.
# Usage: ./configure.sh [--config-dir PATH] [--answers-file PATH] [--from-answers] [--no-install]
# Exit status: 0 means configuration completed; non-zero identifies invalid input or failure.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${HERMES_CURRENT_CONFIG_DIR:-$ROOT_DIR/current_config}"
ANSWERS_FILE="${HERMES_CONFIGURATION_ANSWERS:-$ROOT_DIR/configuration_answers}"
RUN_INSTALLER=true
FROM_ANSWERS=false
USE_ANSWER_DEFAULTS=false

usage() {
  cat <<'EOF'
Create an isolated Hermes deployment configuration and optionally run install.sh.

Usage:
  ./configure.sh [--config-dir PATH] [--answers-file PATH] [--from-answers] [--no-install]

The default ./current_config directory contains hermes.env, the fully composed
bootstrap tree, and installer artifacts. The root-level configuration_answers
file stores the answers with mode 0600. Both paths are excluded from Git.

Use --from-answers to rebuild current_config after updating the repository
without an interactive reuse question.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config-dir)
      [[ $# -ge 2 && -n "$2" ]] || { printf 'ERROR: --config-dir requires a path.\n' >&2; exit 2; }
      CONFIG_DIR="$2"; shift 2 ;;
    --answers-file)
      [[ $# -ge 2 && -n "$2" ]] || { printf 'ERROR: --answers-file requires a path.\n' >&2; exit 2; }
      ANSWERS_FILE="$2"; shift 2 ;;
    --from-answers) FROM_ANSWERS=true; shift ;;
    --no-install) RUN_INSTALLER=false; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'ERROR: unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done
CONFIG_DIR="$(mkdir -p "$(dirname "$CONFIG_DIR")" && cd "$(dirname "$CONFIG_DIR")" && pwd)/$(basename "$CONFIG_DIR")"
ANSWERS_FILE="$(mkdir -p "$(dirname "$ANSWERS_FILE")" && cd "$(dirname "$ANSWERS_FILE")" && pwd)/$(basename "$ANSWERS_FILE")"

export HERMES_INSTALL_LIB_ONLY=true
# shellcheck source=install.sh
source "$ROOT_DIR/install.sh"
unset HERMES_INSTALL_LIB_ONLY

prompt_value() {
  local label="$1" default="${2:-}" value
  if [[ -n "$default" ]]; then
    read -r -p "$label [$default]: " value
    printf '%s' "${value:-$default}"
  else
    while true; do
      read -r -p "$label: " value
      [[ -n "$value" ]] && { printf '%s' "$value"; return; }
      printf 'A value is required.\n' >&2
    done
  fi
}

ask_yes_no() {
  local label="$1" default="$2" answer suffix
  [[ "$default" == true ]] && suffix='Y/n' || suffix='y/N'
  while true; do
    read -r -p "$label [$suffix]: " answer
    answer="${answer:-$([[ "$default" == true ]] && printf y || printf n)}"
    case "$answer" in
      y|Y|yes|YES) return 0 ;;
      n|N|no|NO) return 1 ;;
      *) printf 'Please answer yes or no.\n' >&2 ;;
    esac
  done
}

if [[ "$FROM_ANSWERS" != true && -f "$ANSWERS_FILE" ]]; then
  if ask_yes_no "Reuse existing configuration answers from $ANSWERS_FILE?" true; then
    # Reuse answers as interactive defaults; do not skip the wizard questions.
    # Passwords are never stored in configuration_answers and remain prompt/generate only.
    # shellcheck disable=SC1090
    source "$ANSWERS_FILE"
    USE_ANSWER_DEFAULTS=true
  fi
fi

answer_default() {
  local name="$1" fallback="${2:-}" value=""
  [[ "$USE_ANSWER_DEFAULTS" == true && -v "$name" ]] && value="${!name}"
  printf '%s' "${value:-$fallback}"
}

answer_bool_default() {
  local name="$1" fallback="$2" value=""
  [[ "$USE_ANSWER_DEFAULTS" == true && -v "$name" ]] && value="${!name}"
  [[ "$value" == true || "$value" == false ]] && printf '%s' "$value" || printf '%s' "$fallback"
}

PROFILE_SETTING_DEFINITIONS=(
  'HERMES_ANSIBLE_SETUP|boolean|HERMES_PROFILE_DEFAULT_ANSIBLE_SETUP|false|Install and configure Ansible?|Ansible'
  'HERMES_SSH_SETUP|boolean|HERMES_PROFILE_DEFAULT_SSH_SETUP|true|Prepare a persistent SSH keypair?|SSH keys'
  'HERMES_ADDON_REQUIREMENTS|path|HERMES_PROFILE_DEFAULT_ADDON_REQUIREMENTS|||Addon packages'
)
PROFILE_CONTROLLED_SETTINGS=()
declare -A PROFILE_SETTING_TYPE=()
declare -A PROFILE_SETTING_PROFILE_DEFAULT=()
declare -A PROFILE_SETTING_GLOBAL_DEFAULT=()
declare -A PROFILE_SETTING_PROMPT=()
declare -A PROFILE_SETTING_SUMMARY=()
for profile_setting_definition in "${PROFILE_SETTING_DEFINITIONS[@]}"; do
  IFS='|' read -r setting setting_type profile_default global_default prompt summary \
    <<< "$profile_setting_definition"
  PROFILE_CONTROLLED_SETTINGS+=("$setting")
  PROFILE_SETTING_TYPE["$setting"]="$setting_type"
  PROFILE_SETTING_PROFILE_DEFAULT["$setting"]="$profile_default"
  PROFILE_SETTING_GLOBAL_DEFAULT["$setting"]="$global_default"
  PROFILE_SETTING_PROMPT["$setting"]="$prompt"
  PROFILE_SETTING_SUMMARY["$setting"]="$summary"
done
unset profile_setting_definition setting setting_type profile_default global_default prompt summary
declare -A PROFILE_SETTING_DEFAULTS=()
declare -A PROFILE_SETTING_DEFAULT_ORIGINS=()
declare -A PROFILE_SETTING_PRESET_ORIGINS=()
declare -A PROFILE_SETTING_FINAL_ORIGINS=()
PROFILE_PRESETS_CAPTURED=false
PROFILE_REQUIREMENTS_FROM_PROFILE=false
OPERATOR_ADDON_REQUIREMENTS_SOURCE=''

validate_profile_setting() {
  local setting="$1" value="$2"
  case "${PROFILE_SETTING_TYPE[$setting]}" in
    boolean)
      [[ "$value" == true || "$value" == false ]] || {
        printf 'ERROR: invalid %s value for profile %s.\n' "$setting" "$HERMES_BOOTSTRAP_PROFILE" >&2
        return 1
      }
      ;;
    path)
      [[ -z "$value" || -f "$value" ]] || {
        printf 'ERROR: %s does not exist or is not a file: %s\n' "$setting" "$value" >&2
        return 1
      }
      ;;
    *)
      printf 'ERROR: unsupported profile setting type for %s.\n' "$setting" >&2
      return 1
      ;;
  esac
}

load_profile_setting_defaults() {
  local profile="$1"
  local profile_dir="$ROOT_DIR/examples/bootstrap-profiles/$profile"
  local defaults="$profile_dir/defaults.conf" setting value origin
  [[ -f "$defaults" ]] || { printf 'ERROR: profile %s is missing defaults.conf.\n' "$profile" >&2; return 1; }
  if grep -Ev '^[[:space:]]*(#.*|$|HERMES_PROFILE_DEFAULT_[A-Z0-9_]+=[^[:space:]]*)$' "$defaults" | grep -q .; then
    printf 'ERROR: profile %s has invalid entries in defaults.conf.\n' "$profile" >&2
    return 1
  fi
  PROFILE_SETTING_DEFAULTS=()
  PROFILE_SETTING_DEFAULT_ORIGINS=()
  while IFS=$'\034' read -r setting value origin; do
    validate_profile_setting "$setting" "$value" || return 1
    PROFILE_SETTING_DEFAULTS["$setting"]="$value"
    PROFILE_SETTING_DEFAULT_ORIGINS["$setting"]="$origin"
  done < <(
    unset HERMES_PROFILE_DEFAULT_SSH_SETUP HERMES_PROFILE_DEFAULT_ANSIBLE_SETUP
    unset HERMES_PROFILE_DEFAULT_ADDON_REQUIREMENTS
    # defaults.conf is repository-controlled and validated above.
    # shellcheck disable=SC1090
    source "$defaults"
    for setting in "${PROFILE_CONTROLLED_SETTINGS[@]}"; do
      profile_name="${PROFILE_SETTING_PROFILE_DEFAULT[$setting]}"
      if [[ -v "$profile_name" ]]; then
        value="${!profile_name}"
        origin='selected profile'
      else
        value="${PROFILE_SETTING_GLOBAL_DEFAULT[$setting]}"
        origin='global fallback'
      fi
      if [[ "${PROFILE_SETTING_TYPE[$setting]}" == path && -n "$value" ]]; then
        value="$profile_dir/$value"
      fi
      printf '%s\034%s\034%s\n' "$setting" "$value" "$origin"
    done
  )
}

resolve_profile_setting_default() {
  local setting="$1" value
  if [[ -v "$setting" ]]; then
    value="${!setting}"
  else
    value="${PROFILE_SETTING_DEFAULTS[$setting]}"
  fi
  validate_profile_setting "$setting" "$value" || return 1
  printf '%s' "$value"
}

profile_setting_preset_origin() {
  local setting="$1"
  if [[ -v "$setting" ]]; then
    if [[ ( "$USE_ANSWER_DEFAULTS" == true || "$FROM_ANSWERS" == true ) && \
      -f "$ANSWERS_FILE" ]] && grep -Eq -- "^${setting}=" "$ANSWERS_FILE"; then
      printf 'reused answers'
    else
      printf 'current environment'
    fi
  else
    printf '%s' "${PROFILE_SETTING_DEFAULT_ORIGINS[$setting]}"
  fi
}

capture_and_print_profile_presets() {
  local setting value origin
  printf '\nProfile presets (%s):\n' "$HERMES_BOOTSTRAP_PROFILE"
  for setting in "${PROFILE_CONTROLLED_SETTINGS[@]}"; do
    [[ "${PROFILE_SETTING_TYPE[$setting]}" == boolean ]] || continue
    value="$(resolve_profile_setting_default "$setting")" || return 1
    origin="$(profile_setting_preset_origin "$setting")"
    PROFILE_SETTING_PRESET_ORIGINS["$setting"]="$origin"
    PROFILE_SETTING_FINAL_ORIGINS["$setting"]="$origin"
    printf '  %s: %s [%s]\n' "${PROFILE_SETTING_SUMMARY[$setting]}" "$value" "$origin"
  done
  printf '\n'
  PROFILE_PRESETS_CAPTURED=true
}

resolve_missing_profile_settings() {
  local setting value was_set
  if [[ "${HERMES_PROFILE_REQUIREMENTS_SELECTED:-false}" == true ]]; then
    PROFILE_REQUIREMENTS_FROM_PROFILE=true
    unset HERMES_ADDON_REQUIREMENTS
  fi
  for setting in "${PROFILE_CONTROLLED_SETTINGS[@]}"; do
    was_set=false
    [[ -v "$setting" ]] && was_set=true
    value="$(resolve_profile_setting_default "$setting")" || return 1
    printf -v "$setting" '%s' "$value"
    export "$setting"
    if [[ "$setting" == HERMES_ADDON_REQUIREMENTS && "$was_set" == false && -n "$value" ]]; then
      PROFILE_REQUIREMENTS_FROM_PROFILE=true
    fi
  done
}

prompt_profile_boolean_setting() {
  local setting="$1" default origin answer suffix value
  [[ "${PROFILE_SETTING_TYPE[$setting]}" == boolean ]] || return 1
  default="$(resolve_profile_setting_default "$setting")" || return 1
  [[ "$default" == true ]] && suffix='Y/n' || suffix='y/N'
  while true; do
    origin="${PROFILE_SETTING_PRESET_ORIGINS[$setting]}"
    read -r -p "${PROFILE_SETTING_PROMPT[$setting]} [$suffix]: " answer
    if [[ -z "$answer" ]]; then
      value="$default"
    else
      origin='explicit answer'
      case "$answer" in
        y|Y|yes|YES) value=true ;;
        n|N|no|NO) value=false ;;
        *) printf 'Please answer yes or no.\n' >&2; continue ;;
      esac
    fi
    printf '%s\t%s\n' "$value" "$origin"
    return
  done
}

write_profile_settings() {
  local target="$1" mode="${2:-environment}" setting value
  for setting in "${PROFILE_CONTROLLED_SETTINGS[@]}"; do
    value="${!setting}"
    if [[ "$mode" == answers && "$setting" == HERMES_ADDON_REQUIREMENTS ]]; then
      if [[ "$PROFILE_REQUIREMENTS_FROM_PROFILE" == true ]]; then
        value=''
      elif [[ -n "$OPERATOR_ADDON_REQUIREMENTS_SOURCE" ]]; then
        value="$OPERATOR_ADDON_REQUIREMENTS_SOURCE"
      fi
    fi
    write_setting "$target" "$setting" "$value"
  done
}

print_profile_setting_summary() {
  local setting value suffix
  for setting in "${PROFILE_CONTROLLED_SETTINGS[@]}"; do
    value="${!setting}"
    suffix=''
    if [[ "$setting" == HERMES_ANSIBLE_SETUP && "$value" == true ]]; then
      suffix=" ($HERMES_ANSIBLE_VERSION)"
    elif [[ "${PROFILE_SETTING_TYPE[$setting]}" == path ]]; then
      [[ -n "$value" ]] && value=true || value=false
    fi
    if [[ "${PROFILE_SETTING_TYPE[$setting]}" == boolean ]]; then
      printf '  %-12s %s%s [%s]\n' "${PROFILE_SETTING_SUMMARY[$setting]}:" "$value" "$suffix" \
        "${PROFILE_SETTING_FINAL_ORIGINS[$setting]:-${PROFILE_SETTING_PRESET_ORIGINS[$setting]:-reused answers}}"
    else
      printf '  %-12s %s%s\n' "${PROFILE_SETTING_SUMMARY[$setting]}:" "$value" "$suffix"
    fi
  done
}

validate_hostname() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && "$1" == *.* ]]
}

prompt_hostname() {
  local label="$1" default="$2" value
  while true; do
    value="$(prompt_value "$label" "$default")"
    validate_hostname "$value" && { printf '%s' "$value"; return; }
    printf 'Enter a DNS hostname such as hermes.example.com.\n' >&2
  done
}

prompt_password() {
  local first second
  while true; do
    read -r -s -p 'Dashboard/WebUI password (leave empty to generate): ' first; printf '\n' >&2
    [[ -z "$first" ]] && { printf ''; return; }
    read -r -s -p 'Confirm Dashboard/WebUI password: ' second; printf '\n' >&2
    [[ "$first" == "$second" ]] || { printf 'Passwords do not match.\n' >&2; continue; }
    if (( ${#first} < 14 )); then
      printf 'Use at least 14 characters, or leave empty for a generated password.\n' >&2
      continue
    fi
    printf '%s' "$first"
    return
  done
}

write_setting() {
  local target="$1" name="$2" value="$3"
  printf '%s=%q\n' "$name" "$value" >> "$target"
}

if [[ "$FROM_ANSWERS" == true ]]; then
  [[ -f "$ANSWERS_FILE" ]] || { printf 'ERROR: answers file not found: %s\n' "$ANSWERS_FILE" >&2; exit 1; }
  # Generated by this script, mode 0600, and Git-ignored.
  # shellcheck disable=SC1090
  source "$ANSWERS_FILE"
  printf 'Rebuilding current_config from %s\n' "$ANSWERS_FILE"
else
  printf '\nHermes Kubernetes configuration wizard\n'
  printf 'The Agent is mandatory. Optional components can be selected independently.\n\n'

  HERMES_NAMESPACE="$(prompt_value 'Kubernetes namespace' "$(answer_default HERMES_NAMESPACE hermes)")"
  profile_default="$(answer_default HERMES_BOOTSTRAP_PROFILE personal-assistant)"
    # Discover available profiles dynamically from the repository
    declare -a profile_names=()
    declare -a profile_descriptions=()
    declare -i index=1
    declare -i default_index=1
    local_profile_dir=""
    local_profile_name=""
    local_soul_line=""
    for local_profile_dir in "$ROOT_DIR/examples/bootstrap-profiles/"*/; do
      [[ -d "$local_profile_dir" ]] || continue
      local_profile_name="$(basename "$local_profile_dir")"
      profile_names+=("$local_profile_name")
      # Read first line of SOUL.md for a one-line description
      local_soul_line=""
      [[ -f "$local_profile_dir/SOUL.md" ]] && local_soul_line="$(head -1 "$local_profile_dir/SOUL.md" 2>/dev/null || true)"
      profile_descriptions+=("${local_soul_line:-$local_profile_name}")
      [[ "$local_profile_name" == "$profile_default" ]] && default_index=$index
      index=$((index + 1))
    done
    declare -i profile_count=$((index - 1))
    while true; do
      printf 'Bootstrap profile:\n'
      index=1
      for local_profile_name in "${profile_names[@]}"; do
        printf '  %d) %s\n' "$index" "$local_profile_name"
        index=$((index + 1))
      done
      read -r -p "Select profile [$default_index]: " profile_choice
      profile_choice="${profile_choice:-$default_index}"
      # Match by number or by exact name
      if [[ "$profile_choice" =~ ^[0-9]+$ ]] && (( profile_choice >= 1 && profile_choice <= profile_count )); then
        HERMES_BOOTSTRAP_PROFILE="${profile_names[$((profile_choice - 1))]}"
        break
      fi
      matched=false
      for local_profile_name in "${profile_names[@]}"; do
        if [[ "$profile_choice" == "$local_profile_name" ]]; then
          HERMES_BOOTSTRAP_PROFILE="$local_profile_name"
          matched=true
          break
        fi
      done
      if [[ "$matched" == true ]]; then
        break
      fi
      printf 'Choose a number or profile name from the list above.\n' >&2
    done

  load_profile_setting_defaults "$HERMES_BOOTSTRAP_PROFILE"
  capture_and_print_profile_presets

  MODEL_PROVIDER="$(prompt_value 'Hermes model provider' "$(answer_default MODEL_PROVIDER openai-codex)")"
  MODEL_NAME="$(prompt_value 'Hermes model' "$(answer_default MODEL_NAME gpt-5.6-luna)")"

  HERMES_AGENT_IMAGE="$(prompt_value 'Hermes Agent container image' "$(answer_default HERMES_AGENT_IMAGE nousresearch/hermes-agent:v0.22.5)")"
  HERMES_WEBUI_IMAGE="$(prompt_value 'Hermes WebUI container image' "$(answer_default HERMES_WEBUI_IMAGE ghcr.io/nesquena/hermes-webui:0.52.602)")"
  HERMES_BROWSER_IMAGE="$(prompt_value 'Browserless Chromium container image' "$(answer_default HERMES_BROWSER_IMAGE ghcr.io/browserless/chromium:v2.58.1)")"
  HERMES_IMAGE_PULL_POLICY="$(answer_default HERMES_IMAGE_PULL_POLICY IfNotPresent)"
  while true; do
    read -r -p "Image pull policy [$HERMES_IMAGE_PULL_POLICY] (IfNotPresent/Always): " image_pull_policy
    HERMES_IMAGE_PULL_POLICY="${image_pull_policy:-$HERMES_IMAGE_PULL_POLICY}"
    [[ "$HERMES_IMAGE_PULL_POLICY" == IfNotPresent || "$HERMES_IMAGE_PULL_POLICY" == Always ]] && break
    printf 'Choose IfNotPresent or Always.\n' >&2
  done

  HERMES_DASHBOARD_ENABLED="$(answer_bool_default HERMES_DASHBOARD_ENABLED true)"
  HERMES_WEBUI_ENABLED="$(answer_bool_default HERMES_WEBUI_ENABLED true)"
  HERMES_BROWSER_ENABLED="$(answer_bool_default HERMES_BROWSER_ENABLED true)"
  if ask_yes_no 'Install Dashboard?' "$HERMES_DASHBOARD_ENABLED"; then HERMES_DASHBOARD_ENABLED=true; else HERMES_DASHBOARD_ENABLED=false; fi
  if ask_yes_no 'Install WebUI?' "$HERMES_WEBUI_ENABLED"; then HERMES_WEBUI_ENABLED=true; else HERMES_WEBUI_ENABLED=false; fi
  if ask_yes_no 'Install Browserless Chromium?' "$HERMES_BROWSER_ENABLED"; then HERMES_BROWSER_ENABLED=true; else HERMES_BROWSER_ENABLED=false; fi

  WEBUI_HOST="$(answer_default WEBUI_HOST '')"
  DASHBOARD_HOST="$(answer_default DASHBOARD_HOST '')"
  [[ "$HERMES_WEBUI_ENABLED" == true ]] && WEBUI_HOST="$(prompt_hostname 'WebUI hostname' "$(answer_default WEBUI_HOST hermes.example.com)")"
  [[ "$HERMES_DASHBOARD_ENABLED" == true ]] && DASHBOARD_HOST="$(prompt_hostname 'Dashboard hostname' "$(answer_default DASHBOARD_HOST hermes-admin.example.com)")"

  # Auth mode gates which credentials the wizard asks for below. Kept as a
  # single upfront choice (mirrors the Image pull policy prompt style) so
  # local-password and external-oidc never both ask questions.
  HERMES_AUTH_MODE="$(answer_default HERMES_AUTH_MODE local-password)"
  if [[ "$HERMES_DASHBOARD_ENABLED" == true || "$HERMES_WEBUI_ENABLED" == true ]]; then
    while true; do
      read -r -p "Authentication mode [$HERMES_AUTH_MODE] (local-password/external-oidc): " auth_mode_answer
      HERMES_AUTH_MODE="${auth_mode_answer:-$HERMES_AUTH_MODE}"
      [[ "$HERMES_AUTH_MODE" == local-password || "$HERMES_AUTH_MODE" == external-oidc ]] && break
      printf 'Choose local-password or external-oidc.\n' >&2
    done
  else
    HERMES_AUTH_MODE=local-password
  fi

  DASHBOARD_AUTH_USER="$(answer_default DASHBOARD_AUTH_USER '')"
  DASHBOARD_AUTH_PASSWORD=''
  HERMES_OIDC_ISSUER="$(answer_default HERMES_OIDC_ISSUER '')"
  HERMES_DASHBOARD_OIDC_CLIENT_ID="$(answer_default HERMES_DASHBOARD_OIDC_CLIENT_ID '')"
  HERMES_DASHBOARD_PUBLIC_URL="$(answer_default HERMES_DASHBOARD_PUBLIC_URL '')"
  HERMES_WEBUI_OIDC_CLIENT_ID="$(answer_default HERMES_WEBUI_OIDC_CLIENT_ID '')"
  HERMES_WEBUI_OIDC_REDIRECT_URI="$(answer_default HERMES_WEBUI_OIDC_REDIRECT_URI '')"
  HERMES_WEBUI_OIDC_ALLOW_CLAIM="$(answer_default HERMES_WEBUI_OIDC_ALLOW_CLAIM '')"
  HERMES_WEBUI_OIDC_ALLOW_VALUES="$(answer_default HERMES_WEBUI_OIDC_ALLOW_VALUES '')"

  if [[ "$HERMES_AUTH_MODE" == local-password ]]; then
    if [[ "$HERMES_DASHBOARD_ENABLED" == true || "$HERMES_WEBUI_ENABLED" == true ]]; then
      if [[ "$HERMES_DASHBOARD_ENABLED" == true ]]; then
        DASHBOARD_AUTH_USER="$(prompt_value 'Dashboard username' "$(answer_default DASHBOARD_AUTH_USER admin)")"
        [[ "$DASHBOARD_AUTH_USER" =~ ^[A-Za-z0-9._-]+$ ]] || { printf 'ERROR: invalid Dashboard username.\n' >&2; exit 1; }
      else
        DASHBOARD_AUTH_USER=admin
      fi
      DASHBOARD_AUTH_PASSWORD="$(prompt_password)"
    fi
  else
    # Required fields mirror install.sh's validate_external_oidc_urls /
    # HERMES_AUTH_MODE=external-oidc checks exactly, so there is one place
    # that decides what's required (install.sh fails closed if anything here
    # is left as a placeholder or blank).
    HERMES_OIDC_ISSUER="$(prompt_value 'OIDC issuer URL (shared by Dashboard/WebUI unless overridden in hermes.env)' "$(answer_default HERMES_OIDC_ISSUER https://sso.example.com)")"
    if [[ "$HERMES_DASHBOARD_ENABLED" == true ]]; then
      HERMES_DASHBOARD_OIDC_CLIENT_ID="$(prompt_value 'Dashboard OIDC client ID' "$(answer_default HERMES_DASHBOARD_OIDC_CLIENT_ID hermes-dashboard)")"
      HERMES_DASHBOARD_PUBLIC_URL="$(prompt_value 'Dashboard public URL' "$(answer_default HERMES_DASHBOARD_PUBLIC_URL "https://${DASHBOARD_HOST:-hermes-admin.example.com}")")"
    fi
    if [[ "$HERMES_WEBUI_ENABLED" == true ]]; then
      HERMES_WEBUI_OIDC_CLIENT_ID="$(prompt_value 'WebUI OIDC client ID' "$(answer_default HERMES_WEBUI_OIDC_CLIENT_ID hermes-webui)")"
      HERMES_WEBUI_OIDC_REDIRECT_URI="$(prompt_value 'WebUI OIDC redirect URI' "$(answer_default HERMES_WEBUI_OIDC_REDIRECT_URI "https://${WEBUI_HOST:-hermes.example.com}/api/auth/oidc/callback")")"
      HERMES_WEBUI_OIDC_ALLOW_CLAIM="$(prompt_value 'WebUI allow claim (e.g. groups)' "$(answer_default HERMES_WEBUI_OIDC_ALLOW_CLAIM groups)")"
      HERMES_WEBUI_OIDC_ALLOW_VALUES="$(prompt_value 'WebUI allow values (comma-separated)' "$(answer_default HERMES_WEBUI_OIDC_ALLOW_VALUES hermes-users)")"
    fi
  fi

  IFS=$'\t' read -r HERMES_ANSIBLE_SETUP ansible_origin < <(prompt_profile_boolean_setting HERMES_ANSIBLE_SETUP)
  PROFILE_SETTING_FINAL_ORIGINS[HERMES_ANSIBLE_SETUP]="$ansible_origin"
  HERMES_ANSIBLE_VERSION="$(answer_default HERMES_ANSIBLE_VERSION '')"
  if [[ "$HERMES_ANSIBLE_SETUP" == true ]]; then
    while true; do
      HERMES_ANSIBLE_VERSION="$(prompt_value 'Ansible package version' "$(answer_default HERMES_ANSIBLE_VERSION 14.1.0)")"
      [[ "$HERMES_ANSIBLE_VERSION" =~ ^[0-9]+([.][0-9]+){1,2}$ ]] && break
      printf 'Enter a package version such as 14.1.0.\n' >&2
    done
    HERMES_SSH_SETUP=true
    PROFILE_SETTING_FINAL_ORIGINS[HERMES_SSH_SETUP]='dependency: Ansible'
    printf 'SSH key setup enabled because Ansible was selected.\n'
  else
    HERMES_ANSIBLE_SETUP=false
    IFS=$'\t' read -r HERMES_SSH_SETUP ssh_origin < <(prompt_profile_boolean_setting HERMES_SSH_SETUP)
    PROFILE_SETTING_FINAL_ORIGINS[HERMES_SSH_SETUP]="$ssh_origin"
  fi

  HERMES_ADDON_PYTHON_VERSION="$(answer_default HERMES_ADDON_PYTHON_VERSION '')"
  if ask_yes_no 'Install addon Python packages?' "$([[ -n "$HERMES_ADDON_PYTHON_VERSION" ]] && echo true || echo false)"; then
    while true; do
      HERMES_ADDON_PYTHON_VERSION="$(prompt_value 'Python version for addon packages' "$(answer_default HERMES_ADDON_PYTHON_VERSION 3.13)")"
      [[ "$HERMES_ADDON_PYTHON_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] && break
      printf 'Enter a Python version such as 3.13 or 3.13.5.\n' >&2
    done
  else
    HERMES_ADDON_PYTHON_VERSION=
  fi

  bootstrap_overwrite_default=false
  [[ "${HERMES_BOOTSTRAP_MODE:-}" == overwrite ]] && bootstrap_overwrite_default=true
  if ask_yes_no 'Overwrite existing bootstrap-managed files on the PVC?' "$bootstrap_overwrite_default"; then
    HERMES_BOOTSTRAP_MODE=overwrite
  else
    HERMES_BOOTSTRAP_MODE=missing
  fi
fi

if ((${#PROFILE_SETTING_DEFAULTS[@]} == 0)); then
  load_profile_setting_defaults "$HERMES_BOOTSTRAP_PROFILE"
fi
if [[ "$PROFILE_PRESETS_CAPTURED" != true ]]; then
  capture_and_print_profile_presets
fi
resolve_missing_profile_settings

: "${HERMES_NAMESPACE:?missing HERMES_NAMESPACE in answers}"
: "${HERMES_BOOTSTRAP_PROFILE:?missing HERMES_BOOTSTRAP_PROFILE in answers}"
: "${HERMES_DASHBOARD_ENABLED:?missing HERMES_DASHBOARD_ENABLED in answers}"
: "${HERMES_WEBUI_ENABLED:?missing HERMES_WEBUI_ENABLED in answers}"
: "${HERMES_BROWSER_ENABLED:?missing HERMES_BROWSER_ENABLED in answers}"
: "${HERMES_ANSIBLE_SETUP:?missing HERMES_ANSIBLE_SETUP in answers}"
: "${HERMES_SSH_SETUP:?missing HERMES_SSH_SETUP in answers}"
: "${HERMES_BOOTSTRAP_MODE:?missing HERMES_BOOTSTRAP_MODE in answers}"
WEBUI_HOST="${WEBUI_HOST:-}"
DASHBOARD_HOST="${DASHBOARD_HOST:-}"
DASHBOARD_AUTH_USER="${DASHBOARD_AUTH_USER:-}"
DASHBOARD_AUTH_PASSWORD="${DASHBOARD_AUTH_PASSWORD:-}"
HERMES_AUTH_MODE="${HERMES_AUTH_MODE:-local-password}"
HERMES_OIDC_ISSUER="${HERMES_OIDC_ISSUER:-}"
HERMES_DASHBOARD_OIDC_CLIENT_ID="${HERMES_DASHBOARD_OIDC_CLIENT_ID:-}"
HERMES_DASHBOARD_PUBLIC_URL="${HERMES_DASHBOARD_PUBLIC_URL:-}"
HERMES_WEBUI_OIDC_CLIENT_ID="${HERMES_WEBUI_OIDC_CLIENT_ID:-}"
HERMES_WEBUI_OIDC_REDIRECT_URI="${HERMES_WEBUI_OIDC_REDIRECT_URI:-}"
HERMES_WEBUI_OIDC_ALLOW_CLAIM="${HERMES_WEBUI_OIDC_ALLOW_CLAIM:-}"
HERMES_WEBUI_OIDC_ALLOW_VALUES="${HERMES_WEBUI_OIDC_ALLOW_VALUES:-}"
HERMES_AUTH_SESSION_MAX_TTL_SECONDS="${HERMES_AUTH_SESSION_MAX_TTL_SECONDS:-43200}"
HERMES_AUTH_SESSION_IDLE_TTL_SECONDS="${HERMES_AUTH_SESSION_IDLE_TTL_SECONDS:-7200}"
HERMES_ANSIBLE_VERSION="${HERMES_ANSIBLE_VERSION:-}"
HERMES_ADDON_PYTHON_VERSION="${HERMES_ADDON_PYTHON_VERSION:-}"
MODEL_PROVIDER="${MODEL_PROVIDER:-openai-codex}"
MODEL_NAME="${MODEL_NAME:-gpt-5.6-luna}"
HERMES_AGENT_IMAGE="${HERMES_AGENT_IMAGE:-nousresearch/hermes-agent:v0.22.5}"
HERMES_WEBUI_IMAGE="${HERMES_WEBUI_IMAGE:-ghcr.io/nesquena/hermes-webui:0.52.602}"
HERMES_BROWSER_IMAGE="${HERMES_BROWSER_IMAGE:-ghcr.io/browserless/chromium:v2.58.1}"
HERMES_IMAGE_PULL_POLICY="${HERMES_IMAGE_PULL_POLICY:-IfNotPresent}"
[[ "$MODEL_PROVIDER" =~ ^[A-Za-z0-9._:/-]+$ ]] || { printf 'ERROR: invalid model provider.\n' >&2; exit 1; }
[[ "$MODEL_NAME" =~ ^[A-Za-z0-9._:/-]+$ ]] || { printf 'ERROR: invalid model name.\n' >&2; exit 1; }
for image in "$HERMES_AGENT_IMAGE" "$HERMES_WEBUI_IMAGE" "$HERMES_BROWSER_IMAGE"; do
  [[ "$image" =~ ^[A-Za-z0-9._/@:-]+$ ]] || { printf 'ERROR: invalid container image reference.\n' >&2; exit 1; }
done
[[ "$HERMES_IMAGE_PULL_POLICY" == IfNotPresent || "$HERMES_IMAGE_PULL_POLICY" == Always ]] || { printf 'ERROR: invalid image pull policy.\n' >&2; exit 1; }
[[ "$HERMES_AUTH_SESSION_MAX_TTL_SECONDS" =~ ^[0-9]{1,8}$ ]] || { printf 'ERROR: auth session maximum TTL must be 1 to 8 decimal digits.\n' >&2; exit 1; }
[[ "$HERMES_AUTH_SESSION_IDLE_TTL_SECONDS" =~ ^[0-9]{1,8}$ ]] || { printf 'ERROR: auth session idle TTL must be 1 to 8 decimal digits.\n' >&2; exit 1; }
(( 10#$HERMES_AUTH_SESSION_MAX_TTL_SECONDS >= 60 && 10#$HERMES_AUTH_SESSION_MAX_TTL_SECONDS <= 31536000 )) || { printf 'ERROR: auth session maximum TTL must be between 60 and 31536000 seconds.\n' >&2; exit 1; }
(( 10#$HERMES_AUTH_SESSION_IDLE_TTL_SECONDS >= 60 && 10#$HERMES_AUTH_SESSION_IDLE_TTL_SECONDS <= 10#$HERMES_AUTH_SESSION_MAX_TTL_SECONDS )) || { printf 'ERROR: auth session idle TTL must be at least 60 seconds and no greater than the maximum TTL.\n' >&2; exit 1; }
[[ "$HERMES_BOOTSTRAP_MODE" == missing || "$HERMES_BOOTSTRAP_MODE" == overwrite ]] || { printf 'ERROR: invalid bootstrap mode in answers.\n' >&2; exit 1; }
if [[ "$HERMES_ANSIBLE_SETUP" == true ]]; then
  [[ "$HERMES_ANSIBLE_VERSION" =~ ^[0-9]+([.][0-9]+){1,2}$ ]] || { printf 'ERROR: invalid Ansible version in answers.\n' >&2; exit 1; }
  HERMES_SSH_SETUP=true
  PROFILE_SETTING_FINAL_ORIGINS[HERMES_SSH_SETUP]='dependency: Ansible'
fi

addon_requirements_content=''
if [[ -n "$HERMES_ADDON_REQUIREMENTS" ]]; then
  if [[ "$PROFILE_REQUIREMENTS_FROM_PROFILE" != true ]]; then
    OPERATOR_ADDON_REQUIREMENTS_SOURCE="$(
      python3 - "$HERMES_ADDON_REQUIREMENTS" <<'PY'
from pathlib import Path
import sys
print(Path(sys.argv[1]).resolve(strict=True))
PY
    )"
    HERMES_ADDON_REQUIREMENTS="$OPERATOR_ADDON_REQUIREMENTS_SOURCE"
  fi
  addon_requirements_content="$(<"$HERMES_ADDON_REQUIREMENTS")"
fi
CONFIG_MARKER="$CONFIG_DIR/.hermes-current-config"
if [[ -e "$CONFIG_DIR" && -n "$(find "$CONFIG_DIR" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
  if [[ "$FROM_ANSWERS" == true ]]; then
    [[ -f "$CONFIG_MARKER" ]] || {
      printf 'ERROR: refusing to replace unowned directory without %s\n' "$CONFIG_MARKER" >&2
      exit 1
    }
    rm -rf "$CONFIG_DIR"
  else
    ask_yes_no "Replace existing configuration in $CONFIG_DIR?" false || { printf 'Configuration cancelled.\n'; exit 0; }
    rm -rf "$CONFIG_DIR"
  fi
fi
mkdir -p "$CONFIG_DIR/artifacts" "$CONFIG_DIR/bootstrap"
chmod 700 "$CONFIG_DIR" "$CONFIG_DIR/artifacts" "$CONFIG_DIR/bootstrap"
: > "$CONFIG_MARKER"
chmod 600 "$CONFIG_MARKER"
if [[ -n "$HERMES_ADDON_REQUIREMENTS" ]]; then
  HERMES_ADDON_REQUIREMENTS="$CONFIG_DIR/addon-requirements.txt"
  printf '%s\n' "$addon_requirements_content" > "$HERMES_ADDON_REQUIREMENTS"
  chmod 600 "$HERMES_ADDON_REQUIREMENTS"
  if [[ "$PROFILE_REQUIREMENTS_FROM_PROFILE" == true ]]; then
    python3 "$ROOT_DIR/scripts/prepare_requirements.py" \
      "$HERMES_ADDON_REQUIREMENTS" \
      "$HERMES_ANSIBLE_SETUP" \
      "$HERMES_ANSIBLE_VERSION" \
      true
  fi
fi

# Reuse canonical profile composition so setup cannot drift from install.sh.
RENDER_DIR="$CONFIG_DIR/artifacts"
export HERMES_BOOTSTRAP_PROFILE HERMES_ANSIBLE_SETUP HERMES_SSH_SETUP
compose_profile_bootstrap "$HERMES_BOOTSTRAP_PROFILE"
cp -a "$HERMES_BOOTSTRAP_DIR"/. "$CONFIG_DIR/bootstrap"/
rm -rf "$RENDER_DIR/bootstrap-profile"
HERMES_BOOTSTRAP_DIR="$CONFIG_DIR/bootstrap"
HERMES_RENDER_DIR="$CONFIG_DIR/artifacts"

# Deliver Agent-native configuration through the existing bootstrap path to the
# persistent /opt/data/config.yaml file.
cat > "$HERMES_BOOTSTRAP_DIR/config.yaml" <<EOF
provider: $MODEL_PROVIDER
model: $MODEL_NAME
agent:
  verify_on_stop: false
terminal:
  cwd: /workspace
display:
  tool_progress: all
gateway:
  host: 0.0.0.0
  port: 8642
EOF
chmod 600 "$HERMES_BOOTSTRAP_DIR/config.yaml"

ENV_OUT="$CONFIG_DIR/hermes.env"
umask 077
: > "$ENV_OUT"
write_setting "$ENV_OUT" HERMES_NAMESPACE "$HERMES_NAMESPACE"
write_setting "$ENV_OUT" HERMES_AGENT_ENABLED true
write_setting "$ENV_OUT" HERMES_DASHBOARD_ENABLED "$HERMES_DASHBOARD_ENABLED"
write_setting "$ENV_OUT" HERMES_WEBUI_ENABLED "$HERMES_WEBUI_ENABLED"
write_setting "$ENV_OUT" HERMES_BROWSER_ENABLED "$HERMES_BROWSER_ENABLED"
write_setting "$ENV_OUT" WEBUI_HOST "$WEBUI_HOST"
write_setting "$ENV_OUT" DASHBOARD_HOST "$DASHBOARD_HOST"
write_setting "$ENV_OUT" DASHBOARD_AUTH_USER "$DASHBOARD_AUTH_USER"
write_setting "$ENV_OUT" HERMES_AUTH_MODE "$HERMES_AUTH_MODE"
write_setting "$ENV_OUT" HERMES_OIDC_ISSUER "$HERMES_OIDC_ISSUER"
write_setting "$ENV_OUT" HERMES_DASHBOARD_OIDC_CLIENT_ID "$HERMES_DASHBOARD_OIDC_CLIENT_ID"
write_setting "$ENV_OUT" HERMES_DASHBOARD_PUBLIC_URL "$HERMES_DASHBOARD_PUBLIC_URL"
write_setting "$ENV_OUT" HERMES_WEBUI_OIDC_CLIENT_ID "$HERMES_WEBUI_OIDC_CLIENT_ID"
write_setting "$ENV_OUT" HERMES_WEBUI_OIDC_REDIRECT_URI "$HERMES_WEBUI_OIDC_REDIRECT_URI"
write_setting "$ENV_OUT" HERMES_WEBUI_OIDC_ALLOW_CLAIM "$HERMES_WEBUI_OIDC_ALLOW_CLAIM"
write_setting "$ENV_OUT" HERMES_WEBUI_OIDC_ALLOW_VALUES "$HERMES_WEBUI_OIDC_ALLOW_VALUES"
write_setting "$ENV_OUT" HERMES_AUTH_SESSION_MAX_TTL_SECONDS "$HERMES_AUTH_SESSION_MAX_TTL_SECONDS"
write_setting "$ENV_OUT" HERMES_AUTH_SESSION_IDLE_TTL_SECONDS "$HERMES_AUTH_SESSION_IDLE_TTL_SECONDS"
write_setting "$ENV_OUT" MODEL_PROVIDER "$MODEL_PROVIDER"
write_setting "$ENV_OUT" MODEL_NAME "$MODEL_NAME"
write_setting "$ENV_OUT" HERMES_AGENT_IMAGE "$HERMES_AGENT_IMAGE"
write_setting "$ENV_OUT" HERMES_WEBUI_IMAGE "$HERMES_WEBUI_IMAGE"
write_setting "$ENV_OUT" HERMES_BROWSER_IMAGE "$HERMES_BROWSER_IMAGE"
write_setting "$ENV_OUT" HERMES_IMAGE_PULL_POLICY "$HERMES_IMAGE_PULL_POLICY"
write_setting "$ENV_OUT" HERMES_BOOTSTRAP_PROFILE "$HERMES_BOOTSTRAP_PROFILE"
write_setting "$ENV_OUT" HERMES_BOOTSTRAP_DIR "$HERMES_BOOTSTRAP_DIR"
write_setting "$ENV_OUT" HERMES_BOOTSTRAP_MODE "$HERMES_BOOTSTRAP_MODE"
write_setting "$ENV_OUT" HERMES_RENDER_DIR "$HERMES_RENDER_DIR"
write_profile_settings "$ENV_OUT" environment
write_setting "$ENV_OUT" HERMES_PROFILE_REQUIREMENTS_SELECTED "$PROFILE_REQUIREMENTS_FROM_PROFILE"
write_setting "$ENV_OUT" HERMES_ADDON_PYTHON_VERSION "$HERMES_ADDON_PYTHON_VERSION"
write_setting "$ENV_OUT" HERMES_ANSIBLE_VERSION "$HERMES_ANSIBLE_VERSION"
write_setting "$ENV_OUT" HERMES_SSH_GENERATE_KEY "$HERMES_SSH_SETUP"
chmod 600 "$ENV_OUT"

if [[ "$FROM_ANSWERS" != true ]]; then
  : > "$ANSWERS_FILE"
  write_setting "$ANSWERS_FILE" HERMES_NAMESPACE "$HERMES_NAMESPACE"
  write_setting "$ANSWERS_FILE" HERMES_BOOTSTRAP_PROFILE "$HERMES_BOOTSTRAP_PROFILE"
  write_setting "$ANSWERS_FILE" HERMES_DASHBOARD_ENABLED "$HERMES_DASHBOARD_ENABLED"
  write_setting "$ANSWERS_FILE" HERMES_WEBUI_ENABLED "$HERMES_WEBUI_ENABLED"
  write_setting "$ANSWERS_FILE" HERMES_BROWSER_ENABLED "$HERMES_BROWSER_ENABLED"
  write_setting "$ANSWERS_FILE" WEBUI_HOST "$WEBUI_HOST"
  write_setting "$ANSWERS_FILE" DASHBOARD_HOST "$DASHBOARD_HOST"
  write_setting "$ANSWERS_FILE" DASHBOARD_AUTH_USER "$DASHBOARD_AUTH_USER"
  write_setting "$ANSWERS_FILE" HERMES_AUTH_MODE "$HERMES_AUTH_MODE"
  write_setting "$ANSWERS_FILE" HERMES_OIDC_ISSUER "$HERMES_OIDC_ISSUER"
  write_setting "$ANSWERS_FILE" HERMES_DASHBOARD_OIDC_CLIENT_ID "$HERMES_DASHBOARD_OIDC_CLIENT_ID"
  write_setting "$ANSWERS_FILE" HERMES_DASHBOARD_PUBLIC_URL "$HERMES_DASHBOARD_PUBLIC_URL"
  write_setting "$ANSWERS_FILE" HERMES_WEBUI_OIDC_CLIENT_ID "$HERMES_WEBUI_OIDC_CLIENT_ID"
  write_setting "$ANSWERS_FILE" HERMES_WEBUI_OIDC_REDIRECT_URI "$HERMES_WEBUI_OIDC_REDIRECT_URI"
  write_setting "$ANSWERS_FILE" HERMES_WEBUI_OIDC_ALLOW_CLAIM "$HERMES_WEBUI_OIDC_ALLOW_CLAIM"
  write_setting "$ANSWERS_FILE" HERMES_WEBUI_OIDC_ALLOW_VALUES "$HERMES_WEBUI_OIDC_ALLOW_VALUES"
  write_setting "$ANSWERS_FILE" HERMES_AUTH_SESSION_MAX_TTL_SECONDS "$HERMES_AUTH_SESSION_MAX_TTL_SECONDS"
  write_setting "$ANSWERS_FILE" HERMES_AUTH_SESSION_IDLE_TTL_SECONDS "$HERMES_AUTH_SESSION_IDLE_TTL_SECONDS"
  write_setting "$ANSWERS_FILE" MODEL_PROVIDER "$MODEL_PROVIDER"
  write_setting "$ANSWERS_FILE" MODEL_NAME "$MODEL_NAME"
  write_setting "$ANSWERS_FILE" HERMES_AGENT_IMAGE "$HERMES_AGENT_IMAGE"
  write_setting "$ANSWERS_FILE" HERMES_WEBUI_IMAGE "$HERMES_WEBUI_IMAGE"
  write_setting "$ANSWERS_FILE" HERMES_BROWSER_IMAGE "$HERMES_BROWSER_IMAGE"
  write_setting "$ANSWERS_FILE" HERMES_IMAGE_PULL_POLICY "$HERMES_IMAGE_PULL_POLICY"
  write_profile_settings "$ANSWERS_FILE" answers
  write_setting "$ANSWERS_FILE" HERMES_PROFILE_REQUIREMENTS_SELECTED "$PROFILE_REQUIREMENTS_FROM_PROFILE"
  write_setting "$ANSWERS_FILE" HERMES_ADDON_PYTHON_VERSION "$HERMES_ADDON_PYTHON_VERSION"
  write_setting "$ANSWERS_FILE" HERMES_ANSIBLE_VERSION "$HERMES_ANSIBLE_VERSION"
  write_setting "$ANSWERS_FILE" HERMES_BOOTSTRAP_MODE "$HERMES_BOOTSTRAP_MODE"
  chmod 600 "$ANSWERS_FILE"
fi

printf '\nConfiguration created.\n'
printf '  Directory:  %s\n' "$CONFIG_DIR"
printf '  Environment: %s (mode 600)\n' "$ENV_OUT"
printf '  Bootstrap:   %s (%s mode)\n' "$HERMES_BOOTSTRAP_DIR" "$HERMES_BOOTSTRAP_MODE"
printf '  Agent config: %s -> /opt/data/config.yaml\n' "$HERMES_BOOTSTRAP_DIR/config.yaml"
printf '  Artifacts:   %s\n' "$HERMES_RENDER_DIR"
printf '  Credentials: Kubernetes Secrets only; values are not stored locally or printed\n'
printf '  Answers:     %s (mode 600)\n' "$ANSWERS_FILE"
printf '  Components:  agent%s%s%s\n' \
  "$([[ "$HERMES_DASHBOARD_ENABLED" == true ]] && printf ', dashboard')" \
  "$([[ "$HERMES_WEBUI_ENABLED" == true ]] && printf ', webui')" \
  "$([[ "$HERMES_BROWSER_ENABLED" == true ]] && printf ', browser')"
printf '  Auth mode:   %s\n' "$HERMES_AUTH_MODE"
print_profile_setting_summary
printf '\n'

installer_cmd="HERMES_INSTALL_LIB_ONLY=false ENV_FILE=$(printf '%q' "$ENV_OUT") $(printf '%q' "$ROOT_DIR/install.sh")"
if [[ "$RUN_INSTALLER" == true ]] && ask_yes_no 'Run install.sh now?' false; then
  HERMES_INSTALL_LIB_ONLY=false ENV_FILE="$ENV_OUT" DASHBOARD_AUTH_PASSWORD="$DASHBOARD_AUTH_PASSWORD" "$ROOT_DIR/install.sh"
else
  printf 'Run the installer with:\n  %s\n' "$installer_cmd"
fi
