#!/usr/bin/env python3
"""
FILE: status/test_pod_probe.py
PURPOSE (plain English):
    Offline fixture tests for status/app.py's GPU pod tile. No Docker, no
    network, no root: socket.getaddrinfo is stubbed per case and the env is set
    per case, so each case exercises the real probe_pod() branch it names.

    The tile answers "can the pod be woken?", not "is the pod reachable?". A
    stopped pod is normal, so an unresolved MagicDNS name must never paint the
    panel fail: it reports info when a RunPod API key is configured (the pod can
    be woken) and warn when none is (it cannot).

    Proven here:
      (a) name set, getaddrinfo raises OSError, RUNPOD_KEY_PRESENT=1 -> info,
          hint names --wake-runpod;
      (b) same but RUNPOD_KEY_PRESENT empty -> warn, and never fail;
      (c) getaddrinfo resolves an address outside [IP_ADDRESS]/10 -> fail with
          the existing out-of-mesh hint;
      (d) RUNPOD_HOST unset -> warn;
      (e) every tile has exactly the {name, state, detail, hint} shape, and
          neither detail nor hint leaks the host name or any IP address.

    Against the unpatched status/app.py this harness fails: cases (a) and (b)
    both returned fail there, and the unpatched module had no RUNPOD_KEY_PRESENT
    read at all.

USAGE:
    python3 status/test_pod_probe.py

EXIT CODES:
    0  every assertion passed
    1  one or more assertions failed
"""

import importlib.util
import os
import re
import socket
import sys

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


REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP_PATH = os.path.join(REPO_ROOT, "status", "app.py")

HOST_NAME = "pod-abc.tailnet.ts.net"
IP_RE = re.compile(r"\d{1,3}(\.\d{1,3}){3}")


def load_app():
    """Fresh import each call: app.py reads env at import time."""
    spec = importlib.util.spec_from_file_location("status_app_pod_under_test", APP_PATH)
    if spec is None or spec.loader is None:
        print(f"FAIL cannot load {APP_PATH}", file=sys.stderr)
        sys.exit(1)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def set_env(host, key_present):
    if host is None:
        os.environ.pop("RUNPOD_HOST", None)
    else:
        os.environ["RUNPOD_HOST"] = host
    if key_present is None:
        os.environ.pop("RUNPOD_KEY_PRESENT", None)
    else:
        os.environ["RUNPOD_KEY_PRESENT"] = key_present


def stub_getaddrinfo(behavior):
    """behavior: 'raise' or a string address to resolve."""
    def fake(*args, **kwargs):
        if behavior == "raise":
            raise OSError("Name or service not known")
        return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", (behavior, 0))]
    socket.getaddrinfo = fake


def shape(tile):
    check("tile has exactly the {name,state,detail,hint} shape",
          sorted(tile.keys()), ["detail", "hint", "name", "state"])
    check("tile is named 'GPU pod'", tile["name"], "GPU pod")


def no_leak(label, tile):
    # Never echo the value: RUNPOD_HOST is masked in all output, including CI.
    blob = f"{tile['detail']} {tile['hint']}"
    if HOST_NAME in blob:
        bad(f"{label}: the MagicDNS host name leaked into detail/hint")
    else:
        ok(f"{label}: host name absent from detail/hint")
    if IP_RE.search(blob):
        bad(f"{label}: an IP address leaked into detail/hint")
    else:
        ok(f"{label}: no IP address in detail/hint")


try:
    # (a) stopped pod, key present -> info -----------------------------------
    print("== (a) unresolved name, RUNPOD_KEY_PRESENT=1 ==")
    set_env(HOST_NAME, "1")
    stub_getaddrinfo("raise")
    app = load_app()
    check("RUNPOD_KEY_PRESENT read as a presence flag",
          getattr(app, "RUNPOD_KEY_PRESENT", "<missing>"), "1")
    tile = app.probe_pod()
    shape(tile)
    check("(a) unresolved + key -> state info", tile["state"], "info")
    if "--wake-runpod" in tile["hint"]:
        ok("(a) hint names --wake-runpod")
    else:
        bad(f"(a) hint does not name --wake-runpod: {tile['hint']!r}")
    no_leak("(a)", tile)

    # (b) stopped pod, no key -> warn, never fail ----------------------------
    print("\n== (b) unresolved name, RUNPOD_KEY_PRESENT unset ==")
    set_env(HOST_NAME, None)
    stub_getaddrinfo("raise")
    app = load_app()
    tile = app.probe_pod()
    shape(tile)
    check("(b) unresolved + no key -> state warn", tile["state"], "warn")
    if tile["state"] != "fail":
        ok("(b) state is never fail")
    else:
        bad("(b) state is fail")
    no_leak("(b)", tile)

    # (c) resolved outside the mesh -> fail ----------------------------------
    print("\n== (c) resolved address outside [IP_ADDRESS]/10 ==")
    set_env(HOST_NAME, "1")
    stub_getaddrinfo("10.0.0.5")
    app = load_app()
    tile = app.probe_pod()
    shape(tile)
    check("(c) out-of-mesh address -> state fail", tile["state"], "fail")
    if "The pipe will refuse to send prompts" in tile["hint"]:
        ok("(c) hint is the existing out-of-mesh hint")
    else:
        bad(f"(c) unexpected hint: {tile['hint']!r}")
    no_leak("(c)", tile)

    # (d) host unset -> warn -------------------------------------------------
    print("\n== (d) RUNPOD_HOST unset ==")
    set_env(None, "1")
    stub_getaddrinfo("raise")
    app = load_app()
    tile = app.probe_pod()
    shape(tile)
    check("(d) host unset -> state warn", tile["state"], "warn")
    no_leak("(d)", tile)

finally:
    pass

print(f"\n{PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
