# Repository Codebase Context
Generated on Fri Oct  2 09:59:36 UTC 2026

## File: backup/backup.sh
---
Directory: `backup`
---
```bash
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
  event "backup_failed" "detail=$(printf '%s' "$*" | tr -d '\n' | cut -c1-160)"
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
  perms="$(stat -c '%a' "$f" 2>/dev/null || echo '???')"
  [[ "$perms" == "600" ]] || die "${f} has permissions ${perms}; expected 600. Fix with: chmod 600 ${f}"
done

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

# --- Snapshot only databases containing durable application state ---
DB_PATHS=(
  "${REPO_DIR}/webui_data/webui.db"
  "${REPO_DIR}/webui_data/vector_db/chroma.sqlite3"
)

for db in "${DB_PATHS[@]}"; do
  [[ -f "$db" ]] || continue
  rel="${db#"${REPO_DIR}/"}"
  target="${STAGING_DIR}/databases/${rel}"
  if snapshot_sqlite "$db" "$target"; then
    DB_COUNT=$(( DB_COUNT + 1 ))
  else
    DB_FAILED=$(( DB_FAILED + 1 ))
    warn "Could not snapshot ${rel} via SQLite API."
  fi
done

# --- Allow-list durable non-database state ---
if [[ -d "${REPO_DIR}/webui_data/uploads" ]]; then
  mkdir -p "${STAGING_DIR}/files/webui_data/uploads"
  rsync -a "${REPO_DIR}/webui_data/uploads/" "${STAGING_DIR}/files/webui_data/uploads/" 2>/dev/null || \
    warn "rsync reported issues copying Open WebUI uploads; continuing."
fi

if [[ -d "${REPO_DIR}/webui_data/vector_db" ]]; then
  mkdir -p "${STAGING_DIR}/files/webui_data/vector_db"
  rsync -a \
    --exclude='*.db' --exclude='*.sqlite' --exclude='*.sqlite3' \
    --exclude='*.db-wal' --exclude='*.db-shm' --exclude='*.db-journal' \
    --exclude='*-wal' --exclude='*-shm' \
    "${REPO_DIR}/webui_data/vector_db/" "${STAGING_DIR}/files/webui_data/vector_db/" 2>/dev/null || \
    warn "rsync reported issues copying Open WebUI vector data; continuing."
fi

# hermes_data contains reconstructable runtimes/caches. Preserve only named durable state.
for d in memories memory skills config configs sessions; do
  if [[ -d "${REPO_DIR}/hermes_data/${d}" ]]; then
    mkdir -p "${STAGING_DIR}/files/hermes_data/${d}"
    rsync -a "${REPO_DIR}/hermes_data/${d}/" "${STAGING_DIR}/files/hermes_data/${d}/" 2>/dev/null || \
      warn "rsync reported issues copying Hermes ${d}; continuing."
  fi
done

if [[ -d "${HOME}/.hermes" ]]; then
  mkdir -p "${STAGING_DIR}/hermes"
  rsync -a \
    --exclude='cache/' --exclude='tools/' --exclude='installs/' \
    --exclude='node_modules/' --exclude='.git/' --exclude='venv/' --exclude='.venv/' \
    --exclude='__pycache__/' --exclude='*.pyc' \
    --exclude='*.db' --exclude='*.sqlite' --exclude='*.sqlite3' \
    "${HOME}/.hermes/" "${STAGING_DIR}/hermes/" 2>/dev/null || \
    warn "rsync reported issues copying ~/.hermes durable state; continuing."
fi

if [[ -d "${HOME}/.openhands" ]]; then
  mkdir -p "${STAGING_DIR}/openhands"
  rsync -a --exclude='cache/' --exclude='tmp/' --exclude='logs/' \
    "${HOME}/.openhands/" "${STAGING_DIR}/openhands/" 2>/dev/null || \
    warn "rsync reported issues copying OpenHands state; continuing."
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
    for db in "${DB_PATHS[@]}"; do
      [[ -f "$db" ]] || continue
      rel="${db#"${REPO_DIR}/"}"
      mkdir -p "$(dirname "${STAGING_DIR}/databases/${rel}")"
      if cp -a "$db" "${STAGING_DIR}/databases/${rel}"; then
        DB_COUNT=$(( DB_COUNT + 1 ))
      else
        die "Cold-copy fallback failed for ${rel}."
      fi
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
  [[ -s "${HOST_DIR}/uncommitted.patch" ]] || rm -f "${HOST_DIR}/uncommitted.patch"
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
databases/   Consistent Open WebUI and Chroma SQLite snapshots.
files/       Allow-listed uploads, vector data, and durable Hermes state.
hermes/      Durable ~/.hermes state if present; runtime/cache content excluded.
openhands/   OpenHands user config/state; cache, temp, and logs excluded.
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
```


## File: backup/restore.sh
---
Directory: `backup`
---
```bash
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
```


## File: collect-diagnostics.sh
---
Directory: `.`
---
```bash
#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: collect-diagnostics.sh
# PURPOSE (plain English):
#   Gathers everything needed to diagnose a problem into ONE text file that is
#   safe to paste into an AI chat, attach to a GitHub issue, or send to someone
#   helping you.
#
#   It collects system info, container status, logs, configuration (with every
#   secret removed), network state, and backup health.
#
# THE MOST IMPORTANT THING THIS SCRIPT DOES: REDACTION
#   This output is designed to be shared with strangers and AI services. So
#   every value that could be a credential is replaced before it is written:
#
#     - .env is reported as KEY=<REDACTED:length=64>  -- names and lengths
#       only, never values. Knowing a key is *present and 64 characters* is
#       usually all you need to diagnose; the actual value never is.
#     - Logs are passed through a redaction filter that catches RunPod keys,
#       Tailscale keys, AWS-style keys, GitHub tokens, LLM provider keys,
#       bearer tokens, JWTs, passwords in URLs, and private key blocks.
#     - Tailscale IPs are masked to 100.x.x.N, preserving the shape you need
#       to reason about without publishing your network layout.
#     - CHAT CONTENT AND DOCUMENTS ARE NEVER READ. Not the databases, not
#       uploads, not the vector store. Only counts and file sizes.
#
#   The script prints a summary of what it redacted, and the last section of
#   the report is a self-audit that scans the finished file for anything that
#   still looks like a secret. If it finds something, it tells you loudly.
#
#   Redaction is best-effort, not a guarantee. ALWAYS SKIM THE FILE before
#   sharing it. The script reminds you to do this.
#
# USAGE:
#   ./collect-diagnostics.sh                 full report
#   ./collect-diagnostics.sh --lines 200     more log lines (default 100)
#   ./collect-diagnostics.sh --no-redact     UNSAFE. Local debugging only.
#   ./collect-diagnostics.sh --output FILE   write somewhere specific
#
# OUTPUT:
#   ./diagnostics-<host>-<timestamp>.txt   (mode 0600, gitignored)
# ---------------------------------------------------------------------------
set -uo pipefail   # deliberately NOT -e: one failed probe must not abort the run

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

LOG_LINES=100
REDACT=1
OUTFILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --lines)     LOG_LINES="${2:-100}"; shift 2 ;;
    --no-redact) REDACT=0; shift ;;
    --output)    OUTFILE="${2:-}"; shift 2 ;;
    -h|--help)   sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ "$LOG_LINES" =~ ^[0-9]+$ ]] || { echo "--lines must be a number" >&2; exit 2; }

HOSTNAME_SHORT="$(hostname -s 2>/dev/null || echo pi)"
TIMESTAMP="$(date -u +%Y%m%d-%H%M%S)"
OUTFILE="${OUTFILE:-${SCRIPT_DIR}/diagnostics-${HOSTNAME_SHORT}-${TIMESTAMP}.txt}"

if [[ -t 1 ]]; then
  C_RST=$'\033[0m'; C_OK=$'\033[32m'; C_WRN=$'\033[33m'; C_INF=$'\033[36m'; C_ERR=$'\033[31m'
else
  C_RST=""; C_OK=""; C_WRN=""; C_INF=""; C_ERR=""
fi

# Both compose files. Omitting the overlay makes `ps` and `logs` silently skip
# OpenHands -- and a diagnostic bundle that omits a running service is worse
# than one that says nothing about it, because it looks complete.
COMPOSE=(docker compose
         -f docker-compose.yml
         -f openhands/docker-compose.openhands.yml
         --env-file .env)

# ---------------------------------------------------------------------------
# THE REDACTION FILTER
#
# Everything written to the report passes through here. Patterns are ordered
# most-specific first so that a precise match wins over a generic one.
#
# If you add a new credential type to this project, ADD IT HERE FIRST.
# ---------------------------------------------------------------------------
redact() {
  if (( ! REDACT )); then cat; return; fi
  sed -E \
    -e 's/rpa_[A-Za-z0-9_-]{8,}/<REDACTED:runpod-api-key>/g' \
    -e 's/tskey-[A-Za-z0-9_-]{8,}/<REDACTED:tailscale-key>/g' \
    -e 's/(tskey-auth|tskey-client|tskey-api)[A-Za-z0-9_-]*/<REDACTED:tailscale-key>/g' \
    -e 's/\b(AKIA|ASIA)[A-Z0-9]{16}\b/<REDACTED:aws-key-id>/g' \
    -e 's/\bghp_[A-Za-z0-9]{20,}/<REDACTED:github-token>/g' \
    -e 's/\bgho_[A-Za-z0-9]{20,}/<REDACTED:github-token>/g' \
    -e 's/\bgithub_pat_[A-Za-z0-9_]{20,}/<REDACTED:github-token>/g' \
    -e 's/\bsk-[A-Za-z0-9_-]{20,}/<REDACTED:llm-api-key>/g' \
    -e 's/\bey[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/<REDACTED:jwt>/g' \
    -e 's/([Bb]earer)[[:space:]]+[A-Za-z0-9._~+\/=-]{12,}/\1 <REDACTED:token>/g' \
    -e 's/([Aa]uthorization:[[:space:]]*)[^[:space:]]+/\1<REDACTED:auth-header>/g' \
    -e 's/(api[_-]?key["'"'"']?[[:space:]]*[=:][[:space:]]*["'"'"']?)[A-Za-z0-9._~+\/=-]{8,}/\1<REDACTED>/Ig' \
    -e 's/(secret[_-]?(access[_-]?)?key["'"'"']?[[:space:]]*[=:][[:space:]]*["'"'"']?)[A-Za-z0-9._~+\/=-]{8,}/\1<REDACTED>/Ig' \
    -e 's/(access[_-]?key[_-]?id["'"'"']?[[:space:]]*[=:][[:space:]]*["'"'"']?)[A-Za-z0-9._~+\/=-]{8,}/\1<REDACTED>/Ig' \
    -e 's/(pass(word|wd)?["'"'"']?[[:space:]]*[=:][[:space:]]*["'"'"']?)[^[:space:]"'"'"']{4,}/\1<REDACTED>/Ig' \
    -e 's/(token["'"'"']?[[:space:]]*[=:][[:space:]]*["'"'"']?)[A-Za-z0-9._~+\/=-]{12,}/\1<REDACTED>/Ig' \
    -e 's/(https?:\/\/)[^:@[:space:]\/]+:[^@[:space:]]+@/\1<REDACTED:userinfo>@/g' \
    -e 's/-----BEGIN [A-Z ]*PRIVATE KEY-----/<REDACTED:private-key-block>/g' \
    -e 's/\b100\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\b/100.x.x.\3/g' \
    -e 's/\b([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}\b/<REDACTED:mac>/g' \
    -e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<REDACTED:email>/g'
}

# Write a section header, then run a command with its output redacted and
# indented. Never lets a failing probe kill the script.
sec() { printf '\n\n===============================================================\n  %s\n===============================================================\n' "$1" >> "$OUTFILE"; }
sub() { printf '\n--- %s ---\n' "$1" >> "$OUTFILE"; }
run() {
  # run <description> <command...>
  local desc="$1"; shift
  sub "$desc"
  { "$@" 2>&1 || printf '(command failed or unavailable)\n'; } | redact >> "$OUTFILE"
}
note() { printf '%s\n' "$*" >> "$OUTFILE"; }

printf '%s\n' "============================================================"
printf '  hybrid-ai diagnostics collector\n'
printf '%s\n' "============================================================"
if (( REDACT )); then
  printf '  %sRedaction: ON%s  (secrets will be removed)\n\n' "$C_OK" "$C_RST"
else
  printf '  %sRedaction: OFF -- output WILL contain secrets. Do not share.%s\n\n' "$C_ERR" "$C_RST"
fi

: > "$OUTFILE"
chmod 600 "$OUTFILE"

# ---------------------------------------------------------------------------
# Header -- tells whoever reads this what they are looking at
# ---------------------------------------------------------------------------
cat >> "$OUTFILE" <<EOF
===============================================================
  hybrid-ai DIAGNOSTIC REPORT
===============================================================
generated_utc : $(date -u +%Y-%m-%dT%H:%M:%SZ)
generated_by  : collect-diagnostics.sh
redaction     : $( (( REDACT )) && echo "ENABLED" || echo "*** DISABLED -- CONTAINS SECRETS ***" )
log_lines     : ${LOG_LINES}

ABOUT THIS FILE
---------------
This is a diagnostic bundle for a self-hosted AI stack: Open WebUI + Ollama
running in Docker on a Raspberry Pi, which reaches an on-demand vLLM server
on a rented RunPod GPU over a Tailscale private network. An optional OpenHands
container provides natural-language code maintenance.

Secrets have been replaced with <REDACTED:...> markers. Where a value was a
credential, only its NAME and LENGTH are reported.

No chat content, no uploaded documents, and no vector data were read. Only
counts, sizes, and metadata.

IF YOU ARE AN AI ASSISTANT READING THIS
---------------------------------------
Please identify the root cause and give specific, runnable commands. Useful
context on how the pieces fit together:

  - The GPU pod is STOPPED most of the time, on purpose, to save money. A
    "connection refused" to the pod is usually NORMAL, not a fault.
  - The pod self-stops after 15 idle minutes via a watchdog in start.sh.
  - Cold starts legitimately take 2-5 minutes while model weights load.
  - Tailscale addresses are 100.x.x.x and masked here as 100.x.x.N.
  - webui_data/ holds ALL user state: chats, documents, vectors, and every
    UI-made setting (connections, functions/pipes and their valve values).
  - The Pi has no GPU. Local models run on CPU and are slow by nature.
  - OpenHands is OPTIONAL and loopback-only. Its absence is not a fault.
  - ./doctor.sh is a health checker; its output is included below.
EOF

# ---------------------------------------------------------------------------
# 1. doctor.sh -- the highest-signal section, so it goes first
# ---------------------------------------------------------------------------
printf '  %s[1/9]%s Health check...\n' "$C_INF" "$C_RST"
sec "1. HEALTH CHECK (doctor.sh)"
if [[ -x ./doctor.sh ]]; then
  { ./doctor.sh --no-cloud 2>&1 || true; } | redact >> "$OUTFILE"
elif [[ -f ./doctor.sh ]]; then
  # A missing executable bit is common after a clone from Windows, and it
  # would otherwise silently blank out the single most useful section here.
  note "doctor.sh is present but not executable -- running it via bash."
  note "Fix this permanently with: chmod +x doctor.sh"
  { bash ./doctor.sh --no-cloud 2>&1 || true; } | redact >> "$OUTFILE"
else
  note "doctor.sh not found."
fi

# ---------------------------------------------------------------------------
# 2. Host
# ---------------------------------------------------------------------------
printf '  %s[2/9]%s System information...\n' "$C_INF" "$C_RST"
sec "2. HOST SYSTEM"
run "OS"                  bash -c '. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}"'
run "Kernel / arch"       uname -a
run "Model"               bash -c 'cat /proc/device-tree/model 2>/dev/null || echo "not a Raspberry Pi / unknown"'
run "Uptime and load"     uptime
run "Memory"              free -h
run "Disk"                df -h /
run "Inodes"              df -i /
run "Top memory consumers" bash -c "ps aux --sort=-%mem 2>/dev/null | head -8"
run "Temperature"         bash -c 'vcgencmd measure_temp 2>/dev/null || echo "vcgencmd unavailable"'
run "Throttling (0x0 = healthy)" bash -c 'vcgencmd get_throttled 2>/dev/null || echo "vcgencmd unavailable"'
run "Storage errors in kernel log" bash -c "dmesg 2>/dev/null | grep -iE 'mmcblk|i/o error|ext4-fs error' | tail -20 || echo 'none found (or dmesg needs root)'"

# ---------------------------------------------------------------------------
# 3. Tooling versions
# ---------------------------------------------------------------------------
printf '  %s[3/9]%s Tool versions...\n' "$C_INF" "$C_RST"
sec "3. TOOLING"
{
  for t in docker jq curl sqlite3 rsync restic tailscale git openssl python3; do
    if command -v "$t" >/dev/null 2>&1; then
      case "$t" in
        docker)    v="$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?')" ;;
        tailscale) v="$(tailscale version 2>/dev/null | head -1)" ;;
        restic)    v="$(restic version 2>/dev/null | head -1)" ;;
        sqlite3)   v="$(sqlite3 --version 2>/dev/null | awk '{print $1}')" ;;
        *)         v="$("$t" --version 2>&1 | head -1)" ;;
      esac
      printf '  %-12s %s\n' "$t" "$v"
    else
      printf '  %-12s NOT INSTALLED\n' "$t"
    fi
  done
  printf '  %-12s %s\n' "compose" "$(docker compose version --short 2>/dev/null || echo 'NOT AVAILABLE')"
} 2>&1 | redact >> "$OUTFILE"

# --- Executable bits on our own scripts ------------------------------------
# A missing +x is a real, silent failure mode on a clone made from Windows,
# and it is exactly what stops you running these tools when you need them.
sub "Script permissions"
{
  for s in install.sh doctor.sh collect-diagnostics.sh \
           backup/backup.sh backup/restore.sh runpod/start.sh \
           scripts/setup-agent-workspace.sh \
           openhands/scripts/openhands-control.sh; do
    if [[ -f "$s" ]]; then
      if [[ -x "$s" ]]; then
        printf '  %-42s executable\n' "$s"
      else
        printf '  %-42s NOT EXECUTABLE  <-- chmod +x %s\n' "$s" "$s"
      fi
    else
      printf '  %-42s missing\n' "$s"
    fi
  done
} 2>&1 | redact >> "$OUTFILE"

# ---------------------------------------------------------------------------
# 4. Configuration -- NAMES AND LENGTHS ONLY, NEVER VALUES
# ---------------------------------------------------------------------------
printf '  %s[4/9]%s Configuration (redacted)...\n' "$C_INF" "$C_RST"
sec "4. CONFIGURATION"
note ""
note "Values are NEVER shown. Each entry reports whether the key is set and"
note "how long the value is, which is what actually matters for diagnosis."

sub ".env"
# NOTE: this whole block is wrapped in { ... } >> "$OUTFILE" so that every
# printf lands in the report. Without the wrapper the output goes to the
# terminal and this section silently comes out EMPTY -- which is exactly the
# section you most need when diagnosing a configuration problem.
{
if [[ -f .env ]]; then
  printf 'permissions: %s (expected 600)\n\n' "$(stat -c '%a' .env 2>/dev/null)"

  # Keys whose values are safe and useful to show verbatim.
  SAFE_KEYS="OLLAMA_NUM_PARALLEL|OLLAMA_MAX_LOADED_MODELS|OLLAMA_KEEP_ALIVE|OLLAMA_CONTEXT_LENGTH|OLLAMA_FLASH_ATTENTION|OLLAMA_KV_CACHE_TYPE|OLLAMA_MEM_LIMIT|WEBUI_MEM_LIMIT|OLLAMA_CPUS|WEBUI_CPUS|WEBUI_AUTH|VLLM_PORT|VLLM_MODEL_NAME|POD_WARMUP_TIMEOUT|RAG_EMBEDDING_MODEL|ENABLE_OPENAI_API|SCARF_NO_ANALYTICS|DO_NOT_TRACK|ANONYMIZED_TELEMETRY|PEER_HOSTNAME|PEER_HOSTNAMES|OPENHANDS_PORT|OPENHANDS_IMAGE|OPENHANDS_AGENT_IMAGE_REPOSITORY|OPENHANDS_AGENT_IMAGE_TAG|OPENHANDS_LOG_ALL_EVENTS|OPENHANDS_MEM_LIMIT|OPENHANDS_CPUS|STATUS_UID|DOCKER_GID"

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      k="${BASH_REMATCH[1]}"; v="${BASH_REMATCH[2]}"
      if [[ -z "$v" ]]; then
        printf '  %-32s <EMPTY>\n' "$k"
      elif [[ "$k" =~ ^(${SAFE_KEYS})$ ]]; then
        printf '  %-32s %s\n' "$k" "$v"
      elif [[ "$k" == "TAILSCALE_IP" ]]; then
        # The SHAPE matters for diagnosis (is it inside the mesh range?);
        # the exact host does not.
        if [[ "$v" =~ ^100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\. ]]; then
          printf '  %-32s 100.x.x.x  (VALID mesh range)\n' "$k"
        else
          printf '  %-32s <set>  <-- OUTSIDE 100.64.0.0/10, pipe will refuse to send\n' "$k"
        fi
      elif [[ "$k" =~ ^(OPENHANDS_WORKSPACE|OPENHANDS_STATE_DIR)$ ]]; then
        # Path shape matters a great deal here: if the workspace IS the
        # deployment directory, the agent sandbox can read .env.
        if [[ "$(readlink -f "$v" 2>/dev/null)" == "$(readlink -f "$SCRIPT_DIR")" ]]; then
          printf '  %-32s <deployment dir>  <-- ISOLATION BROKEN, sandbox can read .env\n' "$k"
        else
          printf '  %-32s <set, outside the repo>\n' "$k"
        fi
      else
        printf '  %-32s <REDACTED:length=%s>\n' "$k" "${#v}"
      fi
    fi
  done < .env
else
  printf '  .env NOT FOUND -- run ./install.sh\n'
fi
} 2>&1 | redact >> "$OUTFILE"

sub "Backup credentials"
BC="${HOME}/.config/hybrid-ai-backup"
if [[ -d "$BC" ]]; then
  {
    for f in r2.env repo-password; do
      if [[ -f "${BC}/${f}" ]]; then
        printf '  %-16s present, permissions %s (expected 600)\n' "$f" "$(stat -c '%a' "${BC}/${f}" 2>/dev/null)"
      else
        printf '  %-16s MISSING\n' "$f"
      fi
    done
    # Repository URL shape is useful; the account id inside it is not.
    if [[ -f "${BC}/r2.env" ]]; then
      repo="$(grep -E '^RESTIC_REPOSITORY=' "${BC}/r2.env" 2>/dev/null | cut -d= -f2-)"
      [[ -n "$repo" ]] && printf '  %-16s %s\n' "repository" "$(printf '%s' "$repo" | sed -E 's#(s3:https://)[^.]+(\.r2\.cloudflarestorage\.com/)(.*)#\1<REDACTED:account-id>\2\3#')"
    fi
  } 2>&1 | redact >> "$OUTFILE"
else
  note "  Not configured (${BC} does not exist)"
fi

sub "OpenHands credential store"
{
  if [[ -d "${HOME}/.openhands" ]]; then
    printf '  ~/.openhands      present, permissions %s (expected 700)\n' "$(stat -c '%a' "${HOME}/.openhands" 2>/dev/null)"
    printf '  contents          %s file(s) -- NOT read, only counted\n' \
      "$(find "${HOME}/.openhands" -type f 2>/dev/null | wc -l | tr -d ' ')"
  else
    printf '  ~/.openhands      not present (OpenHands not configured yet)\n'
  fi
} 2>&1 | redact >> "$OUTFILE"

run "docker-compose.yml images in use" bash -c "grep -E '^\s+image:' docker-compose.yml openhands/docker-compose.openhands.yml 2>/dev/null || echo 'not found'"
run "Git state" bash -c "git rev-parse --short HEAD 2>/dev/null && git status --porcelain 2>/dev/null | head -20 || echo 'not a git checkout'"

# ---------------------------------------------------------------------------
# 5. Containers
# ---------------------------------------------------------------------------
printf '  %s[5/9]%s Container status...\n' "$C_INF" "$C_RST"
sec "5. CONTAINERS"
run "Compose services"    "${COMPOSE[@]}" ps
run "All containers"      docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
run "Resource usage"      docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}'

for svc in ollama open-webui hybrid-ai-status hybrid-ai-proxy hybrid-ai-openhands; do
  sub "${svc}: state detail"
  {
    docker inspect "$svc" --format '
  status       : {{.State.Status}}
  running      : {{.State.Running}}
  paused       : {{.State.Paused}}
  restarting   : {{.State.Restarting}}
  exit code    : {{.State.ExitCode}}
  error        : {{.State.Error}}
  started at   : {{.State.StartedAt}}
  restart count: {{.RestartCount}}
  health       : {{if .State.Health}}{{.State.Health.Status}} (failing streak {{.State.Health.FailingStreak}}){{else}}no healthcheck{{end}}
  image        : {{.Config.Image}}' 2>&1 || printf '  container not found\n'
  } | redact >> "$OUTFILE"

  # The last healthcheck output explains *why* a container is unhealthy,
  # which the status alone never tells you.
  sub "${svc}: last healthcheck output"
  { docker inspect "$svc" --format '{{if .State.Health}}{{range .State.Health.Log}}exit={{.ExitCode}} {{.Output}}{{end}}{{else}}no healthcheck{{end}}' 2>&1 | tail -5 || true; } | redact >> "$OUTFILE"
done

# ---------------------------------------------------------------------------
# 6. Logs
# ---------------------------------------------------------------------------
printf '  %s[6/9]%s Logs (last %s lines each)...\n' "$C_INF" "$C_RST" "$LOG_LINES"
sec "6. LOGS"
run "open-webui (last ${LOG_LINES})" "${COMPOSE[@]}" logs --tail "$LOG_LINES" --no-color open-webui
run "ollama (last ${LOG_LINES})"     "${COMPOSE[@]}" logs --tail "$LOG_LINES" --no-color ollama
run "status page (last 40)"          "${COMPOSE[@]}" logs --tail 40 --no-color status
run "proxy (last 40)"                "${COMPOSE[@]}" logs --tail 40 --no-color proxy
run "openhands (last 40)"            "${COMPOSE[@]}" logs --tail 40 --no-color openhands

# The pipe's own structured records: one line per request outcome.
sub "RunPod pipe events (structured)"
{ "${COMPOSE[@]}" logs --tail 400 --no-color open-webui 2>/dev/null \
    | grep -E 'runpod_pipe|runpod_core|event=(request_|pod_ready|runpod_api)' | tail -60 \
    || printf '(none found)\n'; } | redact >> "$OUTFILE"

sub "Errors and exceptions across all containers"
{ "${COMPOSE[@]}" logs --tail 500 --no-color 2>/dev/null \
    | grep -iE 'error|exception|traceback|critical|fatal|refused|timeout|denied' \
    | tail -60 || printf '(none found)\n'; } | redact >> "$OUTFILE"

run "install.sh events" bash -c "grep '^EVENT' install.log 2>/dev/null | tail -25 || echo '(no install.log)'"

sub "Scheduled job history (last outcome per job)"
{
  if [[ -f backup.log || -f install.log ]]; then
    for ev in backup_success backup_failed check_success check_failed \
              restore_success restore_test_success restore_test_failed \
              retention_applied retention_failed install_success install_failed; do
      line="$(grep "event=${ev}" backup.log install.log 2>/dev/null | tail -1)"
      [[ -n "$line" ]] && printf '  %-24s %s\n' "$ev" "${line#*ts=}"
    done
  else
    printf '  (no event logs found)\n'
  fi
} 2>&1 | redact >> "$OUTFILE"

# ---------------------------------------------------------------------------
# 7. Network
# ---------------------------------------------------------------------------
printf '  %s[7/9]%s Network...\n' "$C_INF" "$C_RST"
sec "7. NETWORK"
run "Listening ports"  bash -c "ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null || echo 'unavailable'"
run "Tailscale status" bash -c "tailscale status 2>&1 || echo 'unavailable'"

sub "Tailscale detail"
{
  tailscale status --json 2>/dev/null | jq '{
    BackendState,
    Self:  {HostName: .Self.HostName, Online: .Self.Online, OS: .Self.OS},
    Peers: [ .Peer // {} | to_entries[] | .value
             | {HostName, Online, OS, LastSeen, ExitNode} ]
  }' 2>/dev/null || printf '(tailscale or jq unavailable)\n'
} | redact >> "$OUTFILE"

sub "GPU pod reachability"
{
  if [[ -f .env ]]; then
    TS_IP="$(grep -E '^TAILSCALE_IP=' .env 2>/dev/null | cut -d= -f2-)"
    VP="$(grep -E '^VLLM_PORT=' .env 2>/dev/null | cut -d= -f2-)"; VP="${VP:-8000}"
    if [[ -n "$TS_IP" ]]; then
      printf 'probing http://<pod>:%s/v1/models ...\n' "$VP"
      if curl -fsS --max-time 8 "http://${TS_IP}:${VP}/v1/models" 2>&1 | jq -c '.data[].id' 2>/dev/null; then
        printf 'RESULT: pod is AWAKE and serving\n'
      else
        printf 'RESULT: no response.\n'
        printf 'NOTE: this is NORMAL and expected when the pod is stopped.\n'
        printf '      The pod is stopped by design to avoid billing.\n'
      fi
    else
      printf 'TAILSCALE_IP not set in .env\n'
    fi
  fi
} 2>&1 | redact >> "$OUTFILE"

run "Local service probes" bash -c '
  printf "ollama     : "; curl -fsS --max-time 5 http://127.0.0.1:11434/api/tags >/dev/null 2>&1 && echo "responding" || echo "NOT RESPONDING"
  printf "open-webui : "; curl -fsS --max-time 5 http://127.0.0.1:3000/health >/dev/null 2>&1 && echo "responding" || echo "NOT RESPONDING"
  printf "status page: "; curl -fsS --max-time 5 http://127.0.0.1:80/status/healthz >/dev/null 2>&1 && echo "responding" || echo "NOT RESPONDING (optional)"
  printf "openhands  : "; curl -fsS --max-time 5 http://127.0.0.1:3001 >/dev/null 2>&1 && echo "responding (loopback only, by design)" || echo "NOT RESPONDING (optional)"
  for p in /hub /status /app/ /openwebui /health /ollama/api/tags; do
    printf "route %-16s " "$p"
    curl -s -o /dev/null -w "HTTP %{http_code}\n" --max-time 6 "http://127.0.0.1:80${p}" 2>/dev/null || echo "unreachable"
  done
  printf "NOTE: /openwebui returns 302 by design; /health returns 503 when degraded.\n"
  printf "NOTE: OpenHands is deliberately NOT routed through the proxy.\n"
  printf "internet   : "; curl -fsS --max-time 5 https://api.runpod.io >/dev/null 2>&1 && echo "reachable" || echo "NOT REACHABLE"
  printf "dns        : "; getent hosts api.runpod.io >/dev/null 2>&1 && echo "resolving" || echo "NOT RESOLVING"'

# ---------------------------------------------------------------------------
# 8. Data and models -- METADATA ONLY
# ---------------------------------------------------------------------------
printf '  %s[8/9]%s Data and models...\n' "$C_INF" "$C_RST"
sec "8. DATA AND MODELS"
note ""
note "Sizes and counts only. No chat content, document text, or vectors are read."

run "Data directory sizes" bash -c "du -sh webui_data ollama_data 2>/dev/null || echo 'not present'"
run "webui_data layout"    bash -c "du -sh webui_data/* 2>/dev/null | sort -rh | head -15 || echo 'not present'"

sub "Database health and row counts"
{
  if command -v sqlite3 >/dev/null 2>&1 && [[ -f webui_data/webui.db ]]; then
    printf 'webui.db integrity : %s\n' "$(sqlite3 'file:webui_data/webui.db?mode=ro' 'PRAGMA quick_check;' 2>&1 | head -1)"
    printf 'webui.db size      : %s\n' "$(du -h webui_data/webui.db 2>/dev/null | cut -f1)"
    printf '\nrow counts (how much is configured, not what it contains):\n'
    for t in chat user function tool model knowledge prompt config; do
      c="$(sqlite3 'file:webui_data/webui.db?mode=ro' "SELECT COUNT(*) FROM ${t};" 2>/dev/null || echo 'n/a')"
      printf '  %-12s %s\n' "$t" "$c"
    done
    printf '\ninstalled functions/pipes (ids only):\n'
    sqlite3 'file:webui_data/webui.db?mode=ro' "SELECT '  ' || id || '  active=' || is_active FROM function;" 2>/dev/null || printf '  (none or table absent)\n'
  else
    printf 'sqlite3 unavailable or webui.db not present\n'
  fi
  if [[ -f webui_data/vector_db/chroma.sqlite3 ]]; then
    printf '\nchroma.sqlite3     : %s\n' "$(du -h webui_data/vector_db/chroma.sqlite3 2>/dev/null | cut -f1)"
    printf 'vector index dirs  : %s\n' "$(find webui_data/vector_db -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"
  fi
} 2>&1 | redact >> "$OUTFILE"

run "Ollama models" bash -c "docker exec ollama ollama list 2>/dev/null || echo 'ollama not running'"

# ---------------------------------------------------------------------------
# 9. Backups
# ---------------------------------------------------------------------------
printf '  %s[9/9]%s Backups...\n' "$C_INF" "$C_RST"
sec "9. BACKUPS"
run "Timers" bash -c "systemctl --user list-timers 'hybrid-ai-*' --no-pager 2>/dev/null || echo 'no user timers'"
run "Linger (required for backups to run while logged out)" bash -c "loginctl show-user \"\$USER\" 2>/dev/null | grep -i linger || echo 'unknown'"
run "Recent backup events" bash -c "grep '^EVENT' backup.log 2>/dev/null | tail -25 || echo '(no backup.log)'"
run "Backup service journal" bash -c "journalctl --user -u hybrid-ai-backup.service -n 40 --no-pager 2>/dev/null || echo 'unavailable'"

# ---------------------------------------------------------------------------
# 10. Self-audit -- scan the finished file for anything still secret-shaped
#
# The redaction filter is regex-based and therefore fallible. This final pass
# re-reads what we just wrote and flags anything suspicious, so a leak is
# caught before you paste the file somewhere public.
# ---------------------------------------------------------------------------
sec "10. REDACTION SELF-AUDIT"
SUSPECT=0
{
  if (( REDACT )); then
    printf 'Scanning the finished report for anything that still looks secret.\n\n'
    declare -A CHECKS=(
      ["RunPod API key"]='rpa_[A-Za-z0-9_-]{8,}'
      ["Tailscale key"]='tskey-[A-Za-z0-9_-]{8,}'
      ["AWS key id"]='(AKIA|ASIA)[A-Z0-9]{16}'
      ["GitHub token"]='gh[pousr]_[A-Za-z0-9]{20,}'
      ["LLM API key"]='sk-[A-Za-z0-9_-]{20,}'
      ["JWT"]='ey[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.'
      ["Private key block"]='BEGIN [A-Z ]*PRIVATE KEY'
      ["Credentials in URL"]='https?://[^:@[:space:]/]+:[^@[:space:]]+@'
      ["Full Tailscale IP"]='100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}'
    )
    for name in "${!CHECKS[@]}"; do
      # CAREFUL: `grep -c ... || echo 0` is wrong. When grep finds nothing it
      # PRINTS "0" and ALSO exits non-zero, so the fallback appends a second
      # "0" and the variable becomes "0\n0" -- which then blows up the
      # numeric comparison and silently disables this entire audit.
      # Count lines from the match output instead.
      n="$(grep -oE "${CHECKS[$name]}" "$OUTFILE" 2>/dev/null | wc -l | tr -d ' ')"
      n="${n:-0}"
      if (( n > 0 )); then
        printf '  [!] %-22s %s possible match(es) -- REVIEW BEFORE SHARING\n' "$name" "$n"
        SUSPECT=$(( SUSPECT + n ))
      else
        printf '  [ok] %-21s clean\n' "$name"
      fi
    done
    printf '\n'
    if (( SUSPECT > 0 )); then
      printf 'RESULT: %s possible secret(s) survived redaction. Inspect the file\n' "$SUSPECT"
      printf '        and remove them manually before sharing.\n'
    else
      printf 'RESULT: no known secret patterns detected.\n'
      printf 'NOTE:   this is best-effort pattern matching, not a guarantee.\n'
      printf '        Please still skim the file before sharing it.\n'
    fi
  else
    printf '*** REDACTION WAS DISABLED (--no-redact) ***\n'
    printf 'This file CONTAINS SECRETS. Do not share it with anyone.\n'
    SUSPECT=-1
  fi
} >> "$OUTFILE"

printf '\n\n===============================================================\n  END OF REPORT\n===============================================================\n' >> "$OUTFILE"
chmod 600 "$OUTFILE"

SIZE="$(du -h "$OUTFILE" | cut -f1)"
LINES="$(wc -l < "$OUTFILE" | tr -d ' ')"

printf '\n%s\n' "============================================================"
printf '  %sReport written%s\n\n' "$C_OK" "$C_RST"
printf '    file  : %s\n' "$OUTFILE"
printf '    size  : %s  (%s lines)\n' "$SIZE" "$LINES"
printf '    perms : 600 (only you can read it)\n\n'

if (( REDACT )); then
  if (( SUSPECT > 0 )); then
    printf '  %sWARNING: %s possible secret(s) survived redaction.%s\n' "$C_ERR" "$SUSPECT" "$C_RST"
    printf '  Read section 10 and clean the file before sharing.\n\n'
  else
    printf '  %sSelf-audit found no known secret patterns.%s\n\n' "$C_OK" "$C_RST"
  fi
  printf '  %sSkim it before sharing -- redaction is best-effort:%s\n' "$C_WRN" "$C_RST"
  printf '    less %s\n\n' "$OUTFILE"
  printf '  Then paste it into an AI chat with a question like:\n'
  printf '    "Here is a diagnostic report from my self-hosted AI stack.\n'
  printf '     <describe what is going wrong>. What is the root cause?"\n\n'
else
  printf '  %sREDACTION DISABLED -- this file contains live secrets.%s\n' "$C_ERR" "$C_RST"
  printf '  Do not share it. Delete it when finished:\n'
  printf '    shred -u %s\n\n' "$OUTFILE"
fi
printf '%s\n' "============================================================"

(( SUSPECT > 0 )) && exit 1
exit 0
```


## File: docker-compose.yml
---
Directory: `.`
---
```yaml
# ---------------------------------------------------------------------------
# FILE: docker-compose.yml
# PURPOSE (plain English):
#   This file is the blueprint for the programs that run on your Raspberry Pi.
#   Docker Compose reads it and starts each one as a "container" -- an isolated
#   mini-environment that bundles an app with everything it needs.
#
#   The containers are:
#     - ollama      : runs small AI models directly on the Pi
#     - open-webui  : the chat website you actually open in your browser
#     - status      : the health/diagnostics page
#     - proxy       : Caddy, giving you one address for everything
#
#   A fifth, OpenHands, lives in openhands/docker-compose.openhands.yml and is
#   layered on top as an overlay. See the note below.
#
# HOW IT IS RUN:
#   Never run this by hand. The install.sh script runs it for you, because it
#   first has to generate the .env file that fills in all the ${VARIABLES}
#   below. If you run it manually you will get "variable is not set" warnings.
#
#   install.sh effectively calls:
#     docker compose -f docker-compose.yml \
#                    -f openhands/docker-compose.openhands.yml \
#                    --env-file .env up -d --remove-orphans
#
#   ALWAYS PASS BOTH FILES. A "up -d --remove-orphans" without the overlay
#   treats the OpenHands container as an orphan and DELETES it.
#
# THE PERSISTENCE CONTRACT (important -- read this):
#   ./ollama_data  -> downloaded AI model files
#   ./webui_data   -> your chat history, uploaded documents, and vector database
#
#   These are "bind mounts": real folders on the Pi's disk that get mapped
#   into the containers. We deliberately did NOT use Docker "named volumes",
#   because named volumes are hidden away in Docker's internals and are easy to
#   delete by accident. With bind mounts, you can see your data, back it up
#   with a normal file copy, and destroy/rebuild containers as often as you
#   like without ever losing it.
#
#   Back up these two folders. Everything else in this repo is disposable.
# ---------------------------------------------------------------------------

services:

  # -------------------------------------------------------------------------
  # OLLAMA :: the local, lightweight AI engine
  #
  # Handles the cheap, fast, private work: routing decisions, short summaries,
  # and turning your documents into embeddings (the numeric representations
  # that make document search work). Anything it can answer never leaves the Pi.
  # -------------------------------------------------------------------------
  ollama:
    # SECURITY: pin to an explicit version, not :latest. A mutable tag means
    # `docker compose pull` can silently swap the image underneath you, which
    # is both a supply-chain risk and an unreproducible-deploy problem.
    # Bump deliberately after reading the release notes.
    # Overridable so a version bump is an .env change plus a restart, not a
    # commit. The default is still an explicit pin, never :latest.
    image: ${OLLAMA_IMAGE:-ollama/ollama:0.34.4}
    container_name: ollama
    restart: unless-stopped
    ports:
      # "127.0.0.1:" at the front means ONLY this Pi can reach this port.
      # Without that prefix, the port would be open to your whole network.
      # Open WebUI still reaches it privately via the Docker network.
      - "127.0.0.1:11434:11434"
    volumes:
      # Format is  <folder on the Pi>:<folder inside the container>
      - ./ollama_data:/root/.ollama
    # A REAL, kernel-enforced memory cap. This is what actually stops a model
    # from taking the whole machine down -- unlike OLLAMA_MAX_VRAM, which was
    # never honoured by Ollama and has been removed upstream.
    mem_limit: ${OLLAMA_MEM_LIMIT:-8g}
    mem_reservation: 512m
    # Leave roughly half a core for the OS, the UI, and the proxy. Without
    # this, a busy inference run makes the whole Pi feel unresponsive,
    # including the web UI you are waiting on. install.sh computes this from
    # your actual core count and writes it to .env.
    cpus: ${OLLAMA_CPUS:-3.5}
    environment:
      OLLAMA_HOST: 0.0.0.0:11434
      # How long a model stays resident. Reloading a 2 GB model from disk is
      # slow; on a 16 GB Pi there is room to keep it warm much longer, which
      # makes follow-up questions feel far faster than the first one.
      OLLAMA_KEEP_ALIVE: ${OLLAMA_KEEP_ALIVE:-5m}
      # One request at a time. On a bandwidth-bound machine, concurrency does
      # not raise total throughput -- it just makes every request slower and
      # multiplies KV cache memory.
      OLLAMA_NUM_PARALLEL: ${OLLAMA_NUM_PARALLEL:-1}
      OLLAMA_MAX_LOADED_MODELS: ${OLLAMA_MAX_LOADED_MODELS:-1}
      # Ollama caps every model at 4096 tokens unless told otherwise, which
      # quietly truncates long chats and RAG context.
      #
      # VERSION DEPENDENCY: OLLAMA_CONTEXT_LENGTH is honoured only by newer
      # Ollama servers. On an older pinned image it is silently ignored and
      # you get 4096 regardless -- the same class of failure as the removed
      # OLLAMA_MAX_VRAM. install.sh verifies this after start and warns if
      # the setting did not take effect.
      OLLAMA_CONTEXT_LENGTH: ${OLLAMA_CONTEXT_LENGTH:-8192}
      OLLAMA_FLASH_ATTENTION: ${OLLAMA_FLASH_ATTENTION:-1}
      # f16 by default. q8_0 halves KV cache memory but requires flash
      # attention to be active; when Ollama auto-disables it for an
      # unsupported architecture, the runner panics instead of degrading.
      # See the note in install.sh before opting in.
      OLLAMA_KV_CACHE_TYPE: ${OLLAMA_KV_CACHE_TYPE:-f16}
      # --- Privacy: switch off every telemetry/analytics phone-home ---------
      SCARF_NO_ANALYTICS: "true"
      DO_NOT_TRACK: "true"
      ANONYMIZED_TELEMETRY: "false"
      OTEL_SDK_DISABLED: "true"
    healthcheck:
      # Docker runs this command periodically. If it fails repeatedly, Docker
      # marks the container unhealthy -- which is how open-webui knows to wait.
      test: ["CMD-SHELL", "ollama list >/dev/null 2>&1 || exit 1"]
      interval: 60s
      timeout: 10s
      retries: 5
      start_period: 60s
    logging:
      # Cap log size. An unbounded log file will eventually fill the disk.
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

  # -------------------------------------------------------------------------
  # OPEN WEBUI :: the chat interface and the brain of the control plane
  #
  # This is the website you visit at http://<pi-address>:3000. It stores your
  # conversations, holds your uploaded documents, runs the vector database, and
  # hosts the "pipe" function that reaches out to the cloud GPU when you pick
  # the big model.
  # -------------------------------------------------------------------------
  open-webui:
    # SECURITY: pinned for the same reason as Ollama above. ":main" tracks
    # the development branch and can change on any push upstream.
    image: ${WEBUI_IMAGE:-ghcr.io/open-webui/open-webui:v0.11.4}
    container_name: open-webui
    restart: unless-stopped
    depends_on:
      ollama:
        # Do not start until Ollama's healthcheck is passing, otherwise
        # Open WebUI boots with an empty model list and confuses you.
        condition: service_healthy
    # Embedding documents is Open WebUI's most memory-hungry operation by far;
    # this cap keeps a large upload from destabilising the whole machine.
    mem_limit: ${WEBUI_MEM_LIMIT:-3g}
    mem_reservation: 256m
    cpus: ${WEBUI_CPUS:-2.0}
    ports:
      # Reachable from your whole network (and tailnet) on port 3000.
      - "3000:8080"
    volumes:
      - ./webui_data:/app/backend/data
      # Mounted read-only (":ro"). This just makes the pipe source visible
      # inside the container for reference; you still import it through the UI.
      #
      # NOTE: because the pasted function lives in webui_data/webui.db, editing
      # the file here does NOT change what Open WebUI executes. Re-paste it.
      - ./openwebui:/app/backend/data/functions_src:ro
    environment:
      # --- Where to find the local model engine ----------------------------
      # "ollama" resolves to the other container by name on the Docker network.
      OLLAMA_BASE_URL: http://ollama:11434

      # --- Login session encryption ----------------------------------------
      # Generated once by install.sh and then reused forever. If this value
      # changes, everyone gets logged out.
      WEBUI_SECRET_KEY: ${WEBUI_SECRET_KEY}
      WEBUI_AUTH: ${WEBUI_AUTH:-true}

      # --- Cloud GPU settings, read by openwebui/runpod_pipe.py ------------
      RUNPOD_HOST: ${RUNPOD_HOST}
      PI_HOST: ${PI_HOST}
      # So the pipe's connection-error message names the right peer instead of
      # a hardcoded string that may not match what you called the pod.
      PEER_HOSTNAME: ${PEER_HOSTNAME:-runpod-worker}
      RUNPOD_API_KEY: ${RUNPOD_API_KEY}
      RUNPOD_POD_ID: ${RUNPOD_POD_ID}
      VLLM_PORT: ${VLLM_PORT:-8000}
      VLLM_MODEL_NAME: ${VLLM_MODEL_NAME:-Qwen/Qwen2.5-Coder-32B-Instruct-AWQ}
      POD_WARMUP_TIMEOUT: ${POD_WARMUP_TIMEOUT:-600} 
      # Pipe tuning, read by openwebui/runpod_pipe.py via os.getenv(). These 
      # are also exposed in the Valves panel; the Valves default to these. 
      VLLM_DISPLAY_NAME: ${VLLM_DISPLAY_NAME:-Qwen2.5-Coder-32B (RunPod)} 
      VLLM_REQUEST_TIMEOUT: ${VLLM_REQUEST_TIMEOUT:-900} 
      VLLM_MAX_TOKENS: ${VLLM_MAX_TOKENS:-4096} 
      PIPE_LOG_LEVEL: ${PIPE_LOG_LEVEL:-INFO}

      # --- Privacy / zero-trace enforcement --------------------------------
      SCARF_NO_ANALYTICS: "true"
      DO_NOT_TRACK: "true"
      ANONYMIZED_TELEMETRY: "false"
      OTEL_SDK_DISABLED: "true"
      # Stop the app calling out to community servers to share or rate chats.
      ENABLE_COMMUNITY_SHARING: "false"
      ENABLE_MESSAGE_RATING: "false"
      ENABLE_OPENAI_API: ${ENABLE_OPENAI_API:-false}
      # Document search stays local: embeddings are computed inside this
      # container and stored in Chroma on your disk. Nothing is shipped out.
      RAG_EMBEDDING_ENGINE: ""
      RAG_EMBEDDING_MODEL: ${RAG_EMBEDDING_MODEL:-sentence-transformers/all-MiniLM-L6-v2}
      VECTOR_DB: chroma
      CHROMA_TELEMETRY_DISABLED: "true"
      HF_HUB_DISABLE_TELEMETRY: "1"
      
    dns:
      - 100.100.100.100
    extra_hosts:
      # Lets the container reach services running on the Pi itself.
      - "host.docker.internal:host-gateway"
    healthcheck:
      # Tries curl, then wget, then Python. Open WebUI images have shipped
      # different toolsets over time, and a healthcheck that fails only
      # because a binary is missing produces a container marked "unhealthy"
      # while it is actually serving perfectly -- a confusing false alarm.
      test:
        - "CMD-SHELL"
        - >-
          curl -fsS http://localhost:8080/health >/dev/null 2>&1 ||
          wget -qO- http://localhost:8080/health >/dev/null 2>&1 ||
          python3 -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://localhost:8080/health',timeout=5).status==200 else 1)" ||
          exit 1
      interval: 60s
      timeout: 10s
      retries: 5
      start_period: 90s
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

  # -------------------------------------------------------------------------
  # STATUS PAGE :: at-a-glance health, log tails, and one-click diagnostics
  #
  # Reached at http://<your-pi>/status via the proxy below.
  #
  # SECURITY POSTURE -- this container is deliberately starved of privilege:
  #   - It is given NO credentials. Not .env, not an API key, nothing. It
  #     cannot leak what it was never given.
  #   - Its filesystem is read-only, it drops every Linux capability, and it
  #     runs as an unprivileged user.
  #   - It mounts only what it measures: webui_data and two log files, all
  #     read-only.
  #   - Docker socket access is read-only AND the app only ever issues GET
  #     requests. See status/README.md for the important caveat about what
  #     socket access really means.
  # -------------------------------------------------------------------------
  status:
    image: python:3.12-slim
    container_name: hybrid-ai-status
    restart: unless-stopped
    depends_on:
      - ollama
    # No published ports. The proxy is the only way in, which is what keeps
    # the IP allowlist in the Caddyfile from being trivially bypassed.
    expose:
      - "8088"
    # Tiny by design; capped so it can never crowd out inference.
    mem_limit: 256m
    cpus: "0.5"
    command: ["python", "-u", "/app/app.py"]
    volumes:
      - ./status/app.py:/app/app.py:ro
      # Read-only Docker socket: needed for container state and log tails.
      - /var/run/docker.sock:/var/run/docker.sock:ro
      # Measured, never read for content.
      - ./webui_data:/data/webui_data:ro
      - ./backup.log:/data/backup.log:ro
      - ./install.log:/data/install.log:ro
    environment:
      STATUS_PORT: "8088"
      LOCAL_DOMAIN: ${LOCAL_DOMAIN:?LOCAL_DOMAIN must be set}
      OLLAMA_URL: http://ollama:11434
      WEBUI_URL: http://open-webui:8080
      HERMES_URL: http://hermes:8501
      OPENHANDS_URL: http://openhands:3000
      WEBUI_DATA_PATH: /data/webui_data
      BACKUP_LOG_PATH: /data/backup.log
      INSTALL_LOG_PATH: /data/install.log
      # Not a secret: a private mesh address, and it is masked in all output.
      RUNPOD_HOST: ${RUNPOD_HOST}
      PI_HOST: ${PI_HOST}
      VLLM_PORT: ${VLLM_PORT:-8000}
      PYTHONDONTWRITEBYTECODE: "1"
      DO_NOT_TRACK: "true"
    dns:
      - 100.100.100.100
    user: "${STATUS_UID:-1000}:${DOCKER_GID:-999}"
    read_only: true
    tmpfs:
      - /tmp:size=16m,mode=1777
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    healthcheck:
      test: ["CMD-SHELL", "python -c \"import urllib.request;urllib.request.urlopen('http://127.0.0.1:8088/status/healthz',timeout=5)\" || exit 1"]
      interval: 60s
      timeout: 10s
      retries: 3
      start_period: 20s
    logging:
      driver: "json-file"
      options:
        max-size: "5m"
        max-file: "2"

  # -------------------------------------------------------------------------
  # REVERSE PROXY :: one address for everything
  #
  #   http://<your-pi>/status  -> status page (restricted to LAN + tailnet)
  #   http://<your-pi>/        -> Open WebUI
  #
  # Port 3000 remains published on open-webui so existing bookmarks and the
  # health checks in install.sh keep working unchanged.
  #
  # OpenHands is DELIBERATELY not proxied. See the note at the end of
  # status/Caddyfile for why.
  # -------------------------------------------------------------------------
  proxy:
    image: caddy:2.8-alpine
    container_name: hybrid-ai-proxy
    restart: unless-stopped
    depends_on:
      - open-webui
      - status
    mem_limit: 128m
    cpus: "0.5"
    ports:
      - "80:80"
    volumes:
      - ./status/Caddyfile:/etc/caddy/Caddyfile:ro
      # Caddy validates its config at boot; a syntax error here stops the
      # proxy only, leaving Open WebUI reachable on :3000.
      - ./webui_data/caddy:/data
    environment:
      LOCAL_DOMAIN: ${LOCAL_DOMAIN:?LOCAL_DOMAIN must be set}
      DO_NOT_TRACK: "true"
    security_opt:
      - no-new-privileges:true
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://127.0.0.1:80/status/healthz >/dev/null 2>&1 || exit 1"]
      interval: 60s
      timeout: 10s
      retries: 3
      start_period: 20s
    logging:
      driver: "json-file"
      options:
        max-size: "5m"
        max-file: "2"

# There is deliberately NO top-level "volumes:" block here. See the persistence
# contract note at the top of this file for why.

networks:
  default:
    name: hybrid-ai
```


## File: doctor.sh
---
Directory: `.`
---
```bash
#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: doctor.sh
# PURPOSE (plain English):
#   One command that checks everything and tells you, in plain language, what
#   is wrong and how to fix it. Run this first whenever something misbehaves.
#
#   It is completely read-only. It starts nothing, stops nothing, and changes
#   nothing -- so it is always safe to run, including on a system you think is
#   already broken.
#
# USAGE:
#   ./doctor.sh              run every check
#   ./doctor.sh --quiet      only show problems (good for cron)
#   ./doctor.sh --no-cloud   skip checks that contact RunPod or R2
#
# EXIT CODES (so you can use this in scripts or monitoring):
#   0  everything healthy
#   1  warnings only -- working, but something needs attention
#   2  one or more failures -- something is actually broken
# ---------------------------------------------------------------------------
set -uo pipefail   # deliberately NOT -e: a failing check must not abort the run

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

QUIET=0
NO_CLOUD=0
for arg in "$@"; do
  case "$arg" in
    --quiet)    QUIET=1 ;;
    --no-cloud) NO_CLOUD=1 ;;
    -h|--help)  sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

if [[ -t 1 ]]; then
  C_RST=$'\033[0m'; C_OK=$'\033[32m'; C_WRN=$'\033[33m'
  C_ERR=$'\033[31m'; C_DIM=$'\033[2m'; C_HDR=$'\033[1;36m'
else
  C_RST=""; C_OK=""; C_WRN=""; C_ERR=""; C_DIM=""; C_HDR=""
fi

PASS=0; WARN=0; FAIL=0
declare -a REMEDIES=()

section() { (( QUIET )) || printf '\n%s%s%s\n' "$C_HDR" "$1" "$C_RST"; }
pass() { PASS=$(( PASS + 1 )); (( QUIET )) || printf '  %s✓%s %s\n' "$C_OK" "$C_RST" "$1"; }
warn() {
  WARN=$(( WARN + 1 ))
  printf '  %s!%s %s\n' "$C_WRN" "$C_RST" "$1"
  [[ -n "${2:-}" ]] && REMEDIES+=("${C_WRN}!${C_RST} $2")
}
fail() {
  FAIL=$(( FAIL + 1 ))
  printf '  %s✗%s %s\n' "$C_ERR" "$C_RST" "$1"
  [[ -n "${2:-}" ]] && REMEDIES+=("${C_ERR}✗${C_RST} $2")
}

(( QUIET )) || {
  printf '%s\n' "============================================================"
  printf '  hybrid-ai health check  ::  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  printf '%s\n' "============================================================"
}

# ---------------------------------------------------------------------------
# 1. Host prerequisites
# ---------------------------------------------------------------------------
section "Host"

ARCH="$(uname -m 2>/dev/null)"
if [[ "$ARCH" == "aarch64" || "$ARCH" == "x86_64" ]]; then
  pass "Architecture: ${ARCH}"
else
  fail "Architecture ${ARCH} is not 64-bit." \
       "Reflash with the 64-bit Raspberry Pi OS image. Ollama will not run on 32-bit."
fi

# Some of these have their own installers rather than an apt package, so the
# remedy text is per-tool rather than a generic "apt-get install".
install_hint() {
  case "$1" in
    docker)    printf 'curl -fsSL https://get.docker.com | sudo sh' ;;
    tailscale) printf 'curl -fsSL https://tailscale.com/install.sh | sudo sh' ;;
    *)         printf 'sudo apt-get install -y %s' "$1" ;;
  esac
}

for bin in docker jq curl; do
  if command -v "$bin" >/dev/null 2>&1; then
    pass "${bin} installed"
  else
    fail "${bin} is missing" "Install ${bin}: $(install_hint "$bin")"
  fi
done

# These are needed for backups and the mesh network, but the core chat stack
# still works without them -- so they are warnings, not failures.
for bin in sqlite3 rsync restic tailscale; do
  if command -v "$bin" >/dev/null 2>&1; then
    pass "${bin} installed"
  else
    warn "${bin} is not installed" "Install ${bin}: $(install_hint "$bin")"
  fi
done

if docker info >/dev/null 2>&1; then
  pass "Docker daemon reachable"
else
  fail "Cannot talk to the Docker daemon" \
       "Is it running? Are you in the docker group? 'sudo usermod -aG docker \$USER', then log out and back in."
fi

# --- Disk -------------------------------------------------------------------
# A full disk is behind a surprising share of 'it just stopped working'.
DISK_PCT="$(df --output=pcent / 2>/dev/null | tail -1 | tr -dc '0-9')"
if [[ -n "$DISK_PCT" ]]; then
  if (( DISK_PCT >= 90 )); then
    fail "Disk ${DISK_PCT}% full" \
         "Free space now: 'docker system prune -a --volumes=false' and remove unused Ollama models."
  elif (( DISK_PCT >= 75 )); then
    warn "Disk ${DISK_PCT}% full" "Consider pruning Docker images and unused models."
  else
    pass "Disk ${DISK_PCT}% used"
  fi
fi

# --- Storage type -----------------------------------------------------------
# After model size, this is the biggest performance factor on a Pi: NVMe loads
# models several times faster than an SD card, and SD cards wear out under the
# constant small writes a vector database produces.
ROOT_SRC="$(findmnt -n -o SOURCE / 2>/dev/null || echo '')"
case "$ROOT_SRC" in
  *nvme*)
    pass "Booted from NVMe (recommended)"
    # The drive's own endurance counter, if the nvme tool is available.
    if command -v nvme >/dev/null 2>&1; then
      USED="$(sudo -n nvme smart-log /dev/nvme0 2>/dev/null | awk -F: '/percentage_used/ {gsub(/[^0-9]/,"",$2); print $2}')"
      if [[ -n "$USED" ]]; then
        if [[ "$USED" -ge 80 ]]; then
          warn "NVMe write endurance ${USED}% consumed" "Plan a replacement; ensure backups are current."
        else
          pass "NVMe endurance: ${USED}% consumed"
        fi
      fi
    fi
    ;;
  *mmcblk*)
    # Catching this specific case is worth the extra check: an NVMe drive
    # present but not booted from means you paid for speed you are not
    # getting, and nothing else would ever tell you.
    if lsblk -dno NAME 2>/dev/null | grep -q '^nvme'; then
      fail "Booted from SD card even though an NVMe drive is installed" \
           "The SSD is idle while everything runs at SD speed. Fix the boot order: sudo raspi-config -> Advanced Options -> Boot Order -> NVMe/USB Boot"
    else
      warn "Booted from SD card" \
           "Model loads are several times slower and SD cards wear out under vector-DB writes. An NVMe SSD via the PCIe HAT is the recommended storage for this build."
    fi
    ;;
  *) [[ -n "$ROOT_SRC" ]] && pass "Root filesystem: ${ROOT_SRC}" ;;
esac

# --- Memory -----------------------------------------------------------------
TOTAL_MB="$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)"
if [[ -n "$TOTAL_MB" ]]; then
  if (( TOTAL_MB < 3500 )); then
    warn "Only ${TOTAL_MB} MiB RAM" "Stick to 1B local models on this machine."
  else
    pass "RAM: ${TOTAL_MB} MiB"
  fi

  # Capacity is rarely the real limit on a Pi -- memory BANDWIDTH is. A 16 GB
  # board can load an 8B model but will still only manage 1-3 tokens/sec,
  # because every token requires reading every weight. Flag oversized models
  # explicitly, since "it fits in RAM" misleads people into choosing them.
  if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx ollama; then
    BIG="$(docker exec ollama ollama list 2>/dev/null | awk 'NR>1 && $3+0 > 5 {print $1" ("$3$4")"}')"
    if [[ -n "$BIG" ]]; then
      warn "Large local model(s) installed: $(echo "$BIG" | tr '\n' ' ')" \
           "On a Pi these run at roughly 1-3 tok/s regardless of RAM (memory bandwidth, not capacity, is the limit). A 3B model is the interactive sweet spot; send hard work to the GPU pod."
    fi
  fi
fi

# --- Thermals ---------------------------------------------------------------
# A throttled Pi looks like a software performance problem but is not one.
if command -v vcgencmd >/dev/null 2>&1; then
  THROTTLED="$(vcgencmd get_throttled 2>/dev/null | cut -d= -f2)"
  if [[ "$THROTTLED" == "0x0" ]]; then
    pass "No thermal throttling"
  elif [[ -n "$THROTTLED" ]]; then
    warn "Throttling detected (${THROTTLED})" \
         "Add active cooling and verify you are using the official power supply."
  fi
fi

# --- Storage health ---------------------------------------------------------
if dmesg 2>/dev/null | grep -qiE 'mmcblk.*(i/o error|failed)'; then
  fail "Storage I/O errors found in the kernel log" \
       "Your SD card may be failing. Back up now and replace it, ideally with an SSD."
fi

# ---------------------------------------------------------------------------
# 2. Configuration
# ---------------------------------------------------------------------------
section "Configuration"

if [[ -f .env ]]; then
  pass ".env present"
  PERMS="$(stat -c '%a' .env 2>/dev/null)"
  if [[ "$PERMS" == "600" ]]; then
    pass ".env permissions correct (600)"
  else
    fail ".env permissions are ${PERMS}, expected 600" "Fix: chmod 600 .env"
  fi

  for key in WEBUI_SECRET_KEY RUNPOD_API_KEY RUNPOD_POD_ID TAILSCALE_IP PEER_HOSTNAME; do
    val="$(grep -E "^${key}=" .env 2>/dev/null | head -1 | cut -d= -f2-)"
    if [[ -n "$val" ]]; then
      pass "${key} is set"
    else
      warn "${key} is empty" "Re-run ./install.sh to populate it."
    fi
  done

  TS_IP="$(grep -E '^TAILSCALE_IP=' .env 2>/dev/null | cut -d= -f2-)"
  if [[ -n "$TS_IP" ]]; then
    # Mesh addresses are 100.64.x.x - 100.127.x.x. Anything else means the
    # pipe will refuse to send, which is the safety net working correctly.
    if [[ "$TS_IP" =~ ^100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\. ]]; then
      pass "TAILSCALE_IP is a valid mesh address"
    else
      fail "TAILSCALE_IP (${TS_IP}) is outside the Tailscale range" \
           "The pipe will refuse to send prompts. Re-run ./install.sh to rediscover the pod."
    fi
  fi

  # --- OpenHands credential store -----------------------------------------
  # Holds the LLM provider key you enter in the OpenHands UI. Outside the repo
  # so it is never committed and never visible to the agent sandbox.
  if [[ -d "${HOME}/.openhands" ]]; then
    OH_PERMS="$(stat -c '%a' "${HOME}/.openhands" 2>/dev/null)"
    if [[ "$OH_PERMS" == "700" ]]; then
      pass "~/.openhands permissions correct (700)"
    else
      fail "~/.openhands is ${OH_PERMS}, expected 700" \
           "Fix: chmod 700 ${HOME}/.openhands"
    fi
  fi

  # --- Agent workspace isolation ------------------------------------------
  # THE control that keeps the OpenHands sandbox away from .env. The sandbox
  # runs as your uid, so file permissions would not stop it reading the file;
  # what stops it is the workspace being a separate clone entirely.
  OH_WS="$(grep -E '^OPENHANDS_WORKSPACE=' .env 2>/dev/null | head -1 | cut -d= -f2-)"
  if [[ -n "$OH_WS" ]]; then
    OH_WS_REAL="$(readlink -f "$OH_WS" 2>/dev/null || echo "$OH_WS")"
    DEPLOY_REAL="$(readlink -f "$SCRIPT_DIR")"
    if [[ "$OH_WS_REAL" == "$DEPLOY_REAL" ]]; then
      fail "OPENHANDS_WORKSPACE is the deployment directory" \
           "The agent sandbox could read .env and the log files. Fix: ./scripts/setup-agent-workspace.sh"
    elif [[ -e "${OH_WS}/.env" ]]; then
      fail "A .env exists inside the agent workspace" \
           "That defeats the isolation. Remove it: rm ${OH_WS}/.env"
    elif [[ -d "${OH_WS}/.git" ]]; then
      pass "Agent workspace isolated from the deployment directory"
    else
      warn "Agent workspace ${OH_WS} is not a git clone" \
           "OpenHands will start with an empty workspace. Fix: ./scripts/setup-agent-workspace.sh"
    fi
  fi
else
  fail ".env is missing" "Run ./install.sh to create it."
fi

# ---------------------------------------------------------------------------
# 3. Containers
# ---------------------------------------------------------------------------
section "Containers"

for svc in ollama open-webui hybrid-ai-status hybrid-ai-proxy hybrid-ai-openhands; do
  STATE="$(docker inspect -f '{{.State.Status}}' "$svc" 2>/dev/null)"
  case "$STATE" in
    running)
      HEALTH="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$svc" 2>/dev/null)"
      if [[ "$HEALTH" == "healthy" || "$HEALTH" == "none" ]]; then
        pass "${svc} running"
      elif [[ "$HEALTH" == "starting" ]]; then
        warn "${svc} still starting" "Give it a minute, then re-run this check."
      else
        warn "${svc} running but reported ${HEALTH}" \
             "Check logs: docker compose --env-file .env logs --tail 50 ${svc}"
      fi
      RESTARTS="$(docker inspect -f '{{.RestartCount}}' "$svc" 2>/dev/null || echo 0)"
      if [[ "${RESTARTS:-0}" -gt 5 ]]; then
        warn "${svc} has restarted ${RESTARTS} times" \
             "Something is crashing it. Check the logs and available memory."
      fi
      ;;
    paused)
      warn "${svc} is PAUSED" \
           "A backup may have been interrupted. Resume with: docker unpause ${svc}"
      ;;
    "")
      # The status page, proxy and OpenHands are optional conveniences; chat
      # works perfectly without them, so their absence is not a failure.
      if [[ "$svc" == hybrid-ai-* ]]; then
        warn "${svc} does not exist" "Optional. Run ./install.sh to add it."
      else
        fail "${svc} does not exist" "Run ./install.sh to create it."
      fi ;;
    *)
      fail "${svc} is ${STATE}" \
           "Start it with ./install.sh, or inspect: docker compose --env-file .env logs --tail 50 ${svc}" ;;
  esac
done

# ---------------------------------------------------------------------------
# 4. Services actually responding
# ---------------------------------------------------------------------------
section "Services"

if curl -fsS --max-time 5 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
  MODELS="$(curl -fsS --max-time 5 http://127.0.0.1:11434/api/tags 2>/dev/null | jq -r '.models | length' 2>/dev/null || echo '?')"
  if [[ "$MODELS" == "0" ]]; then
    warn "Ollama is running but has no models" \
         "Pull one: docker exec -it ollama ollama pull llama3.2:3b"
  else
    pass "Ollama responding (${MODELS} model(s))"
  fi
else
  fail "Ollama is not responding on port 11434" \
       "Check: docker compose --env-file .env logs --tail 50 ollama"
fi

if curl -fsS --max-time 5 http://127.0.0.1:3000/health >/dev/null 2>&1; then
  pass "Open WebUI responding on port 3000"
else
  fail "Open WebUI is not responding on port 3000" \
       "Check: docker compose --env-file .env logs --tail 50 open-webui"
fi

# OpenHands is loopback-only by design, so this probe works on the Pi itself
# but will never be reachable from elsewhere without an SSH tunnel.
OH_PORT="$(grep -E '^OPENHANDS_PORT=' .env 2>/dev/null | head -1 | cut -d= -f2-)"
OH_PORT="${OH_PORT:-3001}"
if docker inspect -f '{{.State.Status}}' hybrid-ai-openhands >/dev/null 2>&1; then
  if curl -fsS --max-time 5 "http://127.0.0.1:${OH_PORT}" >/dev/null 2>&1; then
    pass "OpenHands responding on 127.0.0.1:${OH_PORT} (tunnel to reach it remotely)"
  else
    warn "OpenHands container exists but is not answering on ${OH_PORT}" \
         "Optional feature. Check: ./openhands/scripts/openhands-control.sh logs"
  fi
fi

# Check every logical path the proxy is supposed to serve. Checking them
# individually means a single broken route is identified precisely, rather
# than reported as a vague "the proxy is unhappy".
if curl -fsS --max-time 5 http://127.0.0.1:80/status/healthz >/dev/null 2>&1; then
  pass "Proxy: /status responding"
  for route in "/hub:hub page" "/app/:Open WebUI" "/health:health summary"; do
    path="${route%%:*}"; label="${route#*:}"
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 "http://127.0.0.1:80${path}" 2>/dev/null)"
    # /health returns 503 by design when any check is degraded; that is the
    # endpoint working correctly, not a routing failure.
    if [[ "$code" =~ ^(200|503)$ ]]; then
      pass "Proxy: ${path} -> ${label} (HTTP ${code})"
    else
      warn "Proxy: ${path} returned HTTP ${code}" \
           "Check the Caddyfile and: docker compose --env-file .env logs --tail 30 proxy"
    fi
  done
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 "http://127.0.0.1:80/openwebui" 2>/dev/null)"
  if [[ "$code" == "302" ]]; then
    pass "Proxy: /openwebui redirects to /app/ (expected)"
  else
    warn "Proxy: /openwebui returned HTTP ${code}, expected 302" \
         "Open WebUI cannot be served under a subpath; this alias must redirect."
  fi
else
  warn "Status page not reachable on port 80" \
       "Optional feature. Chat still works on :3000. Check: docker compose --env-file .env logs --tail 30 proxy status"
fi

# ---------------------------------------------------------------------------
# 5. Network
# ---------------------------------------------------------------------------
section "Tailscale"

if command -v tailscale >/dev/null 2>&1; then
  TS_STATE="$(tailscale status --json 2>/dev/null | jq -r '.BackendState // "Unknown"' 2>/dev/null || echo Unknown)"
  if [[ "$TS_STATE" == "Running" ]]; then
    SELF="$(tailscale ip -4 2>/dev/null | head -1)"
    pass "Tailscale connected (this node: ${SELF:-unknown})"

    # Match either the role-based name or the legacy one, so this check keeps
    # working whichever you called the pod. install.sh prefers runpod-worker.
    PEER_JSON="$(tailscale status --json 2>/dev/null | jq -r '
      (.Peer // {}) | to_entries | map(.value)
      | map(select((.HostName // "") | ascii_downcase | test("runpod-(worker|vllm)")))
      | .[0] // empty' 2>/dev/null)"

    if [[ -n "$PEER_JSON" ]]; then
      PEER_NAME="$(printf '%s' "$PEER_JSON" | jq -r '.HostName // "?"' 2>/dev/null)"
      ONLINE="$(printf '%s' "$PEER_JSON" | jq -r '.Online // false' 2>/dev/null)"
      if [[ "$ONLINE" == "true" ]]; then
        pass "GPU pod '${PEER_NAME}' is online"
      else
        # This is the normal, money-saving state. Not a problem.
        pass "GPU pod '${PEER_NAME}' known but stopped (normal - it wakes on demand)"
      fi
    else
      warn "GPU pod has never joined this tailnet" \
           "Start the pod once manually, then re-run ./install.sh to discover it."
    fi
  else
    fail "Tailscale backend state: ${TS_STATE}" "Run: sudo tailscale up"
  fi
else
  warn "Tailscale is not installed" "Install it: curl -fsSL https://tailscale.com/install.sh | sudo sh"
fi

# ---------------------------------------------------------------------------
# 6. Backups
#
# A backup that silently stopped working is one of the most damaging failure
# modes here, precisely because nothing appears wrong until you need it.
# ---------------------------------------------------------------------------
section "Backups"

BACKUP_CONF="${HOME}/.config/hybrid-ai-backup"
if [[ -f "${BACKUP_CONF}/r2.env" && -f "${BACKUP_CONF}/repo-password" ]]; then
  pass "Backup credentials present"

  for f in "${BACKUP_CONF}/r2.env" "${BACKUP_CONF}/repo-password"; do
    P="$(stat -c '%a' "$f" 2>/dev/null)"
    if [[ "$P" == "600" ]]; then
      pass "$(basename "$f") permissions correct"
    else
      fail "$(basename "$f") permissions are ${P}, expected 600" "Fix: chmod 600 ${f}"
    fi
  done

  if command -v systemctl >/dev/null 2>&1; then
    if systemctl --user is-active hybrid-ai-backup.timer >/dev/null 2>&1; then
      NEXT="$(systemctl --user list-timers hybrid-ai-backup.timer --no-pager 2>/dev/null | awk 'NR==2 {print $1, $2}')"
      pass "Nightly backup timer active${NEXT:+ (next: ${NEXT})}"
    else
      fail "Backup timer is not active" \
           "Enable it: systemctl --user enable --now hybrid-ai-backup.timer"
    fi

    # Without linger, user timers do not run when you are logged out -- which
    # means the nightly backup silently never happens.
    if command -v loginctl >/dev/null 2>&1; then
      if loginctl show-user "$USER" 2>/dev/null | grep -q 'Linger=yes'; then
        pass "Linger enabled (backups run while logged out)"
      else
        fail "Linger is NOT enabled - backups will not run when you log out" \
             "Fix: sudo loginctl enable-linger $USER"
      fi
    fi
  fi

  # --- How old is the last successful backup? -------------------------------
  if [[ -f backup.log ]]; then
    LAST="$(grep 'event=backup_success' backup.log 2>/dev/null | tail -1 | grep -o 'ts=[^ ]*' | cut -d= -f2)"
    if [[ -n "$LAST" ]]; then
      LAST_EPOCH="$(date -d "$LAST" +%s 2>/dev/null || echo 0)"
      if (( LAST_EPOCH > 0 )); then
        AGE_H=$(( ( $(date +%s) - LAST_EPOCH ) / 3600 ))
        if (( AGE_H <= 36 )); then
          pass "Last successful backup ${AGE_H}h ago"
        elif (( AGE_H <= 168 )); then
          warn "Last successful backup was ${AGE_H}h ago" \
               "Expected nightly. Check: journalctl --user -u hybrid-ai-backup.service -n 50"
        else
          fail "Last successful backup was ${AGE_H}h ago (over a week)" \
               "Backups are not running. Run ./backup/backup.sh manually to see the error."
        fi
      fi
    else
      warn "No successful backup recorded yet" "Run one now: ./backup/backup.sh"
    fi

    if grep -q 'event=backup_failed\|event=check_failed' backup.log 2>/dev/null; then
      RECENT_FAIL="$(grep -c 'event=backup_failed' backup.log 2>/dev/null || echo 0)"
      warn "${RECENT_FAIL} backup failure(s) recorded in the log" \
           "Review: grep 'event=backup_failed' backup.log | tail -5"
    fi
  fi

  if (( ! NO_CLOUD )); then
    if timeout 30 bash -c '
        set -a; while IFS= read -r l; do
          [[ "$l" =~ ^[[:space:]]*[#] ]] && continue
          [[ "$l" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] && printf -v "${BASH_REMATCH[1]}" "%s" "${BASH_REMATCH[2]}" && export "${BASH_REMATCH[1]}"
        done < "$1"; set +a
        restic snapshots --last >/dev/null 2>&1' _ "${BACKUP_CONF}/r2.env"; then
      pass "Backup repository reachable"
    else
      warn "Could not reach the backup repository" \
           "Check network and R2 credentials: ./backup/backup.sh --dry-run"
    fi
  fi
else
  warn "Backups are not configured" \
       "Set them up by re-running ./install.sh - this is your only protection against a failed disk."
fi

# ---------------------------------------------------------------------------
# 7. Data
# ---------------------------------------------------------------------------
section "Data"

for d in webui_data ollama_data; do
  if [[ -d "$d" ]]; then
    SZ="$(du -sh "$d" 2>/dev/null | cut -f1)"
    pass "${d} present (${SZ})"
  else
    warn "${d} does not exist" "It will be created on the next ./install.sh run."
  fi
done

if [[ -d webui_data ]] && command -v sqlite3 >/dev/null 2>&1; then
  DB="webui_data/webui.db"
  if [[ -f "$DB" ]]; then
    # Read-only integrity check; does not lock out the running application.
    RESULT="$(sqlite3 "file:${DB}?mode=ro" 'PRAGMA quick_check;' 2>/dev/null | head -1)"
    if [[ "$RESULT" == "ok" ]]; then
      pass "webui.db passes a quick integrity check"
    elif [[ -n "$RESULT" ]]; then
      fail "webui.db integrity check returned: ${RESULT}" \
           "Restore from backup: ./backup/restore.sh"
    fi
  fi
fi

# Leftover safety copies from a previous restore waste a lot of space.
LEFTOVER="$(find . -maxdepth 1 -name 'webui_data.pre-restore-*' -o -maxdepth 1 -name '.restore-test-*' 2>/dev/null | wc -l | tr -d ' ')"
if [[ "${LEFTOVER:-0}" -gt 0 ]]; then
  warn "${LEFTOVER} leftover restore director(ies) taking up space" \
       "Remove when you are confident: rm -rf webui_data.pre-restore-* .restore-test-*"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '\n%s\n' "============================================================"
printf '  %s%d passed%s   %s%d warning(s)%s   %s%d failure(s)%s\n' \
  "$C_OK" "$PASS" "$C_RST" "$C_WRN" "$WARN" "$C_RST" "$C_ERR" "$FAIL" "$C_RST"
printf '%s\n' "============================================================"

if (( ${#REMEDIES[@]} > 0 )); then
  printf '\n  %sWhat to do%s\n\n' "$C_HDR" "$C_RST"
  for r in "${REMEDIES[@]}"; do
    printf '  %s\n\n' "$r"
  done
fi

if (( FAIL > 0 )); then
  printf '  %sMore help: docs/TROUBLESHOOTING.md%s\n\n' "$C_DIM" "$C_RST"
  exit 2
elif (( WARN > 0 )); then
  printf '  %sWorking, but see the notes above.%s\n\n' "$C_DIM" "$C_RST"
  exit 1
else
  printf '  %sEverything looks healthy.%s\n\n' "$C_OK" "$C_RST"
  exit 0
fi
```


## File: hermes/Dockerfile
---
Directory: `hermes`
---
```dockerfile
FROM python:3.11-slim

# Install system dependencies
# Add retry flags and quiet output to prevent mirror timeouts
RUN apt-get update -o Acquire::Retries=5 && \
    apt-get install -y --no-install-recommends \
        git \
        curl \
        build-essential \
        libxi6 && \
    rm -rf /var/lib/apt/lists/*

# Install Hermes Agent CLI system-wide
RUN curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash

# Clone and build Hermes WebUI
WORKDIR /app
RUN git clone https://github.com/nesquena/hermes-webui.git .
RUN pip install --no-cache-dir -r requirements.txt

EXPOSE 8501 8642

# Launch gateway daemon in background and WebUI in foreground
CMD ["bash", "-c", "source ~/.bashrc && hermes gateway & python3 bootstrap.py --port 8501 --host 0.0.0.0"]
```


## File: hermes/docker-compose.hermes.yml
---
Directory: `hermes`
---
```yaml
services:
  hermes:
    build:
      context: ./hermes
      dockerfile: Dockerfile
    container_name: hermes-agent
    restart: unless-stopped
    command: ["python3", "bootstrap.py", "--host", "0.0.0.0", "--foreground", "--no-browser", "8501"]
    ports:
      - "${HERMES_PORT:-8501}:8501"
      - "${HERMES_API_PORT:-8642}:8642"
    volumes:
      - ./hermes_data:/root/.hermes
      - ./:/workspace
    environment:
      - OPENROUTER_API_KEY=${OPENROUTER_API_KEY}
      - LOCAL_DOMAIN=${LOCAL_DOMAIN}
      - HERMES_WEBUI_FOREGROUND=1
      - HERMES_WEBUI_HOST=0.0.0.0
      - HERMES_WEBUI_PORT=8501
```


## File: install.sh
---
Directory: `.`
---
```bash
#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: install.sh
# PURPOSE (plain English):
#   This is the one script you run on the Raspberry Pi to set everything up.
#   You can run it as many times as you like -- it is "idempotent", meaning
#   running it twice does the same thing as running it once[cite: 1]. Nothing breaks and
#   no data is lost. The CI/CD pipeline runs it on every deploy for that reason.
#
# WHAT IT DOES, IN ORDER:
#   1. Checks that required programs (docker, git, jq, curl, openssl, sqlite3,
#      rsync, tailscale) are installed, and stops with instructions if any are
#      missing.
#   2. Loads your existing .env file, if there is one, so it only asks you for
#      things it does not already know. It evaluates the version to determine
#      if the structure needs to be upgraded.
#   3. Reads your Pi's RAM and works out a safe memory budget for Ollama.
#   4. Generates a login-session encryption key, but only the first time.
#   5. Prompts you for your local domain, OpenRouter key, and RunPod credentials.
#   6. Asks Tailscale for the network address of your cloud GPU pod.
#   7. Creates the data folders if they do not exist (never overwrites them).
#   8. Writes the .env file with locked-down permissions.
#   9. Starts the core stack, OpenHands, Hermes Agent, and status reverse proxy.
#  10. Verifies local DNS resolution for your subdomains and gives exact Pi-hole rules.
#
# HOW TO RUN IT:
#   ./install.sh                   normal, interactive -- asks for anything missing
#   ./install.sh --non-interactive  never prompts; fails instead. Used by CI.
#   ./install.sh --no-start          write .env but do not touch Docker
#   ./install.sh --help              show this usage summary
# ---------------------------------------------------------------------------

# "set -Eeuo pipefail" makes bash strict and safe:
#   -e  stop immediately if any command fails
#   -u  stop if an undefined variable is used (catches typos)
#   -o pipefail  a failure anywhere in a pipeline fails the whole pipeline
#   -E  make sure our error trap works inside functions
set -Eeuo pipefail

# Work from the folder this script lives in, no matter where it was called from.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ENV_FILE="${SCRIPT_DIR}/.env"
TARGET_ENV_VERSION="2"

# Peer hostnames to search for, in priority order.
PEER_HOSTNAMES="${PEER_HOSTNAMES:-runpod-worker runpod-vllm}"
PEER_HOSTNAME="${PEER_HOSTNAME:-${PEER_HOSTNAMES%% *}}"
NON_INTERACTIVE=0
NO_START=0

for arg in "$@"; do
  case "$arg" in
    --non-interactive) NON_INTERACTIVE=1 ;;
    --no-start)         NO_START=1 ;;
    -h|--help)
      sed -n '2,31p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

# --- Output helpers --------------------------------------------------------
if [[ -t 1 ]]; then
  C_RST=$'\033[0m'; C_INF=$'\033[36m'; C_OK=$'\033[32m'
  C_WRN=$'\033[33m'; C_ERR=$'\033[31m'; C_DIM=$'\033[2m'
else
  C_RST=""; C_INF=""; C_OK=""; C_WRN=""; C_ERR=""; C_DIM=""
fi
log()  { printf '%s[ * ]%s %s\n'  "$C_INF" "$C_RST" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_OK"  "$C_RST" "$*"; }
warn() { printf '%s[ ! ]%s %s\n'  "$C_WRN" "$C_RST" "$*" >&2; }
die()  { printf '%s[ X ]%s %s\n'  "$C_ERR" "$C_RST" "$*" >&2; exit 1; }
hr()   { printf '%s%s%s\n' "$C_DIM" "------------------------------------------------------------" "$C_RST"; }

INSTALL_LOG="${SCRIPT_DIR}/install.log"
event() {
  local name="$1"; shift
  printf 'EVENT ts=%s event=%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$name" "$*" \
    >> "$INSTALL_LOG" 2>/dev/null || true
}
touch "$INSTALL_LOG" 2>/dev/null && chmod 600 "$INSTALL_LOG" 2>/dev/null || true
event "install_start" "args=$*" "user=${USER:-unknown}"

trap 'event "install_aborted" "line=${LINENO}"; die "Failed at line ${LINENO}: ${BASH_COMMAND}"' ERR

hr
printf '  hybrid-ai :: local control plane bootstrap\n'
hr

# ---------------------------------------------------------------------------
# STEP 1. Dependency probe
# ---------------------------------------------------------------------------
log "Probing host dependencies..."

MISSING=()
for bin in docker git jq curl openssl sqlite3 rsync; do
  command -v "$bin" >/dev/null 2>&1 || MISSING+=("$bin")
done
command -v tailscale >/dev/null 2>&1 || MISSING+=("tailscale")

if ((${#MISSING[@]} > 0)); then
  warn "Missing required binaries: ${MISSING[*]}"
  cat <<'EOF'

  Install them first. On Raspberry Pi OS / Debian / Ubuntu:

    sudo apt-get update
    sudo apt-get install -y git jq curl openssl sqlite3 rsync restic
    curl -fsSL https://get.docker.com | sudo sh
    curl -fsSL https://tailscale.com/install.sh | sudo sh
    sudo usermod -aG docker "$USER"   # then log out and back in

EOF
  die "Dependency check failed."
fi

if ! docker compose version >/dev/null 2>&1; then
  die "'docker compose' (v2 plugin) not available. Install docker-compose-plugin."
fi

if ! docker info >/dev/null 2>&1; then
  die "Cannot talk to the Docker daemon. Is it running, and is $USER in the 'docker' group?"
fi

ok "docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?')"
ok "compose $(docker compose version --short 2>/dev/null || echo '?')"
ok "jq $(jq --version 2>/dev/null)"
ok "sqlite3 $(sqlite3 --version 2>/dev/null | awk '{print $1}')"
ok "tailscale $(tailscale version 2>/dev/null | head -n1 || echo '?')"

# --- Make our own helper scripts executable --------------------------------
for _s in scripts/setup-agent-workspace.sh openhands/scripts/openhands-control.sh \
          doctor.sh collect-diagnostics.sh backup/backup.sh backup/restore.sh \
          runpod/start.sh; do
  _f="${SCRIPT_DIR}/${_s}"
  [[ -f "$_f" ]] || continue
  if [[ ! -x "$_f" ]]; then
    chmod +x "$_f" 2>/dev/null \
      && ok "Made ${_s} executable." \
      || warn "Could not chmod +x ${_s}. Run it manually: chmod +x ${_s}"
  fi
done
unset _s _f

# ---------------------------------------------------------------------------
# STEP 2. Load existing .env
# ---------------------------------------------------------------------------
if [[ -f "$ENV_FILE" ]]; then
  log "Existing .env found -- preserving current values."

  while IFS= read -r _line || [[ -n "$_line" ]]; do
    [[ "$_line" =~ ^[[:space:]]*# ]] && continue
    [[ "$_line" =~ ^[[:space:]]*$ ]] && continue
    if [[ "$_line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      _k="${BASH_REMATCH[1]}"
      _v="${BASH_REMATCH[2]}"
      _v="${_v%\"}"; _v="${_v#\"}"
      _v="${_v%\'}"; _v="${_v#\'}"
      printf -v "$_k" '%s' "$_v"
      export "${_k?}"
    else
      warn "Ignoring malformed line in .env: ${_line:0:40}"
    fi
  done < "$ENV_FILE"
  unset _line _k _v

  CURRENT_ENV_VERSION="${ENV_VERSION:-0}"
  if [[ "$CURRENT_ENV_VERSION" != "$TARGET_ENV_VERSION" ]]; then
    log "Upgrading .env format (v${CURRENT_ENV_VERSION} -> v${TARGET_ENV_VERSION})..."
  else
    log ".env is up to date (v${TARGET_ENV_VERSION})."
  fi
else
  log "No .env present -- generating from scratch (v${TARGET_ENV_VERSION})."
fi

# ---------------------------------------------------------------------------
# STEP 3. Work out memory budget
# ---------------------------------------------------------------------------
log "Calculating resource allocation..."

TOTAL_KB="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
TOTAL_MB=$(( TOTAL_KB / 1024 ))
CPU_CORES="$(nproc 2>/dev/null || echo 1)"
ARCH="$(uname -m)"

if (( TOTAL_MB <= 0 )); then
  warn "Could not read /proc/meminfo; assuming 4 GB."
  TOTAL_MB=4096
fi

if   (( TOTAL_MB <= 2048 )); then OLLAMA_MEM_LIMIT_MB=$(( TOTAL_MB - 768 ))
elif (( TOTAL_MB <= 4096 )); then OLLAMA_MEM_LIMIT_MB=$(( TOTAL_MB * 60 / 100 ))
elif (( TOTAL_MB <= 8192 )); then OLLAMA_MEM_LIMIT_MB=$(( TOTAL_MB * 65 / 100 ))
else                              OLLAMA_MEM_LIMIT_MB=$(( TOTAL_MB - 5120 ))
fi
(( OLLAMA_MEM_LIMIT_MB < 1024 )) && OLLAMA_MEM_LIMIT_MB=1024
OLLAMA_MEM_LIMIT="${OLLAMA_MEM_LIMIT_MB}m"

if   (( TOTAL_MB <= 4096 )); then WEBUI_MEM_LIMIT="1024m"
elif (( TOTAL_MB <= 8192 )); then WEBUI_MEM_LIMIT="2048m"
else                              WEBUI_MEM_LIMIT="3072m"
fi

if   (( TOTAL_MB <= 4096 )); then OLLAMA_CONTEXT_LENGTH="${OLLAMA_CONTEXT_LENGTH:-4096}"
elif (( TOTAL_MB <= 8192 )); then OLLAMA_CONTEXT_LENGTH="${OLLAMA_CONTEXT_LENGTH:-8192}"
else                              OLLAMA_CONTEXT_LENGTH="${OLLAMA_CONTEXT_LENGTH:-16384}"
fi

OLLAMA_NUM_PARALLEL="${OLLAMA_NUM_PARALLEL:-1}"
OLLAMA_MAX_LOADED_MODELS="${OLLAMA_MAX_LOADED_MODELS:-1}"

if (( TOTAL_MB >= 15000 )); then
  OLLAMA_KEEP_ALIVE="${OLLAMA_KEEP_ALIVE:-30m}"
elif (( TOTAL_MB >= 7000 )); then
  OLLAMA_KEEP_ALIVE="${OLLAMA_KEEP_ALIVE:-15m}"
else
  OLLAMA_KEEP_ALIVE="${OLLAMA_KEEP_ALIVE:-5m}"
fi

OLLAMA_FLASH_ATTENTION="${OLLAMA_FLASH_ATTENTION:-1}"
OLLAMA_KV_CACHE_TYPE="${OLLAMA_KV_CACHE_TYPE:-f16}"

if (( CPU_CORES >= 4 )); then
  OLLAMA_CPUS="${OLLAMA_CPUS:-$(awk "BEGIN{printf \"%.1f\", ${CPU_CORES} - 0.5}")}"
  WEBUI_CPUS="${WEBUI_CPUS:-2.0}"
elif (( CPU_CORES >= 2 )); then
  OLLAMA_CPUS="${OLLAMA_CPUS:-$(awk "BEGIN{printf \"%.1f\", ${CPU_CORES} - 0.5}")}"
  WEBUI_CPUS="${WEBUI_CPUS:-1.0}"
else
  OLLAMA_CPUS="${OLLAMA_CPUS:-1.0}"
  WEBUI_CPUS="${WEBUI_CPUS:-1.0}"
fi

ok "host: ${ARCH}, ${CPU_CORES} cores, ${TOTAL_MB} MiB RAM"
ok "ollama: limit ${OLLAMA_MEM_LIMIT}, context ${OLLAMA_CONTEXT_LENGTH}, keep-alive ${OLLAMA_KEEP_ALIVE}"
ok "cpu shares: ollama ${OLLAMA_CPUS}, open-webui ${WEBUI_CPUS}"
ok "open-webui: limit ${WEBUI_MEM_LIMIT}"

# --- Storage check ---------------------------------------------------------
ROOT_SRC="$(findmnt -n -o SOURCE / 2>/dev/null || echo '')"
case "$ROOT_SRC" in
  *mmcblk*)
    if lsblk -dno NAME 2>/dev/null | grep -q '^nvme'; then
      warn "An NVMe drive is installed, but this Pi booted from the SD card."
      warn "Everything will run at SD speed while the SSD sits idle."
      warn "Fix: sudo raspi-config -> Advanced Options -> Boot Order -> NVMe/USB"
      event "storage_warning" "type=nvme_present_but_sd_boot"
    else
      warn "Running from an SD card."
      warn "Model loads will be several times slower than NVMe, and sustained"
      warn "vector-database writes wear SD cards out within months."
      warn "NVMe via the PCIe HAT is the recommended storage for this build."
      event "storage_warning" "type=sdcard"
    fi
    ;;
  *nvme*)
    ok "Running from NVMe — recommended configuration."
    event "storage_ok" "type=nvme"
    ;;
esac

# ---------------------------------------------------------------------------
# STEP 3b. Identity for the status container
# ---------------------------------------------------------------------------
STATUS_UID="$(id -u)"
if [[ -S /var/run/docker.sock ]]; then
  DOCKER_GID="$(stat -c '%g' /var/run/docker.sock 2>/dev/null || echo 999)"
else
  DOCKER_GID="$(getent group docker 2>/dev/null | cut -d: -f3 || echo 999)"
  DOCKER_GID="${DOCKER_GID:-999}"
fi
ok "status page identity: uid=${STATUS_UID} docker gid=${DOCKER_GID}"

# ---------------------------------------------------------------------------
# STEP 4. Session encryption key
# ---------------------------------------------------------------------------
if [[ -z "${WEBUI_SECRET_KEY:-}" ]]; then
  WEBUI_SECRET_KEY="$(openssl rand -hex 32)"
  ok "Generated new WEBUI_SECRET_KEY."
else
  ok "Reusing existing WEBUI_SECRET_KEY (sessions preserved)."
fi

# ---------------------------------------------------------------------------
# STEP 5. Credential and local domain prompts
# ---------------------------------------------------------------------------
prompt_secret() {
  local __var="$1" __label="$2" __silent="${3:-0}" __val=""
  if [[ -n "${!__var:-}" ]]; then
    ok "${__label}: already set."
    return 0
  fi
  if (( NON_INTERACTIVE )); then
    die "${__label} (${__var}) missing and --non-interactive was requested."
  fi
  while [[ -z "$__val" ]]; do
    if (( __silent )); then
      read -r -s -p "    Enter ${__label}: " __val < /dev/tty; echo
    else
      read -r -p "    Enter ${__label}: " __val < /dev/tty
    fi
    [[ -z "$__val" ]] && warn "Value cannot be empty."
  done
  printf -v "$__var" '%s' "$__val"
}

log "Configuring local network and API credentials..."
prompt_secret LOCAL_DOMAIN       "Local DNS Domain Name (e.g. yourhostname.com)" 0
prompt_secret OPENROUTER_API_KEY "OpenRouter API key" 1
prompt_secret RUNPOD_API_KEY     "RunPod API key" 1
prompt_secret RUNPOD_POD_ID      "RunPod pod ID"  0
prompt_secret RUNPOD_HOST        "RunPod MagicDNS (e.g., runpod-worker.tailXXXX.ts.net)" 0
prompt_secret PI_HOST            "Raspberry Pi MagicDNS (e.g., jarvis.tailXXXX.ts.net)" 0

# ---------------------------------------------------------------------------
# STEP 6. Find the GPU pod on the Tailscale network
# ---------------------------------------------------------------------------
log "Querying Tailscale mesh for peer '${PEER_HOSTNAME}'..."

TS_JSON=""
DISCOVERED_IP=""
PEER_ONLINE="false"
MATCHED_PEER=""

query_tailnet() {
    if TS_JSON="$(tailscale status --json 2>/dev/null)"; then
        BACKEND_STATE="$(printf '%s' "$TS_JSON" | jq -r '.BackendState // "Unknown"')"
        SELF_IP="$(printf '%s' "$TS_JSON" | jq -r '.Self.TailscaleIPs[]? | select(test("^100\\."))' | head -n1)"

        if [[ "$BACKEND_STATE" != "Running" ]]; then
            warn "Tailscale backend state is '${BACKEND_STATE}' (expected 'Running'). Run: sudo tailscale up"
        else
            ok "tailnet up; this node = ${SELF_IP:-unknown}"
        fi

        for _peer in $PEER_HOSTNAMES; do
            _ip="$(
                printf '%s' "$TS_JSON" | jq -r --arg peer "$_peer" '
                    (.Peer // {})
                    | to_entries
                    | map(.value)
                    | map(select(
                        ((.HostName // "") | ascii_downcase | contains($peer | ascii_downcase))
                        or ((.DNSName // "") | ascii_downcase | startswith(($peer | ascii_downcase) + "."))
                      ))
                    | sort_by((.Online // false) | not)
                    | .[0].TailscaleIPs[]? // empty
                  ' | grep -E '^100\.' | head -n1 || true
            )"

            [[ -z "$_ip" ]] && continue

            DISCOVERED_IP="$_ip"
            MATCHED_PEER="$_peer"
            PEER_ONLINE="$(
                printf '%s' "$TS_JSON" | jq -r --arg peer "$_peer" '
                    (.Peer // {}) | to_entries | map(.value)
                    | map(select(((.HostName // "") | ascii_downcase | contains($peer | ascii_downcase))))
                    | .[0].Online // false
                  ' 2>/dev/null || echo false
            )"
            break
        done
        unset _peer _ip
    else
        warn "'tailscale status --json' failed. Is tailscaled running?"
    fi
}

query_tailnet

if [[ "$PEER_ONLINE" != "true" ]]; then
    if [[ -n "${RUNPOD_API_KEY:-}" && -n "${RUNPOD_POD_ID:-}" ]]; then
        warn "Peer '${PEER_HOSTNAME}' is offline or missing. Checking RunPod status..."
        
        RUNPOD_STATUS=$(curl -s -X POST \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer ${RUNPOD_API_KEY}" \
            -d "{\"query\": \"query { pod(input: {podId: \\\"${RUNPOD_POD_ID}\\\"}) { id desiredStatus } }\"}" \
            https://api.runpod.io/graphql | jq -r '.data.pod.desiredStatus // "STOPPED"')

        if [ "$RUNPOD_STATUS" != "RUNNING" ]; then
            warn "RunPod worker is stopped. Sending start command for pod ${RUNPOD_POD_ID}..."
            curl -s -X POST \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer ${RUNPOD_API_KEY}" \
                -d "{\"query\": \"mutation { podResume(input: {podId: \\\"${RUNPOD_POD_ID}\\\"}) { id desiredStatus } }\"}" \
                https://api.runpod.io/graphql > /dev/null
        fi

        log "Waiting for worker to boot and join tailnet (up to 3 minutes)..."
        RETRIES=18
        WAIT_TIME=10
        
        for ((i=1; i<=RETRIES; i++)); do
            sleep $WAIT_TIME
            query_tailnet
            if [[ "$PEER_ONLINE" == "true" ]]; then
                ok "Peer '${MATCHED_PEER}' came online at ${DISCOVERED_IP}"
                break
            else
                warn "Still waiting for 'runpod-worker' to register (Attempt $i of $RETRIES)..."
            fi
        done
    else
        warn "RUNPOD_API_KEY or RUNPOD_POD_ID not set in .env; skipping auto-wake."
    fi
fi

if [[ -n "${DISCOVERED_IP:-}" ]]; then
    TAILSCALE_IP="$DISCOVERED_IP"
    if [[ "$PEER_ONLINE" == "true" ]]; then
        ok "Peer '${MATCHED_PEER}' online at ${TAILSCALE_IP}"
    else
        ok "Peer '${MATCHED_PEER}' known at ${TAILSCALE_IP} (offline — worker did not respond to wake)"
    fi
elif [[ -n "${TAILSCALE_IP:-}" ]]; then
    warn "No peer (${PEER_HOSTNAMES}) in tailnet right now; keeping cached ${TAILSCALE_IP}"
else
    warn "No peer found (tried: ${PEER_HOSTNAMES}) and no cached address."
    if (( NON_INTERACTIVE )); then
        TAILSCALE_IP=""
    else
        read -r -p "    Enter the pod's Tailscale IP (or leave blank to fill in later): " TAILSCALE_IP < /dev/tty
    fi
fi

if [[ -n "${TAILSCALE_IP:-}" && ! "$TAILSCALE_IP" =~ ^100\.([0-9]{1,3}\.){2}[0-9]{1,3}$ ]]; then
    warn "'${TAILSCALE_IP}' does not look like a 100.x.x.x mesh address."
fi

# ---------------------------------------------------------------------------
# STEP 7. Data folders
# ---------------------------------------------------------------------------
log "Ensuring persistent host mounts..."

for f in backup.log install.log; do
  [[ -e "$f" ]] || { : > "$f"; chmod 600 "$f"; }
  if [[ -d "$f" ]]; then
    warn "${f} is a directory (created by an earlier Docker run). Replacing it."
    rmdir "$f" 2>/dev/null && : > "$f" && chmod 600 "$f"
  fi
done

mkdir -p webui_data/caddy
mkdir -p hermes_data

mkdir -p "${HOME}/.openhands"
chmod 700 "${HOME}/.openhands"

mkdir -p "${HOME}/.cache/restic"

for d in ollama_data webui_data hermes_data; do
  if [[ -d "$d" ]]; then
    ok "./${d} exists ($(du -sh "$d" 2>/dev/null | cut -f1 || echo '0') on disk) -- untouched."
  else
    mkdir -p "$d"
    ok "./${d} created."
  fi
done

# ---------------------------------------------------------------------------
# STEP 8. Write .env
# ---------------------------------------------------------------------------
log "Writing ${ENV_FILE} ..."

TMP_ENV="$(mktemp "${SCRIPT_DIR}/.env.XXXXXX")"
chmod 600 "$TMP_ENV"

cat > "$TMP_ENV" <<EOF
# ---------------------------------------------------------------------------
# GENERATED BY install.sh -- $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Contains live credentials. Never commit. Mode 0600.
# Re-run ./install.sh to regenerate; your values are preserved.
# ---------------------------------------------------------------------------
ENV_VERSION=${TARGET_ENV_VERSION}

# --- Local control plane & reverse proxy -----------------------------------
LOCAL_DOMAIN=${LOCAL_DOMAIN}

OLLAMA_MEM_LIMIT=${OLLAMA_MEM_LIMIT}
WEBUI_MEM_LIMIT=${WEBUI_MEM_LIMIT}
OLLAMA_CPUS=${OLLAMA_CPUS}
WEBUI_CPUS=${WEBUI_CPUS}
OLLAMA_CONTEXT_LENGTH=${OLLAMA_CONTEXT_LENGTH}
OLLAMA_NUM_PARALLEL=${OLLAMA_NUM_PARALLEL}
OLLAMA_MAX_LOADED_MODELS=${OLLAMA_MAX_LOADED_MODELS}
OLLAMA_KEEP_ALIVE=${OLLAMA_KEEP_ALIVE}
OLLAMA_FLASH_ATTENTION=${OLLAMA_FLASH_ATTENTION}
OLLAMA_KV_CACHE_TYPE=${OLLAMA_KV_CACHE_TYPE}

# --- Container image pins --------------------------------------------------
OLLAMA_IMAGE=${OLLAMA_IMAGE:-ollama/ollama:0.34.4}
WEBUI_IMAGE=${WEBUI_IMAGE:-ghcr.io/open-webui/open-webui:v0.11.4}

# --- Status page identity --------------------------------------------------
STATUS_UID=${STATUS_UID}
DOCKER_GID=${DOCKER_GID}

# --- Open WebUI ------------------------------------------------------------
WEBUI_SECRET_KEY=${WEBUI_SECRET_KEY}
WEBUI_AUTH=${WEBUI_AUTH:-true}
RAG_EMBEDDING_MODEL=${RAG_EMBEDDING_MODEL:-sentence-transformers/all-MiniLM-L6-v2}
ENABLE_OPENAI_API=${ENABLE_OPENAI_API:-false}

# --- OpenRouter API --------------------------------------------------------
OPENROUTER_API_KEY=${OPENROUTER_API_KEY:-}
OPENROUTER_MODEL=${OPENROUTER_MODEL:-qwen/qwen-2.5-coder-32b-instruct}

# --- Cloud inference plane -------------------------------------------------
RUNPOD_HOST=${RUNPOD_HOST}
PI_HOST=${PI_HOST}
TAILSCALE_IP=${TAILSCALE_IP:-}
PEER_HOSTNAME=${PEER_HOSTNAME}
PEER_HOSTNAMES=${PEER_HOSTNAMES}
RUNPOD_API_KEY=${RUNPOD_API_KEY}
RUNPOD_POD_ID=${RUNPOD_POD_ID}
VLLM_PORT=${VLLM_PORT:-8000}
VLLM_MODEL_NAME=${VLLM_MODEL_NAME:-Qwen/Qwen2.5-Coder-32B-Instruct-AWQ}
POD_WARMUP_TIMEOUT=${POD_WARMUP_TIMEOUT:-600} 
VLLM_DISPLAY_NAME=${VLLM_DISPLAY_NAME:-Qwen2.5-Coder-32B (RunPod)} 
VLLM_REQUEST_TIMEOUT=${VLLM_REQUEST_TIMEOUT:-900} 
VLLM_MAX_TOKENS=${VLLM_MAX_TOKENS:-4096} 
PIPE_LOG_LEVEL=${PIPE_LOG_LEVEL:-INFO}

# --- Hermes Agent system orchestrator -------------------------------------
HERMES_PORT=${HERMES_PORT:-8501}
HERMES_API_PORT=${HERMES_API_PORT:-8642}
HERMES_MEM_LIMIT=${HERMES_MEM_LIMIT:-2048m}
HERMES_CPUS=${HERMES_CPUS:-1.5}

# --- OpenHands maintenance agent -------------------------------------------
OPENHANDS_PORT=${OPENHANDS_PORT:-3001}
OPENHANDS_WORKSPACE=${OPENHANDS_WORKSPACE:-${HOME}/hybrid-ai-agent}
OPENHANDS_STATE_DIR=${OPENHANDS_STATE_DIR:-${HOME}/.openhands}
OPENHANDS_IMAGE=${OPENHANDS_IMAGE:-docker.openhands.dev/openhands/openhands:1.8}
OPENHANDS_AGENT_IMAGE_REPOSITORY=${OPENHANDS_AGENT_IMAGE_REPOSITORY:-ghcr.io/openhands/agent-server}
OPENHANDS_AGENT_IMAGE_TAG=${OPENHANDS_AGENT_IMAGE_TAG:-1.26.0-python}
OPENHANDS_LOG_ALL_EVENTS=${OPENHANDS_LOG_ALL_EVENTS:-false}
OPENHANDS_MEM_LIMIT=${OPENHANDS_MEM_LIMIT:-2g}
OPENHANDS_CPUS=${OPENHANDS_CPUS:-1.5}

# --- Zero-trace ------------------------------------------------------------
SCARF_NO_ANALYTICS=true
DO_NOT_TRACK=true
ANONYMIZED_TELEMETRY=false
EOF

mv -f "$TMP_ENV" "$ENV_FILE"
chmod 600 "$ENV_FILE"
ok ".env written (0600)."

# ---------------------------------------------------------------------------
# STEP 9. Launch
# ---------------------------------------------------------------------------
hr
log "Preparing the OpenHands workspace..."
if (( NON_INTERACTIVE )); then
  "${SCRIPT_DIR}/scripts/setup-agent-workspace.sh" --non-interactive \
    || warn "Agent workspace setup failed; OpenHands will not start until it exists."
else
  "${SCRIPT_DIR}/scripts/setup-agent-workspace.sh" \
    || warn "Agent workspace setup failed; OpenHands will not start until it exists."
fi

if (( NO_START )); then
  hr; ok "--no-start requested. Environment prepared; Docker untouched."; hr
  exit 0
fi

COMPOSE=(
  docker compose
  --env-file "$ENV_FILE"
  -f docker-compose.yml
  -f openhands/docker-compose.openhands.yml
  -f hermes/docker-compose.hermes.yml
)

export COMPOSE_HTTP_TIMEOUT=600
export DOCKER_CLIENT_TIMEOUT=600

log "Pulling container images..."
MAX_RETRIES=5
ATTEMPT=1

while [ $ATTEMPT -le $MAX_RETRIES ]; do
    if "${COMPOSE[@]}" pull; then
        log "All images pulled successfully."
        break
    else
        warn "Pull timed out or failed (Attempt $ATTEMPT of $MAX_RETRIES). Retrying in 10 seconds..."
        sleep 10
        ATTEMPT=$((ATTEMPT + 1))
    fi
done

if [ $ATTEMPT -gt $MAX_RETRIES ]; then
    die "Failed to pull images after $MAX_RETRIES attempts. Please check network routing."
fi

log "Starting full Hybrid-AI control plane stack..."
if ! "${COMPOSE[@]}" up -d --build --remove-orphans; then
  event "stack_start_failed"
  warn "docker compose up failed. Recent logs:"
  "${COMPOSE[@]}" logs --tail 40 2>/dev/null || true
  die "Control plane did not start."
fi
event "stack_started"

# ---------------------------------------------------------------------------
# STEP 10. Verify service health and check local DNS resolution
# ---------------------------------------------------------------------------
log "Verifying service health..."

wait_for() {
  local label="$1" url="$2" max="$3" waited=0
  while (( waited < max )); do
    if curl -fsS --max-time 5 "$url" >/dev/null 2>&1; then
      ok "${label} healthy after ${waited}s."
      event "healthcheck_pass" "service=${label}" "seconds=${waited}"
      return 0
    fi
    sleep 5
    waited=$(( waited + 5 ))
    printf '\r    waiting for %s... %ds' "$label" "$waited"
  done
  printf '\n'
  warn "${label} did not become healthy within ${max}s."
  event "healthcheck_fail" "service=${label}" "seconds=${max}"
  return 1
}

HEALTH_FAILED=0
wait_for "ollama"       "http://127.0.0.1:11434/api/tags" 60  || HEALTH_FAILED=1

if EFFECTIVE_CTX="$(docker exec ollama sh -c 'printf "%s" "${OLLAMA_CONTEXT_LENGTH:-}"' 2>/dev/null)"; then
  if [[ "$EFFECTIVE_CTX" != "$OLLAMA_CONTEXT_LENGTH" ]]; then
    warn "Ollama did not receive OLLAMA_CONTEXT_LENGTH. Context will be 4096."
    event "context_length_not_applied" "requested=${OLLAMA_CONTEXT_LENGTH}"
  elif docker exec ollama ollama --version 2>/dev/null | grep -qE '\b0\.([0-9]|1[01])\.'; then
    warn "Ollama ${OLLAMA_IMAGE:-pinned} predates OLLAMA_CONTEXT_LENGTH support."
    warn "The variable is set but ignored; every model runs at 4096 tokens."
    warn "Fix: set OLLAMA_IMAGE to a current release in .env and re-run ./install.sh"
    event "context_length_unsupported" "requested=${OLLAMA_CONTEXT_LENGTH}"
  else
    ok "Context length ${OLLAMA_CONTEXT_LENGTH} applied."
  fi
fi

wait_for "open-webui"   "http://127.0.0.1:3000/health"    600 || HEALTH_FAILED=1
wait_for "hermes-agent" "http://127.0.0.1:${HERMES_PORT:-8501}" 120 || warn "Hermes WebUI initializing..."
wait_for "openhands"    "http://127.0.0.1:${OPENHANDS_PORT:-3001}" 240 || warn "OpenHands initializing..."
wait_for "status page"  "http://127.0.0.1:80/status/healthz" 60 || warn "Status reverse proxy initializing..."

hr
"${COMPOSE[@]}" ps
hr

if (( HEALTH_FAILED )); then
  event "install_failed" "reason=healthcheck"
  warn "One or more core services are unhealthy. Diagnostic logs below."
  hr
  "${COMPOSE[@]}" logs --tail 40 2>/dev/null || true
  hr
  warn "The stack is running but not serving."
  warn "Run ./doctor.sh for a full diagnosis, or see docs/TROUBLESHOOTING.md"
  exit 1
fi

# --- Verify local DNS subdomains -------------------------------------------
PI_LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
DOMAINS_TO_CHECK=(
  "$LOCAL_DOMAIN"
  "hermes.$LOCAL_DOMAIN"
  "status.$LOCAL_DOMAIN"
)
MISSING_DNS=()

log "Verifying local DNS resolution for ${LOCAL_DOMAIN} subdomains..."
for domain in "${DOMAINS_TO_CHECK[@]}"; do
  if ! getent hosts "$domain" >/dev/null 2>&1; then
    MISSING_DNS+=("$domain")
  fi
done

# ---------------------------------------------------------------------------
# STEP 11. Encrypted offsite backups (Cloudflare R2 via restic)
# ---------------------------------------------------------------------------
BACKUP_CONF_DIR="${HOME}/.config/hybrid-ai-backup"
R2_ENV_FILE="${BACKUP_CONF_DIR}/r2.env"
RESTIC_PW_FILE="${BACKUP_CONF_DIR}/repo-password"
BACKUP_UNITS=(
  hybrid-ai-backup.service
  hybrid-ai-backup.timer
  hybrid-ai-check.service
  hybrid-ai-check.timer
)

install_backup_scheduler() {
  local unit_dir="${HOME}/.config/systemd/user"
  local unit source_file target_file
  local install_failed=0

  if ! command -v systemctl >/dev/null 2>&1; then
    warn "systemctl is unavailable. Schedule backup/backup.sh manually."
    event "backup_schedule_missing" "reason=systemctl_missing"
    return 1
  fi

  mkdir -p "$unit_dir"
  chmod 700 "${HOME}/.config" 2>/dev/null || true
  chmod 700 "${HOME}/.config/systemd" 2>/dev/null || true
  chmod 700 "$unit_dir" 2>/dev/null || true

  log "Installing backup systemd user units..."
  for unit in "${BACKUP_UNITS[@]}"; do
    source_file="${SCRIPT_DIR}/backup/${unit}"
    target_file="${unit_dir}/${unit}"

    if [[ ! -f "$source_file" ]]; then
      warn "Missing backup unit template: ${source_file}"
      event "backup_unit_install_failed" "unit=${unit}" "reason=template_missing"
      install_failed=1
      continue
    fi

    if ! sed "s|__REPO_DIR__|${SCRIPT_DIR}|g" "$source_file" > "${target_file}.tmp"; then
      warn "Could not render ${unit}."
      rm -f "${target_file}.tmp"
      event "backup_unit_install_failed" "unit=${unit}" "reason=render_failed"
      install_failed=1
      continue
    fi

    chmod 0644 "${target_file}.tmp"
    mv -f "${target_file}.tmp" "$target_file"
  done

  if (( install_failed )); then
    warn "One or more backup units could not be installed."
    return 1
  fi

  if ! systemctl --user daemon-reload; then
    warn "systemd user daemon reload failed."
    event "backup_schedule_failed" "reason=daemon_reload"
    return 1
  fi

  for unit in "${BACKUP_UNITS[@]}"; do
    if systemctl --user cat "$unit" >/dev/null 2>&1; then
      ok "${unit} installed."
    else
      warn "${unit} is not visible to the systemd user manager."
      event "backup_unit_install_failed" "unit=${unit}" "reason=not_loaded"
      install_failed=1
    fi
  done

  if (( install_failed )); then
    return 1
  fi

  if systemctl --user enable --now hybrid-ai-backup.timer >/dev/null 2>&1; then
    ok "Backup timer enabled and active."
  else
    warn "Backup timer could not be enabled or started."
    event "backup_timer_failed"
    return 1
  fi

  if systemctl --user enable --now hybrid-ai-check.timer >/dev/null 2>&1; then
    ok "Integrity-check timer enabled and active."
  else
    warn "Integrity-check timer could not be enabled or started."
    event "check_timer_failed"
    return 1
  fi

  if ! systemctl --user is-enabled hybrid-ai-backup.timer >/dev/null 2>&1 ||
     ! systemctl --user is-active hybrid-ai-backup.timer >/dev/null 2>&1; then
    warn "Backup timer verification failed."
    event "backup_timer_verification_failed"
    return 1
  fi

  if ! systemctl --user is-enabled hybrid-ai-check.timer >/dev/null 2>&1 ||
     ! systemctl --user is-active hybrid-ai-check.timer >/dev/null 2>&1; then
    warn "Integrity-check timer verification failed."
    event "check_timer_verification_failed"
    return 1
  fi

  # Linger requires root. Do not invoke sudo from this installer because that
  # would make non-interactive deployments dependent on sudo policy.
  if command -v loginctl >/dev/null 2>&1; then
    if loginctl show-user "$USER" 2>/dev/null | grep -q '^Linger=yes$'; then
      ok "Linger enabled; user timers continue after logout and across boot."
    else
      warn "Linger is disabled; user timers may stop when no user session exists."
      warn "Optional for unattended operation: sudo loginctl enable-linger ${USER}"
      event "backup_linger_disabled" "user=${USER}"
    fi
  fi

  event "backup_schedule_installed" "units=${#BACKUP_UNITS[@]}"
  return 0
}

setup_backups() {
  local backups_configured=0
  local newly_configured=0
  local cf_account="" cf_bucket="" cf_key_id="" cf_secret=""
  local tmp_env="" pw1="" pw2="" _ans="" _gen="" _first=""

  if ! command -v restic >/dev/null 2>&1; then
    warn "restic is not installed. Backups cannot be configured."
    printf '    Install it with: sudo apt-get install -y restic\n'
    event "backup_setup_skipped" "reason=restic_missing"
    return 1
  fi

  if ! bash -n "${SCRIPT_DIR}/backup/backup.sh"; then
    warn "backup/backup.sh has a syntax error. Backup scheduling was not changed."
    event "backup_setup_failed" "reason=backup_script_syntax"
    return 1
  fi

  if [[ -f "$R2_ENV_FILE" && -f "$RESTIC_PW_FILE" ]]; then
    backups_configured=1
    ok "Backup credentials already configured (${BACKUP_CONF_DIR})."
  elif [[ -f "$R2_ENV_FILE" || -f "$RESTIC_PW_FILE" ]]; then
    warn "Backup configuration is incomplete. Both r2.env and repo-password are required."
    event "backup_setup_incomplete"
  fi

  if (( ! backups_configured )); then
    if (( NON_INTERACTIVE )); then
      warn "Backups are not configured; skipping credential prompts in non-interactive mode."
      event "backup_setup_skipped" "reason=non_interactive"
      return 1
    fi

    hr
    printf '  %sEncrypted offsite backups%s\n\n' "$C_INF" "$C_RST"
    printf '  Your chat history, documents, and vector database can be backed up\n'
    printf '  nightly to Cloudflare R2, encrypted on this Pi before upload.\n'
    printf '  Cloudflare stores only ciphertext and cannot read any of it.\n\n'

    read -r -p "  Configure backups now? [Y/n]: " _ans < /dev/tty
    if [[ "${_ans,,}" == "n" ]]; then
      warn "Skipping. Re-run ./install.sh at any time to configure backups."
      event "backup_setup_declined"
      return 1
    fi

    mkdir -p "$BACKUP_CONF_DIR"
    chmod 700 "$BACKUP_CONF_DIR"

    while [[ -z "$cf_account" ]]; do
      read -r -p "    Cloudflare account ID: " cf_account < /dev/tty
      cf_account="${cf_account#https://}"
      cf_account="${cf_account#http://}"
      cf_account="${cf_account%%/*}"
      cf_account="${cf_account%%.r2.cloudflarestorage.com*}"
      cf_account="$(printf '%s' "$cf_account" | tr -d '[:space:]')"
      [[ -n "$cf_account" ]] || warn "Account ID cannot be empty."
    done

    read -r -p "    R2 bucket name [hybrid-ai-backup]: " cf_bucket < /dev/tty
    cf_bucket="${cf_bucket:-hybrid-ai-backup}"
    cf_bucket="$(printf '%s' "$cf_bucket" | tr -d '[:space:]')"

    while [[ -z "$cf_key_id" ]]; do
      read -r -p "    R2 Access Key ID: " cf_key_id < /dev/tty
      cf_key_id="$(printf '%s' "$cf_key_id" | tr -d '[:space:]')"
    done

    while [[ -z "$cf_secret" ]]; do
      read -r -s -p "    R2 Secret Access Key: " cf_secret < /dev/tty
      echo
      cf_secret="$(printf '%s' "$cf_secret" | tr -d '[:space:]')"
    done

    if [[ ! -f "$RESTIC_PW_FILE" ]]; then
      printf '\n    A repository password encrypts your backups.\n'
      read -r -p "    Generate a strong one automatically? [Y/n]: " _gen < /dev/tty

      if [[ "${_gen,,}" == "n" ]]; then
        while :; do
          read -r -s -p "    Enter repository password: " pw1 < /dev/tty
          echo
          read -r -s -p "    Confirm: " pw2 < /dev/tty
          echo
          [[ "$pw1" == "$pw2" && -n "$pw1" ]] && break
          warn "Passwords did not match, or were empty."
        done
        printf '%s\n' "$pw1" > "$RESTIC_PW_FILE"
      else
        openssl rand -base64 48 > "$RESTIC_PW_FILE"
      fi
      chmod 600 "$RESTIC_PW_FILE"
    fi

    tmp_env="$(mktemp "${BACKUP_CONF_DIR}/.r2.XXXXXX")"
    chmod 600 "$tmp_env"
    cat > "$tmp_env" <<EOF2
# hybrid-ai backup credentials -- generated $(date -u +%Y-%m-%dT%H:%M:%SZ)
RESTIC_REPOSITORY=s3:https://${cf_account}.r2.cloudflarestorage.com/${cf_bucket}
RESTIC_PASSWORD_FILE=${RESTIC_PW_FILE}
AWS_ACCESS_KEY_ID=${cf_key_id}
AWS_SECRET_ACCESS_KEY=${cf_secret}
AWS_DEFAULT_REGION=auto
RESTIC_HOST=$(hostname -s)
EOF2
    mv -f "$tmp_env" "$R2_ENV_FILE"
    chmod 600 "$R2_ENV_FILE"
    unset cf_secret pw1 pw2
    ok "Credentials written to ${R2_ENV_FILE} (0600)."

    log "Initialising the encrypted repository..."
    if "${SCRIPT_DIR}/backup/backup.sh" --init; then
      newly_configured=1
      event "backup_repo_ready" "bucket=${cf_bucket}"
    else
      warn "Repository initialisation failed. Check credentials and bucket name."
      event "backup_setup_failed" "reason=init"
      return 1
    fi
  fi

  # Scheduler repair runs on every installation, even when credentials already exist.
  install_backup_scheduler || warn "Backup credentials exist, but scheduler installation needs attention."

  if (( newly_configured )); then
    read -r -p "  Run the first backup now? [Y/n]: " _first < /dev/tty
    if [[ "${_first,,}" != "n" ]]; then
      if "${SCRIPT_DIR}/backup/backup.sh"; then
        ok "First backup completed successfully."
        event "backup_validation_success"
      else
        warn "First backup failed. See backup.log."
        event "backup_validation_failed"
      fi
    fi

    hr
    printf '  %sSTORE YOUR REPOSITORY PASSWORD SOMEWHERE OFF THIS PI.%s\n\n' "$C_WRN" "$C_RST"
    printf '    cat %s\n\n' "$RESTIC_PW_FILE"
    hr
  fi

  return 0
}

setup_backups || true

event "install_success" \
  "ollama_limit=${OLLAMA_MEM_LIMIT}" \
  "peer_resolved=${TAILSCALE_IP:+yes}" \
  "backups=$([[ -f "$R2_ENV_FILE" && -f "$RESTIC_PW_FILE" ]] && echo configured || echo none)"

hr
ok "Control plane stack is up."
printf '\n    Service Hub  : http://%s/hub\n' "${LOCAL_DOMAIN}"
printf '    Open WebUI   : http://%s\n' "${LOCAL_DOMAIN}"
printf '    OpenHands    : SSH tunnel to http://127.0.0.1:%s\n' "${OPENHANDS_PORT:-3001}"
printf '    Hermes Agent : http://hermes.%s\n' "${LOCAL_DOMAIN}"
printf '    Status Page  : http://status.%s\n' "${LOCAL_DOMAIN}"
printf '    Ollama API   : http://%s/ollama/\n' "${LOCAL_DOMAIN}"
printf '    vLLM peer    : http://%s:%s/v1  (on demand)\n\n' "${TAILSCALE_IP:-<unresolved>}" "${VLLM_PORT:-8000}"

if ((${#MISSING_DNS[@]} > 0)); then
  hr
  warn "ACTION REQUIRED: Pi-hole DNS entries are missing!"
  printf 'The following subdomains do not currently resolve to this Pi IP (%s):\n' "${PI_LAN_IP:-192.168.x.x}"
  for missing in "${MISSING_DNS[@]}"; do
    printf '  - %s\n' "$missing"
  done
  printf '\nAdd these A Records in your Pi-hole (Local DNS -> DNS Records):\n'
  for missing in "${MISSING_DNS[@]}"; do
    printf '  %-32s --> %s\n' "$missing" "${PI_LAN_IP:-192.168.x.x}"
  done
  hr
else
  ok "All required local hostnames resolve successfully via local DNS!"
fi

printf '\n  Next steps:\n'
printf '    1. Open http://%s and log in / set up admin\n' "${LOCAL_DOMAIN}"
printf '    2. Open http://hermes.%s to view persistent memories and skills\n' "${LOCAL_DOMAIN}"
printf '    3. From your client, run: ssh -N -L 127.0.0.1:%s:127.0.0.1:%s %s@%s\n' \
  "${OPENHANDS_PORT:-3001}" "${OPENHANDS_PORT:-3001}" "${USER}" "${PI_HOST}"
printf '       Then open http://127.0.0.1:%s for OpenHands\n' "${OPENHANDS_PORT:-3001}"
printf '    4. Check stack health at http://status.%s or run ./doctor.sh\n\n' "${LOCAL_DOMAIN}"
```


## File: openhands/docker-compose.openhands.yml
---
Directory: `openhands`
---
```yaml
# ---------------------------------------------------------------------------
# FILE: openhands/docker-compose.openhands.yml
# PURPOSE (plain English):
#   Runs OpenHands, the agent that maintains this project's code for you.
#   It is an OVERLAY: it adds one service to the main docker-compose.yml rather
#   than replacing it. Always pass BOTH files together:
#
#       docker compose -f docker-compose.yml \
#                      -f openhands/docker-compose.openhands.yml \
#                      --env-file .env <command>
#
#   WHY THAT MATTERS: "up -d --remove-orphans" WITHOUT this file treats the
#   OpenHands container as an orphan and DELETES it. install.sh uses
#   --remove-orphans on every run. Prefer openhands/scripts/openhands-control.sh,
#   which always passes both files.
#
# SECURITY -- read before changing anything here:
#
#   1. DOCKER SOCKET. OpenHands creates sandbox containers, so it needs
#      /var/run/docker.sock. Socket access is effectively root on this host.
#      That is why the port below binds to 127.0.0.1 ONLY, and why there is no
#      Caddy route. Reach it over an SSH tunnel across Tailscale:
#
#          ssh -L 3001:127.0.0.1:3001 <user>@<pi-tailnet-name>
#
#   2. WORKSPACE ISOLATION (the important one). OPENHANDS_WORKSPACE points at
#      a SEPARATE CLONE of the repository -- never at this deployment
#      directory, which holds .env, install.log and backup.log. The sandbox
#      runs as your uid, so file permissions would NOT stop it reading them.
#
#      The sandbox is the component that processes untrusted repository text.
#      It is precisely the component that must not have your credentials in
#      reach. scripts/setup-agent-workspace.sh creates and guards that clone.
#
#      The variable is REQUIRED -- no default. If unset, compose fails loudly
#      rather than silently falling back to something unsafe.
#
#   3. no-new-privileges is set, but be honest about what it buys: it limits
#      setuid escalation inside a container that already holds a socket
#      capable of creating privileged containers. Keep it; do not rely on it.
# ---------------------------------------------------------------------------
services:
  openhands:
    image: ${OPENHANDS_IMAGE:-docker.openhands.dev/openhands/openhands:1.8}
    container_name: hybrid-ai-openhands
    restart: unless-stopped

    # 127.0.0.1 is deliberate and load-bearing. Changing this to 0.0.0.0 would
    # publish arbitrary code execution as root to your LAN.
    ports:
      - "127.0.0.1:${OPENHANDS_PORT:-3001}:3000"

    environment:
      AGENT_SERVER_IMAGE_REPOSITORY: ${OPENHANDS_AGENT_IMAGE_REPOSITORY:-ghcr.io/openhands/agent-server}
      AGENT_SERVER_IMAGE_TAG: ${OPENHANDS_AGENT_IMAGE_TAG:-1.26.0-python}

      # Off by default: event logs are verbose and can echo file contents from
      # the workspace. Turn on temporarily when debugging, then turn it back off.
      LOG_ALL_EVENTS: ${OPENHANDS_LOG_ALL_EVENTS:-false}

      OH_PERSISTENCE_DIR: /.openhands
      SANDBOX_USER_ID: ${STATUS_UID:-1000}

      # The isolated clone -- NOT this directory. See note 2 above.
      # No default: fail loudly rather than fall back to something unsafe.
      SANDBOX_VOLUMES: ${OPENHANDS_WORKSPACE:?OPENHANDS_WORKSPACE must be set - run ./install.sh}:/workspace:rw

      # --- Cloud GPU settings & MagicDNS -----------------------------------
      RUNPOD_HOST: ${RUNPOD_HOST}
      PI_HOST: ${PI_HOST}

    dns:
      - 100.100.100.100

    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      # Holds LLM provider credentials. Lives outside the repo so it is never
      # committed and never visible to the sandbox. Mode 0700.
      - ${OPENHANDS_STATE_DIR:-${HOME}/.openhands}:/.openhands

    extra_hosts:
      - host.docker.internal:host-gateway

    security_opt:
      - no-new-privileges:true

    # A Pi 5 with 16 GB runs Ollama and Open WebUI alongside this. Without a
    # ceiling, a long agent session can starve the serving path -- and what you
    # would notice is chat getting slow, not OpenHands misbehaving.
    deploy:
      resources:
        limits:
          memory: ${OPENHANDS_MEM_LIMIT:-2g}
          cpus: "${OPENHANDS_CPUS:-1.5}"

    healthcheck:
      test: ["CMD-SHELL", "python -c \"import urllib.request; urllib.request.urlopen('http://127.0.0.1:3000', timeout=5)\""]
      interval: 30s
      timeout: 10s
      retries: 5
      # Generous: the first start pulls a large image on modest hardware.
      start_period: 120s

    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
```


## File: openhands/scripts/openhands-control.sh
---
Directory: `openhands/scripts`
---
```bash
#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: openhands/scripts/openhands-control.sh
# PURPOSE (plain English):
#   Start, stop, and inspect the OpenHands maintenance agent.
#
# WHY USE THIS INSTEAD OF docker compose DIRECTLY:
#   OpenHands lives in an overlay file. A compose command that omits the
#   overlay does not see the service -- and "up -d --remove-orphans" without it
#   will DELETE the container, because compose considers it an orphan.
#
#   install.sh uses --remove-orphans on every run. The short form works fine
#   for "logs" and "ps", which is exactly what makes the exception dangerous:
#   the habit forms, and then one command behaves differently.
#
#   This wrapper always passes both files. Use it.
# ---------------------------------------------------------------------------
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

[[ -f .env ]] || { echo "Missing .env. Run ./install.sh first." >&2; exit 1; }

COMPOSE=(docker compose
         -f docker-compose.yml
         -f openhands/docker-compose.openhands.yml
         --env-file .env)

# Read the configured workspace for display. Parsed line by line, never
# sourced -- sourcing executes the file as shell code.
workspace() {
  local line v
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^OPENHANDS_WORKSPACE=(.*)$ ]]; then
      v="${BASH_REMATCH[1]}"; v="${v%\"}"; v="${v#\"}"
      printf '%s' "$v"; return
    fi
  done < .env
  printf '(unset)'
}

case "${1:-status}" in
  start)
    "${COMPOSE[@]}" up -d openhands
    printf '\nOpenHands starting.\n'
    printf '  Workspace : %s\n' "$(workspace)"
    printf '  Access    : ssh -L 3001:127.0.0.1:3001 <user>@<pi>\n'
    printf '              then open http://127.0.0.1:3001\n'
    ;;
  stop)    "${COMPOSE[@]}" stop openhands ;;
  restart) "${COMPOSE[@]}" restart openhands ;;
  logs)    "${COMPOSE[@]}" logs -f --tail 200 openhands ;;
  status)
    "${COMPOSE[@]}" ps openhands
    printf '\nWorkspace: %s\n' "$(workspace)"
    ;;
  update)
    "${COMPOSE[@]}" pull openhands
    "${COMPOSE[@]}" up -d openhands
    ;;
  workspace)
    "${ROOT}/scripts/setup-agent-workspace.sh"
    ;;
  *)
    echo "Usage: $0 {start|stop|restart|logs|status|update|workspace}" >&2
    exit 2
    ;;
esac
```


## File: openwebui/build_pipe.py
---
Directory: `openwebui`
---
```python
#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# FILE: openwebui/build_pipe.py
# PURPOSE (plain English):
#   Glue runpod_core.py and pipe_wrapper.py together into the single file you
#   paste into Open WebUI.
#
# WHY THIS EXISTS:
#   Open WebUI functions are pasted into a text box in the web UI, not
#   installed as Python packages. A pipe therefore cannot "import" a sibling
#   module -- there is no file next to it at runtime.
#
#   We still want the wake/validate/poll logic in its own file, so a future
#   waking shim can import it unchanged rather than duplicating it. This script
#   is the compromise: two source files for humans, one generated file for
#   Open WebUI.
#
# HOW TO RUN IT:
#   python3 openwebui/build_pipe.py            # write openwebui/runpod_pipe.py
#   python3 openwebui/build_pipe.py --check    # verify it is up to date (CI)
#
#   Run it after editing either source file, and commit the result. The --check
#   mode exits non-zero if the generated file is stale, so CI catches a
#   forgotten rebuild before it becomes a confusing production bug.
# ---------------------------------------------------------------------------
from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
CORE = HERE / "runpod_core.py"
WRAPPER = HERE / "pipe_wrapper.py"
OUTPUT = HERE / "runpod_pipe.py"

# Open WebUI parses this frontmatter for the function's name, version, and
# required Python packages. It must be the very first thing in the generated
# file. Do not delete it.
FRONTMATTER = '''"""
title: RunPod vLLM (Tailscale, on-demand)
author: hybrid-ai
version: 1.1.0
license: MIT
description: >
    Routes prompts to a vLLM server on a RunPod GPU pod over a Tailscale mesh
    address. Resumes the pod on demand, waits for the model to warm, streams
    OpenAI-compatible chunks back, and lets the pod's own idle watchdog handle
    shutdown. No prompt content is logged anywhere in this module.
requirements: httpx
"""
'''

BANNER = '''# ===========================================================================
#  GENERATED FILE -- DO NOT EDIT
#
#  Built by openwebui/build_pipe.py from:
#      openwebui/runpod_core.py     wake / validate / poll / stream
#      openwebui/pipe_wrapper.py    Open WebUI presentation layer
#
#  Edit those files and re-run:  python3 openwebui/build_pipe.py
#  Editing this file directly means your change is lost on the next build.
#
#  This concatenation exists because Open WebUI functions are pasted as a
#  single file and cannot import sibling modules.
# ===========================================================================
'''


def build() -> str:
    """Return the contents of the generated single-file pipe."""
    for path in (CORE, WRAPPER):
        if not path.exists():
            raise SystemExit(f"Missing source file: {path}")

    core = CORE.read_text(encoding="utf-8")
    wrapper = WRAPPER.read_text(encoding="utf-8")

    # The wrapper's own header explains that it is one half of a pair. Useful
    # when reading the source, confusing at the top of a generated file that
    # already carries the banner above, so drop it.
    marker = "# --- imports used only by the wrapper"
    if marker in wrapper:
        wrapper = wrapper[wrapper.index(marker):]

    return (
        FRONTMATTER
        + BANNER
        + core
        + "\n\n"
        + "# " + "-" * 73 + "\n"
        + "# OPEN WEBUI PRESENTATION LAYER  (from pipe_wrapper.py)\n"
        + "# " + "-" * 73 + "\n"
        + wrapper
    )


def main() -> int:
    generated = build()
    check_only = "--check" in sys.argv

    if check_only:
        if not OUTPUT.exists():
            print(f"FAIL: {OUTPUT.name} does not exist. Run: python3 {Path(__file__).name}")
            return 1
        if OUTPUT.read_text(encoding="utf-8") != generated:
            print(
                f"FAIL: {OUTPUT.name} is out of date with its sources.\n"
                f"      Run: python3 openwebui/{Path(__file__).name}"
            )
            return 1
        print(f"OK: {OUTPUT.name} is up to date.")
        return 0

    OUTPUT.write_text(generated, encoding="utf-8")
    print(f"Wrote {OUTPUT} ({generated.count(chr(10))} lines)")
    print("Paste this file into Open WebUI -> Workspace -> Functions -> +")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```


## File: openwebui/pipe_wrapper.py
---
Directory: `openwebui`
---
```python
# -------------------------------------------------------------------------
# OPEN WEBUI PRESENTATION LAYER  (from pipe_wrapper.py)
# -------------------------------------------------------------------------
# --- imports used only by the wrapper --------------------------------------
# (runpod_core.py, prepended by build_pipe.py, supplies asyncio, logging, os,
#  time, httpx, the typing names, and its own helpers.)
import uuid

from pydantic import BaseModel, Field


class Pipe:
    """On-demand RunPod vLLM backend for Open WebUI."""

    class Valves(BaseModel):
        """
        Settings you can change from the Open WebUI settings panel.

        Each default reads from an environment variable first, falling back to
        a hardcoded value. Those variables come from the .env that install.sh
        generated on the Pi, passed in by docker-compose.yml. In short: you
        should not need to edit this file to configure it.
        """

        RUNPOD_API_KEY: str = Field(
            default=os.getenv("RUNPOD_API_KEY", ""),
            description="RunPod API key. Used for podResume / status queries only.",
        )
        RUNPOD_POD_ID: str = Field(
            default=os.getenv("RUNPOD_POD_ID", ""),
            description="Target RunPod pod ID.",
        )
        RUNPOD_HOST: str = Field(
            default=os.getenv("RUNPOD_HOST", ""),
            description="MagicDNS hostname of the pod. Resolved by install.sh.",
        )
        PEER_HOSTNAME: str = Field(
            default=os.getenv("PEER_HOSTNAME", "runpod-worker"),
            description="Tailnet hostname of the pod. Used in error messages.",
        )
        VLLM_PORT: int = Field(
            default=int(os.getenv("VLLM_PORT", "8000")),
            description="Port vLLM listens on inside the pod.",
        )
        MODEL_NAME: str = Field(
            default=os.getenv("VLLM_MODEL_NAME", "Qwen/Qwen2.5-Coder-32B-Instruct-AWQ"),
            description="Model identifier as served by vLLM.",
        )
        MODEL_DISPLAY_NAME: str = Field(
            default=os.getenv("VLLM_DISPLAY_NAME", "Qwen2.5-Coder-32B (RunPod)"),
            description="Label shown in the Open WebUI model picker.",
        )
        WARMUP_TIMEOUT: int = Field(
            default=int(os.getenv("POD_WARMUP_TIMEOUT", "600")),
            description="Seconds to wait for the readiness probe before failing.",
        )
        POLL_INTERVAL: float = Field(
            default=5.0, description="Seconds between readiness probes."
        )
        REQUEST_TIMEOUT: int = Field(
            default=int(os.getenv("VLLM_REQUEST_TIMEOUT", "900")),
            description="Read timeout for a single completion stream.",
        )
        MAX_TOKENS: int = Field(
            default=int(os.getenv("VLLM_MAX_TOKENS", "4096")),
            description="Default completion cap when the client sends none.",
        )
        EMIT_STATUS: bool = Field(
            default=True, description="Show wake/warm progress in the chat UI."
        )
        ENFORCE_MESH_ONLY: bool = Field(
            default=True,
            description="Refuse to send prompts to any address outside 100.64.0.0/10.",
        )

    def __init__(self) -> None:
        # "manifold" tells Open WebUI this pipe can offer one or more models in
        # the dropdown, rather than being a single fixed endpoint.
        self.type = "manifold"
        self.id = "runpod_vllm"
        self.name = "runpod/"
        self.valves = self.Valves()

        # The endpoint's config is refreshed per request from current Valves, so
        # changes in the settings panel take effect without restarting Open
        # WebUI. The warm-cache and wake-lock live on it, so we keep ONE
        # instance and refresh its config rather than constructing a new one.
        self._endpoint = RunPodEndpoint(self._config())

    # -- Configuration -------------------------------------------------------

    def _config(self) -> EndpointConfig:
        """Translate Open WebUI Valves into a framework-agnostic config."""
        v = self.valves
        return EndpointConfig(
            runpod_api_key=v.RUNPOD_API_KEY,
            runpod_pod_id=v.RUNPOD_POD_ID,
            runpod_host=v.RUNPOD_HOST,
            vllm_port=v.VLLM_PORT,
            model_name=v.MODEL_NAME,
            peer_hostname=v.PEER_HOSTNAME,
            warmup_timeout=v.WARMUP_TIMEOUT,
            poll_interval=v.POLL_INTERVAL,
            request_timeout=v.REQUEST_TIMEOUT,
            max_tokens=v.MAX_TOKENS,
            enforce_mesh_only=v.ENFORCE_MESH_ONLY,
        )

    # -- Open WebUI model registration --------------------------------------

    def pipes(self) -> List[Dict[str, str]]:
        """Open WebUI calls this to ask which models to show in the dropdown."""
        return [{"id": "vllm-cloud", "name": self.valves.MODEL_DISPLAY_NAME}]

    # -- Presentation --------------------------------------------------------

    def _status_callback(
        self, emitter: Optional[Callable[[dict], Awaitable[None]]]
    ) -> StatusCallback:
        """
        Adapt Open WebUI's event emitter to the core's StatusCallback shape.

        Wrapped in try/except because a cosmetic status update must never crash
        an in-flight response.
        """

        async def _emit(description: str, done: bool = False) -> None:
            if emitter and self.valves.EMIT_STATUS:
                try:
                    await emitter(
                        {
                            "type": "status",
                            "data": {"description": description, "done": done},
                        }
                    )
                except Exception:
                    pass

        return _emit

    # -- Main entrypoint -----------------------------------------------------

    async def pipe(
        self,
        body: Dict[str, Any],
        __event_emitter__: Optional[Callable[[dict], Awaitable[None]]] = None,
        **kwargs: Any,
    ) -> AsyncGenerator[str, None]:
        """
        The function Open WebUI calls for every message sent to this model.

        "body" holds the conversation and settings. The double-underscore
        argument is injected by Open WebUI and lets us push status updates.

        This is an async generator: instead of returning once at the end, it
        yields pieces of text as they arrive, producing the typewriter effect.
        """
        emit = self._status_callback(__event_emitter__)

        # Pick up any Valves changes made since the last request.
        self._endpoint.config = self._config()
        endpoint = self._endpoint

        # Correlation id: ties a "it failed at 3pm" report to exact log lines.
        # Short random hex, no user data.
        req_id = uuid.uuid4().hex[:8]
        started = time.monotonic()
        chunks = 0

        # -- Step 1: validate configuration before touching the network ------
        config_error = endpoint.preflight()
        if config_error:
            # WARNING, not ERROR: a misconfiguration to fix, not a system fault.
            log_event(
                logging.WARNING, "request_rejected",
                request_id=req_id, reason="preflight_failed",
                detail=config_error[:120],
            )
            yield f"**Configuration error**\n\n{config_error}"
            return

        messages = body.get("messages", [])
        if not messages:
            log_event(
                logging.WARNING, "request_rejected",
                request_id=req_id, reason="empty_messages",
            )
            yield "**Error**: no messages in request body."
            return

        payload = endpoint.build_payload(messages, body)

        # Metadata only: how many turns, not what is in them.
        log_event(
            logging.INFO, "request_started", request_id=req_id,
            message_count=len(messages), max_tokens=payload["max_tokens"],
        )

        try:
            async with endpoint.client() as client:
                # -- Steps 2 and 3: wake, then wait ---------------------------
                wake_seconds = await endpoint.ensure_ready(client, emit)
                log_event(
                    logging.INFO, "pod_ready",
                    request_id=req_id, wake_seconds=wake_seconds,
                )

                # -- Step 4: stream the answer -------------------------------
                async for event in endpoint.stream_completion(client, payload):
                    if event["type"] == "content":
                        chunks += 1
                        yield event["text"]

                    elif event["type"] == "error":
                        yield (
                            f"\n\n**vLLM returned HTTP {event['status']}**\n\n"
                            f"```\n{event['detail']}\n```\n\n"
                            f"Full detail is in the pod's logs in the RunPod console."
                        )
                        return

                    elif event["type"] == "done":
                        # --- Classify the outcome ---------------------------
                        # A stream that ends without [DONE] was cut short: the
                        # pod was stopped, the tunnel dropped, or the server
                        # died. Without this check that looks identical to
                        # success from the user's side.
                        duration = round(time.monotonic() - started, 1)

                        if not event["saw_done"]:
                            log_event(
                                logging.WARNING, "request_degraded",
                                request_id=req_id, reason="stream_incomplete",
                                chunks=event["chunks"],
                                malformed_chunks=event["malformed"],
                                duration_s=duration,
                            )
                            await emit("Stream ended unexpectedly.", True)
                            yield (
                                "\n\n---\n**Warning: this response is incomplete.** The "
                                "connection to the pod closed before the model finished. "
                                "The pod may have been stopped mid-generation. Resend to retry."
                            )

                        elif event["finish_reason"] == "length":
                            log_event(
                                logging.INFO, "request_truncated",
                                request_id=req_id, reason="max_tokens",
                                chunks=event["chunks"], duration_s=duration,
                            )
                            await emit("Complete (hit token limit).", True)
                            yield (
                                "\n\n---\n*Response reached the token limit and was cut "
                                "off. Raise `MAX_TOKENS` in the function's Valves for "
                                "longer answers.*"
                            )

                        else:
                            log_event(
                                logging.INFO, "request_success",
                                request_id=req_id, chunks=event["chunks"],
                                malformed_chunks=event["malformed"],
                                finish_reason=event["finish_reason"] or "stop",
                                duration_s=duration,
                            )
                            await emit("Complete.", True)

        # -- Error handling ---------------------------------------------------
        # Each case produces a specific, actionable message in the chat window.
        # A junior developer -- or you at 6am -- should be able to read it and
        # know exactly what to go and check.

        except TimeoutError as exc:
            log_event(
                logging.ERROR, "request_failed", request_id=req_id,
                reason="warmup_timeout", chunks=chunks,
                duration_s=round(time.monotonic() - started, 1),
            )
            await emit("Warm-up timed out.", True)
            yield f"\n\n**Pod warm-up timed out**\n\n{exc}"

        except httpx.ConnectError as exc:
            log_event(
                logging.ERROR, "request_failed", request_id=req_id,
                reason="connect_error", chunks=chunks,
                duration_s=round(time.monotonic() - started, 1),
            )
            await emit("Connection failed.", True)
            yield (
                f"\n\n**Cannot reach the inference pod** at `{endpoint.base_url}`.\n\n"
                f"The tailnet route is likely down. Verify with "
                f"`tailscale status | grep {self.valves.PEER_HOSTNAME}` on the Pi - if "
                f"the peer is missing entirely, the pod's ephemeral node was reaped and "
                f"`RUNPOD_HOST` needs refreshing via `./install.sh`.\n\n"
                f"```\n{scrub(str(exc))[:300]}\n```"
            )

        except httpx.ReadTimeout:
            # Partial output may already have reached the user, so this is a
            # degraded outcome rather than a clean failure.
            log_event(
                logging.ERROR, "request_failed", request_id=req_id,
                reason="read_timeout", chunks=chunks,
                partial_output=chunks > 0,
                duration_s=round(time.monotonic() - started, 1),
            )
            await emit("Stream timed out.", True)
            yield (
                f"\n\n**Stream timed out** after {self.valves.REQUEST_TIMEOUT}s. "
                f"The pod may have been stopped mid-generation, or the request "
                f"exceeded the read timeout. Raise `REQUEST_TIMEOUT` in the Valves "
                f"if long generations are expected."
            )

        except RuntimeError as exc:
            log_event(
                logging.ERROR, "request_failed", request_id=req_id,
                reason="runpod_api_error", chunks=chunks,
                duration_s=round(time.monotonic() - started, 1),
            )
            await emit("RunPod API error.", True)
            yield (
                f"\n\n**RunPod control plane error**\n\n"
                f"```\n{scrub(str(exc))[:300]}\n```"
            )

        except httpx.HTTPStatusError as exc:
            log_event(
                logging.ERROR, "request_failed", request_id=req_id,
                reason="http_status_error",
                status=exc.response.status_code, chunks=chunks,
                duration_s=round(time.monotonic() - started, 1),
            )
            await emit("HTTP error.", True)
            yield (
                f"\n\n**HTTP {exc.response.status_code} from RunPod**\n\n"
                f"Check that `RUNPOD_API_KEY` is valid and scoped to this pod."
            )

        except asyncio.CancelledError:
            # The user hit stop, or Open WebUI tore the request down. Not an
            # error -- record it and re-raise so cancellation still propagates
            # correctly rather than being swallowed.
            log_event(
                logging.INFO, "request_cancelled", request_id=req_id,
                chunks=chunks,
                duration_s=round(time.monotonic() - started, 1),
            )
            raise

        except Exception as exc:  # last-resort guard so nothing escapes silently
            log_event(
                logging.ERROR, "request_failed", request_id=req_id,
                reason="unexpected", exc_type=type(exc).__name__,
                chunks=chunks,
                duration_s=round(time.monotonic() - started, 1),
            )
            await emit("Unexpected failure.", True)
            yield (
                f"\n\n**Unexpected error** (`{type(exc).__name__}`)\n\n"
                f"```\n{scrub(str(exc))[:300]}\n```"
            )
```


## File: openwebui/runpod_core.py
---
Directory: `openwebui`
---
```python
# ---------------------------------------------------------------------------
# FILE: openwebui/runpod_core.py
# PURPOSE (plain English):
#   Everything needed to talk to a vLLM server on an on-demand RunPod GPU pod,
#   with NO dependency on Open WebUI.
#
#   This file knows how to:
#     1. VALIDATE  -- confirm a destination is inside the Tailscale mesh, and
#        refuse to transmit if it is not.
#     2. WAKE      -- ask RunPod to resume a pod that is normally switched off.
#     3. POLL      -- wait until vLLM reports the model is loaded and ready.
#     4. STREAM    -- send a chat-completions request and yield events.
#
#   It knows nothing about chat windows, model dropdowns, valves, or status
#   emitters. That separation is deliberate.
#
# WHY THIS FILE EXISTS SEPARATELY:
#   This logic has one consumer today (the Open WebUI pipe) and will soon have
#   two: a waking shim that fronts every RunPod endpoint so other tools can
#   reach a pod that is currently stopped.
#
#   If it stayed tangled with the Open WebUI Pipe class, building that shim
#   would mean rewriting it -- and then maintaining two implementations of pod
#   lifecycle that drift apart.
#
#   THE RULE: nothing in this file may import or reference Open WebUI, pydantic
#   valves, or event emitters. Progress is reported through the on_status
#   callback, which any caller can implement however it likes.
#
# HOW IT IS DEPLOYED:
#   Open WebUI functions are pasted into the UI as a SINGLE file, so a pipe
#   cannot import this module at runtime. build_pipe.py concatenates this file
#   with pipe_wrapper.py to produce the pasteable runpod_pipe.py.
#
# PRIVACY:
#   Prompts travel only over Tailscale (100.x.x.x, WireGuard-encrypted). Every
#   log line here is metadata only -- timings, status, HTTP codes, counts.
#   Never add message content to a log line.
# ---------------------------------------------------------------------------
from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import time
from dataclasses import dataclass
from typing import Any, AsyncGenerator, Awaitable, Callable, Dict, List, Optional

import httpx

# RunPod's control API. Used to start and query pods -- never to send prompts.
RUNPOD_GRAPHQL = "https://api.runpod.io/graphql"

# Credential shapes that must never reach a chat window or a log line, even
# inside an exception message. Some libraries helpfully include the full
# request (headers and all) in their error text.
_SECRET_PATTERNS = [
    re.compile(r"rpa_[A-Za-z0-9]+"),                    # RunPod API key
    re.compile(r"tskey-[A-Za-z0-9\-]+"),                # Tailscale auth key
    # Authorization headers. The optional "Bearer " must be consumed TOGETHER
    # with the token that follows it. An earlier version of this pattern ended
    # at \S+, which matched the word "Bearer" and stopped -- leaving the actual
    # credential in the string. Order matters: this must precede the bare rule.
    re.compile(r"(?i)authorization\s*[:=]\s*(bearer\s+)?\S+"),
    re.compile(r"(?i)bearer\s+\S+"),
    re.compile(r"(?i)api[_-]?key\s*[:=]\s*\S+"),
]


def scrub(text: str) -> str:
    """Replace anything credential-shaped with [REDACTED]."""
    for pattern in _SECRET_PATTERNS:
        text = pattern.sub("[REDACTED]", text)
    return text


# ---------------------------------------------------------------------------
# OUTCOME LOGGING
#   Every request ends in exactly one of three states, and all three are
#   recorded: success, degraded (partial answer), failure. Without this, a
#   report of "it was slow yesterday" leaves nothing to investigate -- the chat
#   UI keeps no record of why a request behaved the way it did.
#
#   PRIVACY: metadata only -- durations, counts, state names, HTTP codes.
#   Never log message content. Every value additionally passes through scrub()
#   as a second line of defence, in case an exception carries a credential.
# ---------------------------------------------------------------------------
logger = logging.getLogger("hybrid_ai.runpod_core")
if not logger.handlers:
    _handler = logging.StreamHandler()
    _handler.setFormatter(
        logging.Formatter("%(asctime)s %(levelname)s [runpod_core] %(message)s")
    )
    logger.addHandler(_handler)
    logger.setLevel(os.getenv("PIPE_LOG_LEVEL", "INFO").upper())
    # Do not also hand these records to the root logger, which may be
    # configured more verbosely than we want for something on a privacy path.
    logger.propagate = False


def log_event(level: int, event: str, **fields: Any) -> None:
    """Emit one structured, metadata-only line: event=<name> key=value ..."""
    parts = [f"event={event}"]
    for key, value in fields.items():
        parts.append(f"{key}={scrub(str(value))}")
    logger.log(level, " ".join(parts))


# ---------------------------------------------------------------------------
# CONFIGURATION
#   A plain dataclass, not a pydantic model. The Open WebUI wrapper builds one
#   from its Valves; a shim would build one per endpoint from its own config.
#   Neither framework's types leak in here.
# ---------------------------------------------------------------------------
@dataclass
class EndpointConfig:
    """Everything needed to reach one RunPod vLLM endpoint."""

    runpod_api_key: str = ""
    runpod_pod_id: str = ""
    runpod_host: str = ""
    vllm_port: int = 8000
    model_name: str = ""
    # Peer hostname this endpoint registers under on the tailnet. Used only to
    # make error messages actionable.
    peer_hostname: str = "runpod-worker"
    warmup_timeout: int = 600
    poll_interval: float = 5.0
    request_timeout: int = 900
    max_tokens: int = 4096
    # Refuse to send prompts to any address outside 100.64.0.0/10.
    enforce_mesh_only: bool = True


# Progress callback. Any caller implements this however it likes: the pipe
# forwards to Open WebUI's event emitter, a shim would log or update state.
StatusCallback = Callable[[str, bool], Awaitable[None]]


async def _noop_status(_description: str, _done: bool = False) -> None:
    """Default callback for callers that do not care about progress."""
    return None


def is_mesh_address(ip: str) -> bool:
    """
    Return True only if the address is inside 100.64.0.0/10, the range
    Tailscale uses for private mesh addresses.

    WHY THIS MATTERS: if the address were ever wrong -- a typo, a stale value,
    a pasted public address -- prompts would cross the open internet
    unencrypted. This check makes that impossible.

    The range covers 100.64.x.x through 100.127.x.x.

    Parsing is deliberately strict. int() accepts surrounding whitespace and a
    leading sign, so "  100.64.0.1" and "+100.64.0.1" would otherwise pass and
    then be used to build a URL -- a value that LOOKED validated but was never
    really the address we thought it was. On a control whose entire job is
    keeping prompts inside the tunnel, permissive parsing is not a kindness.
    """
    parts = ip.split(".")
    if len(parts) != 4:
        return False
    if not all(p.isdigit() for p in parts):
        return False
    try:
        octets = [int(p) for p in parts]
    except ValueError:
        return False
    if any(o < 0 or o > 255 for o in octets):
        return False
    return octets[0] == 100 and 64 <= octets[1] <= 127


class RunPodEndpoint:
    """
    One on-demand vLLM endpoint on a RunPod GPU pod.

    Framework-agnostic. Owns validation, wake, readiness polling, and
    streaming. Shutdown is NOT handled here -- the pod turns itself off via the
    idle watchdog in runpod/start.sh.
    """

    def __init__(self, config: EndpointConfig) -> None:
        self.config = config

        # After a successful readiness check we skip re-checking for 60
        # seconds, avoiding a pointless round trip on every message during an
        # active conversation.
        self._warm_until: float = 0.0

        # AVAILABILITY: if two callers arrive at once, both would try to resume
        # the pod and both would poll. A lock serialises the wake-and-warm
        # phase so only one does the work; the second waits, then finds it warm.
        #
        # Created lazily rather than here, because an asyncio primitive binds to
        # the event loop it is first used on. A host may construct this object
        # once and serve it from a different loop, producing intermittent
        # "attached to a different loop" errors that are horrible to diagnose.
        self._wake_lock: Optional[asyncio.Lock] = None
        self._wake_lock_loop: Any = None

    # -- Helpers -------------------------------------------------------------

    def _get_wake_lock(self) -> asyncio.Lock:
        """Return a lock belonging to the currently running event loop."""
        try:
            loop = asyncio.get_running_loop()
        except RuntimeError:
            loop = None
        if self._wake_lock is None or self._wake_lock_loop is not loop:
            self._wake_lock = asyncio.Lock()
            self._wake_lock_loop = loop
        return self._wake_lock

    @property
    def base_url(self) -> str:
        """Root URL of the vLLM server, e.g. http://runpod-worker.tailXXXX.ts.net:8000"""
        return f"http://{self.config.runpod_host}:{self.config.vllm_port}"

    def preflight(self) -> Optional[str]:
        """
        Check configuration before doing anything.

        Returns an error message if something is wrong, or None if all is well.
        Callers should run this first so problems surface as a readable message
        instead of a stack trace.
        """
        c = self.config
        if not c.runpod_api_key:
            return "RUNPOD_API_KEY is not set. Re-run ./install.sh on the Pi."
        if not c.runpod_pod_id:
            return "RUNPOD_POD_ID is not set. Re-run ./install.sh on the Pi."
        if not c.runpod_host:
            return (
                "RUNPOD_HOST is empty. The pod has not registered on the tailnet yet. "
                "Start it once manually, then re-run ./install.sh to discover the peer."
            )

        # Validate numeric bounds. These come from environment variables, which
        # on a misconfigured host could be absent, zero, or absurd. A zero
        # poll_interval would busy-loop; an unbounded max_tokens would let one
        # request hold the GPU -- and the billing meter -- open indefinitely.
        if not (1 <= c.warmup_timeout <= 3600):
            return f"WARMUP_TIMEOUT must be between 1 and 3600 (got {c.warmup_timeout})."
        if not (0.5 <= c.poll_interval <= 60):
            return f"POLL_INTERVAL must be between 0.5 and 60 (got {c.poll_interval})."
        if not (1 <= c.max_tokens <= 32768):
            return f"MAX_TOKENS must be between 1 and 32768 (got {c.max_tokens})."
        if not (1 <= c.vllm_port <= 65535):
            return f"VLLM_PORT must be a valid port (got {c.vllm_port})."

        # SECURITY: validated here, at the point of use, rather than only at
        # install time. The address is resolved from live tailnet state.
        if c.enforce_mesh_only:
            is_secure = is_mesh_address(c.runpod_host) or c.runpod_host.endswith(".ts.net")
            if not is_secure:
                return (
                    f"Refusing to transmit: {c.runpod_host} is outside the Tailscale mesh. "
                    f"Prompts would leave the encrypted tunnel. "
                    f"Fix RUNPOD_HOST, or disable ENFORCE_MESH_ONLY if this is intentional."
                )
        return None

    # -- RunPod control plane ------------------------------------------------

    async def _graphql(
        self, client: httpx.AsyncClient, query: str, variables: dict
    ) -> dict:
        """
        Send one GraphQL request to RunPod and return its "data" section.

        GraphQL returns errors with a 200 OK status inside an "errors" key, so
        we check for that explicitly rather than trusting the HTTP status alone.

        SECURITY: the API key goes in an Authorization header, NOT a ?api_key=
        query parameter. RunPod's docs show the query-string form, but
        credentials in URLs are written into proxy logs, server access logs,
        and Referer headers. Headers are not logged by default.

        AVAILABILITY: transient transport failures and 5xx/429 responses are
        retried with exponential backoff. 4xx responses other than 429 are NOT
        retried -- a bad key or unknown pod id fails identically every time,
        and retrying only delays a clear error message.
        """
        last_exc: Optional[Exception] = None
        for attempt in range(1, 4):
            try:
                resp = await client.post(
                    RUNPOD_GRAPHQL,
                    json={"query": query, "variables": variables},
                    headers={
                        "Content-Type": "application/json",
                        "Authorization": f"Bearer {self.config.runpod_api_key}",
                    },
                    timeout=30.0,
                )
                if resp.status_code == 429 or resp.status_code >= 500:
                    if attempt < 3:
                        log_event(
                            logging.WARNING, "runpod_api_retry",
                            attempt=attempt, status=resp.status_code,
                        )
                        await asyncio.sleep(2 ** attempt)
                        continue
                resp.raise_for_status()
                payload = resp.json()
                if payload.get("errors"):
                    msgs = "; ".join(
                        e.get("message", "unknown") for e in payload["errors"]
                    )
                    raise RuntimeError(f"RunPod API error: {msgs}")
                return payload.get("data") or {}
            except (httpx.ConnectError, httpx.ConnectTimeout, httpx.ReadTimeout) as exc:
                last_exc = exc
                if attempt < 3:
                    log_event(
                        logging.WARNING, "runpod_api_retry",
                        attempt=attempt, reason=type(exc).__name__,
                    )
                    await asyncio.sleep(2 ** attempt)
                    continue
                raise

        if last_exc:
            raise last_exc
        raise RuntimeError("RunPod API unreachable after 3 attempts.")

    async def pod_status(self, client: httpx.AsyncClient) -> str:
        """
        Ask RunPod whether the pod is RUNNING, EXITED, etc.

        Returns "UNKNOWN" on any failure -- we would rather attempt a resume
        that turns out to be unnecessary than refuse to try.
        """
        query = """
        query pod($input: PodFilter) {
          pod(input: $input) { id desiredStatus runtime { uptimeInSeconds } }
        }
        """
        try:
            data = await self._graphql(
                client, query, {"input": {"podId": self.config.runpod_pod_id}}
            )
            pod = data.get("pod") or {}
            return pod.get("desiredStatus") or "UNKNOWN"
        except Exception:
            return "UNKNOWN"

    async def start_pod(
        self,
        client: httpx.AsyncClient,
        on_status: StatusCallback = _noop_status,
    ) -> None:
        """
        Resume the pod if it is not already running. Safe to call every time --
        if the pod is already up, this returns immediately.
        """
        status = await self.pod_status(client)
        if status == "RUNNING":
            await on_status("Pod already running - checking model...", False)
            return

        await on_status(f"Pod is {status} - sending resume request...", False)

        mutation = """
        mutation resume($input: PodResumeInput!) {
          podResume(input: $input) { id desiredStatus imageName }
        }
        """
        # gpuCount is required by RunPod's schema. 1 matches the single-GPU
        # default; multi-GPU pods resume with their own configured count
        # regardless of what we pass.
        variables = {"input": {"podId": self.config.runpod_pod_id, "gpuCount": 1}}

        try:
            data = await self._graphql(client, mutation, variables)
            new_status = (data.get("podResume") or {}).get("desiredStatus", "?")
            await on_status(f"Resume accepted (status: {new_status}).", False)
        except RuntimeError as exc:
            # If the pod was already starting, RunPod rejects the resume.
            # Harmless -- carry on to the readiness check.
            if "already" in str(exc).lower():
                await on_status("Pod was already starting.", False)
                return
            raise

    async def wait_for_vllm(
        self,
        client: httpx.AsyncClient,
        on_status: StatusCallback = _noop_status,
    ) -> None:
        """
        Poll /v1/models until vLLM reports the model is loaded.

        Connection errors during this loop are normal and expected: the pod is
        still booting and nothing is listening yet. We only give up once
        warmup_timeout seconds have elapsed.

        NOTE: we poll the MODEL LISTING, not the TCP port. A listening socket is
        not a loaded model, and treating it as one converts a clean "still
        warming up" wait into a confusing mid-stream failure minutes later.
        """
        if time.monotonic() < self._warm_until:
            return  # confirmed ready less than 60 seconds ago

        # time.monotonic() only ever moves forward. Unlike wall-clock time it
        # cannot jump if the system clock is adjusted, which makes it the
        # correct choice for measuring elapsed time.
        deadline = time.monotonic() + self.config.warmup_timeout
        probe_url = f"{self.base_url}/v1/models"
        attempt = 0

        while time.monotonic() < deadline:
            attempt += 1
            elapsed = int(
                self.config.warmup_timeout - (deadline - time.monotonic())
            )
            try:
                resp = await client.get(probe_url, timeout=10.0)
                if resp.status_code == 200:
                    body = resp.json()
                    served = [m.get("id") for m in body.get("data", [])]
                    if served:
                        self._warm_until = time.monotonic() + 60.0
                        await on_status(
                            f"Model ready after {elapsed}s - streaming...", True
                        )
                        return
            except (httpx.ConnectError, httpx.ConnectTimeout, httpx.ReadTimeout):
                pass  # expected while the pod boots and weights load
            except Exception:
                pass

            await on_status(
                f"Waiting for vLLM to load weights... {elapsed}s elapsed "
                f"(probe #{attempt})",
                False,
            )
            await asyncio.sleep(self.config.poll_interval)

        raise TimeoutError(
            f"vLLM did not become ready within {self.config.warmup_timeout}s at "
            f"{probe_url}. Check that the pod started, joined the tailnet as "
            f"'{self.config.peer_hostname}', and that start.sh did not exit early."
        )

    def invalidate_warm_cache(self) -> None:
        """
        Forget that the endpoint was recently confirmed ready.

        AVAILABILITY: callers must do this on any wake/warm failure. A stale
        warm flag would make the next request skip the readiness probe and fail
        immediately against a pod that is not actually up.
        """
        self._warm_until = 0.0

    async def ensure_ready(
        self,
        client: httpx.AsyncClient,
        on_status: StatusCallback = _noop_status,
    ) -> float:
        """
        Wake the pod if needed and block until the model is serving.

        Returns seconds spent waking. Serialised so concurrent callers do not
        both resume the same pod -- the second waits here, then finds it warm.
        """
        async with self._get_wake_lock():
            await on_status("Contacting RunPod control plane...", False)
            wake_started = time.monotonic()
            try:
                await self.start_pod(client, on_status)
                await self.wait_for_vllm(client, on_status)
            except Exception:
                self.invalidate_warm_cache()
                raise
            return round(time.monotonic() - wake_started, 1)

    # -- Inference -----------------------------------------------------------

    def build_payload(
        self, messages: List[Dict[str, Any]], options: Dict[str, Any]
    ) -> Dict[str, Any]:
        """
        Build an OpenAI chat-completions request body, which vLLM understands
        natively.

        Client-supplied max_tokens is never trusted above our own ceiling: an
        oversized value holds the GPU, and the billing meter, open.
        """
        try:
            requested = int(options.get("max_tokens") or self.config.max_tokens)
        except (TypeError, ValueError):
            requested = self.config.max_tokens
        effective = max(1, min(requested, self.config.max_tokens))

        payload: Dict[str, Any] = {
            "model": self.config.model_name,
            "messages": messages,
            "stream": True,
            "max_tokens": effective,
            "temperature": options.get("temperature", 0.7),
            "top_p": options.get("top_p", 0.9),
        }
        # Pass through optional tuning parameters only if the caller supplied them.
        for opt in ("frequency_penalty", "presence_penalty", "stop", "seed"):
            if options.get(opt) is not None:
                payload[opt] = options[opt]
        return payload

    def timeout(self) -> httpx.Timeout:
        """
        Separate timeouts per phase. "read" is generous because generating a
        long answer legitimately takes minutes.
        """
        return httpx.Timeout(
            connect=15.0,
            read=float(self.config.request_timeout),
            write=30.0,
            pool=15.0,
        )

    def client(self) -> httpx.AsyncClient:
        """
        Build an HTTP client for this endpoint.

        SECURITY: trust_env=False ignores HTTP_PROXY and friends. A stray proxy
        setting could silently reroute prompts somewhere we did not intend, so
        we refuse to honour them at all.
        """
        return httpx.AsyncClient(timeout=self.timeout(), trust_env=False)

    async def stream_completion(
        self,
        client: httpx.AsyncClient,
        payload: Dict[str, Any],
    ) -> AsyncGenerator[Dict[str, Any], None]:
        """
        Stream a chat completion, yielding STRUCTURED EVENTS rather than raw
        text. Callers decide how to render them.

        Event shapes:
            {"type": "error",   "status": int, "detail": str}
            {"type": "content", "text": str}
            {"type": "done",    "saw_done": bool, "chunks": int,
             "malformed": int, "finish_reason": str | None}

        Yielding events rather than strings is what keeps this reusable: the
        Open WebUI pipe renders them as markdown, while a shim would re-emit
        them as server-sent events.
        """
        chunks = 0        # content fragments delivered
        malformed = 0     # chunks that failed to parse
        saw_done = False  # did the server send its end-of-stream marker
        finish_reason: Optional[str] = None

        async with client.stream(
            "POST",
            f"{self.base_url}/v1/chat/completions",
            json=payload,
            headers={
                "Content-Type": "application/json",
                "Accept": "text/event-stream",
            },
        ) as response:
            if response.status_code != 200:
                # SECURITY: do not echo the raw upstream body onward. Error
                # bodies routinely contain internal paths, library versions,
                # and occasionally fragments of the request. Surface the status
                # code and a short, scrubbed excerpt only.
                raw = await response.aread()
                detail = scrub(raw.decode("utf-8", errors="replace"))[:200]
                yield {
                    "type": "error",
                    "status": response.status_code,
                    "detail": detail,
                }
                return

            # Server-Sent Events: every line looks like
            #   data: {...json...}
            # and the stream finishes with the literal  data: [DONE]
            async for line in response.aiter_lines():
                if not line or not line.startswith("data: "):
                    continue
                data = line[6:].strip()

                if data == "[DONE]":
                    saw_done = True
                    break

                try:
                    chunk = json.loads(data)
                except json.JSONDecodeError:
                    malformed += 1
                    continue  # skip a malformed chunk rather than dying

                choices = chunk.get("choices") or []
                if not choices:
                    continue

                # finish_reason tells us HOW generation ended. "length" means it
                # hit the token ceiling and was cut off -- the caller deserves
                # to know that rather than silently receiving a truncated answer.
                if choices[0].get("finish_reason"):
                    finish_reason = choices[0]["finish_reason"]

                delta = choices[0].get("delta") or {}
                content = delta.get("content")
                if content:
                    chunks += 1
                    yield {"type": "content", "text": content}

        yield {
            "type": "done",
            "saw_done": saw_done,
            "chunks": chunks,
            "malformed": malformed,
            "finish_reason": finish_reason,
        }
```


## File: openwebui/runpod_pipe.py
---
Directory: `openwebui`
---
```python
"""
title: RunPod vLLM (Tailscale, on-demand)
author: hybrid-ai
version: 1.1.0
license: MIT
description: >
    Routes prompts to a vLLM server on a RunPod GPU pod over a Tailscale mesh
    address. Resumes the pod on demand, waits for the model to warm, streams
    OpenAI-compatible chunks back, and lets the pod's own idle watchdog handle
    shutdown. No prompt content is logged anywhere in this module.
requirements: httpx
"""
# ===========================================================================
#  GENERATED FILE -- DO NOT EDIT
#
#  Built by openwebui/build_pipe.py from:
#      openwebui/runpod_core.py     wake / validate / poll / stream
#      openwebui/pipe_wrapper.py    Open WebUI presentation layer
#
#  Edit those files and re-run:  python3 openwebui/build_pipe.py
#  Editing this file directly means your change is lost on the next build.
#
#  This concatenation exists because Open WebUI functions are pasted as a
#  single file and cannot import sibling modules.
# ===========================================================================
# ---------------------------------------------------------------------------
# FILE: openwebui/runpod_core.py
# PURPOSE (plain English):
#   Everything needed to talk to a vLLM server on an on-demand RunPod GPU pod,
#   with NO dependency on Open WebUI.
#
#   This file knows how to:
#     1. VALIDATE  -- confirm a destination is inside the Tailscale mesh, and
#        refuse to transmit if it is not.
#     2. WAKE      -- ask RunPod to resume a pod that is normally switched off.
#     3. POLL      -- wait until vLLM reports the model is loaded and ready.
#     4. STREAM    -- send a chat-completions request and yield events.
#
#   It knows nothing about chat windows, model dropdowns, valves, or status
#   emitters. That separation is deliberate.
#
# WHY THIS FILE EXISTS SEPARATELY:
#   This logic has one consumer today (the Open WebUI pipe) and will soon have
#   two: a waking shim that fronts every RunPod endpoint so other tools can
#   reach a pod that is currently stopped.
#
#   If it stayed tangled with the Open WebUI Pipe class, building that shim
#   would mean rewriting it -- and then maintaining two implementations of pod
#   lifecycle that drift apart.
#
#   THE RULE: nothing in this file may import or reference Open WebUI, pydantic
#   valves, or event emitters. Progress is reported through the on_status
#   callback, which any caller can implement however it likes.
#
# HOW IT IS DEPLOYED:
#   Open WebUI functions are pasted into the UI as a SINGLE file, so a pipe
#   cannot import this module at runtime. build_pipe.py concatenates this file
#   with pipe_wrapper.py to produce the pasteable runpod_pipe.py.
#
# PRIVACY:
#   Prompts travel only over Tailscale (100.x.x.x, WireGuard-encrypted). Every
#   log line here is metadata only -- timings, status, HTTP codes, counts.
#   Never add message content to a log line.
# ---------------------------------------------------------------------------
from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import time
from dataclasses import dataclass
from typing import Any, AsyncGenerator, Awaitable, Callable, Dict, List, Optional

import httpx

# RunPod's control API. Used to start and query pods -- never to send prompts.
RUNPOD_GRAPHQL = "https://api.runpod.io/graphql"

# Credential shapes that must never reach a chat window or a log line, even
# inside an exception message. Some libraries helpfully include the full
# request (headers and all) in their error text.
_SECRET_PATTERNS = [
    re.compile(r"rpa_[A-Za-z0-9]+"),                    # RunPod API key
    re.compile(r"tskey-[A-Za-z0-9\-]+"),                # Tailscale auth key
    # Authorization headers. The optional "Bearer " must be consumed TOGETHER
    # with the token that follows it. An earlier version of this pattern ended
    # at \S+, which matched the word "Bearer" and stopped -- leaving the actual
    # credential in the string. Order matters: this must precede the bare rule.
    re.compile(r"(?i)authorization\s*[:=]\s*(bearer\s+)?\S+"),
    re.compile(r"(?i)bearer\s+\S+"),
    re.compile(r"(?i)api[_-]?key\s*[:=]\s*\S+"),
]


def scrub(text: str) -> str:
    """Replace anything credential-shaped with [REDACTED]."""
    for pattern in _SECRET_PATTERNS:
        text = pattern.sub("[REDACTED]", text)
    return text


# ---------------------------------------------------------------------------
# OUTCOME LOGGING
#   Every request ends in exactly one of three states, and all three are
#   recorded: success, degraded (partial answer), failure. Without this, a
#   report of "it was slow yesterday" leaves nothing to investigate -- the chat
#   UI keeps no record of why a request behaved the way it did.
#
#   PRIVACY: metadata only -- durations, counts, state names, HTTP codes.
#   Never log message content. Every value additionally passes through scrub()
#   as a second line of defence, in case an exception carries a credential.
# ---------------------------------------------------------------------------
logger = logging.getLogger("hybrid_ai.runpod_core")
if not logger.handlers:
    _handler = logging.StreamHandler()
    _handler.setFormatter(
        logging.Formatter("%(asctime)s %(levelname)s [runpod_core] %(message)s")
    )
    logger.addHandler(_handler)
    logger.setLevel(os.getenv("PIPE_LOG_LEVEL", "INFO").upper())
    # Do not also hand these records to the root logger, which may be
    # configured more verbosely than we want for something on a privacy path.
    logger.propagate = False


def log_event(level: int, event: str, **fields: Any) -> None:
    """Emit one structured, metadata-only line: event=<name> key=value ..."""
    parts = [f"event={event}"]
    for key, value in fields.items():
        parts.append(f"{key}={scrub(str(value))}")
    logger.log(level, " ".join(parts))


# ---------------------------------------------------------------------------
# CONFIGURATION
#   A plain dataclass, not a pydantic model. The Open WebUI wrapper builds one
#   from its Valves; a shim would build one per endpoint from its own config.
#   Neither framework's types leak in here.
# ---------------------------------------------------------------------------
@dataclass
class EndpointConfig:
    """Everything needed to reach one RunPod vLLM endpoint."""

    runpod_api_key: str = ""
    runpod_pod_id: str = ""
    runpod_host: str = ""
    vllm_port: int = 8000
    model_name: str = ""
    # Peer hostname this endpoint registers under on the tailnet. Used only to
    # make error messages actionable.
    peer_hostname: str = "runpod-worker"
    warmup_timeout: int = 600
    poll_interval: float = 5.0
    request_timeout: int = 900
    max_tokens: int = 4096
    # Refuse to send prompts to any address outside 100.64.0.0/10.
    enforce_mesh_only: bool = True


# Progress callback. Any caller implements this however it likes: the pipe
# forwards to Open WebUI's event emitter, a shim would log or update state.
StatusCallback = Callable[[str, bool], Awaitable[None]]


async def _noop_status(_description: str, _done: bool = False) -> None:
    """Default callback for callers that do not care about progress."""
    return None


def is_mesh_address(ip: str) -> bool:
    """
    Return True only if the address is inside 100.64.0.0/10, the range
    Tailscale uses for private mesh addresses.

    WHY THIS MATTERS: if the address were ever wrong -- a typo, a stale value,
    a pasted public address -- prompts would cross the open internet
    unencrypted. This check makes that impossible.

    The range covers 100.64.x.x through 100.127.x.x.

    Parsing is deliberately strict. int() accepts surrounding whitespace and a
    leading sign, so "  100.64.0.1" and "+100.64.0.1" would otherwise pass and
    then be used to build a URL -- a value that LOOKED validated but was never
    really the address we thought it was. On a control whose entire job is
    keeping prompts inside the tunnel, permissive parsing is not a kindness.
    """
    parts = ip.split(".")
    if len(parts) != 4:
        return False
    if not all(p.isdigit() for p in parts):
        return False
    try:
        octets = [int(p) for p in parts]
    except ValueError:
        return False
    if any(o < 0 or o > 255 for o in octets):
        return False
    return octets[0] == 100 and 64 <= octets[1] <= 127


class RunPodEndpoint:
    """
    One on-demand vLLM endpoint on a RunPod GPU pod.

    Framework-agnostic. Owns validation, wake, readiness polling, and
    streaming. Shutdown is NOT handled here -- the pod turns itself off via the
    idle watchdog in runpod/start.sh.
    """

    def __init__(self, config: EndpointConfig) -> None:
        self.config = config

        # After a successful readiness check we skip re-checking for 60
        # seconds, avoiding a pointless round trip on every message during an
        # active conversation.
        self._warm_until: float = 0.0

        # AVAILABILITY: if two callers arrive at once, both would try to resume
        # the pod and both would poll. A lock serialises the wake-and-warm
        # phase so only one does the work; the second waits, then finds it warm.
        #
        # Created lazily rather than here, because an asyncio primitive binds to
        # the event loop it is first used on. A host may construct this object
        # once and serve it from a different loop, producing intermittent
        # "attached to a different loop" errors that are horrible to diagnose.
        self._wake_lock: Optional[asyncio.Lock] = None
        self._wake_lock_loop: Any = None

    # -- Helpers -------------------------------------------------------------

    def _get_wake_lock(self) -> asyncio.Lock:
        """Return a lock belonging to the currently running event loop."""
        try:
            loop = asyncio.get_running_loop()
        except RuntimeError:
            loop = None
        if self._wake_lock is None or self._wake_lock_loop is not loop:
            self._wake_lock = asyncio.Lock()
            self._wake_lock_loop = loop
        return self._wake_lock

    @property
    def base_url(self) -> str:
        """Root URL of the vLLM server, e.g. http://runpod-worker.tailXXXX.ts.net:8000"""
        return f"http://{self.config.runpod_host}:{self.config.vllm_port}"

    def preflight(self) -> Optional[str]:
        """
        Check configuration before doing anything.

        Returns an error message if something is wrong, or None if all is well.
        Callers should run this first so problems surface as a readable message
        instead of a stack trace.
        """
        c = self.config
        if not c.runpod_api_key:
            return "RUNPOD_API_KEY is not set. Re-run ./install.sh on the Pi."
        if not c.runpod_pod_id:
            return "RUNPOD_POD_ID is not set. Re-run ./install.sh on the Pi."
        if not c.runpod_host:
            return (
                "RUNPOD_HOST is empty. The pod has not registered on the tailnet yet. "
                "Start it once manually, then re-run ./install.sh to discover the peer."
            )

        # Validate numeric bounds. These come from environment variables, which
        # on a misconfigured host could be absent, zero, or absurd. A zero
        # poll_interval would busy-loop; an unbounded max_tokens would let one
        # request hold the GPU -- and the billing meter -- open indefinitely.
        if not (1 <= c.warmup_timeout <= 3600):
            return f"WARMUP_TIMEOUT must be between 1 and 3600 (got {c.warmup_timeout})."
        if not (0.5 <= c.poll_interval <= 60):
            return f"POLL_INTERVAL must be between 0.5 and 60 (got {c.poll_interval})."
        if not (1 <= c.max_tokens <= 32768):
            return f"MAX_TOKENS must be between 1 and 32768 (got {c.max_tokens})."
        if not (1 <= c.vllm_port <= 65535):
            return f"VLLM_PORT must be a valid port (got {c.vllm_port})."

        # SECURITY: validated here, at the point of use, rather than only at
        # install time. The address is resolved from live tailnet state.
        if c.enforce_mesh_only:
            is_secure = is_mesh_address(c.runpod_host) or c.runpod_host.endswith(".ts.net")
            if not is_secure:
                return (
                    f"Refusing to transmit: {c.runpod_host} is outside the Tailscale mesh. "
                    f"Prompts would leave the encrypted tunnel. "
                    f"Fix RUNPOD_HOST, or disable ENFORCE_MESH_ONLY if this is intentional."
                )
        return None

    # -- RunPod control plane ------------------------------------------------

    async def _graphql(
        self, client: httpx.AsyncClient, query: str, variables: dict
    ) -> dict:
        """
        Send one GraphQL request to RunPod and return its "data" section.

        GraphQL returns errors with a 200 OK status inside an "errors" key, so
        we check for that explicitly rather than trusting the HTTP status alone.

        SECURITY: the API key goes in an Authorization header, NOT a ?api_key=
        query parameter. RunPod's docs show the query-string form, but
        credentials in URLs are written into proxy logs, server access logs,
        and Referer headers. Headers are not logged by default.

        AVAILABILITY: transient transport failures and 5xx/429 responses are
        retried with exponential backoff. 4xx responses other than 429 are NOT
        retried -- a bad key or unknown pod id fails identically every time,
        and retrying only delays a clear error message.
        """
        last_exc: Optional[Exception] = None
        for attempt in range(1, 4):
            try:
                resp = await client.post(
                    RUNPOD_GRAPHQL,
                    json={"query": query, "variables": variables},
                    headers={
                        "Content-Type": "application/json",
                        "Authorization": f"Bearer {self.config.runpod_api_key}",
                    },
                    timeout=30.0,
                )
                if resp.status_code == 429 or resp.status_code >= 500:
                    if attempt < 3:
                        log_event(
                            logging.WARNING, "runpod_api_retry",
                            attempt=attempt, status=resp.status_code,
                        )
                        await asyncio.sleep(2 ** attempt)
                        continue
                resp.raise_for_status()
                payload = resp.json()
                if payload.get("errors"):
                    msgs = "; ".join(
                        e.get("message", "unknown") for e in payload["errors"]
                    )
                    raise RuntimeError(f"RunPod API error: {msgs}")
                return payload.get("data") or {}
            except (httpx.ConnectError, httpx.ConnectTimeout, httpx.ReadTimeout) as exc:
                last_exc = exc
                if attempt < 3:
                    log_event(
                        logging.WARNING, "runpod_api_retry",
                        attempt=attempt, reason=type(exc).__name__,
                    )
                    await asyncio.sleep(2 ** attempt)
                    continue
                raise

        if last_exc:
            raise last_exc
        raise RuntimeError("RunPod API unreachable after 3 attempts.")

    async def pod_status(self, client: httpx.AsyncClient) -> str:
        """
        Ask RunPod whether the pod is RUNNING, EXITED, etc.

        Returns "UNKNOWN" on any failure -- we would rather attempt a resume
        that turns out to be unnecessary than refuse to try.
        """
        query = """
        query pod($input: PodFilter) {
          pod(input: $input) { id desiredStatus runtime { uptimeInSeconds } }
        }
        """
        try:
            data = await self._graphql(
                client, query, {"input": {"podId": self.config.runpod_pod_id}}
            )
            pod = data.get("pod") or {}
            return pod.get("desiredStatus") or "UNKNOWN"
        except Exception:
            return "UNKNOWN"

    async def start_pod(
        self,
        client: httpx.AsyncClient,
        on_status: StatusCallback = _noop_status,
    ) -> None:
        """
        Resume the pod if it is not already running. Safe to call every time --
        if the pod is already up, this returns immediately.
        """
        status = await self.pod_status(client)
        if status == "RUNNING":
            await on_status("Pod already running - checking model...", False)
            return

        await on_status(f"Pod is {status} - sending resume request...", False)

        mutation = """
        mutation resume($input: PodResumeInput!) {
          podResume(input: $input) { id desiredStatus imageName }
        }
        """
        # gpuCount is required by RunPod's schema. 1 matches the single-GPU
        # default; multi-GPU pods resume with their own configured count
        # regardless of what we pass.
        variables = {"input": {"podId": self.config.runpod_pod_id, "gpuCount": 1}}

        try:
            data = await self._graphql(client, mutation, variables)
            new_status = (data.get("podResume") or {}).get("desiredStatus", "?")
            await on_status(f"Resume accepted (status: {new_status}).", False)
        except RuntimeError as exc:
            # If the pod was already starting, RunPod rejects the resume.
            # Harmless -- carry on to the readiness check.
            if "already" in str(exc).lower():
                await on_status("Pod was already starting.", False)
                return
            raise

    async def wait_for_vllm(
        self,
        client: httpx.AsyncClient,
        on_status: StatusCallback = _noop_status,
    ) -> None:
        """
        Poll /v1/models until vLLM reports the model is loaded.

        Connection errors during this loop are normal and expected: the pod is
        still booting and nothing is listening yet. We only give up once
        warmup_timeout seconds have elapsed.

        NOTE: we poll the MODEL LISTING, not the TCP port. A listening socket is
        not a loaded model, and treating it as one converts a clean "still
        warming up" wait into a confusing mid-stream failure minutes later.
        """
        if time.monotonic() < self._warm_until:
            return  # confirmed ready less than 60 seconds ago

        # time.monotonic() only ever moves forward. Unlike wall-clock time it
        # cannot jump if the system clock is adjusted, which makes it the
        # correct choice for measuring elapsed time.
        deadline = time.monotonic() + self.config.warmup_timeout
        probe_url = f"{self.base_url}/v1/models"
        attempt = 0

        while time.monotonic() < deadline:
            attempt += 1
            elapsed = int(
                self.config.warmup_timeout - (deadline - time.monotonic())
            )
            try:
                resp = await client.get(probe_url, timeout=10.0)
                if resp.status_code == 200:
                    body = resp.json()
                    served = [m.get("id") for m in body.get("data", [])]
                    if served:
                        self._warm_until = time.monotonic() + 60.0
                        await on_status(
                            f"Model ready after {elapsed}s - streaming...", True
                        )
                        return
            except (httpx.ConnectError, httpx.ConnectTimeout, httpx.ReadTimeout):
                pass  # expected while the pod boots and weights load
            except Exception:
                pass

            await on_status(
                f"Waiting for vLLM to load weights... {elapsed}s elapsed "
                f"(probe #{attempt})",
                False,
            )
            await asyncio.sleep(self.config.poll_interval)

        raise TimeoutError(
            f"vLLM did not become ready within {self.config.warmup_timeout}s at "
            f"{probe_url}. Check that the pod started, joined the tailnet as "
            f"'{self.config.peer_hostname}', and that start.sh did not exit early."
        )

    def invalidate_warm_cache(self) -> None:
        """
        Forget that the endpoint was recently confirmed ready.

        AVAILABILITY: callers must do this on any wake/warm failure. A stale
        warm flag would make the next request skip the readiness probe and fail
        immediately against a pod that is not actually up.
        """
        self._warm_until = 0.0

    async def ensure_ready(
        self,
        client: httpx.AsyncClient,
        on_status: StatusCallback = _noop_status,
    ) -> float:
        """
        Wake the pod if needed and block until the model is serving.

        Returns seconds spent waking. Serialised so concurrent callers do not
        both resume the same pod -- the second waits here, then finds it warm.
        """
        async with self._get_wake_lock():
            await on_status("Contacting RunPod control plane...", False)
            wake_started = time.monotonic()
            try:
                await self.start_pod(client, on_status)
                await self.wait_for_vllm(client, on_status)
            except Exception:
                self.invalidate_warm_cache()
                raise
            return round(time.monotonic() - wake_started, 1)

    # -- Inference -----------------------------------------------------------

    def build_payload(
        self, messages: List[Dict[str, Any]], options: Dict[str, Any]
    ) -> Dict[str, Any]:
        """
        Build an OpenAI chat-completions request body, which vLLM understands
        natively.

        Client-supplied max_tokens is never trusted above our own ceiling: an
        oversized value holds the GPU, and the billing meter, open.
        """
        try:
            requested = int(options.get("max_tokens") or self.config.max_tokens)
        except (TypeError, ValueError):
            requested = self.config.max_tokens
        effective = max(1, min(requested, self.config.max_tokens))

        payload: Dict[str, Any] = {
            "model": self.config.model_name,
            "messages": messages,
            "stream": True,
            "max_tokens": effective,
            "temperature": options.get("temperature", 0.7),
            "top_p": options.get("top_p", 0.9),
        }
        # Pass through optional tuning parameters only if the caller supplied them.
        for opt in ("frequency_penalty", "presence_penalty", "stop", "seed"):
            if options.get(opt) is not None:
                payload[opt] = options[opt]
        return payload

    def timeout(self) -> httpx.Timeout:
        """
        Separate timeouts per phase. "read" is generous because generating a
        long answer legitimately takes minutes.
        """
        return httpx.Timeout(
            connect=15.0,
            read=float(self.config.request_timeout),
            write=30.0,
            pool=15.0,
        )

    def client(self) -> httpx.AsyncClient:
        """
        Build an HTTP client for this endpoint.

        SECURITY: trust_env=False ignores HTTP_PROXY and friends. A stray proxy
        setting could silently reroute prompts somewhere we did not intend, so
        we refuse to honour them at all.
        """
        return httpx.AsyncClient(timeout=self.timeout(), trust_env=False)

    async def stream_completion(
        self,
        client: httpx.AsyncClient,
        payload: Dict[str, Any],
    ) -> AsyncGenerator[Dict[str, Any], None]:
        """
        Stream a chat completion, yielding STRUCTURED EVENTS rather than raw
        text. Callers decide how to render them.

        Event shapes:
            {"type": "error",   "status": int, "detail": str}
            {"type": "content", "text": str}
            {"type": "done",    "saw_done": bool, "chunks": int,
             "malformed": int, "finish_reason": str | None}

        Yielding events rather than strings is what keeps this reusable: the
        Open WebUI pipe renders them as markdown, while a shim would re-emit
        them as server-sent events.
        """
        chunks = 0        # content fragments delivered
        malformed = 0     # chunks that failed to parse
        saw_done = False  # did the server send its end-of-stream marker
        finish_reason: Optional[str] = None

        async with client.stream(
            "POST",
            f"{self.base_url}/v1/chat/completions",
            json=payload,
            headers={
                "Content-Type": "application/json",
                "Accept": "text/event-stream",
            },
        ) as response:
            if response.status_code != 200:
                # SECURITY: do not echo the raw upstream body onward. Error
                # bodies routinely contain internal paths, library versions,
                # and occasionally fragments of the request. Surface the status
                # code and a short, scrubbed excerpt only.
                raw = await response.aread()
                detail = scrub(raw.decode("utf-8", errors="replace"))[:200]
                yield {
                    "type": "error",
                    "status": response.status_code,
                    "detail": detail,
                }
                return

            # Server-Sent Events: every line looks like
            #   data: {...json...}
            # and the stream finishes with the literal  data: [DONE]
            async for line in response.aiter_lines():
                if not line or not line.startswith("data: "):
                    continue
                data = line[6:].strip()

                if data == "[DONE]":
                    saw_done = True
                    break

                try:
                    chunk = json.loads(data)
                except json.JSONDecodeError:
                    malformed += 1
                    continue  # skip a malformed chunk rather than dying

                choices = chunk.get("choices") or []
                if not choices:
                    continue

                # finish_reason tells us HOW generation ended. "length" means it
                # hit the token ceiling and was cut off -- the caller deserves
                # to know that rather than silently receiving a truncated answer.
                if choices[0].get("finish_reason"):
                    finish_reason = choices[0]["finish_reason"]

                delta = choices[0].get("delta") or {}
                content = delta.get("content")
                if content:
                    chunks += 1
                    yield {"type": "content", "text": content}

        yield {
            "type": "done",
            "saw_done": saw_done,
            "chunks": chunks,
            "malformed": malformed,
            "finish_reason": finish_reason,
        }


# -------------------------------------------------------------------------
# OPEN WEBUI PRESENTATION LAYER  (from pipe_wrapper.py)
# -------------------------------------------------------------------------
# --- imports used only by the wrapper --------------------------------------
# (runpod_core.py, prepended by build_pipe.py, supplies asyncio, logging, os,
#  time, httpx, the typing names, and its own helpers.)
import uuid

from pydantic import BaseModel, Field


class Pipe:
    """On-demand RunPod vLLM backend for Open WebUI."""

    class Valves(BaseModel):
        """
        Settings you can change from the Open WebUI settings panel.

        Each default reads from an environment variable first, falling back to
        a hardcoded value. Those variables come from the .env that install.sh
        generated on the Pi, passed in by docker-compose.yml. In short: you
        should not need to edit this file to configure it.
        """

        RUNPOD_API_KEY: str = Field(
            default=os.getenv("RUNPOD_API_KEY", ""),
            description="RunPod API key. Used for podResume / status queries only.",
        )
        RUNPOD_POD_ID: str = Field(
            default=os.getenv("RUNPOD_POD_ID", ""),
            description="Target RunPod pod ID.",
        )
        RUNPOD_HOST: str = Field(
            default=os.getenv("RUNPOD_HOST", ""),
            description="MagicDNS hostname of the pod. Resolved by install.sh.",
        )
        PEER_HOSTNAME: str = Field(
            default=os.getenv("PEER_HOSTNAME", "runpod-worker"),
            description="Tailnet hostname of the pod. Used in error messages.",
        )
        VLLM_PORT: int = Field(
            default=int(os.getenv("VLLM_PORT", "8000")),
            description="Port vLLM listens on inside the pod.",
        )
        MODEL_NAME: str = Field(
            default=os.getenv("VLLM_MODEL_NAME", "Qwen/Qwen2.5-Coder-32B-Instruct-AWQ"),
            description="Model identifier as served by vLLM.",
        )
        MODEL_DISPLAY_NAME: str = Field(
            default=os.getenv("VLLM_DISPLAY_NAME", "Qwen2.5-Coder-32B (RunPod)"),
            description="Label shown in the Open WebUI model picker.",
        )
        WARMUP_TIMEOUT: int = Field(
            default=int(os.getenv("POD_WARMUP_TIMEOUT", "600")),
            description="Seconds to wait for the readiness probe before failing.",
        )
        POLL_INTERVAL: float = Field(
            default=5.0, description="Seconds between readiness probes."
        )
        REQUEST_TIMEOUT: int = Field(
            default=int(os.getenv("VLLM_REQUEST_TIMEOUT", "900")),
            description="Read timeout for a single completion stream.",
        )
        MAX_TOKENS: int = Field(
            default=int(os.getenv("VLLM_MAX_TOKENS", "4096")),
            description="Default completion cap when the client sends none.",
        )
        EMIT_STATUS: bool = Field(
            default=True, description="Show wake/warm progress in the chat UI."
        )
        ENFORCE_MESH_ONLY: bool = Field(
            default=True,
            description="Refuse to send prompts to any address outside 100.64.0.0/10.",
        )

    def __init__(self) -> None:
        # "manifold" tells Open WebUI this pipe can offer one or more models in
        # the dropdown, rather than being a single fixed endpoint.
        self.type = "manifold"
        self.id = "runpod_vllm"
        self.name = "runpod/"
        self.valves = self.Valves()

        # The endpoint's config is refreshed per request from current Valves, so
        # changes in the settings panel take effect without restarting Open
        # WebUI. The warm-cache and wake-lock live on it, so we keep ONE
        # instance and refresh its config rather than constructing a new one.
        self._endpoint = RunPodEndpoint(self._config())

    # -- Configuration -------------------------------------------------------

    def _config(self) -> EndpointConfig:
        """Translate Open WebUI Valves into a framework-agnostic config."""
        v = self.valves
        return EndpointConfig(
            runpod_api_key=v.RUNPOD_API_KEY,
            runpod_pod_id=v.RUNPOD_POD_ID,
            runpod_host=v.RUNPOD_HOST,
            vllm_port=v.VLLM_PORT,
            model_name=v.MODEL_NAME,
            peer_hostname=v.PEER_HOSTNAME,
            warmup_timeout=v.WARMUP_TIMEOUT,
            poll_interval=v.POLL_INTERVAL,
            request_timeout=v.REQUEST_TIMEOUT,
            max_tokens=v.MAX_TOKENS,
            enforce_mesh_only=v.ENFORCE_MESH_ONLY,
        )

    # -- Open WebUI model registration --------------------------------------

    def pipes(self) -> List[Dict[str, str]]:
        """Open WebUI calls this to ask which models to show in the dropdown."""
        return [{"id": "vllm-cloud", "name": self.valves.MODEL_DISPLAY_NAME}]

    # -- Presentation --------------------------------------------------------

    def _status_callback(
        self, emitter: Optional[Callable[[dict], Awaitable[None]]]
    ) -> StatusCallback:
        """
        Adapt Open WebUI's event emitter to the core's StatusCallback shape.

        Wrapped in try/except because a cosmetic status update must never crash
        an in-flight response.
        """

        async def _emit(description: str, done: bool = False) -> None:
            if emitter and self.valves.EMIT_STATUS:
                try:
                    await emitter(
                        {
                            "type": "status",
                            "data": {"description": description, "done": done},
                        }
                    )
                except Exception:
                    pass

        return _emit

    # -- Main entrypoint -----------------------------------------------------

    async def pipe(
        self,
        body: Dict[str, Any],
        __event_emitter__: Optional[Callable[[dict], Awaitable[None]]] = None,
        **kwargs: Any,
    ) -> AsyncGenerator[str, None]:
        """
        The function Open WebUI calls for every message sent to this model.

        "body" holds the conversation and settings. The double-underscore
        argument is injected by Open WebUI and lets us push status updates.

        This is an async generator: instead of returning once at the end, it
        yields pieces of text as they arrive, producing the typewriter effect.
        """
        emit = self._status_callback(__event_emitter__)

        # Pick up any Valves changes made since the last request.
        self._endpoint.config = self._config()
        endpoint = self._endpoint

        # Correlation id: ties a "it failed at 3pm" report to exact log lines.
        # Short random hex, no user data.
        req_id = uuid.uuid4().hex[:8]
        started = time.monotonic()
        chunks = 0

        # -- Step 1: validate configuration before touching the network ------
        config_error = endpoint.preflight()
        if config_error:
            # WARNING, not ERROR: a misconfiguration to fix, not a system fault.
            log_event(
                logging.WARNING, "request_rejected",
                request_id=req_id, reason="preflight_failed",
                detail=config_error[:120],
            )
            yield f"**Configuration error**\n\n{config_error}"
            return

        messages = body.get("messages", [])
        if not messages:
            log_event(
                logging.WARNING, "request_rejected",
                request_id=req_id, reason="empty_messages",
            )
            yield "**Error**: no messages in request body."
            return

        payload = endpoint.build_payload(messages, body)

        # Metadata only: how many turns, not what is in them.
        log_event(
            logging.INFO, "request_started", request_id=req_id,
            message_count=len(messages), max_tokens=payload["max_tokens"],
        )

        try:
            async with endpoint.client() as client:
                # -- Steps 2 and 3: wake, then wait ---------------------------
                wake_seconds = await endpoint.ensure_ready(client, emit)
                log_event(
                    logging.INFO, "pod_ready",
                    request_id=req_id, wake_seconds=wake_seconds,
                )

                # -- Step 4: stream the answer -------------------------------
                async for event in endpoint.stream_completion(client, payload):
                    if event["type"] == "content":
                        chunks += 1
                        yield event["text"]

                    elif event["type"] == "error":
                        yield (
                            f"\n\n**vLLM returned HTTP {event['status']}**\n\n"
                            f"```\n{event['detail']}\n```\n\n"
                            f"Full detail is in the pod's logs in the RunPod console."
                        )
                        return

                    elif event["type"] == "done":
                        # --- Classify the outcome ---------------------------
                        # A stream that ends without [DONE] was cut short: the
                        # pod was stopped, the tunnel dropped, or the server
                        # died. Without this check that looks identical to
                        # success from the user's side.
                        duration = round(time.monotonic() - started, 1)

                        if not event["saw_done"]:
                            log_event(
                                logging.WARNING, "request_degraded",
                                request_id=req_id, reason="stream_incomplete",
                                chunks=event["chunks"],
                                malformed_chunks=event["malformed"],
                                duration_s=duration,
                            )
                            await emit("Stream ended unexpectedly.", True)
                            yield (
                                "\n\n---\n**Warning: this response is incomplete.** The "
                                "connection to the pod closed before the model finished. "
                                "The pod may have been stopped mid-generation. Resend to retry."
                            )

                        elif event["finish_reason"] == "length":
                            log_event(
                                logging.INFO, "request_truncated",
                                request_id=req_id, reason="max_tokens",
                                chunks=event["chunks"], duration_s=duration,
                            )
                            await emit("Complete (hit token limit).", True)
                            yield (
                                "\n\n---\n*Response reached the token limit and was cut "
                                "off. Raise `MAX_TOKENS` in the function's Valves for "
                                "longer answers.*"
                            )

                        else:
                            log_event(
                                logging.INFO, "request_success",
                                request_id=req_id, chunks=event["chunks"],
                                malformed_chunks=event["malformed"],
                                finish_reason=event["finish_reason"] or "stop",
                                duration_s=duration,
                            )
                            await emit("Complete.", True)

        # -- Error handling ---------------------------------------------------
        # Each case produces a specific, actionable message in the chat window.
        # A junior developer -- or you at 6am -- should be able to read it and
        # know exactly what to go and check.

        except TimeoutError as exc:
            log_event(
                logging.ERROR, "request_failed", request_id=req_id,
                reason="warmup_timeout", chunks=chunks,
                duration_s=round(time.monotonic() - started, 1),
            )
            await emit("Warm-up timed out.", True)
            yield f"\n\n**Pod warm-up timed out**\n\n{exc}"

        except httpx.ConnectError as exc:
            log_event(
                logging.ERROR, "request_failed", request_id=req_id,
                reason="connect_error", chunks=chunks,
                duration_s=round(time.monotonic() - started, 1),
            )
            await emit("Connection failed.", True)
            yield (
                f"\n\n**Cannot reach the inference pod** at `{endpoint.base_url}`.\n\n"
                f"The tailnet route is likely down. Verify with "
                f"`tailscale status | grep {self.valves.PEER_HOSTNAME}` on the Pi - if "
                f"the peer is missing entirely, the pod's ephemeral node was reaped and "
                f"`RUNPOD_HOST` needs refreshing via `./install.sh`.\n\n"
                f"```\n{scrub(str(exc))[:300]}\n```"
            )

        except httpx.ReadTimeout:
            # Partial output may already have reached the user, so this is a
            # degraded outcome rather than a clean failure.
            log_event(
                logging.ERROR, "request_failed", request_id=req_id,
                reason="read_timeout", chunks=chunks,
                partial_output=chunks > 0,
                duration_s=round(time.monotonic() - started, 1),
            )
            await emit("Stream timed out.", True)
            yield (
                f"\n\n**Stream timed out** after {self.valves.REQUEST_TIMEOUT}s. "
                f"The pod may have been stopped mid-generation, or the request "
                f"exceeded the read timeout. Raise `REQUEST_TIMEOUT` in the Valves "
                f"if long generations are expected."
            )

        except RuntimeError as exc:
            log_event(
                logging.ERROR, "request_failed", request_id=req_id,
                reason="runpod_api_error", chunks=chunks,
                duration_s=round(time.monotonic() - started, 1),
            )
            await emit("RunPod API error.", True)
            yield (
                f"\n\n**RunPod control plane error**\n\n"
                f"```\n{scrub(str(exc))[:300]}\n```"
            )

        except httpx.HTTPStatusError as exc:
            log_event(
                logging.ERROR, "request_failed", request_id=req_id,
                reason="http_status_error",
                status=exc.response.status_code, chunks=chunks,
                duration_s=round(time.monotonic() - started, 1),
            )
            await emit("HTTP error.", True)
            yield (
                f"\n\n**HTTP {exc.response.status_code} from RunPod**\n\n"
                f"Check that `RUNPOD_API_KEY` is valid and scoped to this pod."
            )

        except asyncio.CancelledError:
            # The user hit stop, or Open WebUI tore the request down. Not an
            # error -- record it and re-raise so cancellation still propagates
            # correctly rather than being swallowed.
            log_event(
                logging.INFO, "request_cancelled", request_id=req_id,
                chunks=chunks,
                duration_s=round(time.monotonic() - started, 1),
            )
            raise

        except Exception as exc:  # last-resort guard so nothing escapes silently
            log_event(
                logging.ERROR, "request_failed", request_id=req_id,
                reason="unexpected", exc_type=type(exc).__name__,
                chunks=chunks,
                duration_s=round(time.monotonic() - started, 1),
            )
            await emit("Unexpected failure.", True)
            yield (
                f"\n\n**Unexpected error** (`{type(exc).__name__}`)\n\n"
                f"```\n{scrub(str(exc))[:300]}\n```"
            )
```


## File: openwebui/test_refactor.py
---
Directory: `openwebui`
---
```python
"""
Behavioural checks for the core/wrapper split.

Focus: the security- and availability-critical behaviours that must survive any
change. Run after editing either source file.

    python3 openwebui/test_refactor.py
"""
from __future__ import annotations

import asyncio
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import runpod_core as core

PASS, FAIL = [], []


def check(name: str, condition: bool, detail: str = "") -> None:
    (PASS if condition else FAIL).append(name)
    suffix = f"  -- {detail}" if detail and not condition else ""
    print(f"{'PASS' if condition else 'FAIL'}  {name}{suffix}")


def cfg(**kw):
    base = dict(runpod_api_key="rpa_test", runpod_pod_id="pod123",
                tailscale_ip="100.90.1.5", model_name="test-model")
    base.update(kw)
    return core.EndpointConfig(**base)


print("\n--- mesh address validation (100.64.0.0/10) ---")
for ip, expected in [
    ("100.64.0.1", True), ("100.127.255.255", True), ("100.90.1.5", True),
    ("100.63.255.255", False), ("100.128.0.1", False),
    ("8.8.8.8", False), ("192.168.1.1", False),
    ("100.64.0", False), ("100.64.0.1.1", False),
    ("100.abc.0.1", False), ("", False), ("100.64.0.999", False),
    ("  100.64.0.1", False), ("+100.64.0.1", False),
]:
    check(f"is_mesh_address({ip!r}) == {expected}",
          core.is_mesh_address(ip) is expected)

print("\n--- preflight refuses non-mesh transmission ---")
e = core.RunPodEndpoint(cfg(tailscale_ip="8.8.8.8"))
err = e.preflight()
check("public IP rejected", err is not None and "Refusing to transmit" in err)
check("error names the range", err is not None and "100.64.0.0/10" in err)
check("override allows opt-out",
      core.RunPodEndpoint(cfg(tailscale_ip="8.8.8.8",
                              enforce_mesh_only=False)).preflight() is None)
check("valid mesh IP passes", core.RunPodEndpoint(cfg()).preflight() is None)

print("\n--- preflight bounds ---")
for field, value, word in [
    ("warmup_timeout", 0, "WARMUP_TIMEOUT"), ("warmup_timeout", 3601, "WARMUP_TIMEOUT"),
    ("poll_interval", 0, "POLL_INTERVAL"), ("poll_interval", 61, "POLL_INTERVAL"),
    ("max_tokens", 0, "MAX_TOKENS"), ("max_tokens", 32769, "MAX_TOKENS"),
    ("vllm_port", 0, "VLLM_PORT"), ("vllm_port", 70000, "VLLM_PORT"),
]:
    err = core.RunPodEndpoint(cfg(**{field: value})).preflight()
    check(f"{field}={value} rejected", err is not None and word in err)

for field, word in [("runpod_api_key", "RUNPOD_API_KEY"),
                    ("runpod_pod_id", "RUNPOD_POD_ID"),
                    ("tailscale_ip", "TAILSCALE_IP")]:
    err = core.RunPodEndpoint(cfg(**{field: ""})).preflight()
    check(f"missing {field} rejected", err is not None and word in err)

print("\n--- credential scrubbing ---")
for secret, token, label in [
    ("rpa_abc123XYZ", "rpa_abc123XYZ", "RunPod key"),
    ("tskey-auth-abc123", "tskey-auth-abc123", "Tailscale key"),
    ("Authorization: Bearer sk-xyz123", "sk-xyz123", "auth header token"),
    ("Bearer sk-standalone99", "sk-standalone99", "bare bearer token"),
    ("api_key=supersecret", "supersecret", "api_key"),
    ("API-KEY: hunter2", "hunter2", "API-KEY"),
]:
    out = core.scrub(f"error near {secret} end")
    check(f"scrub redacts {label}", "[REDACTED]" in out and token not in out)

print("\n--- max_tokens clamping (billing protection) ---")
e = core.RunPodEndpoint(cfg(max_tokens=4096))
for requested, expected, label in [
    (999999, 4096, "oversized clamped to ceiling"),
    (100, 100, "smaller value honoured"),
    (None, 4096, "absent uses default"),
    ("garbage", 4096, "non-numeric falls back"),
    (0, 4096, "zero falls back to default"),
    (-5, 1, "negative floored at 1"),
]:
    got = e.build_payload([{"role": "user", "content": "x"}],
                          {"max_tokens": requested})["max_tokens"]
    check(f"{label} ({requested} -> {got})", got == expected, f"expected {expected}")

print("\n--- payload construction ---")
p = e.build_payload([{"role": "user", "content": "hi"}], {})
check("stream always True", p["stream"] is True)
check("model from config", p["model"] == "test-model")
check("optional params omitted when absent", "seed" not in p and "stop" not in p)
p2 = e.build_payload([{"role": "user", "content": "hi"}], {"seed": 42, "stop": ["x"]})
check("optional params passed when present", p2["seed"] == 42 and p2["stop"] == ["x"])

print("\n--- trust_env=False (proxy cannot reroute prompts) ---")
check("client built with trust_env=False",
      core.RunPodEndpoint(cfg()).client().trust_env is False)

print("\n--- warm cache invalidation ---")
e = core.RunPodEndpoint(cfg())
e._warm_until = 9e9
check("warm cache can be set", e._warm_until > 0)
e.invalidate_warm_cache()
check("invalidate_warm_cache resets it", e._warm_until == 0.0)

print("\n--- wake lock rebinds across event loops ---")
async def _get(ep):
    return ep._get_wake_lock()
e = core.RunPodEndpoint(cfg())
check("lock rebuilt for a new loop", asyncio.run(_get(e)) is not asyncio.run(_get(e)))

print("\n--- stream event contract ---")
class FakeStream:
    def __init__(self, lines, status=200):
        self._lines, self.status_code = lines, status
    async def __aenter__(self): return self
    async def __aexit__(self, *a): return False
    async def aiter_lines(self):
        for ln in self._lines: yield ln
    async def aread(self): return b'{"error":"boom"}'

class FakeClient:
    def __init__(self, stream): self._stream = stream
    def stream(self, *a, **k): return self._stream

def sse(text=None, finish=None):
    d = {"choices": [{"delta": {"content": text} if text else {},
                      "finish_reason": finish}]}
    return "data: " + json.dumps(d)

async def collect(lines, status=200):
    ep = core.RunPodEndpoint(cfg())
    return [ev async for ev in ep.stream_completion(FakeClient(FakeStream(lines, status)), {})]

evs = asyncio.run(collect([sse("Hello"), sse(" world"), "data: [DONE]"]))
check("content events yielded in order",
      [x["text"] for x in evs if x["type"] == "content"] == ["Hello", " world"])
check("saw_done True on clean stream", evs[-1]["saw_done"] is True)
check("chunk count correct", evs[-1]["chunks"] == 2)

check("truncated stream flagged saw_done=False",
      asyncio.run(collect([sse("partial")]))[-1]["saw_done"] is False)

evs = asyncio.run(collect([sse("a"), "data: {bad json", sse("b"), "data: [DONE]"]))
check("malformed chunk counted not fatal",
      evs[-1]["malformed"] == 1 and evs[-1]["chunks"] == 2)

check("finish_reason=length propagated",
      asyncio.run(collect([sse("x", finish="length"), "data: [DONE]"]))[-1]["finish_reason"] == "length")

evs = asyncio.run(collect([], status=503))
check("non-200 yields error event", evs[0]["type"] == "error" and evs[0]["status"] == 503)
check("error event has no content events",
      not any(x["type"] == "content" for x in evs))

check("non-SSE lines ignored",
      asyncio.run(collect(["", "noise", sse("ok"), "data: [DONE]"]))[-1]["chunks"] == 1)

print("\n--- core has no Open WebUI / pydantic dependency ---")
# Strip comments first: the core *discusses* pydantic and Valves in its header
# to explain the separation. That is documentation, not coupling.
src = (Path(__file__).resolve().parent / "runpod_core.py").read_text()
code = "\n".join(ln for ln in src.splitlines() if not ln.lstrip().startswith("#"))
for forbidden in ["pydantic", "__event_emitter__", "Valves", "open_webui"]:
    check(f"core code free of {forbidden!r}", forbidden not in code)

print(f"\n{'=' * 60}\n  {len(PASS)} passed, {len(FAIL)} failed")
if FAIL:
    print("  FAILED: " + ", ".join(FAIL))
print("=" * 60)
sys.exit(1 if FAIL else 0)
```


## File: scripts/setup-agent-workspace.sh
---
Directory: `scripts`
---
```bash
#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/setup-agent-workspace.sh
# PURPOSE (plain English):
#   Creates and maintains the SEPARATE clone of this repository that OpenHands
#   works in. Called by install.sh; safe to run by hand at any time.
#
# WHY A SEPARATE CLONE EXISTS (the whole point of this file):
#   OpenHands mounts its workspace read-write and the sandbox runs as YOUR uid.
#   If that workspace were the deployment directory, the sandbox could read:
#
#       .env            RunPod API key, Open WebUI session key
#       install.log     deployment metadata
#       backup.log      backup history
#
#   File permissions would not help. 0600 means "readable by your user", and
#   the sandbox IS your user.
#
#   That matters because the sandbox is the component that processes UNTRUSTED
#   text: log files, diagnostic bundles, issue bodies, repository content.
#   AGENTS.md instructs the agent to treat that text as data rather than
#   instructions -- but an instruction is a mitigation. A clone is a boundary.
#
#   Secondary benefit, unrelated to security: the agent never edits files
#   underneath a running stack. You review, then pull into the deployment
#   directory deliberately.
#
# WHAT IT DOES:
#   1. Works out where the clone should live and where it came from.
#   2. REFUSES to proceed if the target is, or is inside, the deployment dir.
#   3. Creates the clone if missing; updates its origin if it already exists.
#   4. Verifies no .env or log file leaked into it.
#
# HOW TO RUN IT:
#   ./scripts/setup-agent-workspace.sh                    interactive
#   ./scripts/setup-agent-workspace.sh --non-interactive  for CI / install.sh
#   ./scripts/setup-agent-workspace.sh --check            verify only
# ---------------------------------------------------------------------------
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

NON_INTERACTIVE=0
CHECK_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --non-interactive) NON_INTERACTIVE=1 ;;
    --check)           CHECK_ONLY=1 ;;
    -h|--help)
      sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

# --- Output helpers (match install.sh conventions) -------------------------
if [[ -t 1 ]]; then
  C_RST=$'\033[0m'; C_INF=$'\033[36m'; C_OK=$'\033[32m'
  C_WRN=$'\033[33m'; C_ERR=$'\033[31m'
else
  C_RST=""; C_INF=""; C_OK=""; C_WRN=""; C_ERR=""
fi
log()  { printf '%s[ * ]%s %s\n'  "$C_INF" "$C_RST" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_OK"  "$C_RST" "$*"; }
warn() { printf '%s[ ! ]%s %s\n'  "$C_WRN" "$C_RST" "$*" >&2; }
die()  { printf '%s[ X ]%s %s\n'  "$C_ERR" "$C_RST" "$*" >&2; exit 1; }

# --- Work out the target ---------------------------------------------------
# Default: a SIBLING of the deployment directory, never inside it. Inside would
# mean the agent's clone is itself swept up by backups, diagnostics and
# git status -- and .env would sit one directory traversal away.
DEFAULT_WORKSPACE="${HOME}/hybrid-ai-agent"
WORKSPACE="${OPENHANDS_WORKSPACE:-$DEFAULT_WORKSPACE}"

# If .env already names a workspace, honour it -- install.sh writes it there.
#
# SECURITY: parsed line by line, never sourced. `source` executes the file as
# shell code, so a value containing $(...) or backticks would run as a command.
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^OPENHANDS_WORKSPACE=(.*)$ ]] || continue
    candidate="${BASH_REMATCH[1]}"
    candidate="${candidate%\"}"; candidate="${candidate#\"}"
    candidate="${candidate%\'}"; candidate="${candidate#\'}"
    [[ -n "$candidate" ]] && WORKSPACE="$candidate"
  done < "${SCRIPT_DIR}/.env"
  unset line candidate
fi

# Expand a leading ~ ourselves: a value read from a file is not tilde-expanded
# by the shell, and mounting a literal "~/hybrid-ai-agent" directory is a
# genuinely confusing failure to diagnose.
case "$WORKSPACE" in
  "~/"*) WORKSPACE="${HOME}/${WORKSPACE#\~/}" ;;
  "~")   WORKSPACE="${HOME}" ;;
esac

# --- THE CONTROL: workspace must not be the deployment directory -----------
# Everything else in this file is convenience. This is the boundary.
WORKSPACE_REAL="$(readlink -f "$WORKSPACE" 2>/dev/null || echo "$WORKSPACE")"
DEPLOY_REAL="$(readlink -f "$SCRIPT_DIR")"

if [[ "$WORKSPACE_REAL" == "$DEPLOY_REAL" ]]; then
  die "OPENHANDS_WORKSPACE points at the deployment directory (${DEPLOY_REAL}).
     The agent sandbox would be able to read .env and the log files.
     Set it to a separate path, e.g. ${DEFAULT_WORKSPACE}"
fi

case "$WORKSPACE_REAL/" in
  "$DEPLOY_REAL"/*)
    die "OPENHANDS_WORKSPACE is inside the deployment directory.
     Backups, diagnostics and git status would all sweep it up, and .env sits
     one traversal away. Use a sibling path, e.g. ${DEFAULT_WORKSPACE}"
    ;;
esac

# --- Find the origin URL ---------------------------------------------------
ORIGIN_URL=""
if git -C "$SCRIPT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  ORIGIN_URL="$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || true)"
fi

# --- Check mode ------------------------------------------------------------
if (( CHECK_ONLY )); then
  [[ -d "$WORKSPACE/.git" ]] \
    && ok "Agent workspace present: ${WORKSPACE}" \
    || die "Agent workspace missing: ${WORKSPACE}"
  for f in .env .env.local install.log backup.log; do
    [[ -e "$WORKSPACE/$f" ]] \
      && die "SECURITY: ${f} found inside the agent workspace. Remove it."
  done
  ok "No credential files in the agent workspace"
  exit 0
fi

# --- Create or update ------------------------------------------------------
if [[ -d "$WORKSPACE/.git" ]]; then
  ok "Agent workspace already exists: ${WORKSPACE}"
  if [[ -n "$ORIGIN_URL" ]]; then
    current="$(git -C "$WORKSPACE" remote get-url origin 2>/dev/null || true)"
    if [[ "$current" != "$ORIGIN_URL" ]]; then
      log "Updating workspace origin to match this repository"
      git -C "$WORKSPACE" remote set-url origin "$ORIGIN_URL"
    fi
  fi

elif [[ -e "$WORKSPACE" ]]; then
  # Most likely cause: Docker created it as an empty directory on a previous
  # run, because this script was missing or not executable.
  if [[ -d "$WORKSPACE" ]] && [[ -z "$(ls -A "$WORKSPACE" 2>/dev/null)" ]]; then
    log "${WORKSPACE} exists but is empty -- replacing it with a clone."
    rmdir "$WORKSPACE"
  else
    die "${WORKSPACE} exists but is not a git repository, and is not empty.
     Move it aside, or choose another path with OPENHANDS_WORKSPACE."
  fi
fi

if [[ ! -d "$WORKSPACE/.git" ]]; then
  if [[ -z "$ORIGIN_URL" ]]; then
    warn "This directory has no git origin, so the workspace cannot be cloned."
    if (( NON_INTERACTIVE )); then
      die "Push this repository to a remote first, then re-run."
    fi
    read -r -p "    Enter the repository URL to clone: " ORIGIN_URL < /dev/tty
    [[ -n "$ORIGIN_URL" ]] || die "No URL given."
  fi

  log "Cloning into ${WORKSPACE} ..."
  git clone "$ORIGIN_URL" "$WORKSPACE" || die "Clone failed."
  ok "Agent workspace created"
fi

# --- Verify no credentials leaked in --------------------------------------
# A clone should never contain these. If one does, something copied rather
# than cloned, and the isolation this script exists to provide is not real.
LEAKED=0
for f in .env .env.local install.log backup.log; do
  if [[ -e "$WORKSPACE/$f" ]]; then
    warn "SECURITY: ${f} is present in the agent workspace."
    LEAKED=1
  fi
done
if (( LEAKED )); then
  die "Remove those files from ${WORKSPACE} before starting OpenHands.
     Their presence defeats the isolation this workspace provides."
fi
ok "No credential files in the agent workspace"

# --- Report ----------------------------------------------------------------
printf '\n'
ok "Agent workspace ready"
printf '    Workspace : %s\n' "$WORKSPACE_REAL"
printf '    Deployment: %s  (NOT visible to the agent)\n' "$DEPLOY_REAL"
printf '\n'
printf '    The agent branches and commits in the workspace. Review its work,\n'
printf '    then pull into the deployment directory yourself.\n'
```


## File: status/app.py
---
Directory: `status`
---
```python
#!/usr/bin/env python3
"""
FILE: status/app.py
PURPOSE (plain English):
    A small web page at http://<your-pi>/status that shows, at a glance,
    whether everything is working. It displays the state of every service,
    tails recent error logs, and has a button that builds a diagnostic
    bundle you can download and share.

    It is meant for the moment when something is wrong and you do not want to
    SSH in and start typing commands.

WHY THIS IS WRITTEN WITH ONLY THE PYTHON STANDARD LIBRARY:
    No Flask, no FastAPI, no pip install. Fewer dependencies means a smaller
    supply-chain surface and nothing to keep patched. It runs on the stock
    python:3.12-slim image with no build step, which also means no waiting
    for a Docker build on a Raspberry Pi.

SECURITY DESIGN -- please read before modifying:

    1. THIS SERVICE HOLDS NO SECRETS.
       It is deliberately NOT given the .env file, any API key, or any
       credential. It cannot leak what it does not have. If you find yourself
       wanting to add a credential here, reconsider.

    2. IT NEVER READS USER CONTENT.
       Chat databases, uploaded documents and vector stores are measured
       (file sizes, row counts) but never opened for their contents.

    3. IT IS READ-ONLY TOWARDS DOCKER.
       Only HTTP GET requests are issued to the Docker API. There is no code
       path in this file that starts, stops, or changes a container.
       See status/README.md for the important caveat about socket access.

    4. IT SERVES NO FILES FROM DISK.
       There is no static file handler and no user-controlled path is ever
       turned into a filesystem path, so path traversal is not possible.

    5. OUTPUT IS REDACTED ANYWAY.
       Log lines pass through the same redaction patterns as
       collect-diagnostics.sh, as defence in depth, in case a credential
       was written into a log by some upstream component.

    Access control is enforced in front of this service by Caddy, which
    restricts /status to private and Tailscale addresses. This app assumes
    it is never directly exposed to the internet.

ENDPOINTS:
    GET  /status               the HTML page
    GET  /hub                  the hub landing page
    GET  /status/api           the same data as JSON
    POST /status/diagnostic    build a bundle and return it as a download
    GET  /status/healthz       liveness probe for Docker
"""

from __future__ import annotations

import html
import http.client
import json
import os
import re
import socket
import sqlite3
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Dict, List, Optional, Tuple

# --- Configuration (all non-secret) -----------------------------------------
LISTEN_PORT = int(os.getenv("STATUS_PORT", "8088"))
LOCAL_DOMAIN = os.getenv("LOCAL_DOMAIN", "yourhostname.com")
DOCKER_SOCK = os.getenv("DOCKER_SOCKET", "/var/run/docker.sock")

OLLAMA_URL = os.getenv("OLLAMA_URL", "http://ollama:11434")
WEBUI_URL = os.getenv("WEBUI_URL", "http://open-webui:8080")
HERMES_URL = os.getenv("HERMES_URL", "http://hermes-agent:8501")
OPENHANDS_URL = os.getenv("OPENHANDS_URL", "http://openhands:3001")

TAILSCALE_IP = os.getenv("TAILSCALE_IP", "")
VLLM_PORT = os.getenv("VLLM_PORT", "8000")
WEBUI_DATA = os.getenv("WEBUI_DATA_PATH", "/data/webui_data")
BACKUP_LOG = os.getenv("BACKUP_LOG_PATH", "/data/backup.log")
INSTALL_LOG = os.getenv("INSTALL_LOG_PATH", "/data/install.log")

WATCHED = [
    "ollama",
    "open-webui",
    "hermes-agent",
    "hybrid-ai-openhands",
    "hybrid-ai-status",
    "hybrid-ai-proxy",
]

# ---------------------------------------------------------------------------
# Redaction -- mirrors the patterns in collect-diagnostics.sh
# ---------------------------------------------------------------------------
_REDACTIONS: List[Tuple[re.Pattern, str]] = [
    (re.compile(r"rpa_[A-Za-z0-9_-]{8,}"), "<REDACTED:runpod-key>"),
    (re.compile(r"sk-or-v1-[A-Za-z0-9_-]{8,}"), "<REDACTED:openrouter-key>"),
    (re.compile(r"tskey-[A-Za-z0-9_-]{8,}"), "<REDACTED:tailscale-key>"),
    (re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"), "<REDACTED:aws-key-id>"),
    (re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}"), "<REDACTED:github-token>"),
    (re.compile(r"\bey[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"),
     "<REDACTED:jwt>"),
    (re.compile(r"([Bb]earer\s+)[A-Za-z0-9._~+/=-]{12,}"), r"\1<REDACTED:token>"),
    (re.compile(r"([Aa]uthorization:\s*)\S+"), r"\1<REDACTED>"),
    (re.compile(r"((?:api[_-]?key|secret|password|passwd|token)[\"']?\s*[=:]\s*[\"']?)"
                r"[A-Za-z0-9._~+/=-]{8,}", re.I), r"\1<REDACTED>"),
    (re.compile(r"(https?://)[^:@\s/]+:[^@\s]+@"), r"\1<REDACTED:userinfo>@"),
    (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"), "<REDACTED:private-key>"),
    (re.compile(r"\b100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d{1,3}\.(\d{1,3})\b"),
     r"100.x.x.\1"),
    (re.compile(r"\b(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}\b"), "<REDACTED:mac>"),
]


def redact(text: str) -> str:
    """Strip anything credential-shaped. Applied to every log line we emit."""
    for pattern, replacement in _REDACTIONS:
        text = pattern.sub(replacement, text)
    return text


# ---------------------------------------------------------------------------
# Docker API over the unix socket
# ---------------------------------------------------------------------------
class _UnixHTTPConnection(http.client.HTTPConnection):
    def __init__(self, socket_path: str, timeout: float = 5.0):
        super().__init__("localhost", timeout=timeout)
        self._socket_path = socket_path

    def connect(self) -> None:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(self.timeout)
        sock.connect(self._socket_path)
        self.sock = sock


def docker_get(path: str, timeout: float = 5.0) -> Optional[bytes]:
    """Issue a GET against the Docker API. Returns None on any failure."""
    try:
        conn = _UnixHTTPConnection(DOCKER_SOCK, timeout=timeout)
        conn.request("GET", path)
        resp = conn.getresponse()
        if resp.status != 200:
            conn.close()
            return None
        body = resp.read()
        conn.close()
        return body
    except Exception:
        return None


def demux_docker_stream(raw: bytes) -> str:
    out: List[str] = []
    i, n = 0, len(raw)
    while i + 8 <= n:
        size = int.from_bytes(raw[i + 4:i + 8], "big")
        i += 8
        if size <= 0 or i + size > n:
            break
        out.append(raw[i:i + size].decode("utf-8", errors="replace"))
        i += size
    if not out:
        return raw.decode("utf-8", errors="replace")
    return "".join(out)


def container_logs(name: str, tail: int = 40) -> List[str]:
    raw = docker_get(
        f"/containers/{name}/logs?stdout=1&stderr=1&timestamps=0&tail={tail}",
        timeout=8.0,
    )
    if raw is None:
        return []
    text = demux_docker_stream(raw)
    return [redact(line) for line in text.splitlines() if line.strip()]


# ---------------------------------------------------------------------------
# Individual probes
# ---------------------------------------------------------------------------
def probe_http(name: str, url: str, hint: str) -> Dict[str, Any]:
    started = time.monotonic()
    try:
        with urllib.request.urlopen(url, timeout=5) as resp:
            ms = int((time.monotonic() - started) * 1000)
            if resp.status == 200:
                return {"name": name, "state": "ok",
                        "detail": f"responding in {ms} ms", "hint": ""}
            return {"name": name, "state": "warn",
                    "detail": f"HTTP {resp.status}", "hint": hint}
    except Exception as exc:
        return {"name": name, "state": "fail",
                "detail": type(exc).__name__, "hint": hint}


def probe_containers() -> List[Dict[str, Any]]:
    results: List[Dict[str, Any]] = []
    for name in WATCHED:
        raw = docker_get(f"/containers/{name}/json")
        if raw is None:
            if name in ("hybrid-ai-status", "hybrid-ai-proxy"):
                continue
            results.append({"name": name, "state": "fail",
                            "detail": "container not found",
                            "hint": "Run ./install.sh to create it."})
            continue
        try:
            info = json.loads(raw)
        except json.JSONDecodeError:
            continue

        state = info.get("State", {})
        status = state.get("Status", "unknown")
        restarts = info.get("RestartCount", 0)
        health = (state.get("Health") or {}).get("Status")

        if status == "running":
            if health in (None, "healthy"):
                level, detail = "ok", "running"
            elif health == "starting":
                level, detail = "warn", "starting up"
            else:
                level, detail = "warn", f"running but {health}"
            if restarts > 5:
                level = "warn"
                detail += f" · {restarts} restarts"
            hint = ("" if level == "ok"
                    else f"docker compose --env-file .env logs --tail 50 {name}")
        elif status == "paused":
            level, detail = "warn", "paused"
            hint = (f"A backup was interrupted. Resume with: docker unpause {name}")
        else:
            level, detail = "fail", status
            hint = "Run ./install.sh to start it."

        results.append({"name": name, "state": level,
                        "detail": detail, "hint": hint})
    return results


def probe_pod() -> Dict[str, Any]:
    if not TAILSCALE_IP:
        return {"name": "GPU pod", "state": "warn",
                "detail": "TAILSCALE_IP not configured",
                "hint": "Start the pod once, then re-run ./install.sh."}
    mesh = re.match(r"^100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.", TAILSCALE_IP)
    if not mesh:
        return {"name": "GPU pod", "state": "fail",
                "detail": "address is outside the Tailscale mesh range",
                "hint": "The pipe will refuse to send prompts. Re-run ./install.sh."}
    try:
        url = f"http://{TAILSCALE_IP}:{VLLM_PORT}/v1/models"
        with urllib.request.urlopen(url, timeout=6) as resp:
            body = json.loads(resp.read().decode("utf-8", errors="replace"))
            models = [m.get("id", "?") for m in body.get("data", [])]
            return {"name": "GPU pod", "state": "ok",
                    "detail": f"awake · serving {models[0] if models else 'a model'}",
                    "hint": ""}
    except Exception:
        return {"name": "GPU pod", "state": "info",
                "detail": "stopped (normal — wakes on demand)", "hint": ""}


def probe_resources() -> List[Dict[str, Any]]:
    out: List[Dict[str, Any]] = []
    try:
        st = os.statvfs("/data" if os.path.isdir("/data") else "/")
        total = st.f_blocks * st.f_frsize
        free = st.f_bavail * st.f_frsize
        pct = int((1 - free / total) * 100) if total else 0
        gb_free = free / (1024 ** 3)
        if pct >= 90:
            lvl, hint = "fail", "docker system prune -a --volumes=false"
        elif pct >= 75:
            lvl, hint = "warn", "Consider pruning images and unused models."
        else:
            lvl, hint = "ok", ""
        out.append({"name": "Disk", "state": lvl,
                    "detail": f"{pct}% used · {gb_free:.1f} GB free", "hint": hint})
    except Exception:
        pass

    try:
        info: Dict[str, int] = {}
        with open("/proc/meminfo", "r", encoding="utf-8") as fh:
            for line in fh:
                parts = line.split()
                if len(parts) >= 2:
                    info[parts[0].rstrip(":")] = int(parts[1])
        total = info.get("MemTotal", 0)
        avail = info.get("MemAvailable", 0)
        if total:
            pct = int((1 - avail / total) * 100)
            lvl = "fail" if pct >= 95 else "warn" if pct >= 85 else "ok"
            hint = ("Use a smaller local model — the Pi is swapping."
                    if lvl != "ok" else "")
            out.append({"name": "Memory", "state": lvl,
                        "detail": f"{pct}% used · {avail // 1024} MiB available",
                        "hint": hint})
    except Exception:
        pass
    return out


def probe_models() -> Dict[str, Any]:
    try:
        with urllib.request.urlopen(f"{OLLAMA_URL}/api/tags", timeout=5) as resp:
            models = json.loads(resp.read()).get("models", [])
        if not models:
            return {"name": "Local models", "state": "warn",
                    "detail": "none installed",
                    "hint": "docker exec -it ollama ollama pull llama3.2:3b"}
        names = ", ".join(m.get("name", "?") for m in models[:3])
        extra = f" (+{len(models) - 3} more)" if len(models) > 3 else ""
        return {"name": "Local models", "state": "ok",
                "detail": f"{len(models)} · {names}{extra}", "hint": ""}
    except Exception:
        return {"name": "Local models", "state": "fail",
                "detail": "cannot query Ollama",
                "hint": "Check the ollama container logs."}


def probe_backups() -> Dict[str, Any]:
    if not os.path.exists(BACKUP_LOG):
        return {"name": "Backups", "state": "warn",
                "detail": "no backup log found",
                "hint": "Configure backups by re-running ./install.sh."}
    last: Optional[str] = None
    failures = 0
    try:
        with open(BACKUP_LOG, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if "event=backup_success" in line:
                    match = re.search(r"ts=(\S+)", line)
                    if match:
                        last = match.group(1)
                elif "event=backup_failed" in line:
                    failures += 1
    except OSError:
        pass

    if not last:
        return {"name": "Backups", "state": "warn",
                "detail": "no successful backup recorded",
                "hint": "Run one now: ./backup/backup.sh"}
    try:
        when = datetime.strptime(last, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        hours = int((datetime.now(timezone.utc) - when).total_seconds() // 3600)
    except ValueError:
        return {"name": "Backups", "state": "warn",
                "detail": f"last success {last}", "hint": ""}

    if hours <= 36:
        lvl, hint = "ok", ""
    elif hours <= 168:
        lvl, hint = "warn", "journalctl --user -u hybrid-ai-backup.service -n 50"
    else:
        lvl, hint = "fail", "Backups are not running. Try ./backup/backup.sh manually."
    detail = f"last success {hours}h ago"
    if failures:
        detail += f" · {failures} failure(s) logged"
    return {"name": "Backups", "state": lvl, "detail": detail, "hint": hint}


def probe_data() -> Dict[str, Any]:
    db_path = os.path.join(WEBUI_DATA, "webui.db")
    if not os.path.exists(db_path):
        return {"name": "Data", "state": "warn", "detail": "webui.db not found",
                "hint": "Has Open WebUI started at least once?"}
    try:
        size_mb = os.path.getsize(db_path) / (1024 ** 2)
        conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=3)
        try:
            chats = conn.execute("SELECT COUNT(*) FROM chat").fetchone()[0]
            funcs = conn.execute(
                "SELECT COUNT(*) FROM function WHERE is_active=1").fetchone()[0]
        finally:
            conn.close()
        return {"name": "Data", "state": "ok",
                "detail": f"{chats} chats · {funcs} active function(s) · {size_mb:.1f} MB",
                "hint": ""}
    except Exception as exc:
        return {"name": "Data", "state": "warn",
                "detail": f"could not read ({type(exc).__name__})",
                "hint": "Check integrity: ./doctor.sh"}


# ---------------------------------------------------------------------------
# JOB HISTORY
# ---------------------------------------------------------------------------
_JOB_EVENTS: Dict[str, Tuple[str, str]] = {
    "backup_success":          ("Backup", "ok"),
    "backup_failed":           ("Backup", "fail"),
    "backup_run_complete":     ("Backup", "ok"),
    "check_success":           ("Integrity check", "ok"),
    "check_failed":            ("Integrity check", "fail"),
    "restore_success":         ("Restore", "ok"),
    "restore_failed":          ("Restore", "fail"),
    "restore_test_success":    ("Restore rehearsal", "ok"),
    "restore_test_failed":     ("Restore rehearsal", "fail"),
    "restore_test_unverified": ("Restore rehearsal", "warn"),
    "retention_applied":       ("Retention prune", "ok"),
    "retention_failed":        ("Retention prune", "fail"),
    "install_success":         ("Install / deploy", "ok"),
    "install_failed":          ("Install / deploy", "fail"),
    "install_aborted":         ("Install / deploy", "fail"),
    "repo_initialised":        ("Backup repo init", "ok"),
    "models_repulled":         ("Model re-pull", "ok"),
}

_JOB_MAX_AGE_H: Dict[str, Optional[int]] = {
    "Backup": 36,
    "Integrity check": 24 * 45,
    "Restore rehearsal": 24 * 120,
}

_EVENT_RE = re.compile(r"^EVENT\s+ts=(\S+)\s+event=(\S+)(.*)$")


def _parse_events(path: str, limit: int = 4000) -> List[Tuple[str, str, str]]:
    if not os.path.exists(path):
        return []
    out: List[Tuple[str, str, str]] = []
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh.readlines()[-limit:]:
                match = _EVENT_RE.match(line.strip())
                if match:
                    out.append((match.group(1), match.group(2), match.group(3).strip()))
    except OSError:
        return []
    return out


def _age_hours(stamp: str) -> Optional[int]:
    try:
        when = datetime.strptime(stamp, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        return int((datetime.now(timezone.utc) - when).total_seconds() // 3600)
    except ValueError:
        return None


def _humanise(hours: Optional[int]) -> str:
    if hours is None:
        return "unknown"
    if hours < 1:
        return "just now"
    if hours < 24:
        return f"{hours}h ago"
    days = hours // 24
    return f"{days}d ago" if days < 14 else f"{days // 7}w ago"


def probe_jobs() -> List[Dict[str, Any]]:
    events: List[Tuple[str, str, str]] = []
    for path in (BACKUP_LOG, INSTALL_LOG):
        events.extend(_parse_events(path))
    events.sort(key=lambda item: item[0])

    latest: Dict[str, Dict[str, Any]] = {}
    for stamp, name, rest in events:
        mapped = _JOB_EVENTS.get(name)
        if not mapped:
            continue
        label, outcome = mapped
        latest[label] = {"ts": stamp, "outcome": outcome,
                         "event": name, "detail": redact(rest)[:160]}

    jobs: List[Dict[str, Any]] = []
    for label in ("Backup", "Integrity check", "Restore rehearsal",
                  "Retention prune", "Install / deploy"):
        entry = latest.get(label)
        if not entry:
            if label in ("Backup", "Integrity check"):
                jobs.append({"name": label, "state": "warn",
                             "detail": "never run",
                             "hint": "./backup/backup.sh" if label == "Backup"
                                     else "./backup/backup.sh --check"})
            continue

        hours = _age_hours(entry["ts"])
        when = _humanise(hours)
        state = {"ok": "ok", "fail": "fail", "warn": "warn"}.get(entry["outcome"], "info")
        wording = {"ok": "succeeded", "fail": "FAILED", "warn": "incomplete"}
        detail = f"{wording.get(entry['outcome'], entry['outcome'])} {when}"

        hint = ""
        if state == "fail":
            hint = "grep 'event=' backup.log | tail -20"
        else:
            max_age = _JOB_MAX_AGE_H.get(label)
            if max_age and hours is not None and hours > max_age:
                state = "warn"
                detail += " — overdue"
                hint = ("journalctl --user -u hybrid-ai-backup.service -n 50"
                        if label == "Backup" else "./backup/backup.sh --check")
        jobs.append({"name": label, "state": state, "detail": detail, "hint": hint})

    jobs.extend(_probe_timers())
    return jobs


def _probe_timers() -> List[Dict[str, Any]]:
    out: List[Dict[str, Any]] = []
    events = _parse_events(INSTALL_LOG)
    scheduled = any(name == "backup_schedule_installed" for _, name, _ in events)
    disabled = any(name in ("backup_setup_skipped", "backup_setup_declined")
                   for _, name, _ in events)
    if scheduled:
        out.append({"name": "Backup schedule", "state": "ok",
                    "detail": "nightly timer installed (03:15)", "hint": ""})
    elif disabled:
        out.append({"name": "Backup schedule", "state": "warn",
                    "detail": "not configured",
                    "hint": "Re-run ./install.sh to enable nightly backups."})
    return out


# ---------------------------------------------------------------------------
# Aggregation
# ---------------------------------------------------------------------------
def _safe(fn, fallback_name: str):
    try:
        return fn()
    except Exception as exc:
        return {"name": fallback_name, "state": "warn",
                "detail": f"check failed ({type(exc).__name__})", "hint": ""}


_CACHE: Dict[str, Any] = {"at": 0.0, "data": None}
_CACHE_TTL = float(os.getenv("STATUS_CACHE_TTL", "10"))
_CACHE_LOCK = threading.Lock()


def collect_status(force: bool = False) -> Dict[str, Any]:
    if not force and _CACHE_TTL > 0:
        with _CACHE_LOCK:
            if _CACHE["data"] is not None and (time.monotonic() - _CACHE["at"]) < _CACHE_TTL:
                return _CACHE["data"]
    data = _collect_status_uncached()
    if _CACHE_TTL > 0:
        with _CACHE_LOCK:
            _CACHE["at"] = time.monotonic()
            _CACHE["data"] = data
    return data


def _collect_status_uncached() -> Dict[str, Any]:
    with ThreadPoolExecutor(max_workers=10) as pool:
        futures = {
            "webui": pool.submit(_safe, lambda: probe_http(
                "Open WebUI", f"{WEBUI_URL}/health",
                "docker compose --env-file .env logs --tail 50 open-webui"), "Open WebUI"),
            "ollama": pool.submit(_safe, lambda: probe_http(
                "Ollama", f"{OLLAMA_URL}/api/tags",
                "docker compose --env-file .env logs --tail 50 ollama"), "Ollama"),
            "hermes": pool.submit(_safe, lambda: probe_http(
                "Hermes Agent", HERMES_URL,
                "docker compose --env-file .env logs --tail 50 hermes-agent"), "Hermes Agent"),
            "openhands": pool.submit(_safe, lambda: probe_http(
                "OpenHands", OPENHANDS_URL,
                "docker compose --env-file .env logs --tail 50 openhands"), "OpenHands"),
            "pod": pool.submit(_safe, probe_pod, "GPU pod"),
            "containers": pool.submit(_safe, probe_containers, "Containers"),
            "resources": pool.submit(_safe, probe_resources, "Resources"),
            "models": pool.submit(_safe, probe_models, "Local models"),
            "backups": pool.submit(_safe, probe_backups, "Backups"),
            "data": pool.submit(_safe, probe_data, "Data"),
            "jobs": pool.submit(_safe, probe_jobs, "Jobs"),
            "logs": pool.submit(lambda: {
                name: container_logs(name, 40) for name in ("open-webui", "ollama", "hermes-agent", "openhands")}),
            "errors": pool.submit(_safe, recent_errors, "Errors"),
        }

        def get(key, default):
            try:
                return futures[key].result(timeout=25)
            except Exception:
                return default

        services = [get("webui", {}), get("ollama", {}), get("hermes", {}), get("openhands", {}), get("pod", {})]
        containers = get("containers", [])
        resources = get("resources", [])
        checks = (containers if isinstance(containers, list) else [containers])
        checks += (resources if isinstance(resources, list) else [resources])
        checks += [get("models", {}), get("backups", {}), get("data", {})]
        jobs_result = get("jobs", [])
        jobs = jobs_result if isinstance(jobs_result, list) else [jobs_result]
        logs = get("logs", {})
        errors = get("errors", [])

    services = [item for item in services if item]
    checks = [item for item in checks if item]

    worst = "ok"
    for item in services + checks + jobs:
        if item["state"] == "fail":
            worst = "fail"
            break
        if item["state"] == "warn":
            worst = "warn"

    return {
        "generated": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC"),
        "overall": worst,
        "services": services,
        "checks": checks,
        "jobs": jobs,
        "logs": logs if isinstance(logs, dict) else {},
        "errors": errors if isinstance(errors, list) else [],
    }


def recent_errors() -> List[Dict[str, str]]:
    pattern = re.compile(
        r"\b(error|exception|traceback|critical|fatal|refused|timeout|denied|"
        r"failed|request_failed|request_degraded)\b", re.I)
    ignore = re.compile(r"(GET /health|/api/tags|0 failed|failures=0)", re.I)
    found: List[Dict[str, str]] = []
    for name in ("open-webui", "ollama", "hermes-agent", "openhands"):
        for line in container_logs(name, 120):
            if pattern.search(line) and not ignore.search(line):
                found.append({"source": name, "line": line[:400]})
    return found[-25:]


# ---------------------------------------------------------------------------
# Diagnostic bundle
# ---------------------------------------------------------------------------
def build_diagnostic() -> str:
    data = collect_status()
    lines: List[str] = []
    add = lines.append

    add("=" * 63)
    add("  hybrid-ai DIAGNOSTIC BUNDLE (generated from the status page)")
    add("=" * 63)
    add(f"generated : {data['generated']}")
    add(f"overall   : {data['overall'].upper()}")
    add("")
    add("ABOUT THIS FILE")
    add("---------------")
    add("Diagnostics for a self-hosted AI stack: Open WebUI, Hermes, OpenHands,")
    add("and Ollama in Docker on a Raspberry Pi, with cloud inference fallback.")
    add("")
    add("This bundle contains NO credentials. Log lines are additionally passed")
    add("through a redaction filter. No chat content or documents were read.")
    add("")
    add("=" * 63)
    add("  SERVICES")
    add("=" * 63)
    for item in data["services"] + data["checks"]:
        add(f"  [{item['state'].upper():4}] {item['name']:<18} {item['detail']}")
        if item["hint"]:
            add(f"         fix: {item['hint']}")

    add("")
    add("=" * 63)
    add("  SCHEDULED JOBS (last run)")
    add("=" * 63)
    for item in data.get("jobs", []):
        add(f"  [{item['state'].upper():4}] {item['name']:<18} {item['detail']}")
        if item["hint"]:
            add(f"         fix: {item['hint']}")
    if not data.get("jobs"):
        add("  (no job history found)")

    add("")
    add("=" * 63)
    add("  RECENT ERRORS")
    add("=" * 63)
    if data["errors"]:
        for entry in data["errors"]:
            add(f"  [{entry['source']}] {entry['line']}")
    else:
        add("  (none detected)")

    for name, log_lines in data["logs"].items():
        add("")
        add("=" * 63)
        add(f"  LOG TAIL — {name}")
        add("=" * 63)
        for line in log_lines[-40:]:
            add(f"  {line}")

    add("")
    add("=" * 63)
    add("  END OF BUNDLE")
    add("=" * 63)
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# HTML rendering
# ---------------------------------------------------------------------------
_CSS = """
:root{--bg:#0f1419;--card:#1a212b;--line:#2a3441;--fg:#e6edf3;--dim:#8b949e;
--ok:#3fb950;--warn:#d29922;--fail:#f85149;--info:#58a6ff;--accent:#58a6ff}
@media(prefers-color-scheme:light){:root{--bg:#f6f8fa;--card:#fff;--line:#d8dee4;
--fg:#1f2328;--dim:#656d76;--ok:#1a7f37;--warn:#9a6700;--fail:#cf222e;--info:#0969da}}
*{box-sizing:border-box}
body{margin:0;padding:24px;background:var(--bg);color:var(--fg);
font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}
.wrap{max-width:1000px;margin:0 auto}
header{display:flex;align-items:center;justify-content:space-between;
flex-wrap:wrap;gap:12px;margin-bottom:8px}
h1{font-size:20px;margin:0;font-weight:600}
.sub{color:var(--dim);font-size:13px;margin-bottom:20px}
.banner{padding:14px 18px;border-radius:8px;margin-bottom:20px;font-weight:600;
display:flex;align-items:center;gap:10px}
.banner.ok{background:rgba(63,185,80,.12);color:var(--ok);border:1px solid rgba(63,185,80,.3)}
.banner.warn{background:rgba(210,153,34,.12);color:var(--warn);border:1px solid rgba(210,153,34,.3)}
.banner.fail{background:rgba(248,81,73,.12);color:var(--fail);border:1px solid rgba(248,81,73,.3)}
.card{background:var(--card);border:1px solid var(--line);border-radius:8px;
padding:18px;margin-bottom:18px}
h2{font-size:13px;text-transform:uppercase;letter-spacing:.06em;color:var(--dim);
margin:0 0 14px;font-weight:600}
.row{display:flex;align-items:flex-start;gap:12px;padding:9px 0;
border-bottom:1px solid var(--line)}
.row:last-child{border-bottom:0}
.dot{width:9px;height:9px;border-radius:50%;margin-top:7px;flex:none}
.dot.ok{background:var(--ok)}.dot.warn{background:var(--warn)}
.dot.fail{background:var(--fail)}.dot.info{background:var(--info)}
.nm{font-weight:500;min-width:150px}
.dt{color:var(--dim);flex:1}
.hint{display:block;margin-top:5px;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;
font-size:12px;color:var(--accent);word-break:break-all}
pre{background:var(--bg);border:1px solid var(--line);border-radius:6px;padding:12px;
overflow-x:auto;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;
font-size:12px;line-height:1.55;margin:0;max-height:340px}
.err{color:var(--fail)}
button{background:var(--accent);color:#fff;border:0;border-radius:6px;
padding:9px 16px;font-size:14px;font-weight:500;cursor:pointer;font-family:inherit}
button:hover{filter:brightness(1.1)}
button:disabled{opacity:.6;cursor:wait}
button.ghost{background:transparent;color:var(--fg);border:1px solid var(--line)}
.btns{display:flex;gap:10px;flex-wrap:wrap}
.note{color:var(--dim);font-size:12px;margin-top:10px}
details summary{cursor:pointer;color:var(--dim);font-size:13px;margin-bottom:10px}
footer{color:var(--dim);font-size:12px;text-align:center;margin-top:28px}
a{color:var(--accent)}
nav{display:flex;gap:6px;margin-bottom:18px;flex-wrap:wrap}
nav a{padding:6px 12px;border-radius:6px;text-decoration:none;font-size:13px;
border:1px solid var(--line);color:var(--fg)}
nav a.on{background:var(--accent);color:#fff;border-color:var(--accent)}
nav a:hover:not(.on){background:var(--card)}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(230px,1fr));gap:14px}
.tile{display:block;text-decoration:none;color:var(--fg);background:var(--card);
border:1px solid var(--line);border-radius:8px;padding:18px}
.tile:hover{border-color:var(--accent)}
.tile h3{margin:0 0 6px;font-size:15px;display:flex;align-items:center;gap:8px}
.tile p{margin:0;color:var(--dim);font-size:13px}
.tile code{font-size:12px;color:var(--accent)}
"""

_BANNER = {
    "ok": "All systems operational",
    "warn": "Running, but some checks need attention",
    "fail": "Something is broken — see the failures below",
}


def _rows(items: List[Dict[str, Any]]) -> str:
    out = []
    for item in items:
        hint = (f"<span class='hint'>{html.escape(item['hint'])}</span>"
                if item.get("hint") else "")
        out.append(
            f"<div class='row'><span class='dot {item['state']}'></span>"
            f"<span class='nm'>{html.escape(item['name'])}</span>"
            f"<span class='dt'>{html.escape(item['detail'])}{hint}</span></div>"
        )
    return "".join(out)


def render_html(data: Dict[str, Any]) -> str:
    errors = "".join(
        f"<span class='err'>[{html.escape(e['source'])}]</span> {html.escape(e['line'])}\n"
        for e in data["errors"]
    ) or "No errors detected in recent logs.\n"

    tails = "".join(
        f"<details><summary>{html.escape(name)} — last 40 lines</summary>"
        f"<pre>{html.escape(chr(10).join(lines[-40:])) or '(no output)'}</pre></details>"
        for name, lines in data["logs"].items()
    )

    return f"""<!DOCTYPE html>
<html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow">
<title>hybrid-ai status</title><style>{_CSS}</style></head><body><div class="wrap">

<nav>
  <a href="/hub">Hub</a>
  <a href="/status" class="on">Status</a>
  <a href="http://{html.escape(LOCAL_DOMAIN)}">Open WebUI</a>
</nav>
<header>
  <h1>hybrid-ai status</h1>
  <div class="btns">
    <button id="dl">Download diagnostic</button>
    <button class="ghost" onclick="location.reload()">Refresh</button>
  </div>
</header>
<div class="sub">Generated {html.escape(data['generated'])} · auto-refreshes every 60s while visible</div>

<div class="banner {data['overall']}">{_BANNER[data['overall']]}</div>

<div class="card"><h2>Services</h2>{_rows(data['services'])}</div>
<div class="card"><h2>System checks</h2>{_rows(data['checks'])}</div>

<div class="card"><h2>Scheduled jobs — last run</h2>{_rows(data['jobs'])}
  <div class="note">Parsed from structured event logs written by
  <code>backup.sh</code> and <code>install.sh</code>.</div>
</div>

<div class="card"><h2>Recent errors</h2>
  <pre>{errors}</pre>
  <div class="note">Filtered from recent log lines of each service.</div>
</div>

<div class="card"><h2>Log tails</h2>{tails}</div>

<div class="card"><h2>Diagnostics</h2>
  <p style="margin:0 0 12px">Download a shareable bundle of the status above,
  recent errors, and log tails. Contains no credentials or chat content.</p>
  <div class="btns"><button id="dl2">Download diagnostic bundle</button></div>
</div>

<footer>hybrid-ai · <a href="/hub">Hub</a> · <a href="http://{html.escape(LOCAL_DOMAIN)}">Open WebUI</a></footer>
</div>
<script>
async function download(btn){{
  const original = btn.textContent;
  btn.disabled = true; btn.textContent = 'Building…';
  try {{
    const resp = await fetch('/status/diagnostic', {{method:'POST'}});
    if(!resp.ok) throw new Error('HTTP ' + resp.status);
    const blob = await resp.blob();
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    const stamp = new Date().toISOString().replace(/[:.]/g,'-').slice(0,19);
    a.href = url; a.download = 'hybrid-ai-diagnostic-' + stamp + '.txt';
    document.body.appendChild(a); a.click(); a.remove();
    URL.revokeObjectURL(url);
    btn.textContent = 'Downloaded';
  }} catch (err) {{
    btn.textContent = 'Failed — see console';
    console.error(err);
  }}
  setTimeout(() => {{ btn.disabled = false; btn.textContent = original; }}, 2500);
}}
document.getElementById('dl').onclick  = e => download(e.target);
document.getElementById('dl2').onclick = e => download(e.target);

let timer = null;
function schedule(){{
  clearInterval(timer);
  timer = setInterval(() => {{
    if(document.hidden) return;
    if(document.querySelector('button:disabled')) return;
    location.reload();
  }}, 60000);
}}
schedule();
document.addEventListener('visibilitychange', () => {{ if(!document.hidden) schedule(); }});
</script></body></html>"""


def render_hub(data: Dict[str, Any]) -> str:
    """
    The landing page at http://<LOCAL_DOMAIN>/hub — directory of available services
    rendered with live status indicators and clickable subdomain URLs.
    """
    by_name = {item["name"]: item for item in data["services"] + data["checks"]}

    def badge(name: str) -> str:
        state = by_name.get(name, {}).get("state", "info")
        detail = by_name.get(name, {}).get("detail", "")
        return (f"<span class='dot {state}'></span>"
                f"<span style='color:var(--dim);font-size:13px'>{html.escape(detail)}</span>")

    tiles = [
        (f"http://{LOCAL_DOMAIN}", "Open WebUI", "Chat, local RAG, and document workspace.",
         badge("Open WebUI")),
        ("http://127.0.0.1:3001", "OpenHands", "Available through the authenticated SSH tunnel.",
         badge("OpenHands")),
        (f"http://hermes.{LOCAL_DOMAIN}", "Hermes Agent", "System orchestrator & memory engine.",
         badge("Hermes Agent")),
        (f"http://status.{LOCAL_DOMAIN}", "Status Dashboard", "System diagnostics, health checks, and logs.",
         f"<span class='dot {data['overall']}'></span>"
         f"<span style='color:var(--dim);font-size:13px'>{_BANNER[data['overall']]}</span>"),
    ]

    cards = "".join(
        f"<a class='tile' href='{href}' target='_blank'><h3>{html.escape(title)}</h3>"
        f"<p>{html.escape(desc)}</p><p style='margin-top:10px'>{state}</p>"
        f"<code style='display:block;margin-top:8px'>{html.escape(href)}</code></a>"
        for href, title, desc, state in tiles
    )

    return f"""<!DOCTYPE html>
<html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow">
<title>hybrid-ai hub</title><style>{_CSS}</style></head><body><div class="wrap">
<nav>
  <a href="/hub" class="on">Hub</a>
  <a href="http://status.{html.escape(LOCAL_DOMAIN)}">Status</a>
  <a href="http://{html.escape(LOCAL_DOMAIN)}">Open WebUI</a>
</nav>
<header><h1>hybrid-ai service hub</h1></header>
<div class="sub">Local Domain: <strong>{html.escape(LOCAL_DOMAIN)}</strong> · {html.escape(data['generated'])}</div>
<div class="banner {data['overall']}">{_BANNER[data['overall']]}</div>
<div class="tiles">{cards}</div>
<div class="card" style="margin-top:18px"><h2>Addresses</h2>
  <div class="row"><span class="nm">Open WebUI</span><span class="dt"><code>http://{html.escape(LOCAL_DOMAIN)}</code></span></div>
  <div class="row"><span class="nm">OpenHands</span><span class="dt"><code>http://127.0.0.1:3001 via SSH tunnel</code></span></div>
  <div class="row"><span class="nm">Hermes Agent</span><span class="dt"><code>http://hermes.{html.escape(LOCAL_DOMAIN)}</code></span></div>
  <div class="row"><span class="nm">Status Page</span><span class="dt"><code>http://status.{html.escape(LOCAL_DOMAIN)}</code></span></div>
  <div class="row"><span class="nm">Ollama API</span><span class="dt"><code>http://{html.escape(LOCAL_DOMAIN)}/ollama/</code></span></div>
  <div class="row"><span class="nm">Health Summary</span><span class="dt"><code>http://{html.escape(LOCAL_DOMAIN)}/health</code></span></div>
</div>
<footer>hybrid-ai</footer>
</div></body></html>"""


# ---------------------------------------------------------------------------
# HTTP server
# ---------------------------------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    server_version = "hybrid-ai-status"
    sys_version = ""

    def log_message(self, fmt: str, *args: Any) -> None:
        if os.getenv("STATUS_ACCESS_LOG", "0") == "1":
            super().log_message(fmt, *args)

    def _send(self, code: int, body: bytes, ctype: str,
              extra: Optional[Dict[str, str]] = None) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Content-Security-Policy",
                         "default-src 'none'; style-src 'unsafe-inline'; "
                         "script-src 'unsafe-inline'; connect-src 'self'")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Cache-Control", "no-store")
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        path = self.path.split("?", 1)[0].rstrip("/") or "/hub"
        if path == "/status/healthz":
            self._send(200, b"ok", "text/plain; charset=utf-8")
        elif path == "/status/health-summary":
            try:
                overall = collect_status()["overall"]
            except Exception:
                overall = "fail"
            code = 200 if overall == "ok" else 503
            self._send(code, overall.encode(), "text/plain; charset=utf-8")
        elif path == "/status/api":
            body = json.dumps(collect_status(), indent=2).encode()
            self._send(200, body, "application/json; charset=utf-8")
        elif path in ("/hub", "/"):
            try:
                body = render_hub(collect_status()).encode()
                self._send(200, body, "text/html; charset=utf-8")
            except Exception as exc:
                msg = (f"<h1>Hub error</h1><pre>{html.escape(type(exc).__name__)}: "
                       f"{html.escape(redact(str(exc)))}</pre>").encode()
                self._send(500, msg, "text/html; charset=utf-8")
        elif path == "/status":
            try:
                body = render_html(collect_status()).encode()
                self._send(200, body, "text/html; charset=utf-8")
            except Exception as exc:
                msg = (f"<h1>Status page error</h1><pre>{html.escape(type(exc).__name__)}: "
                       f"{html.escape(redact(str(exc)))}</pre>").encode()
                self._send(500, msg, "text/html; charset=utf-8")
        else:
            self._send(404, b"not found", "text/plain; charset=utf-8")

    def do_POST(self) -> None:
        path = self.path.split("?", 1)[0].rstrip("/")
        if path == "/status/diagnostic":
            try:
                body = build_diagnostic().encode()
            except Exception as exc:
                body = f"Diagnostic generation failed: {type(exc).__name__}".encode()
                self._send(500, body, "text/plain; charset=utf-8")
                return
            stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
            self._send(200, body, "text/plain; charset=utf-8",
                       {"Content-Disposition":
                        f'attachment; filename="hybrid-ai-diagnostic-{stamp}.txt"'})
        else:
            self._send(404, b"not found", "text/plain; charset=utf-8")


def main() -> None:
    server = ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), Handler)
    server.daemon_threads = True
    print(f"[status] listening on :{LISTEN_PORT}", flush=True)
    print(f"[status] watching docker socket {DOCKER_SOCK}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
```


