#!/usr/bin/env bash
# shellcheck disable=SC2317  # helpers and the EXIT trap are called indirectly
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
# exact artifact that would have been uploaded.
case "$1" in
  snapshots) exit 0 ;;
  backup)
    if [[ -n "${CAPTURE_DIR:-}" && -d "${2:-}" ]]; then
      rm -rf "$CAPTURE_DIR"
      cp -a "$2" "$CAPTURE_DIR" 2>/dev/null || true
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
chmod +x "$REPO/backup/backup.sh"
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
if [[ "$FAILURES" -ne 0 ]]; then
  echo "FAILURES: $FAILURES" >&2
  exit 1
fi
echo "All backup fixture cases passed."
exit 0
