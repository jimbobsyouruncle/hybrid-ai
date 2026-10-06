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
cd "$SCRIPT_DIR" \|\| exit 1
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

# Read one key from .env, stripping optional surrounding quotes.
env_get() {
  local v
  v="$(grep -E "^$1=" .env 2>/dev/null | tail -1 | cut -d= -f2-)"
  v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
  printf '%s' "$v"
}

# Read one environment variable from a container's config (not a live exec).
container_env() {
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$1" 2>/dev/null \
    | grep -E "^$2=" | head -1 | cut -d= -f2-
}

# Every compose command must use the same project, env file and BOTH compose
# files. Running with only the OpenHands file makes Compose try to recreate the
# shared network and stops OpenHands -- so remedies always print the full form.
COMPOSE_CMD="docker compose -p hybrid-ai --env-file .env -f docker-compose.yml -f openhands/docker-compose.openhands.yml -f hermes/docker-compose.hermes.yml"

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
    getfacl)   printf 'sudo apt-get install -y acl' ;;
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

# These are needed for backups, the mesh network and the OpenHands workspace
# ACLs, but the core chat stack still works without them -- so they are
# warnings, not failures.
for bin in sqlite3 rsync restic tailscale getfacl; do
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
    if [[ -n "$(env_get "$key")" ]]; then
      pass "${key} is set"
    else
      warn "${key} is empty" "Re-run ./install.sh to populate it."
    fi
  done

  TS_IP="$(env_get TAILSCALE_IP)"
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
      pass "${HOME}/.openhands permissions correct (700)"
    else
      fail "${HOME}/.openhands is ${OH_PERMS}, expected 700" \
           "Fix: chmod 700 ${HOME}/.openhands"
    fi
  fi

  # --- Agent workspace isolation ------------------------------------------
  # THE control that keeps the OpenHands sandbox away from .env. The sandbox
  # has write access to its workspace (via an ACL for its own uid), so the
  # only thing that keeps it away from .env and the logs is the workspace
  # being a separate clone entirely.
  OH_WS="$(env_get OPENHANDS_WORKSPACE)"
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
             "Check logs: docker logs --tail 50 ${svc}"
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
      # A failed 'compose up' can leave the container renamed with its old ID
      # as a prefix (e.g. 5d0e433e7877_hybrid-ai-openhands). It still runs, but
      # nothing that looks for the real name will find it.
      RENAMED="$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E "^[0-9a-f]{12}_${svc}$" | head -1)"
      if [[ -n "$RENAMED" ]]; then
        warn "${svc} exists only under a leftover name: ${RENAMED}" \
             "A Compose run failed part-way. Fix: docker rm -f ${RENAMED} && ${COMPOSE_CMD} up -d"
      # The status page, proxy and OpenHands are optional conveniences; chat
      # works perfectly without them, so their absence is not a failure.
      elif [[ "$svc" == hybrid-ai-* ]]; then
        warn "${svc} does not exist" "Optional. Run ./install.sh to add it."
      else
        fail "${svc} does not exist" "Run ./install.sh to create it."
      fi ;;
    *)
      fail "${svc} is ${STATE}" \
           "Start it with ./install.sh, or inspect: docker logs --tail 50 ${svc}" ;;
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
       "Check: docker logs --tail 50 ollama"
fi

if curl -fsS --max-time 5 http://127.0.0.1:3000/health >/dev/null 2>&1; then
  pass "Open WebUI responding on port 3000"
else
  fail "Open WebUI is not responding on port 3000" \
       "Check: docker logs --tail 50 open-webui"
fi

# OpenHands is loopback-only by design, so this probe works on the Pi itself
# but will never be reachable from elsewhere without an SSH tunnel.
OH_PORT="$(env_get OPENHANDS_PORT)"
OH_PORT="${OH_PORT:-3001}"
OH_RUNNING=0
[[ "$(docker inspect -f '{{.State.Status}}' hybrid-ai-openhands 2>/dev/null)" == "running" ]] && OH_RUNNING=1
if (( OH_RUNNING )); then
  if curl -fsS --max-time 5 "http://127.0.0.1:${OH_PORT}" >/dev/null 2>&1; then
    pass "OpenHands responding on 127.0.0.1:${OH_PORT} (tunnel to reach it remotely)"
  else
    warn "OpenHands container exists but is not answering on ${OH_PORT}" \
         "Optional feature. Check: docker logs --tail 50 hybrid-ai-openhands"
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
           "Check the Caddyfile and: docker logs --tail 30 hybrid-ai-proxy"
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
       "Optional feature. Chat still works on :3000. Check: docker logs --tail 30 hybrid-ai-proxy; docker logs --tail 30 hybrid-ai-status"
fi

# ---------------------------------------------------------------------------
# 5. OpenHands sandbox wiring
#
# OpenHands starts a separate agent-server container ("sandbox") for every
# conversation. Three connections must all work, and each one failing looks
# the same in the UI ("Disconnected" / "Network Error"):
#   a) sandbox -> OpenHands   webhooks, via host.docker.internal:<OH port>
#   b) browser -> sandbox     direct to a random host port on the Pi
#   c) sandbox -> /workspace  write access as the sandbox's own uid
# Each check below names exactly which of these is broken.
# ---------------------------------------------------------------------------
if (( OH_RUNNING )); then
  section "OpenHands sandbox"

  # --- (a) Webhook path -----------------------------------------------------
  # This build only reads the legacy name SANDBOX_HOST_PORT. Without it,
  # webhooks go to port 3000 -- which is Open WebUI -- and fail with 405.
  SHP="$(container_env hybrid-ai-openhands SANDBOX_HOST_PORT)"
  if [[ "$SHP" == "$OH_PORT" ]]; then
    pass "SANDBOX_HOST_PORT=${SHP} (webhooks target OpenHands, not Open WebUI)"
  elif [[ -z "$SHP" ]]; then
    if [[ -n "$(container_env hybrid-ai-openhands OH_SANDBOX_HOST_PORT)" ]]; then
      fail "Only OH_SANDBOX_HOST_PORT is set; this build ignores it" \
           "Rename it to SANDBOX_HOST_PORT in openhands/docker-compose.openhands.yml, then: ${COMPOSE_CMD} up -d openhands"
    else
      fail "SANDBOX_HOST_PORT is not set; sandbox webhooks will hit Open WebUI on :3000" \
           "Add 'SANDBOX_HOST_PORT: \${OPENHANDS_PORT:-3001}' to openhands/docker-compose.openhands.yml, then: ${COMPOSE_CMD} up -d openhands"
    fi
  else
    fail "SANDBOX_HOST_PORT=${SHP} does not match OPENHANDS_PORT=${OH_PORT}" \
         "They must match. Fix the compose file, then: ${COMPOSE_CMD} up -d openhands"
  fi

  # The UI port must be on loopback (for the tunnel) and on the Docker bridge
  # (for webhooks) -- and NEVER on all interfaces, which would publish root
  # code execution to the LAN.
  BINDINGS="$(docker inspect -f '{{range $p, $b := .HostConfig.PortBindings}}{{range $b}}{{.HostIp}}:{{.HostPort}} {{end}}{{end}}' hybrid-ai-openhands 2>/dev/null)"
  if [[ " $BINDINGS" =~ (^|[[:space:]])(:|0\.0\.0\.0:|::?:)${OH_PORT}([[:space:]]|$) ]]; then
    fail "OpenHands UI port ${OH_PORT} is published on ALL interfaces" \
         "This exposes root-level code execution to your LAN. Bind it to 127.0.0.1 and 172.17.0.1 only in openhands/docker-compose.openhands.yml."
  else
    pass "OpenHands UI port not exposed to the LAN"
  fi
  if [[ "$BINDINGS" == *"172.17.0.1:${OH_PORT}"* ]]; then
    if curl -s -o /dev/null --max-time 5 "http://172.17.0.1:${OH_PORT}/" 2>/dev/null; then
      pass "OpenHands reachable from sandboxes on the Docker bridge (172.17.0.1:${OH_PORT})"
    else
      fail "OpenHands bridge binding exists but does not answer" \
           "Check: docker logs --tail 50 hybrid-ai-openhands"
    fi
  else
    fail "OpenHands is not bound on the Docker bridge (172.17.0.1:${OH_PORT})" \
         "Sandboxes cannot deliver webhooks. Add '- \"172.17.0.1:\${OPENHANDS_PORT:-3001}:3000\"' under ports, then: ${COMPOSE_CMD} up -d openhands"
  fi

  # --- (b) Browser -> sandbox path ------------------------------------------
  # The browser is handed http://<this host>:<random port>. It has to be a
  # name or IP your PC can reach, and it has to actually be THIS Pi.
  SB_HOST="$(env_get OPENHANDS_SANDBOX_HOST)"
  PATTERN="$(container_env hybrid-ai-openhands SANDBOX_CONTAINER_URL_PATTERN)"
  if [[ -z "$PATTERN" || "$PATTERN" == *"//localhost"* || "$PATTERN" == *"//127."* ]]; then
    fail "Sandbox URL pattern is '${PATTERN:-unset (defaults to localhost)}'" \
         "Remote browsers will show 'Network Error'. Set OPENHANDS_SANDBOX_HOST in .env (e.g. jarvis.lan), then: ${COMPOSE_CMD} up -d openhands"
  else
    pass "Sandbox URL pattern: ${PATTERN}"
    if [[ -n "$SB_HOST" && "$PATTERN" != *"//${SB_HOST}:"* ]]; then
      warn "Running container uses a different host than OPENHANDS_SANDBOX_HOST=${SB_HOST}" \
           ".env was changed but the container was not recreated. Run: ${COMPOSE_CMD} up -d openhands"
    fi
  fi

  if [[ -n "$SB_HOST" ]]; then
    LOCAL_IPS="$(hostname -I 2>/dev/null)"
    RESOLVED="$(getent ahostsv4 "$SB_HOST" 2>/dev/null | awk 'NR==1 {print $1}')"
    if [[ -z "$RESOLVED" ]]; then
      warn "The Pi cannot resolve OPENHANDS_SANDBOX_HOST=${SB_HOST}" \
           "Only your PC needs to resolve it, but confirm it points to one of this Pi's addresses: ${LOCAL_IPS}"
    elif [[ " ${LOCAL_IPS} " == *" ${RESOLVED} "* ]]; then
      pass "${SB_HOST} resolves to ${RESOLVED}, an address on this Pi"
    else
      fail "${SB_HOST} resolves to ${RESOLVED}, which is NOT this Pi (this Pi: ${LOCAL_IPS% })" \
           "Browsers will be sent to the wrong machine. Fix the DNS record (e.g. Pi-hole Local DNS) or set OPENHANDS_SANDBOX_HOST to this Pi's LAN IP."
    fi
  fi

  # CORS: the sandbox only accepts browser calls from origins it was told
  # about. localhost and 127.0.0.1 are different origins to a browser.
  CORS="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' hybrid-ai-openhands 2>/dev/null | grep -E '^OH_PERMITTED_CORS_ORIGINS_[0-9]+=' | cut -d= -f2- | tr '\n' ' ')"
  if [[ "$CORS" == *"http://localhost:${OH_PORT}"* && "$CORS" == *"http://127.0.0.1:${OH_PORT}"* ]]; then
    pass "CORS allows both tunnel origins (localhost and 127.0.0.1 :${OH_PORT})"
  elif [[ -n "$CORS" ]]; then
    warn "CORS origins: ${CORS% }" \
         "Opening the UI from an origin not listed here gives 'Network Error'. Allow both http://localhost:${OH_PORT} and http://127.0.0.1:${OH_PORT}."
  else
    warn "No OH_PERMITTED_CORS_ORIGINS_* set" \
         "Browsers reaching the UI through the SSH tunnel will be blocked by the sandbox. Add both tunnel origins to the compose file."
  fi

  # --- Live sandboxes -------------------------------------------------------
  # Sandboxes keep the config they were created with, so a fix to OpenHands
  # does not reach sandboxes that were already running.
  mapfile -t SANDBOXES < <(docker ps --filter name=oh-agent-server --format '{{.Names}}' 2>/dev/null)
  if (( ${#SANDBOXES[@]} == 0 )); then
    pass "No sandbox running (one starts with each new conversation)"
  fi
  for sb in "${SANDBOXES[@]}"; do
    WH="$(container_env "$sb" OH_WEBHOOKS_0_BASE_URL)"
    if [[ "$WH" == *":${OH_PORT}/"* ]]; then
      pass "${sb}: webhooks -> ${WH}"
    else
      fail "${sb}: webhooks -> ${WH:-unset} (stale config)" \
           "Remove stale sandboxes and start a new conversation: docker rm -f ${sb}"
    fi

    LOGS="$(docker logs --tail 500 "$sb" 2>&1)"
    N405="$(grep -c '405 Method Not Allowed' <<<"$LOGS")"
    (( N405 > 0 )) && warn "${sb}: ${N405} webhook 405 error(s) in recent logs" \
         "Webhooks are reaching the wrong service. Check SANDBOX_HOST_PORT and recreate the sandbox."
    if grep -q "Permission denied" <<<"$LOGS"; then
      warn "${sb}: 'Permission denied' in recent logs" \
           "Workspace permissions problem. See the workspace ACL checks below."
    fi
    if grep -q "dubious ownership" <<<"$LOGS"; then
      warn "${sb}: git reports 'dubious ownership' of /workspace" \
           "Expected while the workspace is owned by you and the sandbox runs as another uid. Per-sandbox fix: docker exec ${sb} git config --global --add safe.directory '*' (does not persist to new sandboxes)."
    fi

    # Test the exact URL the browser is given, from the Pi itself. This proves
    # the host resolves here and the port is published; it cannot see a
    # firewall between your PC and the Pi.
    SB_PORT="$(docker port "$sb" 8000/tcp 2>/dev/null | head -1 | awk -F: '{print $NF}')"
    if [[ -n "$SB_HOST" && -n "$SB_PORT" ]]; then
      if curl -fsS --max-time 5 "http://${SB_HOST}:${SB_PORT}/health" >/dev/null 2>&1; then
        pass "${sb}: agent API answers at http://${SB_HOST}:${SB_PORT} (from your PC: Test-NetConnection ${SB_HOST} -Port ${SB_PORT})"
      else
        warn "${sb}: agent API not answering at http://${SB_HOST}:${SB_PORT}" \
             "Check the port mapping: docker port ${sb}"
      fi
    fi
  done

  STALE="$(docker ps -aq --filter name=oh-agent-server --filter status=exited 2>/dev/null | wc -l | tr -d ' ')"
  if (( STALE > 5 )); then
    warn "${STALE} stopped sandbox containers" \
         "Safe to remove (conversation history lives in the workspace): docker ps -aq --filter name=oh-agent-server --filter status=exited | xargs -r docker rm"
  fi

  # --- (c) Workspace permissions --------------------------------------------
  # agent-server ignores SANDBOX_USER_ID and runs as its own 'openhands' user,
  # so the workspace needs an ACL for that uid. Without it the sandbox exits at
  # startup ("Sandbox failed to start within 120s").
  if [[ -n "${OH_WS:-}" && -d "${OH_WS}" ]]; then
    OH_SB_UID="$(env_get OPENHANDS_SANDBOX_UID)"
    if [[ -z "$OH_SB_UID" && ${#SANDBOXES[@]} -gt 0 ]]; then
      OH_SB_UID="$(docker exec "${SANDBOXES[0]}" id -u 2>/dev/null)"
    fi
    OH_SB_UID="${OH_SB_UID:-10001}"

    if command -v getfacl >/dev/null 2>&1; then
      ACL="$(getfacl -p "$OH_WS" 2>/dev/null)"
      if grep -q "^user:${OH_SB_UID}:rwx" <<<"$ACL" && grep -q "^default:user:${OH_SB_UID}:rwx" <<<"$ACL"; then
        if grep -E "^user:${OH_SB_UID}:" <<<"$ACL" | grep -q '#effective'; then
          fail "Workspace ACL for uid ${OH_SB_UID} is restricted by the ACL mask" \
               "Fix: sudo setfacl -R -m m::rwx ${OH_WS}"
        else
          pass "Workspace ACL grants sandbox uid ${OH_SB_UID} rwx (including new files)"
        fi
      else
        fail "Workspace ${OH_WS} has no rwx ACL for sandbox uid ${OH_SB_UID}" \
             "The sandbox cannot start. Fix: sudo setfacl -R -m u:${OH_SB_UID}:rwx ${OH_WS} && sudo setfacl -R -d -m u:${OH_SB_UID}:rwx ${OH_WS}"
      fi

      # Directories created before the ACL existed do not inherit it.
      MISSING=()
      while IFS= read -r d; do
        getfacl -p "$d" 2>/dev/null | grep -q "^user:${OH_SB_UID}:rwx" || MISSING+=("$d")
      done < <(find "$OH_WS" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
      if (( ${#MISSING[@]} > 0 )); then
        fail "${#MISSING[@]} workspace folder(s) missing the sandbox ACL: $(printf '%s ' "${MISSING[@]:0:5}")" \
             "Fix: sudo setfacl -R -m u:${OH_SB_UID}:rwx ${OH_WS} && sudo setfacl -R -d -m u:${OH_SB_UID}:rwx ${OH_WS}"
      fi
    fi

    # A root-owned project/ broke 'git init' once already.
    ROOT_OWNED="$(find "$OH_WS" -maxdepth 2 -user root ! -path '*/.git/*' 2>/dev/null | head -5)"
    if [[ -n "$ROOT_OWNED" ]]; then
      fail "Root-owned files in the workspace: $(echo "$ROOT_OWNED" | tr '\n' ' ')" \
           "Fix: sudo chown -R $(id -un):$(id -gn) ${OH_WS} && sudo setfacl -R -m u:${OH_SB_UID}:rwx ${OH_WS}"
    else
      pass "No root-owned files at the top of the workspace"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 6. Network
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
# 7. Backups
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
    # shellcheck disable=SC2016
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
# 8. Data
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
LEFTOVER="$(find . -maxdepth 1 \( -name 'webui_data.pre-restore-*' -o -name '.restore-test-*' \) 2>/dev/null | wc -l | tr -d ' ')"
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
