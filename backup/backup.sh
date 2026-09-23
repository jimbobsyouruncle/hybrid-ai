#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: backup/backup.sh
# PURPOSE (plain English):
#   Backs up everything you would be upset to lose -- your chat history, your
#   uploaded documents, and the vector database that makes document search
#   work -- to Cloudflare R2, encrypted before it ever leaves the Pi.
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
#   Open WebUI keeps its data in SQLite, and ChromaDB keeps vectors in SQLite
#   too. Copying a SQLite file while the application is writing to it produces
#   a CORRUPT copy. It will look fine. It will back up without error. It will
#   fail to open when you finally need it, which is the worst possible time to
#   discover the problem.
#
#   So this script does NOT copy the live database files. It asks SQLite to
#   produce a consistent snapshot first (see snapshot_sqlite below), backs up
#   that snapshot, and excludes the live files entirely. This is the single
#   most important thing this script does.
#
# WHAT GETS BACKED UP:
#   - Consistent SQLite snapshots (chat history, users, settings, vectors)
#   - Uploaded documents and any other non-database files in webui_data
#   - Your .env configuration
#   - A manifest recording what was captured and from which versions
#
# WHAT DOES NOT:
#   - ollama_data/ -- model weights, tens of GB, freely re-downloadable.
#     Backing them up would dominate cost for zero benefit.
#
# USAGE:
#   ./backup.sh              run a backup now
#   ./backup.sh --check      verify repository integrity (slow, reads data)
#   ./backup.sh --init       create the repository (first-time setup)
#   ./backup.sh --dry-run    show what would be backed up, upload nothing
# ---------------------------------------------------------------------------
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_DIR"

# Credentials live OUTSIDE the git repository, in a root-only directory, so
# that no git operation and no careless `tar czf` of the project folder can
# ever sweep them up.
BACKUP_CONF_DIR="${BACKUP_CONF_DIR:-${HOME}/.config/hybrid-ai-backup}"
R2_ENV_FILE="${BACKUP_CONF_DIR}/r2.env"
RESTIC_PW_FILE="${BACKUP_CONF_DIR}/repo-password"

# Where consistent database snapshots are staged before upload. Deliberately
# on local disk, deliberately wiped afterwards.
STAGING_DIR="${REPO_DIR}/.backup-staging"

BACKUP_LOG="${BACKUP_LOG:-${REPO_DIR}/backup.log}"

# Retention. Restic keeps the most recent snapshot in each bucket.
KEEP_DAILY="${KEEP_DAILY:-7}"
KEEP_WEEKLY="${KEEP_WEEKLY:-4}"
KEEP_MONTHLY="${KEEP_MONTHLY:-6}"

MODE="backup"
for arg in "$@"; do
  case "$arg" in
    --check)   MODE="check" ;;
    --init)    MODE="init" ;;
    --dry-run) MODE="dryrun" ;;
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
# credential, a filename from a user document, or any chat content here.
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

# AVAILABILITY: always clean up staged database copies, even on failure.
# Those snapshots contain your full chat history in plaintext on local disk;
# leaving them lying around after a crash would be both a privacy problem and
# a slow disk leak.
cleanup() {
  local rc=$?
  # Never leave the application frozen because this script died mid-run.
  if declare -F unpause_webui >/dev/null 2>&1; then unpause_webui; fi
  if [[ -d "$STAGING_DIR" ]]; then
    rm -rf "$STAGING_DIR" 2>/dev/null || true
  fi
  return $rc
}
trap cleanup EXIT
trap 'die "Failed at line ${LINENO}: ${BASH_COMMAND}"' ERR

touch "$BACKUP_LOG" 2>/dev/null && chmod 600 "$BACKUP_LOG" 2>/dev/null || true

# ---------------------------------------------------------------------------
# STEP 1. Load credentials
#
# SECURITY: parsed line by line rather than `source`d. `source` executes the
# file as shell code, so a value containing $(...) would run as a command.
# ---------------------------------------------------------------------------
[[ -f "$R2_ENV_FILE" ]] || die "No credentials at ${R2_ENV_FILE}. Run ./install.sh to configure backups."
[[ -f "$RESTIC_PW_FILE" ]] || die "No repository password at ${RESTIC_PW_FILE}."

# Refuse to run if the credential files are readable by anyone else.
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

# restic reads the passphrase from this file rather than an environment
# variable, keeping it out of /proc/<pid>/environ.
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
#
# WHY THIS MATTERS: a backup you have never verified is a hypothesis, not a
# backup. This reads a random 5% subset of the actual data and confirms it
# decrypts and matches its checksums.
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
# STEP 4. Capture webui_data consistently
#
# THIS IS THE MOST IMPORTANT SECTION IN THE FILE.
#
# Two separate consistency problems have to be solved together:
#
#   PROBLEM 1 -- SQLite.
#     Copying a SQLite file while the app is writing gives you a corrupt copy
#     that looks fine and fails to open when you need it. Solved by asking
#     SQLite itself for a coherent snapshot (VACUUM INTO / .backup).
#
#   PROBLEM 2 -- ChromaDB is split across TWO storage formats.
#     Chroma keeps document metadata in chroma.sqlite3, but keeps the actual
#     vector index in separate binary files (data_level0.bin, header.bin,
#     length.bin, link_lists.bin) inside UUID-named directories. If we
#     snapshot the SQLite half at 03:15:00 and copy the binary half at
#     03:15:04, and a document was embedded in between, the two halves
#     disagree. The restored knowledge base then has metadata referencing
#     vectors that are not in the index.
#
#     Copying a folder is only safe when nothing is writing to it.
#
# THE FIX: briefly PAUSE the Open WebUI container for the capture. `docker
# pause` freezes the process with SIGSTOP -- no shutdown, no restart, no lost
# connections, typically 2-10 seconds. Everything is then captured from a
# single frozen point in time, so the SQLite snapshots and the Chroma binary
# index cannot disagree.
#
# We unpause in the EXIT trap, so the container is resumed even if this script
# crashes partway through.
#
# Set BACKUP_NO_PAUSE=1 to skip pausing. Faster and zero downtime, but the
# Chroma index and its metadata may be captured microseconds apart. Acceptable
# only if you are not actively embedding documents during the backup window.
# ---------------------------------------------------------------------------
PAUSED=0

unpause_webui() {
  if (( PAUSED )); then
    docker compose --env-file "${REPO_DIR}/.env" unpause open-webui >/dev/null 2>&1 || \
      docker unpause open-webui >/dev/null 2>&1 || true
    PAUSED=0
  fi
}

pause_webui() {
  [[ "${BACKUP_NO_PAUSE:-0}" == "1" ]] && return 1
  command -v docker >/dev/null 2>&1 || return 1
  [[ -f "${REPO_DIR}/.env" ]] || return 1
  # Only pause something that is actually running.
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'open-webui' || return 1

  if docker compose --env-file "${REPO_DIR}/.env" pause open-webui >/dev/null 2>&1 || \
     docker pause open-webui >/dev/null 2>&1; then
    PAUSED=1
    return 0
  fi
  return 1
}

snapshot_sqlite() {
  local src="$1" dest="$2"
  mkdir -p "$(dirname "$dest")"

  if command -v sqlite3 >/dev/null 2>&1; then
    # ".timeout 10000" waits up to 10s for a busy writer rather than failing
    # instantly. "VACUUM INTO" also compacts, shrinking the upload.
    if sqlite3 "file:${src}?mode=ro" ".timeout 10000" "VACUUM INTO '${dest}'" 2>/dev/null; then
      return 0
    fi
    # VACUUM INTO refuses if the destination exists; .backup is the fallback.
    rm -f "$dest"
    if sqlite3 "file:${src}?mode=ro" ".timeout 10000" ".backup '${dest}'" 2>/dev/null; then
      return 0
    fi
  fi
  return 1
}

[[ "$MODE" == "dryrun" ]] || log "Capturing webui_data..."

rm -rf "$STAGING_DIR"
mkdir -p "${STAGING_DIR}/databases" "${STAGING_DIR}/files" "${STAGING_DIR}/env" "${STAGING_DIR}/host"
chmod 700 "$STAGING_DIR"

# --- Freeze the application for the duration of the capture ---------------
if pause_webui; then
  CONSISTENCY="paused"
  [[ "$MODE" == "dryrun" ]] || ok "Open WebUI paused for a consistent point-in-time capture."
else
  CONSISTENCY="online"
  [[ "$MODE" == "dryrun" ]] || warn "Could not pause the container; capturing live (see BACKUP_NO_PAUSE)."
fi

DB_COUNT=0
DB_FAILED=0

# Find every SQLite database under webui_data. A glob walk rather than a
# hardcoded list, so a future Open WebUI version that adds a new database
# (or a new Chroma collection) is captured automatically instead of missed.
while IFS= read -r -d '' db; do
  rel="${db#"${REPO_DIR}/webui_data/"}"
  target="${STAGING_DIR}/databases/${rel}"
  if snapshot_sqlite "$db" "$target"; then
    DB_COUNT=$(( DB_COUNT + 1 ))
  else
    DB_FAILED=$(( DB_FAILED + 1 ))
    warn "Could not snapshot ${rel} via SQLite API."
  fi
done < <(find "${REPO_DIR}/webui_data" -type f \
           \( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' \) \
           -print0 2>/dev/null || true)

# --- Everything that is NOT a SQLite database ------------------------------
# This is where uploaded documents live, and -- critically -- where Chroma's
# binary HNSW index files live. Captured from the same frozen moment as the
# SQLite snapshots above, so the vector index and its metadata agree.
#
# We exclude only genuinely disposable things. Anything unrecognised is kept:
# a future Open WebUI version storing something new should be backed up by
# default, not silently dropped.
if [[ -d "${REPO_DIR}/webui_data" ]]; then
  rsync -a \
    --exclude='*.db' --exclude='*.sqlite' --exclude='*.sqlite3' \
    --exclude='*.db-wal' --exclude='*.db-shm' --exclude='*.db-journal' \
    --exclude='*-wal' --exclude='*-shm' \
    --exclude='cache/' --exclude='tmp/' \
    "${REPO_DIR}/webui_data/" "${STAGING_DIR}/files/" 2>/dev/null || \
    warn "rsync reported issues copying files; continuing."
fi

# Release the application as soon as the copy is done -- before the slow
# upload step, which does not need the container frozen.
unpause_webui
[[ "$MODE" == "dryrun" ]] || ok "Capture complete; Open WebUI resumed."

# --- Fallback: full stop, cold copy, restart -------------------------------
# CORRECTNESS OVER UPTIME. If we could not get consistent database copies we
# take a real outage rather than upload something unrestorable. A backup that
# cannot be restored is worse than no backup, because you will rely on it.
if (( DB_FAILED > 0 )); then
  warn "${DB_FAILED} database(s) could not be snapshotted online."
  if command -v docker >/dev/null 2>&1 && [[ -f "${REPO_DIR}/.env" ]]; then
    warn "Falling back to a cold copy. Open WebUI will be briefly unavailable."
    event "cold_copy_fallback" "failed_dbs=${DB_FAILED}"
    CONSISTENCY="cold"

    docker compose --env-file "${REPO_DIR}/.env" stop open-webui >/dev/null 2>&1 || true
    sleep 3
    rm -rf "${STAGING_DIR}/databases"
    mkdir -p "${STAGING_DIR}/databases"
    DB_COUNT=0
    while IFS= read -r -d '' db; do
      rel="${db#"${REPO_DIR}/webui_data/"}"
      mkdir -p "$(dirname "${STAGING_DIR}/databases/${rel}")"
      cp -a "$db" "${STAGING_DIR}/databases/${rel}" && DB_COUNT=$(( DB_COUNT + 1 ))
    done < <(find "${REPO_DIR}/webui_data" -type f \
               \( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' \) \
               -print0 2>/dev/null || true)
    docker compose --env-file "${REPO_DIR}/.env" start open-webui >/dev/null 2>&1 || \
      warn "Could not restart open-webui automatically. Run: ./install.sh"
  else
    die "Cannot produce consistent database copies and cannot fall back. Install sqlite3: sudo apt-get install -y sqlite3"
  fi
fi

[[ "$MODE" == "dryrun" ]] || ok "Captured ${DB_COUNT} database(s) (${CONSISTENCY})."

# ---------------------------------------------------------------------------
# STEP 4b. Capture host and platform state
#
# WHY: the databases hold everything Open WebUI knows -- your connections,
# functions, tools, models, knowledge bases, users and groups all live in
# webui.db. But a bare new Pi also needs to know WHICH Ollama models you had,
# which container versions you were running, and any local customisation.
#
# We do not back up model WEIGHTS (tens of GB, freely re-downloadable). We
# back up the LIST, so restore.sh can re-pull them for you automatically.
# ---------------------------------------------------------------------------
[[ "$MODE" == "dryrun" ]] || log "Capturing host and platform state..."

HOST_DIR="${STAGING_DIR}/host"

# --- Which Ollama models were installed ------------------------------------
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'ollama'; then
  docker exec ollama ollama list 2>/dev/null \
    | awk 'NR>1 {print $1}' > "${HOST_DIR}/ollama-models.txt" || true
  # Any models you built yourself from a Modelfile cannot be re-pulled from a
  # registry, so capture their definitions too.
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

# --- Exact container versions in use ---------------------------------------
docker compose --env-file "${REPO_DIR}/.env" config --images 2>/dev/null \
  > "${HOST_DIR}/container-images.txt" || true

# --- Local customisation of the deployment itself --------------------------
# compose overrides and the pipe source are tracked in git normally, but if
# you edited them locally those edits exist nowhere else.
for f in docker-compose.yml docker-compose.override.yml; do
  [[ -f "${REPO_DIR}/${f}" ]] && cp -a "${REPO_DIR}/${f}" "${HOST_DIR}/${f}" 2>/dev/null || true
done
# openhands/ and scripts/ hold AGENTS.md, the prompts, the overlay, and the
# workspace isolation guard. Tracked in git, but local edits exist nowhere
# else -- the same argument that already put the Caddyfile in this list.
for d in openwebui openhands scripts status; do
  if [[ -d "${REPO_DIR}/${d}" ]]; then
    mkdir -p "${HOST_DIR}/${d}"
    cp -a "${REPO_DIR}/${d}/." "${HOST_DIR}/${d}/" 2>/dev/null || true
  fi
done
# The Caddyfile in particular is worth calling out: if you added a basic_auth
# password hash or changed the allowed networks, that customisation exists
# nowhere else and would be lost with the SD card.

# --- Which commit this deployment was running ------------------------------
if command -v git >/dev/null 2>&1 && [[ -d "${REPO_DIR}/.git" ]]; then
  {
    printf 'commit=%s\n' "$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
    printf 'branch=%s\n' "$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
    printf 'remote=%s\n' "$(git -C "$REPO_DIR" config --get remote.origin.url 2>/dev/null || echo none)"
    printf 'dirty=%s\n' "$(git -C "$REPO_DIR" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  } > "${HOST_DIR}/git-state.txt" 2>/dev/null || true
  # Any uncommitted local changes, so they are not lost with the SD card.
  git -C "$REPO_DIR" diff HEAD > "${HOST_DIR}/uncommitted.patch" 2>/dev/null || true
  [[ -s "${HOST_DIR}/uncommitted.patch" ]] || rm -f "${HOST_DIR}/uncommitted.patch"
fi

# --- Platform facts worth knowing on rebuild -------------------------------
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
#
# Future-you, restoring at 2am onto unfamiliar hardware, will want to know
# exactly what this snapshot contains and what produced it.
# METADATA ONLY -- no document names, no chat content.
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
databases/   Consistent SQLite snapshots. This is where Open WebUI keeps
             EVERYTHING you configured through the UI:
               - chat history and folders
               - users, groups, permissions, API keys
               - model connections (Ollama and OpenAI-compatible endpoints)
               - functions / pipes, including their Python source AND the
                 valve values you set (your RunPod pipe settings live here)
               - tools, prompts, knowledge base definitions
               - system settings from the admin panel
             Also includes chroma.sqlite3, the vector store metadata.

files/       Everything that is not a SQLite database:
               - uploaded documents (uploads/)
               - ChromaDB binary vector index (vector_db/<uuid>/*.bin)
             Captured at the same frozen moment as databases/, so the vector
             index and its metadata cannot disagree.

host/        State needed to rebuild the machine itself:
               ollama-models.txt     which models to re-pull
               modelfiles/           definitions of any custom-built models
               container-images.txt  exact image versions that were running
               docker-compose*.yml   including any local edits
               openwebui/            the pipe source as deployed
               status/               status page app AND your Caddyfile,
                                     including any basic_auth hash or
                                     allowlist changes you made
               git-state.txt         commit this deployment was running
               uncommitted.patch     local edits not yet committed (if any)
               platform.txt          OS, RAM, docker and tailscale facts

env/         The .env configuration from the source host.

NOT INCLUDED (deliberate)
-------------------------
Ollama model WEIGHTS -- tens of GB and freely re-downloadable. restore.sh
re-pulls them automatically from host/ollama-models.txt.

Tailscale machine identity -- a rebuilt Pi must re-authenticate to your
tailnet with 'sudo tailscale up'. Keys are not transferable by design.

To restore, see backup/restore.sh in the hybrid-ai repository.
EOF

# ---------------------------------------------------------------------------
# STEP 6. Stage the configuration file
#
# .env holds live credentials -- but restic encrypts everything before upload,
# so this is safe, and it means a rebuilt Pi gets its RunPod settings back
# without you re-entering anything.
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
# Only the staging directory is passed to restic. The live webui_data is never
# uploaded directly, which is what guarantees every database in every snapshot
# is internally consistent.
# ---------------------------------------------------------------------------
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
#
# --prune actually reclaims space in the bucket. Without it, forgotten
# snapshots stay billable forever.
#
# NOTE: if you later enable R2 Object Lock for ransomware resistance, pruning
# must move off this host -- a client that can prune is a client that can
# destroy your history. See backup/README.md.
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
  # Not fatal: the backup itself already succeeded, which is what matters.
  warn "Retention step failed. Backup itself is safe."
  event "retention_failed" "severity=medium"
fi

# ---------------------------------------------------------------------------
# STEP 9. Report
# ---------------------------------------------------------------------------
SNAP_COUNT="$(restic snapshots --host "$BACKUP_HOST" --json 2>/dev/null | jq 'length' 2>/dev/null || echo '?')"
event "backup_run_complete" "snapshots_retained=${SNAP_COUNT}"

printf '\n'
ok "Done. ${SNAP_COUNT} snapshot(s) retained for host ${BACKUP_HOST}."
printf '    Restore with : ./backup/restore.sh\n'
printf '    Verify with  : ./backup/backup.sh --check\n\n'
