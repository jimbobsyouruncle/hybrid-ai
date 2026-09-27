#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: runpod/start.sh
# ---------------------------------------------------------------------------
set -Eeuo pipefail

VLLM_MODEL="${VLLM_MODEL:-Qwen/Qwen2.5-Coder-32B-Instruct-AWQ}"
VLLM_PORT="${VLLM_PORT:-8000}"
IDLE_MINUTES="${IDLE_MINUTES:-15}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-16384}"
GPU_MEM_UTIL="${GPU_MEM_UTIL:-0.92}"
TS_HOSTNAME="${TS_HOSTNAME:-runpod-worker}"

# Optional controls
VLLM_QUANTIZATION="${VLLM_QUANTIZATION:-}"       
TENSOR_PARALLEL_SIZE="${TENSOR_PARALLEL_SIZE:-}" 
VLLM_API_KEY="${VLLM_API_KEY:-}"                 
TRUST_REMOTE_CODE="${TRUST_REMOTE_CODE:-0}"

RUNTIME_ENV="/etc/runtime.env"
TS_SOCK="/var/run/tailscale/tailscaled.sock"
TS_STATE="/var/lib/tailscale/tailscaled.state"

MAIN_PID=$$

log()  { printf '[start.sh %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die()  {
  event "fatal_error" "detail=$(printf '%s' "$*" | tr -d '\n' | cut -c1-160)" 2>/dev/null || true
  printf '[start.sh FATAL] %s\n' "$*" >&2
  exit 1
}
trap 'die "aborted at line ${LINENO}: ${BASH_COMMAND}"' ERR

EVENT_LOG="${EVENT_LOG:-/var/log/hybrid-ai-events.log}"
event() {
  local name="$1"; shift
  local line
  line="EVENT ts=$(date -u +%Y-%m-%dT%H:%M:%SZ) event=${name} $*"
  printf '%s\n' "$line"
  printf '%s\n' "$line" >> "$EVENT_LOG" 2>/dev/null || true
}

stop_pod() {
  local reason="${1:-unspecified}"
  local attempt delay resp http_ok

  for attempt in 1 2 3 4; do
    resp="$(curl -sS --max-time 30 \
      --config <(printf 'header = "Authorization: Bearer %s"\n' "${RUNPOD_API_KEY}") \
      -X POST "https://api.runpod.io/graphql" \
      -H 'Content-Type: application/json' \
      --data @<(jq -n --arg id "${RUNPOD_POD_ID}" '{
          query: "mutation stop($input: PodStopInput!) { podStop(input: $input) { id desiredStatus } }",
          variables: { input: { podId: $id } }
        }') 2>&1)" || resp=""

    http_ok="$(printf '%s' "$resp" | jq -r '
        if (.errors // empty) then "err"
        elif (.data.podStop.id // empty) then "ok"
        else "unknown" end' 2>/dev/null || echo "unknown")"

    if [[ "$http_ok" == "ok" ]]; then
      event "podstop_success" "reason=${reason}" "attempt=${attempt}" \
            "desired_status=$(printf '%s' "$resp" | jq -r '.data.podStop.desiredStatus // "?"' 2>/dev/null)"
      return 0
    fi

    event "podstop_failure" "reason=${reason}" "attempt=${attempt}" \
          "result=${http_ok}" \
          "detail=$(printf '%s' "$resp" | jq -rc '.errors[0].message // "no_response"' 2>/dev/null | tr -d '\n' | cut -c1-120)"

    if (( attempt < 4 )); then
      delay=$(( attempt * attempt * 5 ))
      sleep "$delay"
    fi
  done

  event "podstop_exhausted" "reason=${reason}" "severity=critical" \
        "action=terminating_pod_locally"
  
  kill -TERM "$MAIN_PID" 2>/dev/null || true
  sleep 10
  pkill -TERM -f 'vllm' 2>/dev/null || true
  return 1
}

log "=============================================================="
log " cloud inference plane :: cold start"
log "=============================================================="

# ---------------------------------------------------------------------------
# STEP 0. Secure SSH Injection
# ---------------------------------------------------------------------------
if [[ -n "${PUBLIC_KEY:-}" ]]; then
  log "Injecting RunPod public SSH keys..."
  echo "${PUBLIC_KEY}" >> /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
  service ssh start
  log "SSH daemon started. Accessible via Tailscale on port 22."
else
  log "WARNING: No PUBLIC_KEY environment variable provided. Standard SSH will not authenticate."
fi

# ---------------------------------------------------------------------------
# STEP 1. Join tailnet (userspace networking)
# ---------------------------------------------------------------------------
[[ -n "${TAILSCALE_AUTH_KEY:-}" ]] || die "TAILSCALE_AUTH_KEY is not set. Cannot join the mesh."

mkdir -p /var/run/tailscale /var/lib/tailscale

log "Starting tailscaled (userspace-networking)..."
tailscaled \
  --tun=userspace-networking \
  --state="${TS_STATE}" \
  --socket="${TS_SOCK}" \
  --socks5-server=localhost:1055 \
  --outbound-http-proxy-listen=localhost:1055 \
  >/var/log/tailscaled.log 2>&1 &
TAILSCALED_PID=$!

for _ in $(seq 1 30); do
  [[ -S "${TS_SOCK}" ]] && break
  kill -0 "$TAILSCALED_PID" 2>/dev/null || die "tailscaled died during startup. See /var/log/tailscaled.log"
  sleep 1
done
[[ -S "${TS_SOCK}" ]] || die "tailscaled socket never appeared."

log "Authenticating to tailnet as '${TS_HOSTNAME}'..."
AUTHKEY_FILE="$(mktemp /run/.tskey.XXXXXX)"
chmod 600 "$AUTHKEY_FILE"
printf '%s' "${TAILSCALE_AUTH_KEY}" > "$AUTHKEY_FILE"

tailscale --socket="${TS_SOCK}" up \
  --auth-key="file:${AUTHKEY_FILE}" \
  --hostname="${TS_HOSTNAME}" \
  --accept-dns=false \
  --ssh

shred -u "$AUTHKEY_FILE" 2>/dev/null || rm -f "$AUTHKEY_FILE"

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
# STEP 2. Runtime state capture
# ---------------------------------------------------------------------------
if command -v nvidia-smi >/dev/null 2>&1; then
  GPU_COUNT="$(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | wc -l | tr -d ' ')"
  GPU_NAME="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1)"
  GPU_MEM_TOTAL="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -n1)"
  
  # Sanitize memory output in case host reports insufficient permissions
  if [[ ! "$GPU_MEM_TOTAL" =~ ^[0-9]+$ ]]; then
    GPU_MEM_TOTAL=0
  fi
else
  GPU_COUNT=0; GPU_NAME="none"; GPU_MEM_TOTAL=0
fi
[[ "${GPU_COUNT:-0}" -ge 1 ]] || die "No CUDA devices visible. Refusing to start vLLM."

if [[ -z "${TENSOR_PARALLEL_SIZE}" ]]; then
  TENSOR_PARALLEL_SIZE="${GPU_COUNT}"
fi

umask 077
cat > "${RUNTIME_ENV}" <<EOF
TAILSCALE_IP="${TAILSCALE_IP}"
TS_HOSTNAME="${TS_HOSTNAME}"
TS_SOCK="${TS_SOCK}"
GPU_COUNT="${GPU_COUNT}"
GPU_NAME="${GPU_NAME}"
GPU_MEM_TOTAL_MB="${GPU_MEM_TOTAL}"
RUNPOD_POD_ID="${RUNPOD_POD_ID:-unknown}"
VLLM_MODEL="${VLLM_MODEL}"
VLLM_PORT="${VLLM_PORT}"
IDLE_MINUTES="${IDLE_MINUTES}"
GPU_MEM_UTIL="${GPU_MEM_UTIL}"
MAX_MODEL_LEN="${MAX_MODEL_LEN}"
TENSOR_PARALLEL_SIZE="${TENSOR_PARALLEL_SIZE}"
VLLM_QUANTIZATION="${VLLM_QUANTIZATION}"
BOOT_TS="$(date -u +%s)"
EOF
chmod 600 "${RUNTIME_ENV}"

event "runtime_state_captured" "gpu_count=${GPU_COUNT}" "gpu_mem_mb=${GPU_MEM_TOTAL}" "tp=${TENSOR_PARALLEL_SIZE}" "pod=${RUNPOD_POD_ID:-unknown}"

# ---------------------------------------------------------------------------
# STEP 3. Idle watchdog
# ---------------------------------------------------------------------------
if [[ -n "${RUNPOD_API_KEY:-}" && -n "${RUNPOD_POD_ID:-}" ]]; then
  log "Arming idle watchdog: ${IDLE_MINUTES} min @ 0% GPU -> podStop"
  event "watchdog_armed" "idle_minutes=${IDLE_MINUTES}" "sample_interval=5s"

  (
    trap - ERR
    set +eE

    idle_count=0
    unknown_streak=0

    sleep 300
    event "watchdog_active" "grace_period_elapsed=300s"

    while true; do
      window_peak=-1
      for _ in $(seq 1 12); do
        sleep 5
        raw="$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null)" || raw=""
        if [[ -n "$raw" ]]; then
          sample="$(printf '%s\n' "$raw" | awk 'BEGIN{m=0} /^[0-9]+$/ {if ($1+0 > m) m=$1+0} END{print m+0}')"
          [[ -n "$sample" ]] && (( sample > window_peak )) && window_peak=$sample
        fi
      done

      if (( window_peak < 0 )); then
        unknown_streak=$(( unknown_streak + 1 ))
        if (( unknown_streak >= 5 )); then
          stop_pod "gpu_unreadable"
          exit 0
        fi
        continue
      fi
      unknown_streak=0

      if (( window_peak > 0 )); then
        idle_count=0
        continue
      fi

      idle_count=$(( idle_count + 1 ))

      if (( idle_count >= IDLE_MINUTES )); then
        stop_pod "idle"
        exit 0
      fi
    done
  ) &
  WATCHDOG_PID=$!
  echo "WATCHDOG_PID=${WATCHDOG_PID}" >> "${RUNTIME_ENV}"
else
  log "WARNING: RUNPOD_API_KEY or RUNPOD_POD_ID unset -- idle watchdog DISABLED."
fi

# ---------------------------------------------------------------------------
# STEP 4. Tidy shutdown
# ---------------------------------------------------------------------------
CLEANUP_DONE=0
cleanup() {
  if (( CLEANUP_DONE )); then return 0; fi
  CLEANUP_DONE=1

  SHUTTING_DOWN=1
  log "Shutting down..."

  [[ -n "${WATCHDOG_PID:-}" ]] && kill "${WATCHDOG_PID}" 2>/dev/null || true
  [[ -n "${VLLM_PID:-}"     ]] && kill -TERM "${VLLM_PID}" 2>/dev/null || true
  tailscale --socket="${TS_SOCK}" logout >/dev/null 2>&1 || true
  [[ -n "${TAILSCALED_PID:-}" ]] && kill "${TAILSCALED_PID}" 2>/dev/null || true
  
  service ssh stop >/dev/null 2>&1 || true

  log "Clean exit."
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# STEP 5. Start vLLM 
# ---------------------------------------------------------------------------
export VLLM_CONFIGURE_LOGGING=0
export VLLM_NO_USAGE_STATS=1
export DO_NOT_TRACK=1
export HF_HUB_DISABLE_TELEMETRY=1
export ANONYMIZED_TELEMETRY=False
export TOKENIZERS_PARALLELISM=false
export NCCL_DEBUG=WARN

source "${RUNTIME_ENV}"

TRUST_FLAG=()
if [[ "${TRUST_REMOTE_CODE}" == "1" ]]; then
  TRUST_FLAG=(--trust-remote-code)
fi

APIKEY_FLAG=()
if [[ -n "${VLLM_API_KEY}" ]]; then
  APIKEY_FLAG=(--api-key "${VLLM_API_KEY}")
fi

QUANT_FLAG=()
if [[ -n "${VLLM_QUANTIZATION}" ]]; then
  QUANT_FLAG=(--quantization "${VLLM_QUANTIZATION}")
fi

MAX_RESTARTS="${MAX_RESTARTS:-3}"
restart_count=0

probe_ready() {
  local deadline=$(( SECONDS + ${READY_TIMEOUT:-900} ))
  while (( SECONDS < deadline )); do
    if curl -fsS --max-time 5 "http://127.0.0.1:${VLLM_PORT}/v1/models" 2>/dev/null \
         | jq -e '.data[0].id' >/dev/null 2>&1; then
      return 0
    fi
    kill -0 "${VLLM_PID:-0}" 2>/dev/null || return 1
    sleep 5
  done
  return 1
}

while true; do
  if [[ "${SHUTTING_DOWN:-0}" == "1" ]]; then
    break
  fi

  log "Launching vLLM -- model=${VLLM_MODEL} tp=${TENSOR_PARALLEL_SIZE} port=${VLLM_PORT}"
  launch_ts=$SECONDS

  if command -v vllm >/dev/null 2>&1; then
    vllm serve "${VLLM_MODEL}" \
      --served-model-name "${VLLM_MODEL}" \
      --dtype auto \
      --tensor-parallel-size "${TENSOR_PARALLEL_SIZE}" \
      --gpu-memory-utilization "${GPU_MEM_UTIL}" \
      --max-model-len "${MAX_MODEL_LEN}" \
      --host 127.0.0.1 \
      --port "${VLLM_PORT}" \
      --uvicorn-log-level warning \
      "${TRUST_FLAG[@]}" \
      "${APIKEY_FLAG[@]}" \
      "${QUANT_FLAG[@]}" &
  else
    python3 -m vllm.entrypoints.openai.api_server \
      --model "${VLLM_MODEL}" \
      --served-model-name "${VLLM_MODEL}" \
      --dtype auto \
      --tensor-parallel-size "${TENSOR_PARALLEL_SIZE}" \
      --gpu-memory-utilization "${GPU_MEM_UTIL}" \
      --max-model-len "${MAX_MODEL_LEN}" \
      --host 127.0.0.1 \
      --port "${VLLM_PORT}" \
      --uvicorn-log-level warning \
      "${TRUST_FLAG[@]}" \
      "${APIKEY_FLAG[@]}" \
      "${QUANT_FLAG[@]}" &
  fi

  VLLM_PID=$!
  sed -i '/^VLLM_PID=/d' "${RUNTIME_ENV}" 2>/dev/null || true
  echo "VLLM_PID=${VLLM_PID}" >> "${RUNTIME_ENV}"

  log "vLLM starting (pid ${VLLM_PID}). Probing readiness on 127.0.0.1:${VLLM_PORT}"

  if probe_ready; then
    log "vLLM is serving. Reachable from tailnet at ${TAILSCALE_IP}:${VLLM_PORT}"
  fi

  if wait "${VLLM_PID}"; then
    exit_code=0
  else
    exit_code=$?
  fi

  if [[ "${SHUTTING_DOWN:-0}" == "1" ]]; then
    break
  fi

  if (( restart_count >= MAX_RESTARTS )); then
    log "FATAL: vLLM failed ${restart_count} times. Stopping the pod."
    if [[ -n "${RUNPOD_API_KEY:-}" && -n "${RUNPOD_POD_ID:-}" ]]; then
      stop_pod "vllm_crash_loop" || true
    fi
    exit 1
  fi

  restart_count=$(( restart_count + 1 ))
  backoff=$(( restart_count * 15 ))
  sleep "$backoff"
done
