#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/test-doctor-post-deploy-log.sh
# PURPOSE (plain English):
#   Proves doctor.sh's post-deploy verification-log check by RUNNING doctor.sh
#   against fixture files -- it does not grep the text of doctor.sh.
#
#   The defect: scripts/deploy-remote.sh used to start a waiter that systemd
#   killed when the deploy unit exited, leaving a 0-byte log whose mtime matched
#   unit exit. Nothing noticed. doctor.sh now looks at the log and warns when it
#   is empty, or when it is older than the commit that is deployed.
#
#   Fully OFFLINE. No Docker, no network, no root. The host commands doctor.sh
#   probes are stubbed on PATH, so a fixed set of unrelated checks passes and
#   the only thing that moves the verdict is the log fixture.
#
#   Proven here:
#     (1) healthy fresh non-empty log -> pass, exit code as the log-absent run;
#     (2) 0-byte log                  -> warn, exit 1, never 2;
#     (3) log mtime > 600 s older than
#         the deployed HEAD's commit  -> warn, exit 1;
#     (4) absent log                  -> a skip note, base exit code;
#     (5) unreadable log / unreadable
#         git dir                     -> a skip note, exit unchanged;
#     (6) the summary never gains a failure in any of the above.
#   Cases (2) and (3) fail against a doctor.sh without the check.
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
BRIDGE_IP="${BRIDGE_IP:-0.0.0.0}"
for n in docker curl jq getfacl iptables df findmnt nvme lsblk dmesg vcgencmd \
         hostname getent uname nproc tailscale systemctl journalctl sqlite3 \
         rsync restic mountpoint ip; do
  ln -sf "$BIN/stub" "$BIN/$n"
done

# --- fixtures ---------------------------------------------------------------
cp "$REPO_ROOT/scripts/lib/hybrid-ai-env.sh" "$APPD/scripts/lib/"
cp "$DOCTOR" "$APPD/doctor.sh"
chmod +x "$APPD/doctor.sh"

# A throwaway git tree whose HEAD commit is "now". Its commit time is what the
# check compares the log's mtime against.
TREE="$WORK/tree"
mkdir -p "$TREE"
( cd "$TREE" && git init -q && git config user.email [EMAIL] \
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
LOG_FRESH="$LOGDIR/fresh.log"
LOG_EMPTY="$LOGDIR/empty.log"
LOG_STALE="$LOGDIR/stale.log"
LOG_UNREADABLE="$LOGDIR/unreadable.log"

printf 'waiting for aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa at 2026-01-01T00:00:00Z\nPASS\n' > "$LOG_FRESH"
: > "$LOG_EMPTY"
printf 'waiting for bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb at 2026-01-01T00:00:00Z\nPASS\n' > "$LOG_STALE"
printf 'waiting for cccccccccccccccccccccccccccccccccccccccc at 2026-01-01T00:00:00Z\nPASS\n' > "$LOG_UNREADABLE"
# The stale log stopped being written two hours ago; HEAD was committed now, so
# the deploy plainly happened after the last verification write.
touch -d '2 hours ago' "$LOG_STALE"
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

# --- (4) baseline: the log is absent ---------------------------------------
run_doctor absent "$LOG_ABSENT"
BASE_RC=$RC; BASE_WARNED=$WARNED; BASE_FAILED=$FAILED

if grep -q "post-deploy verification log skipped (log not present" "$OUT"; then
  pass "absent log: a skip note is printed"
else
  fail "absent log: no skip note printed"
fi
if grep -q "post-deploy verification log is current" "$OUT" \
   || grep -q "post-deploy verification log .* is empty" "$OUT" \
   || grep -q "post-deploy verification log is older" "$OUT"; then
  fail "absent log: the check reported a verdict for a log that is not there"
else
  pass "absent log: no verdict is reported"
fi

# --- (1) healthy fresh non-empty log --------------------------------------
run_doctor fresh "$LOG_FRESH"
if grep -q "post-deploy verification log is current" "$OUT"; then
  pass "fresh log: the check reports pass"
else
  fail "fresh log: no pass line for the post-deploy log check"
fi
if [[ "$RC" == "$BASE_RC" ]]; then
  pass "fresh log: exit code matches the log-absent run (${BASE_RC})"
else
  fail "fresh log: exit code ${RC} differs from the log-absent run (${BASE_RC})"
fi
if [[ "$FAILED" == "$BASE_FAILED" ]]; then
  pass "fresh log: no new failures in the summary"
else
  fail "fresh log: summary failures ${FAILED}, baseline ${BASE_FAILED}"
fi

# --- (2) 0-byte log -------------------------------------------------------
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

# --- (3) stale log --------------------------------------------------------
run_doctor stale "$LOG_STALE"
RC_STALE=$RC
if grep -q "is older than the deployed commit" "$OUT"; then
  pass "stale log: a warn says the deploy happened after the last write"
else
  fail "stale log: no warn about the log being older than the deployed commit"
fi
if [[ "$RC_STALE" != "2" && "$FAILED" == "$BASE_FAILED" ]]; then
  pass "stale log: warning-only (exit ${RC_STALE}, no new failures)"
else
  fail "stale log: exit ${RC_STALE} with ${FAILED} failures, baseline ${BASE_FAILED} -- must stay warning-only"
fi
if [[ "$WARNED" == "$(( BASE_WARNED + 1 ))" ]]; then
  pass "stale log: exactly one extra warning in the summary"
else
  fail "stale log: warnings ${WARNED}, expected $(( BASE_WARNED + 1 ))"
fi

# --- (5) unreadable log, and an unreadable git dir ------------------------
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

run_doctor notgit "$LOG_FRESH" "$NOTGIT"
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

echo "---"
if (( FAILURES != 0 )); then
  echo "FAILURES: ${FAILURES}" >&2
  exit 1
fi
echo "All post-deploy-log assertions passed (${PASS})."
exit 0

