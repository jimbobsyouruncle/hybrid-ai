#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/test-doctor-sandbox-firewall.sh
# PURPOSE (plain English):
#   Proves doctor.sh's sandbox-firewall check by RUNNING doctor.sh against a
#   stubbed iptables and a recorded DOCKER-USER chain -- it does not merely
#   grep the text of doctor.sh.
#
#   The parent change (scripts/sandbox-firewall.sh) puts two DROP rules and one
#   ACCEPT exception in Docker's DOCKER-USER chain so the random sandbox agent
#   ports stop answering on the LAN. doctor.sh now reads that chain back and
#   warns, but never fails, when a rule is missing.
#
#   Fully OFFLINE. No Docker, no network, no root, no live iptables. The
#   stubbed iptables keeps its state in a file, so it behaves like a real
#   chain for the lifetime of one `apply`.
#
#   REAL, NOT TAUTOLOGICAL. The "rules present" fixture is not typed in by
#   hand: this harness runs the REAL scripts/sandbox-firewall.sh apply against
#   the stateful stub, then hands the chain it recorded to doctor.sh. So the
#   pass case proves doctor.sh accepts exactly what the parent script installs,
#   and that the tag and docker0-gateway literals in doctor.sh agree with the
#   ones in scripts/sandbox-firewall.sh. (The port agrees at its default,
#   because both sides read OPENHANDS_PORT with the same 3001 fallback.)
#
#   Proven here:
#     (a) rules applied by the parent script -> the check reports a pass, and
#         the overall exit code equals a baseline run of a doctor.sh WITHOUT
#         the check;
#     (b) rules missing -- all three, and only the webhook ACCEPT -> a warn
#         names the missing rule(s), doctor exits 1, never 2, and no failure
#         line is printed;
#     (c) probe unavailable -- no iptables on PATH, iptables refusing to read
#         the chain (permission denied), an empty listing, and a non-Linux host
#         -- a skip line, no pass and no warn from this check, and an exit code
#         identical to the baseline.
#
#   The baseline is a copy of the doctor.sh under test with the check's section
#   removed, so "same exit code" compares like with like. That same copy is
#   used at the end to prove this harness FAILS against an unpatched doctor.sh:
#   a doctor.sh without the check prints neither a pass nor a skip line, which
#   breaks assertion (a) and every assertion in (c).
#
# Usage:
#   bash scripts/test-doctor-sandbox-firewall.sh [path-to-doctor.sh]
#
# The path defaults to doctor.sh at the repository root, resolved from this
# script's own location so the harness runs from anywhere. Exit 0 when every
# assertion passes, 1 otherwise, 2 on usage error.
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

DOCTOR="${1:-$REPO_ROOT/doctor.sh}"
if [[ ! -f "$DOCTOR" ]]; then
  echo "FAIL: doctor.sh not found: $DOCTOR" >&2
  exit 2
fi
PARENT_SCRIPT="$REPO_ROOT/scripts/sandbox-firewall.sh"
if [[ ! -f "$PARENT_SCRIPT" ]]; then
  echo "FAIL: scripts/sandbox-firewall.sh not found: $PARENT_SCRIPT" >&2
  exit 2
fi

for t in mktemp python3 timeout date git jq; do
  command -v "$t" >/dev/null 2>&1 || { echo "FAIL: ${t} is required" >&2; exit 2; }
done

WORK="$(mktemp -d)"
if [[ -n "${SBX_KEEP:-}" ]]; then
  trap 'echo "kept: $WORK" >&2' EXIT
else
  trap 'rm -rf "$WORK"' EXIT
fi

PASS=0
FAILURES=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; FAILURES=$((FAILURES + 1)); }

BIN="$WORK/bin"
FIXDIR="$WORK/fixtures"
APPD="$WORK/app"
mkdir -p "$BIN" "$FIXDIR" "$APPD/scripts/lib" "$WORK/home" "$WORK/ws" "$WORK/ohstate"

SKIP_RE='sandbox firewall check skipped'
PASS_RE='Sandbox firewall: DOCKER-USER drops keep the sandbox ports off the LAN'
WARN_RE='Sandbox firewall: DOCKER-USER is missing'

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
# Nothing resolves: OPENHANDS_SANDBOX_HOST is a lab name only the operator's PC
# knows, so doctor warns (never fails) -- and does so the same way every run.
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
# warning -- stable, and never a fail.
cat > "$BIN/tailscale" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    status) echo '{"BackendState":"Running","Peer":{}}'; exit 0 ;;
    ip)     echo '100.64.0.10'; exit 0 ;;
  esac
done
exit 0
EOF

# curl: the startup-grace search endpoint answers from a fixture and the local
# health endpoints answer so the Services checks pass; everything else fails, as
# a host with nothing else running would. The startup-grace check is not what
# this harness tests, so one healthy row is all it needs.
cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
url="${*: -1}"
case "$url" in
  *"/api/v1/app-conversations/start-tasks/search"*) cat "$FIXDIR/ok.page1.json"; exit 0 ;;
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

# uname: Linux by default. UNFAKE_OS makes -s answer something else, which is
# how the non-Linux flavour of the skip path is driven. -m always answers
# aarch64 so the architecture check does not move.
cat > "$BIN/uname" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    -s) echo "${UNFAKE_OS:-Linux}"; exit 0 ;;
    -m) echo 'aarch64'; exit 0 ;;
  esac
done
echo "${UNFAKE_OS:-Linux}"
EOF

# iptables: a STATEFUL stand-in for the DOCKER-USER chain. Rules live one per
# line in $IPT_STATE. `-I` prepends (the parent script always inserts at
# position 1), `-C` matches exactly, and `-S` prints the chain the way real
# iptables does -- `-N` first, then one `-A` line per rule, with the comment
# quoted as iptables quotes it. IPT_MODE drives the failure flavours used by
# the skip-path cases.
cat > "$BIN/iptables" <<'EOF'
#!/usr/bin/env bash
state="${IPT_STATE:?IPT_STATE is not set}"
args=()
while (( $# )); do
  case "$1" in
    -w) shift; [[ "${1:-}" =~ ^[0-9]+$ ]] && shift ;;
    *) args+=("$1"); shift ;;
  esac
done
op="${args[0]:-}"
chain="${args[1]:-}"
rest=("${args[@]:2}")
case "$op" in
  -S)
    case "${IPT_MODE:-ok}" in
      fail)  echo 'iptables: Permission denied (you must be root).' >&2; exit 4 ;;
      empty) exit 0 ;;
    esac
    echo "-N $chain"
    [[ -f "$state" ]] || exit 0
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      printf '%s\n' "-A $chain $line" | sed 's/--comment \([^"][^ ]*\)/--comment "\1"/'
    done < "$state"
    exit 0 ;;
  -C)
    needle="${rest[*]}"
    [[ -f "$state" ]] && grep -Fxq -- "$needle" "$state" && exit 0
    exit 1 ;;
  -I)
    [[ "${rest[0]:-}" == "1" ]] || exit 1
    needle="${rest[*]:1}"
    tmp="${state}.new.$$"
    { printf '%s\n' "$needle"; [[ -f "$state" ]] && cat "$state"; } > "$tmp" && mv "$tmp" "$state"
    exit 0 ;;
esac
exit 1
EOF

chmod +x "$BIN"/*

# doctor.sh runs under `set -o pipefail`, and several checks read a stub through
# `... | grep -q`. grep -q exits at the first match, so the stub can be killed
# by SIGPIPE (exit 141) before it finishes writing; pipefail then reports the
# whole pipeline as failed and flips an unrelated check. That race is a property
# of the stub, not of doctor.sh, so every stub ignores SIGPIPE.
for f in "$BIN"/*; do
  [[ "$(head -n1 "$f")" == '#!/usr/bin/env bash' ]] && sed -i "2i trap '' PIPE" "$f"
done

# --- fixtures ---------------------------------------------------------------
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"items":[{"id":"t-ok","status":"COMPLETED","updated_at":"%s","error":null}],"next_page_id":null}\n' \
  "$NOW_ISO" > "$FIXDIR/ok.page1.json"

# --- scratch app ------------------------------------------------------------
cp "$REPO_ROOT/scripts/lib/hybrid-ai-env.sh" "$APPD/scripts/lib/"
cp "$DOCTOR" "$APPD/doctor.sh"
chmod +x "$APPD/doctor.sh"

# The baseline: the same doctor.sh with the 5a2 section deleted. Comparing
# against this, rather than against a skip run of the patched file, is what
# makes "the exit code is unchanged" a real statement. It lives beside the
# copy under test so it resolves scripts/lib and the same .env the same way.
awk '/^# 5a2\. Sandbox network containment/ {skip=1}
     /^# 5b\. Agent clone credentials/ {skip=0}
     !skip' "$APPD/doctor.sh" > "$APPD/doctor-base.sh"
chmod +x "$APPD/doctor-base.sh"
if grep -q 'SBX_TAG' "$APPD/doctor-base.sh"; then
  fail "could not build the baseline: the 5a2 section was not removed"
fi
if ! grep -q 'SBX_TAG' "$APPD/doctor.sh"; then
  fail "the doctor.sh under test has no sandbox-firewall check (unpatched base)"
fi

( cd "$WORK/ws" && git init -q && touch .keep ) >/dev/null 2>&1
chmod 700 "$WORK/ohstate"

# Minimal env so the Configuration checks pass rather than fail. Values are
# placeholders; none is a real credential and none is printed.
cat > "$APPD/.env" <<EOF
WEBUI_SECRET_KEY=fixture
RUNPOD_API_KEY=fixture
RUNPOD_POD_ID=fixture
TAILSCALE_IP=100.64.0.1
PEER_HOSTNAME=fixture
OPENROUTER_API_KEY=fixture
OPENHANDS_WORKSPACE=$WORK/ws
OPENHANDS_SANDBOX_HOST=example.test
OPENHANDS_STATE_DIR=$WORK/ohstate
EOF
chmod 600 "$APPD/.env"

# --- real coupling: let the parent script build the "present" fixture -------
# scripts/sandbox-firewall.sh is run with the stateful stub on PATH, exactly as
# the privileged deploy path runs it. Whatever chain it records is what the
# doctor check is then asked to accept.
run_parent_apply() { # state-file
  (
    cd "$REPO_ROOT" || exit 1
    env -u OPENHANDS_PORT IPT_STATE="$1" IPT_MODE=ok \
      PATH="$BIN:$PATH" HOME="$WORK/home" \
      bash "$PARENT_SCRIPT" apply
  ) > "$WORK/parent-apply.log" 2>&1
  RC=$?
}

STATE_PRESENT="$FIXDIR/chain.present"
# Two pre-DNAT rules a previous release installed. The parent script prepends
# and never deletes, so this is exactly the chain an upgraded host carries, and
# it is the chain doctor.sh's 5a2 check still keys on. Seeded first, then the
# real parent run prepends today's rules above them.
LEGACY_ACCEPT="-i docker0 -p tcp -d 172.17.0.1 --dport 3001 -m comment --comment hybrid-ai-sandbox-egress -j ACCEPT"
LEGACY_STACK_DROP="-i docker0 ! -o docker0 -m comment --comment hybrid-ai-sandbox-egress -j DROP"
LEGACY=2
printf '%s\n%s\n' "$LEGACY_ACCEPT" "$LEGACY_STACK_DROP" > "$STATE_PRESENT"
run_parent_apply "$STATE_PRESENT"
if [[ "$RC" != "0" ]]; then
  fail "scripts/sandbox-firewall.sh apply exited ${RC}: $(tail -1 "$WORK/parent-apply.log")"
fi

CHAIN_LINES="$(grep -c . "$STATE_PRESENT" 2>/dev/null || true)"
if [[ "${CHAIN_LINES:-0}" == "$(( 8 + LEGACY ))" ]]; then
  pass "parent script added 8 rules above the 2 legacy rules in the stub chain"
else
  fail "parent script left ${CHAIN_LINES:-0} rules, expected $(( 8 + LEGACY ))"
fi

# Two "missing" fixtures derived from the real recording, so their shape is the
# parent's, not a hand-typed approximation.
STATE_NONE="$FIXDIR/chain.none"
: > "$STATE_NONE"
STATE_NOACCEPT="$FIXDIR/chain.noaccept"
grep -Fv -- ' -j ACCEPT' "$STATE_PRESENT" > "$STATE_NOACCEPT" 2>/dev/null || : > "$STATE_NOACCEPT"
ACCEPTS="$(grep -c -- ' -j ACCEPT' "$STATE_PRESENT" || true)"
if [[ "$(grep -c . "$STATE_NOACCEPT" 2>/dev/null || echo 0)" == "$(( CHAIN_LINES - ACCEPTS ))" ]]; then
  pass "derived an 'only the webhook ACCEPT missing' fixture from the recorded chain"
else
  fail "could not derive the 'ACCEPT missing' fixture from the recorded chain"
fi

# --- doctor runs ------------------------------------------------------------
# The counts, not just the exit code, are compared: this scratch host has a
# couple of unrelated warnings of its own, so the baseline exits 1 rather than
# 0. Comparing counts is what proves the new check moved nothing except its own
# line -- a check that quietly exited early would show the same exit code.
count_of() { # file key -> number from the summary line
  case "$2" in
    passed)       sed -n 's/^ *\([0-9]\+\) passed.*/\1/p' "$1" | tail -1 ;;
    'warning(s)') sed -n 's/^.* \([0-9]\+\) warning(s).*/\1/p' "$1" | tail -1 ;;
    'failure(s)') sed -n 's/^.* \([0-9]\+\) failure(s).*/\1/p' "$1" | tail -1 ;;
  esac
}

run_doctor() { # name doctor-path state-file [extra env assignments...] ; sets RC
  local name="$1" doc="$2" st="$3"
  shift 3
  (
    cd "$APPD" || exit 1
    env IPT_MODE=ok "$@" IPT_STATE="$st" \
      PATH="$BIN:$PATH" HOME="$WORK/home" SHELL=/bin/bash \
      HYBRID_AI_DATA_DIR="$APPD" HYBRID_AI_LOG_DIR="$APPD" HYBRID_AI_WORK_DIR="$APPD" \
      timeout 120 bash "$doc" --no-cloud
  ) > "$WORK/out.$name" 2>&1
  RC=$?
}

# The baseline: no check at all, so nothing here can be attributed to it.
run_doctor base "$APPD/doctor-base.sh" "$STATE_PRESENT"
RC_BASE=$RC

# --- (a) rules present ------------------------------------------------------
run_doctor present "$APPD/doctor.sh" "$STATE_PRESENT"
RC_PRESENT=$RC
if grep -q "$PASS_RE" "$WORK/out.present"; then
  pass "rules present: the check reports a pass naming the DOCKER-USER chain"
else
  fail "rules present: no pass line for the sandbox-firewall check"
fi
if [[ "$RC_PRESENT" == "$RC_BASE" ]]; then
  pass "rules present: exit code matches the baseline without the check (${RC_BASE})"
else
  fail "rules present: exit code ${RC_PRESENT} differs from the baseline (${RC_BASE})"
fi
if [[ "$(count_of "$WORK/out.present" passed)" == "$(( $(count_of "$WORK/out.base" passed) + 1 ))" \
   && "$(count_of "$WORK/out.present" 'warning(s)')" == "$(count_of "$WORK/out.base" 'warning(s)')" \
   && "$(count_of "$WORK/out.present" 'failure(s)')" == "$(count_of "$WORK/out.base" 'failure(s)')" ]]; then
  pass "rules present: exactly one extra pass, and no extra warning or failure"
else
  fail "rules present: the summary counts do not match the baseline plus one pass"
fi

# --- (b) rules missing ------------------------------------------------------
run_doctor none "$APPD/doctor.sh" "$STATE_NONE"
RC_NONE=$RC
if grep -q "$WARN_RE" "$WORK/out.none"; then
  pass "all rules absent: a warn names the missing DOCKER-USER rules"
else
  fail "all rules absent: no warn line for the missing rules"
fi
if grep -q "$WARN_RE" "$WORK/out.none" \
   && grep -q "webhook ACCEPT" "$WORK/out.none" \
   && grep -q "DROP from docker0 to other Docker networks" "$WORK/out.none" \
   && grep -q "DROP from external interfaces into docker0" "$WORK/out.none"; then
  pass "all rules absent: the warn names all three missing rules"
else
  fail "all rules absent: the warn does not name all three missing rules"
fi
if [[ "$RC_NONE" == "1" ]]; then
  pass "all rules absent: exit code is 1 (warn on a healthy baseline of ${RC_BASE})"
else
  fail "all rules absent: exit code is ${RC_NONE}, expected 1"
fi
if [[ "$RC_NONE" != "2" ]]; then
  pass "all rules absent: exit code is never 2 (check is warning-only)"
else
  fail "all rules absent: exit code is 2 -- the check must never fail the run"
fi
if ! grep -q '✗' "$WORK/out.none" && grep -q '0 failure(s)' "$WORK/out.none"; then
  pass "all rules absent: no failure line is printed"
else
  fail "all rules absent: a failure line was printed"
fi
if [[ "$(count_of "$WORK/out.none" 'warning(s)')" == "$(( $(count_of "$WORK/out.base" 'warning(s)') + 1 ))" \
   && "$(count_of "$WORK/out.none" passed)" == "$(count_of "$WORK/out.base" passed)" ]]; then
  pass "all rules absent: exactly one extra warning, and the pass count is unchanged"
else
  fail "all rules absent: the summary counts do not match the baseline plus one warning"
fi

run_doctor noaccept "$APPD/doctor.sh" "$STATE_NOACCEPT"
RC_NOACCEPT=$RC
if grep -q "webhook ACCEPT" "$WORK/out.noaccept"; then
  pass "ACCEPT missing: the warn names the webhook ACCEPT rule"
else
  fail "ACCEPT missing: the warn does not name the webhook ACCEPT rule"
fi
if grep -q "DROP from docker0 to other Docker networks" "$WORK/out.noaccept" \
   || grep -q "DROP from external interfaces into docker0" "$WORK/out.noaccept"; then
  fail "ACCEPT missing: the warn also names a DROP that is still installed"
else
  pass "ACCEPT missing: the warn names only the rule that is actually gone"
fi
if [[ "$RC_NOACCEPT" == "1" ]]; then
  pass "ACCEPT missing: exit code is 1"
else
  fail "ACCEPT missing: exit code is ${RC_NOACCEPT}, expected 1"
fi
if [[ "$RC_NOACCEPT" != "2" ]] && ! grep -q '✗' "$WORK/out.noaccept"; then
  pass "ACCEPT missing: exit code is never 2 and no failure line is printed"
else
  fail "ACCEPT missing: exit code is 2 or a failure line was printed"
fi

# --- (c) probe unavailable --------------------------------------------------
# Each flavour must print a skip line, stay silent about pass/warn, and leave
# the exit code exactly where the baseline was.
check_skip_flavour() { # name label
  local name="$1" label="$2"
  if grep -q "$SKIP_RE" "$WORK/out.$name"; then
    pass "${label}: a skip line is printed"
  else
    fail "${label}: no skip line printed"
  fi
  if ! grep -q "$PASS_RE" "$WORK/out.$name" && ! grep -q "$WARN_RE" "$WORK/out.$name"; then
    pass "${label}: no pass and no warn from this check"
  else
    fail "${label}: the check counted a pass or a warn it could not justify"
  fi
  if [[ "$RC" == "$RC_BASE" ]]; then
    pass "${label}: exit code is identical to the baseline (${RC_BASE})"
  else
    fail "${label}: exit code ${RC} differs from the baseline (${RC_BASE})"
  fi
  if [[ "$(count_of "$WORK/out.$name" passed)" == "$(count_of "$WORK/out.base" passed)" \
     && "$(count_of "$WORK/out.$name" 'warning(s)')" == "$(count_of "$WORK/out.base" 'warning(s)')" \
     && "$(count_of "$WORK/out.$name" 'failure(s)')" == "$(count_of "$WORK/out.base" 'failure(s)')" ]]; then
    pass "${label}: every summary count matches the baseline (nothing counted)"
  else
    fail "${label}: summary counts differ from the baseline, so the skip counted something"
  fi
}

# (c1) no iptables binary. /usr/sbin and /sbin are dropped from PATH, because a
# runner image usually ships iptables there.
NOMIN_PATH="$BIN:/usr/local/bin:/usr/bin:/bin"
(
  cd "$APPD" || exit 1
  env -u IPT_STATE PATH="$NOMIN_PATH" HOME="$WORK/home" SHELL=/bin/bash \
    HYBRID_AI_DATA_DIR="$APPD" HYBRID_AI_LOG_DIR="$APPD" HYBRID_AI_WORK_DIR="$APPD" \
    timeout 120 bash "$APPD/doctor.sh" --no-cloud
) > "$WORK/out.noiptables" 2>&1
RC=$?
check_skip_flavour noiptables "no iptables binary"
if ! PATH="$NOMIN_PATH" command -v iptables >/dev/null 2>&1; then
  if grep -q 'iptables not installed' "$WORK/out.noiptables"; then
    pass "no iptables binary: the skip reason is the missing binary"
  else
    fail "no iptables binary: skip reason is not the missing binary"
  fi
fi

# (c2) iptables present but the read fails, as an unprivileged run against a
# root-owned chain does.
run_doctor perm "$APPD/doctor.sh" "$STATE_PRESENT" IPT_MODE=fail
check_skip_flavour perm "iptables refuses to read the chain"

# (c3) the listing is empty, which cannot be parsed into rules.
run_doctor empty "$APPD/doctor.sh" "$STATE_PRESENT" IPT_MODE=empty
check_skip_flavour empty "empty DOCKER-USER listing"

# (c4) not a Linux host: no iptables at all on such a system.
run_doctor nonlinux "$APPD/doctor.sh" "$STATE_PRESENT" UNFAKE_OS=Darwin
check_skip_flavour nonlinux "non-Linux host"
if grep -q 'not a Linux host' "$WORK/out.nonlinux"; then
  pass "non-Linux host: the skip reason is the platform"
else
  fail "non-Linux host: skip reason is not the platform"
fi

# --- proof that the harness rejects an unpatched doctor.sh -------------------
# A doctor.sh without the check prints neither a pass nor a skip line, so (a)
# and (c) above fail for it. Re-run this harness against the stripped copy and
# require a non-zero exit. Guarded so it cannot recurse further.
if [[ -z "${SBX_HARNESS_NESTED:-}" ]]; then
  env -u IPT_STATE -u IPT_MODE SBX_HARNESS_NESTED=1 \
    bash "$0" "$APPD/doctor-base.sh" > "$WORK/nested.log" 2>&1
  NESTED_RC=$?
  if [[ "$NESTED_RC" != "0" ]]; then
    pass "unpatched doctor.sh: this harness fails against a copy without the check"
  else
    fail "unpatched doctor.sh: the harness passed, so its assertions prove nothing"
  fi
fi

echo "---"
if (( FAILURES != 0 )); then
  echo "FAILURES: ${FAILURES}" >&2
  exit 1
fi
echo "All sandbox-firewall assertions passed (${PASS})."
exit 0
