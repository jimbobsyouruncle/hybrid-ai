#!/usr/bin/env bash
set -Eeuo pipefail
# ---------------------------------------------------------------------------
# FILE: scripts/test-run-post-deploy-verify.sh
# PURPOSE (plain English):
#   Offline tests for scripts/run-post-deploy-verify.sh. They need no network,
#   no Docker and no access to /etc. curl and jq are stubbed on PATH, and the
#   deployed tree is a throwaway git checkout in a temp dir. A fixture layout
#   file is pointed at with HYBRID_AI_ENV_FILE_FALLBACK.
#
#   They prove the three-step APP_DIR resolution (environment, then layout file,
#   then /workspace) and the two tree-check verdicts (PASS on the expected SHA,
#   FAIL with the exact message on any other commit).
#
# USAGE:
#   bash scripts/test-run-post-deploy-verify.sh
#
# EXIT CODES:
#   0  every case passed
#   1  one or more cases failed
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
VERIFY_SCRIPT="$SCRIPT_DIR/run-post-deploy-verify.sh"

if [[ ! -f "$VERIFY_SCRIPT" ]]; then
  echo "FATAL: cannot find $VERIFY_SCRIPT" >&2
  exit 1
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf -- "$WORKDIR"' EXIT

BINDIR="$WORKDIR/bin"
mkdir -p "$BINDIR"

failures=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; failures=$((failures + 1)); }

# --- PATH stubs -------------------------------------------------------------
# curl: write a controlled body to the -o target and print a controlled status
# code. It never opens a socket.
cat > "$BINDIR/curl" <<'EOF'
#!/usr/bin/env bash
out=""
url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    --max-time|-A|--resolve) shift 2 ;;
    -w|-sS) shift ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
# The status API is a different endpoint from the GitHub API: a case sets
# CURL_TILE_CODE/CURL_TILE_BODY to control the Backups tile, or CURL_TILE_CODE=000
# to make the service unreachable.
if [[ "$url" == *"/status/api"* ]]; then
  [[ -n "$out" ]] && printf '%s' "${CURL_TILE_BODY:-}" > "$out"
  printf '%s' "${CURL_TILE_CODE:-200}"
  exit 0
fi
[[ -n "$out" ]] && printf '%s' "${CURL_STUB_BODY:-}" > "$out"
printf '%s' "${CURL_STUB_CODE:-200}"
exit 0
EOF

# jq: answer only the filters the verifier uses. Rows come from JQ_STUB_ROWS; the
# Backups tile state comes from JQ_STUB_TILE.
cat > "$BINDIR/jq" <<'EOF'
#!/usr/bin/env bash
mode=""
for a in "$@"; do
  case "$a" in
    *'has("workflow_runs")'*) mode=has ;;
    *'workflow_runs[]'*) mode=rows ;;
    *'Backups'*) mode=tile ;;
  esac
done
case "$mode" in
  has) exit "${JQ_STUB_HAS_EXIT:-0}" ;;
  rows) printf '%b' "${JQ_STUB_ROWS:-}"; exit 0 ;;
  tile) printf '%s' "${JQ_STUB_TILE:-}"; exit 0 ;;
  *) exit 1 ;;
esac
EOF

chmod +x "$BINDIR/curl" "$BINDIR/jq"
export PATH="$BINDIR:$PATH"

# --- Throwaway git trees ----------------------------------------------------
REAL_GIT="$(command -v git)"

# A git stub that records its argv (so the tests can see which -C directory the
# verifier resolved) and then delegates to the real git.
cat > "$BINDIR/git" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\${GIT_CALL_LOG:-/dev/null}"
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$BINDIR/git"

make_tree() { # <dir> <marker> -> prints the commit sha
  local dir="$1" marker="$2"
  mkdir -p "$dir"
  (
    cd "$dir"
    "$REAL_GIT" init -q
    "$REAL_GIT" config user.email [EMAIL]
    "$REAL_GIT" config user.name test
    printf '%s\n' "$marker" > marker.txt
    "$REAL_GIT" add marker.txt
    "$REAL_GIT" commit -q -m "$marker"
  ) >/dev/null
  (cd "$dir" && "$REAL_GIT" rev-parse HEAD)
}

TREE_A="$WORKDIR/tree-a"
TREE_B="$WORKDIR/tree-b"
SHA_A="$(make_tree "$TREE_A" alpha)"
SHA_B="$(make_tree "$TREE_B" bravo)"
if [[ "$SHA_A" == "$SHA_B" ]]; then
  echo "FATAL: the two fixture commits collided ($SHA_A)" >&2
  exit 1
fi

LAYOUT="$WORKDIR/hybrid-ai.env"
write_layout() { # <app-dir>
  printf 'HYBRID_AI_APP_DIR=%s\n' "$1" > "$LAYOUT"
}

# A green, completed API run for SHA_A.
export CURL_STUB_CODE=200
export CURL_STUB_BODY='{"workflow_runs":[{"id":1,"status":"completed","conclusion":"success"}]}'
export JQ_STUB_ROWS=$'1\tcompleted\tsuccess\n'

GIT_CALL_LOG="$WORKDIR/git-calls.argv"

# run_verify <app|__unset__> <layout|__absent__> -> sets RC, OUT, GIT_CALLS, RESOLVED
run_verify() {
  local app="$1" layout="$2"
  local env_args=()
  if [[ "$app" != "__unset__" ]]; then
    env_args+=(HYBRID_AI_APP_DIR="$app")
  else
    env_args+=(-u HYBRID_AI_APP_DIR)
  fi
  if [[ "$layout" != "__absent__" ]]; then
    env_args+=(HYBRID_AI_ENV_FILE_FALLBACK="$layout")
  else
    env_args+=(HYBRID_AI_ENV_FILE_FALLBACK="$WORKDIR/no-such-layout.env")
  fi

  rm -f "$GIT_CALL_LOG"
  set +e
  # Scrub the gate's inputs so a value leaked into the caller's environment
  # cannot make a case pass: the layout file must be the only source here.
  env -u BACKUP_LOG -u BACKUP_GROUP_GID -u LOCAL_DOMAIN -u VERIFY_STATUS_UID \
    -u VERIFY_STATUS_GID "${env_args[@]}" GIT_CALL_LOG="$GIT_CALL_LOG" \
    "$VERIFY_SCRIPT" --wait-for "$SHA_A" > "$WORKDIR/out" 2>&1
  RC=$?
  set -e
  OUT="$(cat "$WORKDIR/out")"
  GIT_CALLS="$(cat "$GIT_CALL_LOG" 2>/dev/null || true)"
  # The verifier runs `git -C <dir> rev-parse HEAD`; read back the directory it
  # actually resolved.
  RESOLVED="$(sed -n 's/^-C \([^ ]*\) rev-parse HEAD$/\1/p' <<<"$GIT_CALLS" | head -1)"
}

echo "== Running run-post-deploy-verify.sh tests =="

# Case 1: the environment wins over the layout file. The env tree is on SHA_A
# (PASS), the layout names TREE_B (would FAIL), so PASS proves env precedence.
write_layout "$TREE_B"
run_verify "$TREE_A" "$LAYOUT"
if [[ "$RC" -eq 0 && "$RESOLVED" == "$TREE_A" ]] && grep -qx 'PASS' <<<"$OUT"; then
  pass "env HYBRID_AI_APP_DIR wins over the layout file (PASS)"
else
  fail "env should win over the layout file: rc $RC, resolved '$RESOLVED', out '$OUT'"
fi

# Case 2: env unset -> the layout file supplies APP_DIR. It names TREE_A, which
# is on SHA_A, so the run must PASS. On the unpatched base this reads /workspace
# instead and FAILs.
write_layout "$TREE_A"
run_verify "__unset__" "$LAYOUT"
if [[ "$RC" -eq 0 && "$RESOLVED" == "$TREE_A" ]] && grep -qx 'PASS' <<<"$OUT"; then
  pass "layout file supplies APP_DIR when the env is unset (PASS)"
else
  fail "layout file should supply APP_DIR when the env is unset: rc $RC, resolved '$RESOLVED', out '$OUT'"
fi

# Case 3: neither the env nor a layout file -> the /workspace fallback.
run_verify "__unset__" "__absent__"
if [[ "$RESOLVED" == "/workspace" ]]; then
  pass "no env and no layout file -> APP_DIR resolves to /workspace"
else
  fail "expected the /workspace fallback, resolved '$RESOLVED'"
fi

# Case 4: green run, tree on another commit -> FAIL with the exact message.
run_verify "$TREE_B" "__absent__"
if [[ "$RC" -eq 1 ]] \
   && grep -qxF "FAIL: deployed tree is on ${SHA_B}, expected ${SHA_A}" <<<"$OUT"; then
  pass "tree on another commit -> FAIL 'deployed tree is on <head>, expected <sha>' exit 1"
else
  fail "expected the wrong-commit FAIL, got rc $RC, out '$OUT'"
fi

# Case 5: green run, tree on the expected SHA -> PASS exit 0.
run_verify "$TREE_A" "__absent__"
if [[ "$RC" -eq 0 ]] && grep -qx 'PASS' <<<"$OUT"; then
  pass "tree on the expected SHA -> PASS exit 0"
else
  fail "expected PASS exit 0, got rc $RC, out '$OUT'"
fi

# Case 6: a layout value that is not an absolute path is refused; the run falls
# through to /workspace rather than trusting the value.
printf 'HYBRID_AI_APP_DIR=relative/path\n' > "$LAYOUT"
run_verify "__unset__" "$LAYOUT"
if [[ "$RESOLVED" == "/workspace" ]]; then
  pass "a non-absolute layout value is ignored -> /workspace fallback"
else
  fail "expected a non-absolute layout value to be ignored, resolved '$RESOLVED'"
fi

# --- Backups tile gate ------------------------------------------------------
# These cases need a layout file that names the log, the supplementary gid and
# the domain, plus a real log file. They run as whoever runs the suite; the
# readability probe then prints a skip note (it never claims a root read as a
# pass), so the verdict is driven by (a) the file check and (c) the tile query,
# which is exactly the contract.
BLOG="$WORKDIR/backup.log"
write_gate_layout() { # <app-dir> <log-path>
  printf 'HYBRID_AI_APP_DIR=%s\n' "$1" > "$LAYOUT"
  printf 'BACKUP_LOG=%s\n' "$2" >> "$LAYOUT"
  printf 'BACKUP_GROUP_GID=982\n' >> "$LAYOUT"
  printf 'LOCAL_DOMAIN=example.test\n' >> "$LAYOUT"
}

printf 'EVENT ts=2026-01-01T00:00:00Z event=backup_success detail=stub\n' > "$BLOG"

# Case 7: the writer's log holds a success but the live tile says warn -> FAIL.
# This is the whole point of the gate: a release that leaves the reader blind.
write_gate_layout "$TREE_A" "$BLOG"
export CURL_TILE_CODE=200 JQ_STUB_TILE=warn
run_verify "__unset__" "$LAYOUT"
if [[ "$RC" -eq 1 ]] \
   && grep -qxF 'FAIL: the backup log records event=backup_success but the Backups tile reports warn' <<<"$OUT"; then
  pass "log success + warn tile -> FAIL exit 1"
else
  fail "expected the blind-tile FAIL, got rc $RC, out '$OUT'"
fi

# Case 8: the same log, a healthy tile -> the verdict is unchanged (PASS).
export JQ_STUB_TILE=ok
run_verify "__unset__" "$LAYOUT"
if [[ "$RC" -eq 0 ]] && grep -qx 'PASS' <<<"$OUT"; then
  pass "log success + ok tile -> PASS exit 0 (verdict unchanged)"
else
  fail "expected PASS with a healthy tile, got rc $RC, out '$OUT'"
fi

# Case 9: an unreachable status API is a skip note, never a pass or a FAIL on
# its own account -- with a healthy tree the verdict stays PASS.
export CURL_TILE_CODE=000 JQ_STUB_TILE=""
run_verify "__unset__" "$LAYOUT"
if [[ "$RC" -eq 0 ]] && grep -qx 'PASS' <<<"$OUT"; then
  if grep -q 'skip: the status API was unreachable' <<<"$OUT"; then
    pass "unreachable status API -> skip note, verdict unchanged (PASS)"
  else
    fail "an unreachable API did not print a skip note: '$OUT'"
  fi
else
  fail "an unreachable API should not change the verdict: rc $RC, out '$OUT'"
fi

# Case 10: the log is not a regular, non-empty file -> FAIL, because the reader
# can never work from it whatever the tile says.
: > "$BLOG"
export CURL_TILE_CODE=200 JQ_STUB_TILE=ok
run_verify "__unset__" "$LAYOUT"
if [[ "$RC" -eq 1 ]] \
   && grep -qxF 'FAIL: the backup log is not a regular, non-empty file' <<<"$OUT"; then
  pass "empty backup log -> FAIL exit 1"
else
  fail "expected the empty-log FAIL, got rc $RC, out '$OUT'"
fi
printf 'EVENT ts=2026-01-01T00:00:00Z event=backup_success detail=stub\n' > "$BLOG"
unset CURL_TILE_CODE JQ_STUB_TILE

echo "== done =="
if [[ "$failures" -ne 0 ]]; then
  echo "$failures case(s) failed."
  exit 1
fi
echo "All cases passed."
exit 0
