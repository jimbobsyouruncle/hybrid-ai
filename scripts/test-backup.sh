#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2329  # helpers and the EXIT trap are called indirectly
# ---------------------------------------------------------------------------
# FILE: scripts/test-backup.sh
# Fixture test for backup/backup.sh.
#
# Fully OFFLINE: restic, docker and systemctl are stubbed on PATH. sqlite3 is a
# thin wrapper that logs its argv and then delegates to the real sqlite3, so the
# paused-capture path is exercised for real (checkpoint + quick_check) while the
# test can also assert that an untrusted name never reaches sqlite3 at all.
#
# The real repository is never modified: the script finds its repo from the
# backup.sh directory, so a copy of backup/ is placed inside a scratch git
# repository under a temp dir and the copy is run there.
#
# Cases:
#   a) a discovered name containing a single quote is REJECTED, nothing is
#      created outside staging, and the name never reaches sqlite3
#   a2) glob-char, leading-dash and newline names are rejected too
#   b) a WAL fixture with uncheckpointed frames keeps every row through a
#      paused copy
#   c) a missing/unreadable directory gives NO backup_failed, emits
#      hermes_data_unreadable, and exits with the incomplete code (3)
#   d) a plain text file named *.db is skipped with its reason
#   e) a clean fixture gives backup_success
#   f) the online path (BACKUP_NO_PAUSE=1) uses SQLite .backup, never VACUUM INTO
#
# Exit 0 when every case passes, non-zero otherwise. Exit 2 on usage error.
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_SRC="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
BACKUP_SRC="${REPO_SRC}/backup/backup.sh"

REAL_SQLITE3="$(command -v sqlite3 2>/dev/null || true)"
if [[ -z "$REAL_SQLITE3" ]]; then
  echo "error: sqlite3 is required to run these tests" >&2
  exit 2
fi
for t in mktemp find rsync head cp; do
  command -v "$t" >/dev/null 2>&1 || { echo "error: $t is required" >&2; exit 2; }
done
[[ -f "$BACKUP_SRC" ]] || { echo "error: backup.sh not found at $BACKUP_SRC" >&2; exit 2; }

TMPROOT=""
cleanup() {
  [[ -n "$TMPROOT" && -d "$TMPROOT" ]] && rm -rf "$TMPROOT"
}
trap cleanup EXIT

TMPROOT="$(mktemp -d)"
STUB="$TMPROOT/stub"
SQLITE_LOG="$TMPROOT/sqlite.log"
mkdir -p "$STUB"
: > "$SQLITE_LOG"

# --- stubs -----------------------------------------------------------------
cat > "$STUB/restic" <<'EOF'
#!/usr/bin/env bash
# Assume the repository exists and every operation succeeds. On "backup" the
# staging directory (still present) is copied aside so the test can inspect the
# exact artifact that would have been uploaded. On "restore" it lays down a
# fixture snapshot given in SNAPSHOT_SRC, so restore.sh --test has something
# real to verify.
case "$1" in
  snapshots) exit 0 ;;
  backup)
    if [[ -n "${CAPTURE_DIR:-}" && -d "${2:-}" ]]; then
      rm -rf "$CAPTURE_DIR"
      cp -a "$2" "$CAPTURE_DIR" 2>/dev/null || true
    fi
    exit 0 ;;
  restore)
    if [[ -n "${SNAPSHOT_SRC:-}" && -d "${SNAPSHOT_SRC:-}" ]]; then
      target=""; prev=""
      for a in "$@"; do
        [[ "$prev" == "--target" ]] && target="$a"
        prev="$a"
      done
      if [[ -n "$target" ]]; then
        mkdir -p "$target"
        cp -a "$SNAPSHOT_SRC/." "$target/" 2>/dev/null || true
      fi
    fi
    exit 0 ;;
  forget)  exit 0 ;;
  version) echo "restic 0.0.0 (test stub)"; exit 0 ;;
  *)       exit 0 ;;
esac
EOF

cat > "$STUB/docker" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  inspect) echo running; exit 0 ;;   # every container reports "running"
  pause|unpause|stop|start|exec|version) exit 0 ;;
  compose) exit 0 ;;
  *) exit 0 ;;
esac
EOF

cat > "$STUB/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$STUB/sqlite3" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '${SQLITE_LOG}'
exec '${REAL_SQLITE3}' "\$@"
EOF

chmod +x "$STUB/restic" "$STUB/docker" "$STUB/systemctl" "$STUB/sqlite3"

# --- scratch repository ----------------------------------------------------
REPO="$TMPROOT/repo"
mkdir -p "$REPO"
cp -a "${REPO_SRC}/backup" "$REPO/backup"
# backup.sh and restore.sh source the shared path helper from
# <repo>/scripts/lib/. A scratch repo needs its own copy of it.
cp -a "${REPO_SRC}/scripts" "$REPO/scripts"
chmod +x "$REPO/backup/backup.sh" "$REPO/backup/restore.sh"
mkdir -p "$REPO/webui_data/vector_db" "$REPO/hermes_data" "$REPO/home"

# Credentials live outside the repo; the script only checks mode 0600.
CONF="$TMPROOT/conf"
mkdir -p "$CONF"
chmod 700 "$CONF"
printf 'RESTIC_REPOSITORY=s3:https://example.invalid/bucket\nAWS_ACCESS_KEY_ID=test\nAWS_SECRET_ACCESS_KEY=test\n' > "$CONF/r2.env"
chmod 600 "$CONF/r2.env"
printf 'test-password\n' > "$CONF/repo-password"
chmod 600 "$CONF/repo-password"

LOG="$TMPROOT/backup.log"
CAPTURE="$TMPROOT/capture"
export BACKUP_CONF_DIR="$CONF" BACKUP_LOG="$LOG" HOME="$REPO/home" SQLITE_LOG
export CAPTURE_DIR="$CAPTURE"
export PATH="$STUB:$PATH"
export BACKUP_NO_PAUSE=1

BACKUP="$REPO/backup/backup.sh"

mkwal() {  # mkwal <path> <rows>
  python3 - "$1" "$2" <<'PY'
import sqlite3, os, sys
db, n = sys.argv[1], int(sys.argv[2])
c = sqlite3.connect(db)
c.execute("PRAGMA journal_mode=WAL")
c.execute("PRAGMA wal_autocheckpoint=0")
c.execute("CREATE TABLE t(a)")
c.executemany("INSERT INTO t VALUES(?)", [(i,) for i in range(1, n + 1)])
c.commit()
os._exit(0)
PY
}

run_backup() {  # run_backup <label>; sets RUN_RC, writes stdout/stderr to $TMPROOT/out
  : > "$LOG"
  rm -rf "$CAPTURE"
  RUN_RC=0
  bash "$BACKUP" --non-interactive > "$TMPROOT/out" 2>&1 || RUN_RC=$?
}

FAILURES=0
check() {  # check <description> <expected-rc> <actual-rc>
  if [[ "$3" == "$2" ]]; then
    echo "PASS: $1 (exit $3)"
  else
    echo "FAIL: $1 (expected exit $2, got $3)"
    sed 's/^/      /' "$TMPROOT/out" || true
    FAILURES=$(( FAILURES + 1 ))
  fi
}
assert() {  # assert <description> <condition...>
  local desc="$1"; shift
  if "$@"; then
    echo "PASS: $desc"
  else
    echo "FAIL: $desc"
    sed 's/^/      /' "$TMPROOT/out" || true
    FAILURES=$(( FAILURES + 1 ))
  fi
}
log_has()    { grep -q "event=$1" "$LOG"; }
log_lacks()  { ! grep -q "event=$1" "$LOG"; }
sqlite_log_has()   { grep -qF -- "$1" "$SQLITE_LOG"; }
sqlite_log_lacks() { ! grep -qF -- "$1" "$SQLITE_LOG"; }

# ---------------------------------------------------------------------------
# Case a: a single-quote name is rejected; it is never copied and never reaches
# sqlite3. The name must end in .db so discovery finds it; the quote is exactly
# the character that used to break out of VACUUM INTO's SQL string.
# ---------------------------------------------------------------------------
rm -rf "$REPO/hermes_data"; mkdir -p "$REPO/hermes_data"
EVIL="evil'x.db"
: > "$SQLITE_LOG"
printf 'SQLite format 3\0not really' > "$REPO/hermes_data/${EVIL}"
run_backup "case-a"
check "case a: incomplete exit code" 3 "$RUN_RC"
assert "case a: db_path_rejected emitted"        log_has 'db_path_rejected'
assert "case a: backup_failed NOT emitted"       log_lacks 'backup_failed'
assert "case a: backup_incomplete emitted"       log_has 'backup_incomplete'
assert "case a: raw name never logged"           bash -c "! grep -qF \"evil'x\" '$LOG'"
assert "case a: no database staged"              bash -c "[[ -z \"\$(find '$CAPTURE/databases' -type f 2>/dev/null)\" ]]"
assert "case a: name never reached sqlite3"      bash -c "! grep -qF 'ATTACH DATABASE' '$SQLITE_LOG'"
rm -f "$REPO/hermes_data/${EVIL}"

# ---------------------------------------------------------------------------
# Case a2: other hostile components -- glob chars, a leading dash and an
# embedded newline -- are rejected too, and none reaches sqlite3 or staging.
# ---------------------------------------------------------------------------
rm -rf "$REPO/hermes_data"; mkdir -p "$REPO/hermes_data"
: > "$SQLITE_LOG"
printf 'SQLite format 3\0' > "$REPO/hermes_data/star*.db"
printf 'SQLite format 3\0' > "$REPO/hermes_data/q?.db"
printf 'SQLite format 3\0' > "$REPO/hermes_data/-dash.db"
printf 'SQLite format 3\0' > "$REPO/hermes_data/$(printf 'new\nline').db"
run_backup "case-a2"
check "case a2: incomplete exit code" 3 "$RUN_RC"
assert "case a2: db_path_rejected emitted"  log_has 'db_path_rejected'
assert "case a2: backup_failed NOT emitted" log_lacks 'backup_failed'
assert "case a2: no database staged"        bash -c "[[ -z \"\$(find '$CAPTURE/databases' -type f 2>/dev/null)\" ]]"
assert "case a2: no copy was ever opened"   bash -c "! grep -qE '(star|q\\?|dash)' '$SQLITE_LOG'"
rm -rf "$REPO/hermes_data"

# ---------------------------------------------------------------------------
# Case b: WAL fixture with uncheckpointed frames survives a paused copy
# ---------------------------------------------------------------------------
rm -rf "$REPO/hermes_data"; mkdir -p "$REPO/hermes_data"
unset BACKUP_NO_PAUSE
mkwal "$REPO/hermes_data/wal.db" 5
run_backup "case-b"
check "case b: success exit code" 0 "$RUN_RC"
STAGED="$CAPTURE/databases/hermes_data/wal.db"
assert "case b: staged database exists"          test -f "$STAGED"
assert "case b: all rows kept through the copy"  bash -c "[[ \"\$( '$REAL_SQLITE3' '$STAGED' 'select count(*) from t;' 2>/dev/null )\" == 5 ]]"
assert "case b: backup_success emitted"          log_has 'backup_success'
export BACKUP_NO_PAUSE=1

# ---------------------------------------------------------------------------
# Case c: unreadable directory -> no backup_failed, hermes_data_unreadable,
# exit 3. A permission case is only meaningful as a non-root user.
# ---------------------------------------------------------------------------
rm -rf "$REPO/hermes_data"; mkdir -p "$REPO/hermes_data/sub"
sqlite3 "$REPO/hermes_data/sub/ok.db" 'CREATE TABLE t(a);'
chmod 000 "$REPO/hermes_data/sub"
if [[ "$(id -u)" == "0" ]]; then
  echo "SKIP: case c (permission denied) cannot be exercised as root"
  chmod 755 "$REPO/hermes_data/sub"
else
  run_backup "case-c"
  chmod 755 "$REPO/hermes_data/sub"
  check "case c: incomplete exit code" 3 "$RUN_RC"
  assert "case c: hermes_data_unreadable emitted"  log_has 'hermes_data_unreadable'
  assert "case c: NO backup_failed emitted"        log_lacks 'backup_failed'
fi

# ---------------------------------------------------------------------------
# Case d: a plain text file named *.db is skipped, with its reason
# ---------------------------------------------------------------------------
rm -rf "$REPO/hermes_data"; mkdir -p "$REPO/hermes_data"
printf 'this is not a database\n' > "$REPO/hermes_data/notes.db"
run_backup "case-d"
check "case d: success exit code" 0 "$RUN_RC"
assert "case d: non_sqlite_db_skipped emitted"  log_has 'non_sqlite_db_skipped'
assert "case d: backup_success emitted"         log_has 'backup_success'
assert "case d: notes.db not staged"            bash -c "[[ ! -e '$CAPTURE/databases/hermes_data/notes.db' ]]"
rm -f "$REPO/hermes_data/notes.db"

# ---------------------------------------------------------------------------
# Case e: a clean fixture gives backup_success
# ---------------------------------------------------------------------------
rm -rf "$REPO/hermes_data"; mkdir -p "$REPO/hermes_data"
sqlite3 "$REPO/webui_data/webui.db" 'CREATE TABLE chat(id); INSERT INTO chat VALUES (1);'
sqlite3 "$REPO/hermes_data/state.db" 'CREATE TABLE s(k); INSERT INTO s VALUES (1);'
run_backup "case-e"
check "case e: success exit code" 0 "$RUN_RC"
assert "case e: backup_success emitted"       log_has 'backup_success'
assert "case e: backup_incomplete NOT emitted" log_lacks 'backup_incomplete'
assert "case e: both databases staged"       bash -c "[[ -f '$CAPTURE/databases/webui_data/webui.db' && -f '$CAPTURE/databases/hermes_data/state.db' ]]"

# ---------------------------------------------------------------------------
# Case f: online capture (pause impossible / BACKUP_NO_PAUSE=1) uses SQLite's
# .backup and preserves rows; VACUUM INTO is never invoked.
# ---------------------------------------------------------------------------
rm -rf "$REPO/hermes_data"; mkdir -p "$REPO/hermes_data"
sqlite3 "$REPO/hermes_data/online.db" 'CREATE TABLE t(a); INSERT INTO t VALUES (1),(2),(3);'
export BACKUP_NO_PAUSE=1
: > "$SQLITE_LOG"
run_backup "case-f"
check "case f: success exit code" 0 "$RUN_RC"
STAGED_ON="$CAPTURE/databases/hermes_data/online.db"
assert "case f: online database staged"   test -f "$STAGED_ON"
assert "case f: online rows preserved"    bash -c "[[ \"\$( '$REAL_SQLITE3' '$STAGED_ON' 'select count(*) from t;' 2>/dev/null )\" == 3 ]]"
assert "case f: .backup path used"        sqlite_log_has '.backup "'
assert "case f: VACUUM INTO never used"   sqlite_log_lacks 'VACUUM INTO'

# ---------------------------------------------------------------------------
# Case g: SPLIT layout. APP, DATA, LOG and WORK are four separate temp dirs
# (plus a separate HOME). backup stages from DATA_DIR, writes nothing under
# APP_DIR, and restore --test restores a snapshot made with the DEFAULT layout.
# This exercises the shared path helper's relocation, not just the defaults.
# ---------------------------------------------------------------------------
SPLIT="$TMPROOT/split"
APP2="$SPLIT/app";  DATA2="$SPLIT/data"; LOG2="$SPLIT/log"; WORK2="$SPLIT/work"
HOME2="$SPLIT/home"
mkdir -p "$APP2/openhands" "$APP2/hermes" "$APP2/scripts" "$DATA2" "$LOG2" "$WORK2" "$HOME2"
# A minimal APP_DIR: compose files, the helper, and the backup/restore scripts.
cp -a "${REPO_SRC}/scripts/." "$APP2/scripts/"
cp -a "${REPO_SRC}/backup" "$APP2/backup"
: > "$APP2/docker-compose.yml"
sqlite3 "$DATA2/webui_data/webui.db" 'CREATE TABLE chat(id); INSERT INTO chat VALUES (1);' 2>/dev/null \
  || { mkdir -p "$DATA2/webui_data"; sqlite3 "$DATA2/webui_data/webui.db" 'CREATE TABLE chat(id); INSERT INTO chat VALUES (1);'; }
sqlite3 "$DATA2/hermes_data/state.db" 'CREATE TABLE s(k); INSERT INTO s VALUES (1);' 2>/dev/null \
  || { mkdir -p "$DATA2/hermes_data"; sqlite3 "$DATA2/hermes_data/state.db" 'CREATE TABLE s(k); INSERT INTO s VALUES (1);'; }

# Snapshot the APP_DIR contents before the split run so we can prove it is
# untouched afterwards.
APP_BEFORE="$(find "$APP2" -mindepth 1 | sort)"

: > "$LOG"
rm -rf "$CAPTURE"
RUN_RC=0
env -u BACKUP_LOG HOME="$HOME2" \
    HYBRID_AI_APP_DIR="$APP2" \
    HYBRID_AI_DATA_DIR="$DATA2" \
    HYBRID_AI_LOG_DIR="$LOG2" \
    HYBRID_AI_WORK_DIR="$WORK2" \
    BACKUP_CONF_DIR="$CONF" \
    BACKUP_NO_PAUSE=1 \
    CAPTURE_DIR="$CAPTURE" \
    PATH="$STUB:$PATH" \
  bash "$APP2/backup/backup.sh" --non-interactive > "$TMPROOT/out" 2>&1 || RUN_RC=$?
check "case g: split-layout backup exit code" 0 "$RUN_RC"
assert "case g: database staged from DATA_DIR" \
  test -f "$CAPTURE/databases/webui_data/webui.db"
assert "case g: hermes db staged from DATA_DIR" \
  test -f "$CAPTURE/databases/hermes_data/state.db"
assert "case g: backup.log written under LOG_DIR" test -f "$LOG2/backup.log"
APP_AFTER="$(find "$APP2" -mindepth 1 | sort)"
assert "case g: nothing written under APP_DIR" test "$APP_BEFORE" = "$APP_AFTER"

# restore --test reads a DEFAULT-layout snapshot (CAPTURE) and writes only
# under WORK_DIR. The restic stub lays the snapshot down at --target.
RESTORE_RC=0
env -u BACKUP_LOG HOME="$HOME2" \
    HYBRID_AI_APP_DIR="$APP2" \
    HYBRID_AI_DATA_DIR="$DATA2" \
    HYBRID_AI_LOG_DIR="$LOG2" \
    HYBRID_AI_WORK_DIR="$WORK2" \
    BACKUP_CONF_DIR="$CONF" \
    SNAPSHOT_SRC="$CAPTURE" \
    PATH="$STUB:$PATH" \
  bash "$APP2/backup/restore.sh" --test > "$TMPROOT/out" 2>&1 || RESTORE_RC=$?
check "case g: restore --test exit code" 0 "$RESTORE_RC"
assert "case g: restore log has restore_test_success" \
  bash -c "grep -q 'event=restore_test_success' '$LOG2/backup.log'"
assert "case g: restore test dir made under WORK_DIR" \
  bash -c "compgen -G '$WORK2/.restore-test-*' >/dev/null"
assert "case g: restore wrote nothing under APP_DIR" \
  bash -c "[[ \"\$(find '$APP2' -mindepth 1 | sort)\" == '$APP_BEFORE' ]]"

# ---------------------------------------------------------------------------
if [[ "$FAILURES" -ne 0 ]]; then
  echo "FAILURES: $FAILURES" >&2
  exit 1
fi
echo "All backup fixture cases passed."
exit 0
