#!/bin/bash

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Disk Space Cleanup Script
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#
# This script cleans up:
#   1. System journal logs (keeps last 3 days or max 500MB)
#   2. /var/log old logs and compressed archives
#   3. DNF package cache
#   4. Old kernel images (keeps current + 1 previous)
#   5. /var/cache temporary files
#   6. /tmp temporary files + Bun embedded-native leaks + Cursor sandbox cache
#   7. INFRA_USER Cursor remote-server bins + agent-cli versions + logs/tmp projects
#   8. INFRA_USER Rust/Cargo + rustup tmp (not root's $HOME)
#   9. INFRA_USER npm cache
#   10. Unused Podman images (rootless store)
#   11. Podman build cache including Buildah cache mounts
#   12. Old Trivy scan artifacts under ~/infra-app/trivy-scan-results/
#   13. Project logs and Cargo target/ dirs under INFRA_HOME
#   14. Hermes agent memory backups (~/*-memory-backups)
#
# Hermes memory backups (sibling of ~/hermes-agents-app, not inside it):
#   HERMES_MEMORY_BACKUP_KEEP=30                 (newest snapshots to keep)
#   HERMES_MEMORY_BACKUP_RETENTION_DAYS=90       (drop older snapshots)
#   HERMES_MEMORY_BACKUP_MAX_BYTES=67108864      (64 MiB hard ceiling)
#   HERMES_MEMORY_BACKUP_DIR                     (optional single directory)
#   Always keeps the newest snapshot and the LATEST target, even if that
#   pair is over the byte cap. Same knobs as hermes-agents deploy/scripts/lib.sh.
#
# Under sudo, $HOME is /root. User-space reclaim MUST use INFRA_HOME or it
# skips the host Cargo trees that actually fill the disk (e.g. ~/ironclaw-idc/target
# at ~100G) and prints "Rust/Cargo not installed".
#
# Cursor sandbox cache override:
#   CURSOR_SANDBOX_CACHE_RETENTION_DAYS=3  (default; remove hash dirs older than N days)
#   Always removes **/cargo-target under the cache (rebuildable; often tens of GB).
#
# Cursor user-space (INFRA_HOME/.cursor-server + .cursor):
#   CURSOR_SERVER_BIN_KEEP_NEWEST=2       (keep N newest linux-x64 server installs; ~367MB each)
#   CURSOR_AGENT_VERSIONS_KEEP_NEWEST=2   (keep N newest agent-cli versions; ~250–500MB each)
#   CURSOR_SERVER_LOGS_RETENTION_DAYS=7   (age out data/logs day dirs)
#   CURSOR_PROJECT_TMP_RETENTION_DAYS=3   (age out ~/.cursor/projects/tmp-*)
#   Never deletes a bin/agent version referenced by a live process or the
#   agent-cli cursor-agent symlink. Always drops incomplete versions/.tmp-*.
#
# Bun compiled-binary native-library leaks in /tmp (OpenCode, hunk, etc.):
#   Each invocation can leave a hidden ./{hash}-00000000.so (~5 MB) that is never
#   unlinked. The weekly atime+7 /tmp sweep misses them because they are new/recent.
#   BUN_TMP_NATIVE_RETENTION_MINUTES=60  (skip files touched in the last hour)
#   BUN_TMP_NATIVE_KEEP_NEWEST=5           (cap: delete oldest beyond N newest per pattern)
#
# CodeQL per-run databases under */itemdb/codeql/runs/ (rebuildable):
#   CODEQL_RUNS_RETENTION_DAYS=7   (remove run dirs older than N days)
#   CODEQL_RUNS_KEEP_NEWEST=3      (always keep at least N newest runs per project)
#
# Log truncation covers Debian/Ubuntu (syslog, auth.log, kern.log) and
# Alma/RHEL-style paths (/var/log/messages, /var/log/secure).
#
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=infra-env-helper.sh
source "$SCRIPT_DIR/infra-env-helper.sh"

USER_SPACE_ONLY=0
if [[ "${1:-}" == "--user-space" ]]; then
  USER_SPACE_ONLY=1
  shift
fi

if [[ "${EUID:-0}" -ne 0 && "$USER_SPACE_ONLY" -ne 1 ]]; then
    echo "Error: this script must be run as root (sudo)." >&2
    echo "User-space only (INFRA_HOME Cargo target/, npm, Podman cache): $0 --user-space" >&2
    exit 1
fi

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Podman rootless stores are per-user; when cleanup runs under sudo, invoke podman as INFRA_USER.
run_as_infra_user() {
  if [[ "${EUID:-0}" -ne 0 ]]; then
    "$@"
    return
  fi
  if ! command -v runuser >/dev/null 2>&1 || ! id "$INFRA_USER" &>/dev/null; then
    echo "Error: cannot run podman as $INFRA_USER (need runuser and a valid user)" >&2
    return 1
  fi
  local uid
  uid="$(id -u "$INFRA_USER")"
  runuser -u "$INFRA_USER" -- env \
    XDG_RUNTIME_DIR="/run/user/${uid}" \
    HOME="$INFRA_HOME" \
    "$@"
}

# User-space paths. Never use $HOME here: sudo makes that /root.
infra_user_home() {
  printf '%s' "${INFRA_HOME:?INFRA_HOME is not set}"
}

du_sh() {
  # du exits 1 on unreadable subdirs (e.g. /tmp/systemd-private-*) but still
  # prints a total. Capture that so set -e / trap ERR do not abort cleanup.
  local out
  out="$(du -sh "$1" 2>/dev/null || true)"
  if [[ -n "$out" ]]; then
    echo "$out"
  else
    echo "  (unable to calculate $1)"
  fi
}

# Sum byte sizes of files matching a find expression (best-effort).
find_files_total_bytes() {
  local total=0 size
  while IFS= read -r size; do
    [[ -n "$size" ]] && total=$((total + size))
  done < <(find "$@" -printf '%s\n' 2>/dev/null || true)
  echo "$total"
}

# Remove Bun/OpenCode leaked embedded native libraries from /tmp.
# Legacy: .{hex}-00000000.so  Newer Bun: .bun-{uid}-{hash}.{so,dylib}
clean_bun_tmp_native_leaks() {
  local tmp_dir="${1:-/tmp}"
  local retention_min="${BUN_TMP_NATIVE_RETENTION_MINUTES:-60}"
  local keep_newest="${BUN_TMP_NATIVE_KEEP_NEWEST:-5}"
  local -a patterns=(
    -name '.*-00000000.so'
    -o -name '.bun-*-*.so'
    -o -name '.bun-*-*.dylib'
  )

  if [[ ! -d "$tmp_dir" ]]; then
    return 0
  fi

  echo "📋 Bun /tmp native leak files before cleanup:"
  local before_count before_bytes
  before_count="$(find "$tmp_dir" -maxdepth 1 -type f \( "${patterns[@]}" \) 2>/dev/null | wc -l | tr -d ' ')"
  before_bytes="$(find_files_total_bytes "$tmp_dir" -maxdepth 1 -type f \( "${patterns[@]}" \))"
  if [[ "$before_count" -eq 0 ]]; then
    echo "  (none found)"
    echo ""
    return 0
  fi
  printf '  %s files (~%s)\n' "$before_count" "$(numfmt --to=iec-i --suffix=B "$before_bytes" 2>/dev/null || echo "${before_bytes} bytes")"
  echo ""

  echo "🗑️  Cleaning Bun leaked native libraries in ${tmp_dir}..."
  echo "  Retention: skip files newer than ${retention_min} minute(s); keep ${keep_newest} newest"

  local removed=0
  while IFS= read -r -d '' leak_file; do
    rm -f "$leak_file" && removed=$((removed + 1)) || \
      echo "  (failed to remove $leak_file)"
  done < <(
    find "$tmp_dir" -maxdepth 1 -type f \( "${patterns[@]}" \) \
      -mmin "+${retention_min}" -print0 2>/dev/null
  )
  echo "  Removed ${removed} file(s) older than ${retention_min} minute(s)"

  # Cap runaway same-day growth (e.g. OpenCode polling every few seconds).
  local remaining
  remaining="$(find "$tmp_dir" -maxdepth 1 -type f \( "${patterns[@]}" \) 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$remaining" -gt "$keep_newest" ]]; then
    local cap_removed=0 to_delete=$((remaining - keep_newest))
    while IFS= read -r -d '' leak_file; do
      rm -f "$leak_file" && cap_removed=$((cap_removed + 1)) || \
        echo "  (failed to remove $leak_file)"
      [[ "$cap_removed" -ge "$to_delete" ]] && break
    done < <(
      find "$tmp_dir" -maxdepth 1 -type f \( "${patterns[@]}" \) \
        -printf '%T@ %p\0' 2>/dev/null | sort -z -n | cut -z -d' ' -f2-
    )
    echo "  Removed ${cap_removed} oldest file(s) to cap at ${keep_newest} newest"
  fi

  local after_count after_bytes
  after_count="$(find "$tmp_dir" -maxdepth 1 -type f \( "${patterns[@]}" \) 2>/dev/null | wc -l | tr -d ' ')"
  after_bytes="$(find_files_total_bytes "$tmp_dir" -maxdepth 1 -type f \( "${patterns[@]}" \))"
  printf '📋 Bun /tmp native leak files after cleanup: %s files (~%s)\n' \
    "$after_count" "$(numfmt --to=iec-i --suffix=B "$after_bytes" 2>/dev/null || echo "${after_bytes} bytes")"
  echo ""
}

# Collect Cursor linux-x64 server hashes currently mapped by /proc/*/exe.
cursor_in_use_server_hashes() {
  local server_bin_root="${1:?}"
  local -A seen=()
  local exe target hash
  for exe in /proc/[0-9]*/exe; do
    target="$(readlink -f "$exe" 2>/dev/null || true)"
    [[ -n "$target" ]] || continue
    case "$target" in
      "${server_bin_root}/"*)
        hash="${target#"${server_bin_root}/"}"
        hash="${hash%%/*}"
        if [[ "$hash" =~ ^[a-f0-9]+$ ]]; then
          seen["$hash"]=1
        fi
        ;;
    esac
  done
  if [[ ${#seen[@]} -gt 0 ]]; then
    printf '%s\n' "${!seen[@]}"
  fi
}

# Prune INFRA_USER Cursor remote-server installs + agent-cli version caches.
# Typical reclaim: 1–2GB when several updates have stacked without cleanup.
clean_cursor_user_space() {
  local home
  home="$(infra_user_home)"
  local server_root="${home}/.cursor-server"
  local cursor_dot="${home}/.cursor"
  local bin_keep="${CURSOR_SERVER_BIN_KEEP_NEWEST:-2}"
  local agent_keep="${CURSOR_AGENT_VERSIONS_KEEP_NEWEST:-2}"
  local logs_days="${CURSOR_SERVER_LOGS_RETENTION_DAYS:-7}"
  local project_tmp_days="${CURSOR_PROJECT_TMP_RETENTION_DAYS:-3}"

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "📋 Cursor user-space before cleanup (${INFRA_USER}):"
  if [[ -d "$server_root" ]]; then
    du_sh "$server_root"
  else
    echo "  (no ${server_root})"
  fi
  if [[ -d "$cursor_dot" ]]; then
    du_sh "$cursor_dot"
  fi
  echo ""

  # --- remote-server binary installs (~367MB each) ---
  local bin_root="${server_root}/bin/linux-x64"
  if [[ -d "$bin_root" ]]; then
    echo "🗑️  Cleaning old Cursor server installs (${bin_root})..."
    echo "  Keep newest ${bin_keep}; never remove in-use hashes"

    local -A protected=()
    local hash
    while IFS= read -r hash; do
      [[ -n "$hash" ]] && protected["$hash"]=1
    done < <(cursor_in_use_server_hashes "$bin_root")
    if [[ ${#protected[@]} -gt 0 ]]; then
      echo "  In-use: ${!protected[*]}"
    fi

    local -a bin_dirs=()
    mapfile -t bin_dirs < <(
      find "$bin_root" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %f\n' 2>/dev/null \
        | sort -nr | cut -d' ' -f2-
    )
    local idx removed_bins=0
    for (( idx=0; idx<${#bin_dirs[@]}; idx++ )); do
      hash="${bin_dirs[$idx]}"
      if [[ -n "${protected[$hash]:-}" ]]; then
        echo "  Keeping in-use: ${hash}"
        continue
      fi
      if [[ "$idx" -lt "$bin_keep" ]]; then
        echo "  Keeping newest: ${hash}"
        continue
      fi
      local bin_size
      bin_size="$(du -sh "${bin_root}/${hash}" 2>/dev/null | cut -f1 || echo '?')"
      echo "  Removing old install (${bin_size}): ${hash}"
      rm -rf "${bin_root}/${hash}" && removed_bins=$((removed_bins + 1)) || \
        echo "  (failed to remove ${bin_root}/${hash})"
    done
    echo "  Removed ${removed_bins} old Cursor server install(s)"
    echo ""
  else
    echo "ℹ️  No Cursor server bin dir at ${bin_root}, skipping..."
    echo ""
  fi

  # --- agent-cli version packs (~250–500MB each) ---
  local agent_versions="${server_root}/data/User/globalStorage/anysphere.cursor-agent-worker/agent-cli/.local/share/cursor-agent/versions"
  local agent_link="${server_root}/data/User/globalStorage/anysphere.cursor-agent-worker/agent-cli/.local/bin/cursor-agent"
  if [[ -d "$agent_versions" ]]; then
    echo "🗑️  Cleaning old Cursor agent-cli versions (${agent_versions})..."
    echo "  Keep newest ${agent_keep}; drop incomplete .tmp-*; protect symlink target"

    local linked_version=""
    if [[ -L "$agent_link" ]]; then
      local link_target
      link_target="$(readlink -f "$agent_link" 2>/dev/null || true)"
      case "$link_target" in
        "${agent_versions}/"*)
          linked_version="${link_target#"${agent_versions}/"}"
          linked_version="${linked_version%%/*}"
          ;;
      esac
    fi
    if [[ -n "$linked_version" ]]; then
      echo "  Symlink current: ${linked_version}"
    fi

    # Incomplete downloads / aborted updates — always safe to drop when stale.
    local tmp_removed=0
    while IFS= read -r -d '' tmp_dir; do
      local tmp_size
      tmp_size="$(du -sh "$tmp_dir" 2>/dev/null | cut -f1 || echo '?')"
      echo "  Removing incomplete tmp (${tmp_size}): $(basename "$tmp_dir")"
      rm -rf "$tmp_dir" && tmp_removed=$((tmp_removed + 1)) || \
        echo "  (failed to remove $tmp_dir)"
    done < <(
      find "$agent_versions" -mindepth 1 -maxdepth 1 -type d -name '.tmp-*' \
        -mmin +60 -print0 2>/dev/null
    )
    echo "  Removed ${tmp_removed} incomplete .tmp-* dir(s)"

    # Version dirs are YYYY.MM.DD-<hash>; lexicographic == chronological.
    local -a agent_dirs=()
    mapfile -t agent_dirs < <(
      find "$agent_versions" -mindepth 1 -maxdepth 1 -type d ! -name '.tmp-*' \
        -printf '%f\n' 2>/dev/null | sort -r
    )
    local removed_agents=0 i version
    for (( i=0; i<${#agent_dirs[@]}; i++ )); do
      version="${agent_dirs[$i]}"
      if [[ -n "$linked_version" && "$version" == "$linked_version" ]]; then
        echo "  Keeping linked: ${version}"
        continue
      fi
      if [[ "$i" -lt "$agent_keep" ]]; then
        echo "  Keeping newest: ${version}"
        continue
      fi
      local agent_size
      agent_size="$(du -sh "${agent_versions}/${version}" 2>/dev/null | cut -f1 || echo '?')"
      echo "  Removing old agent (${agent_size}): ${version}"
      rm -rf "${agent_versions}/${version}" && removed_agents=$((removed_agents + 1)) || \
        echo "  (failed to remove ${agent_versions}/${version})"
    done
    echo "  Removed ${removed_agents} old agent-cli version(s)"
    echo ""
  else
    echo "ℹ️  No Cursor agent-cli versions at ${agent_versions}, skipping..."
    echo ""
  fi

  # --- server logs ---
  local logs_root="${server_root}/data/logs"
  if [[ -d "$logs_root" ]]; then
    echo "🗑️  Cleaning Cursor server logs older than ${logs_days} day(s)..."
    local logs_removed=0
    while IFS= read -r -d '' log_dir; do
      local log_size
      log_size="$(du -sh "$log_dir" 2>/dev/null | cut -f1 || echo '?')"
      echo "  Removing (${log_size}): $(basename "$log_dir")"
      rm -rf "$log_dir" && logs_removed=$((logs_removed + 1)) || \
        echo "  (failed to remove $log_dir)"
    done < <(
      find "$logs_root" -mindepth 1 -maxdepth 1 -type d -mtime "+${logs_days}" -print0 2>/dev/null
    )
    echo "  Removed ${logs_removed} log day dir(s)"
    echo ""
  fi

  # --- ephemeral IDE project dirs ---
  local projects_root="${cursor_dot}/projects"
  if [[ -d "$projects_root" ]]; then
    echo "🗑️  Cleaning Cursor project tmp-* dirs older than ${project_tmp_days} day(s)..."
    local proj_removed=0
    while IFS= read -r -d '' proj_dir; do
      local proj_size
      proj_size="$(du -sh "$proj_dir" 2>/dev/null | cut -f1 || echo '?')"
      echo "  Removing (${proj_size}): $(basename "$proj_dir")"
      rm -rf "$proj_dir" && proj_removed=$((proj_removed + 1)) || \
        echo "  (failed to remove $proj_dir)"
    done < <(
      find "$projects_root" -mindepth 1 -maxdepth 1 -type d -name 'tmp-*' \
        -mtime "+${project_tmp_days}" -print0 2>/dev/null
    )
    echo "  Removed ${proj_removed} tmp project dir(s)"
    echo ""
  fi

  echo "📋 Cursor user-space after cleanup:"
  if [[ -d "$server_root" ]]; then
    du_sh "$server_root"
  else
    echo "  (no ${server_root})"
  fi
  if [[ -d "$cursor_dot" ]]; then
    du_sh "$cursor_dot"
  fi
  echo ""
}

# Prune old CodeQL run directories (itemdb/codeql/runs/<timestamp-id>/).
clean_codeql_run_dirs() {
  local project_base="${1:?project base required}"
  local retention_days="${CODEQL_RUNS_RETENTION_DAYS:-7}"
  local keep_newest="${CODEQL_RUNS_KEEP_NEWEST:-3}"

  echo "🗑️  Cleaning CodeQL run directories under ${project_base}..."
  echo "  Retention: ${retention_days} day(s); keep ${keep_newest} newest per project"

  local runs_root removed_total=0
  while IFS= read -r -d '' runs_root; do
    local project_name removed_here=0
    project_name="$(basename "$(dirname "$(dirname "$(dirname "$runs_root")")")")"
    echo "  Project: ${project_name} (${runs_root})"

    # Age-based removal (timestamped dir names sort chronologically).
    while IFS= read -r -d '' old_run; do
      local run_size
      run_size="$(du -sh "$old_run" 2>/dev/null | cut -f1 || echo '?')"
      echo "    Removing run (${retention_days}d+, ${run_size}): $(basename "$old_run")"
      rm -rf "$old_run" && removed_here=$((removed_here + 1)) || \
        echo "    (failed to remove $old_run)"
    done < <(
      find "$runs_root" -mindepth 1 -maxdepth 1 -type d -mtime "+${retention_days}" -print0 2>/dev/null
    )

    # Keep-newest cap among remaining runs.
    local -a remaining=()
    mapfile -t remaining < <(find "$runs_root" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort)
    local excess=$(( ${#remaining[@]} - keep_newest ))
    if [[ "$excess" -gt 0 ]]; then
      local i
      for (( i=0; i<excess; i++ )); do
        local run_dir="${runs_root}/${remaining[$i]}"
        local run_size
        run_size="$(du -sh "$run_dir" 2>/dev/null | cut -f1 || echo '?')"
        echo "    Removing excess run (${run_size}): ${remaining[$i]}"
        rm -rf "$run_dir" && removed_here=$((removed_here + 1)) || \
          echo "    (failed to remove $run_dir)"
      done
    fi

    removed_total=$((removed_total + removed_here))
    echo "    Removed ${removed_here} run(s) for ${project_name}"
  done < <(
    find "$project_base" -path '*/itemdb/codeql/runs' -type d -print0 2>/dev/null
  )

  if [[ "$removed_total" -eq 0 ]]; then
    echo "  (no CodeQL run directories pruned)"
  else
    echo "  Total CodeQL runs removed: ${removed_total}"
  fi
  echo ""
}

# Cap Hermes memory snapshots so ~/hermes-agents-app-memory-backups cannot grow
# without a bound. Always keeps the newest snapshot and the LATEST target.
clean_hermes_memory_backups() {
  local keep="${HERMES_MEMORY_BACKUP_KEEP:-30}"
  local retention_days="${HERMES_MEMORY_BACKUP_RETENTION_DAYS:-90}"
  local max_bytes="${HERMES_MEMORY_BACKUP_MAX_BYTES:-67108864}"
  local home
  home="$(infra_user_home)"

  [[ "$keep" =~ ^[0-9]+$ ]] || keep=30
  [[ "$retention_days" =~ ^[0-9]+$ ]] || retention_days=90
  [[ "$max_bytes" =~ ^[0-9]+$ ]] || max_bytes=67108864
  (( keep < 1 )) && keep=1

  local -a roots=()
  if [[ -n "${HERMES_MEMORY_BACKUP_DIR:-}" && -d "${HERMES_MEMORY_BACKUP_DIR}" ]]; then
    roots+=("$HERMES_MEMORY_BACKUP_DIR")
  else
    local candidate
    shopt -s nullglob
    for candidate in "$home"/*-memory-backups; do
      [[ -d "$candidate" ]] && roots+=("$candidate")
    done
    shopt -u nullglob
  fi

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  if [[ ${#roots[@]} -eq 0 ]]; then
    echo "ℹ️  No Hermes memory backups (*-memory-backups) under ${home}, skipping..."
    echo ""
    return 0
  fi

  local root
  for root in "${roots[@]}"; do
    echo "📋 Hermes memory backups before cleanup:"
    du_sh "$root"
    echo "  Directory: ${root}"
    echo "  Caps: newest ${keep}, older than ${retention_days}d, max $(numfmt --to=iec-i --suffix=B "$max_bytes" 2>/dev/null || echo "${max_bytes} bytes")"

    find "$root" -mindepth 1 -maxdepth 1 -type d -name '.staging-*' -mmin +60 \
      -exec rm -rf {} + 2>/dev/null || true

    local -a snaps=()
    local s
    while IFS= read -r s; do
      [[ -n "$s" ]] || continue
      snaps+=("$s")
    done < <(
      find "$root" -mindepth 1 -maxdepth 1 -type d \
        -regextype posix-extended \
        -regex '.*/[0-9]{8}T[0-9]+Z(-[0-9]+)?$' 2>/dev/null | sort
    )
    if [[ ${#snaps[@]} -eq 0 ]]; then
      echo "  (no snapshots)"
      echo ""
      continue
    fi

    local newest latest=""
    newest="${snaps[${#snaps[@]}-1]}"
    if [[ -L "$root/LATEST" || -e "$root/LATEST" ]]; then
      latest="$(readlink -f "$root/LATEST" 2>/dev/null || true)"
    fi

    local removed=0
    local -a kept=()
    for s in "${snaps[@]}"; do
      if [[ "$s" == "$newest" || ( -n "$latest" && "$s" == "$latest" ) ]]; then
        kept+=("$s")
        continue
      fi
      if [[ -n "$(find "$s" -maxdepth 0 -mtime "+${retention_days}" -print -quit 2>/dev/null || true)" ]]; then
        local old_size
        old_size="$(du -sh "$s" 2>/dev/null | cut -f1 || echo '?')"
        echo "  Removing old snapshot (${retention_days}d+, ${old_size}): $(basename "$s")"
        rm -rf "$s"
        rm -f "${s}.sha256"
        removed=$((removed + 1))
        continue
      fi
      kept+=("$s")
    done
    snaps=("${kept[@]}")

    while [[ ${#snaps[@]} -gt $keep ]]; do
      local victim="" i
      for (( i=0; i<${#snaps[@]}; i++ )); do
        if [[ "${snaps[$i]}" != "$newest" && "${snaps[$i]}" != "$latest" ]]; then
          victim="${snaps[$i]}"
          unset 'snaps[i]'
          snaps=("${snaps[@]}")
          break
        fi
      done
      [[ -n "$victim" ]] || break
      local victim_size
      victim_size="$(du -sh "$victim" 2>/dev/null | cut -f1 || echo '?')"
      echo "  Removing excess snapshot (${victim_size}): $(basename "$victim")"
      rm -rf "$victim"
      rm -f "${victim}.sha256"
      removed=$((removed + 1))
    done

    while [[ ${#snaps[@]} -gt 1 ]]; do
      local total=0
      for s in "${snaps[@]}"; do
        local one
        one="$(du -sb "$s" 2>/dev/null | awk '{print $1}')"
        [[ "$one" =~ ^[0-9]+$ ]] || one=0
        if [[ -f "${s}.sha256" ]]; then
          local sha_bytes
          sha_bytes="$(stat -c '%s' "${s}.sha256" 2>/dev/null || echo 0)"
          [[ "$sha_bytes" =~ ^[0-9]+$ ]] || sha_bytes=0
          one=$((one + sha_bytes))
        fi
        total=$((total + one))
      done
      [[ "$total" -le "$max_bytes" ]] && break
      victim=""
      for (( i=0; i<${#snaps[@]}; i++ )); do
        if [[ "${snaps[$i]}" != "$newest" && "${snaps[$i]}" != "$latest" ]]; then
          victim="${snaps[$i]}"
          unset 'snaps[i]'
          snaps=("${snaps[@]}")
          break
        fi
      done
      [[ -n "$victim" ]] || break
      victim_size="$(du -sh "$victim" 2>/dev/null | cut -f1 || echo '?')"
      echo "  Removing snapshot over ${max_bytes} byte cap (${victim_size}): $(basename "$victim")"
      rm -rf "$victim"
      rm -f "${victim}.sha256"
      removed=$((removed + 1))
    done

    local sha_file
    while IFS= read -r sha_file; do
      [[ -n "$sha_file" ]] || continue
      if [[ ! -d "${sha_file%.sha256}" ]]; then
        rm -f "$sha_file"
      fi
    done < <(find "$root" -mindepth 1 -maxdepth 1 -type f -name '*.sha256' ! -name 'LATEST.sha256' 2>/dev/null || true)

    echo "  Removed ${removed} snapshot(s); ${#snaps[@]} remaining"
    if [[ ${#snaps[@]} -gt 0 ]]; then
      total=0
      for s in "${snaps[@]}"; do
        one="$(du -sb "$s" 2>/dev/null | awk '{print $1}')"
        [[ "$one" =~ ^[0-9]+$ ]] || one=0
        total=$((total + one))
      done
      if [[ "$total" -gt "$max_bytes" ]]; then
        echo "  Newest/LATEST still above the cap ($(numfmt --to=iec-i --suffix=B "$total" 2>/dev/null || echo "$total")); left in place"
      fi
    fi
    echo "📋 Hermes memory backups after cleanup:"
    du_sh "$root"
    echo ""
  done
}

# Error handler
trap 'echo -e "${RED}❌ Script failed at line $LINENO${NC}"; exit 1' ERR

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🧹 Disk Space Cleanup Starting"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Show current disk usage
echo "📊 Current disk usage:"
df -h / | grep -v Filesystem
echo ""

if [[ "$USER_SPACE_ONLY" -eq 1 ]]; then
  echo "ℹ️  --user-space: skipping journal, /var/log, DNF, kernels, and /var/cache"
  echo ""
else

# Check journal disk usage
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📋 Journal logs disk usage:"
sudo journalctl --disk-usage
echo ""

# Clean journal logs
echo "🗑️  Cleaning journal logs (keeping last 3 days)..."
sudo journalctl --vacuum-time=3d
echo ""

echo "🗑️  Limiting journal logs to 500MB max..."
sudo journalctl --vacuum-size=500M
echo ""

# Clean /var/log
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📋 /var/log disk usage before cleanup:"
du -sh /var/log
echo ""

echo "🗑️  Cleaning /var/log old logs and archives..."
# Remove old compressed logs (*.gz files older than 30 days)
sudo find /var/log -type f -name "*.gz" -mtime +30 -delete
# Truncate old rotated logs (*.1, *.2, etc. older than 7 days)
sudo find /var/log -type f -regex '.*\.[0-9]+$' -mtime +7 -delete

# Truncate large log files to free space
# Keep last 50MB of syslog/kern/messages, 20MB of auth/secure
echo "  Truncating large log files..."

if [ -f /var/log/syslog ]; then
  SYSLOG_SIZE=$(stat -c%s /var/log/syslog 2>/dev/null)
  if [ "$SYSLOG_SIZE" -gt 52428800 ]; then
    sudo tail -c 52428800 /var/log/syslog | sudo tee /var/log/syslog > /dev/null
    echo "  Truncated syslog to 50MB"
  fi
fi

if [ -f /var/log/syslog.1 ]; then
  SYSLOG1_SIZE=$(stat -c%s /var/log/syslog.1 2>/dev/null)
  if [ "$SYSLOG1_SIZE" -gt 52428800 ]; then
    sudo tail -c 52428800 /var/log/syslog.1 | sudo tee /var/log/syslog.1 > /dev/null
    echo "  Truncated syslog.1 to 50MB"
  fi
fi

if [ -f /var/log/kern.log ]; then
  KERN_SIZE=$(stat -c%s /var/log/kern.log 2>/dev/null)
  if [ "$KERN_SIZE" -gt 52428800 ]; then
    sudo tail -c 52428800 /var/log/kern.log | sudo tee /var/log/kern.log > /dev/null
    echo "  Truncated kern.log to 50MB"
  fi
fi

if [ -f /var/log/kern.log.1 ]; then
  KERN1_SIZE=$(stat -c%s /var/log/kern.log.1 2>/dev/null)
  if [ "$KERN1_SIZE" -gt 52428800 ]; then
    sudo tail -c 52428800 /var/log/kern.log.1 | sudo tee /var/log/kern.log.1 > /dev/null
    echo "  Truncated kern.log.1 to 50MB"
  fi
fi

if [ -f /var/log/auth.log ]; then
  AUTH_SIZE=$(stat -c%s /var/log/auth.log 2>/dev/null)
  if [ "$AUTH_SIZE" -gt 20971520 ]; then
    sudo tail -c 20971520 /var/log/auth.log | sudo tee /var/log/auth.log > /dev/null
    echo "  Truncated auth.log to 20MB"
  fi
fi

if [ -f /var/log/auth.log.1 ]; then
  AUTH1_SIZE=$(stat -c%s /var/log/auth.log.1 2>/dev/null)
  if [ "$AUTH1_SIZE" -gt 20971520 ]; then
    sudo tail -c 20971520 /var/log/auth.log.1 | sudo tee /var/log/auth.log.1 > /dev/null
    echo "  Truncated auth.log.1 to 20MB"
  fi
fi

# Alma Linux / RHEL / Fedora (rsyslog defaults)
if [ -f /var/log/messages ]; then
  MSG_SIZE=$(stat -c%s /var/log/messages 2>/dev/null)
  if [ "$MSG_SIZE" -gt 52428800 ]; then
    sudo tail -c 52428800 /var/log/messages | sudo tee /var/log/messages > /dev/null
    echo "  Truncated messages to 50MB"
  fi
fi

if [ -f /var/log/messages.1 ]; then
  MSG1_SIZE=$(stat -c%s /var/log/messages.1 2>/dev/null)
  if [ "$MSG1_SIZE" -gt 52428800 ]; then
    sudo tail -c 52428800 /var/log/messages.1 | sudo tee /var/log/messages.1 > /dev/null
    echo "  Truncated messages.1 to 50MB"
  fi
fi

if [ -f /var/log/secure ]; then
  SEC_SIZE=$(stat -c%s /var/log/secure 2>/dev/null)
  if [ "$SEC_SIZE" -gt 20971520 ]; then
    sudo tail -c 20971520 /var/log/secure | sudo tee /var/log/secure > /dev/null
    echo "  Truncated secure to 20MB"
  fi
fi

if [ -f /var/log/secure.1 ]; then
  SEC1_SIZE=$(stat -c%s /var/log/secure.1 2>/dev/null)
  if [ "$SEC1_SIZE" -gt 20971520 ]; then
    sudo tail -c 20971520 /var/log/secure.1 | sudo tee /var/log/secure.1 > /dev/null
    echo "  Truncated secure.1 to 20MB"
  fi
fi
echo ""

echo "📋 /var/log disk usage after cleanup:"
du -sh /var/log
echo ""

# Clean DNF cache
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📋 DNF cache before cleanup:"
du -sh /var/cache/dnf 2>/dev/null || echo "  (no dnf cache dir)"
echo ""

echo "🗑️  Cleaning DNF package cache..."
sudo dnf clean all
echo ""

echo "📋 DNF cache after cleanup:"
du -sh /var/cache/dnf 2>/dev/null || echo "  (no dnf cache dir)"
echo ""

# Clean old kernel images
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📋 Boot directory disk usage before cleanup:"
du -sh /boot
echo ""

echo "🗑️  Removing old kernels (dnf keeps last 2 install-only packages)..."
sudo dnf remove --oldinstallonly --setopt installonly_limit=2 -y 2>/dev/null || \
  echo "  (skipped — no extra kernels or run: dnf install dnf-plugins-core)"
echo ""

echo "📋 Boot directory disk usage after cleanup:"
du -sh /boot
echo ""

# Clean /var/cache
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📋 /var/cache disk usage before cleanup:"
du -sh /var/cache
echo ""

echo "🗑️  Cleaning /var/cache temporary files..."
sudo find /var/cache -type f -atime +7 -delete 2>/dev/null
echo ""

echo "📋 /var/cache disk usage after cleanup:"
du -sh /var/cache
echo ""

fi # USER_SPACE_ONLY system skip

# Clean /tmp
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📋 /tmp disk usage before cleanup:"
du_sh /tmp
echo ""

if [[ "$USER_SPACE_ONLY" -eq 1 ]]; then
  echo "ℹ️  --user-space: skipping root /tmp vacuum (Cursor sandbox still pruned below)"
  echo ""
else
  echo "🗑️  Cleaning /tmp temporary files..."
  sudo find /tmp -mindepth 1 -type f -atime +7 -delete 2>/dev/null
  # -mindepth 1: never delete /tmp itself (empty /tmp would match -empty -delete)
  sudo find /tmp -mindepth 1 -type d -empty -delete 2>/dev/null
  if [[ ! -d /tmp ]]; then
    sudo install -d -m 1777 /tmp
    echo "  Recreated /tmp (1777)"
  fi
  echo ""
fi

# Bun compiled-binary native leaks — not aged out by atime+7 (OpenCode, hunk, etc.)
clean_bun_tmp_native_leaks /tmp

# Cursor agent sandbox cache (cargo-target + npm under /tmp) — not aged by atime+7
# because top-level dirs stay "recent" while holding multi-GB rebuildable trees.
CURSOR_SANDBOX_CACHE_DIR="${CURSOR_SANDBOX_CACHE_DIR:-/tmp/cursor-sandbox-cache}"
CURSOR_SANDBOX_CACHE_RETENTION_DAYS="${CURSOR_SANDBOX_CACHE_RETENTION_DAYS:-3}"
if [[ -d "$CURSOR_SANDBOX_CACHE_DIR" ]]; then
  echo "📋 Cursor sandbox cache before cleanup:"
  du -sh "$CURSOR_SANDBOX_CACHE_DIR" 2>/dev/null || true
  echo ""

  echo "🗑️  Cleaning Cursor sandbox cache (${CURSOR_SANDBOX_CACHE_DIR})..."
  # Biggest win: drop cargo build trees (safe to recreate on next agent run).
  cargo_removed=0
  while IFS= read -r -d '' cargo_dir; do
    size=$(du -sh "$cargo_dir" 2>/dev/null | cut -f1 || echo "?")
    echo "  Removing cargo-target ($size): $cargo_dir"
    rm -rf "$cargo_dir" && cargo_removed=$((cargo_removed + 1)) || \
      echo "  (failed to remove $cargo_dir)"
  done < <(find "$CURSOR_SANDBOX_CACHE_DIR" -type d -name cargo-target -print0 2>/dev/null)
  echo "  Removed ${cargo_removed} cargo-target director(ies)"

  # Age out whole sandbox hash entries (npm caches, leftover metadata).
  entries_removed=0
  while IFS= read -r -d '' entry; do
    size=$(du -sh "$entry" 2>/dev/null | cut -f1 || echo "?")
    echo "  Removing stale entry (${CURSOR_SANDBOX_CACHE_RETENTION_DAYS}d+, $size): $entry"
    rm -rf "$entry" && entries_removed=$((entries_removed + 1)) || \
      echo "  (failed to remove $entry)"
  done < <(
    find "$CURSOR_SANDBOX_CACHE_DIR" -mindepth 1 -maxdepth 1 -type d \
      -mtime "+${CURSOR_SANDBOX_CACHE_RETENTION_DAYS}" -print0 2>/dev/null
  )
  echo "  Removed ${entries_removed} sandbox entr(ies) older than ${CURSOR_SANDBOX_CACHE_RETENTION_DAYS} day(s)"

  # Drop empty dirs left behind
  find "$CURSOR_SANDBOX_CACHE_DIR" -mindepth 1 -type d -empty -delete 2>/dev/null || true

  echo ""
  echo "📋 Cursor sandbox cache after cleanup:"
  if [[ -d "$CURSOR_SANDBOX_CACHE_DIR" ]]; then
    du -sh "$CURSOR_SANDBOX_CACHE_DIR" 2>/dev/null || true
  else
    echo "  (directory removed / absent)"
  fi
  echo ""
else
  echo "ℹ️  No Cursor sandbox cache at ${CURSOR_SANDBOX_CACHE_DIR}, skipping..."
  echo ""
fi

echo "📋 /tmp disk usage after cleanup:"
du_sh /tmp
echo ""

# Cursor remote-server bins + agent-cli versions under INFRA_HOME (not root $HOME)
clean_cursor_user_space

# Clean Rust/Cargo cache for INFRA_USER (sudo $HOME is /root — do not use it)
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
CARGO_HOME="$(infra_user_home)/.cargo"
RUSTUP_HOME="$(infra_user_home)/.rustup"
if [[ -d "$CARGO_HOME" ]]; then
  echo "📋 Rust/Cargo cache disk usage before cleanup (${INFRA_USER}):"
  du_sh "$CARGO_HOME"
  echo ""

  echo "🗑️  Cleaning ${INFRA_USER} Rust/Cargo cache..."
  if [[ -d "$CARGO_HOME/target" ]]; then
    echo "  Removing $CARGO_HOME/target ($(du -sh "$CARGO_HOME/target" 2>/dev/null | cut -f1 || echo '?'))"
    rm -rf "$CARGO_HOME/target"
  fi
  if [[ -d "$CARGO_HOME/registry/cache" ]]; then
    find "$CARGO_HOME/registry/cache" -type f -atime +30 -delete 2>/dev/null || true
    echo "  Cleaned cargo registry cache (files older than 30 days)"
  fi
  if [[ -d "$CARGO_HOME/git/db" ]]; then
    find "$CARGO_HOME/git/db" -type f -atime +30 -delete 2>/dev/null || true
    echo "  Cleaned cargo git cache"
  fi
  if [[ -d "$RUSTUP_HOME/tmp" ]]; then
    echo "  Removing rustup tmp ($(du -sh "$RUSTUP_HOME/tmp" 2>/dev/null | cut -f1 || echo '?'))"
    rm -rf "${RUSTUP_HOME}/tmp/"*
  fi
  echo ""

  echo "📋 Rust/Cargo cache disk usage after cleanup:"
  du_sh "$CARGO_HOME"
  echo ""
else
  echo "ℹ️  No Cargo home at ${CARGO_HOME}, skipping..."
  echo ""
fi

# Clean npm cache as INFRA_USER (root's npm is a different store)
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if run_as_infra_user bash -lc 'command -v npm >/dev/null'; then
  echo "📋 npm cache disk usage before cleanup (${INFRA_USER}):"
  run_as_infra_user npm cache verify 2>/dev/null | tail -1 || echo "  (unable to verify)"
  echo ""

  echo "🗑️  Cleaning ${INFRA_USER} npm cache..."
  run_as_infra_user npm cache clean --force 2>/dev/null || echo "  (npm cache clean failed, may be empty)"
  echo ""

  echo "📋 npm cache disk usage after cleanup:"
  run_as_infra_user npm cache verify 2>/dev/null | tail -1 || echo "  (cache verified)"
  echo ""
else
  echo "ℹ️  npm not installed for ${INFRA_USER}, skipping..."
  echo ""
fi

# Rootless Podman store for INFRA_USER when run via sudo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if run_as_infra_user podman --version >/dev/null 2>&1; then
  echo "📦 Podman storage before cleanup (${INFRA_USER}):"
  run_as_infra_user podman system df || echo "  (podman system df failed)"
  echo ""

  echo "🗑️  Removing unused Podman images and Buildah cache mounts..."
  # --build-cache drops persistent --mount=type=cache trees (IronClaw's
  # ironclaw-cargo-target mount). A failed dist cook can leave that mount
  # full; the next cook then dies with ENOSPC. Does not remove images still
  # referenced by a running container, or named volumes.
  run_as_infra_user podman image prune -a -f --build-cache || echo "  (image prune failed)"
  echo ""

  echo "🗑️  Pruning stopped containers and unused networks..."
  run_as_infra_user podman system prune -f || echo "  (system prune failed)"
  echo ""

  echo "📦 Podman storage after cleanup (${INFRA_USER}):"
  run_as_infra_user podman system df || echo "  (podman system df failed)"
  echo ""
else
  echo "ℹ️  Podman not installed for ${INFRA_USER}, skipping..."
  echo ""
fi

# Clean old Trivy weekly scan artifacts (reports, summaries, SBOM snapshots)
# Keep manifests and recent files (default 28 days ≈ 4 weekly runs).
TRIVY_RESULTS_DIR="${SCAN_RESULTS_DIR:-${INFRA_TRIVY_RESULTS_DIR:-${INFRA_OUTPUT_DIR:-${INFRA_APP_DIR}}/trivy-scan-results}}"
TRIVY_RESULTS_RETENTION_DAYS="${TRIVY_RESULTS_RETENTION_DAYS:-28}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ -d "$TRIVY_RESULTS_DIR" ]]; then
  echo "📋 Trivy scan results before cleanup:"
  du -sh "$TRIVY_RESULTS_DIR" 2>/dev/null || echo "  (unable to calculate)"
  echo ""

  echo "🗑️  Removing Trivy artifacts older than ${TRIVY_RESULTS_RETENTION_DAYS} days..."
  echo "  Directory: $TRIVY_RESULTS_DIR"
  before_count=$(find "$TRIVY_RESULTS_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')
  # Timestamped reports / summaries / diffs
  find "$TRIVY_RESULTS_DIR" -maxdepth 1 -type f \( \
      -name 'trivy-scan-report-*.txt' \
      -o -name 'trivy-summary-*.json' \
      -o -name 'trivy-fs-*.txt' \
      -o -name 'sbom-diff-*.txt' \
    \) -mtime "+${TRIVY_RESULTS_RETENTION_DAYS}" -print -delete 2>/dev/null || true
  # CycloneDX SBOM snapshots (current + .prev); never touch manifests
  if [[ -d "$TRIVY_RESULTS_DIR/sbom" ]]; then
    find "$TRIVY_RESULTS_DIR/sbom" -type f \( \
        -name '*.cyclonedx.json' \
        -o -name '*.cyclonedx.json.prev' \
      \) -mtime "+${TRIVY_RESULTS_RETENTION_DAYS}" -print -delete 2>/dev/null || true
    find "$TRIVY_RESULTS_DIR/sbom" -mindepth 1 -type d -empty -delete 2>/dev/null || true
  fi
  after_count=$(find "$TRIVY_RESULTS_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')
  removed=$((before_count - after_count))
  echo "  Removed ${removed} file(s); ${after_count} remaining (kept manifests + recent artifacts)"
  echo ""

  echo "📋 Trivy scan results after cleanup:"
  du -sh "$TRIVY_RESULTS_DIR" 2>/dev/null || echo "  (unable to calculate)"
  echo ""
else
  echo "ℹ️  Trivy results dir not found ($TRIVY_RESULTS_DIR), skipping..."
  echo ""
fi

clean_hermes_memory_backups

# Clean project-specific directories under INFRA_HOME (not root's $HOME)
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📋 Project directories cleanup (${INFRA_USER} home):"
echo ""

PROJECT_BASE="${PROJECT_BASE:-$(infra_user_home)}"

echo "🗑️  Cleaning large log files in project directories..."
while IFS= read -r logfile; do
  [[ -n "$logfile" ]] || continue
  LOG_SIZE=$(du -h "$logfile" | cut -f1)
  echo "  Truncating $logfile ($LOG_SIZE -> 100M)..."
  truncate -s 100M "$logfile" 2>/dev/null || echo "  (failed to truncate, may need sudo)"
done < <(find "$PROJECT_BASE" -maxdepth 3 -type f -name "*.log" -size +100M 2>/dev/null || true)
echo ""

echo "🗑️  Cleaning Cargo target directories under ${PROJECT_BASE}..."
# Workspace Cargo writes ~/proj/target (depth 2). A failed weekly run that
# searched /root skipped ~/ironclaw-idc/target (~100G) and left the disk at 99%.
while IFS= read -r targetdir; do
  [[ -n "$targetdir" ]] || continue
  TARGET_SIZE=$(du -sh "$targetdir" 2>/dev/null | cut -f1)
  if [ -n "$TARGET_SIZE" ]; then
    echo "  Removing $targetdir ($TARGET_SIZE)..."
    rm -rf "$targetdir" 2>/dev/null || echo "  (failed to remove $targetdir)"
  fi
done < <(find "$PROJECT_BASE" -maxdepth 2 -type d -name "target" 2>/dev/null || true)
echo ""

echo "🗑️  Cleaning CodeQL run databases (itemdb/codeql/runs/)..."
clean_codeql_run_dirs "$PROJECT_BASE"

# Clean up node_modules in inactive projects (optional - commented out by default)
# Uncomment the following lines to remove node_modules directories
# echo "🗑️  Cleaning node_modules in project directories..."
# find "$PROJECT_BASE" -maxdepth 2 -type d -name "node_modules" 2>/dev/null | while read nmdir; do
#   NM_SIZE=$(du -sh "$nmdir" 2>/dev/null | cut -f1)
#   if [ -n "$NM_SIZE" ]; then
#     echo "  Removing $nmdir ($NM_SIZE)..."
#     rm -rf "$nmdir" 2>/dev/null || echo "  (failed to remove, may need sudo)"
#   fi
# done
# echo ""

# Show final disk usage
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 Final disk usage:"
df -h / | grep -v Filesystem
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${GREEN}✅ Cleanup completed successfully!${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📝 Summary:"
if [[ "$USER_SPACE_ONLY" -eq 1 ]]; then
  echo "  • --user-space: journal, /var/log, DNF, kernels, /var/cache, and root /tmp skipped"
else
  echo "  • Journal logs cleaned (3 days retention, 500MB max)"
  echo "  • /var/log old logs removed; large syslog/auth/kern/messages/secure truncated"
  echo "  • DNF package cache cleaned"
  echo "  • Old kernels removed via dnf (installonly_limit=2)"
  echo "  • /var/cache temporary files cleaned"
  echo "  • /tmp temporary files cleaned"
fi
echo "  • Bun /tmp native-library leaks pruned (retention ${BUN_TMP_NATIVE_RETENTION_MINUTES:-60}m, keep ${BUN_TMP_NATIVE_KEEP_NEWEST:-5} newest)"
echo "  • Cursor /tmp/cursor-sandbox-cache pruned (cargo-target + entries older than ${CURSOR_SANDBOX_CACHE_RETENTION_DAYS:-3}d)"
echo "  • Cursor ~/.cursor-server bins kept newest ${CURSOR_SERVER_BIN_KEEP_NEWEST:-2}; agent-cli versions kept newest ${CURSOR_AGENT_VERSIONS_KEEP_NEWEST:-2}"
echo "  • Cursor server logs >${CURSOR_SERVER_LOGS_RETENTION_DAYS:-7}d and ~/.cursor/projects/tmp-* >${CURSOR_PROJECT_TMP_RETENTION_DAYS:-3}d pruned"
echo "  • ${INFRA_USER} Cargo/rustup tmp cleaned (INFRA_HOME, not root \$HOME)"
echo "  • ${INFRA_USER} npm cache cleaned"
echo "  • Podman unused images, --mount=type=cache trees, and stopped containers pruned"
echo "  • Trivy scan artifacts older than ${TRIVY_RESULTS_RETENTION_DAYS:-28} days removed"
echo "  • Project log files truncated (files >100M)"
echo "  • CodeQL run dirs pruned (>${CODEQL_RUNS_RETENTION_DAYS:-7}d old; keep ${CODEQL_RUNS_KEEP_NEWEST:-3} newest per project)"
echo "  • Hermes memory backups capped (newest ${HERMES_MEMORY_BACKUP_KEEP:-30}, >${HERMES_MEMORY_BACKUP_RETENTION_DAYS:-90}d, max ${HERMES_MEMORY_BACKUP_MAX_BYTES:-67108864} bytes)"
echo "  • Cargo target/ directories removed under ${INFRA_HOME}"
echo "  • node_modules cleanup available (uncomment in script)"
echo ""
echo "💡 Tip: Run this script regularly to maintain disk space"
echo "💡 Override Trivy retention: TRIVY_RESULTS_RETENTION_DAYS=14 sudo $0"
echo "💡 Override Cursor sandbox retention: CURSOR_SANDBOX_CACHE_RETENTION_DAYS=7 sudo $0"
echo "💡 Override Cursor server/agent keep: CURSOR_SERVER_BIN_KEEP_NEWEST=1 CURSOR_AGENT_VERSIONS_KEEP_NEWEST=1 sudo $0"
echo "💡 Override Bun /tmp leak retention: BUN_TMP_NATIVE_RETENTION_MINUTES=30 BUN_TMP_NATIVE_KEEP_NEWEST=10 sudo $0"
echo "💡 Override CodeQL run retention: CODEQL_RUNS_RETENTION_DAYS=14 CODEQL_RUNS_KEEP_NEWEST=5 sudo $0"
echo "💡 Override Hermes memory backup cap: HERMES_MEMORY_BACKUP_KEEP=30 HERMES_MEMORY_BACKUP_RETENTION_DAYS=90 HERMES_MEMORY_BACKUP_MAX_BYTES=67108864 sudo $0"
echo "💡 User-space only (no sudo): $0 --user-space"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
