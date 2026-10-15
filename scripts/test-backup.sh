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
#   g) a SPLIT app/data/log/work layout backs up and restores with relocation
#   h) an uncapturable hermes_data DB with BACKUP_ALLOW_AGENT_STOP unset: the
#      cold copy declines to stop hermes-agent, exits 3, stops nothing
#   i) the same with BACKUP_ALLOW_AGENT_STOP=1: hermes-agent IS stopped, the
#      cold copy still cannot capture the DB, cold_copy_failed, exit 3
#   j) an uncapturable webui_data DB: only open-webui is stopped, exit 3
#   k) a cold-copy stop failure: no backup_failed, exit 3
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
DOCKER_LOG="$TMPROOT/docker.log"
mkdir -p "$STUB"
: > "$SQLITE_LOG"
: > "$DOCKER_LOG"

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

cat > "$STUB/docker" <<EOF
#!/usr/bin/env bash
# Log every invocation (argv) so a case can assert exactly which containers
# were stopped. When DOCKER_FAIL_STOP names a container, a 'stop' of it fails.
printf '%s\n' "\$*" >> '${DOCKER_LOG}'
case "\$1" in
  inspect) echo running; exit 0 ;;   # every container reports "running"
  stop)
    if [[ -n "\${DOCKER_FAIL_STOP:-}" && "\${2:-}" == "\$DOCKER_FAIL_STOP" ]]; then
      exit 1
    fi
    exit 0 ;;
  pause|unpause|start|exec|version) exit 0 ;;
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
# A path containing the marker (default 'boom.db') is uncapturable: every
# invocation for it fails. This simulates a database no capture path can read,
# without relying on file permissions (CI runs the suite as a non-root user
# too). SQLITE_FAIL_MARKER lets a case target a fixed path such as the Open
# WebUI database, which is not discovered by name.
marker="\${SQLITE_FAIL_MARKER:-boom.db}"
for a in "\$@"; do
  case "\$a" in
    *"\$marker"*) exit 1 ;;
  esac
done
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
export BACKUP_CONF_DIR="$CONF" BACKUP_LOG="$LOG" HOME="$REPO/home" SQLITE_LOG DOCKER_LOG
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
  : > "$DOCKER_LOG"
  rm -rf "$CAPTURE"
  RUN_RC=0
  bash "$BACKUP" --non-interactive > "$TMPROOT/out" 2>&1 || RUN_RC=$?
}

# Run backup.sh with extra arguments and a caller-supplied environment. Used by
# the stage/upload/external-mode cases below. Does NOT touch CAPTURE_DIR.
run_backup_env() {  # run_backup_env <env K=V...> -- <backup args...>
  local -a envs=() args=()
  local seen_sep=0
  for a in "$@"; do
    if [[ "$a" == "--" ]]; then seen_sep=1; continue; fi
    if (( seen_sep )); then args+=("$a"); else envs+=("$a"); fi
  done
  : > "$LOG"
  : > "$DOCKER_LOG"
  RUN_RC=0
  env "${envs[@]}" bash "$BACKUP" "${args[@]}" > "$TMPROOT/out" 2>&1 || RUN_RC=$?
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
docker_log_has()   { grep -qF -- "stop $1" "$DOCKER_LOG"; }
docker_log_lacks() { ! grep -qF -- "stop $1" "$DOCKER_LOG"; }

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
  assert "case c: no container was stopped"        bash -c "! grep -q '^stop ' '$DOCKER_LOG'"
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
# Case h: a hermes_data database cannot be captured and BACKUP_ALLOW_AGENT_STOP
# is unset. The cold copy must DECLINE to stop hermes-agent, leave that database
# out of the snapshot, keep every other database, and exit 3 -- never 1.
# ---------------------------------------------------------------------------
rm -rf "$REPO/hermes_data"; mkdir -p "$REPO/hermes_data"
sqlite3 "$REPO/hermes_data/keep.db" 'CREATE TABLE t(a); INSERT INTO t VALUES (1);'
printf 'SQLite format 3\0' > "$REPO/hermes_data/boom.db"
rm -f "$REPO/webui_data/webui.db"; mkdir -p "$REPO/webui_data"
sqlite3 "$REPO/webui_data/webui.db" 'CREATE TABLE chat(id); INSERT INTO chat VALUES (1);'
unset BACKUP_ALLOW_AGENT_STOP
run_backup "case-h"
check "case h: incomplete exit code" 3 "$RUN_RC"
assert "case h: NO backup_failed"              log_lacks 'backup_failed'
assert "case h: backup_incomplete logged"      log_has 'backup_incomplete'
assert "case h: cold_copy_agent_stop_declined" log_has 'cold_copy_agent_stop_declined'
assert "case h: hermes-agent NOT stopped"      docker_log_lacks 'hermes-agent'
assert "case h: boom.db not staged"            bash -c "[[ ! -e '$CAPTURE/databases/hermes_data/boom.db' ]]"
assert "case h: other hermes db still staged"  bash -c "[[ -f '$CAPTURE/databases/hermes_data/keep.db' ]]"
assert "case h: webui db still staged"         bash -c "[[ -f '$CAPTURE/databases/webui_data/webui.db' ]]"

# ---------------------------------------------------------------------------
# Case i: the same, but BACKUP_ALLOW_AGENT_STOP=1. The cold copy MAY stop
# hermes-agent, but the database still cannot be captured cold, so it fails
# (cold_copy_failed) and the run still exits 3 -- never 1.
# ---------------------------------------------------------------------------
unset BACKUP_ALLOW_AGENT_STOP
export BACKUP_ALLOW_AGENT_STOP=1
run_backup "case-i"
unset BACKUP_ALLOW_AGENT_STOP
check "case i: incomplete exit code" 3 "$RUN_RC"
assert "case i: hermes-agent IS stopped"      docker_log_has 'hermes-agent'
assert "case i: cold_copy_failed logged"      log_has 'cold_copy_failed'
assert "case i: NO backup_failed"             log_lacks 'backup_failed'
assert "case i: boom.db not staged"           bash -c "[[ ! -e '$CAPTURE/databases/hermes_data/boom.db' ]]"

# ---------------------------------------------------------------------------
# Case j: a webui_data database cannot be captured. Only open-webui may be
# stopped; hermes-agent must be left alone. Exit 3.
# ---------------------------------------------------------------------------
rm -rf "$REPO/hermes_data"; mkdir -p "$REPO/hermes_data"
sqlite3 "$REPO/hermes_data/state.db" 'CREATE TABLE s(k); INSERT INTO s VALUES (1);'
export SQLITE_FAIL_MARKER=webui.db
run_backup "case-j"
unset SQLITE_FAIL_MARKER
check "case j: incomplete exit code" 3 "$RUN_RC"
assert "case j: open-webui IS stopped"    docker_log_has 'open-webui'
assert "case j: hermes-agent NOT stopped" docker_log_lacks 'hermes-agent'
assert "case j: NO backup_failed"         log_lacks 'backup_failed'

# ---------------------------------------------------------------------------
# Case k: stopping open-webui fails. The cold copy is skipped (nothing may be
# copied while the database is still written) and the run is INCOMPLETE, not a
# failure. Exit 3, no backup_failed.
# ---------------------------------------------------------------------------
export SQLITE_FAIL_MARKER=webui.db
export DOCKER_FAIL_STOP=open-webui
run_backup "case-k"
unset SQLITE_FAIL_MARKER DOCKER_FAIL_STOP
check "case k: incomplete exit code" 3 "$RUN_RC"
assert "case k: NO backup_failed"                          log_lacks 'backup_failed'
assert "case k: backup_incomplete logged"                  log_has 'backup_incomplete'
assert "case k: stop failure recorded as incomplete reason" bash -c "grep -q 'cold_copy_stop_failed:open-webui' '$LOG'"
assert "case k: webui db not staged"                       bash -c "[[ ! -e '$CAPTURE/databases/webui_data/webui.db' ]]"

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
# Cases l-p: the stage/upload split (system-mode units call these flags).
# Everything stays offline: an empty CONF proves --stage-only loads no
# credentials, and the restic stub stands in for the network.
# ---------------------------------------------------------------------------
STAGE_WORK="$TMPROOT/stage-work"; mkdir -p "$STAGE_WORK"
STAGE="$STAGE_WORK/.backup-staging"
EMPTYCONF="$TMPROOT/emptyconf"; mkdir -p "$EMPTYCONF"

# Case l: --stage-only KEEPS the staging directory, writes STATUS complete,
# loads NO credentials (CONF points at an empty dir) and exits 0.
rm -rf "$REPO/hermes_data" "$STAGE"; mkdir -p "$REPO/hermes_data"
sqlite3 "$REPO/webui_data/webui.db" 'CREATE TABLE chat(id); INSERT INTO chat VALUES (1);'
sqlite3 "$REPO/hermes_data/state.db" 'CREATE TABLE s(k); INSERT INTO s VALUES (1);'
run_backup_env BACKUP_CONF_DIR="$EMPTYCONF" HYBRID_AI_WORK_DIR="$STAGE_WORK" BACKUP_NO_PAUSE=1 -- --non-interactive --stage-only
check "case l: --stage-only exit code" 0 "$RUN_RC"
assert "case l: staging directory kept"        test -d "$STAGE"
assert "case l: STATUS file written"           test -f "$STAGE/STATUS"
assert "case l: STATUS is complete"            bash -c "grep -qx 'status=complete' '$STAGE/STATUS'"
assert "case l: STATUS has a consistency word" bash -c "grep -qE '^consistency=(paused|online|cold)$' '$STAGE/STATUS'"
assert "case l: stage-only loaded no credentials" bash -c "! grep -q 'No credentials' '$TMPROOT/out'"

# Case m: --stage-only with an uncapturable db leaves the run INCOMPLETE: STATUS
# says incomplete with a fixed reason code, and the exit is 3 (never 1).
rm -rf "$REPO/hermes_data" "$STAGE"; mkdir -p "$REPO/hermes_data"
sqlite3 "$REPO/hermes_data/keep.db" 'CREATE TABLE t(a); INSERT INTO t VALUES (1);'
printf 'SQLite format 3\0' > "$REPO/hermes_data/boom.db"
run_backup_env BACKUP_CONF_DIR="$EMPTYCONF" HYBRID_AI_WORK_DIR="$STAGE_WORK" BACKUP_NO_PAUSE=1 -- --non-interactive --stage-only
check "case m: incomplete --stage-only exit code" 3 "$RUN_RC"
assert "case m: staging kept"                       test -d "$STAGE"
assert "case m: STATUS is incomplete"               bash -c "grep -qx 'status=incomplete' '$STAGE/STATUS'"
assert "case m: STATUS carries a fixed reason code" bash -c "grep -qE '^reason=[A-Za-z_]+[:A-Za-z_]*$' '$STAGE/STATUS'"
assert "case m: raw db name never in STATUS"        bash -c "! grep -q 'boom' '$STAGE/STATUS'"

# Case n: --upload-only refuses when the staging directory / STATUS is missing.
rm -rf "$STAGE"
run_backup_env BACKUP_CONF_DIR="$CONF" HYBRID_AI_WORK_DIR="$STAGE_WORK" -- --non-interactive --upload-only
check "case n: --upload-only refuses without staging" 1 "$RUN_RC"
assert "case n: refusal names the missing staging" bash -c "grep -qi 'staging' '$TMPROOT/out'"

# Case n2: staging exists but STATUS is missing -- also refused.
rm -rf "$STAGE"; mkdir -p "$STAGE"
run_backup_env BACKUP_CONF_DIR="$CONF" HYBRID_AI_WORK_DIR="$STAGE_WORK" -- --non-interactive --upload-only
check "case n2: --upload-only refuses without STATUS" 1 "$RUN_RC"
assert "case n2: refusal names the missing STATUS" bash -c "grep -qi 'STATUS' '$TMPROOT/out'"

# Case o: a complete --stage-only run followed by --upload-only: the upload
# succeeds, the staging directory is removed, and the exit is 0.
rm -rf "$REPO/hermes_data" "$STAGE"; mkdir -p "$REPO/hermes_data"
sqlite3 "$REPO/hermes_data/state.db" 'CREATE TABLE s(k); INSERT INTO s VALUES (1);'
run_backup_env BACKUP_CONF_DIR="$EMPTYCONF" HYBRID_AI_WORK_DIR="$STAGE_WORK" BACKUP_NO_PAUSE=1 -- --non-interactive --stage-only
check "case o: stage complete" 0 "$RUN_RC"
assert "case o: staging present before upload" test -d "$STAGE"
run_backup_env BACKUP_CONF_DIR="$CONF" HYBRID_AI_WORK_DIR="$STAGE_WORK" -- --non-interactive --upload-only
check "case o: --upload-only exit code" 0 "$RUN_RC"
assert "case o: staging REMOVED after successful upload" bash -c "[[ ! -d '$STAGE' ]]"
assert "case o: complete:true tag used"  log_has 'backup_success'

# Case p: --upload-only of an INCOMPLETE capture still uploads but exits 3, and
# the snapshot is tagged complete:false.
rm -rf "$REPO/hermes_data" "$STAGE"; mkdir -p "$REPO/hermes_data"
sqlite3 "$REPO/hermes_data/keep.db" 'CREATE TABLE t(a); INSERT INTO t VALUES (1);'
printf 'SQLite format 3\0' > "$REPO/hermes_data/boom.db"
run_backup_env BACKUP_CONF_DIR="$EMPTYCONF" HYBRID_AI_WORK_DIR="$STAGE_WORK" BACKUP_NO_PAUSE=1 -- --non-interactive --stage-only
check "case p: stage incomplete exit code" 3 "$RUN_RC"
run_backup_env BACKUP_CONF_DIR="$CONF" HYBRID_AI_WORK_DIR="$STAGE_WORK" -- --non-interactive --upload-only
check "case p: --upload-only incomplete exit code" 3 "$RUN_RC"
assert "case p: staging removed after upload" bash -c "[[ ! -d '$STAGE' ]]"
assert "case p: backup_incomplete emitted"    log_has 'backup_incomplete'

# ---------------------------------------------------------------------------
# Case q: CREDENTIALS_DIRECTORY. When systemd sets it, backup.sh reads r2.env
# and repo-password from there and NOT from BACKUP_CONF_DIR.
# ---------------------------------------------------------------------------
CRED="$TMPROOT/cred"; mkdir -p "$CRED"
cp "$CONF/r2.env" "$CRED/r2.env"; chmod 600 "$CRED/r2.env"
cp "$CONF/repo-password" "$CRED/repo-password"; chmod 600 "$CRED/repo-password"
rm -rf "$REPO/hermes_data"; mkdir -p "$REPO/hermes_data"
sqlite3 "$REPO/hermes_data/state.db" 'CREATE TABLE s(k); INSERT INTO s VALUES (1);'
run_backup_env BACKUP_CONF_DIR="$EMPTYCONF" CREDENTIALS_DIRECTORY="$CRED" BACKUP_NO_PAUSE=1 -- --non-interactive
check "case q: credentials-directory run exit code" 0 "$RUN_RC"
assert "case q: credentials read from CREDENTIALS_DIRECTORY" log_has 'backup_success'

# ---------------------------------------------------------------------------
# Case r: BACKUP_CONTAINER_CONTROL=external. backup.sh must issue NO docker
# command at all; it reads the paused list and host facts from the runtime dir.
# ---------------------------------------------------------------------------
CONTROL_RUN="$TMPROOT/control-run"; mkdir -p "$CONTROL_RUN/host-info"
printf 'open-webui\nhermes-agent\n' > "$CONTROL_RUN/paused"
chmod 600 "$CONTROL_RUN/paused"
printf '27.0.0\n' > "$CONTROL_RUN/host-info/platform-docker.txt"
printf 'llama3:latest\n' > "$CONTROL_RUN/host-info/ollama-models.txt"
rm -rf "$REPO/hermes_data" "$STAGE"; mkdir -p "$REPO/hermes_data"
sqlite3 "$REPO/hermes_data/state.db" 'CREATE TABLE s(k); INSERT INTO s VALUES (1);'
run_backup_env BACKUP_CONF_DIR="$EMPTYCONF" HYBRID_AI_WORK_DIR="$STAGE_WORK" BACKUP_CONTAINER_CONTROL=external BACKUP_CONTROL_RUN_DIR="$CONTROL_RUN" -- --non-interactive --stage-only
check "case r: external-control --stage-only exit code" 0 "$RUN_RC"
assert "case r: NO docker command was called in external mode" bash -c "[[ ! -s '$DOCKER_LOG' ]]"
assert "case r: CONSISTENCY is paused from the runtime file" bash -c "grep -qx 'consistency=paused' '$STAGE/STATUS'"
assert "case r: host facts copied into staging/host" bash -c "[[ -f '$STAGE/host/platform-docker.txt' ]]"
assert "case r: docker version came from the helper file" bash -c "grep -qx 'docker=27.0.0' '$STAGE/host/platform.txt'"

# ---------------------------------------------------------------------------
if [[ "$FAILURES" -ne 0 ]]; then
  echo "FAILURES: $FAILURES" >&2
  exit 1
fi
echo "All backup fixture cases passed."
exit 0
