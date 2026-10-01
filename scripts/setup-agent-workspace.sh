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
#   3. Creates the clone if missing; updates its origin if it already exists.
#   4. Verifies no .env or log file leaked into it.
#
# HOW TO RUN IT:
#   ./scripts/setup-agent-workspace.sh                    interactive
#   ./scripts/setup-agent-workspace.sh --non-interactive  for CI / install.sh
#   ./scripts/setup-agent-workspace.sh --check            verify only
# ---------------------------------------------------------------------------
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

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
# git status -- and .env would sit one directory traversal away.
DEFAULT_WORKSPACE="${HOME}/hybrid-ai-agent"
WORKSPACE="${OPENHANDS_WORKSPACE:-$DEFAULT_WORKSPACE}"

# If .env already names a workspace, honour it -- install.sh writes it there.
#
# SECURITY: parsed line by line, never sourced. `source` executes the file as
# shell code, so a value containing $(...) or backticks would run as a command.
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^OPENHANDS_WORKSPACE=(.*)$ ]] || continue
    candidate="${BASH_REMATCH[1]}"
    candidate="${candidate%\"}"; candidate="${candidate#\"}"
    candidate="${candidate%\'}"; candidate="${candidate#\'}"
    [[ -n "$candidate" ]] && WORKSPACE="$candidate"
  done < "${SCRIPT_DIR}/.env"
  unset line candidate
fi

# Expand a leading ~ ourselves: a value read from a file is not tilde-expanded
# by the shell, and mounting a literal "~/hybrid-ai-agent" directory is a
# genuinely confusing failure to diagnose.
case "$WORKSPACE" in
  "~/"*) WORKSPACE="${HOME}/${WORKSPACE#\~/}" ;;
  "~")   WORKSPACE="${HOME}" ;;
esac

# --- THE CONTROL: workspace must not be the deployment directory -----------
# Everything else in this file is convenience. This is the boundary.
WORKSPACE_REAL="$(readlink -f "$WORKSPACE" 2>/dev/null || echo "$WORKSPACE")"
DEPLOY_REAL="$(readlink -f "$SCRIPT_DIR")"

if [[ "$WORKSPACE_REAL" == "$DEPLOY_REAL" ]]; then
  die "OPENHANDS_WORKSPACE points at the deployment directory (${DEPLOY_REAL}).
     The agent sandbox would be able to read .env and the log files.
     Set it to a separate path, e.g. ${DEFAULT_WORKSPACE}"
fi

case "$WORKSPACE_REAL/" in
  "$DEPLOY_REAL"/*)
    die "OPENHANDS_WORKSPACE is inside the deployment directory.
     Backups, diagnostics and git status would all sweep it up, and .env sits
     one traversal away. Use a sibling path, e.g. ${DEFAULT_WORKSPACE}"
    ;;
esac

# --- Find the origin URL ---------------------------------------------------
ORIGIN_URL=""
if git -C "$SCRIPT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  ORIGIN_URL="$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || true)"
fi

# --- Check mode ------------------------------------------------------------
if (( CHECK_ONLY )); then
  [[ -d "$WORKSPACE/.git" ]] \
    && ok "Agent workspace present: ${WORKSPACE}" \
    || die "Agent workspace missing: ${WORKSPACE}"
  for f in .env .env.local install.log backup.log; do
    [[ -e "$WORKSPACE/$f" ]] \
      && die "SECURITY: ${f} found inside the agent workspace. Remove it."
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
