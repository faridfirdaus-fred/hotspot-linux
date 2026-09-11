#!/usr/bin/env bash
# hotspot-linux — uninstall the patched iwlmvm override (see README).
set -euo pipefail
exec "$(cd -- "$(dirname -- "$0")" && pwd -P)/lib/lar-control.sh" rollback
