# Maintenance status — HOSTNAME

Host-local record of **installed automation on this machine**. Lives in **`~/infra-app/maintenance-status.md`** (never commit). Generic script cadence: `~/infra/docs/maintenance-status-roadmap.md`.

**Last updated:** YYYY-MM-DD

## Host

| Field | Value |
|-------|-------|
| Hostname | |
| Profile | `~/infra-app/infra-env-helper.sh` |
| Public IP | |

## Installed timers / units

| Unit | State | Notes |
|------|-------|-------|
| `host-uptime-prep.timer` | not installed / enabled / disabled | Hourly host signals |
| `monitor-pods-liveness.timer` | | Every 2 min |
| `upgrade-host-packages-weekly.timer` | | Sun ~02:00 (dnf upgrade; no auto-reboot by default) |
| `cleanup-disk-space-weekly.timer` | | Sun ~03:00 |
| `scan-containers-vulnerabilities-weekly.timer` | | Sun ~04:30 |
| `update-monitoring-images-weekly.timer` | | Sun ~05:30 (Grafana/Loki rebuild; images ≥ 3d old) |
| `certbot-renew.timer` | | OS package (if present) |

Quick check from `~/infra`:

```bash
./manage-weekly-maintenance.sh status
./manage-monitoring-pods.sh status
./host-uptime-prep.sh status
```

## Host firewall

Summarize from `sudo ./configure-host-firewall-oneoff.sh status` and `~/infra-app/infra-env-helper.sh` (allowed TCP, 443 REDIRECT target, blocked ports).

## Hardening

| Control | State |
|---------|-------|
| SSH drop-in (`/etc/ssh/sshd_config.d/99-infra-hardening.conf`) | |
| fail2ban (`sshd`) | |
| auditd + secrets watch | |
| API scan jail (`configure-fail2ban-api-scan-jail-oneoff.sh`) | optional |

Apply bundle: `sudo ./apply-security-improvements-oneoff.sh`

## Notes / next steps

- 
