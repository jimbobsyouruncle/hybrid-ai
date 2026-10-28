#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/tls-audit.sh
# PURPOSE (plain English):
#   Keeps an append-only record of every certificate Caddy has issued or
#   renewed, WITHOUT asking Docker or reading a single log line. It walks
#   Caddy's managed certificate storage, reads the leaf certificate of each
#   host with openssl (never the private key), and compares its serial with the
#   serial recorded last time.
#
#   A NEW serial IS PROOF OF A RENEWAL. That is the whole point: Caddy renews
#   in memory and never reloads or restarts, so there is no other artifact that
#   says "this certificate was replaced".
#
#   One line is appended ONLY when something changed:
#     ts=<ISO8601> host=<h> event=issue|renew|renew-overdue|missing outcome=... serial=<S> not_after=<ISO> issuer="<CN>" acme_ca=<ca-dir>
#
#   The log is append-only: this script never truncates and never rewrites
#   history. Rotation is a config decision (deploy/logrotate/hybrid-ai-tls).
#
# EXIT: 0 nothing wrong / nothing changed, 1 missing or unreadable certificate
#       storage, 3 the certificate root does not exist (nothing to audit yet).
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

CERT_ROOT=""
LOG_DIR=""
AUDIT_LOG=""
STATE_FILE=""
ENV_FILE=""
RENEWAL_WINDOW_DAYS=30

usage() {
  cat <<'EOF'
Usage: tls-audit.sh [options]

  --cert-root PATH   Caddy managed certificate root
                     (default $HYBRID_AI_DATA_DIR/caddy/caddy/certificates,
                      else <repo>/data/caddy/caddy/certificates)
  --log-dir DIR      directory for the log and state file
                     (default $HYBRID_AI_LOG_DIR, else $HYBRID_AI_DATA_DIR/logs)
  --audit-log PATH   append-only audit log (default <log dir>/tls-audit.log)
  --state-file PATH  serial state file (default <log dir>/tls-audit.state)
  --env-file PATH    env file to read HYBRID_AI_DATA_DIR and HYBRID_AI_LOG_DIR
                     from (default <repo>/.env; never sourced)
  --renewal-window N days-to-expiry that counts as "renewal overdue" (default 30)
  -h, --help         this text
EOF
}

die_usage() { printf 'tls-audit: %s\n' "$1" >&2; exit 2; }
iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }


while (( $# > 0 )); do
  case "$1" in
    --cert-root)      [[ -n "${2:-}" ]] || die_usage "--cert-root needs a value"; CERT_ROOT="$2"; shift 2 ;;
    --log-dir)        [[ -n "${2:-}" ]] || die_usage "--log-dir needs a value"; LOG_DIR="$2"; shift 2 ;;
    --audit-log)      [[ -n "${2:-}" ]] || die_usage "--audit-log needs a value"; AUDIT_LOG="$2"; shift 2 ;;
    --state-file)     [[ -n "${2:-}" ]] || die_usage "--state-file needs a value"; STATE_FILE="$2"; shift 2 ;;
    --env-file)       [[ -n "${2:-}" ]] || die_usage "--env-file needs a value"; ENV_FILE="$2"; shift 2 ;;
    --renewal-window) [[ -n "${2:-}" ]] || die_usage "--renewal-window needs a value"; RENEWAL_WINDOW_DAYS="$2"; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    *)                die_usage "unknown argument: $1" ;;
  esac
done

[[ "$RENEWAL_WINDOW_DAYS" =~ ^[0-9]+$ ]] || die_usage "--renewal-window must be a number"
command -v openssl >/dev/null 2>&1 || die_usage "required tool not found: openssl"

# --- paths come from the shared resolver -----------------------------------
# An explicit --env-file is handed to the helper BEFORE it loads, so a fixture
# still wins over the ambient environment (the helper reads environment first,
# then the file). The certificate root is defined ONCE, in the helper, so a
# future relocation of Caddy's data touches one line.
if [[ -n "$ENV_FILE" && -z "${HYBRID_AI_ENV_FILE:-}" ]]; then
  export HYBRID_AI_ENV_FILE="$ENV_FILE"
fi
# shellcheck source=scripts/lib/hybrid-ai-env.sh
source "${SCRIPT_DIR}/lib/hybrid-ai-env.sh"

# Consumers here read stack settings (ACME_CA and friends), so the env file to
# read is the STACK file the helper resolved.
[[ -n "$ENV_FILE" ]] || ENV_FILE="$HYBRID_AI_STACK_ENV_FILE"

[[ -n "$CERT_ROOT" ]] || CERT_ROOT="$HYBRID_AI_CADDY_CERT_ROOT"
[[ -n "$LOG_DIR" ]] || LOG_DIR="$HYBRID_AI_LOG_DIR"
[[ -n "$AUDIT_LOG" ]] || AUDIT_LOG="${LOG_DIR}/tls-audit.log"
[[ -n "$STATE_FILE" ]] || STATE_FILE="${LOG_DIR}/tls-audit.state"

# Cert root absent means Caddy has not issued anything yet, not that anything
# is broken.
if [[ ! -e "$CERT_ROOT" ]]; then
  printf 'tls-audit: SKIPPED (certificate root does not exist: %s)\n' "$CERT_ROOT" >&2
  exit 3
fi
if [[ ! -d "$CERT_ROOT" || ! -r "$CERT_ROOT" ]]; then
  printf 'tls-audit: certificate root is not a readable directory: %s\n' "$CERT_ROOT" >&2
  exit 1
fi

ensure_private_file() {
  local f="$1" d
  d="$(dirname -- "$f")"
  if [[ ! -d "$d" ]]; then
    mkdir -p "$d" 2>/dev/null || return 1
    chmod 700 "$d" 2>/dev/null || true
  fi
  if [[ ! -e "$f" ]]; then
    ( umask 077; : > "$f" ) || return 1
  fi
  chmod 600 "$f" 2>/dev/null || true
  return 0
}

# Renders "Jan 20 00:00:00 2027 GMT" as ISO8601.
to_iso8601() { date -u -d "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null; }

days_until() {
  local end now
  end="$(date -u -d "$1" +%s 2>/dev/null)" || return 1
  now="$(date -u +%s)"
  [[ "$end" =~ ^-?[0-9]+$ ]] || return 1
  if (( end >= now )); then
    printf '%s' $(( (end - now) / 86400 ))
  else
    printf '%s' $(( -( (now - end + 86399) / 86400 ) ))
  fi
}

ensure_private_file "$AUDIT_LOG" || { printf 'tls-audit: cannot write %s\n' "$AUDIT_LOG" >&2; exit 1; }
ensure_private_file "$STATE_FILE" || { printf 'tls-audit: cannot write %s\n' "$STATE_FILE" >&2; exit 1; }

# State format: one "host serial" pair per line. Read into associative arrays.
declare -A PREV_SERIAL=()
if [[ -s "$STATE_FILE" ]]; then
  while read -r h s rest; do
    [[ -n "${h:-}" && -n "${s:-}" ]] || continue
    PREV_SERIAL["$h"]="$s"
  done < "$STATE_FILE"
fi

declare -A SEEN=()
declare -A NEW_SERIAL=()
changed=0
problems=0
ts="$(iso_now)"

emit() {
  local host="$1" event="$2" outcome="$3" serial="$4" not_after="$5" issuer="$6" ca="$7"
  printf 'ts=%s host=%s event=%s outcome=%s serial=%s not_after=%s issuer="%s" acme_ca=%s\n' \
    "$ts" "$host" "$event" "$outcome" "${serial:-unknown}" "${not_after:-unknown}" \
    "$issuer" "$ca" >> "$AUDIT_LOG" || return 1
  return 0
}

# Caddy layout: <root>/<acme-ca-dir>/<host>/<host>.crt (+ .json, .key).
for ca_dir in "$CERT_ROOT"/*/; do
  [[ -d "$ca_dir" ]] || continue
  ca_name="$(basename -- "${ca_dir%/}")"
  for host_dir in "$ca_dir"*/; do
    [[ -d "$host_dir" ]] || continue
    host="$(basename -- "${host_dir%/}")"
    crt="${host_dir}${host}.crt"
    SEEN["$host"]=1

    if [[ ! -f "$crt" ]]; then
      # The host directory survives a renewal, so a missing .crt is a real gap.
      if [[ -n "${PREV_SERIAL[$host]:-}" ]]; then
        emit "$host" missing failure "" "" "" "$ca_name" || true
        changed=1
        problems=1
      fi
      continue
    fi

    if ! meta="$(openssl x509 -in "$crt" -noout -serial -enddate -issuer -fingerprint -sha256 2>/dev/null)"; then
      printf 'tls-audit: cannot read certificate %s\n' "$crt" >&2
      problems=1
      if [[ -n "${PREV_SERIAL[$host]:-}" ]]; then
        emit "$host" missing failure "" "" "" "$ca_name" || true
        changed=1
      fi
      continue
    fi

    serial="$(printf '%s\n' "$meta" | sed -n 's/^serial=//p' | head -1)"
    enddate="$(printf '%s\n' "$meta" | sed -n 's/^notAfter=//p' | head -1)"
    issuer_line="$(printf '%s\n' "$meta" | sed -n 's/^issuer=//p' | head -1)"
    cn="$(printf '%s' "$issuer_line" | sed -n 's/.*CN=\([^,/]*\).*/\1/p')"
    [[ -n "$cn" ]] || cn="$issuer_line"
    not_after="$(to_iso8601 "$enddate")"
    days="$(days_until "$enddate" || true)"

    NEW_SERIAL["$host"]="$serial"

    if [[ -z "${PREV_SERIAL[$host]:-}" ]]; then
      emit "$host" issue success "$serial" "$not_after" "$cn" "$ca_name" || true
      changed=1
    elif [[ "${PREV_SERIAL[$host]}" != "$serial" ]]; then
      emit "$host" renew success "$serial" "$not_after" "$cn" "$ca_name" || true
      changed=1
    elif [[ "$days" =~ ^-?[0-9]+$ ]] && (( days <= RENEWAL_WINDOW_DAYS )); then
      emit "$host" renew-overdue pending "$serial" "$not_after" "$cn" "$ca_name" || true
      changed=1
    fi
  done
done

# A host we recorded earlier whose certificate is gone entirely.
for host in "${!PREV_SERIAL[@]}"; do
  if [[ -z "${SEEN[$host]:-}" ]]; then
    emit "$host" missing failure "" "" "" "" || true
    changed=1
    problems=1
  fi
done

# Rewrite the state atomically so a crash cannot leave a half-written file.
tmp_state="${STATE_FILE}.tmp.$$"
if ( umask 077; : > "$tmp_state" ) 2>/dev/null; then
  for host in "${!NEW_SERIAL[@]}"; do
    printf '%s %s\n' "$host" "${NEW_SERIAL[$host]}" >> "$tmp_state"
  done
  # Hosts still known through state but whose cert vanished keep their serial so
  # the missing event is not repeated on every run.
  for host in "${!PREV_SERIAL[@]}"; do
    [[ -n "${NEW_SERIAL[$host]:-}" ]] && continue
    printf '%s %s\n' "$host" "${PREV_SERIAL[$host]}" >> "$tmp_state"
  done
  chmod 600 "$tmp_state" 2>/dev/null || true
  mv -f "$tmp_state" "$STATE_FILE" || rm -f "$tmp_state"
else
  rm -f "$tmp_state"
fi

if (( problems )); then
  exit 1
fi
if (( changed )); then
  printf 'tls-audit: recorded change(s); see %s\n' "$AUDIT_LOG"
else
  printf 'tls-audit: no change\n'
fi
exit 0
