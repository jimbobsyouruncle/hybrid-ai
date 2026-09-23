#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# FILE: openwebui/build_pipe.py
# PURPOSE (plain English):
#   Glue runpod_core.py and pipe_wrapper.py together into the single file you
#   paste into Open WebUI.
#
# WHY THIS EXISTS:
#   Open WebUI functions are pasted into a text box in the web UI, not
#   installed as Python packages. A pipe therefore cannot "import" a sibling
#   module -- there is no file next to it at runtime.
#
#   We still want the wake/validate/poll logic in its own file, so a future
#   waking shim can import it unchanged rather than duplicating it. This script
#   is the compromise: two source files for humans, one generated file for
#   Open WebUI.
#
# HOW TO RUN IT:
#   python3 openwebui/build_pipe.py            # write openwebui/runpod_pipe.py
#   python3 openwebui/build_pipe.py --check    # verify it is up to date (CI)
#
#   Run it after editing either source file, and commit the result. The --check
#   mode exits non-zero if the generated file is stale, so CI catches a
#   forgotten rebuild before it becomes a confusing production bug.
# ---------------------------------------------------------------------------
from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
CORE = HERE / "runpod_core.py"
WRAPPER = HERE / "pipe_wrapper.py"
OUTPUT = HERE / "runpod_pipe.py"

# Open WebUI parses this frontmatter for the function's name, version, and
# required Python packages. It must be the very first thing in the generated
# file. Do not delete it.
FRONTMATTER = '''"""
title: RunPod vLLM (Tailscale, on-demand)
author: hybrid-ai
version: 1.1.0
license: MIT
description: >
    Routes prompts to a vLLM server on a RunPod GPU pod over a Tailscale mesh
    address. Resumes the pod on demand, waits for the model to warm, streams
    OpenAI-compatible chunks back, and lets the pod's own idle watchdog handle
    shutdown. No prompt content is logged anywhere in this module.
requirements: httpx
"""
'''

BANNER = '''# ===========================================================================
#  GENERATED FILE -- DO NOT EDIT
#
#  Built by openwebui/build_pipe.py from:
#      openwebui/runpod_core.py     wake / validate / poll / stream
#      openwebui/pipe_wrapper.py    Open WebUI presentation layer
#
#  Edit those files and re-run:  python3 openwebui/build_pipe.py
#  Editing this file directly means your change is lost on the next build.
#
#  This concatenation exists because Open WebUI functions are pasted as a
#  single file and cannot import sibling modules.
# ===========================================================================
'''


def build() -> str:
    """Return the contents of the generated single-file pipe."""
    for path in (CORE, WRAPPER):
        if not path.exists():
            raise SystemExit(f"Missing source file: {path}")

    core = CORE.read_text(encoding="utf-8")
    wrapper = WRAPPER.read_text(encoding="utf-8")

    # The wrapper's own header explains that it is one half of a pair. Useful
    # when reading the source, confusing at the top of a generated file that
    # already carries the banner above, so drop it.
    marker = "# --- imports used only by the wrapper"
    if marker in wrapper:
        wrapper = wrapper[wrapper.index(marker):]

    return (
        FRONTMATTER
        + BANNER
        + core
        + "\n\n"
        + "# " + "-" * 73 + "\n"
        + "# OPEN WEBUI PRESENTATION LAYER  (from pipe_wrapper.py)\n"
        + "# " + "-" * 73 + "\n"
        + wrapper
    )


def main() -> int:
    generated = build()
    check_only = "--check" in sys.argv

    if check_only:
        if not OUTPUT.exists():
            print(f"FAIL: {OUTPUT.name} does not exist. Run: python3 {Path(__file__).name}")
            return 1
        if OUTPUT.read_text(encoding="utf-8") != generated:
            print(
                f"FAIL: {OUTPUT.name} is out of date with its sources.\n"
                f"      Run: python3 openwebui/{Path(__file__).name}"
            )
            return 1
        print(f"OK: {OUTPUT.name} is up to date.")
        return 0

    OUTPUT.write_text(generated, encoding="utf-8")
    print(f"Wrote {OUTPUT} ({generated.count(chr(10))} lines)")
    print("Paste this file into Open WebUI -> Workspace -> Functions -> +")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
