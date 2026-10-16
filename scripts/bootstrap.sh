#!/usr/bin/env bash
set -Eeuo pipefail
# ---------------------------------------------------------------------------
# FILE: scripts/bootstrap.sh
# PURPOSE (plain English):
#   The ONE privileged, one-time setup command the owner runs per device. It
#   stands up a brand-new host AND migrates the current Pi to the target
#   layout: system accounts, FHS paths, system-mode backup and the headless
#   deploy account. Run it once with sudo, then never again.
#
#   It is IDEMPOTENT. A second run on a bootstrapped host changes nothing and
#   exits 0. It never creates an account that already exists; it verifies it.
#
# WHY IT EXISTS (the two problems it closes):
#   1. install.sh already knows how to install the system-mode backup units and
#      the deploy pieces when it runs as root, but nothing did the one-time,
#      root-only work first: create the three system accounts and the credential
#      directory, lay out /opt, /var/lib, /var/log and /etc, and hand over the
#      deploy key. That is this script.
#   2. The stack's secrets and the host LAYOUT used to share one env file, and
#      install.sh REWROTE that file on every run. A root deploy would therefore
#      erase HYBRID_AI_BACKUP_MODE=system and could not leave the file readable
#      by the backup account it needed. The layout now lives in
#      /etc/hybrid-ai/hybrid-ai.env (mode 0644, names and paths only) and the
#      secrets live in /etc/hybrid-ai/stack.env (mode 0600). install.sh writes
#      ONLY the stack file. See scripts/lib/hybrid-ai-env.sh.
#
# SAFE TO RE-RUN; NOT SAFE TO SKIP:
#   The accounts are least-privilege by construction: each gets its own group
#   and none is added to docker, sudo or systemd-journal. hybrid-ai-deploy has a
#   /bin/sh shell and a LOCKED password because sshd runs the forced command
#   through the account's login shell; a nologin shell would refuse it.
#
# NO SECRET IS EVER PRINTED, LOGGED OR WRITTEN BY THIS SCRIPT:
#   It never prints a value from .env, stack.env, r2.env or repo-password, and
#   the migration manifest records PATHS ONLY. It does not generate, rotate or
#   print any key, token or credential.
#
# USAGE:
#   sudo ./scripts/bootstrap.sh --deploy-pubkey <file> [--from <legacy-repo-dir>] \
#                               [--login-user <name>]
#
#     --deploy-pubkey <file>  the PUBLIC key the headless deploy will use. One
#                             key, no options. Installed as the forced-command
#                             line in ~hybrid-ai-deploy/.ssh/authorized_keys.
#     --from <dir>            migrate from a legacy checkout instead of a fresh
#                             install. Moves, never copies or merges.
#     --login-user <name>     the login account to migrate away from.
#                             Defaults to SUDO_USER.
#
# DIAGNOSTIC (touches nothing):
#   --print-paths             print the resolved host paths and exit 0
#   -h | --help               print this header and exit 0
#
# TEST-ONLY:
#   HYBRID_AI_BOOTSTRAP_ROOT  a filesystem prefix for the offline test. UNSET
#                             means "/" (the real filesystem), which is the
#                             default. scripts/test-bootstrap.sh sets it to a
#                             scratch directory.
#
# EXIT CODES (one per refusal class):
#   0  success (including a no-change re-run)
#   1  usage error, or an existing host object that fails verification
#   2  not run as root
#   3  the deploy public key was refused (a private key, more than one key, or
#      a line that already carries options)
#   4  /opt/hybrid-ai exists but is not a clone of the public remote, or its
#      origin carries a credential
#   5  polkitd is absent, or its version predates .rules (JavaScript) support
#   6  a migration move is cross-device, or a move target already exists and is
#      not empty (refused BEFORE any move)
#   7  install.sh failed
#   8  doctor.sh failed
# ---------------------------------------------------------------------------

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

# --- Test-only filesystem prefix -------------------------------------------
# UNSET (the default) means "/", the real filesystem. scripts/test-bootstrap.sh
# sets HYBRID_AI_BOOTSTRAP_ROOT to a scratch directory so the whole script can
# be exercised with no root, no Docker and no network.
ROOT_PREFIX="${HYBRID_AI_BOOTSTRAP_ROOT:-/}"
[[ "$ROOT_PREFIX" == /* ]] || { printf 'bootstrap: HYBRID_AI_BOOTSTRAP_ROOT must be an absolute path.\n' >&2; exit 1; }
ROOT_PREFIX="${ROOT_PREFIX%/}"
# Prefix a host path. With ROOT_PREFIX empty (the default "/") this is the
# identity. A path that already sits under the prefix (as a stubbed getent
# returns during the offline test) is returned unchanged, so the prefix is
# never applied twice.
host_path() {
  local p="$1"
  if [[ -n "$ROOT_PREFIX" && ( "$p" == "$ROOT_PREFIX" || "$p" == "$ROOT_PREFIX"/* ) ]]; then
    printf '%s' "$p"
    return 0
  fi
  printf '%s' "${ROOT_PREFIX}$p"
}

# --- Fixed layout ----------------------------------------------------------
APP_DIR="$(host_path /opt/hybrid-ai)"
ETC_DIR="$(host_path /etc/hybrid-ai)"
LAYOUT_ENV="${ETC_DIR}/hybrid-ai.env"
STACK_ENV="${ETC_DIR}/stack.env"
CRED_DIR="$(host_path /etc/credstore/hybrid-ai-backup)"
DATA_DIR="$(host_path /var/lib/hybrid-ai)"
WORK_DIR="${DATA_DIR}/work"
LOG_DIR="$(host_path /var/log/hybrid-ai)"
# The agent workspace and the repo reference tree are SIBLINGS of the data dir,
# never children of it. setup-agent-workspace.sh and sync-agent-repos.sh both
# refuse a path inside HYBRID_AI_DATA_DIR (it would sit one traversal away from
# the stack env file and the backup credentials), so the bootstrap must render
# these two paths outside it.
AGENT_WS="$(host_path /var/lib/hybrid-ai-agent)"
AGENT_REPOS="$(host_path /var/lib/hybrid-ai-repos)"
OPENHANDS_STATE="${DATA_DIR}/openhands"
HERMES_HOME="${DATA_DIR}/hermes-home"
HERMES_DATA="${DATA_DIR}/hermes_data"
RESTIC_CACHE="$(host_path /var/cache/hybrid-ai-backup)"
SYSTEMD_DIR="$(host_path /etc/systemd/system)"
DEPLOY_HOME="$(host_path /var/lib/hybrid-ai-deploy)"
BACKUP_HOME="$(host_path /var/lib/hybrid-ai-backup)"
LOGIN_DEFS="$(host_path /etc/login.defs)"

# The PUBLIC https remote, by name only. Same canonical URL deploy-instance.sh
# fetches from. Never a value from a file.
PUBLIC_REMOTE="https://github.com/jimbobsyouruncle/hybrid-ai.git"

# Account names. Names only -- never a credential.
STACK_ACCOUNT="hybrid-ai"
BACKUP_ACCOUNT="hybrid-ai-backup"
DEPLOY_ACCOUNT="hybrid-ai-deploy"

usage() { awk 'NR==1{next} /^set -Eeuo pipefail/{exit} {sub(/^# ?/,""); print}' "${BASH_SOURCE[0]}"; }

print_paths() {
  printf 'root                     = %s\n' "${ROOT_PREFIX:-/}"
  printf 'HYBRID_AI_APP_DIR        = %s\n' "$APP_DIR"
  printf 'HYBRID_AI_ENV_FILE       = %s\n' "$LAYOUT_ENV"
  printf 'HYBRID_AI_STACK_ENV_FILE = %s\n' "$STACK_ENV"
  printf 'HYBRID_AI_DATA_DIR       = %s\n' "$DATA_DIR"
  printf 'HYBRID_AI_LOG_DIR        = %s\n' "$LOG_DIR"
  printf 'HYBRID_AI_WORK_DIR       = %s\n' "$WORK_DIR"
  printf 'OPENHANDS_WORKSPACE      = %s\n' "$AGENT_WS"
  printf 'AGENT_REPOS_DIR          = %s\n' "$AGENT_REPOS"
  printf 'OPENHANDS_STATE_DIR      = %s\n' "$OPENHANDS_STATE"
  printf 'HYBRID_AI_HERMES_HOME_DIR= %s\n' "$HERMES_HOME"
  printf 'RESTIC_CACHE_DIR         = %s\n' "$RESTIC_CACHE"
  printf 'creds                    = %s\n' "$CRED_DIR"
}

# --- Argument parsing ------------------------------------------------------
DEPLOY_PUBKEY=""
FROM=""
LOGIN_USER=""

while (( $# > 0 )); do
  case "$1" in
    --deploy-pubkey) DEPLOY_PUBKEY="${2:-}"; shift 2 ;;
    --from)          FROM="${2:-}";          shift 2 ;;
    --login-user)    LOGIN_USER="${2:-}";    shift 2 ;;
    --print-paths)   print_paths; exit 0 ;;
    -h|--help)       usage; exit 0 ;;
    *) die 1 "unknown argument: $1 (see --help)" ;;
  esac
done

[[ -n "$DEPLOY_PUBKEY" ]] || die 1 "--deploy-pubkey is required (see --help)"

# --- 1. Root only ----------------------------------------------------------
[[ "$(id -u)" == "0" ]] || die 2 "must run as root: sudo ./scripts/bootstrap.sh --deploy-pubkey <file>"

LOGIN_USER="${LOGIN_USER:-${SUDO_USER:-}}"
[[ -n "$LOGIN_USER" ]] || die 1 "--login-user is required when SUDO_USER is not set"
MIGRATION=0
[[ -n "$FROM" ]] && MIGRATION=1

# --- 2. Validate the deploy public key (refuse 3) --------------------------
# Exactly one line, a public key, no options. A private key or an option-bearing
# line is refused: an options prefix in the pubkey file could replace the forced
# command later, so it must be rejected at the door.
read_pubkey() {
  local line count=0 ktype="" kblob="" first=""
  local -a lines=()
  [[ -f "$DEPLOY_PUBKEY" ]] || die 3 "--deploy-pubkey does not exist: $DEPLOY_PUBKEY"
  grep -q 'PRIVATE KEY' "$DEPLOY_PUBKEY" 2>/dev/null && \
    die 3 "--deploy-pubkey looks like a PRIVATE key; give the public key file"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    lines+=("$line")
    count=$(( count + 1 ))
  done < "$DEPLOY_PUBKEY"
  (( count == 1 )) || die 3 "--deploy-pubkey must hold exactly one key (found ${count})"
  line="${lines[0]}"
  first="${line%%[[:space:]]*}"
  case "$first" in
    ssh-ed25519|ssh-rsa|ssh-dss|ecdsa-sha2-*|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com) ;;
    *) die 3 "the key line does not start with a known key type (it may carry options); give a bare '<type> <base64>' line" ;;
  esac
  ktype="$first"
  kblob="$(printf '%s' "$line" | awk '{print $2}')"
  [[ -n "$kblob" ]] || die 3 "the key line has no base64 body"
  printf '%s %s' "$ktype" "$kblob"
}
DEPLOY_KEY="$(read_pubkey)"
[[ -n "$DEPLOY_KEY" ]] || die 3 "could not read a public key from $DEPLOY_PUBKEY"
KEY_TYPE="${DEPLOY_KEY%% *}"
KEY_BLOB="${DEPLOY_KEY#* }"

# --- 3. polkit must be present AND support .rules files (refuse 5) ---------
POLKIT_DIR=""
detect_polkit() {
  command -v pkcheck >/dev/null 2>&1 || \
    die 5 "polkit is absent (pkcheck not found); a .rules file would grant nothing"
  local ver major minor
  ver="$(pkaction --version 2>/dev/null | awk '{print $NF}' || true)"
  [[ -n "$ver" ]] || die 5 "could not read the polkit version; .rules support cannot be confirmed"
  major="${ver%%.*}"; minor="${ver#*.}"; minor="${minor%%.*}"
  [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] || \
    die 5 "could not parse the polkit version '${ver}'"
  if (( major == 0 && minor < 106 )); then
    die 5 "polkit ${ver} predates .rules (JavaScript) support; the deploy rule cannot be loaded"
  fi
  local d
  for d in "$(host_path /etc/polkit-1/rules.d)" "$(host_path /usr/share/polkit-1/rules.d)"; do
    if [[ -d "$d" ]]; then POLKIT_DIR="$d"; break; fi
  done
  [[ -n "$POLKIT_DIR" ]] || die 5 "no polkit rules directory found (.rules support unconfirmed)"
}
detect_polkit

# --- 4. /opt/hybrid-ai must be a clean clone of the public remote (refuse 4)
# A URL scheme with userinfo (or an scp-like form) means a credential sits in
# the checkout's config; refuse it, exactly as deploy-instance.sh does.
url_has_userinfo() {
  local v="$1"
  [[ "$v" == *://* ]] || return 1
  local authority="${v#*://}"; authority="${authority%%/*}"
  [[ "$authority" == *@* ]]
}

git_public() {
  GIT_TERMINAL_PROMPT=0 GIT_CONFIG_NOSYSTEM=1 \
  git -c core.hooksPath=/dev/null -c credential.helper= -c http.extraHeader= "$@"
}

prepare_app_dir() {
  if [[ -e "$APP_DIR" ]]; then
    [[ -d "$APP_DIR/.git" ]] || \
      die 4 "$APP_DIR exists but is not a git clone of ${PUBLIC_REMOTE}"
    local origin
    origin="$(git -C "$APP_DIR" config --get remote.origin.url 2>/dev/null || true)"
    if url_has_userinfo "$origin"; then
      die 4 "$APP_DIR origin carries a credential; refusing to fetch through it"
    fi
    if [[ "$origin" != "$PUBLIC_REMOTE" ]]; then
      die 4 "$APP_DIR origin is not the public remote (${PUBLIC_REMOTE}); refusing"
    fi
    log "Updating ${APP_DIR} to origin/main..."
    git_public -C "$APP_DIR" fetch --prune --no-tags "$PUBLIC_REMOTE" \
      "+refs/heads/main:refs/remotes/origin/main" \
      || die 1 "fetching main into ${APP_DIR} failed"
    git -C "$APP_DIR" reset --hard origin/main >/dev/null \
      || die 1 "resetting ${APP_DIR} to origin/main failed"
  else
    log "Cloning ${PUBLIC_REMOTE} into ${APP_DIR}..."
    git_public clone --no-tags "$PUBLIC_REMOTE" "$APP_DIR" \
      || die 1 "cloning ${PUBLIC_REMOTE} failed"
    git -C "$APP_DIR" fetch --prune --no-tags "$PUBLIC_REMOTE" \
      "+refs/heads/main:refs/remotes/origin/main" \
      || die 1 "fetching main into ${APP_DIR} failed"
    git -C "$APP_DIR" reset --hard origin/main >/dev/null \
      || die 1 "resetting ${APP_DIR} to origin/main failed"
    ok "Cloned ${APP_DIR}."
  fi
}
prepare_app_dir

# --- 5. Accounts -----------------------------------------------------------
UID_MIN="$(awk '/^[[:space:]]*UID_MIN/ {print $2; exit}' "$LOGIN_DEFS" 2>/dev/null || true)"
GID_MIN="$(awk '/^[[:space:]]*GID_MIN/ {print $2; exit}' "$LOGIN_DEFS" 2>/dev/null || true)"
[[ "$UID_MIN" =~ ^[0-9]+$ ]] || UID_MIN=1000
[[ "$GID_MIN" =~ ^[0-9]+$ ]] || GID_MIN=1000

NOLOGIN_SHELL="$(host_path /usr/sbin/nologin)"
[[ -x "$NOLOGIN_SHELL" ]] || NOLOGIN_SHELL="$(host_path /sbin/nologin)"
[[ -x "$NOLOGIN_SHELL" ]] || NOLOGIN_SHELL="$(host_path /bin/false)"
DEPLOY_SHELL="$(host_path /bin/sh)"

account_exists()  { getent passwd "$1" >/dev/null 2>&1; }
account_uid()     { getent passwd "$1" 2>/dev/null | cut -d: -f3; }
account_gid()     { getent passwd "$1" 2>/dev/null | cut -d: -f4; }
account_shell()   { getent passwd "$1" 2>/dev/null | cut -d: -f7; }
account_home()    { getent passwd "$1" 2>/dev/null | cut -d: -f6; }
group_exists()    { getent group  "$1" >/dev/null 2>&1; }

# True when the account name appears in the group's member list. Group
# membership (not the primary group) is what grants docker/sudo/journal access.
in_group() {
  local acct="$1" grp="$2" members
  members="$(getent group "$grp" 2>/dev/null | cut -d: -f4)"
  [[ ",${members}," == *",${acct},"* ]]
}

verify_not_privileged() {
  local acct="$1" g
  for g in docker sudo systemd-journal; do
    if in_group "$acct" "$g"; then
      die 1 "${acct} is in the '${g}' group; remove it first: gpasswd -d ${acct} ${g}"
    fi
  done
}

# Create the account, or verify an existing one. Never recreates.
ensure_account() {
  local acct="$1" shell="$2" home="$3" changed=0
  if account_exists "$acct"; then
    local uid
    uid="$(account_uid "$acct")"
    if [[ ! "$uid" =~ ^[0-9]+$ ]] || (( uid >= UID_MIN )); then
      die 1 "${acct} has uid ${uid}, which is not below UID_MIN=${UID_MIN}; it is not a system account"
    fi
    if [[ "$(account_shell "$acct")" != "$shell" ]]; then
      die 1 "${acct} has shell $(account_shell "$acct"), expected ${shell}"
    fi
    verify_not_privileged "$acct"
    if [[ "$acct" == "$DEPLOY_ACCOUNT" ]]; then
      local shadow
      shadow="$(getent shadow "$acct" 2>/dev/null | cut -d: -f2)"
      if [[ "$shadow" != "!"* && "$shadow" != "*"* ]]; then
        usermod -L "$acct" && changed=1
        warn "${acct} password was not locked; locked it now."
      fi
    fi
    if (( changed )); then
      ok "${acct} verified (uid ${uid}, shell ${shell})."
    else
      ok "${acct} already correct (uid ${uid})."
    fi
    return 0
  fi
  if ! group_exists "$acct"; then
    groupadd --system "$acct" || die 1 "could not create the group ${acct}"
  fi
  useradd --system --gid "$acct" --home-dir "$home" --no-create-home \
          --shell "$shell" "$acct" || die 1 "could not create the account ${acct}"
  if [[ "$acct" == "$DEPLOY_ACCOUNT" ]]; then
    # A LOCKED password. sshd runs the forced command through the login shell,
    # so the shell must be a real one; the lock keeps it from ever logging in.
    usermod -L "$acct" || warn "could not lock the ${acct} password"
  fi
  verify_not_privileged "$acct"
  ok "Created system account ${acct} ($(account_uid "$acct"), shell ${shell})."
}

ensure_account "$STACK_ACCOUNT"  "$NOLOGIN_SHELL" "$DATA_DIR"
ensure_account "$BACKUP_ACCOUNT" "$NOLOGIN_SHELL" "$BACKUP_HOME"
ensure_account "$DEPLOY_ACCOUNT" "$DEPLOY_SHELL"  "$DEPLOY_HOME"

STACK_UID="$(account_uid "$STACK_ACCOUNT")"
STACK_GID="$(account_gid "$STACK_ACCOUNT")"
[[ "$STACK_UID" =~ ^[0-9]+$ && "$STACK_GID" =~ ^[0-9]+$ ]] || \
  die 1 "could not read the ${STACK_ACCOUNT} uid/gid"

# --- 6. Layout -------------------------------------------------------------
make_dir() { # mode owner:group path
  local mode="$1" own="$2" path="$3"
  mkdir -p "$path" || die 1 "could not create ${path}"
  chmod "$mode" "$path" || die 1 "could not set mode ${mode} on ${path}"
  chown "$own" "$path" || die 1 "could not set ownership on ${path}"
}
make_dir 0755 root:root "$ETC_DIR"
make_dir 0700 root:root "$CRED_DIR"
make_dir 0755 root:root "$DATA_DIR"
make_dir 0755 root:root "$WORK_DIR"
make_dir 0755 root:root "$LOG_DIR"
# The agent workspace and repo tree belong to the stack account: the OpenHands
# sandbox and the Hermes mount both read them.
make_dir 0755 "${STACK_ACCOUNT}:${STACK_ACCOUNT}" "$AGENT_WS"
make_dir 0755 "${STACK_ACCOUNT}:${STACK_ACCOUNT}" "$AGENT_REPOS"
make_dir 0755 root:root "$OPENHANDS_STATE"
# Empty, owned by the stack account: it is that account's per-user Hermes home.
make_dir 0700 "${STACK_ACCOUNT}:${STACK_ACCOUNT}" "$HERMES_HOME"
# Pre-created and owned by the stack account: install.sh's non-root Hermes
# preflight refuses unless the configured HYBRID_AI_UID owns every entry in
# hermes_data, and install.sh cannot chown it itself.
make_dir 0755 "${STACK_ACCOUNT}:${STACK_ACCOUNT}" "$HERMES_DATA"
make_dir 0755 "${BACKUP_ACCOUNT}:${BACKUP_ACCOUNT}" "$RESTIC_CACHE"
make_dir 0700 "${DEPLOY_ACCOUNT}:${DEPLOY_ACCOUNT}" "$DEPLOY_HOME"
make_dir 0755 root:root "$SYSTEMD_DIR"
ok "Layout ready under ${ROOT_PREFIX:-/}."

# --- 7. The layout env file (names and paths only, 0644) -------------------
# NO SECRET IS EVER WRITTEN HERE. It is world-readable by design: the backup
# account and the deploy account must both read it, and it holds no value.
render_layout() {
  cat <<EOF
# ---------------------------------------------------------------------------
# GENERATED BY scripts/bootstrap.sh -- the host LAYOUT. NAMES AND PATHS ONLY.
# Mode 0644, root-owned: the backup account and the deploy account read it.
# NEVER put a secret in this file. Secrets live in
# HYBRID_AI_STACK_ENV_FILE (mode 0600), which install.sh writes.
# Every setting below is resolved by scripts/lib/hybrid-ai-env.sh.
# ---------------------------------------------------------------------------
HYBRID_AI_APP_DIR=${APP_DIR}
HYBRID_AI_ENV_FILE=${LAYOUT_ENV}
HYBRID_AI_STACK_ENV_FILE=${STACK_ENV}
HYBRID_AI_DATA_DIR=${DATA_DIR}
HYBRID_AI_LOG_DIR=${LOG_DIR}
HYBRID_AI_WORK_DIR=${WORK_DIR}
OPENHANDS_WORKSPACE=${AGENT_WS}
AGENT_REPOS_DIR=${AGENT_REPOS}
OPENHANDS_STATE_DIR=${OPENHANDS_STATE}
RESTIC_CACHE_DIR=${RESTIC_CACHE}
HYBRID_AI_HERMES_HOME_DIR=${HERMES_HOME}
HYBRID_AI_BACKUP_MODE=system
BACKUP_CONTAINER_CONTROL=external
HYBRID_AI_UID=${STACK_UID}
HYBRID_AI_GID=${STACK_GID}
EOF
}

write_layout() {
  local tmp
  tmp="$(mktemp "${ETC_DIR}/.layout.XXXXXX")" || die 1 "could not stage the layout file"
  chmod 0644 "$tmp"
  render_layout > "$tmp"
  if [[ -f "$LAYOUT_ENV" ]] && cmp -s "$tmp" "$LAYOUT_ENV"; then
    rm -f "$tmp"
    ok "${LAYOUT_ENV} already current (0644)."
  else
    chown root:root "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$LAYOUT_ENV"
    chmod 0644 "$LAYOUT_ENV"
    chown root:root "$LAYOUT_ENV" 2>/dev/null || true
    ok "Wrote ${LAYOUT_ENV} (0644, names and paths only)."
  fi
}
write_layout

# Prove BOTH accounts can read the layout file, by reading it AS that account.
prove_readable() {
  local acct="$1"
  runuser -u "$acct" -- test -r "$LAYOUT_ENV" \
    || die 1 "${acct} cannot read ${LAYOUT_ENV}; the backup/deploy pieces would fall back to the wrong paths"
}
prove_readable "$BACKUP_ACCOUNT"
prove_readable "$DEPLOY_ACCOUNT"
ok "Both ${BACKUP_ACCOUNT} and ${DEPLOY_ACCOUNT} can read ${LAYOUT_ENV}."

# --- 8. Deploy pieces ------------------------------------------------------
# The system unit is installed but NEVER enabled: an instantiated unit is
# started explicitly by the forced command and the polkit rule, nothing else.
install -m 0644 "$APP_DIR/deploy/hybrid-ai-deploy@.service" \
  "${SYSTEMD_DIR}/hybrid-ai-deploy@.service" \
  || die 1 "could not install the deploy unit"
ok "Installed hybrid-ai-deploy@.service (0644, not enabled)."

install -m 0644 "$APP_DIR/deploy/50-hybrid-ai-deploy.rules" \
  "${POLKIT_DIR}/50-hybrid-ai-deploy.rules" \
  || die 1 "could not install the polkit rule"
ok "Installed 50-hybrid-ai-deploy.rules into ${POLKIT_DIR} (0644)."

command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1 || true
systemctl reload polkit >/dev/null 2>&1 || systemctl restart polkit >/dev/null 2>&1 || \
  warn "Could not reload polkit; reload it by hand: systemctl reload polkit"

# The authorized_keys line, EXACTLY one, pinned to the forced command.
install_deploy_key() {
  local ssh_dir="${DEPLOY_HOME}/.ssh"
  local key_file="${ssh_dir}/authorized_keys"
  local line="restrict,command=\"${APP_DIR}/scripts/deploy-forced-command.sh\" ${KEY_TYPE} ${KEY_BLOB}"
  make_dir 0700 "${DEPLOY_ACCOUNT}:${DEPLOY_ACCOUNT}" "$ssh_dir"
  printf '%s\n' "$line" > "${key_file}.tmp" || die 1 "could not write authorized_keys"
  chmod 0600 "${key_file}.tmp"
  chown "$DEPLOY_ACCOUNT:$DEPLOY_ACCOUNT" "${key_file}.tmp" 2>/dev/null || true
  mv -f "${key_file}.tmp" "$key_file"
  chmod 0600 "$key_file"
  chown "$DEPLOY_ACCOUNT:$DEPLOY_ACCOUNT" "$key_file" 2>/dev/null || true
  ok "Installed the forced-command key line for ${DEPLOY_ACCOUNT}."
}
install_deploy_key

# If AllowUsers/AllowGroups would block the account, PRINT the line to add.
# Never edit sshd_config.
check_sshd_allow() {
  command -v sshd >/dev/null 2>&1 || { warn "sshd not found; skipped the AllowUsers/AllowGroups check."; return 0; }
  local out allowusers allowgroups grp
  out="$(sshd -T 2>/dev/null || true)"
  [[ -n "$out" ]] || { warn "sshd -T produced no output; skipped the AllowUsers/AllowGroups check."; return 0; }
  allowusers="$(printf '%s\n' "$out" | awk 'tolower($1)=="allowusers"{ $1=""; print }')"
  allowgroups="$(printf '%s\n' "$out" | awk 'tolower($1)=="allowgroups"{ $1=""; print }')"
  grp="$DEPLOY_ACCOUNT"
  if [[ -n "$allowusers" ]] && [[ " $allowusers " != *" ${DEPLOY_ACCOUNT} "* ]]; then
    warn "sshd AllowUsers would block ${DEPLOY_ACCOUNT}. Add this to sshd_config, then reload sshd:"
    printf '    AllowUsers %s\n' "${DEPLOY_ACCOUNT}"
  fi
  if [[ -n "$allowgroups" ]] && [[ " $allowgroups " != *" ${grp} "* ]]; then
    warn "sshd AllowGroups would block ${DEPLOY_ACCOUNT} (group ${grp}). Add this to sshd_config, then reload sshd:"
    printf '    AllowGroups %s\n' "$grp"
  fi
}
check_sshd_allow

# --- 9. Migration: moves, never copies or merges ---------------------------
MANIFEST=""
MANIFEST_ENTRIES=0

manifest_record() { # path-only line
  [[ -n "$MANIFEST" ]] || return 0
  if (( MANIFEST_ENTRIES == 0 )); then
    { printf '# bootstrap migration manifest (paths only, no values)\n'
      printf '# UTC %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$MANIFEST"
    chmod 0600 "$MANIFEST"
  fi
  printf '%s\n' "$1" >> "$MANIFEST"
  MANIFEST_ENTRIES=$(( MANIFEST_ENTRIES + 1 ))
}

# Read one key from a file, line by line, never sourcing. Never prints a value.
file_get() {
  local file="$1" key="$2" line candidate
  [[ -r "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*${key}=(.*)$ ]] || continue
    candidate="${BASH_REMATCH[1]}"
    candidate="${candidate%\"}"; candidate="${candidate#\"}"
    candidate="${candidate%\'}"; candidate="${candidate#\'}"
    printf '%s' "$candidate"
  done < "$file"
}

# Refuse (exit 6) when a move is cross-device or its target already holds data.
# $3 = --allow-existing-target lets a FILE move replace a pre-existing target
# (install.log/backup.log). It never allows a cross-device move.
preflight_move() {
  local src="$1" tgt="$2" allow="${3:-}"
  [[ -e "$src" ]] || return 0
  local srcd tgtp
  srcd="$(stat -c '%d' "$src" 2>/dev/null || echo x)"
  if [[ -e "$tgt" ]]; then
    # An EMPTY directory target is replaceable by a directory move (move_into
    # rmdirs it first): that is how the pre-created data dirs are handled. Every
    # other pre-existing target is the documented "non-empty target" refusal
    # (exit 6), unless the caller explicitly allows replacing a file.
    if [[ -d "$src" && -d "$tgt" && -z "$(ls -A "$tgt" 2>/dev/null)" ]]; then
      :
    elif [[ "$allow" == "--allow-existing-target" ]]; then
      :
    else
      die 6 "refusing to move ${src}: target ${tgt} already exists (non-empty target)"
    fi
  fi
  tgtp="$(dirname "$tgt")"
  if [[ -e "$tgt" && -d "$tgt" ]]; then
    tgtp="$tgt"
  fi
  local tgtd
  tgtd="$(stat -c '%d' "$tgtp" 2>/dev/null || echo y)"
  if [[ "$srcd" == "x" || "$tgtd" == "y" ]]; then
    die 6 "could not determine the filesystem of ${src} or ${tgtp}"
  fi
  if [[ "$srcd" != "$tgtd" ]]; then
    die 6 "refusing to move ${src} to ${tgt}: cross-device (not a rename)"
  fi
}

# Move a source into a target path with rename semantics. Records the move.
move_into() {
  local src="$1" tgt="$2" label="${3:-}"
  [[ -e "$src" ]] || return 0
  if [[ -e "$tgt" && -d "$tgt" && -z "$(ls -A "$tgt" 2>/dev/null)" ]]; then
    rmdir "$tgt"
  fi
  mv -- "$src" "$tgt" || die 1 "could not move ${src} to ${tgt}"
  manifest_record "${label:-move} ${src} -> ${tgt}"
  ok "Moved ${src} -> ${tgt}"
}

move_file_byte_identical() { # src tgt mode [--allow-existing-target]
  local src="$1" tgt="$2" mode="$3" allow="${4:-}"
  [[ -e "$src" ]] || return 0
  # Same refusal class as the data-dir moves: cross-device, or a target that
  # already exists (exit 6) -- never the generic exit 1, and never a silent
  # overwrite. install.log/backup.log routinely already exist under the target
  # log dir, so those two call sites pass --allow-existing-target.
  preflight_move "$src" "$tgt" "$allow"
  mv -- "$src" "$tgt" || die 1 "could not move ${src} to ${tgt}"
  chmod "$mode" "$tgt"
  chown root:root "$tgt" 2>/dev/null || true
  manifest_record "move ${src} -> ${tgt}"
  ok "Moved ${src} -> ${tgt} (${mode}, byte-identical)."
}

run_migration() {
  [[ -d "$FROM" ]] || die 1 "--from ${FROM} is not a directory"
  local legacy_env="${FROM}/.env"
  local login_home
  login_home="$(account_home "$LOGIN_USER")"
  [[ -n "$login_home" ]] || die 1 "could not read the home directory of ${LOGIN_USER}"
  login_home="$(host_path "$login_home")"


  # (a) Stop the stack. `down`, never -v.
  # The env file is the LEGACY .env on a first run. A completed migration moved
  # that file to the stack env file, so a re-run must stop the stack with
  # whichever env file is readable: the legacy one if present, else the resolved
  # stack env file. When neither is readable the stop is skipped with a warning
  # ONLY if no `hybrid-ai` compose container is running; otherwise it refuses.
  if [[ -f "${FROM}/docker-compose.yml" ]]; then
    local stop_env="$legacy_env"
    [[ -r "$stop_env" ]] || stop_env="$STACK_ENV"
    if [[ -r "$stop_env" ]]; then
      log "Stopping the running stack (down, never -v)..."
      docker compose -p hybrid-ai --env-file "$stop_env" --project-directory "$FROM" \
        -f "${FROM}/docker-compose.yml" \
        -f "${FROM}/openhands/docker-compose.openhands.yml" \
        -f "${FROM}/hermes/docker-compose.hermes.yml" down \
        || die 1 "could not stop the stack; refusing to migrate while it runs"
    else
      local running
      running="$(docker ps -q --filter 'label=com.docker.compose.project=hybrid-ai' 2>/dev/null || true)"
      if [[ -z "$running" ]]; then
        warn "No readable env file ('${legacy_env}' or '${STACK_ENV}'); no hybrid-ai container is running, so the stop step is skipped."
      else
        die 1 "could not stop the stack; refusing to migrate while it runs"
      fi
    fi
  else
    warn "No docker-compose.yml under ${FROM}; skipped the stop step."
  fi

  # (b) The legacy OpenHands paths, from the legacy .env, then the defaults.
  local legacy_ws legacy_repos legacy_state
  legacy_ws="$(file_get "$legacy_env" OPENHANDS_WORKSPACE)";     legacy_ws="${legacy_ws:-${login_home}/hybrid-ai-agent}"
  legacy_repos="$(file_get "$legacy_env" AGENT_REPOS_DIR)";      legacy_repos="${legacy_repos:-${login_home}/hybrid-ai-repos}"
  legacy_state="$(file_get "$legacy_env" OPENHANDS_STATE_DIR)";  legacy_state="${legacy_state:-${login_home}/.openhands}"

  # (c) Refuse BEFORE any move. Every source is checked here, including the
  # FILE moves below (legacy .env, credentials, logs), so a cross-device or
  # already-present target is exit 6 before a single rename has happened.
  preflight_move "${FROM}/hermes_data"   "${HERMES_DATA}"
  preflight_move "${FROM}/webui_data"    "${DATA_DIR}/webui_data"
  preflight_move "${FROM}/ollama_data"   "${DATA_DIR}/ollama_data"
  # Repair an earlier run that moved the agent trees to the OLD child paths
  # ("${DATA_DIR}/agent-*") before the layout was corrected to the siblings.
  # When the legacy source is gone but the child copy is present, the child IS
  # the source: the same preflight then refuses (exit 6) if the sibling already
  # holds data, and move_into renames it there when the sibling is absent/empty.
  if [[ ! -e "$legacy_ws" && -e "${DATA_DIR}/agent-workspace" ]]; then
    legacy_ws="${DATA_DIR}/agent-workspace"
  fi
  if [[ ! -e "$legacy_repos" && -e "${DATA_DIR}/agent-repos" ]]; then
    legacy_repos="${DATA_DIR}/agent-repos"
  fi
  preflight_move "$legacy_ws"            "$AGENT_WS"
  preflight_move "$legacy_repos"         "$AGENT_REPOS"
  preflight_move "$legacy_state"         "$OPENHANDS_STATE"
  local cred_src="${login_home}/.config/hybrid-ai-backup"
  preflight_move "$legacy_env"                       "$STACK_ENV"
  preflight_move "${cred_src}/r2.env"                "${CRED_DIR}/r2.env"
  preflight_move "${cred_src}/repo-password"         "${CRED_DIR}/repo-password"
  preflight_move "${FROM}/install.log"               "${LOG_DIR}/install.log" --allow-existing-target
  preflight_move "${FROM}/backup.log"                "${LOG_DIR}/backup.log"  --allow-existing-target

  # The manifest is written next to the logs, paths only.
  MANIFEST="${LOG_DIR}/bootstrap-$(date -u +%Y%m%dT%H%M%SZ).manifest"

  # (d) Rename the data trees into place.
  move_into "${FROM}/hermes_data" "${HERMES_DATA}"   "move-dir"
  move_into "${FROM}/webui_data"  "${DATA_DIR}/webui_data" "move-dir"
  move_into "${FROM}/ollama_data" "${DATA_DIR}/ollama_data" "move-dir"
  move_into "$legacy_ws"    "$AGENT_WS"       "move-dir"
  move_into "$legacy_repos" "$AGENT_REPOS"    "move-dir"
  move_into "$legacy_state" "$OPENHANDS_STATE" "move-dir"

  # (e) The legacy .env becomes the stack env file, byte-identical, 0600 root.
  move_file_byte_identical "$legacy_env" "$STACK_ENV" 0600

  # (f) The login account's backup credentials move into the credstore.
  make_dir 0700 root:root "$CRED_DIR"
  move_file_byte_identical "${cred_src}/r2.env"        "${CRED_DIR}/r2.env"        0600
  move_file_byte_identical "${cred_src}/repo-password" "${CRED_DIR}/repo-password" 0600

  # (g) Logs move into the log directory. install.log/backup.log normally
  # already exist there (install.sh creates them), so these two file moves allow
  # a pre-existing target; a cross-device move is still refused (exit 6).
  move_file_byte_identical "${FROM}/install.log" "${LOG_DIR}/install.log" 0600 --allow-existing-target
  move_file_byte_identical "${FROM}/backup.log"  "${LOG_DIR}/backup.log"  0600 --allow-existing-target

  # (h) hermes_data belongs to the stack account.
  if [[ -d "$HERMES_DATA" ]]; then
    chown -R "${STACK_ACCOUNT}:${STACK_ACCOUNT}" "$HERMES_DATA" \
      || die 1 "could not chown ${HERMES_DATA} to ${STACK_ACCOUNT}"
    manifest_record "chown -R ${STACK_ACCOUNT}:${STACK_ACCOUNT} ${HERMES_DATA}"
    ok "${HERMES_DATA} owned by ${STACK_ACCOUNT}."
  fi

  # (i) The OpenHands workspace and repo tree belong to the stack account too.
  for d in "$AGENT_WS" "$AGENT_REPOS" "$OPENHANDS_STATE"; do
    [[ -d "$d" ]] || continue
    chown -R "${STACK_ACCOUNT}:${STACK_ACCOUNT}" "$d" 2>/dev/null || \
      warn "could not chown -R ${d} to ${STACK_ACCOUNT}"
  done

  # (j) Refuse the Hermes uid change before install.sh starts: the preflight
  # reads hermes_data, so its ownership had to be set above first.
  if [[ -x "${APP_DIR}/scripts/check-hermes-nonroot.sh" ]]; then
    if ! HYBRID_AI_UID="$STACK_UID" HERMES_DATA_DIR="$HERMES_DATA" \
         "${APP_DIR}/scripts/check-hermes-nonroot.sh"; then
      die 1 "the ${STACK_ACCOUNT} uid cannot read ${HERMES_DATA}; fix ownership, then re-run"
    fi
  fi

  if (( MANIFEST_ENTRIES > 0 )); then
    ok "Migration manifest: ${MANIFEST} (0600, paths only)."
  else
    MANIFEST=""
    ok "Nothing to migrate; the layout is already in place."
  fi
}

if (( MIGRATION )); then
  hr; log "Migrating from ${FROM}"; hr
  run_migration
fi

# --- 10. Hand-off: install.sh, then doctor.sh -------------------------------
# Point the hand-off at the LAYOUT file by name, so install.sh resolves the
# layout paths and learns HYBRID_AI_STACK_ENV_FILE from it. install.sh then
# writes ONLY the stack file, so this layout file survives the deploy.
HANDOFF_ENV=(HYBRID_AI_ENV_FILE="$LAYOUT_ENV")
run_install() {
  if [[ -t 0 ]]; then
    env "${HANDOFF_ENV[@]}" "${APP_DIR}/install.sh"
  else
    env "${HANDOFF_ENV[@]}" "${APP_DIR}/install.sh" --non-interactive
  fi
}
log "Handing off to ${APP_DIR}/install.sh..."
if ! run_install; then
  die 7 "install.sh failed; nothing was cut over"
fi
ok "install.sh finished."

log "Running the health gate (${APP_DIR}/doctor.sh --no-cloud)..."
if ! env "${HANDOFF_ENV[@]}" "${APP_DIR}/doctor.sh" --no-cloud; then
  die 8 "doctor.sh failed; nothing was cut over"
fi
ok "doctor.sh passed."

# --- 11. Cut-off (migration only) ------------------------------------------
# Only after BOTH succeeded. Order matters: the login account is removed from
# the docker group LAST, when every privileged step has already completed.
run_cutoff() {
  local login_user="$1" login_home="$2"
  local uid xdg unit
  uid="$(account_uid "$login_user")"
  xdg="/run/user/${uid}"

  for unit in hybrid-ai-backup.timer hybrid-ai-check.timer; do
    runuser -u "$login_user" -- env "XDG_RUNTIME_DIR=$xdg" \
      systemctl --user disable --now "$unit" >/dev/null 2>&1 \
      || warn "could not disable the ${login_user} user unit ${unit} (it may not be installed)"
  done
  ok "Disabled the ${login_user} user backup timers (unit files left in place)."

  # Remove ONLY the deploy key line, matched on the exact key blob.
  local ak="${login_home}/.ssh/authorized_keys"
  if [[ -f "$ak" ]]; then
    local before after
    before="$(wc -l < "$ak" | tr -d ' ')"
    # Remove a line only when one of its whitespace-separated fields is the
    # exact key blob. A prefix or substring match could remove an unrelated key.
    awk -v blob="$KEY_BLOB" '{ keep=1; for (i=1;i<=NF;i++) if ($i==blob) keep=0; if (keep) print }' "$ak" > "${ak}.tmp" \
      || die 1 "could not rewrite ${ak}"
    after="$(wc -l < "${ak}.tmp" | tr -d ' ')"
    chmod 0600 "${ak}.tmp"
    chown "$login_user:$login_user" "${ak}.tmp" 2>/dev/null || true
    mv -f "${ak}.tmp" "$ak"
    printf '    authorized_keys lines: %s -> %s\n' "$before" "$after"
    ok "Removed the deploy key line from ${ak} (that line only)."
  else
    warn "No ${ak}; nothing to remove."
  fi

  if in_group "$login_user" docker; then
    gpasswd -d "$login_user" docker >/dev/null 2>&1 \
      || die 1 "could not remove ${login_user} from the docker group"
    ok "Removed ${login_user} from the docker group (last step)."
  else
    ok "${login_user} is already not in the docker group."
  fi
}

if (( MIGRATION )); then
  CUTOFF_HOME="$(host_path "$(account_home "$LOGIN_USER")")"

  hr; log "Cutting over: retiring the login account's deploy path"; hr
  run_cutoff "$LOGIN_USER" "$CUTOFF_HOME"
fi

hr
ok "Bootstrap complete. Re-run this script at any time; it is idempotent."
