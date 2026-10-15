#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/lib/read-probe.sh
# PURPOSE (plain English):
#   Readability tests that keep working under a Linux file capability.
#
# WHY THE OBVIOUS TESTS ARE WRONG HERE:
#   In system mode the capture unit runs as the unprivileged hybrid-ai-backup
#   account holding AmbientCapabilities=CAP_DAC_READ_SEARCH. That capability
#   lets open(2) read files the account does not own. But Linux DROPS file
#   capabilities for the whole access(2) family -- and `find -readable` and the
#   shell's `[[ -r ]]` operator both use access(2) -- whenever the process's
#   REAL uid is not 0. So those tests would report a CAP_DAC_READ_SEARCH-readable
#   file as UNREADABLE, and the preflight would wrongly declare the run
#   incomplete.
#
# WHAT THIS PROVIDES:
#   probe_can_read <path>   true when open(2) succeeds for reading
#   find_unreadable <dir>   print the first entry an open(2) probe cannot read
#
# The probe opens and closes the path and never prints it, so a permission
# error can never leak a discovered path.
# ---------------------------------------------------------------------------

# True when this process can OPEN the path for reading. The subshell redirects
# the whole command's stderr to /dev/null first, so a permission-denied message
# can never leak a discovered path. Directories open too, so callers that only
# care about files test -f first.
probe_can_read() { ( exec 2>/dev/null; : < "$1" ); }

# Walk one tree and print the FIRST entry an open(2) probe cannot read, then
# stop. -xdev stays on one filesystem; stderr is suppressed so no hostile path
# can leak through an error message. Root bypasses the checks, so only a
# non-root caller can see a difference.
find_unreadable() {
  local entry
  while IFS= read -r -d '' entry; do
    if ! probe_can_read "$entry"; then
      printf '%s' "$entry"
      return 0
    fi
  done < <(find "$1" -xdev -print0 2>/dev/null)
  return 0
}
