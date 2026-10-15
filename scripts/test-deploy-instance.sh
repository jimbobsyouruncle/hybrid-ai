#!/usr/bin/env bash
set -Eeuo pipefail
# ---------------------------------------------------------------------------
# FILE: scripts/test-deploy-instance.sh
# PURPOSE (plain English):
#   Offline tests for scripts/deploy-instance.sh, the root-side half of the
#   headless deploy. git and deploy-remote.sh are stubbed on PATH, so no Docker,
#   no network and no root are needed. The REAL script is invoked by absolute
#   path against a scratch app directory.
#
#   The test proves every refusal has its own exit code: a bad sha (2), the lock
#   held so a second run is refused (3), a credential-bearing origin (4), a
#   non-ancestor sha (7), and a HEAD mismatch after the reset (8). It also proves
#   the accepted path execs deploy-remote.sh (its exit code propagates), that
#   the fetch uses the public https remote with hooks disabled and no credentials
#   and the SYSTEM manager only, that the run log is mode 0640, and the unit has
#   no Restart= line.
#
# USAGE:
#   bash scripts/test-deploy-instance.sh
#
# EXIT CODES:
#   0  every case passed
#   1  one or more cases failed
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
SCRIPT="${SCRIPT_DIR}/deploy-instance.sh"
UNIT_FILE="${REPO}/deploy/hybrid-ai-deploy@.service"

for f in "$SCRIPT" "$UNIT_FILE"; do
  [[ -f "$f" ]] || { echo "FATAL: cannot find $f" >&2; exit 1; }
done

WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

BIN="$WORK/bin"; mkdir -p "$BIN"
APP="$WORK/app"; mkdir -p "$APP/scripts"
LOG="$WORK/log"
LOCK="$WORK/deploy.lock"
EMPTY="$WORK/empty.env"; : > "$EMPTY"
GIT_LOG="$WORK/git.log"
DEPLOY_MARKER="$WORK/deploy-remote.marker"
export GIT_LOG DEPLOY_MARKER

PASS=0
FAIL=0
ok()  { PASS=$(( PASS + 1 )); printf 'ok   %s\n' "$*"; }
bad() { FAIL=$(( FAIL + 1 )); printf 'FAIL %s\n' "$*" >&2; }
has_line()    { grep -Fq -- "$2" "$1"; }
hasnt_regex() { ! grep -Eq -- "$2" "$1"; }

SHA="0123456789abcdef0123456789abcdef01234567"
OTHER="1111111111111111111111111111111111111111"

# --- git stub ---------------------------------------------------------------
# Records argv, then answers by the verb found in the args. Environment knobs
# let each case pick the outcome. -C/-c options are ignored.
cat > "$BIN/git" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GIT_LOG"
verb=""
for a in "$@"; do
  case "$a" in
    config|fetch|merge-base|reset|rev-parse) verb="$a"; break ;;
  esac
done
case "$verb" in
  config)     printf '%s\n' "${GIT_ORIGIN_URL-}"; exit 0 ;;
  fetch)      exit "${GIT_FETCH_RC:-0}" ;;
  merge-base) exit "${GIT_MERGEBASE_RC:-0}" ;;
  reset)      exit "${GIT_RESET_RC:-0}" ;;
  rev-parse)  printf '%s\n' "${GIT_HEAD_SHA-}"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$BIN/git"
export PATH="$BIN:$PATH"

# --- deploy-remote.sh stub --------------------------------------------------
cat > "$APP/scripts/deploy-remote.sh" <<'EOF'
#!/usr/bin/env bash
printf 'deploy-remote %s\n' "$*" >> "$DEPLOY_MARKER"
[ "${DEPLOY_REMOTE_SLEEP:-0}" -gt 0 ] && sleep "$DEPLOY_REMOTE_SLEEP"
exit "${DEPLOY_REMOTE_RC:-0}"
EOF
chmod +x "$APP/scripts/deploy-remote.sh"

# run_instance <outfile> [extra K=V...] -> echoes the exit code.
run_instance() {
  local out="$1"; shift
  local rc=0
  env PATH="$BIN:$PATH" \
      HYBRID_AI_APP_DIR="$APP" \
      HYBRID_AI_ENV_FILE="$EMPTY" \
      HYBRID_AI_LOG_DIR="$LOG" \
      HYBRID_AI_DEPLOY_LOCK_FILE="$LOCK" \
      GIT_ORIGIN_URL="${GIT_ORIGIN_URL:-https://github.com/jimbobsyouruncle/hybrid-ai.git}" \
      GIT_FETCH_RC="${GIT_FETCH_RC:-0}" \
      GIT_MERGEBASE_RC="${GIT_MERGEBASE_RC:-0}" \
      GIT_RESET_RC="${GIT_RESET_RC:-0}" \
      GIT_HEAD_SHA="${GIT_HEAD_SHA:-$SHA}" \
      DEPLOY_REMOTE_RC="${DEPLOY_REMOTE_RC:-0}" \
      DEPLOY_REMOTE_SLEEP="${DEPLOY_REMOTE_SLEEP:-0}" \
      "$@" \
      bash "$SCRIPT" "$SHA" >"$out" 2>&1 || rc=$?
  printf '%s' "$rc"
}

echo "== accepted: fetches public https, checks ancestry, resets, execs =="
: > "$GIT_LOG"; : > "$DEPLOY_MARKER"
rc="$(run_instance "$WORK/accept.out")"
if [[ "$rc" == "0" ]] && has_line "$DEPLOY_MARKER" "deploy-remote $SHA"; then
  ok "accepted commit execs deploy-remote.sh with the sha"
else
  bad "accepted commit exited $rc and deploy-remote marker = $(cat "$DEPLOY_MARKER" 2>/dev/null)"
  sed 's/^/      /' "$WORK/accept.out" >&2 || true
fi
if has_line "$GIT_LOG" "fetch --prune --no-tags https://github.com/jimbobsyouruncle/hybrid-ai.git +refs/heads/main:refs/remotes/origin/main"; then
  ok "fetched main from the public https remote"
else
  bad "did not fetch main from the public https remote"
  grep fetch "$GIT_LOG" >&2 || true
fi
for needle in "core.hooksPath=/dev/null" "credential.helper=" "http.extraHeader="; do
  if has_line "$GIT_LOG" "$needle"; then
    ok "fetch disabled ${needle}"
  else
    bad "fetch did not disable ${needle}"
  fi
done
if has_line "$GIT_LOG" "merge-base --is-ancestor $SHA origin/main"; then
  ok "checked ancestry against origin/main"
else
  bad "did not check ancestry"
fi
if has_line "$GIT_LOG" "reset --hard $SHA"; then
  ok "reset --hard to the sha"
else
  bad "did not reset to the sha"
fi

echo "== refusals (distinct exit codes) =="
# Bad sha: 2 -- run with a bad sha argument directly.
bad_rc=0
env PATH="$BIN:$PATH" HYBRID_AI_APP_DIR="$APP" HYBRID_AI_ENV_FILE="$EMPTY" \
    HYBRID_AI_LOG_DIR="$LOG" HYBRID_AI_DEPLOY_LOCK_FILE="$LOCK" \
    bash "$SCRIPT" "not-a-sha" >"$WORK/badsha.out" 2>&1 || bad_rc=$?
if [[ "$bad_rc" == "2" ]]; then
  ok "a bad sha is refused with exit 2"
else
  bad "a bad sha exited $bad_rc (want 2)"
fi

# Credential-bearing origin: 4
rc="$(GIT_ORIGIN_URL="https://user:pass@github.com/jimbobsyouruncle/hybrid-ai.git" \
      run_instance "$WORK/c_cred.out")"
if [[ "$rc" == "4" ]]; then
  ok "a credential-bearing origin is refused with exit 4"
else
  bad "a credential-bearing origin exited $rc (want 4)"
  sed 's/^/      /' "$WORK/c_cred.out" >&2 || true
fi

# Non-ancestor sha: 7
rc="$(GIT_MERGEBASE_RC=1 run_instance "$WORK/c_ancestor.out")"
if [[ "$rc" == "7" ]]; then
  ok "a non-ancestor sha is refused with exit 7"
else
  bad "a non-ancestor sha exited $rc (want 7)"
fi

# HEAD mismatch after reset: 8
rc="$(GIT_HEAD_SHA="$OTHER" run_instance "$WORK/c_head.out")"
if [[ "$rc" == "8" ]]; then
  ok "a HEAD mismatch is refused with exit 8"
else
  bad "a HEAD mismatch exited $rc (want 8)"
  sed 's/^/      /' "$WORK/c_head.out" >&2 || true
fi

# Fetch failure: 6
rc="$(GIT_FETCH_RC=1 run_instance "$WORK/c_fetch.out")"
if [[ "$rc" == "6" ]]; then
  ok "a failed fetch is refused with exit 6"
else
  bad "a failed fetch exited $rc (want 6)"
fi

echo "== lock held: a second run is refused (exit 3) =="
: > "$DEPLOY_MARKER"
DEPLOY_REMOTE_SLEEP=3 run_instance "$WORK/lock1.out" >"$WORK/lock1.rc" 2>&1 &
bg=$!
# Give the first run time to take the lock (deploy-remote.sh holds it via exec).
sleep 1
rc="$(run_instance "$WORK/lock2.out")"
wait "$bg" || true
if [[ "$rc" == "3" ]]; then
  ok "a second concurrent run is refused with exit 3"
else
  bad "a second concurrent run exited $rc (want 3)"
  sed 's/^/      /' "$WORK/lock2.out" >&2 || true
fi

echo "== run log mode 0640 =="
mode="$(stat -c '%a' "$LOG/deploy/${SHA}.log" 2>/dev/null || echo missing)"
if [[ "$mode" == "640" ]]; then
  ok "the run log is mode 0640"
else
  bad "the run log mode is '${mode}' (want 640)"
fi

echo "== static unit checks =="
check_line() { # file line desc
  if has_line "$1" "$2"; then ok "$3"; else bad "$3"; fi
}
check_line "$UNIT_FILE" 'Type=oneshot' "unit is Type=oneshot"
check_line "$UNIT_FILE" 'User=root' "unit runs as root"
check_line "$UNIT_FILE" 'ExecStart=/opt/hybrid-ai/scripts/deploy-instance.sh %i' "unit execs deploy-instance.sh %i"
check_line "$UNIT_FILE" 'WorkingDirectory=/opt/hybrid-ai' "unit WorkingDirectory is /opt/hybrid-ai"
check_line "$UNIT_FILE" 'Environment=HYBRID_AI_ENV_FILE=/etc/hybrid-ai/hybrid-ai.env' "unit sets the env file path"
check_line "$UNIT_FILE" 'TimeoutStartSec=20min' "unit TimeoutStartSec is 20min"
if hasnt_regex "$UNIT_FILE" '^Restart='; then
  ok "unit has NO Restart= line"
else
  bad "unit has a Restart= line (must never retry a deploy)"
fi

echo "== systemd-analyze verify, with both stub directions =="
# Same tolerance as scripts/test-backup-system-units.sh: skip only when EVERY
# diagnostic is the missing-host-path form for /opt/hybrid-ai; any other
# diagnostic is a failure. A template unit is reported under its INSTANTIATED
# name (e.g. hybrid-ai-deploy@test_instance.service), so the check matches the
# `... is not executable: No such file or directory` tail for a /opt/hybrid-ai
# command rather than the literal file base.
run_verify() {
  local unit="$1" out rc line hostpath_ok=1
  out="$(systemd-analyze verify "$unit" 2>&1)"
  rc=$?
  (( rc == 0 )) && return 0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    case "$line" in
      *": Command /opt/hybrid-ai/"*" is not executable: No such file or directory") ;;
      *) hostpath_ok=0 ;;
    esac
  done <<< "$out"
  if (( hostpath_ok )); then
    printf 'skip: %s (host paths not installed)\n' "$unit"
    return 0
  fi
  printf '%s\n' "$out" >&2
  return 1
}

if ! command -v systemd-analyze >/dev/null 2>&1; then
  printf 'skip: systemd-analyze not available\n'
else
  if run_verify "$UNIT_FILE"; then
    ok "real systemd-analyze verify passes on a host without /opt/hybrid-ai"
  else
    bad "real systemd-analyze verify did not pass"
  fi

  STUBDIR="$(mktemp -d)"
  cat > "${STUBDIR}/systemd-analyze" <<'STUB'
#!/usr/bin/env bash
base="$(basename -- "${@: -1}")"
printf '%s: Command /opt/hybrid-ai/scripts/deploy-instance.sh is not executable: No such file or directory\n' "$base"
exit 1
STUB
  chmod +x "${STUBDIR}/systemd-analyze"
  if PATH="${STUBDIR}:$PATH" run_verify "$UNIT_FILE" >/dev/null; then
    ok "host-path-only stub -> skip, exit 0"
  else
    bad "host-path-only stub should skip and exit 0"
  fi

  cat > "${STUBDIR}/systemd-analyze" <<'STUB'
#!/usr/bin/env bash
base="$(basename -- "${@: -1}")"
printf '%s: Command /opt/hybrid-ai/scripts/deploy-instance.sh is not executable: No such file or directory\n' "$base"
printf '%s: Unknown key %s in section [Service], ignoring.\n' "$base" 'Bogus=1'
exit 1
STUB
  chmod +x "${STUBDIR}/systemd-analyze"
  if PATH="${STUBDIR}:$PATH" run_verify "$UNIT_FILE" >/dev/null 2>&1; then
    bad "host-path + unrelated diagnostic must be a hard failure"
  else
    ok "host-path + one unrelated diagnostic -> failure, exit 1"
  fi
  rm -rf "$STUBDIR"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
