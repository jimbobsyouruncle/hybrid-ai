#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/setup-agent-workspace.sh
# PURPOSE (plain English):
#   Creates and maintains the SEPARATE clone of this repository that OpenHands
#   works in. Called by install.sh; safe to run by hand at any time.
#
# WHY A SEPARATE CLONE EXISTS (the whole point of this file):
#   OpenHands mounts its workspace read-write and the sandbox runs as YOUR uid.
#   If that workspace were the deployment directory, the sandbox could read:
#
#       .env            RunPod API key, Open WebUI session key
#       install.log     deployment metadata
#       backup.log      backup history
#
#   File permissions would not help. 0600 means "readable by your user", and
#   the sandbox IS your user.
#
#   That matters because the sandbox is the component that processes UNTRUSTED
#   text: log files, diagnostic bundles, issue bodies, repository content.
#   AGENTS.md instructs the agent to treat that text as data rather than
#   instructions -- but an instruction is a mitigation. A clone is a boundary.
#
#   Secondary benefit, unrelated to security: the agent never edits files
#   underneath a running stack. You review, then pull into the deployment
#   directory deliberately.
#
# WHAT IT DOES:
#   1. Works out where the clone should live and where it came from.
#   2. REFUSES to proceed if the target is, or is inside, the deployment dir.
#   3. Creates the clone if missing; updates its origin if it already exists,
#      then refreshes it so the root copy of AGENTS.md does not go stale.
#   4. Verifies no .env or log file leaked into it.
#
# HOW TO RUN IT:
#   ./scripts/setup-agent-workspace.sh                    interactive
#   ./scripts/setup-agent-workspace.sh --non-interactive  for CI / install.sh
#   ./scripts/setup-agent-workspace.sh --check            verify only
# ---------------------------------------------------------------------------
set -Eeuo pipefail

# Every host path comes from the ONE shared helper. With no settings, the
# resolved paths are exactly today's.
HYBRID_AI_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/lib" && pwd)"
# shellcheck source=scripts/lib/hybrid-ai-env.sh
source "${HYBRID_AI_LIB_DIR}/hybrid-ai-env.sh"

NON_INTERACTIVE=0
CHECK_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --non-interactive) NON_INTERACTIVE=1 ;;
    --check)           CHECK_ONLY=1 ;;
    -h|--help)
      sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

# --- Output helpers (match install.sh conventions) -------------------------
if [[ -t 1 ]]; then
  C_RST=$'\033[0m'; C_INF=$'\033[36m'; C_OK=$'\033[32m'
  C_WRN=$'\033[33m'; C_ERR=$'\033[31m'
else
  C_RST=""; C_INF=""; C_OK=""; C_WRN=""; C_ERR=""
fi
log()  { printf '%s[ * ]%s %s\n'  "$C_INF" "$C_RST" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_OK"  "$C_RST" "$*"; }
warn() { printf '%s[ ! ]%s %s\n'  "$C_WRN" "$C_RST" "$*" >&2; }
die()  { printf '%s[ X ]%s %s\n'  "$C_ERR" "$C_RST" "$*" >&2; exit 1; }

# --- Work out the target ---------------------------------------------------
# Default: a SIBLING of the deployment directory, never inside it. Inside would
# mean the agent's clone is itself swept up by backups, diagnostics and
# git status -- and the env file would sit one directory traversal away.
# OPENHANDS_WORKSPACE is resolved by the shared helper (environment, then the
# env file parsed line by line, then the default), so nothing is parsed twice.
DEFAULT_WORKSPACE="${HOME}/hybrid-ai-agent"
WORKSPACE="$OPENHANDS_WORKSPACE"

# --- THE CONTROL: the workspace must not reach protected trees -------------
# Everything else in this file is convenience. This is the boundary. The clone
# must not be, live inside, or contain any tree that holds credentials or
# deployment state: the app, data, log and work directories, the directory the
# env file lives in, and the backup credential directory.
WORKSPACE_REAL="$(readlink -f "$WORKSPACE" 2>/dev/null || echo "$WORKSPACE")"
APP_REAL="$(readlink -f "$HYBRID_AI_APP_DIR" 2>/dev/null || echo "$HYBRID_AI_APP_DIR")"
ENV_DIR_REAL="$(dirname "$(readlink -f "$HYBRID_AI_ENV_FILE" 2>/dev/null || echo "$HYBRID_AI_ENV_FILE")")"
GUARDED_REAL=(
  "$APP_REAL"
  "$(readlink -f "$HYBRID_AI_DATA_DIR" 2>/dev/null || echo "$HYBRID_AI_DATA_DIR")"
  "$(readlink -f "$HYBRID_AI_LOG_DIR" 2>/dev/null || echo "$HYBRID_AI_LOG_DIR")"
  "$(readlink -f "$HYBRID_AI_WORK_DIR" 2>/dev/null || echo "$HYBRID_AI_WORK_DIR")"
  "$ENV_DIR_REAL"
  "$(readlink -f "$BACKUP_CONF_DIR" 2>/dev/null || echo "$BACKUP_CONF_DIR")"
)

for guarded in "${GUARDED_REAL[@]}"; do
  if [[ "$WORKSPACE_REAL" == "$guarded" ]]; then
    die "OPENHANDS_WORKSPACE is '${guarded}', a protected directory.
     The agent sandbox would be able to read the env file, the logs, or the
     backup credentials. Set it to a separate path, e.g. ${DEFAULT_WORKSPACE}"
  fi
  case "$WORKSPACE_REAL/" in
    "$guarded"/*)
      die "OPENHANDS_WORKSPACE is inside the protected directory '${guarded}'.
     Backups, diagnostics and git status would all sweep it up, and the env
     file sits one traversal away. Use a sibling path, e.g. ${DEFAULT_WORKSPACE}"
      ;;
  esac
  case "$guarded/" in
    "$WORKSPACE_REAL"/*)
      die "OPENHANDS_WORKSPACE contains the protected directory '${guarded}'.
     The clone would sit above deployment state. Use a path that is not a
     parent of it, e.g. ${DEFAULT_WORKSPACE}"
      ;;
  esac
done
unset guarded

# --- Find the origin URL ---------------------------------------------------
ORIGIN_URL=""
if git -C "$HYBRID_AI_APP_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  ORIGIN_URL="$(git -C "$HYBRID_AI_APP_DIR" remote get-url origin 2>/dev/null || true)"
fi

# --- Check mode ------------------------------------------------------------
if (( CHECK_ONLY )); then
  if [[ -d "$WORKSPACE/.git" ]]; then
    ok "Agent workspace present: ${WORKSPACE}"
  else
    die "Agent workspace missing: ${WORKSPACE}"
  fi
  for f in .env .env.local install.log backup.log; do
    if [[ -e "$WORKSPACE/$f" ]]; then
      die "SECURITY: ${f} found inside the agent workspace. Remove it."
    fi
  done
  ok "No credential files in the agent workspace"
  exit 0
fi

# --- Create or update ------------------------------------------------------
if [[ -d "$WORKSPACE/.git" ]]; then
  ok "Agent workspace already exists: ${WORKSPACE}"
  if [[ -n "$ORIGIN_URL" ]]; then
    current="$(git -C "$WORKSPACE" remote get-url origin 2>/dev/null || true)"
    if [[ "$current" != "$ORIGIN_URL" ]]; then
      log "Updating workspace origin to match this repository"
      git -C "$WORKSPACE" remote set-url origin "$ORIGIN_URL"
    fi
  fi

  # Refresh so the root copy of AGENTS.md (and everything else) does not go
  # stale. The hook path is disabled so a hostile or broken hook cannot run as
  # this user during the fetch. A failed fetch warns and does not abort, so a
  # deploy with no network still completes; install.sh keeps going.
  if git -c core.hooksPath=/dev/null -C "$WORKSPACE" fetch --no-tags origin; then
    default_ref="$(git -C "$WORKSPACE" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)"
    default_branch="${default_ref#origin/}"
    current_branch="$(git -C "$WORKSPACE" symbolic-ref --short HEAD 2>/dev/null || true)"
    if [[ -z "$default_branch" ]]; then
      warn "Could not determine the default branch in ${WORKSPACE}; skipping refresh."
    elif [[ "$current_branch" != "$default_branch" ]]; then
      warn "Workspace is on '${current_branch}', not the default branch '${default_branch}'; skipping refresh."
    elif [[ -n "$(git -C "$WORKSPACE" status --porcelain)" ]]; then
      warn "Workspace has uncommitted changes; skipping refresh to leave them untouched."
    else
      # Clean tree on the default branch: fast-forward only. Never reset,
      # stash, check out over changes, or delete anything.
      if git -C "$WORKSPACE" merge --ff-only "origin/${default_branch}" >/dev/null 2>&1; then
        ok "Agent workspace refreshed to the latest ${default_branch}"
      else
        warn "Could not fast-forward ${WORKSPACE}; skipping refresh."
      fi
    fi
  else
    warn "Fetch failed for ${WORKSPACE}; continuing with the existing clone."
  fi

elif [[ -e "$WORKSPACE" ]]; then
  # Most likely cause: Docker created it as an empty directory on a previous
  # run, because this script was missing or not executable.
  if [[ -d "$WORKSPACE" ]] && [[ -z "$(ls -A "$WORKSPACE" 2>/dev/null)" ]]; then
    log "${WORKSPACE} exists but is empty -- replacing it with a clone."
    rmdir "$WORKSPACE"
  else
    die "${WORKSPACE} exists but is not a git repository, and is not empty.
     Move it aside, or choose another path with OPENHANDS_WORKSPACE."
  fi
fi

if [[ ! -d "$WORKSPACE/.git" ]]; then
  if [[ -z "$ORIGIN_URL" ]]; then
    warn "This directory has no git origin, so the workspace cannot be cloned."
    if (( NON_INTERACTIVE )); then
      die "Push this repository to a remote first, then re-run."
    fi
    read -r -p "    Enter the repository URL to clone: " ORIGIN_URL < /dev/tty
    [[ -n "$ORIGIN_URL" ]] || die "No URL given."
  fi

  log "Cloning into ${WORKSPACE} ..."
  git clone "$ORIGIN_URL" "$WORKSPACE" || die "Clone failed."
  ok "Agent workspace created"
fi

# --- Verify no credentials leaked in --------------------------------------
# A clone should never contain these. If one does, something copied rather
# than cloned, and the isolation this script exists to provide is not real.
LEAKED=0
for f in .env .env.local install.log backup.log; do
  if [[ -e "$WORKSPACE/$f" ]]; then
    warn "SECURITY: ${f} is present in the agent workspace."
    LEAKED=1
  fi
done
if (( LEAKED )); then
  die "Remove those files from ${WORKSPACE} before starting OpenHands.
     Their presence defeats the isolation this workspace provides."
fi
ok "No credential files in the agent workspace"

# --- Report ----------------------------------------------------------------
printf '\n'
ok "Agent workspace ready"
printf '    Workspace : %s\n' "$WORKSPACE_REAL"
printf '    Deployment: %s  (NOT visible to the agent)\n' "$DEPLOY_REAL"
printf '\n'
printf '    The agent branches and commits in the workspace. Review its work,\n'
printf '    then pull into the deployment directory yourself.\n'
