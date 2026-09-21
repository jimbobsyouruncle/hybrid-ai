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
#       Tailscale keys, AWS-style keys, bearer tokens, JWTs, passwords in
#       URLs, and private key blocks.
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
    -e 's/\bgithub_pat_[A-Za-z0-9_]{20,}/<REDACTED:github-token>/g' \
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
on a rented RunPod GPU over a Tailscale private network.

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
  - ./doctor.sh is a health checker; its output is included below.
EOF

# ---------------------------------------------------------------------------
# 1. doctor.sh -- the highest-signal section, so it goes first
# ---------------------------------------------------------------------------
printf '  %s[1/9]%s Health check...\n' "$C_INF" "$C_RST"
sec "1. HEALTH CHECK (doctor.sh)"
if [[ -x ./doctor.sh ]]; then
  { ./doctor.sh --no-cloud 2>&1 || true; } | redact >> "$OUTFILE"
else
  note "doctor.sh not found or not executable."
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
  SAFE_KEYS="OLLAMA_NUM_PARALLEL|OLLAMA_MAX_LOADED_MODELS|OLLAMA_KEEP_ALIVE|OLLAMA_MAX_VRAM|WEBUI_AUTH|VLLM_PORT|VLLM_MODEL_NAME|POD_WARMUP_TIMEOUT|RAG_EMBEDDING_MODEL|ENABLE_OPENAI_API|SCARF_NO_ANALYTICS|DO_NOT_TRACK|ANONYMIZED_TELEMETRY"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      k="${BASH_REMATCH[1]}"; v="${BASH_REMATCH[2]}"
      if [[ -z "$v" ]]; then
        printf '  %-28s <EMPTY>\n' "$k"
      elif [[ "$k" =~ ^(${SAFE_KEYS})$ ]]; then
        printf '  %-28s %s\n' "$k" "$v"
      elif [[ "$k" == "TAILSCALE_IP" ]]; then
        # The SHAPE matters for diagnosis (is it inside the mesh range?);
        # the exact host does not.
        if [[ "$v" =~ ^100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\. ]]; then
          printf '  %-28s 100.x.x.x  (VALID mesh range)\n' "$k"
        else
          printf '  %-28s <set>  <-- OUTSIDE 100.64.0.0/10, pipe will refuse to send\n' "$k"
        fi
      else
        printf '  %-28s <REDACTED:length=%s>\n' "$k" "${#v}"
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

run "docker-compose.yml images in use" bash -c "grep -E '^\s+image:' docker-compose.yml 2>/dev/null || echo 'not found'"
run "Git state" bash -c "git rev-parse --short HEAD 2>/dev/null && git status --porcelain 2>/dev/null | head -20 || echo 'not a git checkout'"

# ---------------------------------------------------------------------------
# 5. Containers
# ---------------------------------------------------------------------------
printf '  %s[5/9]%s Container status...\n' "$C_INF" "$C_RST"
sec "5. CONTAINERS"
run "Compose services"    docker compose --env-file .env ps
run "All containers"      docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
run "Resource usage"      docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}'

for svc in ollama open-webui hybrid-ai-status hybrid-ai-proxy; do
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
run "open-webui (last ${LOG_LINES})" docker compose --env-file .env logs --tail "$LOG_LINES" --no-color open-webui
run "ollama (last ${LOG_LINES})"     docker compose --env-file .env logs --tail "$LOG_LINES" --no-color ollama
run "status page (last 40)"         docker compose --env-file .env logs --tail 40 --no-color status
run "proxy (last 40)"               docker compose --env-file .env logs --tail 40 --no-color proxy

# The pipe's own structured records: one line per request outcome.
sub "RunPod pipe events (structured)"
{ docker compose --env-file .env logs --tail 400 --no-color open-webui 2>/dev/null \
    | grep -E 'runpod_pipe|event=(request_|pod_ready|runpod_api)' | tail -60 \
    || printf '(none found)\n'; } | redact >> "$OUTFILE"

sub "Errors and exceptions across both containers"
{ docker compose --env-file .env logs --tail 500 --no-color 2>/dev/null \
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
  for p in /hub /status /app/ /openwebui /health /ollama/api/tags; do
    printf "route %-16s " "$p"
    curl -s -o /dev/null -w "HTTP %{http_code}\n" --max-time 6 "http://127.0.0.1:80${p}" 2>/dev/null || echo "unreachable"
  done
  printf "NOTE: /openwebui returns 302 by design; /health returns 503 when degraded.\n"
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
