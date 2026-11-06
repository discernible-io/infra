#!/bin/bash
# Podman container liveness monitor helper (invoked by monitor-pods-liveness.service).
#
# For each INFRA_MONITOR_SERVICES entry, ensures the probe container is running and
# heals degraded pods / exited siblings (nginx, agents, infra) even when the probe
# itself looks healthy.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=infra-env-helper.sh
source "$SCRIPT_DIR/infra-env-helper.sh"

LOG_FILE="/var/log/pod-monitor.log"
SERVICES=("${INFRA_MONITOR_SERVICES[@]}")

log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Rootless Podman is per-user. If this script is ever run under sudo/root,
# ensure we still target the intended INFRA_USER store.
podman_cmd() {
    if [[ "${EUID:-0}" -eq 0 && -n "${INFRA_USER:-}" ]] && command -v runuser >/dev/null 2>&1; then
        local uid
        uid="$(id -u "$INFRA_USER" 2>/dev/null || true)"
        if [[ -n "$uid" ]]; then
            runuser -u "$INFRA_USER" -- env \
                XDG_RUNTIME_DIR="/run/user/${uid}" \
                DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
                podman "$@"
            return $?
        fi
    fi
    podman "$@"
}

# Rootless Podman may not be ready immediately after boot (socket/session lag).
wait_for_podman() {
    local infra_uid runtime_dir sock attempt max_attempts=24

    infra_uid="$(id -u "${INFRA_USER:-$(id -un)}" 2>/dev/null || echo "$(id -u)")"
    runtime_dir="${XDG_RUNTIME_DIR:-/run/user/${infra_uid}}"
    sock="${runtime_dir}/podman/podman.sock"

    for ((attempt = 1; attempt <= max_attempts; attempt++)); do
        if [[ -S "$sock" ]] && podman_cmd info >/dev/null 2>&1; then
            [[ "$attempt" -gt 1 ]] && log_message "Podman ready after ${attempt} attempt(s)"
            return 0
        fi
        if [[ "$attempt" -eq 1 ]]; then
            log_message "Waiting for rootless Podman ($sock)..."
        fi
        # After reboot the user socket may not exist until podman.socket / user@ starts.
        if [[ "$attempt" -eq 3 || "$attempt" -eq 8 ]]; then
            if command -v systemctl >/dev/null 2>&1; then
                systemctl --user start podman.socket 2>/dev/null \
                    || log_message "Note: could not start podman.socket (user session may still be coming up)"
            fi
        fi
        sleep 5
    done

    log_message "ERROR: Podman not ready after $((max_attempts * 5))s ($sock); check linger: sudo loginctl enable-linger ${INFRA_USER:-$(id -un)}"
    return 1
}

# podman container exists can fail with stale locks ("file exists") or when the
# user session is down; fall back to podman ps -a name listing.
container_exists() {
    local name="$1"
    local err

    if podman_cmd container exists "$name" 2>/dev/null; then
        return 0
    fi

    err=$(podman_cmd container exists "$name" 2>&1) || true
    if [[ "$err" == *"file exists"* || "$err" == *"acquiring lock"* || "$err" == *"retrieving lock"* ]]; then
        log_message "WARNING: Podman lock error for $name ($err)"
    fi

    podman_cmd ps -a --format '{{.Names}}' 2>/dev/null | grep -qxF "$name"
}

container_status() {
    local name="$1"
    podman_cmd inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo "missing"
}

container_running() {
    [[ "$(container_status "$1")" == "running" ]]
}

pod_name_for_container() {
    local container_name="$1"
    local pod_id pod_name

    # Rootless Podman on Alma 10 exposes the pod id as .Pod (not .PodID).
    pod_id="$(podman_cmd inspect -f '{{.Pod}}' "$container_name" 2>/dev/null || true)"
    if [[ -z "$pod_id" || "$pod_id" == "<nil>" || "$pod_id" == "null" || "$pod_id" == "<no value>" ]]; then
        return 1
    fi
    pod_name="$(podman_cmd pod inspect -f '{{.Name}}' "$pod_id" 2>/dev/null || true)"
    if [[ -z "$pod_name" || "$pod_name" == "<no value>" ]]; then
        return 1
    fi
    printf '%s' "$pod_name"
}

pod_status() {
    local pod_name="$1"
    podman_cmd pod inspect -f '{{.State}}' "$pod_name" 2>/dev/null || echo "missing"
}

# List containers in a pod (names only).
pod_container_names() {
    local pod_name="$1"
    podman_cmd ps -a --pod --filter "pod=$pod_name" --format '{{.Names}}' 2>/dev/null
}

# infra → app/agents → nginx (nginx last avoids upstream DNS races).
order_stack_containers() {
    local -a names=("$@")
    local -a infra=() mid=() nginx=()
    local n

    for n in "${names[@]}"; do
        [[ -n "$n" ]] || continue
        if [[ "$n" == *-infra ]]; then
            infra+=("$n")
        elif [[ "$n" == *nginx* ]]; then
            nginx+=("$n")
        else
            mid+=("$n")
        fi
    done
    printf '%s\n' "${infra[@]+"${infra[@]}"}" "${mid[@]+"${mid[@]}"}" "${nginx[@]+"${nginx[@]}"}"
}

# Expected siblings outside pod inspect (name conventions + monitor probe).
expected_stack_names() {
    local service_name="$1"
    local container_name="$2"
    local port="${3:-}"
    local infra base

    printf '%s\n' "$container_name"
    printf '%s\n' "${service_name}-nginx"
    # hermes-agent → hermes-nginx; openclaw-agents → openclaw-nginx
    base="${service_name%-agents}"
    base="${base%-agent}"
    if [[ "$base" != "$service_name" ]]; then
        printf '%s\n' "${base}-nginx"
    fi
    # Common OpenClaw agent names (hosts still on openclaw-nginx).
    if [[ "$service_name" == openclaw-agents || "$container_name" == openclaw-nginx ]]; then
        printf '%s\n' openclaw-agent-a openclaw-agent-c openclaw-agent-e
    fi
    # Host extras from ~/infra-app: INFRA_MONITOR_STACK_EXTRA[service]="c1 c2 …"
    if [[ -n "${INFRA_MONITOR_STACK_EXTRA[$service_name]:-}" ]]; then
        # shellcheck disable=SC2086
        printf '%s\n' ${INFRA_MONITOR_STACK_EXTRA[$service_name]}
    fi
    if [[ -n "$port" ]]; then
        infra="$(infra_find_infra_container "$port" 2>/dev/null || true)"
        [[ -n "$infra" ]] && printf '%s\n' "$infra"
    fi
}

# Unique existing container names for this service (pod members + conventions).
collect_stack_containers() {
    local service_name="$1"
    local container_name="$2"
    local port="${3:-}"
    local pod_name="" name
    local -a raw=() out=()

    if pod_name="$(pod_name_for_container "$container_name")"; then
        mapfile -t raw < <(pod_container_names "$pod_name")
    fi
    mapfile -t -O "${#raw[@]}" raw < <(expected_stack_names "$service_name" "$container_name" "$port")

    for name in "${raw[@]}"; do
        [[ -n "$name" ]] || continue
        container_exists "$name" || continue
        local seen=0 c
        for c in "${out[@]+"${out[@]}"}"; do
            [[ "$c" == "$name" ]] && seen=1 && break
        done
        [[ "$seen" -eq 0 ]] && out+=("$name")
    done

    if [[ ${#out[@]} -eq 0 ]]; then
        return 0
    fi
    order_stack_containers "${out[@]}"
}

stack_has_down_sibling() {
    local name
    for name in "$@"; do
        container_running "$name" || return 0
    done
    return 1
}

start_container_with_retries() {
    local container_name="$1"
    local max_retries=5
    local retry sleep_s=2
    local is_nginx=0

    [[ "$container_name" == *nginx* ]] && is_nginx=1

    for ((retry = 1; retry <= max_retries; retry++)); do
        if container_running "$container_name"; then
            return 0
        fi
        podman_cmd start "$container_name" >>"$LOG_FILE" 2>&1 || true
        sleep "$sleep_s"
        if container_running "$container_name"; then
            return 0
        fi
        # Nginx often fails once on "host not found in upstream" before DNS/aliases settle.
        if [[ "$is_nginx" -eq 1 ]]; then
            sleep_s=3
            log_message "Retry $retry/$max_retries starting $container_name (upstream may not be ready)"
        else
            sleep_s=2
        fi
    done
    return 1
}

heal_stack() {
    local service_name="$1"
    local container_name="$2"
    local port="${3:-}"
    local pod_name=""
    local -a stack=()
    local c

    if pod_name="$(pod_name_for_container "$container_name")"; then
        log_message "Starting pod $pod_name for $service_name"
        podman_cmd pod start "$pod_name" >>"$LOG_FILE" 2>&1 || true
        sleep 2
    fi

    mapfile -t stack < <(collect_stack_containers "$service_name" "$container_name" "$port")
    if [[ ${#stack[@]} -eq 0 ]]; then
        stack=("$container_name")
        [[ -n "$port" ]] && {
            local infra
            infra="$(infra_find_infra_container "$port" 2>/dev/null || true)"
            [[ -n "$infra" ]] && stack=("$infra" "$container_name" "${service_name}-nginx")
        }
    fi

    for c in "${stack[@]}"; do
        if container_running "$c"; then
            continue
        fi
        log_message "Starting sibling $c for $service_name"
        if ! start_container_with_retries "$c"; then
            log_message "ERROR: failed to start $c for $service_name"
        fi
    done
}

stack_healthy() {
    local service_name="$1"
    local container_name="$2"
    local port="${3:-}"
    local pod_name=""
    local -a stack=()

    container_running "$container_name" || return 1

    if pod_name="$(pod_name_for_container "$container_name")"; then
        local pst
        pst="$(pod_status "$pod_name")"
        # Podman reports Degraded when any member is not running.
        if [[ "$pst" == "Degraded" || "$pst" == "Stopped" || "$pst" == "Exited" ]]; then
            return 1
        fi
    fi

    mapfile -t stack < <(collect_stack_containers "$service_name" "$container_name" "$port")
    if [[ ${#stack[@]} -gt 0 ]] && stack_has_down_sibling "${stack[@]}"; then
        return 1
    fi
    return 0
}

restart_monitoring_pod() {
    local pod="${INFRA_MONITORING_POD:-monitoring-pod}"
    if ! podman_cmd pod exists "$pod" 2>/dev/null; then
        return 1
    fi
    log_message "Starting pod $pod for monitoring"
    podman_cmd pod start "$pod" >>"$LOG_FILE" 2>&1
}

check_and_restart() {
    local service_name="$1"
    local container_name="$2"
    local start_script="$3"
    local port="${4:-}"
    local infra_uid runtime_dir

    infra_uid="$(id -u "${INFRA_USER:-$(id -un)}" 2>/dev/null || echo "$(id -u)")"
    runtime_dir="${XDG_RUNTIME_DIR:-/run/user/${infra_uid}}"

    if ! container_exists "$container_name"; then
        if [[ ! -d "$runtime_dir" ]]; then
            log_message "ERROR: User runtime missing ($runtime_dir); enable linger: sudo loginctl enable-linger ${INFRA_USER:-$(id -un)}"
        else
            log_message "WARNING: Container $container_name does not exist for $service_name"
        fi
        return 1
    fi

    if stack_healthy "$service_name" "$container_name" "$port"; then
        return 0
    fi

    local status pst="n/a" pod_name=""
    status="$(container_status "$container_name")"
    if pod_name="$(pod_name_for_container "$container_name")"; then
        pst="$(pod_status "$pod_name")"
    fi
    log_message "ALERT: $service_name unhealthy (probe=$container_name status=$status pod=${pod_name:-none} pod_state=$pst) - initiating heal"

    if [[ -n "$start_script" && -f "$start_script" ]]; then
        if SERVICE_NAME="$service_name" SERVICE_PORT="$port" bash "$start_script" "$service_name" "$port" >>"$LOG_FILE" 2>&1; then
            if stack_healthy "$service_name" "$container_name" "$port"; then
                log_message "SUCCESS: $service_name healed via $start_script"
                return 0
            fi
            log_message "WARNING: start script returned OK but stack still unhealthy; continuing heal"
        else
            log_message "ERROR: start script failed for $service_name ($start_script); falling back to podman heal"
        fi
    elif [[ -n "$start_script" ]]; then
        log_message "ERROR: configured start script not found for $service_name ($start_script); falling back to podman heal"
    fi

    if [[ -z "$port" ]]; then
        if [[ "$service_name" == "monitoring" ]]; then
            restart_monitoring_pod || true
            heal_stack "$service_name" "$container_name" ""
            if stack_healthy "$service_name" "$container_name" ""; then
                log_message "SUCCESS: $service_name healed via monitoring pod start"
                return 0
            fi
        fi
        # Still try sibling heal without an infra port (pod-based stacks).
        heal_stack "$service_name" "$container_name" ""
        if stack_healthy "$service_name" "$container_name" ""; then
            log_message "SUCCESS: $service_name healed via podman"
            return 0
        fi
        log_message "ERROR: heal did not bring $service_name fully up"
        return 1
    fi

    heal_stack "$service_name" "$container_name" "$port"
    if stack_healthy "$service_name" "$container_name" "$port"; then
        log_message "SUCCESS: $service_name healed via podman (port $port)"
        return 0
    fi
    log_message "ERROR: heal did not bring $service_name fully up"
    return 1
}

log_message "Starting pod monitoring check (user=${INFRA_USER:-?} home=${INFRA_HOME})"

if ! wait_for_podman; then
    log_message "Monitoring check complete - Errors: 1 (podman unavailable)"
    exit 1
fi

error_count=0
for service_def in "${SERVICES[@]}"; do
    IFS=':' read -r name container script port <<<"$service_def"
    if ! check_and_restart "$name" "$container" "$script" "$port"; then
        ((error_count++)) || true
    fi
done

log_message "Monitoring check complete - Errors: $error_count"
