# Host config: `~/infra-app/infra-env-helper.sh`

Machine-specific values live in a **sibling** directory next to the git checkout
(same pattern as `hermes-agents-app`, `idclawserver-app`, …):

```text
~/infra/                 # git — shared scripts only
~/infra-app/             # host-local — never commit
  infra-env-helper.sh    # domains, ports, INFRA_APP_DOMAINS, monitor list
```

The committed file `infra/infra-env-helper.sh` is only a **loader**: it sets
`INFRA_REPO` / `INFRA_APP_DIR` and sources `~/infra-app/infra-env-helper.sh`.
Shared helpers stay in `infra-env-helper-shared.sh` (committed).

Override with `INFRA_APP_DIR` if the app dir is not `$(dirname "$INFRA_REPO")/infra-app`.

**Generated outputs** (Trivy reports, etc.) also go under the sibling app dir:

```text
~/infra-app/
  infra-env-helper.sh
  trivy-scan-results/          # INFRA_TRIVY_RESULTS_DIR (default)
```

Defaults (set in `infra-env-helper-shared.sh`): `INFRA_OUTPUT_DIR=$INFRA_APP_DIR`,
`INFRA_TRIVY_RESULTS_DIR=$INFRA_OUTPUT_DIR/trivy-scan-results`. On other hosts,
`./bootstrap-infra-app.sh` creates the output dir (and may migrate any legacy
`~/infra/trivy-scan-results/*` artifacts into `~/infra-app/`).

Optional pod start map for `start-pod.sh` / liveness (host profile):

```bash
declare -A INFRA_POD_START=(
  [myservice]="my-pod|my-container|${INFRA_HOME}/my-app/deploy.sh|--flag"
)
declare -A INFRA_POD_START_ENV=(
  [myservice]="TARGET=main"
)
# INFRA_MONITOR_SERVICES entry:
#   "myservice:my-container:${INFRA_REPO}/start-pod.sh:8443"
```

**Source of truth for inventories:** host profiles below and
[production-hosts.md](./docs/production-hosts.md). Live values belong in
`~/infra-app/` on each machine, not in git.

## Bootstrap / migrate on another machine

Full operator playbook (preserve profile → update git checkout → populate
`~/infra-app`): [docs/migrate-infra-app.md](./docs/migrate-infra-app.md).

```bash
cd ~/infra
git pull --ff-only

# Preferred: move the old in-repo gitignored profile (if present)
mkdir -p ~/infra-app && chmod 750 ~/infra-app
if [[ -f infra-env-helper.sh ]] && ! grep -q 'INFRA_APP_DIR' infra-env-helper.sh 2>/dev/null; then
  # Git may refuse to overwrite a local file when the loader becomes tracked —
  # move the host profile first, then checkout/pull again if needed.
  mv infra-env-helper.sh ~/infra-app/infra-env-helper.sh
  git checkout -- infra-env-helper.sh   # get the committed loader
fi

# Or install a fresh profile from the templates in this file:
./bootstrap-infra-app.sh example   # or dedalo42|dedalo44|dedalo46|dedalo47|dedalo43

# Fix the shared source line if you moved a legacy file:
#   source "${INFRA_REPO}/infra-env-helper-shared.sh"
# and ensure the profile does NOT set INFRA_REPO from its own dirname.

bash -c 'source ~/infra/infra-env-helper.sh && echo OK user=$INFRA_USER'
```

Each host profile must:

1. Assume `INFRA_REPO` is already set by the loader.
2. Define host arrays (`INFRA_CERT_DOMAINS`, `INFRA_APP_DOMAINS`, `INFRA_API_PORTS`, …).
3. End with `source "${INFRA_REPO}/infra-env-helper-shared.sh"`.

Per-service secrets stay in each `~/<service>-app/` (`secrets/secrets.env`,
`env.local`, etc.) — not in `infra-app`.

See [production-hosts.md](./docs/production-hosts.md) for the full multi-host layout.

## example — generic single-app host

Use this profile when trying the scripts on a new machine or in a fork.
Replace `api.example.com` and the app directory with your own values.

| Service | Port | Domain           |
|---------|------|------------------|
| api     | 5443 | api.example.com  |

Also **22** (SSH). Optional **443** → **5443**. Port **80** is temporary only for certbot.

```bash
sudo ./configure-host-firewall-oneoff.sh enable permanent
sudo ./configure-port-forwarding-oneoff.sh enable permanent 443 api
```

One-shot bootstrap: `sudo ./setup-host-oneoff.sh [certbot-email]`

```bash
#!/usr/bin/env bash
# example — host-local profile for ~/infra-app (never commit).

: "${INFRA_REPO:?INFRA_REPO must be set by the infra checkout loader}"

INFRA_USER="${INFRA_USER:-$(id -un)}"
INFRA_HOME="${INFRA_HOME:-/home/${INFRA_USER}}"

INFRA_CERT_DOMAINS=(
  "api.example.com"
)

declare -gA INFRA_APP_DOMAINS=(
  ["${INFRA_HOME}/api-app"]="api.example.com"
)

declare -gA INFRA_APP_ENV_FILES=(
  ["${INFRA_HOME}/api-app"]="secrets/secrets.env"
)

declare -gA INFRA_API_PORTS=(
  [api]=5443
)

INFRA_PORT_FORWARD_SERVICE="${INFRA_PORT_FORWARD_SERVICE:-api}"
INFRA_MONITOR_SERVICES=(
  "api:api-container::5443"
)

INFRA_CERT_EMAIL="${INFRA_CERT_EMAIL:-admin@example.com}"

# shellcheck source=/dev/null
source "${INFRA_REPO}/infra-env-helper-shared.sh"
```

## dedalo42 — Discernible signing (signportal / signsanctum)

| Service     | Port  | Domain                     |
|-------------|-------|----------------------------|
| signportal  | 14443 | signportal.discernible.io  |
| signsanctum | 1443  | signsanctum.discernible.io |

Host **dedalo42**. Also **22** (SSH). No 443 redirect. Port **80** is temporary only for certbot.

```bash
sudo ./configure-host-firewall-oneoff.sh enable permanent
```

One-shot bootstrap: `sudo ./setup-host-oneoff.sh [certbot-email]`

```bash
#!/usr/bin/env bash
# dedalo42 — host-local profile for ~/infra-app (never commit).

: "${INFRA_REPO:?INFRA_REPO must be set by the infra checkout loader}"

INFRA_USER="${INFRA_USER:-dedalo42}"
INFRA_HOME="${INFRA_HOME:-/home/${INFRA_USER}}"

INFRA_CERT_DOMAINS=(
  "signportal.discernible.io"
  "signsanctum.discernible.io"
)

declare -gA INFRA_APP_DOMAINS=(
  ["${INFRA_HOME}/signportal-app"]="signportal.discernible.io"
  ["${INFRA_HOME}/signsanctum-app"]="signsanctum.discernible.io"
)

declare -gA INFRA_APP_ENV_FILES=(
  ["${INFRA_HOME}/signportal-app"]="secrets/secrets.env"
  ["${INFRA_HOME}/signsanctum-app"]="secrets/secrets.env"
)

declare -gA INFRA_API_PORTS=(
  [signportal]=14443
  [signsanctum]=1443
)

INFRA_MONITOR_SERVICES=(
  "signportal:signportal-container::14443"
  "signsanctum:signsanctum-container::1443"
)

INFRA_CERT_EMAIL="${INFRA_CERT_EMAIL:-admin@discernible.io}"
INFRA_API_SCAN_LOGPATH="${INFRA_API_SCAN_LOGPATH:-/var/log/signportal/api.log}"

# shellcheck source=/dev/null
source "${INFRA_REPO}/infra-env-helper-shared.sh"
```

## dedalo44 — main API (api.identyclaw.com)

| Service      | Port | Domain              |
|--------------|------|---------------------|
| idclawserver | 5443 | api.identyclaw.com  |

Host **dedalo44**. Also **443** → **5443**, **22** (SSH). Port **80** is temporary only for certbot.

```bash
sudo ./configure-host-firewall-oneoff.sh enable permanent
sudo ./configure-port-forwarding-oneoff.sh enable permanent 443 idclawserver
```

One-shot bootstrap: `sudo ./setup-host-oneoff.sh [certbot-email]`

```bash
#!/usr/bin/env bash
# dedalo44 — host-local profile for ~/infra-app (never commit).

: "${INFRA_REPO:?INFRA_REPO must be set by the infra checkout loader}"

INFRA_USER="${INFRA_USER:-dedalo44}"
INFRA_HOME="${INFRA_HOME:-/home/${INFRA_USER}}"

INFRA_CERT_DOMAINS=(
  "api.identyclaw.com"
)

declare -gA INFRA_APP_DOMAINS=(
  ["${INFRA_HOME}/idclawserver-app"]="api.identyclaw.com"
)

declare -gA INFRA_APP_ENV_FILES=(
  ["${INFRA_HOME}/idclawserver-app"]="secrets/secrets.env"
)

declare -gA INFRA_API_PORTS=(
  [idclawserver]=5443
)

INFRA_PORT_FORWARD_SERVICE="${INFRA_PORT_FORWARD_SERVICE:-idclawserver}"
INFRA_MONITOR_SERVICES=(
  "idclawserver:idclawserver-container::5443"
)

INFRA_CERT_EMAIL="${INFRA_CERT_EMAIL:-admin@discernible.io}"
INFRA_API_SCAN_LOGPATH="${INFRA_API_SCAN_LOGPATH:-/var/log/idclawserver/api.log}"

# shellcheck source=/dev/null
source "${INFRA_REPO}/infra-env-helper-shared.sh"
```

## dedalo46 — Discernible IC + monitoring

| Service         | Port | Domain                         |
|-----------------|------|--------------------------------|
| mintroot        | 6443 | root.discernible.io            |
| mintserver      | 2443 | identyclaw.discernible.io      |
| mintclient      | 4443 | purchase.identyclaw.com        |
| mintclient      | 4443 | verify.identyclaw.com (SAN on purchase cert) |
| openclawagents  | 8443 | andrew.dihola.io, joe.dihola.io, daniel.dihola.io, identyclaw-concierge.identyclaw.com (`~/openclaw-agents-app`; Telegram-compatible) |
| monitoring      | 3335 | grafana46.discernible.io (3333 in stack) |

Also allowed: **443** (redirect to mintclient **4443**), monitoring **3100**,
**22** (SSH). Port **80** is temporary only for certbot (`allow-http-temporary`).
OpenClaw ingress is **8443** (`IDENTYCLAW_INGRESS_PORT` in `~/openclaw-agents-app/env.local`);
host Podman must publish **8443→8443**. Telegram Bot API webhooks only accept **80, 88, 443, or 8443**.
Ports **88** and **7443** are retired here and listed in `INFRA_BLOCKED_PUBLIC_TCP_PORTS`.

Host **dedalo46** — domain→port table for iptables is summarized in
`infra-iptables-helper.sh` (chain `INFRA_HOST_FW`, 443→4443 NAT). Persist with:

```bash
sudo ./configure-host-firewall-oneoff.sh enable permanent
sudo ./enable-rootless-podman-helper.sh enable
sudo ./configure-port-forwarding-oneoff.sh enable permanent 443 mintclient
# or: sudo ./golive.sh --with-port-forwarding
```

One-shot bootstrap: `sudo ./setup-host-oneoff.sh [certbot-email]`

```bash
#!/usr/bin/env bash
# dedalo46 — host-local profile for ~/infra-app (never commit).

: "${INFRA_REPO:?INFRA_REPO must be set by the infra checkout loader}"

INFRA_USER="${INFRA_USER:-dedalo46}"
INFRA_HOME="${INFRA_HOME:-/home/${INFRA_USER}}"
INFRA_MONITORING_DOMAIN="${INFRA_MONITORING_DOMAIN:-grafana46.discernible.io}"

INFRA_CERT_DOMAINS=(
  "root.discernible.io"
  "identyclaw.discernible.io"
  "purchase.identyclaw.com"
  "identyclaw-concierge.identyclaw.com"
  "$INFRA_MONITORING_DOMAIN"
)

declare -gA INFRA_CERT_SAN_DOMAINS=(
  ["purchase.identyclaw.com"]="verify.identyclaw.com"
  ["identyclaw-concierge.identyclaw.com"]="andrew.dihola.io joe.dihola.io daniel.dihola.io"
)

declare -gA INFRA_APP_DOMAINS=(
  ["${INFRA_HOME}/mintroot-app"]="root.discernible.io"
  ["${INFRA_HOME}/mintserver-app"]="identyclaw.discernible.io"
  ["${INFRA_HOME}/mintclient-app"]="purchase.identyclaw.com"
  ["${INFRA_HOME}/openclaw-agents-app"]="identyclaw-concierge.identyclaw.com"
  ["${INFRA_HOME}/grafanaloki-app"]="$INFRA_MONITORING_DOMAIN"
)

declare -gA INFRA_API_PORTS=(
  [mintroot]=6443
  [mintserver]=2443
  [mintclient]=4443
  [openclawagents]=8443
)

INFRA_MONITORING_TCP_PORTS=(3100 3335)
INFRA_MONITORING_CERTS_DIR="${INFRA_MONITORING_CERTS_DIR:-${INFRA_HOME}/grafanaloki-app/certs}"
INFRA_PORT_FORWARD_SERVICE="${INFRA_PORT_FORWARD_SERVICE:-mintclient}"
INFRA_BLOCKED_PUBLIC_TCP_PORTS=(88 7443)
INFRA_MONITOR_SERVICES=(
  "mintroot:mintroot-container::6443"
  "mintserver:mintserver-container::2443"
  "mintclient:mintclient-container::4443"
  "openclawagents:openclaw-nginx::8443"
)
INFRA_CERT_EMAIL="${INFRA_CERT_EMAIL:-admin@discernible.io}"
INFRA_API_SCAN_LOGPATH="${INFRA_API_SCAN_LOGPATH:-/var/log/mintserver/api.log}"

# shellcheck source=/dev/null
source "${INFRA_REPO}/infra-env-helper-shared.sh"
```

## dedalo47 — identyclaw IC + agents + SLC (current)

Serves **dihola.io** IC APIs, OpenClaw agents, monitoring, and SLC.

| Service          | Port  | Domain(s)                                      |
|------------------|-------|------------------------------------------------|
| idclawserver     | 5443  | api.dihola.io                                  |
| mintrootidc      | 6443  | root.dihola.io                                 |
| mintserveridc    | 2443  | identyclaw.dihola.io                           |
| identyclawagents | 88    | andrew.dihola.io, joe.dihola.io, daniel.dihola.io |
| hermesagents     | 11443 | `HERMES_PUBLIC_HOST` in `~/hermes-agents-app/env.local` (11xxx: API 11642, dashboard 11919) |
| slcbackend (SLC) | 13443 | api.lastcradle.io (production; 443→13443)      |

**Agent ingress:** one shared nginx listen on **88** (SNI per
`AGENT_*_PUBLIC_HOST` in `~/openclaw-agents-app/env.local`). Host Podman must
publish **88→88**. Telegram Bot API webhooks only accept **80, 88, 443, or 8443**.
Agents use self-signed TLS in `~/openclaw-agents-app/certs/` (not Let's Encrypt
via infra scripts). **13443** is production SLC (`slcbackend` / `api.lastcradle.io`);
repo `~/slcbackend-slc`, app dir `~/slcbackend-app`. **443** → **13443**.

**Hermes (11xxx):** public webhook ingress **11443** (`HERMES_DEPLOY_MODE=pod`,
`HERMES_INGRESS_PORT=11443`); operator API **11642**; optional dashboard **11919**.
Only **11443** is in `INFRA_API_PORTS` / host firewall. Self-signed PEMs via
`./hermes.sh generate-certs` in `~/hermes-agents-app/certs/` (not Let's Encrypt).

Monitoring: **grafana47.dihola.io** on **3100/3333** (world-open when
`INFRA_MONITORING_TCP_RESTRICT=false`; otherwise CIDR-restricted).
One-shot: `sudo ./setup-host-oneoff.sh [certbot-email]`

```bash
sudo ./configure-host-firewall-oneoff.sh enable permanent
sudo ./configure-port-forwarding-oneoff.sh enable permanent 443 slcbackend
```

App dirs: `~/openclaw-agents-app` (certs shared for andrew/joe/daniel SANs),
`~/hermes-agents-app`, `~/slcbackend-app`.
Repos: `~/openclaw-agents`, `~/hermes-agents`, `~/slcbackend-slc`.

```bash
#!/usr/bin/env bash
# dedalo47 — host-local profile for ~/infra-app (never commit).

: "${INFRA_REPO:?INFRA_REPO must be set by the infra checkout loader}"

INFRA_USER="${INFRA_USER:-dedalo47}"
INFRA_HOME="${INFRA_HOME:-/home/${INFRA_USER}}"
INFRA_MONITORING_DOMAIN="${INFRA_MONITORING_DOMAIN:-grafana47.dihola.io}"

INFRA_CERT_DOMAINS=(
  "api.dihola.io"
  "root.dihola.io"
  "identyclaw.dihola.io"
  "slc.dihola.io"
  "api.lastcradle.io"
  "$INFRA_MONITORING_DOMAIN"
)

declare -gA INFRA_CERT_SAN_DOMAINS=()

declare -gA INFRA_APP_DOMAINS=(
  ["${INFRA_HOME}/idclawserver-app"]="api.dihola.io"
  ["${INFRA_HOME}/mintroot-app"]="root.dihola.io"
  ["${INFRA_HOME}/mintserver-app"]="identyclaw.dihola.io"
  ["${INFRA_HOME}/slcbackend-app"]="api.lastcradle.io"
  ["${INFRA_HOME}/grafanaloki-app"]="$INFRA_MONITORING_DOMAIN"
)

declare -gA INFRA_APP_ENV_FILES=(
  ["${INFRA_HOME}/idclawserver-app"]="secrets/secrets.env"
  ["${INFRA_HOME}/mintroot-app"]="secrets/secrets.env"
  ["${INFRA_HOME}/mintserver-app"]="secrets/secrets.env"
  ["${INFRA_HOME}/hermes-agents-app"]="env.local"
  ["${INFRA_HOME}/slcbackend-app"]="secrets/secrets.env"
  ["${INFRA_HOME}/grafanaloki-app"]=".env"
)

declare -gA INFRA_API_PORTS=(
  [idclawserver]=5443
  [mintrootidc]=6443
  [mintserveridc]=2443
  [identyclawagents]=88
  [hermesagents]=11443
  [slcbackend]=13443
)

INFRA_MONITORING_TCP_PORTS=(3333 3100)
INFRA_MONITORING_TCP_RESTRICT=false
INFRA_MONITORING_ALLOW_CIDRS=(
  "127.0.0.1/8"
  "::1/128"
  "10.0.0.0/8"
  "172.16.0.0/12"
  "192.168.0.0/16"
)

INFRA_PORT_FORWARD_SERVICE="${INFRA_PORT_FORWARD_SERVICE:-slcbackend}"
INFRA_PORT_FORWARD_DEST="${INFRA_PORT_FORWARD_DEST:-${INFRA_API_PORTS[slcbackend]}}"
INFRA_MONITORING_CERTS_DIR="${INFRA_MONITORING_CERTS_DIR:-${INFRA_HOME}/grafanaloki-app/certs}"
declare -A INFRA_POD_START=(
  [slcbackend]="slcbackend-pod|slcbackend-container|${INFRA_HOME}/slcbackend-slc/scripts/deploy-local-podman.sh|--skip-build"
)
declare -A INFRA_POD_START_ENV=(
  [slcbackend]="TARGET=main"
)
INFRA_MONITOR_SERVICES=(
  "idclawserver:idclawserver-container::5443"
  "mintrootidc:mintrootidc-container::6443"
  "mintserveridc:mintserveridc-container::2443"
  "slcbackend:slcbackend-container:${INFRA_REPO}/start-pod.sh:13443"
)
INFRA_CERT_EMAIL="${INFRA_CERT_EMAIL:-admin@dihola.io}"
INFRA_API_SCAN_LOGPATH="${INFRA_API_SCAN_LOGPATH:-/var/log/idclawserver/api.log}"

# shellcheck source=/dev/null
source "${INFRA_REPO}/infra-env-helper-shared.sh"
```

**dihola.io** signportal/signsanctum production hostnames (if used) must not be copied
onto **dedalo42**. The live **dedalo47** profile above is IC + agents + SLC, not the
signing-port map.

## dedalo47 (alternate template) — dihola signing + webhook stack

Use only if this Alma host actually runs signportal/signsanctum/mintclient/api-test-scaffold.
Do **not** mix with the current IC + agents profile above.
Former name **clienttest** / `clienttest-app` is deprecated; use `api-test-scaffold` / `api-test-scaffold-app`.

| Service           | Port | Domain (typical)        |
|-------------------|------|-------------------------|
| signportal        | 14443 | signportal.dihola.io    |
| signsanctum       | 1443 | signsanctum.dihola.io   |
| mintclient        | 4443 | purchase.dihola.io      |
| mintclient        | 4443 | verify.dihola.io (SAN on purchase cert) |
| api-test-scaffold | 7443 | webhook.dihola.io       |

```bash
#!/usr/bin/env bash
# dedalo47 alternate — signing stack; host-local ~/infra-app only.

: "${INFRA_REPO:?INFRA_REPO must be set by the infra checkout loader}"

INFRA_USER="${INFRA_USER:-dedalo47}"
INFRA_HOME="${INFRA_HOME:-/home/${INFRA_USER}}"
INFRA_MONITORING_DOMAIN="${INFRA_MONITORING_DOMAIN:-grafana47.dihola.io}"

INFRA_CERT_DOMAINS=(
  "signportal.dihola.io"
  "signsanctum.dihola.io"
  "purchase.dihola.io"
  "webhook.dihola.io"
  "$INFRA_MONITORING_DOMAIN"
)

declare -gA INFRA_CERT_SAN_DOMAINS=(
  ["purchase.dihola.io"]="verify.dihola.io"
)

declare -gA INFRA_API_PORTS=(
  [signportal]=14443
  [signsanctum]=1443
  [mintclient]=4443
  [api-test-scaffold]=7443
)

INFRA_MONITORING_TCP_PORTS=(3100 3333)
INFRA_MONITORING_CERTS_DIR="${INFRA_MONITORING_CERTS_DIR:-${INFRA_HOME}/grafanaloki-app/certs}"
INFRA_MONITOR_SERVICES=(
  "signportal:signportal-container::14443"
  "signsanctum:signsanctum-container::1443"
  "mintclient:mintclient-container::4443"
  "api-test-scaffold:api-test-scaffold-container:${INFRA_HOME}/api-test-scaffold/scripts/deploy-local-podman.sh:7443"
)
INFRA_CERT_EMAIL="${INFRA_CERT_EMAIL:-admin@dihola.io}"

# shellcheck source=/dev/null
source "${INFRA_REPO}/infra-env-helper-shared.sh"
```

## dedalo43 — dihola stack + agents + SLC frontend

Serves **dihola.io** signing/purchase/webhook stacks,
OpenClaw/Hermes agent ingress, ironclaw, and the main-tier SLC frontend
(`lastcradle.io` / `slc.dihola.io`).

| Service            | Port | Domain (typical)           |
|--------------------|------|----------------------------|
| signportal         | 14443 | signportal.dihola.io       |
| signsanctum        | 1443 | signsanctum.dihola.io      |
| mintclient         | 4443 | purchase.dihola.io         |
| mintclient         | 4443 | verify.dihola.io (SAN on purchase cert) |
| ironclaw           | 9443 | ironclaw.dihola.io; **88 → 9443** |
| slcfrontend (SLC)  | 13443 | lastcradle.io (+ www / identyclaw.com SAN); **443 → 13443** |
| openclaw-agents    | 8443 | cornelius.dihola.io (+ SANs john/jay) |
| hermes-agent       | 10443 | hermes.dihola.io; **80 → 10443** (Telegram); **7443 → 10443** (Passport A2A → nginx → pod `:9900`) |
| monitoring         | 3100/3333 | grafana43.dihola.io     |

Also allowed: **22** (SSH). Certbot HTTP-01 still uses a temporary allow on **80** when needed.
OpenClaw + Hermes nginx certs are Let's Encrypt via `INFRA_APP_DOMAINS` (Telegram rejects self-signed).

```bash
sudo ./configure-host-firewall-oneoff.sh enable permanent
sudo ./configure-port-forwarding-oneoff.sh enable permanent
# or: sudo ./golive.sh --with-port-forwarding
```

```bash
#!/usr/bin/env bash
# dedalo43 — host-local profile for ~/infra-app (never commit).
#
# slcfrontend: git checkout ~/slcfrontend-slc (syntheticslastcradle-fe);
# runtime layout ~/slcfrontend-app. Public listen 13443; 443→13443 REDIRECT.

: "${INFRA_REPO:?INFRA_REPO must be set by the infra checkout loader}"

INFRA_USER="${INFRA_USER:-dedalo43}"
INFRA_HOME="${INFRA_HOME:-/home/${INFRA_USER}}"
INFRA_MONITORING_DOMAIN="${INFRA_MONITORING_DOMAIN:-grafana43.dihola.io}"

INFRA_CERT_DOMAINS=(
  "signportal.dihola.io"
  "signsanctum.dihola.io"
  "purchase.dihola.io"
  "webhook.dihola.io"
  "ironclaw.dihola.io"
  # Telegram rejects self-signed certificates — CA-signed required for webhook ingress.
  "cornelius.dihola.io"
  "hermes.dihola.io"
  "slc.dihola.io"
  "lastcradle.io"
  "$INFRA_MONITORING_DOMAIN"
)

declare -gA INFRA_CERT_SAN_DOMAINS=(
  ["purchase.dihola.io"]="verify.dihola.io"
  # Primary LE name for main-tier SLC frontend; www + IdentyClaw apex share the same cert
  # (identyclaw.com redirect is served by slcfrontend on 443→13443).
  ["lastcradle.io"]="www.lastcradle.io identyclaw.com"
  # OpenClaw agents share a single nginx cert file (fullchain.pem/privkey.pem)
  # under openclaw-agents-app/certs. Include all configured agent ingress
  # hostnames as SANs.
  ["cornelius.dihola.io"]="john.dihola.io jay.dihola.io"
)

declare -gA INFRA_APP_DOMAINS=(
  ["${INFRA_HOME}/signportal-app"]="signportal.dihola.io"
  ["${INFRA_HOME}/signsanctum-app"]="signsanctum.dihola.io"
  ["${INFRA_HOME}/mintclient-app"]="purchase.dihola.io"
  # Former ~/clienttest-app — deprecated; certs install to api-test-scaffold-app.
  ["${INFRA_HOME}/api-test-scaffold-app"]="webhook.dihola.io"
  ["${INFRA_HOME}/ironclaw-agents-app"]="ironclaw.dihola.io"
  # Primary LE name lastcradle.io (+ SAN www.lastcradle.io, identyclaw.com).
  ["${INFRA_HOME}/slcfrontend-app"]="lastcradle.io"
  ["${INFRA_HOME}/grafanaloki-app"]="$INFRA_MONITORING_DOMAIN"
  # openclaw-agents-app uses a CA-signed nginx cert so Telegram webhooks work.
  ["${INFRA_HOME}/openclaw-agents-app"]="cornelius.dihola.io"
  # hermes-agents-app — CA-signed cert for Telegram webhook ingress on :10443 (80→10443).
  ["${INFRA_HOME}/hermes-agents-app"]="hermes.dihola.io"
)

declare -gA INFRA_APP_ENV_FILES=(
  ["${INFRA_HOME}/signportal-app"]="secrets/secrets.env"
  ["${INFRA_HOME}/signsanctum-app"]="secrets/secrets.env"
  ["${INFRA_HOME}/mintclient-app"]="secrets/secrets.env"
  ["${INFRA_HOME}/api-test-scaffold-app"]="secrets/secrets.env"
  ["${INFRA_HOME}/ironclaw-agents-app"]="secrets/secrets.env"
  ["${INFRA_HOME}/slcfrontend-app"]="secrets/secrets.env"
  ["${INFRA_HOME}/openclaw-agents-app"]="env.local"
  ["${INFRA_HOME}/hermes-agents-app"]="env.local"
  ["${INFRA_HOME}/grafanaloki-app"]=".env"
)

declare -gA INFRA_API_PORTS=(
  [signportal]=14443
  [signsanctum]=1443
  [mintclient]=4443
  [ironclaw]=9443
  [slcfrontend]=13443
  # Telegram Bot API webhook ports: 80, 88, 443, 8443.
  # openclaw-agents uses 8443; hermes-agent ingress 10443; ironclaw 9443.
  [openclaw-agents]=8443
  [hermes-agent]=10443
)

# 443 → slcfrontend (slc.dihola.io). Former mintclient redirect replaced on this host.
INFRA_PORT_FORWARD_SERVICE="${INFRA_PORT_FORWARD_SERVICE:-slcfrontend}"
INFRA_PORT_FORWARD_DEST="${INFRA_PORT_FORWARD_DEST:-${INFRA_API_PORTS[$INFRA_PORT_FORWARD_SERVICE]}}"

# Extra inbound REDIRECTs (Telegram-compatible aliases): source:dest|service
# ironclaw 9443 via 88; hermes-agent 10443 via 80.
# 7443 is the Passport metadata.webhook_url port (same nginx as :10443 → A2A :9900).
INFRA_EXTRA_PORT_FORWARDS=(
  "88:ironclaw"
  "80:hermes-agent"
  "7443:hermes-agent"
)

INFRA_MONITORING_TCP_PORTS=(3100 3333)
INFRA_PUBLIC_API_TCP_PORTS=(
  "${INFRA_API_PORTS[signportal]}"
  "${INFRA_API_PORTS[signsanctum]}"
  "${INFRA_API_PORTS[mintclient]}"
  "${INFRA_API_PORTS[ironclaw]}"
  "${INFRA_API_PORTS[slcfrontend]}"
  "${INFRA_API_PORTS[openclaw-agents]}"
  "${INFRA_API_PORTS[hermes-agent]}"
)
# 80 / 88 are public Telegram webhook entry ports (REDIRECT to hermes / ironclaw).
# 7443 is the Passport A2A alias (REDIRECT to hermes :10443 → nginx → :9900).
INFRA_PUBLIC_TCP_PORTS=(80 88 443 7443 "${INFRA_PUBLIC_API_TCP_PORTS[@]}" "${INFRA_MONITORING_TCP_PORTS[@]}")
INFRA_ADMIN_TCP_PORTS=(22)
INFRA_BLOCKED_PUBLIC_TCP_PORTS=()

INFRA_MONITOR_SERVICES=(
  "signportal:signportal-container::14443"
  "signsanctum:signsanctum-container::1443"
  "mintclient:mintclient-container::4443"
  # ironclaw-agents-app is present for certs; no ironclaw container is running.
  "slcfrontend:slcfrontend-nginx::13443"
  "openclaw-agents:openclaw-nginx::8443"
  # Hermes ingress (HERMES_TELEGRAM_PORT / HERMES_INGRESS_PORT=10443)
  "hermes-agent:hermes::10443"
  # Grafana/Loki (https://grafana43.dihola.io:3333)
  "monitoring:monitoring-grafana:${INFRA_REPO}/start-monitoring-pod.sh:"
)
INFRA_CERT_EMAIL="${INFRA_CERT_EMAIL:-admin@dihola.io}"
INFRA_API_SCAN_LOGPATH="${INFRA_API_SCAN_LOGPATH:-/var/log/signportal/api.log}"

# shellcheck source=/dev/null
source "${INFRA_REPO}/infra-env-helper-shared.sh"
```

Helper implementations (`infra_resolve_api_port`, `infra_find_infra_container`,
firewall arrays) are in `infra-env-helper-shared.sh` (sourced by each host profile).
If a host omits `monitoring:…` from `INFRA_MONITOR_SERVICES`, the shared helper
appends it when `grafanaloki-app/deploy-monitoring.sh` is present on that host.
