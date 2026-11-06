#!/usr/bin/env bash
# Install Let's Encrypt certificates to app directories
# Usage: sudo ./install-certs-to-apps.sh
#
# Installs domain-specific certificates to each app with correct permissions for nginx (UID 101)
# Domain mappings come from infra-env-helper.sh (INFRA_APP_DOMAINS).

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
NC='\033[0m'

NGINX_UID=101
NGINX_GID=101

restart_nginx_for_app() {
    local app_dir="$1" app_name service nginx=""
    app_name="$(basename "$app_dir")"
    # Host override from ~/infra-app (INFRA_APP_NGINX[app_dir]=container).
    if [[ -n "${INFRA_APP_NGINX[$app_dir]:-}" ]]; then
        nginx="${INFRA_APP_NGINX[$app_dir]}"
    elif [[ "$app_name" == "grafanaloki-app" ]]; then
        nginx="monitoring-nginx"
    elif [[ "$app_name" == "openclaw-agents-app" ]]; then
        nginx="openclaw-nginx"
    elif [[ "$app_name" == "hermes-agents-app" ]]; then
        nginx="hermes-nginx"
    else
        service="${app_name%-app}"
        nginx="${service}-nginx"
    fi
    if infra_run_as_user "$INFRA_USER" podman container exists "$nginx" 2>/dev/null; then
        echo -e "  ${YELLOW}Reloading $nginx...${NC}"
        if infra_run_as_user "$INFRA_USER" podman restart "$nginx" >/dev/null 2>&1; then
            echo -e "  ${GREEN}✓ Restarted $nginx${NC}"
        else
            echo -e "  ${YELLOW}⚠ Failed to restart $nginx (reload manually)${NC}"
        fi
    fi
}

# Validation
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}This script must be run as root (use sudo)${NC}" >&2
    exit 1
fi

echo -e "${BLUE}========== Installing Certificates to App Directories ==========${NC}"
echo ""

# Install to each app directory
FAILED_APPS=()
SUCCESSFUL_APPS=()

for APP_DIR in "${!INFRA_APP_DOMAINS[@]}"; do
    DOMAIN="${INFRA_APP_DOMAINS[$APP_DIR]}"
    APP_NAME=$(basename "$APP_DIR")
    CERT_PATH="/etc/letsencrypt/live/$DOMAIN"
    
    echo -e "${YELLOW}Processing $APP_NAME ($DOMAIN)...${NC}"
    
    # Check if app directory exists
    if [[ ! -d "$APP_DIR" ]]; then
        echo -e "  ${YELLOW}⚠ Skipping (app directory not found)${NC}"
        echo ""
        continue
    fi
    
    # Check if certificate exists (skip if LE not issued on this host yet)
    if [[ ! -d "$CERT_PATH" ]]; then
        echo -e "  ${RED}✗ Missing LE cert: $CERT_PATH${NC}"
        FAILED_APPS+=("$APP_NAME")
        echo ""
        continue
    fi
    
    if [[ ! -f "$CERT_PATH/fullchain.pem" ]] || [[ ! -f "$CERT_PATH/privkey.pem" ]]; then
        echo -e "  ${RED}✗ Certificate files missing in $CERT_PATH${NC}"
        FAILED_APPS+=("$APP_NAME")
        echo ""
        continue
    fi
    
    CERTS_DIR="$APP_DIR/certs"
    
    # Create certs directory if it doesn't exist
    if [[ ! -d "$CERTS_DIR" ]]; then
        mkdir -p "$CERTS_DIR"
        echo -e "  ${GREEN}✓ Created $CERTS_DIR${NC}"
    fi
    chmod 0711 "$CERTS_DIR" 2>/dev/null || true
    
    # Copy certificates
    if ! cp "$CERT_PATH/fullchain.pem" "$CERTS_DIR/fullchain.pem" 2>/dev/null; then
        echo -e "  ${RED}✗ Failed to copy fullchain.pem${NC}"
        FAILED_APPS+=("$APP_NAME")
        echo ""
        continue
    fi
    
    if ! cp "$CERT_PATH/privkey.pem" "$CERTS_DIR/privkey.pem" 2>/dev/null; then
        echo -e "  ${RED}✗ Failed to copy privkey.pem${NC}"
        FAILED_APPS+=("$APP_NAME")
        echo ""
        continue
    fi
    
    echo -e "  ${GREEN}✓ Copied certificates${NC}"

    # Host user must own files before podman unshare can map to container UID 101.
    chown "$INFRA_USER:$INFRA_USER" "$CERTS_DIR/fullchain.pem" "$CERTS_DIR/privkey.pem"

    # Set permissions before namespace ownership (chmod as root is reliable).
    chmod 0644 "$CERTS_DIR/fullchain.pem" 2>/dev/null || true
    chmod 0600 "$CERTS_DIR/privkey.pem" 2>/dev/null || true

    # Set ownership via the deploy user's subuid namespace so that
    # container UID 101 (nginx) owns the cert files.  Must run as
    # INFRA_USER because rootless podman's subuid map belongs to that user.
    user_uid="$(id -u "$INFRA_USER")"
    if runuser -u "$INFRA_USER" -- env XDG_RUNTIME_DIR="/run/user/$user_uid" \
         podman unshare chown ${NGINX_UID}:${NGINX_GID} \
           "$CERTS_DIR/fullchain.pem" "$CERTS_DIR/privkey.pem"; then
        echo -e "  ${GREEN}✓ Set ownership to ${NGINX_UID}:${NGINX_GID} (via $INFRA_USER namespace)${NC}"
    else
        echo -e "  ${RED}✗ Podman unshare ownership failed for $APP_NAME${NC}" >&2
        FAILED_APPS+=("$APP_NAME")
        echo ""
        continue
    fi
    
    echo -e "  ${GREEN}✓ Set permissions: fullchain.pem (0644), privkey.pem (0600)${NC}"
    
    # Display certificate info
    echo -e "  ${YELLOW}Certificate details:${NC}"
    openssl x509 -in "$CERT_PATH/cert.pem" -noout -subject -dates 2>/dev/null | sed 's/^/    /' || true
    
    SUCCESSFUL_APPS+=("$APP_NAME")
    restart_nginx_for_app "$APP_DIR"
    echo -e "  ${GREEN}✓ $APP_NAME complete${NC}"
    echo ""
done

# Summary
echo -e "${BLUE}========== Installation Summary ==========${NC}"
echo ""

if [[ ${#SUCCESSFUL_APPS[@]} -gt 0 ]]; then
    echo -e "${GREEN}Successfully installed to:${NC}"
    for app in "${SUCCESSFUL_APPS[@]}"; do
        echo -e "  ${GREEN}✓ $app${NC}"
    done
    echo ""
fi

if [[ ${#FAILED_APPS[@]} -gt 0 ]]; then
    echo -e "${RED}Failed to install to:${NC}"
    for app in "${FAILED_APPS[@]}"; do
        echo -e "  ${RED}✗ $app${NC}"
    done
    echo ""
    exit 1
fi

echo -e "${GREEN}========== All installations successful! ==========${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo -e "  1. Verify certificates: ./verify-certs-in-apps-weekly.sh${NC}"
echo -e "  2. If any nginx was not restarted above: podman restart <service>-nginx${NC}"
echo -e "  3. Full stack restart (optional): sudo ./restart-containers-apis.sh${NC}"
echo ""
