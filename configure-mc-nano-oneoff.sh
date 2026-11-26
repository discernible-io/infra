#!/usr/bin/env bash
# Use nano (not mcedit) when editing files from Midnight Commander (F4).
#
# MC 4.8.x ignores the ini "editor=" value. F4 uses the internal editor when
# use_internal_edit=true, otherwise $EDITOR (vi if unset).
#
# sudo mc is a different account: it reads /root/.config/mc/ini and drops the
# caller's EDITOR. Run this script with sudo so root's ini is updated and
# /etc/environment supplies EDITOR through pam_env (sudo's PAM stack).
#
# Quit mc before running this script so auto_save_setup does not overwrite
# the ini on exit.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/infra-env-helper.sh" ]]; then
  # shellcheck source=infra-env-helper.sh
  source "$SCRIPT_DIR/infra-env-helper.sh"
fi
INFRA_USER="${INFRA_USER:-$(id -un)}"
INFRA_HOME="${INFRA_HOME:-/home/${INFRA_USER}}"

NANO_BIN="$(command -v nano || true)"
if [[ -z "$NANO_BIN" ]]; then
  echo "nano not found; install with: sudo dnf install -y nano" >&2
  exit 1
fi

configure_mc_home() {
  local home="$1"
  local owner="$2"
  local mc_ini="${home}/.config/mc/ini"
  local bashrc="${home}/.bashrc"

  mkdir -p "$(dirname "$mc_ini")"

  if [[ ! -f "$mc_ini" ]]; then
    # mc writes ini into $HOME. Point it at this account, not the caller.
    HOME="$home" TERM="${TERM:-xterm}" mc -c >/dev/null 2>&1 || true
  fi

  if [[ ! -f "$mc_ini" ]]; then
    cat >"$mc_ini" <<EOF
[Midnight-Commander]
editor=${NANO_BIN}
use_internal_edit=false

[External editor or viewer parameters]
${NANO_BIN}=+%lineno %filename
EOF
  else
    if grep -q '^use_internal_edit=' "$mc_ini"; then
      sed -i 's/^use_internal_edit=.*/use_internal_edit=false/' "$mc_ini"
    else
      sed -i "/^\[Midnight-Commander\]/a use_internal_edit=false" "$mc_ini"
    fi
    if grep -q '^editor=' "$mc_ini"; then
      sed -i "s|^editor=.*|editor=${NANO_BIN}|" "$mc_ini"
    else
      sed -i "/^\[Midnight-Commander\]/a editor=${NANO_BIN}" "$mc_ini"
    fi
    if ! grep -q '^\[External editor or viewer parameters\]' "$mc_ini"; then
      printf '\n[External editor or viewer parameters]\n%s=+%%lineno %%filename\n' "$NANO_BIN" >>"$mc_ini"
    elif ! grep -q "^${NANO_BIN}=" "$mc_ini"; then
      printf '%s=+%%lineno %%filename\n' "$NANO_BIN" >>"$mc_ini"
    fi
  fi

  if [[ -f "$bashrc" ]]; then
    if grep -q '^export EDITOR=' "$bashrc"; then
      sed -i "s|^export EDITOR=.*|export EDITOR=${NANO_BIN}|" "$bashrc"
    else
      printf '\nexport EDITOR=%s\n' "$NANO_BIN" >>"$bashrc"
    fi
    if grep -q '^export VISUAL=' "$bashrc"; then
      sed -i "s|^export VISUAL=.*|export VISUAL=${NANO_BIN}|" "$bashrc"
    else
      printf 'export VISUAL=%s\n' "$NANO_BIN" >>"$bashrc"
    fi
  else
    printf 'export EDITOR=%s\nexport VISUAL=%s\n' "$NANO_BIN" "$NANO_BIN" >"$bashrc"
  fi

  if [[ -n "$owner" && "$(id -un)" == root ]]; then
    chown "${owner}:${owner}" "$mc_ini" "$bashrc" 2>/dev/null || true
    chmod u+w "$mc_ini" 2>/dev/null || true
  fi

  echo "Configured ${mc_ini}:"
  grep -E '^editor=|^use_internal_edit=' "$mc_ini" || true
  echo "Configured ${bashrc}:"
  grep -E '^export (EDITOR|VISUAL)=' "$bashrc" || true
  echo
}

# pam_env reads this on sudo (auth stack includes pam_env.so). sudo's
# env_reset drops the caller's EDITOR, so sudo mc would otherwise fall back to vi.
ensure_system_editor() {
  local env_file="/etc/environment"
  local key

  touch "$env_file"
  for key in EDITOR VISUAL; do
    if grep -q "^${key}=" "$env_file"; then
      sed -i "s|^${key}=.*|${key}=${NANO_BIN}|" "$env_file"
    else
      printf '%s=%s\n' "$key" "$NANO_BIN" >>"$env_file"
    fi
  done

  echo "Configured ${env_file} (used by sudo mc):"
  grep -E '^(EDITOR|VISUAL)=' "$env_file" || true
  echo
}

configure_mc_home "$INFRA_HOME" "$INFRA_USER"

if [[ "$(id -u)" -eq 0 && "$INFRA_HOME" != /root ]]; then
  configure_mc_home /root root
  ensure_system_editor
fi

echo "Next steps:"
echo "  1. Quit mc completely (plain mc and sudo mc)."
echo "  2. source ${INFRA_HOME}/.bashrc"
echo "  3. mc or sudo mc, then F4 on a file — should open nano."
echo
echo "If F4 still uses mcedit, in mc: Options → Configuration → uncheck"
echo "  \"Use internal edit\", OK, then quit mc once to save."
