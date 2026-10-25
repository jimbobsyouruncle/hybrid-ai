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
    indistinguishable from a host that never backed up -- that is the bug this
    change fixes on the compose side. Here we pin the reader's side of the
    contract: an absent, empty or unreadable log degrades to `warn` "no backup
    log found" instead of raising, a non-empty log with no success line says
    "no successful backup recorded", and a fresh success is `ok` and also
    shows up in the Jobs tile.

    Proven here:
      (1) non-empty log, no event=backup_success -> warn "no successful backup
          recorded";
      (2) a recent event=backup_success (within 36h) -> ok, the detail carries
          the age, and the Jobs probe reports Backup succeeded;
      (3) an absent path -> warn "no backup log found", no exception;
      (4) a zero-byte file -> warn "no backup log found", no exception;
      (5) an unreadable file -> warn "no backup log found", never a crash.

USAGE:
    python3 status/test_backup_probe.py

EXIT CODES:
    0  every assertion passed
    1  one or more assertions failed
"""

import builtins
import importlib.util
import os
import shutil
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
    check("absent -> detail 'no backup log found'",
          tile["detail"], "no backup log found")

    # (4) a zero-byte file ----------------------------------------------------
    print("\n== (4) zero-byte backup log ==")
    write("")
    tile = app.probe_backups()
    shape(tile)
    check("zero-byte -> state warn", tile["state"], "warn")
    check("zero-byte -> detail 'no backup log found'",
          tile["detail"], "no backup log found")

    # (5) an unreadable file --------------------------------------------------
    print("\n== (5) unreadable backup log ==")
    write("EVENT ts=%s event=backup_success detail=stub\n" % ts_hours_ago(2))
    real_open = builtins.open

    def deny_backup(path, *args, **kwargs):
        if path == BACKUP_LOG:
            raise PermissionError(13, "Permission denied", path)
        return real_open(path, *args, **kwargs)

    builtins.open = deny_backup
    try:
        tile = app.probe_backups()
    finally:
        builtins.open = real_open
    shape(tile)
    check("unreadable -> state warn", tile["state"], "warn")
    check("unreadable -> detail 'no backup log found'",
          tile["detail"], "no backup log found")
finally:
    shutil.rmtree(WORK, ignore_errors=True)

print()
if FAIL:
    print(f"{PASS} passed, {FAIL} failed", file=sys.stderr)
    sys.exit(1)
print(f"All backup probe assertions passed ({PASS}).")
sys.exit(0)
