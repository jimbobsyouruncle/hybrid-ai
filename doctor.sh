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
#   ./doctor.sh --no-cloud   skip the checks that contact R2 (the backup
#                            repository). The single short RunPod API-key probe
#                            still runs when its preconditions are met.
#
# EXIT CODES (so you can use this in scripts or monitoring):
#   0  everything healthy
#   1  warnings only -- working, but something needs attention
#   2  one or more failures -- something is actually broken
# ---------------------------------------------------------------------------
set -uo pipefail   # deliberately NOT -e: a failing check must not abort the run

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

# Every host path comes from the ONE shared helper. With no settings, the
# resolved paths are exactly today's.
# shellcheck source=scripts/lib/hybrid-ai-env.sh
source "${SCRIPT_DIR}/scripts/lib/hybrid-ai-env.sh"
# Resolving the pod's MagicDNS name to an address happens in ONE place, shared
# with collect-diagnostics.sh and install.sh.
# shellcheck source=scripts/lib/tailscale-resolve.sh
source "${SCRIPT_DIR}/scripts/lib/tailscale-resolve.sh"
APP_DIR="$HYBRID_AI_APP_DIR"
ENV_FILE="$HYBRID_AI_STACK_ENV_FILE"

QUIET=0
NO_CLOUD=0
for arg in "$@"; do
  case "$arg" in
    --quiet)    QUIET=1 ;;
    --no-cloud) NO_CLOUD=1 ;;
    -h|--help)  sed -n '2,23p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

# Read one key from a resolved env file, stripping optional surrounding quotes.
# On a bootstrapped host the LAYOUT file (HYBRID_AI_ENV_FILE, mode 0644) holds
# the path and identity settings while the STACK file
# (HYBRID_AI_STACK_ENV_FILE, mode 0600) holds the secrets, so BOTH are searched
# and the first non-empty value wins. When the two are the same file (no
# bootstrap), the search is identical to reading that one file.
env_get() {
  local file v
  for file in "$HYBRID_AI_ENV_FILE" "$HYBRID_AI_STACK_ENV_FILE"; do
    [[ -n "$file" && -f "$file" ]] || continue
    v="$(grep -E "^$1=" "$file" 2>/dev/null | tail -1 | cut -d= -f2-)"
    v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
    if [[ -n "$v" ]]; then printf '%s' "$v"; return 0; fi
  done
  printf '%s' ""
}

# Same idea, but for a named file, and it reports the two failure modes
# separately: "absent" when the file or the key line is missing/empty, and
# "unreadable" when the file exists but this user cannot read it. Only presence
# is ever tested; the value is returned to a shell variable and never printed.
env_key_state() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || { printf 'absent'; return; }
  [[ -r "$file" ]] || { printf 'unreadable'; return; }
  local v
  v="$(grep -E "^${key}=" "$file" 2>/dev/null | tail -1 | cut -d= -f2-)"
  v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
  if [[ -n "$v" ]]; then printf 'set'; else printf 'absent'; fi
  unset v
}

# --- RunPod control API: validate RUNPOD_API_KEY with ONE read-only query ---
# The pipe and install.sh both authenticate to RunPod with this key, so a key
# that was rotated or revoked surfaces weeks later as "the pod never wakes".
# Asking the control API once turns that into an immediate, precise answer.
#
# This is a QUERY only. doctor.sh is read-only toward RunPod: it never starts,
# stops or resumes a pod.
#
# The key is never printed, never placed in argv and never written inside the
# repository. It reaches curl through a 0600 --config file in a private temp
# directory that is removed on every exit path.
#
# Fail-safe rule: only an unambiguous auth rejection fails the run. A missing
# tool, a timeout, a network failure, a 5xx or a body that is not JSON prints a
# skip note and leaves the counters and the exit code alone -- a probe that
# cannot answer proves nothing.
RP_TMPDIR=""
cleanup_runpod_tmp() { [[ -n "$RP_TMPDIR" ]] && rm -rf "$RP_TMPDIR"; RP_TMPDIR=""; }
runpod_skip() { (( QUIET )) || printf '  %s-%s RunPod API-key check skipped (%s)\n' "$C_DIM" "$C_RST" "$1"; }

runpod_key_check() {
  local key="$1" pod="$2"
  local dir cfg payload body code rc query desired errlow
  dir="$(mktemp -d "${TMPDIR:-/tmp}/hybrid-ai-doctor-runpod.XXXXXX" 2>/dev/null)"
  if [[ -z "$dir" ]]; then
    runpod_skip "no writable temp directory"
    return 0
  fi
  RP_TMPDIR="$dir"
  trap cleanup_runpod_tmp EXIT
  cfg="$dir/curl.cfg"; payload="$dir/payload.json"; body="$dir/body.json"

  # An env value that carries a control character could inject a config
  # directive, so drop them; the same escaping keeps a quote or a backslash
  # inside the double-quoted header value literal.
  key="${key//[[:cntrl:]]/}"
  key="${key//\\/\\\\}"
  key="${key//\"/\\\"}"

  ( umask 077; : > "$cfg" ) || { runpod_skip "cannot write a private curl config"; return 0; }
  {
    printf 'header = "Authorization: Bearer %s"\n' "$key"
    printf 'header = "Content-Type: application/json"\n'
  } > "$cfg" || { runpod_skip "cannot write a private curl config"; return 0; }

  query="query { pod(input: {podId: \"${pod}\"}) { id desiredStatus } }"
  jq -n --arg q "$query" '{query: $q}' > "$payload" 2>/dev/null \
    || { runpod_skip "cannot build the query payload"; return 0; }

  code="$(curl -sS --config "$cfg" --data-binary "@${payload}" \
            -o "$body" --max-time 15 -w '%{http_code}' \
            https://api.runpod.io/graphql 2>/dev/null)"
  rc=$?

  case "$code" in
    2??)
      if jq -e 'has("data") and (.data.pod != null)' "$body" >/dev/null 2>&1; then
        # A STOPPED pod is a PASS: asleep is the normal, money-saving state.
        desired="$(jq -r '.data.pod.desiredStatus // "UNKNOWN"' "$body" 2>/dev/null)"
        pass "RunPod API key accepted for pod ${pod} (desiredStatus: ${desired:-UNKNOWN})"
      else
        errlow="$(jq -r '.errors[0].message // empty' "$body" 2>/dev/null | tr '[:upper:]' '[:lower:]')"
        if [[ "$errlow" == *auth* || "$errlow" == *forbidden* \
              || "$errlow" == *"invalid api key"* || "$errlow" == *unauthori* ]]; then
          fail "RUNPOD_API_KEY was rejected by the RunPod API" \
               "Rotate the key in the RunPod console (Settings -> API Keys), update RUNPOD_API_KEY in ${ENV_FILE}, then re-run ./doctor.sh."
        else
          runpod_skip "the API answered HTTP ${code} without pod data"
        fi
      fi ;;
    401|403)
      fail "RUNPOD_API_KEY was rejected by the RunPod API" \
           "Rotate the key in the RunPod console (Settings -> API Keys), update RUNPOD_API_KEY in ${ENV_FILE}, then re-run ./doctor.sh." ;;
    *)
      # 000 is curl's "no answer"; anything else is a server or routing problem.
      # Neither says anything about the key.
      if (( rc != 0 )); then
        runpod_skip "the RunPod API was unreachable (curl exit ${rc})"
      else
        runpod_skip "the RunPod API answered HTTP ${code:-000}"
      fi ;;
  esac
  cleanup_runpod_tmp
}

# ---------------------------------------------------------------------------
# Hermes / kanban locations and thresholds.
# Overridable from the environment so the checks can be exercised against
# throwaway fixtures without touching the live deployment. Production defaults
# point at the real bind-mounted paths under the deployment directory.
# ---------------------------------------------------------------------------
HERMES_DATA_DIR="${HERMES_DATA_DIR:-${HYBRID_AI_HERMES_DATA_DIR}}"
DOCTOR_TRIAGE_STALL_MIN="${DOCTOR_TRIAGE_STALL_MIN:-15}"
DEPLOY_ENV="${DEPLOY_ENV:-$HYBRID_AI_ENV_FILE}"

# Read one environment variable from a container's config (not a live exec).
container_env() {
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$1" 2>/dev/null \
    | grep -E "^$2=" | head -1 | cut -d= -f2-
}

# Every compose command must use the same project, env file and BOTH compose
# files. Running with only the OpenHands file makes Compose try to recreate the
# shared network and stops OpenHands -- so remedies always print the full form.
# BOTH resolved env files are passed: the layout file holds the host paths and
# identity settings, the stack file holds the runtime config and secrets. When
# the two resolve to the same path, passing it twice is accepted.
COMPOSE_CMD="docker compose -p hybrid-ai --env-file ${HYBRID_AI_ENV_FILE} --env-file ${ENV_FILE} --project-directory ${APP_DIR} -f ${APP_DIR}/docker-compose.yml -f ${APP_DIR}/openhands/docker-compose.openhands.yml -f ${APP_DIR}/hermes/docker-compose.hermes.yml"

(( QUIET )) || {
  printf '%s\n' "============================================================"
  printf '  hybrid-ai health check  ::  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  printf '%s\n' "============================================================"
}

# ---------------------------------------------------------------------------
# 0. Paths
# ---------------------------------------------------------------------------
# Print the resolved host paths so a split layout is obvious at a glance. Only
# PATH settings are printed -- never a credential, a uid, or any other value
# from the env file. A path that was SET (present in the env file or the
# environment) but does not exist is a WARNING, never a failure: the directory
# may simply not have been created yet.
section "Paths"
# The helper records which settings were SET (by the environment or the env
# file) in HYBRID_AI_EXPLICIT_SETTINGS. Only a SET path is warned about when it
# does not exist -- a default is never noise.
PATH_IS_EXPLICIT=" ${HYBRID_AI_EXPLICIT_SETTINGS:-} "
for _name in HYBRID_AI_APP_DIR HYBRID_AI_ENV_FILE HYBRID_AI_STACK_ENV_FILE \
             HYBRID_AI_DATA_DIR \
             HYBRID_AI_LOG_DIR HYBRID_AI_WORK_DIR OPENHANDS_WORKSPACE \
             AGENT_REPOS_DIR OPENHANDS_STATE_DIR BACKUP_CONF_DIR \
             HYBRID_AI_BACKUP_CRED_DIR \
             RESTIC_CACHE_DIR BACKUP_LOG; do
  _p="${!_name}"
  # HYBRID_AI_BACKUP_CRED_DIR is the directory the Backups section actually
  # checks (mode-aware: the root-owned credstore in system mode, BACKUP_CONF_DIR
  # in user mode). BACKUP_CONF_DIR stays printed but is labelled as the
  # user-mode config setting, so the two paths cannot be confused (D11). Paths
  # only -- never a credential value.
  case "$_name" in
    BACKUP_CONF_DIR)        _label="BACKUP_CONF_DIR (user-mode config setting)" ;;
    HYBRID_AI_BACKUP_CRED_DIR) _label="HYBRID_AI_BACKUP_CRED_DIR (checked by the Backups section)" ;;
    *)                      _label="$_name" ;;
  esac
  pass "${_label} = ${_p}"
  if [[ "$_name" != "HYBRID_AI_ENV_FILE" && "$_name" != "HYBRID_AI_STACK_ENV_FILE" && ! -e "$_p" \
        && "$PATH_IS_EXPLICIT" == *" ${_name} "* ]]; then
    warn "${_name} is set but does not exist: ${_p}" \
         "Create it, or unset ${_name} to fall back to the default."
  fi
done
unset _name _p _label PATH_IS_EXPLICIT

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

if [[ -f "$ENV_FILE" ]]; then
  pass "env file present ($ENV_FILE)"
  PERMS="$(stat -c '%a' "$ENV_FILE" 2>/dev/null)"
  if [[ "$PERMS" == "600" ]]; then
    pass "env file permissions correct (600)"
  else
    fail "env file permissions are ${PERMS}, expected 600" "Fix: chmod 600 ${ENV_FILE}"
  fi

  for key in WEBUI_SECRET_KEY RUNPOD_API_KEY RUNPOD_POD_ID RUNPOD_HOST PEER_HOSTNAME; do
    if [[ -n "$(env_get "$key")" ]]; then
      pass "${key} is set"
    else
      warn "${key} is empty" "Re-run ./install.sh to populate it."
    fi
  done

  # The Hermes decomposer falls back to OpenRouter when no GPU pod is warm. If
  # this key is blank, every decompose tick fails and cards sit in Triage with
  # no visible error. Presence only -- the value is never printed.
  OR_KEY="$(env_get OPENROUTER_API_KEY)"
  if [[ -n "$OR_KEY" ]]; then
    pass "OPENROUTER_API_KEY is set in the env file"
  else
    warn "OPENROUTER_API_KEY is empty in the env file" \
         "The Hermes decomposer and the OpenRouter fallback need it. Set it (see .env.example), then: ${COMPOSE_CMD} up -d"
  fi
  unset OR_KEY

  # --- OpenRouter credential present for board profiles ---------------------
  # Each Hermes profile has its own .env under hermes_data/. A board-running
  # profile (default/builder/reviewer) with no OpenRouter key stalls its board
  # exactly like the deployment-wide case above. If hermes_data is absent there
  # are no profiles to check, so emit a single warn rather than one per path.
  if [[ ! -d "$HERMES_DATA_DIR" ]]; then
    warn "OpenRouter credential present for board profiles: ${HERMES_DATA_DIR} not present" \
         "No Hermes profiles on this host, so their OpenRouter credentials cannot be checked. Run ./install.sh to create ${HERMES_DATA_DIR}."
  else
    for prof_env in "${HERMES_DATA_DIR}/.env" \
                    "${HERMES_DATA_DIR}/profiles/builder/.env" \
                    "${HERMES_DATA_DIR}/profiles/reviewer/.env"; do
      case "$(env_key_state "$prof_env" OPENROUTER_API_KEY)" in
        set)        pass "OPENROUTER_API_KEY is set in ${prof_env}" ;;
        unreadable) warn "cannot read ${prof_env}" \
                         "The OpenRouter credential in this profile cannot be verified by this user." ;;
        *)          warn "OPENROUTER_API_KEY is missing or empty in ${prof_env}" \
                         "Set it in that profile's env file (see .env.example) and restart Hermes: ${COMPOSE_CMD} up -d hermes" ;;
      esac
    done
  fi

  # --- GPU pod MagicDNS name resolves inside the mesh ----------------------
  # The deployment stores the pod's MagicDNS NAME (RUNPOD_HOST), never an
  # address: a pod address changes whenever the pod is recreated, so a stored
  # copy goes stale. The name is resolved here and the RESOLVED ADDRESS is what
  # gets validated against [IP_ADDRESS]/10 -- never the name. Mesh addresses are
  # 100.64.x.x - 100.127.x.x; anything else means the pipe will refuse to send,
  # which is the safety net working correctly. Nothing here prints the name or
  # the address; at most a masked 100.x.x.x.
  #
  # POLICY: the deploy gate fails on CONFIGURATION ERRORS, never on a peer being
  # asleep. An on-demand GPU pod leaves the tailnet when it stops, so its
  # MagicDNS name stops resolving: that is the normal money-saving state, not a
  # misconfiguration, so it is a WARNING. A name that is not shaped like a pod
  # MagicDNS record (`<pod>.<tailnet>.ts.net`) is a configuration error and does
  # fail, because nothing could ever resolve it.
  POD_NAME="$(env_get RUNPOD_HOST)"
  if [[ -z "$POD_NAME" ]]; then
    warn "RUNPOD_HOST is empty" \
         "Re-run ./install.sh to record the pod's MagicDNS name."
  else
    POD_ADDR="$(resolve_mesh_address "$POD_NAME")"
    POD_RC=$?
    case "$POD_RC" in
      2)
        # No resolver on this host (no tailscale CLI, no getent), so the name
        # cannot be checked here. That is a gap in this host's tooling, not a
        # misconfiguration, so it must not touch the counters or the exit code.
        (( QUIET )) || printf '  %s-%s GPU pod MagicDNS name resolution skipped (no tailscale CLI and no getent on this host)\n' "$C_DIM" "$C_RST"
        (( QUIET )) || printf '  %s  Nothing is wrong with .env; run this check on the Pi.%s\n' "$C_DIM" "$C_RST" ;;
      1)
        # Unresolved. Whether that is a fault depends on the NAME's shape.
        # The MagicDNS pod record is `<pod>.<tailnet>.ts.net`: two non-empty
        # labels, then the .ts.net suffix, so no leading, trailing or doubled
        # dots. A stopped pod loses that record, so this is the normal
        # on-demand state. Any other shape cannot be a pod record at all, so it
        # is a configuration error.
        if [[ "$POD_NAME" =~ ^[^.]+\.[^.]+\.ts\.net$ ]]; then
          warn "RUNPOD_HOST does not resolve right now: the GPU pod may be asleep or not yet registered on this tailnet (normal for an on-demand pod - it wakes when the pipe sends work)" \
               "To verify end-to-end that a pod can start and join the tailnet: sudo ./install.sh --wake-runpod"
        else
          fail "RUNPOD_HOST does not resolve to an address and is not shaped like a pod MagicDNS name (expected <pod>.<tailnet>.ts.net, e.g. runpod-worker.example-tailnet.ts.net)" \
               "Re-run ./install.sh to record the pod's MagicDNS name."
        fi ;;
      0)
        if mesh_range_ok "$POD_ADDR"; then
          pass "RUNPOD_HOST resolves inside the Tailscale mesh"
        else
          fail "RUNPOD_HOST resolves to an address outside the Tailscale range" \
               "The pipe will refuse to send prompts. Re-run ./install.sh to rediscover the pod."
        fi ;;
    esac
    unset POD_ADDR
  fi
  unset POD_NAME

  # --- RunPod API key is accepted by the control API -----------------------
  # Deliberately NOT gated behind NO_CLOUD: the deploy gate runs
  # `./doctor.sh --no-cloud` and a revoked key is exactly what that gate must
  # catch. This is one short query against the RunPod control API -- nothing to
  # do with R2, which is what --no-cloud skips. Presence of the two settings is
  # already reported above, so a missing one only prints a skip note here.
  RUNPOD_KEY="$(env_get RUNPOD_API_KEY)"
  RUNPOD_POD="$(env_get RUNPOD_POD_ID)"
  if [[ -z "$RUNPOD_KEY" || -z "$RUNPOD_POD" ]]; then
    runpod_skip "RUNPOD_API_KEY or RUNPOD_POD_ID is not set"
  elif ! command -v curl >/dev/null 2>&1; then
    runpod_skip "curl is not installed"
  elif ! command -v jq >/dev/null 2>&1; then
    runpod_skip "jq is not installed"
  else
    runpod_key_check "$RUNPOD_KEY" "$RUNPOD_POD"
  fi
  unset RUNPOD_KEY RUNPOD_POD

  # --- OpenHands credential store -----------------------------------------
  # Holds the LLM provider key you enter in the OpenHands UI. Outside the repo
  # so it is never committed and never visible to the agent sandbox.
  if [[ -d "$OPENHANDS_STATE_DIR" ]]; then
    OH_PERMS="$(stat -c '%a' "$OPENHANDS_STATE_DIR" 2>/dev/null)"
    if [[ "$OH_PERMS" == "700" ]]; then
      pass "${OPENHANDS_STATE_DIR} permissions correct (700)"
    else
      fail "${OPENHANDS_STATE_DIR} is ${OH_PERMS}, expected 700" \
           "Fix: chmod 700 ${OPENHANDS_STATE_DIR}"
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
    DEPLOY_REAL="$(readlink -f "$APP_DIR")"
    # The directory of EACH env file is guarded: the layout file and the stack
    # file. A workspace that IS either directory, or CONTAINS one, can read a
    # secret or a deployment setting, so both must be refused.
    ENV_DIR_REAL="$(dirname "$(readlink -f "$HYBRID_AI_ENV_FILE" 2>/dev/null || echo "$HYBRID_AI_ENV_FILE")")"
    STACK_ENV_DIR_REAL="$(dirname "$(readlink -f "$HYBRID_AI_STACK_ENV_FILE" 2>/dev/null || echo "$HYBRID_AI_STACK_ENV_FILE")")"
    if [[ "$OH_WS_REAL" == "$DEPLOY_REAL" ]]; then
      fail "OPENHANDS_WORKSPACE is the deployment directory" \
           "The agent sandbox could read the env file and the log files. Fix: ./scripts/setup-agent-workspace.sh"
    elif [[ "$OH_WS_REAL" == "$ENV_DIR_REAL" || "$OH_WS_REAL" == "$STACK_ENV_DIR_REAL" ]]; then
      fail "OPENHANDS_WORKSPACE is an env-file directory" \
           "That defeats the isolation. Fix: ./scripts/setup-agent-workspace.sh"
    elif [[ -e "${OH_WS}/.env" || -e "$HYBRID_AI_ENV_FILE" && "$OH_WS_REAL" == "$ENV_DIR_REAL" || -e "$HYBRID_AI_STACK_ENV_FILE" && "$OH_WS_REAL" == "$STACK_ENV_DIR_REAL" ]]; then
      fail "An env file exists inside the agent workspace" \
           "That defeats the isolation. Remove it: rm ${OH_WS}/.env"
    elif [[ -d "${OH_WS}/.git" ]]; then
      pass "Agent workspace isolated from the deployment directory"
    else
      warn "Agent workspace ${OH_WS} is not a git clone" \
           "OpenHands will start with an empty workspace. Fix: ./scripts/setup-agent-workspace.sh"
    fi
  fi
else
  fail "env file is missing ($ENV_FILE)" "Run ./install.sh to create it."
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

# --- Hermes :: read-only agent-repo mount and the internal coder-net ---------
# Two things this change introduced, both load-bearing:
#   1. /agent-repo is the OpenHands clone mounted READ-ONLY. If it ever became
#      writable, Hermes could edit the repository the sandbox is reviewing.
#   2. coder-net is the internal network shared only by hermes and openhands.
#      Any other member is a misconfiguration worth surfacing.
if docker info >/dev/null 2>&1; then
  if docker inspect hermes-agent >/dev/null 2>&1; then
    REPO_RW="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/agent-repo"}}{{.RW}}{{end}}{{end}}' hermes-agent 2>/dev/null)"
    if [[ "$REPO_RW" == "false" ]]; then
      pass "Hermes /agent-repo is mounted read-only"
    elif [[ "$REPO_RW" == "true" ]]; then
      fail "Hermes /agent-repo is mounted READ-WRITE" \
           "It must be ':ro'. Fix hermes/docker-compose.hermes.yml, then: ${COMPOSE_CMD} up -d hermes"
    else
      fail "Hermes has no /agent-repo mount" \
           "Add '\${OPENHANDS_WORKSPACE:?...}:/agent-repo:ro' to hermes/docker-compose.hermes.yml, then: ${COMPOSE_CMD} up -d hermes"
    fi

    # The gateway ("gateway run") is the long-lived process that drains the
    # kanban queue. Read-only host probe via docker top; never docker exec.
    if docker top hermes-agent 2>/dev/null \
         | grep -Eq '(^|[[:space:]])(hermes[[:space:]]+)?gateway[[:space:]]+run([[:space:]]|$)'; then
      pass "Hermes gateway process is running inside hermes-agent"
    else
      warn "Hermes gateway process NOT running inside hermes-agent" \
           "The kanban dispatcher will not run. Fix: ${COMPOSE_CMD} up -d --force-recreate hermes"
    fi

    # --- Hermes code location (WARN only) ---------------------------------
    # The WebUI is PID 1 and hosts every chat and tool. It must load Hermes code
    # and Python from the pinned, root-owned /opt/hermes-agent -- never from the
    # data-volume copy at /root/.hermes. Until the migration removes that old copy
    # (kept for rollback), a volume that still holds it wins unless the image pins
    # the agent dir and interpreter. This reads PID 1's mapped files read-only. It
    # WARNS and never fails: a legacy image on an older host legitimately maps
    # /root/.hermes today, and the remedy is an image rebuild, not a live edit.
    PID1_CODE_PATHS="$(docker exec hermes-agent sh -c 'cat /proc/1/maps' 2>/dev/null \
                       | awk '{print $NF}' | grep -E '/venv/|/site-packages/' || true)"
    if [[ -z "$PID1_CODE_PATHS" ]]; then
      warn "Hermes WebUI code location could not be read" \
           "Could not read PID 1's mapped Python paths (container not running or no shell). Re-run when Hermes is up."
    elif printf '%s\n' "$PID1_CODE_PATHS" | grep -q '/root/\.hermes'; then
      warn "Hermes WebUI (PID 1) is running code from the data volume (/root/.hermes)" \
           "It must load only the pinned /opt/hermes-agent. Rebuild and recreate: ${COMPOSE_CMD} up -d --build hermes"
    else
      pass "Hermes WebUI (PID 1) maps code from the pinned install, not the data volume"
    fi

    # --- Hermes effective uid ---------------------------------------------
    # WARN (never fail) while Hermes runs as uid 0: that is the legacy default
    # on every existing host, and the account migration sets HYBRID_AI_UID to
    # move it to a dedicated non-root service uid.
    HERMES_RUN_UID="$(docker inspect -f '{{.Config.User}}' hermes-agent 2>/dev/null)"
    case "$HERMES_RUN_UID" in
      ""|"0"|"0:0"|"root"|"root:root")
        warn "Hermes runs as root (uid 0)" \
             "Legacy default. Set HYBRID_AI_UID/HYBRID_AI_GID in .env to the dedicated non-root service uid, then: ${COMPOSE_CMD} up -d --build hermes"
        ;;
      *)
        pass "Hermes runs as a non-root uid (${HERMES_RUN_UID})"
        ;;
    esac

    # hermes_data should be owned by the configured non-root uid. Count only,
    # never names: the report must not leak directory contents.
    CFG_UID="$(env_get HYBRID_AI_UID)"
    if [[ -n "$CFG_UID" && "$CFG_UID" != "0" && "$CFG_UID" =~ ^[0-9]+$ && -d "$HERMES_DATA_DIR" ]]; then
      FOREIGN="$(find "$HERMES_DATA_DIR" ! -uid "$CFG_UID" 2>/dev/null | wc -l | tr -d ' ')"
      if [[ "${FOREIGN:-0}" -gt 0 ]]; then
        warn "hermes_data has ${FOREIGN} entr(ies) not owned by HYBRID_AI_UID=${CFG_UID}" \
             "Fix ownership before Hermes starts as that uid, e.g.: sudo chown -R ${CFG_UID}:${CFG_UID} ${HERMES_DATA_DIR}"
      else
        pass "hermes_data is owned by HYBRID_AI_UID=${CFG_UID}"
      fi
    fi
  else
    warn "hermes-agent container not found" "Cannot verify the /agent-repo mount. Run ./install.sh."
  fi

  # --- Kanban Triage not stalled --------------------------------------------
  # With kanban.auto_decompose enabled, a healthy card leaves Triage within
  # about 60s. A card that stays in Triage past the threshold -- whose only
  # event is 'created' -- means the decomposer never picked it up: the silent
  # failure that let a board sit idle for 35 minutes on 2026-10-13.
  #
  # Card text is untrusted input, so only ids and counts leave SQL; titles,
  # bodies, comments and event payloads are never selected or printed. The
  # database is opened read-only, and every failure path degrades to one warn.
  #
  # The threshold must be a whole number of minutes. A stray suffix (e.g.
  # "15m") would make the arithmetic below throw "value too great for base" and
  # print no Triage result at all, so validate it and fall back to 15.
  if [[ ! "$DOCTOR_TRIAGE_STALL_MIN" =~ ^[0-9]+$ ]]; then
    warn "DOCTOR_TRIAGE_STALL_MIN='${DOCTOR_TRIAGE_STALL_MIN}' is not a whole number of minutes" \
         "Using the default of 15 minutes. Set it to an integer (minutes), e.g. DOCTOR_TRIAGE_STALL_MIN=15 ./doctor.sh"
    DOCTOR_TRIAGE_STALL_MIN=15
  fi
  if [[ ! -d "$HERMES_DATA_DIR" ]]; then
    warn "Kanban Triage not stalled: ${HERMES_DATA_DIR} not present" \
         "No Hermes data on this host, so the kanban pipeline cannot be checked."
  elif ! command -v sqlite3 >/dev/null 2>&1; then
    warn "Kanban Triage not stalled: sqlite3 not available" \
         "Cannot read the kanban databases. Install sqlite3: sudo apt-get install -y sqlite3"
  else
    KANBAN_DBS=()
    for db in "${HERMES_DATA_DIR}"/kanban/boards/*/kanban.db; do
      [[ -f "$db" ]] && KANBAN_DBS+=("$db")
    done
    if (( ${#KANBAN_DBS[@]} == 0 )); then
      warn "Kanban Triage not stalled: no board database found" \
           "Expected ${HERMES_DATA_DIR}/kanban/boards/*/kanban.db. Create a board in the Hermes WebUI."
    else
      NOW_EPOCH="$(date +%s)"
      THRESH_EPOCH=$(( NOW_EPOCH - DOCTOR_TRIAGE_STALL_MIN * 60 ))
      for db in "${KANBAN_DBS[@]}"; do
        BOARD="$(basename "$(dirname "$db")")"
        # Counts come straight from SQL. The id list is the only per-row data
        # selected, and it is joined with sed -- no card text is ever read.
        # `set -o pipefail` (set at the top) makes $? reflect sqlite3's own
        # exit status, so a corrupt, locked, unreadable or non-SQLite file is
        # detected instead of being mistaken for a healthy empty result.
        STALL_COUNT="$(sqlite3 "file:${db}?mode=ro" \
          "SELECT COUNT(*) FROM tasks WHERE status='triage' AND created_at < ${THRESH_EPOCH};" 2>/dev/null \
          | head -1)"
        RC=$?
        if (( RC != 0 )) || [[ ! "$STALL_COUNT" =~ ^[0-9]+$ ]]; then
          warn "Kanban Triage not stalled: cannot query board ${BOARD}" \
               "The kanban database at ${db} could not be read (corrupt, locked, non-SQLite or unreadable). Inspect it read-only, e.g.: sqlite3 \"file:${db}?mode=ro\" 'PRAGMA quick_check;'. See docs/TROUBLESHOOTING.md."
          continue
        fi
        if [[ "$STALL_COUNT" == "0" ]]; then
          pass "Kanban Triage not stalled on board ${BOARD}"
          continue
        fi
        # Of those, how many have no event other than 'created' -- the failure
        # signature: the decomposer never touched them.
        CREATED_ONLY="$(sqlite3 "file:${db}?mode=ro" \
          "SELECT COUNT(*) FROM tasks t WHERE t.status='triage' AND t.created_at < ${THRESH_EPOCH} AND NOT EXISTS (SELECT 1 FROM task_events e WHERE e.task_id = t.id AND e.kind <> 'created');" 2>/dev/null \
          | head -1)"
        [[ "$CREATED_ONLY" =~ ^[0-9]+$ ]] || CREATED_ONLY="?"
        STALL_IDS="$(sqlite3 "file:${db}?mode=ro" \
          "SELECT id FROM tasks WHERE status='triage' AND created_at < ${THRESH_EPOCH};" 2>/dev/null \
          | sed '/^$/d' | tr '\n' ' ' | sed 's/ *$//')"
        warn "Kanban Triage stalled on board ${BOARD}: ${STALL_COUNT} task(s) older than ${DOCTOR_TRIAGE_STALL_MIN}m (ids: ${STALL_IDS}); ${CREATED_ONLY} have no event other than 'created'" \
             "The auto-decomposer is not picking up Triage cards. Check the auxiliary provider/credential: hermes -p default config get auxiliary ; confirm OPENROUTER_API_KEY is set in the default profile .env; then: ${COMPOSE_CMD} up -d --force-recreate hermes. See docs/TROUBLESHOOTING.md."
      done
    fi
  fi

  # coder-net must be internal and carry exactly hermes-agent + hybrid-ai-openhands.
  CNET_INTERNAL="$(docker network inspect coder-net -f '{{.Internal}}' 2>/dev/null)"
  if [[ -z "$CNET_INTERNAL" ]]; then
    warn "coder-net network not found" \
         "Hermes cannot reach the OpenHands API by service name. Recreate: ${COMPOSE_CMD} up -d"
  else
    if [[ "$CNET_INTERNAL" == "true" ]]; then
      pass "coder-net is internal (no route off the host)"
    else
      fail "coder-net is NOT internal" \
           "Set 'internal: true' for coder-net in docker-compose.yml, then: ${COMPOSE_CMD} up -d"
    fi

    CNET_MEMBERS="$(docker network inspect coder-net -f '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null | tr ' ' '\n' | sed '/^$/d' | sort | tr '\n' ' ' | sed 's/ *$//')"
    CNET_UNEXPECTED=""
    for m in $CNET_MEMBERS; do
      case "$m" in
        hermes-agent|hybrid-ai-openhands) ;;
        *) CNET_UNEXPECTED="${CNET_UNEXPECTED}${m} " ;;
      esac
    done
    if [[ -n "$CNET_UNEXPECTED" ]]; then
      fail "coder-net has unexpected member(s): ${CNET_UNEXPECTED% }" \
           "Only hermes and openhands may attach. Recreate: ${COMPOSE_CMD} up -d"
    elif [[ "$CNET_MEMBERS" == "hermes-agent hybrid-ai-openhands" ]]; then
      pass "coder-net has exactly hermes and openhands attached"
    else
      warn "coder-net members: ${CNET_MEMBERS:-none} (expected hermes-agent + hybrid-ai-openhands)" \
           "A container is stopped or not yet attached. Recreate: ${COMPOSE_CMD} up -d"
    fi
  fi
fi

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
declare -a SANDBOXES=()
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
    pass "Proxy: /openwebui redirects to the site root / (expected)"
  else
    warn "Proxy: /openwebui returned HTTP ${code}, expected 302" \
         "Open WebUI cannot be served under a subpath; this alias must redirect."
  fi
else
  warn "Status page not reachable on port 80" \
       "Optional feature. Chat still works on :3000. Check: docker logs --tail 30 hybrid-ai-proxy; docker logs --tail 30 hybrid-ai-status"
fi

# --- Pinned sandbox image reaches the app-server, and the sandboxes --------
# The stack pins the hybrid agent-server image, but two independent things
# can leave a stock image running: the env pair never reaching the app-server
# (host .env carries explicit OPENHANDS_AGENT_IMAGE_* values), or the
# app-server build ignoring the override. Neither is visible from the UI, so
# this probe compares the container env AND every live sandbox's real image
# against the resolved pin. It is WARNING-ONLY: warn/pass/skip, never fail().
# Anything it cannot read is a skip, so a host without Docker stays quiet.
sandbox_image_probe() {  # uses the SANDBOXES array already collected above
  local repo_want tag_want want skip seen_repo seen_tag unreadable=() drift=0 sb img
  repo_want="$(env_get OPENHANDS_AGENT_IMAGE_REPOSITORY)"
  repo_want="${repo_want:-ghcr.io/jimbobsyouruncle/openhands-agent-server-hybrid}"
  tag_want="$(env_get OPENHANDS_AGENT_IMAGE_TAG)"
  tag_want="${tag_want:-1.37.1-python-hybrid.3}"
  want="${repo_want}:${tag_want}"

  skip=""
  if ! command -v docker >/dev/null 2>&1; then
    skip="docker is not installed"
  elif ! docker inspect -f '{{.Id}}' hybrid-ai-openhands >/dev/null 2>&1; then
    skip="cannot read the app-server container hybrid-ai-openhands"
  fi
  if [[ -n "$skip" ]]; then
    (( QUIET )) || printf '  %s-%s sandbox image check skipped (%s)\n' "$C_DIM" "$C_RST" "$skip"
    return 0
  fi

  seen_repo="$(container_env hybrid-ai-openhands AGENT_SERVER_IMAGE_REPOSITORY)"
  seen_tag="$(container_env hybrid-ai-openhands AGENT_SERVER_IMAGE_TAG)"
  if [[ "${seen_repo}:${seen_tag}" == "$want" ]]; then
    pass "App-server carries the pinned sandbox image env (${want})"
  else
    warn "OpenHands app-server does not carry the pinned sandbox image env" \
         "Running container has AGENT_SERVER_IMAGE_REPOSITORY=${seen_repo:-unset} and AGENT_SERVER_IMAGE_TAG=${seen_tag:-unset}; the pin resolves to ${want}. A host .env with explicit OPENHANDS_AGENT_IMAGE_* values overrides the default: unset them by name, then re-run ./install.sh so the overlay env is recreated, and start a NEW conversation."
  fi

  for sb in "${SANDBOXES[@]}"; do
    img="$(docker inspect -f '{{.Config.Image}}' "$sb" 2>/dev/null)"
    if [[ -z "$img" ]]; then
      unreadable+=("$sb")
      continue
    fi
    if [[ "$img" != "$want" ]]; then
      drift=$(( drift + 1 ))
      warn "${sb} runs image ${img}, not the pinned ${want}" \
           "A sandbox keeps the config it was created with, so fixing the env never reaches it: start a NEW conversation (and remove the old one: docker rm -f ${sb}). If a FRESH sandbox still runs ${img} while the app-server carries ${want}, the app-server build does not honour the override - report that finding and investigate upstream at the deployed app-server tag, or bump the pin. Do not patch around it here."
    fi
  done

  if (( ${#SANDBOXES[@]} == 0 )); then
    pass "Sandbox image pin ${want}: no live sandbox to compare yet (one starts with each new conversation)"
  elif (( drift == 0 && ${#unreadable[@]} == 0 )); then
    pass "Every live sandbox runs the pinned image ${want}"
  fi
  if (( ${#unreadable[@]} > 0 )); then
    (( QUIET )) || printf '  %s-%s sandbox image check skipped for %d sandbox(es): cannot read the container image (%s)\n' \
      "$C_DIM" "$C_RST" "${#unreadable[@]}" "${unreadable[*]}"
  fi
  return 0
}

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

  sandbox_image_probe

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
           "This sandbox predates the shipped fix, or the /etc/gitconfig mount is missing. Every new sandbox mounts a read-only system git config that trusts only /workspace and /workspace/project/*, so git accepts the bind mount. Re-run ./install.sh, then start a NEW conversation: an existing sandbox keeps the mounts it was created with."
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
      # Never derive the owner from the calling user: doctor runs under sudo, so
      # `id -un` is root and the printed fix would hand the whole workspace to
      # root. Use the stack identity, then the workspace's own owner.
      WS_OWNER="$(env_get HYBRID_AI_UID)"; WS_OWNER="${WS_OWNER:-$(stat -c '%u' "$OH_WS" 2>/dev/null)}"
      WS_GROUP="$(env_get HYBRID_AI_GID)"; WS_GROUP="${WS_GROUP:-$(stat -c '%g' "$OH_WS" 2>/dev/null)}"
      fail "Root-owned files in the workspace: $(echo "$ROOT_OWNED" | tr '\n' ' ')" \
           "Fix: sudo chown -R ${WS_OWNER}:${WS_GROUP} ${OH_WS} && sudo setfacl -R -m u:${OH_SB_UID}:rwx ${OH_WS}"
    else
      pass "No root-owned files at the top of the workspace"
    fi
  fi
else
  # The app-server is not running, so section 5 cannot inspect containers --
  # but the image pin is still checkable, and a stock sandbox left over from
  # before the cut-over is exactly the drift this probe exists to surface.
  sandbox_image_probe
fi

# ---------------------------------------------------------------------------
# 5a. OpenHands sandbox startup grace (WARNING-ONLY)
#
# Placed OUTSIDE the container-inspect gate above on purpose: the only thing
# that decides whether this check runs is whether the app-server answers, so a
# warning still surfaces when the container is not detected. It never calls
# fail(), so it adds no path to exit 2.
# ---------------------------------------------------------------------------
# --- Startup grace: starts marked terminally ERROR ------------------------
# The app-server gives a new sandbox only its built-in grace to answer
# /health (15s in the 1.10 build). This Pi's agent-server answers at ~21s, so
# a start that loses the race is set to ERROR with "Sandbox entered error
# state" and never recovers. The circuit is OPENHANDS_STARTUP_GRACE_SECONDS in
# openhands/docker-compose.openhands.yml.
#
# WARNING-ONLY: a read-only inspection must never turn a deploy red, so this
# check never calls fail(). The search endpoint paginates and page 1 alone
# hides the older rows, so every page is followed until a row falls outside
# the window. Only a count and the remedy are printed -- no task text, no
# credential. The window is overridable so the offline harness can drive it.
STARTUP_GRACE_WINDOW_MINUTES="${STARTUP_GRACE_WINDOW_MINUTES:-30}"
grace_epoch() {
  local v="$1"
  [[ -z "$v" ]] && { printf '0'; return; }
  if [[ "$v" =~ ^[0-9]+$ ]]; then
    if (( ${#v} >= 13 )); then printf '%s' "$(( v / 1000 ))"; else printf '%s' "$v"; fi
    return
  fi
  date -u -d "$v" +%s 2>/dev/null || printf '0'
}
if [[ ! "$STARTUP_GRACE_WINDOW_MINUTES" =~ ^[0-9]+$ ]]; then
  (( QUIET )) || printf '  %s-%s startup-grace check skipped (STARTUP_GRACE_WINDOW_MINUTES is not whole minutes)\n' "$C_DIM" "$C_RST"
elif ! command -v jq >/dev/null 2>&1; then
  (( QUIET )) || printf '  %s-%s startup-grace check skipped (jq not available)\n' "$C_DIM" "$C_RST"
else
  GRACE_CUTOFF=$(( $(date +%s) - STARTUP_GRACE_WINDOW_MINUTES * 60 ))
  GRACE_PAGE_ID=""
  GRACE_COUNT=0
  GRACE_PAGES=0
  GRACE_SKIP=""
  while :; do
    GRACE_PAGES=$(( GRACE_PAGES + 1 ))
    GRACE_URL="http://127.0.0.1:${OH_PORT}/api/v1/app-conversations/start-tasks/search"
    [[ -n "$GRACE_PAGE_ID" ]] && GRACE_URL="${GRACE_URL}?page_id=${GRACE_PAGE_ID}"
    GRACE_BODY="$(curl -fsS --max-time 10 -H 'Accept: application/json' "$GRACE_URL" 2>/dev/null)"
    if [[ -z "$GRACE_BODY" ]]; then
      GRACE_SKIP="app-server not answering on ${OH_PORT}"
      break
    fi
    if ! printf '%s' "$GRACE_BODY" | jq -e 'has("items") or has("data")' >/dev/null 2>&1; then
      GRACE_SKIP="unexpected app-server response"
      break
    fi
    GRACE_OUT_OF_WINDOW=0
    while IFS=$'\t' read -r g_status g_ts g_err; do
      [[ -n "$g_status" || -n "$g_ts" ]] || continue
      g_epoch="$(grace_epoch "$g_ts")"
      if (( g_epoch > 0 && g_epoch < GRACE_CUTOFF )); then
        GRACE_OUT_OF_WINDOW=1
        break
      fi
      if [[ "$g_status" == "ERROR" && "$g_err" == *"Sandbox entered error state"* ]]; then
        GRACE_COUNT=$(( GRACE_COUNT + 1 ))
      fi
    done < <(printf '%s' "$GRACE_BODY" | jq -r '
      (.items // .data // [])[]
      | [ (.status // ""),
          (.updated_at // .created_at // .updated_at_ns // "" | tostring),
          ([(.error // empty),(.error_detail // empty),(.detail // empty),(.message // empty)] | map(tostring) | join(" ")) ]
      | @tsv' 2>/dev/null)
    (( GRACE_OUT_OF_WINDOW )) && break
    GRACE_PAGE_ID="$(printf '%s' "$GRACE_BODY" | jq -r '.next_page_id // empty' 2>/dev/null)"
    [[ -n "$GRACE_PAGE_ID" ]] || break
    (( GRACE_PAGES >= 50 )) && break
  done
  if [[ -n "$GRACE_SKIP" ]]; then
    (( QUIET )) || printf '  %s-%s startup-grace check skipped (%s)\n' "$C_DIM" "$C_RST" "$GRACE_SKIP"
  elif (( GRACE_COUNT > 0 )); then
    warn "${GRACE_COUNT} sandbox start(s) in the last ${STARTUP_GRACE_WINDOW_MINUTES}m were marked terminally ERROR (\"Sandbox entered error state\")" \
         "The app-server startup grace is too short for this Pi. Set OPENHANDS_STARTUP_GRACE_SECONDS in .env (see openhands/docker-compose.openhands.yml), then: ${COMPOSE_CMD} up -d openhands"
  else
    pass "No sandbox start marked terminally ERROR in the last ${STARTUP_GRACE_WINDOW_MINUTES}m"
  fi
  unset GRACE_PAGE_ID GRACE_BODY GRACE_URL g_status g_ts g_err g_epoch
fi

# ---------------------------------------------------------------------------
# 5a2. Sandbox network containment (WARNING-ONLY)
#
# Placed outside the container-inspect gate for the same reason as 5a: the
# rules live in the host's DOCKER-USER chain, so the answer does not depend on
# any container being detected.
#
# WARNING-ONLY: `iptables -S` is the only command this runs -- no insert,
# append, delete, flush or restore -- so it cannot change firewall state, and
# it never calls fail(), so it adds no path to exit 2. A sandbox port being
# reachable from the LAN is worth a warning even when everything else is
# healthy, but it must never turn a deploy red.
#
# THE SKIP PATH EXISTS because the probe genuinely cannot answer everywhere: a
# non-Linux host has no iptables, a non-root run may not read the chain, and
# Docker may not have created DOCKER-USER yet. Each of those prints a dim
# "skipped" line and leaves the exit code exactly as it would have been.
#
# It accepts exactly what scripts/sandbox-firewall.sh installs: the three rules
# carrying its comment tag -- the single ACCEPT for the docker0 gateway webhook
# path on the sandbox port, the DROP from docker0 to the other Docker networks,
# and the DROP from external interfaces into docker0.
# ---------------------------------------------------------------------------
SBX_TAG="hybrid-ai-sandbox-egress"
SBX_CHAIN="DOCKER-USER"
SBX_GATEWAY="172.17.0.1"
SBX_PORT="${OH_PORT:-3001}"
SBX_LISTING=""
SBX_SKIP=""
SBX_ACCEPT=0
SBX_D0_DROP=0
SBX_EXT_DROP=0
if [[ "$(uname -s 2>/dev/null)" != "Linux" ]]; then
  SBX_SKIP="not a Linux host"
elif ! command -v iptables >/dev/null 2>&1; then
  SBX_SKIP="iptables not installed"
elif ! SBX_LISTING="$(iptables -w 5 -S "$SBX_CHAIN" 2>/dev/null)"; then
  SBX_SKIP="cannot read ${SBX_CHAIN} (needs root, or Docker is not up)"
elif [[ -z "$SBX_LISTING" ]]; then
  SBX_SKIP="empty ${SBX_CHAIN} listing"
elif [[ "$SBX_LISTING" != *"-N ${SBX_CHAIN}"* && "$SBX_LISTING" != *"-A ${SBX_CHAIN}"* ]]; then
  SBX_SKIP="unexpected ${SBX_CHAIN} listing"
fi

if [[ -n "$SBX_SKIP" ]]; then
  (( QUIET )) || printf '  %s-%s sandbox firewall check skipped (%s)\n' "$C_DIM" "$C_RST" "$SBX_SKIP"
else
  while IFS= read -r SBX_LINE; do
    [[ "$SBX_LINE" == *"$SBX_TAG"* ]] || continue
    SBX_PAD=" $SBX_LINE "
    if [[ "$SBX_PAD" == *" -j ACCEPT "* && "$SBX_PAD" == *" -i docker0 "* \
       && "$SBX_PAD" == *" --dport ${SBX_PORT} "* ]] \
       && { [[ "$SBX_PAD" == *" -d ${SBX_GATEWAY} "* ]] || [[ "$SBX_PAD" == *" -d ${SBX_GATEWAY}/32 "* ]]; }; then
      SBX_ACCEPT=1
    elif [[ "$SBX_PAD" == *" -j DROP "* ]]; then
      if [[ "$SBX_PAD" == *" -i docker0 "* && "$SBX_PAD" == *" ! -o docker0 "* ]]; then
        SBX_D0_DROP=1
      fi
      if [[ "$SBX_PAD" == *" ! -i lo "* && "$SBX_PAD" == *" -o docker0 "* ]]; then
        SBX_EXT_DROP=1
      fi
    fi
  done <<< "$SBX_LISTING"
  SBX_MISSING=""
  (( SBX_ACCEPT )) || SBX_MISSING="the webhook ACCEPT for the docker0 gateway on port ${SBX_PORT}"
  if (( ! SBX_D0_DROP )); then
    SBX_MISSING="${SBX_MISSING:+${SBX_MISSING}, }the DROP from docker0 to other Docker networks"
  fi
  if (( ! SBX_EXT_DROP )); then
    SBX_MISSING="${SBX_MISSING:+${SBX_MISSING}, }the DROP from external interfaces into docker0"
  fi
  if [[ -z "$SBX_MISSING" ]]; then
    pass "Sandbox firewall: ${SBX_CHAIN} drops keep the sandbox ports off the LAN, with the single webhook ACCEPT in place"
  else
    warn "Sandbox firewall: ${SBX_CHAIN} is missing ${SBX_MISSING}, so sandbox ports may be reachable from the LAN" \
         "Run: sudo ./scripts/sandbox-firewall.sh apply (or re-run ./install.sh); the boot unit hybrid-ai-firewall.service re-applies them on every boot."
  fi
  unset SBX_LINE SBX_PAD
fi
unset SBX_LISTING SBX_SKIP SBX_MISSING SBX_ACCEPT SBX_D0_DROP SBX_EXT_DROP

# ---------------------------------------------------------------------------
# 5b. Agent clone credentials
#
# OpenHands' app-server clones with `https://<token>@github.com/...`, and git
# stores that URL verbatim in project/<repo>/.git/config. The token is then on
# disk in plain text. Hand-stripping the URL does not hold: the next clone
# rewrites it. The agent-server pin that stops this (>= 1.37.0) has shipped
# (1.37.1-python); detection stays the control here regardless. A credential
# still on disk is now a defect, not a tolerable warning, so this check FAILS
# the deploy (exit 2 -> red). An unreadable config or a missing check is still
# only a warning -- neither proves a credential is present.
# ---------------------------------------------------------------------------
section "Agent clones"

CRED_CHECK="${APP_DIR}/scripts/check-git-remotes.sh"
CRED_ROOTS=()
# Each root is used only when it is set AND exists; either one may be absent.
OH_WS_CRED="${OPENHANDS_WORKSPACE:-$(env_get OPENHANDS_WORKSPACE)}"
if [[ -n "$OH_WS_CRED" && -d "$OH_WS_CRED" ]]; then
  CRED_ROOTS+=("$OH_WS_CRED")
fi
AR_DIR="${AGENT_REPOS_DIR:-$(env_get AGENT_REPOS_DIR)}"
if [[ -n "$AR_DIR" && -d "$AR_DIR" ]]; then
  CRED_ROOTS+=("$AR_DIR")
fi

if (( ${#CRED_ROOTS[@]} == 0 )); then
  pass "No agent clone directories found to scan"
elif [[ ! -x "$CRED_CHECK" ]]; then
  warn "Agent clone credential check is missing or not executable" \
       "Restore scripts/check-git-remotes.sh from the repository."
else
  # The check prints only `<path>: <key>` lines -- never a URL or a token --
  # so it is safe to relay them. Exit 0 clean, 1 findings, 2 unreadable.
  CRED_RC=0
  CRED_OUT="$("$CRED_CHECK" "${CRED_ROOTS[@]}" 2>/dev/null)" || CRED_RC=$?
  if (( CRED_RC == 0 )); then
    pass "No agent clone embeds a credential in a git remote"
  elif [[ -n "$CRED_OUT" ]]; then
    while IFS= read -r cline; do
      [[ -n "$cline" ]] || continue
      fail "Credential embedded in a git remote: ${cline}" \
           "Rotate that token in GitHub, then re-run ./doctor.sh. Do not hand-strip the URL: the next clone rewrites it. See docs/TROUBLESHOOTING.md for why."
    done <<<"$CRED_OUT"
  else
    warn "An agent clone git config could not be read" \
         "Check the file permissions under: ${CRED_ROOTS[*]}. See docs/TROUBLESHOOTING.md."
  fi
fi

# --- Agent repo reference-tree freshness (read-only) ------------------------
# scripts/sync-agent-repos.sh --check reads INVENTORY.md and confirms every
# listed repo is still present and on the recorded HEAD. It uses no network and
# writes nothing. Exit 0 is a pass; exit 1 (stale, or a skipped row) or exit 2
# (missing dir, HEAD mismatch, inventory unreadable) is a WARNING here, never a
# failure -- a stale reference tree must not turn a deploy red.
SYNC_CHECK="${APP_DIR}/scripts/sync-agent-repos.sh"
AR_SET="${AGENT_REPOS_DIR:-$(env_get AGENT_REPOS_DIR)}"
if [[ -z "$AR_SET" ]]; then
  : # Reference tree not configured; nothing to check.
elif [[ ! -d "$AR_SET" ]]; then
  warn "Agent repo reference tree directory is missing: ${AR_SET}" \
       "The tree is built by scripts/sync-agent-repos.sh; run it to create it."
elif [[ ! -x "$SYNC_CHECK" ]]; then
  warn "Agent repo sync check is missing or not executable" \
       "Restore scripts/sync-agent-repos.sh from the repository."
else
  SYNC_RC=0
  "$SYNC_CHECK" --check >/dev/null 2>&1 || SYNC_RC=$?
  if (( SYNC_RC == 0 )); then
    pass "Agent repo reference tree inventory is fresh and matches"
  else
    warn "Agent repo reference tree check reported a problem (exit ${SYNC_RC})" \
         "Run ./scripts/sync-agent-repos.sh to refresh the tree, then re-run ./doctor.sh. See docs/TROUBLESHOOTING.md."
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
      # A stopped pod leaves the tailnet, so no peer matches right now. That is
      # the normal on-demand state, not a fault -- but it is worth saying,
      # because a pod that was recreated under a new name looks the same.
      warn "No tailnet peer matching runpod-worker/runpod-vllm right now (the pod may be stopped or may have been recreated)" \
           "Start it: sudo ./install.sh --wake-runpod (resumes the pod and waits up to 3 minutes for it to join the tailnet), then re-run ./doctor.sh"
    fi
  else
    fail "Tailscale backend state: ${TS_STATE}" "Run: sudo tailscale up"
  fi
else
  warn "Tailscale is not installed" "Install it: curl -fsSL https://tailscale.com/install.sh | sudo sh"
fi

# ---------------------------------------------------------------------------
# 6a. /etc/resolv.conf ownership: tailscaled in direct-file mode
#
# On the Pi, tailscaled itself owns /etc/resolv.conf. That is intended, not
# damage: this host runs neither systemd-resolved nor resolvconf, so tailscaled
# falls back to writing the file directly and re-applies it on every DNS
# reconfig. Its own health line -- "System DNS config not ideal.
# /etc/resolv.conf overwritten." -- is that mode announcing itself, which is
# expected-benign here. See https://tailscale.com/s/dns-fight.
#
# This check is INFORMATIONAL: the expected state prints a note and moves no
# counter, so the exit code is unchanged. fail() is never called. The single
# warn() case is a CHANGED state: the health line is present but the file is
# not tailscaled-generated, so something else has taken ownership. Only the
# header line is read; no nameserver value and no file content is printed. A
# missing CLI, an unreachable daemon or an unreadable file skips.
#
# DOCTOR_RESOLV_CONF is an INTERNAL test seam, like
# HYBRID_AI_POST_DEPLOY_VERIFY_LOG: it names a different file to inspect so an
# offline harness can drive the check without touching the real /etc. Unset, it
# is exactly /etc/resolv.conf.
# ---------------------------------------------------------------------------
resolv_skip() { (( QUIET )) || printf '  %s-%s resolv.conf ownership check skipped (%s)\n' "$C_DIM" "$C_RST" "$1"; }
DOCTOR_RESOLV_CONF="${DOCTOR_RESOLV_CONF:-/etc/resolv.conf}"
TS_HEALTH_JSON=""
TS_HEALTH_TXT=""
TS_RESOLV_WARNING=0
RESOLV_TS_HEADER=0
if ! command -v tailscale >/dev/null 2>&1; then
  resolv_skip "tailscale CLI is not installed"
elif ! TS_HEALTH_JSON="$(tailscale status --json 2>/dev/null)"; then
  resolv_skip "tailscale status is not available (daemon unreachable)"
elif ! TS_HEALTH_TXT="$(printf '%s' "$TS_HEALTH_JSON" | jq -r '(.Health // [])[]?' 2>/dev/null)"; then
  resolv_skip "tailscale status is not readable JSON"
elif [[ ! -r "$DOCTOR_RESOLV_CONF" ]]; then
  resolv_skip "${DOCTOR_RESOLV_CONF} is not readable"
else
  if printf '%s\n' "$TS_HEALTH_TXT" | grep -Fqi 'resolv.conf overwritten'; then
    TS_RESOLV_WARNING=1
  fi
  if head -n 5 "$DOCTOR_RESOLV_CONF" 2>/dev/null | grep -Fq 'resolv.conf(5) file generated by tailscale'; then
    RESOLV_TS_HEADER=1
  fi
  if (( TS_RESOLV_WARNING )) && (( RESOLV_TS_HEADER )); then
    (( QUIET )) || printf '  %s-%s tailscaled owns %s in direct-file mode; its "System DNS config not ideal. /etc/resolv.conf overwritten." health line is expected and benign here (https://tailscale.com/s/dns-fight)\n' \
      "$C_DIM" "$C_RST" "$DOCTOR_RESOLV_CONF"
  elif (( TS_RESOLV_WARNING )); then
    warn "Tailscale reports the '/etc/resolv.conf overwritten' health line, but ${DOCTOR_RESOLV_CONF} does NOT carry the tailscaled header: something else owns the file now (the documented state has changed)" \
         "Inspect without changing DNS: ls -l ${DOCTOR_RESOLV_CONF} and tailscale status --json | jq .Health. Then read the resolv.conf ownership section of docs/TROUBLESHOOTING.md."
  fi
fi
unset TS_HEALTH_JSON TS_HEALTH_TXT TS_RESOLV_WARNING RESOLV_TS_HEADER

# ---------------------------------------------------------------------------
# 7. Backups
#
# A backup that silently stopped working is one of the most damaging failure
# modes here, precisely because nothing appears wrong until you need it.
# ---------------------------------------------------------------------------
section "Backups"

# Which units run the nightly backup? One setting decides, and the shared helper
# resolves every derived name so doctor.sh cannot disagree with install.sh or
# backup.sh. In system mode the two-unit privilege split installs SYSTEM units
# (capture + upload) and stores credentials in the root-owned credstore; in user
# mode the per-user unit is used, exactly as before.
BACKUP_MODE="$HYBRID_AI_BACKUP_MODE"
BACKUP_TIMER_UNIT="$HYBRID_AI_BACKUP_TIMER_UNIT"
BACKUP_SERVICE_NAME="$HYBRID_AI_BACKUP_SERVICE_UNIT"
TIMER_SYSTEMCTL=(systemctl "$HYBRID_AI_BACKUP_SYSTEMCTL_SCOPE")
JOURNAL_SCOPE="$HYBRID_AI_BACKUP_JOURNAL_SCOPE"
BACKUP_CONF="$HYBRID_AI_BACKUP_CRED_DIR"
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
    if "${TIMER_SYSTEMCTL[@]}" is-active "$BACKUP_TIMER_UNIT" >/dev/null 2>&1; then
      NEXT="$("${TIMER_SYSTEMCTL[@]}" list-timers "$BACKUP_TIMER_UNIT" --no-pager 2>/dev/null | awk 'NR==2 {print $1, $2}')"
      pass "Nightly backup timer active${NEXT:+ (next: ${NEXT})}"
    else
      fail "Backup timer is not active" \
           "Enable it: ${TIMER_SYSTEMCTL[*]} enable --now ${BACKUP_TIMER_UNIT}"
    fi

    # In user mode, without linger, user timers do not run when you are logged
    # out -- which means the nightly backup silently never happens. System mode
    # units run regardless of login, so this check applies to user mode only.
    if [[ "$BACKUP_MODE" != "system" ]] && command -v loginctl >/dev/null 2>&1; then
      if loginctl show-user "$USER" 2>/dev/null | grep -q 'Linger=yes'; then
        pass "Linger enabled (backups run while logged out)"
      else
        fail "Linger is NOT enabled - backups will not run when you log out" \
             "Fix: sudo loginctl enable-linger $USER"
      fi
    fi
  fi

  # --- How old is the last successful backup? -------------------------------
  if [[ -f "$BACKUP_LOG" ]]; then
    LAST="$(grep 'event=backup_success' "$BACKUP_LOG" 2>/dev/null | tail -1 | grep -o 'ts=[^ ]*' | cut -d= -f2)"
    if [[ -n "$LAST" ]]; then
      LAST_EPOCH="$(date -d "$LAST" +%s 2>/dev/null || echo 0)"
      if (( LAST_EPOCH > 0 )); then
        AGE_H=$(( ( $(date +%s) - LAST_EPOCH ) / 3600 ))
        if (( AGE_H <= 36 )); then
          pass "Last successful backup ${AGE_H}h ago"
        elif (( AGE_H <= 168 )); then
          warn "Last successful backup was ${AGE_H}h ago" \
               "Expected nightly. Check: journalctl ${JOURNAL_SCOPE} -u ${BACKUP_SERVICE_NAME} -n 50"
        else
          fail "Last successful backup was ${AGE_H}h ago (over a week)" \
               "Backups are not running. Run ./backup/backup.sh manually to see the error."
        fi
      fi
    else
      warn "No successful backup recorded yet" "Run one now: ./backup/backup.sh"
    fi

    # Count failures and incomplete runs SINCE THE LAST successful backup.
    # Counting the whole file made these numbers only ever grow, even after a
    # clean run; a success must reset them. Severity stays warn.
    SINCE_LAST="$(awk '/event=backup_success/{buf=""} {buf=buf $0 "\n"} END{printf "%s", buf}' "$BACKUP_LOG" 2>/dev/null || true)"
    RECENT_FAIL="$(printf '%s' "$SINCE_LAST" | grep -c 'event=backup_failed\|event=check_failed' 2>/dev/null || true)"
    RECENT_INCOMPLETE="$(printf '%s' "$SINCE_LAST" | grep -c 'event=backup_incomplete' 2>/dev/null || true)"
    RECENT_FAIL="${RECENT_FAIL:-0}"
    RECENT_INCOMPLETE="${RECENT_INCOMPLETE:-0}"
    if (( RECENT_FAIL > 0 )); then
      warn "${RECENT_FAIL} backup failure(s) since the last successful backup" \
           "Review: grep 'event=backup_failed' \"\$BACKUP_LOG\" | tail -5"
    fi
    if (( RECENT_INCOMPLETE > 0 )); then
      warn "${RECENT_INCOMPLETE} incomplete backup run(s) since the last successful backup" \
           "An incomplete run missed durable state. Review: grep 'event=backup_incomplete' \"\$BACKUP_LOG\" | tail -5"
    fi
  fi

  if (( ! NO_CLOUD )); then
    # RESTIC_PASSWORD_FILE is resolved here with backup.sh's precedence (a
    # CREDENTIALS_DIRECTORY from systemd wins, else ${BACKUP_CONF}) so all three
    # backup scripts share one canonical order. doctor.sh is a manual read-only
    # tool, never a systemd unit, so the CREDENTIALS_DIRECTORY branch is
    # defensive only: the ${BACKUP_CONF} fallback is what actually runs.
    # shellcheck disable=SC2016
    PW_FILE="$(
      timeout 30 bash -c '
        set -a; while IFS= read -r l; do
          [[ "$l" =~ ^[[:space:]]*[#] ]] && continue
          [[ "$l" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] && printf -v "${BASH_REMATCH[1]}" "%s" "${BASH_REMATCH[2]}" && export "${BASH_REMATCH[1]}"
        done < "$1"; set +a
        if [[ -n "${CREDENTIALS_DIRECTORY:-}" ]]; then
          RESTIC_PW_FILE="${CREDENTIALS_DIRECTORY}/repo-password"
        else
          RESTIC_PW_FILE="$2/repo-password"
        fi
        [[ -r "$RESTIC_PW_FILE" ]] || { printf "%s" "$RESTIC_PW_FILE"; exit 3; }
        export RESTIC_PASSWORD_FILE="$RESTIC_PW_FILE"
        restic snapshots --last >/dev/null 2>&1' _ "${BACKUP_CONF}/r2.env" "${BACKUP_CONF}"
    )"
    PROBE_RC=$?
    if (( PROBE_RC == 0 )); then
      pass "Backup repository reachable"
    elif (( PROBE_RC == 3 )); then
      warn "Backup repository password file is missing or unreadable: ${PW_FILE}" \
           "Fix: check ${BACKUP_CONF}/repo-password permissions"
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

for d in "$HYBRID_AI_WEBUI_DATA_DIR" "$HYBRID_AI_OLLAMA_DATA_DIR"; do
  if [[ -d "$d" ]]; then
    SZ="$(du -sh "$d" 2>/dev/null | cut -f1)"
    pass "$(basename "$d") present (${SZ})"
  else
    warn "$(basename "$d") does not exist ($d)" "It will be created on the next ./install.sh run."
  fi
done

if [[ -d "$HYBRID_AI_WEBUI_DATA_DIR" ]] && command -v sqlite3 >/dev/null 2>&1; then
  DB="$HYBRID_AI_WEBUI_DATA_DIR/webui.db"
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
LEFTOVER="$(find "$HYBRID_AI_DATA_DIR" "$HYBRID_AI_WORK_DIR" -maxdepth 1 \( -name 'webui_data.pre-restore-*' -o -name 'hermes_data.pre-restore-*' -o -name '.restore-test-*' \) 2>/dev/null | wc -l | tr -d ' ')"
if [[ "${LEFTOVER:-0}" -gt 0 ]]; then
  warn "${LEFTOVER} leftover restore director(ies) taking up space" \
       "Remove when you are confident: rm -rf \"${HYBRID_AI_DATA_DIR}\"/*.pre-restore-* \"${HYBRID_AI_WORK_DIR}\"/*.restore-test-*"
fi

# ---------------------------------------------------------------------------
# Conversation disk growth (WARNING-ONLY)
#
# Every conversation leaves its own directory under the conversations root, so
# an old install can quietly grow past what the disk can hold. A doctor run is
# a health report, not a cleanup, so this check only reports the measured size
# and count and suggests the prune sweep: it never calls fail() and therefore
# adds no path to exit 2.
#
# THE SKIP PATH EXISTS because the root lives on the host deployment: it may be
# absent on a fresh clone, unreadable for a non-root run, or meaningless on a
# non-Linux host. Those cases print one dim "skipped" line and leave the exit
# code exactly as it would have been -- nothing below can leave a non-zero
# status behind.
#
# Read-only: find, du, wc and tr only -- no mkdir, no chmod, no writes. Symlinks
# at depth 1 are neither counted as directories nor followed.
# ---------------------------------------------------------------------------
CONV_SKIP=""
CONV_ROOT=""
if [[ "$(uname -s 2>/dev/null)" != "Linux" ]]; then
  CONV_SKIP="not a Linux host"
else
  OH_WS_CRED="${OPENHANDS_WORKSPACE:-$(env_get OPENHANDS_WORKSPACE)}"
  CONV_ROOT="${OH_WS_CRED}/conversations"
  if [[ -z "$OH_WS_CRED" ]]; then
    CONV_SKIP="OPENHANDS_WORKSPACE not set"
  elif [[ ! -d "$CONV_ROOT" ]]; then
    CONV_SKIP="conversations root not present"
  elif [[ ! -r "$CONV_ROOT" || ! -x "$CONV_ROOT" ]]; then
    CONV_SKIP="conversations root not readable"
  fi
fi

if [[ -n "$CONV_SKIP" ]]; then
  (( QUIET )) || printf '  %s-%s conversation growth check skipped (%s)\n' "$C_DIM" "$C_RST" "$CONV_SKIP"
else
  CONV_DIRS="$(find "$CONV_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
  CONV_DIRS="${CONV_DIRS:-0}"
  CONV_KIB="$(du -sk "$CONV_ROOT" 2>/dev/null | cut -f1)"
  CONV_KIB="${CONV_KIB:-0}"
  # Render KiB as a human-readable unit without adding a dependency.
  CONV_HUMAN="$(awk -v k="$CONV_KIB" 'BEGIN {
    split("KiB MiB GiB TiB", u, " "); i = 1
    while (k >= 1024 && i < 4) { k /= 1024; i++ }
    printf (i == 1 ? "%d %s" : "%.1f %s"), k, u[i]
    exit
  }' </dev/null)"
  if (( CONV_KIB > 1024 * 1024 || CONV_DIRS > 10 )); then
    warn "conversations root holds ${CONV_DIRS} director(ies), ${CONV_HUMAN} (${CONV_ROOT})" \
         "Consider the conversation prune sweep or the quarantine path to reclaim space."
  else
    pass "conversations root is ${CONV_HUMAN} across ${CONV_DIRS} director(ies)"
  fi
fi

# ---------------------------------------------------------------------------
# Lease-less conversation directories (WARNING ONLY)
#
# A conversation directory with no owner_lease.json is refused by
# scripts/prune-conversations.sh forever: the fail-safe keeps an absent lease,
# so the sweep reports success while moving nothing and the directory is
# invisible to the app as well. That state is silent on a healthy-looking host,
# so surface it with a count.
#
# Read-only: find with a per-entry test, no writes. Depth 1 only, symlinks are
# neither counted nor followed. Same skip discipline as the growth check above:
# a non-Linux host, an unset workspace or an absent/unreadable root prints one
# dim "skipped" line and leaves the exit code exactly as it was.
#
# WARNING-ONLY BY DESIGN: an owner may prefer to keep those directories, so this
# never calls fail() and adds no path to exit 2.
# ---------------------------------------------------------------------------
LL_SKIP="$CONV_SKIP"
if [[ -z "$LL_SKIP" && ! -d "$CONV_ROOT" ]]; then
  LL_SKIP="conversations root not present"
fi

if [[ -n "$LL_SKIP" ]]; then
  (( QUIET )) || printf '  %s-%s lease-less conversation check skipped (%s)\n' "$C_DIM" "$C_RST" "$LL_SKIP"
else
  LEASELESS=0
  while IFS= read -r -d '' _ll_entry; do
    [[ -L "$_ll_entry" ]] && continue
    [[ -d "$_ll_entry" ]] || continue
    [[ -e "$_ll_entry/owner_lease.json" ]] && continue
    LEASELESS=$(( LEASELESS + 1 ))
  done < <(find "$CONV_ROOT" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
  unset _ll_entry
  if (( LEASELESS > 0 )); then
    warn "${LEASELESS} conversation director(ies) have no owner_lease.json (${CONV_ROOT}): the prune sweep refuses them forever, so it moves nothing" \
         "These are invisible to the app. Sweep the ones past the age limit with: sudo systemctl start hybrid-ai-prune (or sudo ${HYBRID_AI_APP_DIR:-/opt/hybrid-ai}/scripts/prune-conversations.sh) after setting HYBRID_AI_PRUNE_ALLOW_LEASE_LESS=1 in .env and re-running ./install.sh. Leave it unset to keep the fail-safe."
  else
    pass "every conversation directory carries an owner lease"
  fi
  unset LEASELESS
fi
unset LL_SKIP

# ---------------------------------------------------------------------------
# Post-deploy verification log (WARNING ONLY)
# ---------------------------------------------------------------------------
# scripts/deploy-remote.sh starts scripts/run-post-deploy-verify.sh in a
# transient unit after every deploy. Each run appends a header line
# `waiting for <sha> at <ts>`, then exactly one verdict: `PASS`, `FAIL: <detail>`
# or `TIMEOUT: <detail>`. The log is appended across deploys, so the LAST
# `waiting for` line names the run of interest and the first verdict line after
# it is that run's outcome. The log is read as data, never as code.
#
# The check reads that verdict. It does NOT compare the log's mtime with a
# commit time: doctor.sh runs before the current deploy's verifier can have
# written, so an mtime comparison warned on every deploy by construction. A
# verdict from an earlier deploy is surfaced here, in this deploy's output.
#
#   absent                        -> skip note, exit unchanged
#   unreadable / git probe fails  -> skip note, exit unchanged
#   exists, 0 bytes               -> warn: the verifier never wrote anything
#   no parseable waiting line     -> warn
#   verdict PASS                  -> pass, naming the short sha and timestamp
#   verdict FAIL / TIMEOUT        -> warn, quoting the verdict and short sha
#   no verdict, wait > 65 minutes -> warn: the run was abandoned
#   no verdict, wait within 65 min-> skip note (still running)
#   unparseable wait timestamp    -> skip note, exit unchanged
#
# This is a smoke detector, never a gate: it calls warn()/pass() only, so the
# worst it can do is raise the exit code to 1, never 2.
# ---------------------------------------------------------------------------
PDV_LOG="$HYBRID_AI_POST_DEPLOY_VERIFY_LOG"
PDV_SKIP=""
PDV_SEEN_WAITING=0
PDV_WAITING_SHA=""
PDV_WAITING_TS=""
PDV_VERDICT=""
PDV_WAIT_EPOCH=""
PDV_NOW=""
PDV_SHA12=""
PDV_LINE=""
if [[ ! -e "$PDV_LOG" ]]; then
  PDV_SKIP="log not present (${PDV_LOG})"
elif [[ ! -r "$PDV_LOG" ]]; then
  PDV_SKIP="log not readable (${PDV_LOG})"
elif ! git -C "$APP_DIR" show -s --format=%ct HEAD >/dev/null 2>&1; then
  PDV_SKIP="deployed tree not readable with git (${APP_DIR})"
elif [[ -s "$PDV_LOG" ]]; then
  while IFS= read -r PDV_LINE || [[ -n "$PDV_LINE" ]]; do
    if [[ "$PDV_LINE" =~ ^waiting\ for\ ([0-9a-fA-F]{40})\ at\ (.+)$ ]]; then
      PDV_WAITING_SHA="${BASH_REMATCH[1]}"
      PDV_WAITING_TS="${BASH_REMATCH[2]}"
      PDV_VERDICT=""
      PDV_SEEN_WAITING=1
    elif (( PDV_SEEN_WAITING )) && [[ -z "$PDV_VERDICT" ]]; then
      case "$PDV_LINE" in
        PASS|FAIL:*|TIMEOUT:*) PDV_VERDICT="${PDV_LINE//[[:cntrl:]]/}" ;;
      esac
    fi
  done < "$PDV_LOG"
fi

if [[ -n "$PDV_SKIP" ]]; then
  (( QUIET )) || printf '  %s-%s post-deploy verification log skipped (%s)\n' "$C_DIM" "$C_RST" "$PDV_SKIP"
elif [[ ! -s "$PDV_LOG" ]]; then
  warn "post-deploy verification log ${PDV_LOG} is empty: the post-deploy verifier never wrote anything" \
       "Either the verifier is not installed (check ${HYBRID_AI_POST_DEPLOY_VERIFY_CMD}) or it was killed before it wrote. Inspect it with: journalctl -u 'hybrid-ai-post-deploy-verify-*'"
elif (( ! PDV_SEEN_WAITING )); then
  warn "post-deploy verification log ${PDV_LOG} has no parseable 'waiting for <sha> at <ts>' line" \
       "Inspect the run with: journalctl -u 'hybrid-ai-post-deploy-verify-*'"
else
  PDV_SHA12="${PDV_WAITING_SHA:0:12}"
  if [[ -n "$PDV_VERDICT" ]]; then
    if [[ "$PDV_VERDICT" == "PASS" ]]; then
      pass "post-deploy verification passed for ${PDV_SHA12} (verdict written ${PDV_WAITING_TS})"
    else
      warn "post-deploy verification reported '${PDV_VERDICT}' for ${PDV_SHA12}" \
           "Inspect the run with: journalctl -u 'hybrid-ai-post-deploy-verify-*'"
    fi
  else
    PDV_WAIT_EPOCH="$(date -u -d "$PDV_WAITING_TS" +%s 2>/dev/null)"
    PDV_NOW="$(date -u +%s)"
    if [[ ! "$PDV_WAIT_EPOCH" =~ ^[0-9]+$ ]]; then
      (( QUIET )) || printf "  %s-%s post-deploy verification log skipped (unparseable verification timestamp '%s')\n" \
        "$C_DIM" "$C_RST" "${PDV_WAITING_TS//[[:cntrl:]]/}"
    elif (( PDV_WAIT_EPOCH + 3900 < PDV_NOW )); then
      warn "post-deploy verification for ${PDV_SHA12} has no verdict and its wait started at ${PDV_WAITING_TS}, more than 65 minutes ago" \
           "Inspect the run with: journalctl -u 'hybrid-ai-post-deploy-verify-*'"
    else
      (( QUIET )) || printf '  %s-%s post-deploy verification log skipped (verification for %s still running since %s)\n' \
        "$C_DIM" "$C_RST" "$PDV_SHA12" "${PDV_WAITING_TS//[[:cntrl:]]/}"
    fi
  fi
fi
unset PDV_LOG PDV_SKIP PDV_SEEN_WAITING PDV_WAITING_SHA PDV_WAITING_TS PDV_VERDICT \
      PDV_WAIT_EPOCH PDV_NOW PDV_SHA12 PDV_LINE

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
