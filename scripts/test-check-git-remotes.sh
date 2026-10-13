#!/usr/bin/env bash
set -Eeuo pipefail
# ---------------------------------------------------------------------------
# FILE: scripts/test-check-git-remotes.sh
# PURPOSE (plain English):
#   Offline tests for scripts/check-git-remotes.sh. They need no network.
#   Throwaway git repos are built under a temp dir, each with a hand-written
#   .git/config, and the REAL check script is invoked by absolute path.
#
#   The fixture "token" strings are assembled at runtime from parts. No
#   literal `user:pass@host` shape appears in this file, so Semgrep does not
#   flag the fixtures as embedded credentials.
#
# USAGE:
#   bash scripts/test-check-git-remotes.sh
#
# EXIT CODES:
#   0  every case passed
#   1  one or more cases failed
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$SCRIPT_DIR/check-git-remotes.sh"

if [[ ! -f "$CHECK" ]]; then
  echo "FATAL: cannot find $CHECK" >&2
  exit 1
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf -- "$WORKDIR"' EXIT

# Fixture credential material, assembled from parts so no literal
# userinfo-looking string is stored in this file.
SECRET="$(printf 'ghp_%s' 'F4KEFIXTURE0000000000000000')"
USERINFO="${SECRET}:x"

failures=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; failures=$(( failures + 1 )); }

# mk_repo <name> <key=value>...
mk_repo() {
  local name="$1"; shift
  local dir="$WORKDIR/$name"
  mkdir -p "$dir"
  git -C "$dir" init -q
  local kv
  for kv in "$@"; do
    git -C "$dir" config "${kv%%=*}" "${kv#*=}"
  done
  printf '%s' "$dir"
}

# run_check <root> -> writes combined output to $OUT_FILE, sets $OUT_RC
OUT_FILE="$WORKDIR/out.txt"
OUT_RC=0
run_check() {
  set +e
  "$CHECK" "$@" >"$OUT_FILE" 2>&1
  OUT_RC=$?
  set -e
}

no_leak() {
  # The fake secret and the userinfo fragment must never appear anywhere.
  if grep -qF -- "$SECRET" "$OUT_FILE"; then
    fail "$1: fake secret leaked into output"
    return 1
  fi
  if grep -qF -- "$USERINFO" "$OUT_FILE"; then
    fail "$1: userinfo leaked into output"
    return 1
  fi
  return 0
}

echo "== Running check-git-remotes.sh tests =="

# --- Clean cases: exit 0, no output, no leak ---------------------------------
for c in clean_https clean_scp clean_ssh; do
  case "$c" in
    clean_https) d="$(mk_repo "$c" "remote.origin.url=https://github.com/org/repo.git")" ;;
    clean_scp)   d="$(mk_repo "$c" "remote.origin.url=git@github.com:org/repo.git")" ;;
    clean_ssh)   d="$(mk_repo "$c" "remote.origin.url=ssh://git@github.com/org/repo.git")" ;;
  esac
  run_check "$d"
  if [[ "$OUT_RC" -eq 0 ]] && [[ ! -s "$OUT_FILE" ]]; then
    pass "$c -> exit 0, no output"
  else
    fail "$c expected exit 0 and no output, got exit $OUT_RC"
  fi
done

# --- Finding cases: exit 1, path and key printed, no leak --------------------
d="$(mk_repo bad_url "remote.origin.url=https://${USERINFO}@github.com/org/repo.git")"
run_check "$d"
if [[ "$OUT_RC" -eq 1 ]] && grep -qF -- "remote.origin.url" "$OUT_FILE"; then
  if no_leak "bad_url"; then
    pass "credential in remote.origin.url -> exit 1, key printed, no leak"
  fi
else
  fail "bad_url expected exit 1 with remote.origin.url, got exit $OUT_RC"
fi

d="$(mk_repo bad_pushurl \
      "remote.origin.url=https://github.com/org/repo.git" \
      "remote.origin.pushurl=https://${USERINFO}@example.invalid/org/repo.git")"
run_check "$d"
if [[ "$OUT_RC" -eq 1 ]] && grep -qF -- "remote.origin.pushurl" "$OUT_FILE"; then
  if no_leak "bad_pushurl"; then
    pass "credential in remote.origin.pushurl -> exit 1, key printed, no leak"
  fi
else
  fail "bad_pushurl expected exit 1 with remote.origin.pushurl, got exit $OUT_RC"
fi

d="$(mk_repo bad_insteadof \
      "url.https://${USERINFO}@github.com/.insteadOf=https://github.com/")"
run_check "$d"
if [[ "$OUT_RC" -eq 1 ]] && grep -qF -- "url.<base>.insteadof" "$OUT_FILE"; then
  if no_leak "bad_insteadof"; then
    pass "credential in url.<base>.insteadOf -> exit 1, key printed, no leak"
  fi
else
  fail "bad_insteadof expected exit 1 with url.<base>.insteadof, got exit $OUT_RC"
fi

# SCP-style and ssh base in an insteadOf key must NOT be flagged.
d="$(mk_repo clean_insteadof \
      "url.git@github.com:.insteadOf=https://github.com/")"
run_check "$d"
if [[ "$OUT_RC" -eq 0 ]] && [[ ! -s "$OUT_FILE" ]]; then
  pass "scp-style insteadOf base -> exit 0, no output"
else
  fail "scp-style insteadOf expected exit 0, got exit $OUT_RC"
fi

# --- Path is included in the finding line ------------------------------------
d="$(mk_repo bad_path "remote.origin.url=https://${USERINFO}@github.com/org/repo.git")"
run_check "$d"
if [[ "$OUT_RC" -eq 1 ]] && grep -qF -- "$d/.git/config: remote.origin.url" "$OUT_FILE"; then
  pass "finding line carries the config path and the key"
else
  fail "finding line missing path or key: $(cat "$OUT_FILE")"
fi

# --- Symlinked .git is not followed ------------------------------------------
REAL="$(mk_repo real_repo "remote.origin.url=https://${USERINFO}@github.com/org/repo.git")"
LINKROOT="$WORKDIR/linkroot"
mkdir -p "$LINKROOT/link/.git"
# Replace the symlink target directory with a symlink to the real .git dir.
rmdir "$LINKROOT/link/.git"
ln -s "$REAL/.git" "$LINKROOT/link/.git"
run_check "$LINKROOT"
if [[ "$OUT_RC" -eq 0 ]] && [[ ! -s "$OUT_FILE" ]]; then
  pass "symlinked .git is not followed -> exit 0, no output"
else
  fail "symlinked .git expected exit 0, got exit $OUT_RC: $(cat "$OUT_FILE")"
fi

# --- Malformed config is reported by path alone ------------------------------
MAL="$WORKDIR/malformed"
mkdir -p "$MAL"
printf 'bad [section\nurl = https://%s@github.com/x.git\n' "$USERINFO" > "$MAL/broken.gitconfig"
run_check "$MAL/broken.gitconfig"
if [[ "$OUT_RC" -eq 2 ]] && grep -qF -- ": unreadable" "$OUT_FILE"; then
  if no_leak "malformed"; then
    pass "malformed file -> exit 2, '<path>: unreadable', no leak"
  fi
else
  fail "malformed file expected exit 2 and ': unreadable', got exit $OUT_RC: $(cat "$OUT_FILE")"
fi

# --- Unreadable config (mode 000) is reported, no contents -------------------
if [[ "$(id -u)" -ne 0 ]]; then
  UNR="$WORKDIR/unreadable/repo/.git"
  mkdir -p "$UNR"
  printf '[remote "origin"]\n\turl = https://%s@github.com/x.git\n' "$USERINFO" > "$UNR/config"
  chmod 000 "$UNR/config"
  run_check "$WORKDIR/unreadable"
  chmod 644 "$UNR/config"
  if [[ "$OUT_RC" -eq 2 ]] && grep -qF -- ": unreadable" "$OUT_FILE"; then
    if no_leak "unreadable"; then
      pass "unreadable file -> exit 2, '<path>: unreadable', no leak"
    fi
  else
    fail "unreadable file expected exit 2 and ': unreadable', got exit $OUT_RC: $(cat "$OUT_FILE")"
  fi
else
  echo "SKIP: unreadable-file case (running as root)"
fi

# --- Hostile remote name must not leak userinfo ------------------------------
HOSTILE="$WORKDIR/hostile/repo/.git"
mkdir -p "$HOSTILE"
{
  printf '[remote "https://%s@github.com/"]\n' "$USERINFO"
  printf '\turl = https://%s@github.com/x.git\n' "$USERINFO"
} > "$HOSTILE/config"
run_check "$WORKDIR/hostile"
if [[ "$OUT_RC" -eq 1 ]]; then
  if no_leak "hostile-section"; then
    pass "hostile remote name -> exit 1, userinfo redacted, no leak"
  fi
else
  fail "hostile remote name expected exit 1, got exit $OUT_RC"
fi

# --- Usage error -------------------------------------------------------------
run_check
if [[ "$OUT_RC" -eq 2 ]]; then
  pass "no arguments -> exit 2 (usage error)"
else
  fail "no arguments expected exit 2, got exit $OUT_RC"
fi

echo "== done =="
if [[ "$failures" -ne 0 ]]; then
  echo "$failures case(s) failed."
  exit 1
fi
echo "All cases passed."
exit 0
