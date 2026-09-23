#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: runpod/start.sh
# PURPOSE (plain English):
#   This script runs on the rented cloud GPU machine, not on your Pi. It is the
#   first thing that executes when the pod powers on, and it does three jobs:
#
#     1. Joins your private Tailscale network, so the Pi can reach it without
#        anything being exposed to the public internet.
#     2. Starts a "watchdog" that notices when the GPU has been doing nothing
#        for 15 minutes and shuts the pod down automatically. This is what
#        keeps your bill small -- you pay for minutes used, not hours idle.
#     3. Starts vLLM, the high-performance server that runs the big AI model
#        and answers requests from your Pi.
#
# WHERE TO PUT IT:
#   Set this as the pod's container start command in RunPod, or bake it into a
#   custom image at /start.sh and set that as the entrypoint. See the README in
#   this folder for the exact steps.
#
# ENVIRONMENT VARIABLES IT NEEDS (set these in the RunPod pod template):
#   REQUIRED:
#     TAILSCALE_AUTH_KEY   An ephemeral, pre-authorised, reusable auth key.
#     RUNPOD_API_KEY       Only used so the pod can shut ITSELF down.
#     RUNPOD_POD_ID        RunPod injects this automatically. Do not set it.
#   OPTIONAL (sensible defaults shown):
#     VLLM_MODEL       Qwen/Qwen2.5-Coder-32B-Instruct-AWQ
#     VLLM_PORT        8000
#     IDLE_MINUTES     15
#     MAX_MODEL_LEN    16384
#     GPU_MEM_UTIL     0.92
#     TS_HOSTNAME      runpod-worker   <-- must match PEER_HOSTNAMES in install.sh
#
# PRIVACY POSTURE:
#   - vLLM's request and statistics logging are switched off. Your prompt text
#     is never written to disk or printed to the console on this machine.
#   - The model API is only reachable over the encrypted Tailscale network.
#     RunPod's public proxy URL is never pointed at it.
#   - The Tailscale auth key is wiped from memory once the pod has joined.
# ---------------------------------------------------------------------------
set -Eeuo pipefail

# The ":-" syntax means "use this default if the variable is not already set".
VLLM_MODEL="${VLLM_MODEL:-Qwen/Qwen2.5-Coder-32B-Instruct-AWQ}"
VLLM_PORT="${VLLM_PORT:-8000}"
IDLE_MINUTES="${IDLE_MINUTES:-15}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-16384}"
GPU_MEM_UTIL="${GPU_MEM_UTIL:-0.92}"
# Role-based, not software-based: a second pod would also run vLLM, so
# "vllm" would stop distinguishing anything. install.sh still discovers
# the legacy "runpod-vllm" name, so an existing pod keeps working until
# you restart it.
TS_HOSTNAME="${TS_HOSTNAME:-runpod-worker}"
RUNTIME_ENV="/etc/runtime.env"
TS_SOCK="/var/run/tailscale/tailscaled.sock"
TS_STATE="/var/lib/tailscale/tailscaled.state"

# ---------------------------------------------------------------------------
# MAIN_PID -- the process id of THIS script, captured at the top level.
#
# WHY THIS EXISTS: the idle watchdog runs inside a background subshell. If the
# watchdog ever needs to shut the whole pod down, it must signal the *parent*
# script, not itself. Bash does not update $$ inside a subshell (that is what
# $BASHPID is for), so $$ would technically work -- but relying on that subtle
# behaviour is exactly the kind of thing that breaks silently during a later
# refactor. Capturing it explicitly, once, makes the intent unmistakable.
# ---------------------------------------------------------------------------
MAIN_PID=$$

log()  { printf '[start.sh %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die()  {
  # Record the failure as a structured event before exiting, so a crashed
  # cold start is greppable rather than just a line of prose in the console.
  event "fatal_error" "detail=$(printf '%s' "$*" | tr -d '\n' | cut -c1-160)" 2>/dev/null || true
  printf '[start.sh FATAL] %s\n' "$*" >&2
  exit 1
}
trap 'die "aborted at line ${LINENO}: ${BASH_COMMAND}"' ERR

# ---------------------------------------------------------------------------
# STRUCTURED EVENT LOG
#   Every significant success or failure is recorded here in a consistent
#   key=value format, so you can grep the pod log for what actually happened
#   instead of reading prose.
#
#   Format:  EVENT ts=<iso8601> event=<name> [key=value ...]
#
#   PRIVACY: events carry METADATA ONLY -- timings, counts, states, exit codes.
#   Never add prompt or response text to an event. That rule is what keeps the
#   zero-trace guarantee true; a single well-meaning debug line would break it.
# ---------------------------------------------------------------------------
EVENT_LOG="${EVENT_LOG:-/var/log/hybrid-ai-events.log}"

event() {
  local name="$1"; shift
  local line
  line="EVENT ts=$(date -u +%Y-%m-%dT%H:%M:%SZ) event=${name} $*"
  # stdout so it appears in the RunPod console, and a file for later grepping.
  printf '%s\n' "$line"
  printf '%s\n' "$line" >> "$EVENT_LOG" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# stop_pod <reason>
#   Ask RunPod to stop this pod, with retries.
#
#   AVAILABILITY: a single API call is not good enough here. If it fails --
#   transient network error, rate limit, brief API outage -- and we gave up,
#   the pod would keep billing indefinitely. We retry with exponential backoff.
#
# ===========================================================================
# CRITICAL FIX (see the long note below) -- READ BEFORE EDITING THIS FUNCTION
# ===========================================================================
#   The previous version of this function ended its failure path with:
#
#       pkill -TERM -f 'vllm...'
#       return 1
#
#   That looked reasonable and was badly wrong, in a way that costs money:
#
#     1. The watchdog runs in a background subshell. After stop_pod returned,
#        the subshell called `exit 0` -- so THE WATCHDOG WAS NOW DEAD.
#     2. The parent script was blocked in `wait` on the vLLM process. pkill
#        had just killed it, so `wait` returned non-zero.
#     3. The parent had no idea this was a deliberate shutdown (SHUTTING_DOWN
#        is only set by cleanup(), which had not run), so it treated the exit
#        as a crash.
#     4. The supervisor loop therefore RESTARTED vLLM.
#
#   Net effect: the pod came back up, served happily, and had no idle monitor
#   watching it any more. It would bill continuously until you noticed by hand
#   -- which is the single most expensive failure this project can have.
#
#   THE FIX: signal the parent script directly. That fires the parent's TERM
#   trap, which sets SHUTTING_DOWN=1, kills vLLM, logs out of the tailnet, and
#   lets the supervisor loop exit cleanly instead of "recovering".
# ===========================================================================
# ---------------------------------------------------------------------------
stop_pod() {
  local reason="${1:-unspecified}"
  local attempt delay resp http_ok

  for attempt in 1 2 3 4; do
    # SECURITY: the key goes in an Authorization header supplied via --config
    # (read from a file descriptor), never on the command line and never in
    # the URL. Command-line arguments are world-readable in /proc/<pid>/cmdline;
    # URLs end up in proxy and access logs.
    resp="$(curl -sS --max-time 30 \
      --config <(printf 'header = "Authorization: Bearer %s"\n' "${RUNPOD_API_KEY}") \
      -X POST "https://api.runpod.io/graphql" \
      -H 'Content-Type: application/json' \
      --data @<(jq -n --arg id "${RUNPOD_POD_ID}" '{
          query: "mutation stop($input: PodStopInput!) { podStop(input: $input) { id desiredStatus } }",
          variables: { input: { podId: $id } }
        }') 2>&1)" || resp=""

    # Success means we got a data.podStop object back and no errors key.
    http_ok="$(printf '%s' "$resp" | jq -r '
        if (.errors // empty) then "err"
        elif (.data.podStop.id // empty) then "ok"
        else "unknown" end' 2>/dev/null || echo "unknown")"

    if [[ "$http_ok" == "ok" ]]; then
      event "podstop_success" "reason=${reason}" "attempt=${attempt}" \
            "desired_status=$(printf '%s' "$resp" | jq -r '.data.podStop.desiredStatus // "?"' 2>/dev/null)"
      return 0
    fi

    # Log the failure WITHOUT echoing the raw body, which can contain headers.
    event "podstop_failure" "reason=${reason}" "attempt=${attempt}" \
          "result=${http_ok}" \
          "detail=$(printf '%s' "$resp" | jq -rc '.errors[0].message // "no_response"' 2>/dev/null | tr -d '\n' | cut -c1-120)"

    if (( attempt < 4 )); then
      delay=$(( attempt * attempt * 5 ))   # 5s, 20s, 45s
      sleep "$delay"
    fi
  done

  # -------------------------------------------------------------------------
  # All retries exhausted. RunPod's API is unreachable, so we cannot stop the
  # pod remotely. Make the local side as harmless and as loud as possible.
  #
  # ORDER MATTERS HERE:
  #   Signal the parent FIRST. Its TERM trap sets SHUTTING_DOWN=1 before the
  #   supervisor loop can observe vLLM dying, which is what prevents the
  #   restart. Killing vLLM first would race the signal and could still let
  #   one restart slip through.
  # -------------------------------------------------------------------------
  event "podstop_exhausted" "reason=${reason}" "severity=critical" \
        "action=terminating_pod_locally" \
        "note=RUNPOD_API_UNREACHABLE_VERIFY_POD_IS_STOPPED_IN_THE_CONSOLE"

  log "CRITICAL: could not reach RunPod's API to stop this pod."
  log "CRITICAL: shutting everything down locally so the GPU goes idle."
  log "CRITICAL: VERIFY IN THE RUNPOD CONSOLE that this pod is actually stopped."

  # Ask the parent to shut down cleanly. This triggers cleanup() via the TERM
  # trap, which stops vLLM, tears down Tailscale, and ends the supervisor loop.
  kill -TERM "$MAIN_PID" 2>/dev/null || true

  # Backstop: if the parent somehow did not respond to the signal, kill the
  # inference server directly so the GPU at least stops doing work.
  sleep 10
  pkill -TERM -f 'vllm.entrypoints.openai.api_server' 2>/dev/null || true
  return 1
}

log "=============================================================="
log " hybrid-ai cloud inference plane :: cold start"
log "=============================================================="

# ---------------------------------------------------------------------------
# STEP 0. Install missing tools
# On a properly built custom image this does nothing. On a stock RunPod image
# it installs Tailscale on first boot, which adds a minute or two.
# ---------------------------------------------------------------------------
if ! command -v tailscaled >/dev/null 2>&1; then
  log "tailscaled absent -- installing."
  export DEBIAN_FRONTEND=noninteractive   # stop apt asking interactive questions
  apt-get update -qq
  apt-get install -y -qq curl ca-certificates iproute2 jq >/dev/null
  curl -fsSL https://tailscale.com/install.sh | sh >/dev/null
fi
command -v jq   >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq jq >/dev/null; }
command -v curl >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq curl >/dev/null; }

# ---------------------------------------------------------------------------
# STEP 1. Join the private network
#
# WHY "userspace-networking": normally Tailscale creates a virtual network
# adapter using a kernel feature called TUN. Cloud containers like RunPod's do
# not grant access to that. Userspace mode does the same job entirely in
# software instead. Slightly slower, but it works without special privileges.
# ---------------------------------------------------------------------------
[[ -n "${TAILSCALE_AUTH_KEY:-}" ]] || die "TAILSCALE_AUTH_KEY is not set. Cannot join the mesh."

mkdir -p /var/run/tailscale /var/lib/tailscale

log "Starting tailscaled (userspace-networking)..."
# The trailing "&" runs this in the background so the script can continue.
tailscaled \
  --tun=userspace-networking \
  --state="${TS_STATE}" \
  --socket="${TS_SOCK}" \
  --socks5-server=localhost:1055 \
  --outbound-http-proxy-listen=localhost:1055 \
  >/var/log/tailscaled.log 2>&1 &
TAILSCALED_PID=$!      # $! = process ID of the command we just backgrounded

# Wait for the control socket to appear rather than guessing with "sleep 10".
for _ in $(seq 1 30); do
  [[ -S "${TS_SOCK}" ]] && break
  kill -0 "$TAILSCALED_PID" 2>/dev/null || die "tailscaled died during startup. See /var/log/tailscaled.log"
  sleep 1
done
[[ -S "${TS_SOCK}" ]] || die "tailscaled socket never appeared."

log "Authenticating to tailnet as '${TS_HOSTNAME}'..."

# SECURITY: passing --authkey=<value> directly would put the key in
# /proc/<pid>/cmdline, which every process on this pod can read. Tailscale
# supports a "file:" prefix to read the key from disk instead. We write it to
# a 0600 file, use it, then shred it.
AUTHKEY_FILE="$(mktemp /run/.tskey.XXXXXX)"
chmod 600 "$AUTHKEY_FILE"
printf '%s' "${TAILSCALE_AUTH_KEY}" > "$AUTHKEY_FILE"

# --accept-routes is deliberately NOT set. This pod has no need to receive
# subnet routes advertised by other nodes, and accepting them would widen the
# network surface reachable from a compromised pod.
tailscale --socket="${TS_SOCK}" up \
  --auth-key="file:${AUTHKEY_FILE}" \
  --hostname="${TS_HOSTNAME}" \
  --accept-dns=false

# Overwrite then remove. shred guards against the value lingering on disk.
shred -u "$AUTHKEY_FILE" 2>/dev/null || rm -f "$AUTHKEY_FILE"

# Wipe the key from this process's environment too. Tailscale has persisted
# what it needs into its state file, so nothing further requires it in memory.
unset TAILSCALE_AUTH_KEY
export TAILSCALE_AUTH_KEY=""

TAILSCALE_IP=""
for _ in $(seq 1 30); do
  TAILSCALE_IP="$(tailscale --socket="${TS_SOCK}" ip -4 2>/dev/null | head -n1 || true)"
  [[ -n "$TAILSCALE_IP" ]] && break
  sleep 1
done
[[ -n "$TAILSCALE_IP" ]] || die "Failed to obtain a Tailscale IPv4 address."
log "Mesh address acquired: ${TAILSCALE_IP}"
event "tailnet_joined" "hostname=${TS_HOSTNAME}" "mode=userspace"

# ---------------------------------------------------------------------------
# STEP 2. Runtime State Capture (RSC)
#
# WHAT THIS MEANS: the pod gets a different network address and possibly a
# different number of GPUs every time it starts. Rather than have each part of
# the system look these up separately (and risk them disagreeing), we detect
# them ONCE here and write them to a single file. Anything that needs them
# reads that file. One source of truth.
# ---------------------------------------------------------------------------
log "Capturing runtime state -> ${RUNTIME_ENV}"

if command -v nvidia-smi >/dev/null 2>&1; then
  # nvidia-smi is NVIDIA's command-line tool for querying the GPU.
  GPU_COUNT="$(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | wc -l | tr -d ' ')"
  GPU_NAME="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1)"
  GPU_MEM_TOTAL="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -n1)"
else
  GPU_COUNT=0; GPU_NAME="none"; GPU_MEM_TOTAL=0
fi
[[ "${GPU_COUNT:-0}" -ge 1 ]] || die "No CUDA devices visible. Refusing to start vLLM."

umask 077   # any file created from here on is readable only by this user
cat > "${RUNTIME_ENV}" <<EOF
# Runtime State Capture -- written by start.sh at $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Source of truth for this pod instance. Do not edit by hand.
TAILSCALE_IP=${TAILSCALE_IP}
TS_HOSTNAME=${TS_HOSTNAME}
TS_SOCK=${TS_SOCK}
GPU_COUNT=${GPU_COUNT}
GPU_NAME=${GPU_NAME}
GPU_MEM_TOTAL_MB=${GPU_MEM_TOTAL}
RUNPOD_POD_ID=${RUNPOD_POD_ID:-unknown}
VLLM_MODEL=${VLLM_MODEL}
VLLM_PORT=${VLLM_PORT}
IDLE_MINUTES=${IDLE_MINUTES}
BOOT_TS=$(date -u +%s)
EOF
chmod 600 "${RUNTIME_ENV}"

log "GPU: ${GPU_COUNT}x ${GPU_NAME} (${GPU_MEM_TOTAL} MiB each)"
log "Pod: ${RUNPOD_POD_ID:-unknown}"
event "runtime_state_captured" "gpu_count=${GPU_COUNT}" "gpu_mem_mb=${GPU_MEM_TOTAL}" "pod=${RUNPOD_POD_ID:-unknown}"

# ---------------------------------------------------------------------------
# STEP 3. Idle watchdog -- the thing that saves you money
#
# HOW IT WORKS: it samples GPU utilisation every 5 seconds and keeps the
# highest reading seen over each 60-second window. If a whole window is idle,
# an idle counter goes up. ANY activity resets it to zero. After IDLE_MINUTES
# consecutive idle windows it asks RunPod to stop this pod, and billing ends.
#
# WHY 5-SECOND SAMPLING RATHER THAN ONE SAMPLE A MINUTE:
#   A short request can start and finish entirely in the gap between two
#   samples. Sampling once a minute would miss it completely and count the
#   window as idle. Several short requests in a row could then shut the pod
#   down while you were actively using it. Taking the peak of twelve samples
#   makes that far less likely.
#
# THE COUNTER RESET is what protects long generations: a ten-minute answer
# keeps the GPU busy throughout, so the idle count never accumulates.
#
# THE 5-MINUTE GRACE PERIOD: loading a 32B model takes several minutes, and
# during that time the GPU genuinely reads 0% because it is waiting on disk.
# Without it the watchdog would stop a pod that had not finished starting.
#
# AVAILABILITY NOTE: everything in the subshell below is written so that no
# single failure can kill the watchdog. A dead watchdog is the worst outcome
# here -- the pod would bill indefinitely with nobody watching.
# ---------------------------------------------------------------------------
if [[ -n "${RUNPOD_API_KEY:-}" && -n "${RUNPOD_POD_ID:-}" ]]; then
  log "Arming idle watchdog: ${IDLE_MINUTES} min @ 0% GPU -> podStop"
  event "watchdog_armed" "idle_minutes=${IDLE_MINUTES}" "sample_interval=5s"

  (
    # AVAILABILITY: disable the strict-mode ERR trap and errexit INSIDE this
    # subshell. Inherited from the parent (set -E), a single transient failure
    # -- one flaky nvidia-smi call -- would otherwise fire `die` and terminate
    # the watchdog silently, leaving the pod billing forever with no monitor.
    # We handle every error explicitly below instead.
    trap - ERR
    set +eE

    idle_count=0
    unknown_streak=0

    sleep 300   # grace period while model weights load
    event "watchdog_active" "grace_period_elapsed=300s"

    while true; do
      # --- Sample for 60 seconds, keeping the peak utilisation -------------
      window_peak=-1        # -1 means "no successful reading this window"
      for _ in $(seq 1 12); do
        sleep 5
        raw="$(nvidia-smi --query-gpu=utilization.gpu \
                 --format=csv,noheader,nounits 2>/dev/null)" || raw=""
        if [[ -n "$raw" ]]; then
          # Keep the busiest GPU. On a multi-GPU pod, one busy card means busy.
          sample="$(printf '%s\n' "$raw" \
                    | awk 'BEGIN{m=0} /^[0-9]+$/ {if ($1+0 > m) m=$1+0} END{print m+0}')"
          [[ -n "$sample" ]] && (( sample > window_peak )) && window_peak=$sample
        fi
      done

      # --- Handle an unreadable GPU ----------------------------------------
      # CORRECTNESS: a failed nvidia-smi is NOT the same as 0% utilisation.
      # Treating "unknown" as "idle" would let a driver hiccup shut down a pod
      # that was working perfectly. We count unknown windows separately and
      # only act if the GPU stays unreadable for a long time, which indicates
      # a genuinely broken pod that should be stopped rather than billed.
      if (( window_peak < 0 )); then
        unknown_streak=$(( unknown_streak + 1 ))
        event "gpu_unreadable" "consecutive_windows=${unknown_streak}"
        if (( unknown_streak >= 5 )); then
          event "watchdog_trigger" "reason=gpu_unreadable" "windows=${unknown_streak}"
          # If stop_pod fails it signals the parent, which shuts everything
          # down. Either way this watchdog has finished its job.
          stop_pod "gpu_unreadable"
          exit 0
        fi
        continue
      fi
      unknown_streak=0

      # --- Busy window ------------------------------------------------------
      if (( window_peak > 0 )); then
        if (( idle_count > 0 )); then
          event "idle_counter_reset" "peak_util=${window_peak}" "was=${idle_count}"
        fi
        idle_count=0
        continue
      fi

      # --- Idle window ------------------------------------------------------
      idle_count=$(( idle_count + 1 ))
      event "idle_window" "count=${idle_count}" "threshold=${IDLE_MINUTES}"

      if (( idle_count >= IDLE_MINUTES )); then
        event "watchdog_trigger" "reason=idle" "idle_minutes=${idle_count}"
        stop_pod "idle"
        exit 0
      fi
    done
  ) &
  WATCHDOG_PID=$!
  echo "WATCHDOG_PID=${WATCHDOG_PID}" >> "${RUNTIME_ENV}"
else
  log "WARNING: RUNPOD_API_KEY or RUNPOD_POD_ID unset -- idle watchdog DISABLED."
  log "WARNING: this pod will bill continuously until stopped manually."
  event "watchdog_disabled" "reason=missing_credentials" "severity=high"
fi

# ---------------------------------------------------------------------------
# STEP 4. Tidy shutdown
#
# A "trap" registers a function to run when the script exits for any reason.
# This makes sure we do not leave orphaned processes or a stale machine entry
# cluttering up your Tailscale account.
#
# IDEMPOTENCY: this can legitimately run twice -- once when a TERM signal
# arrives (bash runs the handler and then RESUMES the script), and again on
# the final EXIT. The guard makes the second run a no-op instead of a
# confusing duplicate set of log lines and kill attempts.
# ---------------------------------------------------------------------------
CLEANUP_DONE=0
cleanup() {
  if (( CLEANUP_DONE )); then
    return 0
  fi
  CLEANUP_DONE=1

  # Tell the supervisor loop this exit is intentional, so it does not try to
  # "recover" from a shutdown we asked for. This single line is what stops a
  # watchdog-initiated shutdown from turning into a restart loop.
  SHUTTING_DOWN=1

  log "Shutting down..."
  event "pod_shutdown_begin" "uptime_seconds=${SECONDS}"
  [[ -n "${WATCHDOG_PID:-}" ]]  && kill "${WATCHDOG_PID}"  2>/dev/null || true
  [[ -n "${VLLM_PID:-}" ]]      && kill -TERM "${VLLM_PID}" 2>/dev/null || true
  tailscale --socket="${TS_SOCK}" logout >/dev/null 2>&1 || true
  [[ -n "${TAILSCALED_PID:-}" ]] && kill "${TAILSCALED_PID}" 2>/dev/null || true
  event "pod_shutdown_complete" "uptime_seconds=${SECONDS}"
  log "Clean exit."
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# STEP 5. Start vLLM, the model server
#
# vLLM exposes an API that looks exactly like OpenAI's, which is why Open WebUI
# can talk to it with no special adapter. Every setting below that starts with
# "--disable-log" or every environment variable mentioning telemetry exists for
# one reason: to make sure your prompts are never recorded anywhere.
# ---------------------------------------------------------------------------
export VLLM_CONFIGURE_LOGGING=0     # turn off vLLM's logging system entirely
export VLLM_NO_USAGE_STATS=1        # do not report usage statistics upstream
export DO_NOT_TRACK=1
export HF_HUB_DISABLE_TELEMETRY=1   # Hugging Face model downloads stay quiet
export ANONYMIZED_TELEMETRY=False
export TOKENIZERS_PARALLELISM=false
export NCCL_DEBUG=WARN

# Load the values we captured in Step 2.
# shellcheck disable=SC1090
source "${RUNTIME_ENV}"

# SECURITY: --trust-remote-code is NOT enabled by default.
#   That flag makes vLLM execute arbitrary Python shipped inside the model
#   repository, with full access to this pod and its credentials. A model
#   that is later modified upstream would run that code silently on your
#   next cold start. Qwen2.5-Coder does not require it.
#   Only set TRUST_REMOTE_CODE=1 for a model you have specifically vetted.
TRUST_FLAG=()
if [[ "${TRUST_REMOTE_CODE:-0}" == "1" ]]; then
  log "WARNING: --trust-remote-code ENABLED. Model repo code will execute on this pod."
  event "trust_remote_code_enabled" "severity=high" "model=${VLLM_MODEL}"
  TRUST_FLAG=(--trust-remote-code)
fi

# SECURITY: bind to loopback only, not 0.0.0.0.
#   In userspace-networking mode tailscaled does not create a real network
#   interface, so the 100.x address cannot be bound directly. Instead
#   tailscaled accepts inbound mesh connections and forwards them to
#   localhost. Binding vLLM to 127.0.0.1 therefore still works over the
#   tailnet, while making the unauthenticated model API unreachable from
#   every other interface on this pod (including the provider's internal
#   network). 0.0.0.0 would have exposed it to all of them.

# ---------------------------------------------------------------------------
# SUPERVISED LAUNCH
#
# AVAILABILITY: a bare vLLM crash used to simply end this script. The pod would
# stay RUNNING and billing, but answer nothing -- the worst combination, since
# you pay for an outage. We supervise it: if vLLM dies unexpectedly we restart
# it, up to MAX_RESTARTS times, logging every outcome.
#
# The restart budget is deliberately finite. A model that cannot start (bad
# weights, too little VRAM) would otherwise crash-loop forever at full cost.
# After the budget is spent we stop the pod so the failure is cheap.
#
# NOTE the interaction with the watchdog: a DELIBERATE shutdown sets
# SHUTTING_DOWN=1 via cleanup(), and the loop breaks instead of restarting.
# That flag is the only thing distinguishing "vLLM crashed" from "we asked
# vLLM to stop", and getting it wrong is what caused the billing bug fixed
# in stop_pod() above.
# ---------------------------------------------------------------------------
MAX_RESTARTS="${MAX_RESTARTS:-3}"
restart_count=0

# probe_ready -- returns 0 once vLLM answers /v1/models with a served model.
# Used to confirm a start actually SUCCEEDED, rather than assuming it did
# because the process is alive. A process that is up but not serving is an
# outage that silently passes a naive check.
probe_ready() {
  local deadline=$(( SECONDS + ${READY_TIMEOUT:-900} ))
  while (( SECONDS < deadline )); do
    if curl -fsS --max-time 5 "http://127.0.0.1:${VLLM_PORT}/v1/models" 2>/dev/null \
         | jq -e '.data[0].id' >/dev/null 2>&1; then
      return 0
    fi
    kill -0 "${VLLM_PID:-0}" 2>/dev/null || return 1   # process died while loading
    sleep 5
  done
  return 1
}

while true; do
  # If a shutdown was requested while we were backing off, do not start again.
  if [[ "${SHUTTING_DOWN:-0}" == "1" ]]; then
    event "vllm_start_skipped" "reason=shutdown_in_progress"
    break
  fi

  log "Launching vLLM -- model=${VLLM_MODEL} tp=${GPU_COUNT} port=${VLLM_PORT}"
  log "Request and stats logging are DISABLED. Prompts are never persisted."
  event "vllm_starting" "model=${VLLM_MODEL}" "tp=${GPU_COUNT}" \
        "attempt=$(( restart_count + 1 ))" "max_attempts=$(( MAX_RESTARTS + 1 ))"

  launch_ts=$SECONDS

  # Flag meanings:
  #   --quantization awq        model is compressed to ~4 bits per weight, so a
  #                             32B model fits on one affordable GPU
  #   --tensor-parallel-size    split the model across this many GPUs
  #   --gpu-memory-utilization  fraction of GPU memory vLLM may claim
  #   --max-model-len           maximum conversation length in tokens
  #   --disable-log-requests    never log prompt or response text  <- privacy
  #   --disable-log-stats       never log throughput statistics    <- privacy
  python3 -m vllm.entrypoints.openai.api_server \
    --model "${VLLM_MODEL}" \
    --served-model-name "${VLLM_MODEL}" \
    --quantization awq \
    --dtype auto \
    --tensor-parallel-size "${GPU_COUNT}" \
    --gpu-memory-utilization "${GPU_MEM_UTIL}" \
    --max-model-len "${MAX_MODEL_LEN}" \
    --host 127.0.0.1 \
    --port "${VLLM_PORT}" \
    --disable-log-requests \
    --disable-log-stats \
    --uvicorn-log-level warning \
    "${TRUST_FLAG[@]}" &

  VLLM_PID=$!
  # Replace rather than append, so the file always reflects the CURRENT pid.
  sed -i '/^VLLM_PID=/d' "${RUNTIME_ENV}" 2>/dev/null || true
  echo "VLLM_PID=${VLLM_PID}" >> "${RUNTIME_ENV}"

  log "vLLM starting (pid ${VLLM_PID}). Probing readiness on 127.0.0.1:${VLLM_PORT}"

  # --- Confirm the start actually succeeded -------------------------------
  if probe_ready; then
    event "vllm_ready" "pid=${VLLM_PID}" "load_seconds=$(( SECONDS - launch_ts ))" \
          "restarts_used=${restart_count}"
    log "vLLM is serving. Reachable from the Pi at ${TAILSCALE_IP}:${VLLM_PORT}"
  else
    event "vllm_ready_timeout" "pid=${VLLM_PID}" \
          "elapsed_seconds=$(( SECONDS - launch_ts ))" "severity=high"
  fi

  # --- Block until vLLM exits ---------------------------------------------
  # CAREFUL: `wait "$PID" || true` would discard the exit status, because $?
  # then reports the status of `true`. Every crash would be logged as
  # exit_code=0, which is exactly the number you do not want when diagnosing
  # why the server died. Capture it inside the if/else instead.
  if wait "${VLLM_PID}"; then
    exit_code=0
  else
    exit_code=$?
  fi
  uptime_s=$(( SECONDS - launch_ts ))

  # A deliberate shutdown (watchdog, SIGTERM, stop_pod failure path) sets this
  # flag via cleanup(). Without this check the supervisor would "helpfully"
  # restart a server we just asked to stop -- and on the stop_pod failure path
  # that meant an unmonitored pod billing indefinitely.
  if [[ "${SHUTTING_DOWN:-0}" == "1" ]]; then
    event "vllm_stopped" "reason=deliberate_shutdown" "uptime_seconds=${uptime_s}"
    break
  fi

  event "vllm_exited" "exit_code=${exit_code}" "uptime_seconds=${uptime_s}" \
        "restarts_used=${restart_count}" "severity=high"

  if (( restart_count >= MAX_RESTARTS )); then
    event "vllm_restart_budget_exhausted" "restarts=${restart_count}" \
          "severity=critical" "action=stopping_pod"
    log "FATAL: vLLM failed ${restart_count} times. Stopping the pod to avoid billing for an outage."
    if [[ -n "${RUNPOD_API_KEY:-}" && -n "${RUNPOD_POD_ID:-}" ]]; then
      stop_pod "vllm_crash_loop" || true
    fi
    exit 1
  fi

  restart_count=$(( restart_count + 1 ))
  # Back off before retrying so a fast crash-loop cannot spin the CPU.
  backoff=$(( restart_count * 15 ))
  event "vllm_restarting" "attempt=${restart_count}" "backoff_seconds=${backoff}"
  sleep "$backoff"
done
