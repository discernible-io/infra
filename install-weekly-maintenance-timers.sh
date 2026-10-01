#!/usr/bin/env bash
# Legacy alias — prefer manage-weekly-maintenance.sh.
# Install and enable weekly maintenance timers (OS upgrade + disk cleanup + Trivy + monitoring images).
#
# Usage:
#   sudo ./install-weekly-maintenance-timers.sh install
#   sudo ./install-weekly-maintenance-timers.sh enable
#   ./install-weekly-maintenance-timers.sh status

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/manage-weekly-maintenance.sh" "${1:-}"
