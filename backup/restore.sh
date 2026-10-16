#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: backup/restore.sh
# PURPOSE (plain English):
#   Brings your data back after a disaster -- a failed disk, a new Pi, or an
#   accidental deletion. It walks you through picking a snapshot, downloads it,
#   and puts everything back where it belongs.
#
#   It is deliberately cautious. Restoring overwrites live data, so the script
#   stops the application first, moves anything currently there to a
#   timestamped safety copy, and asks you to type "RESTORE" before proceeding.
#
# SNAPSHOT LAYOUT (written by backup.sh):
#   databases/webui_data/...   SQLite snapshots, paths relative to the repo
#   databases/hermes_data/...  Hermes SQLite snapshots, paths relative to hermes_data
#   files/webui_data/...       uploads and non-DB vector data
#   files/hermes_data/...      durable Hermes state from the repo directory
#   hermes/                    ~/.hermes durable state
#   openhands/                 ~/.openhands state
#   host/  env/  MANIFEST.txt
#   Very old snapshots stored databases/ relative to webui_data instead; both
#   layouts are detected automatically.
#
# PRE-RESTORE SAFETY COPY (hermes_data.pre-restore-<stamp>):
#   Files overwritten under hermes_data, plus the sidecars of every database we
#   restore, are preserved here using ONE layout: every path is relative to
#   hermes_data (e.g. config.yaml, profiles/<p>/state.db, and each moved
#   <db>-wal / <db>-shm / <db>-journal beside the path of the database it
#   belongs to).
#
# USAGE:
#   ./restore.sh                     interactive: pick from a list of snapshots
#   ./restore.sh --snapshot <id>     restore a specific snapshot
#   ./restore.sh --latest            restore the newest snapshot, still prompts
#   ./restore.sh --list              just list snapshots and exit
#   ./restore.sh --test              restore to a scratch directory and verify,
#                                    touching nothing live. DO THIS QUARTERLY.
#
# RESTORING ONTO A BRAND-NEW PI:
#   1. Work through the Prerequisites in the main README.
#   2. git clone the repository.
#   3. Recreate the credential directory with your R2 credentials and the
#      repository password you stored in your password manager. In user mode
#      that is ~/.config/hybrid-ai-backup/; in system mode the units read them
#      from the root-owned credstore, /etc/credstore/hybrid-ai-backup/ (see
#      backup/README.md). Both resolve to HYBRID_AI_BACKUP_CRED_DIR.
#   4. Run this script. It restores .env too, so you do not need to re-enter
#      your RunPod details.
#   5. Run ./install.sh
#   6. Re-pull your Ollama models -- weights are not backed up by design.
# ---------------------------------------------------------------------------
set -Eeuo pipefail

# Every host path comes from the ONE shared helper. With no settings, the
# resolved paths are exactly today's.
HYBRID_AI_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../scripts/lib" && pwd)"
# shellcheck source=scripts/lib/hybrid-ai-env.sh
source "${HYBRID_AI_LIB_DIR}/hybrid-ai-env.sh"
cd "$HYBRID_AI_APP_DIR" || exit 1

# Credentials come from HYBRID_AI_BACKUP_CRED_DIR: the ONE setting that resolves
# to the root-owned credstore in system mode and to BACKUP_CONF_DIR in user mode,
# so a manual system-mode restore finds them where the units keep them.
R2_ENV_FILE="${HYBRID_AI_BACKUP_CRED_DIR}/r2.env"
RESTIC_PW_FILE="${HYBRID_AI_BACKUP_CRED_DIR}/repo-password"
RESTORE_WORK="$HYBRID_AI_RESTORE_WORK_DIR"

# --- THE CONTROL: credentials must not sit inside the app/data/work trees ---
# Same boundary as backup.sh: the credential directory must not be swept up by
# a git operation or by the very data this script restores. Restore ALWAYS reads
# a credential file, so unlike a capture there is no phase to exempt.
path_within() { [[ "$1" == "$2" || "$1" == "$2"/* ]]; }
for _tree in "$HYBRID_AI_APP_DIR" "$HYBRID_AI_DATA_DIR" "$HYBRID_AI_WORK_DIR"; do
  if path_within "${HYBRID_AI_BACKUP_CRED_DIR%/}" "${_tree%/}"; then
    printf '[ X ] HYBRID_AI_BACKUP_CRED_DIR is inside %s.\n' "$_tree" >&2
    printf '     Backup credentials must live OUTSIDE the app, data and work directories.\n' >&2
    exit 1
  fi
done
unset _tree

# Every container that can touch webui_data or hermes_data, stopped by NAME so
# overlay services (OpenHands, Hermes) are included and a stale .env cannot
# block the stop. Order: front-ends first, Ollama last.
STACK_CONTAINERS=(hybrid-ai-proxy hybrid-ai-status hybrid-ai-openhands hermes-agent open-webui ollama)

SNAPSHOT_ID=""
MODE="interactive"
STAMP="$(date +%Y%m%d-%H%M%S)"
SAFETY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --snapshot) SNAPSHOT_ID="${2:-}"; MODE="direct"; shift 2 ;;
    --latest)   SNAPSHOT_ID="latest"; MODE="direct"; shift ;;
    --list)     MODE="list"; shift ;;
    --test)     MODE="test"; shift ;;
    -h|--help)  sed -n '2,51p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ "$MODE" != "direct" || -n "$SNAPSHOT_ID" ]] || { echo "--snapshot needs an id" >&2; exit 2; }

if [[ -t 1 ]]; then
  C_RST=$'\033[0m'; C_INF=$'\033[36m'; C_OK=$'\033[32m'
  C_WRN=$'\033[33m'; C_ERR=$'\033[31m'; C_DIM=$'\033[2m'
else
  C_RST=""; C_INF=""; C_OK=""; C_WRN=""; C_ERR=""; C_DIM=""
fi
log()  { printf '%s[ * ]%s %s\n'  "$C_INF" "$C_RST" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_OK"  "$C_RST" "$*"; }
warn() { printf '%s[ ! ]%s %s\n'  "$C_WRN" "$C_RST" "$*" >&2; }
hr()   { printf '%s%s%s\n' "$C_DIM" "------------------------------------------------------------" "$C_RST"; }

event() {
  local name="$1"; shift
  printf 'EVENT ts=%s event=%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$name" "$*" \
    | tee -a "$BACKUP_LOG" 2>/dev/null || true
}

die() {
  event "restore_failed" "detail=$(printf '%s' "$*" | tr -d '\n' | cut -c1-160)"
  printf '%s[ X ]%s %s\n' "$C_ERR" "$C_RST" "$*" >&2
  exit 1
}
trap 'die "Failed at line ${LINENO}: ${BASH_COMMAND}"' ERR

# Ask a y/N question on the terminal. Returns 0 for yes.
confirm_yes() {
  local ans=""
  read -r -p "$1 [y/N]: " ans < /dev/tty || true
  [[ "${ans,,}" == "y" ]]
}

# --- Credentials -----------------------------------------------------------
[[ -f "$R2_ENV_FILE" ]] || die "No credentials at ${R2_ENV_FILE}.
If this is a rebuilt Pi, recreate that file with your R2 keys and repository
password before running this script. See backup/README.md."
[[ -f "$RESTIC_PW_FILE" ]] || die "No repository password at ${RESTIC_PW_FILE}."

# SECURITY: parsed line by line rather than sourced. 'source' executes the
# file as shell code, so a value containing $(...) would run as a command.
while IFS= read -r _line || [[ -n "$_line" ]]; do
  [[ "$_line" =~ ^[[:space:]]*# ]] && continue
  [[ "$_line" =~ ^[[:space:]]*$ ]] && continue
  if [[ "$_line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
    _k="${BASH_REMATCH[1]}"; _v="${BASH_REMATCH[2]}"
    _v="${_v%\"}"; _v="${_v#\"}"; _v="${_v%\'}"; _v="${_v#\'}"
    printf -v "$_k" '%s' "$_v"; export "${_k?}"
  fi
done < "$R2_ENV_FILE"
unset _line _k _v
export RESTIC_PASSWORD_FILE="$RESTIC_PW_FILE"

command -v restic >/dev/null 2>&1 || die "restic is not installed."
restic snapshots >/dev/null 2>&1 || die "Cannot reach the repository. Check credentials and network."

# Count DB files and how many pass SQLite's own integrity check.
# Sets TOTAL, GOOD, UNVERIFIED. Prints per-file results when $2 == verbose.
verify_databases() {
  local dir="$1" verbose="${2:-}" db
  TOTAL=0; GOOD=0; UNVERIFIED=0
  while IFS= read -r -d '' db; do
    TOTAL=$(( TOTAL + 1 ))
    if ! command -v sqlite3 >/dev/null 2>&1; then
      GOOD=$(( GOOD + 1 )); UNVERIFIED=1; continue
    fi
    if [[ "$(sqlite3 "$db" 'PRAGMA integrity_check;' 2>/dev/null | head -n1)" == "ok" ]]; then
      GOOD=$(( GOOD + 1 ))
      [[ "$verbose" == "verbose" ]] && printf '    %sOK%s  %s\n' "$C_OK" "$C_RST" "${db#"${dir}/"}"
    else
      [[ "$verbose" == "verbose" ]] && printf '    %sBAD%s %s\n' "$C_ERR" "$C_RST" "${db#"${dir}/"}"
    fi
  done < <(find "$dir" -type f \( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' \) -print0)
  return 0
}

# ---------------------------------------------------------------------------
# --list
# ---------------------------------------------------------------------------
if [[ "$MODE" == "list" ]]; then
  hr; printf '  Available snapshots\n'; hr
  restic snapshots --tag hybrid-ai
  exit 0
fi

# ---------------------------------------------------------------------------
# --test : rehearsal
#
# The only backup you can trust is one you have restored. This performs a
# complete restore into a scratch directory and runs SQLite's integrity check
# against the recovered databases. It touches nothing live.
# ---------------------------------------------------------------------------
if [[ "$MODE" == "test" ]]; then
  TEST_DIR="${HYBRID_AI_WORK_DIR}/.restore-test-${STAMP}"
  log "Test restore into ${TEST_DIR} (nothing live is touched)..."
  mkdir -p "$TEST_DIR"
  restic restore latest --tag hybrid-ai --target "$TEST_DIR" || die "Test restore failed."

  STAGED="$(find "$TEST_DIR" -type d -name databases | head -n1)"
  [[ -n "$STAGED" ]] || die "Restored data contains no databases/ directory."

  if ! command -v sqlite3 >/dev/null 2>&1; then
    warn "sqlite3 is not installed, so database integrity cannot be verified."
    warn "The download itself succeeded. Install it for a real test:"
    printf '      sudo apt-get install -y sqlite3\n\n'
    event "restore_test_unverified" "reason=sqlite3_missing"
    printf '  Downloaded copy is at %s\n\n' "$TEST_DIR"
    exit 0
  fi

  log "Verifying recovered databases..."
  verify_databases "$STAGED" verbose

  hr
  MANIFEST="$(find "$TEST_DIR" -name MANIFEST.txt | head -n1)"
  if [[ -f "$MANIFEST" ]]; then cat "$MANIFEST"; fi
  hr

  if (( TOTAL > 0 && GOOD == TOTAL )); then
    event "restore_test_success" "databases=${TOTAL}"
    ok "All ${TOTAL} database(s) passed integrity checks. Your backups are restorable."
  else
    event "restore_test_failed" "databases=${TOTAL}" "passed=${GOOD}" "severity=critical"
    die "Only ${GOOD}/${TOTAL} databases verified. Investigate before relying on these backups."
  fi
  printf '  Scratch copy left at %s\n' "$TEST_DIR"
  printf '  Remove it when finished: rm -rf %s\n\n' "$TEST_DIR"
  exit 0
fi

# ---------------------------------------------------------------------------
# Interactive snapshot selection
# ---------------------------------------------------------------------------
if [[ "$MODE" == "interactive" ]]; then
  hr; printf '  Available snapshots\n'; hr
  restic snapshots --tag hybrid-ai --compact
  hr
  read -r -p "  Snapshot ID to restore (or 'latest'): " SNAPSHOT_ID < /dev/tty
  [[ -n "$SNAPSHOT_ID" ]] || die "No snapshot selected."
fi

# ---------------------------------------------------------------------------
# Download
# ---------------------------------------------------------------------------
log "Downloading snapshot ${SNAPSHOT_ID}..."
rm -rf "$RESTORE_WORK"; mkdir -p "$RESTORE_WORK"; chmod 700 "$RESTORE_WORK"
restic restore "$SNAPSHOT_ID" --tag hybrid-ai --target "$RESTORE_WORK" || die "Download failed."

STAGED="$(find "$RESTORE_WORK" -type d -name databases | head -n1)"
[[ -n "$STAGED" ]] || die "Snapshot has no databases/ directory. Wrong snapshot?"
STAGED_ROOT="$(dirname "$STAGED")"

# Repo-relative layout (databases/webui_data/... or databases/hermes_data/...)
# vs legacy (databases/webui.db, i.e. relative to webui_data).
if [[ -d "${STAGED}/webui_data" || -d "${STAGED}/hermes_data" ]]; then
  DB_DEST_ROOT="$HYBRID_AI_DATA_DIR"
  LAYOUT="repo-relative"
else
  DB_DEST_ROOT="${HYBRID_AI_DATA_DIR}/webui_data"
  LAYOUT="legacy"
fi

hr
if [[ -f "${STAGED_ROOT}/MANIFEST.txt" ]]; then cat "${STAGED_ROOT}/MANIFEST.txt"; fi
printf '  detected layout    : %s\n' "$LAYOUT"
hr

# --- Verify BEFORE overwriting anything ------------------------------------
log "Verifying recovered databases before touching live data..."
verify_databases "$STAGED"

if (( TOTAL == 0 )); then
  die "No databases found in the snapshot."
elif (( GOOD < TOTAL )); then
  warn "Only ${GOOD}/${TOTAL} databases passed integrity checks."
  read -r -p "  Continue anyway? Type YES to proceed: " c < /dev/tty
  [[ "$c" == "YES" ]] || die "Aborted by user."
elif (( UNVERIFIED )); then
  warn "sqlite3 is not installed, so integrity could NOT be verified."
  warn "Install it (sudo apt-get install -y sqlite3) for a safer restore."
else
  ok "${TOTAL}/${TOTAL} databases verified."
fi

# --- Confirm ---------------------------------------------------------------
hr
printf '  %sThis will replace the live contents of webui_data and hermes_data.%s\n' "$C_WRN" "$C_RST"
printf '  Current data will be preserved aside, not deleted.\n'
printf '  All containers will be stopped for the duration.\n'
hr
read -r -p "  Type RESTORE to proceed: " confirm < /dev/tty
[[ "$confirm" == "RESTORE" ]] || die "Aborted by user."

# ---------------------------------------------------------------------------
# Stop the application
#
# More than one container touches the data being replaced: open-webui writes
# webui.db and Chroma, the proxy writes Caddy state into webui_data/caddy, the
# status page holds a read handle on webui.db, and Hermes writes hermes_data.
# Stopping everything is robust to future containers being added.
# ---------------------------------------------------------------------------
if command -v docker >/dev/null 2>&1; then
  log "Stopping all containers for a clean restore..."
  for c in "${STACK_CONTAINERS[@]}"; do
    docker inspect "$c" >/dev/null 2>&1 || continue
    docker stop "$c" >/dev/null 2>&1 || warn "Could not stop ${c}; make sure it is not writing data."
  done
  sleep 3
  ok "Stack stopped."
fi

# --- Move existing data aside ----------------------------------------------
# webui_data is replaced wholesale, so it is simply moved aside.
if [[ -d "${HYBRID_AI_DATA_DIR}/webui_data" ]]; then
  SAFETY="${HYBRID_AI_DATA_DIR}/webui_data.pre-restore-${STAMP}"
  log "Preserving current data at $(basename "$SAFETY")"
  mv "${HYBRID_AI_DATA_DIR}/webui_data" "$SAFETY"
  event "pre_restore_snapshot_kept" "path=$(basename "$SAFETY")"
fi
mkdir -p "${HYBRID_AI_DATA_DIR}/webui_data"

# hermes_data is ONLY ever merged, never moved wholesale: it holds large,
# rebuildable excluded directories (tools/, hermes-agent/, ...) that must never
# be disturbed, and live files absent from the backup must survive. Overwritten
# files are preserved under hermes_data.pre-restore-<stamp>, and the rsync has
# no --delete flag. Everything preserved there uses ONE layout: every path is
# relative to hermes_data, so a preserved database lands at
# <dir>/profiles/<p>/state.db, never <dir>/hermes_data/profiles/<p>/state.db.
HERMES_BACKUP_DIR=""
RESTORED_HERMES_FILES=0

# Map a repo-relative live Hermes path to its place in the pre-restore dir, by
# stripping the hermes_data/ prefix (the one layout used for everything there).
hermes_backup_path() { printf '%s/%s' "$HERMES_BACKUP_DIR" "${1#hermes_data/}"; }

# --- Files first, then databases -------------------------------------------
if [[ -d "${STAGED_ROOT}/files" ]]; then
  log "Restoring documents and durable state..."
  if [[ -d "${STAGED_ROOT}/files/webui_data" || -d "${STAGED_ROOT}/files/hermes_data" ]]; then
    # Repo-relative: files/webui_data -> webui_data, files/hermes_data -> hermes_data
    if [[ -d "${STAGED_ROOT}/files/webui_data" ]]; then
      rsync -a "${STAGED_ROOT}/files/webui_data/" "${HYBRID_AI_DATA_DIR}/webui_data/" || die "Document restore failed."
    fi
    if [[ -d "${STAGED_ROOT}/files/hermes_data" ]]; then
      mkdir -p "${HYBRID_AI_DATA_DIR}/hermes_data"
      HERMES_BACKUP_DIR="${HYBRID_AI_DATA_DIR}/hermes_data.pre-restore-${STAMP}"
      log "Preserving overwritten hermes_data files under $(basename "$HERMES_BACKUP_DIR")"
      rsync -a --backup --backup-dir="$HERMES_BACKUP_DIR" \
        "${STAGED_ROOT}/files/hermes_data/" "${HYBRID_AI_DATA_DIR}/hermes_data/" || die "Hermes state restore failed."
    fi
  else
    # Legacy: files/ was relative to webui_data.
    rsync -a "${STAGED_ROOT}/files/" "${HYBRID_AI_DATA_DIR}/webui_data/" || die "Document restore failed."
  fi
fi

# Databases go last so they overwrite any same-named file from files/.
#
# For each database ACTUALLY RESTORED under hermes_data we:
#   - preserve the overwritten live database TOGETHER WITH ITS OWN SIDECARS
#     (<db>-wal, <db>-shm, <db>-journal), so the preserved copy opens with the
#     same rows the live database had; and
#   - move those same sidecars into the pre-restore dir, so no restored
#     database is left with a stale sidecar that could be read as newer and
#     corrupt it.
# Only the three exact sidecars of a database we restore are ever touched.
# Nothing is matched by a name glob such as '*.db-*', so unrelated files (a
# live DB not in the backup, its sidecars, workspace/schema.db-notes.md) and
# everything under excluded rebuildable directories are left alone.
#
# If preserving the live database (its main file) or moving one of its sidecars
# aside FAILS -- e.g. a full disk -- that database is SKIPPED, never
# overwritten: overwriting it would destroy it with no safety copy, which this
# card forbids. Skipped databases are counted and reported.
log "Restoring databases (${LAYOUT} layout)..."
RESTORE_SKIPPED=0
RESTORE_SKIPPED_LIST=()
while IFS= read -r -d '' db; do
  rel="${db#"${STAGED}/"}"
  dest="${DB_DEST_ROOT}/${rel}"
  mkdir -p "$(dirname "$dest")"

  if [[ "$DB_DEST_ROOT" == "$HYBRID_AI_DATA_DIR" && "$rel" == hermes_data/* ]]; then
    [[ -n "$HERMES_BACKUP_DIR" ]] || HERMES_BACKUP_DIR="${HYBRID_AI_DATA_DIR}/hermes_data.pre-restore-${STAMP}"

    # Preserve the live database's main file (if it is there). If the copy
    # FAILS (e.g. a full disk) we must NOT overwrite the live database: that
    # would destroy it with no safety copy. Skip this database and report it,
    # matching the rsync --backup path.
    if [[ -f "$dest" ]]; then
      mkdir -p "$(dirname "$(hermes_backup_path "$rel")")"
      if ! cp -a "$dest" "$(hermes_backup_path "$rel")" 2>/dev/null; then
        warn "Could not preserve live ${rel}; SKIPPING its restore to avoid destroying it."
        event "hermes_db_preserve_failed" "path=${rel}" "action=skipped"
        RESTORE_SKIPPED=$(( RESTORE_SKIPPED + 1 ))
        RESTORE_SKIPPED_LIST+=("$rel")
        continue
      fi
    fi

    # Move THIS database's own sidecars aside (preserved AND removed from beside
    # the restored database in one step, so no stale sidecar can be read as
    # newer). A move failure leaves the database with a stale sidecar, so we
    # likewise skip it rather than overwrite.
    skip=0
    for sfx in -wal -shm -journal; do
      if [[ -f "${dest}${sfx}" ]]; then
        mkdir -p "$(dirname "$(hermes_backup_path "${rel}${sfx}")")"
        if ! mv "${dest}${sfx}" "$(hermes_backup_path "${rel}${sfx}")" 2>/dev/null; then
          warn "Could not move aside stale sidecar ${rel}${sfx}; SKIPPING its restore."
          event "hermes_db_preserve_failed" "path=${rel}${sfx}" "action=skipped"
          RESTORE_SKIPPED=$(( RESTORE_SKIPPED + 1 ))
          RESTORE_SKIPPED_LIST+=("$rel")
          skip=1
          break
        fi
      fi
    done
    (( skip )) && continue
  fi

  if ! cp -a "$db" "$dest"; then
    warn "Could not write restored database ${rel}; it was not restored."
    event "hermes_db_restore_failed" "path=${rel}"
    RESTORE_SKIPPED=$(( RESTORE_SKIPPED + 1 ))
    RESTORE_SKIPPED_LIST+=("$rel")
    continue
  fi
done < <(find "$STAGED" -type f -print0)

if (( RESTORE_SKIPPED > 0 )); then
  event "restore_skipped_databases" "count=${RESTORE_SKIPPED}" \
        "paths=$(printf '%s,' "${RESTORE_SKIPPED_LIST[@]}" | cut -c1-160)"
  warn "${RESTORE_SKIPPED} database(s) were NOT restored (see above). Those live databases were left untouched."
fi

# Report the pre-restore safety copy (its location and how much it holds).
if [[ -n "$HERMES_BACKUP_DIR" && -d "$HERMES_BACKUP_DIR" ]]; then
  RESTORED_HERMES_FILES="$(find "$HERMES_BACKUP_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')"
fi
if [[ -n "$HERMES_BACKUP_DIR" && -d "$HERMES_BACKUP_DIR" && "$RESTORED_HERMES_FILES" != "0" ]]; then
  ok "Pre-restore copy of overwritten hermes_data files: $(basename "$HERMES_BACKUP_DIR") (${RESTORED_HERMES_FILES} file(s))"
  event "hermes_pre_restore_backup_kept" "path=$(basename "$HERMES_BACKUP_DIR")" "files=${RESTORED_HERMES_FILES}"
else
  if [[ -n "$HERMES_BACKUP_DIR" ]]; then
    rmdir "$HERMES_BACKUP_DIR" 2>/dev/null || true
  fi
  HERMES_BACKUP_DIR=""
  printf '  No existing hermes_data files needed preserving.\n'
fi

# Caddy needs this directory before the proxy starts again.
mkdir -p "${HYBRID_AI_DATA_DIR}/webui_data/caddy"

# --- Home-directory state (~/.hermes, ~/.openhands) -------------------------
# Offered, not forced: on an existing Pi the live copy is usually newer.
restore_home_dir() {
  local src="$1" dest="$2" label="$3"
  [[ -d "$src" ]] || return 0
  [[ -n "$(ls -A "$src" 2>/dev/null)" ]] || return 0
  if [[ -d "$dest" && -n "$(ls -A "$dest" 2>/dev/null)" ]]; then
    if ! confirm_yes "  ${dest} already exists. Replace it with the ${label} from the backup?"; then
      printf '    Kept the existing %s. Backup copy: %s\n' "$dest" "$src"
      return 0
    fi
    mv "$dest" "${dest}.pre-restore-${STAMP}"
    ok "Existing ${label} moved to ${dest}.pre-restore-${STAMP}"
  fi
  mkdir -p "$dest"
  rsync -a "${src}/" "${dest}/" || { warn "Could not restore ${label}."; return 0; }
  ok "Restored ${label} to ${dest}"
}
restore_home_dir "${STAGED_ROOT}/hermes"    "${HYBRID_AI_HERMES_HOME_DIR}"    "Hermes state"
restore_home_dir "${STAGED_ROOT}/openhands" "${OPENHANDS_STATE_DIR}" "OpenHands state"
if [[ -d "${OPENHANDS_STATE_DIR}" ]]; then chmod 700 "${OPENHANDS_STATE_DIR}" 2>/dev/null || true; fi

# --- .env ------------------------------------------------------------------
if [[ -f "${STAGED_ROOT}/env/.env" ]]; then
  if [[ -f "${HYBRID_AI_ENV_FILE}" ]]; then
    cp -a "${STAGED_ROOT}/env/.env" "${HYBRID_AI_ENV_FILE}.restored-${STAMP}"
    chmod 600 "${HYBRID_AI_ENV_FILE}.restored-${STAMP}"
    ok "Kept the existing .env. Backup copy saved as .env.restored-${STAMP} (0600)."
  else
    cp -a "${STAGED_ROOT}/env/.env" "${HYBRID_AI_ENV_FILE}"
    chmod 600 "${HYBRID_AI_ENV_FILE}"
    ok "Restored .env (0600). Your RunPod settings are back."
  fi
fi

# ---------------------------------------------------------------------------
# Restore host and platform state
# ---------------------------------------------------------------------------
HOST_SRC="${STAGED_ROOT}/host"
if [[ -d "$HOST_SRC" ]]; then
  hr
  log "Restoring host state..."

  if [[ -f "${HOST_SRC}/docker-compose.override.yml" ]]; then
    if [[ ! -f "${HYBRID_AI_APP_DIR}/docker-compose.override.yml" ]]; then
      cp -a "${HOST_SRC}/docker-compose.override.yml" "${HYBRID_AI_APP_DIR}/"
      ok "Restored docker-compose.override.yml"
    else
      warn "Existing docker-compose.override.yml kept; backup copy is in ${HOST_SRC}"
    fi
  fi

  # Only offered when the backed-up copy differs from what is in git.
  for f in status/Caddyfile status/app.py; do
    [[ -f "${HOST_SRC}/${f}" ]] || continue
    if [[ ! -f "${HYBRID_AI_APP_DIR}/${f}" ]]; then
      mkdir -p "$(dirname "${HYBRID_AI_APP_DIR}/${f}")"
      cp -a "${HOST_SRC}/${f}" "${HYBRID_AI_APP_DIR}/${f}"
      ok "Restored ${f}"
    elif ! cmp -s "${HOST_SRC}/${f}" "${HYBRID_AI_APP_DIR}/${f}"; then
      warn "${f} differs from the version in git."
      if confirm_yes "    Restore the backed-up copy over it?"; then
        cp -a "${HOST_SRC}/${f}" "${HYBRID_AI_APP_DIR}/${f}"
        ok "Restored ${f}"
      else
        printf '    Kept the git version. Backup copy: %s\n' "${HOST_SRC}/${f}"
      fi
    fi
  done

  if [[ -f "${HOST_SRC}/uncommitted.patch" ]]; then
    warn "This deployment had uncommitted local changes."
    printf '    Review and apply with:\n      git apply %s\n' "${HOST_SRC}/uncommitted.patch"
  fi

  if [[ -f "${HOST_SRC}/git-state.txt" ]]; then
    printf '\n  Source deployment was running:\n'
    sed 's/^/    /' "${HOST_SRC}/git-state.txt"
    printf '\n'
  fi

  # --- Re-pull Ollama models -----------------------------------------------
  if [[ -s "${HOST_SRC}/ollama-models.txt" ]]; then
    MODEL_TOTAL="$(wc -l < "${HOST_SRC}/ollama-models.txt" | tr -d ' ')"
    hr
    printf '  The source system had %s Ollama model(s):\n\n' "$MODEL_TOTAL"
    sed 's/^/    - /' "${HOST_SRC}/ollama-models.txt"
    printf '\n  Weights are not backed up (they are large and re-downloadable).\n'
    hr
    read -r -p "  Re-pull them now? This needs bandwidth and time. [Y/n]: " _pull < /dev/tty
    if [[ "${_pull,,}" != "n" ]]; then
      if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'ollama'; then
        log "Starting Ollama..."
        # Existing container first; compose fallback covers a brand-new Pi.
        # Ollama is defined in the main file, so that file alone is enough.
        docker start ollama >/dev/null 2>&1 || \
          docker compose -p hybrid-ai --env-file "${HYBRID_AI_STACK_ENV_FILE}" \
            --project-directory "${HYBRID_AI_APP_DIR}" \
            -f "${HYBRID_AI_APP_DIR}/docker-compose.yml" up -d ollama >/dev/null 2>&1 || true
        sleep 10
      fi
      PULLED=0; FAILED=0
      while IFS= read -r m; do
        [[ -z "$m" ]] && continue
        log "Pulling ${m}..."
        if docker exec ollama ollama pull "$m" 2>&1 | tail -1; then
          PULLED=$(( PULLED + 1 ))
        else
          FAILED=$(( FAILED + 1 ))
          warn "Failed to pull ${m} -- pull it manually later."
        fi
      done < "${HOST_SRC}/ollama-models.txt"
      event "models_repulled" "pulled=${PULLED}" "failed=${FAILED}"
      ok "Re-pulled ${PULLED}/${MODEL_TOTAL} model(s)."
    else
      printf '\n  Re-pull later with:\n'
      sed 's|^|    docker exec -it ollama ollama pull |' "${HOST_SRC}/ollama-models.txt"
      printf '\n'
    fi
  fi

  if [[ -d "${HOST_SRC}/modelfiles" ]] && compgen -G "${HOST_SRC}/modelfiles/*.Modelfile" >/dev/null 2>&1; then
    warn "Custom Modelfiles were captured. If any model failed to pull, it was"
    warn "probably built locally. Recreate it with:"
    printf '    docker cp %s/modelfiles ollama:/tmp/\n' "$HOST_SRC"
    printf '    docker exec -it ollama ollama create <name> -f /tmp/modelfiles/<file>\n\n'
  fi
fi

# --- Ownership -------------------------------------------------------------
# Restored files must be owned by the invoking user, or containers fail with
# permission errors that look like data corruption.
for d in webui_data hermes_data; do
  if [[ -d "${HYBRID_AI_DATA_DIR}/${d}" ]]; then
    chown -R "$(id -u):$(id -g)" "${HYBRID_AI_DATA_DIR}/${d}" 2>/dev/null || true
  fi
done

event "restore_success" "snapshot=${SNAPSHOT_ID}" "databases=${TOTAL}" "layout=${LAYOUT}"
rm -rf "$RESTORE_WORK"

# --- Restart ---------------------------------------------------------------
hr
ok "Restore complete."
hr
cat <<NEXT

  The whole stack was stopped for the restore. Bring it back with:

    1. Start everything:
         ./install.sh

    2. Open the UI and confirm the following came back:
         - chat history and folders
         - uploaded documents and knowledge bases
         - model connections (Workspace -> Connections)
         - functions / pipes AND their valve settings
         - users, groups and permissions
         - the status page at http://<this-pi>/status

    3. Re-authenticate this machine to your tailnet if it is a new Pi:
         sudo tailscale up

    4. Confirm everything is healthy:
         ./doctor.sh

    5. Once satisfied, remove the safety copies:
         rm -rf ${SAFETY:-webui_data.pre-restore-*}
         rm -rf hermes_data.pre-restore-*

NEXT
