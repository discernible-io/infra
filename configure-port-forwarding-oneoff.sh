#!/bin/bash

# Inbound iptables REDIRECT: external/local clients on SOURCE_PORT -> DEST_PORT (Podman host port).
# Usage: ./configure-port-forwarding-oneoff.sh [enable|disable|status] [permanent|temporary] [source_port] [dest_port]
#
# Alma/RHEL permanent mode: saves to /etc/sysconfig/iptables and enables
# infra-port-forward.service (re-applies REDIRECT after iptables restore on boot).
# Install loaders with: sudo dnf install -y iptables-services && sudo systemctl enable iptables
#
# Requires firewalld to be stopped/disabled (it replaces NAT and breaks inbound redirect).
# On enable, the script exits if firewalld is active unless ALLOW_FIREWALLD=1 is set.
#
# Destination comes from infra-app (INFRA_PORT_FORWARD_DEST / INFRA_PORT_FORWARD_SERVICE).
# Examples:
#   sudo ./configure-port-forwarding-oneoff.sh enable permanent
#   sudo ./configure-port-forwarding-oneoff.sh enable permanent 443 mintclient
#   sudo INFRA_PORT_FORWARD_DEST=4443 ./configure-port-forwarding-oneoff.sh enable permanent

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/infra-env-helper.sh" ]]; then
    # shellcheck source=infra-env-helper.sh
    source "$SCRIPT_DIR/infra-env-helper.sh"
fi
# shellcheck source=infra-iptables-helper.sh
source "$SCRIPT_DIR/infra-iptables-helper.sh"

# Default ports from infra-app (INFRA_PORT_FORWARD_DEST / INFRA_PORT_FORWARD_SERVICE).
DEFAULT_SOURCE_PORT="${INFRA_PORT_FORWARD_SOURCE:-443}"
DEFAULT_DEST_PORT=""
if declare -F infra_resolve_port_forward_dest &>/dev/null; then
    DEFAULT_DEST_PORT="$(infra_resolve_port_forward_dest 2>/dev/null || true)"
fi

# Parse arguments
ACTION=${1:-status}
MODE=${2:-temporary}
SOURCE_PORT=${3:-$DEFAULT_SOURCE_PORT}
DEST_PORT=${4:-$DEFAULT_DEST_PORT}

if [[ -n "$DEST_PORT" ]] && declare -F infra_resolve_api_port &>/dev/null; then
  if resolved="$(infra_resolve_api_port "$DEST_PORT" 2>/dev/null)"; then
    DEST_PORT="$resolved"
  fi
fi

# Function to show usage
show_usage() {
    cat << EOF
Usage: $0 [enable|disable|status] [permanent|temporary] [source_port] [dest_port]

Actions:
  enable     Enable inbound port mapping (external -> local service)
  disable    Disable inbound port mapping
  status     Show current port mapping status (default)

Modes:
  temporary  Changes apply until reboot (default)
  permanent  Changes survive reboot

Ports:
  source_port  First port (default: $DEFAULT_SOURCE_PORT from INFRA_PORT_FORWARD_SOURCE)
  dest_port    Second port or API service key (required from
               INFRA_PORT_FORWARD_DEST / INFRA_PORT_FORWARD_SERVICE in infra-app,
               or pass explicitly)

Examples:
  $0                                    # Show status
  $0 enable                             # Enable temporary mapping (defaults from infra-app)
  $0 enable permanent                   # Enable permanent mapping
  $0 enable permanent 443 mintclient    # 443 -> service port when mintclient is configured
  $0 disable permanent                  # Disable and save permanently
  $0 enable temporary 80 8080           # Enable temporary mapping (80 -> 8080)
EOF
}

# If called without arguments or with status, show status
if [ "$ACTION" = "status" ]; then
    echo "Port Mapping Status"
    echo "==================="
    echo ""
    if [[ -n "$DEFAULT_DEST_PORT" ]]; then
        echo "Default ports: $DEFAULT_SOURCE_PORT -> $DEFAULT_DEST_PORT"
    else
        echo "Default ports: $DEFAULT_SOURCE_PORT -> (unset; set INFRA_PORT_FORWARD_DEST or INFRA_PORT_FORWARD_SERVICE in infra-app)"
    fi
    if [[ -n "${INFRA_PORT_FORWARD_SERVICE:-}" ]]; then
        echo "Forward service: ${INFRA_PORT_FORWARD_SERVICE} (infra-app via infra-env-helper.sh)"
    fi
    if declare -F infra_iter_extra_port_forwards &>/dev/null; then
        extra_lines="$(infra_iter_extra_port_forwards)"
        if [[ -n "$extra_lines" ]]; then
            echo "Extra forwards (INFRA_EXTRA_PORT_FORWARDS):"
            while read -r src dest; do
                [[ -n "$src" ]] || continue
                echo "  $src -> $dest"
            done <<< "$extra_lines"
        fi
    fi
    echo ""
    echo "Current NAT PREROUTING rules:"
    iptables -t nat -L PREROUTING -n -v --line-numbers | grep -E "(Chain|REDIRECT)" || echo "  No REDIRECT rules found"
    echo ""
    echo "Current NAT OUTPUT rules:"
    iptables -t nat -L OUTPUT -n -v --line-numbers | grep -E "(Chain|REDIRECT)" || echo "  No REDIRECT rules found"
    echo ""
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        echo "Firewall: firewalld is active. NAT rules above may not persist across reboot"
        echo "          unless you map ports in firewalld or switch to iptables-services."
        echo ""
    fi
    show_usage
    exit 0
fi

# Validate action
if [[ "$ACTION" != "enable" && "$ACTION" != "disable" ]]; then
    echo "Error: Action must be 'enable', 'disable', or 'status'"
    echo ""
    show_usage
    exit 1
fi

# Validate mode
if [[ "$MODE" != "permanent" && "$MODE" != "temporary" ]]; then
    echo "Error: Mode must be 'permanent' or 'temporary'"
    echo ""
    show_usage
    exit 1
fi

# Require dest from infra-app profile or an explicit CLI argument (no hardcoded fallback).
if [[ -z "$DEST_PORT" ]]; then
    echo "Error: no destination port. Set INFRA_PORT_FORWARD_DEST or INFRA_PORT_FORWARD_SERVICE in infra-app," >&2
    echo "       or pass dest_port explicitly (e.g. $0 $ACTION $MODE 443 <port|service>)." >&2
    exit 1
fi

# Validate ports
if ! [[ "$SOURCE_PORT" =~ ^[0-9]+$ ]] || ! [[ "$DEST_PORT" =~ ^[0-9]+$ ]]; then
    echo "Error: Ports must be numeric (got source=$SOURCE_PORT dest=$DEST_PORT)"
    exit 1
fi

if [ "$SOURCE_PORT" -lt 1 ] || [ "$SOURCE_PORT" -gt 65535 ] || [ "$DEST_PORT" -lt 1 ] || [ "$DEST_PORT" -gt 65535 ]; then
    echo "Error: Ports must be between 1 and 65535"
    exit 1
fi

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Error: This script must be run as root (use sudo)"
    exit 1
fi

# Function to add iptables rules
add_rules() {
    echo "Adding inbound port mapping: $SOURCE_PORT -> $DEST_PORT"
    infra_apply_port_forward "$SOURCE_PORT" "$DEST_PORT"
    # NOTE: We do NOT redirect outbound traffic to remote hosts on SOURCE_PORT
    # (would break HTTPS to external APIs, e.g. NEAR RPC).
    echo "Inbound port mapping enabled: $SOURCE_PORT -> $DEST_PORT"
}

# Function to remove iptables rules
remove_rules() {
    echo "Removing port mapping(s) for external port: $SOURCE_PORT"
    # Clear every REDIRECT for SOURCE_PORT (any dest), then also the specific pair.
    infra_purge_nat_redirects_for_source "$SOURCE_PORT"
    infra_purge_nat_redirect "$SOURCE_PORT" "$DEST_PORT"
    echo "Port mapping disabled for: $SOURCE_PORT (was targeting $DEST_PORT)"
}

save_permanent() {
    echo "Saving iptables rules..."
    infra_iptables_save_permanent
    echo "Rules saved permanently"
}

# Main logic
case "$ACTION" in
    enable)
        infra_switch_from_firewalld_to_iptables

        # Remove existing rules first (if any) to avoid duplicates
        remove_rules 2>/dev/null || true
        
        # Add new rules
        add_rules

        # When enabling the profile default (443→DEST), reconcile extras:
        # purge REDIRECTs for ports that are now direct API listens, then apply
        # INFRA_EXTRA_PORT_FORWARDS (so retired aliases like 7443→hermes are dropped).
        if [[ "$SOURCE_PORT" == "$DEFAULT_SOURCE_PORT" && "$DEST_PORT" == "$DEFAULT_DEST_PORT" ]]; then
            if declare -F infra_reconcile_stale_api_port_redirects &>/dev/null; then
                infra_reconcile_stale_api_port_redirects
            fi
            if declare -F infra_ensure_extra_port_forward_rules &>/dev/null; then
                infra_ensure_extra_port_forward_rules
            fi
        fi
        
        # Save permanently if requested
        if [ "$MODE" = "permanent" ]; then
            save_permanent
            infra_install_port_forward_onboot
            echo "Port mapping is now permanent (survives reboot; infra-port-forward.service enabled)"
        else
            echo "Port mapping is temporary (will be lost on reboot)"
        fi
        ;;
        
    disable)
        # Remove rules
        remove_rules
        
        # Save permanently if requested
        if [ "$MODE" = "permanent" ]; then
            save_permanent
            echo "Port mapping removal is now permanent"
        else
            echo "Port mapping removed temporarily"
        fi
        ;;
esac

# Show current status after changes
echo ""
if systemctl is-active --quiet firewalld 2>/dev/null; then
    echo "Note: firewalld is active; ensure your port strategy matches (see script header)."
    echo ""
fi
echo "Current NAT PREROUTING rules:"
iptables -t nat -L PREROUTING -n -v --line-numbers | grep -E "(Chain|REDIRECT)" || echo "  No REDIRECT rules found"
echo ""
echo "Current NAT OUTPUT rules:"
iptables -t nat -L OUTPUT -n -v --line-numbers | grep -E "(Chain|REDIRECT)" || echo "  No REDIRECT rules found"

exit 0
