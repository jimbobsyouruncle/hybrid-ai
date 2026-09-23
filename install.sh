#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: install.sh
# PURPOSE (plain English):
#   This is the one script you run on the Raspberry Pi to set everything up.
#   You can run it as many times as you like -- it is "idempotent", meaning
#   running it twice does the same thing as running it once. Nothing breaks and
#   no data is lost. The CI/CD pipeline runs it on every deploy for that reason.
#
# WHAT IT DOES, IN ORDER:
#   1. Checks that required programs (docker, jq, tailscale, curl, openssl) are
#      installed, and stops with instructions if any are missing.
#   2. Loads your existing .env file, if there is one, so it only asks you for
#      things it does not already know.
#   3. Reads your Pi's RAM and works out a safe memory budget for Ollama.
#   4. Generates a login-session encryption key, but only the first time.
#   5. Prompts you for your RunPod API key and pod ID if they are not saved.
#   6. Asks Tailscale for the network address of your cloud GPU pod.
#   7. Creates the data folders if they do not exist (never overwrites them).
#   8. Writes the .env file with locked-down permissions.
#   9. Starts the existing stack plus the OpenHands maintenance component.
#
# HOW TO RUN IT:
#   ./install.sh                     normal, interactive -- asks for anything missing
#   ./install.sh --non-interactive   never prompts; fails instead. Used by CI.
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

# Peer hostnames to search for, in priority order. The first is the name this
# project uses going forward; the rest are legacy names kept so an existing pod
# keeps being discovered until you rename it.
#
# WHY A ROLE-BASED NAME: "runpod-vllm" describes the software on the pod rather
# than the job it does. If you ever add a second pod they will both run vLLM,
# so the name stops distinguishing anything. Naming by ROLE makes adding a
# second pod additive rather than a rename across start.sh, install.sh and .env.
#
# Each name here must match TS_HOSTNAME in the corresponding runpod/start.sh.
PEER_HOSTNAMES="${PEER_HOSTNAMES:-runpod-worker runpod-vllm}"
PEER_HOSTNAME="${PEER_HOSTNAME:-${PEER_HOSTNAMES%% *}}"
NON_INTERACTIVE=0
NO_START=0

for arg in "$@"; do
  case "$arg" in
    --non-interactive) NON_INTERACTIVE=1 ;;
    --no-start)        NO_START=1 ;;
    -h|--help)
      sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

# --- Output helpers --------------------------------------------------------
# Colour codes, but only when writing to a real terminal. When output is piped
# to a file or CI log, colours would show up as unreadable escape characters.
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

# Structured, append-only record of what each run of this script did.
# METADATA ONLY -- never write credential values here. The log is created
# 0600 because it records the shape of your deployment.
INSTALL_LOG="${SCRIPT_DIR}/install.log"
event() {
  local name="$1"; shift
  printf 'EVENT ts=%s event=%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$name" "$*" \
    >> "$INSTALL_LOG" 2>/dev/null || true
}
touch "$INSTALL_LOG" 2>/dev/null && chmod 600 "$INSTALL_LOG" 2>/dev/null || true
event "install_start" "args=$*" "user=${USER:-unknown}"

# If any command fails unexpectedly, report which line it was on.
trap 'event "install_aborted" "line=${LINENO}"; die "Failed at line ${LINENO}: ${BASH_COMMAND}"' ERR

hr
printf '  hybrid-ai :: local control plane bootstrap\n'
hr

# ---------------------------------------------------------------------------
# STEP 1. Dependency probe
# Check the tools we need are present before doing anything destructive.
# ---------------------------------------------------------------------------
log "Probing host dependencies..."

MISSING=()
# sqlite3 and rsync support the backup subsystem; restic is checked
# separately below because it is optional until you enable backups.
for bin in docker jq curl openssl sqlite3 rsync; do
  command -v "$bin" >/dev/null 2>&1 || MISSING+=("$bin")
done
command -v tailscale >/dev/null 2>&1 || MISSING+=("tailscale")

if ((${#MISSING[@]} > 0)); then
  warn "Missing required binaries: ${MISSING[*]}"
  cat <<'EOF'

  Install them first. On Raspberry Pi OS / Debian / Ubuntu:

    sudo apt-get update
    sudo apt-get install -y jq curl openssl sqlite3 rsync restic
    curl -fsSL https://get.docker.com | sudo sh
    curl -fsSL https://tailscale.com/install.sh | sudo sh
    sudo usermod -aG docker "$USER"   # then log out and back in

EOF
  die "Dependency check failed."
fi

# We need Compose v2 (the "docker compose" subcommand). The old standalone
# "docker-compose" binary uses different syntax and is not supported here.
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
# A git checkout, an unzip, or a copy from Windows can all drop the executable
# bit. Without it the workspace setup below fails, the `|| warn` swallows it,
# and Docker then CREATES the workspace path as an empty directory when it
# mounts it -- so OpenHands comes up with an empty workspace and no clone.
# Nothing fails loudly, which makes it unpleasant to diagnose. Fix it here.
#
# This also protects doctor.sh and collect-diagnostics.sh, which are exactly
# what you need working when something else is broken.
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

  # SECURITY: we deliberately do NOT use `source` here. `source` executes the
  # file as shell code, so a value containing $(...) or backticks would run as
  # a command. Instead we parse it line by line, accept only well-formed
  # KEY=value pairs with a safe key name, and assign with printf -v, which
  # never evaluates the value.
  while IFS= read -r _line || [[ -n "$_line" ]]; do
    [[ "$_line" =~ ^[[:space:]]*# ]] && continue      # skip comments
    [[ "$_line" =~ ^[[:space:]]*$ ]] && continue      # skip blanks
    if [[ "$_line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      _k="${BASH_REMATCH[1]}"
      _v="${BASH_REMATCH[2]}"
      _v="${_v%\"}"; _v="${_v#\"}"                    # strip optional quotes
      _v="${_v%\'}"; _v="${_v#\'}"
      printf -v "$_k" '%s' "$_v"
      export "${_k?}"
    else
      warn "Ignoring malformed line in .env: ${_line:0:40}"
    fi
  done < "$ENV_FILE"
  unset _line _k _v
else
  log "No .env present -- generating from scratch."
fi

# ---------------------------------------------------------------------------
# STEP 3. Work out how much memory Ollama may use
# A Pi shares one pool of RAM between everything. If Ollama takes it all, the
# system starts swapping to the SD card and grinds to a halt. We leave headroom
# for the OS, Open WebUI, and the vector database.
# ---------------------------------------------------------------------------
log "Calculating resource allocation..."

TOTAL_KB="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
TOTAL_MB=$(( TOTAL_KB / 1024 ))
CPU_CORES="$(nproc 2>/dev/null || echo 1)"
ARCH="$(uname -m)"

# ---------------------------------------------------------------------------
# IMPORTANT CORRECTION: OLLAMA_MAX_VRAM DOES NOTHING.
#
# Earlier versions of this script computed a careful memory "budget" and set
# OLLAMA_MAX_VRAM from it. That variable was never actually honoured by
# Ollama -- it was ignored in every version that had it, and has since been
# removed from the codebase entirely. Setting it was pure placebo.
#
# What ACTUALLY constrains memory on this machine:
#   1. Docker memory limits (OLLAMA_MEM_LIMIT below) -- a real, enforced cap.
#   2. The size of the model you choose. This is the dominant factor by far.
#   3. OLLAMA_CONTEXT_LENGTH -- the KV cache grows with context, and Ollama
#      defaults to 4096 regardless of what the model supports.
#
# THE REAL BOTTLENECK ON A PI IS MEMORY BANDWIDTH, NOT CAPACITY.
# The Pi 5's LPDDR4X gives roughly 17 GB/s. Generating one token requires
# reading every weight once, so throughput is capped at approximately
# bandwidth / model_size regardless of how much RAM you have:
#
#     1B model  ~17-21 tok/s    comfortable
#     3B model  ~5-8  tok/s     the sweet spot for interactive use
#     8B model  ~1-3  tok/s     technically runs on 16 GB, too slow to chat with
#
# This is why 16 GB does not make an 8B model usable: it removes the capacity
# limit but not the bandwidth limit. Use a 3B model locally and send the hard
# work to the GPU pod -- which is exactly what this architecture is for.
# ---------------------------------------------------------------------------

# Docker memory ceiling for Ollama. This one is genuinely enforced by the
# kernel cgroup, so it protects the rest of the system from a model that
# turns out to be larger than expected.
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

# Open WebUI needs headroom for embedding documents, which is its most
# memory-hungry operation by a wide margin.
if   (( TOTAL_MB <= 4096 )); then WEBUI_MEM_LIMIT="1024m"
elif (( TOTAL_MB <= 8192 )); then WEBUI_MEM_LIMIT="2048m"
else                              WEBUI_MEM_LIMIT="3072m"
fi

# Context length. Ollama caps every model at 4096 tokens unless told
# otherwise, silently, which truncates long conversations and RAG results.
# Raising it costs KV cache memory, so scale it with available RAM.
if   (( TOTAL_MB <= 4096 )); then OLLAMA_CONTEXT_LENGTH="${OLLAMA_CONTEXT_LENGTH:-4096}"
elif (( TOTAL_MB <= 8192 )); then OLLAMA_CONTEXT_LENGTH="${OLLAMA_CONTEXT_LENGTH:-8192}"
else                              OLLAMA_CONTEXT_LENGTH="${OLLAMA_CONTEXT_LENGTH:-16384}"
fi

# Serve one request at a time and keep one model resident. On a
# bandwidth-bound machine, concurrency does not increase total throughput --
# it just makes every request slower and multiplies KV cache memory.
OLLAMA_NUM_PARALLEL="${OLLAMA_NUM_PARALLEL:-1}"
OLLAMA_MAX_LOADED_MODELS="${OLLAMA_MAX_LOADED_MODELS:-1}"

# Reloading a 2 GB model from disk takes real time. With 16 GB there is room
# to keep it resident for longer, which makes the second question in a
# conversation feel dramatically faster than the first.
if (( TOTAL_MB >= 15000 )); then
  OLLAMA_KEEP_ALIVE="${OLLAMA_KEEP_ALIVE:-30m}"
elif (( TOTAL_MB >= 7000 )); then
  OLLAMA_KEEP_ALIVE="${OLLAMA_KEEP_ALIVE:-15m}"
else
  OLLAMA_KEEP_ALIVE="${OLLAMA_KEEP_ALIVE:-5m}"
fi

# Quantising the KV cache roughly halves context memory for a negligible
# quality difference, letting the larger context above fit comfortably.
OLLAMA_FLASH_ATTENTION="${OLLAMA_FLASH_ATTENTION:-1}"
OLLAMA_KV_CACHE_TYPE="${OLLAMA_KV_CACHE_TYPE:-q8_0}"

# --- CPU shares -------------------------------------------------------------
# docker-compose.yml references OLLAMA_CPUS and WEBUI_CPUS, and .env.example
# documents them, but until now nothing computed or wrote them. The compose
# file carries :- defaults so this was never fatal -- but it meant the values
# you saw documented were not the values in use, which is its own problem.
#
# Leave roughly half a core for the OS, the proxy and the status page. Without
# that headroom a busy inference run makes the whole Pi feel unresponsive,
# including the web UI you are sitting there waiting on -- which reads as
# "the whole thing is broken" rather than "inference is slow".
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

# --- Storage check: the single biggest performance factor after model size --
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
#
# The status page runs as an unprivileged user, but still needs to READ the
# Docker socket to report container state. It therefore needs the numeric
# group id that owns that socket on this host, which differs between
# distributions -- so we look it up rather than guessing.
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
# Open WebUI uses this to sign login cookies. Generate once, then never change
# it -- changing it logs everyone out.
# ---------------------------------------------------------------------------
if [[ -z "${WEBUI_SECRET_KEY:-}" ]]; then
  WEBUI_SECRET_KEY="$(openssl rand -hex 32)"
  ok "Generated new WEBUI_SECRET_KEY."
else
  ok "Reusing existing WEBUI_SECRET_KEY (sessions preserved)."
fi

# ---------------------------------------------------------------------------
# STEP 5. Credential prompts
# ---------------------------------------------------------------------------

# prompt_secret VAR_NAME "Human label" [silent]
#   Asks the user for a value, but only if VAR_NAME is currently empty.
#   Pass 1 as the third argument to hide typing (for passwords/API keys).
#   Reads from /dev/tty so prompts still work when output is being piped.
prompt_secret() {
  local __var="$1" __label="$2" __silent="${3:-0}" __val=""
  if [[ -n "${!__var:-}" ]]; then          # ${!__var} = "value of the variable named by __var"
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
  printf -v "$__var" '%s' "$__val"          # assign back to the named variable
}

log "Resolving cloud inference credentials..."
prompt_secret RUNPOD_API_KEY "RunPod API key" 1
prompt_secret RUNPOD_POD_ID  "RunPod pod ID"  0

# ---------------------------------------------------------------------------
# STEP 6. Find the GPU pod on the Tailscale network
# "tailscale status --json" lists every machine on your private network. We use
# jq (a JSON query tool) to find the pod by hostname (see PEER_HOSTNAMES above)
# and pull out its 100.x.x.x address. That address is private to your network
# and encrypted.
# ---------------------------------------------------------------------------
log "Querying Tailscale mesh for peer '${PEER_HOSTNAME}'..."

TS_JSON=""
if TS_JSON="$(tailscale status --json 2>/dev/null)"; then
  BACKEND_STATE="$(printf '%s' "$TS_JSON" | jq -r '.BackendState // "Unknown"')"
  SELF_IP="$(printf '%s' "$TS_JSON" | jq -r '.Self.TailscaleIPs[]? | select(test("^100\\."))' | head -n1)"

  if [[ "$BACKEND_STATE" != "Running" ]]; then
    warn "Tailscale backend state is '${BACKEND_STATE}' (expected 'Running'). Run: sudo tailscale up"
  else
    ok "tailnet up; this node = ${SELF_IP:-unknown}"
  fi

  # Match on hostname or DNS name, preferring a peer that is currently online.
  # Try each candidate name in PEER_HOSTNAMES in order; first hit wins.
  DISCOVERED_IP=""
  PEER_ONLINE="false"
  MATCHED_PEER=""

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
  DISCOVERED_IP=""
  PEER_ONLINE="false"
  MATCHED_PEER=""
fi

if [[ -n "${DISCOVERED_IP:-}" ]]; then
  TAILSCALE_IP="$DISCOVERED_IP"
  if [[ "$PEER_ONLINE" == "true" ]]; then
    ok "Peer '${MATCHED_PEER}' online at ${TAILSCALE_IP}"
  else
    # This is the normal state most of the time -- the pod is stopped to save money.
    ok "Peer '${MATCHED_PEER}' known at ${TAILSCALE_IP} (offline -- pod is stopped, expected)"
  fi

  if [[ "$MATCHED_PEER" != "$PEER_HOSTNAME" ]]; then
    warn "Pod is registered as '${MATCHED_PEER}' (legacy name)."
    warn "Rename it: set TS_HOSTNAME=${PEER_HOSTNAME} in runpod/start.sh, then restart the pod."
  fi
elif [[ -n "${TAILSCALE_IP:-}" ]]; then
  warn "No peer (${PEER_HOSTNAMES}) in tailnet right now; keeping cached ${TAILSCALE_IP}"
else
  warn "No peer found (tried: ${PEER_HOSTNAMES}) and no cached address."
  if (( NON_INTERACTIVE )); then
    TAILSCALE_IP=""
    warn "Continuing with empty TAILSCALE_IP -- the pipe will error until the pod registers."
  else
    read -r -p "    Enter the pod's Tailscale IP (or leave blank to fill in later): " TAILSCALE_IP < /dev/tty
  fi
fi

# Sanity check: mesh addresses always start with 100. Anything else means your
# traffic would leave the encrypted tunnel.
if [[ -n "${TAILSCALE_IP:-}" && ! "$TAILSCALE_IP" =~ ^100\.([0-9]{1,3}\.){2}[0-9]{1,3}$ ]]; then
  warn "'${TAILSCALE_IP}' does not look like a 100.x.x.x mesh address. Traffic may egress the tailnet."
fi

# ---------------------------------------------------------------------------
# STEP 7. Data folders
# "mkdir -p" creates a folder only if it is missing, and never errors if it
# already exists. Existing data is left completely untouched.
# ---------------------------------------------------------------------------
log "Ensuring persistent host mounts..."

# The status container bind-mounts these two log files read-only. Docker
# creates a DIRECTORY in place of any bind-mount source that does not exist,
# which then fails confusingly at read time -- so make sure they are files.
for f in backup.log install.log; do
  [[ -e "$f" ]] || { : > "$f"; chmod 600 "$f"; }
  if [[ -d "$f" ]]; then
    warn "${f} is a directory (created by an earlier Docker run). Replacing it."
    rmdir "$f" 2>/dev/null && : > "$f" && chmod 600 "$f"
  fi
done

# Caddy keeps its own small state here, inside the directory we already back up.
mkdir -p webui_data/caddy

# OpenHands stores LLM provider credentials here. Outside the repo so it is
# never committed, and never visible to the agent sandbox. 0700 so no other
# local account can read it.
mkdir -p "${HOME}/.openhands"
chmod 700 "${HOME}/.openhands"

for d in ollama_data webui_data; do
  if [[ -d "$d" ]]; then
    ok "./${d} exists ($(du -sh "$d" 2>/dev/null | cut -f1 || echo '0') on disk) -- untouched."
  else
    mkdir -p "$d"
    ok "./${d} created."
  fi
done

# ---------------------------------------------------------------------------
# STEP 8. Write .env
# Written to a temporary file first, then moved into place in one atomic step.
# That way a crash mid-write can never leave you with a half-written .env.
# Mode 0600 = only your user account can read it.
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

# --- Local control plane ---------------------------------------------------
# NOTE: OLLAMA_MAX_VRAM is deliberately absent. It never worked and has been
# removed from Ollama. Memory is capped by OLLAMA_MEM_LIMIT below, which is a
# real, kernel-enforced Docker limit.
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

# --- Status page identity (numeric ids, not secrets) -----------------------
STATUS_UID=${STATUS_UID}
DOCKER_GID=${DOCKER_GID}

# --- Open WebUI ------------------------------------------------------------
WEBUI_SECRET_KEY=${WEBUI_SECRET_KEY}
WEBUI_AUTH=${WEBUI_AUTH:-true}
RAG_EMBEDDING_MODEL=${RAG_EMBEDDING_MODEL:-sentence-transformers/all-MiniLM-L6-v2}
ENABLE_OPENAI_API=${ENABLE_OPENAI_API:-false}

# --- Cloud inference plane -------------------------------------------------
TAILSCALE_IP=${TAILSCALE_IP:-}
# Role-based peer name. Adding a second pod later means adding a name to
# PEER_HOSTNAMES, not renaming this one. doctor.sh and the pipe read
# PEER_HOSTNAME so their error messages name the right machine.
PEER_HOSTNAME=${PEER_HOSTNAME}
PEER_HOSTNAMES=${PEER_HOSTNAMES}
RUNPOD_API_KEY=${RUNPOD_API_KEY}
RUNPOD_POD_ID=${RUNPOD_POD_ID}
VLLM_PORT=${VLLM_PORT:-8000}
VLLM_MODEL_NAME=${VLLM_MODEL_NAME:-Qwen/Qwen2.5-Coder-32B-Instruct-AWQ}
POD_WARMUP_TIMEOUT=${POD_WARMUP_TIMEOUT:-600}

# --- OpenHands maintenance agent -------------------------------------------
# Loopback-only UI; access through an SSH tunnel over Tailscale.
#
# OPENHANDS_WORKSPACE must NOT be this directory. The agent sandbox runs as
# your uid, so file permissions would not stop it reading .env and the log
# files. scripts/setup-agent-workspace.sh creates and guards a separate clone.
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

# --- Agent workspace (isolated clone) --------------------------------------
# OpenHands must NOT see this directory: it holds .env and the log files, and
# the sandbox runs as our uid, so permissions would not stop it reading them.
#
# Runs BEFORE the --no-start exit, because preparing the clone is preparation,
# not a Docker operation.
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

# Both compose files, every time. Omitting the overlay on an "up
# --remove-orphans" would DELETE the OpenHands container as an orphan.
COMPOSE=(docker compose
         -f docker-compose.yml
         -f openhands/docker-compose.openhands.yml
         --env-file "$ENV_FILE")

log "Pulling images (no-op if already current)..."
"${COMPOSE[@]}" pull --quiet || warn "Image pull failed; using cached images."

log "Starting control plane..."
# "up -d" starts in the background. "--remove-orphans" cleans up containers
# from services that no longer exist in the compose file.
if ! "${COMPOSE[@]}" up -d --remove-orphans; then
  event "stack_start_failed"
  warn "docker compose up failed. Recent logs:"
  "${COMPOSE[@]}" logs --tail 40 2>/dev/null || true
  die "Control plane did not start."
fi
event "stack_started"

# ---------------------------------------------------------------------------
# STEP 10. Verify the stack is actually SERVING, not merely started
#
# AVAILABILITY: "docker compose up" succeeding only means the containers were
# created. A container can be up and still be broken -- wrong config, failed
# migration, out of memory. Without this gate the script would print a cheerful
# success message over a dead service, and you would not find out until you
# opened the browser. We poll the real health endpoints and report honestly.
# ---------------------------------------------------------------------------
log "Verifying service health..."

wait_for() {          # wait_for <label> <url> <max_seconds>
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
wait_for "ollama"     "http://127.0.0.1:11434/api/tags" 60  || HEALTH_FAILED=1
wait_for "open-webui" "http://127.0.0.1:3000/health"    180 || HEALTH_FAILED=1

# OpenHands is a maintenance convenience, not part of the serving path. Chat and
# the cloud pipe work without it, and its image is large enough that a first pull
# on a Pi can exceed this window. A warning, never a failed install -- and never
# a failed CI deploy, which runs this script under script_stop: true.
wait_for "openhands"  "http://127.0.0.1:${OPENHANDS_PORT:-3001}" 240 || \
  warn "OpenHands not reachable yet. Optional; everything else is unaffected. Check: ./openhands/scripts/openhands-control.sh logs"

# The proxy and status page are conveniences: if they fail the stack is still
# fully usable on :3000, so these warn rather than failing the install.
wait_for "status page" "http://127.0.0.1:80/status/healthz" 60 || \
  warn "Status page not reachable. Chat still works on :3000. Check: docker compose --env-file .env logs proxy status"
if ! curl -fsS --max-time 5 -o /dev/null "http://127.0.0.1:80/app/" 2>/dev/null; then
  warn "Open WebUI not reachable through the proxy (it is still on :3000 directly)."
fi

hr
"${COMPOSE[@]}" ps
hr

if (( HEALTH_FAILED )); then
  event "install_failed" "reason=healthcheck"
  warn "One or more services are unhealthy. Diagnostic logs below."
  hr
  "${COMPOSE[@]}" logs --tail 40 2>/dev/null || true
  hr
  warn "The stack is running but not serving."
  warn "Run ./doctor.sh for a full diagnosis, or see docs/TROUBLESHOOTING.md"
  exit 1
fi

# ---------------------------------------------------------------------------
# STEP 11. Encrypted offsite backups (Cloudflare R2 via restic)
#
# WHY THIS IS HERE: everything above this line is replaceable. Your chat
# history, uploaded documents, and vector database are not. This step sets up
# encrypted nightly backups so a dead SD card is an inconvenience rather than
# a catastrophe.
#
# SECURITY: backup credentials are deliberately stored OUTSIDE the repository
# in ~/.config/hybrid-ai-backup/, mode 0600. They are kept separate from .env
# so that a compromise of the application stack does not automatically hand
# over the ability to delete your backup history.
# ---------------------------------------------------------------------------
BACKUP_CONF_DIR="${HOME}/.config/hybrid-ai-backup"
R2_ENV_FILE="${BACKUP_CONF_DIR}/r2.env"
RESTIC_PW_FILE="${BACKUP_CONF_DIR}/repo-password"

setup_backups() {
  if ! command -v restic >/dev/null 2>&1; then
    warn "restic is not installed. Backups cannot be configured."
    printf '    Install it with: sudo apt-get install -y restic\n'
    event "backup_setup_skipped" "reason=restic_missing"
    return 1
  fi

  # Already configured? Leave it entirely alone.
  if [[ -f "$R2_ENV_FILE" && -f "$RESTIC_PW_FILE" ]]; then
    ok "Backups already configured (${BACKUP_CONF_DIR})."
    return 0
  fi

  if (( NON_INTERACTIVE )); then
    warn "Backups not configured, and --non-interactive was requested."
    warn "Run ./install.sh interactively to set them up."
    event "backup_setup_skipped" "reason=non_interactive"
    return 1
  fi

  hr
  printf '  %sEncrypted offsite backups%s\n\n' "$C_INF" "$C_RST"
  printf '  Your chat history, documents, and vector database can be backed up\n'
  printf '  nightly to Cloudflare R2, encrypted on this Pi before upload.\n'
  printf '  Cloudflare stores only ciphertext and cannot read any of it.\n\n'
  printf '  Cost is typically pennies per month, and R2 charges nothing for\n'
  printf '  downloads -- which matters most on the day you actually restore.\n\n'
  printf '  You will need (see backup/README.md for a walkthrough):\n'
  printf '    - A Cloudflare account ID\n'
  printf '    - An R2 bucket\n'
  printf '    - An R2 API token with "Object Read & Write" on that bucket\n\n'
  hr

  read -r -p "  Configure backups now? [Y/n]: " _ans < /dev/tty
  if [[ "${_ans,,}" == "n" ]]; then
    warn "Skipping. Re-run ./install.sh at any time to configure backups."
    event "backup_setup_declined"
    return 1
  fi

  mkdir -p "$BACKUP_CONF_DIR"
  chmod 700 "$BACKUP_CONF_DIR"

  local cf_account cf_bucket cf_key_id cf_secret
  while [[ -z "${cf_account:-}" ]]; do
    read -r -p "    Cloudflare account ID: " cf_account < /dev/tty
  done
  read -r -p "    R2 bucket name [hybrid-ai-backup]: " cf_bucket < /dev/tty
  cf_bucket="${cf_bucket:-hybrid-ai-backup}"
  while [[ -z "${cf_key_id:-}" ]]; do
    read -r -p "    R2 Access Key ID: " cf_key_id < /dev/tty
  done
  while [[ -z "${cf_secret:-}" ]]; do
    read -r -s -p "    R2 Secret Access Key: " cf_secret < /dev/tty; echo
  done

  # --- Repository password -------------------------------------------------
  # This is the encryption key for everything. restic has no recovery path:
  # lose this and the backups are permanently unreadable, by design.
  if [[ ! -f "$RESTIC_PW_FILE" ]]; then
    printf '\n    A repository password encrypts your backups.\n'
    read -r -p "    Generate a strong one automatically? [Y/n]: " _gen < /dev/tty
    if [[ "${_gen,,}" == "n" ]]; then
      local pw1 pw2
      while :; do
        read -r -s -p "    Enter repository password: " pw1 < /dev/tty; echo
        read -r -s -p "    Confirm: " pw2 < /dev/tty; echo
        [[ "$pw1" == "$pw2" && -n "$pw1" ]] && break
        warn "Passwords did not match, or were empty."
      done
      printf '%s\n' "$pw1" > "$RESTIC_PW_FILE"
      unset pw1 pw2
    else
      openssl rand -base64 48 > "$RESTIC_PW_FILE"
    fi
    chmod 600 "$RESTIC_PW_FILE"
  fi

  # --- Credential file -----------------------------------------------------
  # Written via a 0600 temp file and moved into place, so there is never a
  # moment where the credentials exist with permissive permissions.
  local tmp_env
  tmp_env="$(mktemp "${BACKUP_CONF_DIR}/.r2.XXXXXX")"
  chmod 600 "$tmp_env"
  cat > "$tmp_env" <<EOF2
# hybrid-ai backup credentials -- generated $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Mode 0600. Never commit. Kept outside the git repository deliberately.
RESTIC_REPOSITORY=s3:https://${cf_account}.r2.cloudflarestorage.com/${cf_bucket}
RESTIC_PASSWORD_FILE=${RESTIC_PW_FILE}
AWS_ACCESS_KEY_ID=${cf_key_id}
AWS_SECRET_ACCESS_KEY=${cf_secret}
AWS_DEFAULT_REGION=auto
RESTIC_HOST=$(hostname -s)
EOF2
  mv -f "$tmp_env" "$R2_ENV_FILE"
  chmod 600 "$R2_ENV_FILE"
  unset cf_secret
  ok "Credentials written to ${R2_ENV_FILE} (0600)."

  # --- Initialise the repository -------------------------------------------
  log "Initialising the encrypted repository..."
  if "${SCRIPT_DIR}/backup/backup.sh" --init; then
    event "backup_repo_ready" "bucket=${cf_bucket}"
  else
    warn "Repository initialisation failed. Check the credentials and bucket name."
    event "backup_setup_failed" "reason=init"
    return 1
  fi

  # --- Install the schedule ------------------------------------------------
  # User-level systemd units: the backup runs as you, not as root. It only
  # needs access to your own files and your own credentials.
  local unit_dir="${HOME}/.config/systemd/user"
  mkdir -p "$unit_dir"
  local installed=0
  for unit in hybrid-ai-backup.service hybrid-ai-backup.timer \
              hybrid-ai-check.service hybrid-ai-check.timer; do
    if [[ -f "${SCRIPT_DIR}/backup/${unit}" ]]; then
      sed "s|__REPO_DIR__|${SCRIPT_DIR}|g" "${SCRIPT_DIR}/backup/${unit}" > "${unit_dir}/${unit}"
      installed=$(( installed + 1 ))
    fi
  done

  if (( installed > 0 )) && command -v systemctl >/dev/null 2>&1; then
    systemctl --user daemon-reload 2>/dev/null || true
    systemctl --user enable --now hybrid-ai-backup.timer 2>/dev/null || true
    systemctl --user enable --now hybrid-ai-check.timer  2>/dev/null || true

    # "linger" lets user services run when you are not logged in. Without it,
    # your nightly backup only happens on nights you happen to have an SSH
    # session open -- which is to say, it does not happen.
    if command -v loginctl >/dev/null 2>&1; then
      if ! loginctl show-user "$USER" 2>/dev/null | grep -q 'Linger=yes'; then
        if sudo -n loginctl enable-linger "$USER" 2>/dev/null; then
          ok "Enabled linger so backups run without an active login."
        else
          warn "Run this so backups happen when you are not logged in:"
          printf '      sudo loginctl enable-linger %s\n' "$USER"
        fi
      fi
    fi
    ok "Nightly backup scheduled (03:15) and monthly verification enabled."
    event "backup_schedule_installed" "units=${installed}"
  else
    warn "systemd user units unavailable. Schedule backup.sh manually via cron."
  fi

  # --- First backup --------------------------------------------------------
  read -r -p "  Run the first backup now? [Y/n]: " _first < /dev/tty
  if [[ "${_first,,}" != "n" ]]; then
    "${SCRIPT_DIR}/backup/backup.sh" || warn "First backup failed. See backup.log."
  fi

  hr
  printf '  %sSTORE YOUR REPOSITORY PASSWORD SOMEWHERE OFF THIS PI.%s\n\n' "$C_WRN" "$C_RST"
  printf '    cat %s\n\n' "$RESTIC_PW_FILE"
  printf '  Put it in a password manager. If this SD card dies and the password\n'
  printf '  dies with it, your backups are permanently unrecoverable. restic has\n'
  printf '  no recovery mechanism -- that is what makes the encryption trustworthy.\n'
  hr
  return 0
}

setup_backups || true

event "install_success" "ollama_limit=${OLLAMA_MEM_LIMIT}" "peer_resolved=${TAILSCALE_IP:+yes}" "backups=$([[ -f "$R2_ENV_FILE" ]] && echo configured || echo none)"

PI_IP="${SELF_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
ok "Control plane is up."
printf '\n    Hub        : http://%s/hub\n' "${PI_IP:-localhost}"
printf '    Open WebUI : http://%s/openwebui   (or http://%s:3000)\n' "${PI_IP:-localhost}" "${PI_IP:-localhost}"
printf '    Status     : http://%s/status\n' "${PI_IP:-localhost}"
printf '    OpenHands  : http://127.0.0.1:%s via SSH tunnel only\n' "${OPENHANDS_PORT:-3001}"
printf '    Ollama API : http://%s/ollama/\n' "${PI_IP:-localhost}"
printf '    Ollama dir : http://127.0.0.1:11434\n'
printf '    vLLM peer  : http://%s:%s/v1  (on demand)\n\n' "${TAILSCALE_IP:-<unresolved>}" "${VLLM_PORT:-8000}"
printf '\n  Next steps:\n'
printf '    1. Open http://%s/openwebui and create your admin account\n' "${PI_IP:-localhost}"
printf '    2. Pull a local model:  docker exec -it ollama ollama pull llama3.2:3b\n'
printf '    3. Add the cloud model: Open WebUI -> Workspace -> Functions -> +\n'
printf '       then paste openwebui/runpod_pipe.py and enable it\n'
printf '    4. OpenHands (optional): ssh -L 3001:127.0.0.1:3001 %s@%s\n' "${USER:-user}" "${PI_IP:-localhost}"
printf '\n  Check everything at any time:\n'
printf '    in a browser : http://%s/status\n' "${PI_IP:-localhost}"
printf '    on the CLI   : ./doctor.sh\n'
if [[ -f "${HOME}/.config/hybrid-ai-backup/r2.env" ]]; then
  printf '%s  Backups: nightly at 03:15 -> Cloudflare R2. Rehearse with ./backup/restore.sh --test%s\n\n' "$C_DIM" "$C_RST"
else
  printf '%s  Backups: NOT configured. Re-run ./install.sh to enable them.%s\n\n' "$C_WRN" "$C_RST"
fi
