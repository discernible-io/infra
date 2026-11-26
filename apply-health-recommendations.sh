#!/usr/bin/env bash
# Apply operational recommendations from health review (requires sudo once).
#
# Usage: sudo ./apply-health-recommendations.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${EUID:-0}" -ne 0 ]]; then
  exec sudo bash "$0" "$@"
fi

# shellcheck source=infra-env-helper.sh
source "$SCRIPT_DIR/infra-env-helper.sh"

echo "== 1/4 Rootless Podman (linger + podman.socket) =="
MONITOR_USER="$INFRA_USER" "$SCRIPT_DIR/enable-rootless-podman-helper.sh" enable

echo ""
echo "== 2/4 Weekly maintenance timers =="
"$SCRIPT_DIR/manage-weekly-maintenance.sh" install

echo ""
echo "== 3/4 eBPF diagnostics (bcc-tools + bpftrace; on-demand only) =="
"$SCRIPT_DIR/manage-ebpf-diagnostics.sh" install

echo ""
echo "== 4/4 Host firewall status =="
"$SCRIPT_DIR/configure-host-firewall-oneoff.sh" status

echo ""
echo "== Summary =="
"$SCRIPT_DIR/enable-rootless-podman-helper.sh" status
"$SCRIPT_DIR/manage-weekly-maintenance.sh" status
"$SCRIPT_DIR/manage-ebpf-diagnostics.sh" status || true
"$SCRIPT_DIR/manage-monitoring-pods.sh" status
