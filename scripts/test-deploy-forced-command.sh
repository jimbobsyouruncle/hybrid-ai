#!/usr/bin/env bash
set -Eeuo pipefail
# ---------------------------------------------------------------------------
# FILE: scripts/test-deploy-forced-command.sh
# PURPOSE (plain English):
#   Offline tests for scripts/deploy-forced-command.sh, the forced-command SSH
#   entrypoint behind the headless deploy. systemctl is stubbed on PATH (it
#   records its argv and can be told to fail), so no Docker, no network and no
#   root are needed. The REAL script is invoked by absolute path.
#
#   The test proves that the entrypoint accepts EXACTLY `deploy <40-hex>` and
#   refuses everything else with exit 2 and nothing run: extra arguments, a
#   wrong verb, shell metacharacters, an empty command, an uppercase or short
#   sha. It proves the SYSTEM manager is used (no --user), that a unit failure
#   is a non-zero exit (3), and that the run log is printed from
#   $HYBRID_AI_LOG_DIR/deploy/<sha>.log.
#
#   It also statically checks the polkit rule grants only what the forced
#   command needs: the exact user, action id, verb and unit regex.
#
# USAGE:
#   bash scripts/test-deploy-forced-command.sh
#
# EXIT CODES:
#   0  every case passed
#   1  one or more cases failed
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
SCRIPT="${SCRIPT_DIR}/deploy-forced-command.sh"
UNIT_FILE="${REPO}/deploy/hybrid-ai-deploy@.service"
POLKIT_FILE="${REPO}/deploy/50-hybrid-ai-deploy.rules"

for f in "$SCRIPT" "$UNIT_FILE" "$POLKIT_FILE"; do
  [[ -f "$f" ]] || { echo "FATAL: cannot find $f" >&2; exit 1; }
done

WORKDIR="$(mktemp -d)"
trap 'rm -rf -- "$WORKDIR"' EXIT

BIN="$WORKDIR/bin"
SYSCTL_LOG="$WORKDIR/systemctl.log"
LOGDIR="$WORKDIR/log"
mkdir -p "$BIN" "$LOGDIR"
export SYSCTL_LOG

PASS=0
FAIL=0
ok()  { PASS=$(( PASS + 1 )); printf 'ok   %s\n' "$*"; }
bad() { FAIL=$(( FAIL + 1 )); printf 'FAIL %s\n' "$*" >&2; }
has_line()    { grep -Fq -- "$2" "$1"; }
hasnt_regex() { ! grep -Eq -- "$2" "$1"; }

# --- systemctl stub ---------------------------------------------------------
cat > "$BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SYSCTL_LOG"
case "$1" in
  start) exit "${SYSCTL_START_RC:-0}" ;;
  show)  printf '%s\n' "${SYSCTL_RESULT:-success}"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$BIN/systemctl"
export PATH="$BIN:$PATH"

SHA="0123456789abcdef0123456789abcdef01234567"

# run <cmd> [env...] -> writes combined output to $WORKDIR/out, echoes rc
run() {
  local cmd="$1"; shift
  : > "$SYSCTL_LOG"
  local rc=0
  SSH_ORIGINAL_COMMAND="$cmd" \
  HYBRID_AI_ENV_FILE="$WORKDIR/empty.env" \
  HYBRID_AI_LOG_DIR="$LOGDIR" \
  "$@" "$SCRIPT" >"$WORKDIR/out" 2>&1 || rc=$?
  printf '%s' "$rc"
}

: > "$WORKDIR/empty.env"

echo "== accepted command =="
rc="$(run "deploy $SHA")"
if [[ "$rc" == "0" ]]; then
  ok "accepted 'deploy <40-hex>' exits 0"
else
  bad "accepted command exited $rc (want 0)"
  sed 's/^/      /' "$WORKDIR/out" >&2 || true
fi
if has_line "$SYSCTL_LOG" "start hybrid-ai-deploy@${SHA}.service"; then
  ok "started the exact system unit hybrid-ai-deploy@<sha>.service"
else
  bad "did not start the expected unit"
fi
if hasnt_regex "$SYSCTL_LOG" '--user'; then
  ok "used the SYSTEM manager (no --user anywhere)"
else
  bad "invoked a user manager (--user present)"
fi
if has_line "$SYSCTL_LOG" "show -p Result --value hybrid-ai-deploy@${SHA}.service"; then
  ok "read back the unit's Result"
else
  bad "did not read back the unit Result"
fi

echo "== refusals (exit 2, nothing run) =="
refuse_cases=(
  "extra args|deploy ${SHA} extra"
  "wrong verb|restart ${SHA}"
  "semicolon metacharacter|deploy ${SHA}; rm -rf /"
  "ampersand metacharacter|deploy ${SHA} && id"
  "command substitution|deploy \$(id)"
  "uppercase sha|deploy 0123456789ABCDEF0123456789ABCDEF01234567"
  "short sha|deploy 0123456789abcdef"
  "empty command|"
  "verb only|deploy"
  "trailing space|deploy ${SHA} "
)
for case in "${refuse_cases[@]}"; do
  name="${case%%|*}"; cmd="${case#*|}"
  rc="$(run "$cmd")"
  if [[ "$rc" != "2" ]]; then
    bad "'${name}' exited $rc (want 2)"
    sed 's/^/      /' "$WORKDIR/out" >&2 || true
    continue
  fi
  if [[ -s "$SYSCTL_LOG" ]]; then
    bad "'${name}' refused but systemctl was still invoked"
  else
    ok "'${name}' refused with exit 2 and nothing run"
  fi
done

echo "== unit failure is non-zero =="
# A failing start.
rc="$(run "deploy $SHA" env SYSCTL_START_RC=1)"
if [[ "$rc" != "0" ]]; then
  ok "a failing start gives a non-zero exit ($rc)"
else
  bad "a failing start still exited 0"
fi
# A start that "succeeds" but whose Result is not success.
rc="$(run "deploy $SHA" env SYSCTL_RESULT=failed)"
if [[ "$rc" == "3" ]]; then
  ok "a unit Result of 'failed' exits 3"
else
  bad "a failed unit Result exited $rc (want 3)"
fi

echo "== run log is printed =="
mkdir -p "${LOGDIR}/deploy"
printf 'hello-from-the-run-log\n' > "${LOGDIR}/deploy/${SHA}.log"
rc="$(run "deploy $SHA")"
if [[ "$rc" == "0" ]] && has_line "$WORKDIR/out" "hello-from-the-run-log"; then
  ok "printed the run log from \$HYBRID_AI_LOG_DIR/deploy/<sha>.log"
else
  bad "did not print the run log"
  sed 's/^/      /' "$WORKDIR/out" >&2 || true
fi

echo "== static checks =="
# The polkit rule must contain the exact user, action id, verb and unit regex.
for needle in \
  'subject.user == "hybrid-ai-deploy"' \
  'org.freedesktop.systemd1.manage-units' \
  '"start"' \
  '/^hybrid-ai-deploy@[0-9a-f]{40}\.service$/'; do
  if has_line "$POLKIT_FILE" "$needle"; then
    ok "polkit rule contains: ${needle}"
  else
    bad "polkit rule is missing: ${needle}"
  fi
done
if has_line "$POLKIT_FILE" 'polkit.Result.YES'; then
  ok "polkit rule returns polkit.Result.YES on accept"
else
  bad "polkit rule never returns polkit.Result.YES"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
