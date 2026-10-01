# Infra

Host automation for AlmaLinux 10 servers that run rootless [Podman](https://podman.io/) stacks: TLS, firewalls, systemd timers, certificate install, and container liveness.

This git checkout is **scripts only**. Machine config lives in a sibling **`~/infra-app/`** directory (never commit it). Container runtime secrets stay in each **`~/<service>-app/`** tree because Podman loads them with `--env-file`.

## Quick start (new host)

```bash
sudo dnf install -y jq podman git
git clone https://github.com/discernible-io/infra.git ~/infra
cd ~/infra
./bootstrap-infra-app.sh                 # creates ~/infra-app with an example profile
# or: ./bootstrap-infra-app.sh custom    # interactive domain/port/email
# Edit ~/infra-app/infra-env-helper.sh, then:
./bootstrap-infra-app.sh --with-app-dirs
# Fill secrets in each ~/<service>-app/secrets/secrets.env, then:
sudo ./setup-host-oneoff.sh you@example.com
```

`./bootstrap-infra-app.sh --status` shows the loaded profile. Most other scripts accept `help`.

Named profiles (`example`, plus fleet templates) are listed in [infra-env-helper.md](infra-env-helper.md). Extra tenant apps belong only in `~/infra-app/`.

## Layout

```text
~/infra/                 # this git checkout — shared scripts only
~/infra-app/             # host-local — do not commit
  infra-env-helper.sh    # domains, ports, INFRA_APP_DOMAINS, monitor list
  roditwallet.env        # optional NEAR RPC overrides for idcp-wallet.sh
  maintenance-status.md  # installed timers and hardening on this machine
  trivy-scan-results/    # scanner output
~/<service>-app/         # per-service runtime (certs, secrets.env, data)
```

`./bootstrap-infra-app.sh` creates `~/infra-app/`. The committed [infra-env-helper.sh](infra-env-helper.sh) is only a loader: it sources `~/infra-app/infra-env-helper.sh`. `./bootstrap-app-dir-layout.sh` creates the `*-app` secret placeholders from that profile.

Override paths with `INFRA_APP_DIR`, `INFRA_REPO`, `INFRA_USER`, or `INFRA_HOME` when needed.

## Script naming

Root scripts use **`action-object-result[-periodicity-or-role].sh`** (kebab-case):

| Part | Meaning | Examples |
|------|---------|----------|
| **action** | What the script does | `install`, `verify`, `renew`, `enable`, `scan` |
| **object** | What is acted on | `certs`, `monitoring-pods`, `server`, `containers` |
| **result** | Scope, target, or method | `to-apps`, `letsencrypt`, `liveness`, `apis` |
| **periodicity-or-role** | Cadence or role; omit for on-demand commands | `weekly`, `monthly`, `helper`, `oneoff` |

Shared helpers sourced by other scripts use the **`helper`** suffix. Merged entry points take a **subcommand**, for example `manage-monitoring-pods.sh install` or `renew-certs-all-monthly.sh certbot`.

## Scripts

Most scripts accept `help`. Longer notes and the host software baseline live in [docs/readme.md](docs/readme.md).

### Bootstrap and host setup

| Script | What it does |
|--------|----------------|
| `bootstrap-infra-app.sh` | Create `~/infra-app/`, install a host profile, optional `--with-app-dirs` / `--status` |
| `bootstrap-app-dir-layout.sh` | Create or repair `*-app/` trees (`certs/`, `secrets/`, …) from the profile |
| `setup-host-oneoff.sh` | One-shot bootstrap: rootless Podman, timers, pod monitor, TLS, firewall, optional 443 redirect |
| `golive.sh` | Reboot-persistence bundle (monitor, weekly timers, uptime, firewall, container restarts) |
| `apply-health-recommendations.sh` | Rootless Podman + weekly maintenance timers + status summary |
| `infra-env-helper.sh` | Loader that sources `~/infra-app/infra-env-helper.sh` |
| `infra-env-helper-shared.sh` | Shared profile helpers sourced by the host profile |

### Containers and monitoring

| Script | What it does |
|--------|----------------|
| `restart-containers-apis.sh` | Restart API stacks in dependency order (infra → app → nginx) |
| `start` | Compatibility wrapper; runs `INFRA_SERVICE_STARTER` from the host profile |
| `start-monitoring-pod.sh` | Start Grafana/Loki monitoring pod (wrapper around `start-pod.sh`) |
| `start-pod.sh` | Start any Podman pod by name, or via `INFRA_POD_START` in the host profile |
| `manage-monitoring-pods.sh` | `install` \| `enable` \| `disable` \| `status` for Podman liveness monitoring |
| `monitor-pods-liveness-helper.sh` | Checker invoked by systemd (`INFRA_MONITOR_SERVICES`) |
| `infra-podman-helper.sh` | Shared Podman helpers sourced by other scripts |

### Certificates and TLS

| Script | What it does |
|--------|----------------|
| `generate-cert-letsencrypt.sh` | Issue a Let's Encrypt cert for a domain (optional SANs) |
| `renew-certs-all-monthly.sh` | `certbot` (timer) or `manual [email]` (issue/install/restart) |
| `install-certs-to-apps.sh` | Copy live certs into application directories |
| `install-certs-on-renew-hook-helper.sh` | Certbot deploy hook (install + restart) |
| `verify-certs-in-apps-weekly.sh` | Validate cert files and permissions under app trees |
| `verify-cert-mount-permissions.sh` | Test Podman/nginx cert mount permissions |
| `prepare-httpd-for-certbot-helper.sh` | Shared httpd/DNS helpers (sourced, not run directly) |

### Security and firewall

| Script | What it does |
|--------|----------------|
| `harden-server-oneoff.sh` | Bootstrap SSH, fail2ban, auditd hardening |
| `apply-security-improvements-oneoff.sh` | SSH key cleanup + harden + firewall + optional API jail |
| `fix-audit-rules-oneoff.sh` | Repair audit watch rules when paths are missing |
| `configure-fail2ban-api-scan-jail-oneoff.sh` | `install [logpath]` \| `remove` for API-scan fail2ban jail |
| `configure-host-firewall-oneoff.sh` | Inbound TCP allowlist from the host profile |
| `configure-port-forwarding-oneoff.sh` | iptables REDIRECT (e.g. 443 → app port); optional permanent service |
| `infra-iptables-helper.sh` | Shared iptables helpers |
| `infra-port-forward-restore.sh` | Re-apply port forwards after boot (used by systemd) |

### Weekly / ongoing maintenance

| Script | What it does |
|--------|----------------|
| `manage-weekly-maintenance.sh` | `install` \| `enable` \| `disable` \| `status` for OS upgrade, cleanup, and Trivy timers |
| `install-weekly-maintenance-timers.sh` | Legacy alias for weekly timer install |
| `upgrade-host-packages-weekly.sh` | Weekly `dnf upgrade` (`--check` / `--security-only` / `--reboot-if-needed`) |
| `cleanup-disk-space-weekly.sh` | Clean journals, caches, optional Podman prune, old Trivy artifacts |
| `scan-containers-vulnerabilities-weekly.sh` | Trivy image/fs scans; reports under `~/infra-app/trivy-scan-results/` |
| `host-uptime-prep.sh` | Hourly host health signals (`init`, `enable-permanent`, `status`, `report`) |
| `enable-rootless-podman-helper.sh` | Linger + `podman.socket` for rootless Podman |
| `enable-podman-boot-autostart.sh` | Podman autostart on reboot for `INFRA_USER` |

### Tools and wallet

| Script | What it does |
|--------|----------------|
| `idcp-wallet.sh` | RODiT / NEAR wallet CLI (see [docs/readme.md](docs/readme.md) and [docs/rpc-configuration.md](docs/rpc-configuration.md)) |
| `list-vault-secrets.sh` | List Vault secrets (`discernible` / `discernible-io`, or `VAULT_PROFILE`) |
| `vault_management.sh` | Interactive Vault secret put/get/delete/list (AppRole) |
| `vault.Dockerfile` | Dev Vault image helper |
| `signing-*.hcl` / `podman-policy.hcl` | Vault policy snippets used with the vault scripts |
| `configure-mc-nano-oneoff.sh` | Point Midnight Commander F4 at nano |
| `configure-mc-nano-editor-oneoff.sh` | Same MC/nano setup for a given username |

## Documentation

| Document | Topic |
|----------|--------|
| [docs/readme.md](docs/readme.md) | Expanded script notes, RODiT usage, host software baseline |
| [docs/hardening.md](docs/hardening.md) | Server hardening notes |
| [docs/rpc-configuration.md](docs/rpc-configuration.md) | NEAR RPC for `idcp-wallet.sh` |
| [docs/maintenance-status-roadmap.md](docs/maintenance-status-roadmap.md) | Intended run cadence |
| [docs/maintenance-status.example.md](docs/maintenance-status.example.md) | Per-host status template (copy to `~/infra-app/`) |
| [docs/production-hosts.md](docs/production-hosts.md) | Reference fleet domain and port map |
| [docs/migrate-infra-app.md](docs/migrate-infra-app.md) | Move host config into `~/infra-app/` |
| [CONTRIBUTING.md](CONTRIBUTING.md) | How to send changes |
| [SECURITY.md](SECURITY.md) | Vulnerability reports and what not to commit |

## License

This project is licensed under the [MIT License](LICENSE).

<!-- discernible-io:product-links -->
---

[discernible.io](https://www.discernible.io/) · [Get a Passport](https://purchase.identyclaw.com) · [Verify HOLA](https://verify.identyclaw.com)
<!-- /discernible-io:product-links -->
