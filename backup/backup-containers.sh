#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: backup/backup-containers.sh
# PURPOSE (plain English):
#   The ONLY part of a system-mode backup that is allowed to talk to Docker.
#   It is run as root (systemd's leading "+" on an Exec line drops every
#   sandbox restriction for that one command) by the capture unit's
#   ExecStartPre/ExecStopPost, and it does exactly three fixed things:
#
#     pause      pause the app containers that write durable state, and record
#                which ones were paused
#     unpause    unpause them again (idempotent; succeeds when nothing is
#                paused)
#     host-info  collect the host facts the capture cannot: docker's version
#                and the local model list
#
# WHY IT EXISTS -- THE PRIVILEGE SPLIT:
#   The capture unit runs as the unprivileged hybrid-ai-backup account with a
#   single capability (CAP_DAC_READ_SEARCH) so it can read the container-owned
#   data, and with PrivateNetwork=yes and the docker socket made inaccessible,
#   so it holds no network and no docker access. The upload unit holds the R2
#   credentials but no read privilege. Neither unit may do the other's job.
#   A tiny, fixed, root-owned helper bridges exactly the one gap: pausing the
#   containers for a point-in-time capture and reading docker's own facts.
#
# WHAT IT WILL NOT DO:
#   * It never STARTs or STOPs a container -- only pause and unpause. Stopping
#     hermes-agent kills in-flight agent sessions (incident B1, 2026-10-15);
#     a pause is a SIGSTOP with no restart.
#   * It takes NO path and NO container name from its arguments. The only
#     argument it accepts is the verb above; the container list is the fixed
#     APP_CONTAINERS set below.
#   * It writes ONLY under /run/hybrid-ai-backup (a root-owned runtime dir).
#   * It refuses to run as a non-root account.
#
# USAGE:
#   backup/backup-containers.sh pause
#   backup/backup-containers.sh unpause
#   backup/backup-containers.sh host-info
#
# EXIT CODES:
#   0  the verb did its work
#   1  not root, or the runtime directory could not be prepared
#   2  usage error (a missing or unknown verb)
# ---------------------------------------------------------------------------
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Every host path comes from the ONE shared helper, exactly as backup.sh does.
# shellcheck source=scripts/lib/hybrid-ai-env.sh
source "${SCRIPT_DIR}/../scripts/lib/hybrid-ai-env.sh"

# The one directory this helper writes to. It matches the units'
# RuntimeDirectory=hybrid-ai-backup (systemd sets that to /run/hybrid-ai-backup).
CONTROL_RUN_DIR="${BACKUP_CONTROL_RUN_DIR:-/run/hybrid-ai-backup}"

# The unprivileged account the capture unit runs as. This helper is root, but
# the files it leaves behind (the paused list, the host facts) are READ by the
# capture unit, so they are made readable by that account. Only names and paths
# here -- never a credential.
SERVICE_USER="hybrid-ai-backup"

# The FIXED list of containers that write durable state. It is the same
# APP_CONTAINERS set backup.sh uses; nothing here is ever taken from an argument.
APP_CONTAINERS=(open-webui hermes-agent)

# Every compose file, so 'config --images' reports the full stack, matching the
# way backup.sh and doctor.sh render it.
COMPOSE=(docker compose -p hybrid-ai --env-file "$HYBRID_AI_STACK_ENV_FILE"
         --project-directory "$HYBRID_AI_APP_DIR"
         -f "$HYBRID_AI_APP_DIR/docker-compose.yml"
         -f "$HYBRID_AI_APP_DIR/openhands/docker-compose.openhands.yml"
         -f "$HYBRID_AI_APP_DIR/hermes/docker-compose.hermes.yml")

log() { printf '[ * ] %s\n' "$*"; }

die() { printf '[ X ] %s\n' "$*" >&2; exit 1; }

is_running() { [[ "$(docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null)" == "running" ]]; }

# Make a path readable by the capture account, when that account exists. The
# helper is root, so it can hand over the paused list and host facts the capture
# unit must read; nothing here is a secret.
hand_to_service() {
  id "$SERVICE_USER" >/dev/null 2>&1 || return 0
  chown -R "${SERVICE_USER}:${SERVICE_USER}" "$1" 2>/dev/null || true
}

ensure_run_dir() {
  mkdir -p "$CONTROL_RUN_DIR" || die "Could not create ${CONTROL_RUN_DIR}."
  chmod 700 "$CONTROL_RUN_DIR" 2>/dev/null || true
  hand_to_service "$CONTROL_RUN_DIR"
}

# pause: pause each durable-state container that is running and record it. The
# recording file is written under the runtime dir and read by the capture unit
# to set CONSISTENCY. A container that is already down is skipped, never started.
cmd_pause() {
  ensure_run_dir
  local paused_file="${CONTROL_RUN_DIR}/paused"
  : > "$paused_file"
  chmod 600 "$paused_file" 2>/dev/null || true
  local c
  for c in "${APP_CONTAINERS[@]}"; do
    is_running "$c" || continue
    if docker pause "$c" >/dev/null 2>&1; then
      printf '%s\n' "$c" >> "$paused_file"
    fi
  done
  hand_to_service "$paused_file"
  return 0
}

# unpause: resume the fixed container set and clear the recording. It is
# idempotent -- unpausing a container that is not paused (or not running) is a
# harmless no-op, so it also succeeds when nothing was paused at all.
cmd_unpause() {
  ensure_run_dir
  local c
  for c in "${APP_CONTAINERS[@]}"; do
    docker unpause "$c" >/dev/null 2>&1 || true
  done
  rm -f "${CONTROL_RUN_DIR}/paused" 2>/dev/null || true
  return 0
}

# host-info: collect the facts the capture unit cannot gather without docker.
# Only docker's server version, the local model names, and the rendered image
# list -- never a secret, never a data-tree path.
cmd_host_info() {
  ensure_run_dir
  local out="${CONTROL_RUN_DIR}/host-info"
  mkdir -p "$out"
  chmod 700 "$out" 2>/dev/null || true

  if command -v docker >/dev/null 2>&1; then
    printf '%s\n' "$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo n/a)" \
      > "${out}/platform-docker.txt" 2>/dev/null || true
  else
    printf 'n/a\n' > "${out}/platform-docker.txt" 2>/dev/null || true
  fi

  if is_running ollama; then
    docker exec ollama ollama list 2>/dev/null \
      | awk 'NR>1 {print $1}' > "${out}/ollama-models.txt" || true
    mkdir -p "${out}/modelfiles"
    local m safe
    while IFS= read -r m; do
      [[ -z "$m" ]] && continue
      safe="${m//[^A-Za-z0-9._-]/_}"
      docker exec ollama ollama show --modelfile "$m" \
        > "${out}/modelfiles/${safe}.Modelfile" 2>/dev/null || true
    done < "${out}/ollama-models.txt"
  fi

  if [[ -f "${HYBRID_AI_ENV_FILE}" ]]; then
    "${COMPOSE[@]}" config --images > "${out}/container-images.txt" 2>/dev/null || true
  fi
  hand_to_service "$out"
  return 0
}

if (( $# != 1 )); then
  printf 'usage: %s pause|unpause|host-info\n' "${0##*/}" >&2
  exit 2
fi

[[ "$(id -u)" == "0" ]] || die "This helper modifies container state and must run as root."

case "$1" in
  pause)     cmd_pause ;;
  unpause)   cmd_unpause ;;
  host-info) cmd_host_info ;;
  *)         printf 'usage: %s pause|unpause|host-info\n' "${0##*/}" >&2; exit 2 ;;
esac
