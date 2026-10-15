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
# Log argv so a case can assert WHICH timer and scope was checked, then report
# the backup timer active so the deploy emits no stray warning.
printf '%s\n' "$*" >> "${SYSTEMCTL_LOG:-/dev/null}"
exit 0
EOF

  chmod +x "$BINDIR/docker" "$BINDIR/curl" "$BINDIR/systemctl"
}
make_shims
export PATH="$BINDIR:$PATH"

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

# Case 8: the backup-timer check uses the USER timer in user mode (default).
rm -f "$MARKER"; write_install_stub; write_doctor_stub
SYSTEMCTL_LOG="$WORKDIR/c8.systemctl"; : > "$SYSTEMCTL_LOG"
if SYSTEMCTL_LOG="$SYSTEMCTL_LOG" run_deploy "$WORKDIR/c8.out" "$SHA"; then
  if grep -q -- '--user is-active hybrid-ai-backup.timer' "$SYSTEMCTL_LOG"; then
    pass "user mode checks the user backup timer"
  else
    fail "user mode did not check the user backup timer"
  fi
else
  fail "user-mode deploy failed unexpectedly"
fi

# Case 9: the backup-timer check uses the SYSTEM capture timer in system mode.
rm -f "$MARKER"; write_install_stub; write_doctor_stub
SYSTEMCTL_LOG="$WORKDIR/c9.systemctl"; : > "$SYSTEMCTL_LOG"
if HYBRID_AI_BACKUP_MODE=system SYSTEMCTL_LOG="$SYSTEMCTL_LOG" run_deploy "$WORKDIR/c9.out" "$SHA"; then
  if grep -qx 'is-active hybrid-ai-backup-capture.timer' "$SYSTEMCTL_LOG"; then
    pass "system mode checks the system capture timer"
  else
    fail "system mode did not check the system capture timer"
  fi
else
  fail "system-mode deploy failed unexpectedly"
fi

echo "== done =="
if [[ "$failures" -ne 0 ]]; then
  echo "$failures case(s) failed."
  exit 1
fi
echo "All cases passed."
exit 0
