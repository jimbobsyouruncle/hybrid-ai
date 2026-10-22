#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/prune-docker-cache.sh
# PURPOSE (plain English):
#   Cap the Docker BUILD CACHE so repeated rebuilds of the multi-GB stack
#   images cannot fill the deploy host's disk. Runs from
#   hybrid-ai-docker-prune.timer daily at 04:35.
#
#   CACHE ONLY, by design. The ONLY prune this script ever runs is
#   `docker builder prune`. It never calls `docker rmi`, never runs a container,
#   image, volume, network or system prune, and never deletes a path. Images,
#   running containers, named volumes and bind-mounted data are all out of
#   scope: a wider prune would be a defect, not an enhancement.
#
#   It runs as root because it talks to the Docker socket, exactly like the
#   sibling hybrid-ai-prune.service.
#
# CAPABILITY PROBE (the reason this script exists rather than a one-line unit):
#   There is no single cap flag across Docker versions. Recent buildx documents
#   `docker builder prune --max-used-space`, but that flag has been reported to
#   be a no-op on the embedded dockerd `docker` driver, and older Docker has
#   only `--keep-storage`. So the script READS `docker builder prune --help` at
#   run time and passes the cap flag it actually finds:
#     1. --max-used-space   (preferred when the local help lists it)
#     2. --keep-storage     (fallback for older Docker)
#     3. neither listed     -> log "no supported cache-cap flag" and exit 0.
#   A flag the local help output does not list is NEVER passed, so an unknown
#   Docker does not turn the timer into a hard failure.
#
# CONFIGURATION (environment; also read from the stack .env via the unit's
# EnvironmentFile):
#   HYBRID_AI_BUILD_CACHE_CAP   default 15GB
#       Size cap handed to the probed flag. Only this variable is read; no
#       other .env value is ever printed.
#
# DEGRADED PATHS (all informational, never a failure):
#   docker CLI absent            -> log and exit 0
#   Docker daemon unreachable    -> log and exit 0
#   no supported cap flag        -> log and exit 0
#   df cannot report free space  -> log "unknown" and carry on; free space is
#                                   informational only and NEVER changes the
#                                   exit status.
#
# A genuine `docker builder prune` failure exits 1, so it is visible in
# `systemctl status hybrid-ai-docker-prune`. The unit deliberately has NO
# Restart=: a failing prune must not loop.
#
# USAGE:
#   ./scripts/prune-docker-cache.sh
#
# EXIT CODES:
#   0  capped, or nothing to do (absent CLI, unreachable daemon, no cap flag)
#   1  `docker builder prune` itself failed
# ---------------------------------------------------------------------------
set -euo pipefail

CAP="${HYBRID_AI_BUILD_CACHE_CAP:-15GB}"

log()  { printf '%s [ * ] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
warn() { printf '%s [ ! ] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }

# Free space on the filesystem holding the Docker root. Informational only: the
# caller ignores the result and a failure here never changes the exit status.
log_free_space() {
  local label="$1" avail=""
  avail="$(df -Pk / 2>/dev/null | awk 'NR==2 {printf "%s", $4}')" || avail=""
  if [[ -n "$avail" ]]; then
    log "${label} free-space=${avail}KB"
  else
    log "${label} free-space=unknown"
  fi
}

log "build-cache prune starting (cap=${CAP})"

if ! command -v docker >/dev/null 2>&1; then
  log "docker CLI not found; nothing to prune."
  exit 0
fi

if ! docker info >/dev/null 2>&1; then
  log "docker daemon unreachable (docker info failed); nothing to prune."
  exit 0
fi

# Probe the local help output. A non-zero `--help` is treated as empty help, so
# the no-supported-flag path handles it the same way.
help_out="$(docker builder prune --help 2>&1)" || help_out=""

if [[ "$help_out" == *"--max-used-space"* ]]; then
  cap_flag="--max-used-space"
elif [[ "$help_out" == *"--keep-storage"* ]]; then
  cap_flag="--keep-storage"
else
  log "no supported cache-cap flag in 'docker builder prune --help' (neither --max-used-space nor --keep-storage); nothing to prune."
  exit 0
fi

# --force only when the local help lists it, so an unrecognised flag is never
# passed. Without it the prune would prompt, which a oneshot unit cannot answer.
prune_args=(builder prune)
if [[ "$help_out" == *"--force"* ]]; then
  prune_args+=(--force)
fi
prune_args+=("$cap_flag" "$CAP")

log_free_space "before"
log "running: docker ${prune_args[*]}"

prune_rc=0
docker "${prune_args[@]}" || prune_rc=$?

log_free_space "after"

if (( prune_rc != 0 )); then
  warn "docker builder prune failed (exit ${prune_rc}); the build cache is unchanged."
  exit 1
fi

log "build-cache prune complete (cap=${CAP} flag=${cap_flag}; cache only, no images, containers, volumes or data touched)."
exit 0
