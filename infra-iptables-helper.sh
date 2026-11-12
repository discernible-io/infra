#!/usr/bin/env bash
# Shared iptables helpers (source only).
#
# Public surface is managed with INFRA_HOST_FW + NAT REDIRECT.
# Live port/domain lists come from infra-env-helper.sh on each host.
# Reference layout for a multi-service host:
#
#   Domain                      Port   Service / notes
#   ---------------------------  -----  ------------------------------------------
#   root.discernible.io          6443   mintroot API
#   identyclaw.discernible.io    2443   mintserver API
#   purchase.identyclaw.com      4443   mintclient API (443→4443 REDIRECT)
#   andrew|joe|daniel.dihola.io  8443   openclaw-agents shared nginx (Telegram-compatible)
#   identyclaw-concierge.identyclaw.com 8443  same OpenClaw ingress (SNI)
#   grafana46.discernible.io     3335   Grafana (+ 3100 Loki)
#   (retired on this host: 88, 7443 — explicit DROP in INFRA_BLOCKED_PUBLIC_TCP_PORTS)
#
# Alternate IC + agents + SLC layout:
#
#   api.dihola.io                5443   idclawserver API
#   root.dihola.io               6443   mintroot API
#   identyclaw.dihola.io         2443   mintserver API
#   andrew|joe|daniel.dihola.io  88     openclaw agents (shared nginx SNI; Telegram-compatible)
#   hermes (HERMES_PUBLIC_HOST) 11443   hermes webhook ingress (API 11642 / dash 11919 local)
#   api.lastcradle.io           13443   slcbackend / SLC production (443→13443 REDIRECT)
#   grafana47.dihola.io          3333   Grafana (+ 3100 Loki, CIDR-restricted)
#
#   Admin: 22 (SSH). Certbot HTTP-01: temporary TCP 80 via
#   configure-host-firewall-oneoff.sh allow-http-temporary.
#   Extra tenant ports come from the host profile (INFRA_API_PORTS /
#   INFRA_BLOCKED_PUBLIC_TCP_PORTS), not from this comment block.
#
# Scripts: configure-host-firewall-oneoff.sh (allowlist), configure-port-forwarding-oneoff.sh
# (443→INFRA_PORT_FORWARD_DEST from infra-app), setup-host-oneoff.sh.

infra_assert_firewalld_inactive() {
  if [[ "${ALLOW_FIREWALLD:-}" == "1" ]]; then
    return 0
  fi
  if systemctl is-active --quiet firewalld 2>/dev/null; then
    echo "Error: firewalld is active; stop it before using raw iptables rules:" >&2
    echo "  sudo systemctl disable --now firewalld" >&2
    return 1
  fi
}

infra_ensure_iptables_services() {
  if command -v dnf &>/dev/null; then
    dnf install -y iptables-services &>/dev/null || true
  fi
  if systemctl list-unit-files iptables.service &>/dev/null 2>&1; then
    systemctl enable iptables &>/dev/null || true
    systemctl start iptables &>/dev/null || true
  fi
}

# Prefer raw iptables (INFRA_HOST_FW + REDIRECT). Certbot may enable firewalld for :80/:443.
infra_switch_from_firewalld_to_iptables() {
  if systemctl is-active --quiet firewalld 2>/dev/null; then
    echo "Disabling firewalld (iptables rules required)..."
    systemctl disable --now firewalld
  fi
  infra_ensure_iptables_services
}

infra_load_env_if_needed() {
  if [[ -n "${INFRA_ENV_LOADED:-}" ]]; then
    return 0
  fi
  local dir
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -f "${dir}/infra-env-helper.sh" ]]; then
    # shellcheck source=infra-env-helper.sh
    source "${dir}/infra-env-helper.sh"
  fi
}

infra_port_forward_configured() {
  infra_load_env_if_needed
  [[ -n "${INFRA_PORT_FORWARD_DEST:-}" || -n "${INFRA_PORT_FORWARD_SERVICE:-}" ]] \
    || [[ ${#INFRA_EXTRA_PORT_FORWARDS[@]} -gt 0 ]]
}

infra_resolve_port_forward_dest() {
  local dest="${INFRA_PORT_FORWARD_DEST:-}"
  infra_load_env_if_needed
  if [[ -z "$dest" && -n "${INFRA_PORT_FORWARD_SERVICE:-}" ]]; then
    dest="${INFRA_API_PORTS[$INFRA_PORT_FORWARD_SERVICE]:-}"
  fi
  if [[ -z "$dest" ]]; then
    return 1
  fi
  if declare -F infra_resolve_api_port &>/dev/null; then
    if resolved="$(infra_resolve_api_port "$dest" 2>/dev/null)"; then
      dest="$resolved"
    fi
  fi
  if [[ ! "$dest" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  printf '%s' "$dest"
}

# Print "source dest" lines for INFRA_EXTRA_PORT_FORWARDS (source:dest|service).
infra_iter_extra_port_forwards() {
  local entry src dest resolved
  infra_load_env_if_needed
  for entry in ${INFRA_EXTRA_PORT_FORWARDS[@]+"${INFRA_EXTRA_PORT_FORWARDS[@]}"}; do
    [[ -n "$entry" ]] || continue
    src="${entry%%:*}"
    dest="${entry#*:}"
    [[ "$src" != "$entry" && -n "$src" && -n "$dest" ]] || continue
    if declare -F infra_resolve_api_port &>/dev/null; then
      if resolved="$(infra_resolve_api_port "$dest" 2>/dev/null)"; then
        dest="$resolved"
      fi
    fi
    [[ "$src" =~ ^[0-9]+$ && "$dest" =~ ^[0-9]+$ ]] || continue
    printf '%s %s\n' "$src" "$dest"
  done
}

infra_global_ipv4_addrs() {
  ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1
}

infra_iptables_nat_rule_exists() {
  iptables -t nat -C "$@" 2>/dev/null
}

infra_iptables_nat_add_unique() {
  if infra_iptables_nat_rule_exists "$@"; then
    return 0
  fi
  iptables -t nat -A "$@"
}

infra_apply_port_forward() {
  local source_port="${1:-443}"
  local dest_port="$2"
  [[ "$dest_port" =~ ^[0-9]+$ ]] || return 1

  # Drop any prior redirect for this external port (e.g. 443→5443 before 443→13443).
  infra_purge_nat_redirects_for_source "$source_port"

  infra_iptables_nat_add_unique PREROUTING -p tcp --dport "$source_port" -j REDIRECT --to-port "$dest_port"
  infra_iptables_nat_add_unique OUTPUT -p tcp -d 127.0.0.1 --dport "$source_port" -j REDIRECT --to-port "$dest_port"
  local ip
  while IFS= read -r ip; do
    [[ -n "$ip" ]] || continue
    infra_iptables_nat_add_unique OUTPUT -p tcp -d "$ip" --dport "$source_port" -j REDIRECT --to-port "$dest_port"
  done < <(infra_global_ipv4_addrs)

  if command -v ip6tables &>/dev/null && [[ -r /proc/net/if_inet6 ]]; then
    if ! ip6tables -t nat -C OUTPUT -p tcp -d ::1 --dport "$source_port" -j REDIRECT --to-port "$dest_port" 2>/dev/null; then
      ip6tables -t nat -A OUTPUT -p tcp -d ::1 --dport "$source_port" -j REDIRECT --to-port "$dest_port" 2>/dev/null \
        || true
    fi
  fi
}

infra_ensure_extra_port_forward_rules() {
  local src dest
  while read -r src dest; do
    [[ -n "$src" && -n "$dest" ]] || continue
    infra_apply_port_forward "$src" "$dest"
  done < <(infra_iter_extra_port_forwards)
}

# Drop stale REDIRECTs whose source port is now a direct INFRA_API_PORTS listen
# (and is not still listed as an INFRA_EXTRA_PORT_FORWARDS source).
# Example: after moving :7443 from Olivia alias → api-test-scaffold, purge 7443→10443.
infra_reconcile_stale_api_port_redirects() {
  local port src dest
  declare -A extra_sources=()
  while read -r src dest; do
    [[ -n "$src" ]] || continue
    extra_sources["$src"]=1
  done < <(infra_iter_extra_port_forwards)

  for port in ${INFRA_API_PORTS[@]+"${INFRA_API_PORTS[@]}"}; do
    [[ -n "$port" ]] || continue
    [[ -z "${extra_sources[$port]:-}" ]] || continue
    infra_purge_nat_redirects_for_source "$port"
  done
}

infra_ensure_port_forward_rules() {
  local source_port="${INFRA_PORT_FORWARD_SOURCE:-443}"
  local dest_port
  if dest_port="$(infra_resolve_port_forward_dest)"; then
    infra_apply_port_forward "$source_port" "$dest_port"
  fi
  infra_reconcile_stale_api_port_redirects
  infra_ensure_extra_port_forward_rules
}

infra_normalize_saved_iptables() {
  if [[ ! -f /etc/sysconfig/iptables ]]; then
    return 0
  fi
  # iptables-save on some hosts glues tokens (REDIRECT--to-ports, multiport--dports).
  sed -i \
    -e 's/REDIRECT--to-ports/REDIRECT --to-ports/g' \
    -e 's/multiport--dports/multiport --dports/g' \
    -e 's/conntrack--ctstate/conntrack --ctstate/g' \
    /etc/sysconfig/iptables
}

# Remove every NAT REDIRECT whose match dport is source_port (any --to-port).
# Needed when switching 443→5443 to 443→13443 so the old rule does not win first-match.
infra_purge_nat_redirects_for_source() {
  local source_port="$1"
  local chain num
  for chain in PREROUTING OUTPUT; do
    while true; do
      num="$(iptables -t nat -L "$chain" -n --line-numbers 2>/dev/null \
        | awk -v p="$source_port" '
            $0 ~ /REDIRECT/ && $0 ~ ("dpt:" p "([[:space:]]|$)") { print $1; exit }
          ')"
      [[ -n "$num" ]] || break
      iptables -t nat -D "$chain" "$num" || break
    done
  done
  if command -v ip6tables &>/dev/null; then
    while true; do
      num="$(ip6tables -t nat -L OUTPUT -n --line-numbers 2>/dev/null \
        | awk -v p="$source_port" '
            $0 ~ /REDIRECT/ && $0 ~ ("dpt:" p "([[:space:]]|$)") { print $1; exit }
          ')"
      [[ -n "$num" ]] || break
      ip6tables -t nat -D OUTPUT "$num" || break
    done
  fi
}

# Remove every matching NAT REDIRECT for source_port -> dest_port (handles duplicates).
infra_purge_nat_redirect() {
  local source_port="$1"
  local dest_port="$2"
  local ip

  # Prefer clearing all redirects for this source port when dest is known — callers
  # that only pass source (enable path) use infra_purge_nat_redirects_for_source.
  while iptables -t nat -C PREROUTING -p tcp --dport "$source_port" -j REDIRECT --to-port "$dest_port" 2>/dev/null; do
    iptables -t nat -D PREROUTING -p tcp --dport "$source_port" -j REDIRECT --to-port "$dest_port" || break
  done
  while iptables -t nat -C OUTPUT -p tcp --dport "$source_port" -j REDIRECT --to-port "$dest_port" 2>/dev/null; do
    iptables -t nat -D OUTPUT -p tcp --dport "$source_port" -j REDIRECT --to-port "$dest_port" || break
  done
  while iptables -t nat -C OUTPUT -p tcp -d 127.0.0.1 --dport "$source_port" -j REDIRECT --to-port "$dest_port" 2>/dev/null; do
    iptables -t nat -D OUTPUT -p tcp -d 127.0.0.1 --dport "$source_port" -j REDIRECT --to-port "$dest_port" || break
  done
  while IFS= read -r ip; do
    [[ -n "$ip" ]] || continue
    while iptables -t nat -C OUTPUT -p tcp -d "$ip" --dport "$source_port" -j REDIRECT --to-port "$dest_port" 2>/dev/null; do
      iptables -t nat -D OUTPUT -p tcp -d "$ip" --dport "$source_port" -j REDIRECT --to-port "$dest_port" || break
    done
  done < <(infra_global_ipv4_addrs)
  if command -v ip6tables &>/dev/null; then
    while ip6tables -t nat -C OUTPUT -p tcp -d ::1 --dport "$source_port" -j REDIRECT --to-port "$dest_port" 2>/dev/null; do
      ip6tables -t nat -D OUTPUT -p tcp -d ::1 --dport "$source_port" -j REDIRECT --to-port "$dest_port" || break
    done
  fi
  # Legacy reverse redirect (dest -> source).
  while iptables -t nat -C PREROUTING -p tcp --dport "$dest_port" -j REDIRECT --to-port "$source_port" 2>/dev/null; do
    iptables -t nat -D PREROUTING -p tcp --dport "$dest_port" -j REDIRECT --to-port "$source_port" || break
  done
  while iptables -t nat -C OUTPUT -p tcp --dport "$dest_port" -j REDIRECT --to-port "$source_port" 2>/dev/null; do
    iptables -t nat -D OUTPUT -p tcp --dport "$dest_port" -j REDIRECT --to-port "$source_port" || break
  done
}

infra_install_port_forward_onboot() {
  local repo="${INFRA_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
  local unit_src="${repo}/infra-port-forward.service"
  local unit_dst=/etc/systemd/system/infra-port-forward.service
  local restore="${repo}/infra-port-forward-restore.sh"

  if [[ ! -f "$unit_src" || ! -f "$restore" ]]; then
    echo "Warning: missing $unit_src or $restore; skipping on-boot port forward unit" >&2
    return 1
  fi

  cp "$unit_src" "$unit_dst"
  sed -i "s|^Environment=\"INFRA_REPO=.*|Environment=\"INFRA_REPO=${repo}\"|" "$unit_dst"
  if declare -F infra_systemd_set_env &>/dev/null; then
    infra_systemd_set_env "$unit_dst" INFRA_APP_DIR "${INFRA_APP_DIR:-$(cd "${repo}/.." && pwd)/infra-app}"
  else
    sed -i "s|^Environment=\"INFRA_APP_DIR=.*|Environment=\"INFRA_APP_DIR=${INFRA_APP_DIR:-$(cd "${repo}/.." && pwd)/infra-app}\"|" "$unit_dst"
  fi
  sed -i "s|^ExecStart=.*|ExecStart=/usr/bin/bash ${restore}|" "$unit_dst"
  sed -i "s|^Documentation=.*|Documentation=file://${repo}/docs/readme.md|" "$unit_dst"
  systemctl daemon-reload
  systemctl enable infra-port-forward.service >/dev/null
}

infra_iptables_save_permanent() {
  if ! command -v iptables-save &>/dev/null; then
    echo "Warning: iptables-save not found" >&2
    return 1
  fi

  if infra_port_forward_configured && [[ "${EUID:-0}" -eq 0 ]]; then
    infra_ensure_port_forward_rules
  fi

  if command -v netfilter-persistent &>/dev/null; then
    netfilter-persistent save
    return 0
  fi

  if [[ -d /etc/iptables ]]; then
    iptables-save >/etc/iptables/rules.v4
    return 0
  fi

  if [[ -d /etc/sysconfig ]]; then
    iptables-save >/etc/sysconfig/iptables
    infra_normalize_saved_iptables
    if command -v iptables-restore &>/dev/null; then
      if ! iptables-restore --test /etc/sysconfig/iptables >/dev/null 2>&1; then
        echo "Warning: iptables-restore --test failed; re-normalizing /etc/sysconfig/iptables" >&2
        infra_normalize_saved_iptables
        iptables-restore --test /etc/sysconfig/iptables >/dev/null 2>&1 \
          || echo "Warning: iptables-restore --test still failing for /etc/sysconfig/iptables" >&2
      fi
    fi
    if command -v rpm &>/dev/null && rpm -q iptables-services &>/dev/null; then
      systemctl enable iptables >/dev/null 2>&1 || true
    fi
    return 0
  fi

  if command -v service &>/dev/null && service iptables save 2>/dev/null; then
    return 0
  fi

  echo "Warning: could not persist iptables rules" >&2
  return 1
}
