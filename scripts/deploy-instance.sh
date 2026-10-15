#!/usr/bin/env bash
set -Eeuo pipefail
# ---------------------------------------------------------------------------
# FILE: scripts/deploy-instance.sh
# PURPOSE (plain English):
#   The root-side half of the headless deploy. The forced-command SSH
#   entrypoint (scripts/deploy-forced-command.sh) can do exactly one thing:
#   start the system unit hybrid-ai-deploy@<sha>.service. That unit runs THIS
#   script as root with the 40-hex commit as its single `%i` argument.
#
#   This script is the trust boundary. It:
#     1. re-validates the commit argument (40 lowercase hex);
#     2. takes an exclusive flock, so two deploys can never overlap;
#     3. refuses an origin remote that carries a credential (userinfo);
#     4. fetches main from the PUBLIC https remote only, with git hooks and
#        credential helpers disabled, and never from a credential-bearing URL;
#     5. refuses unless the commit is an ancestor of origin/main;
#     6. resets the tree to the commit and asserts HEAD equals it;
#     7. hands off to scripts/deploy-remote.sh, which re-asserts HEAD, runs
#        install.sh and gates on doctor.sh.
#
#   The ancestor check (step 5) and the HEAD assert (step 6) are MANDATORY
#   controls: they close the gap between "CI validated a commit" and "the host
#   runs exactly that commit". They must never be skipped.
#
#   Each run writes its output to $HYBRID_AI_LOG_DIR/deploy/<sha>.log with
#   mode 0640 (owner read/write, group read only) and group hybrid-ai-deploy,
#   so the unprivileged deploy account can read the log without any
#   systemd-journal access. The deploy/ subdirectory is created mode 0750.
#
#   NOT ACTIVE UNTIL MIGRATION:
#     Nothing here runs until the owner's migration. Card F installs the
#     pieces on the host; a later card switches .github/workflows/deploy.yml
#     over to the forced-command entrypoint. Until then this file is inert.
#
# USAGE:
#   ./scripts/deploy-instance.sh <full-40-hex-commit-sha>     (run as root)
#
# EXIT CODES (every refusal is distinct and documented):
#   0  handed off to deploy-remote.sh (its exit code propagates through exec)
#   2  the argument is missing or not a 40-lowercase-hex commit
#   3  another deploy holds the lock
#   4  the origin remote carries a credential (userinfo in its URL)
#   5  the public remote is unsafe (not https, or carries userinfo)
#   6  fetching main from the public remote failed
#   7  the commit is not an ancestor of origin/main
#   8  HEAD is not the commit after `git reset --hard`
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/hybrid-ai-env.sh
source "${SCRIPT_DIR}/lib/hybrid-ai-env.sh"

APP_DIR="$HYBRID_AI_APP_DIR"
DEPLOY_LOG_DIR="${HYBRID_AI_LOG_DIR}/deploy"
LOCK_FILE="${HYBRID_AI_DEPLOY_LOCK_FILE:-/run/lock/hybrid-ai-deploy.lock}"
# The PUBLIC https remote, by name only -- never a value in the tree. The
# default is this repository's canonical https URL.
PUBLIC_REMOTE="${HYBRID_AI_DEPLOY_PUBLIC_REMOTE:-https://github.com/jimbobsyouruncle/hybrid-ai.git}"

die() { # code message...
  local code="$1"; shift
  printf 'deploy-instance: %s\n' "$*" >&2
  exit "$code"
}

# True when a scheme URL (scheme://...) carries userinfo in its authority,
# e.g. https://user:pass@host/... or ssh://git@host/.... An scp-like SSH form
# (git@host:path) has no scheme, so it is not a URL credential and is allowed.
url_has_userinfo() {
  local v="$1"
  [[ "$v" == *://* ]] || return 1
  local after="${v#*://}"
  local authority="${after%%/*}"
  [[ "$authority" == *@* ]]
}

# True when a URL is an https:// URL. The public remote must be https.
url_is_https() {
  [[ "$1" == https://* ]]
}

# --- 1. Validate the commit argument ----------------------------------------
if (( $# != 1 )); then
  die 2 "requires exactly one argument: the full 40-hex commit SHA (got $#)"
fi
SHA="$1"
if [[ ! "$SHA" =~ ^[0-9a-f]{40}$ ]]; then
  die 2 "the argument is not a full 40-character lowercase hex commit SHA"
fi

# --- 2. Exclusive lock, FIRST: two deploys never overlap --------------------
# Taken before the run log is created or truncated, and held (fd 9) through the
# exec of deploy-remote.sh, so the lock covers the whole pipeline. A second
# deploy is refused here and never touches the first run's log.
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  die 3 "another deploy holds ${LOCK_FILE}"
fi

# --- 3. Set up the run log (mode 0640), now that this run owns the lock -----
mkdir -p -- "$DEPLOY_LOG_DIR"
chmod 0750 -- "$DEPLOY_LOG_DIR" 2>/dev/null || true
chgrp hybrid-ai-deploy -- "$DEPLOY_LOG_DIR" 2>/dev/null || true
LOG_FILE="${DEPLOY_LOG_DIR}/${SHA}.log"
install -m 0640 /dev/null -- "$LOG_FILE"
# Group read for the deploy account, so it can read this log via the forced
# command without any systemd-journal access.
chgrp hybrid-ai-deploy -- "$LOG_FILE" 2>/dev/null || true
exec >>"$LOG_FILE" 2>&1

echo "==> deploy-instance: commit ${SHA}"

# --- 4. Refuse a credential-bearing origin ----------------------------------
ORIGIN_URL="$(git -C "$APP_DIR" config --get remote.origin.url 2>/dev/null || true)"
if [[ -n "$ORIGIN_URL" ]] && url_has_userinfo "$ORIGIN_URL"; then
  die 4 "the origin remote carries a credential; refusing to fetch through it"
fi

# --- 5. Fetch main from the PUBLIC https remote only ------------------------
if ! url_is_https "$PUBLIC_REMOTE"; then
  die 5 "the public remote is not an https URL"
fi
if url_has_userinfo "$PUBLIC_REMOTE"; then
  die 5 "the public remote carries userinfo; refusing"
fi

# Hooks disabled (core.hooksPath=/dev/null), credential helpers cleared
# (credential.helper=), inherited auth headers cleared (http.extraHeader=), and
# no interactive prompt. The refspec writes origin/main explicitly, so the
# ancestor check below compares against the freshly fetched main.
if ! GIT_TERMINAL_PROMPT=0 GIT_CONFIG_NOSYSTEM=1 \
     git -C "$APP_DIR" \
       -c core.hooksPath=/dev/null \
       -c credential.helper= \
       -c http.extraHeader= \
       fetch --prune --no-tags "$PUBLIC_REMOTE" \
         "+refs/heads/main:refs/remotes/origin/main"; then
  die 6 "fetching main from the public remote failed"
fi

# --- 6. MANDATORY: the commit must be an ancestor of origin/main ------------
if ! git -C "$APP_DIR" merge-base --is-ancestor "$SHA" origin/main; then
  die 7 "commit is not an ancestor of origin/main; refusing to deploy"
fi

# --- 7. Reset and MANDATORY assert: HEAD must equal the commit --------------
if ! git -C "$APP_DIR" reset --hard "$SHA"; then
  die 8 "git reset --hard failed"
fi
if ! CURRENT_SHA="$(git -C "$APP_DIR" rev-parse HEAD 2>/dev/null)"; then
  die 8 "could not read HEAD after reset"
fi
if [[ "$CURRENT_SHA" != "$SHA" ]]; then
  die 8 "HEAD is ${CURRENT_SHA} but the validated revision is ${SHA}"
fi

# --- 8. Hand off to the existing remote-deploy half -------------------------
exec "${APP_DIR}/scripts/deploy-remote.sh" "$SHA"
