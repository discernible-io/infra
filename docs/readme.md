# Script catalog and host baseline

Shared scripts for AlmaLinux 10 hosts that run rootless Podman stacks. Host paths and domains live in the sibling **`~/infra-app/`** directory (never commit). The committed `infra-env-helper.sh` only loads that profile.

Install a profile with **`./bootstrap-infra-app.sh <profile>`** (see [infra-env-helper.md](../infra-env-helper.md)), then **`sudo ./setup-host-oneoff.sh`**. Fleet migration notes: [migrate-infra-app.md](./migrate-infra-app.md).

## Prerequisites

```bash
sudo dnf install -y jq podman
```

Certificate, HTTP, and firewall workflows also need the packages listed under **Standard development host software** below.

## Related documentation

| Document | Topic |
|----------|--------|
| [../README.md](../README.md) | Project overview, license, quick start |
| [hardening.md](./hardening.md) | Server SSH hardening |
| [rpc-configuration.md](./rpc-configuration.md) | RPC endpoints for `idcp-wallet.sh` |
| [maintenance-status-roadmap.md](./maintenance-status-roadmap.md) | Maintenance planning (shared scripts; host state in `~/infra-app/maintenance-status.md`) |
| [maintenance-status.example.md](./maintenance-status.example.md) | Per-host installed automation template (copy to `~/infra-app/`) |
| [production-hosts.md](./production-hosts.md) | Reference fleet domain and port map |

## Standard development host software

Baseline packages on an AlmaLinux 10 development host (representative `dnf` names).

### Web server
- `httpd`, `mod_ssl`, `mod_http2`, `mod_lua`

### TLS / certificates
- `certbot`, `python3-certbot`, `python3-certbot-apache`

### Containers
- `podman`, `containers-common`, `aardvark-dns`, `netavark`

### Security
- `fail2ban`, `firewalld`, `openssh-server`

### Mail
- `exim`

### Dev tools
- `git`, `gcc`, `make`, `vim-enhanced`, `ripgrep`

### Monitoring / admin
- `btop`, `mc`, `ncdu`, `jq`, `bind-utils`

### Node (OS packages)
- `nodejs`, `nodejs-npm`

### Python (OS packages)
- `python3` plus assorted `python3-*` libraries (e.g. for Certbot, DNF, firewalld, and other system tools)

### Editors
- `vim-enhanced`, `nano`
- **MC + nano:** F4 needs `editor=/usr/bin/nano` and `use_internal_edit=false` in `~/.config/mc/ini` (not `EDITOR` alone). Run `./configure-mc-nano-oneoff.sh` while mc is closed.

### Repositories
- `epel-release` enabled

## Script naming

Root scripts use **`action-object-result[-periodicity-or-role].sh`** (kebab-case):

| Part | Meaning | Examples |
|------|---------|----------|
| **action** | Verb: what the script does | `install`, `verify`, `renew`, `enable`, `scan` |
| **object** | What is acted on | `certs`, `monitoring-pods`, `server`, `containers` |
| **result** | Scope, target, or method | `to-apps`, `letsencrypt`, `liveness`, `apis` |
| **periodicity-or-role** | Recommended calendar cadence or operational role; omit for normal on-demand commands | `daily`, `weekly`, `monthly`, `helper`, `oneoff` |

Shared helpers sourced by other scripts use the **`helper`** suffix (for example `prepare-httpd-for-certbot-helper.sh`).

Scripts that used to be separate entry points are merged with a **subcommand** as the result, for example `manage-monitoring-pods.sh install` or `renew-certs-all-monthly.sh certbot`.

## Scripts overview

### Core services
- **`idcp-wallet.sh`** — RODiT wallet management (see usage below)
- **`list-vault-secrets.sh`** — List Vault secrets (`discernible` or `discernible-io` profile, or `VAULT_PROFILE`)
- **`vault_management.sh`** — Interactive Vault secret management (AppRole; needs `VAULT_ROLE_ID` / `VAULT_SECRET_ID`)
- **`vault.Dockerfile`**, **`signing-*.hcl`**, **`podman-policy.hcl`** — Vault image/policy helpers
- **`restart-containers-apis.sh`** — Restart all API containers in correct order
- **`start`** — Compatibility wrapper; runs `INFRA_SERVICE_STARTER` from the host profile

### Container monitoring
- **`manage-monitoring-pods.sh`** — `install` | `enable` | `disable` | `status` for Podman liveness monitoring
- **`start-monitoring-pod.sh`** — Start `monitoring-pod` (Grafana/Loki); full deploy only if pod missing
- **`start-pod.sh`** — Generic pod start / optional deploy (`<pod> <probe> [deploy…]`, or `INFRA_POD_START` lookup)
- **`monitor-pods-liveness-helper.sh`** — Checker invoked by systemd (services from `INFRA_MONITOR_SERVICES`)
- **`monitor-pods-liveness.service`** / **`monitor-pods-liveness.timer`** — Systemd units (installed by `manage-monitoring-pods.sh install`)

### Security and certificates
- **`generate-cert-letsencrypt.sh`** — Issue a Let's Encrypt certificate for a domain (optional SANs via `INFRA_CERT_SAN_DOMAINS`)
- **`renew-certs-all-monthly.sh`** — `certbot` (cron/timer) or `manual [email]` (per-domain issue + install + optional restart)
- **`install-certs-to-apps.sh`** — Copy live certs into application directories
- **`install-certs-on-renew-hook-helper.sh`** — Certbot deploy hook (install + restart)
- **`verify-certs-in-apps-weekly.sh`** — Validate cert files and permissions under app trees
- **`verify-cert-mount-permissions.sh`** — Test Podman/nginx cert mount permissions
- **`prepare-httpd-for-certbot-helper.sh`** — Shared httpd lifecycle (sourced, not run directly)
- **`scan-containers-vulnerabilities-weekly.sh`** — Trivy: local/registry images, optional `trivy fs` on `*-idc` repos, SBOM diff (`--pull-missing`, `--fail-on-findings`); reports under `~/infra-app/trivy-scan-results/`
- **`scan-containers-vulnerabilities-weekly.{service,timer}`** — Weekly Trivy timer (install via `manage-weekly-maintenance.sh install`)
- **`harden-server-oneoff.sh`** — Bootstrap SSH, fail2ban, auditd hardening
- **`apply-security-improvements-oneoff.sh`** — SSH keys cleanup + harden + firewall + optional API fail2ban jail
- **`fix-audit-rules-oneoff.sh`** — Repair audit watch rules when secrets paths are missing
- **`configure-fail2ban-api-scan-jail-oneoff.sh`** — `install [logpath]` | `remove` for API-scan fail2ban jail

### System maintenance
- **`bootstrap-infra-app.sh`** — Create `~/infra-app/`, host profile, `maintenance-status.md` template
- **`bootstrap-app-dir-layout.sh`** — Create or repair `*-app/` directory trees
- **`golive.sh`** — Reboot-persistence bundle: pod monitor, weekly timers, host-uptime, firewall, container restarts (no SSH hardening or cert issue)
- **`apply-health-recommendations.sh`** — Rootless Podman + weekly maintenance timers + status summary
- **`manage-weekly-maintenance.sh`** — `install` | `enable` | `disable` | `status` for OS upgrade + cleanup + Trivy + monitoring-image weekly timers
- **`install-weekly-maintenance-timers.sh`** — Legacy alias for weekly timer install
- **`upgrade-host-packages-weekly.sh`** — Weekly `dnf upgrade` (Sun 02:00 timer); `--check` / `--security-only` / `--reboot-if-needed`
- **`upgrade-host-packages-weekly.{service,timer}`** — Units installed by `manage-weekly-maintenance.sh install`
- **`update-monitoring-images-weekly.sh`** — Weekly Grafana/Loki rebuild/redeploy when images ≥ 3 days old (Sun 05:30); `--check` / `--force`
- **`update-monitoring-images-weekly.{service,timer}`** — Units installed by `manage-weekly-maintenance.sh install`
- **`cleanup-disk-space-weekly.sh`** — Clean journal logs, syslog, and Podman cache (Sun 03:00 timer)
- **`host-uptime-prep.sh`** — Hourly host health signals (`init`, `enable-permanent`, `status`, `report`)
- **`enable-rootless-podman-helper.sh`** — Linger + `podman.socket` for rootless Podman
- **`enable-podman-boot-autostart.sh`** — Podman autostart on reboot for `INFRA_USER`
- **`configure-port-forwarding-oneoff.sh`** — iptables 443→`INFRA_PORT_FORWARD_DEST` REDIRECT (service name or port)
- **`configure-host-firewall-oneoff.sh`** — inbound TCP allowlist from `~/infra-app/infra-env-helper.sh`
- **`setup-host-oneoff.sh`** — One-shot bootstrap: rootless Podman, weekly timers, pod monitor, app dirs, TLS, firewall, optional 443 redirect

## RODiT wallet usage

```bash
./idcp-wallet.sh                                    # List available accounts
./idcp-wallet.sh <accountID>                        # Show RODiT IDs and balance
./idcp-wallet.sh <accountID> keys                   # Display account keys
./idcp-wallet.sh <accountID> <roditId>              # Display specific RODiT
./idcp-wallet.sh <fundingID> <newID> init           # Initialize account (0.01 NEAR)
./idcp-wallet.sh <originID> <destID> <roditId>      # Transfer RODiT
./idcp-wallet.sh gennearaccount                     # Generate new account
```

New accounts require 0.01 NEAR to initialize. For testnet: https://wallet.testnet.near.org/

RPC endpoint selection: [rpc-configuration.md](./rpc-configuration.md).
