#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/tls-dry-run-renewal.sh
# PURPOSE (plain English):
#   Proves the whole renewal-and-watchdog chain works end to end, using
#   Let's Encrypt STAGING ONLY.
#
#   This never runs against production and consumes no production rate limit.
#   Staging issuance is untrusted and repeatable, which is exactly what a test
#   needs. The script refuses to run when ACME_CA is anything other than a
#   staging directory -- there is deliberately NO --force override, because a
#   forced production reissue would burn a real rate limit.
#
#   --check-only does the preflight and changes nothing (docker present, compose
#   file present, staging CA, certificate root readable, proxy container name).
#   That is the mode the offline test exercises.
#
#   A FULL RUN requires --yes and then, in order:
#     1. record the current certificate serial
#     2. move the host's cert directory aside to <cert-root>/staging-hold/<host>.<epoch>
#        (a forced reissue needs Caddy to see NO managed certificate)
#     3. `docker compose restart proxy`  -- ALLOWED ONLY HERE, nowhere else
#     4. wait up to 180s for a certificate whose serial differs
#     5. run scripts/tls-audit.sh so the renewal is recorded
#     6. run scripts/tls-check.sh to confirm the served certificate is healthy
#   On any failure the held directory is restored and the script exits 1.
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

ENV_FILE="${REPO_DIR}/.env"
CHECK_ONLY=0
ASSUME_YES=0
HOST=""
CERT_ROOT=""
COMPOSE_FILE="${REPO_DIR}/docker-compose.yml"
PROXY_SERVICE="proxy"
WAIT_SECONDS=180

usage() {
  cat <<'EOF'
Usage: tls-dry-run-renewal.sh [options]

  --check-only       preflight only; changes nothing
  --yes              required for a full (staging) renewal run
  --host HOST        hostname to reissue (default: LOCAL_DOMAIN from the env file)
  --env-file PATH    env file to read ACME_CA and LOCAL_DOMAIN from
  --cert-root PATH   Caddy managed certificate root
  --compose-file P   compose file (default <repo>/docker-compose.yml)
  --proxy-service S  proxy service name (default: proxy)
  -h, --help         this text
EOF
}

die_usage() { printf 'tls-dry-run-renewal: %s\n' "$1" >&2; exit 2; }
note() { printf 'tls-dry-run-renewal: %s\n' "$1"; }
fail() { printf 'tls-dry-run-renewal: FAIL: %s\n' "$1" >&2; }

env_read_key() {
  local file="$1" key="$2" v
  [[ -f "$file" && -r "$file" ]] || return 1
  v="$(grep -E "^[[:space:]]*${key}=" "$file" 2>/dev/null | tail -1 | cut -d= -f2-)"
  v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
  printf '%s' "$v"
}

while (( $# > 0 )); do
  case "$1" in
    --check-only)    CHECK_ONLY=1; shift ;;
    --yes)           ASSUME_YES=1; shift ;;
    --host)          [[ -n "${2:-}" ]] || die_usage "--host needs a value"; HOST="$2"; shift 2 ;;
    --env-file)      [[ -n "${2:-}" ]] || die_usage "--env-file needs a value"; ENV_FILE="$2"; shift 2 ;;
    --cert-root)     [[ -n "${2:-}" ]] || die_usage "--cert-root needs a value"; CERT_ROOT="$2"; shift 2 ;;
    --compose-file)  [[ -n "${2:-}" ]] || die_usage "--compose-file needs a value"; COMPOSE_FILE="$2"; shift 2 ;;
    --proxy-service) [[ -n "${2:-}" ]] || die_usage "--proxy-service needs a value"; PROXY_SERVICE="$2"; shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    *)               die_usage "unknown argument: $1" ;;
  esac
done

# --- staging-only gate (no override, by design) ----------------------------
ACME_CA_VAL="$(env_read_key "$ENV_FILE" ACME_CA || true)"
PROD_CA="acme-v02.api.letsencrypt.org"

if [[ -z "$ACME_CA_VAL" ]]; then
  fail "ACME_CA is unset. This script only runs against Let's Encrypt STAGING (a directory whose name contains 'acme-staging'). Refusing."
  exit 2
fi
if [[ "$ACME_CA_VAL" == *"$PROD_CA"* ]]; then
  fail "ACME_CA points at the PRODUCTION directory (${PROD_CA}). A staging dry-run must never touch production rate limits. Refusing."
  exit 2
fi
case "${ACME_CA_VAL,,}" in
  *acme-staging*) : ;;
  *)
    fail "ACME_CA does not name a staging directory (expected a path containing 'acme-staging'). Refusing."
    exit 2 ;;
esac

if [[ -z "$CERT_ROOT" ]]; then
  CERT_ROOT="${HYBRID_AI_DATA_DIR:-${REPO_DIR}/data}/webui_data/caddy/caddy/certificates"
fi
if [[ -z "$HOST" ]]; then
  HOST="$(env_read_key "$ENV_FILE" LOCAL_DOMAIN || true)"
fi
if [[ -z "$HOST" ]]; then
  fail "no host: pass --host or set LOCAL_DOMAIN in the env file."
  exit 2
fi

# --- preflight (shared by --check-only and the full run) -------------------
preflight_failed=0

if ! command -v docker >/dev/null 2>&1; then
  fail "docker is not installed or not on PATH."
  preflight_failed=1
else
  note "preflight: docker present ($(command -v docker))"
fi

if [[ ! -f "$COMPOSE_FILE" ]]; then
  fail "compose file not found: ${COMPOSE_FILE}"
  preflight_failed=1
else
  note "preflight: compose file present (${COMPOSE_FILE})"
fi

note "preflight: ACME_CA is a staging directory"
note "preflight: proxy service name is '${PROXY_SERVICE}'"

if [[ ! -d "$CERT_ROOT" ]]; then
  fail "certificate root is not readable/missing: ${CERT_ROOT}"
  preflight_failed=1
else
  note "preflight: certificate root readable (${CERT_ROOT})"
fi

if (( preflight_failed )); then
  if (( CHECK_ONLY )); then
    # check-only reports the gap and changes nothing.
    exit 1
  fi
  fail "preflight failed; nothing changed."
  exit 1
fi

if (( CHECK_ONLY )); then
  note "check-only: preflight passed; nothing was changed."
  exit 0
fi

if (( ! ASSUME_YES )); then
  fail "a full staging renewal needs --yes. Nothing changed."
  exit 2
fi

# --- locate the managed certificate for HOST ------------------------------
find_crt() {
  local h="$1" f
  f="$(find "$CERT_ROOT" -maxdepth 3 -type f -name "${h}.crt" 2>/dev/null | head -1)"
  printf '%s' "$f"
}

read_serial() {
  local f="$1"
  [[ -n "$f" && -f "$f" ]] || return 1
  openssl x509 -in "$f" -noout -serial 2>/dev/null | sed -n 's/^serial=//p' | head -1
}

CRT_PATH="$(find_crt "$HOST")"
BEFORE_SERIAL="$(read_serial "$CRT_PATH" || true)"
if [[ -z "$BEFORE_SERIAL" ]]; then
  note "no managed certificate found for ${HOST} under ${CERT_ROOT}"
fi
note "serial before: ${BEFORE_SERIAL:-none}"

HOST_DIR=""
if [[ -n "$CRT_PATH" ]]; then
  HOST_DIR="$(dirname -- "$CRT_PATH")"
fi

HOLD_ROOT="${CERT_ROOT}/staging-hold"
STAMP="$(date -u +%s)"
HELD_DIR=""
restore_hold() {
  if [[ -n "$HELD_DIR" && -d "$HELD_DIR" && -n "$HOST_DIR" ]]; then
    rm -rf "$HOST_DIR"
    mv "$HELD_DIR" "$HOST_DIR" 2>/dev/null || true
    note "restored held certificate directory to ${HOST_DIR}"
  fi
}

if [[ -n "$HOST_DIR" && -d "$HOST_DIR" ]]; then
  mkdir -p "$HOLD_ROOT" || { fail "cannot create ${HOLD_ROOT}"; exit 1; }
  HELD_DIR="${HOLD_ROOT}/${HOST}.${STAMP}"
  if ! mv "$HOST_DIR" "$HELD_DIR"; then
    fail "cannot move ${HOST_DIR} aside; nothing changed."
    exit 1
  fi
  note "moved certificate directory aside to ${HELD_DIR}"
fi

# --- restart the proxy so Caddy sees no managed certificate ---------------
# THIS IS THE ONLY PLACE IN THIS REPOSITORY THAT RESTARTS THE PROXY, and it is
# gated behind the staging CA check plus --yes above.
note "restarting proxy (staging only)..."
if ! docker compose -f "$COMPOSE_FILE" restart "$PROXY_SERVICE" >/dev/null 2>&1; then
  fail "docker compose restart ${PROXY_SERVICE} failed."
  restore_hold
  exit 1
fi

# --- wait for a certificate whose serial differs --------------------------
deadline=$(( $(date -u +%s) + WAIT_SECONDS ))
AFTER_SERIAL=""
while (( $(date -u +%s) < deadline )); do
  AFTER_CRT="$(find_crt "$HOST")"
  AFTER_SERIAL="$(read_serial "$AFTER_CRT" || true)"
  if [[ -n "$AFTER_SERIAL" && "$AFTER_SERIAL" != "$BEFORE_SERIAL" ]]; then
    break
  fi
  sleep 5
done

if [[ -z "$AFTER_SERIAL" || "$AFTER_SERIAL" == "$BEFORE_SERIAL" ]]; then
  fail "no new certificate appeared within ${WAIT_SECONDS}s (serial still ${AFTER_SERIAL:-none})."
  restore_hold
  exit 1
fi
note "serial after: ${AFTER_SERIAL}"

# --- record the renewal and confirm the served certificate is healthy -----
note "recording the renewal with scripts/tls-audit.sh ..."
if ! bash "${SCRIPT_DIR}/tls-audit.sh" --cert-root "$CERT_ROOT"; then
  fail "tls-audit.sh reported a problem after the renewal."
  restore_hold
  exit 1
fi

note "confirming the served certificate with scripts/tls-check.sh ..."
if ! bash "${SCRIPT_DIR}/tls-check.sh" --host "$HOST" --env-file "$ENV_FILE" --quiet; then
  fail "tls-check.sh did not report a healthy certificate for ${HOST}."
  restore_hold
  exit 1
fi

printf 'tls-dry-run-renewal: PASS (serial %s -> %s)\n' "${BEFORE_SERIAL:-none}" "$AFTER_SERIAL"
exit 0
