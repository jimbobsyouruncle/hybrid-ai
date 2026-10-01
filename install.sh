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
