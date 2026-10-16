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
# WHAT A NORMAL RUN DOES:
#   1. Works out where the tree lives (AGENT_REPOS_DIR), the account to
#      inventory (AGENT_REPOS_OWNER), and an optional local manifest.
#   2. REFUSES a target that is, is inside, or contains the deployment
#      directory or the OpenHands workspace. The tree must not be able to
#      reach .env or the log files.
#   3. Lists the account's repos through the public GitHub REST API
#      (GET /users/<owner>/repos?type=owner&per_page=100), following every
#      Link: rel="next" page. No token is sent.
#   4. Keeps only non-fork repos owned by the account. Forks are never copied.
#   5. Adds repos named in an optional local manifest (tiny, gitignored).
#   6. Takes an flock so two runs cannot collide.
#   7. For each existing clone, BEFORE any fetch, refuses a clone whose git
#      config embeds a credential in a remote URL (scripts/check-git-remotes.sh).
#   8. Clones missing repos and refreshes existing ones fast-forward only. It
#      never hard-resets and never deletes anything.
#   9. Writes INVENTORY.md atomically: one row per repo with the default
#      branch, HEAD short SHA, status and last sync time (UTC).
#
# SYMLINKS:
#   Every clone is made with core.symlinks=false and that setting is persisted,
#   so a repository cannot plant a symlink that escapes the tree. A clone whose
#   working tree already contains a symlink is skipped as skipped:symlinks and
#   is never modified; the operator re-clones that one by hand. Nothing is ever
#   deleted.
#
# HOW TO RUN IT (on the host, as the deploy user):
#   ./scripts/sync-agent-repos.sh                 sync everything
#   ./scripts/sync-agent-repos.sh --dry-run       show what a run WOULD do
#   ./scripts/sync-agent-repos.sh --check         verify the tree from INVENTORY.md
#   ./scripts/sync-agent-repos.sh --help          show this message
#
#   install.sh calls this near the start of every deploy, before it loads .env.
#   To refresh on a schedule the owner installs a timer BY HAND, e.g. a daily
#   systemd timer (see hermes/README.md) or this crontab line:
#
#     17 4 * * * cd /home/youruser/hybrid-ai && ./scripts/sync-agent-repos.sh >> install.log 2>&1
#
# FLAGS:
#   --dry-run            List the API and manifest inventories and the planned
#                        action per repo. It reads the GitHub API over the
#                        network, but does no clone, no fetch, no git write and
#                        writes no file: it does not create AGENT_REPOS_DIR and
#                        puts its throwaway API-page scratch in ${TMPDIR:-/tmp}.
#   --check              Offline. Read INVENTORY.md and verify each listed dir
#                        exists and its HEAD still matches. Uses no network and
#                        writes nothing.
#   --max-age-hours N    Freshness threshold for --check, in hours. Default 48.
#                        Also read from AGENT_REPOS_MAX_AGE_HOURS.
#
# EXIT CODES (a normal run):
#   0  every repo cloned, refreshed or already up to date; none skipped/stale.
#   1  the run finished but something was skipped (skipped:<reason>) or stale.
#   2  an error: usage error, safety refusal, concurrent run, a failed
#      clone/fetch, or an unreadable inventory.
# EXIT CODES (--check):
#   0  ok
#   1  the inventory is older than the max age, or a skipped/stale row exists
#   2  a listed dir is missing, a HEAD does not match, or the inventory is
#      missing or unreadable
#
# TEST-ONLY SEAMS (never set these in production):
#   AGENT_REPOS_CLONE_BASE
#       Override the git clone base. Accepts ONLY an existing local directory
#       or a file:// URL -- never a network host. While set, the GitHub API
#       listing is skipped so the test runs with no network.
#   AGENT_REPOS_INVENTORY_FILE
#       Override the INVENTORY.md path (read by --check, written by a run).
#   Both are OFF by default. With neither set the script behaves exactly as in
#   production.
#
# SECURITY:
#   - Reads no credentials, sends no token, logs no credential. The credential
#     check prints only `<path>: <key>` lines.
#   - A normal run writes ONLY under AGENT_REPOS_DIR. A --dry-run writes nothing
#     (no AGENT_REPOS_DIR creation, no file), and --check writes nothing.
#   - Disables git hooks (core.hooksPath=/dev/null), tags and symlinks, and
#     does not recurse into submodules, so a hostile repo cannot execute code.
#   - .env is parsed line by line, never sourced: `source` would execute the
#     file as shell code.
# ---------------------------------------------------------------------------
set -Eeuo pipefail

# Every host path comes from the ONE shared helper. With no settings, the
# resolved paths are exactly today's.
HYBRID_AI_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/lib" && pwd)"
# shellcheck source=scripts/lib/hybrid-ai-env.sh
source "${HYBRID_AI_LIB_DIR}/hybrid-ai-env.sh"

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
die()  { printf '%s[ X ]%s %s\n'  "$C_ERR" "$C_RST" "$*" >&2; exit 2; }

# Print the header comment (everything after the shebang, up to `set -Eeuo`).
usage() {
  awk 'NR==1{next} /^set -Eeuo pipefail/{exit} {sub(/^# ?/,""); print}' "${BASH_SOURCE[0]}"
}

# --- Read one value from the env file, never sourced -----------------------
# Used only for the settings the shared helper does not resolve (the freshness
# window, the owner, the optional manifest). The path settings come from the
# helper. Never `source` it -- a value containing $(...) would run as code.
env_value() {
  local key="$1" line candidate
  [[ -f "${HYBRID_AI_ENV_FILE}" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*${key}=(.*)$ ]] || continue
    candidate="${BASH_REMATCH[1]}"
    candidate="${candidate%\"}"; candidate="${candidate#\"}"
    candidate="${candidate%\'}"; candidate="${candidate#\'}"
    printf '%s' "$candidate"
    return 0
  done < "${HYBRID_AI_ENV_FILE}"
}

# Expand a leading ~ by hand: a value read from .env is not tilde-expanded.
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

# --- Argument parsing ------------------------------------------------------
MODE="run"                 # run | dry-run | check | help
CLI_MAX_AGE=""
while (( $# > 0 )); do
  case "$1" in
    -h|--help)         MODE="help" ;;
    --dry-run)         MODE="dry-run" ;;
    --check)           MODE="check" ;;
    --max-age-hours)   shift; CLI_MAX_AGE="${1:-}" ;;
    --max-age-hours=*) CLI_MAX_AGE="${1#*=}" ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

if [[ "$MODE" == "help" ]]; then usage; exit 0; fi

# Freshness threshold for --check. CLI wins, then the environment / .env, then
# the 48-hour default.
MAX_AGE_HOURS="${CLI_MAX_AGE:-${AGENT_REPOS_MAX_AGE_HOURS:-$(env_value AGENT_REPOS_MAX_AGE_HOURS)}}"
MAX_AGE_HOURS="${MAX_AGE_HOURS:-48}"
[[ "$MAX_AGE_HOURS" =~ ^[0-9]+$ ]] || die "AGENT_REPOS_MAX_AGE_HOURS must be a whole number of hours. Got: ${MAX_AGE_HOURS}"

# --- Resolve the reference-tree directory ----------------------------------
# Resolved by the shared helper: environment, then the env file, then a sibling
# default. Never the deployment directory: a separate tree is the whole point.
DEFAULT_AGENT_REPOS_DIR="${HOME}/hybrid-ai-repos"
[[ -n "$AGENT_REPOS_DIR" ]] || die "AGENT_REPOS_DIR resolved to an empty path."

# --- Resolve the OpenHands workspace (only for the refusal check) ----------
# Resolved by the shared helper (OPENHANDS_WORKSPACE).

AGENT_REPOS_REAL="$(readlink -f "$AGENT_REPOS_DIR" 2>/dev/null || echo "$AGENT_REPOS_DIR")"

# The inventory path. Overridable for tests; unused in production.
INV_PATH="${AGENT_REPOS_INVENTORY_FILE:-${AGENT_REPOS_DIR}/INVENTORY.md}"

# --- Small helpers ---------------------------------------------------------
iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Short HEAD of a work tree, or "-" when there is none.
sha_short() { git -C "$1" rev-parse --short HEAD 2>/dev/null || printf '-'; }

# True when the working tree contains a symlink. -P means find never follows a
# symlink; the .git directory itself is pruned so its contents are not scanned.
tree_has_symlink() {
  local tree="$1" hit
  hit="$(find -P "$tree" -path "${tree}/.git" -prune -o -type l -print -quit 2>/dev/null || true)"
  [[ -n "$hit" ]]
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Relay the check's findings. The check prints only `<path>: <key>` lines --
# never a URL, userinfo or token -- so it is safe to pass them through.
relay_cred() {
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    warn "credential-remote: ${line}"
  done <<<"$1"
}

CRED_CHECK="${HYBRID_AI_APP_DIR}/scripts/check-git-remotes.sh"

# --- THE CONTROL: the tree must never touch protected trees -----------------
# Everything else here is convenience. These checks are the boundary. A
# read-only mount of the wrong path would expose the env file, the log files or
# the backup credentials to the component that processes untrusted text. The
# tree must not be, live inside, or contain any of: the app, data, log and work
# directories, the directory the env file lives in, the OpenHands workspace, and
# the backup credential directory. A --check writes nothing, so it is exempt.
if [[ "$MODE" != "check" ]]; then
  WORKSPACE_REAL="$(readlink -f "$OPENHANDS_WORKSPACE" 2>/dev/null || echo "$OPENHANDS_WORKSPACE")"
  ENV_DIR_REAL="$(dirname "$(readlink -f "$HYBRID_AI_ENV_FILE" 2>/dev/null || echo "$HYBRID_AI_ENV_FILE")")"
  STACK_ENV_DIR_REAL="$(dirname "$(readlink -f "$HYBRID_AI_STACK_ENV_FILE" 2>/dev/null || echo "$HYBRID_AI_STACK_ENV_FILE")")"
  GUARDED_REAL=(
    "$(readlink -f "$HYBRID_AI_APP_DIR" 2>/dev/null || echo "$HYBRID_AI_APP_DIR")"
    "$(readlink -f "$HYBRID_AI_DATA_DIR" 2>/dev/null || echo "$HYBRID_AI_DATA_DIR")"
    "$(readlink -f "$HYBRID_AI_LOG_DIR" 2>/dev/null || echo "$HYBRID_AI_LOG_DIR")"
    "$(readlink -f "$HYBRID_AI_WORK_DIR" 2>/dev/null || echo "$HYBRID_AI_WORK_DIR")"
    "$ENV_DIR_REAL"
    "$STACK_ENV_DIR_REAL"
    "$WORKSPACE_REAL"
    "$(readlink -f "$BACKUP_CONF_DIR" 2>/dev/null || echo "$BACKUP_CONF_DIR")"
  )
  for guarded in "${GUARDED_REAL[@]}"; do
    if path_is_within "$AGENT_REPOS_REAL" "$guarded"; then
      die "AGENT_REPOS_DIR is '${guarded}', or is inside it.
     Hermes would mount credentials or deployment state. Choose a separate path,
     e.g. ${DEFAULT_AGENT_REPOS_DIR}"
    fi
    if path_is_within "$guarded" "$AGENT_REPOS_REAL"; then
      die "AGENT_REPOS_DIR contains '${guarded}'.
     Choose a path that is not a parent of it, e.g. ${DEFAULT_AGENT_REPOS_DIR}"
    fi
  done
  unset guarded
fi

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

# ===========================================================================
# --check : offline verification against INVENTORY.md
# ===========================================================================
run_check() {
  local inv="$1" ts dir epoch now age_h bad skip name head status dirpath cur

  [[ -f "$inv" ]] || die "Inventory not found: ${inv}. Run the sync first."
  [[ -r "$inv" ]] || die "Inventory is not readable: ${inv}."

  ts="$(awk -F': ' '/^- Generated \(UTC\):/ {print $2; exit}' "$inv")"
  dir="$(awk -F': ' '/^- Directory:/ {print $2; exit}' "$inv")"
  [[ -n "$ts" ]]  || die "Inventory has no generated timestamp: ${inv}."
  [[ -n "$dir" ]] || die "Inventory has no directory line: ${inv}."
  epoch="$(date -u -d "$ts" +%s 2>/dev/null || true)"
  [[ -n "$epoch" ]] || die "Inventory timestamp is not parseable (${ts}): ${inv}."

  now="$(date -u +%s)"
  age_h=$(( (now - epoch) / 3600 ))

  bad=0
  skip=0
  # Each data row is "| name | branch | head | status | last-sync |". The fields
  # we do not need are read into the throwaway variable `_`. grep keeps only the
  # rows that start with a pipe; the header and separator rows fall through the
  # `case` below.
  while IFS='|' read -r _ name _ head status _ _; do
    name="$(trim "${name:-}")"
    head="$(trim "${head:-}")"
    status="$(trim "${status:-}")"
    case "$name" in
      ""|Repository|---*|-*) continue ;;
    esac
    dirpath="${dir}/${name}"
    if [[ ! -d "$dirpath" ]]; then
      warn "check: missing directory for ${name}: ${dirpath}"
      bad=$((bad + 1))
      continue
    fi
    if [[ "$head" != "-" && -n "$head" ]]; then
      cur="$(sha_short "$dirpath")"
      if [[ "$cur" != "$head" ]]; then
        warn "check: HEAD mismatch for ${name}: inventory ${head}, on disk ${cur}"
        bad=$((bad + 1))
        continue
      fi
    fi
    case "$status" in
      skipped:*|stale|error) skip=$((skip + 1)) ;;
    esac
  done < <(grep '^|' "$inv" 2>/dev/null || true)

  if (( bad > 0 )); then
    die "check: ${bad} problem(s) found; see the lines above."
  fi
  if (( age_h > MAX_AGE_HOURS )); then
    warn "check: inventory is stale: generated ${age_h}h ago (max ${MAX_AGE_HOURS}h). Re-run the sync."
    exit 1
  fi
  if (( skip > 0 )); then
    warn "check: ${skip} skipped/stale/errored row(s) in the inventory."
    exit 1
  fi
  ok "check: inventory is fresh (${age_h}h) and every listed repo matches."
  exit 0
}

if [[ "$MODE" == "check" ]]; then
  run_check "$INV_PATH"
fi

# ===========================================================================
# Resolve the owner (needed by the API listing).
# ===========================================================================
OWNER="${AGENT_REPOS_OWNER:-$(env_value AGENT_REPOS_OWNER)}"
if [[ -z "$OWNER" ]]; then
  ORIGIN_URL="$(git -C "$HYBRID_AI_APP_DIR" remote get-url origin 2>/dev/null || true)"
  if [[ "$ORIGIN_URL" =~ github\.com[:/]+([^/]+)/[^/]+$ ]]; then
    OWNER="${BASH_REMATCH[1]}"
  fi
fi
[[ -n "$OWNER" ]] || die "Cannot determine the account owner. Set AGENT_REPOS_OWNER,
     or run this from a clone whose origin is a github.com URL."
valid_name "$OWNER" || die "The owner name '${OWNER}' is not a valid GitHub login."

# ===========================================================================
# TEST-ONLY clone base. Accepts ONLY an existing local directory or a file://
# URL -- never a network host. Unset in production, where GitHub is used.
# ===========================================================================
CLONE_BASE=""
if [[ -n "${AGENT_REPOS_CLONE_BASE:-}" ]]; then
  b="${AGENT_REPOS_CLONE_BASE}"
  if [[ "$b" == file://* ]]; then
    CLONE_BASE="${b%/}"
  elif [[ -d "$b" ]]; then
    CLONE_BASE="file://${b%/}"
  else
    die "AGENT_REPOS_CLONE_BASE (TEST-ONLY) must be an existing local directory or a file:// URL. Got: ${b}"
  fi
fi

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

# --- Listing source --------------------------------------------------------
API_BASE="https://api.github.com"

if [[ -n "$CLONE_BASE" ]]; then
  # TEST-ONLY path: no network at all. The manifest alone supplies the repos.
  log "TEST-ONLY clone base set (${CLONE_BASE}): skipping the GitHub API listing."
else
  # Scratch for the API-page downloads. A normal run keeps it under the tree
  # (and creates the tree first); a --dry-run must not create or write anything
  # under AGENT_REPOS_DIR at all, so its scratch goes in ${TMPDIR:-/tmp}. Either
  # way it is short-lived and removed on exit.
  if [[ "$MODE" == "dry-run" ]]; then
    TMPDIR_SYNC="$(mktemp -d "${TMPDIR:-/tmp}/.sync.XXXXXX")"
  else
    mkdir -p "$AGENT_REPOS_DIR"
    ok "Reference tree: ${AGENT_REPOS_REAL}"
    TMPDIR_SYNC="$(mktemp -d "${AGENT_REPOS_DIR}/.sync.XXXXXX")"
  fi
  trap 'rm -rf "$TMPDIR_SYNC"' EXIT

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
fi

# --- Manifest (optional, local, gitignored) --------------------------------
# Lines: "OWNER/NAME" to include, "-OWNER/NAME" to exclude. Blank lines and
# lines starting with '#' are ignored. This is how PRIVATE repos, which the
# unauthenticated API cannot list, are added.
# Excluding a repo stops future syncing of it; it does NOT delete a copy that
# already exists on disk. This script never deletes anything.
AGENT_REPOS_MANIFEST="${AGENT_REPOS_MANIFEST:-$(env_value AGENT_REPOS_MANIFEST)}"
AGENT_REPOS_MANIFEST="${AGENT_REPOS_MANIFEST:-${HYBRID_AI_APP_DIR}/agent-repos.local}"
AGENT_REPOS_MANIFEST="$(expand_tilde "$AGENT_REPOS_MANIFEST")"

manifest_default_branch() {  # owner/name base -> branch on stdout, non-zero on failure
  local full="$1" base="$2" ref url
  if [[ -n "$base" ]]; then
    url="${base}/${full#*/}.git"
  else
    url="https://github.com/${full}.git"
  fi
  ref="$(GIT_TERMINAL_PROMPT=0 git ls-remote --symref "$url" HEAD 2>/dev/null \
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
    m_branch="$(manifest_default_branch "$full" "$CLONE_BASE" || true)"
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

clone_url_for() {  # name full -> URL on stdout
  if [[ -n "$CLONE_BASE" ]]; then printf '%s/%s.git' "$CLONE_BASE" "$1"
  else printf 'https://github.com/%s.git' "$2"; fi
}

planned_action() {  # dest -> short description of what a run would do
  local dest="$1" rc=0
  if [[ -d "${dest}/.git" ]]; then
    if [[ -n "$(git -C "$dest" status --porcelain 2>/dev/null)" ]]; then
      printf 'skip (dirty tree)'; return
    fi
    if tree_has_symlink "$dest"; then
      printf 'skip (symlink in tree)'; return
    fi
    if [[ -x "$CRED_CHECK" ]]; then
      "$CRED_CHECK" "$dest" >/dev/null 2>&1 || rc=$?
    fi
    if (( rc == 1 )); then printf 'skip (credential in remote)'; return; fi
    if (( rc == 2 )); then printf 'error (git config unreadable)'; return; fi
    printf 'update (fast-forward only)'
  elif [[ -e "$dest" ]]; then
    printf 'skip (exists but not a git repo)'
  else
    printf 'clone'
  fi
}

# ===========================================================================
# --dry-run : list the inventories and the planned action, change nothing.
# ===========================================================================
if [[ "$MODE" == "dry-run" ]]; then
  printf '\n%sPlanned actions (dry run, nothing is written):%s\n' "$C_INF" "$C_RST"
  printf '    API inventory (owner): %s repos\n' "${#FULLNAMES[@]}"
  for full in "${FULLNAMES[@]}"; do
    name="${full#*/}"
    dest="${AGENT_REPOS_DIR}/${name}"
    printf '    %-40s %s\n' "$full" "$(planned_action "$dest")"
  done
  printf '\n    Reference tree: %s\n' "$AGENT_REPOS_REAL"
  printf '\n'
  exit 0
fi

# ===========================================================================
# Normal run.
# ===========================================================================

# --- Lock ------------------------------------------------------------------
# One run at a time. flock -n fails immediately if another holds it. The fd is
# held for the whole run (opened on the lock file) and released when the
# process exits. A concurrent run changes nothing and exits 2.
mkdir -p "$AGENT_REPOS_DIR"
exec 9>"${AGENT_REPOS_DIR}/.sync.lock"
if ! flock -n 9; then
  die "another sync is running (lock ${AGENT_REPOS_DIR}/.sync.lock is held).
     Nothing was changed. Try again once the other run finishes."
fi

# Scratch dir for API pages, inside the tree (see above).
if [[ -z "${TMPDIR_SYNC:-}" ]]; then
  TMPDIR_SYNC="$(mktemp -d "${AGENT_REPOS_DIR}/.sync.XXXXXX")"
  trap 'rm -rf "$TMPDIR_SYNC"' EXIT
fi

# --- Sync ------------------------------------------------------------------
run_time="$(iso_now)"
n_total=0; n_cloned=0; n_updated=0; n_up_to_date=0; n_skipped=0; n_failed=0; n_stale=0
declare -A ASSERTED_NAMES=()
INV_NAME=(); INV_BRANCH=(); INV_HEAD=(); INV_STATUS=(); INV_TIME=()
inv_add() { INV_NAME+=("$1"); INV_BRANCH+=("$2"); INV_HEAD+=("$3"); INV_STATUS+=("$4"); INV_TIME+=("$5"); }

for full in "${FULLNAMES[@]}"; do
  owner="${REPO_OWNER[$full]}"
  name="${full#*/}"
  branch="${BRANCH[$full]}"
  dest="${AGENT_REPOS_DIR}/${name}"
  url="$(clone_url_for "$name" "$full")"
  n_total=$((n_total + 1))
  ASSERTED_NAMES["$name"]=1

  if [[ -d "${dest}/.git" ]]; then
    # Persist the symlink setting on the existing clone before the refresh.
    git -C "$dest" config core.symlinks false 2>/dev/null || true

    # A dirty tree is left alone: ff-only must never discard work.
    if [[ -n "$(git -C "$dest" status --porcelain 2>/dev/null)" ]]; then
      warn "Skipping ${name}: working tree is dirty (uncommitted changes)."
      n_skipped=$((n_skipped + 1))
      inv_add "$name" "$branch" "$(sha_short "$dest")" "skipped:dirty" "$run_time"
      continue
    fi

    # A tree that already holds a symlink is refused, never modified.
    if tree_has_symlink "$dest"; then
      warn "Skipping ${name}: working tree contains a symlink. Re-clone this repo by hand to replace it; nothing was changed."
      n_skipped=$((n_skipped + 1))
      inv_add "$name" "$branch" "$(sha_short "$dest")" "skipped:symlinks" "$run_time"
      continue
    fi

    # Refuse a clone whose git config embeds a credential, BEFORE any fetch.
    cred_rc=0
    cred_out=""
    if [[ -x "$CRED_CHECK" ]]; then
      cred_out="$("$CRED_CHECK" "$dest" 2>/dev/null)" || cred_rc=$?
    else
      cred_rc=2
    fi
    if (( cred_rc == 1 )); then
      relay_cred "$cred_out"
      warn "Skipping ${name}: a git remote embeds a credential (see the lines above)."
      n_skipped=$((n_skipped + 1))
      inv_add "$name" "$branch" "$(sha_short "$dest")" "skipped:credential-remote" "$run_time"
      continue
    elif (( cred_rc == 2 )); then
      relay_cred "$cred_out"
      warn "Error: ${name}: the credential check could not read the git config."
      n_failed=$((n_failed + 1))
      inv_add "$name" "$branch" "$(sha_short "$dest")" "error" "$run_time"
      continue
    fi

    # -c core.hooksPath=/dev/null on every git call: a repository must never be
    # able to run code on the host through a hook.
    head_before="$(git -C "$dest" rev-parse HEAD 2>/dev/null || true)"
    if git -C "$dest" -c core.hooksPath=/dev/null fetch --no-tags --prune origin >/dev/null 2>&1 \
       && git -C "$dest" -c core.hooksPath=/dev/null checkout --detach "$branch" >/dev/null 2>&1 \
       && git -C "$dest" -c core.hooksPath=/dev/null merge --ff-only "origin/${branch}" >/dev/null 2>&1; then
      head_after="$(git -C "$dest" rev-parse HEAD 2>/dev/null || true)"
      if [[ -n "$head_before" && "$head_before" == "$head_after" ]]; then
        ok "${name} already up to date (${branch})"
        n_up_to_date=$((n_up_to_date + 1))
        inv_add "$name" "$branch" "$(sha_short "$dest")" "up-to-date" "$run_time"
      else
        ok "Updated ${name} (${branch})"
        n_updated=$((n_updated + 1))
        inv_add "$name" "$branch" "$(sha_short "$dest")" "updated" "$run_time"
      fi
    else
      warn "Failed to refresh ${name} (${branch})."
      n_failed=$((n_failed + 1))
      inv_add "$name" "$branch" "$(sha_short "$dest")" "error" "$run_time"
    fi
    continue
  fi

  if [[ -e "$dest" ]]; then
    warn "Skipping ${name}: ${dest} exists but is not a git repository."
    n_skipped=$((n_skipped + 1))
    inv_add "$name" "$branch" "-" "skipped:not-a-repo" "$run_time"
    continue
  fi

  # Clone. No hooks (core.hooksPath=/dev/null), core.symlinks=false, no tags,
  # no submodules and no LFS smudge -- none of these may run code, plant a
  # symlink, or fetch extra data. Single branch keeps it to the default one.
  if GIT_LFS_SKIP_SMUDGE=1 GIT_TERMINAL_PROMPT=0 \
       git -c core.hooksPath=/dev/null -c core.symlinks=false clone \
         --single-branch --branch "$branch" --no-recurse-submodules --no-tags \
         "$url" "$dest" >/dev/null 2>&1; then
    git -C "$dest" config core.symlinks false 2>/dev/null || true
    ok "Cloned ${name} (${branch})"
    n_cloned=$((n_cloned + 1))
    inv_add "$name" "$branch" "$(sha_short "$dest")" "cloned" "$run_time"
  else
    warn "Failed to clone ${name} (${branch})."
    n_failed=$((n_failed + 1))
    inv_add "$name" "$branch" "-" "error" "$run_time"
  fi
done
unset owner name branch dest url full

# --- Stale: a real clone on disk that is no longer in the inventory --------
# Only directories that are actually git clones count. A non-git directory is
# ignored here (it is never modified or reported as a clone), matching --check,
# which relies on the directory existing. Nothing is ever deleted.
for dpath in "$AGENT_REPOS_DIR"/*/; do
  [[ -d "${dpath}.git" ]] || continue
  dname="$(basename "$dpath")"
  [[ "$dname" == .* ]] && continue
  [[ -n "${ASSERTED_NAMES[$dname]:-}" ]] && continue
  n_stale=$((n_stale + 1))
  inv_add "$dname" "-" "$(sha_short "$dpath")" "stale" "$run_time"
  warn "stale: ${dname} is on disk but no longer in the inventory (left in place)."
done
unset dpath dname

# --- Inventory (atomic) ----------------------------------------------------
n_rows="${#INV_NAME[@]}"
expected=$((n_total + n_stale))
if (( n_rows != expected )); then
  die "Inventory reconciliation failed: ${n_rows} row(s) written, ${expected} expected."
fi

inv_tmp="$(mktemp "${AGENT_REPOS_DIR}/.INVENTORY.XXXXXX")"
{
  printf '# Agent repo reference tree inventory\n\n'
  printf -- '- Generated (UTC): %s\n' "$run_time"
  printf -- '- Directory: %s\n' "$AGENT_REPOS_REAL"
  printf -- '- Totals: %d repositories | %d cloned | %d updated | %d up-to-date | %d skipped | %d error | %d stale\n\n' \
    "$n_rows" "$n_cloned" "$n_updated" "$n_up_to_date" "$n_skipped" "$n_failed" "$n_stale"
  printf '| Repository | Default branch | HEAD | Status | Last sync (UTC) |\n'
  printf '| --- | --- | --- | --- | --- |\n'
  i=0
  while (( i < n_rows )); do
    printf '| %s | %s | %s | %s | %s |\n' \
      "${INV_NAME[$i]}" "${INV_BRANCH[$i]}" "${INV_HEAD[$i]}" "${INV_STATUS[$i]}" "${INV_TIME[$i]}"
    i=$((i + 1))
  done
} > "$inv_tmp"
mv -f "$inv_tmp" "$INV_PATH"
ok "Inventory written: ${INV_PATH}"

# --- Report ----------------------------------------------------------------
printf '\n'
ok "Agent repo reference tree synced"
printf '    Directory : %s\n' "$AGENT_REPOS_REAL"
printf '    Repos     : %d total, %d cloned, %d updated, %d up-to-date, %d skipped, %d stale, %d failed\n' \
  "$n_total" "$n_cloned" "$n_updated" "$n_up_to_date" "$n_skipped" "$n_stale" "$n_failed"
printf '    Mounted in the Hermes container READ-ONLY at /agent-repos\n'
printf '\n'

exit_code=0
if (( n_failed > 0 )); then
  exit_code=2
elif (( n_skipped > 0 || n_stale > 0 )); then
  exit_code=1
fi
exit "$exit_code"
