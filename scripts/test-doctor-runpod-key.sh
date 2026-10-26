#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/test-doctor-runpod-key.sh
# PURPOSE (plain English):
#   Proves two doctor.sh behaviours by RUNNING doctor.sh against stubbed
#   curl/getent/tailscale/docker and fixture .env files -- it does not merely
#   grep the text of doctor.sh.
#
#   1. A GPU pod that is merely ASLEEP must not fail the deploy gate. A stopped
#      on-demand pod leaves the tailnet, so its MagicDNS name stops resolving.
#      That is the normal money-saving state: it is a warning, never a failure.
#      A name that is not shaped like a pod MagicDNS record is a configuration
#      error and still fails.
#   2. RUNPOD_API_KEY is validated with ONE read-only RunPod GraphQL query, so a
#      rotated or revoked key is caught at deploy time instead of surfacing
#      weeks later as "the pod never wakes". Only an unambiguous auth rejection
#      may fail; a timeout, a 5xx or a malformed body is a skip.
#
#   Fully OFFLINE. No Docker, no network, no root. doctor.sh runs against a
#   scratch app whose unrelated checks are made to pass (or stay quiet) by the
#   stubs, so the only thing that moves the exit code is the fixture under test.
#
#   Proven here:
#     (a) well-formed 3-label .ts.net name that does not resolve -> warn, and
#         the exit code is never 2 (the unpatched doctor.sh exits 2 here);
#     (b) bare two-label .ts.net suffix -> fail;
#     (c) single label and foreign domain -> fail;
#     (d) valid key, STOPPED pod -> pass naming the pod and desiredStatus;
#     (e) 401 from the API -> fail;
#     (e2) GraphQL auth error on HTTP 200 -> fail;
#     (f) network failure -> skip, exit code as the healthy run;
#     (g) curl absent -> skip, and the check adds nothing to the exit code.
#   The key is never printed: the harness asserts it is absent from the report
#   and absent from curl's argv, and that the request was a query, not a
#   mutation.
#
# Usage:
#   bash scripts/test-doctor-runpod-key.sh [path-to-doctor.sh]
#
# The path defaults to doctor.sh at the repository root, resolved from this
# script's own location so the harness runs from anywhere. Point it at a copy
# of the base doctor.sh to prove case (a) fails without the change.
# Exit 0 when every assertion passes, 1 on assertion failure, 2 on usage error.
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

DOCTOR="${1:-$REPO_ROOT/doctor.sh}"
if [[ ! -f "$DOCTOR" ]]; then
  echo "FAIL: doctor.sh not found: $DOCTOR" >&2
  exit 2
fi

for t in mktemp timeout date git jq; do
  command -v "$t" >/dev/null 2>&1 || { echo "FAIL: ${t} is required" >&2; exit 2; }
done

WORK="$(mktemp -d)"
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf -- "$WORK"' EXIT

PASS=0
FAILURES=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; FAILURES=$((FAILURES + 1)); }

BIN="$WORK/bin"
RECORD="$WORK/record"
APPD="$WORK/app"
mkdir -p "$BIN" "$RECORD" "$APPD/scripts/lib" "$WORK/home" "$WORK/ws" "$WORK/ohstate"

# A value that is obviously not a credential, used only to prove doctor.sh
# never echoes it. Written into the fixture .env and nowhere else.
FIXTURE_KEY='rpa_FIXTUREKEYDONOTUSE000000'
FIXTURE_POD='pod-fixture-1234'

# --- stubs ------------------------------------------------------------------
# docker: answers just enough that doctor's container, binding and sandbox
# checks pass, so they never move the exit code. hermes-agent is reported absent
# (a warning, never a failure).
cat > "$BIN/docker" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do [[ "$a" == "info" ]] && exit 0; done
tmpl=""; prev=""
for a in "$@"; do
  [[ "$prev" == "-f" ]] && tmpl="$a"
  prev="$a"
done
for a in "$@"; do [[ "$a" == "network" ]] && exit 1; done
[[ "$*" == *"hermes-agent"* ]] && exit 1
[[ "$*" == *"name=oh-agent-server"* ]] && exit 0
case "$tmpl" in
  *".State.Status"*) echo running; exit 0 ;;
  *".State.Health"*) echo none; exit 0 ;;
  *"RestartCount"*)  echo 0; exit 0 ;;
  *"PortBindings"*)  echo '172.17.0.1:3001 '; exit 0 ;;
  *"println ."*)
    printf '%s\n' \
      'AGENT_SERVER_IMAGE_REPOSITORY=ghcr.io/jimbobsyouruncle/openhands-agent-server-hybrid' \
      'AGENT_SERVER_IMAGE_TAG=1.37.1-python-hybrid.3' \
      'SANDBOX_HOST_PORT=3001' \
      'SANDBOX_CONTAINER_URL_PATTERN=http://example.test:{port}' \
      'OH_PERMITTED_CORS_ORIGINS_0=http://localhost:3001' \
      'OH_PERMITTED_CORS_ORIGINS_1=http://172.17.0.1:3001'
    exit 0 ;;
esac
exit 1
EOF

# getfacl: reports the sandbox uid's ACL present, so the workspace check passes.
cat > "$BIN/getfacl" <<'EOF'
#!/usr/bin/env bash
printf 'user:10001:rwx\ndefault:user:10001:rwx\n'
exit 0
EOF

# sleep: no-op, so nothing in doctor.sh can slow the harness down.
cat > "$BIN/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

# restic: only reachable in a run that is not --no-cloud; keep it hermetic.
cat > "$BIN/restic" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF

# --- host probes -------------------------------------------------------------
# doctor.sh inspects the REAL host (disk free space, boot device, RAM, mesh DNS,
# kernel log). On a shared runner those vary between runs and can flip an
# unrelated check from warn to fail, which would move the exit code the
# comparisons below rely on. Each of these stubs pins one probe to a fixed
# answer so the ONLY thing that can move the exit code is the fixture.
cat > "$BIN/df" <<'EOF'
#!/usr/bin/env bash
printf 'Use%%\n 41%%\n'
EOF

cat > "$BIN/findmnt" <<'EOF'
#!/usr/bin/env bash
echo '/dev/nvme0n1p2'
EOF

cat > "$BIN/nvme" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF

cat > "$BIN/lsblk" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF

cat > "$BIN/dmesg" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$BIN/vcgencmd" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF

cat > "$BIN/hostname" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    -I) echo '10.0.0.5 '; exit 0 ;;
  esac
done
echo 'hybrid-ai-test-host'
EOF

# The pod's MagicDNS name is the one the healthy fixture stores. Only that
# literal name answers: any other name is genuinely unresolvable here, which is
# what the (a)/(b)/(c) fixtures need.
cat > "$BIN/getent" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  ahostsv4)
    case "${2:-}" in
      runpod-worker.example.test) echo '100.64.0.9  STREAM'; exit 0 ;;
    esac ;;
esac
exit 2
EOF

cat > "$BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF

cat > "$BIN/journalctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$BIN/ip" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$BIN/uname" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    -m) echo 'aarch64'; exit 0 ;;
  esac
done
echo 'Linux'
EOF

cat > "$BIN/nproc" <<'EOF'
#!/usr/bin/env bash
echo 4
EOF

# Optional tools doctor warns about when absent: report them present so their
# pass/warn lines do not depend on what the runner has installed.
for t in sqlite3 rsync; do
  cat > "$BIN/$t" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
done

# tailscale: connected, with no GPU pod peer in the tailnet (a pass plus a
# stable warning, never a failure). `ip -4 <name>` answers only for the healthy
# fixture's pod name, so the shared resolver reaches getent for the other
# fixtures and correctly reports "not resolved".
cat > "$BIN/tailscale" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    status) echo '{"BackendState":"Running","Peer":{}}'; exit 0 ;;
    ip)
      case "${*: -1}" in
        runpod-worker.example.test) echo '100.64.0.9'; exit 0 ;;
      esac
      exit 1 ;;
  esac
done
exit 0
EOF

# curl: two jobs.
#   1. The RunPod GraphQL endpoint is answered per RP_MODE. Each answer writes
#      the body to the -o file and prints the HTTP code, exactly as curl does.
#      The request's payload and argv are RECORDED so the harness can prove the
#      query was a query (never a mutation) and that the key stayed out of argv.
#   2. The local endpoints answer so the Services checks pass; everything else
#      fails, as a host with nothing else running would.
cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
url="${*: -1}"
case "$url" in
  *"api.runpod.io/graphql"*)
    out=""; cfg=""
    prev=""
    for a in "$@"; do
      [[ "$prev" == "-o" ]] && out="$a"
      [[ "$prev" == "--config" ]] && cfg="$a"
      prev="$a"
    done
    printf '%s\n' "$*" > "$RECORD/argv"
    if [[ -n "$cfg" && -r "$cfg" ]] && grep -q 'Authorization: Bearer ' "$cfg"; then
      printf 'present\n' > "$RECORD/header"
    else
      printf 'absent\n' > "$RECORD/header"
    fi
    for a in "$@"; do
      if [[ "$a" == @* ]]; then cp "${a#@}" "$RECORD/query" 2>/dev/null; fi
    done
    case "${RP_MODE:-valid}" in
      valid)
        printf '%s' '{"data":{"pod":{"id":"pod-fixture-1234","desiredStatus":"STOPPED"}}}' > "$out"
        printf '200'; exit 0 ;;
      unauthorized)
        printf '%s' '{"error":"Unauthorized"}' > "$out"
        printf '401'; exit 0 ;;
      graphqlauth)
        printf '%s' '{"errors":[{"message":"Invalid API key"}]}' > "$out"
        printf '200'; exit 0 ;;
      server)
        printf '%s' 'upstream unavailable' > "$out"
        printf '502'; exit 0 ;;
      malformed)
        printf '%s' '<html>not json</html>' > "$out"
        printf '200'; exit 0 ;;
      unreachable)
        # No answer at all: curl prints no http_code and exits 7.
        exit 7 ;;
    esac
    exit 7 ;;
  *":11434/api/tags") printf '%s' '{"models":[{"name":"llama3.2:3b"}]}'; exit 0 ;;
  *":3000/health") exit 0 ;;
  *":3001/"*) exit 0 ;;
esac
exit 7
EOF

chmod +x "$BIN"/*

# doctor.sh runs under `set -o pipefail`, and several checks read a stub through
# `... | grep -q`. grep -q exits at the first match, so the stub can be killed
# by SIGPIPE (exit 141) before it finishes writing; pipefail then reports the
# whole pipeline as failed and flips an unrelated check. That race is a property
# of the stub, not of doctor.sh, so every stub ignores SIGPIPE to keep the
# harness deterministic.
for f in "$BIN"/*; do
  [[ "$(head -n1 "$f")" == '#!/usr/bin/env bash' ]] && sed -i "2i trap '' PIPE" "$f"
done

# --- scratch app ------------------------------------------------------------
cp "$REPO_ROOT/scripts/lib/hybrid-ai-env.sh" "$APPD/scripts/lib/"
# doctor.sh resolves the pod MagicDNS name through this shared lib.
cp "$REPO_ROOT/scripts/lib/tailscale-resolve.sh" "$APPD/scripts/lib/"
cp "$DOCTOR" "$APPD/doctor.sh"
chmod +x "$APPD/doctor.sh"

# A git workspace (so the isolation check passes) and a 0700 state dir.
( cd "$WORK/ws" && git init -q && touch .keep ) >/dev/null 2>&1
chmod 700 "$WORK/ohstate"

write_env() { # runpod_host
  cat > "$APPD/.env" <<EOF
WEBUI_SECRET_KEY=fixture
RUNPOD_API_KEY=${FIXTURE_KEY}
RUNPOD_POD_ID=${FIXTURE_POD}
RUNPOD_HOST=$1
PEER_HOSTNAME=fixture
OPENROUTER_API_KEY=fixture
OPENHANDS_WORKSPACE=$WORK/ws
OPENHANDS_SANDBOX_HOST=example.test
OPENHANDS_STATE_DIR=$WORK/ohstate
EOF
  chmod 600 "$APPD/.env"
}

# The name every ".ts.net" fixture uses: two labels, then the tailnet suffix.
POD_TS_NAME='runpod-worker.example-tailnet.ts.net'

SKIP_RE='RunPod API-key check skipped'
WARN_RE='the GPU pod may be asleep or not yet registered on this tailnet'
FAIL_RE='is not shaped like a pod MagicDNS name'
PASS_RE='RunPod API key accepted for pod'

run_doctor() { # fixture runpod_host rp_mode [path] ; sets RC, writes $WORK/out.<fixture>
  local fixture="$1" host="$2" mode="$3" doc="${4:-$APPD/doctor.sh}"
  write_env "$host"
  (
    cd "$APPD" || exit 1
    RP_MODE="$mode" RECORD="$RECORD" \
    PATH="${RUN_PATH:-$BIN:$PATH}" HOME="$WORK/home" SHELL=/bin/bash \
    HYBRID_AI_DATA_DIR="$APPD" HYBRID_AI_LOG_DIR="$APPD" HYBRID_AI_WORK_DIR="$APPD" \
    timeout 120 bash "$doc" --no-cloud
  ) > "$WORK/out.$fixture" 2>&1
  RC=$?
}

# --- healthy baseline -------------------------------------------------------
# The pod name resolves inside the mesh and the API accepts the key, so this run
# carries only the unrelated warnings every stubbed host has. Every comparison
# below is against it.
run_doctor healthy runpod-worker.example.test valid
RC_OK=$RC
OUT_OK="$WORK/out.healthy"

if grep -q 'RUNPOD_HOST resolves inside the Tailscale mesh' "$OUT_OK"; then
  pass "healthy fixture: the pod name resolves inside the mesh (pass line byte-identical)"
else
  fail "healthy fixture: no 'RUNPOD_HOST resolves inside the Tailscale mesh' pass line"
fi
if grep -q "RunPod API key accepted for pod ${FIXTURE_POD} (desiredStatus: STOPPED)" "$OUT_OK"; then
  pass "healthy fixture: a STOPPED pod passes and the line names the pod and desiredStatus"
else
  fail "healthy fixture: no API-key pass line naming ${FIXTURE_POD} and STOPPED"
fi
if [[ "$RC_OK" != "2" ]]; then
  pass "healthy fixture: the baseline is not a failure (exit ${RC_OK})"
else
  fail "healthy fixture: the baseline unexpectedly fails (exit 2); the other cases cannot be attributed"
fi
# The request must be a query, and the key must have travelled in the 0600
# config file rather than in argv.
if [[ -r "$RECORD/query" ]] && grep -q 'query' "$RECORD/query" \
   && ! grep -qi 'mutation' "$RECORD/query"; then
  pass "RunPod request is a read-only query (no mutation)"
else
  fail "RunPod request is not a plain query, or no payload was recorded"
fi
if [[ "$(cat "$RECORD/header" 2>/dev/null)" == "present" ]]; then
  pass "the Authorization header reached curl through the --config file"
else
  fail "the Authorization header was not present in curl's --config file"
fi
if ! grep -qF "$FIXTURE_KEY" "$RECORD/argv" 2>/dev/null \
   && ! grep -qF "$FIXTURE_KEY" "$OUT_OK"; then
  pass "the API key never appears in curl's argv or in the report"
else
  fail "the API key leaked into curl's argv or the report"
fi

# --- (a) a well-formed pod name that does not resolve -> warn, never 2 ------
# This is the sleeping pod: it left the tailnet, so MagicDNS stopped answering.
# The unpatched doctor.sh hard-fails this case with exit 2.
run_doctor unresolved "$POD_TS_NAME" valid
RC_UNRESOLVED=$RC
OUT_UNRESOLVED="$WORK/out.unresolved"
if grep -q "$WARN_RE" "$OUT_UNRESOLVED"; then
  pass "unresolved pod name: a warn says the pod may be asleep or not yet registered"
else
  fail "unresolved pod name: no warn about a sleeping/unregistered pod"
fi
if grep -q 'sudo ./install.sh --wake-runpod' "$OUT_UNRESOLVED"; then
  pass "unresolved pod name: the remedy names the manual end-to-end verification"
else
  fail "unresolved pod name: no remedy naming sudo ./install.sh --wake-runpod"
fi
if [[ "$RC_UNRESOLVED" != "2" ]]; then
  pass "unresolved pod name: the exit code is never 2 (got ${RC_UNRESOLVED})"
else
  fail "unresolved pod name: exit code is 2 -- a sleeping pod must never fail the gate"
fi
if [[ "$RC_UNRESOLVED" == "1" ]]; then
  pass "unresolved pod name: the exit code is 1 (warnings only)"
else
  fail "unresolved pod name: exit code is ${RC_UNRESOLVED}, expected 1"
fi

# --- (b) bare two-label tailnet suffix -> configuration error --------------
# `tailnet.ts.net` cannot be a pod record: there is no pod label.
run_doctor bare 'tailnet.ts.net' valid
RC_BARE=$RC
if grep -q "$FAIL_RE" "$WORK/out.bare"; then
  pass "bare tailnet suffix: a fail names the expected pod MagicDNS shape"
else
  fail "bare tailnet suffix: no fail naming the expected pod MagicDNS shape"
fi
if [[ "$RC_BARE" == "2" ]]; then
  pass "bare tailnet suffix: exit code is 2"
else
  fail "bare tailnet suffix: exit code is ${RC_BARE}, expected 2"
fi

# --- (c) single label and foreign domain -> configuration error ------------
run_doctor single 'pod' valid
RC_SINGLE=$RC
if grep -q "$FAIL_RE" "$WORK/out.single"; then
  pass "single-label name: a fail names the expected pod MagicDNS shape"
else
  fail "single-label name: no fail naming the expected pod MagicDNS shape"
fi
if [[ "$RC_SINGLE" == "2" ]]; then
  pass "single-label name: exit code is 2"
else
  fail "single-label name: exit code is ${RC_SINGLE}, expected 2"
fi

run_doctor foreign 'pod.example.com' valid
RC_FOREIGN=$RC
if grep -q "$FAIL_RE" "$WORK/out.foreign"; then
  pass "foreign domain: a fail names the expected pod MagicDNS shape"
else
  fail "foreign domain: no fail naming the expected pod MagicDNS shape"
fi
if [[ "$RC_FOREIGN" == "2" ]]; then
  pass "foreign domain: exit code is 2"
else
  fail "foreign domain: exit code is ${RC_FOREIGN}, expected 2"
fi

# --- (d) valid key already covered by the healthy baseline -----------------
if [[ "$RC_OK" != "2" ]] && grep -q "$PASS_RE" "$OUT_OK"; then
  pass "valid key: the check passes without moving the exit code off the baseline"
else
  fail "valid key: the check did not pass cleanly"
fi

# --- (e) a definitive auth rejection -> fail -------------------------------
run_doctor unauthorized runpod-worker.example.test unauthorized
RC_UNAUTH=$RC
if grep -q 'RUNPOD_API_KEY was rejected by the RunPod API' "$WORK/out.unauthorized"; then
  pass "HTTP 401: the check fails and names the rejected key"
else
  fail "HTTP 401: no failure naming RUNPOD_API_KEY"
fi
if grep -q 'Rotate the key' "$WORK/out.unauthorized"; then
  pass "HTTP 401: the remedy says to rotate the key"
else
  fail "HTTP 401: no rotate-the-key remedy"
fi
if [[ "$RC_UNAUTH" == "2" ]]; then
  pass "HTTP 401: exit code is 2"
else
  fail "HTTP 401: exit code is ${RC_UNAUTH}, expected 2"
fi
if ! grep -qF "$FIXTURE_KEY" "$WORK/out.unauthorized"; then
  pass "HTTP 401: the rejection report never echoes the key"
else
  fail "HTTP 401: the rejection report echoed the key"
fi

# --- (e2) GraphQL auth error on HTTP 200 -> fail ---------------------------
run_doctor graphqlauth runpod-worker.example.test graphqlauth
RC_GQLAUTH=$RC
if grep -q 'RUNPOD_API_KEY was rejected by the RunPod API' "$WORK/out.graphqlauth"; then
  pass "GraphQL auth error on HTTP 200: the check fails"
else
  fail "GraphQL auth error on HTTP 200: no failure reported"
fi
if [[ "$RC_GQLAUTH" == "2" ]]; then
  pass "GraphQL auth error on HTTP 200: exit code is 2"
else
  fail "GraphQL auth error on HTTP 200: exit code is ${RC_GQLAUTH}, expected 2"
fi

# --- (f) network failure and other unanswerable probes -> skip --------------
# A probe that cannot answer proves nothing, so each of these leaves the exit
# code exactly where the healthy run left it.
for mode in unreachable server malformed; do
  run_doctor "$mode" runpod-worker.example.test "$mode"
  if grep -q "$SKIP_RE" "$WORK/out.$mode"; then
    pass "${mode}: a skip note is printed"
  else
    fail "${mode}: no skip note printed"
  fi
  if [[ "$RC" == "$RC_OK" ]]; then
    pass "${mode}: exit code matches the healthy run (${RC_OK})"
  else
    fail "${mode}: exit code ${RC} differs from the healthy run (${RC_OK})"
  fi
done

# --- (g) curl absent -> skip, and the check adds nothing to the exit code ---
# Without curl, doctor's own Host and Services checks fail for their own
# reasons, so the comparison is against a copy of the same doctor.sh with the
# API-key block REMOVED: the only difference between the two runs is the new
# check. It must add no failure of its own.
BASELINE="$APPD/doctor.no-runpod.sh"
awk '
  /^  # --- RunPod API key is accepted by the control API/ { skip = 1 }
  skip && /^  unset RUNPOD_KEY RUNPOD_POD$/ { skip = 0; next }
  !skip { print }
' "$APPD/doctor.sh" > "$BASELINE"
chmod +x "$BASELINE"
# The literal text is the point: this is a grep PATTERN, not an expansion.
# shellcheck disable=SC2016
if ! grep -qF 'RUNPOD_KEY="$(env_get RUNPOD_API_KEY)"' "$BASELINE"; then
  pass "baseline built: the API-key block was removed"
else
  fail "could not build the baseline: the API-key block is still present"
fi

NOCURL_BIN="$WORK/bin-nocurl"
mkdir -p "$NOCURL_BIN"
# A PATH with no curl at all: every stub doctor.sh-neutralising tool first, then
# every real executable except curl. `command -v curl` must genuinely fail, so
# omitting the binary is the only honest way to prove the skip path.
for f in "$BIN"/*; do
  n="$(basename "$f")"
  [[ "$n" == "curl" ]] && continue
  ln -sf "$f" "$NOCURL_BIN/$n"
done
IFS=: read -r -a _path_dirs <<< "$PATH"
for d in "${_path_dirs[@]}"; do
  [[ -d "$d" ]] || continue
  for f in "$d"/*; do
    n="$(basename "$f")"
    [[ "$n" == "curl" ]] && continue
    [[ -x "$f" && ! -e "$NOCURL_BIN/$n" ]] && ln -s "$f" "$NOCURL_BIN/$n" 2>/dev/null
  done
done
unset _path_dirs d f n
command -v jq >/dev/null 2>&1 && ln -sf "$(command -v jq)" "$NOCURL_BIN/jq"

RUN_PATH="$NOCURL_BIN" run_doctor nocurl runpod-worker.example.test valid
RC_NOCURL=$RC
if grep -q "${SKIP_RE} (curl is not installed)" "$WORK/out.nocurl"; then
  pass "curl absent: a skip note says curl is not installed"
else
  fail "curl absent: no skip note naming curl"
fi
RUN_PATH="$NOCURL_BIN" run_doctor nocurl-base runpod-worker.example.test valid "$BASELINE"
RC_NOCURL_BASE=$RC
if [[ "$RC_NOCURL" == "$RC_NOCURL_BASE" ]]; then
  pass "curl absent: exit code is identical to the same doctor.sh without the check (${RC_NOCURL_BASE})"
else
  fail "curl absent: exit code ${RC_NOCURL} differs from the check-free baseline (${RC_NOCURL_BASE})"
fi
if ! grep -q "$SKIP_RE" "$WORK/out.nocurl-base"; then
  pass "curl absent: the check-free baseline prints no RunPod skip note"
else
  fail "curl absent: the check-free baseline printed a RunPod skip note"
fi

echo "---"
if (( FAILURES != 0 )); then
  echo "FAILURES: ${FAILURES}" >&2
  exit 1
fi
echo "All RunPod key assertions passed (${PASS})."
exit 0
