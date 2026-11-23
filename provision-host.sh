#!/usr/bin/env bash
# Enroll this checkout using an independently reviewed, root-installed provisioner.
# Never run this operator-writable launcher as root; never sudo checkout Python.
set -euo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
HELPER=/usr/local/libexec/hermes-provision-host.py
if [[ $# -eq 0 || "${1:-}" == --help || "${1:-}" == -h ]]; then
  printf '%s\n' \
    'Usage: ./provision-host.sh --revision FULL_COMMIT [--kubeconfig PROTECTED_PATH]' \
    'Enroll this configured checkout; no namespace/env override, no app resource writes.' \
    'Requires clean tracked checkout at FULL_COMMIT and a reviewed protected source snapshot.' \
    'Initial bootstrap is an administrator review/staging procedure, not sudo of checkout code.' \
    'Read scripts/provision_host.py (module documentation or python3 scripts/provision_host.py --help).' \
    'Administrator installs the reviewed provisioner at /usr/local/libexec/hermes-provision-host.py,' \
    'then stages a separately reviewed git archive using its --stage-archive interface.' \
    'No sudoers changes. Subsequent operations use ./maintenance.sh.'
  exit 0
fi
[[ $EUID -ne 0 ]] || { printf 'Run this launcher as the checkout operator, not root.\n' >&2; exit 2; }
[[ -z "${ENV_FILE:-}" ]] || { printf 'ENV_FILE overrides are not supported.\n' >&2; exit 2; }
revision=''
kubeconfig=''
while (($#)); do
  case "$1" in
    --revision)
      [[ $# -ge 2 && -z "$revision" ]] || { printf 'Supply --revision once.\n' >&2; exit 2; }
      revision=$2; shift 2 ;;
    --kubeconfig)
      [[ $# -ge 2 && -z "$kubeconfig" ]] || { printf 'Supply --kubeconfig once.\n' >&2; exit 2; }
      kubeconfig=$2; shift 2 ;;
    *) printf 'Unsupported argument; use --help.\n' >&2; exit 2 ;;
  esac
done
[[ "$revision" =~ ^([a-f0-9]{40}|[a-f0-9]{64})$ ]] || { printf 'A full lowercase commit ID is required.\n' >&2; exit 2; }
# Remove repository redirection inherited from the caller. Git runs as the operator
# only; protected enrollment never runs Git or imports anything from this checkout.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
[[ "$(git --no-replace-objects -C "$ROOT_DIR" rev-parse --show-toplevel)" == "$ROOT_DIR" ]] || { printf 'Launcher must belong to the repository root.\n' >&2; exit 2; }
[[ "$(git --no-replace-objects -C "$ROOT_DIR" rev-parse HEAD)" == "$revision" ]] || { printf 'Checkout HEAD differs from reviewed revision.\n' >&2; exit 2; }
[[ -z "$(git --no-replace-objects -C "$ROOT_DIR" -c core.fsmonitor=false status --porcelain --untracked-files=no)" ]] || { printf 'Tracked checkout changes must be reviewed and committed first.\n' >&2; exit 2; }
[[ -f "$HELPER" && ! -L "$HELPER" && -x "$HELPER" ]] || { printf 'Administrator-reviewed provisioner not installed; see --help. Nothing was enrolled.\n' >&2; exit 2; }
# Verify trust before sudo executes the helper; checking from inside its Python
# body alone would be too late. Once every parent is protected, the operator
# cannot replace the checked file between this check and sudo.
/usr/bin/python3 -I -c '
import os, pathlib, stat, sys
p = pathlib.Path("/usr/local/libexec/hermes-provision-host.py")
try:
    for item in (p, *p.parents):
        s = item.lstat()
        if s.st_uid != 0 or s.st_mode & 0o022 or stat.S_ISLNK(s.st_mode):
            raise ValueError()
        if item == p and not stat.S_ISREG(s.st_mode):
            raise ValueError()
        if item != p and not stat.S_ISDIR(s.st_mode):
            raise ValueError()
except (OSError, ValueError):
    sys.exit("Provisioner or parents are not protected root-owned paths; refusing sudo.")
'
args=(--checkout "$ROOT_DIR" --revision "$revision")
[[ -z "$kubeconfig" ]] || args+=(--kubeconfig "$kubeconfig")
exec /usr/bin/sudo "$HELPER" "${args[@]}"
