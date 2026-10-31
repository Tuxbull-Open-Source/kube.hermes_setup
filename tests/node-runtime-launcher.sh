#!/usr/bin/env bash
# Verify the production WebUI Node launcher preserves the image loader environment.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d -t hermes-production-node-launcher.XXXXXX)"
trap 'rm -rf -- "$TMP_DIR"' EXIT

(
  set -a
  # shellcheck disable=SC1091
  source "$ROOT_DIR/examples/hermes.env.example"
  set +a
  export HERMES_INSTALL_LIB_ONLY=true
  # shellcheck disable=SC1091
  source "$ROOT_DIR/install.sh"
  export HERMES_DASHBOARD_ENABLED=false
  export HERMES_WEBUI_ENABLED=true
  export HERMES_BROWSER_ENABLED=false
  export HERMES_BOOTSTRAP_MODE=disabled
  export HERMES_ADDON_REQUIREMENTS=
  export WEBUI_HOST=webui.example.com
  export HERMES_RENDER_DIR="$TMP_DIR/render"
  prepare_paths
  prepare_defaults
  mkdir -p "$RENDER_DIR"
  python3 "$ROOT_DIR/scripts/render_template.py" "$ROOT_DIR/manifests/hermes.yaml.tpl" "$MANIFEST_OUT"
)

python3 - "$TMP_DIR/render/hermes.yaml" "$TMP_DIR/init.sh" <<'PY'
import sys,yaml
manifest,output=sys.argv[1:]
docs=[x for x in yaml.safe_load_all(open(manifest)) if x]
webui=next(x for x in docs if x.get('kind')=='Deployment' and x['metadata']['name']=='hermes-webui')
pod=webui['spec']['template']['spec']
container=next(x for x in pod['containers'] if x['name']=='hermes-webui')
env={x['name']:x for x in container.get('env',[])}
assert 'LD_LIBRARY_PATH' not in env, 'WebUI still replaces the image-defined LD_LIBRARY_PATH'
init=next(x for x in pod['initContainers'] if x['name']=='prepare-browser-cli')
script=init['args'][0]
assert 'node_root=/opt/data/node' in script
assert 'npm_source="$(npm root -g)/npm"' in script
assert 'runtimes="$node_root/runtimes"' in script
assert 'runtime_stage="$runtimes/.$runtime_key.$$"' in script
assert 'mv -fT "$current_tmp" "$node_root/current"' in script
assert 'NODE_LAUNCHER' in script
assert 'NPM_LAUNCHER' in script
assert 'NPX_LAUNCHER' in script
assert "[ -n \"$node_atomic_lib\" ] ||" not in script
open(output,'w').write(script)
PY

mkdir -p \
  "$TMP_DIR/source/bin" \
  "$TMP_DIR/source/npm/bin" \
  "$TMP_DIR/source/agent-node-modules" \
  "$TMP_DIR/fake-bin" \
  "$TMP_DIR/runtime"
cat > "$TMP_DIR/source/bin/node" <<'NODE'
#!/bin/sh
case "${1-}" in
  --version) printf '%s\n' runtime-v1 ;;
  env) printenv LD_LIBRARY_PATH 2>/dev/null || true ;;
  marker) printf '%s\n' runtime-v1 ;;
  args) shift; printf '%s\n' "$@" ;;
  exit) exit "$2" ;;
  */bin/npm|*/npm-cli.js) printf '%s\n' npm-ok ;;
  */bin/npx|*/npx-cli.js) printf '%s\n' npx-ok ;;
  *) printf 'unexpected payload argument: %s\n' "${1-}" >&2; exit 64 ;;
esac
NODE
chmod 755 "$TMP_DIR/source/bin/node"
printf '%s\n' '#!/usr/bin/env node' > "$TMP_DIR/source/npm/bin/npm-cli.js"
printf '%s\n' '#!/usr/bin/env node' > "$TMP_DIR/source/npm/bin/npx-cli.js"
printf '%s\n' '{}' > "$TMP_DIR/source/npm/package.json"
chmod 755 "$TMP_DIR/source/npm/bin/"*.js
cat > "$TMP_DIR/fake-bin/ldd" <<'LDD'
#!/bin/sh
if [ "${LDD_FAIL:-0}" = 1 ]; then
  printf '%s\n' 'libatomic.so.1 => not found'
  exit 0
fi
printf '%s\n' 'linux-vdso.so.1 (0x0000000000000000)'
LDD
chmod 755 "$TMP_DIR/fake-bin/ldd"

python3 - "$TMP_DIR/init.sh" "$TMP_DIR/runtime" "$TMP_DIR/source" <<'PY'
from pathlib import Path
import sys
script,runtime,source=map(Path,sys.argv[1:])
text=script.read_text()
text=text.replace('/opt/data/node',str(runtime))
text=text.replace('/usr/local/bin/node',str(source/'bin/node'))
text=text.replace('npm_source="$(npm root -g)/npm"',f'npm_source={source / "npm"}')
text=text.replace('/home/hermeswebui/.hermes/hermes-agent/node_modules',str(source/'agent-node-modules'))
text=text.replace('chown -R 10000:10000',': # ownership skipped in fixture')
script.write_text(text)
PY
PATH="$TMP_DIR/fake-bin:$PATH" sh "$TMP_DIR/init.sh"

NODE="$TMP_DIR/runtime/bin/node"
NPM="$TMP_DIR/runtime/bin/npm"
NPX="$TMP_DIR/runtime/bin/npx"
PRIVATE="$TMP_DIR/runtime/lib"
ACTIVE_RUNTIME="$(readlink -f "$TMP_DIR/runtime/current")"
PRIVATE="$ACTIVE_RUNTIME/lib"
[[ -x "$NODE" && -x "$ACTIVE_RUNTIME/libexec/node" ]]
[[ ! -e "$PRIVATE/libatomic.so.1" && ! -L "$PRIVATE/libatomic.so.1" ]]
unset LD_LIBRARY_PATH || true
[[ "$("$NODE" env)" == "$PRIVATE" ]]
custom=/custom/image/lib:/custom/extension/lib
[[ "$(LD_LIBRARY_PATH="$custom" "$NODE" env)" == "$PRIVATE:$custom" ]]
already="/before:$PRIVATE:/after"
[[ "$(LD_LIBRARY_PATH="$already" "$NODE" env)" == "$already" ]]
mapfile -t args < <("$NODE" args 'one value' two)
[[ "${args[0]}" == 'one value' && "${args[1]}" == two ]]
set +e
"$NODE" exit 37
rc=$?
set -e
[[ "$rc" == 37 ]]
npm_result="$(PATH="$TMP_DIR/runtime/bin:$PATH" "$NPM" --version)"
npx_result="$(PATH="$TMP_DIR/runtime/bin:$PATH" "$NPX" --version)"
[[ "$npm_result" == npm-ok ]]
[[ "$npx_result" == npx-ok ]]

# A trusted retained payload with a lost execute bit is repaired on rerun.
chmod 644 "$ACTIVE_RUNTIME/libexec/node"
set +e
"$NODE" marker >/dev/null 2>&1
mode_rc=$?
set -e
[[ "$mode_rc" != 0 ]]
PATH="$TMP_DIR/fake-bin:$PATH" sh "$TMP_DIR/init.sh"
[[ -x "$ACTIVE_RUNTIME/libexec/node" ]]
[[ "$("$NODE" marker)" == runtime-v1 ]]

# A malformed active pointer is replaced without retaining it as previous.
ln -sfn '../malformed-runtime-pointer' "$TMP_DIR/runtime/current"
PATH="$TMP_DIR/fake-bin:$PATH" sh "$TMP_DIR/init.sh"
ACTIVE_RUNTIME="$(readlink -f "$TMP_DIR/runtime/current")"
[[ "$ACTIVE_RUNTIME" == "$TMP_DIR/runtime/runtimes/"* ]]
[[ "$("$NODE" marker)" == runtime-v1 ]]

# An unexpected private library invalidates and rebuilds the generation.
unexpected_runtime="$ACTIVE_RUNTIME"
printf '%s\n' invalid-library > "$unexpected_runtime/lib/libstdc++.so.6"
PATH="$TMP_DIR/fake-bin:$PATH" sh "$TMP_DIR/init.sh"
ACTIVE_RUNTIME="$(readlink -f "$TMP_DIR/runtime/current")"
[[ "$ACTIVE_RUNTIME" != "$unexpected_runtime" ]]
[[ ! -e "$unexpected_runtime" ]]
[[ ! -e "$ACTIVE_RUNTIME/lib/libstdc++.so.6" ]]
[[ "$("$NODE" marker)" == runtime-v1 ]]

# A content-corrupted same-key runtime is replaced from the trusted source.
corrupt_runtime="$ACTIVE_RUNTIME"
printf '%s\n' '#!/bin/sh' 'printf corrupted-runtime\\n' > "$corrupt_runtime/libexec/node"
chmod 755 "$corrupt_runtime/libexec/node"
set +e
PATH="$TMP_DIR/fake-bin:$PATH" sh "$TMP_DIR/init.sh" >/dev/null 2>&1
corrupt_repair_rc=$?
set -e
[[ "$corrupt_repair_rc" == 0 ]]
ACTIVE_RUNTIME="$(readlink -f "$TMP_DIR/runtime/current")"
[[ "$ACTIVE_RUNTIME" != "$corrupt_runtime" ]]
[[ ! -e "$corrupt_runtime" ]]
[[ "$("$NODE" marker)" == runtime-v1 ]]
[[ "$(PATH="$TMP_DIR/runtime/bin:$PATH" "$NPM" --version)" == npm-ok ]]
[[ "$(PATH="$TMP_DIR/runtime/bin:$PATH" "$NPX" --version)" == npx-ok ]]
repair_state="$(python3 - "$TMP_DIR/runtime" <<'PY'
from pathlib import Path
import hashlib,sys
root=Path(sys.argv[1]); rows=[]
for path in sorted(x for x in root.rglob('*') if x.is_file() or x.is_symlink()):
    rel=path.relative_to(root).as_posix()
    payload=('L:'+path.readlink().as_posix()).encode() if path.is_symlink() else b'F:'+path.read_bytes()
    rows.append(rel.encode()+b'\0'+payload)
print(hashlib.sha256(b'\0'.join(rows)).hexdigest())
PY
)"
PATH="$TMP_DIR/fake-bin:$PATH" sh "$TMP_DIR/init.sh"
repair_state_after="$(python3 - "$TMP_DIR/runtime" <<'PY'
from pathlib import Path
import hashlib,sys
root=Path(sys.argv[1]); rows=[]
for path in sorted(x for x in root.rglob('*') if x.is_file() or x.is_symlink()):
    rel=path.relative_to(root).as_posix()
    payload=('L:'+path.readlink().as_posix()).encode() if path.is_symlink() else b'F:'+path.read_bytes()
    rows.append(rel.encode()+b'\0'+payload)
print(hashlib.sha256(b'\0'.join(rows)).hexdigest())
PY
)"
[[ "$repair_state_after" == "$repair_state" ]]

# A failed source-runtime refresh must not publish any part of the candidate.
before_state="$(python3 - "$TMP_DIR/runtime" <<'PY'
from pathlib import Path
import hashlib,sys
root=Path(sys.argv[1])
rows=[]
for path in sorted(x for x in root.rglob('*') if x.is_file() or x.is_symlink()):
    rel=path.relative_to(root).as_posix()
    if path.is_symlink(): payload=('L:'+path.readlink().as_posix()).encode()
    else: payload=b'F:'+path.read_bytes()
    rows.append(rel.encode()+b'\0'+payload)
print(hashlib.sha256(b'\0'.join(rows)).hexdigest())
PY
)"
sed -i 's/runtime-v1/runtime-v2/' "$TMP_DIR/source/bin/node"
set +e
LDD_FAIL=1 PATH="$TMP_DIR/fake-bin:$PATH" sh "$TMP_DIR/init.sh" >/dev/null 2>&1
refresh_rc=$?
set -e
[[ "$refresh_rc" != 0 ]]
[[ "$("$NODE" marker)" == runtime-v1 ]]
after_ldd_failure="$(python3 - "$TMP_DIR/runtime" <<'PY'
from pathlib import Path
import hashlib,sys
root=Path(sys.argv[1]); rows=[]
for path in sorted(x for x in root.rglob('*') if x.is_file() or x.is_symlink()):
    rel=path.relative_to(root).as_posix()
    payload=('L:'+path.readlink().as_posix()).encode() if path.is_symlink() else b'F:'+path.read_bytes()
    rows.append(rel.encode()+b'\0'+payload)
print(hashlib.sha256(b'\0'.join(rows)).hexdigest())
PY
)"
[[ "$after_ldd_failure" == "$before_state" ]]

# A malformed npm candidate must also fail before changing active commands.
mv "$TMP_DIR/source/npm/bin/npm-cli.js" "$TMP_DIR/source/npm/bin/npm-cli.js.missing"
set +e
PATH="$TMP_DIR/fake-bin:$PATH" sh "$TMP_DIR/init.sh" >/dev/null 2>&1
npm_refresh_rc=$?
set -e
[[ "$npm_refresh_rc" != 0 ]]
[[ "$("$NODE" marker)" == runtime-v1 ]]
[[ "$(PATH="$TMP_DIR/runtime/bin:$PATH" "$NPM" --version)" == npm-ok ]]
[[ "$(PATH="$TMP_DIR/runtime/bin:$PATH" "$NPX" --version)" == npx-ok ]]
after_npm_failure="$(python3 - "$TMP_DIR/runtime" <<'PY'
from pathlib import Path
import hashlib,sys
root=Path(sys.argv[1]); rows=[]
for path in sorted(x for x in root.rglob('*') if x.is_file() or x.is_symlink()):
    rel=path.relative_to(root).as_posix()
    payload=('L:'+path.readlink().as_posix()).encode() if path.is_symlink() else b'F:'+path.read_bytes()
    rows.append(rel.encode()+b'\0'+payload)
print(hashlib.sha256(b'\0'.join(rows)).hexdigest())
PY
)"
[[ "$after_npm_failure" == "$before_state" ]]

# A complete v2 candidate publishes only after validation.
mv "$TMP_DIR/source/npm/bin/npm-cli.js.missing" "$TMP_DIR/source/npm/bin/npm-cli.js"
PATH="$TMP_DIR/fake-bin:$PATH" sh "$TMP_DIR/init.sh"
ACTIVE_RUNTIME="$(readlink -f "$TMP_DIR/runtime/current")"
[[ "$ACTIVE_RUNTIME" == "$TMP_DIR/runtime/runtimes/"* ]]
[[ "$("$NODE" marker)" == runtime-v2 ]]
[[ "$(PATH="$TMP_DIR/runtime/bin:$PATH" "$NPM" --version)" == npm-ok ]]
[[ "$(PATH="$TMP_DIR/runtime/bin:$PATH" "$NPX" --version)" == npx-ok ]]
[[ "$(readlink -f "$TMP_DIR/runtime/previous")" != "$ACTIVE_RUNTIME" ]]
[[ "$(find "$TMP_DIR/runtime/runtimes" -mindepth 1 -maxdepth 1 -type d | wc -l)" == 2 ]]

# A third valid update retains v2 for rollback and garbage-collects v1.
sed -i 's/runtime-v2/runtime-v3/' "$TMP_DIR/source/bin/node"
v2_runtime="$ACTIVE_RUNTIME"
v1_runtime="$(readlink -f "$TMP_DIR/runtime/previous")"
PATH="$TMP_DIR/fake-bin:$PATH" sh "$TMP_DIR/init.sh"
v3_runtime="$(readlink -f "$TMP_DIR/runtime/current")"
[[ "$v3_runtime" != "$v2_runtime" ]]
[[ "$(readlink -f "$TMP_DIR/runtime/previous")" == "$v2_runtime" ]]
[[ ! -e "$v1_runtime" ]]
[[ "$(find "$TMP_DIR/runtime/runtimes" -mindepth 1 -maxdepth 1 -type d | wc -l)" == 2 ]]
[[ "$("$NODE" marker)" == runtime-v3 ]]

printf 'production Node launcher tests passed\n'
