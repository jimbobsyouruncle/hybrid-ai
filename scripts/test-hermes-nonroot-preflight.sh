#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/test-hermes-nonroot-preflight.sh
# PURPOSE (plain English):
#   Offline fixture tests for scripts/check-hermes-nonroot.sh, the install.sh
#   preflight that gates running Hermes as a non-root uid. They need no network
#   and no root.
#
#   The uid lookup is driven through a stub `getent` on PATH plus a fixture
#   login.defs, so the cases are deterministic and no system account is created
#   or changed. The real check script is invoked by absolute path.
#
# COVERED:
#   a) HYBRID_AI_UID unset  -> exit 0, today's behaviour, no output
#   a2) HYBRID_AI_UID=0     -> exit 0, no-op
#   b) uid resolves to a login account (shell not nologin/false) -> refuse
#   c) uid does not resolve to any account (real getent) -> refuse
#   d) hermes_data holds entries not owned by the uid -> refuse, COUNT ONLY,
#      and the foreign entry name never appears in the output
#   e) a clean system account + fully owned hermes_data -> pass
#
# USAGE:
#   bash scripts/test-hermes-nonroot-preflight.sh
#
# EXIT CODES:
#   0  every case passed
#   1  one or more cases failed
#   2  a required tool is missing
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$SCRIPT_DIR/check-hermes-nonroot.sh"

if [[ ! -f "$CHECK" ]]; then
  echo "FATAL: cannot find $CHECK" >&2
  exit 2
fi
for t in mktemp getent find awk cut wc tr; do
  command -v "$t" >/dev/null 2>&1 || { echo "error: $t is required" >&2; exit 2; }
done

WORKDIR="$(mktemp -d)"
trap 'rm -rf -- "$WORKDIR"' EXIT

# --- fixture login.defs: a system uid is below 60000 -------------------------
LOGIN_DEFS="$WORKDIR/login.defs"
cat > "$LOGIN_DEFS" <<'EOF'
UID_MIN                  60000
UID_MAX                  99999
EOF

# --- stub getent: passwd lookups consult a small map file --------------------
STUB="$WORKDIR/stub"
mkdir -p "$STUB"
GETENT_MAP="$WORKDIR/getent.map"
: > "$GETENT_MAP"

cat > "$STUB/getent" <<'EOF'
#!/usr/bin/env bash
# Stub getent. Only `getent passwd <uid>` is meaningful here.
if [[ "${1:-}" == "passwd" ]]; then
  uid="${2:-}"
  if [[ -f "${GETENT_MAP:-}" ]]; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      if [[ "$(printf '%s' "$line" | cut -d: -f3)" == "$uid" ]]; then
        printf '%s\n' "$line"
        exit 0
      fi
    done < "$GETENT_MAP"
  fi
fi
exit 2
EOF
chmod +x "$STUB/getent"

OUT_FILE="$WORKDIR/out.txt"
OUT_RC=0

# run_check <uid> <data-dir> [use-real-getent]
run_check() {
  local uid="$1" data_dir="$2" real_getent="${3:-0}"
  local path_prefix="$STUB"
  [[ "$real_getent" == "1" ]] && path_prefix=""
  env -i \
    PATH="${path_prefix:+$path_prefix:}/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    HOME="$WORKDIR" \
    HYBRID_AI_UID="$uid" \
    HERMES_DATA_DIR="$data_dir" \
    LOGIN_DEFS="$LOGIN_DEFS" \
    GETENT_MAP="$GETENT_MAP" \
    "$CHECK" >"$OUT_FILE" 2>&1
  OUT_RC=$?
}

failures=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; sed 's/^/      /' "$OUT_FILE" || true; failures=$(( failures + 1 )); }

echo "== Running check-hermes-nonroot.sh tests =="

# --- a) unset -> exit 0, no output -------------------------------------------
run_check "" "$WORKDIR/none"
if [[ "$OUT_RC" -eq 0 && ! -s "$OUT_FILE" ]]; then
  pass "a) unset uid is a no-op (exit 0, silent)"
else
  fail "a) unset uid should exit 0 with no output (got $OUT_RC)"
fi

# --- a2) uid 0 -> exit 0, no output ------------------------------------------
run_check "0" "$WORKDIR/none"
if [[ "$OUT_RC" -eq 0 && ! -s "$OUT_FILE" ]]; then
  pass "a2) uid 0 is a no-op (exit 0, silent)"
else
  fail "a2) uid 0 should exit 0 with no output (got $OUT_RC)"
fi

# --- b) login account (shell /bin/bash) -> refuse ----------------------------
GETENT_UID="12001"
printf 'svcuser:x:%s:%s::/home/svcuser:/bin/bash\n' "$GETENT_UID" "$GETENT_UID" > "$GETENT_MAP"
mkdir -p "$WORKDIR/hdata_owned"
run_check "$GETENT_UID" "$WORKDIR/hdata_owned"
if [[ "$OUT_RC" -ne 0 ]] && grep -q "login shell" "$OUT_FILE"; then
  pass "b) a login-shell uid is refused"
else
  fail "b) a login-shell uid should be refused (got $OUT_RC)"
fi

# --- c) uid does not resolve (real getent) -> refuse -------------------------
# 60099 is above this fixture's UID_MIN and is not a real account.
run_check "60099" "$WORKDIR/hdata_owned" 1
if [[ "$OUT_RC" -ne 0 ]] && grep -q "does not resolve" "$OUT_FILE"; then
  pass "c) an unresolved uid is refused"
else
  fail "c) an unresolved uid should be refused (got $OUT_RC)"
fi

# --- d) foreign-owned entries -> refuse, count only, no names ----------------
# The account is valid, but hermes_data files are owned by the CURRENT uid
# (this test's uid), which differs from the configured uid.
FOREIGN_UID="12002"
printf 'hermes:x:%s:%s::/nonexistent:/usr/sbin/nologin\n' "$FOREIGN_UID" "$FOREIGN_UID" > "$GETENT_MAP"
FOREIGN_DIR="$WORKDIR/hdata_foreign"
mkdir -p "$FOREIGN_DIR"
FOREIGN_NAME="STRANGER_ENTRY.txt"
printf 'x\n' > "$FOREIGN_DIR/$FOREIGN_NAME"
run_check "$FOREIGN_UID" "$FOREIGN_DIR"
if [[ "$OUT_RC" -ne 0 ]] && grep -q "not owned by uid" "$OUT_FILE"; then
  if grep -qF "$FOREIGN_NAME" "$OUT_FILE"; then
    fail "d) foreign entry name leaked into output"
  else
    pass "d) foreign-owned hermes_data is refused with a count and no names"
  fi
else
  fail "d) foreign-owned hermes_data should be refused (got $OUT_RC)"
fi

# --- e) clean system account + fully owned data -> pass ----------------------
CLEAN_UID="12003"
printf 'hermes:x:%s:%s::/nonexistent:/usr/sbin/nologin\n' "$CLEAN_UID" "$CLEAN_UID" > "$GETENT_MAP"
CLEAN_DIR="$WORKDIR/hdata_clean"
mkdir -p "$CLEAN_DIR"
# Remove the foreign count by pointing the check at an empty dir owned by us and
# using a valid account: the only foreign path would be the dir itself, so use
# an empty tree. The configured uid need not own it -- the check compares to the
# CONFIGURED uid, so an empty dir owned by another uid would still count as one
# foreign entry (the directory). To exercise the pass path we need the dir owned
# by CLEAN_UID, which requires root. When not root, assert the intended pass
# semantics with a non-existent data dir instead (skipped cleanly).
if [[ "$(id -u)" -eq 0 ]]; then
  chown -R "$CLEAN_UID:$CLEAN_UID" "$CLEAN_DIR"
  run_check "$CLEAN_UID" "$CLEAN_DIR"
  if [[ "$OUT_RC" -eq 0 ]] && grep -q "is owned by it" "$OUT_FILE"; then
    pass "e) a clean system account passes"
  else
    fail "e) a clean system account should pass (got $OUT_RC)"
  fi
else
  # Non-root: a data dir that does not exist is not descended into, so a valid
  # account passes. This is the same code path reached on a fresh host.
  run_check "$CLEAN_UID" "$WORKDIR/hdata_absent"
  if [[ "$OUT_RC" -eq 0 ]] && grep -q "is owned by it" "$OUT_FILE"; then
    pass "e) a clean system account passes (no data dir; chown skipped, not root)"
  else
    fail "e) a clean system account should pass (got $OUT_RC)"
  fi
fi

if [[ "$failures" -ne 0 ]]; then
  echo "FAILURES: $failures" >&2
  exit 1
fi
echo "All fixture cases passed."
exit 0
