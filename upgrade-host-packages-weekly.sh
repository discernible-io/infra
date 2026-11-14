#!/usr/bin/env bash
# Apply pending AlmaLinux / RHEL-family OS package updates (weekly maintenance).
#
# Usage:
#   sudo ./upgrade-host-packages-weekly.sh           # dnf upgrade -y
#   sudo ./upgrade-host-packages-weekly.sh --check   # report only (no apply)
#   sudo ./upgrade-host-packages-weekly.sh --security-only
#
# Environment:
#   AUTO_REBOOT=1              Reboot when dnf needs-restarting -r says yes
#   UPGRADE_SECURITY_ONLY=1    Same as --security-only
#   UPGRADE_DOWNLOAD_ONLY=1    Download packages only (no install)
#   UPGRADE_EXCLUDE='pkg…'     Space-separated dnf --exclude list (optional)
#
# Default policy: apply updates, log reboot need, do NOT reboot.
# Install timer via: sudo ./manage-weekly-maintenance.sh install

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=infra-env-helper.sh
source "$SCRIPT_DIR/infra-env-helper.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

LOG_DIR="${INFRA_HOST_UPGRADE_LOG_DIR:-/var/log/infra-host-package-upgrade}"
RUN_LOG="${LOG_DIR}/runs.log"
REBOOT_FLAG="${INFRA_REBOOT_REQUIRED_FLAG:-/var/lib/infra/reboot-required}"

CHECK_ONLY=0
SECURITY_ONLY="${UPGRADE_SECURITY_ONLY:-0}"
DOWNLOAD_ONLY="${UPGRADE_DOWNLOAD_ONLY:-0}"
AUTO_REBOOT="${AUTO_REBOOT:-0}"

usage() {
  cat <<EOF
Usage: sudo $0 [--check|--security-only|--download-only] [--reboot-if-needed]

  (default)         Run dnf upgrade -y, report reboot need
  --check           List pending updates only
  --security-only   Apply security updates only
  --download-only   Download packages; do not install
  --reboot-if-needed
                    Reboot when dnf needs-restarting -r indicates it
                    (same as AUTO_REBOOT=1)

Logs: $RUN_LOG
Flag: $REBOOT_FLAG (created when reboot is needed)
EOF
  exit 1
}

require_root() {
  if [[ "${EUID:-0}" -ne 0 ]]; then
    echo -e "${RED}Error: run as root: sudo $0${NC}" >&2
    exit 1
  fi
}

detect_pkg() {
  if command -v dnf >/dev/null 2>&1; then
    PKG=dnf
  elif command -v yum >/dev/null 2>&1; then
    PKG=yum
  else
    echo -e "${RED}Error: neither dnf nor yum found${NC}" >&2
    exit 1
  fi
}

log_line() {
  local level="$1"
  shift
  local msg="$*"
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  mkdir -p "$LOG_DIR" "$(dirname "$REBOOT_FLAG")"
  echo "${ts} level=${level} ${msg}" | tee -a "$RUN_LOG"
}

reboot_needed() {
  if [[ "$PKG" == dnf ]]; then
    # Exit 1 => reboot needed; exit 0 => not needed
    if dnf needs-restarting -r >/dev/null 2>&1; then
      return 1
    fi
    return 0
  fi
  if command -v needs-restarting >/dev/null 2>&1; then
    if needs-restarting -r >/dev/null 2>&1; then
      return 1
    fi
    return 0
  fi
  # Fallback: new kernel installed but not running
  local running latest
  running="$(uname -r)"
  latest="$(rpm -q kernel --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' 2>/dev/null | sort -V | tail -1 || true)"
  [[ -n "$latest" && "$running" != "$latest" ]]
}

mark_reboot_required() {
  local reason="$1"
  mkdir -p "$(dirname "$REBOOT_FLAG")"
  cat >"$REBOOT_FLAG" <<EOF
ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
reason=${reason}
running_kernel=$(uname -r)
EOF
  log_line warn "reboot_required=1 reason=${reason}"
}

clear_reboot_flag_if_current() {
  if [[ -f "$REBOOT_FLAG" ]] && ! reboot_needed; then
    rm -f "$REBOOT_FLAG"
  fi
}

pending_count() {
  # dnf check-update: 100 = updates available, 0 = none
  set +e
  local out
  out="$("$PKG" check-update -q 2>/dev/null)"
  local rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    echo 0
    return
  fi
  if [[ $rc -eq 100 ]]; then
    echo "$out" | awk 'NF && $1 !~ /^Obsoleting/ {c++} END{print c+0}'
    return
  fi
  echo "?"
}

cmd_check() {
  echo -e "${BLUE}Pending OS package updates (${PKG})${NC}"
  set +e
  "$PKG" check-update
  local rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    echo -e "${GREEN}No updates available${NC}"
  elif [[ $rc -eq 100 ]]; then
    echo -e "${YELLOW}Updates are available (see list above)${NC}"
  else
    echo -e "${RED}${PKG} check-update failed (exit ${rc})${NC}" >&2
    exit "$rc"
  fi
  if [[ "$PKG" == dnf ]]; then
    echo ""
    "$PKG" updateinfo summary 2>/dev/null || true
  fi
  echo ""
  if reboot_needed; then
    echo -e "${YELLOW}Reboot currently needed (stale libs/kernel/services)${NC}"
  else
    echo -e "${GREEN}Reboot not currently indicated${NC}"
  fi
}

apply_updates() {
  local -a args=(-y)
  local -a extra_excludes=()
  if [[ "$DOWNLOAD_ONLY" == "1" ]]; then
    args+=(--downloadonly)
  fi
  if [[ "$SECURITY_ONLY" == "1" ]]; then
    args+=(--security)
  fi
  # Optional permanent skips (space-separated), e.g. broken EPEL ahead of baseos.
  # Example: UPGRADE_EXCLUDE='python3-pyOpenSSL'
  if [[ -n "${UPGRADE_EXCLUDE:-}" ]]; then
    local pkg
    # shellcheck disable=SC2086
    for pkg in ${UPGRADE_EXCLUDE}; do
      [[ -n "$pkg" ]] || continue
      args+=(--exclude="$pkg")
      extra_excludes+=("$pkg")
    done
  fi

  echo -e "${BLUE}Applying OS updates via ${PKG} ${args[*]}${NC}"
  set +e
  "$PKG" upgrade "${args[@]}"
  local rc=$?
  set -e
  # yum/dnf historically used 100 for "nothing to do" on some check paths;
  # upgrade should be 0 on success.
  if [[ $rc -ne 0 ]]; then
    # EPEL can publish deps Alma baseos cannot satisfy yet (e.g. pyOpenSSL
    # wanting cryptography>=49 while baseos is still on 43). On Alma/DNF5,
    # --skip-broken alone may still fail; --nobest keeps the installed
    # candidate and upgrades everything else.
    if [[ "$PKG" == dnf ]]; then
      echo -e "${YELLOW}${PKG} upgrade failed (exit ${rc}); retrying with --nobest${NC}"
      log_line warn "upgrade_retry nobest=1 prior_exit=${rc}"
      set +e
      "$PKG" upgrade "${args[@]}" --nobest
      rc=$?
      set -e
    fi
  fi
  if [[ $rc -ne 0 ]]; then
    log_line error "upgrade_failed exit=${rc}"
    exit "$rc"
  fi
  if [[ ${#extra_excludes[@]} -gt 0 ]]; then
    log_line ok "upgrade_applied security_only=${SECURITY_ONLY} download_only=${DOWNLOAD_ONLY} exclude=${extra_excludes[*]}"
  else
    log_line ok "upgrade_applied security_only=${SECURITY_ONLY} download_only=${DOWNLOAD_ONLY}"
  fi
}

maybe_reboot() {
  if ! reboot_needed; then
    clear_reboot_flag_if_current
    log_line ok "reboot_required=0"
    echo -e "${GREEN}No reboot required${NC}"
    return
  fi

  mark_reboot_required "needs-restarting"

  if [[ "$AUTO_REBOOT" == "1" ]]; then
    log_line warn "auto_reboot=1 initiating reboot in 60s"
    echo -e "${YELLOW}Rebooting in 60 seconds (AUTO_REBOOT=1). Cancel with: shutdown -c${NC}"
    shutdown -r +1 "infra weekly host package upgrade requires reboot"
  else
    echo -e "${YELLOW}Reboot recommended. Flag: ${REBOOT_FLAG}${NC}"
    echo -e "${YELLOW}Or re-run with --reboot-if-needed / AUTO_REBOOT=1${NC}"
  fi
}

# --- args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) CHECK_ONLY=1 ;;
    --security-only) SECURITY_ONLY=1 ;;
    --download-only) DOWNLOAD_ONLY=1 ;;
    --reboot-if-needed) AUTO_REBOOT=1 ;;
    -h|--help|help) usage ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
  shift
done

require_root
detect_pkg
mkdir -p "$LOG_DIR" "$(dirname "$REBOOT_FLAG")"

if [[ "$CHECK_ONLY" == "1" ]]; then
  cmd_check
  exit 0
fi

pending="$(pending_count)"
log_line info "start pending≈${pending} security_only=${SECURITY_ONLY} download_only=${DOWNLOAD_ONLY} auto_reboot=${AUTO_REBOOT}"

apply_updates
# Refresh metadata-dependent reboot hint after install
maybe_reboot

echo -e "${GREEN}✓ Host package upgrade finished${NC}"
