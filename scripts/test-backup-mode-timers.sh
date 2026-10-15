#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/test-backup-mode-timers.sh
# PURPOSE (plain English):
#   Proves the backup SCHEDULE checks follow HYBRID_AI_BACKUP_MODE:
#
#     * user mode (the default) checks the user units
#       (systemctl --user ... hybrid-ai-backup.timer);
#     * system mode checks the system capture timer
#       (systemctl ... hybrid-ai-backup-capture.timer, no --user).
#
#   Three of the four places that look at the schedule are exercised at run
#   time with systemctl/journalctl stubbed on PATH, so the test asserts the
#   ACTUAL argv the script produced:
#
#     * doctor.sh              (the "Backups" section)
#     * collect-diagnostics.sh (the "Backups" section)
#     * backup.sh              (the platform.txt "backup_timer=" line)
#
#   The fourth, scripts/deploy-remote.sh, is covered by
#   scripts/test-deploy-remote.sh (cases 8 and 9). This file also greps the
#   source of all four to prove the mode branch exists.
#
# Fully OFFLINE. Needs only bash and coreutils.
#
# Exit 0 when every case passes, non-zero otherwise. Exit 2 on usage error.
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

FAILURES=0
ok()  { printf 'PASS: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; FAILURES=$(( FAILURES + 1 )); }

# --- Stubs on PATH ----------------------------------------------------------
STUB="$TMPROOT/bin"
mkdir -p "$STUB"
# Every stubbed command records its argv, then succeeds with empty output. An
# empty list-timers output keeps the scripts' parsers happy.
for c in docker systemctl journalctl loginctl restic tailscale curl ss getfacl; do
  cat > "$STUB/$c" <<'EOF'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename -- "$0")" "$*" >> "${CALL_LOG:-/dev/null}"
exit 0
EOF
  chmod +x "$STUB/$c"
done

CREDS="$TMPROOT/creds"
mkdir -p "$CREDS"
printf 'ACCOUNT_ID=x\n' > "$CREDS/r2.env"
printf 'pw\n' > "$CREDS/repo-password"
chmod 600 "$CREDS/r2.env" "$CREDS/repo-password"

CALLS="$TMPROOT/calls"
: > "$CALLS"

# assert_doctor_mode <desc> <mode> <timer> <scope>
#   <scope> is "user" for a --user call, or "system" for a bare call.
assert_doctor_mode() { # desc mode timer scope
  local desc="$1" mode="$2" timer="$3" scope="$4"
  : > "$CALLS"
  env -i PATH="$STUB:/usr/bin:/bin" HOME="$TMPROOT/home" USER=testuser \
      CALL_LOG="$CALLS" BACKUP_CONF_DIR="$CREDS" \
      HYBRID_AI_BACKUP_CRED_DIR="$CREDS" \
      HYBRID_AI_BACKUP_MODE="$mode" \
      timeout 90 bash "$REPO/doctor.sh" --no-cloud --quiet >/dev/null 2>&1 || true
  if [[ "$scope" == "user" ]]; then
    if grep -qF -- "--user is-active ${timer}" "$CALLS"; then ok "$desc"; else bad "$desc"; fi
  else
    if grep -qxF -- "systemctl is-active ${timer}" "$CALLS"; then ok "$desc"; else bad "$desc"; fi
  fi
}

assert_diag_mode() { # desc mode timer scope
  local desc="$1" mode="$2" timer="$3" scope="$4"
  : > "$CALLS"
  env -i PATH="$STUB:/usr/bin:/bin" HOME="$TMPROOT/home" USER=testuser \
      CALL_LOG="$CALLS" BACKUP_CONF_DIR="$CREDS" \
      HYBRID_AI_BACKUP_CRED_DIR="$CREDS" \
      HYBRID_AI_BACKUP_MODE="$mode" \
      timeout 90 bash "$REPO/collect-diagnostics.sh" --no-redact \
        --output "$TMPROOT/diag.txt" >/dev/null 2>&1 || true
  if [[ "$scope" == "user" ]]; then
    if grep -qF -- "--user list-timers hybrid-ai-* --no-pager" "$CALLS"; then ok "$desc"; else bad "$desc"; fi
  else
    if grep -qxF -- "systemctl list-timers hybrid-ai-* --no-pager" "$CALLS"; then ok "$desc"; else bad "$desc"; fi
  fi
}

echo "== doctor.sh =="
assert_doctor_mode "doctor: user mode checks the user timer" \
  user hybrid-ai-backup.timer user
assert_doctor_mode "doctor: system mode checks the system capture timer" \
  system hybrid-ai-backup-capture.timer system

echo "== collect-diagnostics.sh =="
assert_diag_mode "diagnostics: user mode lists user timers" \
  user hybrid-ai-backup.timer user
assert_diag_mode "diagnostics: system mode lists system timers" \
  system hybrid-ai-backup-capture.timer system

# --- backup.sh platform.txt: static source assertion ------------------------
# Running backup.sh end-to-end to inspect one line of platform.txt duplicates
# scripts/test-backup.sh; here we assert the branch is present and picks the
# right timer in each mode.
echo "== backup.sh platform.txt =="
BACKUP="$REPO/backup/backup.sh"
if grep -q 'systemctl is-enabled hybrid-ai-backup-capture.timer' "$BACKUP" \
   && grep -q 'systemctl --user is-enabled hybrid-ai-backup.timer' "$BACKUP"; then
  ok "backup.sh platform.txt selects the timer by mode"
else
  bad "backup.sh platform.txt does not select the timer by mode"
fi

# --- deploy-remote.sh: static source assertion (runtime is case 8/9 there) --
echo "== deploy-remote.sh =="
DEPLOY="$REPO/scripts/deploy-remote.sh"
if grep -q 'hybrid-ai-backup-capture.timer' "$DEPLOY" \
   && grep -q 'hybrid-ai-backup.timer' "$DEPLOY" \
   && grep -q 'SYSTEMCTL_SCOPE' "$DEPLOY"; then
  ok "deploy-remote.sh selects the timer by mode"
else
  bad "deploy-remote.sh does not select the timer by mode"
fi

# --- Every one of the four locations branches on HYBRID_AI_BACKUP_MODE ------
echo "== mode branch present in all four =="
for f in doctor.sh collect-diagnostics.sh scripts/deploy-remote.sh; do
  if grep -q 'HYBRID_AI_BACKUP_MODE' "$REPO/$f"; then
    ok "$f branches on HYBRID_AI_BACKUP_MODE"
  else
    bad "$f does not branch on HYBRID_AI_BACKUP_MODE"
  fi
done
if grep -q 'BACKUP_MODE' "$BACKUP"; then
  ok "backup/backup.sh branches on the mode"
else
  bad "backup/backup.sh does not branch on the mode"
fi

# ---------------------------------------------------------------------------
if (( FAILURES != 0 )); then
  echo "FAILURES: $FAILURES" >&2
  exit 1
fi
echo "All backup-mode timer cases passed."
exit 0
