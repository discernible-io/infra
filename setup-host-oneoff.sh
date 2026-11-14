#!/usr/bin/env bash
# One-shot host bootstrap driven by ~/infra-app/infra-env-helper.sh.
# Ports, domains, and 443 redirect target come from the host profile.
#
# Usage (from your terminal, not the agent shell):
#   ./setup-host-oneoff.sh [certbot-email]
#   sudo ./setup-host-oneoff.sh [certbot-email]
#
# Requires: a host profile in `~/infra-app/` (`./bootstrap-infra-app.sh` on a new machine).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${EUID}" -ne 0 ]]; then
  exec sudo bash "$0" "$@"
fi

# shellcheck source=infra-env-helper.sh
source "$SCRIPT_DIR/infra-env-helper.sh"
# shellcheck source=infra-iptables-helper.sh
source "$SCRIPT_DIR/infra-iptables-helper.sh"
# shellcheck source=infra-podman-helper.sh
source "$SCRIPT_DIR/infra-podman-helper.sh"

CERT_EMAIL="${1:-$INFRA_CERT_EMAIL}"

echo "== Host: INFRA_USER=${INFRA_USER} INFRA_APP_DIR=${INFRA_APP_DIR} =="
echo "   Cert email: ${CERT_EMAIL}"
if declare -p INFRA_API_PORTS &>/dev/null; then
  echo "   API ports:  ${!INFRA_API_PORTS[*]}"
fi

echo ""
echo "== Rootless Podman session (linger + podman.socket) =="
MONITOR_USER="$INFRA_USER" "$SCRIPT_DIR/enable-rootless-podman-helper.sh" enable
infra_enable_podman_boot_autostart "$INFRA_USER" || true

echo ""
echo "== Weekly maintenance timers (cleanup + vulnerability scan) =="
"$SCRIPT_DIR/manage-weekly-maintenance.sh" install

echo ""
echo "== Pod monitor (systemd) =="
export MONITOR_USER="$INFRA_USER"
printf 'n\ny\n' | "$SCRIPT_DIR/manage-monitoring-pods.sh" install

echo ""
echo "== App directories (certs/, logs/, data/, nginx/, secrets/) =="
"$SCRIPT_DIR/bootstrap-app-dir-layout.sh"

echo ""
echo "== TLS: issue/renew + install to *-app =="
printf 'n\n' | "$SCRIPT_DIR/renew-certs-all-monthly.sh" manual "$CERT_EMAIL"
echo "== TLS: point certbot-renew.timer at infra renew (standalone :80 + 13d floor) =="
"$SCRIPT_DIR/renew-certs-all-monthly.sh" install-timer

echo ""
echo "== Host firewall (iptables allowlist from infra-app profile) =="
infra_switch_from_firewalld_to_iptables
"$SCRIPT_DIR/configure-host-firewall-oneoff.sh" enable permanent

if infra_port_forward_configured; then
  echo ""
  echo "== Port forwarding (443 -> ${INFRA_PORT_FORWARD_SERVICE:-${INFRA_PORT_FORWARD_DEST}}) =="
  "$SCRIPT_DIR/configure-port-forwarding-oneoff.sh" enable permanent
else
  echo ""
  echo "== Port forwarding skipped (INFRA_PORT_FORWARD_SERVICE / DEST unset in profile) =="
fi

echo ""
echo "== Verify =="
"$SCRIPT_DIR/verify-certs-in-apps-weekly.sh" || true
"$SCRIPT_DIR/enable-rootless-podman-helper.sh" status || true
"$SCRIPT_DIR/manage-weekly-maintenance.sh" status || true
"$SCRIPT_DIR/configure-host-firewall-oneoff.sh" status || true
if infra_port_forward_configured; then
  "$SCRIPT_DIR/configure-port-forwarding-oneoff.sh" status || true
fi
systemctl is-active monitor-pods-liveness.timer && systemctl list-timers monitor-pods-liveness.timer --no-pager || true

echo ""
echo "Done (${INFRA_USER}). Restart API/monitoring pods when ready if certs changed."
