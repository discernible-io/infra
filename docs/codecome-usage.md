# CodeCome — usage notes (from host audit experience)

Practical guide for running [CodeCome](https://github.com/pruiz/CodeCome) against first-party Discernible app repos on this class of host. Based on a full Phase 1→5 run (SignSanctum / SignPortal portfolio, 2026-10-20).

CodeCome is **not** part of `~/infra`. Clone it separately when you need an authorized defensive review, then delete the workspace when finished (audit trees + CodeQL tooling are large).

## What it is

Phased, agent-driven security review:

| Phase | Purpose | Typical agent |
|-------|---------|----------------|
| **1a–1c** | Recon, sandbox bootstrap, CodeQL, threat notes | `recon` |
| **2** | HIGH/CRITICAL hypotheses → `PENDING` findings | `auditor` |
| **3** | Counter-analysis / dedup (usually keeps or rejects) | `reviewer` |
| **4** | Validate one finding → `CONFIRMED` / `REJECTED` | `validator` |
| **5** | PoC for a confirmed finding → `EXPLOITED` | `exploiter` |
| **6** | Formal report (optional) | `reporter` |

Artifacts live under the CodeCome checkout: `itemdb/notes/`, `itemdb/findings/`, `itemdb/evidence/`, `runs/`.

## Prerequisites

```bash
# OpenCode CLI on PATH (bash profile usually has this)
export PATH="$HOME/.opencode/bin:$HOME/.local/bin:$PATH"
which opencode

# Optional but used here: Cursor-hosted model id
# CODECOME_MODEL=cursor/composer-2.5
```

Non-login shells (`nohup`, cron, Cursor agent shells) often **omit** `~/.bashrc` PATH — always export `PATH` explicitly before `make phase-*`.

Also needed: Python venv (`make venv` in CodeCome), Docker/Podman as required by the sandbox recipe, and disk for CodeQL under `.tools/` (~0.7G+) plus DBs under `itemdb/codeql/`.

## Setup for a Discernible portfolio review

```bash
git clone git@github.com:pruiz/CodeCome.git ~/CodeCome
cd ~/CodeCome
make venv

# Put first-party trees under src/ (copy or rsync; avoid polluting product .git)
mkdir -p src
rsync -a --delete --exclude node_modules --exclude .git \
  ~/signsanctum-idc/ src/signsanctum-idc/
rsync -a --delete --exclude node_modules --exclude .git \
  ~/signportal-idc/ src/signportal-idc/
# add mintclient-idc, api-test-scaffold, app, … as needed

# Install deps inside copies if Phase 1b/validation needs them
(cd src/signsanctum-idc && npm ci)   # or npm install
(cd src/signportal-idc && npm ci)
```

Edit `codecome.yml`:

- Set `target.description` / `assumptions` to **authorized first-party remediation**.
- Under `audit.extra_prompts`, pin **HIGH/CRITICAL only** for hypothesis, validation, and reporting.
- Keep `source_path: "./src"` and sensible `scope.exclude` (`node_modules`, `.git`, …).

## Recommended run order

Pin the model on every phase (example used successfully on this host):

```bash
export PATH="$HOME/.opencode/bin:$HOME/.local/bin:$PATH"
export CODECOME_MODEL=cursor/composer-2.5
cd ~/CodeCome

make phase-1    # ~15–25 min with CodeQL on a multi-repo Node portfolio
make phase-2    # hypotheses → PENDING
make phase-3    # counter-analysis; does not CONFIRMED by design
```

Validate pending findings one by one (or `make validate-all`):

```bash
make phase-4 FINDING=CC-0001
make findings STATUS=CONFIRMED
```

**Exploits — only CONFIRMED HIGH/CRITICAL.** Do **not** rely on `make exploit-all` alone: `--eligible-for-exploit` means “CONFIRMED and not yet exploited,” **not** “HIGH/CRITICAL.” Filter yourself:

```bash
# Example: only HIGH/CRITICAL confirmed IDs
make phase-5 FINDING=CC-0001
make phase-5 FINDING=CC-0002
# skip MEDIUM even if CONFIRMED
```

Optional wrap-up:

```bash
make phase-6
```

Ad-hoc prompt overrides:

```bash
PROMPT_EXTRA="Use staging secrets; no production." make phase-4 FINDING=CC-0001
```

## Timing and cost (observed)

| Phase | Ballpark (composer-2.5) |
|-------|-------------------------|
| Phase 1 (1a+1b+CodeQL+1c) | ~15–25 minutes |
| Phase 2 / 3 | ~2–3 minutes each |
| Phase 4 per finding | ~3–5 minutes |
| Phase 5 per finding | ~3–5 minutes |

Background `nohup` works if `PATH` includes OpenCode. Log under `runs/logs/` and stop a sequential queue with `TERM` on the parent `make` / wrapper (in-flight finding may finish or stay partially written — re-run that `FINDING` if unsure).

## Lessons that mattered

1. **Severity gate in `codecome.yml`** — without it, Phase 2 floods Medium/Low noise.
2. **Exploit only HIGH/CRITICAL** — `exploit-all` will happily PoC MEDIUM CONFIRMED findings.
3. **Sandbox ≠ staging** — many Phase 4/5 proofs use local Express fixtures and mocked login when Vault/NEAR secrets are absent. Treat impact as “API/middleware confirmed”; on-chain or production JWT claim distributions stay open questions unless you feed staging secrets via `PROMPT_EXTRA` / `PROMPT_EXTRA_FILE`.
4. **Remediation handoff** — copy finding markdown into each product repo (e.g. `security-audit/CC-000N.md`) with absolute paths to `itemdb/evidence/CC-000N/exploits/` on the audit host. Remove those dirs after fixes land.
5. **Disk** — expect ~1G+ for `.tools/codeql` + DBs + `src/*/node_modules`. Delete the whole `~/CodeCome` tree when the engagement is done; product remotes (`~/signsanctum-idc`, etc.) stay untouched except any handoff folder you added.

## Cleanup after an engagement

```bash
# Remove handoff copies from product checkouts if present
rm -rf ~/signsanctum-idc/security-audit ~/signportal-idc/security-audit

# Remove the entire audit workspace (tooling + findings + CodeQL)
rm -rf ~/CodeCome
```

Re-clone from `git@github.com:pruiz/CodeCome.git` for the next review.

## Useful commands

```bash
make status
make findings STATUS=PENDING
make findings STATUS=CONFIRMED
make findings STATUS=EXPLOITED
.venv/bin/python3 tools/list-findings.py --status CONFIRMED --eligible-for-exploit --format plain
make frontmatter
```

Upstream workflow detail: CodeCome `docs/workflow.md` after clone.

## Scope of the 2026-10-20 host run (historical)

Portfolio under `src/`: signsanctum-idc, signportal-idc, mintclient-idc, api-test-scaffold, app.

| ID | Severity | Outcome | Area |
|----|----------|---------|------|
| CC-0001 | HIGH | Exploited then remediated | SignSanctum — missing `validatepermissions` on signing routes |
| CC-0002 | HIGH | Exploited then remediated | SignSanctum — unbounded `tamperproofedValues` policy signing |
| CC-0003 | HIGH | Exploited then remediated | SignPortal — arbitrary minting fee on client signing |
| CC-0004 | MEDIUM | Confirmed, no exploit (policy) | SignSanctum — post-auth rate limit fail-open |

No HIGH findings in mintclient / app / api-test-scaffold on that pass. Audit workspace and handoff folders were removed from this host after remediation.
