#!/usr/bin/env bash
set -Eeuo pipefail
# ---------------------------------------------------------------------------
# FILE: scripts/test-deploy-remote.sh
# PURPOSE (plain English):
#   Offline tests for scripts/deploy-remote.sh. They need no Docker and no
#   network. A throwaway git repo is built in a temp dir, and install.sh,
#   docker, curl, systemctl and doctor.sh are stubbed with shims / fixtures.
#   The tests invoke the REAL deploy-remote.sh by absolute path.
#
# USAGE:
#   bash scripts/test-deploy-remote.sh
#
# EXIT CODES:
#   0  every case passed
#   1  one or more cases failed
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_SCRIPT="$SCRIPT_DIR/deploy-remote.sh"

if [[ ! -f "$DEPLOY_SCRIPT" ]]; then
  echo "FATAL: cannot find $DEPLOY_SCRIPT" >&2
  exit 1
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf -- "$WORKDIR"' EXIT

BINDIR="$WORKDIR/bin"      # shims that go on PATH
REPO="$WORKDIR/repo"       # throwaway git working tree
MARKER="$WORKDIR/install-ran"
export INSTALL_MARKER="$MARKER"

mkdir -p "$BINDIR" "$REPO"

failures=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; failures=$((failures + 1)); }

# --- PATH shims -------------------------------------------------------------
make_shims() {
  cat > "$BINDIR/docker" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  cat > "$BINDIR/curl" <<'EOF'
#!/usr/bin/env bash
# Health endpoint always appears up so the poll succeeds on the first try.
exit 0
EOF

  cat > "$BINDIR/systemctl" <<'EOF'
#!/usr/bin/env bash
# Report the backup timer active so the deploy emits no stray warning.
exit 0
EOF

  # systemd-run: records its argv so the post-deploy cases can assert the exact
  # transient unit the deploy asks for. SYSTEMD_RUN_EXIT simulates a launch
  # failure (systemd refuses to start the unit).
  cat > "$BINDIR/systemd-run" <<'EOF'
#!/usr/bin/env bash
printf 'INVOKED\n' >> "${SYSTEMD_RUN_LOG:-/dev/null}"
printf '%s\n' "$@" >> "${SYSTEMD_RUN_LOG:-/dev/null}"
exit "${SYSTEMD_RUN_EXIT:-0}"
EOF

  chmod +x "$BINDIR/docker" "$BINDIR/curl" "$BINDIR/systemctl" "$BINDIR/systemd-run"
}
make_shims
export PATH="$BINDIR:$PATH"

# Default every run to the "verifier is absent" case so the pre-existing cases
# never depend on whether the host really ships /usr/local/sbin/run-post-deploy-
# verify.sh. The post-deploy cases below override these per call.
export HYBRID_AI_POST_DEPLOY_VERIFY_CMD="$WORKDIR/no-such-verifier"
export HYBRID_AI_POST_DEPLOY_VERIFY_LOG="$WORKDIR/no-such-verify.log"
unset SYSTEMD_RUN_LOG SYSTEMD_RUN_EXIT

# --- Throwaway repo with a real commit --------------------------------------
setup_repo() {
  (
    cd "$REPO"
    git init -q
    git config user.email test@example.com
    git config user.name test
    git commit -q --allow-empty -m initial
  )
}
setup_repo

# install.sh stub: touch the marker, then succeed.
write_install_stub() {
  cat > "$REPO/install.sh" <<'EOF'
#!/usr/bin/env bash
touch "$INSTALL_MARKER"
exit 0
EOF
  chmod +x "$REPO/install.sh"
}

# doctor.sh fixture: exit with $DOCTOR_EXIT.
write_doctor_stub() {
  cat > "$REPO/doctor.sh" <<'EOF'
#!/usr/bin/env bash
exit "${DOCTOR_EXIT:-0}"
EOF
  chmod +x "$REPO/doctor.sh"
}

has_line() { grep -qF -- "$2" "$1"; }
line_number() { grep -nF -- "$2" "$1" | head -1 | cut -d: -f1; }

repo_sha() { (cd "$REPO" && git rev-parse HEAD); }

# run_deploy <outfile> [args...]
run_deploy() {
  local out="$1"; shift
  ( cd "$REPO" && "$DEPLOY_SCRIPT" "$@" ) >"$out" 2>&1
}

echo "== Running deploy-remote.sh tests =="

# Case 1: missing argument fails.
rm -f "$MARKER"; write_install_stub; write_doctor_stub
if run_deploy "$WORKDIR/c1.out"; then
  fail "missing argument should fail"
else
  pass "missing argument fails (non-zero)"
fi

# Case 2: malformed SHA fails.
rm -f "$MARKER"
if run_deploy "$WORKDIR/c2.out" "not-a-sha"; then
  fail "malformed SHA should fail"
else
  if has_line "$WORKDIR/c2.out" "::error::"; then
    pass "malformed SHA fails (non-zero) with ::error::"
  else
    fail "malformed SHA failed but printed no ::error:: line"
  fi
fi

# Case 3: HEAD mismatch fails BEFORE install.sh runs.
rm -f "$MARKER"
WRONG_SHA="0000000000000000000000000000000000000000"
if run_deploy "$WORKDIR/c3.out" "$WRONG_SHA"; then
  fail "HEAD mismatch should fail"
else
  if [[ -e "$MARKER" ]]; then
    fail "HEAD mismatch failed but install.sh still ran"
  else
    if has_line "$WORKDIR/c3.out" "::error::"; then
      pass "HEAD mismatch fails (non-zero), ::error::, install.sh never ran"
    else
      fail "HEAD mismatch failed but printed no ::error:: line"
    fi
  fi
fi

SHA="$(repo_sha)"

# Case 4: doctor exit 0 -> script exit 0.
rm -f "$MARKER"; write_install_stub; write_doctor_stub
if DOCTOR_EXIT=0 run_deploy "$WORKDIR/c4.out" "$SHA"; then
  if [[ -e "$MARKER" ]]; then
    pass "doctor exit 0 -> script exit 0 (install ran)"
  else
    fail "doctor exit 0 -> exit 0 but install.sh never ran"
  fi
else
  fail "doctor exit 0 should keep the deploy green"
fi

# Case 5: doctor exit 1 -> exit 0 plus ::warning:: line.
rm -f "$MARKER"; write_install_stub; write_doctor_stub
if DOCTOR_EXIT=1 run_deploy "$WORKDIR/c5.out" "$SHA"; then
  if has_line "$WORKDIR/c5.out" "::warning::doctor.sh reported warnings"; then
    pass "doctor exit 1 -> script exit 0 with ::warning::"
  else
    fail "doctor exit 1 -> exit 0 but no ::warning:: line"
  fi
else
  fail "doctor exit 1 (warnings) should not fail the deploy"
fi

# Case 6: doctor exit 2 -> non-zero, ::error:: line, after informational lines.
rm -f "$MARKER"; write_install_stub; write_doctor_stub
if DOCTOR_EXIT=2 run_deploy "$WORKDIR/c6.out" "$SHA"; then
  fail "doctor exit 2 should fail the deploy"
else
  if has_line "$WORKDIR/c6.out" "::error::doctor.sh reported failures"; then
    info_ln="$(line_number "$WORKDIR/c6.out" "==> Persistent data intact:")"
    err_ln="$(line_number "$WORKDIR/c6.out" "::error::doctor.sh reported failures")"
    if [[ -n "$info_ln" && -n "$err_ln" && "$info_ln" -lt "$err_ln" ]]; then
      pass "doctor exit 2 -> non-zero, ::error:: after informational lines"
    else
      fail "doctor exit 2 -> ::error:: printed before the informational lines"
    fi
  else
    fail "doctor exit 2 failed but printed no ::error:: line"
  fi
fi

# Case 7: missing doctor.sh -> non-zero.
rm -f "$MARKER"; write_install_stub; rm -f "$REPO/doctor.sh"
if run_deploy "$WORKDIR/c7.out" "$SHA"; then
  fail "missing doctor.sh should fail the deploy"
else
  if has_line "$WORKDIR/c7.out" "::error::"; then
    pass "missing doctor.sh -> non-zero with ::error::"
  else
    fail "missing doctor.sh failed but printed no ::error:: line"
  fi
fi

# --- Doctor-level credential check: a finding must fail the deploy ----------
# Regression for card B26: an embedded credential is a HARD FAIL (doctor exit 2
# -> deploy step exit 4), not a warning. The REAL doctor.sh is invoked with its
# scan roots pointed at throwaway trees. Unrelated host failures are common in
# CI, so the assertions compare the credential run against a baseline and a
# clean run rather than assuming the host is healthy.
DOCTOR="$SCRIPT_DIR/../doctor.sh"
if [[ ! -f "$DOCTOR" ]]; then
  fail "cannot find the real doctor.sh at $DOCTOR"
else
  # Fixture credential assembled at runtime so no literal userinfo shape is
  # committed. It is a dummy (`user:pass`) in a temp dir, never a real secret.
  FIX_USERINFO="$(printf '%s:%s' 'user' 'pass')"
  FIX_URL="https://${FIX_USERINFO}@github.com/x.git"

  CRED_BAD="$WORKDIR/cred-bad"
  CRED_CLEAN="$WORKDIR/cred-clean"
  CRED_NONE="$WORKDIR/cred-none"
  mkdir -p "$CRED_BAD/proj/.git" "$CRED_CLEAN/proj/.git" "$CRED_NONE"
  printf '[remote "origin"]\n\turl = %s\n' "$FIX_URL" > "$CRED_BAD/proj/.git/config"
  printf '[remote "origin"]\n\turl = https://github.com/x.git\n' > "$CRED_CLEAN/proj/.git/config"

  # run_doctor <workspace> <repos-dir> <outfile> -> sets DOCTOR_RC, DOCTOR_FAILS
  run_doctor() {
    set +e
    OPENHANDS_WORKSPACE="$1" AGENT_REPOS_DIR="$2" "$DOCTOR" --no-cloud >"$3" 2>&1
    DOCTOR_RC=$?
    set -e
    DOCTOR_FAILS="$(sed -n 's/.*[^0-9]\([0-9][0-9]*\) failure(s).*/\1/p' "$3" | tail -1)"
    DOCTOR_FAILS="${DOCTOR_FAILS:-0}"
  }

  run_doctor "$CRED_NONE"  "$CRED_NONE"  "$WORKDIR/cred-none.out"
  BASE_RC=$DOCTOR_RC; BASE_FAILS=$DOCTOR_FAILS
  run_doctor "$CRED_CLEAN" "$CRED_NONE"  "$WORKDIR/cred-clean.out"
  CLEAN_RC=$DOCTOR_RC; CLEAN_FAILS=$DOCTOR_FAILS
  run_doctor "$CRED_BAD"   "$CRED_NONE"  "$WORKDIR/cred-bad.out"
  BAD_RC=$DOCTOR_RC; BAD_FAILS=$DOCTOR_FAILS

  # Clean tree keeps the previous exit and adds no failure.
  if [[ "$CLEAN_RC" -eq "$BASE_RC" && "$CLEAN_FAILS" -eq "$BASE_FAILS" ]]; then
    pass "clean scan roots keep the previous exit ($CLEAN_RC) and add no failure"
  else
    fail "clean scan roots changed the verdict (base rc $BASE_RC/$BASE_FAILS fails, clean rc $CLEAN_RC/$CLEAN_FAILS)"
  fi

  # Finding: exit 2, exactly one extra failure, path + key printed.
  if [[ "$BAD_RC" -eq 2 && "$BAD_FAILS" -eq $(( CLEAN_FAILS + 1 )) ]]; then
    pass "credential finding -> doctor exit 2, exactly one extra failure"
  else
    fail "credential finding expected exit 2 and one extra failure, got rc $BAD_RC, $BAD_FAILS vs clean $CLEAN_FAILS"
  fi

  if has_line "$WORKDIR/cred-bad.out" "Credential embedded in a git remote: $CRED_BAD/proj/.git/config: remote.origin.url"; then
    pass "credential finding prints the config path and key"
  else
    fail "credential finding did not print path+key"
  fi

  if grep -qF -- "$FIX_USERINFO" "$WORKDIR/cred-bad.out" || grep -qF -- "$FIX_URL" "$WORKDIR/cred-bad.out"; then
    fail "credential finding leaked the URL or the password"
  else
    pass "credential finding never prints the URL or the password"
  fi

  # The 1-vs-2 mapping already proven above (cases 5 and 6) turns rc 2 into
  # exit 4; the credential finding now travels that path instead of rc 1.
fi

# --- Post-deploy verification hook -----------------------------------------
# The defect: the hook used to start `setsid nohup ... &`, which systemd kills
# at unit exit (setsid escapes the session, not the cgroup), and it silently did
# nothing when the script was absent. The hook now asks systemd for a transient
# unit that outlives the deploy, and says so loudly when it cannot.
rm -f "$MARKER"; write_install_stub; write_doctor_stub

VERIFY_STUB="$WORKDIR/verify-stub"
printf '#!/usr/bin/env bash\nexit 0\n' > "$VERIFY_STUB"
chmod +x "$VERIFY_STUB"
VERIFY_LOG="$WORKDIR/verify.log"
SDRUN_LOG="$WORKDIR/systemd-run.argv"
rm -f "$SDRUN_LOG"

if HYBRID_AI_POST_DEPLOY_VERIFY_CMD="$VERIFY_STUB" \
   HYBRID_AI_POST_DEPLOY_VERIFY_LOG="$VERIFY_LOG" \
   SYSTEMD_RUN_LOG="$SDRUN_LOG" \
   run_deploy "$WORKDIR/c8.out" "$SHA"; then
  RC_SCHEDULED=0
else
  RC_SCHEDULED=$?
fi

INVOCATIONS="$(grep -c '^INVOKED$' "$SDRUN_LOG" 2>/dev/null || true)"
INVOCATIONS="${INVOCATIONS:-0}"
if [[ "$RC_SCHEDULED" -eq 0 && "$INVOCATIONS" -eq 1 ]]; then
  pass "verifier present -> systemd-run invoked exactly once, deploy exit 0"
else
  fail "verifier present -> expected one systemd-run call and exit 0, got ${INVOCATIONS} call(s), exit ${RC_SCHEDULED}"
fi

if [[ "$INVOCATIONS" -eq 1 ]]; then
  missing=""
  for needle in "--collect" "--service-type=exec" \
                "StandardOutput=append:${VERIFY_LOG}" \
                "StandardError=append:${VERIFY_LOG}" "--wait-for" "$SHA"; do
    grep -qF -- "$needle" "$SDRUN_LOG" || missing="${missing} ${needle}"
  done
  if [[ -z "$missing" ]]; then
    pass "verifier present -> argv carries --collect, --service-type=exec, both append: properties and --wait-for <sha>"
  else
    fail "verifier present -> argv is missing:${missing}"
  fi
  if grep -qE -- '--unit=hybrid-ai-post-deploy-verify-[0-9a-f]{12}-[0-9]+' "$SDRUN_LOG"; then
    pass "verifier present -> the transient unit is named hybrid-ai-post-deploy-verify-<sha12>-<pid>"
  else
    fail "verifier present -> the unit name does not match hybrid-ai-post-deploy-verify-<sha12>-<pid>"
  fi
else
  fail "verifier present -> argv assertions skipped, systemd-run never ran"
fi

# Case: the verifier script is absent. The deploy must say so and stay green.
rm -f "$MARKER" "$SDRUN_LOG"
ABSENT_CMD="$WORKDIR/not-installed/run-post-deploy-verify.sh"
if HYBRID_AI_POST_DEPLOY_VERIFY_CMD="$ABSENT_CMD" \
   HYBRID_AI_POST_DEPLOY_VERIFY_LOG="$VERIFY_LOG" \
   SYSTEMD_RUN_LOG="$SDRUN_LOG" \
   run_deploy "$WORKDIR/c9.out" "$SHA"; then
  RC_ABSENT=0
else
  RC_ABSENT=$?
fi
if has_line "$WORKDIR/c9.out" "::warning::post-deploy verification script is absent: ${ABSENT_CMD}"; then
  pass "verifier absent -> the exact absent warning is printed"
else
  fail "verifier absent -> the exact ::warning::post-deploy verification script is absent line is missing"
fi
if [[ "$RC_ABSENT" -eq 0 ]]; then
  pass "verifier absent -> the deploy exit code is unchanged (0)"
else
  fail "verifier absent -> the deploy exited ${RC_ABSENT}, expected 0"
fi
if [[ ! -s "$SDRUN_LOG" ]]; then
  pass "verifier absent -> systemd-run was never invoked"
else
  fail "verifier absent -> systemd-run was invoked for a script that does not exist"
fi

# Case: scheduling fails (systemd refuses). Loud, but never fatal.
rm -f "$MARKER" "$SDRUN_LOG"
if HYBRID_AI_POST_DEPLOY_VERIFY_CMD="$VERIFY_STUB" \
   HYBRID_AI_POST_DEPLOY_VERIFY_LOG="$VERIFY_LOG" \
   SYSTEMD_RUN_LOG="$SDRUN_LOG" SYSTEMD_RUN_EXIT=1 \
   run_deploy "$WORKDIR/c10.out" "$SHA"; then
  RC_SCHEDFAIL=0
else
  RC_SCHEDFAIL=$?
fi
if has_line "$WORKDIR/c10.out" "::warning::post-deploy verification could not be scheduled"; then
  pass "scheduling failure -> the exact could-not-be-scheduled warning is printed"
else
  fail "scheduling failure -> the exact ::warning::post-deploy verification could not be scheduled line is missing"
fi
if [[ "$RC_SCHEDFAIL" -eq 0 ]]; then
  pass "scheduling failure -> the deploy exit code is unchanged (0)"
else
  fail "scheduling failure -> the deploy exited ${RC_SCHEDFAIL}, expected 0"
fi

echo "== done =="
if [[ "$failures" -ne 0 ]]; then
  echo "$failures case(s) failed."
  exit 1
fi
echo "All cases passed."
exit 0
