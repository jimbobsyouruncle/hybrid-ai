#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/tls-check.sh
# PURPOSE (plain English):
#   Answers one question: is the certificate the host is actually SERVING
#   healthy? It connects to a live TLS endpoint with SNI, reads the leaf
#   certificate that comes back, and reports how many days are left.
#
#   It is a WATCHDOG, not a renewer. Caddy issues and renews the certificates;
#   this script never issues, never renews, never reloads, never restarts and
#   never touches certificate storage. It only reads what is served over the
#   network and, optionally, appends a line to an audit log.
#
# USAGE:
#   ./scripts/tls-check.sh                      check the default hosts
#   ./scripts/tls-check.sh --host a --host b    check named hosts
#   ./scripts/tls-check.sh --quiet --alert      cron/timer mode
#   ./scripts/tls-check.sh --json               machine-readable output
#
# FIXED THRESHOLDS AND EXIT CODES (do not change):
#   TLS disabled                              -> 3  SKIPPED (not an error)
#   connect fails / no cert / chain invalid    -> 3
#   SAN does not contain the hostname          -> 3
#   days <= 0 (expired)                        -> 2  CRITICAL
#   days < 7                                   -> 2  CRITICAL
#   days < 14                                  -> 1  WARN
#   otherwise                                  -> 0  OK
#   The exit code is the WORST severity across every checked host.
#
#   Both thresholds are flags (--warn-days, --crit-days) and both are printed
#   in the per-host line so a log explains itself without the script.
#
# READ-ONLY GUARANTEE: the only writes are the audit append (--audit) and the
# alert call (--alert). No docker calls, no restart, no reload, no certificate
# storage writes. Private keys are never read.
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

WARN_DAYS=14
CRIT_DAYS=7
QUIET=0
JSON=0
DO_AUDIT=0
DO_ALERT=0
ENV_FILE=""
CA_FILE=""
PROBE_ADDR=""
declare -a HOST_ARGS=()
SINK_DIR=""
AUDIT_LOG=""

usage() {
  cat <<'EOF'
Usage: tls-check.sh [options]

  --host HOST          hostname to check (repeatable). Highest priority.
  --env-file PATH      env file to read settings from (default <repo>/.env)
  --probe-addr ADDR    HOST:PORT to connect to (default $TLS_PROBE_ADDR or 127.0.0.1:443)
  --ca-file PATH       verify against this trust store instead of the system store
  --warn-days N        WARN below N days (default 14)
  --crit-days N        CRITICAL below N days (default 7)
  --audit-log PATH     append one audit line per host (default $HYBRID_AI_LOG_DIR/tls-check.log)
  --audit              shorthand for --audit-log with the default path
  --alert              call scripts/tls-alert.sh when the result is not OK
  --no-alert           do not alert (default)
  --sink-dir DIR       send alerts to DIR instead of the network (tests)
  --quiet              print only non-OK hosts plus one summary line
  --json               print one JSON object, nothing else
  -h, --help           this text
EOF
}

die_usage() { printf 'tls-check: %s\n' "$1" >&2; exit 2; }

# --- narrow env reader ------------------------------------------------------
# Reads ONE key from a file without sourcing or executing it. The value is
# never printed by this script. Surrounding single/double quotes are stripped.
env_read_key() {
  local file="$1" key="$2" v
  [[ -f "$file" && -r "$file" ]] || return 1
  v="$(grep -E "^[[:space:]]*${key}=" "$file" 2>/dev/null | tail -1 | cut -d= -f2-)"
  v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
  printf '%s' "$v"
}

iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

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

# Extracts the FIRST certificate block (the leaf) from an s_client dump.
leaf_from_pem() {
  awk '/-----BEGIN CERTIFICATE-----/{f=1} f{print} /-----END CERTIFICATE-----/{if(f) exit}'
}

# "Jan 20 00:00:00 2027 GMT" -> "2027-01-20T00:00:00Z"
to_iso8601() { date -u -d "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null; }

# days = floor((notAfter - now) / 86400)
days_until() {
  local end now
  end="$(date -u -d "$1" +%s 2>/dev/null)" || return 1
  now="$(date -u +%s)"
  [[ "$end" =~ ^-?[0-9]+$ ]] || return 1
  if (( end >= now )); then
    printf '%s' $(( (end - now) / 86400 ))
  else
    # Floor division for negative differences (bash truncates toward zero).
    printf '%s' $(( -( (now - end + 86399) / 86400 ) ))
  fi
}

# san_match LIST HOST -> 0 when LIST (comma separated DNS:... entries) covers HOST.
# Exact match, or a wildcard *.example.com matching exactly ONE extra label.
san_match() {
  local list="$1" host="$2" entry prefix
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    if [[ "$entry" == "DNS:${host}" ]]; then
      return 0
    fi
    if [[ "$entry" == DNS:\*.* ]]; then
      local suffix="${entry#DNS:*}"
      if [[ "$host" == *"${suffix}" && "$host" != "${suffix#.}" ]]; then
        prefix="${host%"${suffix}"}"
        [[ -n "$prefix" && "$prefix" != *.* ]] && return 0
      fi
    fi
  done < <(printf '%s\n' "$list" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  return 1
}

severity_for_exit() {
  case "$1" in
    0) printf 'ok' ;;
    1) printf 'warn' ;;
    2) printf 'critical' ;;
    *) printf 'missing' ;;
  esac
}

# --- argument parsing -------------------------------------------------------
while (( $# > 0 )); do
  case "$1" in
    --host)        [[ -n "${2:-}" ]] || die_usage "--host needs a value"; HOST_ARGS+=("$2"); shift 2 ;;
    --env-file)    [[ -n "${2:-}" ]] || die_usage "--env-file needs a value"; ENV_FILE="$2"; shift 2 ;;
    --probe-addr)  [[ -n "${2:-}" ]] || die_usage "--probe-addr needs a value"; PROBE_ADDR="$2"; shift 2 ;;
    --ca-file)     [[ -n "${2:-}" ]] || die_usage "--ca-file needs a value"; CA_FILE="$2"; shift 2 ;;
    --warn-days)   [[ -n "${2:-}" ]] || die_usage "--warn-days needs a value"; WARN_DAYS="$2"; shift 2 ;;
    --crit-days)   [[ -n "${2:-}" ]] || die_usage "--crit-days needs a value"; CRIT_DAYS="$2"; shift 2 ;;
    --audit-log)   [[ -n "${2:-}" ]] || die_usage "--audit-log needs a value"; AUDIT_LOG="$2"; DO_AUDIT=1; shift 2 ;;
    --audit)       DO_AUDIT=1; shift ;;
    --alert)       DO_ALERT=1; shift ;;
    --no-alert)    DO_ALERT=0; shift ;;
    --sink-dir)    [[ -n "${2:-}" ]] || die_usage "--sink-dir needs a value"; SINK_DIR="$2"; shift 2 ;;
    --quiet)       QUIET=1; shift ;;
    --json)        JSON=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             die_usage "unknown argument: $1" ;;
  esac
done

[[ "$WARN_DAYS" =~ ^[0-9]+$ ]] || die_usage "--warn-days must be a number"
[[ "$CRIT_DAYS" =~ ^[0-9]+$ ]] || die_usage "--crit-days must be a number"
(( WARN_DAYS > CRIT_DAYS )) || die_usage "--warn-days must be greater than --crit-days"
for tool in openssl date; do
  command -v "$tool" >/dev/null 2>&1 || die_usage "required tool not found: ${tool}"
done

# --- paths come from the shared resolver -----------------------------------
# An explicit --env-file is handed to the helper BEFORE it loads, so a fixture
# still wins over the ambient environment (the helper reads environment first,
# then the file).
if [[ -n "$ENV_FILE" && -z "${HYBRID_AI_ENV_FILE:-}" ]]; then
  export HYBRID_AI_ENV_FILE="$ENV_FILE"
fi
# shellcheck source=scripts/lib/hybrid-ai-env.sh
source "${SCRIPT_DIR}/lib/hybrid-ai-env.sh"

# This script reads stack settings (TLS_ENABLED and friends) and passes the same
# file to the alert hook, so it is the STACK file the helper resolved. A
# --env-file fixture set above is already the resolved HYBRID_AI_ENV_FILE, and
# HYBRID_AI_STACK_ENV_FILE defaults to it, so the fixture keeps working.
[[ -n "$ENV_FILE" ]] || ENV_FILE="$HYBRID_AI_STACK_ENV_FILE"

# --- settings: exported environment first, then the env file ---------------
# The env file is never sourced and no value is ever printed. An exported
# variable wins over the file so the caller can override without editing it.
pick() {
  local var="$1" key="$2"
  if [[ -n "${!var:-}" ]]; then printf '%s' "${!var}"; return 0; fi
  env_read_key "$ENV_FILE" "$key" || true
}

TLS_ENABLED_RAW="$(pick TLS_ENABLED TLS_ENABLED)"
TLS_HOSTS_RAW="$(pick TLS_HOSTS TLS_HOSTS)"
LOCAL_DOMAIN_RAW="$(pick LOCAL_DOMAIN LOCAL_DOMAIN)"
TLS_PROBE_RAW="$(pick TLS_PROBE_ADDR TLS_PROBE_ADDR)"

case "$(printf '%s' "$TLS_ENABLED_RAW" | tr '[:upper:]' '[:lower:]')" in
  yes|true|1|on) TLS_ENABLED=1 ;;
  *)             TLS_ENABLED=0 ;;
esac

# --- host list: --host > $TLS_HOSTS > LOCAL_DOMAIN (three hosts) ------------
declare -a HOSTS=()
if (( ${#HOST_ARGS[@]} > 0 )); then
  HOSTS=("${HOST_ARGS[@]}")
elif [[ -n "$TLS_HOSTS_RAW" ]]; then
  IFS=',' read -r -a _raw_hosts <<< "$TLS_HOSTS_RAW"
  for h in "${_raw_hosts[@]}"; do
    h="$(printf '%s' "$h" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [[ -n "$h" ]] && HOSTS+=("$h")
  done
fi

if [[ -z "$PROBE_ADDR" ]]; then
  PROBE_ADDR="$TLS_PROBE_RAW"
fi
if [[ -z "$PROBE_ADDR" ]]; then
  PROBE_ADDR="127.0.0.1:443"
fi

# The log directory is the one the helper resolved, so the watchdog's audit log
# lands beside the backups and logrotate finds it.
[[ -n "$AUDIT_LOG" ]] || AUDIT_LOG="${HYBRID_AI_LOG_DIR}/tls-check.log"

# --- TLS disabled: SKIPPED (exit 3, never an error) -------------------------
if (( ! TLS_ENABLED )); then
  if (( JSON )); then
    printf '{"enabled":false,"checked_at":"%s","overall":"missing","exit_code":3,"warn_days":%s,"crit_days":%s,"hosts":[]}\n' \
      "$(iso_now)" "$WARN_DAYS" "$CRIT_DAYS"
  else
    printf 'tls-check: SKIPPED (TLS disabled)\n'
  fi
  exit 3
fi

if (( ${#HOSTS[@]} == 0 )); then
  if [[ -n "$LOCAL_DOMAIN_RAW" ]]; then
    HOSTS=("$LOCAL_DOMAIN_RAW" "hermes.${LOCAL_DOMAIN_RAW}" "status.${LOCAL_DOMAIN_RAW}")
  else
    die_usage "no hosts to check: pass --host, set TLS_HOSTS, or set LOCAL_DOMAIN"
  fi
fi

# --- per-host probe ---------------------------------------------------------
checked_at="$(iso_now)"
overall_exit=0
declare -a JSON_HOSTS=()
declare -a SEVERITY_LINES=()

for host in "${HOSTS[@]}"; do
  connect_out=""
  verify_out=""
  cert_present=0
  chain_valid=0
  san_ok=0
  issuer=""
  not_after=""
  not_after_iso=""
  days=""
  serial=""
  host_exit=3
  severity="missing"
  note=""

  # Pass A: metadata. No verification flags, so a staging certificate is still
  # diagnosable (its days and SAN) instead of being mislabelled as unreachable.
  if command -v timeout >/dev/null 2>&1; then
    connect_out="$(timeout 20 openssl s_client -connect "$PROBE_ADDR" \
                     -servername "$host" -showcerts </dev/null 2>/dev/null || true)"
  else
    connect_out="$(openssl s_client -connect "$PROBE_ADDR" \
                     -servername "$host" -showcerts </dev/null 2>/dev/null || true)"
  fi

  leaf_pem="$(printf '%s\n' "$connect_out" | leaf_from_pem)"
  if [[ "$leaf_pem" == *"BEGIN CERTIFICATE"* && "$leaf_pem" == *"END CERTIFICATE"* ]]; then
    meta="$(printf '%s\n' "$leaf_pem" | openssl x509 -noout -nameopt RFC2253 \
              -dates -serial -issuer -ext subjectAltName 2>/dev/null || true)"
    if [[ -n "$meta" ]]; then
      cert_present=1
      not_after="$(printf '%s\n' "$meta" | sed -n 's/^notAfter=//p' | head -1)"
      serial="$(printf '%s\n' "$meta" | sed -n 's/^serial=//p' | head -1)"
      issuer="$(printf '%s\n' "$meta" | sed -n 's/^issuer=//p' | head -1)"
      not_after_iso="$(to_iso8601 "$not_after")"
      days="$(days_until "$not_after" || true)"
      san_list="$(printf '%s\n' "$meta" | awk '/Subject Alternative Name/{f=1;next} f{print}' \
                    | tr '\n' ',' | sed 's/[[:space:]]//g; s/,,*/,/g')"
      if san_match "$san_list" "$host"; then san_ok=1; fi
    fi
  fi

  # Pass B: chain verification. Non-zero or absent verify code means the chain
  # is not trusted here; the SAN and days above are still reported.
  verify_args=(-connect "$PROBE_ADDR" -servername "$host" -verify_return_error -verify_hostname "$host")
  [[ -n "$CA_FILE" ]] && verify_args+=(-CAfile "$CA_FILE")
  if command -v timeout >/dev/null 2>&1; then
    verify_out="$(timeout 20 openssl s_client "${verify_args[@]}" </dev/null 2>&1 || true)"
  else
    verify_out="$(openssl s_client "${verify_args[@]}" </dev/null 2>&1 || true)"
  fi
  verify_code="$(printf '%s\n' "$verify_out" | sed -n 's/^[[:space:]]*Verify return code:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | tail -1)"
  if [[ "$verify_code" == "0" ]]; then chain_valid=1; fi

  # --- severity, in the fixed order ---
  # Expiry is tested BEFORE chain validity on purpose: an expired certificate
  # always fails chain verification, so testing the chain first would mask the
  # actionable "expired" verdict (exit 2) behind a generic "chain not valid".
  if (( ! cert_present )); then
    host_exit=3; note="no certificate served"
  elif [[ ! "$days" =~ ^-?[0-9]+$ ]]; then
    host_exit=3; note="unparseable expiry"
  elif (( days <= 0 )); then
    host_exit=2; note="expired"
  elif (( ! chain_valid )); then
    host_exit=3; note="chain not valid"
  elif (( ! san_ok )); then
    host_exit=3; note="SAN does not cover ${host}"
  elif (( days < CRIT_DAYS )); then
    host_exit=2; note="below critical threshold"
  elif (( days < WARN_DAYS )); then
    host_exit=1; note="below warn threshold"
  else
    host_exit=0; note=""
  fi
  severity="$(severity_for_exit "$host_exit")"
  (( host_exit > overall_exit )) && overall_exit=$host_exit

  # --- audit append: one line per host per run, 0600, append only ---
  if (( DO_AUDIT )); then
    if ensure_private_file "$AUDIT_LOG"; then
      printf 'ts=%s host=%s issuer="%s" not_after=%s days=%s severity=%s exit=%s serial=%s\n' \
        "$checked_at" "$host" "$issuer" "${not_after_iso:-unknown}" "${days:-unknown}" \
        "$severity" "$host_exit" "${serial:-unknown}" >> "$AUDIT_LOG" 2>/dev/null || true
    fi
  fi

  # --- human line ---
  line="$(printf '%-32s %-8s days=%-6s not_after=%-22s issuer="%s" serial=%s thresholds: warn<%sd crit<%sd' \
            "$host" "$severity" "${days:-?}" "${not_after_iso:-?}" "$issuer" "${serial:-?}" \
            "$WARN_DAYS" "$CRIT_DAYS")"
  [[ -n "$note" ]] && line="${line} (${note})"
  SEVERITY_LINES+=("$line")

  JSON_HOSTS+=("$(jq -n \
    --arg hostname "$host" \
    --argjson certificate "$( (( cert_present )) && echo true || echo false )" \
    --argjson chain_valid "$( (( chain_valid )) && echo true || echo false )" \
    --argjson san_match "$( (( san_ok )) && echo true || echo false )" \
    --arg issuer "$issuer" \
    --arg not_after "$not_after_iso" \
    --argjson days "$( [[ "$days" =~ ^-?[0-9]+$ ]] && echo "$days" || echo -1 )" \
    --arg serial "$serial" \
    --arg severity "$severity" \
    '{hostname:$hostname, certificate:$certificate, chain_valid:$chain_valid,
      san_match:$san_match, issuer:$issuer, not_after:$not_after,
      days_to_expiry:$days, serial:$serial, severity:$severity}')")
done

overall="$(severity_for_exit "$overall_exit")"

# --- output ---------------------------------------------------------------
if (( JSON )); then
  if command -v jq >/dev/null 2>&1; then
    printf '%s\n' "${JSON_HOSTS[@]}" | jq -s \
      --arg checked_at "$checked_at" \
      --arg overall "$overall" \
      --argjson exit_code "$overall_exit" \
      --argjson warn_days "$WARN_DAYS" \
      --argjson crit_days "$CRIT_DAYS" \
      '{enabled:true, checked_at:$checked_at, overall:$overall, exit_code:$exit_code,
        warn_days:$warn_days, crit_days:$crit_days, hosts:.}'
  else
    die_usage "--json requires jq"
  fi
elif (( QUIET )); then
  i=0
  for host in "${HOSTS[@]}"; do
    if [[ "${SEVERITY_LINES[$i]}" != *" ok "* ]]; then
      printf '%s\n' "${SEVERITY_LINES[$i]}"
    fi
    i=$(( i + 1 ))
  done
  printf 'tls-check: %s host(s) checked, overall=%s exit=%s\n' \
    "${#HOSTS[@]}" "$overall" "$overall_exit"
else
  for line in "${SEVERITY_LINES[@]}"; do
    printf '%s\n' "$line"
  done
  printf 'tls-check: %s host(s) checked, overall=%s exit=%s (warn<%sd crit<%sd)\n' \
    "${#HOSTS[@]}" "$overall" "$overall_exit" "$WARN_DAYS" "$CRIT_DAYS"
fi

# --- alert on warn/critical/missing ---------------------------------------
if (( DO_ALERT )) && (( overall_exit != 0 )); then
  alert_bin="${SCRIPT_DIR}/tls-alert.sh"
  if [[ -x "$alert_bin" || -f "$alert_bin" ]]; then
    alert_args=(--severity "$overall" --env-file "$ENV_FILE"
                --subject "hybrid-ai TLS ${overall} on ${HOSTS[0]}"
                --body "tls-check overall=${overall} exit=${overall_exit} hosts=${HOSTS[*]}")
    [[ -n "$SINK_DIR" ]] && alert_args+=(--sink-dir "$SINK_DIR")
    bash "$alert_bin" "${alert_args[@]}" >/dev/null 2>&1 || true
  fi
fi

exit "$overall_exit"
