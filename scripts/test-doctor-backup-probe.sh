#!/usr/bin/env bash
# Offline regression guard for doctor.sh's backup-repository probe.
#
# The probe runs `restic snapshots --last` inside a `bash -c` subshell. restic
# has no password unless RESTIC_PASSWORD_FILE is set, so without that export the
# probe always warned "Could not reach the backup repository" even when the same
# repository opened fine from backup/restore.sh seconds earlier.
#
# This harness is grep-level: no Docker, no network, no restic. It inspects the
# text of a doctor.sh and asserts the probe sets the password file, resolves it
# with backup.sh's CREDENTIALS_DIRECTORY-then-fallback precedence, and never
# invokes restic before the export.
#
# Usage:
#   bash scripts/test-doctor-backup-probe.sh [path-to-doctor.sh]
#
# The path defaults to doctor.sh at the repository root; the root is resolved
# from this script's own location so the harness runs from anywhere.
# Exit 0 when every assertion passes, 1 otherwise, 2 on usage error.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

DOCTOR="${1:-$REPO_ROOT/doctor.sh}"

if [[ ! -f "$DOCTOR" ]]; then
  echo "FAIL: doctor.sh not found: $DOCTOR" >&2
  exit 2
fi

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

# --- Locate the probe block -------------------------------------------------
# Anchor on the restic invocation, then widen to the enclosing NO_CLOUD guard
# and its closing `fi`.
RESTIC_LINE="$(grep -n 'restic snapshots' "$DOCTOR" | head -1 | cut -d: -f1 || true)"
if [[ -z "$RESTIC_LINE" ]]; then
  fail "doctor.sh contains a 'restic snapshots' probe"
  echo "FAILURES: ${FAILURES}" >&2
  exit 1
fi

PROBE_START="$(awk -v n="$RESTIC_LINE" 'NR <= n && /NO_CLOUD/ { l = NR } END { print l }' "$DOCTOR")"
if [[ -z "$PROBE_START" ]]; then
  PROBE_START="$RESTIC_LINE"
fi
PROBE_END="$(awk -v n="$RESTIC_LINE" 'NR > n && /^  fi$/ { print NR; exit }' "$DOCTOR")"
if [[ -z "$PROBE_END" ]]; then
  PROBE_END="$((RESTIC_LINE + 12))"
fi

PROBE="$(sed -n "${PROBE_START},${PROBE_END}p" "$DOCTOR")"

# --- Assertions -------------------------------------------------------------
if grep -q 'RESTIC_PASSWORD_FILE' <<<"$PROBE"; then
  pass "probe sets RESTIC_PASSWORD_FILE"
else
  fail "probe never sets RESTIC_PASSWORD_FILE (restic runs with no password)"
fi

if grep -q 'CREDENTIALS_DIRECTORY' <<<"$PROBE" \
   && grep -q 'repo-password' <<<"$PROBE"; then
  pass "probe resolves repo-password with CREDENTIALS_DIRECTORY precedence"
else
  fail "probe does not resolve repo-password with CREDENTIALS_DIRECTORY precedence"
fi

if grep -Eq 'CREDENTIALS_DIRECTORY[^"]*\}?/repo-password' <<<"$PROBE"; then
  pass "probe prefers \${CREDENTIALS_DIRECTORY}/repo-password"
else
  fail "probe does not prefer \${CREDENTIALS_DIRECTORY}/repo-password"
fi

# Every restic invocation in the block must be preceded by the password export.
EXPORT_OFFSET="$(awk '/RESTIC_PASSWORD_FILE/ { print NR; exit }' <<<"$PROBE" || true)"
EXPORT_OFFSET="${EXPORT_OFFSET:-0}"
UNGUARDED=0
while IFS=: read -r off _rest; do
  [[ -z "$off" ]] && continue
  if (( off < EXPORT_OFFSET )); then
    UNGUARDED=$((UNGUARDED + 1))
  fi
done < <(grep -n 'restic snapshots' <<<"$PROBE" || true)

if (( UNGUARDED == 0 )); then
  pass "no restic invocation precedes the password export"
else
  fail "${UNGUARDED} restic invocation(s) run before the password export"
fi

if grep -q 'read -r ' <<<"$PROBE" && grep -q 'done < ' <<<"$PROBE" \
   && ! grep -qE '^[[:space:]]*(source|\.) ' <<<"$PROBE"; then
  pass "r2.env is still parsed line-by-line (never sourced)"
else
  fail "r2.env parse is no longer a line-by-line read loop"
fi

if grep -q 'warn "Could not reach the backup repository"' <<<"$PROBE" \
   && ! grep -qE '(^|[^_])fail "' <<<"$PROBE"; then
  pass "probe stays warn-only (generic repository warning retained)"
else
  fail "probe no longer ends in a warn for repository failures"
fi

if (( FAILURES != 0 )); then
  echo "FAILURES: ${FAILURES}" >&2
  exit 1
fi
echo "All backup-probe assertions passed."
exit 0
