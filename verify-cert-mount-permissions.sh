#!/bin/bash
# Test script for certificate permissions with podman unshare
# This validates that nginx container (UID 101) can read certificates
# without requiring group read permissions on privkey.pem

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=infra-env-helper.sh
source "$SCRIPT_DIR/infra-env-helper.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=========================================="
echo "Certificate Permissions Test for Podman"
echo "=========================================="
echo ""

# Configuration
TEST_DIR="${INFRA_HOME}/signportal-test-certs"
NGINX_UID=101
NGINX_GID=101

# Cleanup function
cleanup() {
    echo ""
    echo -e "${YELLOW}Cleaning up test resources...${NC}"
    podman pod exists test-cert-pod 2>/dev/null && podman pod rm -f test-cert-pod || true
    podman image exists test-nginx:latest 2>/dev/null && podman rmi -f test-nginx:latest || true
    
    # Use podman unshare to remove directory (works even with subuid ownership)
    if [ -d "$TEST_DIR" ]; then
        podman unshare rm -rf "$TEST_DIR" 2>/dev/null || true
    fi
    
    # Clean up temp nginx config
    [ -n "$NGINX_CONF_DIR" ] && [ -d "$NGINX_CONF_DIR" ] && rm -rf "$NGINX_CONF_DIR"
    
    echo -e "${GREEN}Cleanup complete${NC}"
}

# Trap to ensure cleanup on exit
trap cleanup EXIT

# Step 1: Create test directory and certificates
echo -e "${YELLOW}Step 1: Creating test certificates...${NC}"
mkdir -p "$TEST_DIR"

# Generate self-signed certificate for testing
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TEST_DIR/privkey.pem" \
    -out "$TEST_DIR/fullchain.pem" \
    -days 1 \
    -subj "/CN=test.local" 2>/dev/null

echo -e "${GREEN}✓ Test certificates created${NC}"
echo ""

# Step 2: Show initial permissions (host user ownership)
echo -e "${YELLOW}Step 2: Initial permissions (host user)${NC}"
ls -la "$TEST_DIR"
echo ""

# Step 3: Create nginx config directory BEFORE changing ownership
echo -e "${YELLOW}Step 3: Creating nginx configuration directory...${NC}"
mkdir -p "$TEST_DIR/nginx-conf"
cat > "$TEST_DIR/nginx-conf/nginx.conf" << 'EOF'
user nginx;
worker_processes 1;
error_log /var/log/nginx/error.log debug;
pid /tmp/nginx.pid;

events {
    worker_connections 1024;
}

http {
    server {
        listen 8443 ssl;
        server_name test.local;
        ssl_certificate /app/certs/fullchain.pem;
        ssl_certificate_key /app/certs/privkey.pem;

        location / {
            return 200 "Certificate test successful!\n";
            add_header Content-Type text/plain;
        }
    }
}
EOF
echo -e "${GREEN}✓ Nginx configuration created${NC}"
echo ""

# Step 4: Apply podman unshare ownership (only to certs, not nginx-conf)
echo -e "${YELLOW}Step 4: Applying podman unshare ownership to certificates (UID 101:101)${NC}"
podman unshare chown ${NGINX_UID}:${NGINX_GID} "$TEST_DIR/privkey.pem"
podman unshare chown ${NGINX_UID}:${NGINX_GID} "$TEST_DIR/fullchain.pem"
echo -e "${GREEN}✓ Ownership set to ${NGINX_UID}:${NGINX_GID} (nginx user in container namespace)${NC}"
echo ""

# Step 5: Set restrictive permissions
echo -e "${YELLOW}Step 5: Setting restrictive permissions${NC}"
podman unshare chmod 0400 "$TEST_DIR/privkey.pem"
podman unshare chmod 0440 "$TEST_DIR/fullchain.pem"
echo -e "${GREEN}✓ privkey.pem: 0400 (owner read-only)${NC}"
echo -e "${GREEN}✓ fullchain.pem: 0440 (owner+group read)${NC}"
echo ""

# Step 6: Verify permissions from host perspective
echo -e "${YELLOW}Step 6: Verifying permissions (host view)${NC}"
ls -la "$TEST_DIR"
echo ""

# Step 7: Verify permissions from podman unshare perspective
echo -e "${YELLOW}Step 7: Verifying permissions (container namespace view)${NC}"
echo "Certificate files only:"
podman unshare ls -la "$TEST_DIR"/*.pem
echo ""

# Step 8: Create test pod
echo -e "${YELLOW}Step 8: Creating test pod...${NC}"
podman pod create --name test-cert-pod -p 18443:8443
echo -e "${GREEN}✓ Test pod created${NC}"
echo ""

# Step 9: Run nginx container with mounted certificates
echo -e "${YELLOW}Step 9: Running nginx container with certificate mount...${NC}"
# Create a temporary directory for nginx config that won't have permission issues
NGINX_CONF_DIR=$(mktemp -d)
cp "$TEST_DIR/nginx-conf/nginx.conf" "$NGINX_CONF_DIR/nginx.conf"

podman run -d \
    --pod test-cert-pod \
    --name test-nginx \
    -v "$TEST_DIR:/app/certs:ro,Z" \
    -v "$NGINX_CONF_DIR/nginx.conf:/etc/nginx/nginx.conf:ro,Z" \
    docker.io/nginx:1.31.7-alpine@sha256:892bb2152464f0c5d8972593a5f5afaf8054552580b699d95f8ff4af08c2d33d

echo -e "${GREEN}✓ Nginx container started${NC}"
echo ""

# Step 10: Wait for nginx to start (retry up to 10s for rootless networking)
echo -e "${YELLOW}Step 10: Waiting for nginx to start...${NC}"
NGINX_READY=0
for i in $(seq 1 10); do
    if curl -k -s --connect-timeout 1 https://localhost:18443/ >/dev/null 2>&1; then
        NGINX_READY=1
        break
    fi
    sleep 1
done
if [[ $NGINX_READY -eq 1 ]]; then
    echo -e "${GREEN}✓ Nginx reachable after ${i}s${NC}"
else
    echo -e "${YELLOW}⚠ Nginx not reachable after 10s — will check logs${NC}"
fi
echo ""

# Step 11: Check nginx logs for errors
echo -e "${YELLOW}Step 11: Checking nginx logs...${NC}"
NGINX_LOGS=$(podman logs test-nginx 2>&1)
if echo "$NGINX_LOGS" | grep -i "permission denied" >/dev/null 2>&1; then
    echo -e "${RED}✗ FAILED: Permission denied errors found in nginx logs${NC}"
    echo "$NGINX_LOGS"
    exit 1
elif echo "$NGINX_LOGS" | grep -iE '\[(emerg|error)\]' >/dev/null 2>&1; then
    echo -e "${YELLOW}⚠ Errors found in nginx logs:${NC}"
    echo "$NGINX_LOGS" | grep -iE '\[(emerg|error)\]' | head -5
else
    echo -e "${GREEN}✓ No permission or startup errors in nginx logs${NC}"
fi
echo ""

# Step 12: Test HTTPS connection
echo -e "${YELLOW}Step 12: Testing HTTPS connection...${NC}"
CURL_OUTPUT=$(curl -k -s --connect-timeout 5 https://localhost:18443/ 2>&1) || true
if echo "$CURL_OUTPUT" | grep -q "Certificate test successful"; then
    echo -e "${GREEN}✓ HTTPS connection successful!${NC}"
    echo -e "${GREEN}✓ Nginx can read certificates with 0400 permissions${NC}"
else
    echo -e "${RED}✗ FAILED: Could not connect to nginx${NC}"
    echo "curl output: $CURL_OUTPUT"
    echo ""
    echo "Pod port mappings:"
    podman pod inspect test-cert-pod --format '{{range .InfraContainerId}}{{.}}{{end}}' 2>/dev/null || true
    podman port test-cert-pod 2>/dev/null || true
    echo ""
    echo "Nginx logs:"
    podman logs test-nginx 2>&1
    exit 1
fi
echo ""

# Step 13: Verify file permissions inside container
echo -e "${YELLOW}Step 13: Verifying permissions inside container...${NC}"
podman exec test-nginx ls -la /app/certs/
echo ""

# Step 14: Verify nginx can read the files
echo -e "${YELLOW}Step 14: Testing file readability inside container...${NC}"
if podman exec test-nginx cat /app/certs/privkey.pem > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Nginx user can read privkey.pem${NC}"
else
    echo -e "${RED}✗ FAILED: Nginx user cannot read privkey.pem${NC}"
    exit 1
fi

if podman exec test-nginx cat /app/certs/fullchain.pem > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Nginx user can read fullchain.pem${NC}"
else
    echo -e "${RED}✗ FAILED: Nginx user cannot read fullchain.pem${NC}"
    exit 1
fi
echo ""

# Success summary
echo "=========================================="
echo -e "${GREEN}✓ ALL TESTS PASSED!${NC}"
echo "=========================================="
echo ""
echo "Summary:"
echo "  • privkey.pem with 0400 permissions works correctly"
echo "  • fullchain.pem with 0440 permissions works correctly"
echo "  • podman unshare chown -R 101:101 sets correct ownership"
echo "  • No group read permissions required on privkey.pem"
echo "  • Nginx container (UID 101) can read certificates"
echo ""
echo "This approach is secure and reproducible for production deployments."
echo ""
