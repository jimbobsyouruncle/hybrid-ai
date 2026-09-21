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
# A full SD card is behind a surprising share of 'it just stopped working'.
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
    # present but not booted from means the user paid for speed they are not
    # getting, and nothing else would ever tell them.
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

# --- SD card health ---------------------------------------------------------
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
  for key in WEBUI_SECRET_KEY RUNPOD_API_KEY RUNPOD_POD_ID TAILSCALE_IP; do
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
else
  fail ".env is missing" "Run ./install.sh to create it."
fi

# ---------------------------------------------------------------------------
# 3. Containers
# ---------------------------------------------------------------------------
section "Containers"

for svc in ollama open-webui hybrid-ai-status hybrid-ai-proxy; do
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
      # The status page and proxy are optional conveniences; chat works
      # perfectly without them, so their absence is not a failure.
      if [[ "$svc" == hybrid-ai-* ]]; then
        warn "${svc} does not exist" "Optional. Run ./install.sh to add the status page."
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

    PEER_JSON="$(tailscale status --json 2>/dev/null | jq -r '
      (.Peer // {}) | to_entries | map(.value)
      | map(select((.HostName // "") | ascii_downcase | contains("runpod-vllm")))
      | .[0] // empty' 2>/dev/null)"
    if [[ -n "$PEER_JSON" ]]; then
      ONLINE="$(printf '%s' "$PEER_JSON" | jq -r '.Online // false' 2>/dev/null)"
      if [[ "$ONLINE" == "true" ]]; then
        pass "GPU pod is online"
      else
        # This is the normal, money-saving state. Not a problem.
        pass "GPU pod known but stopped (normal - it wakes on demand)"
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
