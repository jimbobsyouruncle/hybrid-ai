#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: backup/backup.sh
# PURPOSE (plain English):
#   Backs up everything you would be upset to lose -- your chat history, your
#   uploaded documents, the vector database that makes document search
#   work, Hermes Agent memories, and OpenHands configurations -- to Cloudflare
#   R2, encrypted before it ever leaves the Pi[cite: 2].
#
#   It runs automatically every night via a systemd timer[cite: 2]. You can also run it
#   by hand at any time[cite: 2].
#
# WHY RESTIC:
#   - Encrypts on the Pi[cite: 2]. Cloudflare stores ciphertext and cannot read it[cite: 2].
#   - Deduplicates at block level, so the second backup of a 2 GB database
#     uploads only the few MB that actually changed[cite: 2].
#   - Keeps snapshots, so you can go back to "last Tuesday", not just "latest"[cite: 2].
#
# WHY CLOUDFLARE R2:
#   - No egress fees[cite: 2]. Restoring 50 GB costs nothing in bandwidth, which is
#     exactly when you least want a surprise bill[cite: 2].
#   - Roughly $0.015/GB/month stored[cite: 2]. A typical setup costs pennies[cite: 2].
#
# THE HARD PART -- WHY WE DO NOT JUST COPY THE FILES:
#   Open WebUI keeps its data in SQLite, ChromaDB keeps vectors in SQLite,
#   and Hermes Agent stores memory state in SQLite. Copying a SQLite file
#   while the application is writing to it produces a CORRUPT copy[cite: 2]. It will look
#   fine[cite: 2]. It will back up without error[cite: 2]. It will fail to open when you finally
#   need it, which is the worst possible time to discover the problem[cite: 2].
#
#   So this script does NOT copy the live database files directly[cite: 2]. It asks SQLite to
#   produce a consistent snapshot first (see snapshot_sqlite below), backs up
#   that snapshot, and excludes the live files entirely[cite: 2]. This is the single
#   most important thing this script does[cite: 2].
#
# WHAT GETS BACKED UP:
#   - Consistent SQLite snapshots (Open WebUI, ChromaDB, and Hermes Agent state)
#   - Uploaded documents and any other non-database files in webui_data
#   - Hermes Agent memories (~/.hermes/) and acquired skill definitions
#   - OpenHands state (~/.openhands/) and maintenance workspace settings
#   - Your .env configuration and local reverse proxy rules (status/Caddyfile)
#   - A manifest recording what was captured and from which versions
#
# WHAT DOES NOT:
#   - ollama_data/ -- model weights, tens of GB, freely re-downloadable[cite: 2].
#     Backing them up would dominate cost for zero benefit[cite: 2].
#
# USAGE:
#   ./backup.sh             run a backup now[cite: 2]
#   ./backup.sh --check     verify repository integrity (slow, reads data)[cite: 2]
#   ./backup.sh --init      create the repository (first-time setup)[cite: 2]
#   ./backup.sh --dry-run   show what would be backed up, upload nothing[cite: 2]
# ---------------------------------------------------------------------------
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_DIR"

# Credentials live OUTSIDE the git repository, in a root-only directory, so
# that no git operation and no careless `tar czf` of the project folder can
# ever sweep them up[cite: 2].
BACKUP_CONF_DIR="${BACKUP_CONF_DIR:-${HOME}/.config/hybrid-ai-backup}"
R2_ENV_FILE="${BACKUP_CONF_DIR}/r2.env"
RESTIC_PW_FILE="${BACKUP_CONF_DIR}/repo-password"

# Where consistent database snapshots are staged before upload. Deliberately
# on local disk, deliberately wiped afterwards[cite: 2].
STAGING_DIR="${REPO_DIR}/.backup-staging"

BACKUP_LOG="${BACKUP_LOG:-${REPO_DIR}/backup.log}"

# Retention. Restic keeps the most recent snapshot in each bucket[cite: 2].
KEEP_DAILY="${KEEP_DAILY:-7}"
KEEP_WEEKLY="${KEEP_WEEKLY:-4}"
KEEP_MONTHLY="${KEEP_MONTHLY:-6}"

MODE="backup"
NON_INTERACTIVE=0
for arg in "$@"; do
  case "$arg" in
    --check)           MODE="check" ;;
    --init)            MODE="init" ;;
    --dry-run)         MODE="dryrun" ;;
    --non-interactive) NON_INTERACTIVE=1 ;;
    -h|--help) sed -n '2,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

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
# credential, a filename from a user document, or any chat content here[cite: 2].
event() {
  local name="$1"; shift
  printf 'EVENT ts=%s event=%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$name" "$*" \
    | tee -a "$BACKUP_LOG" 2>/dev/null || true
}

die() {
  event "backup_failed" "detail=$(printf '\%s' "$*" | tr -d '\n' | cut -c1-160)"
  printf '%s[ X ]%s %s\n' "$C_ERR" "$C_RST" "$*" >&2
  exit 1
}

# AVAILABILITY: always clean up staged database copies, even on failure[cite: 2].
cleanup() {
  local rc=$?
  if declare -F unpause_webui >/dev/null 2>&1; then unpause_webui; fi
  if [[ -d "$STAGING_DIR" ]]; then
    rm -rf "$STAGING_DIR" 2>/dev/null || true
  fi
  return $rc
}
trap cleanup EXIT
trap 'die "Failed at line ${LINENO}:${BASH_COMMAND}"' ERR

touch "$BACKUP_LOG" 2>/dev/null && chmod 600 "$BACKUP_LOG" 2>/dev/null || true

# ---------------------------------------------------------------------------
# STEP 1. Load credentials
# ---------------------------------------------------------------------------
[[ -f "$R2_ENV_FILE" ]] || die "No credentials at ${R2_ENV_FILE}. Run ./install.sh to configure backups."
[[ -f "$RESTIC_PW_FILE" ]] || die "No repository password at ${RESTIC_PW_FILE}."

for f in "$R2_ENV_FILE" "$RESTIC_PW_FILE"; do
  perms="$(stat -c '\%a' "$f" 2>/dev/null || echo '???')"
  [[ "$perms" == "600" ]] \vert{}\vert{} die "${f} has permissions ${perms}; expected 600. Fix with: chmod 600${f}"
done

while IFS= read -r _line || [[ -n "$_line" ]]; do
  [[ "$_line" =~ ^[[:space:]]*# ]] && continue
  [[ "$_line" =~ ^[[:space:]]*$ ]] && continue
  if [[ "$_line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
    _k="${BASH_REMATCH[1]}"; _v="${BASH_REMATCH[2]}"
    _v="${_v\%\"}"; _v="${_v#\"}"; _v="${_v\%\'}"; _v="${_v#\'}"
    printf -v "$_k" '\%s' "$_v"
    export "${_k?}"
  fi
done < "$R2_ENV_FILE"
unset _line _k _v

export RESTIC_PASSWORD_FILE="$RESTIC_PW_FILE"

[[ -n "${RESTIC_REPOSITORY:-}" ]]    || die "RESTIC_REPOSITORY not set in ${R2_ENV_FILE}"
[[ -n "${AWS_ACCESS_KEY_ID:-}" ]]    || die "AWS_ACCESS_KEY_ID not set in ${R2_ENV_FILE}"
[[ -n "${AWS_SECRET_ACCESS_KEY:-}" ]]|| die "AWS_SECRET_ACCESS_KEY not set in ${R2_ENV_FILE}"

command -v restic >/dev/null 2>&1 || die "restic is not installed. Run ./install.sh, or: sudo apt-get install -y restic"

BACKUP_HOST="${RESTIC_HOST:-$(hostname -s)}"

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
  cat <<'EOF'

  IMPORTANT -- do this now, not later:

  Store your repository password somewhere OFF this Pi. A password manager is
  ideal. If the SD card dies and the password died with it, your backups are
  permanently unreadable. Restic has no recovery mechanism, by design.

EOF
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
# STEP 4. Capture application data consistently
# ---------------------------------------------------------------------------
PAUSED=0

unpause_webui() {
  if (( PAUSED )); then
    docker compose --env-file "${REPO_DIR}/.env" unpause open-webui hermes-agent >/dev/null 2>&1 || \
      docker unpause open-webui hermes-agent >/dev/null 2>&1 || true
    PAUSED=0
  fi
}

pause_webui() {
  [[ "${BACKUP_NO_PAUSE:-0}" == "1" ]] && return 1
  command -v docker >/dev/null 2>&1 || return 1
  [[ -f "${REPO_DIR}/.env" ]] || return 1

  docker ps --format '{{.Names}}' 2>/dev/null | grep -qE 'open-webui|hermes-agent' || return 1

  if docker compose --env-file "${REPO_DIR}/.env" pause open-webui hermes-agent >/dev/null 2>&1 || \
     docker pause open-webui hermes-agent >/dev/null 2>&1; then
    PAUSED=1
    return 0
  fi
  return 1
}

snapshot_sqlite() {
  local src="$1" dest="$2"
  mkdir -p "$(dirname "$dest")"

  if command -v sqlite3 >/dev/null 2>&1; then
    if sqlite3 "file:${src}?mode=ro" ".timeout 10000" "VACUUM INTO '${dest}'" 2>/dev/null; then
      return 0
    fi
    rm -f "$dest"
    if sqlite3 "file:${src}?mode=ro" ".timeout 10000" ".backup '${dest}'" 2>/dev/null; then
      return 0
    fi
  fi
  return 1
}

[[ "$MODE" == "dryrun" ]] || log "Capturing application state..."

rm -rf "$STAGING_DIR"
mkdir -p "${STAGING_DIR}/databases" "${STAGING_DIR}/files" "${STAGING_DIR}/env" "${STAGING_DIR}/host" "${STAGING_DIR}/hermes" "${STAGING_DIR}/openhands"
chmod 700 "$STAGING_DIR"

if pause_webui; then
  CONSISTENCY="paused"
  [[ "$MODE" == "dryrun" ]] || ok "Open WebUI & Hermes Agent paused for point-in-time capture."
else
  CONSISTENCY="online"
  [[ "$MODE" == "dryrun" ]] || warn "Could not pause containers; capturing live (see BACKUP_NO_PAUSE)."
fi

DB_COUNT=0
DB_FAILED=0

# --- Search and snapshot all SQLite databases across webui_data & hermes_data ---
SEARCH_PATHS=("${REPO_DIR}/webui_data" "${REPO_DIR}/hermes_data" "${HOME}/.hermes")

for search_path in "${SEARCH_PATHS[@]}"; do
  [[ -d "$search_path" ]] || continue
  while IFS= read -r -d '' db; do
    rel="${db#"${REPO_DIR}/"}"
    rel="${rel#"${HOME}/"}"
    target="${STAGING_DIR}/databases/${rel}"
    if snapshot_sqlite "$db" "$target"; then
      DB_COUNT=$(( DB_COUNT + 1 ))
    else
      DB_FAILED=$(( DB_FAILED + 1 ))
      warn "Could not snapshot ${rel} via SQLite API."
    fi
  done < <(find "$search_path" -type f \
             \(-name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3'\) \
             -print0 2>/dev/null || true)
done

# --- Copy non-database files from webui_data, hermes_data, and openhands ---
if [[ -d "${REPO_DIR}/webui_data" ]]; then
  rsync -a \
    --exclude='*.db' --exclude='*.sqlite' --exclude='*.sqlite3' \
    --exclude='*.db-wal' --exclude='*.db-shm' --exclude='*.db-journal' \
    --exclude='*-wal' --exclude='*-shm' \
    --exclude='cache/' --exclude='tmp/' \
    "${REPO_DIR}/webui_data/" "${STAGING_DIR}/files/webui_data/" 2>/dev/null || \
    warn "rsync reported issues copying webui_data files; continuing."
fi

if [[ -d "${REPO_DIR}/hermes_data" ]]; then
  rsync -a \
    --exclude='*.db' --exclude='*.sqlite' --exclude='*.sqlite3' \
    "${REPO_DIR}/hermes_data/" "${STAGING_DIR}/files/hermes_data/" 2>/dev/null || true
fi

if [[ -d "${HOME}/.hermes" ]]; then
  rsync -a \
    --exclude='*.db' --exclude='*.sqlite' --exclude='*.sqlite3' \
    "${HOME}/.hermes/" "${STAGING_DIR}/hermes/" 2>/dev/null || true
fi

if [[ -d "${HOME}/.openhands" ]]; then
  rsync -a "${HOME}/.openhands/" "${STAGING_DIR}/openhands/" 2>/dev/null || true
fi

unpause_webui
[[ "$MODE" == "dryrun" ]] || ok "Capture complete; application services resumed."

if (( DB_FAILED > 0 )); then
  warn "${DB_FAILED} database(s) could not be snapshotted online."
  if command -v docker >/dev/null 2>&1 && [[ -f "${REPO_DIR}/.env" ]]; then
    warn "Falling back to a cold copy. Services will be briefly unavailable."
    event "cold_copy_fallback" "failed_dbs=${DB_FAILED}"
    CONSISTENCY="cold"

    docker compose --env-file "${REPO_DIR}/.env" stop open-webui hermes-agent >/dev/null 2>&1 || true
    sleep 3
    rm -rf "${STAGING_DIR}/databases"
    mkdir -p "${STAGING_DIR}/databases"
    DB_COUNT=0
    for search_path in "${SEARCH_PATHS[@]}"; do
      [[ -d "$search_path" ]] || continue
      while IFS= read -r -d '' db; do
        rel="${db#"${REPO_DIR}/"}"
        rel="${rel#"${HOME}/"}"
        mkdir -p "$(dirname "${STAGING_DIR}/databases/${rel}")"
        cp -a "$db" "${STAGING_DIR}/databases/${rel}" && DB_COUNT=$(( DB_COUNT + 1 ))
      done < <(find "$search_path" -type f \
                 \(-name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3'\) \
                 -print0 2>/dev/null || true)
    done
    docker compose --env-file "${REPO_DIR}/.env" start open-webui hermes-agent >/dev/null 2>&1 || \
      warn "Could not restart services automatically. Run: ./install.sh"
  else
    die "Cannot produce consistent database copies and cannot fall back."
  fi
fi

[[ "$MODE" == "dryrun" ]] || ok "Captured ${DB_COUNT} database(s) (${CONSISTENCY})."

# ---------------------------------------------------------------------------
# STEP 4b. Capture host and platform state
# ---------------------------------------------------------------------------
[[ "$MODE" == "dryrun" ]] || log "Capturing host and platform state..."

HOST_DIR="${STAGING_DIR}/host"

if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'ollama'; then
  docker exec ollama ollama list 2>/dev/null \
    | awk 'NR>1 {print $1}' > "${HOST_DIR}/ollama-models.txt" || true
  mkdir -p "${HOST_DIR}/modelfiles"
  while IFS= read -r m; do
    [[ -z "$m" ]] && continue
    safe="${m//[^A-Za-z0-9._-]/_}"
    docker exec ollama ollama show --modelfile "$m" \
      > "${HOST_DIR}/modelfiles/${safe}.Modelfile" 2>/dev/null || true
  done < "${HOST_DIR}/ollama-models.txt"
  OLLAMA_MODEL_COUNT="$(wc -l < "${HOST_DIR}/ollama-models.txt" 2>/dev/null | tr -d ' ' || echo 0)"
else
  OLLAMA_MODEL_COUNT=0
fi

docker compose --env-file "${REPO_DIR}/.env" config --images 2>/dev/null \
  > "${HOST_DIR}/container-images.txt" || true

for f in docker-compose.yml docker-compose.override.yml; do
  [[ -f "${REPO_DIR}/${f}" ]] && cp -a "${REPO_DIR}/${f}" "${HOST_DIR}/${f}" 2>/dev/null || true
done

for d in openwebui openhands hermes scripts status; do
  if [[ -d "${REPO_DIR}/${d}" ]]; then
    mkdir -p "${HOST_DIR}/${d}"
    cp -a "${REPO_DIR}/${d}/." "${HOST_DIR}/${d}/" 2>/dev/null || true
  fi
done

if command -v git >/dev/null 2>&1 && [[ -d "${REPO_DIR}/.git" ]]; then
  {
    printf 'commit=%s\n' "$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
    printf 'branch=%s\n' "$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
    printf 'remote=%s\n' "$(git -C "$REPO_DIR" config --get remote.origin.url 2>/dev/null || echo none)"
    printf 'dirty=%s\n' "$(git -C "$REPO_DIR" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  } > "${HOST_DIR}/git-state.txt" 2>/dev/null || true
  git -C "$REPO_DIR" diff HEAD > "${HOST_DIR}/uncommitted.patch" 2>/dev/null || true
  [[ -s "${HOST_DIR}/uncommitted.patch" ]] \vert{}\vert{} rm -f "${HOST_DIR}/uncommitted.patch"
fi

{
  printf 'hostname=%s\n'        "$(hostname -s 2>/dev/null)"
  printf 'os=%s\n'              "$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}")"
  printf 'kernel=%s\n'          "$(uname -r 2>/dev/null)"
  printf 'arch=%s\n'            "$(uname -m 2>/dev/null)"
  printf 'total_ram_mb=%s\n'    "$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)"
  printf 'docker=%s\n'          "$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo n/a)"
  printf 'tailscale_host=%s\n'  "$(tailscale status --json 2>/dev/null | jq -r '.Self.HostName // "unknown"' 2>/dev/null || echo unknown)"
  printf 'backup_timer=%s\n'    "$(systemctl --user is-enabled hybrid-ai-backup.timer 2>/dev/null || echo unknown)"
} > "${HOST_DIR}/platform.txt" 2>/dev/null || true

chmod -R go-rwx "$HOST_DIR" 2>/dev/null || true

# ---------------------------------------------------------------------------
# STEP 5. Write a manifest
# ---------------------------------------------------------------------------
cat > "${STAGING_DIR}/MANIFEST.txt" <<EOF
hybrid-ai backup manifest
=========================
created_utc        : $(date -u +%Y-%m-%dT%H:%M:%SZ)
source_host        : ${BACKUP_HOST}
consistency_method : ${CONSISTENCY}
databases_captured : ${DB_COUNT}
ollama_models      : ${OLLAMA_MODEL_COUNT:-0} (names only; weights not backed up)
restic_version     : $(restic version 2>/dev/null | head -n1)

Contents
--------
databases/   Consistent SQLite snapshots (Open WebUI, ChromaDB, Hermes Agent).
files/       Uploaded documents, vector indexes, and persistent tool states.
hermes/      Hermes Agent skills (~/.hermes/skills) and config files.
openhands/   OpenHands user configs and workspace settings (~/.openhands).
host/        Deployment configurations, Caddyfile, and host metadata.
env/         Active .env configuration.

To restore, see backup/restore.sh in the hybrid-ai repository.
EOF

# ---------------------------------------------------------------------------
# STEP 6. Stage the configuration file
# ---------------------------------------------------------------------------
if [[ -f "${REPO_DIR}/.env" ]]; then
  cp -a "${REPO_DIR}/.env" "${STAGING_DIR}/env/.env"
  chmod 600 "${STAGING_DIR}/env/.env"
fi

STAGED_MB="$(du -sm "$STAGING_DIR" 2>/dev/null | cut -f1 || echo '?')"

if [[ "$MODE" == "dryrun" ]]; then
  log "Dry run -- nothing will be uploaded."
  printf '\n  Staged %s MB:\n\n' "$STAGED_MB"
  find "$STAGING_DIR" -maxdepth 2 -mindepth 1 -printf '    %y %p\n' 2>/dev/null | head -40
  printf '\n  Repository: %s\n\n' "${RESTIC_REPOSITORY}"
  exit 0
fi

# ---------------------------------------------------------------------------
# STEP 7. Upload
#
# Only the staging directory is passed to restic. The live application data is
# never uploaded directly, guaranteeing every snapshot is consistent.
# ---------------------------------------------------------------------------
log "Checking restic repository status..."

if ! restic snapshots >/dev/null 2>&1; then
  warn "Repository at ${RESTIC_REPOSITORY} is not initialized!"
  
  if (( NON_INTERACTIVE )); then
    die "Repository uninitialized and --non-interactive requested. Run: ./backup/backup.sh --init"
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

log "Uploading to R2 (${STAGED_MB} MB staged, deduplicated against previous runs)..."
BACKUP_START=$SECONDS

if restic backup "$STAGING_DIR" \
      --host "$BACKUP_HOST" \
      --tag hybrid-ai \
      --tag "consistency:${CONSISTENCY}" \
      --exclude-caches \
      --one-file-system 2>&1 | tee -a "$BACKUP_LOG"; then
  BACKUP_SECONDS=$(( SECONDS - BACKUP_START ))
  event "backup_success" "host=${BACKUP_HOST}" "staged_mb=${STAGED_MB}" \
        "databases=${DB_COUNT}" "consistency=${CONSISTENCY}" \
        "duration_s=${BACKUP_SECONDS}"
  ok "Backup complete in ${BACKUP_SECONDS}s."
else
  die "restic backup failed. See ${BACKUP_LOG}."
fi

# ---------------------------------------------------------------------------
# STEP 8. Retention
# ---------------------------------------------------------------------------
log "Applying retention policy (${KEEP_DAILY}d / ${KEEP_WEEKLY}w / ${KEEP_MONTHLY}m)..."
if restic forget \
      --host "$BACKUP_HOST" \
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
SNAP_COUNT="$(restic snapshots --host "$BACKUP_HOST" --json 2>/dev/null | jq 'length' 2>/dev/null || echo '?')"
event "backup_run_complete" "snapshots_retained=${SNAP_COUNT}"

printf '\n'
ok "Done. ${SNAP_COUNT} snapshot(s) retained for host${BACKUP_HOST}."
printf '    Restore with : ./backup/restore.sh\n'
printf '    Verify with  : ./backup/backup.sh --check\n\n'
