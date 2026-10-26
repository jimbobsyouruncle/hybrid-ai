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
#   2. Refreshes the read-only agent repo reference tree Hermes reads at
#      /agent-repos, so it is current even if a later step fails or stops. A
#      failure here is a warning, not a stop, and it needs no prompt (it runs in
#      both interactive and --non-interactive modes).
#   3. Loads your existing .env file, if there is one, so it only asks you for
#      things it does not already know. It evaluates the version to determine
#      if the structure needs to be upgraded.
#   4. Reads your Pi's RAM and works out a safe memory budget for Ollama.
#   5. Generates a login-session encryption key, but only the first time.
#   6. Prompts you for your local domain, OpenRouter key, and RunPod credentials.
#   7. Asks Tailscale for the network address of your cloud GPU pod (read-only).
#      It does NOT start the pod unless you opt in: set RUNPOD_AUTO_WAKE=1 (or
#      true) in .env, or pass --wake-runpod for a single run. Off by default.
#   8. Creates the data folders if they do not exist (never overwrites them).
#   9. Writes the .env file with locked-down permissions.
#  10. Starts the core stack, OpenHands, Hermes Agent, and status reverse proxy,
#      then closes the sandbox port exposure with DOCKER-USER drops.
#  11. Verifies local DNS resolution for your subdomains and gives exact Pi-hole rules.
#
# HOW TO RUN IT:
#   ./install.sh                   normal, interactive -- asks for anything missing
#   ./install.sh --non-interactive  never prompts; fails instead. Used by CI.
#   ./install.sh --no-start          write .env but do not touch Docker
#   ./install.sh --wake-runpod       start the RunPod GPU pod this run if it is
#                                    offline, even if RUNPOD_AUTO_WAKE=0
#                                    (RUNPOD_AUTO_WAKE=1 in .env does it every run)
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

# Every host path comes from the ONE shared helper. With no settings, the
# resolved paths are exactly today's.
# shellcheck source=scripts/lib/hybrid-ai-env.sh
source "${SCRIPT_DIR}/scripts/lib/hybrid-ai-env.sh"
# shellcheck source=scripts/lib/build-gate.sh
source "${SCRIPT_DIR}/scripts/lib/build-gate.sh"

APP_DIR="$HYBRID_AI_APP_DIR"
# The stack's env file: the one handed to `docker compose --env-file` and the
# one this installer WRITES. HYBRID_AI_ENV_FILE is the layout file and is only
# ever read. With HYBRID_AI_STACK_ENV_FILE unset the two are the same path, so
# behaviour is byte-identical to before.
ENV_FILE="$HYBRID_AI_STACK_ENV_FILE"
DATA_DIR="$HYBRID_AI_DATA_DIR"
LOG_DIR="$HYBRID_AI_LOG_DIR"
WORK_DIR="$HYBRID_AI_WORK_DIR"
TARGET_ENV_VERSION="2"

# Peer hostnames to search for, in priority order.
PEER_HOSTNAMES="${PEER_HOSTNAMES:-runpod-worker runpod-vllm}"
PEER_HOSTNAME="${PEER_HOSTNAME:-${PEER_HOSTNAMES%% *}}"
NON_INTERACTIVE=0
NO_START=0
WAKE_RUNPOD_FLAG=0

for arg in "$@"; do
  case "$arg" in
    --non-interactive) NON_INTERACTIVE=1 ;;
    --no-start)         NO_START=1 ;;
    --wake-runpod)      WAKE_RUNPOD_FLAG=1 ;;
    -h|--help)
      sed -n '2,38p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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
log()  { printf '%s[ * ]%s %s %s\n' "$C_INF" "$C_RST" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_OK"  "$C_RST" "$*"; }
warn() { printf '%s[ ! ]%s %s\n'  "$C_WRN" "$C_RST" "$*" >&2; }
die()  { printf '%s[ X ]%s %s\n'  "$C_ERR" "$C_RST" "$*" >&2; exit 1; }
hr()   { printf '%s%s%s\n' "$C_DIM" "------------------------------------------------------------" "$C_RST"; }

INSTALL_LOG="$HYBRID_AI_INSTALL_LOG"
event() {
  local name="$1"; shift
  printf 'EVENT ts=%s event=%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$name" "$*" \
    >> "$INSTALL_LOG" 2>/dev/null || true
}
touch "$INSTALL_LOG" 2>/dev/null && chmod 600 "$INSTALL_LOG" 2>/dev/null || true
event "install_start" "args=$*" "user=${USER:-unknown}"

trap 'event "install_aborted" "line=${LINENO}"; die "Failed at line ${LINENO}: ${BASH_COMMAND}"' ERR
# The progress heartbeat must never outlive the run that started it.
trap 'hybrid_progress_stop' EXIT

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
for _s in scripts/setup-agent-workspace.sh scripts/sync-agent-repos.sh \
          scripts/sandbox-firewall.sh \
          openhands/scripts/openhands-control.sh \
          doctor.sh collect-diagnostics.sh backup/backup.sh backup/restore.sh \
          runpod/start.sh; do
  _f="${APP_DIR}/${_s}"
  [[ -f "$_f" ]] || continue
  if [[ ! -x "$_f" ]]; then
    if chmod +x "$_f" 2>/dev/null; then
      ok "Made ${_s} executable."
    else
      warn "Could not chmod +x ${_s}. Run it manually: chmod +x ${_s}"
    fi
  fi
done
unset _s _f

# ---------------------------------------------------------------------------
# Refresh the read-only reference tree Hermes sees at /agent-repos first, so it
# is current even when a later install step fails or stops. A failure here is a
# warning, not a stop, and it needs no prompt. The script reads AGENT_REPOS_DIR
# and OPENHANDS_WORKSPACE from the environment, or parses .env itself, and falls
# back to the same defaults this installer writes below.
# ---------------------------------------------------------------------------
log "Syncing the read-only agent repo reference tree..."
"${APP_DIR}/scripts/sync-agent-repos.sh" \
  || warn "Agent repo sync failed; Hermes sees a stale tree at ${AGENT_REPOS_DIR}. Re-run scripts/sync-agent-repos.sh by hand."

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
# STEP 2b. Migrate stale OpenHands image pins
# ---------------------------------------------------------------------------
# Older installs pinned the app-server at :1.8 and the agent-server at
# 1.26.0-python. Those images embed credentials in git clone URLs and reach
# model context, which 1.10 / 1.37.1-python fix. Older installs also set
# OPENHANDS_AGENT_IMAGE_REPOSITORY to the canonical ghcr.io/openhands/agent-server,
# which the app server reserves for its own bundled SDK version: with that exact
# repository set it silently re-pins AGENT_SERVER_IMAGE_TAG, so the 1.37.1-python
# tag never takes effect. STEP 8 rewrites the .env as ${VAR:-default}, so a stale
# value loaded above would survive every deploy and the new default would never
# take effect. Unset the EXACT stale values here so the ${VAR:-default} in STEP 8
# then writes the new pin. Any other value is an owner-chosen pin and is preserved
# untouched. Idempotent: after one run the loaded value no longer matches, so a
# second run migrates nothing.
#
# The next migration cuts the sandbox over from the stock agent-server to the
# derived hybrid image (ghcr.io/jimbobsyouruncle/openhands-agent-server-hybrid),
# which adds the tooling the repo's ShellCheck gate needs. It is PAIR-EXACT on
# purpose: it unsets OPENHANDS_AGENT_IMAGE_REPOSITORY and
# OPENHANDS_AGENT_IMAGE_TAG only when BOTH load as the OLD default pair
# (docker.openhands.dev/openhands/agent-server AND 1.37.1-python). A deployed
# host carries that pair verbatim, so the two independent unsets above would not
# clear it and ${VAR:-default} in STEP 8 would keep the stale pair forever. The
# pair check is used instead of two independent unsets so that a host which
# customised EITHER half is treated as an owner-chosen pin: unsets keyed off the
# value alone would silently reset a custom tag to the new default. On a partial
# match both values are left untouched and the pin is logged as left alone.
#
# The next migration cuts the hybrid image over from the TAGGED build it first
# shipped (ghcr.io/jimbobsyouruncle/openhands-agent-server-hybrid at
# 1.37.1-python-hybrid.1) to the current hybrid tag (the hybrid.3 build, whose
# Semgrep is raised to 1.179.0 to match the CI SAST gate). This one is PAIR-EXACT
# too, and for the same reason: an already-migrated host carries the hybrid.1
# pair verbatim in its stack env, and STEP 8 preserves an explicit value as an
# owner pin, so without this branch the host would stay on hybrid.1 forever. The
# pair check keeps a host which customised EITHER half (a private repository, or
# a self-built tag) on its owner-chosen pin -- unsets keyed off the value alone
# would silently reset it. Idempotent: after one run the loaded pair no longer
# matches, so a second run migrates nothing.
#
# The final migration is the last one: it bumps the hybrid.2 pair (the hybrid.2
# build, whose ShellCheck was raised to 0.11.0) to the current hybrid.3 tag. It
# is PAIR-EXACT for the same reason again -- a host that already took hybrid.2
# carries that pair verbatim, and STEP 8 would preserve it as an owner pin, so
# without this branch the host would stay on hybrid.2 forever. Idempotent: after
# one run the loaded pair no longer matches, so a second run migrates nothing.
if [[ "${OPENHANDS_IMAGE:-}" == "docker.openhands.dev/openhands/openhands:1.8" ]]; then
  log "Migrating OPENHANDS_IMAGE off the stale :1.8 pin to the current default."
  unset OPENHANDS_IMAGE
fi
if [[ "${OPENHANDS_AGENT_IMAGE_TAG:-}" == "1.26.0-python" ]]; then
  log "Migrating OPENHANDS_AGENT_IMAGE_TAG off the stale 1.26.0-python pin to the current default."
  unset OPENHANDS_AGENT_IMAGE_TAG
fi
if [[ "${OPENHANDS_AGENT_IMAGE_REPOSITORY:-}" == "ghcr.io/openhands/agent-server" ]]; then
  log "Migrating OPENHANDS_AGENT_IMAGE_REPOSITORY off the canonical ghcr.io/openhands/agent-server repository to the current default."
  unset OPENHANDS_AGENT_IMAGE_REPOSITORY
fi
if [[ "${OPENHANDS_AGENT_IMAGE_REPOSITORY:-}" == "docker.openhands.dev/openhands/agent-server" \
   && "${OPENHANDS_AGENT_IMAGE_TAG:-}" == "1.37.1-python" ]]; then
  log "Migrating the stock agent-server pin (docker.openhands.dev/openhands/agent-server:1.37.1-python) to the derived hybrid image."
  unset OPENHANDS_AGENT_IMAGE_REPOSITORY
  unset OPENHANDS_AGENT_IMAGE_TAG
elif [[ "${OPENHANDS_AGENT_IMAGE_REPOSITORY:-}" == "ghcr.io/jimbobsyouruncle/openhands-agent-server-hybrid" \
     && "${OPENHANDS_AGENT_IMAGE_TAG:-}" == "1.37.1-python-hybrid.1" ]]; then
  log "Migrating the derived hybrid image pin (ghcr.io/jimbobsyouruncle/openhands-agent-server-hybrid:1.37.1-python-hybrid.1) to the current hybrid tag."
  unset OPENHANDS_AGENT_IMAGE_REPOSITORY
  unset OPENHANDS_AGENT_IMAGE_TAG
elif [[ "${OPENHANDS_AGENT_IMAGE_REPOSITORY:-}" == "ghcr.io/jimbobsyouruncle/openhands-agent-server-hybrid" \
     && "${OPENHANDS_AGENT_IMAGE_TAG:-}" == "1.37.1-python-hybrid.2" ]]; then
  log "Migrating the derived hybrid image pin (ghcr.io/jimbobsyouruncle/openhands-agent-server-hybrid:1.37.1-python-hybrid.2) to the current hybrid tag."
  unset OPENHANDS_AGENT_IMAGE_REPOSITORY
  unset OPENHANDS_AGENT_IMAGE_TAG
elif [[ -n "${OPENHANDS_AGENT_IMAGE_REPOSITORY:-}" || -n "${OPENHANDS_AGENT_IMAGE_TAG:-}" ]]; then
  log "Leaving the OpenHands agent-server image pin alone (not a known stale default pair)."
fi

# The shared helper above already resolved every LAYOUT-managed setting from
# HYBRID_AI_ENV_FILE (the layout file): the host paths, the agent workspace, the
# Hermes home, the mode selectors and the identity that decides which uid the
# whole stack runs as. The stack file loaded just above supplies runtime config
# and secrets only. On a bootstrapped host the two files are DIFFERENT, and a
# legacy stack file still carries the OLD values (empty HYBRID_AI_UID=, the login
# home's OPENHANDS_WORKSPACE, and so on). Letting those win would drop the stack
# to uid 0 and point the containers at the trees migration moved away, so restore
# the layout-resolved values here.
#
# When HYBRID_AI_STACK_ENV_FILE is unset the stack file IS the layout file and
# the helper read the SAME file, so every line below is an exact no-op.
HYBRID_AI_UID="$HYBRID_AI_LAYOUT_UID"
HYBRID_AI_GID="$HYBRID_AI_LAYOUT_GID"
OPENHANDS_WORKSPACE="$HYBRID_AI_LAYOUT_OPENHANDS_WORKSPACE"
AGENT_REPOS_DIR="$HYBRID_AI_LAYOUT_AGENT_REPOS_DIR"
OPENHANDS_STATE_DIR="$HYBRID_AI_LAYOUT_OPENHANDS_STATE_DIR"
export HYBRID_AI_UID HYBRID_AI_GID OPENHANDS_WORKSPACE AGENT_REPOS_DIR OPENHANDS_STATE_DIR

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
# STEP 3b. Identity for the status container and the sandbox
# ---------------------------------------------------------------------------
# When HYBRID_AI_UID/HYBRID_AI_GID are set, they drive BOTH the status
# container uid and the OpenHands sandbox uid, so the whole stack runs as the
# dedicated non-root service account. Unset keeps today's behaviour exactly:
# the login account's uid/gid.
STATUS_UID="${HYBRID_AI_UID:-$(id -u)}"
STACK_GID="${HYBRID_AI_GID:-$(id -g)}"
if [[ -S /var/run/docker.sock ]]; then
  DOCKER_GID="$(stat -c '%g' /var/run/docker.sock 2>/dev/null || echo 999)"
else
  DOCKER_GID="$(getent group docker 2>/dev/null | cut -d: -f3 || echo 999)"
  DOCKER_GID="${DOCKER_GID:-999}"
fi
ok "status page identity: uid=${STATUS_UID} docker gid=${DOCKER_GID}"
if [[ -n "${HYBRID_AI_UID:-}" ]]; then
  ok "stack runs as HYBRID_AI_UID=${STATUS_UID} gid=${STACK_GID}"
fi

# The backup log's group gid. In system mode the log is 0640 owned by
# hybrid-ai-backup, and the status container reads it through exactly one
# supplementary group, so the gid must be the hybrid-ai-backup group's. It is
# resolved BY NAME (numeric ids differ per host and appear nowhere in the repo)
# and this installer fails closed if the group cannot be found: a status
# container with the wrong gid leaves the Backups tile blind while the backup
# log reports success.
# In user mode the log stays 0600 owned by the invoking account, so the only
# value that grants nothing new is the primary gid the container already has.
if [[ "$HYBRID_AI_BACKUP_MODE" == "system" ]]; then
  BACKUP_GROUP_GID_DEFAULT="$(getent group hybrid-ai-backup 2>/dev/null | cut -d: -f3 || true)"
  [[ "$BACKUP_GROUP_GID_DEFAULT" =~ ^[0-9]+$ ]] \
    || die "the hybrid-ai-backup group does not exist, so the status container cannot be granted read access to BACKUP_LOG. Create it (useradd --system hybrid-ai-backup) and re-run ./install.sh."
else
  BACKUP_GROUP_GID_DEFAULT="${DOCKER_GID:-999}"
fi
ok "backup log group gid for the status container: ${BACKUP_GROUP_GID_DEFAULT}"

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

# RunPod auto-wake is opt-in: only the exact values "1" or "true" in
# RUNPOD_AUTO_WAKE, or the --wake-runpod flag (this run only), enable it.
# The setting itself is written back to .env unchanged by the Step 8 rewrite.
RUNPOD_AUTO_WAKE="${RUNPOD_AUTO_WAKE:-0}"
WAKE_ENABLED=0
if (( WAKE_RUNPOD_FLAG )) || [[ "$RUNPOD_AUTO_WAKE" == "1" || "$RUNPOD_AUTO_WAKE" == "true" ]]; then
    WAKE_ENABLED=1
fi

if [[ "$PEER_ONLINE" != "true" && "$WAKE_ENABLED" != "1" ]]; then
    log "RunPod auto-wake disabled (RUNPOD_AUTO_WAKE=${RUNPOD_AUTO_WAKE}); not starting the GPU pod."
fi

if [[ "$PEER_ONLINE" != "true" && "$WAKE_ENABLED" == "1" ]]; then
    if [[ -n "${RUNPOD_API_KEY:-}" && -n "${RUNPOD_POD_ID:-}" ]]; then
        warn "Peer '${PEER_HOSTNAME}' is offline or missing. Checking RunPod status..."
        
        RUNPOD_STATUS=$(curl -s -X POST \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer ${RUNPOD_API_KEY}" \
            -d "{\"query\": \"query { pod(input: {podId: \\\"${RUNPOD_POD_ID}\\\"}) { id desiredStatus } }\"}" \
            https://api.runpod.io/graphql | jq -r '.data.pod.desiredStatus // "STOPPED"' 2>/dev/null || echo "UNKNOWN")

        if [ "$RUNPOD_STATUS" != "RUNNING" ]; then
            warn "RunPod worker is stopped. Sending start command for pod ${RUNPOD_POD_ID}..."
            curl -s -X POST \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer ${RUNPOD_API_KEY}" \
                -d "{\"query\": \"mutation { podResume(input: {podId: \\\"${RUNPOD_POD_ID}\\\"}) { id desiredStatus } }\"}" \
                https://api.runpod.io/graphql > /dev/null || warn "RunPod resume request failed; continuing."
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
    elif [[ "$WAKE_ENABLED" == "1" ]]; then
        ok "Peer '${MATCHED_PEER}' known at ${TAILSCALE_IP} (offline — worker did not respond to wake)"
    else
        ok "Peer '${MATCHED_PEER}' known at ${TAILSCALE_IP} (offline — auto-wake disabled)"
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

# --- OpenHands: workspace path and browser-reachable sandbox host ----------
# OPENHANDS_WORKSPACE is resolved by the shared helper above, from the
# environment, an existing env file, or the default sibling directory.
# AGENT_REPOS_DIR is resolved by the shared helper the same way. Refreshed near
# the start of every run by scripts/sync-agent-repos.sh, before .env is loaded.
if [[ -z "${OPENHANDS_SANDBOX_HOST:-}" ]]; then
  _default_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')"
  if (( NON_INTERACTIVE )); then
    OPENHANDS_SANDBOX_HOST="$_default_ip"
    warn "OPENHANDS_SANDBOX_HOST defaulted to ${OPENHANDS_SANDBOX_HOST}"
  else
    read -r -p "    Host your browser uses to reach this Pi (e.g. jarvis.lan) [${_default_ip}]: " OPENHANDS_SANDBOX_HOST < /dev/tty
    OPENHANDS_SANDBOX_HOST="${OPENHANDS_SANDBOX_HOST:-$_default_ip}"
  fi
  unset _default_ip
fi
[[ -n "$OPENHANDS_SANDBOX_HOST" ]] || die "OPENHANDS_SANDBOX_HOST could not be determined."

# ---------------------------------------------------------------------------
# STEP 7. Data folders
# ---------------------------------------------------------------------------
log "Ensuring persistent host mounts..."

for f in "$HYBRID_AI_INSTALL_LOG" "$BACKUP_LOG"; do
  if [[ "$HYBRID_AI_BACKUP_MODE" == "system" && "$f" == "$BACKUP_LOG" ]]; then
    # In system mode the backup log lives in the units' LogsDirectory=
    # (/var/log/hybrid-ai-backup) and is written by the hybrid-ai-backup account.
    # install.sh must not leave a root:root 0600 file the account cannot append
    # to: as root it repairs the ownership of an existing file; otherwise it
    # leaves the path to LogsDirectory=, which systemd creates and owns on the
    # first unit start. User mode is unchanged (the log is created 0600 by the
    # invoking account, below).
    # The repair makes the file readable by the account that writes it AND by
    # the status container's supplementary group (0640, group hybrid-ai-backup).
    # It never widens the log to the world, and it converges an existing host on
    # the next deploy with no by-hand chmod or chown step.
    if [[ -e "$f" && "$(id -u)" == "0" ]]; then
      chown hybrid-ai-backup:hybrid-ai-backup "$f" 2>/dev/null || true
      chmod 640 "$f" 2>/dev/null || true
    fi
    continue
  fi
  [[ -e "$f" ]] || { : > "$f"; chmod 600 "$f"; }
  if [[ -d "$f" ]]; then
    warn "$(basename "$f") is a directory (created by an earlier Docker run). Replacing it."
    rmdir "$f" 2>/dev/null && : > "$f" && chmod 600 "$f"
  fi
done

mkdir -p "$HYBRID_AI_WEBUI_DATA_DIR/caddy"
mkdir -p "$HYBRID_AI_HERMES_DATA_DIR"

mkdir -p "$OPENHANDS_STATE_DIR"
chmod 700 "$OPENHANDS_STATE_DIR"

mkdir -p "$RESTIC_CACHE_DIR"

for d in "$HYBRID_AI_OLLAMA_DATA_DIR" "$HYBRID_AI_WEBUI_DATA_DIR" "$HYBRID_AI_HERMES_DATA_DIR"; do
  if [[ -d "$d" ]]; then
    ok "$d exists ($(du -sh "$d" 2>/dev/null | cut -f1 || echo '0') on disk) -- untouched."
  else
    mkdir -p "$d"
    ok "$d created."
  fi
done

# ---------------------------------------------------------------------------
# STEP 8. Write .env
# ---------------------------------------------------------------------------
log "Writing ${ENV_FILE} ..."

TMP_ENV="$(mktemp "$(dirname -- "$ENV_FILE")/.env.XXXXXX")"
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
RUNPOD_AUTO_WAKE=${RUNPOD_AUTO_WAKE}
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
# Dedicated non-root uid/gid for the Hermes image. No default is written: leaving
# these unset keeps the legacy uid 0. Set them during the account migration.
HYBRID_AI_UID=${HYBRID_AI_UID:-}
HYBRID_AI_GID=${HYBRID_AI_GID:-}

# --- Host paths (optional relocation) --------------------------------------
# All host paths resolve through scripts/lib/hybrid-ai-env.sh. Left commented,
# they default to the deployment directory; uncomment to split the layout.
#HYBRID_AI_APP_DIR=${APP_DIR}
#HYBRID_AI_DATA_DIR=${DATA_DIR}
#HYBRID_AI_LOG_DIR=${LOG_DIR}
#HYBRID_AI_WORK_DIR=${WORK_DIR}

# The post-deploy verifier's log. Unlike the paths above this one is WRITTEN,
# not commented: docker-compose.yml interpolates it for the status service's
# read-only mount and refuses a bind whose source is unset. Written as
# ${VAR:-default} so an owner override in this file survives every reinstall.
HYBRID_AI_POST_DEPLOY_VERIFY_LOG=${HYBRID_AI_POST_DEPLOY_VERIFY_LOG:-/var/log/hybrid-ai-post-deploy-verify.log}

# The backup log the status service mounts read-only. WRITTEN, not commented:
# docker-compose.yml interpolates BACKUP_LOG fail-closed for that bind. The
# value is the one scripts/lib/hybrid-ai-env.sh already resolved from the mode
# (user: $HYBRID_AI_LOG_DIR/backup.log, system: the units' LogsDirectory=), so
# the reader cannot drift from the writer.
BACKUP_LOG=${BACKUP_LOG}

# The ONE supplementary group the status container is given, so it can read the
# backup log without the file becoming world-readable and without the service
# running as root. Scripts/lib/hybrid-ai-env.sh does not resolve this setting;
# install.sh does, by NAME: the hybrid-ai-backup group's gid in system mode (the
# log's group owner), and the container's own primary gid in user mode (which
# grants no new access). Written as ${VAR:-default} so an owner override
# survives every reinstall. docker-compose.yml fails closed if it is unset.
BACKUP_GROUP_GID=${BACKUP_GROUP_GID:-${BACKUP_GROUP_GID_DEFAULT}}

# --- OpenHands maintenance agent -------------------------------------------
OPENHANDS_PORT=${OPENHANDS_PORT:-3001}
OPENHANDS_WORKSPACE=${OPENHANDS_WORKSPACE}
# Read-only local copy of every non-fork repo you own. Mounted into Hermes at
# /agent-repos. Refreshed on every deploy by scripts/sync-agent-repos.sh.
AGENT_REPOS_DIR=${AGENT_REPOS_DIR}
OPENHANDS_SANDBOX_HOST=${OPENHANDS_SANDBOX_HOST}
OPENHANDS_STATE_DIR=${OPENHANDS_STATE_DIR}
OPENHANDS_IMAGE=${OPENHANDS_IMAGE:-docker.openhands.dev/openhands/openhands:1.10}
OPENHANDS_AGENT_IMAGE_REPOSITORY=${OPENHANDS_AGENT_IMAGE_REPOSITORY:-ghcr.io/jimbobsyouruncle/openhands-agent-server-hybrid}
OPENHANDS_AGENT_IMAGE_TAG=${OPENHANDS_AGENT_IMAGE_TAG:-1.37.1-python-hybrid.3}
OPENHANDS_STARTUP_GRACE_SECONDS=${OPENHANDS_STARTUP_GRACE_SECONDS:-120}
OPENHANDS_LOG_ALL_EVENTS=${OPENHANDS_LOG_ALL_EVENTS:-false}
OPENHANDS_MEM_LIMIT=${OPENHANDS_MEM_LIMIT:-3g}
OPENHANDS_CPUS=${OPENHANDS_CPUS:-2.5}

# --- Docker build-cache cap ------------------------------------------------
# hybrid-ai-docker-prune.timer runs scripts/prune-docker-cache.sh daily at
# 04:35 to cap the Docker BUILD CACHE (cache only; never images, containers,
# volumes or bind-mounted data). This size is handed to whichever cap flag the
# local docker supports (--max-used-space, else --keep-storage).
HYBRID_AI_BUILD_CACHE_CAP=${HYBRID_AI_BUILD_CACHE_CAP:-15GB}

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
  "${APP_DIR}/scripts/setup-agent-workspace.sh" --non-interactive \
    || warn "Agent workspace setup failed; OpenHands will not start until it exists."
else
  "${APP_DIR}/scripts/setup-agent-workspace.sh" \
    || warn "Agent workspace setup failed; OpenHands will not start until it exists."
fi

prepare_openhands_workspace() {
  # -n: fail instead of prompting for a password, so CI never hangs.
  local SUDO=(sudo)
  if (( NON_INTERACTIVE )); then SUDO=(sudo -n); fi
  if ! command -v setfacl >/dev/null 2>&1; then
    "${SUDO[@]}" apt-get install -y acl || return 1
  fi
  local img="${OPENHANDS_AGENT_IMAGE_REPOSITORY:-ghcr.io/jimbobsyouruncle/openhands-agent-server-hybrid}:${OPENHANDS_AGENT_IMAGE_TAG:-1.37.1-python-hybrid.3}"
  docker pull -q "$img" >/dev/null || return 1
  local uid
  uid="$(docker run --rm --entrypoint id "$img" -u openhands)" || return 1
  [[ -d "$OPENHANDS_WORKSPACE/.git" ]] || return 1
  mkdir -p "$OPENHANDS_WORKSPACE/project" "$OPENHANDS_WORKSPACE/conversations"
  # The overlay bind-mounts this file at /etc/gitconfig. The mount source must
  # exist before docker starts the sandbox, or docker creates a DIRECTORY in its
  # place. 0644 so the sandbox uid can read it; re-running rewrites it.
  install -m 0644 "${APP_DIR}/openhands/sandbox-gitconfig" \
    "$OPENHANDS_WORKSPACE/.sandbox-gitconfig" || return 1
  "${SUDO[@]}" chown -R "${STATUS_UID}:${STACK_GID}" "$OPENHANDS_WORKSPACE/project" "$OPENHANDS_WORKSPACE/conversations" "$OPENHANDS_WORKSPACE/.sandbox-gitconfig" || return 1
  "${SUDO[@]}" setfacl -R -m "u:${uid}:rwx" "$OPENHANDS_WORKSPACE" || return 1
  "${SUDO[@]}" setfacl -R -d -m "u:${uid}:rwx" "$OPENHANDS_WORKSPACE" || return 1
  # Keep agent runtime folders out of the clone's git status
  local ex="$OPENHANDS_WORKSPACE/.git/info/exclude" d
  for d in conversations/ project/ .sandbox-gitconfig; do grep -qxF "$d" "$ex" 2>/dev/null || echo "$d" >> "$ex"; done
  ok "OpenHands workspace ready for sandbox uid ${uid}."
}
prepare_openhands_workspace || warn "OpenHands workspace ACLs not applied (needs sudo). Re-run ./install.sh interactively, then check with ./doctor.sh"

# ---------------------------------------------------------------------------
# STEP 9a. Install and enable the boot firewall unit
# ---------------------------------------------------------------------------
# STEP 9b applies the DOCKER-USER rules for this run, but Docker recreates an
# empty DOCKER-USER chain on every boot, so those rules are gone after a reboot.
# hybrid-ai-firewall.service re-applies them at boot. scripts/bootstrap.sh has
# always installed and enabled it; the deploy path did not, so a host deployed
# for weeks could reboot with an empty chain. Install it on every deploy.
#
# This sits before the --no-start exit so both paths install the unit. Enable
# ONLY: STEP 9b already applied the rules, this is boot persistence, so no
# --now, no start and no restart.
#
# Fail-safe, never fail-closed: it never calls sudo, never dies and never
# changes this script's exit status. Without root, systemctl or the unit
# template it warns and records an event.
#
# HYBRID_AI_SYSTEMD_UNIT_DIR is a HARNESS-ONLY override for
# scripts/test-install-health.sh, which installs into a scratch directory. Do
# not document it: it is not in .env.example and not in STEP 8's .env template.
install_firewall_unit() {
  local unit="hybrid-ai-firewall.service"
  local unit_dir="${HYBRID_AI_SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
  local source_file="${APP_DIR}/deploy/${unit}"
  local target_file="${unit_dir}/${unit}"
  local was_enabled=0

  if [[ "$(id -u)" != "0" ]]; then
    warn "hybrid-ai-firewall.service needs root to install into ${unit_dir}; not calling sudo."
    warn "Re-run ./install.sh as root so the boot firewall unit is installed and enabled."
    event "sandbox_firewall_unit_failed" "reason=not_root"
    return 0
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    warn "systemctl is unavailable; install and enable ${unit} by hand."
    event "sandbox_firewall_unit_failed" "reason=systemctl_missing"
    return 0
  fi

  if [[ ! -f "$source_file" ]]; then
    warn "Missing firewall unit file: ${source_file}"
    event "sandbox_firewall_unit_failed" "reason=template_missing"
    return 0
  fi

  if ! install -m 0644 "$source_file" "${target_file}.tmp"; then
    rm -f "${target_file}.tmp"
    warn "Could not stage ${unit} in ${unit_dir}."
    event "sandbox_firewall_unit_failed" "reason=copy_failed"
    return 0
  fi
  if ! mv -f "${target_file}.tmp" "$target_file"; then
    warn "Could not move ${unit} into ${unit_dir}."
    event "sandbox_firewall_unit_failed" "reason=move_failed"
    return 0
  fi

  if ! systemctl daemon-reload; then
    warn "system daemon reload failed; ${unit} is installed but may not be visible yet."
    event "sandbox_firewall_unit_failed" "reason=daemon_reload"
    return 0
  fi

  if systemctl is-enabled "$unit" >/dev/null 2>&1; then
    was_enabled=1
  fi

  if ! systemctl enable "$unit" >/dev/null 2>&1; then
    warn "Could not enable ${unit}; boot firewall persistence is not in place."
    event "sandbox_firewall_unit_failed" "reason=enable"
    return 0
  fi

  if [[ "$(systemctl is-enabled "$unit" 2>/dev/null)" != "enabled" ]]; then
    warn "${unit} is installed but not enabled; the boot firewall rules stay off."
    event "sandbox_firewall_unit_failed" "reason=not_enabled"
    return 0
  fi

  if (( was_enabled )); then
    ok "${unit} already enabled (boot firewall persistence in place)."
  else
    ok "Installed and enabled ${unit} (boot firewall persistence)."
  fi
  event "sandbox_firewall_unit_installed"
  return 0
}

# ---------------------------------------------------------------------------
# STEP 9a-1. Re-apply the headless-deploy wiring (system unit + polkit rule)
# ---------------------------------------------------------------------------
# scripts/bootstrap.sh installs these ONCE, on a fresh device. Until now that was
# the only install path, so a later fix to either file never reached a host that
# had already been bootstrapped. On 2026-10-22 the host enforced a stale
# TimeoutStartSec=20min against the tree's 45min and SIGTERM'd a deploy
# mid-build; the raise had to be copied over by hand.
#
# Re-applying on every deploy closes that gap: the files here are tracked and
# review-gated, so the host always matches the tree it is deploying.
#
# SELF-REFERENCE IS SAFE AND INTENDED. During a deploy this script runs INSIDE a
# running instance of this very unit. The running instance keeps the
# configuration it loaded; overwriting the file plus `systemctl daemon-reload`
# only changes what the NEXT instantiation starts with. The current deploy is
# unaffected, and the new content takes effect from the next deploy.
#
# NEVER enable and NEVER start the unit: it is an instantiated template, and the
# polkit rule grants only `start` of `hybrid-ai-deploy@<40-hex>.service`. No
# `Restart=` policy is added either (incident B1).
#
# Both functions sit before the --no-start exit so both paths place the files,
# and neither is gated on HYBRID_AI_BACKUP_MODE: this is not backup related.
#
# Fail-safe, never fail-closed: no sudo, never dies and never changes this
# script's exit status. A failed copy leaves the previous file in place, so the
# host keeps working with the unit it already has.
#
# HYBRID_AI_SYSTEMD_UNIT_DIR and HYBRID_AI_POLKIT_RULES_DIR are the HARNESS-ONLY
# overrides for scripts/test-deploy-wiring-install.sh, which installs into
# scratch directories. Do not document them.
install_deploy_unit() {
  local unit="hybrid-ai-deploy@.service"
  local unit_dir="${HYBRID_AI_SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
  local source_file="${APP_DIR}/deploy/${unit}"
  local target_file="${unit_dir}/${unit}"

  if [[ "$(id -u)" != "0" ]]; then
    warn "${unit} needs root to install into ${unit_dir}; not calling sudo."
    warn "Re-run ./install.sh as root so the headless-deploy unit is re-applied."
    event "deploy_unit_install_failed" "reason=not_root"
    return 0
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    warn "systemctl is unavailable; install ${unit} by hand."
    event "deploy_unit_install_failed" "reason=systemctl_missing"
    return 0
  fi

  if [[ ! -f "$source_file" ]]; then
    warn "Missing deploy unit file: ${source_file}"
    event "deploy_unit_install_failed" "reason=template_missing"
    return 0
  fi

  if ! install -m 0644 "$source_file" "${target_file}.tmp"; then
    rm -f "${target_file}.tmp"
    warn "Could not stage ${unit} in ${unit_dir}."
    event "deploy_unit_install_failed" "reason=copy_failed"
    return 0
  fi
  if ! mv -f "${target_file}.tmp" "$target_file"; then
    warn "Could not move ${unit} into ${unit_dir}."
    event "deploy_unit_install_failed" "reason=move_failed"
    return 0
  fi

  if ! systemctl daemon-reload; then
    warn "system daemon reload failed; ${unit} is installed but may not be visible yet."
    event "deploy_unit_install_failed" "reason=daemon_reload"
    return 0
  fi

  ok "Re-applied ${unit} (never enabled; effective from the next deploy)."
  event "deploy_unit_installed"
  return 0
}

# The polkit rule is copied byte-identical from the tree: it grants `start` of one
# unit shape and nothing else. The first existing rules directory wins, in the
# same order scripts/bootstrap.sh probes.
install_deploy_polkit_rule() {
  local rule="50-hybrid-ai-deploy.rules"
  local source_file="${APP_DIR}/deploy/${rule}"
  local polkit_dir="" target_file="" d

  if [[ "$(id -u)" != "0" ]]; then
    warn "${rule} needs root to install; not calling sudo."
    warn "Re-run ./install.sh as root so the deploy polkit rule is re-applied."
    event "deploy_polkit_rule_install_failed" "reason=not_root"
    return 0
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    warn "systemctl is unavailable; install ${rule} and reload polkit by hand."
    event "deploy_polkit_rule_install_failed" "reason=systemctl_missing"
    return 0
  fi

  for d in ${HYBRID_AI_POLKIT_RULES_DIR:+"$HYBRID_AI_POLKIT_RULES_DIR"} \
           /etc/polkit-1/rules.d /usr/share/polkit-1/rules.d; do
    if [[ -d "$d" ]]; then polkit_dir="$d"; break; fi
  done
  if [[ -z "$polkit_dir" ]]; then
    warn "No polkit rules directory found; install ${rule} by hand."
    event "deploy_polkit_rule_install_failed" "reason=rules_dir_missing"
    return 0
  fi

  if [[ ! -f "$source_file" ]]; then
    warn "Missing polkit rule file: ${source_file}"
    event "deploy_polkit_rule_install_failed" "reason=template_missing"
    return 0
  fi

  target_file="${polkit_dir}/${rule}"
  if ! install -m 0644 "$source_file" "${target_file}.tmp"; then
    rm -f "${target_file}.tmp"
    warn "Could not stage ${rule} in ${polkit_dir}."
    event "deploy_polkit_rule_install_failed" "reason=copy_failed"
    return 0
  fi
  if ! mv -f "${target_file}.tmp" "$target_file"; then
    warn "Could not move ${rule} into ${polkit_dir}."
    event "deploy_polkit_rule_install_failed" "reason=move_failed"
    return 0
  fi

  if ! { systemctl reload polkit || systemctl restart polkit; }; then
    warn "Could not reload polkit; reload it by hand: systemctl reload polkit"
    event "deploy_polkit_rule_install_failed" "reason=polkit_reload"
    return 0
  fi

  ok "Re-applied ${rule} into ${polkit_dir} (0644)."
  event "deploy_polkit_rule_installed"
  return 0
}

# ---------------------------------------------------------------------------
# STEP 9a-1b. Install the post-deploy verifier
# ---------------------------------------------------------------------------
# scripts/deploy-remote.sh starts this verifier in a transient systemd unit
# after every deploy. It used to point at a file nothing ever installed, so the
# check silently never ran. Copied root:root 0755 from the tree, staged as
# <target>.tmp then moved, so a failed copy leaves any previous file in place.
#
# Fail-safe, never fail-closed: it never calls sudo, never dies and never
# changes this script's exit status. Without root or without the source it warns
# and records an event.
#
# HYBRID_AI_SBIN_DIR is a HARNESS-ONLY override, the same precedent as
# HYBRID_AI_SYSTEMD_UNIT_DIR and HYBRID_AI_POLKIT_RULES_DIR above; it is not
# documented anywhere else.
install_post_deploy_verifier() {
  local source_file="${APP_DIR}/scripts/run-post-deploy-verify.sh"
  local sbin_dir="${HYBRID_AI_SBIN_DIR:-/usr/local/sbin}"
  local target_file="${sbin_dir}/run-post-deploy-verify.sh"

  if [[ "$(id -u)" != "0" ]]; then
    warn "The post-deploy verifier needs root to install into ${sbin_dir}; not calling sudo."
    warn "Re-run ./install.sh as root so post-deploy verification is installed."
    event "post_deploy_verifier_install_failed" "reason=not_root"
    return 0
  fi

  if [[ ! -f "$source_file" ]]; then
    warn "Missing post-deploy verifier: ${source_file}"
    event "post_deploy_verifier_install_failed" "reason=source_missing"
    return 0
  fi

  if ! install -o root -g root -m 0755 "$source_file" "${target_file}.tmp"; then
    rm -f "${target_file}.tmp"
    warn "Could not stage the post-deploy verifier in ${sbin_dir}."
    event "post_deploy_verifier_install_failed" "reason=copy_failed"
    return 0
  fi
  if ! mv -f "${target_file}.tmp" "$target_file"; then
    warn "Could not move the post-deploy verifier into ${sbin_dir}."
    event "post_deploy_verifier_install_failed" "reason=move_failed"
    return 0
  fi

  ok "Installed the post-deploy verifier (0755): ${target_file}"
  event "post_deploy_verifier_installed"
  return 0
}

# ---------------------------------------------------------------------------
# STEP 9a-2. Install and enable the prune units (conversations and Docker cache)
# ---------------------------------------------------------------------------
# Two timers, two independent daily jobs, installed together:
#   * hybrid-ai-prune.timer        (04:20) quarantines stale OpenHands
#     conversations. It QUARANTINES and never deletes them. install.sh also runs
#     the script once after the stack is up (run_prune_catch_up), catch-up only.
#   * hybrid-ai-docker-prune.timer (04:35) caps the Docker BUILD CACHE so
#     repeated rebuilds of the multi-GB stack images cannot fill the disk. It is
#     cache only: no images, containers, volumes or bind-mounted data.
#
# UNCONDITIONAL: this is not gateable and must never appear inside the backup
# gate, because pruning is unrelated to whether backups are configured. It sits
# before the --no-start exit so both deploy paths install the timers.
#
# Fail-safe, never fail-closed: it never calls sudo, never dies and never
# changes this script's exit status. Without root, systemctl or the unit
# template it warns and records an event.
#
# HYBRID_AI_SYSTEMD_UNIT_DIR is the same HARNESS-ONLY override the firewall step
# uses for scripts/test-install-health.sh; it is not documented anywhere else.
install_prune_scheduler() {
  local unit timer
  local unit_dir="${HYBRID_AI_SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
  local units=(hybrid-ai-prune.service hybrid-ai-prune.timer \
               hybrid-ai-docker-prune.service hybrid-ai-docker-prune.timer)
  local timers=(hybrid-ai-prune.timer hybrid-ai-docker-prune.timer)

  if [[ "$(id -u)" != "0" ]]; then
    warn "The prune units need root to install into ${unit_dir}; not calling sudo."
    warn "Re-run ./install.sh as root so the daily conversation prune is scheduled."
    event "prune_schedule_failed" "reason=not_root"
    return 0
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    warn "systemctl is unavailable; install and enable hybrid-ai-prune.timer by hand."
    event "prune_schedule_failed" "reason=systemctl_missing"
    return 0
  fi

  for unit in "${units[@]}"; do
    if [[ ! -f "${APP_DIR}/deploy/${unit}" ]]; then
      warn "Missing prune unit file: ${APP_DIR}/deploy/${unit}"
      event "prune_schedule_failed" "reason=template_missing" "unit=${unit}"
      return 0
    fi
  done

  for unit in "${units[@]}"; do
    local source_file="${APP_DIR}/deploy/${unit}"
    local target_file="${unit_dir}/${unit}"
    if ! install -m 0644 "$source_file" "${target_file}.tmp"; then
      rm -f "${target_file}.tmp"
      warn "Could not stage ${unit} in ${unit_dir}."
      event "prune_schedule_failed" "reason=copy_failed" "unit=${unit}"
      return 0
    fi
    if ! mv -f "${target_file}.tmp" "$target_file"; then
      warn "Could not move ${unit} into ${unit_dir}."
      event "prune_schedule_failed" "reason=move_failed" "unit=${unit}"
      return 0
    fi
  done

  if ! systemctl daemon-reload; then
    warn "system daemon reload failed; the prune units may not be visible yet."
    event "prune_schedule_failed" "reason=daemon_reload"
    return 0
  fi

  # enable and start are separate calls on purpose: scripts/test-install-health.sh
  # asserts that no "enable --now" appears in this script's systemctl argv.
  # Every failure path here warns, names the unit and returns 0: a prune
  # schedule can never fail a deploy.
  for timer in "${timers[@]}"; do
    if ! systemctl enable "$timer" >/dev/null 2>&1; then
      warn "Could not enable ${timer}; that daily prune is not scheduled."
      event "prune_schedule_failed" "reason=enable" "unit=${timer}"
      return 0
    fi
    if ! systemctl start "$timer" >/dev/null 2>&1; then
      warn "Could not start ${timer}; it is enabled but not running."
      event "prune_schedule_failed" "reason=start" "unit=${timer}"
      return 0
    fi
    if [[ "$(systemctl is-enabled "$timer" 2>/dev/null)" != "enabled" ]]; then
      warn "${timer} is installed but not enabled."
      event "prune_schedule_failed" "reason=not_enabled" "unit=${timer}"
      return 0
    fi
    if [[ "$(systemctl is-active "$timer" 2>/dev/null)" != "active" ]]; then
      warn "${timer} is enabled but not active."
      event "prune_schedule_failed" "reason=not_active" "unit=${timer}"
      return 0
    fi
  done

  ok "Installed and enabled hybrid-ai-prune.timer (daily conversation prune) and hybrid-ai-docker-prune.timer (daily Docker build-cache cap)."
  event "prune_schedule_installed"
  return 0
}

# Catch-up prune: the timer above is the primary mechanism. This one-shot call
# exists only for a host that was off or had not re-deployed for a while, so the
# tree is swept once after the stack comes up. It never dies and never changes
# this script's exit status.
run_prune_catch_up() {
  local script="${APP_DIR}/scripts/prune-conversations.sh"

  if [[ ! -f "$script" ]]; then
    warn "Catch-up prune skipped: ${script} is not installed."
    event "prune_catch_up_skipped" "reason=script_missing"
    return 0
  fi

  if ! bash "$script"; then
    warn "Catch-up prune failed; the daily timer will retry. Nothing was deleted."
    event "prune_catch_up_failed"
    return 0
  fi

  ok "Catch-up conversation prune completed (quarantine only)."
  event "prune_catch_up_completed"
  return 0
}

install_firewall_unit || true
install_deploy_unit || true
install_deploy_polkit_rule || true
install_post_deploy_verifier || true
install_prune_scheduler || true

if (( NO_START )); then
  hr; ok "--no-start requested. Environment prepared; Docker untouched."
  warn "Sandbox firewall rules not applied: DOCKER-USER does not exist until Docker starts. hybrid-ai-firewall.service applies them at boot."
  hr
  exit 0
fi

COMPOSE=(
  docker compose
  --env-file "$ENV_FILE"
  --project-directory "$APP_DIR"
  -f "$APP_DIR/docker-compose.yml"
  -f "$APP_DIR/openhands/docker-compose.openhands.yml"
  -f "$APP_DIR/hermes/docker-compose.hermes.yml"
)

export COMPOSE_HTTP_TIMEOUT=600
export DOCKER_CLIENT_TIMEOUT=600

# Per-phase wall-clock, printed as a summary at the end. `SECONDS` is bash's
# own counter, so nothing has to be timed by hand.
PHASE_PULL=0
PHASE_BUILD=0
PHASE_UP=0
_phase_mark=$SECONDS

log "Pulling container images..."
hybrid_progress_start "pull"
MAX_RETRIES=5
ATTEMPT=1

while [ $ATTEMPT -le $MAX_RETRIES ]; do
    if "${COMPOSE[@]}" pull --ignore-buildable; then
        log "All images pulled successfully."
        break
    else
        warn "Pull timed out or failed (Attempt $ATTEMPT of $MAX_RETRIES). Retrying in 10 seconds..."
        sleep 10
        ATTEMPT=$((ATTEMPT + 1))
    fi
done
hybrid_progress_stop
PHASE_PULL=$(( SECONDS - _phase_mark )); _phase_mark=$SECONDS

if [ $ATTEMPT -gt $MAX_RETRIES ]; then
    die "Failed to pull images after $MAX_RETRIES attempts. Please check network routing."
fi

# Non-root Hermes preflight. A no-op unless HYBRID_AI_UID is set and non-zero.
# It refuses (before anything is started) when the uid is not a system account,
# or when hermes_data holds entries that uid cannot read. Read-only; no sudo.
# See scripts/check-hermes-nonroot.sh.
if ! "${APP_DIR}/scripts/check-hermes-nonroot.sh"; then
  die "Refusing to start: the Hermes non-root uid is not usable (see above)."
fi

# ---------------------------------------------------------------------------
# Deciding whether the Hermes image has to be rebuilt
# ---------------------------------------------------------------------------
# The image carries the sha of the inputs it was built from. Rebuild only when
# that sha differs from the sha of the inputs now. Every uncertain case -- no
# image, no label, an unreadable label, any error -- rebuilds, so the gate can
# never leave a stale image serving.
#
# The gate lives in scripts/lib/build-gate.sh. The pinned BUILD_INPUTS_SHA is
# exported around the build so compose can pass it as the build arg; without
# it the label would be the Dockerfile default and every deploy would rebuild.
build_gate_decide "$APP_DIR" "$ENV_FILE"
if [[ "$BUILD_GATE_DECISION" == "cache" ]]; then
  log "build-gate: cache hit (${BUILD_GATE_SHA})"
  event "build_gate_cache_hit" "sha=${BUILD_GATE_SHA}"
else
  log "build-gate: rebuild (${BUILD_GATE_REASON})"
  event "build_gate_rebuild" "reason=${BUILD_GATE_REASON}" "sha=${BUILD_GATE_SHA}"
fi

log "Starting full Hybrid-AI control plane stack..."
# Build, then start. `compose build` builds every service with a `build:`
# section -- today only hermes -- which is exactly what `up --build` did, but
# as its own phase so its time is visible and so a cache hit can skip it.
if [[ "$BUILD_GATE_DECISION" != "cache" ]]; then
  log "Building images..."
  hybrid_progress_start "build"
  if ! BUILD_INPUTS_SHA="$BUILD_GATE_SHA" "${COMPOSE[@]}" build; then
    hybrid_progress_stop
    PHASE_BUILD=$(( SECONDS - _phase_mark ))
    event "stack_build_failed"
    warn "docker compose build failed."
    die "Control plane image build did not complete."
  fi
  hybrid_progress_stop
fi
PHASE_BUILD=$(( SECONDS - _phase_mark )); _phase_mark=$SECONDS

if ! "${COMPOSE[@]}" up -d --remove-orphans; then
  PHASE_UP=$(( SECONDS - _phase_mark ))
  event "stack_start_failed"
  warn "docker compose up failed. Recent logs:"
  "${COMPOSE[@]}" logs --tail 40 2>/dev/null || true
  die "Control plane did not start."
fi
PHASE_UP=$(( SECONDS - _phase_mark )); _phase_mark=$SECONDS
event "stack_started"


# ---------------------------------------------------------------------------
# STEP 9b. Close the sandbox port exposure
# ---------------------------------------------------------------------------
# Docker only creates DOCKER-USER once the daemon is up, so this runs after the
# stack starts. install.sh already runs as root in the deploy path, so the
# script is called directly and never through sudo. A host without the chain
# (for example Docker present but not running) is a warning, not a failure:
# hybrid-ai-firewall.service applies the same rules at the next boot.
log "Applying sandbox firewall rules..."
FIREWALL_RC=0
if [[ -x "${APP_DIR}/scripts/sandbox-firewall.sh" ]]; then
  "${APP_DIR}/scripts/sandbox-firewall.sh" apply || FIREWALL_RC=$?
else
  FIREWALL_RC=127
fi
case "$FIREWALL_RC" in
  0)
    event "sandbox_firewall_applied"
    ;;
  4)
    event "sandbox_firewall_skipped" "reason=no-docker-user"
    warn "DOCKER-USER does not exist yet, so the sandbox firewall rules were not applied. hybrid-ai-firewall.service applies them at boot."
    ;;
  *)
    event "sandbox_firewall_failed" "rc=${FIREWALL_RC}"
    warn "scripts/sandbox-firewall.sh exited ${FIREWALL_RC}; sandbox ports may still be reachable. Re-run it by hand as root."
    ;;
esac

# ---------------------------------------------------------------------------
# STEP 10. Verify service health and check local DNS resolution
# ---------------------------------------------------------------------------
# Per-phase summary. Printed once the deploy phases are done, and again on the
# health-failure exit, so a slow phase is always attributable.
print_phase_summary() {
  log "Phase durations (s): pull=${PHASE_PULL} build=${PHASE_BUILD} up=${PHASE_UP} verify=$(( SECONDS - _phase_mark ))"
  event "phase_durations" "pull=${PHASE_PULL}" "build=${PHASE_BUILD}" \
    "up=${PHASE_UP}" "verify=$(( SECONDS - _phase_mark ))"
}

log "Verifying service health..."
hybrid_progress_start "verify"

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
# Hermes is a core service: a failed wait sets HEALTH_FAILED, so install.sh
# exits non-zero instead of logging install_success. 300 s covers a cold first
# start on the Pi (a first run builds and imports the agent tree).
wait_for "hermes-agent" "http://127.0.0.1:${HERMES_PORT:-8501}" 300 || HEALTH_FAILED=1
wait_for "openhands"    "http://127.0.0.1:${OPENHANDS_PORT:-3001}" 240 || warn "OpenHands initializing..."
wait_for "status page"  "http://127.0.0.1:80/status/healthz" 60 || warn "Status reverse proxy initializing..."
hybrid_progress_stop
print_phase_summary

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
# HYBRID_AI_BACKUP_MODE decides WHICH backup units are installed. The shared
# helper resolves every derived name and path below, so install.sh, doctor.sh
# and backup.sh cannot disagree. "user" (the default) installs the per-user
# units under ~/.config/systemd/user, exactly as before. "system" installs the
# two-unit privilege split from backup/system/ into /etc/systemd/system,
# running as the dedicated hybrid-ai-backup account; this needs root, and card
# F creates that account once (see backup/README.md).
BACKUP_MODE="$HYBRID_AI_BACKUP_MODE"

# Credentials live OUTSIDE the app/data/work trees. In user mode that is
# BACKUP_CONF_DIR; in system mode root writes them to the credstore the units
# read via LoadCredential=. HYBRID_AI_BACKUP_CRED_DIR resolves this choice.
BACKUP_CRED_DIR="$HYBRID_AI_BACKUP_CRED_DIR"
R2_ENV_FILE="${BACKUP_CRED_DIR}/r2.env"
RESTIC_PW_FILE="${BACKUP_CRED_DIR}/repo-password"

# User-mode units (unchanged). System mode installs the backup/system set.
BACKUP_UNITS=(
  hybrid-ai-backup.service
  hybrid-ai-backup.timer
  hybrid-ai-check.service
  hybrid-ai-check.timer
)
SYSTEM_UNITS=(
  hybrid-ai-backup-capture.service
  hybrid-ai-backup-capture.timer
  hybrid-ai-backup-upload.service
  hybrid-ai-backup-check.service
  hybrid-ai-backup-check.timer
)

# Install (or refresh) the system-mode units into /etc/systemd/system. Requires
# root; card E's deploy unit runs install.sh as root after migration, so this is
# the normal path there. It never calls sudo: when it is not root it verifies
# and warns only. In system mode it NEVER installs the user units.
install_backup_scheduler_system() {
  local unit source_file target_file
  local install_failed=0
  local unit_dir="/etc/systemd/system"

  if [[ "$(id -u)" != "0" ]]; then
    warn "System-mode backup units need root to install into ${unit_dir}."
    warn "Re-run this installer as root (card E's deploy unit does). Not calling sudo."
    event "backup_schedule_failed" "reason=not_root"
    return 1
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    warn "systemctl is unavailable. Install the units in backup/system/ manually."
    event "backup_schedule_missing" "reason=systemctl_missing"
    return 1
  fi

  log "Installing backup system units into ${unit_dir}..."
  for unit in "${SYSTEM_UNITS[@]}"; do
    source_file="${APP_DIR}/backup/system/${unit}"
    target_file="${unit_dir}/${unit}"

    if [[ ! -f "$source_file" ]]; then
      warn "Missing backup system unit template: ${source_file}"
      event "backup_unit_install_failed" "unit=${unit}" "reason=template_missing"
      install_failed=1
      continue
    fi

    # Paths in these units are already absolute (/opt/hybrid-ai/...), so unlike
    # the user units there is no __REPO_DIR__ placeholder to render; copy as-is.
    if ! install -m 0644 "$source_file" "${target_file}.tmp"; then
      warn "Could not stage ${unit}."
      rm -f "${target_file}.tmp"
      event "backup_unit_install_failed" "unit=${unit}" "reason=copy_failed"
      install_failed=1
      continue
    fi
    mv -f "${target_file}.tmp" "$target_file"
  done

  if (( install_failed )); then
    warn "One or more backup system units could not be installed."
    return 1
  fi

  if ! systemctl daemon-reload; then
    warn "system daemon reload failed."
    event "backup_schedule_failed" "reason=daemon_reload"
    return 1
  fi

  for unit in "${SYSTEM_UNITS[@]}"; do
    if systemctl cat "$unit" >/dev/null 2>&1; then
      ok "${unit} installed."
    else
      warn "${unit} is not visible to the system systemd manager."
      event "backup_unit_install_failed" "unit=${unit}" "reason=not_loaded"
      install_failed=1
    fi
  done
  if (( install_failed )); then
    return 1
  fi

  if systemctl enable --now hybrid-ai-backup-capture.timer >/dev/null 2>&1; then
    ok "Backup capture timer enabled and active."
  else
    warn "Backup capture timer could not be enabled or started."
    event "backup_timer_failed"
    return 1
  fi
  if systemctl enable --now hybrid-ai-backup-check.timer >/dev/null 2>&1; then
    ok "Integrity-check timer enabled and active."
  else
    warn "Integrity-check timer could not be enabled or started."
    event "check_timer_failed"
    return 1
  fi

  if ! systemctl is-enabled hybrid-ai-backup-capture.timer >/dev/null 2>&1 ||
     ! systemctl is-active hybrid-ai-backup-capture.timer >/dev/null 2>&1; then
    warn "Backup capture timer verification failed."
    event "backup_timer_verification_failed"
    return 1
  fi
  if ! systemctl is-enabled hybrid-ai-backup-check.timer >/dev/null 2>&1 ||
     ! systemctl is-active hybrid-ai-backup-check.timer >/dev/null 2>&1; then
    warn "Integrity-check timer verification failed."
    event "check_timer_verification_failed"
    return 1
  fi

  event "backup_schedule_installed" "units=${#SYSTEM_UNITS[@]}" "mode=system"
  return 0
}

install_backup_scheduler() {
  # In system mode this dispatches to the two-unit installer and NEVER touches
  # the user units.
  if [[ "$BACKUP_MODE" == "system" ]]; then
    install_backup_scheduler_system
    return $?
  fi

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
    source_file="${APP_DIR}/backup/${unit}"
    target_file="${unit_dir}/${unit}"

    if [[ ! -f "$source_file" ]]; then
      warn "Missing backup unit template: ${source_file}"
      event "backup_unit_install_failed" "unit=${unit}" "reason=template_missing"
      install_failed=1
      continue
    fi

    if ! sed "s|__REPO_DIR__|${APP_DIR}|g" "$source_file" > "${target_file}.tmp"; then
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

  # Run backup.sh with the credentials the mode uses. In system mode the files
  # live in the root-owned credstore, so point backup.sh at it the same way the
  # units' LoadCredential= does.
  run_backup() {
    if [[ "$BACKUP_MODE" == "system" ]]; then
      CREDENTIALS_DIRECTORY="$BACKUP_CRED_DIR" "${APP_DIR}/backup/backup.sh" "$@"
    else
      "${APP_DIR}/backup/backup.sh" "$@"
    fi
  }

  if ! command -v restic >/dev/null 2>&1; then
    warn "restic is not installed. Backups cannot be configured."
    printf '    Install it with: sudo apt-get install -y restic\n'
    event "backup_setup_skipped" "reason=restic_missing"
    return 1
  fi

  if ! bash -n "${APP_DIR}/backup/backup.sh"; then
    warn "backup/backup.sh has a syntax error. Backup scheduling was not changed."
    event "backup_setup_failed" "reason=backup_script_syntax"
    return 1
  fi

  if [[ -f "$R2_ENV_FILE" && -f "$RESTIC_PW_FILE" ]]; then
    backups_configured=1
    ok "Backup credentials already configured (${BACKUP_CRED_DIR})."
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

    mkdir -p "$BACKUP_CRED_DIR"
    chmod 700 "$BACKUP_CRED_DIR"

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

    tmp_env="$(mktemp "${BACKUP_CRED_DIR}/.r2.XXXXXX")"
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
    if run_backup --init; then
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
      if run_backup; then
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

run_prune_catch_up || true

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
