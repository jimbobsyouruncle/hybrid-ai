#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/test-deploy-wiring-install.sh
# PURPOSE (plain English):
#   Offline tests for install.sh's re-application of the headless-deploy wiring
#   (the system unit and the polkit rule). They need NO root, NO Docker and NO
#   network: every host command install.sh probes is stubbed on PATH, and the
#   unit and polkit directories are redirected into a scratch tree.
#
#   The bug this covers: scripts/bootstrap.sh installs both files ONCE, on a
#   fresh device, and install.sh never mentioned them. A later fix to either
#   file therefore never reached an already-bootstrapped host. On 2026-10-22 the
#   host enforced a stale TimeoutStartSec=20min against the tree's 45min and
#   SIGTERM'd a deploy mid-build. install.sh now re-applies both files on every
#   deploy, so the host always matches the tree it is deploying.
#
# CASES:
#   (a) no unit installed            -> installed 0644, byte-identical to tree
#   (b) stale unit (20 min timeout)  -> replaced by the tree content
#   (c) absent / stale polkit rule   -> installed / refreshed, byte-identical
#   (d) the systemctl log never shows an enable or start of a
#       hybrid-ai-deploy@* unit (the template must stay never-enabled)
#   (e) non-root                     -> warns, writes nothing, exit 0
#   (f) systemctl missing            -> warns, writes nothing, exit 0
#   (g) install.sh's exit status is unchanged in EVERY case
#   (h) a --no-start run still places both files
#
#   Against an install.sh without the wiring (the base commit) cases (a)-(c)
#   and (h) fail.
#
# USAGE:
#   bash scripts/test-deploy-wiring-install.sh
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
for t in mktemp stat grep cmp install; do
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

UNIT="hybrid-ai-deploy@.service"
RULE="50-hybrid-ai-deploy.rules"
VERIFIER="run-post-deploy-verify.sh"
UNIT_SRC="$REPO/deploy/$UNIT"
RULE_SRC="$REPO/deploy/$RULE"
VERIFIER_SRC="$REPO/scripts/$VERIFIER"
[[ -f "$UNIT_SRC" ]] || { echo "FATAL: cannot find deploy/$UNIT" >&2; exit 2; }
[[ -f "$RULE_SRC" ]] || { echo "FATAL: cannot find deploy/$RULE" >&2; exit 2; }
[[ -f "$VERIFIER_SRC" ]] || { echo "FATAL: cannot find scripts/$VERIFIER" >&2; exit 2; }

# --- scratch app + layout ----------------------------------------------------
APP="$WORK/app"
BIN="$WORK/bin"
BIN_ROOT="$WORK/bin-root"
SYSD="$WORK/systemd"
POLKITD="$WORK/polkit-rules.d"
SBIND="$WORK/sbin"
mkdir -p "$APP/scripts/lib" "$APP/deploy" "$BIN" "$BIN_ROOT" "$SYSD" "$POLKITD" "$SBIND" \
         "$WORK/data" "$WORK/log" "$WORK/work" "$WORK/ws" "$WORK/repos" \
         "$WORK/ohstate" "$WORK/conf" "$WORK/restic" "$WORK/etc/hybrid-ai" \
         "$WORK/sysstate"
cp "$REPO/install.sh" "$APP/install.sh"
cp "$REPO/scripts/lib/hybrid-ai-env.sh" "$APP/scripts/lib/"
if [[ -f "$REPO/scripts/lib/build-gate.sh" ]]; then
  cp "$REPO/scripts/lib/build-gate.sh" "$APP/scripts/lib/"
fi

# install.sh sources scripts/lib/tls.sh and its TLS render step reads the
# tracked templates, so the scratch app tree must carry them too.
mkdir -p "$APP/status"
cp "$REPO/scripts/lib/tls.sh" "$APP/scripts/lib/"
cp "$REPO/status/Caddyfile.tmpl" "$APP/status/Caddyfile.tmpl"
cp "$REPO/docker-compose.yml.tmpl" "$APP/docker-compose.yml.tmpl"
cp "$UNIT_SRC" "$RULE_SRC" "$APP/deploy/"
[[ -f "$REPO/deploy/hybrid-ai-firewall.service" ]] && \
  cp "$REPO/deploy/hybrid-ai-firewall.service" "$APP/deploy/"
mkdir -p "$APP/openhands" "$WORK/ws/.git/info"
[[ -f "$REPO/openhands/sandbox-gitconfig" ]] && \
  cp "$REPO/openhands/sandbox-gitconfig" "$APP/openhands/sandbox-gitconfig"
: > "$WORK/ws/.git/info/exclude"
# The agent scripts are not under test here; stub them so the run stays quiet.
for s in setup-agent-workspace.sh sync-agent-repos.sh check-hermes-nonroot.sh; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$APP/scripts/$s"
done
# The verifier is copied byte-identical: the install cases compare the placed
# file against the tree.
cp "$VERIFIER_SRC" "$APP/scripts/$VERIFIER"
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
for d in docker git jq openssl sqlite3 rsync tailscale hostname \
         loginctl setfacl apt-get restic; do
  # shellcheck disable=SC2016  # $0 must expand inside the generated stub
  printf '#!/usr/bin/env bash\nprintf "%%s stub\\n" "$0"\nexit 0\n' > "$BIN/$d"
done
# sudo records its argv and swallows the call. install.sh does use sudo
# elsewhere, so the assertions below look only at unit/polkit/systemctl argv.
# nproc must answer with a number: install.sh uses it in arithmetic.
printf '#!/usr/bin/env bash\nprintf "4\\n"\n' > "$BIN/nproc"
cat > "$BIN/sudo" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SUDO_ARGV_LOG:-/dev/null}"
exit 0
EOF
# `id` answers without a real account; chown is a no-op.
# shellcheck disable=SC2016  # $@ must expand inside the generated stub
printf '#!/usr/bin/env bash\nif [[ "${1:-}" == "-u" ]]; then printf "1000\\n"; exit 0; fi\nif [[ "${1:-}" == "-g" ]]; then printf "1000\\n"; exit 0; fi\nexec /usr/bin/id "$@"\n' > "$BIN/id"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/chown"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/sleep"
cat > "$BIN/getent" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  group) printf 'docker:x:999:\n' ;;
  hosts) printf '[IP_ADDRESS] %s\n' "${2:-}" ;;
esac
exit 0
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/curl"
# install: record the argv, then do the real copy so the mode and the bytes are
# genuine. CI is not root, so -o root -g root is stripped before exec'ing the
# real install: only the argv assertion cares about the ownership flags.
cat > "$BIN/install" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${INSTALL_ARGV_LOG:-/dev/null}"
args=()
while (( $# )); do
  case "$1" in
    -o|-g) shift 2; continue ;;
  esac
  args+=("$1"); shift
done
exec /usr/bin/install "${args[@]}"
EOF
# systemctl: record the argv and answer from a scratch state directory. It has
# to satisfy the other install steps too (daemon-reload, cat, enable --now,
# is-enabled, is-active) or their own checks start failing.
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
ROOT_PATH="$BIN_ROOT:$BIN:$PATH"

# A PATH with no systemctl anywhere: a symlink farm over the real bin dirs with
# the stubs layered on top and systemctl left out.
BIN_NOSYS="$WORK/bin-nosystemctl"
mkdir -p "$BIN_NOSYS"
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
SUDO_ARGV="$WORK/sudo-argv.log"

# run_install log rc_name [extra args...] - the caller sets RUN_PATH and
# RUN_EXTRA for the variant.
run_install() {
  local log="$1" rc=0
  shift
  : > "$INSTALL_ARGV"; : > "$SYSTEMCTL_ARGV"; : > "$SUDO_ARGV"
  env -u HYBRID_AI_APP_DIR -u HYBRID_AI_DATA_DIR -u HYBRID_AI_LOG_DIR \
      -u HYBRID_AI_WORK_DIR -u HYBRID_AI_STACK_ENV_FILE \
      -u OPENHANDS_WORKSPACE -u AGENT_REPOS_DIR -u OPENHANDS_STATE_DIR \
      -u BACKUP_CONF_DIR -u RESTIC_CACHE_DIR -u HYBRID_AI_HERMES_HOME_DIR \
      -u HYBRID_AI_BACKUP_MODE -u BACKUP_CONTAINER_CONTROL \
      -u HYBRID_AI_UID -u HYBRID_AI_GID \
      -u HYBRID_AI_POST_DEPLOY_VERIFY_CMD -u HYBRID_AI_POST_DEPLOY_VERIFY_LOG \
      PATH="${RUN_PATH:-$BIN:$PATH}" \
      HYBRID_AI_ENV_FILE="$LAYOUT" \
      HYBRID_AI_SYSTEMD_UNIT_DIR="$SYSD" \
      HYBRID_AI_POLKIT_RULES_DIR="$POLKITD" \
      HYBRID_AI_SBIN_DIR="$SBIND" \
      INSTALL_ARGV_LOG="$INSTALL_ARGV" \
      SUDO_ARGV_LOG="$SUDO_ARGV" \
      SYSTEMCTL_LOG="$SYSTEMCTL_ARGV" \
      SYSTEMCTL_STATE="$WORK/sysstate" \
      SYSTEMCTL_UNIT_DIR="$SYSD" \
      LOCAL_DOMAIN=example.test OPENROUTER_API_KEY=stub RUNPOD_API_KEY=stub \
      RUNPOD_POD_ID=stub RUNPOD_HOST=stub PI_HOST=stub \
      OPENHANDS_SANDBOX_HOST=example.test PEER_HOSTNAMES="none" \
      USER=fixture \
      bash "$APP/install.sh" --non-interactive "$@" >> "$log" 2>&1 || rc=$?
  return "$rc"
}

reset_state() {
  rm -f "$SYSD/$UNIT" "$POLKITD/$RULE"
  rm -rf "${WORK:?}/sysstate"; mkdir -p "$WORK/sysstate"
}

reset_sbin() { rm -f "$SBIND/$VERIFIER"; }

# ---------------------------------------------------------------------------
echo "== (a) an absent unit is installed 0644 and byte-identical =="
reset_state
RUN_PATH="$ROOT_PATH"
: > "$WORK/a.log"
rc=0
run_install "$WORK/a.log" --no-start || rc=$?
check "(a) the run exits 0" "0" "$rc"
if [[ -f "$SYSD/$UNIT" ]]; then
  ok "(a) the unit was installed into the scratch unit dir"
else
  bad "(a) the unit was NOT installed"
  sed 's/^/      /' "$WORK/a.log" >&2
fi
check "(a) the installed unit has mode 0644" "644" "$(stat -c '%a' "$SYSD/$UNIT" 2>/dev/null)"
if cmp -s "$UNIT_SRC" "$SYSD/$UNIT"; then
  ok "(a) the installed unit is byte-identical to the tree"
else
  bad "(a) the installed unit differs from the tree"
fi
if grep -q 'EVENT .*event=deploy_unit_installed' "$WORK/log/install.log"; then
  ok "(a) deploy_unit_installed was logged"
else
  bad "(a) deploy_unit_installed was not logged"
fi

echo
echo "== (b) a stale unit is replaced by the tree content =="
stale_tmp="$WORK/stale.unit"
sed 's/^TimeoutStartSec=45min$/TimeoutStartSec=20min/' "$UNIT_SRC" > "$stale_tmp"
grep -qx 'TimeoutStartSec=20min' "$stale_tmp" \
  || bad "(b) could not build the stale fixture (no TimeoutStartSec=45min line)"
install -m 0644 "$stale_tmp" "$SYSD/$UNIT"
grep -qx 'TimeoutStartSec=20min' "$SYSD/$UNIT" \
  && ok "(b) the stale unit is in place before the run"
: > "$WORK/b.log"
rc=0
run_install "$WORK/b.log" --no-start || rc=$?
check "(b) the run exits 0" "0" "$rc"
if cmp -s "$UNIT_SRC" "$SYSD/$UNIT"; then
  ok "(b) the stale unit was refreshed to the tree content"
else
  bad "(b) the stale unit was NOT refreshed"
  diff -u "$UNIT_SRC" "$SYSD/$UNIT" | sed 's/^/      /' >&2 || true
fi
if grep -qx 'TimeoutStartSec=45min' "$SYSD/$UNIT"; then
  ok "(b) the host now enforces the 45-minute ceiling"
else
  bad "(b) the host does not enforce the 45-minute ceiling"
fi

echo
echo "== (c) the polkit rule is installed and refreshed byte-identically =="
reset_state
: > "$WORK/c.log"
rc=0
run_install "$WORK/c.log" --no-start || rc=$?
check "(c) the run exits 0" "0" "$rc"
if [[ -f "$POLKITD/$RULE" ]]; then
  ok "(c) the rule was installed into the scratch polkit dir"
else
  bad "(c) the rule was NOT installed"
  sed 's/^/      /' "$WORK/c.log" >&2
fi
check "(c) the installed rule has mode 0644" "644" "$(stat -c '%a' "$POLKITD/$RULE" 2>/dev/null)"
if cmp -s "$RULE_SRC" "$POLKITD/$RULE"; then
  ok "(c) the installed rule is byte-identical to the tree"
else
  bad "(c) the installed rule differs from the tree"
fi
if grep -q 'EVENT .*event=deploy_polkit_rule_installed' "$WORK/log/install.log"; then
  ok "(c) deploy_polkit_rule_installed was logged"
else
  bad "(c) deploy_polkit_rule_installed was not logged"
fi
if grep -qx 'reload polkit' "$SYSTEMCTL_ARGV"; then
  ok "(c) polkit was reloaded"
else
  bad "(c) polkit was not reloaded"
fi

# stale rule: corrupt the installed copy, re-run, expect the tree content back
printf '// stale\n' > "$POLKITD/$RULE"
: > "$WORK/c2.log"
rc=0
run_install "$WORK/c2.log" --no-start || rc=$?
check "(c) the refresh run exits 0" "0" "$rc"
if cmp -s "$RULE_SRC" "$POLKITD/$RULE"; then
  ok "(c) the stale rule was refreshed to the tree content"
else
  bad "(c) the stale rule was NOT refreshed"
  diff -u "$RULE_SRC" "$POLKITD/$RULE" | sed 's/^/      /' >&2 || true
fi

echo
echo "== (d) the template unit is never enabled and never started =="
if grep -E '^(enable|start|restart|stop|disable)[[:space:]]' "$SYSTEMCTL_ARGV" \
     | grep -q 'hybrid-ai-deploy'; then
  bad "(d) systemctl was asked to enable/start/stop a hybrid-ai-deploy unit"
  grep -E '^(enable|start|restart|stop|disable)[[:space:]]' "$SYSTEMCTL_ARGV" | sed 's/^/      /' >&2
else
  ok "(d) no enable/start/stop of any hybrid-ai-deploy unit was recorded"
fi
if grep -qxF 'daemon-reload' "$SYSTEMCTL_ARGV"; then
  ok "(d) daemon-reload was recorded so the new unit is visible"
else
  bad "(d) daemon-reload was not recorded"
fi
if grep -Eq '^[[:space:]]*Restart=' "$UNIT_SRC"; then
  bad "(d) the unit gained a Restart= policy"
else
  ok "(d) the unit carries no Restart= policy"
fi
if grep -Eq '^[[:space:]]*TimeoutStartSec=45min' "$UNIT_SRC"; then
  ok "(d) the unit keeps TimeoutStartSec=45min"
else
  bad "(d) the unit lost TimeoutStartSec=45min"
fi

echo
echo "== idempotency: a second identical run succeeds and changes nothing =="
reset_state
: > "$WORK/idem1.log"
rc=0
run_install "$WORK/idem1.log" --no-start || rc=$?
check "the first run exits 0" "0" "$rc"
cp "$SYSD/$UNIT" "$WORK/unit-first.bin" 2>/dev/null || true
cp "$POLKITD/$RULE" "$WORK/rule-first.bin" 2>/dev/null || true
: > "$WORK/idem2.log"
rc=0
run_install "$WORK/idem2.log" --no-start || rc=$?
check "the second run exits 0" "0" "$rc"
if cmp -s "$WORK/unit-first.bin" "$SYSD/$UNIT"; then
  ok "the second run leaves the unit byte-identical"
else
  bad "the second run changed the unit file"
fi
if cmp -s "$WORK/rule-first.bin" "$POLKITD/$RULE"; then
  ok "the second run leaves the rule byte-identical"
else
  bad "the second run changed the rule file"
fi
if grep -qiE 'error|cannot|failed' "$WORK/idem2.log"; then
  bad "the second run printed an error"
  grep -iE 'error|cannot|failed' "$WORK/idem2.log" | sed 's/^/      /' >&2
else
  ok "the second run printed no error"
fi

echo
echo "== (e) a non-root run warns and writes nothing =="
reset_state
RUN_PATH="$BIN:$PATH"
: > "$WORK/e.log"
rc=0
run_install "$WORK/e.log" --no-start || rc=$?
check "(e) the non-root run still exits 0" "0" "$rc"
if grep -q 'needs root' "$WORK/e.log"; then
  ok "(e) the non-root run warns about the deploy wiring"
else
  bad "(e) the non-root run did not warn"
fi
if grep -q 'EVENT .*event=deploy_unit_install_failed .*reason=not_root' "$WORK/log/install.log"; then
  ok "(e) deploy_unit_install_failed reason=not_root was logged"
else
  bad "(e) deploy_unit_install_failed reason=not_root was not logged"
fi
if grep -q 'EVENT .*event=deploy_polkit_rule_install_failed .*reason=not_root' "$WORK/log/install.log"; then
  ok "(e) deploy_polkit_rule_install_failed reason=not_root was logged"
else
  bad "(e) deploy_polkit_rule_install_failed reason=not_root was not logged"
fi
if [[ -e "$SYSD/$UNIT" || -e "$POLKITD/$RULE" ]]; then
  bad "(e) the non-root run wrote a file"
else
  ok "(e) the non-root run wrote no file"
fi
if grep -q 'hybrid-ai-deploy' "$INSTALL_ARGV" || grep -q 'hybrid-ai-deploy' "$SYSTEMCTL_ARGV"; then
  bad "(e) the non-root run tried to install or reload the deploy unit"
else
  ok "(e) the non-root run made no install/systemctl call for the deploy wiring"
fi
if grep -q 'hybrid-ai-deploy' "$SUDO_ARGV"; then
  bad "(e) the non-root run shelled out through sudo"
  grep 'hybrid-ai-deploy' "$SUDO_ARGV" | sed 's/^/      sudo /' >&2
else
  ok "(e) the non-root run made no sudo call for the deploy wiring"
fi

echo
echo "== (f) a run without systemctl warns and writes nothing =="
reset_state
RUN_PATH="$BIN_NOSYS"
: > "$WORK/f.log"
rc=0
run_install "$WORK/f.log" --no-start || rc=$?
check "(f) the run without systemctl still exits 0" "0" "$rc"
if grep -q 'systemctl is unavailable' "$WORK/f.log"; then
  ok "(f) the run without systemctl warns"
else
  bad "(f) the run without systemctl did not warn"
fi
if grep -q 'EVENT .*event=deploy_unit_install_failed .*reason=systemctl_missing' "$WORK/log/install.log"; then
  ok "(f) deploy_unit_install_failed reason=systemctl_missing was logged"
else
  bad "(f) deploy_unit_install_failed reason=systemctl_missing was not logged"
fi
if [[ -e "$SYSD/$UNIT" || -e "$POLKITD/$RULE" ]]; then
  bad "(f) the run without systemctl installed a file anyway"
else
  ok "(f) the run without systemctl installed nothing"
fi

echo
echo "== (h) a --no-start run still places both files =="
reset_state
RUN_PATH="$ROOT_PATH"
: > "$WORK/h.log"
rc=0
run_install "$WORK/h.log" --no-start || rc=$?
check "(h) the --no-start run exits 0" "0" "$rc"
if [[ -f "$SYSD/$UNIT" && -f "$POLKITD/$RULE" ]]; then
  ok "(h) --no-start placed the unit and the rule"
else
  bad "(h) --no-start did not place the unit and the rule"
  sed 's/^/      /' "$WORK/h.log" >&2
fi
if grep -q -- '--no-start requested' "$WORK/h.log"; then
  ok "(h) the run really took the --no-start path"
else
  bad "(h) the run did not take the --no-start path"
fi

# ---------------------------------------------------------------------------
echo
echo "== (i) the post-deploy verifier is installed root:root 0755, byte-identical =="
reset_state; reset_sbin
RUN_PATH="$ROOT_PATH"
: > "$WORK/i.log"
rc=0
run_install "$WORK/i.log" --no-start || rc=$?
check "(i) the run exits 0" "0" "$rc"
if [[ -f "$SBIND/$VERIFIER" ]]; then
  ok "(i) the verifier was installed into the scratch sbin dir"
else
  bad "(i) the verifier was NOT installed"
  sed 's/^/      /' "$WORK/i.log" >&2
fi
check "(i) the installed verifier has mode 0755" "755" "$(stat -c '%a' "$SBIND/$VERIFIER" 2>/dev/null)"
if cmp -s "$VERIFIER_SRC" "$SBIND/$VERIFIER"; then
  ok "(i) the installed verifier is byte-identical to the tree"
else
  bad "(i) the installed verifier differs from the tree"
fi
if grep -q -- "-o root -g root -m 0755 $APP/scripts/$VERIFIER" "$INSTALL_ARGV"; then
  ok "(i) install was asked for root:root and mode 0755"
else
  bad "(i) install was not asked for -o root -g root -m 0755"
  sed 's/^/      /' "$INSTALL_ARGV" >&2
fi
if grep -q 'EVENT .*event=post_deploy_verifier_installed' "$WORK/log/install.log"; then
  ok "(i) post_deploy_verifier_installed was logged"
else
  bad "(i) post_deploy_verifier_installed was not logged"
fi
if grep -E '^(enable|start|restart|stop|disable)[[:space:]]' "$SYSTEMCTL_ARGV" \
     | grep -q 'post-deploy-verify'; then
  bad "(i) systemctl was asked to enable/start a verifier unit"
else
  ok "(i) the verifier is never enabled or started by systemctl"
fi

echo
echo "== (j) a re-install replaces an existing copy byte-identically =="
printf '#!/usr/bin/env bash\n# stale\nexit 1\n' > "$SBIND/$VERIFIER"
chmod 0600 "$SBIND/$VERIFIER"
: > "$WORK/j.log"
rc=0
run_install "$WORK/j.log" --no-start || rc=$?
check "(j) the re-install run exits 0" "0" "$rc"
check "(j) the replaced file has mode 0755" "755" "$(stat -c '%a' "$SBIND/$VERIFIER" 2>/dev/null)"
if cmp -s "$VERIFIER_SRC" "$SBIND/$VERIFIER"; then
  ok "(j) the stale copy was replaced by the tree content"
else
  bad "(j) the stale copy was NOT replaced"
  diff -u "$VERIFIER_SRC" "$SBIND/$VERIFIER" | sed 's/^/      /' >&2 || true
fi
if [[ -e "$SBIND/$VERIFIER.tmp" ]]; then
  bad "(j) a staging file was left behind"
else
  ok "(j) no staging file was left behind"
fi

echo
echo "== (k) a --no-start run still installs the verifier =="
reset_state; reset_sbin
: > "$WORK/k.log"
rc=0
run_install "$WORK/k.log" --no-start || rc=$?
check "(k) the --no-start run exits 0" "0" "$rc"
if [[ -f "$SBIND/$VERIFIER" ]]; then
  ok "(k) --no-start placed the verifier"
else
  bad "(k) --no-start did not place the verifier"
fi
if grep -q -- '--no-start requested' "$WORK/k.log"; then
  ok "(k) the run really took the --no-start path"
else
  bad "(k) the run did not take the --no-start path"
fi

echo
echo "== (l) a non-root run warns and writes no verifier =="
reset_state; reset_sbin
RUN_PATH="$BIN:$PATH"
: > "$WORK/l.log"
rc=0
run_install "$WORK/l.log" --no-start || rc=$?
check "(l) the non-root run still exits 0" "0" "$rc"
if grep -q 'post-deploy verifier needs root' "$WORK/l.log"; then
  ok "(l) the non-root run warns about the verifier"
else
  bad "(l) the non-root run did not warn about the verifier"
fi
if grep -q 'EVENT .*event=post_deploy_verifier_install_failed .*reason=not_root' "$WORK/log/install.log"; then
  ok "(l) post_deploy_verifier_install_failed reason=not_root was logged"
else
  bad "(l) post_deploy_verifier_install_failed reason=not_root was not logged"
fi
if [[ -e "$SBIND/$VERIFIER" ]]; then
  bad "(l) the non-root run wrote the verifier"
else
  ok "(l) the non-root run wrote no verifier"
fi
if grep -q "$VERIFIER" "$SUDO_ARGV"; then
  bad "(l) the non-root run shelled out through sudo for the verifier"
else
  ok "(l) the non-root run made no sudo call for the verifier"
fi

# ---------------------------------------------------------------------------
echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
