#!/usr/bin/env bash
# Create ~/infra-app (host-local, never commit) and install a profile.
#
# New users:
#   ./bootstrap-infra-app.sh              # example profile if missing; status if present
#   ./bootstrap-infra-app.sh custom       # interactive domain/port/email
#   ./bootstrap-infra-app.sh example --with-app-dirs
#
# Named fleet templates (from infra-env-helper.md):
#   ./bootstrap-infra-app.sh <profile>
#   INFRA_APP_DIR=/path/to/infra-app ./bootstrap-infra-app.sh example
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_REPO="${INFRA_REPO:-$SCRIPT_DIR}"
INFRA_APP_DIR="${INFRA_APP_DIR:-$(cd "${INFRA_REPO}/.." && pwd)/infra-app}"
HOST_PROFILE="${INFRA_APP_DIR}/infra-env-helper.sh"

WITH_APP_DIRS=0
STATUS_ONLY=0
PROFILE_NAME=""

usage() {
  cat <<EOF
Usage: $0 [profile] [--with-app-dirs] [--status]

Creates ${INFRA_APP_DIR}/ and writes infra-env-helper.sh for this machine.
Does not overwrite an existing profile (move it aside first to regenerate).

Profiles:
  (none)     If no profile exists, install 'example'. If one exists, print status.
  example    Generic single-app host (api.example.com:5443)
  custom     Interactive prompts (user, domain, port, email, 443 redirect)
  <name>     Named template from infra-env-helper.md (if present)

Flags:
  --with-app-dirs   Also create *-app trees (certs/, secrets/, …) from the profile
  --status          Print the loaded profile without writing files
  -h, --help        This help

Host config lives only in infra-app. Per-service runtime secrets stay in each
~/<service>-app/secrets/ (created by bootstrap-app-dir-layout.sh) because
containers load them with --env-file. Do not copy those files into git.
EOF
}

print_status() {
  if [[ ! -f "$HOST_PROFILE" ]]; then
    echo "No host profile at $HOST_PROFILE"
    echo "Run: $0 example"
    return 1
  fi
  # shellcheck source=/dev/null
  bash -c "source '${INFRA_REPO}/infra-env-helper.sh' &&
    echo \"INFRA_USER=\$INFRA_USER\" &&
    echo \"INFRA_HOME=\$INFRA_HOME\" &&
    echo \"INFRA_APP_DIR=\$INFRA_APP_DIR\" &&
    echo \"INFRA_CERT_EMAIL=\${INFRA_CERT_EMAIL:-}\" &&
    echo \"INFRA_PORT_FORWARD_SERVICE=\${INFRA_PORT_FORWARD_SERVICE:-}\" &&
    echo \"ports=\${!INFRA_API_PORTS[*]}\""
}

write_example_profile() {
  local user
  user="$(id -un)"
  cat >"$HOST_PROFILE" <<EOF
#!/usr/bin/env bash
# example — host-local profile for ~/infra-app (never commit).

: "\${INFRA_REPO:?INFRA_REPO must be set by the infra checkout loader}"

INFRA_USER="\${INFRA_USER:-${user}}"
INFRA_HOME="\${INFRA_HOME:-/home/\${INFRA_USER}}"

INFRA_CERT_DOMAINS=(
  "api.example.com"
)

declare -gA INFRA_APP_DOMAINS=(
  ["\${INFRA_HOME}/api-app"]="api.example.com"
)

declare -gA INFRA_APP_ENV_FILES=(
  ["\${INFRA_HOME}/api-app"]="secrets/secrets.env"
)

declare -gA INFRA_API_PORTS=(
  [api]=5443
)

INFRA_PORT_FORWARD_SERVICE="\${INFRA_PORT_FORWARD_SERVICE:-api}"
INFRA_MONITOR_SERVICES=(
  "api:api-container::5443"
)

INFRA_CERT_EMAIL="\${INFRA_CERT_EMAIL:-admin@example.com}"

# shellcheck source=/dev/null
source "\${INFRA_REPO}/infra-env-helper-shared.sh"
EOF
}

write_custom_profile() {
  local user domain service port email redirect
  user="$(id -un)"
  echo "Interactive host profile (written to ${HOST_PROFILE})"
  echo "Press Enter to accept the default in [brackets]."
  read -r -p "INFRA_USER [${user}]: " user_in
  user="${user_in:-$user}"
  read -r -p "Primary domain [api.example.com]: " domain
  domain="${domain:-api.example.com}"
  read -r -p "Service name [api]: " service
  service="${service:-api}"
  read -r -p "API listen port [5443]: " port
  port="${port:-5443}"
  read -r -p "Let's Encrypt email [admin@${domain#*.}]: " email
  email="${email:-admin@${domain#*.}}"
  read -r -p "Redirect TCP 443 to ${port}? [Y/n]: " redirect
  redirect="${redirect:-Y}"

  local port_forward=""
  if [[ "$redirect" =~ ^[Yy] ]]; then
    port_forward="INFRA_PORT_FORWARD_SERVICE=\"\${INFRA_PORT_FORWARD_SERVICE:-${service}}\""
  fi

  cat >"$HOST_PROFILE" <<EOF
#!/usr/bin/env bash
# custom — host-local profile for ~/infra-app (never commit).

: "\${INFRA_REPO:?INFRA_REPO must be set by the infra checkout loader}"

INFRA_USER="\${INFRA_USER:-${user}}"
INFRA_HOME="\${INFRA_HOME:-/home/\${INFRA_USER}}"

INFRA_CERT_DOMAINS=(
  "${domain}"
)

declare -gA INFRA_APP_DOMAINS=(
  ["\${INFRA_HOME}/${service}-app"]="${domain}"
)

declare -gA INFRA_APP_ENV_FILES=(
  ["\${INFRA_HOME}/${service}-app"]="secrets/secrets.env"
)

declare -gA INFRA_API_PORTS=(
  [${service}]=${port}
)

${port_forward}
INFRA_MONITOR_SERVICES=(
  "${service}:${service}-container::${port}"
)

INFRA_CERT_EMAIL="\${INFRA_CERT_EMAIL:-${email}}"

# shellcheck source=/dev/null
source "\${INFRA_REPO}/infra-env-helper-shared.sh"
EOF
}

emit_profile_from_md() {
  local host="$1"
  local md="${INFRA_REPO}/infra-env-helper.md"
  python3 - "$md" "$host" <<'PY'
import re, sys
md_path, host = sys.argv[1], sys.argv[2]
text = open(md_path, encoding="utf-8").read()
heading_re = re.compile(rf"^## {re.escape(host)}\b.*$", re.M)
matches = list(heading_re.finditer(text))
section = None
for m in matches:
    line = m.group(0)
    if "(alternate" in line:
        continue
    start = m.start()
    nxt = re.search(r"^## ", text[m.end():], re.M)
    end = m.end() + nxt.start() if nxt else len(text)
    section = text[start:end]
    break
if not section:
    sys.exit(2)
body = None
for m in re.finditer(r"(?ms)^```bash\n(.*?)^```", section):
    candidate = m.group(1)
    if "INFRA_USER=" in candidate and "infra-env-helper-shared.sh" in candidate:
        body = candidate
        break
if body is None:
    sys.exit(2)
body = re.sub(r"(?m)^_INFRA_ENV_DIR=.*\n", "", body)
body = re.sub(r"(?m)^INFRA_REPO=.*\n", "", body)
if "INFRA_REPO:?" not in body:
    body = (
        "#!/usr/bin/env bash\n"
        f"# {host} — host-local profile (lives in ~/infra-app/, never commit).\n"
        "# Loaded by ~/infra/infra-env-helper.sh; INFRA_REPO must already be set.\n\n"
        ': "${INFRA_REPO:?INFRA_REPO must be set by the infra checkout loader}"\n\n'
        + re.sub(r"(?m)^#!/usr/bin/env bash\n", "", body, count=1)
    )
body = body.replace(
    'source "${_INFRA_ENV_DIR}/infra-env-helper-shared.sh"',
    'source "${INFRA_REPO}/infra-env-helper-shared.sh"',
)
if 'source "${INFRA_REPO}/infra-env-helper-shared.sh"' not in body:
    body = (
        body.rstrip()
        + '\n\n# shellcheck source=/dev/null\nsource "${INFRA_REPO}/infra-env-helper-shared.sh"\n'
    )
sys.stdout.write(body if body.endswith("\n") else body + "\n")
PY
}

seed_host_local_files() {
  local wallet_dst="${INFRA_APP_DIR}/roditwallet.env"
  if [[ ! -f "$wallet_dst" ]]; then
    cat >"$wallet_dst" <<'EOF'
# Optional NEAR RPC overrides for idcp-wallet.sh (host-local; do not commit).
# Uncomment one:
# export NEAR_NETWORK_CONFIG="mainnet-lava"
# export NEAR_NETWORK_CONFIG="mainnet-fastnear"
# export NEAR_NETWORK_CONFIG="testnet-lava"
EOF
    chmod 640 "$wallet_dst"
    echo "Installed: $wallet_dst"
  fi

  local manifest="${INFRA_APP_DIR}/trivy-scan-results/scan-image-manifest.txt"
  if [[ ! -f "$manifest" ]]; then
    cat >"$manifest" <<'EOF'
# Optional extra images for scan-containers-vulnerabilities-weekly.sh
# One image reference per line, comments allowed.
EOF
    chmod 640 "$manifest"
    echo "Installed: $manifest"
  fi
}

write_app_readme() {
  cat >"${INFRA_APP_DIR}/README.md" <<EOF
# infra-app (host-local)

Sibling of the \`infra\` git checkout. **Do not commit** this directory.

| Path | Purpose |
|------|---------|
| \`infra-env-helper.sh\` | This host's domains, ports, app→env map, monitor list |
| \`roditwallet.env\` | Optional NEAR RPC overrides for \`idcp-wallet.sh\` |
| \`maintenance-status.md\` | Installed timers, firewall snapshot, hardening on **this** machine |
| \`trivy-scan-results/\` | Weekly Trivy reports / SBOM (script output) |
| \`mail/smtp.env\` | SMTP accounts for \`manage-mail-sender.sh\` (server, account emails) |
| \`mail/smtp-password.<account>\` | SMTP password per account (legacy \`smtp-password\` for the default) |

Shared scripts stay in the \`infra\` checkout. Per-service runtime secrets stay
in each \`~/<service>-app/secrets/\` (or \`env.local\` / \`.env\`) because
containers load them with \`--env-file\`. Create those trees with
\`bootstrap-app-dir-layout.sh\` after editing this profile.

Override with \`INFRA_APP_DIR\` / \`INFRA_OUTPUT_DIR\` / \`INFRA_TRIVY_RESULTS_DIR\`.
EOF
}

for arg in "$@"; do
  case "$arg" in
    -h|--help|help) usage; exit 0 ;;
    --with-app-dirs) WITH_APP_DIRS=1 ;;
    --status) STATUS_ONLY=1 ;;
    -i|--interactive|custom) PROFILE_NAME="custom" ;;
    -*)
      echo "Unknown flag: $arg" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [[ -n "$PROFILE_NAME" ]]; then
        echo "Unexpected extra argument: $arg" >&2
        usage >&2
        exit 1
      fi
      PROFILE_NAME="$arg"
      ;;
  esac
done

if [[ "$STATUS_ONLY" -eq 1 ]]; then
  print_status
  exit $?
fi

if [[ -z "$PROFILE_NAME" ]]; then
  if [[ -f "$HOST_PROFILE" ]]; then
    echo "Already bootstrapped: $HOST_PROFILE"
    print_status || true
    if [[ "$WITH_APP_DIRS" -eq 1 ]]; then
      "${INFRA_REPO}/bootstrap-app-dir-layout.sh"
    else
      echo ""
      echo "Edit the profile, then:"
      echo "  $0 --with-app-dirs"
      echo "  sudo ${INFRA_REPO}/setup-host-oneoff.sh"
    fi
    exit 0
  fi
  PROFILE_NAME="example"
  echo "No host profile yet — installing '${PROFILE_NAME}' into ${INFRA_APP_DIR}"
fi

case "$PROFILE_NAME" in
  example|custom|dedalo42|dedalo44|dedalo46|dedalo47|dedalo43) ;;
  *)
    echo "Unknown profile: $PROFILE_NAME" >&2
    usage >&2
    exit 1
    ;;
esac

mkdir -p "$INFRA_APP_DIR" "${INFRA_APP_DIR}/trivy-scan-results"
chmod 750 "$INFRA_APP_DIR" "${INFRA_APP_DIR}/trivy-scan-results"

# Copy the committed scan-image example only (seed_host_local_files).
# Do not move leftover reports out of the git checkout.

if [[ -f "$HOST_PROFILE" ]]; then
  echo "Already exists: $HOST_PROFILE"
  echo "Output dir: ${INFRA_APP_DIR}/trivy-scan-results"
  echo "Edit the profile in place, or move it aside and re-run to regenerate."
  seed_host_local_files
  write_app_readme
  if [[ "$WITH_APP_DIRS" -eq 1 ]]; then
    "${INFRA_REPO}/bootstrap-app-dir-layout.sh"
  fi
  exit 0
fi

case "$PROFILE_NAME" in
  example) write_example_profile ;;
  custom) write_custom_profile ;;
  *)
    if ! emit_profile_from_md "$PROFILE_NAME" >"$HOST_PROFILE"; then
      rm -f "$HOST_PROFILE"
      echo "Could not extract profile '$PROFILE_NAME' from infra-env-helper.md" >&2
      echo "Use: $0 custom   or copy a bash block from infra-env-helper.md" >&2
      exit 1
    fi
    ;;
esac

chmod 640 "$HOST_PROFILE"
seed_host_local_files
write_app_readme

MAINT_STATUS="${INFRA_APP_DIR}/maintenance-status.md"
if [[ ! -f "$MAINT_STATUS" ]]; then
  EXAMPLE="${INFRA_REPO}/docs/maintenance-status.example.md"
  if [[ -f "$EXAMPLE" ]]; then
    sed "s/HOSTNAME/${PROFILE_NAME}/; s/YYYY-MM-DD/$(date +%Y-%m-%d)/" "$EXAMPLE" >"$MAINT_STATUS"
  else
    cat >"$MAINT_STATUS" <<EOF
# Maintenance status — ${PROFILE_NAME}

Host-local installed automation. See ${INFRA_REPO}/docs/maintenance-status-roadmap.md.

Last updated: $(date +%Y-%m-%d)
EOF
  fi
  chmod 640 "$MAINT_STATUS"
  echo "Installed: $MAINT_STATUS"
fi

echo "Installed: $HOST_PROFILE"
echo "Outputs:   ${INFRA_APP_DIR}/trivy-scan-results"
echo "Verify:    $0 --status"

if [[ "$WITH_APP_DIRS" -eq 1 ]]; then
  "${INFRA_REPO}/bootstrap-app-dir-layout.sh"
else
  echo ""
  echo "Next:"
  echo "  1. Edit ${HOST_PROFILE} (domains, ports, INFRA_CERT_EMAIL)"
  echo "  2. ${INFRA_REPO}/bootstrap-app-dir-layout.sh"
  echo "  3. Fill secrets in each ~/<service>-app/secrets/secrets.env"
  echo "  4. sudo ${INFRA_REPO}/setup-host-oneoff.sh"
fi
