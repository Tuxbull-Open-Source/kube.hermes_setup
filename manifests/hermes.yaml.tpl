apiVersion: v1
kind: Namespace
metadata:
  name: ${HERMES_NAMESPACE}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: hermes-home
  namespace: ${HERMES_NAMESPACE}
spec:
  accessModes: ["ReadWriteOnce"]
  ${STORAGE_CLASS_NAME:+storageClassName: ${STORAGE_CLASS_NAME}}
  resources:
    requests:
      storage: ${HERMES_HOME_STORAGE_SIZE}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: hermes-workspace
  namespace: ${HERMES_NAMESPACE}
spec:
  accessModes: ["ReadWriteOnce"]
  ${STORAGE_CLASS_NAME:+storageClassName: ${STORAGE_CLASS_NAME}}
  resources:
    requests:
      storage: ${HERMES_WORKSPACE_STORAGE_SIZE}
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: hermes-dashboard-login-rewrite
  namespace: ${HERMES_NAMESPACE}
spec:
  replacePath:
    path: /auth/password-login
---
apiVersion: batch/v1
kind: Job
metadata:
  name: hermes-init-config
  namespace: ${HERMES_NAMESPACE}
spec:
  template:
    spec:
      restartPolicy: OnFailure
      automountServiceAccountToken: false
      securityContext:
        fsGroup: ${HERMES_RUNTIME_GID}
        fsGroupChangePolicy: Always
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: init
        image: ${HERMES_AGENT_IMAGE}
        imagePullPolicy: ${HERMES_IMAGE_PULL_POLICY}
        env:
        - name: HERMES_BOOTSTRAP_MODE
          value: "${HERMES_BOOTSTRAP_MODE}"
        - name: HERMES_ADDON_PYTHON_MODE
          value: "${HERMES_ADDON_PYTHON_MODE}"
        - name: HERMES_UV_DIR
          value: "${HERMES_UV_DIR}"
        - name: HERMES_ADDON_VENV
          value: "${HERMES_ADDON_VENV}"
        - name: HERMES_ADDON_PYTHON_VERSION
          value: "${HERMES_ADDON_PYTHON_VERSION}"
        - name: UV_PYTHON_INSTALL_DIR
          value: "${HERMES_UV_DIR}/python"
        - name: UV_CACHE_DIR
          value: /opt/data/.cache/uv
        - name: LANG
          value: C.UTF-8
        - name: LC_ALL
          value: C.UTF-8
        - name: HERMES_SSH_SETUP
          value: "${HERMES_SSH_SETUP}"
        - name: HERMES_SSH_GENERATE_KEY
          value: "${HERMES_SSH_GENERATE_KEY}"
        - name: HERMES_SSH_KEY_TYPE
          value: "${HERMES_SSH_KEY_TYPE}"
        - name: HERMES_SSH_KEY_PATH
          value: "${HERMES_SSH_KEY_PATH}"
        - name: BROWSER_CDP_URL
          valueFrom:
            secretKeyRef:
              name: hermes-browser-cdp
              key: BROWSER_CDP_URL
        - name: API_SERVER_KEY
          valueFrom:
            secretKeyRef:
              name: hermes-api-server
              key: api-key
        command: ["sh", "-c"]
        args:
        - |
          set -eu
          umask 077
          mkdir -p /opt/data /workspace /opt/data/.config /opt/data/.cache
          if [ "${HERMES_SSH_SETUP}" != "false" ] && [ "${HERMES_SSH_SETUP}" != "FALSE" ] && [ "${HERMES_SSH_SETUP}" != "0" ] && [ "${HERMES_SSH_SETUP}" != "no" ] && [ "${HERMES_SSH_SETUP}" != "NO" ] && [ "${HERMES_SSH_SETUP}" != "off" ] && [ "${HERMES_SSH_SETUP}" != "OFF" ]; then
            mkdir -p /opt/data/.ssh
            touch /opt/data/.ssh/known_hosts
            chmod 700 /opt/data/.ssh
            chmod 644 /opt/data/.ssh/known_hosts
            if [ "${HERMES_SSH_GENERATE_KEY}" != "false" ] && [ "${HERMES_SSH_GENERATE_KEY}" != "FALSE" ] && [ "${HERMES_SSH_GENERATE_KEY}" != "0" ] && [ "${HERMES_SSH_GENERATE_KEY}" != "no" ] && [ "${HERMES_SSH_GENERATE_KEY}" != "NO" ] && [ "${HERMES_SSH_GENERATE_KEY}" != "off" ] && [ "${HERMES_SSH_GENERATE_KEY}" != "OFF" ]; then
              if [ ! -f "${HERMES_SSH_KEY_PATH}" ]; then
                command -v ssh-keygen >/dev/null 2>&1 || { echo "ssh-keygen is required when HERMES_SSH_GENERATE_KEY=true" >&2; exit 1; }
                ssh-keygen -t "${HERMES_SSH_KEY_TYPE}" -N '' -C "hermes-agent@${HERMES_NAMESPACE}" -f "${HERMES_SSH_KEY_PATH}"
              fi
              chmod 600 "${HERMES_SSH_KEY_PATH}"
              [ ! -f "${HERMES_SSH_KEY_PATH}.pub" ] || chmod 644 "${HERMES_SSH_KEY_PATH}.pub"
            fi
            if [ -f "${HERMES_SSH_KEY_PATH}" ]; then
              ssh_config=/opt/data/.ssh/config
              ssh_config_tmp="$ssh_config.$$.tmp"
              touch "$ssh_config"
              sed '/^# BEGIN kube\.hermes_setup SSH identity$/,/^# END kube\.hermes_setup SSH identity$/d' "$ssh_config" |
                sed '/^# BEGIN kube\.hermes_setup system SSH config$/,/^# END kube\.hermes_setup system SSH config$/d' > "$ssh_config_tmp"
              {
                printf '%s\n' '# BEGIN kube.hermes_setup SSH identity'
                printf '%s\n' 'Host *'
                printf '%s\n' '    IdentityFile ${HERMES_SSH_KEY_PATH}'
                printf '%s\n' '    IdentitiesOnly yes'
                printf '%s\n' '# END kube.hermes_setup SSH identity'
                cat "$ssh_config_tmp"
                printf '%s\n' '# BEGIN kube.hermes_setup system SSH config'
                printf '%s\n' 'Host *'
                printf '%s\n' '    Include /etc/ssh/ssh_config'
                printf '%s\n' '# END kube.hermes_setup system SSH config'
              } > "$ssh_config"
              rm -f "$ssh_config_tmp"
              chmod 600 "$ssh_config"
              mkdir -p /opt/data/hermes-managed/bin
              {
                printf '%s\n' '#!/bin/sh'
                printf '%s\n' '# Managed by kube.hermes_setup; use the persistent runtime SSH config.'
                printf '%s\n' 'ssh_binary="$(PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin command -v ssh)" || exit 127'
                printf '%s\n' 'exec "$ssh_binary" -F /opt/data/.ssh/config "$@"'
              } > /opt/data/hermes-managed/bin/ssh
              chmod 755 /opt/data/hermes-managed/bin/ssh
            fi
          else
            rm -f /opt/data/hermes-managed/bin/ssh
          fi
          mkdir -p /opt/data/.npm
          installer_default_soul() {
            printf '%s\n' 'You are Hermes Agent, an intelligent AI assistant. Be helpful, direct, technically precise, and security-conscious.'
            printf '%s\n' ''
            printf '%s\n' '## Browser usage policy'
            printf '%s\n' 'A real Chromium browser is available through Hermes browser tools via the `BROWSER_CDP_URL` environment variable. Use browser tools for real UI/web verification, especially WebUI issues, JavaScript-rendered pages, login flows, Ingress checks, screenshots, browser console errors, and reproducing frontend problems. Use curl for HTTP status/headers/health endpoints, but do not rely only on curl for UI problems. Never print the full `BROWSER_CDP_URL`; it contains a token.'
          }
          write_installer_default_soul() {
            installer_default_soul > "$1"
          }
          bootstrap_soul_is_generic() {
            soul="$1"
            [ -f "$soul" ] && [ ! -L "$soul" ] || return 1
            [ "$(stat -c '%h' "$soul")" = "1" ] || return 1
            soul_content="$(cat "$soul")" || return 1
            if [ "$soul_content" = 'You are Hermes Agent, an intelligent AI assistant created by Nous Research. You are helpful, knowledgeable, and direct. You assist users with a wide range of tasks including answering questions, writing and editing code, analyzing information, creative work, and executing actions via your tools. You communicate clearly, admit uncertainty when appropriate, and prioritize being genuinely useful over being verbose unless otherwise directed below. Be targeted and efficient in your exploration and investigations.' ]; then
              return 0
            fi
            [ "$soul_content" = "$(installer_default_soul)" ]
          }
          bootstrap_copy_missing() {
            src="$1"
            dest="$2"
            [ -e "$src" ] || return 0
            if [ -d "$src" ]; then
              mkdir -p "$dest"
              find "$src" -mindepth 1 -print | while IFS= read -r item; do
                rel="$(printf '%s\n' "$item" | sed "s#^$src/##")"
                target="$dest/$rel"
                if [ -d "$item" ]; then
                  mkdir -p "$target"
                elif [ ! -e "$target" ]; then
                  mkdir -p "$(dirname "$target")"
                  cp -a "$item" "$target"
                fi
              done
            elif [ ! -e "$dest" ]; then
              mkdir -p "$(dirname "$dest")"
              cp -a "$src" "$dest"
            fi
          }
          bootstrap_copy_overwrite() {
            src="$1"
            dest="$2"
            [ -e "$src" ] || return 0
            mkdir -p "$(dirname "$dest")"
            if [ -d "$src" ]; then
              mkdir -p "$dest"
              cp -a "$src"/. "$dest"/
            else
              cp -a "$src" "$dest"
            fi
          }
          if [ -f /bootstrap/bootstrap.tar.gz ]; then
            rm -rf /tmp/hermes-bootstrap
            mkdir -p /tmp/hermes-bootstrap
            tar -xzf /bootstrap/bootstrap.tar.gz -C /tmp/hermes-bootstrap
            if [ "${HERMES_BOOTSTRAP_MODE}" != "disabled" ]; then
              if [ "${HERMES_BOOTSTRAP_MODE}" = "overwrite" ]; then
                bootstrap_copy_overwrite /tmp/hermes-bootstrap/opt-data /opt/data
                bootstrap_copy_overwrite /tmp/hermes-bootstrap/workspace /workspace
              else
                # A stock Hermes/installer identity carries no operator intent and
                # must not block the explicitly selected bootstrap profile. Preserve
                # every other existing SOUL.md exactly in non-destructive mode.
                if [ -f /tmp/hermes-bootstrap/opt-data/SOUL.md ] && [ ! -L /tmp/hermes-bootstrap/opt-data/SOUL.md ] && bootstrap_soul_is_generic /opt/data/SOUL.md; then
                  cp -a /tmp/hermes-bootstrap/opt-data/SOUL.md /opt/data/SOUL.md
                fi
                bootstrap_copy_missing /tmp/hermes-bootstrap/opt-data /opt/data
                bootstrap_copy_missing /tmp/hermes-bootstrap/workspace /workspace
              fi
            fi
            if [ -f /tmp/hermes-bootstrap/addons/requirements.txt ]; then
              mkdir -p "$HERMES_UV_DIR/bin" "$UV_PYTHON_INSTALL_DIR" "$UV_CACHE_DIR" /opt/data/.local/bin
              if [ ! -x "$HERMES_UV_DIR/bin/uv" ]; then
                command -v curl >/dev/null 2>&1 || { echo "curl is required to install uv" >&2; exit 1; }
                command -v sha256sum >/dev/null 2>&1 || { echo "sha256sum is required to verify uv" >&2; exit 1; }
                UV_INSTALLER_URL="https://github.com/astral-sh/uv/releases/download/0.11.32/uv-installer.sh"
                UV_INSTALLER_SHA256="43aff33a967fe40e8c17949d8c85c65bc43f3b5c94742393c957f56ab5ba80f4"
                UV_INSTALLER_PATH="/tmp/hermes-uv-installer.sh"
                curl -fsSL "$UV_INSTALLER_URL" -o "$UV_INSTALLER_PATH"
                printf '%s  %s\n' "$UV_INSTALLER_SHA256" "$UV_INSTALLER_PATH" | sha256sum -c -
                UV_INSTALL_DIR="$HERMES_UV_DIR/bin" sh "$UV_INSTALLER_PATH"
                rm -f "$UV_INSTALLER_PATH"
              fi
              export PATH="$HERMES_UV_DIR/bin:$PATH"
              uv --version
              uv python install "$HERMES_ADDON_PYTHON_VERSION"
              if [ ! -x "$HERMES_ADDON_VENV/bin/python" ] || [ ! -f "$HERMES_ADDON_VENV/.hermes-uv-managed" ]; then
                rm -rf "$HERMES_ADDON_VENV"
                uv venv --seed --python "$HERMES_ADDON_PYTHON_VERSION" "$HERMES_ADDON_VENV"
                touch "$HERMES_ADDON_VENV/.hermes-uv-managed"
              fi
              "$HERMES_ADDON_VENV/bin/python" -m pip install --upgrade pip
              uv pip install --python "$HERMES_ADDON_VENV/bin/python" -r /tmp/hermes-bootstrap/addons/requirements.txt
              if [ "${HERMES_PROFILE_REQUIREMENTS_SELECTED}" = "true" ] && [ "${HERMES_ANSIBLE_SETUP}" = "false" ]; then
                uv pip uninstall --python "$HERMES_ADDON_VENV/bin/python" ansible ansible-core
              fi
            fi
            rm -rf /tmp/hermes-bootstrap
          fi
          # Hermes' local terminal backend captures a login-shell snapshot.
          # Debian's /etc/profile resets PATH, so restore the PVC-backed addon
          # runtime afterwards through a small installer-managed profile hook.
          # Keep the hook separate from .profile so existing operator content
          # is preserved and the managed values remain idempotent.
          mkdir -p /opt/data/home
          {
            printf '%s\n' '# Managed by kube.hermes_setup; do not put secrets in this file.'
            printf '%s\n' 'export PATH="/opt/data/hermes-managed/bin:${HERMES_ADDON_VENV}/bin:${HERMES_UV_DIR}/bin:/opt/data/node/bin:/opt/data/node_modules/.bin:/opt/data/.local/bin:$PATH"'
            printf '%s\n' 'export npm_config_yes=true'
            printf '%s\n' 'export LANG="C.UTF-8"'
            printf '%s\n' 'export LC_ALL="C.UTF-8"'
            if [ -n "${HERMES_ANSIBLE_CONFIG}" ]; then
              printf '%s\n' 'export ANSIBLE_CONFIG="${HERMES_ANSIBLE_CONFIG}"'
            fi
          } > /opt/data/home/.hermes-terminal-env
          chmod 600 /opt/data/home/.hermes-terminal-env
          update_terminal_profile() {
            profile="$1"
            tmp_profile="$profile.$$.tmp"
            touch "$profile"
            sed '/^# BEGIN kube.hermes_setup terminal environment$/,/^# END kube.hermes_setup terminal environment$/d' "$profile" > "$tmp_profile"
            cat "$tmp_profile" > "$profile"
            rm -f "$tmp_profile"
          }
          # Remove the block written by releases before the subprocess HOME
          # contract was accounted for; preserve all operator-managed content.
          update_terminal_profile /opt/data/.profile
          update_terminal_profile /opt/data/home/.profile
          {
            printf '%s\n' ''
            printf '%s\n' '# BEGIN kube.hermes_setup terminal environment'
            printf '%s\n' '[ ! -r /opt/data/home/.hermes-terminal-env ] || . /opt/data/home/.hermes-terminal-env'
            printf '%s\n' '# END kube.hermes_setup terminal environment'
          } >> /opt/data/home/.profile
          chmod 600 /opt/data/.profile /opt/data/home/.profile
          write_default_config() {
            {
              printf '%s\n' 'provider: ${MODEL_PROVIDER}'
              printf '%s\n' 'model: ${MODEL_NAME}'
              printf '%s\n' 'agent:'
              printf '%s\n' '  verify_on_stop: false'
              printf '%s\n' 'terminal:'
              printf '%s\n' '  cwd: /workspace'
              printf '%s\n' 'display:'
              printf '%s\n' '  tool_progress: all'
              printf '%s\n' 'gateway:'
              printf '%s\n' '  host: 0.0.0.0'
              printf '%s\n' '  port: 8642'
            } > /opt/data/config.yaml
          }
          if [ ! -f /opt/data/config.yaml ]; then
            write_default_config
          elif grep -q 'anthropic/claude-opus-4.6' /opt/data/config.yaml 2>/dev/null && grep -q 'provider: auto' /opt/data/config.yaml 2>/dev/null; then
            # Some Agent images seed /opt/data/config.yaml before this init script runs.
            # Replace only that untouched image default; preserve any operator-managed config.
            cp /opt/data/config.yaml "/opt/data/config.yaml.image-default-$(date -u +%Y%m%dT%H%M%SZ).bak"
            write_default_config
          fi
          touch /opt/data/.env
          upsert_runtime_env() {
            env_name="$1"
            env_value="$2"
            tmp_env="$(mktemp /opt/data/.env.XXXXXX)"
            trap 'rm -f "$tmp_env"' 0 1 2 15
            found=false
            while IFS= read -r line || [ -n "$line" ]; do
              case "$line" in
                "$env_name"=*)
                  if [ "$found" = false ]; then
                    printf '%s=%s\n' "$env_name" "$env_value"
                    found=true
                  fi
                  ;;
                *) printf '%s\n' "$line" ;;
              esac
            done < /opt/data/.env > "$tmp_env"
            if [ "$found" = false ]; then
              printf '%s=%s\n' "$env_name" "$env_value" >> "$tmp_env"
            fi
            chmod 600 "$tmp_env"
            chown ${HERMES_RUNTIME_UID}:${HERMES_RUNTIME_GID} "$tmp_env"
            mv -f "$tmp_env" /opt/data/.env
            trap - 0 1 2 15
          }
          upsert_runtime_env API_SERVER_KEY "$API_SERVER_KEY"
          upsert_runtime_env BROWSER_CDP_URL "$BROWSER_CDP_URL"
          sync_profile_runtime_env() {
            env_name="$1"
            env_value="$2"
            profiles_root=/opt/data/profiles
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
            [ -d "$profiles_root" ] || return 0
            for profile_dir in "$profiles_root"/*; do
              [ -d "$profile_dir" ] || continue
              env_file="$profile_dir/.env"
              [ -f "$env_file" ] || continue
              grep -q "^$env_name=" "$env_file" || continue
              tmp_env="$(mktemp "$env_file.XXXXXX")"
              trap 'rm -f "$tmp_env"' 0 1 2 15
              found=false
              while IFS= read -r line || [ -n "$line" ]; do
                case "$line" in
                  "$env_name"=*)
                    if [ "$found" = false ]; then
                      printf '%s=%s\n' "$env_name" "$env_value"
                      found=true
                    fi
                    ;;
                  *) printf '%s\n' "$line" ;;
                esac
              done < "$env_file" > "$tmp_env"
              chmod 600 "$tmp_env"
              chown ${HERMES_RUNTIME_UID}:${HERMES_RUNTIME_GID} "$tmp_env"
              mv -f "$tmp_env" "$env_file"
              trap - 0 1 2 15
            done
          }
          if [ -n "$BROWSER_CDP_URL" ]; then
            sync_profile_runtime_env BROWSER_CDP_URL "$BROWSER_CDP_URL"
          fi
          chmod 600 /opt/data/.env
          if [ ! -f /opt/data/SOUL.md ]; then
            write_installer_default_soul /opt/data/SOUL.md
          fi
          if [ "${HERMES_ANSIBLE_SETUP}" = "true" ] || [ "${HERMES_ANSIBLE_SETUP}" = "TRUE" ] || [ "${HERMES_ANSIBLE_SETUP}" = "1" ] || [ "${HERMES_ANSIBLE_SETUP}" = "yes" ] || [ "${HERMES_ANSIBLE_SETUP}" = "YES" ] || [ "${HERMES_ANSIBLE_SETUP}" = "on" ] || [ "${HERMES_ANSIBLE_SETUP}" = "ON" ]; then
            mkdir -p /workspace/ansible/collections /workspace/ansible/group_vars /workspace/ansible/host_vars /workspace/ansible/inventory /workspace/ansible/playbooks /workspace/ansible/roles /opt/data/ansible/cp /opt/data/ansible/tmp
          if [ ! -f /workspace/ansible/ansible.cfg ]; then
            {
              printf '%s\n' '[defaults]'
              printf '%s\n' 'inventory = /workspace/ansible/inventory/hosts.ini'
              printf '%s\n' 'roles_path = /workspace/ansible/roles:/opt/data/ansible/roles'
              printf '%s\n' 'collections_path = /workspace/ansible/collections:/opt/data/ansible/collections'
              printf '%s\n' 'local_tmp = /opt/data/ansible/tmp'
              printf '%s\n' 'remote_tmp = /opt/data/ansible/tmp'
              printf '%s\n' 'host_key_checking = True'
              printf '%s\n' 'retry_files_enabled = False'
              printf '%s\n' 'stdout_callback = default'
              printf '%s\n' 'interpreter_python = auto_silent'
              printf '%s\n' ''
              printf '%s\n' '[ssh_connection]'
              printf '%s\n' 'ssh_args = -F /opt/data/.ssh/config -o ControlMaster=auto -o ControlPersist=60s'
              printf '%s\n' 'control_path_dir = /opt/data/ansible/cp'
              printf '%s\n' 'pipelining = True'
            } > /workspace/ansible/ansible.cfg
          fi
          if [ ! -f /workspace/ansible/inventory/hosts.ini ]; then
            {
              printf '%s\n' '# Safe default inventory. Replace with your own hosts.'
              printf '%s\n' '[local]'
              printf '%s\n' 'localhost ansible_connection=local'
            } > /workspace/ansible/inventory/hosts.ini
          fi
          # Migrate only the exact legacy installer default. A root kubectl
          # exec could otherwise create /tmp/.ansible-hermes mode 0700 and
          # block the unprivileged WebUI runtime user.
          if grep -qx 'remote_tmp = /tmp/.ansible-hermes' /workspace/ansible/ansible.cfg 2>/dev/null; then
            sed 's#^remote_tmp = /tmp/.ansible-hermes$#remote_tmp = /opt/data/ansible/tmp#' /workspace/ansible/ansible.cfg > /workspace/ansible/ansible.cfg.$$.tmp
            cat /workspace/ansible/ansible.cfg.$$.tmp > /workspace/ansible/ansible.cfg
            rm -f /workspace/ansible/ansible.cfg.$$.tmp
          fi
          fi
          chown -R ${HERMES_RUNTIME_UID}:${HERMES_RUNTIME_GID} /opt/data /workspace
          chmod 700 /opt/data
          [ ! -d /opt/data/.ssh ] || chmod 700 /opt/data/.ssh
          [ ! -f /opt/data/.ssh/known_hosts ] || chmod 644 /opt/data/.ssh/known_hosts
          find /opt/data/.ssh -type f -name 'id_*' ! -name '*.pub' -exec chmod 600 {} + 2>/dev/null || true
          find /opt/data/.ssh -type f -name 'id_*.pub' -exec chmod 644 {} + 2>/dev/null || true
          [ ! -f /opt/data/.ssh/config ] || chmod 600 /opt/data/.ssh/config
          [ ! -f /opt/data/hermes-managed/bin/ssh ] || chmod 755 /opt/data/hermes-managed/bin/ssh
        volumeMounts:
        - name: home
          mountPath: /opt/data
        - name: workspace
          mountPath: /workspace
        - name: bootstrap
          mountPath: /bootstrap
          readOnly: true
      volumes:
      - name: bootstrap
        secret:
          secretName: hermes-bootstrap-archive
          optional: true
      - name: home
        persistentVolumeClaim:
          claimName: hermes-home
      - name: workspace
        persistentVolumeClaim:
          claimName: hermes-workspace
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hermes-agent
  namespace: ${HERMES_NAMESPACE}
spec:
  replicas: 1
  revisionHistoryLimit: 3
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: hermes-agent
  template:
    metadata:
      annotations:
        kube-hermes-setup.example.com/api-key-revision: "${API_SERVER_KEY_REVISION}"
      labels:
        app: hermes-agent
    spec:
      automountServiceAccountToken: false
      securityContext:
        fsGroup: ${HERMES_RUNTIME_GID}
        fsGroupChangePolicy: Always
        seccompProfile:
          type: RuntimeDefault
      initContainers:
      - name: prepare-permissions
        image: busybox:1.36
        command: ["sh", "-c"]
        args:
        - |
          set -eu
          mkdir -p /opt/data /workspace
          if [ -n "${HERMES_ANSIBLE_CONFIG}" ]; then
            mkdir -p /workspace/ansible/collections /workspace/ansible/group_vars /workspace/ansible/host_vars /workspace/ansible/inventory /workspace/ansible/playbooks /workspace/ansible/roles /opt/data/ansible/cp /opt/data/ansible/tmp
          fi
          chown -R ${HERMES_RUNTIME_UID}:${HERMES_RUNTIME_GID} /opt/data /workspace
          chmod 700 /opt/data
          [ ! -d /opt/data/.ssh ] || chmod 700 /opt/data/.ssh
          [ ! -f /opt/data/.ssh/known_hosts ] || chmod 644 /opt/data/.ssh/known_hosts
          find /opt/data/.ssh -type f -name 'id_*' ! -name '*.pub' -exec chmod 600 {} + 2>/dev/null || true
          find /opt/data/.ssh -type f -name 'id_*.pub' -exec chmod 644 {} + 2>/dev/null || true
          [ ! -f /opt/data/.ssh/config ] || chmod 600 /opt/data/.ssh/config
          [ ! -f /opt/data/hermes-managed/bin/ssh ] || chmod 755 /opt/data/hermes-managed/bin/ssh
        volumeMounts:
        - name: home
          mountPath: /opt/data
        - name: workspace
          mountPath: /workspace
      containers:
      - name: hermes-agent
        image: ${HERMES_AGENT_IMAGE}
        imagePullPolicy: ${HERMES_IMAGE_PULL_POLICY}
        securityContext:
          allowPrivilegeEscalation: false
        command: ["/init", "/opt/hermes/docker/main-wrapper.sh"]
        args: ["gateway", "run"]
        ports:
        - name: api
          containerPort: 8642
        env:
        - name: HERMES_HOME
          value: /opt/data
        - name: HOME
          value: /opt/data
        - name: CODEX_HOME
          value: /opt/data
        - name: XDG_CONFIG_HOME
          value: /opt/data/.config
        - name: XDG_CACHE_HOME
          value: /opt/data/.cache
        - name: LANG
          value: C.UTF-8
        - name: LC_ALL
          value: C.UTF-8
        - name: HERMES_WRITE_SAFE_ROOT
          value: /opt/data:/workspace
        - name: HERMES_ADDON_PYTHON_MODE
          value: "${HERMES_ADDON_PYTHON_MODE}"
        - name: npm_config_yes
          value: "true"
        - name: HERMES_UV_DIR
          value: "${HERMES_UV_DIR}"
        - name: HERMES_ADDON_VENV
          value: "${HERMES_ADDON_VENV}"
        - name: HERMES_ADDON_PYTHON_VERSION
          value: "${HERMES_ADDON_PYTHON_VERSION}"
        - name: UV_PYTHON_INSTALL_DIR
          value: "${HERMES_UV_DIR}/python"
        - name: UV_CACHE_DIR
          value: /opt/data/.cache/uv
        - name: ANSIBLE_CONFIG
          value: "${HERMES_ANSIBLE_CONFIG}"
        - name: PATH
          value: /opt/data/hermes-managed/bin:/opt/hermes/bin:/opt/hermes/.venv/bin:${HERMES_ADDON_VENV}/bin:${HERMES_UV_DIR}/bin:/opt/data/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
        - name: API_SERVER_ENABLED
          value: "true"
        - name: API_SERVER_HOST
          value: 0.0.0.0
        - name: API_SERVER_PORT
          value: "8642"
        - name: API_SERVER_KEY
          valueFrom:
            secretKeyRef:
              name: hermes-api-server
              key: api-key
        - name: BROWSER_CDP_URL
          valueFrom:
            secretKeyRef:
              name: hermes-browser-cdp
              key: BROWSER_CDP_URL
        volumeMounts:
        - name: home
          mountPath: /opt/data
        - name: workspace
          mountPath: /workspace
        startupProbe:
          httpGet:
            path: /health
            port: api
          periodSeconds: 5
          failureThreshold: 36
        readinessProbe:
          httpGet:
            path: /health
            port: api
          initialDelaySeconds: 0
          periodSeconds: 10
          failureThreshold: 18
        livenessProbe:
          httpGet:
            path: /health
            port: api
          initialDelaySeconds: 0
          periodSeconds: 20
          failureThreshold: 6
        resources:
          requests:
            cpu: ${HERMES_AGENT_CPU_REQUEST}
            memory: ${HERMES_AGENT_MEMORY_REQUEST}
          limits:
            cpu: "${HERMES_AGENT_CPU_LIMIT}"
            memory: ${HERMES_AGENT_MEMORY_LIMIT}
      volumes:
      - name: home
        persistentVolumeClaim:
          claimName: hermes-home
      - name: workspace
        persistentVolumeClaim:
          claimName: hermes-workspace
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hermes-dashboard
  namespace: ${HERMES_NAMESPACE}
spec:
  replicas: 1
  revisionHistoryLimit: 3
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: hermes-dashboard
  template:
    metadata:
      annotations:
        kube-hermes-setup.example.com/api-key-revision: "${API_SERVER_KEY_REVISION}"
      labels:
        app: hermes-dashboard
    spec:
      automountServiceAccountToken: false
      securityContext:
        fsGroup: ${HERMES_RUNTIME_GID}
        fsGroupChangePolicy: Always
        seccompProfile:
          type: RuntimeDefault
      initContainers:
      - name: prepare-permissions
        image: busybox:1.36
        command: ["sh", "-c"]
        args:
        - |
          set -eu
          mkdir -p /opt/data /workspace
          if [ -n "${HERMES_ANSIBLE_CONFIG}" ]; then
            mkdir -p /workspace/ansible/collections /workspace/ansible/group_vars /workspace/ansible/host_vars /workspace/ansible/inventory /workspace/ansible/playbooks /workspace/ansible/roles /opt/data/ansible/cp /opt/data/ansible/tmp
          fi
          chown -R ${HERMES_RUNTIME_UID}:${HERMES_RUNTIME_GID} /opt/data /workspace
          chmod 700 /opt/data
          [ ! -d /opt/data/.ssh ] || chmod 700 /opt/data/.ssh
          [ ! -f /opt/data/.ssh/known_hosts ] || chmod 644 /opt/data/.ssh/known_hosts
          find /opt/data/.ssh -type f -name 'id_*' ! -name '*.pub' -exec chmod 600 {} + 2>/dev/null || true
          find /opt/data/.ssh -type f -name 'id_*.pub' -exec chmod 644 {} + 2>/dev/null || true
          [ ! -f /opt/data/.ssh/config ] || chmod 600 /opt/data/.ssh/config
          [ ! -f /opt/data/hermes-managed/bin/ssh ] || chmod 755 /opt/data/hermes-managed/bin/ssh
        volumeMounts:
        - name: home
          mountPath: /opt/data
        - name: workspace
          mountPath: /workspace
      containers:
      - name: hermes-dashboard
        image: ${HERMES_AGENT_IMAGE}
        imagePullPolicy: ${HERMES_IMAGE_PULL_POLICY}
        securityContext:
          allowPrivilegeEscalation: false
        command: ["/init", "/opt/hermes/docker/main-wrapper.sh"]
        args: ["dashboard", "--host", "0.0.0.0", "--port", "9119", "--no-open"]
        ports:
        - name: dashboard
          containerPort: 9119
        env:
        - name: HERMES_HOME
          value: /opt/data
        - name: HOME
          value: /opt/data
        - name: CODEX_HOME
          value: /opt/data
        - name: XDG_CONFIG_HOME
          value: /opt/data/.config
        - name: XDG_CACHE_HOME
          value: /opt/data/.cache
        - name: LANG
          value: C.UTF-8
        - name: LC_ALL
          value: C.UTF-8
        - name: HERMES_WRITE_SAFE_ROOT
          value: /opt/data:/workspace
        - name: HERMES_DASHBOARD_FILES_ROOT
          value: /workspace
        - name: HERMES_ADDON_PYTHON_MODE
          value: "${HERMES_ADDON_PYTHON_MODE}"
        - name: HERMES_UV_DIR
          value: "${HERMES_UV_DIR}"
        - name: HERMES_ADDON_VENV
          value: "${HERMES_ADDON_VENV}"
        - name: HERMES_ADDON_PYTHON_VERSION
          value: "${HERMES_ADDON_PYTHON_VERSION}"
        - name: UV_PYTHON_INSTALL_DIR
          value: "${HERMES_UV_DIR}/python"
        - name: UV_CACHE_DIR
          value: /opt/data/.cache/uv
        - name: ANSIBLE_CONFIG
          value: "${HERMES_ANSIBLE_CONFIG}"
        - name: PATH
          value: /opt/data/hermes-managed/bin:/opt/hermes/bin:/opt/hermes/.venv/bin:${HERMES_ADDON_VENV}/bin:${HERMES_UV_DIR}/bin:/opt/data/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
        # HERMES_AUTH_LOCAL_ONLY_START
        - name: HERMES_DASHBOARD_BASIC_AUTH_USERNAME
          valueFrom:
            secretKeyRef:
              name: hermes-dashboard-auth
              key: username
        - name: HERMES_DASHBOARD_BASIC_AUTH_PASSWORD
          valueFrom:
            secretKeyRef:
              name: hermes-dashboard-auth
              key: password
        # HERMES_AUTH_LOCAL_ONLY_END
        # HERMES_AUTH_EXTERNAL_OIDC_START
        - name: HERMES_DASHBOARD_OIDC_ISSUER
          value: "${HERMES_DASHBOARD_OIDC_ISSUER}"
        - name: HERMES_DASHBOARD_OIDC_CLIENT_ID
          value: "${HERMES_DASHBOARD_OIDC_CLIENT_ID}"
        - name: HERMES_DASHBOARD_OIDC_SCOPES
          value: "${HERMES_DASHBOARD_OIDC_SCOPES}"
        - name: HERMES_DASHBOARD_PUBLIC_URL
          value: "${HERMES_DASHBOARD_PUBLIC_URL}"
        # HERMES_AUTH_EXTERNAL_OIDC_END
        - name: GATEWAY_HEALTH_URL
          value: http://hermes-agent:8642
        - name: API_SERVER_KEY
          valueFrom:
            secretKeyRef:
              name: hermes-api-server
              key: api-key
        - name: BROWSER_CDP_URL
          valueFrom:
            secretKeyRef:
              name: hermes-browser-cdp
              key: BROWSER_CDP_URL
        volumeMounts:
        - name: home
          mountPath: /opt/data
        - name: workspace
          mountPath: /workspace
        startupProbe:
          tcpSocket:
            port: dashboard
          periodSeconds: 5
          failureThreshold: 36
        readinessProbe:
          tcpSocket:
            port: dashboard
          initialDelaySeconds: 0
          periodSeconds: 10
          failureThreshold: 18
        livenessProbe:
          tcpSocket:
            port: dashboard
          initialDelaySeconds: 0
          periodSeconds: 20
          failureThreshold: 6
        resources:
          requests:
            cpu: ${HERMES_DASHBOARD_CPU_REQUEST}
            memory: ${HERMES_DASHBOARD_MEMORY_REQUEST}
          limits:
            cpu: "${HERMES_DASHBOARD_CPU_LIMIT}"
            memory: ${HERMES_DASHBOARD_MEMORY_LIMIT}
      volumes:
      - name: home
        persistentVolumeClaim:
          claimName: hermes-home
      - name: workspace
        persistentVolumeClaim:
          claimName: hermes-workspace
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hermes-webui
  namespace: ${HERMES_NAMESPACE}
spec:
  replicas: 1
  revisionHistoryLimit: 3
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: hermes-webui
  template:
    metadata:
      annotations:
        kube-hermes-setup.example.com/api-key-revision: "${API_SERVER_KEY_REVISION}"
      labels:
        app: hermes-webui
    spec:
      automountServiceAccountToken: false
      securityContext:
        fsGroup: ${HERMES_RUNTIME_GID}
        fsGroupChangePolicy: Always
        seccompProfile:
          type: RuntimeDefault
      initContainers:
      - name: prepare-webui-state
        image: busybox:1.36
        command: ["sh", "-c"]
        args:
        - |
          set -eu
          mkdir -p /opt/data/webui /workspace
          chown -R ${HERMES_RUNTIME_UID}:${HERMES_RUNTIME_GID} /opt/data /workspace
          chmod 700 /opt/data
          [ ! -d /opt/data/.ssh ] || chmod 700 /opt/data/.ssh
          [ ! -f /opt/data/.ssh/known_hosts ] || chmod 644 /opt/data/.ssh/known_hosts
          find /opt/data/.ssh -type f -name 'id_*' ! -name '*.pub' -exec chmod 600 {} + 2>/dev/null || true
          find /opt/data/.ssh -type f -name 'id_*.pub' -exec chmod 644 {} + 2>/dev/null || true
          [ ! -f /opt/data/.ssh/config ] || chmod 600 /opt/data/.ssh/config
          [ ! -f /opt/data/hermes-managed/bin/ssh ] || chmod 755 /opt/data/hermes-managed/bin/ssh
          chmod 700 /opt/data/webui
        volumeMounts:
        - name: home
          mountPath: /opt/data
        - name: workspace
          mountPath: /workspace
      - name: copy-agent-source
        image: ${HERMES_AGENT_IMAGE}
        imagePullPolicy: ${HERMES_IMAGE_PULL_POLICY}
        command: ["/bin/sh", "-c"]
        args:
        - >-
          set -eu;
          cp -a /opt/hermes/. /agent-src/;
          chown -R ${HERMES_RUNTIME_UID}:${HERMES_RUNTIME_GID} /agent-src;
          chmod -R go-w /agent-src
        volumeMounts:
        - name: hermes-agent-src
          mountPath: /agent-src
      - name: prepare-browser-cli
        image: ${HERMES_AGENT_IMAGE}
        imagePullPolicy: ${HERMES_IMAGE_PULL_POLICY}
        command: ["/bin/sh", "-c"]
        args:
        - |
          set -eu
          node_root=/opt/data/node
          node_source=/usr/local/bin/node
          npm_source=/usr/local/lib/node_modules/npm
          runtimes="$node_root/runtimes"
          repairs="$node_root/repairs"
          mkdir -p "$node_root/bin" "$runtimes" "$repairs"

          for required in "$node_source" "$npm_source/package.json" "$npm_source/bin/npm-cli.js" "$npm_source/bin/npx-cli.js"; do
            [ -f "$required" ] || { echo "managed Node runtime source missing: $required" >&2; exit 1; }
          done
          [ -x "$node_source" ] || { echo 'managed Node source is not executable' >&2; exit 1; }

          # Validate every source dependency before touching the active runtime.
          ldd_output="$(ldd "$node_source" 2>&1)" || {
            printf '%s\n' "$ldd_output" >&2
            echo 'unable to inspect managed Node runtime dependencies' >&2
            exit 1
          }
          if printf '%s\n' "$ldd_output" | grep -Eq 'libatomic[.]so[.]1[[:space:]]+=>[[:space:]]+not found'; then
            echo 'libatomic.so.1 required by the managed Node runtime is unresolved' >&2
            exit 1
          fi
          node_atomic_lib="$(printf '%s\n' "$ldd_output" | awk '$1 == "libatomic.so.1" && $3 ~ /^\// { print $3; exit }')"
          node_sha="$(sha256sum "$node_source" | cut -d' ' -f1)"
          npm_sha="$(tar -C "$npm_source" --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner -cf - . | sha256sum | cut -d' ' -f1)"
          atomic_sha=none
          if [ -n "$node_atomic_lib" ]; then
            [ -f "$node_atomic_lib" ] || { echo 'resolved libatomic.so.1 is not a file' >&2; exit 1; }
            atomic_sha="$(sha256sum "$node_atomic_lib" | cut -d' ' -f1)"
          fi
          base_runtime_key="$(printf '%s\n' "$node_sha" "$npm_sha" "$atomic_sha" | sha256sum | cut -d' ' -f1)"
          runtime_key="$base_runtime_key"
          valid_runtime_pointer() {
            pointer="$1"
            case "$pointer" in
              runtimes/*) key="$(printf '%s' "$pointer" | cut -c10-)" ;;
              *) return 1 ;;
            esac
            [ "$(printf '%s' "$key" | wc -c)" -eq 64 ] || return 1
            case "$key" in *[!0-9a-f]*) return 1 ;; esac
          }
          valid_hash() {
            value="$1"
            [ "$(printf '%s' "$value" | wc -c)" -eq 64 ] || return 1
            case "$value" in *[!0-9a-f]*) return 1 ;; esac
          }
          runtime_integrity_valid() {
            candidate="$1"
            [ -d "$candidate" ] && [ ! -L "$candidate" ] || return 1
            [ -f "$candidate/.complete" ] && [ ! -L "$candidate/.complete" ] || return 1
            metadata="$candidate/.metadata"
            [ -f "$metadata" ] && [ ! -L "$metadata" ] || return 1
            [ "$(grep -c '^node_sha=' "$metadata")" -eq 1 ] || return 1
            [ "$(grep -c '^npm_sha=' "$metadata")" -eq 1 ] || return 1
            [ "$(grep -c '^atomic_sha=' "$metadata")" -eq 1 ] || return 1
            [ "$(grep -c '^source_key=' "$metadata")" -eq 1 ] || return 1
            [ "$(grep -c '^payload_sha=' "$metadata")" -eq 1 ] || return 1
            stored_node_sha="$(sed -n 's/^node_sha=//p' "$metadata")"
            stored_npm_sha="$(sed -n 's/^npm_sha=//p' "$metadata")"
            stored_atomic_sha="$(sed -n 's/^atomic_sha=//p' "$metadata")"
            stored_source_key="$(sed -n 's/^source_key=//p' "$metadata")"
            stored_payload_sha="$(sed -n 's/^payload_sha=//p' "$metadata")"
            valid_hash "$stored_node_sha" || return 1
            valid_hash "$stored_npm_sha" || return 1
            valid_hash "$stored_source_key" || return 1
            valid_hash "$stored_payload_sha" || return 1
            [ "$stored_atomic_sha" = none ] || valid_hash "$stored_atomic_sha" || return 1
            [ -f "$candidate/libexec/node" ] && [ ! -L "$candidate/libexec/node" ] || return 1
            [ "$(sha256sum "$candidate/libexec/node" | cut -d' ' -f1)" = "$stored_node_sha" ] || return 1
            npm_candidate="$candidate/lib/node_modules/npm"
            [ -d "$npm_candidate" ] && [ ! -L "$npm_candidate" ] || return 1
            for npm_file in package.json bin/npm-cli.js bin/npx-cli.js; do
              [ -f "$npm_candidate/$npm_file" ] && [ ! -L "$npm_candidate/$npm_file" ] || return 1
            done
            candidate_npm_sha="$(tar -C "$npm_candidate" --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner -cf - . | sha256sum | cut -d' ' -f1)"
            [ "$candidate_npm_sha" = "$stored_npm_sha" ] || return 1
            if [ "$stored_atomic_sha" = none ]; then
              [ ! -e "$candidate/lib/libatomic.so.1" ] && [ ! -L "$candidate/lib/libatomic.so.1" ] || return 1
            else
              [ -f "$candidate/lib/libatomic.so.1" ] && [ ! -L "$candidate/lib/libatomic.so.1" ] || return 1
              [ "$(sha256sum "$candidate/lib/libatomic.so.1" | cut -d' ' -f1)" = "$stored_atomic_sha" ] || return 1
            fi
            candidate_payload_sha="$(tar -C "$candidate" --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner --mode=0777 -cf - libexec lib | sha256sum | cut -d' ' -f1)"
            [ "$candidate_payload_sha" = "$stored_payload_sha" ] || return 1
          }
          runtime_matches_source() {
            runtime_integrity_valid "$1" || return 1
            [ "$stored_node_sha" = "$node_sha" ] || return 1
            [ "$stored_npm_sha" = "$npm_sha" ] || return 1
            [ "$stored_atomic_sha" = "$atomic_sha" ] || return 1
            [ "$stored_source_key" = "$base_runtime_key" ] || return 1
          }

          repair_map="$repairs/$base_runtime_key"
          if [ -f "$repair_map" ] && [ ! -L "$repair_map" ]; then
            mapped_runtime_key="$(cat "$repair_map")"
            if valid_hash "$mapped_runtime_key" && { [ -e "$runtimes/$mapped_runtime_key" ] || [ -L "$runtimes/$mapped_runtime_key" ]; }; then
              runtime_key="$mapped_runtime_key"
            else
              rm -f -- "$repair_map"
            fi
          elif [ -e "$repair_map" ] || [ -L "$repair_map" ]; then
            rm -f -- "$repair_map"
          fi

          repair_round=0
          runtime="$runtimes/$runtime_key"
          while [ -e "$runtime" ] || [ -L "$runtime" ]; do
            runtime_matches_source "$runtime" && break
            repair_round=$((repair_round + 1))
            [ "$repair_round" -le 8 ] || { echo 'too many corrupt managed Node runtimes' >&2; exit 1; }
            corrupt_sha="$(tar -C "$runtimes" --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner -cf - "$(basename "$runtime")" | sha256sum | cut -d' ' -f1)"
            runtime_key="$(printf '%s\n' "$base_runtime_key" "$runtime_key" "$corrupt_sha" | sha256sum | cut -d' ' -f1)"
            runtime="$runtimes/$runtime_key"
          done
          runtime_stage="$runtimes/.$runtime_key.$$"

          if [ ! -d "$runtime" ]; then
            rm -rf -- "$runtime_stage"
            trap 'rm -rf -- "$runtime_stage"' 0 1 2 15
            mkdir -p "$runtime_stage/libexec" "$runtime_stage/lib/node_modules"
            cp "$node_source" "$runtime_stage/libexec/node"
            chmod 755 "$runtime_stage/libexec/node"
            if [ -n "$node_atomic_lib" ]; then
              cp -pL "$node_atomic_lib" "$runtime_stage/lib/libatomic.so.1"
              chmod 644 "$runtime_stage/lib/libatomic.so.1"
            fi
            cp -a "$npm_source" "$runtime_stage/lib/node_modules/npm"
            payload_sha="$(tar -C "$runtime_stage" --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner --mode=0777 -cf - libexec lib | sha256sum | cut -d' ' -f1)"
            cat > "$runtime_stage/.metadata" <<RUNTIME_METADATA
          node_sha=$node_sha
          npm_sha=$npm_sha
          atomic_sha=$atomic_sha
          source_key=$base_runtime_key
          payload_sha=$payload_sha
          RUNTIME_METADATA
            chmod 644 "$runtime_stage/.metadata"
            [ -f "$runtime_stage/lib/node_modules/npm/bin/npm-cli.js" ] || { echo 'staged npm CLI is missing' >&2; exit 1; }
            [ -f "$runtime_stage/lib/node_modules/npm/bin/npx-cli.js" ] || { echo 'staged npx CLI is missing' >&2; exit 1; }
            LD_LIBRARY_PATH="$runtime_stage/lib" "$runtime_stage/libexec/node" --version >/dev/null
            LD_LIBRARY_PATH="$runtime_stage/lib" "$runtime_stage/libexec/node" "$runtime_stage/lib/node_modules/npm/bin/npm-cli.js" --version >/dev/null
            LD_LIBRARY_PATH="$runtime_stage/lib" "$runtime_stage/libexec/node" "$runtime_stage/lib/node_modules/npm/bin/npx-cli.js" --version >/dev/null
            printf '%s\n' complete > "$runtime_stage/.complete"
            mv -T "$runtime_stage" "$runtime"
            trap - 0 1 2 15
          fi

          runtime_matches_source "$runtime" || { echo 'managed Node runtime validation failed' >&2; exit 1; }
          chmod 755 "$runtime/libexec/node"
          LD_LIBRARY_PATH="$runtime/lib" "$runtime/libexec/node" --version >/dev/null
          LD_LIBRARY_PATH="$runtime/lib" "$runtime/libexec/node" "$runtime/lib/node_modules/npm/bin/npm-cli.js" --version >/dev/null
          LD_LIBRARY_PATH="$runtime/lib" "$runtime/libexec/node" "$runtime/lib/node_modules/npm/bin/npx-cli.js" --version >/dev/null
          if [ "$runtime_key" != "$base_runtime_key" ]; then
            repair_map_tmp="$repairs/.$base_runtime_key.$$"
            printf '%s\n' "$runtime_key" > "$repair_map_tmp"
            chmod 644 "$repair_map_tmp"
            mv -fT "$repair_map_tmp" "$repair_map"
          else
            rm -f -- "$repair_map"
          fi

          # Prepare stable wrappers before activating the complete runtime.
          node_launcher_tmp="$node_root/bin/.node.$$"
          cat > "$node_launcher_tmp" <<'NODE_LAUNCHER'
          #!/bin/sh
          set -eu
          node_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
          runtime="$(readlink -f "$node_root/current")"
          case "$runtime" in "$node_root"/runtimes/*) ;; *) echo 'invalid managed Node runtime' >&2; exit 1 ;; esac
          [ -f "$runtime/.complete" ] || { echo 'incomplete managed Node runtime' >&2; exit 1; }
          private_lib="$runtime/lib"
          current="$(printenv LD_LIBRARY_PATH 2>/dev/null || true)"
          case ":$current:" in
            *":$private_lib:"*) ;;
            *) if [ -n "$current" ]; then current="$private_lib:$current"; else current="$private_lib"; fi ;;
          esac
          exec env LD_LIBRARY_PATH="$current" "$runtime/libexec/node" "$@"
          NODE_LAUNCHER

          npm_launcher_tmp="$node_root/bin/.npm.$$"
          cat > "$npm_launcher_tmp" <<'NPM_LAUNCHER'
          #!/bin/sh
          set -eu
          node_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
          runtime="$(readlink -f "$node_root/current")"
          case "$runtime" in "$node_root"/runtimes/*) ;; *) echo 'invalid managed Node runtime' >&2; exit 1 ;; esac
          [ -f "$runtime/.complete" ] || { echo 'incomplete managed Node runtime' >&2; exit 1; }
          private_lib="$runtime/lib"
          current="$(printenv LD_LIBRARY_PATH 2>/dev/null || true)"
          case ":$current:" in
            *":$private_lib:"*) ;;
            *) if [ -n "$current" ]; then current="$private_lib:$current"; else current="$private_lib"; fi ;;
          esac
          exec env LD_LIBRARY_PATH="$current" "$runtime/libexec/node" "$runtime/lib/node_modules/npm/bin/npm-cli.js" "$@"
          NPM_LAUNCHER

          npx_launcher_tmp="$node_root/bin/.npx.$$"
          cat > "$npx_launcher_tmp" <<'NPX_LAUNCHER'
          #!/bin/sh
          set -eu
          node_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
          runtime="$(readlink -f "$node_root/current")"
          case "$runtime" in "$node_root"/runtimes/*) ;; *) echo 'invalid managed Node runtime' >&2; exit 1 ;; esac
          [ -f "$runtime/.complete" ] || { echo 'incomplete managed Node runtime' >&2; exit 1; }
          private_lib="$runtime/lib"
          current="$(printenv LD_LIBRARY_PATH 2>/dev/null || true)"
          case ":$current:" in
            *":$private_lib:"*) ;;
            *) if [ -n "$current" ]; then current="$private_lib:$current"; else current="$private_lib"; fi ;;
          esac
          exec env LD_LIBRARY_PATH="$current" "$runtime/libexec/node" "$runtime/lib/node_modules/npm/bin/npx-cli.js" "$@"
          NPX_LAUNCHER
          chmod 755 "$node_launcher_tmp" "$npm_launcher_tmp" "$npx_launcher_tmp"

          current_tmp="$node_root/.current.$$"
          ln -s "runtimes/$runtime_key" "$current_tmp"
          old_current="$(readlink "$node_root/current" 2>/dev/null || true)"
          old_current_valid=false
          case "$old_current" in
            '') ;;
            runtimes/*)
              if valid_runtime_pointer "$old_current"; then
                runtime_integrity_valid "$node_root/$old_current" && old_current_valid=true
              else
                old_current=''
              fi
              ;;
            *) old_current='' ;;
          esac
          mv -fT "$current_tmp" "$node_root/current"
          if [ "$old_current_valid" = true ] && [ "$old_current" != "runtimes/$runtime_key" ]; then
            previous_tmp="$node_root/.previous.$$"
            ln -s "$old_current" "$previous_tmp"
            mv -fT "$previous_tmp" "$node_root/previous"
          fi
          mv -fT "$npm_launcher_tmp" "$node_root/bin/npm"
          mv -fT "$npx_launcher_tmp" "$node_root/bin/npx"
          mv -fT "$node_launcher_tmp" "$node_root/bin/node"

          current_runtime="$(readlink "$node_root/current")"
          previous_runtime="$(readlink "$node_root/previous" 2>/dev/null || true)"
          for candidate in "$runtimes"/[0-9a-f]*; do
            [ -d "$candidate" ] || continue
            relative="runtimes/$(basename "$candidate")"
            valid_runtime_pointer "$relative" || { echo "refusing unknown managed Node runtime directory: $candidate" >&2; exit 1; }
            if [ "$relative" != "$current_runtime" ] && [ "$relative" != "$previous_runtime" ]; then
              rm -rf -- "$candidate"
            fi
          done
          for candidate_map in "$repairs"/[0-9a-f]*; do
            [ -e "$candidate_map" ] || [ -L "$candidate_map" ] || continue
            map_key="$(basename "$candidate_map")"
            valid_hash "$map_key" || { echo "refusing unknown managed Node repair map: $candidate_map" >&2; exit 1; }
            [ "$map_key" = "$base_runtime_key" ] || rm -f -- "$candidate_map"
          done

          ln -sfn /home/hermeswebui/.hermes/hermes-agent/node_modules /opt/data/node_modules
          chown -R ${HERMES_RUNTIME_UID}:${HERMES_RUNTIME_GID} "$node_root"
        volumeMounts:
        - name: home
          mountPath: /opt/data
      containers:
      - name: hermes-webui
        image: ${HERMES_WEBUI_IMAGE}
        imagePullPolicy: ${HERMES_IMAGE_PULL_POLICY}
        securityContext:
          allowPrivilegeEscalation: false
        ports:
        - name: web
          containerPort: 8787
        env:
        - name: HERMES_HOME
          value: /opt/data
        - name: HOME
          value: /opt/data
        - name: CODEX_HOME
          value: /opt/data
        - name: XDG_CONFIG_HOME
          value: /opt/data/.config
        - name: XDG_CACHE_HOME
          value: /opt/data/.cache
        - name: LANG
          value: C.UTF-8
        - name: LC_ALL
          value: C.UTF-8
        - name: HERMES_WRITE_SAFE_ROOT
          value: /opt/data:/workspace
        - name: HERMES_WEBUI_HOST
          value: 0.0.0.0
        - name: HERMES_WEBUI_PORT
          value: "8787"
        - name: HERMES_WEBUI_STATE_DIR
          value: /opt/data/webui
        - name: HERMES_WEBUI_SESSION_TTL
          value: "${HERMES_AUTH_SESSION_MAX_TTL_SECONDS}"
        - name: HERMES_WEBUI_AGENT_DIR
          value: /home/hermeswebui/.hermes/hermes-agent
        - name: HERMES_WEBUI_AUTO_INSTALL
          value: "1"
        # Recent hermes-agent rejects non-Nix wheel/sdist builds. The current
        # WebUI startup script still installs the mounted Agent source through
        # that path; this flag allows the supported container build path until
        # WebUI's editable-install fix is available in a released image.
        - name: HERMES_NIX_BUILD
          value: "1"
        - name: npm_config_yes
          value: "true"
        # HERMES_AUTH_LOCAL_ONLY_START
        - name: HERMES_WEBUI_PASSWORD
          valueFrom:
            secretKeyRef:
              name: hermes-dashboard-auth
              key: password
        # HERMES_AUTH_LOCAL_ONLY_END
        # HERMES_AUTH_EXTERNAL_OIDC_START
        - name: HERMES_WEBUI_OIDC_ISSUER
          value: "${HERMES_WEBUI_OIDC_ISSUER}"
        - name: HERMES_WEBUI_OIDC_CLIENT_ID
          value: "${HERMES_WEBUI_OIDC_CLIENT_ID}"
        - name: HERMES_WEBUI_OIDC_REDIRECT_URI
          value: "${HERMES_WEBUI_OIDC_REDIRECT_URI}"
        - name: HERMES_WEBUI_OIDC_SCOPES
          value: "${HERMES_WEBUI_OIDC_SCOPES}"
        - name: HERMES_WEBUI_OIDC_ALLOW_CLAIM
          value: "${HERMES_WEBUI_OIDC_ALLOW_CLAIM}"
        - name: HERMES_WEBUI_OIDC_ALLOW_VALUES
          value: "${HERMES_WEBUI_OIDC_ALLOW_VALUES}"
        # HERMES_AUTH_EXTERNAL_OIDC_END
        - name: HERMES_WEBUI_MAX_UPLOAD_MB
          value: "${HERMES_WEBUI_MAX_UPLOAD_MB}"
        - name: HERMES_ADDON_PYTHON_MODE
          value: "${HERMES_ADDON_PYTHON_MODE}"
        - name: HERMES_UV_DIR
          value: "${HERMES_UV_DIR}"
        - name: HERMES_ADDON_VENV
          value: "${HERMES_ADDON_VENV}"
        - name: HERMES_ADDON_PYTHON_VERSION
          value: "${HERMES_ADDON_PYTHON_VERSION}"
        - name: UV_PYTHON_INSTALL_DIR
          value: "${HERMES_UV_DIR}/python"
        - name: UV_CACHE_DIR
          value: /opt/data/.cache/uv
        - name: ANSIBLE_CONFIG
          value: "${HERMES_ANSIBLE_CONFIG}"
        - name: PATH
          value: /opt/data/hermes-managed/bin:${HERMES_ADDON_VENV}/bin:${HERMES_UV_DIR}/bin:/opt/data/node/bin:/opt/data/node_modules/.bin:/opt/data/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
        - name: HERMES_API_URL
          value: http://hermes-agent:8642
        - name: HERMES_API_KEY
          valueFrom:
            secretKeyRef:
              name: hermes-api-server
              key: api-key
        - name: BROWSER_CDP_URL
          valueFrom:
            secretKeyRef:
              name: hermes-browser-cdp
              key: BROWSER_CDP_URL
        - name: WANTED_UID
          value: "${HERMES_RUNTIME_UID}"
        - name: WANTED_GID
          value: "${HERMES_RUNTIME_GID}"
        volumeMounts:
        - name: home
          mountPath: /opt/data
        - name: workspace
          mountPath: /workspace
        - name: hermes-agent-src
          mountPath: /home/hermeswebui/.hermes/hermes-agent
          readOnly: true
        readinessProbe:
          httpGet:
            path: /health
            port: web
          initialDelaySeconds: 30
          periodSeconds: 10
          failureThreshold: 18
        livenessProbe:
          httpGet:
            path: /health
            port: web
          initialDelaySeconds: 90
          periodSeconds: 20
          failureThreshold: 6
        resources:
          requests:
            cpu: ${HERMES_WEBUI_CPU_REQUEST}
            memory: ${HERMES_WEBUI_MEMORY_REQUEST}
          limits:
            cpu: "${HERMES_WEBUI_CPU_LIMIT}"
            memory: ${HERMES_WEBUI_MEMORY_LIMIT}
      volumes:
      - name: home
        persistentVolumeClaim:
          claimName: hermes-home
      - name: workspace
        persistentVolumeClaim:
          claimName: hermes-workspace
      - name: hermes-agent-src
        emptyDir: {}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hermes-browser
  namespace: ${HERMES_NAMESPACE}
spec:
  replicas: 1
  revisionHistoryLimit: 3
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: hermes-browser
  template:
    metadata:
      labels:
        app: hermes-browser
    spec:
      automountServiceAccountToken: false
      securityContext:
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: chromium
        image: ${HERMES_BROWSER_IMAGE}
        imagePullPolicy: ${HERMES_IMAGE_PULL_POLICY}
        securityContext:
          runAsUser: 999
          runAsGroup: 999
          runAsNonRoot: true
          allowPrivilegeEscalation: false
          capabilities:
            drop:
            - ALL
        ports:
        - name: http
          containerPort: 3000
        env:
        - name: PORT
          value: "3000"
        - name: HOST
          value: 0.0.0.0
        - name: TOKEN
          valueFrom:
            secretKeyRef:
              name: hermes-browser-token
              key: token
        - name: CONCURRENT
          value: "${BROWSER_CONCURRENT}"
        - name: QUEUED
          value: "${BROWSER_QUEUED}"
        - name: TIMEOUT
          value: "${BROWSER_TIMEOUT_MS}"
        readinessProbe:
          tcpSocket:
            port: http
          initialDelaySeconds: 10
          periodSeconds: 10
          failureThreshold: 18
        livenessProbe:
          tcpSocket:
            port: http
          initialDelaySeconds: 30
          periodSeconds: 20
          failureThreshold: 6
        resources:
          requests:
            cpu: ${HERMES_BROWSER_CPU_REQUEST}
            memory: ${HERMES_BROWSER_MEMORY_REQUEST}
          limits:
            cpu: "${HERMES_BROWSER_CPU_LIMIT}"
            memory: ${HERMES_BROWSER_MEMORY_LIMIT}
---
apiVersion: v1
kind: Service
metadata:
  name: hermes-agent
  namespace: ${HERMES_NAMESPACE}
spec:
  selector:
    app: hermes-agent
  ports:
  - name: api
    port: 8642
    targetPort: api
---
apiVersion: v1
kind: Service
metadata:
  name: hermes-dashboard
  namespace: ${HERMES_NAMESPACE}
spec:
  selector:
    app: hermes-dashboard
  ports:
  - name: dashboard
    port: 9119
    targetPort: dashboard
---
apiVersion: v1
kind: Service
metadata:
  name: hermes-webui
  namespace: ${HERMES_NAMESPACE}
spec:
  selector:
    app: hermes-webui
  ports:
  - name: web
    port: 8787
    targetPort: web
---
apiVersion: v1
kind: Service
metadata:
  name: hermes-browser
  namespace: ${HERMES_NAMESPACE}
spec:
  type: ClusterIP
  selector:
    app: hermes-browser
  ports:
  - name: http
    port: 3000
    targetPort: http
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: hermes-browser-restrict
  namespace: ${HERMES_NAMESPACE}
spec:
  podSelector:
    matchLabels:
      app: hermes-browser
  policyTypes: ["Ingress", "Egress"]
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: hermes-agent
    - podSelector:
        matchLabels:
          app: hermes-dashboard
    - podSelector:
        matchLabels:
          app: hermes-webui
    ports:
    - protocol: TCP
      port: 3000
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
      podSelector:
        matchLabels:
          k8s-app: kube-dns
    ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
  - to:
    - ipBlock:
        cidr: 0.0.0.0/0
        except:
        - 10.0.0.0/8
        - 172.16.0.0/12
        - 192.168.0.0/16
        - 100.64.0.0/10
        - 127.0.0.0/8
        - 169.254.0.0/16
        - 224.0.0.0/4
    ports:
    - protocol: TCP
      port: 80
    - protocol: TCP
      port: 443
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hermes-webui
  namespace: ${HERMES_NAMESPACE}
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: ${TRAEFIK_ENTRYPOINT}
    traefik.ingress.kubernetes.io/router.tls: "${TLS_ENABLED}"
spec:
  ingressClassName: ${INGRESS_CLASS_NAME}
  ${TLS_SECRET_NAME:+tls:
  - hosts:
    - ${WEBUI_HOST}
    secretName: ${TLS_SECRET_NAME}}
  rules:
  - host: ${WEBUI_HOST}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: hermes-webui
            port:
              number: 8787
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hermes-dashboard
  namespace: ${HERMES_NAMESPACE}
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: ${TRAEFIK_ENTRYPOINT}
    traefik.ingress.kubernetes.io/router.tls: "${TLS_ENABLED}"
spec:
  ingressClassName: ${INGRESS_CLASS_NAME}
  ${TLS_SECRET_NAME:+tls:
  - hosts:
    - ${DASHBOARD_HOST}
    secretName: ${TLS_SECRET_NAME}}
  rules:
  - host: ${DASHBOARD_HOST}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: hermes-dashboard
            port:
              number: 9119
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hermes-dashboard-login
  namespace: ${HERMES_NAMESPACE}
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: ${TRAEFIK_ENTRYPOINT}
    traefik.ingress.kubernetes.io/router.tls: "${TLS_ENABLED}"
${DASHBOARD_LOGIN_MIDDLEWARE_ANNOTATION}
spec:
  ingressClassName: ${INGRESS_CLASS_NAME}
  rules:
  - host: ${DASHBOARD_HOST}
    http:
      paths:
      - path: /auth/login
        pathType: Prefix
        backend:
          service:
            name: hermes-dashboard
            port:
              number: 9119
