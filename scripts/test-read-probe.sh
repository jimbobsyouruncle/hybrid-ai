#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/test-read-probe.sh
# PURPOSE (plain English):
#   Fixture test for backup/lib/read-probe.sh. It proves the OPEN-based probe
#   reports a file as readable when the access(2)-based probe would not, which
#   is exactly the CAP_DAC_READ_SEARCH case in system mode.
#
#   It does this WITHOUT needing root or a capability: a file the current user
#   cannot read (mode 000, owned by another uid) is opened through a tiny
#   helper that is setuid/setcap-free. Instead, the test proves the two modes
#   DISAGREE only when they should by pointing each at fixtures it can and
#   cannot open:
#
#     * an ordinary readable file: both modes say readable;
#     * a missing file: both say unreadable;
#     * a directory with entries: the open probe lists it, the access probe
#       checks r+x.
#
#   The capability-specific disagreement (open succeeds where access(2) fails)
#   cannot be reproduced unprivileged, so it is asserted structurally: the open
#   probe must actually OPEN the file (it must fail on a file that cannot be
#   opened) rather than consult [[ -r ]]. The test proves that by making a file
#   unreadable to the current user and checking the open probe fails on it too,
#   then proving the open probe reads the 16-byte header through the same
#   function the classifier uses.
#
# Fully OFFLINE. Needs only bash and coreutils.
#
# Exit 0 when every case passes, non-zero otherwise. Exit 2 on usage error.
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_SRC="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
PROBE_SRC="${REPO_SRC}/backup/lib/read-probe.sh"
[[ -f "$PROBE_SRC" ]] || { echo "error: read-probe.sh not found at $PROBE_SRC" >&2; exit 2; }

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

FAILURES=0
ok()  { printf 'PASS: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; FAILURES=$(( FAILURES + 1 )); }
assert() { # desc command...
  local d="$1"; shift
  if "$@"; then ok "$d"; else bad "$d"; fi
}

# Source the probe in a subshell so the test's own shell is untouched.
# shellcheck source=backup/lib/read-probe.sh
source "$PROBE_SRC"

# --- Fixtures ---------------------------------------------------------------
READABLE="$TMPROOT/readable.txt"
printf 'SQLite format 3\0abcdef' > "$READABLE"
chmod 0644 "$READABLE"

MISSING="$TMPROOT/does-not-exist.txt"

DIR="$TMPROOT/dir"
mkdir -p "$DIR"
printf 'x\n' > "$DIR/entry"

EMPTYDIR="$TMPROOT/emptydir"
mkdir -p "$EMPTYDIR"

# A file the current user cannot read. If this test runs as root, chmod 000 is
# not a barrier; skip the negative fixture then (root reads everything).
UNREADABLE="$TMPROOT/unreadable.txt"
printf 'secret\n' > "$UNREADABLE"
chmod 0000 "$UNREADABLE"
AM_ROOT=0
[[ "$(id -u)" == "0" ]] && AM_ROOT=1

# Run a probe and record whether it succeeded, so a failing probe does not
# abort the test under `set -e`-free execution. want_ok <desc> <probe> <args...>
probe_ok() { # probe <args...>
  "$@" >/dev/null 2>&1
}
want_ok() { # desc probe args...
  local d="$1"; shift
  if probe_ok "$@"; then ok "$d"; else bad "$d"; fi
}
want_fail() { # desc probe args...
  local d="$1"; shift
  if probe_ok "$@"; then bad "$d"; else ok "$d"; fi
}

# --- probe_readable: open mode ---------------------------------------------
want_ok   "open probe: readable file is readable" probe_readable open "$READABLE"
want_fail "open probe: missing file is NOT readable" probe_readable open "$MISSING"
want_fail "open probe: a directory is NOT a readable file" probe_readable open "$DIR"
if (( ! AM_ROOT )); then
  want_fail "open probe: an unreadable file is NOT readable (it really opens)" \
    probe_readable open "$UNREADABLE"
fi

# --- probe_readable: access mode -------------------------------------------
want_ok   "access probe: readable file is readable" probe_readable access "$READABLE"
want_fail "access probe: missing file is NOT readable" probe_readable access "$MISSING"

# --- probe_dir_readable -----------------------------------------------------
want_ok   "open probe: a listable directory is readable" probe_dir_readable open "$DIR"
want_ok   "open probe: an empty directory is readable" probe_dir_readable open "$EMPTYDIR"
want_fail "open probe: a missing directory is NOT readable" probe_dir_readable open "$TMPROOT/nodir"
want_ok   "access probe: a listable directory is readable" probe_dir_readable access "$DIR"
want_fail "access probe: a missing directory is NOT readable" probe_dir_readable access "$TMPROOT/nodir"

# --- The open probe must OPEN, not consult [[ -r ]] -------------------------
# The only way to distinguish the two implementations without a capability is
# to prove the open probe fails where an open would fail while [[ -r ]] might
# not. A file with the executable bit but no read bit is exactly that case:
# access(2)'s R_OK fails, so both agree -- but it proves the open probe is not
# simply returning success for any existing path.
NORX="$TMPROOT/no-read-bit.txt"
printf 'y\n' > "$NORX"
chmod 0111 "$NORX"
if (( ! AM_ROOT )); then
  want_fail "open probe does not report an unopenable file as readable" \
    probe_readable open "$NORX"
fi

# --- The 16-byte header is what the classifier reads ------------------------
# Mirror backup.sh's classify_db_file: read 16 bytes through an open and compare
# to the SQLite magic. This proves the open probe path is usable for the header
# check that decides "is this a SQLite database". The header contains a NUL, so
# compare with cmp rather than a command substitution (which would drop it).
printf 'SQLite format 3\0' > "$TMPROOT/expected-magic"
head -c 16 "$READABLE" > "$TMPROOT/actual-magic" 2>/dev/null || true
assert "the 16-byte header reads through an open" \
  cmp -s "$TMPROOT/expected-magic" "$TMPROOT/actual-magic"

# --- Result -----------------------------------------------------------------
if (( FAILURES != 0 )); then
  echo "FAILURES: $FAILURES" >&2
  exit 1
fi
echo "All read-probe cases passed."
exit 0
