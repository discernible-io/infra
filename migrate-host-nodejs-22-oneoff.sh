#!/usr/bin/env bash
# Switch this host from NodeSource Node 20 to the pinned Node 22.23.4 line.
#
# Why: cicd-deployment-standard / coding-standard pin builders and CI to
# node:22.23.4 (Node 20 has no CVE-2026-111497 fix). Local deploy scripts and
# npm engines expect the same host patch.
#
# Usage (from your terminal — needs an interactive sudo password):
#   ~/infra/migrate-host-nodejs-22-oneoff.sh
#   sudo ~/infra/migrate-host-nodejs-22-oneoff.sh
#
# Idempotent: re-running with 22.23.4 already installed exits 0 after verify.
set -euo pipefail

TARGET_VERSION="${TARGET_VERSION:-22.23.4}"
NODE_MAJOR="${NODE_MAJOR:-22}"
NS_KEY_URL="https://rpm.nodesource.com/gpgkey/ns-operations-public.key"
NS_BASE="https://rpm.nodesource.com/pub_${NODE_MAJOR}.x/nodistro"

if [[ "${EUID}" -ne 0 ]]; then
  exec sudo -E bash "$0" "$@"
fi

SYS_ARCH="$(uname -m)"
case "$SYS_ARCH" in
  x86_64|aarch64) ;;
  *)
    echo "Unsupported architecture: $SYS_ARCH" >&2
    exit 1
    ;;
esac

echo "==> Current Node (if any)"
command -v node >/dev/null 2>&1 && node -v || echo "(node not on PATH yet)"
rpm -q nodejs 2>/dev/null || true

echo "==> Replace NodeSource yum repos with pub_${NODE_MAJOR}.x"
rm -f /etc/yum.repos.d/nodesource*.repo
cat >/etc/yum.repos.d/nodesource-nodejs.repo <<EOF
[nodesource-nodejs]
name=Node.js Packages for Linux RPM based distros - ${SYS_ARCH}
baseurl=${NS_BASE}/nodejs/${SYS_ARCH}
priority=9
enabled=1
gpgcheck=1
gpgkey=${NS_KEY_URL}
module_hotfixes=1
EOF

# N|Solid channel is optional; keep it aligned so stale 20.x metadata cannot win.
cat >/etc/yum.repos.d/nodesource-nsolid.repo <<EOF
[nodesource-nsolid]
name=N|Solid Packages for Linux RPM based distros - ${SYS_ARCH}
baseurl=${NS_BASE}/nsolid/${SYS_ARCH}
priority=9
enabled=1
gpgcheck=1
gpgkey=${NS_KEY_URL}
module_hotfixes=1
EOF

rpm --import "$NS_KEY_URL" 2>/dev/null || true
dnf clean all -q
dnf makecache -q --repo=nodesource-nodejs

echo "==> Install nodejs-${TARGET_VERSION} (exact patch pin)"
# Epoch 2: matches NodeSource package NEVRA (e.g. 2:22.23.4-1nodesource).
dnf install -y "nodejs-${TARGET_VERSION}"

echo "==> Verify"
NODE_BIN="$(command -v node)"
NPM_BIN="$(command -v npm)"
INSTALLED="$(node -v | sed 's/^v//')"
echo "    node: ${NODE_BIN} -> $(node -v)"
echo "    npm:  ${NPM_BIN} -> $(npm -v)"
rpm -q nodejs

if [[ "$INSTALLED" != "$TARGET_VERSION" ]]; then
  echo "ERROR: expected Node ${TARGET_VERSION}, got ${INSTALLED}" >&2
  exit 1
fi

echo "==> Host Node migrated to ${TARGET_VERSION}"
