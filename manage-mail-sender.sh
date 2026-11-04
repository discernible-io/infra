#!/usr/bin/env bash
# Send mail from this host with Himalaya (SMTP only, no IMAP).
#
# The SMTP account and password live only in the sibling directory
# ../infra-app/mail/ (INFRA_APP_DIR). Nothing in this git checkout holds them.
#
# Usage:
#   sudo ./manage-mail-sender.sh install
#   ./manage-mail-sender.sh status
#   ./manage-mail-sender.sh send --to ADDR --subject TEXT [--body TEXT] [--account NAME]
#   ./manage-mail-sender.sh send --to ADDR --subject TEXT --html --html-file FILE [--account NAME]
#   ./manage-mail-sender.sh help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=infra-env-helper.sh
source "$SCRIPT_DIR/infra-env-helper.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

INFRA_USER="${INFRA_USER:-$(id -un)}"
INFRA_HOME="${INFRA_HOME:-/home/${INFRA_USER}}"
INFRA_GROUP="$(id -gn "$INFRA_USER")"
INFRA_CERT_EMAIL="${INFRA_CERT_EMAIL:-}"

HIMALAYA_VERSION="2.2.1"
HIMALAYA_TARGET="x86_64-linux"
HIMALAYA_SHA256="5c5ba2724c162f82d0a0c71b6c03224ed44f8bef7b14ace5da0635d3af2665a0"
HIMALAYA_URL="https://github.com/pimalaya/himalaya/releases/download/v${HIMALAYA_VERSION}/himalaya.${HIMALAYA_TARGET}.tgz"
HIMALAYA_BIN="/usr/local/bin/himalaya"

MAIL_DIR="${INFRA_APP_DIR}/mail"
SMTP_ENV="${MAIL_DIR}/smtp.env"
PASS_FILE="${MAIL_DIR}/smtp-password"
CONFIG_FILE="${MAIL_DIR}/config.toml"

SMTP_SERVER=""
SMTP_STARTTLS="true"
SMTP_DEFAULT=""
SMTP_ACCOUNTS=()
declare -A SMTP_EMAIL=()
declare -A SMTP_FROM_NAME=()
# Legacy single-account fields, migrated into SMTP_ACCOUNTS when present.
SMTP_USER=""
SMTP_FROM=""
SMTP_FROM_NAME_LEGACY=""

usage() {
  cat <<EOF
Usage: sudo $0 install
       $0 status
       $0 send --to ADDR --subject TEXT [--body TEXT] [--account NAME]
       $0 send --to ADDR --subject TEXT --html [--body HTML | --html-file FILE] [--account NAME]
       $0 help

install   Download Himalaya ${HIMALAYA_VERSION} to ${HIMALAYA_BIN} and create
          ${MAIL_DIR}/ if needed. Does not overwrite smtp.env or password files.
status    Show the binary, accounts, and password files. Runs account check for
          every complete account.
send      Send one message as --account NAME (default from SMTP_DEFAULT).
          Body is --body, or stdin when stdin is not a tty.
          Repeat --to for more than one recipient.
          --html sends that body as HTML, with a plain-text alternative.
          Local <img> files are embedded. Remote image URLs are left as-is.
          --html-file reads the HTML from a file and resolves images next to it.

Accounts live only under ${MAIL_DIR}/ (../infra-app/mail):
  ${SMTP_ENV}
  smtp-password.<account>   (legacy smtp-password is used for the default)
See docs/mail-sender.env.example. Do not put these files in this git checkout.
EOF
}

log() { echo -e "$*"; }
die() { log "${RED}Error: $*${NC}" >&2; exit 1; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "install must be run with sudo"
  fi
}

himalaya_bin() {
  if [[ -x "$HIMALAYA_BIN" ]]; then
    printf '%s\n' "$HIMALAYA_BIN"
    return 0
  fi
  if command -v himalaya >/dev/null 2>&1; then
    command -v himalaya
    return 0
  fi
  return 1
}

file_mode() {
  stat -c '%a' "$1"
}

write_owned() {
  local dest=$1 mode=$2
  local tmp
  tmp="$(mktemp)"
  cat >"$tmp"
  if [[ "${EUID}" -eq 0 ]]; then
    install -o "$INFRA_USER" -g "$INFRA_GROUP" -m "$mode" "$tmp" "$dest"
  else
    install -m "$mode" "$tmp" "$dest"
  fi
  rm -f "$tmp"
}

ensure_mail_dir() {
  if [[ "${EUID}" -eq 0 ]]; then
    install -d -o "$INFRA_USER" -g "$INFRA_GROUP" -m 700 "$MAIL_DIR"
  else
    install -d -m 700 "$MAIL_DIR"
  fi
}

account_key_prefix() {
  local id=$1
  printf 'SMTP_%s' "$(printf '%s' "$id" | tr '[:lower:]-' '[:upper:]_')"
}

pass_file_for() {
  local id=$1
  local named="${MAIL_DIR}/smtp-password.${id}"
  if [[ -f "$named" ]]; then
    printf '%s\n' "$named"
    return 0
  fi
  if [[ -n "$SMTP_DEFAULT" && "$id" == "$SMTP_DEFAULT" && -f "$PASS_FILE" ]]; then
    printf '%s\n' "$PASS_FILE"
    return 0
  fi
  printf '%s\n' "$named"
}

password_nonempty_file() {
  local f=$1
  [[ -f "$f" ]] || return 1
  local stripped
  stripped="$(tr -d '[:space:]' <"$f")"
  [[ -n "$stripped" ]]
}

# Account settings and password files. Created for the host user so they can be
# filled in before the Himalaya binary is installed.
ensure_secret_files() {
  ensure_mail_dir
  if [[ ! -f "$SMTP_ENV" ]]; then
    write_owned "$SMTP_ENV" 600 <<EOF
# Host SMTP accounts for manage-mail-sender.sh.
# This file lives in ../infra-app/mail and is not committed.
# SMTP_SERVER is a Himalaya URL, for example:
#   smtp://smtp.example.com:587
#   smtps://smtp.example.com:465
SMTP_SERVER=
SMTP_STARTTLS=true
SMTP_DEFAULT=github
SMTP_ACCOUNTS=github,founder
SMTP_GITHUB_EMAIL=${INFRA_CERT_EMAIL:-github@discernible.io}
SMTP_GITHUB_FROM_NAME=
SMTP_FOUNDER_EMAIL=founder@discernible.io
SMTP_FOUNDER_FROM_NAME=
EOF
    log "${GREEN}Wrote ${SMTP_ENV}${NC}"
  fi
  local id pass
  # Ensure at least the default legacy password path exists.
  if [[ ! -f "$PASS_FILE" ]]; then
    write_owned "$PASS_FILE" 600 </dev/null
    log "${GREEN}Wrote empty ${PASS_FILE}${NC}"
  fi
  if [[ -f "$SMTP_ENV" ]]; then
    # Best-effort: create named password stubs once accounts are known.
    load_smtp_env || true
    for id in "${SMTP_ACCOUNTS[@]:-}"; do
      [[ -n "$id" ]] || continue
      pass="$(pass_file_for "$id")"
      if [[ ! -f "$pass" ]]; then
        write_owned "$pass" 600 </dev/null
        log "${GREEN}Wrote empty ${pass}${NC}"
      fi
    done
  fi
}

strip_value() {
  local v=$1
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  if [[ "$v" == \"*\" ]]; then
    v="${v#\"}"
    v="${v%\"}"
  elif [[ "$v" == \'*\' ]]; then
    v="${v#\'}"
    v="${v%\'}"
  fi
  printf '%s' "$v"
}

load_smtp_env() {
  SMTP_SERVER=""
  SMTP_STARTTLS="true"
  SMTP_DEFAULT=""
  SMTP_ACCOUNTS=()
  SMTP_EMAIL=()
  SMTP_FROM_NAME=()
  SMTP_USER=""
  SMTP_FROM=""
  SMTP_FROM_NAME_LEGACY=""
  [[ -f "$SMTP_ENV" ]] || return 0

  local line key val id email_key name_key
  local -A raw=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    if [[ ! "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      die "invalid line in ${SMTP_ENV}: ${line%%=*}"
    fi
    key="${BASH_REMATCH[1]}"
    val="$(strip_value "${BASH_REMATCH[2]}")"
    raw["$key"]="$val"
  done <"$SMTP_ENV"

  SMTP_SERVER="${raw[SMTP_SERVER]:-}"
  SMTP_STARTTLS="${raw[SMTP_STARTTLS]:-true}"
  SMTP_DEFAULT="${raw[SMTP_DEFAULT]:-}"
  SMTP_USER="${raw[SMTP_USER]:-}"
  SMTP_FROM="${raw[SMTP_FROM]:-}"
  SMTP_FROM_NAME_LEGACY="${raw[SMTP_FROM_NAME]:-}"

  if [[ -n "${raw[SMTP_ACCOUNTS]:-}" ]]; then
    local IFS=,
    read -r -a SMTP_ACCOUNTS <<<"${raw[SMTP_ACCOUNTS]}"
  fi

  # Trim account ids and drop empties.
  local -a cleaned=()
  for id in "${SMTP_ACCOUNTS[@]:-}"; do
    id="$(strip_value "$id")"
    [[ -n "$id" ]] || continue
    cleaned+=("$id")
  done
  SMTP_ACCOUNTS=("${cleaned[@]:-}")

  for id in "${SMTP_ACCOUNTS[@]:-}"; do
    email_key="$(account_key_prefix "$id")_EMAIL"
    name_key="$(account_key_prefix "$id")_FROM_NAME"
    if [[ -n "${raw[$email_key]:-}" ]]; then
      SMTP_EMAIL["$id"]="${raw[$email_key]}"
    fi
    if [[ -n "${raw[$name_key]:-}" ]]; then
      SMTP_FROM_NAME["$id"]="${raw[$name_key]}"
    fi
  done

  # Legacy single-account smtp.env → one account named "host".
  if [[ ${#SMTP_ACCOUNTS[@]} -eq 0 ]]; then
    local email="${SMTP_FROM:-$SMTP_USER}"
    if [[ -n "$email" ]]; then
      SMTP_ACCOUNTS=(host)
      SMTP_DEFAULT=host
      SMTP_EMAIL[host]="$email"
      SMTP_FROM_NAME[host]="$SMTP_FROM_NAME_LEGACY"
    fi
  fi

  if [[ -z "$SMTP_DEFAULT" && ${#SMTP_ACCOUNTS[@]} -gt 0 ]]; then
    SMTP_DEFAULT="${SMTP_ACCOUNTS[0]}"
  fi
}

toml_quote() {
  local s=$1
  if [[ "$s" == *$'\n'* || "$s" == *$'\r'* ]]; then
    die "SMTP value contains a newline"
  fi
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}

ACCOUNT_ERROR=""

shared_smtp_ready() {
  ACCOUNT_ERROR=""
  if [[ -z "$SMTP_SERVER" ]]; then
    ACCOUNT_ERROR="missing SMTP_SERVER"
    return 1
  fi
  if [[ "$SMTP_SERVER" != smtp://* && "$SMTP_SERVER" != smtps://* ]]; then
    ACCOUNT_ERROR="SMTP_SERVER must be a Himalaya URL (smtp://host:587 or smtps://host:465)"
    return 1
  fi
  case "$SMTP_STARTTLS" in
    true|false) ;;
    *)
      ACCOUNT_ERROR="SMTP_STARTTLS must be true or false"
      return 1
      ;;
  esac
  return 0
}

account_ready() {
  local id=$1
  ACCOUNT_ERROR=""
  shared_smtp_ready || return 1
  if [[ -z "${SMTP_EMAIL[$id]:-}" ]]; then
    ACCOUNT_ERROR="missing $(account_key_prefix "$id")_EMAIL"
    return 1
  fi
  return 0
}

resolve_account() {
  local want=$1
  local id email
  if [[ -z "$want" ]]; then
    [[ -n "$SMTP_DEFAULT" ]] || die "no SMTP_DEFAULT and no --account"
    printf '%s\n' "$SMTP_DEFAULT"
    return 0
  fi
  for id in "${SMTP_ACCOUNTS[@]:-}"; do
    if [[ "$id" == "$want" ]]; then
      printf '%s\n' "$id"
      return 0
    fi
  done
  for id in "${SMTP_ACCOUNTS[@]:-}"; do
    email="${SMTP_EMAIL[$id]:-}"
    if [[ "$email" == "$want" ]]; then
      printf '%s\n' "$id"
      return 0
    fi
  done
  die "unknown account '${want}' (known: ${SMTP_ACCOUNTS[*]:-none})"
}

write_config() {
  local id email name pass starttls_line=""
  if [[ "$SMTP_SERVER" == smtp://* ]]; then
    starttls_line="smtp.starttls = ${SMTP_STARTTLS}"
  fi
  {
    echo "# Generated by manage-mail-sender.sh. Edit smtp.env, not this file."
    for id in "${SMTP_ACCOUNTS[@]:-}"; do
      email="${SMTP_EMAIL[$id]:-}"
      [[ -n "$email" ]] || continue
      name="${SMTP_FROM_NAME[$id]:-}"
      pass="$(pass_file_for "$id")"
      echo
      echo "[accounts.${id}]"
      if [[ "$id" == "$SMTP_DEFAULT" ]]; then
        echo "default = true"
      else
        echo "default = false"
      fi
      echo "email = $(toml_quote "$email")"
      if [[ -n "$name" ]]; then
        echo "display-name = $(toml_quote "$name")"
      fi
      echo
      echo "smtp.server = $(toml_quote "$SMTP_SERVER")"
      if [[ -n "$starttls_line" ]]; then
        echo "$starttls_line"
      fi
      echo "smtp.sasl.plain.username = $(toml_quote "$email")"
      echo "smtp.sasl.plain.password.command = $(toml_quote "cat ${pass}")"
    done
  } | write_owned "$CONFIG_FILE" 600
}

cmd_install() {
  require_root
  local machine tmpdir
  machine="$(uname -m)"
  if [[ "$machine" != "x86_64" ]]; then
    die "pinned asset is ${HIMALAYA_TARGET}; this machine is ${machine}"
  fi
  for bin in curl tar sha256sum install; do
    command -v "$bin" >/dev/null 2>&1 || die "missing required command: ${bin}"
  done

  log "${BLUE}Installing Himalaya ${HIMALAYA_VERSION}${NC}"
  tmpdir="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf $(printf '%q' "$tmpdir")" RETURN EXIT

  curl -fsSL -o "${tmpdir}/himalaya.tgz" "$HIMALAYA_URL"
  echo "${HIMALAYA_SHA256}  ${tmpdir}/himalaya.tgz" | sha256sum -c -
  tar -xzf "${tmpdir}/himalaya.tgz" -C "$tmpdir"
  [[ -f "${tmpdir}/himalaya" ]] || die "archive did not contain a himalaya binary"
  install -m 755 "${tmpdir}/himalaya" "$HIMALAYA_BIN"
  local ver
  ver="$("$HIMALAYA_BIN" --version 2>&1 || true)"
  rm -rf "$tmpdir"
  trap - RETURN EXIT
  log "${GREEN}${ver} installed at ${HIMALAYA_BIN}${NC}"
  if [[ "$ver" != *"${HIMALAYA_VERSION}"* ]]; then
    die "installed binary version does not match ${HIMALAYA_VERSION}: ${ver}"
  fi

  ensure_secret_files

  log ""
  log "Next: edit ${SMTP_ENV} and put each mailbox password in smtp-password.<account>"
  log "Then: ${SCRIPT_DIR}/manage-mail-sender.sh status"
}

mode_ok() {
  local mode
  mode="$(file_mode "$1")"
  [[ "$mode" == "600" ]]
}

check_one_account() {
  local bin=$1 id=$2
  local report errfile pass
  pass="$(pass_file_for "$id")"
  if ! account_ready "$id"; then
    log "${YELLOW}Account ${id}: incomplete (${ACCOUNT_ERROR})${NC}"
    return 1
  fi
  if ! password_nonempty_file "$pass"; then
    log "${YELLOW}Account ${id}: password empty (${pass})${NC}"
    return 1
  fi
  errfile="$(mktemp)"
  if ! report="$("$bin" --json -c "$CONFIG_FILE" account check -a "$id" --backend smtp 2>"$errfile")"; then
    log "${RED}Account ${id}: check failed${NC}"
    if [[ -s "$errfile" ]]; then
      cat "$errfile" >&2
    fi
    printf '%s\n' "$report" >&2
    rm -f "$errfile"
    return 1
  fi
  rm -f "$errfile"
  if ! printf '%s' "$report" | jq -e '(.backends | type == "array") and (.backends | length > 0) and all(.backends[]; .ok == true)' >/dev/null; then
    log "${RED}Account ${id}: check failed${NC}"
    printf '%s\n' "$report" | jq -r '
      if (.backends | type == "array") then
        .backends[] | "\(.backend): \(.error // "failed")"
      elif .error then
        .error
      else
        .
      end
    ' >&2
    return 1
  fi
  log "${GREEN}Account ${id} (${SMTP_EMAIL[$id]}): check passed${NC}"
  return 0
}

cmd_status() {
  local bin ver rc=0 dir_mode id pass
  ensure_secret_files
  dir_mode="$(file_mode "$MAIL_DIR")"
  if [[ "$dir_mode" == "700" ]]; then
    log "${GREEN}Directory: ${MAIL_DIR} mode ${dir_mode}${NC}"
  else
    log "${YELLOW}Directory: ${MAIL_DIR} mode ${dir_mode} (expected 700)${NC}"
    rc=1
  fi

  if [[ ! -f "$SMTP_ENV" ]]; then
    log "${RED}Missing ${SMTP_ENV}${NC}"
    return 1
  fi
  if mode_ok "$SMTP_ENV"; then
    log "${GREEN}smtp.env: mode 600${NC}"
  else
    log "${YELLOW}smtp.env: mode $(file_mode "$SMTP_ENV") (expected 600)${NC}"
    rc=1
  fi

  load_smtp_env
  if [[ -z "$SMTP_SERVER" ]]; then
    log "${YELLOW}SMTP_SERVER is empty. Edit ${SMTP_ENV}${NC}"
    return 1
  fi
  log "${GREEN}SMTP_SERVER is set${NC}"
  if [[ ${#SMTP_ACCOUNTS[@]} -eq 0 ]]; then
    log "${YELLOW}No accounts in SMTP_ACCOUNTS. Edit ${SMTP_ENV}${NC}"
    return 1
  fi
  log "Default account: ${SMTP_DEFAULT}"
  for id in "${SMTP_ACCOUNTS[@]}"; do
    pass="$(pass_file_for "$id")"
    if [[ -f "$pass" ]] && mode_ok "$pass"; then
      log "${GREEN}Account ${id}: ${SMTP_EMAIL[$id]:-(no email)} password file $(basename "$pass") mode 600${NC}"
    elif [[ -f "$pass" ]]; then
      log "${YELLOW}Account ${id}: password file $(basename "$pass") mode $(file_mode "$pass") (expected 600)${NC}"
      rc=1
    else
      log "${RED}Account ${id}: missing password file ${pass}${NC}"
      rc=1
    fi
  done

  if bin="$(himalaya_bin)"; then
    ver="$("$bin" --version 2>&1 || true)"
    log "${GREEN}Binary: ${bin} (${ver})${NC}"
  else
    log "${RED}Himalaya is not installed. Run: sudo ${SCRIPT_DIR}/manage-mail-sender.sh install${NC}"
    return 1
  fi

  if ! command -v jq >/dev/null 2>&1; then
    die "jq is required to read account check results"
  fi
  if ! shared_smtp_ready; then
    log "${YELLOW}${ACCOUNT_ERROR}${NC}"
    return 1
  fi
  write_config
  log "Running account checks..."
  for id in "${SMTP_ACCOUNTS[@]}"; do
    check_one_account "$bin" "$id" || rc=1
  done
  return "$rc"
}

# Build an RFC 5322 message with a plain part and an HTML part.
# Local <img src> files under HTML_BASE are embedded. Prints the output path's
# image count on stdout.
write_html_message() {
  local out=$1
  command -v python3 >/dev/null 2>&1 || die "python3 is required to send HTML"
  HTML_OUT="$out" python3 - <<'PY'
import os
import re
from email.encoders import encode_base64
from email.generator import BytesGenerator
from email.mime.base import MIMEBase
from email.mime.image import MIMEImage
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from email.policy import SMTP
from email.utils import formataddr, formatdate, make_msgid
from html import unescape
from io import BytesIO
from pathlib import Path

html_text = os.environ["HTML_BODY"]
base = Path(os.environ.get("HTML_BASE") or ".").resolve()
subject = os.environ["HTML_SUBJECT"]
from_addr = os.environ["HTML_FROM"]
from_name = os.environ.get("HTML_FROM_NAME") or ""
recipients = [line for line in os.environ["HTML_TO"].splitlines() if line.strip()]
out = Path(os.environ["HTML_OUT"])

plain = re.sub(r"(?is)<(script|style)\b[^>]*>.*?</\1>", " ", html_text)
plain = re.sub(r"(?i)<br\s*/?>", "\n", plain)
plain = re.sub(r"(?i)</p\s*>", "\n\n", plain)
plain = re.sub(r"(?i)</(div|tr|h[1-6]|li)\s*>", "\n", plain)
plain = re.sub(r"(?s)<[^>]+>", " ", plain)
plain = unescape(plain)
plain = re.sub(r"[ \t]+\n", "\n", plain)
plain = re.sub(r"\n{3,}", "\n\n", plain)
plain = re.sub(r"[ \t]{2,}", " ", plain).strip()

image_ext = {
    ".png": "png",
    ".jpg": "jpeg",
    ".jpeg": "jpeg",
    ".gif": "gif",
    ".webp": "webp",
}
seen = {}
images = []

def embed(src: str):
    if src.startswith(("http://", "https://", "cid:", "data:")):
        return None
    path = Path(src)
    path = path.resolve() if path.is_absolute() else (base / path).resolve()
    if not path.is_file():
        return None
    subtype = image_ext.get(path.suffix.lower())
    if subtype is None:
        return None
    key = str(path)
    if key in seen:
        return seen[key]
    cid = make_msgid()[1:-1]
    data = path.read_bytes()
    if subtype in {"jpeg", "png", "gif"}:
        part = MIMEImage(data, _subtype=subtype)
    else:
        part = MIMEBase("image", subtype)
        part.set_payload(data)
        encode_base64(part)
    part.add_header("Content-ID", f"<{cid}>")
    part.add_header("Content-Disposition", "inline", filename=path.name)
    images.append(part)
    seen[key] = cid
    return cid

def repl(match):
    cid = embed(match.group(2))
    if cid is None:
        return match.group(0)
    return f'{match.group(1)}cid:{cid}{match.group(3)}'

html_out = re.sub(r'(<img\b[^>]*\bsrc=")([^"]+)(")', repl, html_text, flags=re.I)

root = MIMEMultipart("alternative", policy=SMTP)
root["From"] = formataddr((from_name, from_addr)) if from_name else from_addr
root["To"] = ", ".join(recipients)
root["Subject"] = subject
root["Date"] = formatdate(localtime=True)
root.attach(MIMEText(plain or "HTML message", "plain", "utf-8"))
if images:
    related = MIMEMultipart("related", policy=SMTP)
    related.attach(MIMEText(html_out, "html", "utf-8"))
    for part in images:
        related.attach(part)
    root.attach(related)
else:
    root.attach(MIMEText(html_out, "html", "utf-8"))

buf = BytesIO()
BytesGenerator(buf, policy=SMTP).flatten(root)
out.write_bytes(buf.getvalue())
print(len(images))
PY
}

cmd_send() {
  local -a recipients=()
  local subject="" body="" body_set=0 html=0 html_file="" html_base="" account_want=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --to)
        [[ $# -ge 2 ]] || die "--to needs an address"
        recipients+=("$2")
        shift 2
        ;;
      --subject)
        [[ $# -ge 2 ]] || die "--subject needs text"
        subject="$2"
        shift 2
        ;;
      --body)
        [[ $# -ge 2 ]] || die "--body needs text"
        body="$2"
        body_set=1
        shift 2
        ;;
      --account|--from)
        [[ $# -ge 2 ]] || die "$1 needs an account name or email"
        account_want="$2"
        shift 2
        ;;
      --html)
        html=1
        shift
        ;;
      --html-file)
        [[ $# -ge 2 ]] || die "--html-file needs a path"
        html_file="$2"
        html=1
        shift 2
        ;;
      -h|--help|help)
        usage
        exit 0
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
  done

  [[ ${#recipients[@]} -gt 0 ]] || die "send needs --to ADDR"
  [[ -n "$subject" ]] || die "send needs --subject TEXT"
  if [[ -n "$html_file" && "$body_set" -eq 1 ]]; then
    die "--html-file cannot be combined with --body"
  fi
  if [[ -n "$html_file" ]]; then
    [[ -f "$html_file" ]] || die "HTML file not found: ${html_file}"
    body="$(cat "$html_file")"
    body_set=1
    html_base="$(cd "$(dirname "$html_file")" && pwd)"
  elif [[ "$body_set" -eq 0 ]]; then
    if [[ -t 0 ]]; then
      die "pass --body TEXT, --html-file FILE, or pipe the message body on stdin"
    fi
    body="$(cat)"
    html_base="$(pwd)"
  else
    html_base="$(pwd)"
  fi
  if [[ -z "${body//[[:space:]]/}" ]]; then
    die "message body is empty"
  fi

  local bin account pass
  bin="$(himalaya_bin)" || die "Himalaya is not installed. Run: sudo $0 install"
  ensure_secret_files
  load_smtp_env
  account="$(resolve_account "$account_want")"
  if ! account_ready "$account"; then
    die "${ACCOUNT_ERROR}. Edit ${SMTP_ENV}"
  fi
  pass="$(pass_file_for "$account")"
  if ! password_nonempty_file "$pass"; then
    die "password is empty (${pass})"
  fi
  write_config

  if [[ "$html" -eq 1 ]]; then
    local eml images
    eml="$(mktemp)"
    images="$(
      HTML_BODY="$body" \
      HTML_BASE="$html_base" \
      HTML_SUBJECT="$subject" \
      HTML_FROM="${SMTP_EMAIL[$account]}" \
      HTML_FROM_NAME="${SMTP_FROM_NAME[$account]:-}" \
      HTML_TO="$(printf '%s\n' "${recipients[@]}")" \
      write_html_message "$eml"
    )" || { rm -f "$eml"; die "could not build the HTML message"; }
    log "Embedded ${images} image(s)"
    local rc=0
    "$bin" -c "$CONFIG_FILE" message send -a "$account" --backend smtp --no-save -- "$eml" || rc=$?
    rm -f "$eml"
    return "$rc"
  fi

  local -a args=(message compose -a "$account" --backend smtp --send --no-save --subject "$subject" --body "$body")
  local addr
  for addr in "${recipients[@]}"; do
    args+=(--to "$addr")
  done
  "$bin" -c "$CONFIG_FILE" "${args[@]}"
}

main() {
  local cmd="${1:-help}"
  case "$cmd" in
    install)
      shift
      [[ $# -eq 0 ]] || die "install takes no arguments"
      cmd_install
      ;;
    status)
      shift
      [[ $# -eq 0 ]] || die "status takes no arguments"
      cmd_status
      ;;
    send)
      shift
      cmd_send "$@"
      ;;
    help|-h|--help)
      usage
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"
