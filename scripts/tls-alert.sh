#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/tls-alert.sh
# PURPOSE (plain English):
#   Delivers one TLS health alert. This repository has no mail relay and no
#   alert webhook today, so the alert rides the host's EXISTING monitoring path:
#   systemd user timers write to journald, and doctor.sh reports by exit code.
#
# TRANSPORT A (always): one structured line on stderr, which journald captures:
#   ts=<ISO8601> source=tls severity=<warn|critical|missing|test> subject="..." body="..."
#
# TRANSPORT B (only when HYBRID_AI_ALERT_WEBHOOK_URL is set): POST the same
#   JSON body to that URL with curl. https:// only; http:// and any URL carrying
#   userinfo are refused. The URL NEVER appears in argv, in output or in a log:
#   it is handed to curl through a 0600 --config file in a private mktemp dir,
#   exactly as doctor.sh does for its RunPod key. Timeout 10s. Non-2xx is a
#   transport failure.
#
# --sink-dir DIR is the offline/test transport: append the same line to
#   DIR/tls-alert-test.log and skip the network entirely.
#
# EXIT: 0 delivered on every configured transport, 1 not delivered, 2 usage.
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

SEVERITY=""
SUBJECT=""
BODY=""
SELF_TEST=0
SINK_DIR=""
ENV_FILE="${REPO_DIR}/.env"

usage() {
  cat <<'EOF'
Usage: tls-alert.sh [options]

  --severity SEV       warn | critical | missing | test
  --subject TEXT       short subject line
  --body TEXT          alert body (or pipe it on stdin)
  --test               fire a synthetic self-test alert (severity=test)
  --sink-dir DIR       write to DIR/tls-alert-test.log instead of the network
  --env-file PATH      env file to read HYBRID_AI_ALERT_WEBHOOK_URL from
  -h, --help           this text
EOF
}

die_usage() { printf 'tls-alert: %s\n' "$1" >&2; exit 2; }

iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

env_read_key() {
  local file="$1" key="$2" v
  [[ -f "$file" && -r "$file" ]] || return 1
  v="$(grep -E "^[[:space:]]*${key}=" "$file" 2>/dev/null | tail -1 | cut -d= -f2-)"
  v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
  printf '%s' "$v"
}

# One JSON object with the same fields as the journald line.
json_body() {
  local sev="$1" subj="$2" body="$3" ts="$4"
  if command -v jq >/dev/null 2>&1; then
    jq -cn --arg ts "$ts" --arg sev "$sev" --arg subject "$subj" --arg body "$body" \
      '{ts:$ts, source:"tls", severity:$sev, subject:$subject, body:$body}'
  else
    # Minimal, correct escaping for the three fields we control.
    local e_subj e_body
    e_subj="$(printf '%s' "$subj" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    e_body="$(printf '%s' "$body" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g')"
    printf '{"ts":"%s","source":"tls","severity":"%s","subject":"%s","body":"%s"}' \
      "$ts" "$sev" "$e_subj" "$e_body"
  fi
}

while (( $# > 0 )); do
  case "$1" in
    --severity) [[ -n "${2:-}" ]] || die_usage "--severity needs a value"; SEVERITY="$2"; shift 2 ;;
    --subject)  [[ -n "${2:-}" ]] || die_usage "--subject needs a value"; SUBJECT="$2"; shift 2 ;;
    --body)     [[ -n "${2:-}" ]] || die_usage "--body needs a value"; BODY="$2"; shift 2 ;;
    --test)     SELF_TEST=1; shift ;;
    --sink-dir) [[ -n "${2:-}" ]] || die_usage "--sink-dir needs a value"; SINK_DIR="$2"; shift 2 ;;
    --env-file) [[ -n "${2:-}" ]] || die_usage "--env-file needs a value"; ENV_FILE="$2"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    *)          die_usage "unknown argument: $1" ;;
  esac
done

if (( SELF_TEST )); then
  SEVERITY="test"
  [[ -n "$SUBJECT" ]] || SUBJECT="hybrid-ai TLS alert self-test"
fi

[[ -n "$SEVERITY" ]] || die_usage "--severity is required"
case "$SEVERITY" in warn|critical|missing|test) ;; *) die_usage "invalid severity: $SEVERITY" ;; esac

if [[ -z "$BODY" && ! -t 0 ]]; then
  BODY="$(cat)"
fi
if (( SELF_TEST )); then
  [[ -n "$BODY" ]] || BODY="Synthetic alert from scripts/tls-alert.sh; every configured transport was exercised."
fi
[[ -n "$SUBJECT" ]] || die_usage "--subject is required"
[[ -n "$BODY" ]] || die_usage "--body (or stdin) is required"

TS="$(iso_now)"
LINE="$(printf 'ts=%s source=tls severity=%s subject="%s" body="%s"' \
          "$TS" "$SEVERITY" "$SUBJECT" "${BODY//$'\n'/ }")"

attempted=()
results=()
failed=0

# --- transport A: journald (stderr) ---------------------------------------
printf '%s\n' "$LINE" >&2
attempted+=("journald")
results+=("journald=delivered")

# --- transport sink-dir: offline/test -------------------------------------
if [[ -n "$SINK_DIR" ]]; then
  if ! mkdir -p "$SINK_DIR" 2>/dev/null; then
    attempted+=("sink-dir")
    results+=("sink-dir=failed (cannot create ${SINK_DIR})")
    failed=1
  else
    sink_file="${SINK_DIR}/tls-alert-test.log"
    if printf '%s\n' "$LINE" >> "$sink_file" 2>/dev/null; then
      attempted+=("sink-dir")
      results+=("sink-dir=delivered (${sink_file})")
    else
      attempted+=("sink-dir")
      results+=("sink-dir=failed (cannot append to ${sink_file})")
      failed=1
    fi
  fi
else
  # --- transport B: webhook (network) ------------------------------------
  webhook="$(env_read_key "$ENV_FILE" HYBRID_AI_ALERT_WEBHOOK_URL || true)"
  if [[ -z "$webhook" ]]; then
    attempted+=("webhook")
    results+=("webhook=not-configured")
  else
    attempted+=("webhook")
    case "$webhook" in
      https://*) : ;;
      *) results+=("webhook=refused (URL must be https://)")
         failed=1 ; webhook="" ;;
    esac
    if [[ -n "$webhook" ]]; then
      # userinfo (anything before '@' in the authority) is refused: a credential
      # in a URL would end up in a config file and could leak into a log line.
      authority="${webhook#https://}"
      authority="${authority%%/*}"
      if [[ "$authority" == *"@"* ]]; then
        results+=("webhook=refused (URL must not carry userinfo)")
        failed=1
        webhook=""
      elif [[ -z "$authority" ]]; then
        results+=("webhook=refused (URL has no host)")
        failed=1
        webhook=""
      fi
    fi
    if [[ -n "$webhook" ]]; then
      if ! command -v curl >/dev/null 2>&1; then
        results+=("webhook=failed (curl not installed)")
        failed=1
      else
        payload="$(json_body "$SEVERITY" "$SUBJECT" "$BODY" "$TS")"
        tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/hybrid-ai-tls-alert.XXXXXX" 2>/dev/null)"
        if [[ -z "$tmpdir" ]]; then
          results+=("webhook=failed (no writable temp directory)")
          failed=1
        else
          cfg="${tmpdir}/curl.cfg"
          bodyfile="${tmpdir}/body.json"
          # An env value carrying a control character could inject a config
          # directive; escape so the URL stays a single literal.
          safe_url="${webhook//[[:cntrl:]]/}"
          safe_url="${safe_url//\\/\\\\}"
          safe_url="${safe_url//\"/\\\"}"
          if ( umask 077; : > "$cfg" ) 2>/dev/null \
             && printf 'url = "%s"\n' "$safe_url" > "$cfg" 2>/dev/null \
             && printf 'header = "Content-Type: application/json"\n' >> "$cfg" 2>/dev/null \
             && printf '%s' "$payload" > "$bodyfile" 2>/dev/null; then
            code="$(curl -sS --config "$cfg" --data-binary "@${bodyfile}" \
                       -o /dev/null --max-time 10 -w '%{http_code}' 2>/dev/null)"
            rc=$?
            case "$code" in
              2??) results+=("webhook=delivered (HTTP ${code})") ;;
              000|"") results+=("webhook=failed (unreachable, curl exit ${rc})"); failed=1 ;;
              *)   results+=("webhook=failed (HTTP ${code})"); failed=1 ;;
            esac
          else
            results+=("webhook=failed (cannot write a private curl config)")
            failed=1
          fi
          rm -rf "$tmpdir"
        fi
      fi
    fi
  fi
fi

if (( SELF_TEST )); then
  printf 'tls-alert: self-test attempted: %s\n' "${attempted[*]}" >&2
  for r in "${results[@]}"; do printf 'tls-alert:   %s\n' "$r" >&2; done
fi

if (( failed )); then
  exit 1
fi
exit 0
