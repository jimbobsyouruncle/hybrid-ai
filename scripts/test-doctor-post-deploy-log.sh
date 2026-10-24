#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/test-doctor-post-deploy-log.sh
# PURPOSE (plain English):
#   Proves doctor.sh's post-deploy verification-log check by RUNNING doctor.sh
#   against fixture files -- it does not grep the text of doctor.sh.
#
#   The defect: the check used to compare the log's mtime with the deployed
#   commit's time. doctor.sh runs during a deploy, after the new tree is
#   checked out but before that deploy's verifier can have written, so the log
#   was always "older than the deployed commit" and the check warned on EVERY
#   deploy by construction. It also never read the verdict the verifier wrote.
#
#   Now it parses the log. A run's block is one `waiting for <sha> at <ts>`
#   line followed by one verdict line: `PASS`, `FAIL: <detail>` or
#   `TIMEOUT: <detail>`. The last waiting line is the run of interest and the
#   first verdict after it is its outcome. A PASS for any sha passes; FAIL and
#   TIMEOUT warn; a waiting line with no verdict warns only once it is older
#   than 65 minutes, because a deploy may simply still be verifying.
#
#   Fully OFFLINE. No Docker, no network, no root. The host commands doctor.sh
#   probes are stubbed on PATH, so a fixed set of unrelated checks passes and
#   the only thing that moves the verdict is the log fixture.
#
#   Proven here:
#     (1) PASS for a sha that is NOT the deployed HEAD, with the log's mtime
#         hours in the past   -> pass naming the short sha, baseline exit --
#         this is the case that proves the structural noise is gone;
#     (2) FAIL verdict         -> warn quoting the verdict, exit 1, never 2;
#     (3) TIMEOUT verdict      -> warn quoting the verdict;
#     (4) waiting line, no verdict, started 90 min ago
#                              -> warn (abandoned), exit 1, never 2;
#     (5) waiting line, no verdict, started now
#                              -> skip note, baseline exit, no extra warning;
#     (6) non-empty log without a parseable waiting line
#                              -> warn, never a silent pass;
#     (7) waiting line with an unparseable timestamp
#                              -> skip note, exit unchanged;
#     (8) absent log           -> skip note, base exit code;
#     (9) 0-byte log           -> warn, exit 1, never 2;
#    (10) unreadable log, unreadable git dir
#                              -> skip note, exit unchanged;
#    (11) the summary never gains a failure in any of the above.
#   Cases (1) through (7) fail against a doctor.sh that compares mtimes.
#
# USAGE:
#   bash scripts/test-doctor-post-deploy-log.sh [path-to-doctor.sh]
#
#   The path defaults to doctor.sh at the repository root, resolved from this
#   script's own location so the harness runs from anywhere. Point it at a copy
#   of the base doctor.sh to prove the harness fails without the check.
#
# EXIT CODES:
#   0  every assertion passed
#   1  one or more assertions failed
#   2  a required tool is missing, or doctor.sh was not found
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

DOCTOR="${1:-$REPO_ROOT/doctor.sh}"
if [[ ! -f "$DOCTOR" ]]; then
  echo "FAIL: doctor.sh not found: $DOCTOR" >&2
  exit 2
fi

for t in mktemp stat date git bash timeout; do
  command -v "$t" >/dev/null 2>&1 || { echo "FAIL: ${t} is required" >&2; exit 2; }
done
REAL_JQ="$(command -v jq || true)"

WORK="$(mktemp -d)"
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf -- "$WORK"' EXIT

PASS=0
FAILURES=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; FAILURES=$((FAILURES + 1)); }

BIN="$WORK/bin"
APPD="$WORK/app"
LOGDIR="$WORK/logs"
mkdir -p "$BIN" "$APPD/scripts/lib" "$LOGDIR" "$WORK/home" "$WORK/ws" "$WORK/ohstate"

# --- PATH stubs -------------------------------------------------------------
# One dispatcher, linked under every name doctor.sh probes. Each branch pins a
# fixed answer, so an unrelated check can never flip between runs and move the
# exit code the comparisons rely on.
cat > "$BIN/stub" <<'STUB'
#!/usr/bin/env bash
trap '' PIPE
me="$(basename "$0")"
case "$me" in
  docker)
    for a in "$@"; do [[ "$a" == "info" ]] && exit 0; done
    for a in "$@"; do [[ "$a" == "network" ]] && exit 1; done
    tmpl=""; prev=""
    for a in "$@"; do [[ "$prev" == "-f" ]] && tmpl="$a"; prev="$a"; done
    case "$*" in
      *"top hermes-agent"*)  echo '7 hermes gateway run'; exit 0 ;;
      *"exec hermes-agent"*) exit 1 ;;
    esac
    case "$tmpl" in
      *".Mounts"*)       echo 'false'; exit 0 ;;
      *".Config.User"*)  echo '10001'; exit 0 ;;
      *".State.Status"*) echo running; exit 0 ;;
      *".State.Health"*) echo none; exit 0 ;;
      *"RestartCount"*)  echo 0; exit 0 ;;
      *"PortBindings"*)  printf '%s:3001 [IP_ADDRESS]:3001 ' "$BRIDGE_IP"; exit 0 ;;
      *"println ."*)
        printf '%s\n' 'SANDBOX_HOST_PORT=3001' \
          'SANDBOX_CONTAINER_URL_PATTERN=http://example.test:{port}' \
          'OH_PERMITTED_CORS_ORIGINS_0=http://localhost:3001'
        exit 0 ;;
    esac
    exit 1 ;;
  curl)
    url="${*: -1}"
    case "$url" in
      *":11434/api/tags") printf '%s' '{"models":[{"name":"llama3.2:3b"}]}'; exit 0 ;;
      *":3000/health") exit 0 ;;
      *":3001/"*) exit 0 ;;
      *"/health") exit 0 ;;
    esac
    exit 7 ;;
  jq)
    prog=""
    for a in "$@"; do
      case "$a" in -*) continue ;; *) prog="$a"; break ;; esac
    done
    case "$prog" in
      *'has("items")'*|*'@tsv'*|*'next_page_id'*) exit 0 ;;
      *) exec "$REAL_JQ" "$@" ;;
    esac ;;
  getfacl) printf 'user:10001:rwx\ndefault:user:10001:rwx\n'; exit 0 ;;
  iptables) printf '%s\n' '-P INPUT ACCEPT' '-A DOCKER-USER -j RETURN'; exit 0 ;;
  df) printf 'Use%%\n 41%%\n' ;;
  findmnt) echo '/dev/nvme0n1p2' ;;
  nvme|lsblk|vcgencmd|getent) exit 1 ;;
  dmesg|ip) exit 0 ;;
  hostname) for a in "$@"; do [[ "$a" == "-I" ]] && { echo '[IP_ADDRESS] '; exit 0; }; done; echo host ;;
  uname) for a in "$@"; do [[ "$a" == "-m" ]] && { echo aarch64; exit 0; }; done; echo Linux ;;
  nproc) echo 4 ;;
  tailscale)
    for a in "$@"; do
      case "$a" in
        status) echo '{"BackendState":"Running","Peer":{}}'; exit 0 ;;
        ip) echo '[IP_ADDRESS]'; exit 0 ;;
      esac
    done
    exit 0 ;;
  systemctl|journalctl|sqlite3|rsync|restic|mountpoint) exit 1 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$BIN/stub"
# The host-side bind doctor.sh expects when it reads the port bindings. Taken
# from doctor.sh itself so the stub can never drift from the real check.
BRIDGE_IP="$(sed -n "s/.*\"\$BINDINGS\" == \*\"\([^:\"]*\):\\\${OH_PORT}\".*/\1/p" "$DOCTOR" | head -1)"
BRIDGE_IP="${BRIDGE_IP:-[IP_ADDRESS]}"
for n in docker curl jq getfacl iptables df findmnt nvme lsblk dmesg vcgencmd \
         hostname getent uname nproc tailscale systemctl journalctl sqlite3 \
         rsync restic mountpoint ip; do
  ln -sf "$BIN/stub" "$BIN/$n"
done

# --- fixtures ---------------------------------------------------------------
cp "$REPO_ROOT/scripts/lib/hybrid-ai-env.sh" "$APPD/scripts/lib/"
cp "$DOCTOR" "$APPD/doctor.sh"
chmod +x "$APPD/doctor.sh"

# A throwaway git tree. doctor.sh still probes it for git readability; nothing
# compares its commit time with the log any more.
TREE="$WORK/tree"
mkdir -p "$TREE"
( cd "$TREE" && git init -q && git config user.email fixture@example.test \
    && git config user.name test && git commit -q --allow-empty -m deployed ) >/dev/null 2>&1
NOTGIT="$WORK/notgit"
mkdir -p "$NOTGIT"

chmod 700 "$WORK/ohstate"
( cd "$WORK/ws" && git init -q && touch .keep ) >/dev/null 2>&1

# Minimal env so the Configuration checks pass rather than fail. Placeholders
# only; none is a real credential and none is printed.
cat > "$APPD/.env" <<EOF
WEBUI_SECRET_KEY=fixture
RUNPOD_API_KEY=fixture
RUNPOD_POD_ID=fixture
PEER_HOSTNAME=fixture
OPENROUTER_API_KEY=fixture
OPENHANDS_WORKSPACE=$WORK/ws
OPENHANDS_SANDBOX_HOST=example.test
OPENHANDS_STATE_DIR=$WORK/ohstate
EOF
chmod 600 "$APPD/.env"

LOG_ABSENT="$LOGDIR/absent.log"
LOG_PASS="$LOGDIR/pass.log"
LOG_EMPTY="$LOGDIR/empty.log"
LOG_FAIL="$LOGDIR/fail.log"
LOG_TIMEOUT="$LOGDIR/timeout.log"
LOG_ABANDONED="$LOGDIR/abandoned.log"
LOG_RUNNING="$LOGDIR/running.log"
LOG_GARBAGE="$LOGDIR/garbage.log"
LOG_BADTS="$LOGDIR/badts.log"
LOG_UNREADABLE="$LOGDIR/unreadable.log"

# Every sha below is a 40-hex value the throwaway tree's HEAD never has, so a
# PASS can only come from reading the log -- never from matching the deployment.
SHA_PASS="1234567890abcdef1234567890abcdef12345678"
SHA_FAIL="abcdef1234567890abcdef1234567890abcdef12"
SHA_TIMEOUT="fedcba0987654321fedcba0987654321fedcba09"
SHA_ABANDONED="0123456789abcdef0123456789abcdef01234567"
SHA_RUNNING="9999999999999999999999999999999999999999"
SHA_BADTS="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
SHA12_PASS="${SHA_PASS:0:12}"
SHA12_FAIL="${SHA_FAIL:0:12}"
SHA12_TIMEOUT="${SHA_TIMEOUT:0:12}"
SHA12_ABANDONED="${SHA_ABANDONED:0:12}"
SHA12_RUNNING="${SHA_RUNNING:0:12}"

TS_OLD="$(date -u -d '90 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
TS_NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

printf 'waiting for %s at %s\nPASS\n' "$SHA_PASS" "$TS_OLD" > "$LOG_PASS"
printf 'waiting for %s at %s\nFAIL: run 123 conclusion failure\n' "$SHA_FAIL" "$TS_NOW" > "$LOG_FAIL"
printf 'waiting for %s at %s\nTIMEOUT: no completed run for %s after 60 minutes\n' \
  "$SHA_TIMEOUT" "$TS_OLD" "$SHA_TIMEOUT" > "$LOG_TIMEOUT"
printf 'waiting for %s at %s\n' "$SHA_ABANDONED" "$TS_OLD" > "$LOG_ABANDONED"
printf 'waiting for %s at %s\n' "$SHA_RUNNING" "$TS_NOW" > "$LOG_RUNNING"
printf '%s\n' 'not a waiting line' 'still not a waiting line' > "$LOG_GARBAGE"
printf 'waiting for %s at not-a-timestamp\n' "$SHA_BADTS" > "$LOG_BADTS"
printf 'waiting for %s at %s\nPASS\n' "$SHA_PASS" "$TS_OLD" > "$LOG_UNREADABLE"
: > "$LOG_EMPTY"
# The PASS log stopped being written three hours ago while the deployed tree was
# committed a moment ago. Under the old mtime rule this warned on every deploy.
touch -d '3 hours ago' "$LOG_PASS"
chmod 000 "$LOG_UNREADABLE"

summary_count() { # <outfile> <passed|warning|failure>
  sed -n "s/.*[^0-9]\\([0-9][0-9]*\\) $2(s).*/\\1/p" "$1" | tail -1
}

# run_doctor <tag> <log path> [app dir]
# Sets RC, OUT, PASSED, WARNED, FAILED.
run_doctor() {
  local tag="$1" log="$2" appdir="${3:-$TREE}"
  OUT="$WORK/out.$tag"
  (
    cd "$APPD" || exit 1
    PATH="$BIN:$PATH" HOME="$WORK/home" SHELL=/bin/bash \
    REAL_JQ="$REAL_JQ" BRIDGE_IP="$BRIDGE_IP" \
    HYBRID_AI_APP_DIR="$appdir" HYBRID_AI_ENV_FILE="$APPD/.env" \
    HYBRID_AI_DATA_DIR="$APPD" HYBRID_AI_LOG_DIR="$APPD" HYBRID_AI_WORK_DIR="$APPD" \
    HYBRID_AI_POST_DEPLOY_VERIFY_LOG="$log" \
    HYBRID_AI_HERMES_DATA_DIR="$APPD/hermes_data" \
    timeout 120 bash "$APPD/doctor.sh" --no-cloud
  ) > "$OUT" 2>&1
  RC=$?
  PASSED="$(summary_count "$OUT" passed)"; PASSED="${PASSED:-0}"
  WARNED="$(summary_count "$OUT" warning)"; WARNED="${WARNED:-0}"
  FAILED="$(summary_count "$OUT" failure)"; FAILED="${FAILED:-0}"
}

echo "== Running doctor.sh post-deploy-log tests =="

# --- (8) baseline: the log is absent ---------------------------------------
run_doctor absent "$LOG_ABSENT"
BASE_RC=$RC; BASE_WARNED=$WARNED; BASE_FAILED=$FAILED

if grep -q "post-deploy verification log skipped (log not present" "$OUT"; then
  pass "absent log: a skip note is printed"
else
  fail "absent log: no skip note printed"
fi
if grep -q "post-deploy verification passed for" "$OUT" \
   || grep -q "post-deploy verification reported" "$OUT" \
   || grep -q "is empty: the post-deploy verifier" "$OUT" \
   || grep -q "has no parseable" "$OUT"; then
  fail "absent log: the check reported a verdict for a log that is not there"
else
  pass "absent log: no verdict is reported"
fi

# --- (1) PASS for a sha that is not the deployed HEAD ----------------------
run_doctor pass "$LOG_PASS"
RC_PASS=$RC
if grep -q "post-deploy verification passed for ${SHA12_PASS} (verdict written ${TS_OLD})" "$OUT"; then
  pass "pass verdict: the pass line names the short sha and the waiting timestamp"
else
  fail "pass verdict: no pass line naming ${SHA12_PASS} / ${TS_OLD}"
fi
if [[ "$RC_PASS" == "$BASE_RC" ]]; then
  pass "pass verdict: exit code matches the log-absent run (${BASE_RC})"
else
  fail "pass verdict: exit code ${RC_PASS} differs from the log-absent run (${BASE_RC})"
fi
if [[ "$WARNED" == "$BASE_WARNED" ]]; then
  pass "pass verdict: no extra warning despite a 3-hour-old mtime"
else
  fail "pass verdict: warnings ${WARNED}, baseline ${BASE_WARNED} -- an old mtime must not warn"
fi
if [[ "$FAILED" == "$BASE_FAILED" ]]; then
  pass "pass verdict: no new failures in the summary"
else
  fail "pass verdict: summary failures ${FAILED}, baseline ${BASE_FAILED}"
fi

# --- (2) FAIL verdict -----------------------------------------------------
run_doctor fail "$LOG_FAIL"
RC_FAIL=$RC
if grep -q "post-deploy verification reported 'FAIL: run 123 conclusion failure' for ${SHA12_FAIL}" "$OUT"; then
  pass "fail verdict: the warn quotes the verdict and the short sha"
else
  fail "fail verdict: no warn quoting the FAIL verdict for ${SHA12_FAIL}"
fi
if grep -q "journalctl -u 'hybrid-ai-post-deploy-verify-\*'" "$OUT"; then
  pass "fail verdict: the remedy names journalctl for the verifier units"
else
  fail "fail verdict: the remedy does not name journalctl -u 'hybrid-ai-post-deploy-verify-*'"
fi
if [[ "$RC_FAIL" == "1" ]]; then
  pass "fail verdict: exit code is 1"
else
  fail "fail verdict: exit code ${RC_FAIL}, expected 1 (baseline ${BASE_RC})"
fi
if [[ "$RC_FAIL" != "2" ]]; then
  pass "fail verdict: exit code is never 2 (check is warning-only)"
else
  fail "fail verdict: exit code is 2 -- the check must never fail the host"
fi
if [[ "$WARNED" == "$(( BASE_WARNED + 1 ))" ]]; then
  pass "fail verdict: exactly one extra warning in the summary"
else
  fail "fail verdict: warnings ${WARNED}, expected $(( BASE_WARNED + 1 ))"
fi
if [[ "$FAILED" == "$BASE_FAILED" ]]; then
  pass "fail verdict: no new failures in the summary"
else
  fail "fail verdict: summary failures ${FAILED}, baseline ${BASE_FAILED}"
fi

# --- (3) TIMEOUT verdict --------------------------------------------------
run_doctor timeout "$LOG_TIMEOUT"
RC_TIMEOUT=$RC
if grep -q "post-deploy verification reported 'TIMEOUT: no completed run for ${SHA_TIMEOUT} after 60 minutes' for ${SHA12_TIMEOUT}" "$OUT"; then
  pass "timeout verdict: the warn quotes the verdict and the short sha"
else
  fail "timeout verdict: no warn quoting the TIMEOUT verdict for ${SHA12_TIMEOUT}"
fi
if [[ "$RC_TIMEOUT" != "2" && "$FAILED" == "$BASE_FAILED" ]]; then
  pass "timeout verdict: warning-only (exit ${RC_TIMEOUT}, no new failures)"
else
  fail "timeout verdict: exit ${RC_TIMEOUT} with ${FAILED} failures, baseline ${BASE_RC}/${BASE_FAILED}"
fi
if [[ "$WARNED" == "$(( BASE_WARNED + 1 ))" ]]; then
  pass "timeout verdict: exactly one extra warning in the summary"
else
  fail "timeout verdict: warnings ${WARNED}, expected $(( BASE_WARNED + 1 ))"
fi

# --- (4) waiting line, no verdict, 90 minutes old -------------------------
run_doctor abandoned "$LOG_ABANDONED"
RC_ABANDONED=$RC
if grep -q "post-deploy verification for ${SHA12_ABANDONED} has no verdict and its wait started at ${TS_OLD}, more than 65 minutes ago" "$OUT"; then
  pass "abandoned wait: a warn names the short sha and the waiting timestamp"
else
  fail "abandoned wait: no warn about the abandoned verification for ${SHA12_ABANDONED}"
fi
if grep -q "journalctl -u 'hybrid-ai-post-deploy-verify-\*'" "$OUT"; then
  pass "abandoned wait: the remedy names journalctl for the verifier units"
else
  fail "abandoned wait: the remedy does not name journalctl -u 'hybrid-ai-post-deploy-verify-*'"
fi
if [[ "$RC_ABANDONED" == "1" ]]; then
  pass "abandoned wait: exit code is 1, never 2"
else
  fail "abandoned wait: exit code ${RC_ABANDONED}, expected 1 and never 2"
fi
if [[ "$WARNED" == "$(( BASE_WARNED + 1 ))" && "$FAILED" == "$BASE_FAILED" ]]; then
  pass "abandoned wait: exactly one extra warning and no new failures"
else
  fail "abandoned wait: warnings ${WARNED}/failures ${FAILED}, baseline ${BASE_WARNED}/${BASE_FAILED}"
fi

# --- (5) waiting line, no verdict, started now ----------------------------
run_doctor running "$LOG_RUNNING"
RC_RUNNING=$RC
if grep -q "post-deploy verification log skipped (verification for ${SHA12_RUNNING} still running since ${TS_NOW})" "$OUT"; then
  pass "running wait: a skip note says the verification is still running"
else
  fail "running wait: no skip note for the in-flight verification of ${SHA12_RUNNING}"
fi
if [[ "$RC_RUNNING" == "$BASE_RC" ]]; then
  pass "running wait: exit code matches the log-absent run (${BASE_RC})"
else
  fail "running wait: exit code ${RC_RUNNING} differs from the log-absent run (${BASE_RC})"
fi
if [[ "$WARNED" == "$BASE_WARNED" ]]; then
  pass "running wait: no extra warning while the verification is in flight"
else
  fail "running wait: warnings ${WARNED}, baseline ${BASE_WARNED}"
fi
if grep -q "post-deploy verification for .* has no verdict" "$OUT"; then
  fail "running wait: it wrongly reported the in-flight verification as abandoned"
else
  pass "running wait: it is not reported as abandoned"
fi

# --- (6) non-empty log without a parseable waiting line -------------------
run_doctor garbage "$LOG_GARBAGE"
RC_GARBAGE=$RC
if grep -q "has no parseable 'waiting for <sha> at <ts>' line" "$OUT"; then
  pass "no waiting line: a warn says the waiting line cannot be parsed"
else
  fail "no waiting line: no warn about the missing waiting line (silent pass?)"
fi
if grep -q "journalctl -u 'hybrid-ai-post-deploy-verify-\*'" "$OUT"; then
  pass "no waiting line: the remedy names journalctl for the verifier units"
else
  fail "no waiting line: the remedy does not name journalctl -u 'hybrid-ai-post-deploy-verify-*'"
fi
if [[ "$RC_GARBAGE" == "1" ]]; then
  pass "no waiting line: exit code is 1"
else
  fail "no waiting line: exit code ${RC_GARBAGE}, expected 1 (baseline ${BASE_RC})"
fi
if [[ "$WARNED" == "$(( BASE_WARNED + 1 ))" && "$FAILED" == "$BASE_FAILED" ]]; then
  pass "no waiting line: exactly one extra warning and no new failures"
else
  fail "no waiting line: warnings ${WARNED}/failures ${FAILED}, baseline ${BASE_WARNED}/${BASE_FAILED}"
fi

# --- (7) waiting line with an unparseable timestamp -----------------------
run_doctor badts "$LOG_BADTS"
RC_BADTS=$RC
if grep -q "post-deploy verification log skipped (unparseable verification timestamp 'not-a-timestamp')" "$OUT"; then
  pass "unparseable timestamp: a skip note quotes the raw value"
else
  fail "unparseable timestamp: no skip note quoting 'not-a-timestamp'"
fi
if [[ "$RC_BADTS" == "$BASE_RC" && "$FAILED" == "$BASE_FAILED" ]]; then
  pass "unparseable timestamp: exit code and failures match the log-absent run"
else
  fail "unparseable timestamp: exit ${RC_BADTS}/${FAILED} failures, baseline ${BASE_RC}/${BASE_FAILED}"
fi
if [[ "$WARNED" == "$BASE_WARNED" ]]; then
  pass "unparseable timestamp: no extra warning"
else
  fail "unparseable timestamp: warnings ${WARNED}, baseline ${BASE_WARNED}"
fi

# --- (9) 0-byte log -------------------------------------------------------
run_doctor empty "$LOG_EMPTY"
RC_EMPTY=$RC
if grep -q "is empty: the post-deploy verifier never wrote anything" "$OUT"; then
  pass "0-byte log: a warn says the verifier never wrote anything"
else
  fail "0-byte log: no warn about the empty log"
fi
if grep -q "journalctl -u 'hybrid-ai-post-deploy-verify-\*'" "$OUT"; then
  pass "0-byte log: the remedy names journalctl for the verifier units"
else
  fail "0-byte log: the remedy does not name journalctl -u 'hybrid-ai-post-deploy-verify-*'"
fi
if [[ "$RC_EMPTY" == "1" ]]; then
  pass "0-byte log: exit code is 1"
else
  fail "0-byte log: exit code ${RC_EMPTY}, expected 1 (baseline ${BASE_RC})"
fi
if [[ "$RC_EMPTY" != "2" ]]; then
  pass "0-byte log: exit code is never 2 (check is warning-only)"
else
  fail "0-byte log: exit code is 2 -- the check must never fail the host"
fi
if [[ "$WARNED" == "$(( BASE_WARNED + 1 ))" ]]; then
  pass "0-byte log: exactly one extra warning in the summary"
else
  fail "0-byte log: warnings ${WARNED}, expected $(( BASE_WARNED + 1 ))"
fi
if [[ "$FAILED" == "$BASE_FAILED" ]]; then
  pass "0-byte log: no new failures in the summary"
else
  fail "0-byte log: summary failures ${FAILED}, baseline ${BASE_FAILED}"
fi

# --- (10) unreadable log, and an unreadable git dir -----------------------
if [[ "$(id -u)" != "0" ]]; then
  run_doctor unreadable "$LOG_UNREADABLE"
  if grep -q "post-deploy verification log skipped (log not readable" "$OUT"; then
    pass "unreadable log: a skip note is printed"
  else
    fail "unreadable log: no skip note printed"
  fi
  if [[ "$RC" == "$BASE_RC" && "$FAILED" == "$BASE_FAILED" ]]; then
    pass "unreadable log: exit code and failures match the log-absent run"
  else
    fail "unreadable log: exit ${RC}/${FAILED} failures, baseline ${BASE_RC}/${BASE_FAILED}"
  fi
  if ! grep -q "is empty: the post-deploy verifier" "$OUT"; then
    pass "unreadable log: it is not misreported as an empty log"
  else
    fail "unreadable log: it was misreported as an empty log"
  fi
else
  # chmod 000 does not stop uid 0 from reading the file, so the git-dir case
  # below carries the "unreadable" evidence on a root runner.
  echo "skip: running as root, so the unreadable-log case is covered by the git dir case"
fi

run_doctor notgit "$LOG_PASS" "$NOTGIT"
RC_NOTGIT=$RC
if grep -q "post-deploy verification log skipped (deployed tree not readable with git" "$OUT"; then
  pass "unreadable git dir: a skip note is printed"
else
  fail "unreadable git dir: no skip note printed"
fi
if [[ "$RC_NOTGIT" == "$BASE_RC" && "$FAILED" == "$BASE_FAILED" ]]; then
  pass "unreadable git dir: exit code and failures match the log-absent run"
else
  fail "unreadable git dir: exit ${RC_NOTGIT}/${FAILED} failures, baseline ${BASE_RC}/${BASE_FAILED}"
fi
if [[ "$WARNED" == "$BASE_WARNED" ]]; then
  pass "unreadable git dir: no extra warning"
else
  fail "unreadable git dir: warnings ${WARNED}, baseline ${BASE_WARNED}"
fi

echo "---"
if (( FAILURES != 0 )); then
  echo "FAILURES: ${FAILURES}" >&2
  exit 1
fi
echo "All post-deploy-log assertions passed (${PASS})."
exit 0
