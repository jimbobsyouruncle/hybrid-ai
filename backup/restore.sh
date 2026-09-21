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
#   3. Recreate ~/.config/hybrid-ai-backup/ with your R2 credentials and the
#      repository password you stored in your password manager.
#   4. Run this script. It will restore .env too, so you do not need to
#      re-enter your RunPod details.
#   5. Run ./install.sh
#   6. Re-pull your Ollama models -- weights are not backed up by design.
# ---------------------------------------------------------------------------
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_DIR"

BACKUP_CONF_DIR="${BACKUP_CONF_DIR:-${HOME}/.config/hybrid-ai-backup}"
R2_ENV_FILE="${BACKUP_CONF_DIR}/r2.env"
RESTIC_PW_FILE="${BACKUP_CONF_DIR}/repo-password"
RESTORE_WORK="${REPO_DIR}/.restore-work"
BACKUP_LOG="${BACKUP_LOG:-${REPO_DIR}/backup.log}"

SNAPSHOT_ID=""
MODE="interactive"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --snapshot) SNAPSHOT_ID="${2:-}"; MODE="direct"; shift 2 ;;
    --latest)   SNAPSHOT_ID="latest"; MODE="direct"; shift ;;
    --list)     MODE="list"; shift ;;
    --test)     MODE="test"; shift ;;
    -h|--help)  sed -n '2,36p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

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

# --- Credentials -----------------------------------------------------------
[[ -f "$R2_ENV_FILE" ]] || die "No credentials at ${R2_ENV_FILE}.
If this is a rebuilt Pi, recreate that file with your R2 keys and repository
password before running this script. See backup/README.md."
[[ -f "$RESTIC_PW_FILE" ]] || die "No repository password at ${RESTIC_PW_FILE}."

# SECURITY: parsed line by line rather than `source`d. `source` executes the
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
# WHY THIS EXISTS: the only backup you can trust is one you have restored.
# This performs a complete restore into a scratch directory and runs SQLite's
# own integrity check against the recovered databases. It touches nothing
# live, so it is safe to run on a working system -- and you should, quarterly.
# ---------------------------------------------------------------------------
if [[ "$MODE" == "test" ]]; then
  TEST_DIR="${REPO_DIR}/.restore-test-$(date +%Y%m%d-%H%M%S)"
  log "Test restore into ${TEST_DIR} (nothing live is touched)..."
  mkdir -p "$TEST_DIR"

  restic restore latest --tag hybrid-ai --target "$TEST_DIR" || die "Test restore failed."

  STAGED="$(find "$TEST_DIR" -type d -name databases | head -n1)"
  [[ -n "$STAGED" ]] || die "Restored data contains no databases/ directory."

  # Without sqlite3 we cannot verify anything. Say so plainly rather than
  # reporting a scary "0/N verified" failure that only means "no tool".
  if ! command -v sqlite3 >/dev/null 2>&1; then
    warn "sqlite3 is not installed, so database integrity cannot be verified."
    warn "The download itself succeeded. Install it for a real test:"
    printf '      sudo apt-get install -y sqlite3\n\n'
    event "restore_test_unverified" "reason=sqlite3_missing"
    printf '  Downloaded copy is at %s\n\n' "$TEST_DIR"
    exit 0
  fi

  log "Verifying recovered databases..."
  TOTAL=0; GOOD=0
  while IFS= read -r -d '' db; do
    TOTAL=$(( TOTAL + 1 ))
    # "PRAGMA integrity_check" is SQLite auditing its own file. This is the
    # step that proves the consistent-snapshot logic in backup.sh worked.
    if [[ "$(sqlite3 "$db" 'PRAGMA integrity_check;' 2>/dev/null | head -n1)" == "ok" ]]; then
      GOOD=$(( GOOD + 1 ))
      printf '    %sOK%s  %s\n' "$C_OK" "$C_RST" "$(basename "$db")"
    else
      printf '    %sBAD%s %s\n' "$C_ERR" "$C_RST" "$(basename "$db")"
    fi
  done < <(find "$STAGED" -type f \( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' \) -print0)

  hr
  MANIFEST="$(find "$TEST_DIR" -name MANIFEST.txt | head -n1)"
  [[ -f "$MANIFEST" ]] && cat "$MANIFEST"
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
rm -rf "$RESTORE_WORK"; mkdir -p "$RESTORE_WORK"
restic restore "$SNAPSHOT_ID" --tag hybrid-ai --target "$RESTORE_WORK" || die "Download failed."

STAGED="$(find "$RESTORE_WORK" -type d -name databases | head -n1)"
[[ -n "$STAGED" ]] || die "Snapshot has no databases/ directory. Wrong snapshot?"
STAGED_ROOT="$(dirname "$STAGED")"

hr
[[ -f "${STAGED_ROOT}/MANIFEST.txt" ]] && cat "${STAGED_ROOT}/MANIFEST.txt"
hr

# --- Verify BEFORE overwriting anything ------------------------------------
# Never destroy working data on the basis of a backup we have not checked.
log "Verifying recovered databases before touching live data..."
TOTAL=0; GOOD=0; UNVERIFIED=0
while IFS= read -r -d '' db; do
  TOTAL=$(( TOTAL + 1 ))
  if command -v sqlite3 >/dev/null 2>&1; then
    if [[ "$(sqlite3 "$db" 'PRAGMA integrity_check;' 2>/dev/null | head -n1)" == "ok" ]]; then
      GOOD=$(( GOOD + 1 ))
    fi
  else
    # Cannot verify without sqlite3. Count it as passing so the restore is not
    # blocked, but the user is warned explicitly below.
    GOOD=$(( GOOD + 1 ))
    UNVERIFIED=1
  fi
done < <(find "$STAGED" -type f \( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' \) -print0)

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
printf '  %sThis will replace the live contents of webui_data.%s\n' "$C_WRN" "$C_RST"
printf '  Current data will be moved aside, not deleted.\n'
printf '  All containers will be stopped for the duration.\n'
hr
read -r -p "  Type RESTORE to proceed: " confirm < /dev/tty
[[ "$confirm" == "RESTORE" ]] || die "Aborted by user."

# ---------------------------------------------------------------------------
# Stop the application
#
# WHY THE WHOLE STACK, NOT JUST open-webui:
#   An earlier version stopped only the open-webui container, on the reasoning
#   that it is the thing writing webui.db. That was too narrow. More than one
#   container touches this directory:
#
#     open-webui  writes webui.db and the Chroma vector store
#     proxy       writes Caddy's own state into ./webui_data/caddy
#     status      mounts ./webui_data read-only and opens webui.db to report
#                 row counts, so it holds a read handle on the file we are
#                 about to move out from underneath it
#
#   Restoring while any of those are live risks a half-written Caddy state
#   directory, a status container pointing at a vanished inode, and confusing
#   permission errors that look exactly like data corruption.
#
#   Stopping everything is also more robust to future change: if a later
#   version adds another container that mounts webui_data, a narrowly targeted
#   stop would silently stop being correct. Ollama does not touch webui_data,
#   so stopping it is strictly unnecessary -- it costs one model reload on the
#   next start, which is a trivial price for not having to keep this list
#   accurate forever.
# ---------------------------------------------------------------------------
if [[ -f "${REPO_DIR}/.env" ]] && command -v docker >/dev/null 2>&1; then
  log "Stopping all containers for a clean restore..."
  docker compose --env-file "${REPO_DIR}/.env" stop >/dev/null 2>&1 || \
    warn "Could not stop the stack cleanly; continuing, but verify afterwards."
  sleep 3
  ok "Stack stopped."
fi

# --- Move existing data aside ----------------------------------------------
if [[ -d "${REPO_DIR}/webui_data" ]]; then
  SAFETY="${REPO_DIR}/webui_data.pre-restore-$(date +%Y%m%d-%H%M%S)"
  log "Preserving current data at $(basename "$SAFETY")"
  mv "${REPO_DIR}/webui_data" "$SAFETY"
  event "pre_restore_snapshot_kept" "path=$(basename "$SAFETY")"
fi
mkdir -p "${REPO_DIR}/webui_data"

# --- Documents first, then databases ---------------------------------------
if [[ -d "${STAGED_ROOT}/files" ]]; then
  log "Restoring documents..."
  rsync -a "${STAGED_ROOT}/files/" "${REPO_DIR}/webui_data/" || die "Document restore failed."
fi

# Databases go last so they overwrite any same-named file from files/.
log "Restoring databases..."
while IFS= read -r -d '' db; do
  rel="${db#"${STAGED}/"}"
  mkdir -p "$(dirname "${REPO_DIR}/webui_data/${rel}")"
  cp -a "$db" "${REPO_DIR}/webui_data/${rel}"
done < <(find "$STAGED" -type f -print0)

# Stale WAL/journal sidecars would be interpreted as newer than the restored
# database and could corrupt it on first open. They are transient by nature.
find "${REPO_DIR}/webui_data" -type f \
  \( -name '*.db-wal' -o -name '*.db-shm' -o -name '*.db-journal' \) -delete 2>/dev/null || true

# Caddy needs this directory to exist before the proxy starts again. It is
# inside webui_data (so it is backed up), but an older snapshot may predate it.
mkdir -p "${REPO_DIR}/webui_data/caddy"

# --- .env ------------------------------------------------------------------
if [[ -f "${STAGED_ROOT}/env/.env" ]]; then
  if [[ -f "${REPO_DIR}/.env" ]]; then
    ok "Keeping the existing .env (restored copy is at ${STAGED_ROOT}/env/.env)."
  else
    cp -a "${STAGED_ROOT}/env/.env" "${REPO_DIR}/.env"
    chmod 600 "${REPO_DIR}/.env"
    ok "Restored .env (0600). Your RunPod settings are back."
  fi
fi

# ---------------------------------------------------------------------------
# Restore host and platform state
#
# The databases above bring back everything Open WebUI knows -- connections,
# functions and their valve settings, tools, knowledge bases, users, groups.
# This section brings back the things that live OUTSIDE the application:
# local deployment edits, and the list of Ollama models to re-pull.
# ---------------------------------------------------------------------------
HOST_SRC="${STAGED_ROOT}/host"
if [[ -d "$HOST_SRC" ]]; then
  hr
  log "Restoring host state..."

  # --- Local edits to the deployment ---------------------------------------
  # Offered, never forced: the version in git is usually the one you want, and
  # silently overwriting a freshly cloned repo would be surprising.
  if [[ -f "${HOST_SRC}/docker-compose.override.yml" ]]; then
    if [[ ! -f "${REPO_DIR}/docker-compose.override.yml" ]]; then
      cp -a "${HOST_SRC}/docker-compose.override.yml" "${REPO_DIR}/"
      ok "Restored docker-compose.override.yml"
    else
      warn "Existing docker-compose.override.yml kept; backup copy is in ${HOST_SRC}"
    fi
  fi

  # Restore local customisation of the status page and reverse proxy. Only
  # offered when the backed-up copy actually differs from what is in git --
  # otherwise this would prompt on every restore for no reason.
  for f in status/Caddyfile status/app.py; do
    if [[ -f "${HOST_SRC}/${f}" ]]; then
      if [[ ! -f "${REPO_DIR}/${f}" ]]; then
        mkdir -p "$(dirname "${REPO_DIR}/${f}")"
        cp -a "${HOST_SRC}/${f}" "${REPO_DIR}/${f}"
        ok "Restored ${f}"
      elif ! cmp -s "${HOST_SRC}/${f}" "${REPO_DIR}/${f}"; then
        warn "${f} differs from the version in git."
        read -r -p "    Restore the backed-up copy over it? [y/N]: " _c < /dev/tty
        if [[ "${_c,,}" == "y" ]]; then
          cp -a "${HOST_SRC}/${f}" "${REPO_DIR}/${f}"
          ok "Restored ${f}"
        else
          printf '    Kept the git version. Backup copy: %s\n' "${HOST_SRC}/${f}"
        fi
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
  # Weights are not backed up by design, but the LIST is -- so this is
  # automatic rather than something you have to remember.
  if [[ -f "${HOST_SRC}/ollama-models.txt" ]] && [[ -s "${HOST_SRC}/ollama-models.txt" ]]; then
    MODEL_TOTAL="$(wc -l < "${HOST_SRC}/ollama-models.txt" | tr -d ' ')"
    hr
    printf '  The source system had %s Ollama model(s):\n\n' "$MODEL_TOTAL"
    sed 's/^/    - /' "${HOST_SRC}/ollama-models.txt"
    printf '\n  Weights are not backed up (they are large and re-downloadable).\n'
    hr
    read -r -p "  Re-pull them now? This needs bandwidth and time. [Y/n]: " _pull < /dev/tty
    if [[ "${_pull,,}" != "n" ]]; then
      # Ollama must be running to pull into. We stopped the whole stack above,
      # so start just this one service back up for the pull.
      if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'ollama'; then
        log "Starting Ollama..."
        docker compose --env-file "${REPO_DIR}/.env" up -d ollama >/dev/null 2>&1 || true
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

  # --- Custom-built models --------------------------------------------------
  # Models you created from a Modelfile cannot be pulled from a registry.
  if [[ -d "${HOST_SRC}/modelfiles" ]] && compgen -G "${HOST_SRC}/modelfiles/*.Modelfile" >/dev/null 2>&1; then
    warn "Custom Modelfiles were captured. If any model failed to pull, it was"
    warn "probably built locally. Recreate it with:"
    printf '    docker cp %s/modelfiles ollama:/tmp/\n' "$HOST_SRC"
    printf '    docker exec -it ollama ollama create <name> -f /tmp/modelfiles/<file>\n\n'
  fi
fi

# --- Ownership -------------------------------------------------------------
# Restored files must be owned by the invoking user, or the containers will
# fail with permission errors that look like data corruption.
chown -R "$(id -u):$(id -g)" "${REPO_DIR}/webui_data" 2>/dev/null || true

event "restore_success" "snapshot=${SNAPSHOT_ID}" "databases=${TOTAL}"
rm -rf "$RESTORE_WORK"

# --- Restart ---------------------------------------------------------------
hr
ok "Restore complete."
hr
cat <<EOF

  The whole stack was stopped for the restore. Bring it back with:

    1. Start everything:
         ./install.sh

    2. Open the UI and confirm the following came back:
         - chat history and folders
         - uploaded documents and knowledge bases
         - model connections (Workspace -> Connections)
         - functions / pipes AND their valve settings
           (Workspace -> Functions -> the RunPod pipe should be enabled
            with your pod ID and Tailscale IP already populated)
         - users, groups and permissions
         - the status page at http://<this-pi>/status

    3. Re-authenticate this machine to your tailnet if it is a new Pi.
       Machine identities are not transferable, by design:
         sudo tailscale up

    4. If the pod's address changed, refresh it:
         ./install.sh

    5. Confirm everything is healthy:
         ./doctor.sh

    6. Once satisfied, remove the safety copy:
         rm -rf ${SAFETY:-webui_data.pre-restore-*}

EOF
