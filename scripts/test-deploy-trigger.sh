#!/usr/bin/env bash
set -Eeuo pipefail
# ---------------------------------------------------------------------------
# FILE: scripts/test-deploy-trigger.sh
# PURPOSE (plain English):
#   Offline tests for scripts/deploy-trigger.sh, the CLIENT half of the
#   headless deploy. ssh, ssh-keyscan and ssh-keygen are stubbed on PATH, so
#   no network, no key material and no root are needed. The REAL script is
#   invoked by absolute path.
#
#   The test proves:
#     (a) the exact command string sent is `deploy <sha>` and the login name is
#         `hybrid-ai-deploy`;
#     (b) a malformed sha (short, uppercase, a trailing extra argument, a
#         semicolon) sends NOTHING and exits non-zero;
#     (c) a host-key fingerprint mismatch exits non-zero and never invokes ssh;
#     (d) remote exit 0/2/3/255 map exactly as deploy-trigger.sh documents;
#     (e) the temporary private key file is removed on success AND on failure;
#     (f) the mandatory ssh options are present and StrictHostKeyChecking=no
#         and accept-new never appear.
#
# USAGE:
#   bash scripts/test-deploy-trigger.sh
#
# EXIT CODES:
#   0  every case passed
#   1  one or more cases failed
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${SCRIPT_DIR}/deploy-trigger.sh"

[[ -f "$SCRIPT" ]] || { echo "FATAL: cannot find $SCRIPT" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

BIN="$WORK/bin"; mkdir -p "$BIN"
SSH_LOG="$WORK/ssh.log"
KEYSCAN_LOG="$WORK/keyscan.log"
KEYGEN_LOG="$WORK/keygen.log"
export SSH_LOG KEYSCAN_LOG KEYGEN_LOG

PASS=0
FAIL=0
ok()  { PASS=$(( PASS + 1 )); printf 'ok   %s\n' "$*"; }
bad() { FAIL=$(( FAIL + 1 )); printf 'FAIL %s\n' "$*" >&2; }
has_line()    { grep -Fq -- "$2" "$1"; }
hasnt_regex() { ! grep -Eq -- "$2" "$1"; }

SHA="0123456789abcdef0123456789abcdef01234567"
GOOD_FP="SHA256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
BAD_FP="SHA256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
HOST="[IP_ADDRESS]"

# --- ssh stub ---------------------------------------------------------------
# Records the login (USER), the exact remote command (CMD, the LAST argv word)
# and the full argv (ARGV) on separate lines, then exits with $SSH_RC. When
# SSH_EMIT is set it prints that first, standing in for the remote output.
cat > "$BIN/ssh" <<'EOF'
#!/usr/bin/env bash
printf 'USER=%s\n' "${@: -2:1}" >> "$SSH_LOG"
printf 'CMD=%s\n'  "${!#}"      >> "$SSH_LOG"
printf 'ARGV=%s\n' "$*"         >> "$SSH_LOG"
[[ -n "${SSH_EMIT:-}" ]] && printf '%s\n' "$SSH_EMIT"
exit "${SSH_RC:-0}"
EOF

# --- ssh-keyscan stub -------------------------------------------------------
# Prints a known_hosts-style line (the shape `ssh-keyscan -t ed25519` emits),
# or nothing when KEYSCAN_EMPTY is set. Exits with $KEYSCAN_RC.
cat > "$BIN/ssh-keyscan" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$KEYSCAN_LOG"
if [[ -z "${KEYSCAN_EMPTY:-}" ]]; then
  printf '%s ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIexample\n' "${1:-host}"
fi
exit "${KEYSCAN_RC:-0}"
EOF

# --- ssh-keygen stub --------------------------------------------------------
# Reads the known_hosts line on stdin and prints the fingerprint line that
# `ssh-keygen -lf -` emits, with field 2 replaced by $KEYGEN_FP.
cat > "$BIN/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$KEYGEN_LOG"
cat >/dev/null
printf '256 %s scanned-host (ED25519)\n' "${KEYGEN_FP:-SHA256:unknown}"
exit "${KEYGEN_RC:-0}"
EOF

chmod +x "$BIN/ssh" "$BIN/ssh-keyscan" "$BIN/ssh-keygen"
export PATH="$BIN:$PATH"

# run <sha...> -> runs the real script in a private RUNNER_TEMP; echoes rc.
# RT is a fixed runner-temp path, recreated per run, so the caller can inspect
# the temp dir (and check the key file was removed) without subshell scoping.
# KEYGEN_FP (the fingerprint the ssh-keygen stub reports) defaults to the good
# value, so an unset override means "scan reports a matching host key".
RT="$WORK/runner-temp"
run() {
  : > "$SSH_LOG"; : > "$KEYSCAN_LOG"; : > "$KEYGEN_LOG"
  rm -rf -- "$RT"; mkdir -p "$RT"
  local rc=0
  RUNNER_TEMP="$RT" \
  PI_HOST="$HOST" \
  PI_SSH_KEY="FAKE-PRIVATE-KEY-CONTENT" \
  PI_SSH_HOST_KEY="${FP:-$GOOD_FP}" \
  KEYGEN_FP="${KEYGEN_FP:-$GOOD_FP}" \
  "$SCRIPT" "$@" >"$WORK/out" 2>&1 || rc=$?
  printf '%s' "$rc"
}

ssh_called() { [[ -s "$SSH_LOG" ]]; }
key_left()   { [[ -e "$RT/hybrid-ai-deploy-key" ]]; }

echo "== (a) exact command string and login name =="
rc="$(run "$SHA")"
if [[ "$rc" == "0" ]]; then
  ok "remote exit 0 -> script exit 0"
else
  bad "remote exit 0 exited $rc (want 0)"
  sed 's/^/      /' "$WORK/out" >&2 || true
fi
# The ssh stub records the login (USER), the exact remote command (CMD, the
# LAST argv word) and the full argv. Assert the login name, the exact
# two-token command string, and that the key was passed with -i.
if has_line "$SSH_LOG" "CMD=deploy ${SHA}" \
   && has_line "$SSH_LOG" "USER=hybrid-ai-deploy@${HOST}" \
   && has_line "$SSH_LOG" "ARGV=-i $RT/hybrid-ai-deploy-key "; then
  ok "sent exactly 'deploy <sha>' to hybrid-ai-deploy@<host> with -i <key>"
else
  bad "did not send the exact command string / login name"
  sed 's/^/      /' "$SSH_LOG" >&2 || true
fi

echo "== (b) malformed sha sends nothing =="
bad_shas=(
  "too short|0123456789abcdef"
  "uppercase|0123456789ABCDEF0123456789ABCDEF01234567"
)
for case in "${bad_shas[@]}"; do
  name="${case%%|*}"; value="${case#*|}"
  rc="$(run "$value")"
  if [[ "$rc" == "0" ]]; then
    bad "'${name}' exited 0 (want non-zero)"
  elif ssh_called; then
    bad "'${name}' refused but ssh was still invoked"
  else
    ok "'${name}' refused (exit $rc) and ssh was never invoked"
  fi
done
# A trailing extra argument (two args) must be refused.
rc="$(run "$SHA" "extra")"
if [[ "$rc" != "0" ]] && ! ssh_called; then
  ok "a trailing extra argument is refused (exit $rc) and ssh was never invoked"
else
  bad "a trailing extra argument was not refused cleanly (rc=$rc)"
fi
# A sha carrying a semicolon must be refused.
rc="$(run "${SHA}; id")"
if [[ "$rc" != "0" ]] && ! ssh_called; then
  ok "a semicolon in the sha is refused (exit $rc) and ssh was never invoked"
else
  bad "a semicolon sha was not refused cleanly (rc=$rc)"
fi

echo "== (c) fingerprint mismatch never invokes ssh =="
rc="$(FP="$BAD_FP" run "$SHA")"
if [[ "$rc" != "0" ]] && ! ssh_called && ! key_left; then
  ok "fingerprint mismatch exits $rc, ssh never invoked, key removed"
else
  bad "fingerprint mismatch was not refused cleanly (rc=$rc, ssh_called=$(ssh_called && echo yes || echo no))"
fi
if has_line "$WORK/out" "::error::"; then
  ok "fingerprint mismatch prints an ::error:: line"
else
  bad "fingerprint mismatch printed no ::error:: line"
fi
if has_line "$KEYSCAN_LOG" "-t ed25519 $HOST"; then
  ok "fetched the host key with 'ssh-keyscan -t ed25519 <host>'"
else
  bad "did not fetch the host key with ssh-keyscan -t ed25519"
fi

echo "== (d) remote exit-code mapping =="
# 0 -> 0
rc="$(run "$SHA")"
if [[ "$rc" == "0" ]]; then ok "remote 0 -> 0"; else bad "remote 0 -> $rc (want 0)"; fi
# 2 -> non-zero with the refusal error
rc="$(SSH_RC=2 run "$SHA")"
if [[ "$rc" != "0" ]] && has_line "$WORK/out" "::error::forced command refused the request"; then
  ok "remote 2 -> non-zero ($rc) with 'forced command refused the request'"
else
  bad "remote 2 mapped wrong (rc=$rc)"
fi
# 3 -> non-zero with the unit error
rc="$(SSH_RC=3 run "$SHA")"
if [[ "$rc" != "0" ]] && has_line "$WORK/out" "::error::deploy unit failed"; then
  ok "remote 3 -> non-zero ($rc) with 'deploy unit failed'"
else
  bad "remote 3 mapped wrong (rc=$rc)"
fi
# 255 -> non-zero with a generic error
rc="$(SSH_RC=255 run "$SHA")"
if [[ "$rc" != "0" ]] && has_line "$WORK/out" "::error::"; then
  ok "remote 255 -> non-zero ($rc) with an ::error:: line"
else
  bad "remote 255 mapped wrong (rc=$rc)"
fi

echo "== (e) key removed on success and on failure =="
rc="$(run "$SHA")"
if [[ "$rc" == "0" ]] && ! key_left; then
  ok "key file removed on success"
else
  bad "key file survived a success (rc=$rc)"
fi
rc="$(SSH_RC=3 run "$SHA")"
if [[ "$rc" != "0" ]] && ! key_left; then
  ok "key file removed on remote failure"
else
  bad "key file survived a remote failure (rc=$rc)"
fi
rc="$(FP="$BAD_FP" run "$SHA")"
if ! key_left; then
  ok "key file removed on host-key mismatch"
else
  bad "key file survived a host-key mismatch"
fi

echo "== (e2) remote output reaches the log =="
rc="$(SSH_EMIT="unit: hybrid-ai-deploy@${SHA}.service
result: success
hello-from-the-run-log" run "$SHA")"
if [[ "$rc" == "0" ]] \
   && has_line "$WORK/out" "unit: hybrid-ai-deploy@${SHA}.service" \
   && has_line "$WORK/out" "result: success" \
   && has_line "$WORK/out" "hello-from-the-run-log"; then
  ok "remote unit:/result:/run log output appears in the job log"
else
  bad "remote output did not reach the job log"
  sed 's/^/      /' "$WORK/out" >&2 || true
fi

echo "== (f) mandatory ssh options, no weakened checking =="
rc="$(run "$SHA")"
for opt in \
  "IdentitiesOnly=yes" \
  "BatchMode=yes" \
  "StrictHostKeyChecking=yes" \
  "UserKnownHostsFile=" \
  "ConnectTimeout=" \
  "ServerAliveInterval="; do
  if has_line "$SSH_LOG" "$opt"; then
    ok "ssh invocation contains ${opt}"
  else
    bad "ssh invocation is missing ${opt}"
  fi
done
if hasnt_regex "$SSH_LOG" 'StrictHostKeyChecking=no|accept-new'; then
  ok "StrictHostKeyChecking=no and accept-new never appear"
else
  bad "a weakened host-key option appeared in the ssh invocation"
fi

echo "== static checks =="
# The private key must be written mode 0600 and never echoed.
if has_line "$SCRIPT" "chmod 0600 -- \"\$KEY_FILE\""; then
  ok "the private key file is chmod 0600"
else
  bad "the private key file is not chmod 0600"
fi
if hasnt_regex "$SCRIPT" '^[[:space:]]*set -x'; then
  ok "the script never enables xtrace"
else
  bad "the script enables xtrace"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
