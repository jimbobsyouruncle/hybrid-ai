#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: backup/lib/read-probe.sh
# PURPOSE (plain English):
#   Two tiny readability probes, kept in their own file so a test can source
#   them directly and check both modes on a fixture.
#
# WHY TWO MODES:
#   User mode can decide readability with access(2) -- bash's [[ -r ]] and
#   find's -readable. That is cheap and correct when the process is the file
#   owner or root.
#
#   System mode CANNOT: the capture unit runs as the hybrid-ai-backup account
#   with CAP_DAC_READ_SEARCH, and Linux DROPS effective capabilities for
#   access(2) whenever the real uid is not root. So [[ -r ]] would report a file
#   the process can genuinely read as unreadable. The open(2) syscall does
#   honour the effective capability set, so an open-based probe reports what a
#   read will actually do. `head -c 0` opens the file and reads nothing.
#
# These functions are pure: they take the mode as an argument and touch nothing
# else. Sourced by backup/backup.sh; also sourced by the probe fixture test.
# ---------------------------------------------------------------------------

# probe_readable <mode: open|access> <file>
probe_readable() {
  local mode="$1" f="$2"
  [[ -f "$f" && ! -L "$f" ]] || return 1
  if [[ "$mode" == "open" ]]; then
    head -c 0 -- "$f" >/dev/null 2>&1
  else
    [[ -r "$f" ]]
  fi
}

# probe_dir_readable <mode: open|access> <dir>
probe_dir_readable() {
  local mode="$1" d="$2"
  [[ -d "$d" ]] || return 1
  if [[ "$mode" == "open" ]]; then
    ( ls -A -- "$d" ) >/dev/null 2>&1
  else
    [[ -r "$d" && -x "$d" ]]
  fi
}
