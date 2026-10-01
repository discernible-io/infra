#!/usr/bin/env bash
# Renew Let's Encrypt certificates for all infra-managed domains.
#
# Usage:
#   sudo ./renew-certs-all-monthly.sh certbot          # non-interactive (cron/timer)
#   sudo ./renew-certs-all-monthly.sh manual [email]   # per-domain issue/renew + install + optional restart

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

usage() {
    echo "Usage: sudo $0 certbot"
    echo "       sudo $0 manual [email]"
    exit 1
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}This script must be run as root (use sudo)${NC}" >&2
        exit 1
    fi
}

mode_certbot() {
    require_root
    # Certs are issued with --standalone (see generate-cert-letsencrypt.sh).
    # Keep httpd stopped so certbot can bind :80; only open the firewall temporarily.
    setup_httpd_cleanup_trap
    ensure_httpd_stopped

    echo -e "${BLUE}========== Automated Certificate Renewal ==========${NC}"

    open_firewall_http_for_certbot

    if ss -tlnH 2>/dev/null | grep -q ':80 '; then
        echo -e "${RED}Port 80 is in use. Stop the service using it, then retry.${NC}" >&2
        ss -tlnp | grep ':80 ' || true
        exit 1
    fi

    certbot renew --non-interactive --deploy-hook "$SCRIPT_DIR/install-certs-on-renew-hook-helper.sh"
    stop_httpd_after_certbot
    trap - EXIT

    echo -e "${GREEN}✓ Renewal run complete (httpd stopped)${NC}"
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
    "") usage ;;
    *) echo -e "${RED}Unknown mode: $MODE${NC}" >&2; usage ;;
esac
