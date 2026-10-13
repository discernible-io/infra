# Production host layout

Reference mapping for the Discernible / dihola fleet. DNS often points at
**icarus** edge hosts; Alma **dedalo** hosts run Podman stacks.

This file is an **example inventory**: domains and ports only. Live addresses,
credentials, and per-host firewall state stay in DNS and in `~/infra-app/`
(never commit IPs or secrets). Forks should replace this map with their own
hosts.

## idclawserver (main API, port 5443 + 443 redirect)

| Edge | Domain              | Alma host |
|------|---------------------|-----------|
| —    | api.identyclaw.com  | **dedalo44** |

## signportal-rodit (sign portal, port 14443)

| Edge     | Domain                      | Alma host  |
|----------|-----------------------------|------------|
| —        | signportal.discernible.io   | **dedalo42** |
| icarus40 | signportal.dihola.io        | dedalo47 |

## signsanctum-rodit (sign sanctum, port 1443)

| Edge     | Domain                       | Alma host  |
|----------|------------------------------|------------|
| —        | signsanctum.discernible.io   | **dedalo42** |
| icarus40 | signsanctum.dihola.io        | dedalo47 |

## mintrootapi-rodit (root API, port 6443)

| Edge        | Domain              | Alma host |
|-------------|---------------------|-----------|
| icarus39    | root.dihola.io      | dedalo47 |
| (discernible)| root.discernible.io | **dedalo46** |

## mintserver-ic (identyclaw, port 2443)

| Edge     | Domain                      | Alma host |
|----------|-----------------------------|-----------|
| icarus39 | identyclaw.dihola.io        | dedalo47 |
| —        | identyclaw.discernible.io   | **dedalo46** |

## mintclient-ic (purchase + HOLA verify, port 4443 + 443 redirect)

| Edge     | Domain                   | Alma host |
|----------|--------------------------|-----------|
| icarus40 | purchase.dihola.io       | dedalo47 |
| icarus40 | verify.dihola.io         | dedalo47 |
| —        | purchase.identyclaw.com  | **dedalo46** |
| —        | verify.identyclaw.com    | **dedalo46** |

`verify.*` is included as a **SAN** on the `purchase.*` Let's Encrypt certificate
(see `INFRA_CERT_SAN_DOMAINS` in `infra-env-helper.sh`). Both hostnames share
`mintclient-app/certs/fullchain.pem`.

## Product apex (identyclaw.com)

| Note | Detail |
|------|--------|
| DNS | Apex is at the registrar (IONOS), not on the Alma fleet |
| Commerce | Live purchase host remains `purchase.identyclaw.com` (unchanged) |
| Product home | Live marketing host remains `www.discernible.io` (unchanged) |

Document-only: apex HTTPS/cert health is a registrar concern. Do **not** rename or retire existing IdentyClaw / Discernible / Last Cradle hostnames in app configs.

## openclaw-agents (OpenClaw agents, port 8443 on dedalo46)

Shared nginx TLS ingress on **8443** on **dedalo46** (`identyclaw-agents-pod` /
`openclaw-nginx`). Telegram Bot API webhooks only accept **80, 88, 443, or 8443**.
Agent gateways are pod-internal (18789 / 18791 / 18793 / …). App dir:
`~/openclaw-agents-app`. Repo: `~/openclaw-agents`.

| Edge | Domain                    | Alma host  |
|------|---------------------------|------------|
| —    | andrew.dihola.io          | **dedalo46** |
| —    | joe.dihola.io             | **dedalo46** |
| —    | daniel.dihola.io          | **dedalo46** |
| —    | identyclaw-concierge.identyclaw.com | **dedalo46** |
| —    | agent-a.identyclaw.com    | **dedalo43** |
| —    | agent-b.identyclaw.com    | **dedalo43** |
| —    | agent-c.identyclaw.com    | **dedalo43** |

dedalo43 still documents nginx on **9443** in its host profile; dedalo47 uses **88**.

## monitoring (Grafana, port 3335 published / 3333 in stack)

| Edge     | Domain                    | Alma host |
|----------|---------------------------|-----------|
| icarus39 | grafana47.dihola.io       | dedalo47 |
| —        | grafana46.discernible.io  | **dedalo46** |

## slcbackend / SLC production (api.lastcradle.io, port 13443 + 443 redirect)

`slc.dihola.io` is not registered on **dedalo47**. Related hostnames that remain in configs and docs (do **not** rename):
`slc.discernible.io`, `slc.discernible.io:8443`, `slcapi.discernible.io`, `slcapi.discernible.io:9443`.
There is no `~/syntheticlc-app` on this host.

| Edge | Domain              | Alma host    |
|------|---------------------|--------------|
| —    | api.lastcradle.io   | **dedalo47** |

App directory: `~/slcbackend-app`. Repo checkout: `~/slcbackend-slc`
([discernible-io/syntheticslastcradle](https://github.com/discernible-io/syntheticslastcradle.git), `main`).
Host publishes **13443**; permanent **443→13443** via
`configure-port-forwarding-oneoff.sh` (`INFRA_PORT_FORWARD_SERVICE=slcbackend`).

## identyclaw agents on dedalo47 (shared nginx ingress, port 88)

Agents share one Podman publish **88→88** (nginx `listen 88 ssl` with SNI).
Telegram Bot API webhooks only accept **80, 88, 443, or 8443**.

| Edge     | Domain              | Alma host |
|----------|---------------------|-----------|
| icarus39 | andrew.dihola.io    | dedalo47 |
| icarus39 | joe.dihola.io       | dedalo47 |
| icarus39 | daniel.dihola.io    | dedalo47 |

App directory: `~/openclaw-agents-app` (`env.local` `AGENT_*_PUBLIC_HOST`).
Repo: `~/openclaw-agents`. Self-signed TLS (not Let's Encrypt via infra).

## hermes agents on dedalo47 (11xxx ports)

Podman pod `hermes-agents-pod` (`hermes` + `hermes-nginx`). Port block:

| Role | Port | Notes |
|------|------|--------|
| Ingress (nginx TLS / webhooks) | **11443** | Public; `INFRA_API_PORTS[hermesagents]` |
| Operator API | **11642** | Host-local; not in firewall allowlist |
| Dashboard (optional) | **11919** | Host-local; `HERMES_DASHBOARD=1` |

Public path: `https://$HERMES_PUBLIC_HOST:11443/webhooks/<route>` (HMAC). TLS is
self-signed via `./hermes.sh generate-certs` (not Let's Encrypt). Separate from
OpenClaw **88**.

| Edge | Domain | Alma host |
|------|--------|-----------|
| — | `HERMES_PUBLIC_HOST` (`env.local`) | **dedalo47** |

App directory: `~/hermes-agents-app` (`HERMES_DEPLOY_MODE=pod`,
`HERMES_INGRESS_PORT=11443`, `HERMES_API_PORT=11642`).
Repo: `~/hermes-agents`.

## This repository on dedalo44

Scripts load host config from the sibling **`~/infra-app/infra-env-helper.sh`**
(see [infra-env-helper.md](../infra-env-helper.md)). Install once with
`./bootstrap-infra-app.sh dedalo44` (or move a legacy in-repo profile into `~/infra-app/`).

- **idclawserver** — api.identyclaw.com:5443 (443→5443 redirect)

Bootstrap: `sudo ./setup-host-oneoff.sh`

## dedalo46 (Discernible IC + monitoring)

- **mintroot** — root.discernible.io:6443
- **mintserver** — identyclaw.discernible.io:2443
- **mintclient** — purchase.identyclaw.com:4443 (443→4443 redirect)
- **openclaw-agents** — andrew/joe/daniel.dihola.io + identyclaw-concierge.identyclaw.com:8443
- **grafanaloki** — grafana46.discernible.io (host port 3335)

Bootstrap: `sudo ./setup-host-oneoff.sh`

### Host `*-app` directory layout

Each runtime app tree under `~/…-app/` follows the generic CI/CD host layout:

```
~/<app-dir>/
├── certs/              # fullchain.pem, privkey.pem (chmod 711 on certs/)
├── logs/
├── data/
├── nginx/              # reference only; live config is in the image
└── secrets/
    └── secrets.env     # chmod 644; --env-file at runtime
```

On this host: `idclawserver-app`. Create or repair layout:

```bash
cd ~/infra
./bootstrap-app-dir-layout.sh
```

Sibling hosts: **dedalo42** (Discernible signportal/signsanctum), **dedalo46** (Discernible IC + monitoring), **dedalo47** (dihola stack).

**dedalo47** uses `setup-host-oneoff.sh` with the dihola profile in
[infra-env-helper.md](../infra-env-helper.md) (`~/infra-app`).
