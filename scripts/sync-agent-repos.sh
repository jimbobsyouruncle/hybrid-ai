#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/sync-agent-repos.sh
# PURPOSE (plain English):
#   Builds and maintains a READ-ONLY local copy of every non-fork repository
#   owned by the account, each on its own default branch, under a single
#   directory on the host. Hermes mounts that directory read-only at
#   /agent-repos so it can read your code (and any agent-context markdown
#   files) no matter which ai/* branch OpenHands last left checked out in the
#   OpenHands workspace clone.
#
# WHY A SEPARATE TREE EXISTS:
#   The OpenHands workspace clone tracks ONE repository and points at whatever
#   branch OpenHands last touched. Hermes needs a stable, read-only view of ALL
#   of your repositories, each on its default branch. This tree is that view.
#   It is deliberately separate from both the deployment directory and the
#   OpenHands workspace, and it holds no credentials.
#
# WHAT IT DOES:
#   1. Works out where the tree lives (AGENT_REPOS_DIR), the account to
#      inventory (AGENT_REPOS_OWNER), and an optional local manifest.
#   2. REFUSES a target that is, is inside, or contains the deployment
#      directory or the OpenHands workspace. The tree must not be able to
#      reach .env or the log files.
#   3. Lists the account's repos through the public GitHub REST API
#      (GET /users/<owner>/repos?type=owner&per_page=100), following every
#      Link: rel="next" page. No token is sent.
#   4. Keeps only non-fork repos owned by the account. Forks are never copied.
#   5. Adds repos named in an optional local manifest (tiny, gitignored, for
#      private repos). A manifest repo the API reports as a fork is refused.
#   6. Clones missing repos and refreshes existing ones with a fast-forward
#      only fetch. It never hard-resets and never discards local work.
#
# HOW TO RUN IT (on the host, as the deploy user):
#   ./scripts/sync-agent-repos.sh                 sync everything
#   ./scripts/sync-agent-repos.sh --help          show this message
#
#   install.sh calls this on every deploy, after step 9. To refresh on a
#   schedule the owner installs a timer BY HAND, e.g. a daily systemd timer
#   (see hermes/README.md) or this crontab line:
#
#     17 4 * * * cd /home/youruser/hybrid-ai && ./scripts/sync-agent-repos.sh >> install.log 2>&1
#
# SECURITY:
#   - Reads no credentials, sends no token, logs no credential.
#   - Writes ONLY under AGENT_REPOS_DIR.
#   - Disables git hooks (core.hooksPath=/dev/null) and tags, and does not
#     recurse into submodules, so a hostile repo cannot execute code here.
#   - .env is parsed line by line, never sourced: `source` would execute the
#     file as shell code.
# ---------------------------------------------------------------------------
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

# --- Output helpers (match install.sh / setup-agent-workspace.sh) ----------
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

for arg in "$@"; do
  case "$arg" in
    -h|--help)
      sed -n '2,60p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

# --- Read one value from .env, never sourced -------------------------------
# Same convention as scripts/setup-agent-workspace.sh: read the file line by
# line and match KEY=... exactly. Never `source` it -- a value containing
# $(...) or backticks would otherwise run as a command.
env_value() {
  local key="$1" line candidate
  [[ -f "${SCRIPT_DIR}/.env" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*${key}=(.*)$ ]] || continue
    candidate="${BASH_REMATCH[1]}"
    candidate="${candidate%\"}"; candidate="${candidate#\"}"
    candidate="${candidate%\'}"; candidate="${candidate#\'}"
    printf '%s' "$candidate"
    return 0
  done < "${SCRIPT_DIR}/.env"
}

# Expand a leading ~ by hand: a value read from a file is not tilde-expanded
# by the shell, and mounting a literal "~/..." path is a confusing failure.
# A value read from .env is not tilde-expanded, so match a literal ~ on purpose.
# shellcheck disable=SC2088
expand_tilde() {
  case "$1" in
    "~/"*) printf '%s' "${HOME}/${1#\~/}" ;;
    "~")   printf '%s' "${HOME}" ;;
    *)     printf '%s' "$1" ;;
  esac
}

# True when $1 is $2 or lives underneath it. Both must be realpaths.
path_is_within() {
  [[ "$1" == "$2" || "$1" == "$2"/* ]]
}

# --- Resolve the reference-tree directory ----------------------------------
# Environment wins, then .env, then a sibling default. Never the deployment
# directory: a separate tree is the whole point of this script.
DEFAULT_AGENT_REPOS_DIR="${HOME}/hybrid-ai-repos"
AGENT_REPOS_DIR="${AGENT_REPOS_DIR:-$(env_value AGENT_REPOS_DIR)}"
AGENT_REPOS_DIR="${AGENT_REPOS_DIR:-$DEFAULT_AGENT_REPOS_DIR}"
AGENT_REPOS_DIR="$(expand_tilde "$AGENT_REPOS_DIR")"
[[ -n "$AGENT_REPOS_DIR" ]] || die "AGENT_REPOS_DIR resolved to an empty path."

# --- Resolve the OpenHands workspace (only for the refusal check) ----------
DEFAULT_WORKSPACE="${HOME}/hybrid-ai-agent"
OPENHANDS_WORKSPACE="${OPENHANDS_WORKSPACE:-$(env_value OPENHANDS_WORKSPACE)}"
OPENHANDS_WORKSPACE="${OPENHANDS_WORKSPACE:-$DEFAULT_WORKSPACE}"
OPENHANDS_WORKSPACE="$(expand_tilde "$OPENHANDS_WORKSPACE")"

# --- THE CONTROL: the tree must never touch the deployment dir or workspace -
# Everything else here is convenience. These checks are the boundary. A
# read-only mount of the wrong path would expose .env and the log files to the
# component that processes untrusted text.
AGENT_REPOS_REAL="$(readlink -f "$AGENT_REPOS_DIR" 2>/dev/null || echo "$AGENT_REPOS_DIR")"
DEPLOY_REAL="$(readlink -f "$SCRIPT_DIR")"
WORKSPACE_REAL="$(readlink -f "$OPENHANDS_WORKSPACE" 2>/dev/null || echo "$OPENHANDS_WORKSPACE")"

if path_is_within "$AGENT_REPOS_REAL" "$DEPLOY_REAL"; then
  die "AGENT_REPOS_DIR is the deployment directory, or is inside it (${DEPLOY_REAL}).
     Hermes would mount .env and the log files. Choose a separate path, e.g.
     ${DEFAULT_AGENT_REPOS_DIR}"
fi
if path_is_within "$AGENT_REPOS_REAL" "$WORKSPACE_REAL"; then
  die "AGENT_REPOS_DIR is the OpenHands workspace, or is inside it (${WORKSPACE_REAL}).
     The reference tree must be separate from the working clone. Choose another
     path, e.g. ${DEFAULT_AGENT_REPOS_DIR}"
fi
if path_is_within "$DEPLOY_REAL" "$AGENT_REPOS_REAL"; then
  die "AGENT_REPOS_DIR contains the deployment directory (${DEPLOY_REAL}).
     Choose a path that is not a parent of it, e.g. ${DEFAULT_AGENT_REPOS_DIR}"
fi
if path_is_within "$WORKSPACE_REAL" "$AGENT_REPOS_REAL"; then
  die "AGENT_REPOS_DIR contains the OpenHands workspace (${WORKSPACE_REAL}).
     Choose a path that is not a parent of it, e.g. ${DEFAULT_AGENT_REPOS_DIR}"
fi

# --- Resolve the account owner ---------------------------------------------
OWNER="${AGENT_REPOS_OWNER:-$(env_value AGENT_REPOS_OWNER)}"
if [[ -z "$OWNER" ]]; then
  ORIGIN_URL="$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || true)"
  if [[ "$ORIGIN_URL" =~ github\.com[:/]+([^/]+)/[^/]+$ ]]; then
    OWNER="${BASH_REMATCH[1]}"
  fi
fi
[[ -n "$OWNER" ]] || die "Cannot determine the account owner. Set AGENT_REPOS_OWNER,
     or run this from a clone whose origin is a github.com URL."

# --- Validation ------------------------------------------------------------
# A name is used to build BOTH a URL and a filesystem path, so it is validated
# here and nowhere else. `.` and `..` are rejected explicitly so `../` cannot
# escape AGENT_REPOS_DIR. Nothing invalid is ever used to build a path.
valid_name() {
  local s="$1"
  [[ "$s" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  [[ "$s" == "." || "$s" == ".." ]] && return 1
  return 0
}

valid_branch() {
  local b="$1"
  [[ -n "$b" ]] || return 1
  git check-ref-format --branch "$b" >/dev/null 2>&1
}

valid_name "$OWNER" || die "The owner name '${OWNER}' is not a valid GitHub login."

# --- Inventory -------------------------------------------------------------
# keyed by full name "owner/name"; value is the default branch. FULLNAMES keeps
# a deterministic iteration order for the log.
declare -A BRANCH=()
declare -A REPO_OWNER=()
declare -A API_FORK=()
FULLNAMES=()

add_repo() {  # owner name branch
  local owner="$1" name="$2" branch="$3" full="$1/$2"
  BRANCH["$full"]="$branch"
  REPO_OWNER["$full"]="$owner"
  FULLNAMES+=("$full")
}

# --- Scratch and tree ------------------------------------------------------
# Every write in this script stays under AGENT_REPOS_DIR: the tree itself, and
# a short-lived scratch directory for API pages. Create the tree first so the
# scratch directory can live inside it, not in $TMPDIR.
mkdir -p "$AGENT_REPOS_DIR"
ok "Reference tree: ${AGENT_REPOS_REAL}"
TMPDIR_SYNC="$(mktemp -d "${AGENT_REPOS_DIR}/.sync.XXXXXX")"
trap 'rm -rf "$TMPDIR_SYNC"' EXIT

API_BASE="https://api.github.com"

log "Listing non-fork repositories owned by '${OWNER}' via the GitHub API ..."
page_url="${API_BASE}/users/${OWNER}/repos?type=owner&per_page=100"
: > "${TMPDIR_SYNC}/repos.jsonl"
pages=0
while [[ -n "$page_url" ]]; do
  pages=$((pages + 1))
  # --no token anywhere: an unauthenticated read of public metadata.
  if ! curl -fsS --retry 2 --retry-delay 1 --max-time 30 \
      -H "Accept: application/vnd.github+json" \
      -D "${TMPDIR_SYNC}/hdr" -o "${TMPDIR_SYNC}/page.json" "$page_url"; then
    die "GitHub API request failed: ${page_url}
     Nothing was changed. Check network access and try again."
  fi
  if ! jq -e 'type == "array"' "${TMPDIR_SYNC}/page.json" >/dev/null 2>&1; then
    die "Unexpected GitHub API response (not an array). Nothing was changed."
  fi
  jq -c '.[]' "${TMPDIR_SYNC}/page.json" >> "${TMPDIR_SYNC}/repos.jsonl"
  # Follow Link: rel="next". Split on commas: the header may carry several
  # relations. `|| true` because an absent "next" is a normal end condition.
  page_url="$(grep -i '^link:' "${TMPDIR_SYNC}/hdr" \
    | tr ',' '\n' \
    | grep -i 'rel="next"' \
    | sed -E 's/.*<([^>]+)>.*/\1/' || true)"
done
ok "Listed ${pages} API page(s)."

# Keep only non-forks owned by this account; record forks for the manifest check.
while IFS=$'\t' read -r full owner name branch fork; do
  [[ -n "$full" ]] || continue
  if [[ "$fork" == "true" ]]; then
    API_FORK["$full"]=1
    continue
  fi
  # Case-insensitive owner match: GitHub logins are case-insensitive.
  if [[ "${owner,,}" != "${OWNER,,}" ]]; then
    continue
  fi
  if ! valid_name "$owner" || ! valid_name "$name"; then
    warn "Skipping invalid API entry: ${full}"
    continue
  fi
  if ! valid_branch "$branch"; then
    warn "Skipping ${full}: default branch '${branch}' is not a valid ref."
    continue
  fi
  if [[ -n "${BRANCH[$full]:-}" ]]; then
    continue
  fi
  add_repo "$owner" "$name" "$branch"
done < <(jq -r '[.full_name, .owner.login, .name, .default_branch, (.fork|tostring)] | @tsv' "${TMPDIR_SYNC}/repos.jsonl")

# --- Manifest (optional, local, gitignored) --------------------------------
# Lines: "OWNER/NAME" to include, "-OWNER/NAME" to exclude. Blank lines and
# lines starting with '#' are ignored. This is how PRIVATE repos, which the
# unauthenticated API cannot list, are added.
# Excluding a repo stops future syncing of it; it does NOT delete a copy that
# already exists on disk. This script never deletes anything.
AGENT_REPOS_MANIFEST="${AGENT_REPOS_MANIFEST:-$(env_value AGENT_REPOS_MANIFEST)}"
AGENT_REPOS_MANIFEST="${AGENT_REPOS_MANIFEST:-${SCRIPT_DIR}/agent-repos.local}"
AGENT_REPOS_MANIFEST="$(expand_tilde "$AGENT_REPOS_MANIFEST")"

manifest_default_branch() {  # owner/name -> branch on stdout, non-zero on failure
  local full="$1" ref
  ref="$(GIT_TERMINAL_PROMPT=0 git ls-remote --symref "https://github.com/${full}.git" HEAD 2>/dev/null \
    | awk '/^ref:/ {print $2; exit}')" || true
  [[ "$ref" == refs/heads/* ]] || return 1
  printf '%s' "${ref#refs/heads/}"
}

if [[ -f "$AGENT_REPOS_MANIFEST" ]]; then
  log "Reading manifest ${AGENT_REPOS_MANIFEST} ..."
  while IFS= read -r mline || [[ -n "$mline" ]]; do
    mline="${mline#"${mline%%[![:space:]]*}"}"        # ltrim
    mline="${mline%"${mline##*[![:space:]]}"}"        # rtrim
    [[ -z "$mline" || "$mline" == \#* ]] && continue
    exclude=0
    [[ "$mline" == -* ]] && { exclude=1; mline="${mline#-}"; }
    if [[ "$mline" != */* ]]; then
      warn "Manifest line is not OWNER/NAME: '${mline}'"
      continue
    fi
    m_owner="${mline%%/*}"
    m_name="${mline#*/}"
    full="${m_owner}/${m_name}"
    if ! valid_name "$m_owner" || ! valid_name "$m_name"; then
      warn "Manifest entry '${mline}' is not a valid OWNER/NAME. Skipping."
      continue
    fi
    if (( exclude )); then
      if [[ -n "${BRANCH[$full]:-}" ]]; then
        unset 'BRANCH[$full]' 'REPO_OWNER[$full]'
        new_fullnames=()
        for f in "${FULLNAMES[@]}"; do [[ "$f" == "$full" ]] || new_fullnames+=("$f"); done
        FULLNAMES=("${new_fullnames[@]}")
        unset new_fullnames f
        ok "Excluded by manifest: ${full}"
      fi
      continue
    fi
    if [[ -n "${API_FORK[$full]:-}" ]]; then
      warn "Refusing manifest entry ${full}: the API reports it as a fork."
      continue
    fi
    if [[ -n "${BRANCH[$full]:-}" ]]; then
      continue
    fi
    m_branch="$(manifest_default_branch "$full" || true)"
    if [[ -z "$m_branch" ]] || ! valid_branch "$m_branch"; then
      warn "Could not resolve a default branch for ${full}. Skipping."
      continue
    fi
    add_repo "$m_owner" "$m_name" "$m_branch"
  done < "$AGENT_REPOS_MANIFEST"
  unset mline m_owner m_name full m_branch exclude
else
  log "No manifest at ${AGENT_REPOS_MANIFEST} (optional)."
fi

# --- Sync ------------------------------------------------------------------
n_total=0; n_cloned=0; n_updated=0; n_skipped=0; n_failed=0
for full in "${FULLNAMES[@]}"; do
  owner="${REPO_OWNER[$full]}"
  name="${full#*/}"
  branch="${BRANCH[$full]}"
  dest="${AGENT_REPOS_DIR}/${name}"
  url="https://github.com/${full}.git"
  n_total=$((n_total + 1))

  if [[ -d "${dest}/.git" ]]; then
    # Refresh. A dirty tree is left alone: ff-only must never discard work.
    if [[ -n "$(git -C "$dest" status --porcelain 2>/dev/null)" ]]; then
      warn "Skipping ${name}: working tree is dirty (uncommitted changes)."
      n_skipped=$((n_skipped + 1))
      continue
    fi
    # -c core.hooksPath=/dev/null on every git call: a repository must never be
    # able to run code on the host through a hook.
    if git -C "$dest" -c core.hooksPath=/dev/null fetch --no-tags --prune origin >/dev/null 2>&1 \
       && git -C "$dest" -c core.hooksPath=/dev/null checkout --detach "$branch" >/dev/null 2>&1 \
       && git -C "$dest" -c core.hooksPath=/dev/null merge --ff-only "origin/${branch}" >/dev/null 2>&1; then
      ok "Updated ${name} (${branch})"
      n_updated=$((n_updated + 1))
    else
      warn "Failed to refresh ${name} (${branch})."
      n_failed=$((n_failed + 1))
    fi
    continue
  fi

  if [[ -e "$dest" ]]; then
    warn "Skipping ${name}: ${dest} exists but is not a git repository."
    n_skipped=$((n_skipped + 1))
    continue
  fi

  # Clone. No hooks (core.hooksPath=/dev/null), no tags, no submodules, and no
  # LFS smudge -- none of these may run code or fetch extra data. Single branch
  # keeps it to the default branch only.
  if GIT_LFS_SKIP_SMUDGE=1 GIT_TERMINAL_PROMPT=0 \
       git -c core.hooksPath=/dev/null clone \
         --single-branch --branch "$branch" --no-recurse-submodules --no-tags \
         "$url" "$dest" >/dev/null 2>&1; then
    ok "Cloned ${name} (${branch})"
    n_cloned=$((n_cloned + 1))
  else
    warn "Failed to clone ${name} (${branch})."
    n_failed=$((n_failed + 1))
  fi
done
unset owner name branch dest url full

# --- Report ----------------------------------------------------------------
printf '\n'
ok "Agent repo reference tree synced"
printf '    Directory : %s\n' "$AGENT_REPOS_REAL"
printf '    Repos     : %d total, %d cloned, %d updated, %d skipped, %d failed\n' \
  "$n_total" "$n_cloned" "$n_updated" "$n_skipped" "$n_failed"
printf '    Mounted in the Hermes container READ-ONLY at /agent-repos\n'
printf '\n'

(( n_failed == 0 )) || exit 1