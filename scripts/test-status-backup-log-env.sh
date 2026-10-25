#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/test-status-backup-log-env.sh
# PURPOSE (plain English):
#   Offline fixture test for the BACKUP_LOG line in install.sh's STEP 8 .env
#   template. No root, no Docker, no network: every host command install.sh
#   probes is stubbed on PATH, and the whole run is pointed at a scratch
#   app/data/log tree with --no-start so install.sh writes the env file and
#   stops before touching Docker.
#
#   WHY THIS EXISTS: docker-compose.yml now builds the status service's
#   read-only backup-log mount from ${BACKUP_LOG:?...}, so the mount source is
#   whatever scripts/lib/hybrid-ai-env.sh resolved. docker-compose.yml used to
#   mount ${HYBRID_AI_LOG_DIR}/backup.log unconditionally, which in SYSTEM mode
#   is a file nothing writes: the units append to their LogsDirectory=
#   (/var/log/hybrid-ai-backup/backup.log). The status page therefore said
#   "no successful backup recorded" forever on a host whose backups worked.
#   STEP 8 now writes the RESOLVED value
#     BACKUP_LOG=${BACKUP_LOG}
#   so the reader (status container) and the writer (units or backup.sh) name
#   one path, and an owner override survives every reinstall.
#
# CASES:
#   (a) user mode, unset     -> <log dir>/backup.log is written, i.e. exactly
#                               the path the old compose expression rendered
#   (b) system mode, unset   -> /var/log/hybrid-ai-backup/backup.log is written
#   (c) system mode, owner-set value in the stack env file -> preserved
#                               byte-for-byte, and again on a second run
#   (d) user mode, owner-set value -> preserved byte-for-byte
#
#   Against an install.sh without the template line the key is absent from the
#   written .env, so every case fails.
#
# USAGE:
#   bash scripts/test-status-backup-log-env.sh
#
# EXIT CODES:
#   0  every case passed
#   1  one or more cases failed
#   2  a required tool is missing
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
[[ -f "${REPO}/install.sh" ]] || { echo "FATAL: cannot find install.sh" >&2; exit 2; }
for t in mktemp stat grep; do
  command -v "$t" >/dev/null 2>&1 || { echo "error: $t is required" >&2; exit 2; }
done

SYSTEM_LOG="/var/log/hybrid-ai-backup/backup.log"
OVER="$(mktemp -d)/owner-backup.log"

PASS=0
FAIL=0
ok()   { PASS=$(( PASS + 1 )); printf 'ok   %s\n' "$*"; }
bad()  { FAIL=$(( FAIL + 1 )); printf 'FAIL %s\n' "$*" >&2; }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi; }

WORK="$(mktemp -d)"
if [[ "${KEEP:-0}" == "1" ]]; then
  printf 'keeping %s\n' "$WORK"
else
  trap 'rm -rf -- "$WORK"' EXIT
fi

# --- scratch app + layout ----------------------------------------------------
APP="$WORK/app"
BIN="$WORK/bin"
mkdir -p "$APP/scripts/lib" "$BIN" "$WORK/data" "$WORK/log" "$WORK/work" \
         "$WORK/ws" "$WORK/repos" "$WORK/ohstate" "$WORK/conf" "$WORK/restic" \
         "$WORK/etc/hybrid-ai" "$WORK/ws/.git/info"
cp "$REPO/install.sh" "$APP/install.sh"
cp "$REPO/scripts/lib/hybrid-ai-env.sh" "$APP/scripts/lib/"
[ -f "$REPO/scripts/lib/build-gate.sh" ] || { echo "FATAL: scripts/lib/build-gate.sh is missing; the build gate does not exist in this tree." >&2; exit 2; }
cp "$REPO/scripts/lib/build-gate.sh" "$APP/scripts/lib/"
printf '#!/usr/bin/env bash\nexit 0\n' > "$APP/scripts/setup-agent-workspace.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$APP/scripts/sync-agent-repos.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$APP/scripts/check-hermes-nonroot.sh"
chmod +x "$APP/scripts/"*.sh

LAYOUT="$WORK/etc/hybrid-ai/hybrid-ai.env"
STACK="$WORK/etc/hybrid-ai/stack.env"
write_layout() { # mode
  {
    printf 'HYBRID_AI_APP_DIR=%s\n' "$APP"
    printf 'HYBRID_AI_ENV_FILE=%s\n' "$LAYOUT"
    printf 'HYBRID_AI_STACK_ENV_FILE=%s\n' "$STACK"
    printf 'HYBRID_AI_DATA_DIR=%s\n' "$WORK/data"
    printf 'HYBRID_AI_LOG_DIR=%s\n' "$WORK/log"
    printf 'HYBRID_AI_WORK_DIR=%s\n' "$WORK/work"
    printf 'OPENHANDS_WORKSPACE=%s\n' "$WORK/ws"
    printf 'AGENT_REPOS_DIR=%s\n' "$WORK/repos"
    printf 'OPENHANDS_STATE_DIR=%s\n' "$WORK/ohstate"
    printf 'BACKUP_CONF_DIR=%s\n' "$WORK/conf"
    printf 'RESTIC_CACHE_DIR=%s\n' "$WORK/restic"
    printf 'HYBRID_AI_HERMES_HOME_DIR=%s\n' "$WORK/hermes"
    printf 'HYBRID_AI_BACKUP_MODE=%s\n' "$1"
    printf 'BACKUP_CONTAINER_CONTROL=external\n'
    printf 'HYBRID_AI_UID=1000\n'
    printf 'HYBRID_AI_GID=1000\n'
  } > "$LAYOUT"
  chmod 644 "$LAYOUT"
}

# --- stubs -------------------------------------------------------------------
for d in docker git jq openssl sqlite3 rsync tailscale hostname nproc \
         loginctl setfacl apt-get sudo restic; do
  # shellcheck disable=SC2016  # $0 must expand inside the generated stub
  printf '#!/usr/bin/env bash\nprintf "%%s stub\\n" "$0"\nexit 0\n' > "$BIN/$d"
done
# shellcheck disable=SC2016  # $@ must expand inside the generated stub
printf '#!/usr/bin/env bash\nif [[ "${1:-}" == "-u" ]]; then printf "1000\\n"; exit 0; fi\nif [[ "${1:-}" == "-g" ]]; then printf "1000\\n"; exit 0; fi\nexec /usr/bin/id "$@"\n' > "$BIN/id"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/chown"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/sleep"
cat > "$BIN/getent" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  group) printf 'docker:x:999:\n' ;;
  hosts) printf '[IP_ADDRESS] %s\n' "${2:-}" ;;
esac
exit 0
EOF
cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$BIN"/*

run_install() { # log
  local log="$1" rc=0
  env -u HYBRID_AI_APP_DIR -u HYBRID_AI_DATA_DIR -u HYBRID_AI_LOG_DIR \
      -u HYBRID_AI_WORK_DIR -u HYBRID_AI_STACK_ENV_FILE \
      -u OPENHANDS_WORKSPACE -u AGENT_REPOS_DIR -u OPENHANDS_STATE_DIR \
      -u BACKUP_CONF_DIR -u RESTIC_CACHE_DIR -u HYBRID_AI_HERMES_HOME_DIR \
      -u HYBRID_AI_BACKUP_MODE -u BACKUP_CONTAINER_CONTROL \
      -u HYBRID_AI_UID -u HYBRID_AI_GID -u HYBRID_AI_LAYOUT_UID -u HYBRID_AI_LAYOUT_GID \
      -u BACKUP_LOG \
      PATH="$BIN:$PATH" \
      HYBRID_AI_ENV_FILE="$LAYOUT" \
      LOCAL_DOMAIN=example.test OPENROUTER_API_KEY=stub RUNPOD_API_KEY=stub \
      RUNPOD_POD_ID=stub RUNPOD_HOST=stub PI_HOST=stub \
      OPENHANDS_SANDBOX_HOST=example.test PEER_HOSTNAMES="none" \
      USER=fixture \
      bash "$APP/install.sh" --non-interactive --no-start >> "$log" 2>&1 || rc=$?
  return "$rc"
}

env_value() { # file key
  grep -E "^$2=" "$1" 2>/dev/null | head -n1 | cut -d= -f2-
}

LOG="$WORK/install.log"

# ---------------------------------------------------------------------------
echo "== (a) user mode writes <log dir>/backup.log, the old compose path =="
write_layout user
: > "$LOG"
rm -f "$STACK"
rc=0
run_install "$LOG" || rc=$?
check "install.sh exits 0 with --no-start" "0" "$rc"
check "the user-mode backup log path was written" \
      "$WORK/log/backup.log" "$(env_value "$STACK" BACKUP_LOG)"

# ---------------------------------------------------------------------------
echo
echo "== (b) system mode writes the units' LogsDirectory= path =="
write_layout system
: > "$LOG"
rm -f "$STACK"
rc=0
run_install "$LOG" || rc=$?
check "install.sh exits 0 in system mode" "0" "$rc"
check "the system-mode backup log path was written" \
      "$SYSTEM_LOG" "$(env_value "$STACK" BACKUP_LOG)"

# ---------------------------------------------------------------------------
echo
echo "== (c) a system-mode owner override is preserved across reruns =="
: > "$LOG"
{
  printf 'BACKUP_LOG=%s\n' "$OVER"
} > "$STACK"
chmod 600 "$STACK"
rc=0
run_install "$LOG" || rc=$?
check "install.sh exits 0 with an override" "0" "$rc"
check "the owner override survived the rewrite" "$OVER" "$(env_value "$STACK" BACKUP_LOG)"
: > "$LOG"
rc=0
run_install "$LOG" || rc=$?
check "a second run exits 0" "0" "$rc"
check "the override is unchanged on the second run" "$OVER" "$(env_value "$STACK" BACKUP_LOG)"

# ---------------------------------------------------------------------------
echo
echo "== (d) a user-mode owner override is preserved byte-for-byte =="
write_layout user
: > "$LOG"
{
  printf 'BACKUP_LOG=%s\n' "$OVER"
} > "$STACK"
chmod 600 "$STACK"
rc=0
run_install "$LOG" || rc=$?
check "install.sh exits 0 with a user-mode override" "0" "$rc"
check "the user-mode override survived the rewrite" "$OVER" "$(env_value "$STACK" BACKUP_LOG)"

# ---------------------------------------------------------------------------
echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
