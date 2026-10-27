#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/test-doctor-backup-counts.sh
# PURPOSE (plain English):
#   Proves doctor.sh's backup-failure count by RUNNING doctor.sh against a
#   synthetic backup log -- it does not grep the text of doctor.sh.
#
#   The defect: one failed backup RUN writes TWO event=backup_failed lines
#   (backup.sh's die() logs the event, then the ERR trap calls die again), but
#   doctor.sh counted LINES, so 58 lines reported "58 backup failure(s)" for 29
#   real failures. It must count DISTINCT ts= values -- runs -- since the last
#   event=backup_success, which still resets the count.
#
#   Fully OFFLINE. No Docker, no network, no root. The host commands doctor.sh
#   probes are stubbed on PATH, so the only thing that moves the count is the
#   fixture log.
#
#   Proven here:
#     (1) three failed runs (six lines, three distinct ts=) -> the warn says
#         "3 backup failure(s)", NOT 6; exactly one extra warning, no new
#         failures, exit 1 and NEVER 2;
#     (2) the count resets at the last event=backup_success: two runs before it
#         and one after -> "1 backup failure(s)";
#     (3) a clean log (one success) -> no failure warning at all;
#     (4) event=check_failed lines are counted the same way (distinct ts=) and
#         share the warning.
#   Case (1) fails against a doctor.sh that counts lines (it would say 6).
#
# USAGE:
#   bash scripts/test-doctor-backup-counts.sh [path-to-doctor.sh]
#
#   The path defaults to doctor.sh at the repository root, resolved from this
#   script's own location so the harness runs from anywhere. Point it at a copy
#   of the base doctor.sh to prove the harness FAILS without the fix:
#     git show origin/main:doctor.sh > /tmp/doctor-base.sh
#     bash scripts/test-doctor-backup-counts.sh /tmp/doctor-base.sh
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

for t in mktemp stat date git bash timeout sort wc; do
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
CRED="$WORK/cred"
mkdir -p "$BIN" "$APPD/scripts/lib" "$CRED" "$WORK/home" "$WORK/ws" "$WORK/ohstate"

# --- PATH stubs -------------------------------------------------------------
# One dispatcher, linked under every name doctor.sh probes. Each branch pins a
# fixed answer so an unrelated check can never flip between runs and move the
# exit code or the summary counts the comparisons rely on.
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

# --- scratch app ------------------------------------------------------------
cp "$REPO_ROOT/scripts/lib/hybrid-ai-env.sh" "$APPD/scripts/lib/"
cp "$DOCTOR" "$APPD/doctor.sh"
chmod +x "$APPD/doctor.sh"

# Credentials: doctor.sh only reaches the failure count when it sees the pair.
printf 'ACCOUNT_ID=fixture\n' > "$CRED/r2.env"
printf 'fixture\n' > "$CRED/repo-password"
chmod 600 "$CRED/r2.env" "$CRED/repo-password"

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

LOG_THREE="$WORK/three.log"
LOG_RESET="$WORK/reset.log"
LOG_CLEAN="$WORK/clean.log"
LOG_CHECK="$WORK/check.log"

TS_A="$(date -u -d '5 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
TS_B="$(date -u -d '4 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
TS_C="$(date -u -d '3 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
TS_OK="$(date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%SZ)"

# (1) three failed runs, each writing its pair of lines: six lines, three runs.
{
  for ts in "$TS_A" "$TS_B" "$TS_C"; do
    printf 'EVENT ts=%s event=backup_failed detail=stub\n' "$ts"
    printf 'EVENT ts=%s event=backup_failed detail=stub\n' "$ts"
  done
} > "$LOG_THREE"

# (2) two runs before the last success, one after it.
{
  printf 'EVENT ts=%s event=backup_failed detail=stub\n' "$TS_A"
  printf 'EVENT ts=%s event=backup_failed detail=stub\n' "$TS_A"
  printf 'EVENT ts=%s event=backup_success detail=stub\n' "$TS_OK"
  printf 'EVENT ts=%s event=backup_failed detail=stub\n' "$TS_B"
  printf 'EVENT ts=%s event=backup_failed detail=stub\n' "$TS_B"
} > "$LOG_RESET"

# (3) baseline: a log with no success and NO failures. The only difference from
# the three-run log is the failure count itself, so any other check that fires
# on this stub host fires in both runs.
printf 'EVENT ts=%s event=retention_applied detail=stub\n' "$TS_OK" > "$LOG_CLEAN"

# (4) two check_failed runs, two lines each.
{
  for ts in "$TS_A" "$TS_B"; do
    printf 'EVENT ts=%s event=check_failed detail=stub\n' "$ts"
    printf 'EVENT ts=%s event=check_failed detail=stub\n' "$ts"
  done
} > "$LOG_CHECK"

summary_count() { # <outfile> <passed|warning|failure>
  sed -n "s/.*[^0-9]\\([0-9][0-9]*\\) $2(s).*/\\1/p" "$1" | tail -1
}

# run_doctor <tag> <backup log>
# Sets RC, OUT, PASSED, WARNED, FAILED.
run_doctor() {
  local tag="$1" log="$2"
  OUT="$WORK/out.$tag"
  (
    cd "$APPD" || exit 1
    PATH="$BIN:$PATH" HOME="$WORK/home" SHELL=/bin/bash USER=fixture \
    REAL_JQ="$REAL_JQ" BRIDGE_IP="$BRIDGE_IP" \
    HYBRID_AI_APP_DIR="$APPD" HYBRID_AI_ENV_FILE="$APPD/.env" \
    HYBRID_AI_DATA_DIR="$APPD" HYBRID_AI_LOG_DIR="$APPD" HYBRID_AI_WORK_DIR="$APPD" \
    HYBRID_AI_HERMES_DATA_DIR="$APPD/hermes_data" \
    HYBRID_AI_BACKUP_CRED_DIR="$CRED" BACKUP_LOG="$log" \
    timeout 120 bash "$APPD/doctor.sh" --no-cloud
  ) > "$OUT" 2>&1
  RC=$?
  PASSED="$(summary_count "$OUT" passed)"; PASSED="${PASSED:-0}"
  WARNED="$(summary_count "$OUT" warning)"; WARNED="${WARNED:-0}"
  FAILED="$(summary_count "$OUT" failure)"; FAILED="${FAILED:-0}"
}

echo "== Running doctor.sh backup-count tests =="

# --- (3) baseline: a clean log, so the count is zero -----------------------
run_doctor clean "$LOG_CLEAN"
BASE_RC=$RC; BASE_WARNED=$WARNED; BASE_FAILED=$FAILED
if grep -q "backup failure(s) since the last successful backup" "$OUT"; then
  fail "clean: a baseline log with no backup_failed line produced a failure warning"
else
  pass "clean: no failure warning from a baseline with no failed run"
fi
if grep -q "No successful backup recorded yet" "$OUT"; then
  pass "clean: the baseline reaches the count site (no success recorded)"
else
  fail "clean: the baseline never reached the count site"
fi

# --- (1) three failed runs (six lines) -> three failures -------------------
run_doctor three "$LOG_THREE"
if grep -q "3 backup failure(s) since the last successful backup" "$OUT"; then
  pass "three runs: the warn counts DISTINCT runs (3), not lines (6)"
else
  fail "three runs: no warn naming 3 backup failure(s)"
fi
if grep -q "6 backup failure(s) since the last successful backup" "$OUT"; then
  fail "three runs: the warn counted lines (6) instead of runs"
else
  pass "three runs: the warn never reports the line count (6)"
fi
if [[ "$WARNED" == "$((BASE_WARNED + 1))" ]]; then
  pass "three runs: exactly one extra warning over the baseline"
else
  fail "three runs: warnings ${WARNED}, baseline ${BASE_WARNED} (want exactly one more)"
fi
if [[ "$FAILED" == "$BASE_FAILED" ]]; then
  pass "three runs: no new failures in the summary"
else
  fail "three runs: summary failures ${FAILED}, baseline ${BASE_FAILED}"
fi
if [[ "$RC" == "$BASE_RC" ]]; then
  pass "three runs: exit code ${RC} equals the baseline (the count moves nothing)"
else
  fail "three runs: exit code ${RC} differs from the baseline (${BASE_RC})"
fi

# --- (2) the last success resets the count --------------------------------
run_doctor reset "$LOG_RESET"
if grep -q "1 backup failure(s) since the last successful backup" "$OUT"; then
  pass "reset: only the runs after the last success are counted (1)"
else
  fail "reset: no warn naming 1 backup failure(s) after the last success"
fi
if grep -q "2 backup failure(s) since the last successful backup" "$OUT"; then
  fail "reset: the count was not reset by the last event=backup_success"
else
  pass "reset: the earlier runs are not carried past the last success"
fi

# --- (4) check_failed lines count the same way ----------------------------
run_doctor check "$LOG_CHECK"
if grep -q "2 backup failure(s) since the last successful backup" "$OUT"; then
  pass "check: two check_failed runs (four lines) count as 2, not 4"
else
  fail "check: no warn naming 2 backup failure(s) for the check_failed runs"
fi
if grep -q "4 backup failure(s) since the last successful backup" "$OUT"; then
  fail "check: the warn counted lines (4) instead of runs"
else
  pass "check: the warn never reports the line count (4)"
fi

echo "---"
if (( FAILURES != 0 )); then
  echo "FAILURES: ${FAILURES}" >&2
  exit 1
fi
echo "All backup-count assertions passed (${PASS})."
exit 0
