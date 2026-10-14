#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/check-hermes-nonroot.sh
# PURPOSE (plain English):
#   Preflight gate for running the Hermes image as a dedicated non-root uid.
#   It is deliberately a NO-OP unless HYBRID_AI_UID is set and non-zero, so an
#   existing host that still runs Hermes as uid 0 behaves exactly as before.
#
#   When HYBRID_AI_UID is set and non-zero it refuses (exit non-zero, with a
#   clear message) if either:
#     * the uid does not resolve to an account whose shell is nologin/false AND
#       whose uid is below UID_MIN (read from /etc/login.defs); or
#     * the hermes_data directory contains entries not owned by that uid. It
#       reports a COUNT only -- never a name.
#
#   It is read-only: it changes nothing, starts nothing, and needs no sudo.
#
# USAGE:
#   scripts/check-hermes-nonroot.sh
#
# ENVIRONMENT:
#   HYBRID_AI_UID         the target non-root uid. Unset/empty/0 -> no-op.
#   HYBRID_AI_GID         not required here (informational only).
#   HERMES_DATA_DIR       the host data directory (default: hermes_data).
#   LOGIN_DEFS            path to login.defs (default: /etc/login.defs).
#
# EXIT CODES:
#   0  no-op (unset/0), or the configured uid passes every check
#   1  the configured uid fails a check (refuse)
# ---------------------------------------------------------------------------
set -uo pipefail

HYBRID_AI_UID="${HYBRID_AI_UID:-}"
HERMES_DATA_DIR="${HERMES_DATA_DIR:-hermes_data}"
LOGIN_DEFS="${LOGIN_DEFS:-/etc/login.defs}"

err() { printf '[ X ] %s\n' "$*" >&2; }

# No-op unless a real, non-zero uid is configured.
if [[ -z "$HYBRID_AI_UID" || "$HYBRID_AI_UID" == "0" ]]; then
  exit 0
fi

if [[ ! "$HYBRID_AI_UID" =~ ^[0-9]+$ ]]; then
  err "HYBRID_AI_UID='${HYBRID_AI_UID}' is not a numeric uid."
  exit 1
fi

# --- 1. The uid must be a system service account -----------------------------
PASSWD_ENTRY="$(getent passwd "$HYBRID_AI_UID" 2>/dev/null || true)"
if [[ -z "$PASSWD_ENTRY" ]]; then
  err "HYBRID_AI_UID=${HYBRID_AI_UID} does not resolve to an account (getent passwd)."
  err "Create the 'hermes' service account before starting the stack."
  exit 1
fi

# passwd field 7 is the login shell.
ACCOUNT_SHELL="$(printf '%s' "$PASSWD_ENTRY" | cut -d: -f7)"
case "$ACCOUNT_SHELL" in
  */nologin|*/false) ;;
  *)
    err "HYBRID_AI_UID=${HYBRID_AI_UID} resolves to an account with login shell '${ACCOUNT_SHELL}'."
    err "The Hermes service account must be a no-login account (shell nologin or false)."
    exit 1
    ;;
esac

UID_MIN="$(awk '/^[[:space:]]*UID_MIN/ {print $2; exit}' "$LOGIN_DEFS" 2>/dev/null || true)"
if [[ -z "$UID_MIN" || ! "$UID_MIN" =~ ^[0-9]+$ ]]; then
  err "Could not read UID_MIN from '${LOGIN_DEFS}'."
  exit 1
fi
if (( HYBRID_AI_UID >= UID_MIN )); then
  err "HYBRID_AI_UID=${HYBRID_AI_UID} is not below UID_MIN=${UID_MIN} (not a system account)."
  exit 1
fi

# --- 2. hermes_data must be owned by that uid (count only, never names) ------
if [[ -d "$HERMES_DATA_DIR" ]]; then
  FOREIGN="$(find "$HERMES_DATA_DIR" ! -uid "$HYBRID_AI_UID" 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${FOREIGN:-0}" -gt 0 ]]; then
    err "hermes_data has ${FOREIGN} entr(ies) not owned by uid ${HYBRID_AI_UID}."
    err "Fix ownership before starting, e.g.: sudo chown -R ${HYBRID_AI_UID}:${HYBRID_AI_UID} ${HERMES_DATA_DIR}"
    exit 1
  fi
fi

printf '[ OK ] HYBRID_AI_UID=%s is a system account and hermes_data is owned by it.\n' "$HYBRID_AI_UID"
exit 0
