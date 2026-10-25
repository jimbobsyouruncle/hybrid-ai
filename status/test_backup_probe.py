#!/usr/bin/env python3
"""
FILE: status/test_backup_probe.py
PURPOSE (plain English):
    Offline fixture tests for status/app.py's Backups tile. No Docker, no
    network, no root: every case is a fixture log file in a scratch directory,
    and the probe's path is pointed at it through the same BACKUP_LOG_PATH
    setting the container uses.

    WHY THIS EXISTS: the tile must never lie and never crash. A host whose
    backups work but whose log the container cannot see used to be
    indistinguishable from a host that never backed up -- the bug twice
    misdiagnosed as B66. Here we pin the reader's contract: absent, unreadable
    and empty are THREE DISTINCT faults with three distinct messages, a
    non-empty log with no success line says "no successful backup recorded",
    and a fresh success is `ok` and also shows up in the Jobs tile.

    The unreadable case is a REAL permission failure, not a monkeypatched
    open(): a 0600 file owned by another uid. When the suite runs as root it
    drops privileges for that read (fork + os.setgid/os.setuid), because root
    can read anything. When it cannot drop, that ONE case prints SKIP -- never
    PASS. The CI runner is non-root, so CI must never reach SKIP.

    Proven here:
      (1) non-empty log, no event=backup_success -> warn "no successful backup
          recorded";
      (2) a recent event=backup_success (within 36h) -> ok, the detail carries
          the age, and the Jobs probe reports Backup succeeded;
      (3) an absent path -> warn "no backup log found", no exception;
      (4) a zero-byte file -> warn "backup log is empty", no exception;
      (5) a 0600 file owned by another uid -> warn "backup log not readable"
          naming permission denied, the reader's uid and the owner uid/gid;
      (6) a 0640 file whose group is ours -> the log parses normally;
      (7) the four "nothing to report" strings are pairwise distinct, and no
          OSError message equals anything the healthy path can produce.

USAGE:
    python3 status/test_backup_probe.py

EXIT CODES:
    0  every assertion passed (SKIP is printed but never counted as a pass)
    1  one or more assertions failed
"""

import importlib.util
import json
import os
import shutil
import stat
import sys
import tempfile
from datetime import datetime, timedelta, timezone

PASS = 0
FAIL = 0


def ok(msg: str) -> None:
    global PASS
    PASS += 1
    print(f"ok   {msg}")


def bad(msg: str) -> None:
    global FAIL
    FAIL += 1
    print(f"FAIL {msg}", file=sys.stderr)


def check(label: str, got, want) -> None:
    if got == want:
        ok(label)
    else:
        bad(f"{label} (want {want!r}, got {got!r})")


WORK = tempfile.mkdtemp(prefix="backup-probe-")
BACKUP_LOG = os.path.join(WORK, "backup.log")
INSTALL_LOG = os.path.join(WORK, "install.log")
os.environ["BACKUP_LOG_PATH"] = BACKUP_LOG
os.environ["INSTALL_LOG_PATH"] = INSTALL_LOG

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP_PATH = os.path.join(REPO_ROOT, "status", "app.py")

spec = importlib.util.spec_from_file_location("status_app_backup_under_test", APP_PATH)
if spec is None or spec.loader is None:
    print(f"FAIL cannot load {APP_PATH}", file=sys.stderr)
    sys.exit(1)
app = importlib.util.module_from_spec(spec)
spec.loader.exec_module(app)
if not hasattr(app, "probe_backups"):
    print("FAIL status/app.py has no probe_backups", file=sys.stderr)
    sys.exit(1)


def write(text: str) -> None:
    with open(BACKUP_LOG, "w", encoding="utf-8") as fh:
        fh.write(text)


def remove() -> None:
    if os.path.isdir(BACKUP_LOG):
        shutil.rmtree(BACKUP_LOG)
    elif os.path.exists(BACKUP_LOG):
        os.remove(BACKUP_LOG)


def shape(tile: dict) -> None:
    check("tile has the {name,state,detail,hint} shape",
          sorted(tile.keys()), ["detail", "hint", "name", "state"])
    check("tile is named 'Backups'", tile["name"], "Backups")


def ts_hours_ago(hours: int) -> str:
    when = datetime.now(timezone.utc) - timedelta(hours=hours)
    return when.strftime("%Y-%m-%dT%H:%M:%SZ")


def probe_backups_as(uid: int, gid: int):
    """Run probe_backups() in a child that has dropped to uid:gid.

    Root can read any file, so a root process can never observe the unreadable
    branch. The child writes the tile as JSON to a pipe; None means this
    process could not drop privileges and the caller must SKIP, not pass.
    """
    if os.geteuid() != 0:
        return None
    # The scratch tree is 0700 by default; the dropped child must still be able
    # to traverse it and open the file it is denied.
    os.chmod(WORK, 0o711)
    read_fd, write_fd = os.pipe()
    pid = os.fork()
    if pid == 0:  # child
        try:
            os.close(read_fd)
            os.setgroups([])
            os.setgid(gid)
            os.setuid(uid)
            payload = json.dumps(app.probe_backups()).encode()
            os.write(write_fd, payload)
            os._exit(0)
        except BaseException:
            os._exit(1)
    os.close(write_fd)
    chunks = []
    while True:
        chunk = os.read(read_fd, 65536)
        if not chunk:
            break
        chunks.append(chunk)
    os.close(read_fd)
    _, status = os.waitpid(pid, 0)
    raw = b"".join(chunks)
    if status != 0 or not raw:
        return None
    return json.loads(raw.decode())


try:
    # (1) a log with history but no success ----------------------------------
    print("== (1) non-empty log with no successful backup ==")
    write("EVENT ts=%s event=backup_failed detail=stub\n" % ts_hours_ago(2))
    tile = app.probe_backups()
    shape(tile)
    check("no success -> state warn", tile["state"], "warn")
    check("no success -> detail 'no successful backup recorded'",
          tile["detail"], "no successful backup recorded")

    # (2) a recent success -> ok, and the Jobs tile agrees -------------------
    print("\n== (2) recent event=backup_success ==")
    write("EVENT ts=%s event=backup_success detail=stub\n" % ts_hours_ago(2))
    tile = app.probe_backups()
    shape(tile)
    check("recent success -> state ok", tile["state"], "ok")
    if "last success" in tile["detail"] and "ago" in tile["detail"]:
        ok("recent success -> detail carries the age")
    else:
        bad(f"recent success -> detail has no age: {tile['detail']!r}")
    jobs = app.probe_jobs()
    backup_job = next((j for j in jobs if j.get("name") == "Backup"), None)
    if backup_job is None:
        bad("Jobs probe has no Backup entry")
    else:
        check("Jobs probe reports Backup succeeded",
              backup_job["state"], "ok")
        if "succeeded" in backup_job["detail"]:
            ok("Jobs probe detail says succeeded")
        else:
            bad(f"Jobs probe detail does not say succeeded: {backup_job['detail']!r}")

    # (3) an absent path ------------------------------------------------------
    print("\n== (3) absent backup log ==")
    remove()
    tile = app.probe_backups()
    shape(tile)
    check("absent -> state warn", tile["state"], "warn")
    # Literal expectations, not app constants: a base tree without the new
    # constants must still reach a FAIL line, never an AttributeError.
    check("absent -> detail 'no backup log found'",
          tile["detail"], "no backup log found")
    absent_detail = tile["detail"]

    # (4) a zero-byte file ----------------------------------------------------
    print("\n== (4) zero-byte backup log ==")
    write("")
    tile = app.probe_backups()
    shape(tile)
    check("zero-byte -> state warn", tile["state"], "warn")
    check("zero-byte -> detail 'backup log is empty'",
          tile["detail"], "backup log is empty")
    empty_detail = tile["detail"]

    # (5) an unreadable file: a REAL permission failure, never a monkeypatched
    # open(). Non-root reaches it with a file whose mode denies its own owner
    # read (0000). Root bypasses every mode check, so it reads in a child that
    # has already dropped to an unprivileged uid; if that fork cannot happen the
    # case prints SKIP and is never counted as a pass.
    print("\n== (5) unreadable backup log ==")
    unreadable_detail = None
    write("EVENT ts=%s event=backup_success detail=stub\n" % ts_hours_ago(2))
    if os.geteuid() != 0:
        os.chmod(BACKUP_LOG, 0o000)
        reader_uid = os.geteuid()
        tile = app.probe_backups()
    else:
        os.chmod(BACKUP_LOG, 0o600)
        reader_uid = 65534  # nobody
        tile = probe_backups_as(reader_uid, 65534)
    if tile is None:
        print("SKIP unreadable-log case: this test process could not drop "
              "privileges to read a file it does not own")
    else:
        shape(tile)
        check("unreadable -> state warn", tile["state"], "warn")
        unreadable_detail = tile["detail"]
        check("unreadable -> detail is the unreadable message",
              unreadable_detail.split(" — ", 1)[0],
              "backup log not readable")
        check("unreadable -> detail says permission denied",
              "permission denied" in unreadable_detail, True)
        check("unreadable -> detail names the reader's uid",
              f"uid {reader_uid}" in unreadable_detail, True)
        st = os.stat(BACKUP_LOG)
        check("unreadable -> detail names the file's owner uid:gid",
              f"owner {st.st_uid}:{st.st_gid}" in unreadable_detail, True)
        check("unreadable -> hint names BACKUP_GROUP_GID",
              "BACKUP_GROUP_GID" in tile["hint"], True)

    # (6) a 0640 log the group can read parses normally -----------------------
    print("\n== (6) group-readable (0640) backup log parses ==")
    remove()
    write("EVENT ts=%s event=backup_success detail=stub\n" % ts_hours_ago(2))
    os.chmod(BACKUP_LOG, 0o640)
    tile = app.probe_backups()
    shape(tile)
    check("0640 -> state ok", tile["state"], "ok")
    check("0640 -> mode is exactly 0640",
          stat.S_IMODE(os.stat(BACKUP_LOG).st_mode), 0o640)

    # (7) the strings must be pairwise distinct, and no OSError branch may
    # return anything the healthy path can produce ---------------------------
    print("\n== (7) honest failure taxonomy ==")
    no_success_detail = "no successful backup recorded"
    four = [absent_detail, empty_detail, unreadable_detail, no_success_detail]
    if unreadable_detail is None:
        four = [absent_detail, empty_detail, no_success_detail]
    check("the failure details are pairwise distinct",
          len(set(four)), len(four))
    if unreadable_detail is not None:
        check("the unreadable detail is not the absent detail",
              unreadable_detail == absent_detail, False)
        check("the unreadable detail is not the empty detail",
              unreadable_detail == empty_detail, False)
        check("the unreadable detail is not the no-success detail",
              unreadable_detail == no_success_detail, False)
    healthy = app.probe_backups()["detail"]
    check("a healthy detail never looks like a failure detail",
          any(healthy.startswith(d.split(" — ", 1)[0]) for d in four), False)
finally:
    shutil.rmtree(WORK, ignore_errors=True)

print()
if FAIL:
    print(f"{PASS} passed, {FAIL} failed", file=sys.stderr)
    sys.exit(1)
print(f"All backup probe assertions passed ({PASS}).")
sys.exit(0)
