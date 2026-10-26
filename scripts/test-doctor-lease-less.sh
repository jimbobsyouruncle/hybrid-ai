#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/test-doctor-lease-less.sh
# PURPOSE (plain English):
#   Proves doctor.sh's lease-less conversation check by RUNNING doctor.sh
#   against fixture conversation trees -- it does not grep the text of
#   doctor.sh.
#
#   The defect: a conversation directory with no owner_lease.json is refused by
#   scripts/prune-conversations.sh forever (the fail-safe keeps an absent
#   lease) and is invisible to the app. Sweeping it reports success while
#   moving nothing, and doctor.sh said nothing at all, so the state was silent.
#
#   The check counts lease-less directories at depth 1 under the conversations
#   root and warns with the count plus the command that fixes it, naming the
#   opt-in knob HYBRID_AI_PRUNE_ALLOW_LEASE_LESS and the prune unit. It is
#   WARNING-ONLY: it must never call fail(), so it can never raise the exit
#   code to 2.
#
#   Proven here:
#     (1) every directory carries a lease -> a pass line, exit code exactly the
#         baseline of the same host with no lease-less directory;
#     (2) three lease-less directories   -> a warn naming the count, exactly one
#         extra warning, no new failures, exit 1 and NEVER 2;
#     (3) conversations root absent      -> one dim skip note, no warning, exit
#         code and failure count unchanged from the clean run;
#     (4) a lease-less directory whose name is odd, a symlink and a plain file
#         at depth 1 are never counted (symlinks are not followed).
#
#   Fully OFFLINE. No Docker, no network, no root. The host commands doctor.sh
#   probes are stubbed on PATH so unrelated checks cannot move the verdict.
#
# USAGE:
#   bash scripts/test-doctor-lease-less.sh [path-to-doctor.sh]
#
#   The path defaults to doctor.sh at the repository root, resolved from this
#   script's own location so the harness runs from anywhere. Point it at a copy
#   of the base doctor.sh to prove the harness FAILS without the check:
#     git show origin/main:doctor.sh > /tmp/doctor-base.sh
#     bash scripts/test-doctor-lease-less.sh /tmp/doctor-base.sh
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

for t in mktemp stat date git bash timeout find; do
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
mkdir -p "$BIN" "$APPD/scripts/lib" "$WORK/home" "$WORK/ws" "$WORK/ohstate"

# --- PATH stubs -------------------------------------------------------------
# One dispatcher, linked under every name doctor.sh probes. Each branch pins a
# fixed answer so an unrelated check can never flip between runs and move the
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
      *"PortBindings"*)  printf '%s:3001 127.0.0.1:3001 ' "$BRIDGE_IP"; exit 0 ;;
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
  hostname) for a in "$@"; do [[ "$a" == "-I" ]] && { echo '127.0.0.1 '; exit 0; }; done; echo host ;;
  uname) for a in "$@"; do [[ "$a" == "-m" ]] && { echo aarch64; exit 0; }; done; echo Linux ;;
  nproc) echo 4 ;;
  tailscale)
    for a in "$@"; do
      case "$a" in
        status) echo '{"BackendState":"Running","Peer":{}}'; exit 0 ;;
        ip) echo '127.0.0.1'; exit 0 ;;
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
BRIDGE_IP="${BRIDGE_IP:-127.0.0.1}"
for n in docker curl jq getfacl iptables df findmnt nvme lsblk dmesg vcgencmd \
         hostname getent uname nproc tailscale systemctl journalctl sqlite3 \
         rsync restic mountpoint ip; do
  ln -sf "$BIN/stub" "$BIN/$n"
done

# --- fixture ----------------------------------------------------------------
cp "$REPO_ROOT/scripts/lib/hybrid-ai-env.sh" "$APPD/scripts/lib/"
cp "$DOCTOR" "$APPD/doctor.sh"
chmod +x "$APPD/doctor.sh"

TREE="$WORK/tree"
mkdir -p "$TREE"
( cd "$TREE" && git init -q && git config user.email fixture@example.test \
    && git config user.name test && git commit -q --allow-empty -m deployed ) >/dev/null 2>&1

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

summary_count() { # <outfile> <passed|warning|failure>
  sed -n "s/.*[^0-9]\\([0-9][0-9]*\\) $2(s).*/\\1/p" "$1" | tail -1
}

# run_doctor <tag> [workspace dir]
# Sets RC, OUT, PASSED, WARNED, FAILED.
run_doctor() {
  local tag="$1" ws="${2:-$WORK/ws}"
  OUT="$WORK/out.$tag"
  (
    cd "$APPD" || exit 1
    PATH="$BIN:$PATH" HOME="$WORK/home" SHELL=/bin/bash \
    REAL_JQ="$REAL_JQ" BRIDGE_IP="$BRIDGE_IP" \
    HYBRID_AI_APP_DIR="$APPD" HYBRID_AI_ENV_FILE="$APPD/.env" \
    HYBRID_AI_DATA_DIR="$APPD" HYBRID_AI_LOG_DIR="$APPD" HYBRID_AI_WORK_DIR="$APPD" \
    HYBRID_AI_HERMES_DATA_DIR="$APPD/hermes_data" \
    OPENHANDS_WORKSPACE="$ws" \
    timeout 120 bash "$APPD/doctor.sh" --no-cloud
  ) > "$OUT" 2>&1
  RC=$?
  PASSED="$(summary_count "$OUT" passed)"; PASSED="${PASSED:-0}"
  WARNED="$(summary_count "$OUT" warning)"; WARNED="${WARNED:-0}"
  FAILED="$(summary_count "$OUT" failure)"; FAILED="${FAILED:-0}"
}

echo "== Running doctor.sh lease-less tests =="

# --- (1) clean: every directory carries a lease ----------------------------
WS_CLEAN="$WORK/ws-clean"
mkdir -p "$WS_CLEAN/conversations/conv-a" "$WS_CLEAN/conversations/conv-b"
printf '{"owner_instance_id":"fixture","generation":1,"expires_at":1}\n' \
  > "$WS_CLEAN/conversations/conv-a/owner_lease.json"
printf '{"owner_instance_id":"fixture","generation":1,"expires_at":1}\n' \
  > "$WS_CLEAN/conversations/conv-b/owner_lease.json"
run_doctor clean "$WS_CLEAN"
BASE_RC=$RC; BASE_WARNED=$WARNED; BASE_FAILED=$FAILED
CLEAN_OUT="$OUT"

if grep -q "every conversation directory carries an owner lease" "$CLEAN_OUT"; then
  pass "clean: the check passes when every directory carries a lease"
else
  fail "clean: no pass line for a lease-complete conversations root"
fi
if grep -q "lease-less conversation check skipped" "$CLEAN_OUT"; then
  fail "clean: the check reported itself skipped with a readable root"
else
  pass "clean: the check did not report itself skipped"
fi
if grep -q "have no owner_lease.json" "$CLEAN_OUT"; then
  fail "clean: the check warned with no lease-less directory present"
else
  pass "clean: no lease-less warning"
fi

# --- (2) lease-less: three directories without a lease ---------------------
WS_LL="$WORK/ws-ll"
mkdir -p "$WS_LL/conversations"
for n in orphan-1 orphan-2 orphan-3; do
  mkdir -p "$WS_LL/conversations/$n"
  printf 'payload' > "$WS_LL/conversations/$n/data.txt"
done
mkdir -p "$WS_LL/conversations/with-lease"
printf '{"owner_instance_id":"fixture","generation":1,"expires_at":1}\n' \
  > "$WS_LL/conversations/with-lease/owner_lease.json"
# Neither of these is a conversation directory: a symlink and a plain file.
ln -s "$WS_LL/conversations/orphan-1" "$WS_LL/conversations/linked"
printf 'not a directory\n' > "$WS_LL/conversations/stray-file"
run_doctor leaseless "$WS_LL"
RC_LL=$RC; WARNED_LL=$WARNED; FAILED_LL=$FAILED
LL_OUT="$OUT"

if grep -q "3 conversation director(ies) have no owner_lease.json" "$LL_OUT"; then
  pass "lease-less: the warn names the count (3), not the total directory count"
else
  fail "lease-less: no warn naming the count 3"
fi
if grep -q "HYBRID_AI_PRUNE_ALLOW_LEASE_LESS" "$LL_OUT"; then
  pass "lease-less: the remedy names the opt-in knob HYBRID_AI_PRUNE_ALLOW_LEASE_LESS"
else
  fail "lease-less: the remedy does not name HYBRID_AI_PRUNE_ALLOW_LEASE_LESS"
fi
if grep -q "systemctl start hybrid-ai-prune" "$LL_OUT"; then
  pass "lease-less: the remedy names the prune unit"
else
  fail "lease-less: the remedy does not name 'systemctl start hybrid-ai-prune'"
fi
if grep -q "prune-conversations.sh" "$LL_OUT"; then
  pass "lease-less: the remedy names the prune script"
else
  fail "lease-less: the remedy does not name the prune script"
fi
if [[ "$WARNED_LL" == "$((BASE_WARNED + 1))" ]]; then
  pass "lease-less: exactly one extra warning over the clean run"
else
  fail "lease-less: warnings ${WARNED_LL}, clean ${BASE_WARNED} (want exactly one more)"
fi
if [[ "$FAILED_LL" == "$BASE_FAILED" ]]; then
  pass "lease-less: no new failures in the summary"
else
  fail "lease-less: summary failures ${FAILED_LL}, clean ${BASE_FAILED}"
fi
if [[ "$RC_LL" != "2" ]]; then
  pass "lease-less: exit code ${RC_LL} is never 2 (warning-only check)"
else
  fail "lease-less: exit code is 2 -- the check must never call fail()"
fi
if (( BASE_RC == 0 )); then
  if [[ "$RC_LL" == "1" ]]; then
    pass "lease-less: exit code is 1 over a clean baseline of 0"
  else
    fail "lease-less: exit code ${RC_LL} is not 1 over a clean baseline of 0"
  fi
else
  if [[ "$RC_LL" == "$BASE_RC" ]]; then
    pass "lease-less: exit code matches the clean baseline (${BASE_RC})"
  else
    fail "lease-less: exit code ${RC_LL} differs from the clean baseline (${BASE_RC})"
  fi
fi
if grep -q "lease-less conversation check skipped" "$LL_OUT"; then
  fail "lease-less: the check skipped despite a readable conversations root"
else
  pass "lease-less: the check ran rather than skipping"
fi

# --- (3) unreachable: the conversations root is absent ---------------------
WS_NONE="$WORK/ws-none"
mkdir -p "$WS_NONE"
run_doctor absent "$WS_NONE"
RC_NONE=$RC; WARNED_NONE=$WARNED; FAILED_NONE=$FAILED
NONE_OUT="$OUT"

if grep -q "lease-less conversation check skipped (conversations root not present)" "$NONE_OUT"; then
  pass "absent root: a skip note names the reason"
else
  fail "absent root: no skip note naming 'conversations root not present'"
fi
if grep -q "have no owner_lease.json" "$NONE_OUT"; then
  fail "absent root: the check warned with no root"
else
  pass "absent root: no lease-less warning"
fi
if [[ "$RC_NONE" == "$BASE_RC" && "$FAILED_NONE" == "$BASE_FAILED" ]]; then
  pass "absent root: exit code and failures match the clean run"
else
  fail "absent root: exit ${RC_NONE}/${FAILED_NONE} failures, clean ${BASE_RC}/${BASE_FAILED}"
fi
if [[ "$WARNED_NONE" -le "$BASE_WARNED" ]]; then
  pass "absent root: no extra warning"
else
  fail "absent root: warnings ${WARNED_NONE}, clean ${BASE_WARNED}"
fi

# --- (4) unreadable root ----------------------------------------------------
# chmod 000 does not stop uid 0 from reading, so on a root runner this case is
# reported as skipped rather than falsely passing.
WS_UNREAD="$WORK/ws-unread"
mkdir -p "$WS_UNREAD/conversations/conv-x"
chmod 000 "$WS_UNREAD/conversations"
run_doctor unreadable "$WS_UNREAD"
if [[ ! -r "$WS_UNREAD/conversations" ]]; then
  if grep -q "lease-less conversation check skipped (conversations root not readable)" "$OUT"; then
    pass "unreadable root: a skip note names the reason"
  else
    fail "unreadable root: no skip note naming 'conversations root not readable'"
  fi
  if [[ "$RC" == "$BASE_RC" && "$FAILED" == "$BASE_FAILED" ]]; then
    pass "unreadable root: exit code and failures match the clean run"
  else
    fail "unreadable root: exit ${RC}/${FAILED} failures, clean ${BASE_RC}/${BASE_FAILED}"
  fi
else
  echo "skip: running as root, so the unreadable-root case cannot be exercised"
fi
chmod 755 "$WS_UNREAD/conversations" 2>/dev/null || true

echo "---"
if (( FAILURES != 0 )); then
  echo "FAILURES: ${FAILURES}" >&2
  exit 1
fi
echo "All lease-less assertions passed (${PASS})."
exit 0
