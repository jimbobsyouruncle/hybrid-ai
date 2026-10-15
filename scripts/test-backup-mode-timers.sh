#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/test-backup-mode-timers.sh
# PURPOSE (plain English):
#   Proves the ONE setting HYBRID_AI_BACKUP_MODE steers every tool that reports
#   or checks the nightly backup timer. In user mode they must keep the per-user
#   unit and systemctl --user; in system mode they must use the capture timer
#   through systemctl --system (and drop the user-only linger check).
#
#   Fully OFFLINE. The four real scripts (doctor.sh, collect-diagnostics.sh,
#   scripts/deploy-remote.sh and backup/backup.sh) are copied into a scratch app
#   directory and run there against a stub PATH. A stub `systemctl` records its
#   argv, so the test asserts the exact scope and unit each script used, for both
#   modes. No Docker, no network, no root.
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_SRC="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

for t in mktemp find git sqlite3; do
  command -v "$t" >/dev/null 2>&1 || { echo "error: $t is required" >&2; exit 2; }
done
[[ -f "${REPO_SRC}/backup/backup.sh" ]] || { echo "error: backup.sh not found" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$(( PASS + 1 )); printf 'ok   %s\n' "$*"; }
bad()  { FAIL=$(( FAIL + 1 )); printf 'FAIL %s\n' "$*" >&2; }
assert() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

BIN="$WORK/bin"; mkdir -p "$BIN"
SYSCTL_LOG="$WORK/systemctl.log"
export SYSCTL_LOG

# --- stubs ------------------------------------------------------------------
cat > "$BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SYSCTL_LOG"
# is-enabled prints a plausible word; is-active/list-timers print nothing.
[[ "$*" == *is-enabled* ]] && echo enabled
exit 0
EOF
cat > "$BIN/journalctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$JOURNALCTL_LOG"
exit 0
EOF
cat > "$BIN/docker" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
# Health endpoints appear up, so deploy-remote does not poll for 2 minutes.
exit 0
EOF
cat > "$BIN/restic" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$BIN/loginctl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
cat > "$BIN/sleep" <<'EOF'
#!/usr/bin/env bash
# Keep the offline test fast: the deploy's settle/poll waits are not under test.
exit 0
EOF
chmod +x "$BIN"/*
JOURNALCTL_LOG="$WORK/journalctl.log"
export JOURNALCTL_LOG

# --- scratch app ------------------------------------------------------------
APPD="$WORK/app"
mkdir -p "$APPD/scripts/lib" "$APPD/backup" "$APPD/openhands" "$APPD/hermes" \
         "$APPD/webui_data" "$APPD/hermes_data"
cp "$REPO_SRC/scripts/lib/hybrid-ai-env.sh" "$APPD/scripts/lib/"
cp "$REPO_SRC/scripts/lib/read-probe.sh" "$APPD/scripts/lib/"
cp "$REPO_SRC/backup/backup.sh" "$APPD/backup/"
cp "$REPO_SRC/backup/backup-containers.sh" "$APPD/backup/" 2>/dev/null || true
cp "$REPO_SRC/doctor.sh" "$APPD/"
cp "$REPO_SRC/collect-diagnostics.sh" "$APPD/"
cp "$REPO_SRC/scripts/deploy-remote.sh" "$APPD/scripts/"
: > "$APPD/docker-compose.yml"
chmod +x "$APPD/backup/backup.sh" "$APPD/doctor.sh" "$APPD/collect-diagnostics.sh" "$APPD/scripts/deploy-remote.sh"
sqlite3 "$APPD/webui_data/webui.db" 'CREATE TABLE chat(id);' 2>/dev/null || true
sqlite3 "$APPD/hermes_data/state.db" 'CREATE TABLE s(k);' 2>/dev/null || true

# Credentials in a scratch dir, so doctor finds them and reaches the timer check.
CRED="$WORK/cred"; mkdir -p "$CRED"
printf 'RESTIC_REPOSITORY=s3:https://example.invalid/b\nAWS_ACCESS_KEY_ID=x\nAWS_SECRET_ACCESS_KEY=y\n' > "$CRED/r2.env"
printf 'pw\n' > "$CRED/repo-password"
chmod 600 "$CRED/r2.env" "$CRED/repo-password"

# --- git repo for deploy-remote ---------------------------------------------
( cd "$APPD" && git init -q && git config user.email t@e.com && git config user.name t \
  && git commit -q --allow-empty -m init )
SHA="$( cd "$APPD" && git rev-parse HEAD )"

# Minimal install.sh / doctor.sh stubs so deploy-remote's steps succeed.
cat > "$APPD/install.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$APPD/install.sh"

run_doctor() { # mode
  : > "$SYSCTL_LOG"
  ( cd "$APPD" && PATH="$BIN:$PATH" HYBRID_AI_BACKUP_MODE="$1" HYBRID_AI_BACKUP_CRED_DIR="$CRED" \
      HYBRID_AI_WORK_DIR="$APPD" HOME="$WORK/home" \
      timeout 60 bash ./doctor.sh --no-cloud ) > "$WORK/doctor.$1.out" 2>&1
  return 0
}

run_deploy() { # mode
  : > "$SYSCTL_LOG"
  ( cd "$APPD" && PATH="$BIN:$PATH" HYBRID_AI_BACKUP_MODE="$1" \
      HYBRID_AI_WORK_DIR="$APPD" HOME="$WORK/home" \
      timeout 60 bash ./scripts/deploy-remote.sh "$SHA" ) > "$WORK/deploy.$1.out" 2>&1
  return 0
}

run_collect() { # mode
  : > "$SYSCTL_LOG"
  : > "$JOURNALCTL_LOG"
  ( cd "$APPD" && PATH="$BIN:$PATH" HYBRID_AI_BACKUP_MODE="$1" HYBRID_AI_BACKUP_CRED_DIR="$CRED" \
      HYBRID_AI_WORK_DIR="$APPD" HOME="$WORK/home" \
      timeout 90 bash ./collect-diagnostics.sh --output "$WORK/diag.$1.txt" --lines 5 ) \
      > "$WORK/collect.$1.out" 2>&1
  return 0
}

run_backup() { # mode
  : > "$SYSCTL_LOG"
  rm -rf "$APPD/.backup-staging"
  ( cd "$APPD" && PATH="$BIN:$PATH" HYBRID_AI_BACKUP_MODE="$1" BACKUP_CONF_DIR="$CRED" \
      HYBRID_AI_WORK_DIR="$APPD" HYBRID_AI_LOG_DIR="$APPD" HOME="$WORK/home" \
      BACKUP_NO_PAUSE=1 \
      timeout 60 bash ./backup/backup.sh --non-interactive --stage-only ) > "$WORK/backup.$1.out" 2>&1
  return 0
}

mkdir -p "$WORK/home"

# ---------------------------------------------------------------------------
# User mode: every tool keeps the per-user unit and --user scope.
# ---------------------------------------------------------------------------
echo "== user mode =="
run_doctor user
assert "doctor (user) checks the user backup timer" \
  bash -c "grep -q -- '--user is-active hybrid-ai-backup.timer' '$SYSCTL_LOG'"
assert "doctor (user) never uses --system for the backup timer" \
  bash -c "! grep -q -- '--system is-active hybrid-ai-backup' '$SYSCTL_LOG'"

run_deploy user
assert "deploy-remote (user) checks the user backup timer" \
  bash -c "grep -q -- '--user is-active hybrid-ai-backup.timer' '$SYSCTL_LOG'"

run_collect user
assert "collect-diagnostics (user) lists user timers" \
  bash -c "grep -q -- '--user list-timers hybrid-ai-' '$SYSCTL_LOG'"

run_backup user
assert "backup.sh (user) platform.txt reports the user timer" \
  bash -c "grep -qx 'backup_timer=enabled' '$APPD/.backup-staging/host/platform.txt'"
assert "backup.sh (user) asked systemctl for the user backup timer" \
  bash -c "grep -q -- '--user is-enabled hybrid-ai-backup.timer' '$SYSCTL_LOG'"

# ---------------------------------------------------------------------------
# System mode: the capture timer through --system; no user-unit checks.
# ---------------------------------------------------------------------------
echo "== system mode =="
run_doctor system
assert "doctor (system) checks the system capture timer" \
  bash -c "grep -q -- '--system is-active hybrid-ai-backup-capture.timer' '$SYSCTL_LOG'"
assert "doctor (system) never checks the user backup timer" \
  bash -c "! grep -q -- '--user is-active hybrid-ai-backup' '$SYSCTL_LOG'"
assert "doctor (system) skips the user-only linger check" \
  bash -c "! grep -qi 'Linger' '$WORK/doctor.system.out'"

run_deploy system
assert "deploy-remote (system) checks the system capture timer" \
  bash -c "grep -q -- '--system is-active hybrid-ai-backup-capture.timer' '$SYSCTL_LOG'"

run_collect system
assert "collect-diagnostics (system) lists system timers" \
  bash -c "grep -q -- '--system list-timers hybrid-ai-' '$SYSCTL_LOG'"
assert "collect-diagnostics (system) uses the capture-unit journal" \
  bash -c "grep -q -- '--system -u hybrid-ai-backup-capture.service' '$JOURNALCTL_LOG'"

run_backup system
assert "backup.sh (system) platform.txt reports the system timer" \
  bash -c "grep -qx 'backup_timer=enabled' '$APPD/.backup-staging/host/platform.txt'"
assert "backup.sh (system) asked systemctl for the capture timer" \
  bash -c "grep -q -- '--system is-enabled hybrid-ai-backup-capture.timer' '$SYSCTL_LOG'"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
