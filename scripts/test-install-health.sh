#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/test-install-health.sh
# PURPOSE (plain English):
#   Offline tests for install.sh's service health gate. They need NO root, NO
#   Docker and NO network: every host command install.sh probes is stubbed on
#   PATH, and the whole run is pointed at a scratch app/data tree.
#
#   The bug this covers (B37 D7): a failed hermes-agent health wait only printed
#   a warning, so install.sh still logged install_success and exited 0. The
#   bootstrap trusts that exit code before it cuts over, so an unhealthy Hermes
#   would have been cut over. The fix sets HEALTH_FAILED=1 on a failed Hermes
#   wait, so install.sh exits non-zero and never logs install_success.
#
# CASES:
#   * a healthy hermes-agent -> install.sh exits 0 and logs install_success
#   * an unhealthy hermes-agent -> install.sh exits 1 and logs install_failed
#     reason=healthcheck, with no install_success
#   * the Hermes wait window is 300 s (raised from 120 s for a cold first start)
#
# USAGE:
#   bash scripts/test-install-health.sh
#
# EXIT CODES:
#   0  every case passed
#   1  one or more cases failed
#   2  a required tool is missing
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
[[ -f "${REPO}/install.sh" ]] || { echo "FATAL: cannot find install.sh" >&2; exit 2; }
for t in mktemp stat grep cmp; do
  command -v "$t" >/dev/null 2>&1 || { echo "error: $t is required" >&2; exit 2; }
done

PASS=0
FAIL=0
ok()   { PASS=$(( PASS + 1 )); printf 'ok   %s\n' "$*"; }
bad()  { FAIL=$(( FAIL + 1 )); printf 'FAIL %s\n' "$*" >&2; }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi; }

WORK="$(mktemp -d)"
if [[ "${KEEP:-0}" == "1" ]]; then
  printf 'keeping %s\n' "$WORK"
else
  trap 'rm -rf -- "$WORK"' EXIT
fi

# --- scratch app + layout ----------------------------------------------------
APP="$WORK/app"
BIN="$WORK/bin"
BIN_ROOT="$WORK/bin-root"
SYSD="$WORK/systemd"
mkdir -p "$APP/scripts/lib" "$APP/deploy" "$BIN" "$BIN_ROOT" "$SYSD" "$WORK/data" "$WORK/log" "$WORK/work" \
         "$WORK/ws" "$WORK/repos" "$WORK/ohstate" "$WORK/conf" "$WORK/restic" \
         "$WORK/etc/hybrid-ai"
cp "$REPO/install.sh" "$APP/install.sh"
cp "$REPO/scripts/lib/hybrid-ai-env.sh" "$APP/scripts/lib/"
cp "$REPO/deploy/hybrid-ai-firewall.service" "$APP/deploy/"
# The sandbox git config is shipped by install.sh; copy it so the install path
# can run, and give the scratch workspace a git dir so install writes the exclude.
mkdir -p "$APP/openhands" "$WORK/ws/.git/info"
cp "$REPO/openhands/sandbox-gitconfig" "$APP/openhands/sandbox-gitconfig"
: > "$WORK/ws/.git/info/exclude"
# The agent scripts are not under test here; stub them so the run is quiet.
printf '#!/usr/bin/env bash\nexit 0\n' > "$APP/scripts/setup-agent-workspace.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$APP/scripts/sync-agent-repos.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$APP/scripts/check-hermes-nonroot.sh"
chmod +x "$APP/scripts/"*.sh

LAYOUT="$WORK/etc/hybrid-ai/hybrid-ai.env"
STACK="$WORK/etc/hybrid-ai/stack.env"
{
  printf 'HYBRID_AI_APP_DIR=%s\n' "$APP"
  printf 'HYBRID_AI_ENV_FILE=%s\n' "$LAYOUT"
  printf 'HYBRID_AI_STACK_ENV_FILE=%s\n' "$STACK"
  printf 'HYBRID_AI_DATA_DIR=%s\n' "$WORK/data"
  printf 'HYBRID_AI_LOG_DIR=%s\n' "$WORK/log"
  printf 'HYBRID_AI_WORK_DIR=%s\n' "$WORK/work"
  printf 'OPENHANDS_WORKSPACE=%s\n' "$WORK/ws"
  printf 'AGENT_REPOS_DIR=%s\n' "$WORK/repos"
  printf 'OPENHANDS_STATE_DIR=%s\n' "$WORK/ohstate"
  printf 'BACKUP_CONF_DIR=%s\n' "$WORK/conf"
  printf 'RESTIC_CACHE_DIR=%s\n' "$WORK/restic"
  printf 'HYBRID_AI_HERMES_HOME_DIR=%s\n' "$WORK/hermes"
  printf 'HYBRID_AI_BACKUP_MODE=system\n'
  printf 'BACKUP_CONTAINER_CONTROL=external\n'
  printf 'HYBRID_AI_UID=1000\n'
  printf 'HYBRID_AI_GID=1000\n'
} > "$LAYOUT"
chmod 644 "$LAYOUT"

# --- stubs -------------------------------------------------------------------
for d in docker git jq openssl sqlite3 rsync tailscale hostname nproc \
         loginctl setfacl apt-get sudo restic; do
  # shellcheck disable=SC2016  # $0 must expand inside the generated stub
  printf '#!/usr/bin/env bash\nprintf "%%s stub\\n" "$0"\nexit 0\n' > "$BIN/$d"
done
# `id` answers without a real account; chown is a no-op.
# shellcheck disable=SC2016  # $@ must expand inside the generated stub
printf '#!/usr/bin/env bash\nif [[ "${1:-}" == "-u" ]]; then printf "1000\\n"; exit 0; fi\nif [[ "${1:-}" == "-g" ]]; then printf "1000\\n"; exit 0; fi\nexec /usr/bin/id "$@"\n' > "$BIN/id"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/chown"
# sleep returns at once so the wait loops spin without real delay.
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/sleep"
# getent resolves a docker group and any host name.
cat > "$BIN/getent" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  group) printf 'docker:x:999:\n' ;;
  hosts) printf '127.0.0.1 %s\n' "${2:-}" ;;
esac
exit 0
EOF
# curl: every endpoint is healthy except hermes-agent, which follows
# HERMES_HEALTH ("ok" by default, anything else fails).
cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
url=""
for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
case "$url" in
  *8501*) [[ "${HERMES_HEALTH:-ok}" == "ok" ]] && exit 0 || exit 1 ;;
  *) exit 0 ;;
esac
EOF
# install: record the argv, then do the real copy so the mode and the bytes are
# genuine (the .sandbox-gitconfig assertions depend on that).
cat > "$BIN/install" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${INSTALL_ARGV_LOG:-/dev/null}"
exec /usr/bin/install "$@"
EOF
# systemctl: record the argv and answer from a scratch state directory. It also
# has to satisfy the backup scheduler's system-mode calls (daemon-reload, cat,
# enable --now, is-enabled, is-active) or that step starts failing.
cat > "$BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SYSTEMCTL_LOG:-/dev/null}"
[[ "${1:-}" == "--user" ]] && shift
cmd="${1:-}"; unit="${2:-}"
state="${SYSTEMCTL_STATE:-/nonexistent}"
case "$cmd" in
  daemon-reload|reload|start|restart|stop|disable) exit 0 ;;
  cat)
    [[ -f "${SYSTEMCTL_UNIT_DIR:-/nonexistent}/${unit}" ]] && exit 0
    case "$unit" in hybrid-ai-backup*|hybrid-ai-check*) exit 0 ;; esac
    exit 1 ;;
  enable)
    [[ "$unit" == "--now" ]] && unit="${3:-}"
    [[ -n "$unit" ]] && : > "${state}/${unit}.enabled"
    exit 0 ;;
  is-enabled)
    if [[ -e "${state}/${unit}.enabled" ]]; then printf 'enabled\n'; exit 0; fi
    printf 'disabled\n'; exit 1 ;;
  is-active) printf 'active\n'; exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$BIN"/*

# Root variant: only `id` differs, so it must win on PATH ahead of $BIN.
# shellcheck disable=SC2016  # $@ must expand inside the generated stub
printf '#!/usr/bin/env bash\nif [[ "${1:-}" == "-u" ]]; then printf "0\\n"; exit 0; fi\nif [[ "${1:-}" == "-g" ]]; then printf "1000\\n"; exit 0; fi\nexec /usr/bin/id "$@"\n' > "$BIN_ROOT/id"
chmod +x "$BIN_ROOT/id"

# A PATH with no systemctl anywhere: symlink farm over the real bin dirs, with
# the stubs layered on top and systemctl left out.
BIN_NOSYS="$WORK/bin-nosystemctl"
mkdir -p "$BIN_NOSYS" "$WORK/sysstate"
for d in /usr/bin /usr/local/bin /usr/sbin; do
  for f in "$d"/*; do
    b="${f##*/}"
    [[ "$b" == "systemctl" ]] && continue
    [[ -e "$BIN_NOSYS/$b" ]] && continue
    ln -s "$f" "$BIN_NOSYS/$b"
  done
done
for f in "$BIN"/*; do
  b="${f##*/}"
  [[ "$b" == "systemctl" ]] && continue
  ln -sfn "$f" "$BIN_NOSYS/$b"
done
ln -sfn "$BIN_ROOT/id" "$BIN_NOSYS/id"

INSTALL_ARGV="$WORK/install-argv.log"
SYSTEMCTL_ARGV="$WORK/systemctl-argv.log"

# run_install hermes_health log [unit_dir] [install_argv_log] [path]
# The path argument picks the variant: ROOT_PATH for the privileged runs and
# BIN_NOSYS for the no-systemctl run. The default is the unprivileged stubs.
run_install() {
  local health="$1" log="$2" rc=0
  local unit_dir="${3:-$SYSD}" argv_log="${4:-$INSTALL_ARGV}"
  local run_path="${5:-$BIN:$PATH}"
  env -u HYBRID_AI_APP_DIR -u HYBRID_AI_DATA_DIR -u HYBRID_AI_LOG_DIR \
      -u HYBRID_AI_WORK_DIR -u HYBRID_AI_STACK_ENV_FILE \
      -u OPENHANDS_WORKSPACE -u AGENT_REPOS_DIR -u OPENHANDS_STATE_DIR \
      -u BACKUP_CONF_DIR -u RESTIC_CACHE_DIR -u HYBRID_AI_HERMES_HOME_DIR \
      -u HYBRID_AI_BACKUP_MODE -u BACKUP_CONTAINER_CONTROL \
      -u HYBRID_AI_UID -u HYBRID_AI_GID -u HYBRID_AI_LAYOUT_UID -u HYBRID_AI_LAYOUT_GID \
      PATH="$run_path" \
      HYBRID_AI_ENV_FILE="$LAYOUT" \
      HYBRID_AI_SYSTEMD_UNIT_DIR="$unit_dir" \
      INSTALL_ARGV_LOG="$argv_log" \
      SYSTEMCTL_LOG="$SYSTEMCTL_ARGV" \
      SYSTEMCTL_STATE="$WORK/sysstate" \
      SYSTEMCTL_UNIT_DIR="$unit_dir" \
      HERMES_HEALTH="$health" \
      LOCAL_DOMAIN=example.test OPENROUTER_API_KEY=stub RUNPOD_API_KEY=stub \
      RUNPOD_POD_ID=stub RUNPOD_HOST=stub PI_HOST=stub \
      OPENHANDS_SANDBOX_HOST=example.test PEER_HOSTNAMES="none" \
      USER=fixture \
      bash "$APP/install.sh" --non-interactive >> "$log" 2>&1 || rc=$?
  return "$rc"
}
ROOT_PATH="$BIN_ROOT:$BIN:$PATH"

INSTALL_LOG="$WORK/log/install.log"

# ---------------------------------------------------------------------------
echo "== the Hermes wait window is raised from 120 s to 300 s =="
if grep -qE 'wait_for "hermes-agent".*300' "$REPO/install.sh"; then
  ok "hermes-agent waits 300 s"
else
  bad "hermes-agent does not wait 300 s"
fi
if grep -qE 'wait_for "openhands".*warn' "$REPO/install.sh" \
   && grep -qE 'wait_for "status page".*warn' "$REPO/install.sh"; then
  ok "OpenHands and the status page still only warn"
else
  bad "OpenHands or the status page no longer only warns"
fi

# ---------------------------------------------------------------------------
echo
echo "== a healthy hermes-agent exits 0 and logs install_success =="
: > "$INSTALL_LOG"
rc=0
run_install ok "$WORK/healthy.log" || rc=$?
check "install.sh exits 0 when every service is healthy" "0" "$rc"
if grep -q 'EVENT .*event=install_success' "$INSTALL_LOG"; then
  ok "install_success was logged"
else
  bad "install_success was not logged"
  sed 's/^/      /' "$WORK/healthy.log" >&2
fi
if grep -q 'EVENT .*event=install_failed' "$INSTALL_LOG"; then
  bad "install_failed was logged on a healthy run"
else
  ok "no install_failed event on a healthy run"
fi

# ---------------------------------------------------------------------------
echo
echo "== an unhealthy hermes-agent exits non-zero and logs install_failed (D7) =="
: > "$INSTALL_LOG"
rc=0
run_install bad "$WORK/unhealthy.log" || rc=$?
check "install.sh exits non-zero when hermes is unhealthy" "1" "$rc"
if grep -q 'EVENT .*event=install_failed.*reason=healthcheck' "$INSTALL_LOG"; then
  ok "install_failed reason=healthcheck was logged"
else
  bad "install_failed reason=healthcheck was not logged"
fi
if grep -q 'EVENT .*event=install_success' "$INSTALL_LOG"; then
  bad "install_success was logged despite an unhealthy hermes"
else
  ok "install_success was NOT logged for an unhealthy hermes"
fi
if grep -q 'hermes-agent did not become healthy' "$WORK/unhealthy.log"; then
  ok "the failed Hermes wait is reported"
else
  bad "the failed Hermes wait was not reported"
fi

# ---------------------------------------------------------------------------
echo
echo "== sandbox git ownership: scoped /etc/gitconfig, no blanket safe.directory =="
GITCFG="$REPO/openhands/sandbox-gitconfig"
if [[ -f "$GITCFG" ]]; then
  ok "openhands/sandbox-gitconfig exists"
else
  bad "openhands/sandbox-gitconfig is missing"
fi
if grep -qF 'directory = /workspace' "$GITCFG" \
   && grep -qF 'directory = /workspace/project/*' "$GITCFG"; then
  ok "the config scopes trust to the workspace roots"
else
  bad "the config does not list the workspace roots"
fi
if grep -Eq '^[[:space:]]*directory[[:space:]]*=[[:space:]]*\*[[:space:]]*$' "$GITCFG"; then
  bad "the config contains a blanket safe.directory '*'"
else
  ok "the config contains no blanket safe.directory '*'"
fi

COMPOSE="$REPO/openhands/docker-compose.openhands.yml"
if grep -qF '.sandbox-gitconfig:/etc/gitconfig:ro' "$COMPOSE" \
   && grep -qF ':/workspace:rw' "$COMPOSE"; then
  ok "the overlay mounts the config read-only at /etc/gitconfig"
else
  bad "the overlay does not mount the config at /etc/gitconfig"
fi

if ! grep -qF "safe.directory '*'" "$REPO/doctor.sh" \
   && ! grep -Eq "safe\.directory[[:space:]]*=[[:space:]]*['\"]?\\*" "$REPO/doctor.sh"; then
  ok "doctor.sh recommends no blanket safe.directory"
else
  bad "doctor.sh still recommends a blanket safe.directory"
fi
if grep -qF '/etc/gitconfig' "$REPO/doctor.sh" \
   && grep -qF './install.sh' "$REPO/doctor.sh"; then
  ok "doctor.sh names /etc/gitconfig and re-running install.sh"
else
  bad "doctor.sh does not name /etc/gitconfig or re-running install.sh"
fi

# Behavioural: the install path writes the config into the workspace.
: > "$WORK/gitcfg.log"
rc=0
run_install ok "$WORK/gitcfg.log" || rc=$?
check "install.sh exits 0 for the sandbox-config run" "0" "$rc"
WS_CFG="$WORK/ws/.sandbox-gitconfig"
if [[ -f "$WS_CFG" ]]; then
  ok "install.sh wrote .sandbox-gitconfig into the workspace"
else
  bad "install.sh did not write .sandbox-gitconfig"
fi
if [[ "$(stat -c '%a' "$WS_CFG" 2>/dev/null)" == "644" ]]; then
  ok ".sandbox-gitconfig has mode 0644"
else
  bad ".sandbox-gitconfig does not have mode 0644 (got '$(stat -c '%a' "$WS_CFG" 2>/dev/null)')"
fi
if cmp -s "$GITCFG" "$WS_CFG"; then
  ok ".sandbox-gitconfig matches the shipped config"
else
  bad ".sandbox-gitconfig differs from the shipped config"
fi
if grep -qxF '.sandbox-gitconfig' "$WORK/ws/.git/info/exclude"; then
  ok ".sandbox-gitconfig is excluded from the clone's git status"
else
  bad ".sandbox-gitconfig is not in the clone's .git/info/exclude"
fi
# install.sh runs as root on the host, so `install` creates the mount source
# root-owned unless it is handed to the stack identity like project/ and
# conversations/. A root-owned file fails doctor's workspace check and turns the
# deploy red; chown is stubbed here, so assert the CODE, not the resulting owner.
if grep -F 'chown -R' "$REPO/install.sh" | grep -qF '.sandbox-gitconfig'; then
  ok "install.sh hands .sandbox-gitconfig to the stack owner"
else
  bad "install.sh leaves .sandbox-gitconfig root-owned (doctor fails the workspace check)"
fi

# ---------------------------------------------------------------------------
echo
echo "== the deploy path installs and enables the boot firewall unit =="
UNIT="hybrid-ai-firewall.service"
UNIT_SRC="$REPO/deploy/hybrid-ai-firewall.service"
UNIT_INSTALLED="$SYSD/$UNIT"

# (a) fresh root run: install the unit 0644 into the scratch unit dir, reload,
# enable, verify. The installer must not start it, and must never use sudo.
rm -f "$UNIT_INSTALLED"; : > "$INSTALL_ARGV"; : > "$SYSTEMCTL_ARGV"
rm -rf "${WORK:?}/sysstate"; mkdir -p "$WORK/sysstate"
: > "$INSTALL_LOG"
rc=0
run_install ok "$WORK/fw-fresh.log" "$SYSD" "$INSTALL_ARGV" "$ROOT_PATH" || rc=$?
check "root run with the firewall unit exits 0" "0" "$rc"

if grep -F -- "-m 0644" "$INSTALL_ARGV" | grep -qF "$APP/deploy/$UNIT $UNIT_INSTALLED.tmp"; then
  ok "install recorded -m 0644 of the unit into the scratch unit dir"
else
  bad "install did not record a -m 0644 copy of the unit into the scratch unit dir"
  sed 's/^/      /' "$INSTALL_ARGV" >&2
fi
if [[ -f "$UNIT_INSTALLED" ]]; then
  ok "the unit file exists in the scratch unit dir"
else
  bad "the unit file was not written to the scratch unit dir"
fi
check "the installed unit has mode 0644" "644" "$(stat -c '%a' "$UNIT_INSTALLED" 2>/dev/null)"
if cmp -s "$UNIT_SRC" "$UNIT_INSTALLED"; then
  ok "the installed unit matches the shipped unit"
else
  bad "the installed unit differs from the shipped unit"
fi
if grep -qxF 'daemon-reload' "$SYSTEMCTL_ARGV"; then
  ok "systemctl daemon-reload was recorded"
else
  bad "systemctl daemon-reload was not recorded"
fi
if grep -qxF "enable $UNIT" "$SYSTEMCTL_ARGV"; then
  ok "systemctl enable $UNIT was recorded"
else
  bad "systemctl enable $UNIT was not recorded"
fi
if grep -qxF "is-enabled $UNIT" "$SYSTEMCTL_ARGV"; then
  ok "systemctl is-enabled $UNIT verified the result"
else
  bad "systemctl is-enabled $UNIT was not run"
fi
if grep -E '^(enable|start|restart|disable) ' "$SYSTEMCTL_ARGV" | grep -q -- '--now'; then
  bad "the firewall unit was enabled with --now (rules must not be re-applied here)"
else
  ok "the firewall unit was enabled without --now"
fi
if grep -Eq '^(start|restart|disable) '"$UNIT"'$' "$SYSTEMCTL_ARGV"; then
  bad "the firewall unit was started, restarted or disabled"
else
  ok "the firewall unit was not started, restarted or disabled"
fi
if grep -q 'EVENT .*event=sandbox_firewall_unit_installed' "$INSTALL_LOG"; then
  ok "sandbox_firewall_unit_installed was logged"
else
  bad "sandbox_firewall_unit_installed was not logged"
fi
if grep -Eq '(^|[[:space:]])sudo([[:space:]]|$)' "$INSTALL_ARGV" "$SYSTEMCTL_ARGV"; then
  bad "sudo appears in a recorded argv"
else
  ok "no sudo in any recorded argv"
fi

# (b) rerun: byte-identical unit, still enabled, exit 0.
snapshot="$WORK/unit-first.bin"
cp "$UNIT_INSTALLED" "$snapshot" 2>/dev/null || true
: > "$SYSTEMCTL_ARGV"
rc=0
run_install ok "$WORK/fw-rerun.log" "$SYSD" "$INSTALL_ARGV" "$ROOT_PATH" || rc=$?
check "a second root run exits 0" "0" "$rc"
if cmp -s "$snapshot" "$UNIT_INSTALLED"; then
  ok "a second run leaves the unit byte-identical"
else
  bad "a second run changed the unit file"
fi
if [[ -e "$WORK/sysstate/$UNIT.enabled" ]]; then
  ok "the unit stays enabled after the rerun"
else
  bad "the unit is no longer enabled after the rerun"
fi
if grep -q 'already enabled' "$WORK/fw-rerun.log"; then
  ok "the rerun reports the unit as already enabled"
else
  bad "the rerun did not report the unit as already enabled"
fi
if grep -qxF "is-enabled $UNIT" "$SYSTEMCTL_ARGV"; then
  ok "the rerun still verifies is-enabled"
else
  bad "the rerun did not verify is-enabled"
fi

# (c) non-root: warn, exit 0, no install of the unit and no mutating systemctl.
rm -f "$UNIT_INSTALLED"; : > "$INSTALL_ARGV"; : > "$SYSTEMCTL_ARGV"
rm -rf "${WORK:?}/sysstate"; mkdir -p "$WORK/sysstate"
: > "$INSTALL_LOG"
rc=0
run_install ok "$WORK/fw-nonroot.log" "$SYSD" "$INSTALL_ARGV" || rc=$?
check "a non-root run still exits 0" "0" "$rc"
if grep -q 'needs root to install' "$WORK/fw-nonroot.log"; then
  ok "the non-root run warns about the firewall unit"
else
  bad "the non-root run did not warn about the firewall unit"
fi
if grep -q 'EVENT .*event=sandbox_firewall_unit_failed .*reason=not_root' "$INSTALL_LOG"; then
  ok "sandbox_firewall_unit_failed reason=not_root was logged"
else
  bad "sandbox_firewall_unit_failed reason=not_root was not logged"
fi
if grep -qF "$UNIT" "$INSTALL_ARGV"; then
  bad "the non-root run recorded an install of the firewall unit"
else
  ok "the non-root run recorded no install of the firewall unit"
fi
if grep -Eq "^(enable|start|restart|disable|daemon-reload)" "$SYSTEMCTL_ARGV"; then
  bad "the non-root run recorded a mutating systemctl call"
else
  ok "the non-root run recorded no mutating systemctl call"
fi
if [[ -e "$UNIT_INSTALLED" ]]; then
  bad "the non-root run wrote the unit file"
else
  ok "the non-root run wrote no unit file"
fi

# (d) systemctl absent: warn, exit 0, and the unit is not installed.
rm -f "$UNIT_INSTALLED"; : > "$INSTALL_ARGV"; : > "$SYSTEMCTL_ARGV"
: > "$INSTALL_LOG"
rc=0
run_install ok "$WORK/fw-nosystemctl.log" "$SYSD" "$INSTALL_ARGV" "$BIN_NOSYS" || rc=$?
check "a run without systemctl still exits 0" "0" "$rc"
if grep -q 'systemctl is unavailable' "$WORK/fw-nosystemctl.log"; then
  ok "the run without systemctl warns"
else
  bad "the run without systemctl did not warn"
fi
if grep -q 'EVENT .*event=sandbox_firewall_unit_failed .*reason=systemctl_missing' "$INSTALL_LOG"; then
  ok "sandbox_firewall_unit_failed reason=systemctl_missing was logged"
else
  bad "sandbox_firewall_unit_failed reason=systemctl_missing was not logged"
fi
if [[ -e "$UNIT_INSTALLED" ]]; then
  bad "the run without systemctl installed the unit anyway"
else
  ok "the run without systemctl installed nothing"
fi

# ---------------------------------------------------------------------------
echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
