#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/test-hybrid-ai-env.sh
# PURPOSE (plain English):
#   Checks the ONE shared path helper, scripts/lib/hybrid-ai-env.sh, and the
#   isolation guards the scripts build on it. Fully OFFLINE: it needs no Docker,
#   no sqlite3, no rsync and no restic. It runs on any host with bash.
#
#   It proves four things:
#     1. With no settings, every resolved path equals today's default.
#     2. A value in the env file is treated as DATA and never executed.
#     3. Every value the helper must refuse is refused (non-zero exit).
#     4. The isolation guards refuse every forbidden target.
#   It also greps the tracked scripts to prove no path bypasses the helper.
# ---------------------------------------------------------------------------
set -uo pipefail

# Ambient settings must never leak into the "defaults" assertions. Clear every
# setting the helper resolves so the test is deterministic on any host (a CI
# runner, a developer shell with OPENHANDS_WORKSPACE exported, and so on).
unset HYBRID_AI_APP_DIR HYBRID_AI_ENV_FILE HYBRID_AI_ENV_FILE_FALLBACK \
      HYBRID_AI_DATA_DIR HYBRID_AI_LOG_DIR \
      HYBRID_AI_WORK_DIR HYBRID_AI_UID HYBRID_AI_GID OPENHANDS_WORKSPACE \
      AGENT_REPOS_DIR OPENHANDS_STATE_DIR BACKUP_CONF_DIR RESTIC_CACHE_DIR \
      BACKUP_LOG HYBRID_AI_HERMES_HOME_DIR HYBRID_AI_BACKUP_MODE \
      HYBRID_AI_POST_DEPLOY_VERIFY_CMD HYBRID_AI_POST_DEPLOY_VERIFY_LOG \
      BACKUP_CONTAINER_CONTROL 2>/dev/null || true

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -- "${HERE}/.." && pwd)"
HELPER="${REPO}/scripts/lib/hybrid-ai-env.sh"

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$(( PASS + 1 )); printf 'ok   %s\n' "$*"; }
bad()  { FAIL=$(( FAIL + 1 )); printf 'FAIL %s\n' "$*" >&2; }
check() { # desc expected actual
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}
assert() { # desc command...
  local d="$1"; shift
  if "$@"; then ok "$d"; else bad "$d"; fi
}

# Run the helper in a fresh shell with a given env file and extra env, and
# print the value of one resolved variable on stdout. Non-zero exit on refusal.
resolve() { # envfile var [extra K=V ...]
  local envfile="$1" var="$2"; shift 2
  env "$@" HYBRID_AI_ENV_FILE="$envfile" bash -c "source '$HELPER' >/dev/null 2>&1; printf '%s' \"\$$var\""
}

# Run the helper and return its exit code only.
resolve_rc() { # envfile [extra K=V ...]
  local envfile="$1"; shift
  env "$@" HYBRID_AI_ENV_FILE="$envfile" bash -c "source '$HELPER'" >/dev/null 2>&1
  return $?
}

# ---------------------------------------------------------------------------
# 1. Defaults equal today's paths
# ---------------------------------------------------------------------------
echo "== defaults =="
EMPTY="${TMPROOT}/empty.env"
: > "$EMPTY"

check "APP_DIR default is the repo dir" "$REPO" "$(resolve "$EMPTY" HYBRID_AI_APP_DIR)"
# ENV_FILE default depends on APP_DIR, so resolve it with a fresh APP_DIR and NO
# explicit HYBRID_AI_ENV_FILE.
DEFAULT_APPD="${TMPROOT}/default-app"
mkdir -p "$DEFAULT_APPD"
check "ENV_FILE default is APP_DIR/.env" "${DEFAULT_APPD}/.env" \
  "$(env HYBRID_AI_APP_DIR="$DEFAULT_APPD" bash -c "source '$HELPER' >/dev/null 2>&1; printf '%s' \"\$HYBRID_AI_ENV_FILE\"")"
check "DATA_DIR default is the repo dir" "$REPO" "$(resolve "$EMPTY" HYBRID_AI_DATA_DIR)"
check "LOG_DIR default is the repo dir" "$REPO" "$(resolve "$EMPTY" HYBRID_AI_LOG_DIR)"
check "WORK_DIR default is the repo dir" "$REPO" "$(resolve "$EMPTY" HYBRID_AI_WORK_DIR)"
check "hermes_data keeps its name" "${REPO}/hermes_data" "$(resolve "$EMPTY" HYBRID_AI_HERMES_DATA_DIR)"
check "webui_data keeps its name" "${REPO}/webui_data" "$(resolve "$EMPTY" HYBRID_AI_WEBUI_DATA_DIR)"
check "ollama_data keeps its name" "${REPO}/ollama_data" "$(resolve "$EMPTY" HYBRID_AI_OLLAMA_DATA_DIR)"
check "install.log default" "${REPO}/install.log" "$(resolve "$EMPTY" HYBRID_AI_INSTALL_LOG)"
check "backup.log default" "${REPO}/backup.log" "$(resolve "$EMPTY" BACKUP_LOG)"
check "staging default" "${REPO}/.backup-staging" "$(resolve "$EMPTY" HYBRID_AI_BACKUP_STAGING_DIR)"
check "restore work default" "${REPO}/.restore-work" "$(resolve "$EMPTY" HYBRID_AI_RESTORE_WORK_DIR)"
check "OPENHANDS_WORKSPACE default" "$HOME/hybrid-ai-agent" "$(resolve "$EMPTY" OPENHANDS_WORKSPACE)"
check "AGENT_REPOS_DIR default" "$HOME/hybrid-ai-repos" "$(resolve "$EMPTY" AGENT_REPOS_DIR)"
check "OPENHANDS_STATE_DIR default" "$HOME/.openhands" "$(resolve "$EMPTY" OPENHANDS_STATE_DIR)"
check "BACKUP_CONF_DIR default" "$HOME/.config/hybrid-ai-backup" "$(resolve "$EMPTY" BACKUP_CONF_DIR)"
check "RESTIC_CACHE_DIR default" "$HOME/.cache/restic" "$(resolve "$EMPTY" RESTIC_CACHE_DIR)"
check "HYBRID_AI_HERMES_HOME_DIR default" "$HOME/.hermes" "$(resolve "$EMPTY" HYBRID_AI_HERMES_HOME_DIR)"
# The post-deploy verifier command and log. INTERNAL test seams, but their
# defaults are exactly the paths the deploy hook used to hardcode.
check "HYBRID_AI_POST_DEPLOY_VERIFY_CMD default" \
  "/usr/local/sbin/run-post-deploy-verify.sh" "$(resolve "$EMPTY" HYBRID_AI_POST_DEPLOY_VERIFY_CMD)"
check "HYBRID_AI_POST_DEPLOY_VERIFY_LOG default" \
  "/var/log/hybrid-ai-post-deploy-verify.log" "$(resolve "$EMPTY" HYBRID_AI_POST_DEPLOY_VERIFY_LOG)"
# An exported value wins for both, which is how the harnesses relocate them.
check "an exported POST_DEPLOY_VERIFY_CMD wins" "${TMPROOT}/sbin/run-post-deploy-verify.sh" \
  "$(resolve "$EMPTY" HYBRID_AI_POST_DEPLOY_VERIFY_CMD \
      HYBRID_AI_POST_DEPLOY_VERIFY_CMD="${TMPROOT}/sbin/run-post-deploy-verify.sh")"
check "an exported POST_DEPLOY_VERIFY_LOG wins" "${TMPROOT}/logs/verify.log" \
  "$(resolve "$EMPTY" HYBRID_AI_POST_DEPLOY_VERIFY_LOG \
      HYBRID_AI_POST_DEPLOY_VERIFY_LOG="${TMPROOT}/logs/verify.log")"
check "HYBRID_AI_BACKUP_MODE default is user" "user" "$(resolve "$EMPTY" HYBRID_AI_BACKUP_MODE)"
check "BACKUP_CONTAINER_CONTROL default is self" "self" "$(resolve "$EMPTY" BACKUP_CONTAINER_CONTROL)"
check "UID default is empty" "" "$(resolve "$EMPTY" HYBRID_AI_UID)"
check "GID default is empty" "" "$(resolve "$EMPTY" HYBRID_AI_GID)"

# --- STACK_ENV_FILE defaults to the resolved LAYOUT file --------------------
# With the setting unset the stack file and the layout file are the SAME path,
# so every `--env-file` command line stays byte-identical to today's.
check "STACK_ENV_FILE defaults to the resolved ENV_FILE" "$(resolve "$EMPTY" HYBRID_AI_ENV_FILE)" \
  "$(resolve "$EMPTY" HYBRID_AI_STACK_ENV_FILE)"
STACKD="${TMPROOT}/stack-default"
mkdir -p "$STACKD"
# The bootstrap layout: the LAYOUT file names itself and the stack file.
cat > "$STACKD/.env" <<STACKEOF
HYBRID_AI_ENV_FILE=${STACKD}/.env
HYBRID_AI_STACK_ENV_FILE=${STACKD}/stack.env
STACKEOF
: > "${STACKD}/stack.env"
check "STACK_ENV_FILE resolves the layout file's own value" "${STACKD}/stack.env" \
  "$(env HYBRID_AI_ENV_FILE="${STACKD}/.env" bash -c "source '$HELPER' >/dev/null 2>&1; printf '%s' \"\$HYBRID_AI_STACK_ENV_FILE\"")"
# An explicit environment value wins over the layout file.
check "an exported STACK_ENV_FILE wins" "${TMPROOT}/exported-stack.env" \
  "$(env HYBRID_AI_ENV_FILE="${STACKD}/.env" HYBRID_AI_STACK_ENV_FILE="${TMPROOT}/exported-stack.env" \
      bash -c "source '$HELPER' >/dev/null 2>&1; printf '%s' \"\$HYBRID_AI_STACK_ENV_FILE\"")"

# The whole resolved set, byte for byte, with nothing set. This is the strongest
# form of "with no settings, every path is identical to today": the complete
# sorted KEY=VALUE dump of the new helper must equal the expected dump.
CLONE="${TMPROOT}/clone-app"
mkdir -p "${CLONE}/scripts/lib" "${CLONE}/backup" "${CLONE}/openhands" "${CLONE}/hermes"
: > "${CLONE}/docker-compose.yml"
cp "$HELPER" "${CLONE}/scripts/lib/"
CH="${TMPROOT}/clonehome"
mkdir -p "$CH"
DUMP_SCRIPT="${TMPROOT}/dump.sh"
cat > "$DUMP_SCRIPT" <<'DUMPEOF'
# shellcheck source=/dev/null
source "$HYBRID_AI_LIB" >/dev/null 2>&1
for v in HYBRID_AI_APP_DIR HYBRID_AI_ENV_FILE HYBRID_AI_STACK_ENV_FILE \
         HYBRID_AI_DATA_DIR \
         HYBRID_AI_LOG_DIR HYBRID_AI_WORK_DIR \
         HYBRID_AI_HERMES_DATA_DIR HYBRID_AI_WEBUI_DATA_DIR \
         HYBRID_AI_OLLAMA_DATA_DIR HYBRID_AI_INSTALL_LOG \
         HYBRID_AI_BACKUP_STAGING_DIR HYBRID_AI_RESTORE_WORK_DIR \
         HYBRID_AI_HERMES_HOME_DIR HYBRID_AI_BACKUP_MODE \
         HYBRID_AI_POST_DEPLOY_VERIFY_CMD HYBRID_AI_POST_DEPLOY_VERIFY_LOG \
         BACKUP_CONTAINER_CONTROL BACKUP_LOG BACKUP_CONF_DIR \
         RESTIC_CACHE_DIR OPENHANDS_WORKSPACE AGENT_REPOS_DIR \
         OPENHANDS_STATE_DIR; do
  printf '%s=%s\n' "$v" "${!v}"
done
DUMPEOF
DUMP="$(env -i HOME="$CH" PATH="$PATH" HYBRID_AI_LIB="${CLONE}/scripts/lib/hybrid-ai-env.sh" \
        HYBRID_AI_APP_DIR="$CLONE" bash "$DUMP_SCRIPT" | sort)"
EXPECT="$(sort <<EOF
HYBRID_AI_APP_DIR=${CLONE}
HYBRID_AI_ENV_FILE=${CLONE}/.env
HYBRID_AI_STACK_ENV_FILE=${CLONE}/.env
HYBRID_AI_DATA_DIR=${CLONE}
HYBRID_AI_LOG_DIR=${CLONE}
HYBRID_AI_WORK_DIR=${CLONE}
HYBRID_AI_HERMES_DATA_DIR=${CLONE}/hermes_data
HYBRID_AI_WEBUI_DATA_DIR=${CLONE}/webui_data
HYBRID_AI_OLLAMA_DATA_DIR=${CLONE}/ollama_data
HYBRID_AI_INSTALL_LOG=${CLONE}/install.log
HYBRID_AI_BACKUP_STAGING_DIR=${CLONE}/.backup-staging
HYBRID_AI_RESTORE_WORK_DIR=${CLONE}/.restore-work
HYBRID_AI_HERMES_HOME_DIR=${CH}/.hermes
HYBRID_AI_POST_DEPLOY_VERIFY_CMD=/usr/local/sbin/run-post-deploy-verify.sh
HYBRID_AI_POST_DEPLOY_VERIFY_LOG=/var/log/hybrid-ai-post-deploy-verify.log
HYBRID_AI_BACKUP_MODE=user
BACKUP_CONTAINER_CONTROL=self
BACKUP_LOG=${CLONE}/backup.log
BACKUP_CONF_DIR=${CH}/.config/hybrid-ai-backup
RESTIC_CACHE_DIR=${CH}/.cache/restic
OPENHANDS_WORKSPACE=${CH}/hybrid-ai-agent
AGENT_REPOS_DIR=${CH}/hybrid-ai-repos
OPENHANDS_STATE_DIR=${CH}/.openhands
EOF
)"
check "the full resolved set with no settings is byte-identical to today" \
      "$EXPECT" "$DUMP"

# ---------------------------------------------------------------------------
# 2. A value in the env file is DATA, not code
# ---------------------------------------------------------------------------
echo "== env file is never executed =="
MARKER="${TMPROOT}/PWNED"
PWN_ENV="${TMPROOT}/pwn.env"
# A single literal dollar sign. Built this way so shellcheck sees the dollar as
# data being assembled, not as a single-quoted expression that can never expand.
DOLLAR='$'
printf 'HYBRID_AI_DATA_DIR=%s(touch %s; echo /tmp/should_not_appear)\n' "$DOLLAR" "$MARKER" > "$PWN_ENV"
resolve "$PWN_ENV" HYBRID_AI_DATA_DIR >/dev/null 2>&1 || true
assert "a \$(...) in the env file is NOT executed" bash -c "[[ ! -e '$MARKER' ]]"

# The same, with a command substitution that has no spaces, must be accepted as
# a literal path and still not run.
LITERAL_ENV="${TMPROOT}/lit.env"
printf 'HYBRID_AI_DATA_DIR=/tmp/hai%s%s\n' "$DOLLAR" '(whoami)' > "$LITERAL_ENV"
GOT="$(resolve "$LITERAL_ENV" HYBRID_AI_DATA_DIR 2>/dev/null || true)"
check "a command substitution is kept literally" "/tmp/hai${DOLLAR}(whoami)" "$GOT"
assert "still not executed when accepted" bash -c "[[ ! -e '$MARKER' ]]"

# ---------------------------------------------------------------------------
# 3. Every refused value is refused (AC2)
# ---------------------------------------------------------------------------
echo "== refused values =="
REFUSE_CASES=(
  "relative|sub/dir"
  "whitespace|/tmp/a b"
  "control-char|/tmp/a$(printf '\001')b"
  "colon|/tmp/a:b"
  "comma|/tmp/a,b"
  "root-slash|/"
)
for case in "${REFUSE_CASES[@]}"; do
  name="${case%%|*}"; val="${case#*|}"
  f="${TMPROOT}/refuse_${name}.env"
  printf 'HYBRID_AI_DATA_DIR=%s\n' "$val" > "$f"
  if resolve_rc "$f"; then
    bad "refused '${name}' value (helper accepted it)"
  else
    ok "refused '${name}' value"
  fi
done

# A valid absolute value IS accepted.
GOOD_ENV="${TMPROOT}/good.env"
printf 'HYBRID_AI_DATA_DIR=/tmp/hai-ok\n' > "$GOOD_ENV"
check "accepts a valid absolute value" "/tmp/hai-ok" "$(resolve "$GOOD_ENV" HYBRID_AI_DATA_DIR)"

# ENUM settings: the allowed words are accepted; any other value is refused.
for v in user system; do
  fe="${TMPROOT}/mode_${v}.env"; printf 'HYBRID_AI_BACKUP_MODE=%s\n' "$v" > "$fe"
  check "HYBRID_AI_BACKUP_MODE accepts '${v}'" "$v" "$(resolve "$fe" HYBRID_AI_BACKUP_MODE)"
done
for v in self external; do
  fe="${TMPROOT}/ctrl_${v}.env"; printf 'BACKUP_CONTAINER_CONTROL=%s\n' "$v" > "$fe"
  check "BACKUP_CONTAINER_CONTROL accepts '${v}'" "$v" "$(resolve "$fe" BACKUP_CONTAINER_CONTROL)"
done
for bad_val in "System" "host" "yes" "USER" "systemd"; do
  fe="${TMPROOT}/bad_mode.env"; printf 'HYBRID_AI_BACKUP_MODE=%s\n' "$bad_val" > "$fe"
  if resolve_rc "$fe"; then
    bad "refused HYBRID_AI_BACKUP_MODE value '${bad_val}' (helper accepted it)"
  else
    ok "refused HYBRID_AI_BACKUP_MODE value '${bad_val}'"
  fi
done
# An empty value means "unset": the default applies, exactly as for a path.
fe="${TMPROOT}/empty_mode.env"; printf 'HYBRID_AI_BACKUP_MODE=\n' > "$fe"
check "an empty HYBRID_AI_BACKUP_MODE falls back to user" "user" "$(resolve "$fe" HYBRID_AI_BACKUP_MODE)"
for bad_val in "docker" "none" "TRUE"; do
  fe="${TMPROOT}/bad_ctrl.env"; printf 'BACKUP_CONTAINER_CONTROL=%s\n' "$bad_val" > "$fe"
  if resolve_rc "$fe"; then
    bad "refused BACKUP_CONTAINER_CONTROL value '${bad_val}' (helper accepted it)"
  else
    ok "refused BACKUP_CONTAINER_CONTROL value '${bad_val}'"
  fi
done

# The mode-derived unit names and credential directory are resolved by the ONE
# helper, so doctor.sh/install.sh/deploy-remote.sh/collect-diagnostics.sh/
# backup.sh cannot disagree about which units run.
echo "== mode-derived names =="
check "user-mode backup timer"       "hybrid-ai-backup.timer"         "$(resolve "$EMPTY" HYBRID_AI_BACKUP_TIMER_UNIT)"
check "user-mode backup service"     "hybrid-ai-backup.service"       "$(resolve "$EMPTY" HYBRID_AI_BACKUP_SERVICE_UNIT)"
check "user-mode check timer"        "hybrid-ai-check.timer"          "$(resolve "$EMPTY" HYBRID_AI_BACKUP_CHECK_TIMER_UNIT)"
check "user-mode systemctl scope"    "--user"                         "$(resolve "$EMPTY" HYBRID_AI_BACKUP_SYSTEMCTL_SCOPE)"
check "user-mode journal scope"      "--user"                         "$(resolve "$EMPTY" HYBRID_AI_BACKUP_JOURNAL_SCOPE)"
check "user-mode cred dir is BACKUP_CONF_DIR" "$HOME/.config/hybrid-ai-backup" "$(resolve "$EMPTY" HYBRID_AI_BACKUP_CRED_DIR)"

SYSMODE="${TMPROOT}/sysmode.env"; printf 'HYBRID_AI_BACKUP_MODE=system\n' > "$SYSMODE"
check "system-mode backup timer"     "hybrid-ai-backup-capture.timer" "$(resolve "$SYSMODE" HYBRID_AI_BACKUP_TIMER_UNIT)"
check "system-mode backup service"   "hybrid-ai-backup-capture.service" "$(resolve "$SYSMODE" HYBRID_AI_BACKUP_SERVICE_UNIT)"
check "system-mode check timer"      "hybrid-ai-backup-check.timer"   "$(resolve "$SYSMODE" HYBRID_AI_BACKUP_CHECK_TIMER_UNIT)"
check "system-mode systemctl scope"  "--system"                       "$(resolve "$SYSMODE" HYBRID_AI_BACKUP_SYSTEMCTL_SCOPE)"
check "system-mode journal scope"    "--system"                       "$(resolve "$SYSMODE" HYBRID_AI_BACKUP_JOURNAL_SCOPE)"
check "system-mode cred dir is the credstore" "/etc/credstore/hybrid-ai-backup" "$(resolve "$SYSMODE" HYBRID_AI_BACKUP_CRED_DIR)"

# BACKUP_LOG resolves to ONE path per mode: the units' LogsDirectory= in system
# mode, $LOG_DIR/backup.log in user mode. doctor.sh reads the same value, so the
# two can no longer disagree (D9).
check "user-mode BACKUP_LOG default" "${REPO}/backup.log" "$(resolve "$EMPTY" BACKUP_LOG)"
check "system-mode BACKUP_LOG default is the units' LogsDirectory path" \
  "/var/log/hybrid-ai-backup/backup.log" "$(resolve "$SYSMODE" BACKUP_LOG)"
# A SET value still wins in both modes (no mode may silently ignore it).
SETLOG="${TMPROOT}/setlog.env"
printf 'HYBRID_AI_BACKUP_MODE=system\nBACKUP_LOG=/tmp/explicit/backup.log\n' > "$SETLOG"
check "an explicit BACKUP_LOG wins in system mode" \
  "/tmp/explicit/backup.log" "$(resolve "$SETLOG" BACKUP_LOG)"
SETLOG_U="${TMPROOT}/setlog-user.env"
printf 'BACKUP_LOG=/tmp/explicit-user/backup.log\n' > "$SETLOG_U"
check "an explicit BACKUP_LOG wins in user mode" \
  "/tmp/explicit-user/backup.log" "$(resolve "$SETLOG_U" BACKUP_LOG)"

# ---------------------------------------------------------------------------
# 3b. Fail closed on an env file that exists but cannot be read
# ---------------------------------------------------------------------------
echo "== fail closed on an unreadable env file =="
# A file that exists with mode 0000 cannot be read by this (non-root) process,
# so the helper must refuse rather than silently use the built-in defaults.
# Only meaningful when this test is NOT root: root bypasses the read bit.
if [[ "$(id -u)" != "0" ]]; then
  LOCKED_LAYOUT="${TMPROOT}/locked-layout.env"
  printf 'HYBRID_AI_DATA_DIR=/tmp/x\n' > "$LOCKED_LAYOUT"
  chmod 000 "$LOCKED_LAYOUT"
  rc=0; err="$(env HYBRID_AI_ENV_FILE="$LOCKED_LAYOUT" bash -c "source '$HELPER'" 2>&1 >/dev/null)" || rc=$?
  check "an unreadable layout file exits non-zero" "1" "$rc"
  if [[ "$err" == *HYBRID_AI_ENV_FILE* ]]; then
    ok "the message names HYBRID_AI_ENV_FILE"
  else
    bad "the message did not name HYBRID_AI_ENV_FILE: $err"
  fi
  if [[ "$err" == *locked-layout.env* ]]; then
    ok "the message names the path"
  else
    bad "the message did not name the path: $err"
  fi

  # The same for the STACK file: it, too, must refuse rather than default.
  LAYOUTDIR="${TMPROOT}/fc-layout"; mkdir -p "$LAYOUTDIR"
  LOCKED_STACK="${TMPROOT}/locked-stack.env"
  printf 'HYBRID_AI_STACK_ENV_FILE=%s\n' "$LOCKED_STACK" > "${LAYOUTDIR}/layout.env"
  printf 'SECRET=1\n' > "$LOCKED_STACK"
  chmod 000 "$LOCKED_STACK"
  rc=0; err="$(env HYBRID_AI_ENV_FILE="${LAYOUTDIR}/layout.env" bash -c "source '$HELPER'" 2>&1 >/dev/null)" || rc=$?
  check "an unreadable stack file exits non-zero" "1" "$rc"
  if [[ "$err" == *HYBRID_AI_STACK_ENV_FILE* ]]; then
    ok "the message names HYBRID_AI_STACK_ENV_FILE"
  else
    bad "the message did not name HYBRID_AI_STACK_ENV_FILE: $err"
  fi
  chmod 600 "$LOCKED_STACK" "$LOCKED_LAYOUT"
else
  printf 'ok   skip unreadable-env-file assertions (running as root)\n'
fi

# ---------------------------------------------------------------------------
# 3c. Bootstrap LAYOUT fallback (D10)
# ---------------------------------------------------------------------------
# On a bootstrapped host $HYBRID_AI_APP_DIR/.env does not exist: the layout
# moved to /etc/hybrid-ai/hybrid-ai.env. When HYBRID_AI_ENV_FILE is UNSET the
# helper must probe the fallback layout file. The fallback location is the NAMED
# variable HYBRID_AI_ENV_FILE_FALLBACK, so these fixtures live in the temp dir
# and NOTHING here reads or writes /etc.
echo "== bootstrap layout fallback (D10) =="
FBDIR="${TMPROOT}/fb"; mkdir -p "${FBDIR}/app"
FBDIR_APP="${FBDIR}/app"            # has NO .env
LAYOUT="${FBDIR}/hybrid-ai.env"     # the fallback LAYOUT file
STACK_FB="${FBDIR}/stack.env"       # the secrets file the layout names
: > "$STACK_FB"
cat > "$LAYOUT" <<FBEOF
HYBRID_AI_ENV_FILE=${LAYOUT}
HYBRID_AI_STACK_ENV_FILE=${STACK_FB}
HYBRID_AI_BACKUP_MODE=system
FBEOF

# A resolver that runs the helper with NO explicit HYBRID_AI_ENV_FILE and an
# explicit fallback location, printing one resolved variable.
fb_resolve() { # var [extra K=V ...]
  local var="$1"; shift
  env "$@" HYBRID_AI_ENV_FILE_FALLBACK="$LAYOUT" \
      HYBRID_AI_APP_DIR="$FBDIR_APP" \
      bash -c "source '$HELPER' >/dev/null 2>&1; printf '%s' \"\$$var\""
}
fb_rc() { # [extra K=V ...]
  env "$@" HYBRID_AI_ENV_FILE_FALLBACK="$LAYOUT" HYBRID_AI_APP_DIR="$FBDIR_APP" \
      bash -c "source '$HELPER'" >/dev/null 2>&1
  return $?
}

# Criterion 1 + 3: with $APP_DIR/.env absent, the fallback resolves and the
# WHOLE chain follows the layout file.
check "fallback: HYBRID_AI_ENV_FILE resolves to the fallback layout" "$LAYOUT" \
  "$(fb_resolve HYBRID_AI_ENV_FILE)"
check "fallback: mode is read from the layout (system)" "system" \
  "$(fb_resolve HYBRID_AI_BACKUP_MODE)"
check "fallback: BACKUP_LOG follows the mode" "/var/log/hybrid-ai-backup/backup.log" \
  "$(fb_resolve BACKUP_LOG)"
check "fallback: HYBRID_AI_BACKUP_CRED_DIR is the credstore default" \
  "/etc/credstore/hybrid-ai-backup" "$(fb_resolve HYBRID_AI_BACKUP_CRED_DIR)"
check "fallback: STACK_ENV_FILE is the file the layout names" "$STACK_FB" \
  "$(fb_resolve HYBRID_AI_STACK_ENV_FILE)"
check "fallback: APP_DIR keeps its explicit value" "$FBDIR_APP" \
  "$(fb_resolve HYBRID_AI_APP_DIR)"

# Criterion 2 (b): when $APP_DIR/.env EXISTS the fallback is never consulted.
PRESENT_DIR="${FBDIR}/present"; mkdir -p "$PRESENT_DIR"
PRESENT_LAYOUT="${FBDIR}/present-layout.env"
printf 'HYBRID_AI_DATA_DIR=/tmp/from-present-layout\n' > "$PRESENT_LAYOUT"
cat > "${PRESENT_DIR}/.env" <<PEOF
HYBRID_AI_DATA_DIR=/tmp/from-app-dotenv
PEOF
check "fallback not used when \$APP_DIR/.env exists" "/tmp/from-app-dotenv" \
  "$(env HYBRID_AI_ENV_FILE_FALLBACK="$PRESENT_LAYOUT" HYBRID_AI_APP_DIR="$PRESENT_DIR" \
      bash -c "source '$HELPER' >/dev/null 2>&1; printf '%s' \"\$HYBRID_AI_DATA_DIR\"")"

# Criterion 2 (a): an explicit HYBRID_AI_ENV_FILE always wins; the fallback is
# never consulted even when it exists and $APP_DIR/.env does not.
check "explicit HYBRID_AI_ENV_FILE wins over the fallback" "/tmp/from-explicit" \
  "$(env HYBRID_AI_ENV_FILE="$LAYOUT" HYBRID_AI_ENV_FILE_FALLBACK="$PRESENT_LAYOUT" \
      HYBRID_AI_APP_DIR="$FBDIR_APP" HYBRID_AI_DATA_DIR=/tmp/from-explicit \
      bash -c "source '$HELPER' >/dev/null 2>&1; printf '%s' \"\$HYBRID_AI_DATA_DIR\"")"
check "explicit HYBRID_AI_ENV_FILE is not replaced by the fallback" "$LAYOUT" \
  "$(env HYBRID_AI_ENV_FILE="$LAYOUT" HYBRID_AI_ENV_FILE_FALLBACK="$PRESENT_LAYOUT" \
      HYBRID_AI_APP_DIR="$FBDIR_APP" \
      bash -c "source '$HELPER' >/dev/null 2>&1; printf '%s' \"\$HYBRID_AI_ENV_FILE\"")"

# The fallback override variable is honoured: point it at a DIFFERENT layout and
# that layout's value is the one that applies.
OVERRIDE_LAYOUT="${FBDIR}/override.env"
printf 'HYBRID_AI_DATA_DIR=/tmp/from-override\n' > "$OVERRIDE_LAYOUT"
check "the fallback override variable is honoured" "/tmp/from-override" \
  "$(env HYBRID_AI_ENV_FILE_FALLBACK="$OVERRIDE_LAYOUT" HYBRID_AI_APP_DIR="$FBDIR_APP" \
      bash -c "source '$HELPER' >/dev/null 2>&1; printf '%s' \"\$HYBRID_AI_DATA_DIR\"")"

# Criterion 4: fail closed. With the fallback active and the resolved stack file
# PRESENT but unreadable to this uid, the helper exits non-zero and names the
# setting and path -- never a value. Only meaningful when NOT root.
if [[ "$(id -u)" != "0" ]]; then
  LOCKED_FB_STACK="${FBDIR}/locked-stack.env"
  printf 'SECRET=1\n' > "$LOCKED_FB_STACK"
  chmod 000 "$LOCKED_FB_STACK"
  LOCKED_LAYOUT="${FBDIR}/locked-layout.env"
  cat > "$LOCKED_LAYOUT" <<LFBEOF
HYBRID_AI_ENV_FILE=${LOCKED_LAYOUT}
HYBRID_AI_STACK_ENV_FILE=${LOCKED_FB_STACK}
LFBEOF
  rc=0; err="$(env HYBRID_AI_ENV_FILE_FALLBACK="$LOCKED_LAYOUT" HYBRID_AI_APP_DIR="$FBDIR_APP" \
               bash -c "source '$HELPER'" 2>&1 >/dev/null)" || rc=$?
  check "fallback: an unreadable stack file exits non-zero" "1" "$rc"
  if [[ "$err" == *HYBRID_AI_STACK_ENV_FILE* && "$err" == *locked-stack.env* ]]; then
    ok "fallback: the message names the setting and the path"
  else
    bad "fallback: the message did not name the setting and path: $err"
  fi
  if [[ "$err" == *"SECRET"* || "$err" == *"=1"* ]]; then
    bad "fallback: the message leaked a value from the file"
  else
    ok "fallback: the message leaks no value"
  fi
  chmod 600 "$LOCKED_FB_STACK"
else
  printf 'ok   skip fallback unreadable-stack assertion (running as root)\n'
fi

# A file that simply does not exist is NOT an error: the defaults apply.
MISSING_ENV="${TMPROOT}/does-not-exist.env"
if resolve_rc "$MISSING_ENV"; then
  ok "a missing env file still resolves to the defaults"
else
  bad "a missing env file was refused"
fi

# ---------------------------------------------------------------------------
# 4. Isolation guards (AC6)
# ---------------------------------------------------------------------------
echo "== isolation guards =="

# Build a scratch "app" with the helper and the two guard scripts.
APPD="${TMPROOT}/app"
mkdir -p "${APPD}/scripts/lib" "${APPD}/backup" "${APPD}/openhands" "${APPD}/hermes"
cp "$HELPER" "${APPD}/scripts/lib/"
cp "${REPO}/scripts/setup-agent-workspace.sh" "${APPD}/scripts/"
cp "${REPO}/scripts/sync-agent-repos.sh" "${APPD}/scripts/"
cp "${REPO}/doctor.sh" "${APPD}/"
cp "${REPO}/backup/backup.sh" "${APPD}/backup/"
cp "${REPO}/backup/restore.sh" "${APPD}/backup/"
: > "${APPD}/docker-compose.yml"

DATAD="${TMPROOT}/data"; LOGD="${TMPROOT}/log"; WORKD="${TMPROOT}/work"
CONFD_GOOD="${TMPROOT}/conf-good"; CONFD_BAD="${TMPROOT}/conf-bad"
mkdir -p "$DATAD" "$LOGD" "$WORKD" "$CONFD_GOOD" "$CONFD_BAD/inside-app"
mkdir -p "${TMPROOT}/etc"
ENVF="${TMPROOT}/etc/env"; : > "$ENVF"

# A helper env shared by the guard runs, relocating every tree.
GUARD_ENV=(HOME="$TMPROOT/home" HYBRID_AI_APP_DIR="$APPD" HYBRID_AI_ENV_FILE="$ENVF"
           HYBRID_AI_DATA_DIR="$DATAD" HYBRID_AI_LOG_DIR="$LOGD" HYBRID_AI_WORK_DIR="$WORKD"
           BACKUP_CONF_DIR="$CONFD_GOOD")
mkdir -p "${TMPROOT}/home"

# --- The STACK file's directory is guarded too -------------------------------
# With the bootstrap layout the secrets live in HYBRID_AI_STACK_ENV_FILE, so a
# workspace or repo tree that is, contains, or lives inside ITS directory must be
# refused exactly like the layout file's directory.
STACKD="${TMPROOT}/stackdir"
mkdir -p "$STACKD"
STACKF="${STACKD}/stack.env"; : > "$STACKF"
GUARD_ENV_STACK=("${GUARD_ENV[@]}" HYBRID_AI_STACK_ENV_FILE="$STACKF")
for t in "$STACKD" "${STACKD}/child" "${TMPROOT}" ; do
  if env "${GUARD_ENV_STACK[@]}" OPENHANDS_WORKSPACE="$t" \
       bash "${APPD}/scripts/setup-agent-workspace.sh" --non-interactive >/dev/null 2>&1; then
    bad "setup-agent-workspace refused stack-dir workspace '${t}'"
  else
    ok "setup-agent-workspace refused stack-dir workspace '${t}'"
  fi
done
for t in "$STACKD" "${STACKD}/repos" "${TMPROOT}"; do
  if env "${GUARD_ENV_STACK[@]}" AGENT_REPOS_DIR="$t" \
       bash "${APPD}/scripts/sync-agent-repos.sh" --dry-run >/dev/null 2>&1; then
    bad "sync-agent-repos refused stack-dir AGENT_REPOS_DIR '${t}'"
  else
    ok "sync-agent-repos refused stack-dir AGENT_REPOS_DIR '${t}'"
  fi
done
# doctor.sh refuses a workspace that IS the stack file's directory. doctor.sh
# reads OPENHANDS_WORKSPACE from the env FILES (env_get), so seed it there.
DL="${TMPROOT}/doctor-layout.env"
printf 'OPENHANDS_WORKSPACE=%s\n' "$STACKD" > "$DL"
DMSG="$(env HOME="$TMPROOT/home" HYBRID_AI_APP_DIR="$APPD" HYBRID_AI_ENV_FILE="$DL" \
        HYBRID_AI_STACK_ENV_FILE="$STACKF" HYBRID_AI_DATA_DIR="$DATAD" \
        HYBRID_AI_LOG_DIR="$LOGD" HYBRID_AI_WORK_DIR="$WORKD" BACKUP_CONF_DIR="$CONFD_GOOD" \
        bash "${APPD}/doctor.sh" --no-cloud 2>&1 || true)"
if [[ "$DMSG" == *"env-file directory"* ]]; then
  ok "doctor.sh refused a workspace at the stack file's directory"
else
  bad "doctor.sh did not flag a workspace at the stack file's directory"
fi

# --- setup-agent-workspace.sh refuses a workspace in a protected tree --------
guarded_targets=(
  "$APPD"                    # the app dir
  "${APPD}/child"            # inside the app dir
  "$DATAD"                   # the data dir
  "${DATAD}/child"           # inside the data dir
  "$LOGD"                    # the log dir
  "$WORKD"                   # the work dir
  "${TMPROOT}/etc"           # the directory the env file lives in
  "$CONFD_GOOD"              # the backup credential directory
  "${TMPROOT}"               # contains every protected dir
)
for t in "${guarded_targets[@]}"; do
  if env "${GUARD_ENV[@]}" OPENHANDS_WORKSPACE="$t" \
       bash "${APPD}/scripts/setup-agent-workspace.sh" --non-interactive >/dev/null 2>&1; then
    bad "setup-agent-workspace refused workspace '${t}'"
  else
    ok "setup-agent-workspace refused workspace '${t}'"
  fi
done

# --- setup-agent-workspace.sh does NOT refuse a clean sibling -----------------
# The guard must not fire for a path outside every protected tree. --check also
# fails when no clone exists; we assert only that the GUARD did not fire.
MSG="$(env "${GUARD_ENV[@]}" OPENHANDS_WORKSPACE="${TMPROOT}/agent-ws" \
      bash "${APPD}/scripts/setup-agent-workspace.sh" --check 2>&1 || true)"
if [[ "$MSG" == *"protected directory"* || "$MSG" == *"workspace containment"* ]]; then
  bad "setup-agent-workspace wrongly refused a clean sibling"
else
  ok "setup-agent-workspace did not fire the guard for a clean sibling"
fi

# --- sync-agent-repos.sh refuses a tree in a protected target ----------------
for t in "$APPD" "${APPD}/repos" "$DATAD" "$LOGD" "$WORKD" "${TMPROOT}/etc" \
         "$CONFD_GOOD" "${TMPROOT}"; do
  if env "${GUARD_ENV[@]}" AGENT_REPOS_DIR="$t" \
       bash "${APPD}/scripts/sync-agent-repos.sh" --dry-run >/dev/null 2>&1; then
    bad "sync-agent-repos refused AGENT_REPOS_DIR '${t}'"
  else
    ok "sync-agent-repos refused AGENT_REPOS_DIR '${t}'"
  fi
done

# --- backup.sh / restore.sh refuse a BACKUP_CONF_DIR inside the trees --------
for script in backup/backup.sh backup/restore.sh; do
  for t in "$APPD" "$DATAD" "$WORKD"; do
    if env "${GUARD_ENV[@]}" BACKUP_CONF_DIR="$t" \
         bash "${APPD}/${script}" --dry-run >/dev/null 2>&1; then
      bad "${script} refused BACKUP_CONF_DIR inside '${t}'"
    else
      ok "${script} refused BACKUP_CONF_DIR inside '${t}'"
    fi
  done
done

# ---------------------------------------------------------------------------
# 5. No path bypasses the helper (AC3 grep)
# ---------------------------------------------------------------------------
echo "== no bypassing paths =="
# Search every tracked shell script EXCEPT the helper and this test for the
# forbidden constructs: a repo-relative data/log/env path, a bare --env-file .env,
# or a $HOME-derived state/data path.
BYPASS_FILES="$(cd "$REPO" && git ls-files '*.sh' | grep -vE '^(scripts/lib/hybrid-ai-env\.sh|scripts/test-hybrid-ai-env\.sh)$')"
HITS="$(cd "$REPO" && printf '%s\n' "$BYPASS_FILES" | while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  grep -nE '\$\{REPO_DIR\}|\$\{SCRIPT_DIR\}/\.env|--env-file [.]env|\$\{HOME\}/\.openhands|\$\{HOME\}/\.hermes|\$\{HOME\}/\.config/hybrid-ai-backup|\$\{HOME\}/\.cache/restic' "$f" 2>/dev/null | sed "s|^|$f:|"
done)"
if [[ -z "$HITS" ]]; then
  ok "no repo-relative, SCRIPT_DIR, HOME-derived, or bare --env-file paths remain"
else
  bad "found paths that bypass the helper:"
  printf '%s\n' "$HITS" >&2
fi

# --- Every --env-file consumer passes the STACK file --------------------------
# The split is only real if every compose call hands over HYBRID_AI_STACK_ENV_FILE.
# A consumer left on HYBRID_AI_ENV_FILE would read the layout file, which holds
# no secrets. The helper itself and this test are excluded (they define/mention
# the setting name).
STACK_CONSUMERS="$(cd "$REPO" && git ls-files '*.sh' | grep -vE '^(scripts/lib/hybrid-ai-env\.sh|scripts/test-hybrid-ai-env\.sh)$')"
BAD_CONSUMERS="$(cd "$REPO" && printf '%s\n' "$STACK_CONSUMERS" | while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  # Files that pass an env file to docker compose must name the STACK setting.
  if grep -qE -- '--env-file' "$f" 2>/dev/null; then
    if ! grep -qE 'HYBRID_AI_STACK_ENV_FILE' "$f" 2>/dev/null; then
      printf '%s\n' "$f"
    fi
  fi
done)"
if [[ -z "$BAD_CONSUMERS" ]]; then
  ok "every --env-file consumer uses HYBRID_AI_STACK_ENV_FILE"
else
  bad "these --env-file consumers do not use the stack file:"
  printf '%s\n' "$BAD_CONSUMERS" >&2
fi

# install.sh must WRITE the stack file, never the layout file.
STACK_ASSIGN="ENV_FILE=\"\$HYBRID_AI_STACK_ENV_FILE\""
if grep -qF "$STACK_ASSIGN" "$REPO/install.sh"; then
  ok "install.sh writes the stack env file"
else
  bad "install.sh does not set ENV_FILE from HYBRID_AI_STACK_ENV_FILE"
fi

# ---------------------------------------------------------------------------
# 6. install.sh STEP 8 template renders the startup-grace default
# ---------------------------------------------------------------------------
echo "== install.sh STEP 8 template: OPENHANDS_STARTUP_GRACE_SECONDS =="
# The template between `cat > "$TMP_ENV" <<EOF` and its closing `EOF` is rendered
# here in a controlled environment, proving both directions of the override:
# unset yields exactly 120, and an owner-set value is preserved byte-for-byte.
STEP8_TMPL="${TMPROOT}/step8.tmpl"
awk '/^cat > "\$TMP_ENV" <<EOF$/{f=1;next} f&&/^EOF$/{exit} f' \
  "$REPO/install.sh" > "$STEP8_TMPL"

if [[ -s "$STEP8_TMPL" ]]; then
  ok "extracted the STEP 8 heredoc template from install.sh"
else
  bad "could not extract the STEP 8 heredoc template from install.sh"
fi

# Render the template exactly as install.sh does: every substitution comes from
# the variables install.sh has already set. Unrelated ${...} lines are given a
# neutral value; only the startup-grace line is asserted on.
render_step8() { # extra_bash_commands_on_one_line
  (
    cd "$REPO" || exit 1
    unset OPENHANDS_STARTUP_GRACE_SECONDS 2>/dev/null || true
    export HYBRID_AI_UID=1000 HYBRID_AI_GID=1000 STATUS_UID=1000 DOCKER_GID=999 \
      LOCAL_DOMAIN=example.test RUNPOD_HOST=rp PI_HOST=pi OPENROUTER_API_KEY='' \
      RUNPOD_API_KEY='' RUNPOD_POD_ID='' TAILSCALE_IP='' PEER_HOSTNAME='' PEER_HOSTNAMES='' \
      RUNPOD_AUTO_WAKE=true VLLM_PORT=8000 VLLM_MODEL_NAME=m POD_WARMUP_TIMEOUT=600 \
      VLLM_DISPLAY_NAME=v VLLM_REQUEST_TIMEOUT=900 VLLM_MAX_TOKENS=4096 \
      PIPE_LOG_LEVEL=INFO HERMES_PORT=8501 HERMES_API_PORT=8642 \
      OPENHANDS_PORT=3001 OPENHANDS_WORKSPACE=/tmp/ws \
      AGENT_REPOS_DIR=/tmp/ar OPENHANDS_SANDBOX_HOST=example.test \
      OPENHANDS_STATE_DIR=/tmp/oh \
      WEBUI_SECRET_KEY=x OPENROUTER_MODEL=m RAG_EMBEDDING_MODEL=m \
      OLLAMA_MEM_LIMIT=8g WEBUI_MEM_LIMIT=3g OLLAMA_CPUS=3.5 WEBUI_CPUS=2.0 \
      OLLAMA_CONTEXT_LENGTH=4096 OLLAMA_NUM_PARALLEL=2 OLLAMA_MAX_LOADED_MODELS=1 \
      OLLAMA_KEEP_ALIVE=5m OLLAMA_FLASH_ATTENTION=true OLLAMA_KV_CACHE_TYPE=f16 \
      TARGET_ENV_VERSION=1 APP_DIR=/tmp DATA_DIR=/tmp LOG_DIR=/tmp WORK_DIR=/tmp
    [[ -n "${1:-}" ]] && eval "$1"
    bash -c 'eval "cat <<EOF
$(cat "$1")
EOF"' _ "$STEP8_TMPL"
  )
}

GRACE_UNSET="$(render_step8 "" \
  | grep -E '^OPENHANDS_STARTUP_GRACE_SECONDS=' || true)"
check "STEP 8 renders the default grace (120) when unset" \
  "OPENHANDS_STARTUP_GRACE_SECONDS=120" "$GRACE_UNSET"

GRACE_SET="$(render_step8 'export OPENHANDS_STARTUP_GRACE_SECONDS=180' \
  | grep -E '^OPENHANDS_STARTUP_GRACE_SECONDS=' || true)"
check "STEP 8 preserves an owner-set grace (180)" \
  "OPENHANDS_STARTUP_GRACE_SECONDS=180" "$GRACE_SET"

# ---------------------------------------------------------------------------
echo
if (( FAIL != 0 )); then
  printf 'FAILED: %d of %d checks\n' "$FAIL" "$(( PASS + FAIL ))" >&2
  exit 1
fi
printf 'All %d hybrid-ai-env checks passed.\n' "$PASS"
