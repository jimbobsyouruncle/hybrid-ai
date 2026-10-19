#!/usr/bin/env bash
set -Eeuo pipefail
# ---------------------------------------------------------------------------
# FILE: scripts/test-deploy-image-gate.sh
# PURPOSE (plain English):
#   Offline tests for scripts/deploy-image-gate.sh, the deploy workflow's
#   fail-closed pre-flight gate. No root, no network and no Docker: `curl` is
#   stubbed on PATH with a fixture-driven fake, and the gate is pointed at a
#   fixture install.sh. Retry and timeout intervals are squeezed to seconds so
#   the whole harness finishes quickly.
#
#   The test proves:
#     (a) a manifest that already exists -> exit 0 on the FIRST probe;
#     (b) missing then present -> succeeds after a retry;
#     (c) never present -> times out non-zero with the gate's own message;
#     (d) a probe error and an unexpected HTTP 500 -> fail closed, no success
#         message;
#     (e) an install.sh with no pin -> non-zero (unresolvable tag);
#     and that the anonymous bearer token is never printed.
#
# USAGE:
#   bash scripts/test-deploy-image-gate.sh
#
# EXIT CODES:
#   0  every case passed
#   1  one or more cases failed
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
SCRIPT="${SCRIPT_DIR}/deploy-image-gate.sh"

# The current default agent-server image tag. The fixture install.sh below and
# the real install.sh must both resolve to this.
EXPECTED_TAG="1.37.1-python-hybrid.3"

[[ -f "$SCRIPT" ]] || { echo "FATAL: cannot find $SCRIPT" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

BIN="$WORK/bin"; mkdir -p "$BIN"

PASS=0
FAIL=0
ok()  { PASS=$(( PASS + 1 )); printf 'ok   %s\n' "$*"; }
bad() { FAIL=$(( FAIL + 1 )); printf 'FAIL %s\n' "$*" >&2; }

# --- curl stub --------------------------------------------------------------
# The token endpoint always succeeds unless FAKE_TOKEN_FAIL=1. Each manifest
# probe consumes the next line of $FAKE_STATE/codes (clamped to the last), so a
# test controls the sequence of HTTP statuses. FAKE_MANIFEST_FAIL=1 makes the
# manifest probe a transport error.
cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
set -u
url=""
out=""
wflag=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w) wflag="$2"; shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in
  *"/token?"*)
    [ "${FAKE_TOKEN_FAIL:-0}" = "1" ] && exit 22
    printf '{"token":"%s"}\n' "${FAKE_TOKEN_VALUE:-fake-token-value}"
    exit 0
    ;;
esac
[ "${FAKE_MANIFEST_FAIL:-0}" = "1" ] && exit 7
counter="$FAKE_STATE/counter"
n=0
[ -f "$counter" ] && n="$(cat "$counter")"
n=$(( n + 1 ))
printf '%s' "$n" > "$counter"
code="$(sed -n "${n}p" "$FAKE_STATE/codes")"
[ -n "$code" ] || code="$(tail -n 1 "$FAKE_STATE/codes")"
if [ -n "$wflag" ]; then
  printf '%s' "$code"
else
  [ -n "$out" ] && : > "$out"
  printf 'fake-body'
fi
exit 0
EOF
chmod +x "$BIN/curl"

# Fixture install.sh files.
GOOD_INSTALL="$WORK/install-good.sh"
sed "s|__EXPECTED_TAG__|${EXPECTED_TAG}|" > "$GOOD_INSTALL" <<'EOF'
OPENHANDS_AGENT_IMAGE_REPOSITORY=${OPENHANDS_AGENT_IMAGE_REPOSITORY:-ghcr.io/jimbobsyouruncle/openhands-agent-server-hybrid}
OPENHANDS_AGENT_IMAGE_TAG=${OPENHANDS_AGENT_IMAGE_TAG:-__EXPECTED_TAG__}
EOF
NOPIN_INSTALL="$WORK/install-nopin.sh"
cat > "$NOPIN_INSTALL" <<'EOF'
# fixture with no OPENHANDS_AGENT_IMAGE_* pins at all
EOF

STATE="$WORK/state"; mkdir -p "$STATE"
export PATH="$BIN:$PATH" FAKE_STATE="$STATE" GATE_INSTALL_SH="$GOOD_INSTALL"
export GATE_INTERVAL_SECONDS=1

probes_used() { cat "$STATE/counter" 2>/dev/null || printf '0'; }

# run_gate <outfile> -- runs the gate, capturing stdout+stderr; echoes exit code
run_gate() {
  local out="$1"; shift
  : > "$STATE/counter"
  set +e
  "$SCRIPT" "$@" > "$out" 2>&1
  local rc=$?
  set -e
  printf '%s' "$rc"
}

# --- (a) manifest exists -> exit 0 on the first probe -----------------------
printf '200\n' > "$STATE/codes"
rc="$(run_gate "$WORK/a.log")"
if [ "$rc" = "0" ] && grep -q 'HTTP 200' "$WORK/a.log" && [ "$(probes_used)" = "1" ]; then
  ok "(a) existing manifest exits 0 on the first probe"
else
  bad "(a) expected exit 0 after one probe (rc=$rc, probes=$(probes_used))"
fi

# --- (b) missing then present -> succeeds after a retry ---------------------
printf '404\n404\n200\n' > "$STATE/codes"
rc="$(run_gate "$WORK/b.log" )"
probes="$(probes_used)"
if [ "$rc" = "0" ] && [ "$probes" = "3" ] && grep -q 'HTTP 200' "$WORK/b.log"; then
  ok "(b) succeeds after retry (3 probes)"
else
  bad "(b) expected exit 0 after 3 probes (rc=$rc, probes=$probes)"
fi

# --- (c) never present -> times out non-zero with the gate's message --------
printf '404\n' > "$STATE/codes"
rc="$(GATE_TIMEOUT_SECONDS=1 run_gate "$WORK/c.log")"
if [ "$rc" != "0" ] && grep -q 'timed out' "$WORK/c.log" && ! grep -q 'Proceeding' "$WORK/c.log"; then
  ok "(c) timeout exits non-zero ($rc) with the gate's timeout message"
else
  bad "(c) expected a non-zero timeout (rc=$rc)"
fi

# --- (d1) unexpected HTTP 500 -> fail closed --------------------------------
printf '500\n' > "$STATE/codes"
rc="$(run_gate "$WORK/d1.log")"
if [ "$rc" != "0" ] && grep -q 'unexpected HTTP 500' "$WORK/d1.log" && ! grep -q 'Proceeding' "$WORK/d1.log"; then
  ok "(d1) HTTP 500 fails closed ($rc)"
else
  bad "(d1) expected a non-zero fail-closed exit on HTTP 500 (rc=$rc)"
fi

# --- (d2) probe (transport) error -> fail closed ----------------------------
printf '200\n' > "$STATE/codes"
rc="$(FAKE_MANIFEST_FAIL=1 run_gate "$WORK/d2.log")"
if [ "$rc" != "0" ] && grep -q 'probe error' "$WORK/d2.log" && ! grep -q 'Proceeding' "$WORK/d2.log"; then
  ok "(d2) transport error fails closed ($rc)"
else
  bad "(d2) expected a non-zero fail-closed exit on a probe error (rc=$rc)"
fi

# --- (e) unresolvable tag -> non-zero --------------------------------------
printf '200\n' > "$STATE/codes"
rc="$(GATE_INSTALL_SH="$NOPIN_INSTALL" run_gate "$WORK/e.log")"
if [ "$rc" != "0" ] && grep -q 'could not resolve' "$WORK/e.log"; then
  ok "(e) an install.sh with no pin exits non-zero ($rc)"
else
  bad "(e) expected a non-zero exit when the pin cannot be resolved (rc=$rc)"
fi

# --- (f) the real install.sh resolves to the current default tag ------------
# The gate reads the pin straight out of install.sh, so this asserts the real
# file's default is the hybrid.3 tag (the fixture above embeds it too). Fails
# against an install.sh still on hybrid.2.
printf '200\n' > "$STATE/codes"
rc="$(GATE_INSTALL_SH="$REPO_ROOT/install.sh" run_gate "$WORK/f.log")"
if [ "$rc" = "0" ] && grep -q ":${EXPECTED_TAG} is published" "$WORK/f.log"; then
  ok "(f) install.sh resolves the default tag ${EXPECTED_TAG}"
else
  bad "(f) expected install.sh to resolve ${EXPECTED_TAG} (rc=$rc)"
fi

# --- the anonymous token is never printed ----------------------------------
if ! grep -Rqs 'fake-token-value' "$WORK"/*.log; then
  ok "the bearer token value never appears in the gate's output"
else
  bad "the bearer token value leaked into the gate's output"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
