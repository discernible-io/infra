#!/usr/bin/env bash
# Shared defaults and helpers for host-local infra-env-helper.sh (source, do not execute).

if [[ -n "${INFRA_ENV_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
INFRA_ENV_LOADED=1

_INFRA_SHARED_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_REPO="${INFRA_REPO:-$_INFRA_SHARED_DIR}"
INFRA_USER="${INFRA_USER:-$(id -un)}"
INFRA_HOME="${INFRA_HOME:-/home/${INFRA_USER}}"

# Sibling app dir holds host profile + generated script outputs (never in git).
if [[ -z "${INFRA_APP_DIR:-}" ]]; then
  INFRA_APP_DIR="$(cd "${INFRA_REPO}/.." && pwd)/infra-app"
fi
INFRA_OUTPUT_DIR="${INFRA_OUTPUT_DIR:-$INFRA_APP_DIR}"
INFRA_TRIVY_RESULTS_DIR="${INFRA_TRIVY_RESULTS_DIR:-${INFRA_OUTPUT_DIR}/trivy-scan-results}"

# :=() does not create a real array; plain assignment is required for set -u callers.
infra_ensure_array() {
  local name="$1"
  if ! declare -p "$name" &>/dev/null 2>&1; then
    eval "${name}=()"
  elif [[ "$(declare -p "$name" 2>/dev/null || true)" != declare\ -a* ]]; then
    unset "$name"
    eval "${name}=()"
  fi
}

infra_ensure_assoc_array() {
  local name="$1"
  if ! declare -p "$name" &>/dev/null 2>&1; then
    eval "declare -gA ${name}=()"
  elif [[ "$(declare -p "$name" 2>/dev/null || true)" != declare\ -A* ]]; then
    unset "$name"
    eval "declare -gA ${name}=()"
  fi
}

infra_ensure_array INFRA_PUBLIC_API_TCP_PORTS
infra_ensure_array INFRA_PUBLIC_TCP_PORTS
infra_ensure_array INFRA_MONITORING_TCP_PORTS
infra_ensure_array INFRA_ADMIN_TCP_PORTS
infra_ensure_array INFRA_MONITORING_ALLOW_CIDRS
infra_ensure_array INFRA_BLOCKED_PUBLIC_TCP_PORTS
infra_ensure_array INFRA_EXTRA_PORT_FORWARDS
# Host-published ports reachable only from rootless pasta / link-local (e.g. Postgres
# via host.containers.internal). Not opened to the public Internet.
infra_ensure_array INFRA_LOCAL_ONLY_TCP_PORTS
infra_ensure_array INFRA_LOCAL_ONLY_ALLOW_CIDRS
infra_ensure_assoc_array INFRA_POD_START
infra_ensure_assoc_array INFRA_POD_START_ENV

infra_monitoring_restrict_enabled() {
  [[ "${INFRA_MONITORING_TCP_RESTRICT:-}" == "1" || "${INFRA_MONITORING_TCP_RESTRICT:-}" == "true" ]]
}

infra_effective_public_tcp_ports() {
  local -a ports=()
  local p monitoring_port
  if infra_monitoring_restrict_enabled; then
    for p in "${INFRA_PUBLIC_TCP_PORTS[@]}"; do
      local is_monitoring=0
      for monitoring_port in "${INFRA_MONITORING_TCP_PORTS[@]}"; do
        if [[ "$p" == "$monitoring_port" ]]; then
          is_monitoring=1
          break
        fi
      done
      if [[ "$is_monitoring" -eq 0 ]]; then
        ports+=("$p")
      fi
    done
  else
    ports=("${INFRA_PUBLIC_TCP_PORTS[@]}")
  fi
  printf '%s\n' "${ports[@]}"
}

infra_monitoring_allow_cidrs() {
  local -a cidrs=("${INFRA_MONITORING_ALLOW_CIDRS[@]}")
  local host_ip
  host_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  if [[ -n "$host_ip" ]]; then
    cidrs+=("${host_ip}/32")
  fi
  printf '%s\n' "${cidrs[@]}"
}

# CIDRs allowed to reach INFRA_LOCAL_ONLY_TCP_PORTS (pasta link-local by default).
infra_local_only_allow_cidrs() {
  local -a cidrs=("${INFRA_LOCAL_ONLY_ALLOW_CIDRS[@]}")
  if [[ ${#cidrs[@]} -eq 0 ]]; then
    cidrs=(169.254.0.0/16)
  fi
  printf '%s\n' "${cidrs[@]}"
}

infra_array_contains() {
  local needle="$1"
  local p
  shift
  for p in "$@"; do
    [[ "$p" == "$needle" ]] && return 0
  done
  return 1
}

if [[ ${#INFRA_PUBLIC_API_TCP_PORTS[@]} -eq 0 ]] && declare -p INFRA_API_PORTS &>/dev/null; then
  _infra_api_port_values=()
  for _infra_svc in "${!INFRA_API_PORTS[@]}"; do
    _infra_port="${INFRA_API_PORTS[$_infra_svc]}"
    [[ "$_infra_port" =~ ^[0-9]+$ ]] || continue
    _infra_api_port_values+=("$_infra_port")
  done
  if [[ ${#_infra_api_port_values[@]} -gt 0 ]]; then
    INFRA_PUBLIC_API_TCP_PORTS=("${_infra_api_port_values[@]}")
  fi
fi

if [[ ${#INFRA_PUBLIC_TCP_PORTS[@]} -eq 0 ]]; then
  if [[ -n "${INFRA_PORT_FORWARD_DEST:-}" ]]; then
    INFRA_PUBLIC_TCP_PORTS=(443 "${INFRA_PUBLIC_API_TCP_PORTS[@]}" "${INFRA_MONITORING_TCP_PORTS[@]}")
  else
    INFRA_PUBLIC_TCP_PORTS=("${INFRA_PUBLIC_API_TCP_PORTS[@]}" "${INFRA_MONITORING_TCP_PORTS[@]}")
  fi
fi

if [[ ${#INFRA_ADMIN_TCP_PORTS[@]} -eq 0 ]]; then
  INFRA_ADMIN_TCP_PORTS=(22)
fi

# Drop inbound TCP 8443 unless a service still publishes it (legacy signportal).
if declare -p INFRA_API_PORTS &>/dev/null; then
  if ! infra_array_contains 8443 ${INFRA_API_PORTS[@]+"${INFRA_API_PORTS[@]}"}; then
    if ! infra_array_contains 8443 ${INFRA_BLOCKED_PUBLIC_TCP_PORTS[@]+"${INFRA_BLOCKED_PUBLIC_TCP_PORTS[@]}"}; then
      INFRA_BLOCKED_PUBLIC_TCP_PORTS+=(8443)
    fi
  fi
fi

INFRA_SERVICE_STARTER="${INFRA_SERVICE_STARTER:-}"

# Grafana/Loki stack (grafanaloki-app); used by start-monitoring-pod.sh and liveness monitor.
INFRA_MONITORING_POD="${INFRA_MONITORING_POD:-monitoring-pod}"
INFRA_MONITORING_PROBE_CONTAINER="${INFRA_MONITORING_PROBE_CONTAINER:-monitoring-grafana}"
INFRA_MONITORING_DEPLOY_SCRIPT="${INFRA_MONITORING_DEPLOY_SCRIPT:-${INFRA_HOME}/grafanaloki-app/deploy-monitoring.sh}"
INFRA_MONITORING_START_SCRIPT="${INFRA_MONITORING_START_SCRIPT:-${INFRA_REPO}/start-monitoring-pod.sh}"

# Ensure the Grafana/Loki pod is covered by monitor-pods-liveness when the stack exists.
# Host profiles may list it explicitly; if omitted, append a default entry.
infra_ensure_array INFRA_MONITOR_SERVICES
_infra_monitoring_listed=false
for _infra_svc in "${INFRA_MONITOR_SERVICES[@]}"; do
  if [[ "${_infra_svc%%:*}" == "monitoring" ]]; then
    _infra_monitoring_listed=true
    break
  fi
done
if [[ "$_infra_monitoring_listed" == false ]] \
  && [[ -f "$INFRA_MONITORING_DEPLOY_SCRIPT" ]]; then
  INFRA_MONITOR_SERVICES+=(
    "monitoring:${INFRA_MONITORING_PROBE_CONTAINER}:${INFRA_MONITORING_START_SCRIPT}:"
  )
fi
unset _infra_monitoring_listed _infra_svc

if [[ -n "${INFRA_PORT_FORWARD_SERVICE:-}" && -z "${INFRA_PORT_FORWARD_DEST:-}" ]]; then
  INFRA_PORT_FORWARD_DEST="${INFRA_API_PORTS[$INFRA_PORT_FORWARD_SERVICE]:-}"
fi

infra_resolve_api_port() {
  local key="$1"
  if [[ "$key" =~ ^[0-9]+$ ]]; then
    printf '%s' "$key"
    return 0
  fi
  if [[ -n "${INFRA_API_PORTS[$key]+x}" ]]; then
    printf '%s' "${INFRA_API_PORTS[$key]}"
    return 0
  fi
  return 1
}

infra_find_infra_container() {
  local port="$1"
  podman ps -a --format '{{if eq .Ports "0.0.0.0:'"$port"'->'"$port"'/tcp"}}{{.Names}}{{end}}' 2>/dev/null \
    | grep -E '.*-infra$' | head -n 1
}

if ! declare -p INFRA_CERT_SAN_DOMAINS &>/dev/null 2>&1; then
  declare -gA INFRA_CERT_SAN_DOMAINS=()
fi

# Space-separated SAN hostnames for a primary LE certificate (e.g. verify.* on mintclient).
infra_cert_san_domains_for() {
  local primary="$1"
  printf '%s' "${INFRA_CERT_SAN_DOMAINS[$primary]:-}"
}

# Set Environment=KEY=value (quoted or unquoted) on an installed systemd unit.
infra_systemd_set_env() {
  local unit="$1" key="$2" value="$3"
  if [[ ! -f "$unit" ]]; then
    return 1
  fi
  if grep -qE "^Environment=\"${key}=" "$unit"; then
    sed -i "s|^Environment=\"${key}=.*|Environment=\"${key}=${value}\"|" "$unit"
  elif grep -qE "^Environment=${key}=" "$unit"; then
    sed -i "s|^Environment=${key}=.*|Environment=${key}=${value}|" "$unit"
  elif grep -qE '^Environment=.*INFRA_REPO=' "$unit"; then
    sed -i "/^Environment=.*INFRA_REPO=/a Environment=${key}=${value}" "$unit"
  else
    sed -i "/^\\[Service\\]/a Environment=${key}=${value}" "$unit"
  fi
}
