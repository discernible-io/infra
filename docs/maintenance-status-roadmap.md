# Maintenance status and roadmap

This document records the **intended run cadence** for scripts in this repository, their **role** in host and service uptime, and **planned improvements**. It supersedes ad hoc notes from a single review; update it when scripts or automation change.

**Host-specific state** (installed timers, firewall snapshot, hardening on *this* machine) belongs in the sibling app dir, not in git:

```text
~/infra-app/
  infra-env-helper.sh       # domains, ports, monitor list (required)
  maintenance-status.md     # installed automation on this host (recommended)
  trivy-scan-results/       # weekly scan output
```

Profile templates: [infra-env-helper.md](../infra-env-helper.md). Fleet domain/port map: [production-hosts.md](./production-hosts.md).

---

## Current status

### Continuous (systemd timers or sub-hourly)

These are not “daily/weekly/monthly” jobs; they should stay **enabled on production hosts** once installed.

| Item | Script / unit | Cadence | Purpose |
|------|----------------|---------|---------|
| Host signals | `host-uptime-prep.sh` via `host-uptime-prep.timer` | About **hourly** (`OnUnitActiveSec=1h`) | Disk and inode use on `/`, memory, NTP-ish sync, failed systemd units, swap, journal disk string; append-only JSON log at `/var/log/host-uptime-prep/runs.log`. Install: `sudo ./host-uptime-prep.sh init` then `enable-permanent`. |
| Container liveness | `monitor-pods-liveness-helper.sh` via `monitor-pods-liveness.timer` | **Every 2 minutes** | Restarts configured Podman containers if not running (`manage-monitoring-pods.sh install` / `enable`). |

**Human review:** run `./host-uptime-prep.sh status` or `./host-uptime-prep.sh report` on demand; a **weekly** glance at `report` is reasonable if no other monitoring exists.

### Weekly (systemd timers when installed)

Prefer **`manage-weekly-maintenance.sh`** (`install` | `enable` | `disable` | `status`) to install all weekly timers. Legacy alias: **`install-weekly-maintenance-timers.sh`**. Called automatically by **`setup-host-oneoff.sh`** and **`golive.sh`**.

| Script / unit | Schedule | Notes |
|---------------|----------|--------|
| `upgrade-host-packages-weekly.sh` via `upgrade-host-packages-weekly.timer` | Sun **02:00** (+ up to 20 min jitter) | `dnf upgrade -y` (Alma/RHEL-family). Logs under `/var/log/infra-host-package-upgrade/`. Sets `/var/lib/infra/reboot-required` when `dnf needs-restarting -r` says so; **does not reboot** unless `AUTO_REBOOT=1` / `--reboot-if-needed`. Runs before cleanup so old kernels can be pruned. |
| `cleanup-disk-space-weekly.sh` via `cleanup-disk-space-weekly.timer` | Sun **03:00** (+ up to 30 min jitter) | Journal, `/var/log`, DNF cache, old kernels, caches, optional Podman prune, old Trivy artifacts under `~/infra-app/trivy-scan-results/`. |
| `scan-containers-vulnerabilities-weekly.sh` via `scan-containers-vulnerabilities-weekly.timer` | Sun **04:30** (+ up to 15 min jitter) | Trivy on Podman + optional GHCR pulls, git HEAD tags, `trivy fs` on `*-idc` repos, SBOM diff; reports under `~/infra-app/trivy-scan-results/`. Or GitHub `container-vulnerability-scan.yml`. |
| `update-monitoring-images-weekly.sh` via `update-monitoring-images-weekly.timer` | Sun **05:30** (+ up to 15 min jitter) | Pull upstream Grafana/Loki bases (must be ≥ **3 days** old), rebuild hardened images from `grafanaloki-app`, redeploy `monitoring-pod`. Skips when local images are newer than `MIN_IMAGE_AGE_DAYS` (default 3) unless `--force`. Does **not** bump `.env` pins — only rebuilds the pinned tags. |
| `verify-certs-in-apps-weekly.sh` | Manual / after deploy | Validates cert files and permissions under app trees; good alongside renewal checks. |
| `manage-monitoring-pods.sh status` | Manual | Confirms `monitor-pods-liveness.timer` and recent `/var/log/pod-monitor.log` lines. |

### Monthly (or policy-driven)

| Script | Notes |
|--------|--------|
| `renew-certs-all-monthly.sh manual` | Manual orchestration for Let’s Encrypt plus install to app dirs. Certs are ~90 days; use as a **manual backstop** if unattended renewal is not wired. Prefer `renew-certs-all-monthly.sh certbot` on a timer with hooks; see roadmap. Many hosts also use the OS **`certbot-renew.timer`**. |

### One-time or on-demand

| Script | Typical use |
|--------|-------------|
| `bootstrap-infra-app.sh <profile>` | Create `~/infra-app/`, install host profile from [infra-env-helper.md](../infra-env-helper.md), create `trivy-scan-results/`. Profiles: **example**, **custom**, or a named fleet template. |
| `bootstrap-app-dir-layout.sh` | Create or repair `*-app/` trees (`certs/`, `logs/`, `secrets/`, …). |
| `host-uptime-prep.sh` `init` / `enable-permanent` | Install and enable the hourly timer. |
| `golive.sh` | Reboot-persistence bundle: pod monitor, rootless Podman socket, **weekly maintenance timers**, host-uptime timer, `unless-stopped` on Podman containers, API restarts, monitoring pod, **host firewall** (`configure-host-firewall-oneoff.sh enable permanent`), status. Run **`sudo ./golive.sh`**; Podman steps use **`INFRA_USER`** via `runuser` (rootless store). Optional **`--with-port-forwarding`** for 443 REDIRECT. Does **not** harden SSH or issue certs. |
| `setup-host-oneoff.sh` | Full bootstrap from `~/infra-app`: rootless Podman, weekly timers, pod monitor, app layout, TLS, firewall, optional 443 redirect. |
| `apply-security-improvements-oneoff.sh` | SSH `authorized_keys` cleanup, `harden-server-oneoff.sh`, host firewall, optional idclaw API fail2ban jail, verification. |
| `apply-health-recommendations.sh` | Rootless Podman linger/socket, weekly maintenance timers, firewall status summary. |
| `harden-server-oneoff.sh` | Bootstrap or rare hardening change (SSH key-only, fail2ban, auditd, secrets watch). |
| `fix-audit-rules-oneoff.sh` | Repair audit watch rules when secrets paths moved or are missing. |
| `configure-host-firewall-oneoff.sh` | Restrict inbound TCP to admin + public ports from `~/infra-app/infra-env-helper.sh`. Use **`sudo ./configure-host-firewall-oneoff.sh enable permanent`**; verify with **`sudo … status`** (non-root cannot read iptables). |
| `configure-port-forwarding-oneoff.sh` | iptables 443→`INFRA_PORT_FORWARD_DEST` REDIRECT; `infra-port-forward-restore.sh` re-applies after reboot when installed permanent. |
| `manage-weekly-maintenance.sh` | `install` \| `enable` \| `disable` \| `status` for OS upgrade + cleanup + Trivy + monitoring-image weekly timers. |
| `upgrade-host-packages-weekly.sh` | Manual / timer: `--check`, `--security-only`, `--reboot-if-needed`. |
| `update-monitoring-images-weekly.sh` | Manual / timer: rebuild Grafana/Loki when images ≥ 3d old; `--check` / `--force`. |
| `manage-monitoring-pods.sh` | `install`, `enable`, `disable`, or `status` for pod monitoring. |
| `enable-rootless-podman-helper.sh` | `enable` \| `status` — linger + `podman.socket` for **`INFRA_USER`** (or **`MONITOR_USER`**). |
| `enable-podman-boot-autostart.sh` | Linger + podman.socket + podman-restart for **`INFRA_USER`**. |
| `start-monitoring-pod.sh` | Start Grafana/Loki monitoring pod if missing. |
| `generate-cert-letsencrypt.sh`, `install-certs-to-apps.sh` | Initial issuance or called from renewal flow. |
| `restart-containers-apis.sh` | Ordered container restarts after deploy or cert reload (rootless: run as **`INFRA_USER`**, or via `golive.sh`). |
| `verify-cert-mount-permissions.sh` | Validates Podman/nginx cert mount permissions when changing layout. |
| `configure-fail2ban-api-scan-jail-oneoff.sh` | Optional fail2ban jail for API scan patterns (`install` / `remove`). |
| `configure-mc-nano-oneoff.sh`, `configure-mc-nano-editor-oneoff.sh` | MC F4 → nano editor setup. |
| `idcp-wallet.sh` | RODiT / NEAR wallet workflows (not generic host maintenance). |

### Installed automation on this host

Record what is **actually enabled on each machine** in **`~/infra-app/maintenance-status.md`** (never commit). After bootstrap, copy the template from [maintenance-status.example.md](./maintenance-status.example.md) or let `bootstrap-infra-app.sh` create it.

Verify from `~/infra`:

```bash
./manage-weekly-maintenance.sh status
./manage-monitoring-pods.sh status
./host-uptime-prep.sh status
sudo ./configure-host-firewall-oneoff.sh status
```

Fleet domain/port reference: [production-hosts.md](./production-hosts.md). Live allowlist on a host comes from **`~/infra-app/infra-env-helper.sh`**.

### Known inconsistencies (status)

- **Pod monitor / weekly unit templates:** Committed `.service`/`.timer` files use **`__INFRA_USER__`**, **`__INFRA_HOME__`**, **`__INFRA_REPO__`** placeholders. `install` rewrites them from the host profile (`INFRA_USER` / `INFRA_HOME` / `INFRA_REPO`). Override monitor user with **`MONITOR_USER`** if needed.
- **Rootless Podman under sudo:** `podman` as root sees an empty container list. **`golive.sh`**, **`cleanup-disk-space-weekly.sh`**, and **`install-certs-on-renew-hook-helper.sh`** run Podman as **`INFRA_USER`** (`runuser` + `XDG_RUNTIME_DIR`). Other scripts invoked manually may still need the same pattern.
- **Host profiles:** sibling **`~/infra-app/`** (never commit); templates in [infra-env-helper.md](../infra-env-helper.md) / [production-hosts.md](./production-hosts.md) — **example**, **custom**, or a named fleet template.
- **Weekly timer installers:** prefer **`manage-weekly-maintenance.sh`**; **`install-weekly-maintenance-timers.sh`** is a legacy alias with the same outcome.

---

## Future improvements (roadmap)

Prioritize items that close gaps between “scripts exist” and “long uptime with minimal surprise.”

1. **Unattended TLS renewal aligned with app install**  
   `renew-certs-all-monthly.sh manual` prompts interactively for service restart. For production, use **`renew-certs-all-monthly.sh certbot`** on a timer plus the deploy hook that runs `install-certs-to-apps.sh` and reloads or restarts only what is needed, without `read`.

2. **Optional auto-reboot after OS upgrades**  
   Weekly upgrade already records `/var/lib/infra/reboot-required`. Consider host-local `AUTO_REBOOT=1` in the systemd unit only where a brief Sunday reboot is acceptable; otherwise keep manual reboot after reviewing the flag / `manage-weekly-maintenance.sh status`.

3. **Backups and restore verification**  
   No backup or restore-test script lives here; add runbooks or automation and a **monthly** or **quarterly** restore drill where data loss would hurt availability.

4. **Disk hardware health (optional)**  
   For bare metal, consider periodic **SMART** or controller-specific health checks where relevant.

5. **Single source of truth for monitoring paths**  
   Document **`MONITOR_USER`** and repo path once; `manage-monitoring-pods.sh` already resolves paths from the script location.

6. **Bump Grafana/Loki version pins**  
   `update-monitoring-images-weekly.sh` rebuilds the tags in `grafanaloki-app/.env`. Promoting to a newer upstream release (e.g. Grafana 11.6.x → 11.6.y) remains a manual `.env` / Dockerfile change.

---

## Related documentation

- [../README.md](../README.md) — project overview and license.
- [maintenance-status.example.md](./maintenance-status.example.md) — copy to `~/infra-app/maintenance-status.md` per host.
- Pod monitoring: see `docs/readme.md` (Container Monitoring) for install and usage.

When automation changes on a host, update **`~/infra-app/maintenance-status.md`** on that machine (timers, firewall snapshot, hardening state). Update this file only when shared scripts or intended cadence change.
