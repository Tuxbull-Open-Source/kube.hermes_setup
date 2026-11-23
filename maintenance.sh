#!/usr/bin/env bash
# Stable spelling; the implementation remains maintain.sh.
set -euo pipefail
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/maintain.sh" "$@"
