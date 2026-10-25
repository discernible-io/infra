#!/usr/bin/env bash
# Restrict inbound TCP to public/admin ports from infra-env-helper.sh.
# API ports in INFRA_PUBLIC_API_TCP_PORTS are open; INFRA_BLOCKED_PUBLIC_TCP_PORTS may add exceptions.
# Traffic redirected via INFRA_PORT_FORWARD_* / INFRA_EXTRA_PORT_FORWARDS is allowed via ctorigdstport.
#
# Usage:
#   sudo ./configure-host-firewall-oneoff.sh enable [permanent]
#   sudo ./configure-host-firewall-oneoff.sh disable [permanent]
#   sudo ./configure-host-firewall-oneoff.sh status
#   sudo ./configure-host-firewall-oneoff.sh allow-http-temporary   # certbot standalone (:80)
#   sudo ./configure-host-firewall-oneoff.sh deny-http-temporary
#
# Requires firewalld disabled (same as configure-port-forwarding-oneoff.sh).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=infra-env-helper.sh
source "$SCRIPT_DIR/infra-env-helper.sh"
# shellcheck source=infra-iptables-helper.sh
source "$SCRIPT_DIR/infra-iptables-helper.sh"

CHAIN_NAME=INFRA_HOST_FW
INPUT_JUMP_COMMENT="infra-host-firewall"
STATE_DIR=/var/lib/infra
HTTP_FLAG_FILE="$STATE_DIR/allow-http-temporary"

ACTION=${1:-status}
MODE=${2:-temporary}

show_usage() {
  cat <<EOF
Usage: $0 <action> [permanent|temporary]

Actions:
  enable              Allow only admin + public TCP ports (see infra-env-helper.sh)
  disable             Remove firewall chain/jump
  status              Show chain and allowed/blocked ports (default)
  allow-http-temporary  Also allow inbound TCP 80 (Let's Encrypt standalone)
  deny-http-temporary   Remove temporary TCP 80 allow

Public TCP:   ${INFRA_PUBLIC_TCP_PORTS[*]}
Admin TCP:    ${INFRA_ADMIN_TCP_PORTS[*]}
Local-only TCP: ${INFRA_LOCAL_ONLY_TCP_PORTS[*]:-(none)} (from ${INFRA_LOCAL_ONLY_ALLOW_CIDRS[*]:-169.254.0.0/16})
443 redirect: ${INFRA_PORT_FORWARD_DEST:-?} (${INFRA_PORT_FORWARD_SERVICE:-unset})
Extra REDIRECTs: ${INFRA_EXTRA_PORT_FORWARDS[*]:-(none)}
Blocked TCP:  ${INFRA_BLOCKED_PUBLIC_TCP_PORTS[*]}

Example:
  sudo $0 enable permanent
EOF
}

infra_allowed_tcp_ports() {
  local -a ports=()
  local -A seen=()
  local p
  ports+=("${INFRA_ADMIN_TCP_PORTS[@]}")
  mapfile -t _infra_public_ports < <(infra_effective_public_tcp_ports)
  ports+=("${_infra_public_ports[@]}")
  if [[ -f "$HTTP_FLAG_FILE" ]]; then
    ports+=(80)
  fi
  # Deduplicate while preserving order (allow-http-temporary must not double-count 80
  # when it is already in INFRA_PUBLIC_TCP_PORTS).
  for p in "${ports[@]}"; do
    [[ -n "$p" ]] || continue
    if [[ -n "${seen[$p]:-}" ]]; then
      continue
    fi
    seen["$p"]=1
    printf '%s\n' "$p"
  done
}

# iptables multiport accepts at most 15 ports per rule.
add_multiport_accept_rules() {
  local -a ports=("$@")
  local -a chunk=()
  local p csv
  local max=15

  for p in "${ports[@]}"; do
    [[ -n "$p" ]] || continue
    chunk+=("$p")
    if [[ ${#chunk[@]} -ge $max ]]; then
      csv="$(build_multiport_dports "${chunk[@]}")"
      iptables -A "$CHAIN_NAME" -p tcp -m conntrack --ctstate NEW -m multiport --dports "$csv" -j ACCEPT
      chunk=()
    fi
  done
  if [[ ${#chunk[@]} -gt 0 ]]; then
    csv="$(build_multiport_dports "${chunk[@]}")"
    iptables -A "$CHAIN_NAME" -p tcp -m conntrack --ctstate NEW -m multiport --dports "$csv" -j ACCEPT
  fi
}

infra_add_monitoring_cidr_rules() {
  local port cidr
  local -a cidrs=()
  mapfile -t cidrs < <(infra_monitoring_allow_cidrs)
  for port in "${INFRA_MONITORING_TCP_PORTS[@]}"; do
    [[ -n "$port" ]] || continue
    for cidr in "${cidrs[@]}"; do
      [[ -n "$cidr" ]] || continue
      # iptables is IPv4-only; skip IPv6 CIDRs (e.g. ::1/128).
      [[ "$cidr" == *:* ]] && continue
      iptables -A "$CHAIN_NAME" -p tcp --dport "$port" -s "$cidr" \
        -m conntrack --ctstate NEW -j ACCEPT
    done
  done
}

# Allow host-published ports (e.g. Postgres) only from pasta/link-local clients.
infra_add_local_only_port_rules() {
  local port cidr
  local -a cidrs=()
  mapfile -t cidrs < <(infra_local_only_allow_cidrs)
  for port in "${INFRA_LOCAL_ONLY_TCP_PORTS[@]}"; do
    [[ -n "$port" ]] || continue
    for cidr in "${cidrs[@]}"; do
      [[ -n "$cidr" ]] || continue
      [[ "$cidr" == *:* ]] && continue
      iptables -A "$CHAIN_NAME" -p tcp --dport "$port" -s "$cidr" \
        -m conntrack --ctstate NEW -j ACCEPT
    done
  done
}

iptables_chain_exists() {
  iptables -nL "$CHAIN_NAME" &>/dev/null
}

iptables_input_jump_exists() {
  iptables -C INPUT -j "$CHAIN_NAME" &>/dev/null 2>&1
}

remove_firewall_rules() {
  while iptables_input_jump_exists; do
    iptables -D INPUT -j "$CHAIN_NAME" 2>/dev/null || break
  done
  if iptables_chain_exists; then
    iptables -F "$CHAIN_NAME" 2>/dev/null || true
    iptables -X "$CHAIN_NAME" 2>/dev/null || true
  fi
}

build_multiport_dports() {
  local -a ports=("$@")
  local joined=""
  local p
  for p in "${ports[@]}"; do
    [[ -n "$p" ]] || continue
    if [[ -n "$joined" ]]; then
      joined+=","
    fi
    joined+="$p"
  done
  printf '%s' "$joined"
}

infra_add_blocked_api_port_rules() {
  local port src dest
  local -A redirect_sources_by_dest=()
  local fwd="${INFRA_PORT_FORWARD_DEST:-}"
  local fwd_src="${INFRA_PORT_FORWARD_SOURCE:-443}"

  if [[ -n "$fwd" ]]; then
    redirect_sources_by_dest["$fwd"]="$fwd_src"
  fi
  if declare -F infra_iter_extra_port_forwards &>/dev/null; then
    while read -r src dest; do
      [[ -n "$src" && -n "$dest" ]] || continue
      if [[ -n "${redirect_sources_by_dest[$dest]:-}" ]]; then
        redirect_sources_by_dest["$dest"]+=",$src"
      else
        redirect_sources_by_dest["$dest"]="$src"
      fi
    done < <(infra_iter_extra_port_forwards)
  fi

  for port in "${INFRA_BLOCKED_PUBLIC_TCP_PORTS[@]}"; do
    [[ -n "$port" ]] || continue
    if [[ -n "${redirect_sources_by_dest[$port]:-}" ]]; then
      # Allow REDIRECT from configured source port(s); drop direct NEW to that port.
      IFS=',' read -r -a _redir_srcs <<< "${redirect_sources_by_dest[$port]}"
      for src in "${_redir_srcs[@]}"; do
        [[ -n "$src" ]] || continue
        iptables -A "$CHAIN_NAME" -p tcp --dport "$port" \
          -m conntrack --ctstate NEW --ctorigdstport "$src" -j ACCEPT
      done
      iptables -A "$CHAIN_NAME" -p tcp --dport "$port" \
        -m conntrack --ctstate NEW -j DROP
      continue
    fi
    iptables -A "$CHAIN_NAME" -p tcp --dport "$port" \
      -m conntrack --ctstate NEW -j DROP
  done
}

add_firewall_rules() {
  local -a allowed=()
  mapfile -t allowed < <(infra_allowed_tcp_ports)

  remove_firewall_rules
  iptables -N "$CHAIN_NAME"
  iptables -I INPUT 1 -j "$CHAIN_NAME"

  iptables -A "$CHAIN_NAME" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  iptables -A "$CHAIN_NAME" -i lo -j ACCEPT

  if [[ ${#allowed[@]} -gt 0 ]]; then
    add_multiport_accept_rules "${allowed[@]}"
  fi

  if infra_monitoring_restrict_enabled; then
    infra_add_monitoring_cidr_rules
  fi

  infra_add_local_only_port_rules

  infra_add_blocked_api_port_rules

  # Drop other new inbound TCP (public surface = allowed list only).
  iptables -A "$CHAIN_NAME" -p tcp -m conntrack --ctstate NEW -j DROP
  iptables -A "$CHAIN_NAME" -j RETURN

  echo "Host firewall enabled."
  echo "  Allowed inbound TCP: ${allowed[*]}"
  if infra_monitoring_restrict_enabled; then
    echo "  Monitoring ports (${INFRA_MONITORING_TCP_PORTS[*]}) restricted to allowlisted CIDRs"
  fi
  if [[ ${#INFRA_LOCAL_ONLY_TCP_PORTS[@]} -gt 0 ]]; then
    echo "  Local-only TCP:      ${INFRA_LOCAL_ONLY_TCP_PORTS[*]} (from $(infra_local_only_allow_cidrs | paste -sd, -))"
  fi
  echo "  443 REDIRECT target: ${INFRA_PORT_FORWARD_DEST:-?} (${INFRA_PORT_FORWARD_SERVICE:-unset})"
  if [[ ${#INFRA_EXTRA_PORT_FORWARDS[@]} -gt 0 ]]; then
    echo "  Extra REDIRECTs:     ${INFRA_EXTRA_PORT_FORWARDS[*]}"
  fi
  echo "  Blocked API ports:   ${INFRA_BLOCKED_PUBLIC_TCP_PORTS[*]}"
}

cmd_status() {
  echo "Host firewall status"
  echo "===================="
  echo "Public TCP:   ${INFRA_PUBLIC_TCP_PORTS[*]}"
  echo "Admin TCP:    ${INFRA_ADMIN_TCP_PORTS[*]}"
  echo "Local-only TCP: ${INFRA_LOCAL_ONLY_TCP_PORTS[*]:-(none)} (from ${INFRA_LOCAL_ONLY_ALLOW_CIDRS[*]:-169.254.0.0/16})"
  echo "443 redirect: ${INFRA_PORT_FORWARD_DEST:-?} (${INFRA_PORT_FORWARD_SERVICE:-unset})"
  if [[ ${#INFRA_EXTRA_PORT_FORWARDS[@]} -gt 0 ]]; then
    echo "Extra REDIRECTs: ${INFRA_EXTRA_PORT_FORWARDS[*]}"
  fi
  echo "Blocked TCP:  ${INFRA_BLOCKED_PUBLIC_TCP_PORTS[*]}"
  if [[ -f "$HTTP_FLAG_FILE" ]]; then
    echo "HTTP temporary allow: yes (port 80)"
  else
    echo "HTTP temporary allow: no"
  fi
  echo ""
  if systemctl is-active --quiet firewalld 2>/dev/null; then
    echo "Warning: firewalld is active — these rules may not apply as expected."
    echo ""
  fi
  if iptables_chain_exists; then
    iptables -L "$CHAIN_NAME" -n -v --line-numbers
  else
    echo "Chain $CHAIN_NAME is not configured."
  fi
}

require_root() {
  if [[ "${EUID:-0}" -ne 0 ]]; then
    echo "Error: run as root (sudo $0 ...)" >&2
    exit 1
  fi
}

maybe_save() {
  if [[ "${MODE:-}" == "permanent" ]]; then
    mkdir -p "$STATE_DIR"
    infra_iptables_save_permanent
    echo "Rules saved permanently (/etc/sysconfig/iptables)."
  fi
}

case "$ACTION" in
  status)
    cmd_status
    exit 0
    ;;
  enable|disable|allow-http-temporary|deny-http-temporary)
    ;;
  *)
    echo "Error: unknown action '$ACTION'" >&2
    show_usage
    exit 1
    ;;
esac

if [[ "$ACTION" == "enable" || "$ACTION" == "disable" ]] && [[ "$MODE" != "permanent" && "$MODE" != "temporary" ]]; then
  echo "Error: mode must be 'permanent' or 'temporary'" >&2
  exit 1
fi

require_root

if [[ "$ACTION" == "enable" ]]; then
  infra_switch_from_firewalld_to_iptables
elif ! infra_assert_firewalld_inactive; then
  exit 1
fi

case "$ACTION" in
  enable)
    add_firewall_rules
    maybe_save
    ;;
  disable)
    remove_firewall_rules
    maybe_save
    echo "Host firewall disabled."
    ;;
  allow-http-temporary)
    mkdir -p "$STATE_DIR"
    touch "$HTTP_FLAG_FILE"
    if iptables_chain_exists; then
      add_firewall_rules
      maybe_save
    else
      echo "Created $HTTP_FLAG_FILE — run '$0 enable permanent' to apply."
    fi
    ;;
  deny-http-temporary)
    rm -f "$HTTP_FLAG_FILE"
    if iptables_chain_exists; then
      add_firewall_rules
      maybe_save
    else
      echo "Removed temporary HTTP allow flag."
    fi
    ;;
esac

if iptables_chain_exists; then
  echo ""
  iptables -L "$CHAIN_NAME" -n -v --line-numbers
fi

exit 0
