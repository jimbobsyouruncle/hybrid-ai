#!/usr/bin/env python3
"""
FILE: status/test_deploy_verification.py
PURPOSE (plain English):
    Offline fixture tests for status/app.py's Deploy verification tile. No
    Docker, no network, no root: every case is a fixture log file in a scratch
    directory, and the probe's path is pointed at it through the same
    POST_DEPLOY_VERIFY_LOG_PATH setting the container uses.

    The tile answers "is the host on the verified revision?" at a glance. It
    parses the LAST `waiting for <sha> at <ts>` line and the verdict line that
    follows it (`PASS`, `FAIL: <detail>` or `TIMEOUT: <detail>`), the same
    semantics doctor.sh uses. It must never crash: an absent, empty,
    directory-shaped, unreadable, unparseable or still-running log degrades to
    `warn` with a clear detail.

    Proven here:
      (1) PASS          -> ok, naming the short sha and the timestamp;
      (2) FAIL: <detail> -> fail, quoting the verdict and the hint command;
      (3) TIMEOUT:<det> -> fail;
      (4) the LAST run wins (a later FAIL overrides an earlier PASS);
      (5) a verdict from one run is never carried into a later waiting block;
      (6) absent file    -> warn, "no verdict recorded yet";
      (7) 0-byte file    -> warn;
      (8) directory path -> warn (Docker makes one for a missing bind source);
      (9) unreadable     -> warn "unreadable by the status container" (skipped
          only when running as root, where the mode bit does not stop a read);
     (10) no parseable waiting line -> warn, never a silent pass;
     (11) a credential-shaped verdict detail is redacted before display;
     (12) every case returns the {name, state, detail, hint} tile shape.

    Against the unpatched status/app.py there is no probe_deploy_verification at
    all, so this harness cannot even import it and fails immediately.

USAGE:
    python3 status/test_deploy_verification.py

EXIT CODES:
    0  every assertion passed
    1  one or more assertions failed
"""

import importlib.util
import os
import shutil
import sys
import tempfile

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


WORK = tempfile.mkdtemp(prefix="deploy-verify-probe-")
LOG = os.path.join(WORK, "post-deploy-verify.log")
os.environ["POST_DEPLOY_VERIFY_LOG_PATH"] = LOG

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP_PATH = os.path.join(REPO_ROOT, "status", "app.py")

spec = importlib.util.spec_from_file_location("status_app_under_test", APP_PATH)
if spec is None or spec.loader is None:
    print(f"FAIL cannot load {APP_PATH}", file=sys.stderr)
    sys.exit(1)
app = importlib.util.module_from_spec(spec)
spec.loader.exec_module(app)
if not hasattr(app, "probe_deploy_verification"):
    print("FAIL status/app.py has no probe_deploy_verification", file=sys.stderr)
    sys.exit(1)


def write(text: str) -> None:
    with open(LOG, "w", encoding="utf-8") as fh:
        fh.write(text)


def remove() -> None:
    if os.path.isdir(LOG):
        shutil.rmtree(LOG)
    elif os.path.exists(LOG):
        os.remove(LOG)


def shape(tile: dict) -> None:
    check("tile has the {name,state,detail,hint} shape",
          sorted(tile.keys()), ["detail", "hint", "name", "state"])
    check("tile is named 'Deploy verification'", tile["name"], "Deploy verification")


SHA_PASS = "1234567890abcdef1234567890abcdef12345678"
SHA_FAIL = "abcdef1234567890abcdef1234567890abcdef12"
SHA_TIMEOUT = "fedcba0987654321fedcba0987654321fedcba09"
TS = "2026-01-02T03:04:05Z"
SHORT_PASS = SHA_PASS[:12]
SHORT_FAIL = SHA_FAIL[:12]

try:
    # (1) PASS -> ok naming the short sha and the timestamp ------------------
    print("== (1) PASS verdict ==")
    write(f"waiting for {SHA_PASS} at {TS}\nPASS\n")
    tile = app.probe_deploy_verification()
    shape(tile)
    check("PASS -> state ok", tile["state"], "ok")
    if SHORT_PASS in tile["detail"] and TS in tile["detail"]:
        ok("PASS -> detail names the short sha and the timestamp")
    else:
        bad(f"PASS -> detail missing short sha/timestamp: {tile['detail']!r}")

    # (2) FAIL -> fail quoting the verdict -----------------------------------
    print("\n== (2) FAIL verdict ==")
    write(f"waiting for {SHA_FAIL} at {TS}\nFAIL: run 9 conclusion failure\n")
    tile = app.probe_deploy_verification()
    shape(tile)
    check("FAIL -> state fail", tile["state"], "fail")
    if "FAIL: run 9 conclusion failure" in tile["detail"] and SHORT_FAIL in tile["detail"]:
        ok("FAIL -> detail quotes the verdict and the short sha")
    else:
        bad(f"FAIL -> detail does not quote the verdict/sha: {tile['detail']!r}")
    if "hybrid-ai-post-deploy-verify" in tile["hint"]:
        ok("FAIL -> hint names the verifier units")
    else:
        bad(f"FAIL -> hint does not name the verifier units: {tile['hint']!r}")

    # (3) TIMEOUT -> fail ----------------------------------------------------
    print("\n== (3) TIMEOUT verdict ==")
    write(f"waiting for {SHA_TIMEOUT} at {TS}\nTIMEOUT: no completed run after 60 minutes\n")
    tile = app.probe_deploy_verification()
    shape(tile)
    check("TIMEOUT -> state fail", tile["state"], "fail")
    if "TIMEOUT:" in tile["detail"]:
        ok("TIMEOUT -> detail quotes the verdict")
    else:
        bad(f"TIMEOUT -> detail does not quote the verdict: {tile['detail']!r}")

    # (4) the LAST run wins --------------------------------------------------
    print("\n== (4) the last run wins ==")
    write(f"waiting for {SHA_PASS} at {TS}\nPASS\n"
          f"waiting for {SHA_FAIL} at {TS}\nFAIL: run 9 conclusion failure\n")
    tile = app.probe_deploy_verification()
    check("last run wins -> state fail", tile["state"], "fail")
    if SHORT_FAIL in tile["detail"]:
        ok("last run wins -> detail names the LAST sha")
    else:
        bad(f"last run wins -> detail names the wrong sha: {tile['detail']!r}")

    # (5) a verdict is never carried into a later waiting block --------------
    print("\n== (5) verdict never carried into a later block ==")
    write(f"waiting for {SHA_PASS} at {TS}\nPASS\n"
          f"waiting for {SHA_FAIL} at {TS}\n")
    tile = app.probe_deploy_verification()
    check("no verdict for the last run -> state warn", tile["state"], "warn")
    if "PASS" not in tile["detail"]:
        ok("no verdict for the last run -> the earlier PASS is not reused")
    else:
        bad(f"no verdict for the last run -> reused the earlier PASS: {tile['detail']!r}")

    # (6) absent file --------------------------------------------------------
    print("\n== (6) absent file ==")
    remove()
    tile = app.probe_deploy_verification()
    shape(tile)
    check("absent -> state warn", tile["state"], "warn")
    check("absent -> detail names the cause", tile["detail"], "no verdict recorded yet")

    # (7) 0-byte file --------------------------------------------------------
    print("\n== (7) empty file ==")
    write("")
    tile = app.probe_deploy_verification()
    check("empty -> state warn", tile["state"], "warn")
    if "empty" in tile["detail"]:
        ok("empty -> detail says the log is empty")
    else:
        bad(f"empty -> detail does not say empty: {tile['detail']!r}")

    # (8) directory path (Docker's shape for a missing bind source) ----------
    print("\n== (8) directory path ==")
    remove()
    os.makedirs(LOG)
    tile = app.probe_deploy_verification()
    check("directory -> state warn", tile["state"], "warn")
    if "directory" in tile["detail"]:
        ok("directory -> detail names the directory shape")
    else:
        bad(f"directory -> detail does not name the directory: {tile['detail']!r}")

    # (9) unreadable file ----------------------------------------------------
    print("\n== (9) unreadable file ==")
    remove()
    write(f"waiting for {SHA_PASS} at {TS}\nPASS\n")
    os.chmod(LOG, 0o000)
    if os.geteuid() == 0:
        print("ok   skip unreadable-file case (running as root, mode bit cannot deny a read)")
    else:
        tile = app.probe_deploy_verification()
        check("unreadable -> state warn", tile["state"], "warn")
        if "unreadable" in tile["detail"]:
            ok("unreadable -> detail says unreadable by the status container")
        else:
            bad(f"unreadable -> detail does not say unreadable: {tile['detail']!r}")
    os.chmod(LOG, 0o600)
    remove()

    # (10) no parseable waiting line -----------------------------------------
    print("\n== (10) no parseable waiting line ==")
    write("this is not a waiting line\nnor is this\n")
    tile = app.probe_deploy_verification()
    check("garbage -> state warn", tile["state"], "warn")
    if "waiting for" in tile["detail"]:
        ok("garbage -> detail names the missing waiting line")
    else:
        bad(f"garbage -> detail does not name the waiting line: {tile['detail']!r}")

    # (11) redaction ---------------------------------------------------------
    print("\n== (11) redaction ==")
    leak = "ghp_" + "A" * 30
    write(f"waiting for {SHA_FAIL} at {TS}\nFAIL: token {leak} leaked\n")
    tile = app.probe_deploy_verification()
    if leak not in tile["detail"]:
        ok("redaction -> the raw credential-shaped detail is not emitted")
    else:
        bad("redaction -> a credential-shaped detail reached the tile")
    if "REDACTED" in tile["detail"]:
        ok("redaction -> the redaction marker is present")
    else:
        bad(f"redaction -> no redaction marker in: {tile['detail']!r}")

    # (12) never a crash on a control-character verdict ----------------------
    print("\n== (12) control characters do not crash the probe ==")
    write(f"waiting for {SHA_PASS} at {TS}\nP\x00A\x01S\x02S\n")
    tile = app.probe_deploy_verification()
    shape(tile)
    ok("a control-laced verdict line returns a tile instead of raising")
finally:
    shutil.rmtree(WORK, ignore_errors=True)

print()
if FAIL:
    print(f"{PASS} passed, {FAIL} failed", file=sys.stderr)
    sys.exit(1)
print(f"All deploy-verification probe assertions passed ({PASS}).")
sys.exit(0)