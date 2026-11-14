#!/usr/bin/env bash
# Scrub secret values out of bash history and other text files.
#
# Loads values from each app's secrets/secrets.env (and api.env / env.local when
# present). Secret *content* in those source files is never rewritten — basename
# secrets.env is always skipped for scrubbing. Ownership/mode of secrets.env
# (and its secrets/ directory) are validated against the host layout standard
# and fixed on apply.
#
# Expected layout (same as bootstrap-app-dir-layout / verify-certs-in-apps):
#   secrets/           mode 0750, owner INFRA_USER
#   secrets/secrets.env mode 0644, owner INFRA_USER  (--env-file readable)
#
# Usage:
#   ./scrub-secrets-oneoff.sh                 # dry-run default history targets
#   ./scrub-secrets-oneoff.sh apply           # fix perms + rewrite history matches
#   ./scrub-secrets-oneoff.sh dry-run PATH…   # scan extra files/dirs
#   ./scrub-secrets-oneoff.sh apply PATH…
#   ./scrub-secrets-oneoff.sh help
#
# Environment:
#   SCRUB_MIN_LEN=8     skip values shorter than this (default 8)
#   SCRUB_INCLUDE_HIST=0  do not add default shell-history targets
#
# After apply on ~/.bash_history, restart the shell or run:
#   history -c; history -r

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=infra-env-helper.sh
source "$SCRIPT_DIR/infra-env-helper.sh"

MODE="dry-run"
MIN_LEN="${SCRUB_MIN_LEN:-8}"
INCLUDE_HIST="${SCRUB_INCLUDE_HIST:-1}"
TARGETS=()
PERM_ISSUES=0
PERM_FIXED=0

# Layout standard for secrets.env (Podman --env-file).
SECRETS_ENV_MODE="644"
SECRETS_DIR_MODE="750"

usage() {
  cat <<EOF
Usage: $(basename "$0") [dry-run|apply] [PATH...]

Load secret values from app secrets.env (never rewrite those files' content),
validate ownership/permissions on secrets.env, then scrub leaked values from
shell history and any other paths you pass.

  dry-run   Report perm issues and files/lines that would change (default)
  apply     Fix secrets.env ownership/mode; rewrite matching history/files

Expected: secrets/ ${SECRETS_DIR_MODE}, secrets.env ${SECRETS_ENV_MODE},
owner ${INFRA_USER:-INFRA_USER}.

Default targets (unless SCRUB_INCLUDE_HIST=0): HISTFILE, ~/.bash_history,
~/.zsh_history, ~/.python_history, ~/.mysql_history, ~/.node_repl_history,
and fish history when present.

Paths may be files or directories. Directory walks skip .git, node_modules,
binary files, and any file named secrets.env.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    help|-h|--help)
      usage
      exit 0
      ;;
    dry-run|apply)
      MODE="$1"
      shift
      ;;
    --)
      shift
      TARGETS+=("$@")
      break
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      TARGETS+=("$1")
      shift
      ;;
  esac
done

TARGET_USER="${SUDO_USER:-${INFRA_USER:-$USER}}"
if [[ "$TARGET_USER" == root ]]; then
  TARGET_USER="${INFRA_USER:-$USER}"
fi
HOME_DIR="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
if [[ -z "$HOME_DIR" || ! -d "$HOME_DIR" ]]; then
  HOME_DIR="${HOME:-}"
fi

# Collect secret source files from the host profile app dirs.
SECRET_SOURCES=()
add_secret_source() {
  local f="$1"
  [[ -f "$f" && -r "$f" ]] || return 0
  local s
  for s in "${SECRET_SOURCES[@]+"${SECRET_SOURCES[@]}"}"; do
    [[ "$s" == "$f" ]] && return 0
  done
  SECRET_SOURCES+=("$f")
}

if [[ -n "${INFRA_APP_DOMAINS[*]+x}" ]]; then
  for app_dir in "${!INFRA_APP_DOMAINS[@]}"; do
    add_secret_source "${app_dir}/secrets/secrets.env"
    add_secret_source "${app_dir}/secrets/api.env"
    add_secret_source "${app_dir}/env.local"
    add_secret_source "${app_dir}/.env"
  done
fi

# Also pick up any *-app/secrets/secrets.env under INFRA_HOME.
if [[ -n "${INFRA_HOME:-}" && -d "${INFRA_HOME}" ]]; then
  while IFS= read -r -d '' f; do
    add_secret_source "$f"
  done < <(find "$INFRA_HOME" -maxdepth 3 -type f -path '*/secrets/secrets.env' -print0 2>/dev/null || true)
fi

if [[ ${#SECRET_SOURCES[@]} -eq 0 ]]; then
  echo "Error: no readable secrets.env (or api.env / env.local) found." >&2
  exit 1
fi

EXPECTED_OWNER="${INFRA_USER:-$TARGET_USER}"

# Validate (and on apply, fix) ownership/mode for every secrets.env we found.
# Content is never rewritten here.
validate_secrets_env_layout() {
  local src base dir cur_mode cur_owner want_file_mode want_dir_mode
  local -a secrets_env_files=()

  for src in "${SECRET_SOURCES[@]}"; do
    base="$(basename "$src")"
    [[ "$base" == "secrets.env" ]] || continue
    secrets_env_files+=("$src")
  done

  # Also validate profile-mapped secrets.env paths even if empty/unreadable earlier.
  if [[ -n "${INFRA_APP_DOMAINS[*]+x}" ]]; then
    local app_dir env_rel env_file
    for app_dir in "${!INFRA_APP_DOMAINS[@]}"; do
      env_rel="${INFRA_APP_ENV_FILES[$app_dir]:-secrets/secrets.env}"
      env_file="${app_dir}/${env_rel}"
      if [[ "$(basename "$env_file")" == "secrets.env" && -e "$env_file" ]]; then
        local already=0 s
        for s in "${secrets_env_files[@]+"${secrets_env_files[@]}"}"; do
          [[ "$s" == "$env_file" ]] && { already=1; break; }
        done
        [[ "$already" -eq 0 ]] && secrets_env_files+=("$env_file")
      fi
    done
  fi

  if [[ ${#secrets_env_files[@]} -eq 0 ]]; then
    echo "Warning: no secrets.env files found to validate ownership/permissions." >&2
    return 0
  fi

  echo "secrets.env ownership/permissions (expect owner=${EXPECTED_OWNER}, file=${SECRETS_ENV_MODE}, dir=${SECRETS_DIR_MODE}):"

  for src in "${secrets_env_files[@]}"; do
    dir="$(dirname "$src")"
    want_file_mode="$SECRETS_ENV_MODE"
    want_dir_mode="$SECRETS_DIR_MODE"

    if [[ ! -f "$src" ]]; then
      echo "  ✗ missing: $src"
      PERM_ISSUES=$((PERM_ISSUES + 1))
      continue
    fi

    cur_mode="$(stat -c '%a' "$src")"
    cur_owner="$(stat -c '%U' "$src")"
    if [[ "$cur_owner" == "$EXPECTED_OWNER" && "$cur_mode" == "$want_file_mode" ]]; then
      echo "  ✓ $src  ${cur_owner} mode ${cur_mode}"
    else
      echo "  ✗ $src  ${cur_owner} mode ${cur_mode} (expected ${EXPECTED_OWNER} mode ${want_file_mode})"
      PERM_ISSUES=$((PERM_ISSUES + 1))
      if [[ "$MODE" == "apply" ]]; then
        if [[ "$cur_mode" != "$want_file_mode" ]]; then
          chmod "$want_file_mode" "$src"
          echo "    fixed mode -> ${want_file_mode}"
          PERM_FIXED=$((PERM_FIXED + 1))
        fi
        if [[ "$cur_owner" != "$EXPECTED_OWNER" ]]; then
          if [[ "$(id -u)" -eq 0 ]]; then
            chown "${EXPECTED_OWNER}:${EXPECTED_OWNER}" "$src"
            echo "    fixed owner -> ${EXPECTED_OWNER}:${EXPECTED_OWNER}"
            PERM_FIXED=$((PERM_FIXED + 1))
          else
            echo "    Error: cannot chown without root (sudo $0 apply)" >&2
            return 1
          fi
        fi
      fi
    fi

    if [[ -d "$dir" && "$(basename "$dir")" == "secrets" ]]; then
      cur_mode="$(stat -c '%a' "$dir")"
      cur_owner="$(stat -c '%U' "$dir")"
      if [[ "$cur_owner" == "$EXPECTED_OWNER" && "$cur_mode" == "$want_dir_mode" ]]; then
        echo "  ✓ $dir/  ${cur_owner} mode ${cur_mode}"
      else
        echo "  ✗ $dir/  ${cur_owner} mode ${cur_mode} (expected ${EXPECTED_OWNER} mode ${want_dir_mode})"
        PERM_ISSUES=$((PERM_ISSUES + 1))
        if [[ "$MODE" == "apply" ]]; then
          if [[ "$cur_mode" != "$want_dir_mode" ]]; then
            chmod "$want_dir_mode" "$dir"
            echo "    fixed mode -> ${want_dir_mode}"
            PERM_FIXED=$((PERM_FIXED + 1))
          fi
          if [[ "$cur_owner" != "$EXPECTED_OWNER" ]]; then
            if [[ "$(id -u)" -eq 0 ]]; then
              chown "${EXPECTED_OWNER}:${EXPECTED_OWNER}" "$dir"
              echo "    fixed owner -> ${EXPECTED_OWNER}:${EXPECTED_OWNER}"
              PERM_FIXED=$((PERM_FIXED + 1))
            else
              echo "    Error: cannot chown without root (sudo $0 apply)" >&2
              return 1
            fi
          fi
        fi
      fi
    fi
  done
  echo ""
}

# Default history targets for the infra user.
if [[ "$INCLUDE_HIST" != "0" ]]; then
  hist_candidates=(
    "${HISTFILE:-}"
    "${HOME_DIR}/.bash_history"
    "${HOME_DIR}/.zsh_history"
    "${HOME_DIR}/.python_history"
    "${HOME_DIR}/.mysql_history"
    "${HOME_DIR}/.node_repl_history"
    "${HOME_DIR}/.local/share/fish/fish_history"
  )
  for f in "${hist_candidates[@]}"; do
    [[ -n "$f" && -f "$f" ]] || continue
    TARGETS+=("$f")
  done
fi

if [[ ${#TARGETS[@]} -eq 0 ]]; then
  echo "Error: no targets to scan. Pass file/dir paths, or ensure history files exist." >&2
  exit 1
fi

# Deduplicate targets while preserving order.
declare -A SEEN_TARGET=()
UNIQUE_TARGETS=()
for t in "${TARGETS[@]}"; do
  # Resolve relative paths against cwd
  if [[ "$t" != /* ]]; then
    t="$(pwd)/$t"
  fi
  [[ -e "$t" ]] || { echo "Warning: skipping missing path: $t" >&2; continue; }
  [[ -n "${SEEN_TARGET[$t]:-}" ]] && continue
  SEEN_TARGET[$t]=1
  UNIQUE_TARGETS+=("$t")
done
TARGETS=("${UNIQUE_TARGETS[@]}")

if [[ ${#TARGETS[@]} -eq 0 ]]; then
  echo "Error: no existing targets to scan." >&2
  exit 1
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/scrub-secrets.XXXXXX")"
chmod 700 "$TMP_DIR"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

PATTERNS_FILE="${TMP_DIR}/patterns.txt"
SOURCES_FILE="${TMP_DIR}/sources.txt"
TARGETS_FILE="${TMP_DIR}/targets.txt"
: >"$PATTERNS_FILE"
chmod 600 "$PATTERNS_FILE"

# Parse KEY=VALUE lines; keep values only (never echo them).
extract_values() {
  local file="$1"
  # Strip CR, comments, blank lines; support export and optional quotes.
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      local raw="${BASH_REMATCH[3]}"
      # Trim surrounding whitespace
      raw="${raw#"${raw%%[![:space:]]*}"}"
      raw="${raw%"${raw##*[![:space:]]}"}"
      # Drop matching single/double quotes
      if [[ "$raw" =~ ^\"(.*)\"$ ]]; then
        raw="${BASH_REMATCH[1]}"
      elif [[ "$raw" =~ ^\'(.*)\'$ ]]; then
        raw="${BASH_REMATCH[1]}"
      fi
      [[ -z "$raw" ]] && continue
      if ((${#raw} < MIN_LEN)); then
        continue
      fi
      printf '%s\n' "$raw"
    fi
  done <"$file"
}

RAW_PATTERNS="${TMP_DIR}/patterns.raw"
: >"$RAW_PATTERNS"
chmod 600 "$RAW_PATTERNS"
for src in "${SECRET_SOURCES[@]}"; do
  printf '%s\n' "$src" >>"$SOURCES_FILE"
  extract_values "$src" >>"$RAW_PATTERNS"
done

# Deduplicate without putting values in bash associative-array keys.
sort -u "$RAW_PATTERNS" >"$PATTERNS_FILE"
rm -f "$RAW_PATTERNS"
VALUE_COUNT="$(grep -c . "$PATTERNS_FILE" || true)"

if [[ "$VALUE_COUNT" -eq 0 ]]; then
  echo "Error: no secret values >= ${MIN_LEN} chars found in source files." >&2
  echo "Sources checked:" >&2
  printf '  %s\n' "${SECRET_SOURCES[@]}" >&2
  exit 1
fi

printf '%s\n' "${TARGETS[@]}" >"$TARGETS_FILE"

echo "Mode: $MODE"
echo "Secret sources (${#SECRET_SOURCES[@]}):"
printf '  %s\n' "${SECRET_SOURCES[@]}"
echo "Distinct values loaded: $VALUE_COUNT (len >= $MIN_LEN; values not printed)"
echo "Targets:"
printf '  %s\n' "${TARGETS[@]}"
echo ""

validate_secrets_env_layout

# Python does the scan/rewrite so secret material never appears on argv.
export SCRUB_MODE="$MODE"
export SCRUB_PATTERNS_FILE="$PATTERNS_FILE"
export SCRUB_SOURCES_FILE="$SOURCES_FILE"
export SCRUB_TARGETS_FILE="$TARGETS_FILE"
export SCRUB_REDACTION="<REDACTED>"

set +e
python3 - <<'PY'
import os
import sys
from pathlib import Path

mode = os.environ["SCRUB_MODE"]
patterns_path = Path(os.environ["SCRUB_PATTERNS_FILE"])
sources_path = Path(os.environ["SCRUB_SOURCES_FILE"])
targets_path = Path(os.environ["SCRUB_TARGETS_FILE"])
redaction = os.environ.get("SCRUB_REDACTION", "<REDACTED>")

patterns = [p for p in patterns_path.read_text(encoding="utf-8", errors="surrogateescape").splitlines() if p]
# Longest first so overlapping values redact correctly.
patterns.sort(key=len, reverse=True)

protected = set()
for line in sources_path.read_text(encoding="utf-8", errors="surrogateescape").splitlines():
    if line:
        protected.add(Path(line).resolve())

skip_dir_names = {".git", "node_modules", ".cache", "__pycache__", ".venv", "venv"}
history_names = {
    ".bash_history",
    ".zsh_history",
    ".python_history",
    ".mysql_history",
    ".node_repl_history",
    "fish_history",
}

def is_protected(path: Path) -> bool:
    try:
        resolved = path.resolve()
    except OSError:
        return True
    if path.name == "secrets.env":
        return True
    if resolved in protected:
        return True
    return False

def iter_files(root: Path):
    if root.is_file():
        yield root
        return
    if not root.is_dir():
        return
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in skip_dir_names]
        for name in filenames:
            yield Path(dirpath) / name

def looks_text(sample: bytes) -> bool:
    if b"\x00" in sample:
        return False
    # Reject mostly non-printable samples.
    if not sample:
        return True
    textish = sum(1 for b in sample if b in (9, 10, 13) or 32 <= b <= 126)
    return (textish / len(sample)) >= 0.85

def contains_secret(data: str) -> bool:
    return any(p in data for p in patterns)

def scrub_history(text: str) -> tuple[str, int]:
    removed = 0
    out_lines = []
    for line in text.splitlines(keepends=True):
        body = line[:-1] if line.endswith("\n") else line
        if line.endswith("\r\n"):
            body = line[:-2]
        elif line.endswith("\n") or line.endswith("\r"):
            body = line[:-1]
        if contains_secret(body):
            removed += 1
            continue
        out_lines.append(line)
    return "".join(out_lines), removed

def scrub_generic(text: str) -> tuple[str, int]:
    hits = 0
    out = text
    for p in patterns:
        n = out.count(p)
        if n:
            hits += n
            out = out.replace(p, redaction)
    return out, hits

targets = []
for line in targets_path.read_text(encoding="utf-8", errors="surrogateescape").splitlines():
    if line:
        targets.append(Path(line))

files_scanned = 0
files_hit = 0
files_changed = 0
files_skipped = 0
total_hits = 0

for target in targets:
    for path in iter_files(target):
        if is_protected(path):
            files_skipped += 1
            continue
        if not path.is_file():
            continue
        try:
            if path.stat().st_size == 0:
                files_scanned += 1
                continue
            with path.open("rb") as fh:
                sample = fh.read(8192)
            if not looks_text(sample):
                files_skipped += 1
                continue
            raw = path.read_bytes()
            try:
                text = raw.decode("utf-8")
                encoding = "utf-8"
            except UnicodeDecodeError:
                text = raw.decode("latin-1")
                encoding = "latin-1"
        except OSError as exc:
            print(f"  skip (unreadable): {path}: {exc}", file=sys.stderr)
            files_skipped += 1
            continue

        files_scanned += 1
        if not contains_secret(text):
            continue

        is_history = path.name in history_names or path.name.endswith("_history")
        if is_history:
            new_text, hits = scrub_history(text)
            kind = "history-lines-removed"
        else:
            new_text, hits = scrub_generic(text)
            kind = "value-replacements"

        if hits == 0 or new_text == text:
            continue

        files_hit += 1
        total_hits += hits
        print(f"  HIT {path} ({kind}={hits})")

        if mode == "apply":
            tmp = path.with_name(path.name + ".scrub-tmp")
            try:
                data = new_text.encode(encoding)
                with tmp.open("wb") as fh:
                    fh.write(data)
                    fh.flush()
                    os.fsync(fh.fileno())
                os.chmod(tmp, path.stat().st_mode & 0o777)
                os.replace(tmp, path)
                files_changed += 1
            except OSError as exc:
                print(f"  ERROR writing {path}: {exc}", file=sys.stderr)
                try:
                    tmp.unlink(missing_ok=True)
                except OSError:
                    pass
                sys.exit(1)

print("")
print(f"Scanned: {files_scanned}  hits: {files_hit}  skipped: {files_skipped}  total_matches: {total_hits}")
if mode == "apply":
    print(f"Rewrote: {files_changed} file(s)")
    if files_changed:
        print("If a live shell still has old history in memory: history -c; history -r")
else:
    print("Dry-run only. Re-run with 'apply' to rewrite matching files.")
    if files_hit:
        sys.exit(2)
PY
status=$?
set -e

if [[ "$MODE" == "apply" && "$PERM_FIXED" -gt 0 ]]; then
  echo "Fixed secrets.env ownership/permissions: $PERM_FIXED change(s)"
fi

# Prefer scrub status; still fail dry-run when only perms are wrong.
if [[ "$status" -eq 0 && "$MODE" == "dry-run" && "$PERM_ISSUES" -gt 0 ]]; then
  echo "Dry-run: secrets.env ownership/permissions need attention (re-run with apply)."
  exit 2
fi
if [[ "$status" -eq 0 && "$MODE" == "apply" && "$PERM_ISSUES" -gt 0 && "$PERM_FIXED" -eq 0 ]]; then
  echo "Error: secrets.env ownership/permissions issues remain." >&2
  exit 1
fi

# dry-run with scrub hits exits 2 from python
exit "$status"
