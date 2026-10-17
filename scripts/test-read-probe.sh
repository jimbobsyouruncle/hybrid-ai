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
#
#   It also pins the D3 fix: find_unreadable walks ONLY regular files and
#   directories. A tree that also holds a unix socket (open(2) fails ENXIO) and
#   a dangling symlink (ENOENT) must report NOTHING -- those entries hold no
#   data to capture. A genuinely unreadable regular file must still be reported,
#   so the honest-INCOMPLETE control is unchanged. A mode-000 file is readable
#   to root, so that case drops to an unprivileged uid (setpriv/runuser) when
#   run as root and prints SKIP -- never a pass -- if it cannot; a SKIP on a
#   non-root runner is a FAILURE.
# ---------------------------------------------------------------------------
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/read-probe.sh
source "${SCRIPT_DIR}/lib/read-probe.sh"

pass=0 fail=0 skip=0
ok()   { printf 'ok   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf 'FAIL %s\n' "$1"; fail=$((fail+1)); }
skip() { printf 'SKIP %s\n' "$1"; skip=$((skip+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (want '$3' got '$2')"; fi; }

WORK="$(mktemp -d)"
SOCKTREE="$(mktemp -d)"
LOCKTREE="$(mktemp -d)"
trap 'rm -rf "$WORK" "$SOCKTREE" "$LOCKTREE"' EXIT

PROBE_LIB="${SCRIPT_DIR}/lib/read-probe.sh"

# --- privilege drop (for the mode-000 fixture) -----------------------------
# A mode-000 file is readable to root, so a permission case must run as an
# unprivileged uid. When this script is root it drops to 'nobody'; if it cannot
# drop, the case prints SKIP and never a pass. On a NON-root runner a SKIP is a
# FAILURE (the GitHub runner is never root), so the case must actually run.
if (( EUID == 0 )); then
  PROBE_NUID="$(id -u nobody 2>/dev/null || echo 65534)"
  PROBE_NGID="$(id -g nobody 2>/dev/null || echo 65534)"
  if command -v setpriv >/dev/null 2>&1; then
    probe_pre=(setpriv --reuid="$PROBE_NUID" --regid="$PROBE_NGID" --clear-groups)
  elif command -v runuser >/dev/null 2>&1; then
    probe_pre=(runuser -u nobody --)
  else
    probe_pre=()
  fi
else
  probe_pre=()
fi

# Run find_unreadable <dir> under the (possibly dropped) uid. The lib is sourced
# inside the child so the function exists there.
run_find_unreadable() {
  if (( ${#probe_pre[@]} > 0 )); then
    # shellcheck disable=SC2016  # $1/$2 must expand inside the child bash, not here
    "${probe_pre[@]}" bash -c 'source "$1"; find_unreadable "$2"' _ "$PROBE_LIB" "$1"
  else
    find_unreadable "$1"
  fi
}

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

# 7. D3: a tree with a unix socket and a dangling symlink (plus readable files
#    and a directory) must report NOTHING. Sockets fail open(2) with ENXIO and
#    dangling symlinks with ENOENT, and neither holds data to capture; treating
#    them as unreadable made the whole tree look unreadable. This FAILS on the
#    unpatched base commit, which probes every entry.
if command -v python3 >/dev/null 2>&1; then
  mkdir -p "${SOCKTREE}/sub"
  printf 'data' > "${SOCKTREE}/ok.txt"
  printf 'data' > "${SOCKTREE}/sub/inner.txt"
  if python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "${SOCKTREE}/sock" 2>/dev/null \
     && [[ -S "${SOCKTREE}/sock" ]]; then
    ln -s "${SOCKTREE}/definitely-absent" "${SOCKTREE}/dangling"
    if [[ -L "${SOCKTREE}/dangling" && ! -e "${SOCKTREE}/dangling" ]]; then
      # Sanity: the probe really cannot read these two entries.
      if probe_can_read "${SOCKTREE}/sock"; then
        bad "socket fixture is readable (does not reproduce the defect)"
      elif probe_can_read "${SOCKTREE}/dangling"; then
        bad "dangling-symlink fixture is readable (does not reproduce the defect)"
      else
        ok "socket and dangling symlink are unreadable to open(2)"
        check "find_unreadable ignores a socket and a dangling symlink" \
              "$(find_unreadable "$SOCKTREE")" ""
      fi
    else
      bad "could not create a dangling symlink fixture"
    fi
  else
    bad "could not create a unix socket fixture"
  fi
else
  printf 'ok   skip socket/symlink fixture (python3 unavailable)\n'
fi

# 8. D3 (negative control): a genuinely unreadable REGULAR FILE must still be
#    reported, so the honest-INCOMPLETE marking is unchanged. Runs as an
#    unprivileged uid; SKIP (never a pass) only when root cannot drop.
printf 'secret' > "${LOCKTREE}/locked.bin"
chmod 000 "${LOCKTREE}/locked.bin"
if (( EUID == 0 )) && (( ${#probe_pre[@]} == 0 )); then
  skip "unreadable regular file still detected (running as root and cannot drop privileges)"
elif (( EUID == 0 )) && ! "${probe_pre[@]}" true >/dev/null 2>&1; then
  skip "unreadable regular file still detected (cannot drop privileges)"
else
  if (( EUID == 0 )); then
    chmod 0755 "$LOCKTREE"
  fi
  # Sanity: the dropped uid really cannot read the file.
  # shellcheck disable=SC2016  # $1 must expand inside the child bash, not here
  if (( ${#probe_pre[@]} > 0 )) && "${probe_pre[@]}" bash -c ': < "$1"' _ "${LOCKTREE}/locked.bin" 2>/dev/null; then
    bad "mode-000 fixture is readable by the dropped uid (does not reproduce)"
  else
    check "find_unreadable still reports an unreadable regular file" \
          "$(run_find_unreadable "$LOCKTREE")" "${LOCKTREE}/locked.bin"
  fi
fi

printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
(( fail == 0 ))
