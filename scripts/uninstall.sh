#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/uninstall.sh
# PURPOSE (plain English):
#   The ONE privileged command that tears the hybrid-ai stack down. It stops
#   and removes the containers, the two Docker networks, the systemd units and
#   the polkit rule, the sandbox-egress firewall rules the stack installed, and
#   the program directory. By DEFAULT it KEEPS the data; pass --remove-data to
#   delete that as well.
#
#   It is RE-RUNNABLE. A second run after a software-only uninstall reports the
#   leftovers and can then remove the data.
#
# KEPT, DELIBERATELY:
#   * every Docker image and the Docker build cache
#   * the hybrid-ai and hybrid-ai-backup system accounts
#   * anything outside the allowlist below; the script refuses to guess
#
# REMOVED:
#   * containers ollama, open-webui, hybrid-ai-status, hybrid-ai-proxy,
#     hermes-agent and hybrid-ai-openhands; on a re-run, the OpenHands
#     sandboxes named oh-agent-server*
#   * Docker networks hybrid-ai and coder-net
#   * the hybrid-ai-* systemd units in /etc/systemd/system, and the login user's
#     hybrid-ai backup and check user units
#   * the polkit rule 50-hybrid-ai-deploy.rules
#   * ONLY the DOCKER-USER rules tagged hybrid-ai-sandbox-egress
#   * /opt/hybrid-ai
#   * with --remove-data: the data, work, log, restic-cache and backup
#     credential directories, and /etc/hybrid-ai
#
# BEFORE YOU START:
#   Disable the GitHub deploy.yml workflow. It runs on every push to main and
#   would re-install the stack on the next push.
#
# USAGE:
#   sudo scripts/uninstall.sh [--dry-run] [--keep-data | --remove-data] [--yes] \
#                             [--login-user <name>]
#
#     --dry-run      print the FULL plan and change nothing
#     --keep-data    keep the data directories (the default)
#     --remove-data  also remove the data directories
#     --yes          skip the interactive confirmation; the KEEP default stays
#     --login-user   the login account whose user units are disabled.
#                    Defaults to SUDO_USER.
#     -h | --help    print this header and exit 0
#
# TEST-ONLY:
#   HYBRID_AI_UNINSTALL_ROOT  a filesystem prefix for the offline test. UNSET
#                             means "/" (the real filesystem), the default.
#                             scripts/test-uninstall.sh sets it to a scratch
#                             tree, so the whole script runs with no root, no
#                             Docker and no systemd.
#
# SECURITY:
#   No value from .env, stack.env or the credential store is ever read or
#   printed. Only names and paths reach the output. This script never calls
#   sudo, and it never flushes or deletes an iptables chain.
#
# EXIT CODES:
#   0  success, including a no-change re-run and a dry run
#   1  usage error
#   2  not run as root
# ---------------------------------------------------------------------------
set -Eeuo pipefail

# --- Output helpers --------------------------------------------------------
if [[ -t 1 ]]; then
  C_RST=$'\033[0m'; C_INF=$'\033[36m'; C_OK=$'\033[32m'
  C_WRN=$'\033[33m'; C_ERR=$'\033[31m'
else
  C_RST=""; C_INF=""; C_OK=""; C_WRN=""; C_ERR=""
fi
log()  { printf '%s[ * ]%s %s\n' "$C_INF" "$C_RST" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_OK"  "$C_RST" "$*"; }
warn() { printf '%s[ ! ]%s %s\n' "$C_WRN" "$C_RST" "$*" >&2; }
die()  { local code="$1"; shift; printf '%s[ X ]%s %s\n' "$C_ERR" "$C_RST" "$*" >&2; exit "$code"; }
hr()   { printf '%s%s%s\n' "$C_RST" "------------------------------------------------------------" "$C_RST"; }

usage() { awk 'NR==1{next} /^set -Eeuo pipefail/{exit} {sub(/^# ?/,""); print}' "${BASH_SOURCE[0]}"; }

# A glob that matches nothing expands to nothing rather than to itself, so the
# hybrid-ai-* unit sweep below cannot try to remove a literal "hybrid-ai-*".
shopt -s nullglob

# --- Test-only filesystem prefix -------------------------------------------
# UNSET (the default) means "/", the real filesystem. scripts/test-uninstall.sh
# sets HYBRID_AI_UNINSTALL_ROOT to a scratch directory so the whole script can
# be exercised with no root, no Docker and no systemd.
ROOT_PREFIX="${HYBRID_AI_UNINSTALL_ROOT:-/}"
[[ "$ROOT_PREFIX" == /* ]] || { printf 'uninstall: HYBRID_AI_UNINSTALL_ROOT must be an absolute path.\n' >&2; exit 1; }
ROOT_PREFIX="${ROOT_PREFIX%/}"
# Prefix a host path. With ROOT_PREFIX empty (the default "/") this is the
# identity. A path that already sits under the prefix is returned unchanged, so
# the prefix is never applied twice.
host_path() {
  local p="$1"
  if [[ -n "$ROOT_PREFIX" && ( "$p" == "$ROOT_PREFIX" || "$p" == "$ROOT_PREFIX"/* ) ]]; then
    printf '%s' "$p"
    return 0
  fi
  printf '%s' "${ROOT_PREFIX}$p"
}

# --- Argument parsing ------------------------------------------------------
# Parsed BEFORE the root check, so --help works for anyone and --dry-run is
# understood before anything is inspected.
DRY_RUN=0
DATA_CHOICE=""
ASSUME_YES=0
LOGIN_USER=""

while (( $# > 0 )); do
  case "$1" in
    --dry-run)      DRY_RUN=1; shift ;;
    --keep-data)    DATA_CHOICE="keep"; shift ;;
    --remove-data)  DATA_CHOICE="remove"; shift ;;
    --yes|-y)       ASSUME_YES=1; shift ;;
    --login-user)
      [[ -n "${2:-}" ]] || die 1 "--login-user needs a value (see --help)"
      LOGIN_USER="$2"; shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    *) die 1 "unknown argument: $1 (see --help)" ;;
  esac
done

# --- Privilege -------------------------------------------------------------
# Root only. There is deliberately no bypass flag: the harness runs with a
# stubbed `id` instead. This script never calls sudo.
[[ "$(id -u)" == "0" ]] || die 2 "must run as root: sudo scripts/uninstall.sh"

LOGIN_USER="${LOGIN_USER:-${SUDO_USER:-}}"

# --- Fixed host paths (FHS defaults) ---------------------------------------
APP_DIR="$(host_path /opt/hybrid-ai)"
ETC_DIR="$(host_path /etc/hybrid-ai)"
LAYOUT_ENV="${ETC_DIR}/hybrid-ai.env"
STACK_ENV="${ETC_DIR}/stack.env"
SYSTEMD_DIR="$(host_path /etc/systemd/system)"
POLKIT_DIRS=( "$(host_path /etc/polkit-1/rules.d)" "$(host_path /usr/share/polkit-1/rules.d)" )
POLKIT_RULE="50-hybrid-ai-deploy.rules"
DATA_DIR="$(host_path /var/lib/hybrid-ai)"
LOG_DIR="$(host_path /var/log/hybrid-ai)"
WORK_DIR="${DATA_DIR}/work"
RESTIC_CACHE="$(host_path /var/cache/hybrid-ai-backup)"
CRED_DIR="$(host_path /etc/credstore/hybrid-ai-backup)"

# --- Layout-file reader (PARSE, never source) ------------------------------
# Read ONE key from a layout file, line by line. The value is DATA, never code,
# and it is never printed. Last match wins, matching scripts/lib/hybrid-ai-env.sh.
parse_env_value() { # file key
  local file="$1" key="$2" line candidate=""
  if [[ ! -f "$file" || ! -r "$file" ]]; then
    printf ''
    return 0
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*${key}=(.*)$ ]] || continue
    candidate="${BASH_REMATCH[1]}"
    candidate="${candidate%\"}"; candidate="${candidate#\"}"
    candidate="${candidate%\'}"; candidate="${candidate#\'}"
  done < "$file"
  printf '%s' "$candidate"
}

# Apply one layout setting over a default. A relative value is refused with a
# message naming the SETTING; the value itself is never printed.
apply_layout_setting() { # varname setting
  local var="$1" name="$2" v
  v="$(parse_env_value "$LAYOUT_ENV" "$name")"
  [[ -n "$v" ]] || return 0
  case "$v" in
    /*) printf -v "$var" '%s' "$v" ;;
    *)  warn "${name} is not an absolute path; ignoring it." ;;
  esac
  return 0
}

# Resolve every path. When a clone is present its own env library is the single
# source of truth; without a clone, fall back to the FHS defaults and the
# readable layout file.
resolve_paths() {
  local clone_lib="${APP_DIR}/scripts/lib/hybrid-ai-env.sh"
  if [[ -r "$clone_lib" ]]; then
    # Point the library's fallback probe at this run's layout file. With
    # ROOT_PREFIX "/" this equals the built-in default, so it is a no-op there.
    export HYBRID_AI_ENV_FILE_FALLBACK="$LAYOUT_ENV"
    # The path is dynamic (it comes from the resolved app dir), so tell the
    # linter to skip following it rather than name a literal relative path.
    # shellcheck source=/dev/null
    source "$clone_lib"
    APP_DIR="$(host_path "$HYBRID_AI_APP_DIR")"
    DATA_DIR="$(host_path "$HYBRID_AI_DATA_DIR")"
    LOG_DIR="$(host_path "$HYBRID_AI_LOG_DIR")"
    WORK_DIR="$(host_path "$HYBRID_AI_WORK_DIR")"
    LAYOUT_ENV="$(host_path "$HYBRID_AI_ENV_FILE")"
    ETC_DIR="$(dirname "$LAYOUT_ENV")"
    STACK_ENV="$(host_path "$HYBRID_AI_STACK_ENV_FILE")"
    if [[ -n "${RESTIC_CACHE_DIR:-}" ]]; then
      RESTIC_CACHE="$(host_path "$RESTIC_CACHE_DIR")"
    fi
    if [[ -n "${HYBRID_AI_BACKUP_CRED_DIR:-}" ]]; then
      CRED_DIR="$(host_path "$HYBRID_AI_BACKUP_CRED_DIR")"
    fi
    return 0
  fi

  warn "no clone at ${APP_DIR}; using the built-in FHS defaults and parsing ${LAYOUT_ENV}"
  apply_layout_setting APP_DIR      HYBRID_AI_APP_DIR
  apply_layout_setting DATA_DIR     HYBRID_AI_DATA_DIR
  apply_layout_setting LOG_DIR      HYBRID_AI_LOG_DIR
  apply_layout_setting WORK_DIR     HYBRID_AI_WORK_DIR
  apply_layout_setting RESTIC_CACHE RESTIC_CACHE_DIR
  apply_layout_setting CRED_DIR     HYBRID_AI_BACKUP_CRED_DIR
  apply_layout_setting STACK_ENV    HYBRID_AI_STACK_ENV_FILE
  APP_DIR="$(host_path "$APP_DIR")"
  DATA_DIR="$(host_path "$DATA_DIR")"
  LOG_DIR="$(host_path "$LOG_DIR")"
  WORK_DIR="$(host_path "$WORK_DIR")"
  RESTIC_CACHE="$(host_path "$RESTIC_CACHE")"
  CRED_DIR="$(host_path "$CRED_DIR")"
  STACK_ENV="$(host_path "$STACK_ENV")"
  return 0
}

resolve_paths

# --- What we are allowed to remove -----------------------------------------
# An exact prefix list. Anything a layout file names outside it is refused and
# left untouched. The two trailing glob prefixes mirror the documented
# /var/lib/hybrid-ai* and /var/log/hybrid-ai* allowlist entries.
ALLOW_EXACT=(
  "$(host_path /opt/hybrid-ai)"
  "$(host_path /var/cache/hybrid-ai-backup)"
  "$(host_path /etc/hybrid-ai)"
  "$(host_path /etc/credstore/hybrid-ai-backup)"
)
ALLOW_GLOB=(
  "$(host_path /var/lib/hybrid-ai)"
  "$(host_path /var/log/hybrid-ai)"
)

allowlisted_path() { # path
  local p="$1" pre
  for pre in "${ALLOW_EXACT[@]}"; do
    if [[ "$p" == "$pre" || "$p" == "$pre"/* ]]; then return 0; fi
  done
  for pre in "${ALLOW_GLOB[@]}"; do
    if [[ "$p" == "$pre"* ]]; then return 0; fi
  done
  return 1
}

# --- The explicit inventories ----------------------------------------------
COMPOSE_FILES=(
  "${APP_DIR}/docker-compose.yml"
  "${APP_DIR}/openhands/docker-compose.openhands.yml"
  "${APP_DIR}/hermes/docker-compose.hermes.yml"
)
CONTAINER_NAMES=( ollama open-webui hybrid-ai-status hybrid-ai-proxy hermes-agent hybrid-ai-openhands )
SANDBOX_FILTER="oh-agent-server"
NETWORKS=( hybrid-ai coder-net )
SYSTEM_UNITS=(
  hybrid-ai-firewall.service
  hybrid-ai-prune.service
  hybrid-ai-prune.timer
  hybrid-ai-deploy@.service
  hybrid-ai-backup-capture.service
  hybrid-ai-backup-capture.timer
  hybrid-ai-backup-check.service
  hybrid-ai-backup-check.timer
  hybrid-ai-backup-upload.service
)
USER_UNITS=(
  hybrid-ai-backup.service
  hybrid-ai-backup.timer
  hybrid-ai-check.service
  hybrid-ai-check.timer
)
FIREWALL_CHAIN="DOCKER-USER"
FIREWALL_TAG="hybrid-ai-sandbox-egress"
IPT_LOCK_WAIT="5"
IPT=( iptables -w "$IPT_LOCK_WAIT" )

# The data directories, each with the setting that named it, so a refusal can
# name the setting.
DATA_SETTINGS=( HYBRID_AI_DATA_DIR HYBRID_AI_WORK_DIR HYBRID_AI_LOG_DIR \
                RESTIC_CACHE_DIR HYBRID_AI_BACKUP_CRED_DIR HYBRID_AI_ENV_FILE )
DATA_PATHS=( "$DATA_DIR" "$WORK_DIR" "$LOG_DIR" "$RESTIC_CACHE" "$CRED_DIR" "$ETC_DIR" )
DATA_ALLOWED=()
REMOVE_DATA=0

build_removal_plan() {
  local i
  DATA_ALLOWED=()
  for (( i = 0; i < ${#DATA_PATHS[@]}; i++ )); do
    if allowlisted_path "${DATA_PATHS[i]}"; then
      DATA_ALLOWED+=(1)
    else
      DATA_ALLOWED+=(0)
    fi
  done
  return 0
}

build_removal_plan

# --- Small capability probes -----------------------------------------------
have_docker()    { command -v docker    >/dev/null 2>&1; }
have_systemctl() { command -v systemctl >/dev/null 2>&1; }
account_uid()    { getent passwd "$1" 2>/dev/null | cut -d: -f3; }

# In --dry-run, print the action instead of running it.
act() {
  if (( DRY_RUN )); then
    printf '      [plan] %s\n' "$*"
    return 0
  fi
  "$@"
}

# --- Detection -------------------------------------------------------------
# Reported BEFORE any action. Three states: an existing install, remnants only,
# or nothing at all.
STATE=""
REMNANTS=()

install_present() {
  local f
  for f in "${COMPOSE_FILES[@]}"; do
    if [[ ! -f "$f" ]]; then return 1; fi
  done
  return 0
}

find_remnants() {
  local p d
  REMNANTS=()
  for p in "$DATA_DIR" "$WORK_DIR" "$LOG_DIR" "$RESTIC_CACHE" "$CRED_DIR" "$ETC_DIR"; do
    if [[ -e "$p" ]]; then REMNANTS+=("$p"); fi
  done
  for d in "${POLKIT_DIRS[@]}"; do
    if [[ -e "${d}/${POLKIT_RULE}" ]]; then REMNANTS+=("${d}/${POLKIT_RULE}"); fi
  done
  for p in "${SYSTEMD_DIR}"/hybrid-ai-*; do
    REMNANTS+=("$p")
  done
  return 0
}

detect_state() {
  if install_present; then
    STATE="existing"
  else
    find_remnants
    if (( ${#REMNANTS[@]} > 0 )); then
      STATE="remnants"
    else
      STATE="none"
    fi
  fi
  return 0
}

report_detection() {
  hr; log "Detecting the hybrid-ai stack"; hr
  case "$STATE" in
    existing)
      ok "existing install: ${APP_DIR} (all three compose files are present)"
      ;;
    remnants)
      warn "remnants only: no install at ${APP_DIR}, but these remain:"
      local p
      for p in "${REMNANTS[@]}"; do printf '      %s\n' "$p"; done
      ;;
    none)
      ok "nothing found: no install at ${APP_DIR} and no remnants under the data directories, /etc or systemd. Nothing to do."
      ;;
  esac
  return 0
}

report_data_paths() {
  local i
  hr; log "Data directories (KEPT by default)"; hr
  for (( i = 0; i < ${#DATA_PATHS[@]}; i++ )); do
    if [[ "${DATA_ALLOWED[i]}" == "1" ]]; then
      printf '      %s\n' "${DATA_PATHS[i]}"
    else
      warn "refusing to remove ${DATA_PATHS[i]} (setting ${DATA_SETTINGS[i]}): outside the allowlist. It is left untouched."
    fi
  done
  return 0
}

# --- The KEEP-vs-remove decision -------------------------------------------
decide_data() {
  local p ans
  if (( DRY_RUN )); then
    if [[ "$DATA_CHOICE" == "remove" ]]; then
      printf '      [plan] remove the data directories listed above\n'
    else
      printf '      [plan] keep the data directories listed above (default)\n'
    fi
    return 0
  fi
  if [[ "$DATA_CHOICE" == "remove" ]]; then REMOVE_DATA=1; ok "data: will be removed (--remove-data)"; return 0; fi
  if [[ "$DATA_CHOICE" == "keep" ]];   then REMOVE_DATA=0; ok "data: will be kept (--keep-data)";     return 0; fi
  if (( ASSUME_YES )); then REMOVE_DATA=0; ok "data: will be kept (--yes; the default is KEEP)"; return 0; fi
  if [[ ! -t 0 ]]; then REMOVE_DATA=0; ok "data: will be kept (not a terminal; the default is KEEP)"; return 0; fi

  printf 'Remove these data directories too? [y/N] '
  ans=""
  read -r ans || ans=""
  case "$ans" in
    y|Y|yes|YES) REMOVE_DATA=1; ok "data: will be removed" ;;
    *)           REMOVE_DATA=0; ok "data: will be kept" ;;
  esac
  return 0
}

# --- Step: stop the scheduled jobs and the boot firewall unit --------------
# This runs FIRST, before the containers go, so no timer fires mid-teardown.
step_stop_units() {
  local u uid_num
  hr; log "Stopping the scheduled jobs and the boot firewall unit"; hr
  if ! have_systemctl; then
    warn "systemctl is unavailable; skipping the system unit inventory."
  else
    for u in "${SYSTEM_UNITS[@]}"; do
      case "$u" in
        *@.*) act systemctl disable "$u"      || warn "could not disable ${u} (it may not be installed)" ;;
        *)    act systemctl disable --now "$u" || warn "could not disable ${u} (it may not be installed)" ;;
      esac
    done
  fi

  if [[ -z "$LOGIN_USER" ]]; then
    warn "no --login-user and SUDO_USER is unset; skipping the user units."
    return 0
  fi
  uid_num="$(account_uid "$LOGIN_USER")"
  if [[ -z "$uid_num" ]]; then
    warn "could not resolve the uid for ${LOGIN_USER}; skipping the user units."
    return 0
  fi
  for u in "${USER_UNITS[@]}"; do
    act runuser -u "$LOGIN_USER" -- env "XDG_RUNTIME_DIR=/run/user/${uid_num}" \
      systemctl --user disable --now "$u" \
      || warn "could not disable the ${LOGIN_USER} user unit ${u} (it may not be installed)"
  done
  return 0
}

# --- Step: containers ------------------------------------------------------
step_containers() {
  hr; log "Removing the containers"; hr
  if [[ "$STATE" == "existing" ]]; then
    # The SAME compose shape install.sh uses: one env file, the project
    # directory, and the three files in the same order.
    local -a compose=( docker compose --env-file "$STACK_ENV" --project-directory "$APP_DIR" \
      -f "$APP_DIR/docker-compose.yml" \
      -f "$APP_DIR/openhands/docker-compose.openhands.yml" \
      -f "$APP_DIR/hermes/docker-compose.hermes.yml" )
    if (( DRY_RUN )); then
      printf '      [plan] %s down --remove-orphans\n' "${compose[*]}"
      return 0
    fi
    if ! have_docker; then warn "docker is unavailable; skipping container removal."; return 0; fi
    "${compose[@]}" down --remove-orphans || warn "docker compose down reported a problem; continuing."
    return 0
  fi

  # Remnants: remove the known containers by NAME, then the sandboxes. No
  # compose call, and no filter that could match anything else.
  if (( DRY_RUN )); then
    printf '      [plan] docker rm -f %s\n' "${CONTAINER_NAMES[*]}"
    printf '      [plan] docker ps -aq --filter name=%s | xargs -r docker rm -f\n' "$SANDBOX_FILTER"
    return 0
  fi
  if ! have_docker; then warn "docker is unavailable; skipping container removal."; return 0; fi
  docker rm -f "${CONTAINER_NAMES[@]}" || warn "some containers were already gone; continuing."
  docker ps -aq --filter "name=$SANDBOX_FILTER" | xargs -r docker rm -f \
    || warn "the sandbox sweep reported a problem; continuing."
  return 0
}

# --- Step: networks --------------------------------------------------------
step_networks() {
  local n
  hr; log "Removing the Docker networks"; hr
  if ! have_docker; then warn "docker is unavailable; skipping network removal."; return 0; fi
  for n in "${NETWORKS[@]}"; do
    if (( DRY_RUN )); then
      printf '      [plan] docker network rm %s\n' "$n"
      continue
    fi
    docker network rm "$n" >/dev/null 2>&1 \
      || warn "could not remove network ${n} (already gone, or still in use)."
  done
  return 0
}

# --- Step: unit files and the polkit rule ----------------------------------
step_remove_unit_files() {
  local f base d
  hr; log "Removing the systemd unit files and the polkit rule"; hr
  if [[ -d "$SYSTEMD_DIR" ]]; then
    for f in "${SYSTEMD_DIR}"/hybrid-ai-*; do
      base="$(basename "$f")"
      if [[ "$base" != hybrid-ai-* ]]; then continue; fi
      if [[ "$(dirname "$f")" != "$SYSTEMD_DIR" ]]; then continue; fi
      if (( DRY_RUN )); then
        printf '      [plan] rm -rf %s\n' "$f"
        continue
      fi
      rm -rf -- "$f" || warn "could not remove ${f}"
    done
  fi
  for d in "${POLKIT_DIRS[@]}"; do
    f="${d}/${POLKIT_RULE}"
    if [[ ! -e "$f" ]]; then continue; fi
    if (( DRY_RUN )); then
      printf '      [plan] rm -f %s\n' "$f"
      continue
    fi
    rm -f -- "$f" || warn "could not remove ${f}"
  done
  return 0
}

step_reload_systemd() {
  if ! have_systemctl; then
    warn "systemctl is unavailable; skipping daemon-reload and the polkit reload."
    return 0
  fi
  act systemctl daemon-reload || warn "systemctl daemon-reload failed; units may linger in memory."
  if (( DRY_RUN )); then
    printf '      [plan] systemctl reload polkit\n'
    return 0
  fi
  systemctl reload polkit >/dev/null 2>&1 || systemctl restart polkit >/dev/null 2>&1 \
    || warn "could not reload polkit; reload it by hand: systemctl reload polkit"
  return 0
}

# --- Step: firewall --------------------------------------------------------
# Delete ONLY the DOCKER-USER rules whose comment is exactly the tag this stack
# installs. Never flush the chain, never delete the chain, never touch an
# untagged rule.
step_firewall() {
  local listing line body i tagged
  local -a toks rule
  hr; log "Removing the sandbox-egress firewall rules (tagged ${FIREWALL_TAG} only)"; hr
  if ! command -v iptables >/dev/null 2>&1; then
    warn "iptables is not installed; skipping the sandbox-egress rules. The exit code is unchanged."
    return 0
  fi
  if ! listing="$("${IPT[@]}" -S "$FIREWALL_CHAIN" 2>/dev/null)"; then
    warn "the ${FIREWALL_CHAIN} chain does not exist; skipping the sandbox-egress rules. The exit code is unchanged."
    return 0
  fi

  while IFS= read -r line; do
    [[ "$line" == "-A ${FIREWALL_CHAIN} "* ]] || continue
    body="${line#"-A ${FIREWALL_CHAIN} "}"
    read -r -a toks <<< "$body"
    tagged=0
    for (( i = 0; i < ${#toks[@]}; i++ )); do
      if [[ "${toks[i]}" == "--comment" && "${toks[i+1]:-}" == "$FIREWALL_TAG" ]]; then
        tagged=1
        break
      fi
    done
    if (( tagged == 0 )); then continue; fi
    if (( DRY_RUN )); then
      printf '      [plan] iptables -w %s -D %s %s\n' "$IPT_LOCK_WAIT" "$FIREWALL_CHAIN" "$body"
      continue
    fi
    read -r -a rule <<< "$body"
    "${IPT[@]}" -D "$FIREWALL_CHAIN" "${rule[@]}" \
      || warn "iptables refused to delete one tagged rule; continuing."
  done <<< "$listing"
  return 0
}

# --- Step: the program directory -------------------------------------------
step_remove_app_dir() {
  hr; log "Removing the program directory"; hr
  if ! allowlisted_path "$APP_DIR"; then
    warn "refusing to remove ${APP_DIR} (setting HYBRID_AI_APP_DIR): outside the allowlist. It is left untouched."
    return 0
  fi
  if [[ ! -e "$APP_DIR" ]]; then
    ok "already gone: ${APP_DIR}"
    return 0
  fi
  # Leave the current directory before removing anything, so the script can
  # never delete its own working directory mid-run.
  cd / || true
  if (( DRY_RUN )); then
    printf '      [plan] rm -rf %s\n' "$APP_DIR"
    return 0
  fi
  rm -rf -- "$APP_DIR" || warn "could not remove ${APP_DIR}"
  return 0
}

# --- Step: the data directories --------------------------------------------
step_remove_data() {
  local i p
  hr; log "Data directories"; hr
  for (( i = 0; i < ${#DATA_PATHS[@]}; i++ )); do
    p="${DATA_PATHS[i]}"
    if [[ "${DATA_ALLOWED[i]}" != "1" ]]; then
      warn "refusing to remove ${p} (setting ${DATA_SETTINGS[i]}): outside the allowlist. It is left untouched."
      continue
    fi
    if (( ! REMOVE_DATA )); then
      ok "kept: ${p}"
      continue
    fi
    if [[ ! -e "$p" ]]; then
      ok "already gone: ${p}"
      continue
    fi
    if (( DRY_RUN )); then
      printf '      [plan] rm -rf %s\n' "$p"
      continue
    fi
    rm -rf -- "$p" || warn "could not remove ${p}"
  done
  return 0
}

# --- Main ------------------------------------------------------------------
detect_state
report_detection

if [[ "$STATE" == "none" ]]; then
  exit 0
fi

report_data_paths
decide_data

step_stop_units
step_containers
step_networks
step_remove_unit_files
step_reload_systemd
step_firewall
step_remove_app_dir
step_remove_data

hr
if (( DRY_RUN )); then
  ok "--dry-run: nothing was changed."
else
  ok "Teardown complete. Images, the Docker build cache and the hybrid-ai system accounts were kept."
fi
hr
