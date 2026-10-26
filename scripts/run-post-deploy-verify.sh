#!/usr/bin/env bash
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# FILE: scripts/run-post-deploy-verify.sh
# PURPOSE (plain English):
#   Checks the deploy AFTER the deploy workflow has finished. scripts/
#   deploy-remote.sh starts it in a transient systemd unit when it is present,
#   so the check outlives the deploy unit's cgroup (a child of the deploy unit
#   would be killed the moment that unit exits).
#
#   It waits for the GitHub Actions run(s) for one commit SHA to complete, then
#   checks that every one of them concluded "success", then checks that the
#   deployed tree still sits on that same commit. It writes ONE result line:
#   PASS, FAIL (with the reason) or TIMEOUT.
#
# WHY IT EXISTS:
#   The deploy workflow reports on the work it started, not on the result of the
#   build it kicked off in the same run. A verification that runs after the run
#   completes is the only place that can see the final verdict AND the tree.
#   Before this script existed the hook pointed at a file nothing installed, so
#   the check silently never ran.
#
# DEPENDENCIES: bash, curl, jq, git, date -- all already probed by install.sh.
#   No Python, no token, no credential. The GitHub API is read ANONYMOUSLY.
#
# USAGE:
#   ./scripts/run-post-deploy-verify.sh --wait-for <full-40-hex-commit-sha>
#
#   APP_DIR resolves in order: HYBRID_AI_APP_DIR from the environment; else
#   HYBRID_AI_APP_DIR parsed line by line from the layout file named by
#   ${HYBRID_AI_ENV_FILE_FALLBACK:-/etc/hybrid-ai/hybrid-ai.env}; else /workspace.
#   The layout file is read as DATA (KEY=VALUE), never sourced, and no value from
#   it is ever printed. Tests point APP_DIR at a throwaway checkout.
#
# EXIT CODES:
#   0  PASS   every run succeeded and the deployed tree is on the SHA
#   1  FAIL   a run failed, the API refused, or the tree is on another commit
#   1  TIMEOUT (also non-zero) no completed run inside the 60 minute deadline
#   2  usage error: bad argument, unknown option, or a malformed SHA
# ---------------------------------------------------------------------------

REPO_SLUG="jimbobsyouruncle/hybrid-ai"
POLL_SECONDS=30
DEADLINE_SECONDS=3600
USER_AGENT="hybrid-ai-post-deploy-verify"

usage_refuse() {
  printf 'run-post-deploy-verify: %s\n' "$1" >&2
  printf 'usage: run-post-deploy-verify.sh --wait-for <40-hex-commit-sha>\n' >&2
  exit 2
}

# One result line on stdout, nothing else. Detail, when present, is folded into
# that single line so the log stays greppable.
finish() { # <PASS|FAIL|TIMEOUT> <rc> [detail]
  local verdict="$1" rc="$2" detail="${3:-}"
  if [[ -n "$detail" ]]; then
    printf '%s: %s\n' "$verdict" "$detail"
  else
    printf '%s\n' "$verdict"
  fi
  exit "$rc"
}

[[ $# -eq 2 ]] || usage_refuse "expected exactly one option: --wait-for <sha>"
[[ "$1" == "--wait-for" ]] || usage_refuse "unknown option or missing --wait-for"
SHA="$2"
[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] \
  || usage_refuse "--wait-for needs a 40-character lowercase hex commit SHA"

# Resolve APP_DIR in three steps. The layout file is read as DATA, one KEY=VALUE
# line at a time -- it is NEVER sourced, and no value read from it is printed.
# An unreadable EXISTING file fails closed and names the setting, never a value.
HYBRID_AI_ENV_FILE_FALLBACK="${HYBRID_AI_ENV_FILE_FALLBACK:-/etc/hybrid-ai/hybrid-ai.env}"

resolve_app_dir() {
  local value="" line key

  if [[ -n "${HYBRID_AI_APP_DIR:-}" ]]; then
    printf '%s' "$HYBRID_AI_APP_DIR"
    return 0
  fi

  if [[ -e "$HYBRID_AI_ENV_FILE_FALLBACK" ]]; then
    if [[ ! -r "$HYBRID_AI_ENV_FILE_FALLBACK" ]]; then
      printf 'run-post-deploy-verify: HYBRID_AI_ENV_FILE_FALLBACK (%s) exists but is not readable\n' \
        "$HYBRID_AI_ENV_FILE_FALLBACK" >&2
      return 1
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line#"${line%%[![:space:]]*}"}"
      [[ "$line" == HYBRID_AI_APP_DIR=* ]] || continue
      value="${line#HYBRID_AI_APP_DIR=}"
      key="$value"
      [[ "$key" == /* ]] || { value=""; break; }
      if [[ "$key" == *[[:space:]]* || "$key" == *:* || "$key" == *","* ]]; then
        value=""
        break
      fi
      break
    done < "$HYBRID_AI_ENV_FILE_FALLBACK"
    if [[ -n "$value" ]]; then
      printf '%s' "$value"
      return 0
    fi
  fi

  printf '%s' "/workspace"
  return 0
}

APP_DIR="$(resolve_app_dir)" || exit 1
API_URL="https://api.github.com/repos/${REPO_SLUG}/actions/runs?head_sha=${SHA}"

# --- Backups tile gate ------------------------------------------------------
# A release can leave the Backups tile blind while the writer's log records a
# success: the reader is then wrong, not the backups. This gate catches exactly
# that. It reads settings from the layout file as DATA (never sourced, values
# never printed) and needs three things:
#   (a) BACKUP_LOG is a regular, non-empty file;
#   (b) the STATUS CONTAINER'S identity (uid 1000, primary gid 999, plus the one
#       supplementary BACKUP_GROUP_GID) can read it -- probed by DROPPING
#       privileges from root with setpriv, because a root read proves nothing;
#   (c) the live status API's Backups tile is not `warn` while the log holds a
#       backup_success line.
# Anything this cannot test leaves the verdict to the checks it CAN run, and
# says so on stderr: a skipped probe is never reported as a pass.
GATE_REASON=""
# Identity the status service actually runs as (docker-compose.yml `user:`).
STATUS_RUN_UID="${VERIFY_STATUS_UID:-1000}"
STATUS_RUN_GID="${VERIFY_STATUS_GID:-999}"

gate_skip() { printf 'run-post-deploy-verify: skip: %s\n' "$1" >&2; }

# Read ONE key from the layout file, line by line, never sourcing it.
layout_value() { # <KEY>
  local key="$1" line value=""
  [[ -r "$HYBRID_AI_ENV_FILE_FALLBACK" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    [[ "$line" == "$key="* ]] || continue
    value="${line#*=}"
    value="${value%\"}"; value="${value#\"}"
    value="${value%\'}"; value="${value#\'}"
  done < "$HYBRID_AI_ENV_FILE_FALLBACK"
  printf '%s' "$value"
}

# True when the log holds at least one success line, read as the caller (root in
# the transient unit). Used only to decide whether a `warn` tile contradicts the
# writer; a read failure here is "unknown", never "no success".
log_has_success() { # <path>
  grep -q 'event=backup_success' "$1" 2>/dev/null
}

# Probe readability as the status container's identity. Sets B_READ_STATE to
# readable | unreadable | skipped. A root read is NEVER reported as readable.
B_READ_STATE=""
probe_read_as_status() { # <path> <supplementary-gid>
  local path="$1" gid="$2"
  B_READ_STATE="skipped"
  if [[ "$(id -u)" != "0" ]]; then
    gate_skip "not root: cannot drop privileges to the status container's identity; readability not proven by this run"
    return 0
  fi
  if ! command -v setpriv >/dev/null 2>&1; then
    gate_skip "setpriv is unavailable: readability as the status identity not proven"
    return 0
  fi
  if [[ ! "$gid" =~ ^[0-9]+$ ]]; then
    gate_skip "BACKUP_GROUP_GID is not a numeric gid: readability as the status identity not proven"
    return 0
  fi
  if setpriv --reuid="$STATUS_RUN_UID" --regid="$STATUS_RUN_GID" \
       --groups="$gid" --inh-caps=-all --bounding-set=-all -- \
       test -r "$path" 2>/dev/null; then
    B_READ_STATE="readable"
  else
    B_READ_STATE="unreadable"
  fi
  return 0
}

# Query the live status API through the route the Caddyfile names:
# http://status.$LOCAL_DOMAIN/status/api, resolved to loopback. Sets B_TILE to
# the Backups state, or empty when no verdict could be read.
B_TILE=""
probe_tile() { # <local-domain>
  local domain="$1" body code
  B_TILE=""
  if [[ -z "$domain" ]]; then
    gate_skip "LOCAL_DOMAIN is not set in the layout file: the status API was not queried"
    return 0
  fi
  body="$(mktemp)"
  code="$(curl -sS --max-time 10 -A "$USER_AGENT" \
      --resolve "status.${domain}:80:127.0.0.1" \
      -o "$body" -w '%{http_code}' \
      "http://status.${domain}/status/api" 2>/dev/null || true)"
  if [[ "$code" != 2* ]]; then
    rm -f -- "$body"
    gate_skip "the status API was unreachable: the Backups tile was not checked"
    return 0
  fi
  B_TILE="$(jq -r '.checks[]? | select(.name == "Backups") | .state' "$body" 2>/dev/null || true)"
  rm -f -- "$body"
  if [[ -z "$B_TILE" ]]; then
    gate_skip "the status API returned no Backups tile: the tile was not checked"
    return 0
  fi
  return 0
}

# Returns 1 and fills GATE_REASON when the release leaves the tile blind while
# the writer's log reports success.
check_backup_tile() {
  local log gid domain
  log="${BACKUP_LOG:-$(layout_value BACKUP_LOG)}"
  gid="${BACKUP_GROUP_GID:-$(layout_value BACKUP_GROUP_GID)}"
  domain="${LOCAL_DOMAIN:-$(layout_value LOCAL_DOMAIN)}"

  GATE_REASON=""
  if [[ -z "$log" ]]; then
    gate_skip "BACKUP_LOG is not set: the backup log was not checked"
    return 0
  fi
  if [[ ! -f "$log" || ! -s "$log" ]]; then
    GATE_REASON="the backup log is not a regular, non-empty file"
    return 1
  fi
  probe_read_as_status "$log" "$gid"
  if [[ "$B_READ_STATE" == "unreadable" ]]; then
    GATE_REASON="the status container's identity cannot read the backup log"
    return 1
  fi
  probe_tile "$domain"
  if [[ "$B_TILE" == "warn" ]] && log_has_success "$log"; then
    GATE_REASON="the backup log records event=backup_success but the Backups tile reports warn"
    return 1
  fi
  return 0
}

BODY_FILE="$(mktemp)"
ERR_FILE="$(mktemp)"
trap 'rm -f -- "$BODY_FILE" "$ERR_FILE"' EXIT

# Filled by probe_runs(). Kept as globals so the caller can print the exact
# run ids and conclusions in one FAIL line.
PROBE_STATE=""
PROBE_ERROR=""
RUN_IDS=()
RUN_STATUS=()
RUN_CONCLUSION=()

# Ask the API once. Always returns 0; the outcome is in PROBE_STATE.
#   completed  at least one run, every run completed
#   pending    no run yet, or a run still in progress
#   error      the API, the network or the body was unusable
# Never sends an Authorization header: the request is anonymous on purpose.
probe_runs() {
  local http_code rows id status conclusion

  PROBE_STATE="pending"
  PROBE_ERROR=""
  RUN_IDS=(); RUN_STATUS=(); RUN_CONCLUSION=()

  if ! http_code="$(curl -sS --max-time 20 -A "$USER_AGENT" \
        -o "$BODY_FILE" -w '%{http_code}' "$API_URL" 2>"$ERR_FILE")"; then
    PROBE_STATE="error"
    PROBE_ERROR="curl could not reach the github api"
    return 0
  fi

  case "$http_code" in
    2*) ;;
    *)
      PROBE_STATE="error"
      PROBE_ERROR="github api returned HTTP ${http_code}"
      return 0
      ;;
  esac

  if ! jq -e 'has("workflow_runs")' "$BODY_FILE" >/dev/null 2>&1; then
    PROBE_STATE="error"
    PROBE_ERROR="github api returned a body that jq could not parse"
    return 0
  fi

  if ! rows="$(jq -r '.workflow_runs[] | "\(.id)\t\(.status)\t\(.conclusion // "")"' \
        "$BODY_FILE" 2>/dev/null)"; then
    PROBE_STATE="error"
    PROBE_ERROR="github api returned a body that jq could not parse"
    return 0
  fi

  while IFS=$'\t' read -r id status conclusion; do
    [[ -n "$id" ]] || continue
    RUN_IDS+=("$id")
    RUN_STATUS+=("$status")
    RUN_CONCLUSION+=("$conclusion")
  done <<<"$rows"

  # Zero runs is NOT "completed": the run may not exist for a few seconds after
  # the deploy starts the check.
  (( ${#RUN_IDS[@]} > 0 )) || return 0

  local s
  for s in "${RUN_STATUS[@]}"; do
    [[ "$s" == "completed" ]] || return 0
  done
  PROBE_STATE="completed"
  return 0
}

# Which conclusions a completed set carries, as one comma-separated word list.
conclusion_list() {
  local out="" i
  for i in "${!RUN_CONCLUSION[@]}"; do
    [[ -n "$out" ]] && out+=","
    out+="${RUN_CONCLUSION[$i]:-none}"
  done
  printf '%s' "$out"
}

printf 'waiting for %s at %s\n' "$SHA" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

START_TS="$(date +%s)"
while :; do
  probe_runs

  case "$PROBE_STATE" in
    error)
      finish FAIL 1 "$PROBE_ERROR"
      ;;
    completed)
      all_success=1
      idx=0
      while (( idx < ${#RUN_CONCLUSION[@]} )); do
        [[ "${RUN_CONCLUSION[$idx]}" == "success" ]] || all_success=0
        idx=$(( idx + 1 ))
      done
      unset idx

      if (( ! all_success )); then
        if (( ${#RUN_IDS[@]} == 1 )); then
          finish FAIL 1 "run ${RUN_IDS[0]} conclusion ${RUN_CONCLUSION[0]:-none}"
        fi
        finish FAIL 1 "run conclusions: $(conclusion_list)"
      fi

      # The workflow is green. Now prove the host is actually on that commit.
      deployed_head=""
      if ! deployed_head="$(git -C "$APP_DIR" rev-parse HEAD 2>/dev/null)"; then
        finish FAIL 1 "cannot read HEAD of the deployed tree at ${APP_DIR} (expected ${SHA})"
      fi
      if [[ -z "$deployed_head" ]]; then
        finish FAIL 1 "cannot read HEAD of the deployed tree at ${APP_DIR} (expected ${SHA})"
      fi
      if [[ "${deployed_head,,}" != "${SHA,,}" ]]; then
        finish FAIL 1 "deployed tree is on ${deployed_head}, expected ${SHA}"
      fi

      # The tree is right. Last gate: the Backups tile must not be blind while
      # the writer's log holds a success. A probe that could not run leaves the
      # verdict to the probes that did (a skip note on stderr, never a pass).
      if ! check_backup_tile; then
        finish FAIL 1 "${GATE_REASON}"
      fi

      finish PASS 0
      ;;
  esac

  if (( $(date +%s) - START_TS >= DEADLINE_SECONDS )); then
    finish TIMEOUT 1 "no completed run for ${SHA} after $(( DEADLINE_SECONDS / 60 )) minutes"
  fi

  sleep "$POLL_SECONDS"
done
