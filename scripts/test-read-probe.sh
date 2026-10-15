#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/test-read-probe.sh
# PURPOSE (plain English):
#   Prove the open(2)-based readability probe in scripts/lib/read-probe.sh does
#   what backup.sh needs. The probe exists because access(2)-based tests
#   (`find -readable`, `[[ -r ]]`) misreport CAP_DAC_READ_SEARCH-readable files
#   as unreadable when the real uid is not 0; open(2) does not.
#
#   This is a no-root, no-network, no-docker fixture test. It cannot create a
#   file capability here, so it asserts the CONTRACT the capability relies on:
#   the probe is open(2)-based, it succeeds on readable files and directories,
#   it fails on a missing path and on a mode-0000 file when the caller is not
#   root, and find_unreadable reports the first entry the probe cannot read.
# ---------------------------------------------------------------------------
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/read-probe.sh
source "${SCRIPT_DIR}/lib/read-probe.sh"

pass=0 fail=0
ok()   { printf 'ok   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf 'FAIL %s\n' "$1"; fail=$((fail+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (want '$3' got '$2')"; fi; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

printf 'SQLite format 3\000' > "${WORK}/readable.bin"
mkdir -p "${WORK}/sub"
printf 'x' > "${WORK}/sub/inner.txt"

# 1. A readable file opens.
if probe_can_read "${WORK}/readable.bin"; then ok "probe opens a readable file"; else bad "probe opens a readable file"; fi

# 2. A directory opens (open(2) with O_RDONLY on a directory succeeds as root
#    and, for the read bit, as its owner).
if probe_can_read "${WORK}"; then ok "probe opens a directory"; else bad "probe opens a directory"; fi

# 3. A missing path does not open.
if probe_can_read "${WORK}/definitely-absent"; then bad "probe rejects a missing path"; else ok "probe rejects a missing path"; fi

# 4. find_unreadable finds nothing in an all-readable tree.
check "find_unreadable finds nothing in a readable tree" \
      "$(find_unreadable "$WORK")" ""

# 5. The probe never prints the path it could not read (no leak).
leak="$(probe_can_read "${WORK}/definitely-absent" 2>&1 || true)"
check "probe prints no path on failure" "$leak" ""

# 6. A mode-0000 file: root bypasses the read bit, so only assert as non-root.
if [[ "$(id -u)" != "0" ]]; then
  printf 'secret' > "${WORK}/locked.bin"
  chmod 000 "${WORK}/locked.bin"
  if probe_can_read "${WORK}/locked.bin"; then
    bad "probe rejects an unreadable file as non-root"
  else
    ok "probe rejects an unreadable file as non-root"
  fi
  # access(2) and open(2) agree here (no capability is held), so this also
  # confirms the probe is not merely reporting a fixed value.
  check "find_unreadable reports the locked entry" \
        "$(find_unreadable "$WORK")" "${WORK}/locked.bin"
else
  printf 'ok   skip unreadable-file assertions (running as root)\n'
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
