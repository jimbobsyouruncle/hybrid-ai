#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: backup/backup.sh
# PURPOSE (plain English):
#   Backs up everything you would be upset to lose -- your chat history, your
#   uploaded documents, the vector database that makes document search
#   work, Hermes Agent memories, and OpenHands configuration -- to Cloudflare
#   R2, encrypted before it ever leaves the Pi.
#
#   It runs automatically every night via a systemd timer. You can also run it
#   by hand at any time.
#
# WHY RESTIC:
#   - Encrypts on the Pi. Cloudflare stores ciphertext and cannot read it.
#   - Deduplicates at block level, so the second backup of a 2 GB database
#     uploads only the few MB that actually changed.
#   - Keeps snapshots, so you can go back to "last Tuesday", not just "latest".
#
# WHY CLOUDFLARE R2:
#   - No egress fees. Restoring 50 GB costs nothing in bandwidth, which is
#     exactly when you least want a surprise bill.
#   - Roughly $0.015/GB/month stored. A typical setup costs pennies.
#
# THE HARD PART -- WHY WE DO NOT JUST COPY THE FILES:
#   Open WebUI keeps its data in SQLite and ChromaDB keeps vectors in SQLite.
#   Copying a SQLite file while the application is writing to it produces a
#   CORRUPT copy. It will look fine. It will back up without error. It will
#   fail to open when you finally need it.
#
#   So this script does NOT copy the live database files directly. When the
#   stack can be paused (see CONTAINER CONTROL), it copies each database plus
#   its sidecars into staging WITHOUT opening the live files, then checkpoint
#   and quick_check the STAGED copy. When pausing is impossible it uses
#   SQLite's online backup ('.backup'). Either way the live files are excluded
#   from the upload. VACUUM INTO is never used: its only destination mechanism
#   splices the path into SQL text, and the paths come from container data.
#
# UNTRUSTED PATHS:
#   Every path discovered under hermes_data is written by the Hermes container
#   and is therefore attacker-controlled. Before such a path reaches any copy
#   or sqlite3 call it must pass the allow-list in valid_rel_path. A rejected
#   path is never touched; it is counted and it makes the run INCOMPLETE.
#
# INCOMPLETE RUNS:
#   If durable state could not be captured (a rejected path, an unreadable
#   entry, a partial rsync, an unverifiable database) the run still uploads
#   what it has -- but it is tagged complete:false, logs backup_incomplete, and
#   exits EXIT_INCOMPLETE (3). A run that aborts outright still logs
#   backup_failed and exits 1. Do not confuse the two.
#
# EXIT CODES:
#   0  everything durable was captured and uploaded.
#   1  the run ABORTED: missing/unreadable credentials, a restic failure, an
#      uninitialised repository, a --check integrity failure, or a failure to
#      cd into the repo. This is the only status the backup service retries.
#   2  a usage error (an unknown argument).
#   3  the run finished but MISSED durable state (INCOMPLETE): a rejected path,
#      an unreadable data tree, a partial rsync, an uncapturable database. It
#      is never retried. A spurious or partial capture must never exit 0, so
#      every such case funnels through the EXIT_INCOMPLETE path below.
#
# DATA PERMISSIONS:
#   HYBRID_AI_UID (when set) makes the stack write hermes_data as that uid. If
#   this backup runs as a different account it may not be able to read that
#   tree at all. The preflight in stage_backup detects that BEFORE any container
#   is touched: it logs backup_data_unreadable with both uids, marks the run
#   INCOMPLETE, and stops nothing. Run the backup as the account that owns the
#   data, or grant this account read access to it.
#
# CONTAINER CONTROL:
#   Containers are paused/stopped by CONTAINER NAME with plain docker
#   commands, never via 'docker compose'. hermes-agent lives in an overlay
#   compose file, so a compose call without every -f file cannot see it and
#   fails silently -- which once meant the "cold copy" ran against live DBs.
#   Anything this script pauses or stops is resumed by the EXIT trap, even if
#   the script fails part-way.
#
#   The cold-copy fallback stops ONLY the containers a failed database needs.
#   hermes-agent is stopped ONLY when BACKUP_ALLOW_AGENT_STOP=1 is set, because
#   stopping it kills in-flight agent sessions; without that flag the cold copy
#   declines, the database stays out of the snapshot, and the run is INCOMPLETE
#   (exit 3) -- never a retry loop that stops the stack every 15 minutes.
#
# WHAT GETS BACKED UP (staging paths are relative to the repo directory):
#   - databases/   Consistent SQLite snapshots, discovered at run time. Covers
#                  every Open WebUI / Chroma database under webui_data and every
#                  Hermes SQLite database under hermes_data (state.db, kanban.db,
#                  cron/*.db, per-profile state across profiles/*).
#   - files/       Uploads, non-DB vector data, and the WHOLE durable
#                  hermes_data tree minus rebuildable/volatile content (see the
#                  HERMES_EXCLUDES array). Captured by exclusion, not by an
#                  allow-list, so new durable state is never silently missed.
#   - hermes/      Durable ~/.hermes state (caches/runtimes excluded)
#   - openhands/   ~/.openhands state (cache/tmp/logs excluded)
#   - host/        Compose files, scripts, Caddyfile, model list, metadata
#   - env/         Your .env configuration
#
# WHAT DOES NOT:
#   - ollama_data/ -- model weights, tens of GB, freely re-downloadable.
#
# USAGE:
#   ./backup.sh                    run a backup now
#   ./backup.sh --check            verify repository integrity (slow)
#   ./backup.sh --init             create the repository (first-time setup)
#   ./backup.sh --dry-run          show what would be backed up, upload nothing
#   ./backup.sh --non-interactive  never prompt (used by the systemd timer)
#   ./backup.sh --stage-only       capture only: no credentials, keep staging,
#                                  write STAGING_DIR/STATUS, exit 0 or 3
#   ./backup.sh --upload-only      upload only: never reads a data tree, refuses
#                                  without STAGING_DIR/STATUS, exit 0 or 3
#
# STAGE AND UPLOAD AS SEPARATE UNITS:
#   The split lets the capture run with read-only data access, no network and no
#   credentials, while the upload run holds the R2 credentials and network but
#   no read privilege. The two share only STAGING_DIR and its STATUS file.
#
# CONTAINER CONTROL:
#   BACKUP_CONTAINER_CONTROL=external means this script runs NO docker command
#   at all. A root helper (backup/backup-containers.sh) pauses the containers
#   and records which were paused in /run/hybrid-ai-backup/paused; this script
#   reads that file for CONSISTENCY and copies host metadata from
#   /run/hybrid-ai-backup/host-info/. The cold-copy fallback is declined (the
#   run is INCOMPLETE, exactly as for an unreadable tree). The default, auto,
#   keeps today's behaviour.
#
# CREDENTIALS:
#   When $CREDENTIALS_DIRECTORY is set (systemd LoadCredential), r2.env and
#   repo-password are read from it with the same parser and the same required
#   keys. Otherwise they are read from BACKUP_CONF_DIR as today.
# ---------------------------------------------------------------------------
set -Eeuo pipefail

# Every host path comes from the ONE shared helper. With no settings, the
# resolved paths are exactly today's.
HYBRID_AI_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../scripts/lib" && pwd)"
# shellcheck source=scripts/lib/hybrid-ai-env.sh
source "${HYBRID_AI_LIB_DIR}/hybrid-ai-env.sh"
cd "$HYBRID_AI_APP_DIR" || exit 1

# Credentials live OUTSIDE the git repository so that no git operation and no
# careless 'tar czf' of the project folder can ever sweep them up. In system
# mode systemd sets $CREDENTIALS_DIRECTORY (LoadCredential); read them from
# there, or from BACKUP_CONF_DIR as today.
CREDENTIALS_SOURCE_DIR="${CREDENTIALS_DIRECTORY:-$BACKUP_CONF_DIR}"
R2_ENV_FILE="${CREDENTIALS_SOURCE_DIR}/r2.env"
RESTIC_PW_FILE="${CREDENTIALS_SOURCE_DIR}/repo-password"
export RESTIC_CACHE_DIR

# Where consistent snapshots are staged before upload. Wiped afterwards.
STAGING_DIR="$HYBRID_AI_BACKUP_STAGING_DIR"

KEEP_DAILY="${KEEP_DAILY:-7}"
KEEP_WEEKLY="${KEEP_WEEKLY:-4}"
KEEP_MONTHLY="${KEEP_MONTHLY:-6}"

# Every compose file, so 'config --images' reports the full stack. The
# resolved env file and the app directory are passed explicitly, so the stack
# is the same one doctor.sh and install.sh operate on.
COMPOSE=(docker compose -p hybrid-ai --env-file "$HYBRID_AI_ENV_FILE"
         --project-directory "$HYBRID_AI_APP_DIR"
         -f "$HYBRID_AI_APP_DIR/docker-compose.yml"
         -f "$HYBRID_AI_APP_DIR/openhands/docker-compose.openhands.yml"
         -f "$HYBRID_AI_APP_DIR/hermes/docker-compose.hermes.yml")

# Container names (not compose service names) that write durable state.
APP_CONTAINERS=(open-webui hermes-agent)
PAUSED_CONTAINERS=()
STOPPED_CONTAINERS=()

# Fixed paths the root helper (backup/backup-containers.sh) uses in external
# container-control mode. The default is the fixed /run/hybrid-ai-backup. The
# HYBRID_AI_BACKUP_RUN_DIR override exists ONLY so the offline test suite can
# point at a scratch directory without root; it changes no privilege and the
# helper always writes to the fixed default. Names are fixed; no path or
# container name ever comes from an argument.
BACKUP_RUN_DIR="${HYBRID_AI_BACKUP_RUN_DIR:-/run/hybrid-ai-backup}"
PAUSED_FILE="${BACKUP_RUN_DIR}/paused"
HOST_INFO_DIR="${BACKUP_RUN_DIR}/host-info"

# BACKUP_CONTAINER_CONTROL=external: this process runs NO docker command at
# all. It reads what the root helper paused and copies the helper's host-info.
# Any other value keeps today's behaviour (this script controls containers).
EXTERNAL_CONTAINER_CONTROL=0
if [[ "${BACKUP_CONTAINER_CONTROL:-auto}" == "external" ]]; then
  EXTERNAL_CONTAINER_CONTROL=1
fi

# HYBRID_AI_BACKUP_MODE=system selects the split capture/upload system units.
# It is informational here (the units pass --stage-only / --upload-only); the
# default, user, is unchanged.
BACKUP_MODE="${HYBRID_AI_BACKUP_MODE:-user}"

MODE="backup"
STAGE_ONLY=0
UPLOAD_ONLY=0
NON_INTERACTIVE=0
for arg in "$@"; do
  case "$arg" in
    --check)           MODE="check" ;;
    --init)            MODE="init" ;;
    --dry-run)         MODE="dryrun" ;;
    --stage-only)      STAGE_ONLY=1 ;;
    --upload-only)     UPLOAD_ONLY=1 ;;
    --non-interactive) NON_INTERACTIVE=1 ;;
    -h|--help) sed -n '2,129p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

# --stage-only and --upload-only are mutually exclusive, and neither combines
# with --init/--check/--dry-run (those are whole-run modes with their own
# credential and repository handling).
if (( STAGE_ONLY && UPLOAD_ONLY )); then
  echo "Cannot combine --stage-only and --upload-only." >&2
  exit 2
fi
if (( STAGE_ONLY || UPLOAD_ONLY )) && [[ "$MODE" != "backup" ]]; then
  echo "--stage-only and --upload-only cannot be combined with --init, --check or --dry-run." >&2
  exit 2
fi

# --- THE CONTROL: credentials must not sit inside the app/data/work trees ---
# Backup credentials are the keys to EVERY backup. Kept inside the deploy
# tree, a data tree, or the staging work tree, they would be swept into a git
# operation, a diagnostics bundle, or a backup of the tree itself. A --dry-run
# writes nothing, but the read of a misplaced credential is what we refuse.
# This applies to whichever directory the credentials come from, including the
# systemd credential directory in system mode.
#
# --stage-only reads NO credentials, so there is nothing to protect and the
# check is skipped (it would otherwise inspect a directory this run never uses).
if (( ! STAGE_ONLY )); then
  path_within() { [[ "$1" == "$2" || "$1" == "$2"/* ]]; }
  for _tree in "$HYBRID_AI_APP_DIR" "$HYBRID_AI_DATA_DIR" "$HYBRID_AI_WORK_DIR"; do
    if path_within "${CREDENTIALS_SOURCE_DIR%/}" "${_tree%/}"; then
      printf '[ X ] The backup credential directory is inside %s.\n' "$_tree" >&2
      printf '     Backup credentials must live OUTSIDE the app, data and work directories.\n' >&2
      exit 1
    fi
  done
  unset _tree
fi

# --- Output helpers --------------------------------------------------------
if [[ -t 1 ]]; then
  C_RST=$'\033[0m'; C_INF=$'\033[36m'; C_OK=$'\033[32m'
  C_WRN=$'\033[33m'; C_ERR=$'\033[31m'
else
  C_RST=""; C_INF=""; C_OK=""; C_WRN=""; C_ERR=""
fi
log()  { printf '%s[ * ]%s %s\n'  "$C_INF" "$C_RST" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_OK"  "$C_RST" "$*"; }
warn() { printf '%s[ ! ]%s %s\n'  "$C_WRN" "$C_RST" "$*" >&2; }

# Structured, greppable record of every run. METADATA ONLY -- never write a
# credential, a user document filename, or any chat content here.
event() {
  local name="$1"; shift
  printf 'EVENT ts=%s event=%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$name" "$*" \
    | tee -a "$BACKUP_LOG" 2>/dev/null || true
}

die() {
  event "backup_failed" "detail=$(printf '%s' "$*" | tr -d '\n' | cut -c1-160)"
  printf '%s[ X ]%s %s\n' "$C_ERR" "$C_RST" "$*" >&2
  exit 1
}

# Exit code for a run that finished but MISSED durable state. Distinct from 1
# (an aborted run): both backup units list it in RestartPreventExitStatus so
# systemd does not retry it every 15 minutes -- a retry would fail identically.
EXIT_INCOMPLETE=3

# --- STATUS file (stage-only / upload-only handshake) -----------------------
# The capture unit writes STAGING_DIR/STATUS; the upload unit reads it. It
# carries a fixed verdict and FIXED reason codes only -- never a discovered
# name, path or credential. The two lines are exactly:
#   status=complete|incomplete
#   reasons=<comma-separated fixed codes, or "-">
STATUS_FILE_NAME="STATUS"

# Map each incomplete reason to a FIXED code. A reason string is
# "family:detail"; the family is a constant we control, but the detail can be a
# tree label, an rsync label or a container name. Only the family is kept, so
# no discovered or attacker-controlled text can reach the STATUS file.
status_reason_code() {
  case "${1%%:*}" in
    backup_data_unreadable)       printf 'data_unreadable' ;;
    hermes_data_unreadable)       printf 'hermes_data_unreadable' ;;
    db_path_rejected)             printf 'db_path_rejected' ;;
    rsync_partial)                printf 'rsync_partial' ;;
    cold_copy_skipped)            printf 'cold_copy_skipped' ;;
    cold_copy_agent_stop_declined) printf 'agent_stop_declined' ;;
    cold_copy_stop_failed)        printf 'cold_copy_stop_failed' ;;
    cold_copy_failed)             printf 'cold_copy_failed' ;;
    external_control_unreadable)  printf 'external_control_unreadable' ;;
    *)                            printf 'other' ;;
  esac
}

write_status() {
  [[ -n "${STAGING_DIR:-}" && -d "$STAGING_DIR" ]] || return 0
  local verdict="complete" codes="-" code
  if (( INCOMPLETE_COUNT > 0 )); then
    verdict="incomplete"
    local -A _seen=()
    codes=""
    for _r in "${INCOMPLETE_REASONS[@]}"; do
      code="$(status_reason_code "$_r")"
      [[ -n "${_seen[$code]:-}" ]] && continue
      _seen[$code]=1
      codes+="${codes:+,}${code}"
    done
    unset _seen
  fi
  {
    printf 'status=%s\n' "$verdict"
    printf 'reasons=%s\n' "$codes"
  } > "${STAGING_DIR}/${STATUS_FILE_NAME}" 2>/dev/null || true
}

# --- Incomplete-run tracking ------------------------------------------------
# A run that could not capture everything it should have is INCOMPLETE, not
# successful. It is still uploaded (that partial data is worth keeping), but it
# is tagged complete:false, emits backup_incomplete instead of backup_success,
# and exits with EXIT_INCOMPLETE so the failure is visible rather than implied.
INCOMPLETE_COUNT=0
INCOMPLETE_REASONS=()

mark_incomplete() {
  INCOMPLETE_COUNT=$(( INCOMPLETE_COUNT + 1 ))
  INCOMPLETE_REASONS+=("$1")
}

# --- Untrusted-path validation ---------------------------------------------
# hermes_data is written by the Hermes container, so every path discovered
# beneath it is attacker-controlled. Before such a path is used for ANY copy or
# sqlite3 call it must pass this allow-list:
#   * the absolute path starts with "$HYBRID_AI_DATA_DIR/" (so the "$db" -> rel
#     derivation below is exact and can never escape via "..")
#   * the whole data-relative path matches ^([A-Za-z0-9._@+-]+/)*[A-Za-z0-9._@+-]+$
#   * no component is "." or ".."
#   * no component starts with "-" (so it can never be read as an option)
# The absolute prefix ("$HYBRID_AI_DATA_DIR") is not inspected: it is ours, not
# the container's. A rejected path is counted only -- its raw name is NEVER
# logged.
valid_rel_path() {
  local abs="$1" rel
  [[ "$abs" == "${HYBRID_AI_DATA_DIR}/"* ]] || return 1
  rel="${abs#"${HYBRID_AI_DATA_DIR}/"}"
  [[ -n "$rel" ]] || return 1
  # Match the ENTIRE path against one anchored regex. The char class cannot
  # match a quote, a newline, a '*', a '?' or a space, so a component cannot
  # hide behind a glob expansion or a line split. The pattern also forbids
  # empty components, a leading/trailing slash, and repeated slashes.
  [[ "$rel" =~ ^[A-Za-z0-9._@+-]+(/[A-Za-z0-9._@+-]+)*$ ]] || return 1
  # Reject any "." or ".." component and any component starting with "-".
  [[ "$rel" =~ (^|/)\.\.?(/|$) ]] && return 1
  [[ "$rel" =~ (^|/)- ]] && return 1
  return 0
}

# --- Container control -----------------------------------------------------
is_running() { [[ "$(docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null)" == "running" ]]; }

unpause_webui() {
  # External control: the root helper's ExecStopPost=+backup-containers.sh
  # unpause resumes the containers. This process runs no docker command, so it
  # only clears its own bookkeeping.
  if (( EXTERNAL_CONTAINER_CONTROL )); then
    PAUSED_CONTAINERS=()
    return 0
  fi
  local c
  for c in "${PAUSED_CONTAINERS[@]}"; do
    docker unpause "$c" >/dev/null 2>&1 || warn "Could not unpause ${c}. Run: docker unpause ${c}"
  done
  PAUSED_CONTAINERS=()
}

restart_stopped() {
  # External control never stops or starts a container.
  if (( EXTERNAL_CONTAINER_CONTROL )); then
    STOPPED_CONTAINERS=()
    return 0
  fi
  if (( ${#STOPPED_CONTAINERS[@]} > 0 )); then
    docker start "${STOPPED_CONTAINERS[@]}" >/dev/null 2>&1 \
      || warn "Could not restart ${STOPPED_CONTAINERS[*]}. Run: docker start ${STOPPED_CONTAINERS[*]}"
    STOPPED_CONTAINERS=()
  fi
}

# Pause every app container that is running. Returns 0 only when the capture can
# be considered POINT-IN-TIME: every durable-state container was running AND is
# now paused. If any container was not running, the stack could not be fully
# frozen, so this reports failure and the caller falls back to the online backup.
#
# In external mode this process runs NO docker command: it reads which
# containers the root helper paused from PAUSED_FILE. CONSISTENCY is "paused"
# only when every app container is listed there; otherwise "online".
pause_webui() {
  [[ "${BACKUP_NO_PAUSE:-0}" == "1" ]] && return 1
  if (( EXTERNAL_CONTAINER_CONTROL )); then
    PAUSED_CONTAINERS=()
    local c
    if [[ -r "$PAUSED_FILE" ]]; then
      local line
      while IFS= read -r line || [[ -n "$line" ]]; do
        for c in "${APP_CONTAINERS[@]}"; do
          [[ "$line" == "$c" ]] && PAUSED_CONTAINERS+=("$c")
        done
      done < "$PAUSED_FILE"
    fi
    # Point-in-time only when EVERY app container was paused by the helper.
    (( ${#PAUSED_CONTAINERS[@]} == ${#APP_CONTAINERS[@]} ))
    return
  fi
  command -v docker >/dev/null 2>&1 || return 1
  local c all_running=1
  for c in "${APP_CONTAINERS[@]}"; do
    if ! is_running "$c"; then all_running=0; fi
  done
  for c in "${APP_CONTAINERS[@]}"; do
    is_running "$c" || continue
    if docker pause "$c" >/dev/null 2>&1; then
      PAUSED_CONTAINERS+=("$c")
    else
      unpause_webui   # never leave a half-paused stack behind
      return 1
    fi
  done
  (( all_running ))
}

# SQLite helpers -------------------------------------------------------------
# EVERY path that reaches sqlite3 is validated first (valid_rel_path). The
# helpers below NEVER build SQL text or a sqlite3 URI from a discovered name:
# the path is only ever an argv element. In particular VACUUM INTO is gone --
# its destination could only be supplied by splicing the path into SQL.

# The exact bytes every SQLite database file starts with.
SQLITE_MAGIC='SQLite format 3'

# --- Readability probe ------------------------------------------------------
# WHY NOT -readable / [[ -r ]]:
#   In system mode the capture unit carries CAP_DAC_READ_SEARCH as an ambient
#   capability. Linux drops effective capabilities for access(2) when the real
#   uid is not root, so access(2)-based tests -- find's -readable and bash's
#   [[ -r ]] -- would report a file this process CAN read as unreadable. The
#   fix is to test readability by OPENING the file instead: an open(2) honours
#   the effective capability set, so it reports what a read will actually do.
#   User mode keeps the current, cheaper access(2)-based checks.
#
# The two probes live in backup/lib/read-probe.sh so a fixture test can source
# them directly. READ_PROBE_MODE is "open" in system mode (which sets external
# container control) and "access" otherwise.
_HYBRID_AI_BACKUP_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=backup/lib/read-probe.sh
source "${_HYBRID_AI_BACKUP_DIR}/lib/read-probe.sh"
READ_PROBE_MODE="access"
if (( EXTERNAL_CONTAINER_CONTROL )) || [[ "$BACKUP_MODE" == "system" ]]; then
  READ_PROBE_MODE="open"
fi

probe_file() { probe_readable "$READ_PROBE_MODE" "$1"; }
probe_dir()  { probe_dir_readable "$READ_PROBE_MODE" "$1"; }

# Classify a file by its 16-byte header (not its name). Fills DB_IS_SQLITE.
# Reads at most 17 bytes so a file whose header is exactly this string plus
# more content still compares as SQLite (the cut drops the 17th byte).
DB_IS_SQLITE=0
classify_db_file() {
  DB_IS_SQLITE=0
  [[ -f "$1" && ! -L "$1" ]] || return 1
  probe_file "$1" || return 1
  local head16
  head16="$(head -c 16 "$1" 2>/dev/null)" || return 1
  [[ "$head16" == "$SQLITE_MAGIC" ]] && DB_IS_SQLITE=1
  return 0
}

# Copy the staged database without opening the LIVE files with sqlite3; the
# staged copy is then checkpointed and must pass PRAGMA quick_check. Every
# sidecar present (-wal, -shm, -journal) is copied too, or a WAL database's
# uncheckpointed rows would be silently lost.
sqlite_snapshot_paused() {
  local db="$1" target="$2" sfx
  [[ -f "$db" && ! -L "$db" ]] || return 1
  mkdir -p "$(dirname "$target")" || return 1
  cp -a --no-dereference -- "$db" "$target" || return 1
  for sfx in -wal -shm -journal; do
    # A symlinked sidecar is refused, not followed: copying it as a symlink and
    # then checkpointing the staged copy would let the link point the write at
    # an attacker-chosen file, and following it into staging would pull an
    # arbitrary file's bytes into the snapshot.
    [[ -L "${db}${sfx}" ]] && return 1
    if [[ -f "${db}${sfx}" ]]; then
      cp -a --no-dereference -- "${db}${sfx}" "${target}${sfx}" || return 1
    fi
  done
  if command -v sqlite3 >/dev/null 2>&1; then
    # Fold the staged WAL into the staged main file, then prove it is coherent.
    sqlite3 "$target" 'PRAGMA wal_checkpoint(TRUNCATE);' >/dev/null 2>&1 || return 1
    [[ "$(sqlite3 "$target" 'PRAGMA quick_check;' 2>/dev/null | head -n1)" == "ok" ]] || return 1
  fi
  # The sidecars are now folded in; drop them so the staged database is a
  # single self-contained file (never a WAL that restore could misread).
  for sfx in -wal -shm -journal; do
    [[ -e "${target}${sfx}" ]] && rm -f "${target}${sfx}"
  done
  return 0
}

# Online backup via SQLite's own backup API ('.backup'). The .backup dot-command
# does not parse SQL, and the path is passed inside double quotes, so a name
# made only of the allowed characters cannot escape. The SOURCE is opened
# read-only. VACUUM INTO is deliberately not used here or anywhere.
sqlite_snapshot_online() {
  local db="$1" target="$2"
  [[ -f "$db" ]] || return 1
  command -v sqlite3 >/dev/null 2>&1 || return 1
  mkdir -p "$(dirname "$target")" || return 1
  sqlite3 -readonly -- "$db" ".timeout 10000" ".backup \"${target}\"" 2>/dev/null || return 1
  [[ -s "$target" ]] || return 1
  return 0
}

# Last-resort copy with the stack STOPPED. Re-validates the path, re-classifies
# by header, copies without following symlinks, folds in any sidecar and
# REQUIRES PRAGMA quick_check to pass. A genuine non-SQLite file is skipped; any
# other failure is fatal to the run. Returns 0 ok, 1 failure, 2 non-SQLite,
# 3 rejected path. Sets SNAPSHOT_REL.
cold_copy_db() {
  local db="$1"
  SNAPSHOT_REL=""
  valid_rel_path "$db" || return 3
  SNAPSHOT_REL="${db#"${HYBRID_AI_DATA_DIR}/"}"
  [[ -f "$db" && ! -L "$db" ]] || return 1
  classify_db_file "$db" || return 1
  (( DB_IS_SQLITE )) || return 2
  # A cold copy that cannot be verified is not a backup; refuse to pretend.
  command -v sqlite3 >/dev/null 2>&1 || return 1
  sqlite_snapshot_paused "$db" "${STAGING_DIR}/databases/${SNAPSHOT_REL}"
}

# AVAILABILITY: always resume services and clean staged copies, even on failure.
cleanup() {
  local rc=$?
  unpause_webui
  restart_stopped
  # stage-only keeps STAGING_DIR for the upload unit to pick up; upload-only
  # removes it only after a SUCCESSFUL upload (inside upload_backup) so a failed
  # upload can be retried against the same staged data. Every other mode wipes
  # the staging directory as before.
  if (( ! STAGE_ONLY && ! UPLOAD_ONLY )); then
    if [[ -d "$STAGING_DIR" ]]; then
      rm -rf "$STAGING_DIR" 2>/dev/null || true
    fi
  fi
  return $rc
}
trap cleanup EXIT
trap 'die "Failed at line ${LINENO}: ${BASH_COMMAND}"' ERR

touch "$BACKUP_LOG" 2>/dev/null && chmod 600 "$BACKUP_LOG" 2>/dev/null || true

# ---------------------------------------------------------------------------
# STEP 1. Load credentials
#
# --stage-only loads NO credentials at all: the capture unit has no network and
# no credential directory. The credential block below is skipped entirely, and
# the file checks are never reached.
# ---------------------------------------------------------------------------
if (( STAGE_ONLY )); then
  log "Stage-only run: no credentials are loaded (capture has no network)."
else
[[ -f "$R2_ENV_FILE" ]] || die "No credentials at ${R2_ENV_FILE}. Run ./install.sh to configure backups."
[[ -f "$RESTIC_PW_FILE" ]] || die "No repository password at ${RESTIC_PW_FILE}."

for f in "$R2_ENV_FILE" "$RESTIC_PW_FILE"; do
  perms="$(stat -c '%a' "$f" 2>/dev/null || echo '???')"
  [[ "$perms" == "600" ]] || die "${f} has permissions ${perms}; expected 600. Fix with: chmod 600 ${f}"
done

# SECURITY: parsed line by line, never sourced. 'source' would execute $(...).
while IFS= read -r _line || [[ -n "$_line" ]]; do
  [[ "$_line" =~ ^[[:space:]]*# ]] && continue
  [[ "$_line" =~ ^[[:space:]]*$ ]] && continue
  if [[ "$_line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
    _k="${BASH_REMATCH[1]}"; _v="${BASH_REMATCH[2]}"
    _v="${_v%\"}"; _v="${_v#\"}"; _v="${_v%\'}"; _v="${_v#\'}"
    printf -v "$_k" '%s' "$_v"
    export "${_k?}"
  fi
done < "$R2_ENV_FILE"
unset _line _k _v
export RESTIC_PASSWORD_FILE="$RESTIC_PW_FILE"

[[ -n "${RESTIC_REPOSITORY:-}" ]]     || die "RESTIC_REPOSITORY not set in ${R2_ENV_FILE}"
[[ -n "${AWS_ACCESS_KEY_ID:-}" ]]     || die "AWS_ACCESS_KEY_ID not set in ${R2_ENV_FILE}"
[[ -n "${AWS_SECRET_ACCESS_KEY:-}" ]] || die "AWS_SECRET_ACCESS_KEY not set in ${R2_ENV_FILE}"
command -v restic >/dev/null 2>&1 || die "restic is not installed. Run: sudo apt-get install -y restic"

BACKUP_HOST="${RESTIC_HOST:-$(hostname -s)}"
fi   # end: credentials (skipped for --stage-only)

# --stage-only loads no credentials, so RESTIC_HOST is unavailable; a host name
# is still needed for the manifest and host state. The same value is used.
if (( STAGE_ONLY )); then
  BACKUP_HOST="${RESTIC_HOST:-$(hostname -s)}"
fi

# ---------------------------------------------------------------------------
# --upload-only preconditions.
#
# The upload unit reads ONLY the staging directory; it never reads a data tree.
# Refuse when STAGING_DIR or its STATUS file is missing: there is nothing to
# upload, and a missing STATUS means the capture did not finish.
#
# Parse STATUS line by line into exactly two values, with the same discipline as
# the credential parser (data, never code). An unrecognised line or verdict is
# refused. COMPLETE_TAG is then taken from STATUS, not from this process's own
# incomplete counter (which stays 0 on the upload side).
# ---------------------------------------------------------------------------
COMPLETE_TAG="complete:true"
if (( UPLOAD_ONLY )); then
  # A refusal here is a deliberate exit 3, not a failure: clear the ERR trap so
  # it is not relabelled backup_failed.
  refuse_upload() { printf '%s\n' "$1" >&2; trap - ERR; exit 3; }
  [[ -d "$STAGING_DIR" ]] || refuse_upload "No staging directory at ${STAGING_DIR}; nothing to upload. Run --stage-only first."
  STATUS_PATH="${STAGING_DIR}/${STATUS_FILE_NAME}"
  [[ -f "$STATUS_PATH" ]] || refuse_upload "No STATUS file at ${STATUS_PATH}; the capture did not complete. Run --stage-only first."
  STATUS_VERDICT=""
  while IFS= read -r _sline || [[ -n "$_sline" ]]; do
    [[ "$_sline" =~ ^status=(complete|incomplete)$ ]] && STATUS_VERDICT="${BASH_REMATCH[1]}"
  done < "$STATUS_PATH"
  unset _sline
  case "$STATUS_VERDICT" in
    complete)   COMPLETE_TAG="complete:true";  INCOMPLETE_COUNT=0 ;;
    incomplete) COMPLETE_TAG="complete:false"; INCOMPLETE_COUNT=1
                INCOMPLETE_REASONS=("status_incomplete") ;;
    *) refuse_upload "STATUS file at ${STATUS_PATH} is missing a valid status line." ;;
  esac
  # The upload side reads only the staging directory; these are the values the
  # manifest/report used, defaulted so `set -u` never trips.
  CONSISTENCY="${CONSISTENCY:-external}"
  DB_COUNT="${DB_COUNT:-0}"
  STAGED_MB="$(du -sm "$STAGING_DIR" 2>/dev/null | cut -f1 || true)"
  STAGED_MB="${STAGED_MB:-?}"
fi

# ---------------------------------------------------------------------------
# STEP 2. --init : create the repository
# ---------------------------------------------------------------------------
if [[ "$MODE" == "init" ]]; then
  log "Initialising restic repository..."
  if restic snapshots >/dev/null 2>&1; then
    ok "Repository already initialised. Nothing to do."
    exit 0
  fi
  restic init || die "restic init failed. Check your R2 credentials and bucket name."
  event "repo_initialised" "host=${BACKUP_HOST}"
  ok "Repository created."
  cat <<'MSG'

  IMPORTANT -- do this now, not later:

  Store your repository password somewhere OFF this Pi. A password manager is
  ideal. If the disk dies and the password died with it, your backups are
  permanently unreadable. Restic has no recovery mechanism, by design.

MSG
  exit 0
fi

# ---------------------------------------------------------------------------
# STEP 3. --check : verify integrity
# ---------------------------------------------------------------------------
if [[ "$MODE" == "check" ]]; then
  log "Verifying repository integrity (reads ~5% of data; this takes a while)..."
  if restic check --read-data-subset=5%; then
    event "check_success" "subset=5%"
    ok "Repository is healthy."
    exit 0
  else
    event "check_failed" "severity=critical"
    die "INTEGRITY CHECK FAILED. Do not trust these backups until resolved."
  fi
fi

# ---------------------------------------------------------------------------
# STEP 4. Capture application data consistently -- stage_backup()
#
# Capture (stage) and upload are separate functions that share ONLY the staging
# directory and the manifest, so a later card can run them as separate systemd
# units. stage_backup() fills STAGING_DIR and the manifest; upload_backup()
# reads them. Neither introduces a new $HOME- or repo-relative path.
# ---------------------------------------------------------------------------
stage_backup() {
# --- Read-access preflight. Runs BEFORE any container is touched. -----------
# The backup runs as whoever invoked it (a systemd --user unit runs as the
# human user), while with HYBRID_AI_UID set the stack writes hermes_data as the
# stack uid. If this process cannot read a data tree, nothing under it can be
# captured -- and a cold copy that stopped the agent for nothing killed
# in-flight sessions (incident B1, 2026-10-15). So detect it here, be honest
# about it, and stop no container. A discovered name is NEVER printed: only the
# fixed tree label and numeric uids reach the log.
DATA_UNREADABLE=0
for _tree_var in HYBRID_AI_HERMES_DATA_DIR HYBRID_AI_WEBUI_DATA_DIR; do
  _tree="${!_tree_var}"
  [[ -d "$_tree" ]] || continue
  # User mode keeps find's -readable (access(2)); system mode probes by opening
  # (see probe_dir_readable) because access(2) ignores CAP_DAC_READ_SEARCH.
  # -xdev stays on one filesystem; -quit stops at the first unreadable entry.
  # stderr is suppressed so no hostile path can leak through an error message.
  if [[ "$READ_PROBE_MODE" == "open" ]]; then
    _tree_bad=0
    probe_dir "$_tree" || _tree_bad=1
    # The tree may be readable while an entry under it is not; -readable here is
    # only a fast hint and is corroborated by the open-based discovery below.
    if (( ! _tree_bad )) && [[ -n "$(find "$_tree" -xdev ! -readable -print -quit 2>/dev/null)" ]]; then
      # Do not decide on access(2) alone in system mode: confirm with an open.
      _probe_entry="$(find "$_tree" -xdev ! -readable -print -quit 2>/dev/null || true)"
      probe_file "$_probe_entry" || _tree_bad=1
    fi
  else
    _tree_bad=0
    [[ -n "$(find "$_tree" -xdev ! -readable -print -quit 2>/dev/null)" ]] && _tree_bad=1
  fi
  if (( _tree_bad )); then
    case "$_tree_var" in
      HYBRID_AI_HERMES_DATA_DIR) _tree_label="hermes_data" ;;
      HYBRID_AI_WEBUI_DATA_DIR)  _tree_label="webui_data" ;;
      *)                         _tree_label="unknown" ;;
    esac
    _owner="$(stat -c '%u:%g' "$_tree" 2>/dev/null || echo unknown)"
    event "backup_data_unreadable" "tree=${_tree_label}" \
          "owner_uid_gid=${_owner}" "run_uid=$(id -u)"
    mark_incomplete "backup_data_unreadable:${_tree_label}"
    warn "The backup runs as uid $(id -u) but ${_tree_label} is owned by ${_owner} and is not readable by this process, so nothing under it can be captured. This run is INCOMPLETE and will not be retried. Run the backup as the account that owns the data, or grant this account read access to it."
    DATA_UNREADABLE=1
  fi
done
unset _tree_var _tree _tree_label _owner _tree_bad _probe_entry

[[ "$MODE" == "dryrun" ]] || log "Capturing application state..."
rm -rf "$STAGING_DIR"
mkdir -p "${STAGING_DIR}/databases" "${STAGING_DIR}/files" "${STAGING_DIR}/env" \
         "${STAGING_DIR}/host" "${STAGING_DIR}/hermes" "${STAGING_DIR}/openhands"
chmod 700 "$STAGING_DIR"

if pause_webui; then
  CONSISTENCY="paused"
  [[ "$MODE" == "dryrun" ]] || ok "Paused for point-in-time capture: ${PAUSED_CONTAINERS[*]}"
else
  CONSISTENCY="online"
  [[ "$MODE" == "dryrun" ]] || warn "Could not pause containers; capturing live (see BACKUP_NO_PAUSE)."
fi

# ---------------------------------------------------------------------------
# Durable hermes_data: ONE exclude list, used for BOTH the file capture and the
# database discovery. hermes_data is the ONLY durable Hermes state that survives
# a container recreate (hermes/docker-compose.hermes.yml mounts
# ./hermes_data:/root/.hermes). We capture it by EXCLUSION, not by an
# allow-list, because an allow-list once dropped state (a rebuilt-by-hand
# BACKLOG.md) that lived only in state.db.
#
# Directory entries end with '/'; file/glob entries do not. 'profiles/*/home/'
# drops each profile's throwaway HOME. The *.db*-family entries are excluded
# here because live SQLite is captured as a consistent snapshot instead (see
# discover_databases below), never copied while in use.
# ---------------------------------------------------------------------------
HERMES_DATA="${HYBRID_AI_DATA_DIR}/hermes_data"
WEBUI_DB_PATHS=(
  "${HYBRID_AI_DATA_DIR}/webui_data/webui.db"
  "${HYBRID_AI_DATA_DIR}/webui_data/vector_db/chroma.sqlite3"
)
HERMES_EXCLUDES=(
  'tools/' 'hermes-agent/' 'installs/' 'cache/' 'image_cache/' 'audio_cache/'
  'lsp/' 'node_modules/' 'venv/' '.venv/' '__pycache__/' '.git/' 'logs/'
  'runtime/' 'sandboxes/' 'terminal-sessions/' 'profiles/*/home/'
  '*.pyc' '*.log' '*.lock' '*.pid' '*.sock'
  'models_dev_cache.json' 'models_dev_cache.etag' 'provider_models_cache.json'
  '*.db' '*.sqlite' '*.sqlite3' '*-wal' '*-shm' '*-journal'
)

# rsync arguments for the list above (null-separated for mapfile).
hermes_rsync_excludes() {
  local x
  for x in "${HERMES_EXCLUDES[@]}"; do printf '%s\0' "--exclude=${x}"; done
}

# Bare directory names to prune during discovery -- derived from the SAME list
# so the two can never drift. Only simple names (no '/') are emitted here; see
# hermes_prune_paths for path-pattern entries.
hermes_prune_names() {
  local x name
  for x in "${HERMES_EXCLUDES[@]}"; do
    [[ "$x" == */ ]] || continue
    name="${x%/}"
    [[ "$name" == */* ]] && continue
    printf '%s\0' "$name"
  done
}

# Directory entries that carry a '/', e.g. 'profiles/*/home/'. Emitted for use
# as -path predicates, so per-profile home is pruned by its PATH pattern -- NOT
# by a bare -name home, which would wrongly prune every directory named home.
hermes_prune_paths() {
  local x pat
  for x in "${HERMES_EXCLUDES[@]}"; do
    [[ "$x" == */ ]] || continue
    pat="${x%/}"
    [[ "$pat" == */* ]] || continue
    printf '%s\0' "$pat"
  done
}

# Turn ONE path entry (e.g. 'profiles/*/home') into anchored find predicates.
# find's '*' crosses '/', so a lone -path "$HERMES_DATA/profiles/*/home" would
# also match deeper trees such as profiles/<p>/workspace/proj/home. Pairing it
# with an anchored ! -path that requires an EXTRA component
# ("$HERMES_DATA/profiles/*/*/home") leaves EXACTLY the one-component case that
# rsync's profile-home exclusion matches. The real $HERMES_DATA prefix anchors
# the match, so nothing outside profiles/<one>/home is ever pruned.
hermes_prune_path_args() {
  local pat="$1" head tail
  head="${pat%/*}"
  tail="${pat##*/}"
  printf '%s\0' -path "${HERMES_DATA}/${pat}" '!' -path "${HERMES_DATA}/${head}/*/${tail}"
}

# Snapshot one discovered database. Codes are captured by the caller so the
# cold-copy fallback can retry a FAILURE but never a rejected or non-SQLite path.
# Returns:
#   0  captured successfully
#   1  capture failed, or the file is unreadable (candidate for cold copy)
#   2  file is NOT SQLite (16-byte header); skipped, never fatal
#   3  path REJECTED by the allow-list; counted, raw name never logged
# Sets SNAPSHOT_REL (repo-relative path) for the caller's logging.
SNAPSHOT_REL=""
snapshot_one_db() {
  local db="$1" rel target
  SNAPSHOT_REL=""

  # Attacker-controlled path: refuse it before any copy or sqlite3 call.
  if ! valid_rel_path "$db"; then
    return 3
  fi
  rel="${db#"${HYBRID_AI_DATA_DIR}/"}"
  SNAPSHOT_REL="$rel"
  target="${STAGING_DIR}/databases/${rel}"

  # Classify by the 16-byte header, never by the file name. A genuine
  # non-SQLite file is skipped; an unreadable file is a failure, so the
  # cold-copy fallback gets a chance before the run dies.
  if ! classify_db_file "$db"; then
    return 1
  fi
  if (( ! DB_IS_SQLITE )); then
    return 2
  fi

  if [[ "$CONSISTENCY" == "paused" ]]; then
    sqlite_snapshot_paused "$db" "$target" || return 1
  else
    sqlite_snapshot_online "$db" "$target" || return 1
  fi
  return 0
}

# Discover every live SQLite database at RUN TIME. Covers the whole hermes_data
# tree (state.db, kanban.db, shared-state.db, kanban/boards/*/kanban.db,
# cron/executions.db, profiles/*/state.db, profiles/*/cron/*.db, ...) plus the
# two Open WebUI databases. Fills DISCOVERED_DBS.
#
# The prune expression is built from the SAME exclude list so the two can never
# drift: simple directory names become -name predicates, path patterns (e.g.
# 'profiles/*/home') become ANCHORED -path predicates (see hermes_prune_path_args).
# A bare -name home is deliberately NOT used -- it would prune every directory
# named home, and an unanchored -path would prune deeper 'home' dirs too.
#
# find runs in a process substitution, so its stderr is redirected into a file
# and its exit status absorbed with '|| true'. Without that, a find error on an
# unreadable entry fired the inherited ERR trap and logged a spurious
# backup_failed while the run carried on. Any output there is a real readability
# problem: it is counted, makes the run INCOMPLETE, and is reported.
discover_databases() {
  DISCOVERED_DBS=()
  local prune=() p args=() first=1
  local err_file="${STAGING_DIR}/.discovery.errors"
  : > "$err_file" 2>/dev/null || true

  if [[ -d "$HERMES_DATA" ]]; then
    while IFS= read -r -d '' p; do
      (( first )) || prune+=(-o)
      prune+=(-name "$p")
      first=0
    done < <(hermes_prune_names)
    while IFS= read -r -d '' p; do
      mapfile -d '' -t args < <(hermes_prune_path_args "$p")
      (( first )) || prune+=(-o)
      prune+=( \( "${args[@]}" \) )
      first=0
    done < <(hermes_prune_paths)
    while IFS= read -r -d '' db; do
      DISCOVERED_DBS+=("$db")
    done < <(find "$HERMES_DATA" \( "${prune[@]}" \) -prune -o \
               -type f \( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' \) -print0 \
               2>>"$err_file" || true)
  elif [[ -e "$HERMES_DATA" ]]; then
    printf 'hermes_data exists but is not a readable directory\n' >> "$err_file"
  fi

  local extra
  for extra in "${WEBUI_DB_PATHS[@]}"; do
    [[ -f "$extra" ]] && DISCOVERED_DBS+=("$extra")
  done

  if [[ -s "$err_file" ]]; then
    event "hermes_data_unreadable" "count=1"
    mark_incomplete "hermes_data_unreadable"
    warn "Some durable-state entries could not be read; this run is INCOMPLETE."
  fi
  rm -f "$err_file" 2>/dev/null || true
  return 0
}

DB_COUNT=0
DB_FAILED=0
DB_NONSQLITE=0
DB_REJECTED=0
FAILED_DBS=()
NONSQLITE_DBS=()

# Paths are staged RELATIVE TO THE REPO (e.g. databases/webui_data/webui.db).
# restore.sh relies on this layout.
discover_databases
if (( ${#DISCOVERED_DBS[@]} > 0 )); then
  [[ "$MODE" == "dryrun" ]] || log "Found ${#DISCOVERED_DBS[@]} database file(s) to snapshot."
fi

for db in "${DISCOVERED_DBS[@]}"; do
  rc=0
  snapshot_one_db "$db" || rc=$?
  case "$rc" in
    0) DB_COUNT=$(( DB_COUNT + 1 )) ;;
    1) DB_FAILED=$(( DB_FAILED + 1 )); FAILED_DBS+=("$db")
       warn "Could not capture ${SNAPSHOT_REL} via SQLite." ;;
    2) DB_NONSQLITE=$(( DB_NONSQLITE + 1 )); NONSQLITE_DBS+=("$SNAPSHOT_REL")
       warn "${SNAPSHOT_REL} is not a SQLite database (header); skipping its snapshot." ;;
    3) DB_REJECTED=$(( DB_REJECTED + 1 ))
       # Count only. The raw name is attacker-controlled and is NEVER logged.
       warn "A discovered path failed the name allow-list; skipping it." ;;
  esac
done
if (( DB_REJECTED > 0 )); then
  event "db_path_rejected" "count=${DB_REJECTED}"
  mark_incomplete "db_path_rejected"
fi

# --- Allow-list durable non-database state ---------------------------------
# A partial rsync (exit 23/24: some files vanished or could not be transferred)
# means durable state is missing from the snapshot, so the run is INCOMPLETE.
# Other rsync exit codes are loud warnings as before. The label is a fixed
# string, never a path, so no untrusted name reaches the event log.
rsync_classify() {
  local rc="$1" label="$2"
  if (( rc == 23 || rc == 24 )); then
    event "rsync_partial" "source=${3}" "exit=${rc}"
    mark_incomplete "rsync_partial:${3}"
    warn "rsync for ${label} was partial (exit ${rc}); this run is INCOMPLETE."
  elif (( rc != 0 )); then
    warn "rsync reported issues copying ${label}; continuing."
  fi
}

if [[ -d "${HYBRID_AI_DATA_DIR}/webui_data/uploads" ]]; then
  mkdir -p "${STAGING_DIR}/files/webui_data/uploads"
  rc=0; rsync -a "${HYBRID_AI_DATA_DIR}/webui_data/uploads/" "${STAGING_DIR}/files/webui_data/uploads/" 2>/dev/null || rc=$?
  rsync_classify "$rc" "Open WebUI uploads" "webui_uploads"
fi

if [[ -d "${HYBRID_AI_DATA_DIR}/webui_data/vector_db" ]]; then
  mkdir -p "${STAGING_DIR}/files/webui_data/vector_db"
  rc=0
  rsync -a \
    --exclude='*.db' --exclude='*.sqlite' --exclude='*.sqlite3' \
    --exclude='*.db-wal' --exclude='*.db-shm' --exclude='*.db-journal' \
    --exclude='*-wal' --exclude='*-shm' \
    "${HYBRID_AI_DATA_DIR}/webui_data/vector_db/" "${STAGING_DIR}/files/webui_data/vector_db/" 2>/dev/null || rc=$?
  rsync_classify "$rc" "Open WebUI vector data" "webui_vector_db"
fi

# Durable hermes_data: capture the WHOLE tree by exclusion (see HERMES_EXCLUDES).
# NOTE: webui/ is deliberately KEPT. hermes/Dockerfile clones the Hermes WebUI
# INTO the image, so the application code is not user state; ~/.hermes/webui
# holds durable user data (attachments/, sessions/, settings.json,
# workspaces.json, last_workspace.txt). The generic rules already drop its
# *.log files and cache *.json.
if [[ -d "$HERMES_DATA" ]]; then
  mkdir -p "${STAGING_DIR}/files/hermes_data"
  mapfile -d '' -t HERMES_RSYNC_EXCL < <(hermes_rsync_excludes)
  rc=0
  rsync -a "${HERMES_RSYNC_EXCL[@]}" \
    "${HERMES_DATA}/" "${STAGING_DIR}/files/hermes_data/" 2>/dev/null || rc=$?
  rsync_classify "$rc" "durable hermes_data" "hermes_data"
  unset HERMES_RSYNC_EXCL
fi

if [[ -d "${HYBRID_AI_HERMES_HOME_DIR}" ]]; then
  rc=0
  rsync -a \
    --exclude='cache/' --exclude='tools/' --exclude='installs/' \
    --exclude='node_modules/' --exclude='.git/' --exclude='venv/' --exclude='.venv/' \
    --exclude='__pycache__/' --exclude='*.pyc' \
    --exclude='*.db' --exclude='*.sqlite' --exclude='*.sqlite3' \
    "${HYBRID_AI_HERMES_HOME_DIR}/" "${STAGING_DIR}/hermes/" 2>/dev/null || rc=$?
  rsync_classify "$rc" "the .hermes durable state" "dot_hermes"
fi

if [[ -d "${OPENHANDS_STATE_DIR}" ]]; then
  rc=0
  rsync -a --exclude='cache/' --exclude='tmp/' --exclude='logs/' \
    "${OPENHANDS_STATE_DIR}/" "${STAGING_DIR}/openhands/" 2>/dev/null || rc=$?
  rsync_classify "$rc" "OpenHands state" "openhands"
fi

unpause_webui
[[ "$MODE" == "dryrun" ]] || ok "Capture complete; application services resumed."

# --- Cold-copy fallback ----------------------------------------------------
# Uses the SAME run-time discovered list, never a hardcoded one. A database that
# could not be captured online is retried with its client container STOPPED and
# MUST pass quick_check. The cold copy now stops ONLY the containers the FAILED
# databases need, and NEVER calls die(): a database it still cannot capture is
# reported (cold_copy_failed) and left out of the snapshot, which makes the run
# INCOMPLETE (exit 3) rather than aborting it (exit 1) into a retry loop. That
# is exactly what backup/README.md documents. A genuine non-SQLite file is
# skipped, not fatal; a REJECTED path is skipped too (it was counted and already
# made the run incomplete).
if (( DB_FAILED > 0 )); then
  warn "${DB_FAILED} database(s) could not be captured online."
  if (( EXTERNAL_CONTAINER_CONTROL )); then
    # External container control: this process must run NO docker command at
    # all (no inspect, exec, compose, version, stop). It therefore cannot stop a
    # container for a cold copy, so the fallback is declined and the databases
    # stay out of the snapshot. The run is INCOMPLETE (exit 3), exactly as for
    # an unreadable tree -- and, like the default, it stops no container.
    event "cold_copy_skipped" "reason=external_control" "failed_dbs=${DB_FAILED}"
    warn "External container control: the cold-copy fallback is declined because this process runs no docker command. The failed databases stay out of this snapshot and the run is INCOMPLETE."
    mark_incomplete "cold_copy_skipped:external_control"
  elif (( DATA_UNREADABLE )); then
    # The preflight already proved this process cannot read the data. Stopping
    # the stack here would only kill in-flight agent sessions for nothing.
    event "cold_copy_skipped" "reason=data_unreadable" "failed_dbs=${DB_FAILED}"
    warn "Skipping the cold copy: a data tree is not readable by this process. No container will be stopped."
    mark_incomplete "cold_copy_skipped:data_unreadable"
  elif ! command -v docker >/dev/null 2>&1; then
    # No docker: nothing can be stopped and no cold copy is possible. That is a
    # missing snapshot, not an abort -- mark it INCOMPLETE and keep the run.
    event "cold_copy_skipped" "reason=docker_unavailable" "failed_dbs=${DB_FAILED}"
    warn "Cannot produce consistent database copies and cannot fall back: docker is unavailable."
    mark_incomplete "cold_copy_skipped:docker_unavailable"
  else
    # Which containers do the FAILED databases need? Match their absolute paths
    # against the fixed data-dir prefixes (ours, not container-provided).
    wfail=0; afail=0; agent_declined=0; agent_allowed=0
    for db in "${FAILED_DBS[@]}"; do
      [[ "$db" == "${HYBRID_AI_WEBUI_DATA_DIR}/"* ]] && wfail=1
      if [[ "$db" == "${HYBRID_AI_HERMES_DATA_DIR}/"* ]]; then
        afail=1
        if [[ "${BACKUP_ALLOW_AGENT_STOP:-0}" == "1" ]]; then
          agent_allowed=1
        else
          agent_declined=1
        fi
      fi
    done

    # webui_frozen/agent_frozen = the container owning the failed databases is
    # frozen (stopped/paused) at a single point in time, so they may be copied
    # cold. When there is nothing to freeze for a class it counts as frozen; a
    # database whose container could NOT be frozen is left out of the snapshot
    # instead of being copied while it is still being written.
    webui_frozen=0; agent_frozen=0; stop_failed=0
    (( wfail )) || webui_frozen=1
    (( afail )) || agent_frozen=1

    cold_targets=()
    (( wfail )) && cold_targets+=(open-webui)
    (( afail && agent_allowed )) && cold_targets+=(hermes-agent)
    for c in "${cold_targets[@]}"; do
      is_running "$c" || continue
      if docker stop "$c" >/dev/null 2>&1; then
        STOPPED_CONTAINERS+=("$c")
        [[ "$c" == "open-webui" ]] && webui_frozen=1
        [[ "$c" == "hermes-agent" ]] && agent_frozen=1
      else
        # Do NOT die: unable to stop is an INCOMPLETE run, not an abort, and
        # nothing may be copied while the database is still being written.
        stop_failed=1
        mark_incomplete "cold_copy_stop_failed:${c}"
        warn "Could not stop ${c}; its databases will not be cold-copied."
      fi
    done
    # A paused stack is already frozen at a single point in time.
    [[ "$CONSISTENCY" == "paused" ]] && webui_frozen=1

    if (( stop_failed )); then
      # Restart anything already stopped; copy nothing while a writer is live.
      restart_stopped
    else
      cold_handled=0
      if (( agent_declined )); then
        event "cold_copy_agent_stop_declined" "failed_dbs=${DB_FAILED}"
        warn "hermes-agent is left running: stopping it kills in-flight agent sessions. Set BACKUP_ALLOW_AGENT_STOP=1 to let the cold copy stop it."
        mark_incomplete "cold_copy_agent_stop_declined"
        cold_handled=1
      fi
      if (( wfail && ! webui_frozen )); then
        warn "open-webui could not be frozen, so its failed databases stay out of this snapshot; the run is INCOMPLETE."
        mark_incomplete "cold_copy_stop_failed:open-webui"
        cold_handled=1
      fi
      if (( (wfail && webui_frozen) || (afail && agent_frozen) )); then
        warn "Falling back to a cold copy. Only the containers the failed databases need are stopped."
        event "cold_copy_fallback" "failed_dbs=${DB_FAILED}"
        CONSISTENCY="cold"
        sleep 3
        for db in "${FAILED_DBS[@]}"; do
          [[ -f "$db" && ! -L "$db" ]] || continue
          # Skip a database whose container is not frozen: it is left out (which
          # makes the run incomplete) rather than copied while being written.
          if [[ "$db" == "${HYBRID_AI_HERMES_DATA_DIR}/"* ]] && (( ! agent_frozen )); then
            continue
          fi
          if [[ "$db" == "${HYBRID_AI_WEBUI_DATA_DIR}/"* ]] && (( ! webui_frozen )); then
            continue
          fi
          crc=0; cold_copy_db "$db" || crc=$?
          case "$crc" in
            0) DB_COUNT=$(( DB_COUNT + 1 )) ;;
            2) warn "Skipping cold copy of non-SQLite ${SNAPSHOT_REL}." ;;
            3) : ;;   # rejected: already counted, already incomplete
            *) # Cannot capture even cold: report it, keep the other databases,
               # drop any partial staging, and make the run INCOMPLETE -- never
               # die into a retry loop.
               rm -f "${STAGING_DIR}/databases/${SNAPSHOT_REL}" 2>/dev/null || true
               event "cold_copy_failed" "severity=high"
               warn "Cold copy could not capture ${SNAPSHOT_REL}; it stays out of the snapshot and this run is INCOMPLETE."
               mark_incomplete "cold_copy_failed" ;;
          esac
        done
        restart_stopped
        cold_handled=1
      fi
      if (( ! cold_handled )); then
        # No container could be stopped for the failed databases (e.g. it was not
        # running), so the cold copy is skipped entirely. The databases stay out
        # of the snapshot, which is what makes the run INCOMPLETE -- never 0.
        event "cold_copy_skipped" "reason=no_container_stopped" "failed_dbs=${DB_FAILED}"
        warn "No container may be stopped for the failed databases, so they stay out of this snapshot; the run is INCOMPLETE."
        mark_incomplete "cold_copy_skipped:no_container_stopped"
      fi
    fi
  fi
fi

if (( DB_NONSQLITE > 0 )); then
  event "non_sqlite_db_skipped" "count=${DB_NONSQLITE}" \
        "paths=$(printf '%s,' "${NONSQLITE_DBS[@]}" | cut -c1-160)"
  warn "${DB_NONSQLITE} file(s) matched a database extension but are not SQLite; skipped."
fi

[[ "$MODE" == "dryrun" ]] || ok "Captured ${DB_COUNT} database(s) (${CONSISTENCY})."

# ---------------------------------------------------------------------------
# STEP 4b. Capture host and platform state
# ---------------------------------------------------------------------------
[[ "$MODE" == "dryrun" ]] || log "Capturing host and platform state..."
HOST_DIR="${STAGING_DIR}/host"

OLLAMA_MODEL_COUNT=0
if (( EXTERNAL_CONTAINER_CONTROL )); then
  # No docker command runs in this process. The root helper captured host
  # metadata that needs docker/systemctl (container images, ollama models and
  # their Modelfiles, platform details) into HOST_INFO_DIR; copy it in.
  if [[ -d "$HOST_INFO_DIR" ]]; then
    cp -a "${HOST_INFO_DIR}/." "${HOST_DIR}/" 2>/dev/null || true
  else
    event "external_host_info_missing"
    warn "External container control: no host info at ${HOST_INFO_DIR}; host metadata will be incomplete."
    mark_incomplete "external_control_unreadable:host_info"
  fi
  if [[ -f "${HOST_DIR}/ollama-models.txt" ]]; then
    OLLAMA_MODEL_COUNT="$(wc -l < "${HOST_DIR}/ollama-models.txt" 2>/dev/null | tr -d ' ')"
  fi
else
if is_running ollama; then
  docker exec ollama ollama list 2>/dev/null \
    | awk 'NR>1 {print $1}' > "${HOST_DIR}/ollama-models.txt" || true
  mkdir -p "${HOST_DIR}/modelfiles"
  while IFS= read -r m; do
    [[ -z "$m" ]] && continue
    safe="${m//[^A-Za-z0-9._-]/_}"
    docker exec ollama ollama show --modelfile "$m" \
      > "${HOST_DIR}/modelfiles/${safe}.Modelfile" 2>/dev/null || true
  done < "${HOST_DIR}/ollama-models.txt"
  OLLAMA_MODEL_COUNT="$(wc -l < "${HOST_DIR}/ollama-models.txt" 2>/dev/null | tr -d ' ')"
fi

if [[ -f "${HYBRID_AI_ENV_FILE}" ]]; then
  "${COMPOSE[@]}" config --images > "${HOST_DIR}/container-images.txt" 2>/dev/null || true
fi
fi   # end: docker-based host metadata (skipped under external control)

for f in docker-compose.yml docker-compose.override.yml; do
  if [[ -f "${HYBRID_AI_APP_DIR}/${f}" ]]; then
    cp -a "${HYBRID_AI_APP_DIR}/${f}" "${HOST_DIR}/${f}" 2>/dev/null || true
  fi
done

for d in openwebui openhands hermes scripts status; do
  if [[ -d "${HYBRID_AI_APP_DIR}/${d}" ]]; then
    mkdir -p "${HOST_DIR}/${d}"
    cp -a "${HYBRID_AI_APP_DIR}/${d}/." "${HOST_DIR}/${d}/" 2>/dev/null || true
  fi
done

if command -v git >/dev/null 2>&1 && [[ -d "${HYBRID_AI_APP_DIR}/.git" ]]; then
  {
    printf 'commit=%s\n' "$(git -C "$HYBRID_AI_APP_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
    printf 'branch=%s\n' "$(git -C "$HYBRID_AI_APP_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
    printf 'remote=%s\n' "$(git -C "$HYBRID_AI_APP_DIR" config --get remote.origin.url 2>/dev/null || echo none)"
    printf 'dirty=%s\n'  "$(git -C "$HYBRID_AI_APP_DIR" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  } > "${HOST_DIR}/git-state.txt" 2>/dev/null || true
  git -C "$HYBRID_AI_APP_DIR" diff HEAD > "${HOST_DIR}/uncommitted.patch" 2>/dev/null || true
  [[ -s "${HOST_DIR}/uncommitted.patch" ]] || rm -f "${HOST_DIR}/uncommitted.patch"
fi

{
  printf 'hostname=%s\n'       "$(hostname -s 2>/dev/null)"
  # shellcheck source=/dev/null
  printf 'os=%s\n'             "$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}")"
  printf 'kernel=%s\n'         "$(uname -r 2>/dev/null)"
  printf 'arch=%s\n'           "$(uname -m 2>/dev/null)"
  printf 'total_ram_mb=%s\n'   "$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)"
  if (( EXTERNAL_CONTAINER_CONTROL )); then
    # No docker command may run in this process; the helper's platform.txt (if
    # present) already carries the docker version.
    printf 'docker=%s\n'       "$(sed -n 's/^docker=//p' "${HOST_INFO_DIR}/platform.txt" 2>/dev/null | head -n1 || echo n/a)"
  else
    printf 'docker=%s\n'       "$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo n/a)"
  fi
  printf 'tailscale_host=%s\n' "$(tailscale status --json 2>/dev/null | jq -r '.Self.HostName // "unknown"' 2>/dev/null || echo unknown)"
  # In system mode the schedule is the system timer; in user mode the user timer.
  if [[ "$BACKUP_MODE" == "system" ]]; then
    printf 'backup_timer=%s\n' "$(systemctl is-enabled hybrid-ai-backup-capture.timer 2>/dev/null || echo unknown)"
  else
    printf 'backup_timer=%s\n' "$(systemctl --user is-enabled hybrid-ai-backup.timer 2>/dev/null || echo unknown)"
  fi
} > "${HOST_DIR}/platform.txt" 2>/dev/null || true

chmod -R go-rwx "$HOST_DIR" 2>/dev/null || true

# ---------------------------------------------------------------------------
# STEP 5. Write a manifest
# ---------------------------------------------------------------------------
# In --stage-only there are no credentials and no network, so restic is not
# available and its version is reported as "n/a". Every other mode asks restic.
if (( STAGE_ONLY )); then
  RESTIC_VERSION="n/a"
else
  RESTIC_VERSION="$(restic version 2>/dev/null | head -n1)"
fi

cat > "${STAGING_DIR}/MANIFEST.txt" <<MANIFEST
hybrid-ai backup manifest
=========================
created_utc        : $(date -u +%Y-%m-%dT%H:%M:%SZ)
source_host        : ${BACKUP_HOST}
consistency_method : ${CONSISTENCY}
run_status         : $( (( INCOMPLETE_COUNT > 0 )) && echo "incomplete" || echo "complete" )
databases_captured : ${DB_COUNT}
ollama_models      : ${OLLAMA_MODEL_COUNT:-0} (names only; weights not backed up)
restic_version     : ${RESTIC_VERSION}
layout             : repo-relative (v2)

Contents
--------
databases/   Consistent SQLite snapshots, repo-relative, discovered at run time
             (webui_data/... and hermes_data/...).
files/       Uploads, vector data, and the whole durable hermes_data tree
             (rebuildable/volatile content excluded), repo-relative.
hermes/      Durable ~/.hermes state; runtime/cache content excluded.
openhands/   ~/.openhands state; cache, temp, and logs excluded.
host/        Compose files, scripts, Caddyfile, model list, host metadata.
env/         Active .env configuration.

To restore, see backup/restore.sh in the hybrid-ai repository.
MANIFEST

# ---------------------------------------------------------------------------
# STEP 6. Stage the configuration file
# ---------------------------------------------------------------------------
if [[ -f "${HYBRID_AI_ENV_FILE}" ]]; then
  cp -a "${HYBRID_AI_ENV_FILE}" "${STAGING_DIR}/env/.env"
  chmod 600 "${STAGING_DIR}/env/.env"
fi

# An unreadable staged entry (from an incomplete rsync) can make du fail; that
# must not abort an otherwise-finished run via the ERR trap, so absorb it.
STAGED_MB="$(du -sm "$STAGING_DIR" 2>/dev/null | cut -f1 || true)"
STAGED_MB="${STAGED_MB:-?}"

# Write the STATUS file LAST, once the verdict is final. It carries fixed codes
# only (never a discovered name), and it is the handshake the upload unit reads.
write_status
}   # end stage_backup()

if [[ "$MODE" == "dryrun" ]]; then
  log "Dry run -- nothing will be uploaded."
  printf '\n  Staged %s MB:\n\n' "$STAGED_MB"
  find "$STAGING_DIR" -maxdepth 3 -mindepth 1 -printf '    %y %P\n' 2>/dev/null | head -40
  printf '\n  Repository: %s\n\n' "${RESTIC_REPOSITORY}"
  exit 0
fi

# ---------------------------------------------------------------------------
# STEP 7. Upload -- upload_backup()
#
# Only the staging directory is passed to restic. Live application data is
# never uploaded directly, guaranteeing every snapshot is consistent.
#
# An INCOMPLETE run still uploads -- partial data is worth keeping -- but it is
# tagged complete:false so a restore can see at a glance that durable state was
# missing, and it exits with EXIT_INCOMPLETE rather than reporting success.
# ---------------------------------------------------------------------------
upload_backup() {
log "Checking restic repository status..."
if ! restic snapshots >/dev/null 2>&1; then
  warn "Repository at ${RESTIC_REPOSITORY} is not initialized!"
  if (( NON_INTERACTIVE )) || [[ ! -t 0 ]]; then
    die "Repository uninitialized. Run: ./backup/backup.sh --init"
  fi
  read -r -p "  Initialize repository now? [Y/n]: " _init_ans < /dev/tty
  if [[ "${_init_ans,,}" != "n" ]]; then
    log "Initialising restic repository..."
    if restic init; then
      event "repo_initialised_on_demand" "host=${BACKUP_HOST}"
      ok "Repository initialized successfully."
    else
      die "Failed to initialize restic repository. Check credentials and bucket name."
    fi
  else
    die "Backup aborted: repository is not initialized."
  fi
fi

# In upload-only mode COMPLETE_TAG was taken from the STATUS file above; keep
# it. In a whole run it is derived from this process's own incomplete counter.
if (( ! UPLOAD_ONLY )); then
  if (( INCOMPLETE_COUNT > 0 )); then
    COMPLETE_TAG="complete:false"
  else
    COMPLETE_TAG="complete:true"
  fi
fi

log "Uploading to R2 (${STAGED_MB} MB staged, deduplicated against previous runs)..."
BACKUP_START=$SECONDS

if restic backup "$STAGING_DIR" \
      --host "$BACKUP_HOST" \
      --tag hybrid-ai \
      --tag "consistency:${CONSISTENCY}" \
      --tag "$COMPLETE_TAG" \
      --exclude-caches \
      --one-file-system 2>&1 | tee -a "$BACKUP_LOG"; then
  BACKUP_SECONDS=$(( SECONDS - BACKUP_START ))
  if (( INCOMPLETE_COUNT > 0 )); then
    event "backup_incomplete" "host=${BACKUP_HOST}" "staged_mb=${STAGED_MB}" \
          "databases=${DB_COUNT}" "consistency=${CONSISTENCY}" \
          "duration_s=${BACKUP_SECONDS}" "reasons=$(printf '%s,' "${INCOMPLETE_REASONS[@]}" | cut -c1-160)"
    warn "Backup uploaded but INCOMPLETE: durable state is missing from this snapshot."
  else
    event "backup_success" "host=${BACKUP_HOST}" "staged_mb=${STAGED_MB}" \
          "databases=${DB_COUNT}" "consistency=${CONSISTENCY}" \
          "duration_s=${BACKUP_SECONDS}"
    ok "Backup complete in ${BACKUP_SECONDS}s."
  fi
else
  die "restic backup failed. See ${BACKUP_LOG}."
fi

# ---------------------------------------------------------------------------
# STEP 8. Retention
# ---------------------------------------------------------------------------
log "Applying retention policy (${KEEP_DAILY}d / ${KEEP_WEEKLY}w / ${KEEP_MONTHLY}m)..."
if restic forget \
      --host "$BACKUP_HOST" \
      --tag hybrid-ai \
      --keep-daily "$KEEP_DAILY" \
      --keep-weekly "$KEEP_WEEKLY" \
      --keep-monthly "$KEEP_MONTHLY" \
      --prune 2>&1 | tee -a "$BACKUP_LOG"; then
  event "retention_applied" "daily=${KEEP_DAILY}" "weekly=${KEEP_WEEKLY}" "monthly=${KEEP_MONTHLY}"
  ok "Retention applied."
else
  warn "Retention step failed. Backup itself is safe."
  event "retention_failed" "severity=medium"
fi

# ---------------------------------------------------------------------------
# STEP 9. Report
# ---------------------------------------------------------------------------
SNAP_COUNT="$(restic snapshots --host "$BACKUP_HOST" --tag hybrid-ai --json 2>/dev/null | jq 'length' 2>/dev/null || echo '?')"
event "backup_run_complete" "snapshots_retained=${SNAP_COUNT}"

printf '\n'
ok "Done. ${SNAP_COUNT} snapshot(s) retained for host ${BACKUP_HOST}."
printf '    Restore with : ./backup/restore.sh\n'
printf '    Verify with  : ./backup/backup.sh --check\n\n'
}   # end upload_backup()

# --- Run ---------------------------------------------------------------------
#
# Three shapes, selected by the flags:
#   --stage-only   capture only; no credentials; keep staging + STATUS; exit 0/3
#   --upload-only  upload only; never reads a data tree; exit 0/3
#   (no flag)      stage then upload, exactly as today
#
# The ERR trap is cleared before a deliberate non-zero exit so it is not
# re-labelled a failure.
if (( STAGE_ONLY )); then
  stage_backup
  if (( INCOMPLETE_COUNT > 0 )); then
    ok "Capture finished INCOMPLETE; STATUS written for the upload unit."
    trap - ERR
    exit "$EXIT_INCOMPLETE"
  fi
  ok "Capture complete; STATUS written for the upload unit."
  exit 0
fi

if (( UPLOAD_ONLY )); then
  upload_backup
  # A successful upload consumes the staged data: remove STAGING_DIR so a later
  # run cannot re-upload stale plaintext. (A failed upload exits non-zero from
  # upload_backup and keeps the staging directory for a retry.)
  if [[ -d "$STAGING_DIR" ]]; then
    rm -rf "$STAGING_DIR" 2>/dev/null || true
  fi
  if (( INCOMPLETE_COUNT > 0 )); then
    trap - ERR
    exit "$EXIT_INCOMPLETE"
  fi
  exit 0
fi

stage_backup
upload_backup
if (( INCOMPLETE_COUNT > 0 )); then
  trap - ERR
  exit "$EXIT_INCOMPLETE"
fi
