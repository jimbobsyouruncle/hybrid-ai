#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: backup/backup-containers.sh
# PURPOSE (plain English):
#   The ONE privileged step of a system-mode backup. It is the only part of the
#   backup that runs as root, and it does exactly three small, fixed things:
#
#     pause       pause the durable-state containers and record which ones were
#                 paused, so the capture unit can describe CONSISTENCY.
#     unpause     resume those containers. Idempotent: it succeeds even when
#                 nothing is paused, so it is safe to run from ExecStopPost even
#                 if the capture never got as far as pausing.
#     host-info   gather the few host facts that need docker/systemctl
#                 (container images, ollama models, docker version) into a
#                 directory the unprivileged capture unit can read.
#
# WHY IT EXISTS (the privilege split):
#   The capture unit runs as the dedicated `hybrid-ai-backup` account with
#   CAP_DAC_READ_SEARCH and NO network and NO credentials. Pausing a container
#   needs the docker socket, which would hand that account the whole docker
#   API. So the privileged docker work is isolated here, in a tiny helper that
#   is invoked by systemd with a leading '+', while the capture unit itself
#   never touches the socket.
#
# WHAT IT DELIBERATELY DOES NOT DO:
#   * It never STOPS or STARTS a container. It only pauses and unpauses. A
#     stopped container cannot be a point-in-time freeze, and stopping
#     hermes-agent kills in-flight agent sessions (incident B1, 2026-10-15).
#   * It never takes a path, a directory or a container name from its
#     arguments. The only argument it accepts is the verb. The container list
#     is fixed below and the write location is fixed below.
#   * It writes ONLY under /run/hybrid-ai-backup.
#
# USAGE:
#   backup/backup-containers.sh pause
#   backup/backup-containers.sh unpause
#   backup/backup-containers.sh host-info
#
# It must run as root. Any other user is refused.
# ---------------------------------------------------------------------------
set -Eeuo pipefail

# --- Fixed, non-negotiable locations ---------------------------------------
# No path and no container name is ever taken from an argument. The default is
# the fixed /run/hybrid-ai-backup; HYBRID_AI_BACKUP_RUN_DIR may override it ONLY
# so the offline test suite can point at a scratch directory. The override
# changes no privilege and the helper still refuses to run as a non-root user.
RUN_DIR="${HYBRID_AI_BACKUP_RUN_DIR:-/run/hybrid-ai-backup}"
PAUSED_FILE="${RUN_DIR}/paused"
HOST_INFO_DIR="${RUN_DIR}/host-info"

# The containers that write durable state. This list MUST stay identical to
# APP_CONTAINERS in backup/backup.sh; a test asserts that they match. The set is
# fixed here so a stray argument can never widen it.
APP_CONTAINERS=(open-webui hermes-agent)

# The account the capture/upload units run as. Used only to hand the run
# directory to that account so the unprivileged capture can read what root
# wrote. If the account does not exist yet (card F has not run), the directory
# stays root-only, which is still safe.
BACKUP_USER="hybrid-ai-backup"

usage() {
  printf 'usage: %s pause|unpause|host-info\n' "$(basename -- "${BASH_SOURCE[0]}")" >&2
}

# --- Argument: the verb only ------------------------------------------------
if [[ $# -ne 1 ]]; then
  usage
  exit 2
fi
VERB="$1"
case "$VERB" in
  pause|unpause|host-info) ;;
  *) usage; exit 2 ;;
esac

# --- Root only --------------------------------------------------------------
if [[ "$(id -u)" != "0" ]]; then
  printf '%s must run as root.\n' "$(basename -- "${BASH_SOURCE[0]}")" >&2
  exit 1
fi

mkdir -p "$RUN_DIR"
chmod 0700 "$RUN_DIR" 2>/dev/null || true

# Hand the run directory to the backup account so the unprivileged capture unit
# can read the paused list and the host info. Done after every write below too.
hand_over_run_dir() {
  if id -u "$BACKUP_USER" >/dev/null 2>&1; then
    chown -R "${BACKUP_USER}" "$RUN_DIR" 2>/dev/null || true
  fi
  chmod 0700 "$RUN_DIR" 2>/dev/null || true
}

is_running() { [[ "$(docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null)" == "running" ]]; }

# --- pause ------------------------------------------------------------------
# Pause every fixed app container that is running, and record exactly those in
# PAUSED_FILE. The file is rewritten each run, so a stale list cannot linger.
do_pause() {
  : > "$PAUSED_FILE"
  chmod 0644 "$PAUSED_FILE" 2>/dev/null || true
  local c
  for c in "${APP_CONTAINERS[@]}"; do
    is_running "$c" || continue
    if docker pause "$c" >/dev/null 2>&1; then
      printf '%s\n' "$c" >> "$PAUSED_FILE"
    fi
  done
}

# --- unpause ----------------------------------------------------------------
# Resume every fixed app container. Idempotent: unpausing a container that is
# not paused fails, which is ignored, so this always succeeds. It removes the
# paused list so a later capture cannot read a stale one.
do_unpause() {
  local c
  for c in "${APP_CONTAINERS[@]}"; do
    docker unpause "$c" >/dev/null 2>&1 || true
  done
  rm -f "$PAUSED_FILE" 2>/dev/null || true
}

# --- host-info --------------------------------------------------------------
# Gather host facts that need docker/systemctl. backup.sh copies this directory
# into staging/host when BACKUP_CONTAINER_CONTROL=external, because in that mode
# backup.sh runs no docker command at all.
do_host_info() {
  rm -rf "$HOST_INFO_DIR"
  mkdir -p "$HOST_INFO_DIR"
  chmod 0700 "$HOST_INFO_DIR" 2>/dev/null || true

  # Resolve the stack paths from the ONE shared helper, exactly as backup.sh
  # does. HYBRID_AI_ENV_FILE is set by the unit (Environment=).
  local lib_dir
  lib_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../scripts/lib" && pwd)"
  # shellcheck source=scripts/lib/hybrid-ai-env.sh
  source "${lib_dir}/hybrid-ai-env.sh"

  local compose=(
    docker compose -p hybrid-ai --env-file "$HYBRID_AI_ENV_FILE"
    --project-directory "$HYBRID_AI_APP_DIR"
    -f "$HYBRID_AI_APP_DIR/docker-compose.yml"
    -f "$HYBRID_AI_APP_DIR/openhands/docker-compose.openhands.yml"
    -f "$HYBRID_AI_APP_DIR/hermes/docker-compose.hermes.yml"
  )

  if [[ -f "$HYBRID_AI_ENV_FILE" ]]; then
    "${compose[@]}" config --images > "${HOST_INFO_DIR}/container-images.txt" 2>/dev/null || true
  fi

  if is_running ollama; then
    docker exec ollama ollama list 2>/dev/null \
      | awk 'NR>1 {print $1}' > "${HOST_INFO_DIR}/ollama-models.txt" || true
    mkdir -p "${HOST_INFO_DIR}/modelfiles"
    local m safe
    while IFS= read -r m; do
      [[ -z "$m" ]] && continue
      safe="${m//[^A-Za-z0-9._-]/_}"
      docker exec ollama ollama show --modelfile "$m" \
        > "${HOST_INFO_DIR}/modelfiles/${safe}.Modelfile" 2>/dev/null || true
    done < "${HOST_INFO_DIR}/ollama-models.txt"
  fi

  # backup.sh reads the docker= line from this file and then writes its own
  # platform.txt over the copy in staging, so only docker= and the timer state
  # matter here.
  {
    printf 'docker=%s\n'       "$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo n/a)"
    printf 'backup_timer=%s\n' "$(systemctl is-enabled hybrid-ai-backup-capture.timer 2>/dev/null || echo unknown)"
  } > "${HOST_INFO_DIR}/platform.txt" 2>/dev/null || true

  chmod -R go-rwx "$HOST_INFO_DIR" 2>/dev/null || true
}

case "$VERB" in
  pause)     do_pause ;;
  unpause)   do_unpause ;;
  host-info) do_host_info ;;
esac

hand_over_run_dir
exit 0
