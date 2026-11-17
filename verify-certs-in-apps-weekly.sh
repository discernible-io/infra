#!/usr/bin/env bash
# Verify TLS certificates and secrets.env under all app directories.
# Usage: ./verify-certs-in-apps-weekly.sh
#
# Checks per app:
#   certs/              mode 0711
#   certs/*.pem         modes and nginx ownership (UID/GID 101 in container namespace)
#   secrets/            mode 0750 or 0755
#   secrets/secrets.env mode 0644, readable for --env-file
#
# Apps and domains come from infra-env-helper.sh (INFRA_APP_DOMAINS).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=infra-env-helper.sh
source "$SCRIPT_DIR/infra-env-helper.sh"
if ! declare -F infra_cert_san_domains_for &>/dev/null; then
  # shellcheck source=infra-env-helper-shared.sh
  source "$SCRIPT_DIR/infra-env-helper-shared.sh"
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

NGINX_UID=101
NGINX_GID=101
ISSUES_FOUND=0
WARNINGS_FOUND=0

# Return 0 if $1 mode is listed in "${@:2}".
mode_is_one_of() {
    local mode="$1"
    shift
    local m
    for m in "$@"; do
        [[ "$mode" == "$m" ]] && return 0
    done
    return 1
}

# Print host stat line; increment ISSUES_FOUND if path missing and $2 is "required".
print_host_stat() {
    local path="$1"
    local required="${2:-optional}"
    if [[ ! -e "$path" ]]; then
        if [[ "$required" == "required" ]]; then
            echo -e "  ${RED}✗ Missing: $path${NC}"
            ((ISSUES_FOUND++)) || true
        else
            echo -e "  ${YELLOW}⚠ Not present: $path${NC}"
        fi
        return 1
    fi
    local mode owner
    mode=$(stat -c '%a' "$path")
    owner=$(stat -c '%U:%G (%u:%g)' "$path")
    echo -e "  ${YELLOW}$path${NC}"
    echo -e "    mode: $mode  owner: $owner"
    return 0
}

# Container-namespace ownership via podman unshare (maps nginx UID 101).
print_container_stat() {
    local path="$1"
    local line ns
    if ! command -v podman >/dev/null 2>&1; then
        echo -e "    ${YELLOW}(podman not available — skipping container-namespace ownership check)${NC}"
        return 0
    fi
    if ! line=$(podman unshare stat -c '%u:%g %a' "$path" 2>/dev/null); then
        echo -e "    ${YELLOW}(podman unshare stat failed — skipping container-namespace ownership check)${NC}"
        return 0
    fi
    ns="${line%% *}"
    echo -e "    container namespace: $line (expect ${NGINX_UID}:${NGINX_GID})"
    if [[ "$ns" != "${NGINX_UID}:${NGINX_GID}" ]]; then
        echo -e "    ${YELLOW}⚠ Warning: PEM not owned by nginx UID ${NGINX_UID} in container namespace${NC}"
        ((WARNINGS_FOUND++)) || true
    fi
}

check_mode() {
    local path="$1"
    local label="$2"
    shift 2
    local acceptable=("$@")
    local mode
    mode=$(stat -c '%a' "$path" 2>/dev/null || echo "")
    if [[ -z "$mode" ]]; then
        return 1
    fi
    if mode_is_one_of "$mode" "${acceptable[@]}"; then
        echo -e "  ${GREEN}✓ $label mode $mode OK${NC}"
        return 0
    fi
    echo -e "  ${YELLOW}⚠ $label mode $mode (expected: ${acceptable[*]})${NC}"
    ((WARNINGS_FOUND++)) || true
    return 0
}

echo -e "${BLUE}========== App TLS and Secrets Verification ==========${NC}"
echo ""

for APP_DIR in "${!INFRA_APP_DOMAINS[@]}"; do
    DOMAIN="${INFRA_APP_DOMAINS[$APP_DIR]}"
    APP_NAME=$(basename "$APP_DIR")
    CERTS_DIR="$APP_DIR/certs"
    ENV_REL_PATH="${INFRA_APP_ENV_FILES[$APP_DIR]:-secrets/secrets.env}"
    ENV_FILE="$APP_DIR/$ENV_REL_PATH"
    ENV_DIR="$(dirname "$ENV_FILE")"
    ENV_BASENAME="$(basename "$ENV_FILE")"

    echo -e "${YELLOW}=== $APP_NAME ($DOMAIN) ===${NC}"

    if [[ ! -d "$APP_DIR" ]]; then
        echo -e "  ${YELLOW}⚠ App directory not found: $APP_DIR${NC}"
        ((ISSUES_FOUND++)) || true
        echo ""
        continue
    fi

    # --- TLS certificates ---
    echo -e "  ${BLUE}TLS certificates${NC}"

    # Empty INFRA_APP_DOMAINS value = outbound-only / no public TLS (e.g. livekitworker).
    # Layout may still have certs/; do not require LE PEMs or hostname match.
    if [[ -z "$DOMAIN" ]]; then
        echo -e "  ${GREEN}✓ No public domain — skipping LE PEM / hostname checks${NC}"
        if [[ -d "$CERTS_DIR" ]]; then
            check_mode "$CERTS_DIR" "certs/" 711
            print_host_stat "$CERTS_DIR"
        else
            echo -e "  ${YELLOW}⚠ Certs directory not present (optional for outbound-only apps)${NC}"
        fi
    elif [[ ! -d "$CERTS_DIR" ]]; then
        echo -e "  ${RED}✗ Certs directory missing: $CERTS_DIR${NC}"
        ((ISSUES_FOUND++)) || true
    else
        check_mode "$CERTS_DIR" "certs/" 711
        print_host_stat "$CERTS_DIR"

        for pem in fullchain.pem privkey.pem; do
            pem_path="$CERTS_DIR/$pem"
            if [[ ! -f "$pem_path" ]]; then
                echo -e "  ${RED}✗ Missing $pem${NC}"
                ((ISSUES_FOUND++)) || true
                continue
            fi
            echo -e "  ${GREEN}✓ $pem exists${NC}"
            print_host_stat "$pem_path"
            if [[ "$pem" == "fullchain.pem" ]]; then
                check_mode "$pem_path" "fullchain.pem" 644 440
            else
                check_mode "$pem_path" "privkey.pem" 600 400
            fi
            print_container_stat "$pem_path"
        done

        if [[ -f "$CERTS_DIR/fullchain.pem" ]]; then
            echo -e "  ${YELLOW}Certificate validity:${NC}"
            openssl x509 -in "$CERTS_DIR/fullchain.pem" -noout -subject -dates 2>/dev/null \
                | sed 's/^/    /' || echo "    (Could not read certificate)"

            if host_check=$(openssl x509 -in "$CERTS_DIR/fullchain.pem" -noout -checkhost "$DOMAIN" 2>&1); then
                echo -e "  ${GREEN}✓ Certificate matches $DOMAIN${NC}"
            else
                echo -e "  ${RED}✗ Certificate does not match $DOMAIN${NC}"
                echo "$host_check" | sed 's/^/    /'
                ((ISSUES_FOUND++)) || true
            fi

            if declare -F infra_cert_san_domains_for &>/dev/null; then
                san_list="$(infra_cert_san_domains_for "$DOMAIN")"
                if [[ -n "$san_list" ]]; then
                    read -r -a san_domains <<< "$san_list"
                    for san_domain in "${san_domains[@]}"; do
                        [[ -n "$san_domain" ]] || continue
                        if openssl x509 -in "$CERTS_DIR/fullchain.pem" -noout -checkhost "$san_domain" >/dev/null 2>&1; then
                            echo -e "  ${GREEN}✓ Certificate matches SAN $san_domain${NC}"
                        else
                            echo -e "  ${RED}✗ Certificate does not match SAN $san_domain${NC}"
                            ((ISSUES_FOUND++)) || true
                        fi
                    done
                fi
            fi
        fi
    fi

    # --- Runtime env file ---
    echo -e "  ${BLUE}$ENV_REL_PATH${NC}"

    if [[ "$ENV_DIR" != "$APP_DIR" ]]; then
        if [[ ! -d "$ENV_DIR" ]]; then
            echo -e "  ${RED}✗ Env directory missing: $ENV_DIR${NC}"
            ((ISSUES_FOUND++)) || true
        else
            check_mode "$ENV_DIR" "$(basename "$ENV_DIR")/" 750 755
            print_host_stat "$ENV_DIR"
        fi
    fi

    if [[ ! -f "$ENV_FILE" ]]; then
        echo -e "  ${RED}✗ Missing $ENV_BASENAME: $ENV_FILE${NC}"
        ((ISSUES_FOUND++)) || true
    else
        echo -e "  ${GREEN}✓ $ENV_BASENAME exists${NC}"
        print_host_stat "$ENV_FILE"

        if [[ "$ENV_REL_PATH" == "secrets/secrets.env" ]]; then
            check_mode "$ENV_FILE" "$ENV_BASENAME" 644

            # World-readable file is intentional for --env-file; flag tighter modes.
            env_mode=$(stat -c '%a' "$ENV_FILE")
            if [[ "$env_mode" == "600" || "$env_mode" == "640" ]]; then
                echo -e "  ${YELLOW}⚠ $ENV_BASENAME is $env_mode — confirm the deploy user/container can still read it${NC}"
                ((WARNINGS_FOUND++)) || true
            fi
        else
            check_mode "$ENV_FILE" "$ENV_BASENAME" 600 640 644
        fi
    fi

    echo ""
done

echo -e "${BLUE}========== Verification Summary ==========${NC}"

if [[ $ISSUES_FOUND -eq 0 && $WARNINGS_FOUND -eq 0 ]]; then
    echo -e "${GREEN}✓ All apps: certificates and secrets.env look correct${NC}"
    exit 0
elif [[ $ISSUES_FOUND -eq 0 ]]; then
    echo -e "${YELLOW}⚠ No critical issues; $WARNINGS_FOUND warning(s) — review output above${NC}"
    exit 0
else
    echo -e "${RED}✗ Found $ISSUES_FOUND issue(s)${NC}"
    [[ $WARNINGS_FOUND -gt 0 ]] && echo -e "${YELLOW}  and $WARNINGS_FOUND warning(s)${NC}"
    echo -e "${YELLOW}Certs: sudo ./install-certs-to-apps.sh${NC}"
    echo -e "${YELLOW}Runtime env: ensure each configured env file exists with expected permissions${NC}"
    exit 1
fi
