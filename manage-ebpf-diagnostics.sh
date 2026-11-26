#!/usr/bin/env bash
# Install and use BCC / bpftrace for on-demand host latency diagnostics.
#
# Packages stay on the host for incident debugging. Optional short samples are
# on-demand only — this does not install a systemd timer.
#
# Usage:
#   sudo ./manage-ebpf-diagnostics.sh install
#   ./manage-ebpf-diagnostics.sh status
#   sudo ./manage-ebpf-diagnostics.sh sample [--seconds N]
#   ./manage-ebpf-diagnostics.sh help
#
# Environment:
#   EBPF_SAMPLE_SECONDS=30   Default sample window for `sample`
#   EBPF_LOG_DIR=/var/log/infra-ebpf-diagnostics

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=infra-env-helper.sh
source "$SCRIPT_DIR/infra-env-helper.sh"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'

PACKAGES=(bcc-tools bpftrace)
BCC_TOOLS_DIR="${BCC_TOOLS_DIR:-/usr/share/bcc/tools}"
LOG_DIR="${EBPF_LOG_DIR:-/var/log/infra-ebpf-diagnostics}"
SAMPLE_SECONDS="${EBPF_SAMPLE_SECONDS:-30}"

usage() {
  cat <<EOF
Usage: sudo $0 install
       $0 status
       sudo $0 sample [--seconds N]
       $0 help

Installs BCC tools + bpftrace for on-demand host diagnostics (no timer).

Commands:
  install   dnf install bcc-tools bpftrace (requires root)
  status    Show package/tool availability
  sample    Short block I/O + run-queue latency sample (requires root)
  help      Incident runbook (common probes)

Optional short samples are for baselines or incidents — not a weekly must-pass job.
EOF
}

require_root() {
  if [[ "${EUID:-0}" -ne 0 ]]; then
    echo -e "${RED}Error: this command requires sudo${NC}" >&2
    usage
    exit 1
  fi
}

cmd_help() {
  cat <<EOF
${BLUE}eBPF diagnostics runbook (Alma host / rootless Podman APIs)${NC}

Install once:
  sudo ./manage-ebpf-diagnostics.sh install

Quick baseline (≈30s):
  sudo ./manage-ebpf-diagnostics.sh sample
  sudo ./manage-ebpf-diagnostics.sh sample --seconds 60

When an API on :1443 / :14443 feels slow, as root:

  # Block I/O latency histogram
  ${BCC_TOOLS_DIR}/biolatency 1 10

  # CPU run-queue latency (scheduling delay)
  ${BCC_TOOLS_DIR}/runqlat 1 10

  # Who is doing disk I/O
  ${BCC_TOOLS_DIR}/biosnoop

  # New TCP connects (unexpected egress / DNS storms)
  ${BCC_TOOLS_DIR}/tcpconnect

  # Failed / interesting opens
  ${BCC_TOOLS_DIR}/opensnoop -x

  # bpftrace one-liners (if BCC script missing)
  bpftrace -e 'tracepoint:syscalls:sys_enter_connect { @[comm] = count(); }'
  bpftrace -e 'tracepoint:block:block_rq_issue { @[comm] = count(); }'

Notes:
  • Prefer short runs; leave probes attached only while investigating.
  • Samples append under ${LOG_DIR}/ when run via \`sample\`.
  • Does not replace host-uptime-prep, Trivy, or cert renew.
EOF
}

pkg_installed() {
  local pkg="$1"
  rpm -q "$pkg" &>/dev/null
}

tool_path() {
  local name="$1"
  if [[ -x "${BCC_TOOLS_DIR}/${name}" ]]; then
    echo "${BCC_TOOLS_DIR}/${name}"
    return 0
  fi
  if command -v "$name" >/dev/null 2>&1; then
    command -v "$name"
    return 0
  fi
  return 1
}

cmd_status() {
  echo -e "${BLUE}eBPF diagnostics status${NC}"
  echo ""
  echo -e "${CYAN}Packages:${NC}"
  local pkg ok=1
  for pkg in "${PACKAGES[@]}"; do
    if pkg_installed "$pkg"; then
      echo -e "  ${GREEN}✓${NC} $(rpm -q "$pkg")"
    else
      echo -e "  ${YELLOW}○${NC} $pkg not installed"
      ok=0
    fi
  done

  echo ""
  echo -e "${CYAN}Tools:${NC}"
  local tool
  for tool in biolatency runqlat biosnoop tcpconnect opensnoop bpftrace; do
    if path="$(tool_path "$tool" 2>/dev/null)"; then
      echo -e "  ${GREEN}✓${NC} $tool → $path"
    else
      echo -e "  ${YELLOW}○${NC} $tool missing"
      ok=0
    fi
  done

  echo ""
  if [[ -d "$LOG_DIR" ]]; then
    echo -e "${CYAN}Sample log dir:${NC} $LOG_DIR"
    ls -lt "$LOG_DIR" 2>/dev/null | head -n 6 || true
  else
    echo -e "${CYAN}Sample log dir:${NC} $LOG_DIR (not created yet)"
  fi

  echo ""
  if [[ "$ok" -eq 1 ]]; then
    echo -e "${GREEN}✓ Ready for on-demand probes${NC}"
    return 0
  fi
  echo -e "${YELLOW}Install with: sudo $0 install${NC}"
  return 1
}

cmd_install() {
  require_root
  echo -e "${BLUE}Installing eBPF diagnostics packages${NC}"
  echo "  ${PACKAGES[*]}"
  dnf install -y "${PACKAGES[@]}"
  echo ""
  cmd_status || true
  echo ""
  echo -e "${GREEN}✓ Packages installed (no timer — use sample/help on demand)${NC}"
}

run_timed() {
  local label="$1"
  local seconds="$2"
  shift 2
  local out="$1"
  shift

  echo -e "${YELLOW}→ ${label} (${seconds}s)${NC}" | tee -a "$out"
  if ! command -v timeout >/dev/null 2>&1; then
    echo "timeout(1) required" | tee -a "$out" >&2
    return 1
  fi
  # BCC histogram tools often take interval + count; prefer their own duration
  # when the binary supports interval/count. Otherwise wrap with timeout.
  set +e
  timeout --signal=INT --kill-after=5 "${seconds}s" "$@" >>"$out" 2>&1
  local rc=$?
  set -e
  # 124 = timeout killed; 130 = SIGINT — both OK for a bounded sample
  if [[ "$rc" -eq 0 || "$rc" -eq 124 || "$rc" -eq 130 ]]; then
    echo -e "${GREEN}✓ ${label} finished${NC}" | tee -a "$out"
    return 0
  fi
  echo -e "${YELLOW}⚠ ${label} exited rc=${rc}${NC}" | tee -a "$out"
  return 0
}

cmd_sample() {
  require_root
  local seconds="$SAMPLE_SECONDS"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --seconds)
        [[ $# -ge 2 ]] || { echo "--seconds needs a value" >&2; exit 1; }
        seconds="$2"
        shift 2
        ;;
      --seconds=*)
        seconds="${1#*=}"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown option: $1" >&2
        usage
        exit 1
        ;;
    esac
  done

  if ! [[ "$seconds" =~ ^[1-9][0-9]*$ ]] || [[ "$seconds" -gt 600 ]]; then
    echo -e "${RED}Error: --seconds must be 1–600 (got: ${seconds})${NC}" >&2
    exit 1
  fi

  local missing=0
  local pkg
  for pkg in "${PACKAGES[@]}"; do
    if ! pkg_installed "$pkg"; then
      echo -e "${RED}Missing package: $pkg${NC}" >&2
      missing=1
    fi
  done
  if [[ "$missing" -eq 1 ]]; then
    echo -e "${YELLOW}Run: sudo $0 install${NC}" >&2
    exit 1
  fi

  install -d -m 0755 -o root -g root "$LOG_DIR"
  local stamp out
  stamp="$(date -u +%Y%m%d_%H%M%S)"
  out="${LOG_DIR}/sample-${stamp}.txt"

  {
    echo "=== eBPF host latency sample ==="
    echo "ts_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "host=$(hostname -f 2>/dev/null || hostname)"
    echo "seconds=${seconds}"
    echo "kernel=$(uname -r)"
    echo ""
  } | tee "$out"

  local biolatency runqlat
  biolatency="$(tool_path biolatency)" || biolatency=""
  runqlat="$(tool_path runqlat)" || runqlat=""

  # biolatency / runqlat: interval_sec count → roughly `seconds` of output
  if [[ -n "$biolatency" ]]; then
    run_timed "biolatency (block I/O)" "$seconds" "$out" \
      "$biolatency" 1 "$seconds"
  else
    echo -e "${YELLOW}○ biolatency not found; bpftrace block_rq_issue counts${NC}" | tee -a "$out"
    run_timed "bpftrace block_rq_issue" "$seconds" "$out" \
      bpftrace -e "tracepoint:block:block_rq_issue { @[comm] = count(); }"
  fi

  echo "" | tee -a "$out"

  if [[ -n "$runqlat" ]]; then
    run_timed "runqlat (CPU sched delay)" "$seconds" "$out" \
      "$runqlat" 1 "$seconds"
  else
    echo -e "${YELLOW}○ runqlat not found; skipping${NC}" | tee -a "$out"
  fi

  {
    echo ""
    echo "=== sample complete ==="
    echo "report=${out}"
  } | tee -a "$out"

  # Append index line for quick grepping
  printf '%s seconds=%s file=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$seconds" "$out" >>"${LOG_DIR}/samples.log"
  chmod 0644 "$out" "${LOG_DIR}/samples.log" 2>/dev/null || true

  echo ""
  echo -e "${GREEN}✓ Sample written to ${out}${NC}"
  echo -e "${CYAN}Incident tips: $0 help${NC}"
}

main() {
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    install) cmd_install "$@" ;;
    status) cmd_status "$@" ;;
    sample) cmd_sample "$@" ;;
    help|-h|--help) cmd_help ;;
    "") usage; exit 1 ;;
    *)
      echo -e "${RED}Unknown command: $cmd${NC}" >&2
      usage
      exit 1
      ;;
  esac
}

main "$@"
