#!/usr/bin/env bash
# Shared helpers for Let's Encrypt certificate operations (httpd + DNS).
# Source from other infra scripts; do not run directly.

# shellcheck disable=SC2034
HTTPD_STARTED_BY_SCRIPT=false
FIREWALL_HTTP_OPENED_BY_SCRIPT=false
CERTBOT_PORT80_REDIRECT_CLEARED=false

open_firewall_http_for_certbot() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # Permanent 80→service REDIRECT (e.g. hermes) steals HTTP-01; drop it for certbot.
    if declare -F infra_purge_nat_redirects_for_source &>/dev/null; then
        echo -e "${YELLOW}Temporarily clearing NAT REDIRECT on port 80 for certificate operation...${NC}"
        infra_purge_nat_redirects_for_source 80
        CERTBOT_PORT80_REDIRECT_CLEARED=true
    elif [[ -f "$script_dir/infra-iptables-helper.sh" ]]; then
        # shellcheck source=infra-iptables-helper.sh
        source "$script_dir/infra-iptables-helper.sh"
        echo -e "${YELLOW}Temporarily clearing NAT REDIRECT on port 80 for certificate operation...${NC}"
        infra_purge_nat_redirects_for_source 80
        CERTBOT_PORT80_REDIRECT_CLEARED=true
    fi

    if iptables -nL INFRA_HOST_FW &>/dev/null 2>&1; then
        echo -e "${YELLOW}Opening port 80 in iptables host firewall for certificate operation...${NC}"
        # temporary: do not iptables-save without NAT REDIRECT (would drop 443→API on disk)
        "$script_dir/configure-host-firewall-oneoff.sh" allow-http-temporary temporary
        FIREWALL_HTTP_OPENED_BY_SCRIPT=true
        echo -e "${GREEN}Opened temporary HTTP via iptables (INFRA_HOST_FW)${NC}"
        return 0
    fi

    echo -e "${YELLOW}No iptables host firewall chain active; port 80 assumed open${NC}"
}

close_firewall_http_after_certbot() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # Always remove the temporary HTTP-01 allow when finishing. deny-http-temporary is
    # idempotent (clears /var/lib/infra/allow-http-temporary and rebuilds the chain),
    # so this is safe even if this process did not open port 80 or the flag was lost.
    if iptables -nL INFRA_HOST_FW &>/dev/null 2>&1; then
        echo -e "${YELLOW}Closing temporary port 80 in iptables host firewall...${NC}"
        "$script_dir/configure-host-firewall-oneoff.sh" deny-http-temporary temporary || true
        echo -e "${GREEN}Closed temporary HTTP via iptables (INFRA_HOST_FW)${NC}"
    elif [[ "${FIREWALL_HTTP_OPENED_BY_SCRIPT:-false}" == true ]]; then
        echo -e "${YELLOW}Closing temporary port 80 flag (firewall chain not active)...${NC}"
        "$script_dir/configure-host-firewall-oneoff.sh" deny-http-temporary temporary || true
    fi
    FIREWALL_HTTP_OPENED_BY_SCRIPT=false

    if [[ "${CERTBOT_PORT80_REDIRECT_CLEARED:-false}" == true ]]; then
        if ! declare -F infra_ensure_port_forward_rules &>/dev/null; then
            # shellcheck source=infra-iptables-helper.sh
            source "$script_dir/infra-iptables-helper.sh"
        fi
        echo -e "${YELLOW}Restoring NAT REDIRECT rules (including port 80 if configured)...${NC}"
        infra_ensure_port_forward_rules || true
        CERTBOT_PORT80_REDIRECT_CLEARED=false
    fi
}

# Installs dig/host (bind-utils) on Alma/RHEL when missing.
ensure_bind_utils() {
    if command -v dig >/dev/null 2>&1; then
        return 0
    fi
    echo -e "${YELLOW}Installing bind-utils (provides dig)...${NC}"
    if command -v dnf >/dev/null 2>&1; then
        dnf install -y bind-utils
    elif command -v yum >/dev/null 2>&1; then
        yum install -y bind-utils
    else
        echo -e "${RED}Cannot install dig: no dnf/yum found${NC}" >&2
        return 1
    fi
}

infra_server_ipv4() {
    local ip
    ip=$(curl -s4 --max-time 10 https://api.ipify.org 2>/dev/null || true)
    if [[ -z "$ip" ]]; then
        ip=$(curl -s4 --max-time 10 ifconfig.me 2>/dev/null || true)
    fi
    if [[ -z "$ip" ]]; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    echo "$ip"
}

# Warn if $1 does not resolve to $2 (expected public IPv4). Returns 0 if OK or unknown.
# Prefer public resolvers; accept a match from any resolver (local caches can lag).
infra_check_dns_a() {
    local domain="$1"
    local expected_ip="$2"
    local resolved resolver matched=0
    local -a seen=()

    ensure_bind_utils || return 1
    if [[ -z "$expected_ip" || "$expected_ip" == "Unable to determine" ]]; then
        echo -e "${YELLOW}⚠ Could not determine server IP; skipping DNS check for $domain${NC}"
        return 0
    fi

    for resolver in "@1.1.1.1" "@8.8.8.8" ""; do
        if [[ -n "$resolver" ]]; then
            resolved=$(dig +time=5 +tries=1 +short A "$domain" "$resolver" 2>/dev/null | grep -E '^[0-9.]+$' | head -n 1)
        else
            resolved=$(dig +time=5 +tries=1 +short A "$domain" 2>/dev/null | grep -E '^[0-9.]+$' | head -n 1)
        fi
        [[ -n "$resolved" ]] || continue
        seen+=("$resolved")
        if [[ "$resolved" == "$expected_ip" ]]; then
            matched=1
            break
        fi
    done

    if [[ "$matched" -eq 1 ]]; then
        echo -e "${GREEN}✓ DNS: $domain → $expected_ip${NC}"
        return 0
    fi
    if [[ ${#seen[@]} -eq 0 ]]; then
        echo -e "${RED}✗ DNS: no A record for $domain (need $expected_ip)${NC}"
        return 1
    fi
    echo -e "${RED}✗ DNS: $domain → ${seen[*]} (expected $expected_ip)${NC}"
    echo -e "${YELLOW}  Authoritative NS may already be correct; wait for cache TTL or flush local resolver.${NC}"
    return 1
}

ensure_httpd_stopped() {
    if systemctl is-active --quiet httpd 2>/dev/null; then
        echo -e "${YELLOW}Stopping httpd...${NC}"
        systemctl stop httpd || true
    fi
    systemctl disable httpd 2>/dev/null || true
    HTTPD_STARTED_BY_SCRIPT=false
}

ensure_httpd_default_ssl_cert() {
    local ssl_conf="/etc/httpd/conf.d/ssl.conf"
    local cert_path="/etc/pki/tls/certs/localhost.crt"
    local key_path="/etc/pki/tls/private/localhost.key"

    if [[ ! -f "$ssl_conf" ]]; then
        return 0
    fi

    if ! grep -Eq "^[[:space:]]*SSLCertificate(File|KeyFile)[[:space:]]+" "$ssl_conf"; then
        return 0
    fi

    if [[ -s "$cert_path" && -s "$key_path" ]]; then
        return 0
    fi

    echo -e "${YELLOW}Creating missing default httpd localhost SSL certificate...${NC}"
    mkdir -p "$(dirname "$cert_path")" "$(dirname "$key_path")"
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$key_path" \
        -out "$cert_path" \
        -days 3650 \
        -subj "/CN=localhost" >/dev/null 2>&1
    chmod 0600 "$key_path"
    chmod 0644 "$cert_path"
}

start_httpd_for_certbot() {
    open_firewall_http_for_certbot

    ensure_httpd_default_ssl_cert

    echo -e "${YELLOW}Testing httpd configuration...${NC}"
    httpd -t

    echo -e "${YELLOW}Starting httpd for certificate operation...${NC}"
    systemctl start httpd
    systemctl reload httpd
    HTTPD_STARTED_BY_SCRIPT=true
}

stop_httpd_after_certbot() {
    if systemctl is-active --quiet httpd 2>/dev/null; then
        echo -e "${YELLOW}Stopping httpd (certificate operation complete)...${NC}"
        systemctl stop httpd || true
    fi
    systemctl disable httpd 2>/dev/null || true
    HTTPD_STARTED_BY_SCRIPT=false
    close_firewall_http_after_certbot
}

setup_httpd_cleanup_trap() {
    trap 'stop_httpd_after_certbot' EXIT
}
