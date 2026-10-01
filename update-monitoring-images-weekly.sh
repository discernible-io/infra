#!/usr/bin/env bash
# Rebuild and redeploy the Grafana/Loki monitoring stack when local images
# are old enough (default: at least 3 days). Intended for weekly systemd timer.
#
# Usage:
#   ./update-monitoring-images-weekly.sh           # age gate + pull + deploy
#   ./update-monitoring-images-weekly.sh --check   # report ages only
#   ./update-monitoring-images-weekly.sh --force   # ignore min age
#
# Environment:
#   MIN_IMAGE_AGE_DAYS=3     Skip when all local Grafana/Loki images are newer
#   MONITORING_GIT_PULL=1    ff-only pull grafanaloki-app before deploy (default 0)
#   INFRA_MONITORING_APP_DIR Override path (default: $INFRA_HOME/grafanaloki-app)
#
# Install timer via: sudo ./manage-weekly-maintenance.sh install

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=infra-env-helper.sh
source "$SCRIPT_DIR/infra-env-helper.sh"
# shellcheck source=infra-podman-helper.sh
source "$SCRIPT_DIR/infra-podman-helper.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

APP_DIR="${INFRA_MONITORING_APP_DIR:-${INFRA_HOME}/grafanaloki-app}"
DEPLOY_SCRIPT="${INFRA_MONITORING_DEPLOY_SCRIPT:-${APP_DIR}/deploy-monitoring.sh}"
MIN_IMAGE_AGE_DAYS="${MIN_IMAGE_AGE_DAYS:-3}"
MONITORING_GIT_PULL="${MONITORING_GIT_PULL:-0}"
RUN_AS="${MONITOR_USER:-$INFRA_USER}"

LOG_DIR="${INFRA_MONITORING_UPDATE_LOG_DIR:-${INFRA_APP_DIR}/monitoring-image-update}"
RUN_LOG="${LOG_DIR}/runs.log"

CHECK_ONLY=0
FORCE=0

usage() {
  cat <<EOF
Usage: $0 [--check|--force]

  (default)  Pull upstream bases (must be ≥ ${MIN_IMAGE_AGE_DAYS}d old), rebuild
             hardened Grafana/Loki images, and run deploy-monitoring.sh when local
             images are missing or ≥ ${MIN_IMAGE_AGE_DAYS} days old.
  --check    Report image ages and planned action only
  --force    Rebuild/redeploy even if local images are newer than the age gate

Env: MIN_IMAGE_AGE_DAYS (default ${MIN_IMAGE_AGE_DAYS}), MONITORING_GIT_PULL=1
Logs: $RUN_LOG
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage ;;
    --check) CHECK_ONLY=1 ;;
    --force) FORCE=1 ;;
    *) echo -e "${RED}Unknown option: $1${NC}" >&2; usage ;;
  esac
  shift
done

log_line() {
  local level="$1"
  shift
  local msg="$*"
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  mkdir -p "$LOG_DIR"
  printf '%s [%s] %s\n' "$ts" "$level" "$msg" | tee -a "$RUN_LOG"
}

run_podman() {
  infra_run_as_user "$RUN_AS" podman "$@"
}

# Print Created timestamp (unix epoch) for a local image, or empty if missing.
image_created_epoch() {
  local ref="$1"
  local created
  created="$(run_podman image inspect -f '{{.Created}}' "$ref" 2>/dev/null || true)"
  if [[ -z "$created" ]]; then
    # Podman often stores local builds under localhost/
    created="$(run_podman image inspect -f '{{.Created}}' "localhost/${ref}" 2>/dev/null || true)"
  fi
  [[ -n "$created" ]] || return 1
  created_to_epoch "$created"
}

# Normalize Podman Created strings (nanoseconds / "+0000 UTC") for GNU date.
created_to_epoch() {
  local created="$1"
  local re_space='^([0-9]{4}-[0-9]{2}-[0-9]{2}) ([0-9]{2}:[0-9]{2}:[0-9]{2})'
  local re_iso='^([0-9]{4}-[0-9]{2}-[0-9]{2})T([0-9]{2}:[0-9]{2}:[0-9]{2})'
  if [[ "$created" =~ $re_space ]]; then
    created="${BASH_REMATCH[1]}T${BASH_REMATCH[2]}Z"
  elif [[ "$created" =~ $re_iso ]]; then
    created="${BASH_REMATCH[1]}T${BASH_REMATCH[2]}Z"
  fi
  date -d "$created" +%s 2>/dev/null || date -u -d "$created" +%s 2>/dev/null
}

image_age_days() {
  local epoch="$1"
  local now
  now="$(date +%s)"
  echo $(( (now - epoch) / 86400 ))
}

load_monitoring_env() {
  if [[ ! -f "${APP_DIR}/.env" ]]; then
    echo -e "${RED}Missing ${APP_DIR}/.env — monitoring stack not configured on this host${NC}" >&2
    exit 1
  fi
  set -a
  # shellcheck disable=SC1091
  source "${APP_DIR}/.env"
  set +a
  if [[ -z "${GRAFANA_IMAGE:-}" || -z "${LOKI_IMAGE:-}" ]]; then
    echo -e "${RED}.env must set GRAFANA_IMAGE and LOKI_IMAGE${NC}" >&2
    exit 1
  fi
}

# True if image is missing or age_days >= MIN_IMAGE_AGE_DAYS.
image_needs_update() {
  local ref="$1"
  local epoch age
  if ! epoch="$(image_created_epoch "$ref")"; then
    echo -e "  ${YELLOW}${ref}: not present locally (will build)${NC}"
    return 0
  fi
  age="$(image_age_days "$epoch")"
  echo -e "  ${ref}: ${age}d old (created $(date -u -d "@${epoch}" +%Y-%m-%dT%H:%MZ))"
  (( age >= MIN_IMAGE_AGE_DAYS ))
}

# Pull upstream and require Created age >= MIN_IMAGE_AGE_DAYS (soak / avoid brand-new).
pull_upstream_if_old_enough() {
  local ref="$1"
  local epoch age
  echo -e "${BLUE}→ Pulling upstream ${ref}${NC}"
  if ! run_podman pull "$ref"; then
    echo -e "${RED}Failed to pull ${ref}${NC}" >&2
    return 1
  fi
  epoch="$(run_podman image inspect -f '{{.Created}}' "$ref")"
  epoch="$(created_to_epoch "$epoch")"
  age="$(image_age_days "$epoch")"
  echo -e "  upstream ${ref}: ${age}d old"
  if (( age < MIN_IMAGE_AGE_DAYS )); then
    echo -e "${YELLOW}Upstream ${ref} is only ${age}d old (need ≥ ${MIN_IMAGE_AGE_DAYS}d) — skipping update${NC}"
    return 2
  fi
  return 0
}

maybe_git_pull() {
  if [[ "$MONITORING_GIT_PULL" != "1" ]]; then
    return 0
  fi
  if [[ ! -d "${APP_DIR}/.git" ]]; then
    echo -e "${YELLOW}MONITORING_GIT_PULL=1 but ${APP_DIR} is not a git repo — skipping pull${NC}"
    return 0
  fi
  echo -e "${BLUE}→ git pull --ff-only in ${APP_DIR}${NC}"
  infra_run_as_user "$RUN_AS" git -C "$APP_DIR" pull --ff-only
}

main() {
  echo -e "${BLUE}Monitoring image update (min age ${MIN_IMAGE_AGE_DAYS}d)${NC}"

  if [[ ! -x "$DEPLOY_SCRIPT" && ! -f "$DEPLOY_SCRIPT" ]]; then
    echo -e "${YELLOW}No deploy script at ${DEPLOY_SCRIPT} — nothing to do on this host${NC}"
    log_line SKIP "no deploy script"
    exit 0
  fi

  load_monitoring_env

  local grafana_tag loki_tag
  grafana_tag="${GRAFANA_IMAGE##*:}"
  loki_tag="${LOKI_IMAGE##*:}"

  local needs=0
  echo -e "${CYAN}Local image ages:${NC}"
  if image_needs_update "$GRAFANA_IMAGE"; then needs=1; fi
  if image_needs_update "$LOKI_IMAGE"; then needs=1; fi

  if (( FORCE )); then
    needs=1
    echo -e "${YELLOW}--force: ignoring local age gate${NC}"
  fi

  if (( ! needs )); then
    echo -e "${GREEN}All local Grafana/Loki images are newer than ${MIN_IMAGE_AGE_DAYS}d — skip${NC}"
    log_line SKIP "local images younger than ${MIN_IMAGE_AGE_DAYS}d"
    exit 0
  fi

  if (( CHECK_ONLY )); then
    echo -e "${YELLOW}--check: would pull upstream bases and run ${DEPLOY_SCRIPT}${NC}"
    exit 0
  fi

  local rc=0
  pull_upstream_if_old_enough "docker.io/grafana/grafana:${grafana_tag}" || rc=$?
  if (( rc == 2 )); then
    log_line SKIP "upstream grafana too new"
    exit 0
  elif (( rc != 0 )); then
    log_line FAIL "pull grafana"
    exit "$rc"
  fi

  rc=0
  pull_upstream_if_old_enough "docker.io/grafana/loki:${loki_tag}" || rc=$?
  if (( rc == 2 )); then
    log_line SKIP "upstream loki too new"
    exit 0
  elif (( rc != 0 )); then
    log_line FAIL "pull loki"
    exit "$rc"
  fi

  maybe_git_pull

  echo -e "${BLUE}→ Deploying via ${DEPLOY_SCRIPT}${NC}"
  if ! infra_run_as_user "$RUN_AS" bash "$DEPLOY_SCRIPT"; then
    log_line FAIL "deploy-monitoring.sh"
    exit 1
  fi

  log_line OK "rebuilt ${GRAFANA_IMAGE} ${LOKI_IMAGE}"
  echo -e "${GREEN}✓ Monitoring images updated and pod redeployed${NC}"
}

main
