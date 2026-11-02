#!/usr/bin/env bash
# Validate the shared API-key sync helper retained by reconcile-api-key.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d -t hermes-api-key-sync.XXXXXX)"
trap 'rm -rf -- "$TMP_DIR"' EXIT
export ENV_FILE=/dev/null
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

printf 'API-key sync helper tests passed\n'
