#!/usr/bin/env bash
# Renew Let's Encrypt certificates for all infra-managed domains.
#
# Usage:
#   sudo ./renew-certs-all-monthly.sh certbot          # non-interactive (cron/timer)
#   sudo ./renew-certs-all-monthly.sh manual [email]   # per-domain issue/renew + install + optional restart
#   sudo ./renew-certs-all-monthly.sh install-timer    # point OS certbot-renew.service at this script
#   sudo ./renew-certs-all-monthly.sh uninstall-timer  # restore stock certbot-renew.service ExecStart
#
# Renewal window: lineages get renew_before_expiry=13 days (floor). Certbot ARI may renew
# earlier (~30d for Let's Encrypt). Stock certbot-renew.timer must use this script so
# standalone HTTP-01 can open :80; otherwise attempts fail until near expiry.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=infra-env-helper.sh
source "$SCRIPT_DIR/infra-env-helper.sh"
# shellcheck source=prepare-httpd-for-certbot-helper.sh
source "$SCRIPT_DIR/prepare-httpd-for-certbot-helper.sh"

DOMAINS=("${INFRA_CERT_DOMAINS[@]}")

# Minimum remaining lifetime before certbot renew will attempt (lineage config).
# ARI may still renew earlier; this is the latest we allow before expiry.
RENEW_BEFORE_EXPIRY="${RENEW_BEFORE_EXPIRY:-13 days}"
CERTBOT_RENEW_DROPIN_DIR="/etc/systemd/system/certbot-renew.service.d"
CERTBOT_RENEW_DROPIN="${CERTBOT_RENEW_DROPIN_DIR}/infra-standalone.conf"

usage() {
    echo "Usage: sudo $0 certbot"
    echo "       sudo $0 manual [email]"
    echo "       sudo $0 install-timer"
    echo "       sudo $0 uninstall-timer"
    exit 1
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}This script must be run as root (use sudo)${NC}" >&2
        exit 1
    fi
}

# Ensure every lineage renews no later than RENEW_BEFORE_EXPIRY before notAfter.
ensure_renew_before_expiry() {
    local conf interval="$RENEW_BEFORE_EXPIRY"
    local renewal_dir="/etc/letsencrypt/renewal"

    [[ -d "$renewal_dir" ]] || return 0

    echo -e "${YELLOW}Ensuring renew_before_expiry = ${interval} in ${renewal_dir}/*.conf${NC}"
    shopt -s nullglob
    for conf in "$renewal_dir"/*.conf; do
        if grep -qE '^[[:space:]]*renew_before_expiry[[:space:]]*=' "$conf"; then
            sed -i -E "s|^[[:space:]]*renew_before_expiry[[:space:]]*=.*|renew_before_expiry = ${interval}|" "$conf"
        elif grep -qE '^\[renewalparams\]' "$conf"; then
            sed -i -E "/^\[renewalparams\]/a renew_before_expiry = ${interval}" "$conf"
        else
            printf '\n[renewalparams]\nrenew_before_expiry = %s\n' "$interval" >>"$conf"
        fi
    done
    shopt -u nullglob
}

mode_install_timer() {
    require_root

    if [[ ! -f /usr/lib/systemd/system/certbot-renew.service ]]; then
        echo -e "${RED}certbot-renew.service not found (install certbot first)${NC}" >&2
        exit 1
    fi

    ensure_renew_before_expiry

    mkdir -p "$CERTBOT_RENEW_DROPIN_DIR"
    cat >"$CERTBOT_RENEW_DROPIN" <<EOF
# Managed by renew-certs-all-monthly.sh install-timer.
# Stock certbot renew cannot satisfy standalone HTTP-01 (needs temporary :80).
[Service]
EnvironmentFile=
ExecStart=
ExecStart=${SCRIPT_DIR}/renew-certs-all-monthly.sh certbot
EOF
    chmod 644 "$CERTBOT_RENEW_DROPIN"
    systemctl daemon-reload
    systemctl enable --now certbot-renew.timer

    echo -e "${GREEN}✓ certbot-renew.service now runs: ${SCRIPT_DIR}/renew-certs-all-monthly.sh certbot${NC}"
    echo -e "${GREEN}✓ renew_before_expiry floor: ${RENEW_BEFORE_EXPIRY}${NC}"
    systemctl cat certbot-renew.service --no-pager | tail -n 20 || true
    systemctl list-timers certbot-renew.timer --no-pager || true
}

mode_uninstall_timer() {
    require_root
    if [[ -f "$CERTBOT_RENEW_DROPIN" ]]; then
        rm -f "$CERTBOT_RENEW_DROPIN"
        rmdir "$CERTBOT_RENEW_DROPIN_DIR" 2>/dev/null || true
        systemctl daemon-reload
        echo -e "${GREEN}✓ Removed infra drop-in; stock certbot-renew ExecStart restored${NC}"
    else
        echo -e "${YELLOW}No infra drop-in at ${CERTBOT_RENEW_DROPIN}${NC}"
    fi
}

mode_certbot() {
    require_root
    local rc=0

    # Certs are issued with --standalone (see generate-cert-letsencrypt.sh).
    # Keep httpd stopped so certbot can bind :80; only open the firewall temporarily.
    # EXIT trap always closes temporary :80 and restores NAT, including on set -e failure.
    setup_httpd_cleanup_trap
    ensure_httpd_stopped
    ensure_renew_before_expiry

    echo -e "${BLUE}========== Automated Certificate Renewal ==========${NC}"
    echo -e "${BLUE}Renewal floor: ${RENEW_BEFORE_EXPIRY} before expiry (ARI may renew earlier)${NC}"

    open_firewall_http_for_certbot

    if ss -tlnH 2>/dev/null | grep -q ':80 '; then
        echo -e "${RED}Port 80 is in use. Stop the service using it, then retry.${NC}" >&2
        ss -tlnp | grep ':80 ' || true
        exit 1
    fi

    certbot renew --non-interactive --deploy-hook "$SCRIPT_DIR/install-certs-on-renew-hook-helper.sh" || rc=$?

    stop_httpd_after_certbot
    trap - EXIT

    if [[ "$rc" -eq 0 ]]; then
        echo -e "${GREEN}✓ Renewal run complete (standalone; port 80 closed)${NC}"
    else
        echo -e "${YELLOW}Renewal finished with errors (exit $rc); port 80 closed${NC}" >&2
    fi
    return "$rc"
}

mode_manual() {
    local email="${1:-}"

    require_root
    setup_httpd_cleanup_trap
    ensure_httpd_stopped

    echo -e "${BLUE}========== Certificate Renewal and Installation ==========${NC}"
    echo ""

    echo -e "${YELLOW}Step 1: Generating/renewing certificates...${NC}"
    local failed_domains=()

    for domain in "${DOMAINS[@]}"; do
        echo -e "${YELLOW}  Processing $domain...${NC}"

        if [[ -n "$email" ]]; then
            if ! "$SCRIPT_DIR/generate-cert-letsencrypt.sh" "$domain" "$email"; then
                echo -e "  ${RED}✗ Failed for $domain${NC}"
                failed_domains+=("$domain")
            else
                echo -e "  ${GREEN}✓ Success${NC}"
            fi
        else
            echo -e "  ${YELLOW}No email provided. Running in interactive mode.${NC}"
            if ! "$SCRIPT_DIR/generate-cert-letsencrypt.sh" "$domain"; then
                echo -e "  ${RED}✗ Failed for $domain${NC}"
                failed_domains+=("$domain")
            else
                echo -e "  ${GREEN}✓ Success${NC}"
            fi
        fi
    done

    if [[ ${#failed_domains[@]} -gt 0 ]]; then
        echo -e "${RED}Certificate generation failed for:${NC}"
        for domain in "${failed_domains[@]}"; do
            echo -e "  ${RED}✗ $domain${NC}"
        done
        echo -e "${YELLOW}Continuing install for any certificates already on disk...${NC}"
    fi

    ensure_httpd_stopped
    trap - EXIT

    if [[ ${#failed_domains[@]} -eq 0 ]]; then
        echo -e "${GREEN}✓ All certificates generated/renewed${NC}"
    fi
    echo ""

    echo -e "${YELLOW}Step 2: Installing certificates to app directories...${NC}"
    if ! "$SCRIPT_DIR/install-certs-to-apps.sh"; then
        echo -e "${RED}Certificate installation failed${NC}" >&2
        ensure_httpd_stopped
        exit 1
    fi

    if [[ ${#failed_domains[@]} -gt 0 ]]; then
        echo -e "${YELLOW}Fix DNS or run cert issue on the host that owns those names, then re-run install.${NC}"
        ensure_httpd_stopped
        exit 1
    fi

    echo -e "${GREEN}✓ Certificate installation complete${NC}"
    echo ""

    echo -e "${YELLOW}Step 3: Service restart${NC}"
    echo -e "${YELLOW}Restart services to apply new certificates? (y/n)${NC}"
    read -r -p "Restart services? [y/N] " -t 10 restart_choice || restart_choice="n"

    if [[ "$restart_choice" =~ ^[Yy]$ ]]; then
        if [[ -f "$SCRIPT_DIR/restart-containers-apis.sh" ]]; then
            echo -e "${YELLOW}Running restart-containers-apis.sh...${NC}"
            if "$SCRIPT_DIR/restart-containers-apis.sh"; then
                echo -e "${GREEN}✓ Services restarted${NC}"
            else
                echo -e "${YELLOW}⚠ Service restart had issues. Check manually.${NC}"
            fi
        else
            echo -e "${YELLOW}⚠ restart-containers-apis.sh not found. Restart services manually.${NC}"
        fi
    else
        echo -e "${YELLOW}Skipping service restart. Restart manually when ready.${NC}"
    fi

    echo ""
    echo -e "${GREEN}========== Certificate Renewal Complete ==========${NC}"
    echo -e "${YELLOW}Certificates installed to: ${INFRA_HOME}/*-app/certs/${NC}"
    echo -e "${GREEN}httpd is stopped (used only during certificate operations).${NC}"
    echo ""
}

MODE="${1:-}"
shift || true

case "$MODE" in
    certbot|auto) mode_certbot ;;
    manual) mode_manual "${1:-}" ;;
    install-timer) mode_install_timer ;;
    uninstall-timer) mode_uninstall_timer ;;
    "") usage ;;
    *) echo -e "${RED}Unknown mode: $MODE${NC}" >&2; usage ;;
esac
