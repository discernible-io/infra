#!/usr/bin/env bash
# Install, enable, disable, or show status for weekly maintenance timers.
#
# Usage:
#   sudo ./manage-weekly-maintenance.sh install
#   sudo ./manage-weekly-maintenance.sh enable
#   sudo ./manage-weekly-maintenance.sh disable
#   ./manage-weekly-maintenance.sh status

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=infra-env-helper.sh
source "$SCRIPT_DIR/infra-env-helper.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

REPO_DIR="$INFRA_REPO"
MAINT_USER="${MONITOR_USER:-$INFRA_USER}"
USER_UID="$(id -u "$MAINT_USER" 2>/dev/null || echo "1000")"

UPGRADE_SERVICE="upgrade-host-packages-weekly.service"
UPGRADE_TIMER="upgrade-host-packages-weekly.timer"
SCAN_SERVICE="scan-containers-vulnerabilities-weekly.service"
SCAN_TIMER="scan-containers-vulnerabilities-weekly.timer"
CLEANUP_SERVICE="cleanup-disk-space-weekly.service"
CLEANUP_TIMER="cleanup-disk-space-weekly.timer"
MONITORING_UPDATE_SERVICE="update-monitoring-images-weekly.service"
MONITORING_UPDATE_TIMER="update-monitoring-images-weekly.timer"

WEEKLY_TIMERS=("$UPGRADE_TIMER" "$CLEANUP_TIMER" "$SCAN_TIMER" "$MONITORING_UPDATE_TIMER")
WEEKLY_SERVICES=("$UPGRADE_SERVICE" "$CLEANUP_SERVICE" "$SCAN_SERVICE" "$MONITORING_UPDATE_SERVICE")

usage() {
  cat <<EOF
Usage: sudo $0 install|enable|disable
       $0 status

Weekly timers:
  • $UPGRADE_TIMER — Sun 02:00 (dnf/yum host package upgrade; no auto-reboot by default)
  • $CLEANUP_TIMER — Sun 03:00 (disk/journal/cache cleanup)
  • $SCAN_TIMER — Sun 04:30 (Trivy container/source scan)
  • $MONITORING_UPDATE_TIMER — Sun 05:30 (Grafana/Loki rebuild when images ≥ 3d old)
EOF
  exit 1
}

require_root() {
  if [[ "${EUID:-0}" -ne 0 ]]; then
    echo -e "${RED}Error: this command requires sudo${NC}" >&2
    usage
  fi
}

timer_installed() {
  [[ -f "/etc/systemd/system/${UPGRADE_TIMER}" && \
     -f "/etc/systemd/system/${SCAN_TIMER}" && \
     -f "/etc/systemd/system/${CLEANUP_TIMER}" && \
     -f "/etc/systemd/system/${MONITORING_UPDATE_TIMER}" ]]
}

install_upgrade_units() {
  cp "$REPO_DIR/upgrade-host-packages-weekly.service" "/etc/systemd/system/${UPGRADE_SERVICE}"
  cp "$REPO_DIR/upgrade-host-packages-weekly.timer" "/etc/systemd/system/${UPGRADE_TIMER}"
  chmod 644 "/etc/systemd/system/${UPGRADE_SERVICE}" "/etc/systemd/system/${UPGRADE_TIMER}"

  sed -i "s|^WorkingDirectory=.*|WorkingDirectory=${REPO_DIR}|" "/etc/systemd/system/${UPGRADE_SERVICE}"
  sed -i "s|^Environment=INFRA_HOME=.*|Environment=INFRA_HOME=${INFRA_HOME}|" "/etc/systemd/system/${UPGRADE_SERVICE}"
  sed -i "s|^Environment=INFRA_REPO=.*|Environment=INFRA_REPO=${REPO_DIR}|" "/etc/systemd/system/${UPGRADE_SERVICE}"
  infra_systemd_set_env "/etc/systemd/system/${UPGRADE_SERVICE}" INFRA_APP_DIR "${INFRA_APP_DIR}"
  sed -i "s|^Environment=INFRA_USER=.*|Environment=INFRA_USER=${MAINT_USER}|" "/etc/systemd/system/${UPGRADE_SERVICE}"
  sed -i "s|^ExecStart=.*|ExecStart=${REPO_DIR}/upgrade-host-packages-weekly.sh|" "/etc/systemd/system/${UPGRADE_SERVICE}"
  sed -i "s|^Documentation=.*|Documentation=file://${REPO_DIR}/docs/readme.md|" "/etc/systemd/system/${UPGRADE_SERVICE}"
  sed -i "s|^Documentation=.*|Documentation=file://${REPO_DIR}/docs/readme.md|" "/etc/systemd/system/${UPGRADE_TIMER}"
}

install_scan_units() {
  local svc="$REPO_DIR/scan-containers-vulnerabilities-weekly.service"
  local tmr="$REPO_DIR/scan-containers-vulnerabilities-weekly.timer"
  cp "$svc" "/etc/systemd/system/${SCAN_SERVICE}"
  cp "$tmr" "/etc/systemd/system/${SCAN_TIMER}"
  chmod 644 "/etc/systemd/system/${SCAN_SERVICE}" "/etc/systemd/system/${SCAN_TIMER}"

  sed -i "s|^User=.*|User=${MAINT_USER}|" "/etc/systemd/system/${SCAN_SERVICE}"
  sed -i "s|^Group=.*|Group=${MAINT_USER}|" "/etc/systemd/system/${SCAN_SERVICE}"
  sed -i "s|^WorkingDirectory=.*|WorkingDirectory=${REPO_DIR}|" "/etc/systemd/system/${SCAN_SERVICE}"
  sed -i "s|^Environment=INFRA_HOME=.*|Environment=INFRA_HOME=${INFRA_HOME}|" "/etc/systemd/system/${SCAN_SERVICE}"
  sed -i "s|^Environment=INFRA_REPO=.*|Environment=INFRA_REPO=${REPO_DIR}|" "/etc/systemd/system/${SCAN_SERVICE}"
  infra_systemd_set_env "/etc/systemd/system/${SCAN_SERVICE}" INFRA_APP_DIR "${INFRA_APP_DIR}"
  sed -i "s|^Environment=INFRA_USER=.*|Environment=INFRA_USER=${MAINT_USER}|" "/etc/systemd/system/${SCAN_SERVICE}" 2>/dev/null || \
    sed -i "/^Environment=INFRA_REPO=/a Environment=INFRA_USER=${MAINT_USER}" "/etc/systemd/system/${SCAN_SERVICE}"
  sed -i "s|^ExecStart=.*|ExecStart=${REPO_DIR}/scan-containers-vulnerabilities-weekly.sh|" "/etc/systemd/system/${SCAN_SERVICE}"
  sed -i "s|^Documentation=.*|Documentation=file://${REPO_DIR}/docs/readme.md|" "/etc/systemd/system/${SCAN_SERVICE}"
  sed -i "s|^Documentation=.*|Documentation=file://${REPO_DIR}/docs/readme.md|" "/etc/systemd/system/${SCAN_TIMER}"
}

install_cleanup_units() {
  cp "$REPO_DIR/cleanup-disk-space-weekly.service" "/etc/systemd/system/${CLEANUP_SERVICE}"
  cp "$REPO_DIR/cleanup-disk-space-weekly.timer" "/etc/systemd/system/${CLEANUP_TIMER}"
  chmod 644 "/etc/systemd/system/${CLEANUP_SERVICE}" "/etc/systemd/system/${CLEANUP_TIMER}"

  sed -i "s|^WorkingDirectory=.*|WorkingDirectory=${REPO_DIR}|" "/etc/systemd/system/${CLEANUP_SERVICE}"
  sed -i "s|^Environment=INFRA_HOME=.*|Environment=INFRA_HOME=${INFRA_HOME}|" "/etc/systemd/system/${CLEANUP_SERVICE}"
  sed -i "s|^Environment=INFRA_REPO=.*|Environment=INFRA_REPO=${REPO_DIR}|" "/etc/systemd/system/${CLEANUP_SERVICE}"
  infra_systemd_set_env "/etc/systemd/system/${CLEANUP_SERVICE}" INFRA_APP_DIR "${INFRA_APP_DIR}"
  sed -i "s|^Environment=INFRA_USER=.*|Environment=INFRA_USER=${MAINT_USER}|" "/etc/systemd/system/${CLEANUP_SERVICE}"
  sed -i "s|^ExecStart=.*|ExecStart=${REPO_DIR}/cleanup-disk-space-weekly.sh|" "/etc/systemd/system/${CLEANUP_SERVICE}"
  sed -i "s|^Documentation=.*|Documentation=file://${REPO_DIR}/docs/readme.md|" "/etc/systemd/system/${CLEANUP_SERVICE}"
  sed -i "s|^Documentation=.*|Documentation=file://${REPO_DIR}/docs/readme.md|" "/etc/systemd/system/${CLEANUP_TIMER}"
}

install_monitoring_update_units() {
  local svc="$REPO_DIR/update-monitoring-images-weekly.service"
  local tmr="$REPO_DIR/update-monitoring-images-weekly.timer"
  cp "$svc" "/etc/systemd/system/${MONITORING_UPDATE_SERVICE}"
  cp "$tmr" "/etc/systemd/system/${MONITORING_UPDATE_TIMER}"
  chmod 644 "/etc/systemd/system/${MONITORING_UPDATE_SERVICE}" "/etc/systemd/system/${MONITORING_UPDATE_TIMER}"

  sed -i "s|^User=.*|User=${MAINT_USER}|" "/etc/systemd/system/${MONITORING_UPDATE_SERVICE}"
  sed -i "s|^Group=.*|Group=${MAINT_USER}|" "/etc/systemd/system/${MONITORING_UPDATE_SERVICE}"
  sed -i "s|^WorkingDirectory=.*|WorkingDirectory=${REPO_DIR}|" "/etc/systemd/system/${MONITORING_UPDATE_SERVICE}"
  sed -i "s|^Environment=INFRA_HOME=.*|Environment=INFRA_HOME=${INFRA_HOME}|" "/etc/systemd/system/${MONITORING_UPDATE_SERVICE}"
  sed -i "s|^Environment=INFRA_REPO=.*|Environment=INFRA_REPO=${REPO_DIR}|" "/etc/systemd/system/${MONITORING_UPDATE_SERVICE}"
  infra_systemd_set_env "/etc/systemd/system/${MONITORING_UPDATE_SERVICE}" INFRA_APP_DIR "${INFRA_APP_DIR}"
  sed -i "s|^Environment=INFRA_USER=.*|Environment=INFRA_USER=${MAINT_USER}|" "/etc/systemd/system/${MONITORING_UPDATE_SERVICE}" 2>/dev/null || \
    sed -i "/^Environment=INFRA_REPO=/a Environment=INFRA_USER=${MAINT_USER}" "/etc/systemd/system/${MONITORING_UPDATE_SERVICE}"
  sed -i "s|^Environment=\"XDG_RUNTIME_DIR=.*|Environment=\"XDG_RUNTIME_DIR=/run/user/${USER_UID}\"|" "/etc/systemd/system/${MONITORING_UPDATE_SERVICE}"
  sed -i "s|^Environment=\"DBUS_SESSION_BUS_ADDRESS=.*|Environment=\"DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${USER_UID}/bus\"|" "/etc/systemd/system/${MONITORING_UPDATE_SERVICE}"
  sed -i "s|^ExecStart=.*|ExecStart=${REPO_DIR}/update-monitoring-images-weekly.sh|" "/etc/systemd/system/${MONITORING_UPDATE_SERVICE}"
  sed -i "s|^Documentation=.*|Documentation=file://${REPO_DIR}/docs/readme.md|" "/etc/systemd/system/${MONITORING_UPDATE_SERVICE}"
  sed -i "s|^Documentation=.*|Documentation=file://${REPO_DIR}/docs/readme.md|" "/etc/systemd/system/${MONITORING_UPDATE_TIMER}"
}

cmd_install() {
  require_root
  echo -e "${BLUE}Installing weekly maintenance timers for ${MAINT_USER}@${REPO_DIR}${NC}"

  local f
  for f in \
    "$REPO_DIR/upgrade-host-packages-weekly.sh" \
    "$REPO_DIR/cleanup-disk-space-weekly.sh" \
    "$REPO_DIR/scan-containers-vulnerabilities-weekly.sh" \
    "$REPO_DIR/update-monitoring-images-weekly.sh" \
    "$REPO_DIR/upgrade-host-packages-weekly.service" \
    "$REPO_DIR/upgrade-host-packages-weekly.timer" \
    "$REPO_DIR/scan-containers-vulnerabilities-weekly.service" \
    "$REPO_DIR/scan-containers-vulnerabilities-weekly.timer" \
    "$REPO_DIR/cleanup-disk-space-weekly.service" \
    "$REPO_DIR/cleanup-disk-space-weekly.timer" \
    "$REPO_DIR/update-monitoring-images-weekly.service" \
    "$REPO_DIR/update-monitoring-images-weekly.timer"; do
    if [[ ! -f "$f" ]]; then
      echo -e "${RED}Missing: $f${NC}" >&2
      exit 1
    fi
  done

  chmod +x \
    "$REPO_DIR/upgrade-host-packages-weekly.sh" \
    "$REPO_DIR/cleanup-disk-space-weekly.sh" \
    "$REPO_DIR/scan-containers-vulnerabilities-weekly.sh" \
    "$REPO_DIR/update-monitoring-images-weekly.sh"

  install_upgrade_units
  install_cleanup_units
  install_scan_units
  install_monitoring_update_units
  systemctl daemon-reload
  systemctl enable "${WEEKLY_TIMERS[@]}"
  systemctl start "${WEEKLY_TIMERS[@]}"

  echo -e "${GREEN}✓ Weekly maintenance timers installed and enabled${NC}"
  systemctl list-timers "${WEEKLY_TIMERS[@]}" --no-pager
}

cmd_enable() {
  require_root
  if ! timer_installed; then
    echo -e "${YELLOW}Not installed — run: sudo $0 install${NC}"
    exit 1
  fi
  systemctl daemon-reload
  systemctl enable "${WEEKLY_TIMERS[@]}"
  systemctl start "${WEEKLY_TIMERS[@]}"
  echo -e "${GREEN}✓ Weekly maintenance enabled${NC}"
}

cmd_disable() {
  require_root
  if ! timer_installed; then
    echo -e "${YELLOW}Weekly maintenance is not installed${NC}"
    exit 0
  fi
  systemctl stop "${WEEKLY_TIMERS[@]}" 2>/dev/null || true
  systemctl disable "${WEEKLY_TIMERS[@]}" 2>/dev/null || true
  echo -e "${GREEN}✓ Weekly maintenance disabled${NC}"
}

cmd_status() {
  echo -e "${BLUE}Weekly maintenance status${NC}"

  echo -e "\n${CYAN}Installation:${NC}"
  if timer_installed; then
    echo -e "${GREEN}✓ Installed${NC}"
  else
    echo -e "${YELLOW}○ Not fully installed — run: sudo $0 install${NC}"
  fi

  echo -e "\n${CYAN}Timers:${NC}"
  local t
  for t in "${WEEKLY_TIMERS[@]}"; do
    if systemctl is-active --quiet "$t" 2>/dev/null; then
      echo -e "${GREEN}✓ $t active${NC}"
    elif [[ -f "/etc/systemd/system/$t" ]]; then
      echo -e "${YELLOW}○ $t inactive${NC}"
    else
      echo -e "${RED}✗ $t not installed${NC}"
    fi
  done

  if [[ -f "/etc/systemd/system/${UPGRADE_TIMER}" || \
        -f "/etc/systemd/system/${CLEANUP_TIMER}" || \
        -f "/etc/systemd/system/${SCAN_TIMER}" || \
        -f "/etc/systemd/system/${MONITORING_UPDATE_TIMER}" ]]; then
    systemctl list-timers "${WEEKLY_TIMERS[@]}" --no-pager 2>/dev/null || true
  fi

  echo -e "\n${CYAN}Last service runs:${NC}"
  local s
  for s in "${WEEKLY_SERVICES[@]}"; do
    if [[ -f "/etc/systemd/system/$s" ]]; then
      local ts
      ts="$(systemctl show "$s" -p ActiveEnterTimestamp --value 2>/dev/null || true)"
      if [[ -z "$ts" || "$ts" == "n/a" ]]; then
        ts="never"
      fi
      printf '  %s: %s\n' "$s" "$ts"
    else
      printf '  %s: not installed\n' "$s"
    fi
  done

  local reboot_flag="${INFRA_REBOOT_REQUIRED_FLAG:-/var/lib/infra/reboot-required}"
  echo -e "\n${CYAN}Reboot flag:${NC}"
  if [[ -f "$reboot_flag" ]]; then
    echo -e "${YELLOW}✓ Present: $reboot_flag${NC}"
    sed 's/^/  /' "$reboot_flag" 2>/dev/null || true
  else
    echo -e "${GREEN}○ None ($reboot_flag)${NC}"
  fi
}

ACTION="${1:-}"
case "$ACTION" in
  install) cmd_install ;;
  enable) cmd_enable ;;
  disable) cmd_disable ;;
  status) cmd_status ;;
  *) usage ;;
esac
