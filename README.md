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

Named fleet templates (`dedalo43`, `dedalo47`, …) are listed in [infra-env-helper.md](infra-env-helper.md). Extra tenant apps belong only in `~/infra-app/`.

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

## Documentation

| Document | Topic |
|----------|--------|
| [docs/readme.md](docs/readme.md) | Script catalog and host software baseline |
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

Archived VPN helpers in `archive/` call the `wg` command-line tool. They do not include [WireGuard](https://www.wireguard.com/) source. WireGuard is a registered trademark of Jason A. Donenfeld. Discernible-IO is not sponsored or endorsed by Jason A. Donenfeld.

<!-- discernible-io:product-links -->
---

[discernible.io](https://www.discernible.io/) · [Get a Passport](https://purchase.identyclaw.com) · [Verify HOLA](https://verify.identyclaw.com)
<!-- /discernible-io:product-links -->
