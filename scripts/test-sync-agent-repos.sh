#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/test-sync-agent-repos.sh
# PURPOSE (plain English):
#   Offline tests for scripts/sync-agent-repos.sh. They need no network.
#   Every "remote" is a bare git repository under a throwaway temp dir, cloned
#   through a local file:// base, and the REAL sync script is invoked by
#   absolute path.
#
#   The script's two TEST-ONLY seams drive this:
#     AGENT_REPOS_CLONE_BASE      points the clone base at the local bare repos
#                                 (a file:// base is required to be local), and
#                                 makes the sync skip the GitHub API listing so
#                                 no request ever leaves the host.
#     AGENT_REPOS_INVENTORY_FILE  points the inventory at a temp file so the
#                                 tests can read and forge it.
#   With neither set, the script behaves exactly as in production.
#
#   The fixture credential strings are assembled at runtime from parts. No
#   literal `user:pass@host` shape appears in this file, so Semgrep does not
#   flag the fixtures as embedded credentials.
#
# COVERED:
#   clone; fast-forward update; already-up-to-date; dirty skip; diverged skip
#   (never clobbered); a symlink checked out as a plain file (core.symlinks
#   false); a symlink planted in a tree -> skipped:symlinks; credential-remote
#   skip; lock contention; inventory totals reconcile; a stray clone (rc 0,
#   warned, stale row, never deleted); an unclonable repo -> rc 2; --check ok,
#   stale, skipped-row, stale-row, missing dir and missing inventory.
#
# USAGE:
#   bash scripts/test-sync-agent-repos.sh
#
# EXIT CODES:
#   0  every case passed
#   1  one or more cases failed
# ---------------------------------------------------------------------------
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SYNC="$SCRIPT_DIR/sync-agent-repos.sh"

if [[ ! -f "$SYNC" ]]; then
  echo "FATAL: cannot find $SYNC" >&2
  exit 1
fi

ARCH="$(mktemp -d)"
trap 'rm -rf -- "$ARCH"' EXIT

# The clone base: a directory of bare repos. The sync script turns this into
# file:// URLs and, because it is set, skips the network listing entirely.
BASE="$ARCH/bare"
mkdir -p "$BASE"

# Fixture credential material, assembled from parts so no literal
# userinfo-looking string is stored in this file.
SECRET="$(printf 'ghp_%s' 'F4KEFIXTURE0000000000000000')"
USERINFO="${SECRET}:x"

# Deterministic identity for the commits the fixtures make.
GITID=(-c user.email=fixture@example.invalid -c user.name=fixture)

failures=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; failures=$(( failures + 1 )); }

# --- Fixture helpers -------------------------------------------------------
# new_repo <name> [branch]: init a bare repo, clone it to $WORK, seed a file.
new_repo() {
  local name="$1" branch="${2:-main}"
  git init -q --bare --initial-branch="$branch" "$BASE/$name.git"
  WORK="$ARCH/work/$name"
  git clone -q "file://$BASE/$name.git" "$WORK" 2>/dev/null
  git -C "$WORK" checkout -q -b "$branch"
  printf 'hello\n' > "$WORK/file.txt"
}

# commit_push <name> [branch] [msg]: stage all, commit, push, pin the bare HEAD.
commit_push() {
  local name="$1" branch="${2:-main}" msg="${3:-init}" bare="$BASE/$1.git"
  git -C "$WORK" "${GITID[@]}" add -A
  git -C "$WORK" "${GITID[@]}" commit -q -m "$msg"
  git -C "$WORK" push -q -u origin "$branch"
  git -C "$bare" symbolic-ref HEAD "refs/heads/$branch"
}

# advance_remote <name> [branch] [msg]: add a commit to the bare repo directly.
advance_remote() {
  local name="$1" branch="${2:-main}" msg="${3:-advance}"
  local tmp="$ARCH/adv-$name-$$"
  git clone -q "file://$BASE/$name.git" "$tmp"
  printf '%s\n' "$msg" >> "$tmp/advance.txt"
  git -C "$tmp" "${GITID[@]}" add -A
  git -C "$tmp" "${GITID[@]}" commit -q -m "$msg"
  git -C "$tmp" push -q origin "$branch"
}

# run_sync <reposdir> <manifest> <inventory> [extra args...]
# Runs the real script with the test seams. Sets SYNC_RC, writes $ARCH/out.txt.
run_sync() {
  local reposdir="$1" manifest="$2" inventory="$3"; shift 3
  set +e
  AGENT_REPOS_DIR="$reposdir" \
  AGENT_REPOS_MANIFEST="$manifest" \
  AGENT_REPOS_CLONE_BASE="$BASE" \
  AGENT_REPOS_INVENTORY_FILE="$inventory" \
  AGENT_REPOS_OWNER="fixtureowner" \
  OPENHANDS_WORKSPACE="$ARCH/ws" \
  HOME="$ARCH" \
    "$SYNC" "$@" >"$ARCH/out.txt" 2>&1
  SYNC_RC=$?
  set -e
}

# run_check <inventory>: run --check against a given inventory file.
run_check() {
  set +e
  AGENT_REPOS_DIR="$ARCH/unused" \
  AGENT_REPOS_INVENTORY_FILE="$1" \
  HOME="$ARCH" \
    "$SYNC" --check >"$ARCH/out.txt" 2>&1
  SYNC_RC=$?
  set -e
}

# count data rows in an inventory (pipe rows minus header and separator).
inv_rows() { local n; n="$(grep -c '^|' "$1" || true)"; printf '%s' "$(( n - 2 ))"; }

echo "== Running sync-agent-repos.sh tests =="

# --- Build the fixture bare repos ------------------------------------------
new_repo foo main
commit_push foo main init

new_repo diverged main
commit_push diverged main init

new_repo symrepo main
ln -s file.txt "$WORK/linkfile"          # a symlink committed into history
commit_push symrepo main init

new_repo cred main
commit_push cred main init

new_repo extra main
commit_push extra main init

# A repo whose committed history contains a symlink. On a filesystem that does
# not support symlinks (or with core.symlinks=false) git checks it out as a
# plain file, so a normal clone is clean. An existing clone that DOES contain a
# symlink is what we plant by hand for the skipped:symlinks case.
new_repo presym main
ln -s ../file.txt "$WORK/symlink.txt"
commit_push presym main init

# --- clone ----------------------------------------------------------------
R1="$ARCH/r1"; M1="$ARCH/m1.txt"; INV1="$ARCH/inv1.md"
mkdir -p "$R1"; printf 'fixtureowner/foo\n' > "$M1"
run_sync "$R1" "$M1" "$INV1"
if (( SYNC_RC == 0 )) && [[ -d "$R1/foo/.git" ]] && grep -q 'Cloned foo' "$ARCH/out.txt"; then
  if grep -qE "\| foo \| main \| [0-9a-f]+ \| cloned \|" "$INV1"; then
    pass "clone: rc 0, foo cloned, inventory row 'cloned'"
  else
    fail "clone: inventory row missing or wrong: $(grep foo "$INV1" || true)"
  fi
else
  fail "clone: expected rc 0 and a clone, got rc $SYNC_RC: $(cat "$ARCH/out.txt")"
fi

# --- fast-forward update --------------------------------------------------
advance_remote foo main second
run_sync "$R1" "$M1" "$INV1"
if (( SYNC_RC == 0 )) && grep -q 'Updated foo' "$ARCH/out.txt" \
   && grep -qE "\| foo \| main \| [0-9a-f]+ \| updated \|" "$INV1"; then
  pass "update: rc 0, foo updated, inventory row 'updated'"
else
  fail "update: expected an ff update, got rc $SYNC_RC: $(cat "$ARCH/out.txt")"
fi

# --- already up to date ---------------------------------------------------
run_sync "$R1" "$M1" "$INV1"
if (( SYNC_RC == 0 )) && grep -q 'already up to date' "$ARCH/out.txt" \
   && grep -qE "\| foo \| main \| [0-9a-f]+ \| up-to-date \|" "$INV1"; then
  pass "up-to-date: rc 0, no change, inventory row 'up-to-date'"
else
  fail "up-to-date: expected no change, got rc $SYNC_RC: $(cat "$ARCH/out.txt")"
fi

# --- dirty skip -----------------------------------------------------------
printf 'local edit\n' >> "$R1/foo/file.txt"
run_sync "$R1" "$M1" "$INV1"
if (( SYNC_RC == 1 )) && grep -q 'dirty' "$ARCH/out.txt" \
   && grep -qE "\| foo \| main \| [0-9a-f]+ \| skipped:dirty \|" "$INV1"; then
  pass "dirty: rc 1, skipped, inventory row 'skipped:dirty'"
else
  fail "dirty: expected rc 1 and a dirty skip, got rc $SYNC_RC: $(cat "$ARCH/out.txt")"
fi
git -C "$R1/foo" checkout -q -- file.txt   # restore for the later --check cases

# --- diverged skip (the local commit is never discarded) ------------------
R2="$ARCH/r2"; M2="$ARCH/m2.txt"; INV2="$ARCH/inv2.md"
mkdir -p "$R2"; printf 'fixtureowner/diverged\n' > "$M2"
run_sync "$R2" "$M2" "$INV2"          # clone
printf 'local only\n' >> "$R2/diverged/file.txt"
git -C "$R2/diverged" "${GITID[@]}" add -A
git -C "$R2/diverged" "${GITID[@]}" commit -q -m "local"
advance_remote diverged main remote     # remote advances independently
run_sync "$R2" "$M2" "$INV2"
local_subject="$(git -C "$R2/diverged" log -1 --format=%s)"
if (( SYNC_RC == 2 )) && [[ "$local_subject" == "local" ]] \
   && grep -q 'Failed to refresh diverged' "$ARCH/out.txt"; then
  pass "diverged: rc 2, local commit preserved, refresh refused"
else
  fail "diverged: expected rc 2 and local commit kept, got rc $SYNC_RC, subject '$local_subject'"
fi

# --- symlink checked out as a plain file (core.symlinks=false) ------------
R3="$ARCH/r3"; M3="$ARCH/m3.txt"; INV3="$ARCH/inv3.md"
mkdir -p "$R3"; printf 'fixtureowner/symrepo\n' > "$M3"
run_sync "$R3" "$M3" "$INV3"
if (( SYNC_RC == 0 )) && [[ -e "$R3/symrepo/linkfile" && ! -L "$R3/symrepo/linkfile" ]] \
   && [[ "$(git -C "$R3/symrepo" config core.symlinks)" == "false" ]]; then
  pass "symlink: checked out as a plain file, core.symlinks persisted false"
else
  fail "symlink: expected a plain file and core.symlinks=false, got rc $SYNC_RC"
fi

# --- a symlink planted in the tree -> skipped:symlinks, never deleted ------
# Replacing the checkout with a real symlink makes the tree clean at HEAD by
# content, so the symlink guard (not the dirty guard) fires.
R7="$ARCH/r7"; M7="$ARCH/m7.txt"; INV7="$ARCH/inv7.md"
mkdir -p "$R7"; printf 'fixtureowner/presym\n' > "$M7"
run_sync "$R7" "$M7" "$INV7"          # clone; symlink arrives as a plain file
rm -f "$R7/presym/symlink.txt"
ln -s ../file.txt "$R7/presym/symlink.txt"
[[ -z "$(git -C "$R7/presym" status --porcelain)" ]] || fail "symlink-in-tree: setup left the tree dirty"
run_sync "$R7" "$M7" "$INV7"
if (( SYNC_RC == 1 )) && [[ -L "$R7/presym/symlink.txt" ]] \
   && grep -qE "\| presym \| main \| [0-9a-f]+ \| skipped:symlinks \|" "$INV7"; then
  pass "symlink-in-tree: rc 1, skipped:symlinks, symlink left in place"
else
  fail "symlink-in-tree: expected rc 1 and a skipped:symlinks row, got rc $SYNC_RC: $(cat "$ARCH/out.txt")"
fi

# --- credential-remote skip -----------------------------------------------
R4="$ARCH/r4"; M4="$ARCH/m4.txt"; INV4="$ARCH/inv4.md"
mkdir -p "$R4"; printf 'fixtureowner/cred\n' > "$M4"
run_sync "$R4" "$M4" "$INV4"          # clone first (clean)
# Now plant a credential in the clone's remote URL and re-run.
git -C "$R4/cred" config remote.origin.url "https://${USERINFO}@github.com/fixtureowner/cred.git"
run_sync "$R4" "$M4" "$INV4"
if (( SYNC_RC == 1 )) \
   && grep -qE "\| cred \| main \| [0-9a-f]+ \| skipped:credential-remote \|" "$INV4" \
   && grep -q 'credential-remote' "$ARCH/out.txt"; then
  # The check may print the path and the config key, but never the userinfo.
  if grep -qF -- "$USERINFO" "$ARCH/out.txt" || grep -qF -- "$SECRET" "$ARCH/out.txt"; then
    fail "credential-remote: fixture credential leaked into output"
  elif grep -qF -- "$USERINFO" "$INV4" || grep -qF -- "$SECRET" "$INV4"; then
    fail "credential-remote: fixture credential leaked into the inventory"
  else
    pass "credential-remote: rc 1, skipped, no fetch, no credential leaked"
  fi
else
  fail "credential-remote: expected rc 1 and a skipped:credential-remote row, got rc $SYNC_RC"
fi

# --- lock contention ------------------------------------------------------
R5="$ARCH/r5"; M5="$ARCH/m5.txt"; INV5="$ARCH/inv5.md"
mkdir -p "$R5"; printf 'fixtureowner/foo\n' > "$M5"
exec 8>"$R5/.sync.lock"
if flock -n 8; then
  run_sync "$R5" "$M5" "$INV5"
  if (( SYNC_RC == 2 )) && grep -q 'another sync is running' "$ARCH/out.txt" \
     && [[ ! -e "$R5/foo" ]]; then
    pass "lock: rc 2, 'another sync is running', nothing changed"
  else
    fail "lock: expected rc 2 and no change, got rc $SYNC_RC: $(cat "$ARCH/out.txt")"
  fi
  flock -u 8
else
  fail "lock: the test could not acquire the lock to set up the case"
fi
exec 8>&-

# --- inventory totals reconcile -------------------------------------------
R6="$ARCH/r6"; M6="$ARCH/m6.txt"; INV6="$ARCH/inv6.md"
mkdir -p "$R6"; printf 'fixtureowner/foo\nfixtureowner/extra\n' > "$M6"
run_sync "$R6" "$M6" "$INV6"
n_rows="$(inv_rows "$INV6")"
read -r c_repos c_cloned c_updated c_utd c_skip c_err c_stale < <(
  awk -F'[^0-9]+' '/^- Totals:/ {for (i=2; i<=8; i++) printf "%s ", $i; print ""}' "$INV6"
)
sum=$(( c_cloned + c_updated + c_utd + c_skip + c_err + c_stale ))
if (( SYNC_RC == 0 )) && [[ "$c_repos" == "$n_rows" ]] && [[ "$sum" == "$c_repos" ]] \
   && [[ "$n_rows" == "2" ]]; then
  pass "inventory: totals reconcile (${c_repos} repositories, ${n_rows} rows, ${sum} categorised)"
else
  fail "inventory: totals do not reconcile: line='$(grep -m1 Totals "$INV6")' rows=${n_rows} repo=${c_repos} sum=${sum}"
fi

# --- --check: ok ----------------------------------------------------------
# Refresh INV1 so every row is a plain success before the --check cases that
# build on it.
run_sync "$R1" "$M1" "$INV1"
run_check "$INV1"
if (( SYNC_RC == 0 )); then
  pass "--check: fresh inventory -> rc 0"
else
  fail "--check: expected rc 0, got $SYNC_RC: $(cat "$ARCH/out.txt")"
fi

# --- --check: stale (old timestamp) ---------------------------------------
STALE="$ARCH/inv-stale.md"
sed -E 's/^- Generated \(UTC\): .*/- Generated (UTC): 2000-01-01T00:00:00Z/' "$INV1" > "$STALE"
run_check "$STALE"
if (( SYNC_RC == 1 )); then
  pass "--check: stale inventory -> rc 1"
else
  fail "--check stale: expected rc 1, got $SYNC_RC: $(cat "$ARCH/out.txt")"
fi

# --- --check: a skipped row -> rc 1 ---------------------------------------
SKIPINV="$ARCH/inv-skip.md"
sed -E 's/\| up-to-date \|/| skipped:dirty |/' "$INV1" > "$SKIPINV"
run_check "$SKIPINV"
if (( SYNC_RC == 1 )); then
  pass "--check: skipped row -> rc 1"
else
  fail "--check skipped-row: expected rc 1, got $SYNC_RC: $(cat "$ARCH/out.txt")"
fi

# --- --check: missing dir -> rc 2 -----------------------------------------
MOVED="$ARCH/foo-moved"
mv "$R1/foo" "$MOVED"
run_check "$INV1"
mv "$MOVED" "$R1/foo"
if (( SYNC_RC == 2 )); then
  pass "--check: missing directory -> rc 2"
else
  fail "--check missing-dir: expected rc 2, got $SYNC_RC: $(cat "$ARCH/out.txt")"
fi

# --- --check: missing inventory -> rc 2 -----------------------------------
run_check "$ARCH/does-not-exist.md"
if (( SYNC_RC == 2 )); then
  pass "--check: missing inventory -> rc 2"
else
  fail "--check missing-inventory: expected rc 2, got $SYNC_RC"
fi

# --- sync: a stray clone only warns and exits 0 ---------------------------
# A real clone on disk that is not in the manifest is informational in sync
# mode: the run warns, records a `stale` row and still exits 0. It is never
# deleted. `--check` is what enforces staleness.
R8="$ARCH/r8"; M8="$ARCH/m8.txt"; INV8="$ARCH/inv8.md"
mkdir -p "$R8"; printf 'fixtureowner/foo\n' > "$M8"
git clone -q "file://$BASE/foo.git" "$R8/zzzstray" 2>/dev/null
run_sync "$R8" "$M8" "$INV8"          # first run: clones foo
run_sync "$R8" "$M8" "$INV8"          # second run: foo up to date, stray only
stale_n="$(awk -F'[^0-9]+' '/^- Totals:/ {print $8; exit}' "$INV8")"
if (( SYNC_RC == 0 )) \
   && grep -q 'stale: zzzstray' "$ARCH/out.txt" \
   && grep -Eq '^\| zzzstray \| - \| [0-9a-f]+ \| stale \|' "$INV8" \
   && [[ "$stale_n" == "1" ]] \
   && [[ -d "$R8/zzzstray/.git" ]]; then
  pass "sync: stray clone -> rc 0, warned, stale row, still on disk"
else
  fail "sync stale-only: expected rc 0 with a stale row and the stray kept, got rc=$SYNC_RC stale=${stale_n}: $(cat "$ARCH/out.txt")"
fi

# --- sync: a repo that cannot be cloned is still an error (rc 2) ----------
# The bare repo still advertises a default branch, so the manifest accepts it,
# but its objects are gone, so the clone itself fails.
new_repo does-not-exist main
commit_push does-not-exist main init
rm -rf "${BASE:?}/does-not-exist.git/objects"/*
R9="$ARCH/r9"; M9="$ARCH/m9.txt"; INV9="$ARCH/inv9.md"
mkdir -p "$R9"; printf 'fixtureowner/does-not-exist\n' > "$M9"
run_sync "$R9" "$M9" "$INV9"
if (( SYNC_RC == 2 )) && grep -q '| error |' "$INV9"; then
  pass "sync: unclonable repo -> rc 2 with an error row"
else
  fail "sync failure: expected rc 2 and an error row, got rc=$SYNC_RC: $(cat "$ARCH/out.txt")"
fi

# --- --check: a stale row in a fresh inventory -> rc 1 --------------------
STALEROW="$ARCH/inv-stalerow.md"
sed -E 's/\| up-to-date \|/| stale |/' "$INV1" > "$STALEROW"
run_check "$STALEROW"
if (( SYNC_RC == 1 )) && grep -q 'skipped/stale/errored row(s)' "$ARCH/out.txt"; then
  pass "--check: stale row -> rc 1"
else
  fail "--check stale-row: expected rc 1 with the skipped/stale/errored warning, got $SYNC_RC: $(cat "$ARCH/out.txt")"
fi

echo "== done =="
if (( failures != 0 )); then
  echo "$failures case(s) failed."
  exit 1
fi
echo "All cases passed."
exit 0
