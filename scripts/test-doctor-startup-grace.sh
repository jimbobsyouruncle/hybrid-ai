#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/test-doctor-startup-grace.sh
# PURPOSE (plain English):
#   Proves doctor.sh's startup-grace check by RUNNING doctor.sh against stubbed
#   docker/curl/jq/getfacl and fixture JSON on disk -- it does not merely grep
#   the text of doctor.sh.
#
#   The deployed app-server (OpenHands 1.10) waits only its built-in 15s for a
#   new sandbox to answer /health; this Pi's agent-server answers at ~21s, so a
#   start that loses the race is marked terminally ERROR ("500: Sandbox entered
#   error state") and never recovers. doctor.sh now counts those in a recent
#   window and warns with the remedy (OPENHANDS_STARTUP_GRACE_SECONDS).
#
#   Fully OFFLINE. No Docker, no network, no root. doctor.sh runs against a
#   scratch app whose unrelated checks are made to pass (or stay quiet) by the
#   stubs, so the only thing that moves the exit code is the startup-grace
#   fixture.
#
#   Proven here:
#     (a) healthy fixture        -> the check reports pass;
#     (b) in-window ERROR        -> a warn names the remedy, exit 1, never 2;
#     (c) app-server unreachable -> a skip note, exit code identical to (a);
#     (d) endpoint up, no rows   -> NOT reported as a skip;
#     (e) offset-less UTC row on a non-UTC host -> still outside the window.
#   The ERROR row sits on page 2 with page 1 carrying a cursor, so (b) also
#   proves the pager is followed rather than reading page 1 alone.
#
# Usage:
#   bash scripts/test-doctor-startup-grace.sh [path-to-doctor.sh]
#
# The path defaults to doctor.sh at the repository root, resolved from this
# script's own location so the harness runs from anywhere. Point it at a copy
# of the base doctor.sh to prove the harness fails without the check.
# Exit 0 when every assertion passes, 1 otherwise, 2 on usage error.
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

DOCTOR="${1:-$REPO_ROOT/doctor.sh}"
if [[ ! -f "$DOCTOR" ]]; then
  echo "FAIL: doctor.sh not found: $DOCTOR" >&2
  exit 2
fi

for t in mktemp python3 timeout date git jq; do
  command -v "$t" >/dev/null 2>&1 || { echo "FAIL: ${t} is required" >&2; exit 2; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAILURES=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; FAILURES=$((FAILURES + 1)); }

BIN="$WORK/bin"
FIXDIR="$WORK/fixtures"
APPD="$WORK/app"
mkdir -p "$BIN" "$FIXDIR" "$APPD/scripts/lib" "$WORK/home" "$WORK/ws" "$WORK/ohstate"

# --- stubs ------------------------------------------------------------------
# docker: answers just enough that doctor's container, binding and sandbox
# checks pass, so they never move the exit code. hermes-agent is reported absent.
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
    # container_env reads one key per line from this; give it consistent wiring.
    printf '%s\n' \
      'SANDBOX_HOST_PORT=3001' \
      'SANDBOX_CONTAINER_URL_PATTERN=http://example.test:{port}' \
      'OH_PERMITTED_CORS_ORIGINS_0=http://localhost:3001' \
      'OH_PERMITTED_CORS_ORIGINS_1=http://127.0.0.1:3001'
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

# restic: only reachable in --no-cloud runs as an optional tool; keep it
# hermetic.
cat > "$BIN/restic" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF

# --- host probes -------------------------------------------------------------
# doctor.sh inspects the REAL host (disk free space, boot device, RAM, mesh DNS,
# kernel log). On a shared runner those vary between runs and can flip an
# unrelated check from warn to fail, which would move the exit code the
# comparisons below rely on. Each of these stubs pins one probe to a fixed
# answer so the ONLY thing that can move the exit code is the startup-grace
# fixture.
cat > "$BIN/df" <<'EOF'
#!/usr/bin/env bash
# Low usage, so the disk check passes whatever the runner's / is doing.
printf 'Use%%\n 41%%\n'
EOF

cat > "$BIN/findmnt" <<'EOF'
#!/usr/bin/env bash
# Booted from NVMe: the recommended case, and stable.
echo '/dev/nvme0n1p2'
EOF

cat > "$BIN/nvme" <<'EOF'
#!/usr/bin/env bash
# No endurance reading, so no extra pass/warn line.
exit 1
EOF

cat > "$BIN/lsblk" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF

cat > "$BIN/dmesg" <<'EOF'
#!/usr/bin/env bash
# No kernel-log output, so no storage-IO failure (and no permission error).
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

cat > "$BIN/getent" <<'EOF'
#!/usr/bin/env bash
# The pod's MagicDNS name resolves: this is the fallback path of the shared
# resolver. Everything else does not, because OPENHANDS_SANDBOX_HOST is a lab
# name only the operator's PC knows, so doctor warns (never fails) about it the
# same way every run.
case "${1:-}" in
  ahostsv4)
    case "${2:-}" in
      runpod-worker.example.test)
        if [[ "${TS_RESOLVE_MODE:-}" == "out" ]]; then
          echo '203.0.113.10  STREAM'
        else
          echo '100.64.0.9  STREAM'
        fi
        exit 0 ;;
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

# tailscale: connected, with no GPU pod in the tailnet. That is a pass plus a
# warning -- stable, and never a fail. `ip -4 <name>` answers for the pod
# MagicDNS name, so the doctor resolve-and-validate check passes.
# TS_RESOLVE_MODE=out answers with an address OUTSIDE the mesh range instead,
# which the doctor must fail on (exit 2).
cat > "$BIN/tailscale" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    status) echo '{"BackendState":"Running","Peer":{}}'; exit 0 ;;
    ip)
      if [[ "${TS_RESOLVE_MODE:-}" == "out" ]]; then
        echo '203.0.113.10'
      else
        echo '100.64.0.9'
      fi
      exit 0 ;;
  esac
done
exit 0
EOF

# curl: the start-tasks search endpoint is answered from fixtures and the local
# health endpoints answer so the Services checks pass; everything else fails, as
# a host with nothing else running would.
#   FIXTURE=unreachable -> the search endpoint is down
#   FIXTURE=empty       -> the search endpoint is up with no rows
#   FIXTURE=warn        -> page 1 carries a cursor, page 2 the ERROR row
cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
url="${*: -1}"
case "$url" in
  *"/api/v1/app-conversations/start-tasks/search"*)
    case "${FIXTURE:-ok}" in
      unreachable) exit 7 ;;
      empty) printf '%s' '{"items":[],"next_page_id":null}'; exit 0 ;;
      warn)
        if [[ "$url" == *"page_id="* ]]; then cat "$FIXDIR/warn.page2.json"; else cat "$FIXDIR/warn.page1.json"; fi
        exit 0 ;;
      offsetless) cat "$FIXDIR/offsetless.page1.json"; exit 0 ;;
      *) cat "$FIXDIR/ok.page1.json"; exit 0 ;;
    esac ;;
  *":11434/api/tags") printf '%s' '{"models":[{"name":"llama3.2:3b"}]}'; exit 0 ;;
  *":3000/health") exit 0 ;;
  *":3001/"*) exit 0 ;;
esac
exit 7
EOF

# jq: implements exactly the filters the check uses (presence test, page cursor,
# TSV rows) and falls through to the real jq for anything else.
cat > "$BIN/jq" <<'EOF'
#!/usr/bin/env bash
prog=""
for a in "$@"; do
  case "$a" in
    -*) continue ;;
    *) prog="$a"; break ;;
  esac
done
case "$prog" in
  *'has("items")'*)
    exec python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(4)
sys.exit(0 if isinstance(d, dict) and ("items" in d or "data" in d) else 1)' ;;
  *'@tsv'*)
    exec python3 -c '
import json, sys
d = json.load(sys.stdin)
for it in (d.get("items") or d.get("data") or []):
    st = it.get("status", "")
    ts = it.get("updated_at") or it.get("created_at") or it.get("updated_at_ns") or ""
    err = " ".join(str(it.get(k, "")) for k in ("error", "error_detail", "detail", "message") if it.get(k))
    print(f"{st}\t{ts}\t{err}")' ;;
  *'next_page_id'*)
    exec python3 -c '
import json, sys
pid = json.load(sys.stdin).get("next_page_id") or ""
if pid:
    print(pid)' ;;
  *)
    exec /usr/bin/jq "$@" ;;
esac
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

# --- fixtures ---------------------------------------------------------------
# Timestamps are "now", so rows land inside the window whatever
# STARTUP_GRACE_WINDOW_MINUTES defaults to.
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"items":[{"id":"t-ok","status":"COMPLETED","updated_at":"%s","error":null}],"next_page_id":null}\n' \
  "$NOW_ISO" > "$FIXDIR/ok.page1.json"
printf '{"items":[{"id":"t-run","status":"RUNNING","updated_at":"%s"}],"next_page_id":"p2"}\n' \
  "$NOW_ISO" > "$FIXDIR/warn.page1.json"
printf '{"items":[{"id":"t-err","status":"ERROR","updated_at":"%s","error":"Sandbox entered error state"}],"next_page_id":null}\n' \
  "$NOW_ISO" > "$FIXDIR/warn.page2.json"
# The real start-tasks/search endpoint emits OFFSET-LESS UTC (no trailing Z, no
# +/-hh:mm). Parsed as UTC this row is 60 minutes old (outside the default
# 30-minute window); parsed in America/New_York (UTC-4) `date -d` shifts it ~4
# hours into the future, so the unpatched doctor.sh counts it as recent.
OFFSETLESS_ISO="$(date -u -d '-60 minutes' +%Y-%m-%dT%H:%M:%S)"
printf '{"items":[{"id":"t-offsetless","status":"ERROR","updated_at":"%s","error":"Sandbox entered error state"}],"next_page_id":null}\n' \
  "$OFFSETLESS_ISO" > "$FIXDIR/offsetless.page1.json"

# --- scratch app ------------------------------------------------------------
cp "$REPO_ROOT/scripts/lib/hybrid-ai-env.sh" "$APPD/scripts/lib/"
# doctor.sh resolves the pod MagicDNS name through this shared lib.
cp "$REPO_ROOT/scripts/lib/tailscale-resolve.sh" "$APPD/scripts/lib/"
cp "$DOCTOR" "$APPD/doctor.sh"
chmod +x "$APPD/doctor.sh"

# A git workspace (so the isolation check passes) and a 0700 state dir.
( cd "$WORK/ws" && git init -q && touch .keep ) >/dev/null 2>&1
chmod 700 "$WORK/ohstate"

# Minimal env so the Configuration checks pass rather than fail. Values are
# placeholders; none is a real credential and none is printed.
cat > "$APPD/.env" <<EOF
WEBUI_SECRET_KEY=fixture
RUNPOD_API_KEY=fixture
RUNPOD_POD_ID=fixture
RUNPOD_HOST=runpod-worker.example.test
PEER_HOSTNAME=fixture
OPENROUTER_API_KEY=fixture
OPENHANDS_WORKSPACE=$WORK/ws
OPENHANDS_SANDBOX_HOST=example.test
OPENHANDS_STATE_DIR=$WORK/ohstate
EOF
chmod 600 "$APPD/.env"

SKIP_RE='startup-grace check skipped'

run_doctor() { # fixture [timezone] ; sets RC, writes $WORK/out.<fixture>
  local fixture="$1"
  local tz="${2:-}"
  (
    cd "$APPD" || exit 1
    [[ -n "$tz" ]] && export TZ="$tz"
    FIXTURE="$fixture" FIXDIR="$FIXDIR" \
    PATH="$BIN:$PATH" HOME="$WORK/home" SHELL=/bin/bash \
    HYBRID_AI_DATA_DIR="$APPD" HYBRID_AI_LOG_DIR="$APPD" HYBRID_AI_WORK_DIR="$APPD" \
    timeout 120 bash "$APPD/doctor.sh" --no-cloud
  ) > "$WORK/out.$fixture" 2>&1
  RC=$?
}

# --- (a) healthy fixture ----------------------------------------------------
run_doctor ok
RC_OK=$RC
if grep -q "No sandbox start marked terminally ERROR" "$WORK/out.ok"; then
  pass "healthy fixture: the startup-grace check reports pass"
else
  fail "healthy fixture: no pass line for the startup-grace check"
fi

# --- (b) in-window ERROR fixture -------------------------------------------
run_doctor warn
RC_WARN=$RC
if grep -q "Sandbox entered error state" "$WORK/out.warn" \
   && grep -q "OPENHANDS_STARTUP_GRACE_SECONDS" "$WORK/out.warn"; then
  pass "ERROR fixture: a warn names the remedy (OPENHANDS_STARTUP_GRACE_SECONDS)"
else
  fail "ERROR fixture: no startup-grace warn naming the remedy"
fi
if [[ "$RC_WARN" == "1" ]]; then
  pass "ERROR fixture: exit code is 1 (warn on a clean baseline)"
else
  fail "ERROR fixture: exit code is ${RC_WARN}, expected 1 (healthy baseline ${RC_OK})"
fi
if [[ "$RC_WARN" != "2" ]]; then
  pass "ERROR fixture: exit code is never 2 (check is warning-only)"
else
  fail "ERROR fixture: exit code is 2 -- the check must never fail the run"
fi

# --- (c) unreachable app-server fixture ------------------------------------
run_doctor unreachable
RC_UNREACHABLE=$RC
if grep -q "$SKIP_RE" "$WORK/out.unreachable"; then
  pass "unreachable fixture: a skip note is printed"
else
  fail "unreachable fixture: no skip note printed"
fi
if [[ "$RC_UNREACHABLE" == "$RC_OK" ]]; then
  pass "unreachable fixture: exit code matches the healthy run (${RC_OK})"
else
  fail "unreachable fixture: exit code ${RC_UNREACHABLE} differs from the healthy run (${RC_OK})"
fi

# --- (d) endpoint up, no rows ----------------------------------------------
run_doctor empty
if ! grep -q "$SKIP_RE" "$WORK/out.empty"; then
  pass "empty fixture: a reachable endpoint is not reported as a skip"
else
  fail "empty fixture: a reachable endpoint was reported as a skip"
fi

# --- (e) offset-less UTC timestamp on a non-UTC host -----------------------
# The endpoint's naive timestamp is UTC; the harness forces a non-UTC TZ so a
# plain `date -d` would misread it as local time and inflate the count.
run_doctor offsetless America/New_York
RC_OFFSETLESS=$RC
if grep -q "No sandbox start marked terminally ERROR" "$WORK/out.offsetless"; then
  pass "offset-less fixture: the startup-grace check reports pass"
else
  fail "offset-less fixture: no pass line for the startup-grace check"
fi
if ! grep -q "Sandbox entered error state" "$WORK/out.offsetless"; then
  pass "offset-less fixture: no inflated warn count for an out-of-window row"
else
  fail "offset-less fixture: a stale row was counted as recent (warn printed)"
fi
if [[ "$RC_OFFSETLESS" == "$RC_OK" ]]; then
  pass "offset-less fixture: exit code matches the healthy run (${RC_OK})"
else
  fail "offset-less fixture: exit code ${RC_OFFSETLESS} differs from the healthy run (${RC_OK})"
fi
if [[ "$RC_OFFSETLESS" != "2" ]]; then
  pass "offset-less fixture: exit code is never 2 (check is warning-only)"
else
  fail "offset-less fixture: exit code is 2 -- the check must never fail the run"
fi

echo "---"
if (( FAILURES != 0 )); then
  echo "FAILURES: ${FAILURES}" >&2
  exit 1
fi
echo "All startup-grace assertions passed (${PASS})."
exit 0
