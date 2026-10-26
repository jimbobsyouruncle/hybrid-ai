#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/test-prune-conversations.sh
# PURPOSE (plain English):
#   Prove the lease guard in scripts/prune-conversations.sh works in BOTH
#   directions, entirely offline.
#
#   The builder sandbox cannot see the host's conversation directories, so this
#   harness never looks at /var/lib and never touches a live deployment. For
#   every case it builds a throwaway fixture tree under mktemp -d and overrides
#   the environment variables the script honours, so the sweep runs against
#   that fixture only.
#
#   The script under test reads ${OPENHANDS_WORKSPACE}/conversations/ and moves
#   a directory into a date-stamped quarantine root only when its owner lease is
#   expired past the grace period, its mtime is older than the age limit, no
#   container mounts it, and the move cap has not been reached. It exits 0 on
#   every path and prints ONE summary line:
#     summary: scanned=N kept-live=N kept-recent=N moved=N refused=N ...
#
#   Cases proven here (each its own fixture tree, each a clear PASS or FAIL):
#     (a) a live lease -> the directory is kept (kept-live=1, moved=0).
#     (b) an expired lease past grace with an old mtime -> moved into the
#         quarantine run directory, gone from conversations, inner files intact.
#     (c) an expired lease on a directory newer than the age limit -> kept as
#         recent (kept-recent=1, moved=0).
#     (d) a missing lease -> the conservative default applies: the directory is
#         KEPT and refused with reason lease-missing, never moved.
#     (e) a conversation entry that is a symlink -> refused as symlink, not
#         followed, and the target contents are untouched.
#     (f) the per-run cap is honoured: three eligible directories with
#         HYBRID_AI_PRUNE_MAX_MOVES=1 -> moved=1 and two cap-reached refusals.
#     (g) a second consecutive run over the same tree -> moved=0, exit 0, and
#         nothing changes.
#     (h) the quarantine root is created mode 0750, and owned by uid 0 when the
#         harness runs as root. On a non-root runner this prints a visible SKIP
#         (a SKIP is not a failure) because it cannot assert uid 0.
#     (i) the resolved quarantine path never escapes the fixture tree, and a
#         ${OPENHANDS_WORKSPACE}/conversations that is itself a symlink pointing
#         outside the workspace makes the script refuse to sweep (exit 0,
#         nothing moved outside).
#     (j) HYBRID_AI_PRUNE_ALLOW_LEASE_LESS=1 -> a lease-less directory past the
#         age limit moves (moved-lease-less=1, reason lease-less-moved) with its
#         files intact, and a lease-less directory inside the age limit is
#         refused with reason lease-less-recent.
#     (j2) every non-truthy spelling of the knob ("", 0, false, no) keeps the
#         fail-safe: moved=0, refused=1, reason lease-missing.
#     (k) quarantine retention is ON by default at 90 days: a <YYYYMMDD> run
#         directory older than the window is deleted and logged with its path
#         and age, one inside the window is kept with its files.
#     (k2) an explicitly EMPTY or 0 retention knob opts out: nothing is deleted
#         and the run logs that retention is disabled. 0 must not be read as a
#         zero-day window.
#     (k3) retention is confined to dated run directories directly inside the
#         quarantine root: a dated symlink is not followed, a non-date directory
#         is kept, and the live conversations tree is untouched.
#     (l) install.sh STEP 8 writes both new knobs with the documented defaults
#         (ALLOW_LEASE_LESS empty = OFF, RETENTION_DAYS 90 = ON) and preserves
#         an owner value, including an empty RETENTION_DAYS opt-out.
#
#   Fully offline: no Docker, no network, no root, no systemd. docker is stubbed
#   on PATH so the container guard reports "none" deterministically. python3 is
#   used by the lease guard and is present on the runners.
#
#   The harness FAILS LOUDLY (non-zero) when scripts/prune-conversations.sh is
#   missing or not executable, so it is red against a tree without the script.
#
# Usage:
#   bash scripts/test-prune-conversations.sh
#
# Exit 0 when every assertion passes, 1 otherwise.
# ---------------------------------------------------------------------------
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PRUNE="${SCRIPT_DIR}/prune-conversations.sh"

if [[ ! -f "$PRUNE" ]]; then
  printf 'FAIL: the script under test is missing: %s\n' "$PRUNE" >&2
  exit 1
fi
if [[ ! -x "$PRUNE" ]]; then
  printf 'FAIL: the script under test is not executable: %s\n' "$PRUNE" >&2
  exit 1
fi

pass=0 fail=0 skip=0 CASE_BAD=0
ok()   { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); CASE_BAD=$((CASE_BAD+1)); }
skip() { printf '  SKIP %s\n' "$1"; skip=$((skip+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (want '$3' got '$2')"; fi; }
case_begin() { CASE_BAD=0; }
case_end()   { if (( CASE_BAD == 0 )); then printf 'PASS %s\n\n' "$1"; else printf 'FAIL %s\n\n' "$1"; fi; }

WORK_ROOT="$(mktemp -d)"
STUB_BIN="$(mktemp -d)"
trap 'rm -rf "$WORK_ROOT" "$STUB_BIN"' EXIT

# A docker stub that prints nothing and exits 0. `docker ps` therefore lists no
# containers and the container guard reports "none", deterministically, with no
# daemon and no network.
cat > "${STUB_BIN}/docker" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "${STUB_BIN}/docker"

NOW="$(date -u +%s)"
QDATE="$(date -u +%Y%m%d)"

# --- Knobs (overridden per case) -------------------------------------------
AGE=100
GRACE=10
MAX_MOVES=20
QBASE=""
# Empty means "leave the knob unset in the child", so the script's own default
# (OFF for lease-less, 90 days for retention) is what the case exercises.
ALLOW_LEASE_LESS=""
RETENTION_DAYS=""

# --- Fixture helpers -------------------------------------------------------
# Build a fresh tree with four distinct directories inside it and an (absent)
# layout env file. The default quarantine root is then
# <tree>/hybrid-ai-conversation-quarantine, a sibling of the data dir and
# outside every tree the backup captures.
new_tree() {
  TREE="$(mktemp -d "${WORK_ROOT}/case.XXXXXX")"
  mkdir -p "${TREE}/data" "${TREE}/app" "${TREE}/work" "${TREE}/workspace/conversations"
  CONV="${TREE}/workspace/conversations"
  QROOT="${TREE}/hybrid-ai-conversation-quarantine"
}

# Write a lease file. $1 dir, $2 expiry epoch seconds.
write_lease() {
  printf '{"owner_instance_id":"fixture","generation":1,"expires_at":%s,"owner_host":"fixture","owner_pid":1}\n' \
    "$2" > "$1/owner_lease.json"
}

# Age a directory's mtime by $2 seconds.
age_dir() { touch -d "@$(( NOW - $2 ))" -- "$1"; }

# --- Run the script under test against a fixture tree ----------------------
RUN_OUT=""; RUN_RC=0; RUN_SUMMARY=""
run_prune() {
  local tree="$1"
  local -a unset_args=()
  # A completely unset retention knob must behave like the documented default
  # (90 days ON), so every case that does not set it unsets it explicitly.
  if [[ -z "$RETENTION_DAYS" ]]; then
    unset_args+=("-u" "HYBRID_AI_PRUNE_QUARANTINE_RETENTION_DAYS")
  fi
  if [[ -z "$ALLOW_LEASE_LESS" ]]; then
    unset_args+=("-u" "HYBRID_AI_PRUNE_ALLOW_LEASE_LESS")
  fi
  local -a e=(
    "PATH=${STUB_BIN}:${PATH}"
    "HYBRID_AI_ENV_FILE=${tree}/hybrid-ai.env"
    "HYBRID_AI_APP_DIR=${tree}/app"
    "HYBRID_AI_DATA_DIR=${tree}/data"
    "HYBRID_AI_WORK_DIR=${tree}/work"
    "OPENHANDS_WORKSPACE=${tree}/workspace"
    "HYBRID_AI_PRUNE_AGE_SECONDS=${AGE}"
    "HYBRID_AI_PRUNE_GRACE_SECONDS=${GRACE}"
    "HYBRID_AI_PRUNE_MAX_MOVES=${MAX_MOVES}"
  )
  if [[ -n "$QBASE" ]]; then
    e+=("HYBRID_AI_PRUNE_QUARANTINE_BASE=${QBASE}")
  fi
  if [[ -n "$ALLOW_LEASE_LESS" ]]; then
    e+=("HYBRID_AI_PRUNE_ALLOW_LEASE_LESS=${ALLOW_LEASE_LESS}")
  fi
  if [[ -n "$RETENTION_DAYS" ]]; then
    e+=("HYBRID_AI_PRUNE_QUARANTINE_RETENTION_DAYS=${RETENTION_DAYS}")
  fi
  local rc=0
  RUN_OUT="$(env "${unset_args[@]}" "${e[@]}" bash "$PRUNE" 2>&1)" || rc=$?
  RUN_RC="$rc"
  RUN_SUMMARY="$(printf '%s\n' "$RUN_OUT" | grep -o 'summary: .*' | tail -n1 || true)"
}

counter() { printf '%s\n' "$RUN_SUMMARY" | sed -n "s/.* $1=\([0-9][0-9]*\).*/\1/p" | head -n1; }
refusals_of() { printf '%s' "${RUN_SUMMARY#*refusals=}"; }

printf 'prune-conversations lease-guard tests\n\n'

# --- (a) live lease -> kept -------------------------------------------------
case_begin
new_tree
mkdir -p "${CONV}/live-conv"
printf 'payload' > "${CONV}/live-conv/data.txt"
write_lease "${CONV}/live-conv" "$(( NOW + 3600 ))"
age_dir "${CONV}/live-conv" 100000
run_prune "$TREE"
check "(a) exit code is 0" "$RUN_RC" "0"
check "(a) kept-live counter" "$(counter kept-live)" "1"
check "(a) moved counter" "$(counter moved)" "0"
check "(a) directory is still present" "$([[ -d "${CONV}/live-conv" ]] && echo yes || echo no)" "yes"
case_end "(a) live/unexpired lease keeps the directory"

# --- (b) expired past grace + old mtime -> moved ----------------------------
case_begin
new_tree
mkdir -p "${CONV}/stale-conv/nested"
printf 'keep-me' > "${CONV}/stale-conv/inner.txt"
printf 'also' > "${CONV}/stale-conv/nested/deep.txt"
write_lease "${CONV}/stale-conv" "$(( NOW - GRACE - 100 ))"
age_dir "${CONV}/stale-conv" "$(( AGE + 100 ))"
run_prune "$TREE"
check "(b) exit code is 0" "$RUN_RC" "0"
check "(b) moved counter" "$(counter moved)" "1"
check "(b) kept-live counter" "$(counter kept-live)" "0"
check "(b) kept-recent counter" "$(counter kept-recent)" "0"
check "(b) refused counter" "$(counter refused)" "0"
check "(b) gone from conversations" "$([[ -e "${CONV}/stale-conv" ]] && echo present || echo gone)" "gone"
check "(b) inner file preserved" "$(cat "${QROOT}/${QDATE}/stale-conv/inner.txt" 2>/dev/null || echo missing)" "keep-me"
check "(b) nested file preserved" "$(cat "${QROOT}/${QDATE}/stale-conv/nested/deep.txt" 2>/dev/null || echo missing)" "also"
case_end "(b) expired lease past grace moves the directory into quarantine"

# --- (c) expired lease but recent mtime -> kept recent ----------------------
case_begin
new_tree
mkdir -p "${CONV}/recent-conv"
write_lease "${CONV}/recent-conv" "$(( NOW - GRACE - 100 ))"
run_prune "$TREE"
check "(c) exit code is 0" "$RUN_RC" "0"
check "(c) kept-recent counter" "$(counter kept-recent)" "1"
check "(c) moved counter" "$(counter moved)" "0"
check "(c) directory is still present" "$([[ -d "${CONV}/recent-conv" ]] && echo yes || echo no)" "yes"
case_end "(c) a directory newer than the age limit is kept as recent"

# --- (d) missing lease -> kept, refused lease-missing ----------------------
case_begin
new_tree
mkdir -p "${CONV}/no-lease"
printf 'x' > "${CONV}/no-lease/file.txt"
age_dir "${CONV}/no-lease" "$(( AGE + 100 ))"
run_prune "$TREE"
check "(d) exit code is 0" "$RUN_RC" "0"
check "(d) moved counter" "$(counter moved)" "0"
check "(d) refused counter" "$(counter refused)" "1"
if [[ "$(refusals_of)" == *"lease-missing"* ]]; then ok "(d) refusal reason is lease-missing"; else bad "(d) refusal reason is lease-missing (got '$(refusals_of)')"; fi
check "(d) directory is still present" "$([[ -d "${CONV}/no-lease" ]] && echo yes || echo no)" "yes"
case_end "(d) a missing lease is kept (conservative default)"

# --- (e) symlink entry -> refused, not followed -----------------------------
case_begin
new_tree
mkdir -p "${TREE}/outside/target"
printf 'untouched' > "${TREE}/outside/target/secret.txt"
ln -s "${TREE}/outside/target" "${CONV}/linked"
run_prune "$TREE"
check "(e) exit code is 0" "$RUN_RC" "0"
check "(e) moved counter" "$(counter moved)" "0"
check "(e) refused counter" "$(counter refused)" "1"
if [[ "$(refusals_of)" == *"symlink"* ]]; then ok "(e) refusal reason is symlink"; else bad "(e) refusal reason is symlink (got '$(refusals_of)')"; fi
check "(e) symlink is not followed" "$([[ -L "${CONV}/linked" ]] && echo symlink || echo changed)" "symlink"
check "(e) target contents untouched" "$(cat "${TREE}/outside/target/secret.txt" 2>/dev/null || echo missing)" "untouched"
check "(e) target not moved" "$([[ -d "${TREE}/outside/target" ]] && echo yes || echo no)" "yes"
case_end "(e) a symlink entry is refused and never followed"

# --- (f) per-run cap honoured ----------------------------------------------
case_begin
new_tree
MAX_MOVES=1
for n in cap1 cap2 cap3; do
  mkdir -p "${CONV}/${n}"
  printf 'x' > "${CONV}/${n}/f.txt"
  write_lease "${CONV}/${n}" "$(( NOW - GRACE - 100 ))"
  age_dir "${CONV}/${n}" "$(( AGE + 100 ))"
done
run_prune "$TREE"
MAX_MOVES=20
check "(f) exit code is 0" "$RUN_RC" "0"
check "(f) moved counter" "$(counter moved)" "1"
check "(f) refused counter" "$(counter refused)" "2"
check "(f) cap-reached refusals counted" "$(printf '%s' "$(refusals_of)" | grep -o 'cap-reached' | wc -l | tr -d ' ')" "2"
check "(f) exactly one directory moved" "$(find "${QROOT}/${QDATE}" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" "1"
case_end "(f) the per-run move cap is honoured"

# --- (g) second consecutive run -> no change --------------------------------
case_begin
new_tree
mkdir -p "${CONV}/once"
printf 'x' > "${CONV}/once/f.txt"
write_lease "${CONV}/once" "$(( NOW - GRACE - 100 ))"
age_dir "${CONV}/once" "$(( AGE + 100 ))"
run_prune "$TREE"
check "(g) first run exit code is 0" "$RUN_RC" "0"
check "(g) first run moved" "$(counter moved)" "1"
run_prune "$TREE"
check "(g) second run exit code is 0" "$RUN_RC" "0"
check "(g) second run moved counter" "$(counter moved)" "0"
check "(g) conversations still empty" "$(find "$CONV" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" "0"
check "(g) quarantined directory still present" "$([[ -d "${QROOT}/${QDATE}/once" ]] && echo yes || echo no)" "yes"
case_end "(g) a second consecutive run moves nothing and exits 0"

# --- (h) quarantine root mode and ownership ---------------------------------
case_begin
new_tree
mkdir -p "${CONV}/live"
write_lease "${CONV}/live" "$(( NOW + 3600 ))"
run_prune "$TREE"
check "(h) exit code is 0" "$RUN_RC" "0"
check "(h) quarantine base exists" "$([[ -d "$QROOT" ]] && echo yes || echo no)" "yes"
check "(h) quarantine base mode is 0750" "$(stat -c %a -- "$QROOT" 2>/dev/null || echo missing)" "750"
check "(h) quarantine run dir mode is 0750" "$(stat -c %a -- "${QROOT}/${QDATE}" 2>/dev/null || echo missing)" "750"
if (( EUID == 0 )); then
  check "(h) quarantine base owned by uid 0" "$(stat -c %u -- "$QROOT" 2>/dev/null || echo missing)" "0"
  check "(h) quarantine run dir owned by uid 0" "$(stat -c %u -- "${QROOT}/${QDATE}" 2>/dev/null || echo missing)" "0"
else
  skip "(h) ownership assertion needs root (running as uid $(id -u)); mode 0750 was still asserted"
fi
case_end "(h) the quarantine root is created mode 0750"

# --- (i) quarantine never escapes the fixture tree --------------------------
case_begin
new_tree
mkdir -p "${CONV}/moved"
write_lease "${CONV}/moved" "$(( NOW - GRACE - 100 ))"
age_dir "${CONV}/moved" "$(( AGE + 100 ))"
run_prune "$TREE"
check "(i) exit code is 0" "$RUN_RC" "0"
QREPORTED="${RUN_SUMMARY#*quarantine=}"
QREPORTED="${QREPORTED%% *}"
QREAL="$(realpath -m -- "$QREPORTED" 2>/dev/null || echo "")"
TREE_REAL="$(realpath -m -- "$TREE")"
if [[ -n "$QREAL" && "$QREAL" == "$TREE_REAL"/* ]]; then
  ok "(i) reported quarantine path is inside the fixture tree"
else
  bad "(i) reported quarantine path is inside the fixture tree (got '$QREAL')"
fi

# A conversations directory that is a symlink pointing outside the workspace:
# the script must refuse to sweep, exit 0, and move nothing outside.
new_tree
rmdir "${CONV}"
mkdir -p "${TREE}/outside/conversations/old"
printf 'outside' > "${TREE}/outside/conversations/old/f.txt"
write_lease "${TREE}/outside/conversations/old" "$(( NOW - GRACE - 100 ))"
age_dir "${TREE}/outside/conversations/old" "$(( AGE + 100 ))"
ln -s "${TREE}/outside/conversations" "${CONV}"
run_prune "$TREE"
check "(i) symlinked conversations exit code is 0" "$RUN_RC" "0"
check "(i) symlinked conversations moved nothing" "$(counter moved)" "0"
check "(i) nothing moved outside the workspace" "$([[ -d "${TREE}/outside/conversations/old" ]] && echo yes || echo no)" "yes"
check "(i) no quarantine was created" "$([[ -e "$QROOT" ]] && echo present || echo absent)" "absent"
case_end "(i) the quarantine never escapes the workspace/fixture tree"

# --- (j) lease-less opt-in: old directory moves, recent one is refused ------
case_begin
new_tree
mkdir -p "${CONV}/orphan-old/nested" "${CONV}/orphan-new"
printf 'keep-me' > "${CONV}/orphan-old/inner.txt"
printf 'deep' > "${CONV}/orphan-old/nested/deep.txt"
printf 'x' > "${CONV}/orphan-new/f.txt"
age_dir "${CONV}/orphan-old" "$(( AGE + 100 ))"
ALLOW_LEASE_LESS=1
run_prune "$TREE"
ALLOW_LEASE_LESS=""
check "(j) exit code is 0" "$RUN_RC" "0"
check "(j) moved counter" "$(counter moved)" "1"
check "(j) moved-lease-less counter" "$(counter moved-lease-less)" "1"
check "(j) refused counter" "$(counter refused)" "1"
if [[ "$(refusals_of)" == *"lease-less-recent"* ]]; then ok "(j) the recent lease-less directory is refused as lease-less-recent"; else bad "(j) the recent lease-less directory is refused as lease-less-recent (got '$(refusals_of)')"; fi
if [[ "$(refusals_of)" == *"lease-missing"* ]]; then bad "(j) the knob-on run still reports lease-missing"; else ok "(j) the knob-on run does not report lease-missing"; fi
check "(j) the old lease-less directory is gone" "$([[ -e "${CONV}/orphan-old" ]] && echo present || echo gone)" "gone"
check "(j) the recent lease-less directory is still present" "$([[ -d "${CONV}/orphan-new" ]] && echo yes || echo no)" "yes"
check "(j) inner file preserved" "$(cat "${QROOT}/${QDATE}/orphan-old/inner.txt" 2>/dev/null || echo missing)" "keep-me"
check "(j) nested file preserved" "$(cat "${QROOT}/${QDATE}/orphan-old/nested/deep.txt" 2>/dev/null || echo missing)" "deep"
case_end "(j) HYBRID_AI_PRUNE_ALLOW_LEASE_LESS=1 moves an old lease-less directory only"

# --- (j2) knob OFF is byte-identical: no new fields except the summary ------
case_begin
new_tree
mkdir -p "${CONV}/orphan-off"
printf 'x' > "${CONV}/orphan-off/f.txt"
age_dir "${CONV}/orphan-off" "$(( AGE + 100 ))"
for v in "" 0 false no; do
  ALLOW_LEASE_LESS="$v"
  run_prune "$TREE"
  check "(j2) knob='${v}' exit code is 0" "$RUN_RC" "0"
  check "(j2) knob='${v}' moved counter" "$(counter moved)" "0"
  check "(j2) knob='${v}' moved-lease-less counter" "$(counter moved-lease-less)" "0"
  check "(j2) knob='${v}' refused counter" "$(counter refused)" "1"
  if [[ "$(refusals_of)" == *"lease-missing"* ]]; then ok "(j2) knob='${v}' refusal reason is lease-missing"; else bad "(j2) knob='${v}' refusal reason is lease-missing (got '$(refusals_of)')"; fi
done
ALLOW_LEASE_LESS=""
check "(j2) the directory survived every OFF spelling" "$([[ -d "${CONV}/orphan-off" ]] && echo yes || echo no)" "yes"
case_end "(j2) every non-truthy spelling of the knob keeps the fail-safe"

# --- (k) quarantine retention: ON by default, window honoured --------------
case_begin
new_tree
mkdir -p "${CONV}/live"
write_lease "${CONV}/live" "$(( NOW + 3600 ))"
# Two pre-existing run directories: one far outside a 90-day window, one inside.
OLD_RUN="${QROOT}/20200101"
NEW_RUN="${QROOT}/$(date -u -d "@$(( NOW - 86400 ))" +%Y%m%d)"
mkdir -p "${OLD_RUN}/conv-old" "${NEW_RUN}/conv-new"
printf 'stale' > "${OLD_RUN}/conv-old/f.txt"
printf 'fresh' > "${NEW_RUN}/conv-new/f.txt"
age_dir "$OLD_RUN" "$(( 100 * 86400 ))"
age_dir "$NEW_RUN" "86400"
run_prune "$TREE"
check "(k) exit code is 0" "$RUN_RC" "0"
check "(k) retention-deleted counter" "$(counter retention-deleted)" "1"
check "(k) the directory past the 90-day default was deleted" "$([[ -e "$OLD_RUN" ]] && echo present || echo gone)" "gone"
check "(k) the directory inside the window was kept" "$([[ -d "$NEW_RUN" ]] && echo yes || echo no)" "yes"
check "(k) the kept directory still holds its files" "$(cat "${NEW_RUN}/conv-new/f.txt" 2>/dev/null || echo missing)" "fresh"
if [[ "$RUN_OUT" == *"retention-deleted: ${OLD_RUN}"* ]]; then ok "(k) the deletion is logged with its path"; else bad "(k) the deletion is logged with its path"; fi
if [[ "$RUN_OUT" == *"age="*"window=90d"* ]]; then ok "(k) the deletion log records the age and the window"; else bad "(k) the deletion log records the age and the window"; fi
check "(k) the live conversations tree is untouched" "$([[ -d "${CONV}/live" ]] && echo yes || echo no)" "yes"
case_end "(k) the quarantine root is bounded by a 90-day default retention"

# --- (k2) retention opt-out: an EMPTY or 0 knob never deletes --------------
# 0 must be an opt-out, not a zero-day window: a zero-day window would delete
# every run directory, including the one this run just wrote.
for optout in "" 0; do
  case_begin
  new_tree
  mkdir -p "${CONV}/live"
  write_lease "${CONV}/live" "$(( NOW + 3600 ))"
  OLD_RUN="${QROOT}/20200101"
  mkdir -p "${OLD_RUN}/conv-old"
  printf 'stale' > "${OLD_RUN}/conv-old/f.txt"
  age_dir "$OLD_RUN" "$(( 400 * 86400 ))"
  RETENTION_DAYS="$optout"
  rc=0
  RUN_OUT="$(env -u HYBRID_AI_PRUNE_ALLOW_LEASE_LESS \
    "PATH=${STUB_BIN}:${PATH}" \
    "HYBRID_AI_ENV_FILE=${TREE}/hybrid-ai.env" \
    "HYBRID_AI_APP_DIR=${TREE}/app" "HYBRID_AI_DATA_DIR=${TREE}/data" \
    "HYBRID_AI_WORK_DIR=${TREE}/work" "OPENHANDS_WORKSPACE=${TREE}/workspace" \
    "HYBRID_AI_PRUNE_AGE_SECONDS=${AGE}" "HYBRID_AI_PRUNE_GRACE_SECONDS=${GRACE}" \
    "HYBRID_AI_PRUNE_MAX_MOVES=${MAX_MOVES}" \
    "HYBRID_AI_PRUNE_QUARANTINE_RETENTION_DAYS=${optout}" \
    bash "$PRUNE" 2>&1)" || rc=$?
  RETENTION_DAYS=""
  RUN_RC="$rc"
  RUN_SUMMARY="$(printf '%s\n' "$RUN_OUT" | grep -o 'summary: .*' | tail -n1 || true)"
  check "(k2) opt-out='${optout}' exit code is 0" "$RUN_RC" "0"
  check "(k2) opt-out='${optout}' retention-deleted counter" "$(counter retention-deleted)" "0"
  check "(k2) opt-out='${optout}' the old run directory survived" "$([[ -d "$OLD_RUN" ]] && echo yes || echo no)" "yes"
  if [[ "$RUN_OUT" == *"retention: disabled"* ]]; then ok "(k2) opt-out='${optout}' logs that retention is disabled"; else bad "(k2) opt-out='${optout}' logs that retention is disabled"; fi
  case_end "(k2) retention knob '${optout}' restores the never-delete behaviour"
done

# --- (k3) retention never leaves the quarantine root ----------------------
case_begin
new_tree
mkdir -p "${CONV}/live"
write_lease "${CONV}/live" "$(( NOW + 3600 ))"
mkdir -p "${TREE}/outside/target" "$QROOT"
printf 'untouched' > "${TREE}/outside/target/secret.txt"
age_dir "${TREE}/outside/target" "$(( 400 * 86400 ))"
# A dated symlink INSIDE the quarantine root must not be followed out of it.
ln -s "${TREE}/outside/target" "${QROOT}/20200101"
# A dated real directory inside the root is deleted, proving the loop ran.
REAL_OLD="${QROOT}/20200102"
mkdir -p "$REAL_OLD"
age_dir "$REAL_OLD" "$(( 400 * 86400 ))"
# A non-date directory inside the root is never a run directory.
mkdir -p "${QROOT}/not-a-run"
age_dir "${QROOT}/not-a-run" "$(( 400 * 86400 ))"
run_prune "$TREE"
check "(k3) exit code is 0" "$RUN_RC" "0"
check "(k3) the symlink target survives" "$(cat "${TREE}/outside/target/secret.txt" 2>/dev/null || echo missing)" "untouched"
check "(k3) the symlink itself is not deleted" "$([[ -L "${QROOT}/20200101" ]] && echo symlink || echo changed)" "symlink"
check "(k3) the dated directory inside the root was deleted" "$([[ -e "$REAL_OLD" ]] && echo present || echo gone)" "gone"
check "(k3) a non-date directory inside the root was kept" "$([[ -d "${QROOT}/not-a-run" ]] && echo yes || echo no)" "yes"
check "(k3) the live conversations tree is untouched" "$([[ -d "${CONV}/live" ]] && echo yes || echo no)" "yes"
case_end "(k3) retention deletion is confined to dated run directories in the quarantine root"

# --- (l) install.sh STEP 8 writes and preserves both new knobs -------------
case_begin
STEP8_TMPL="${WORK_ROOT}/step8.tmpl"
awk '/^cat > "\$TMP_ENV" <<EOF$/{f=1;next} f&&/^EOF$/{exit} f' \
  "$(cd -- "${SCRIPT_DIR}/.." && pwd)/install.sh" > "$STEP8_TMPL"
if [[ -s "$STEP8_TMPL" ]]; then ok "(l) extracted the STEP 8 heredoc template"; else bad "(l) extracted the STEP 8 heredoc template"; fi

render_step8() { # optional_extra_shell
  (
    unset HYBRID_AI_PRUNE_ALLOW_LEASE_LESS HYBRID_AI_PRUNE_QUARANTINE_RETENTION_DAYS
    [[ -n "${1:-}" ]] && eval "$1"
    # Only the prune block is rendered: every other ${...} line is skipped, so
    # this fixture never needs the rest of install.sh's environment.
    grep -E '^HYBRID_AI_PRUNE_(ALLOW_LEASE_LESS|QUARANTINE_RETENTION_DAYS)=' "$STEP8_TMPL" \
      | while IFS= read -r line; do eval "printf '%s\n' \"${line}\""; done
  )
}

R_UNSET="$(render_step8 "")"
check "(l) ALLOW_LEASE_LESS defaults to empty when unset" \
  "$(printf '%s\n' "$R_UNSET" | grep -E '^HYBRID_AI_PRUNE_ALLOW_LEASE_LESS=' || true)" \
  "HYBRID_AI_PRUNE_ALLOW_LEASE_LESS="
check "(l) RETENTION_DAYS defaults to 90 when unset" \
  "$(printf '%s\n' "$R_UNSET" | grep -E '^HYBRID_AI_PRUNE_QUARANTINE_RETENTION_DAYS=' || true)" \
  "HYBRID_AI_PRUNE_QUARANTINE_RETENTION_DAYS=90"
R_SET="$(render_step8 'export HYBRID_AI_PRUNE_ALLOW_LEASE_LESS=1 HYBRID_AI_PRUNE_QUARANTINE_RETENTION_DAYS=30')"
check "(l) an owner-set ALLOW_LEASE_LESS is preserved" \
  "$(printf '%s\n' "$R_SET" | grep -E '^HYBRID_AI_PRUNE_ALLOW_LEASE_LESS=' || true)" \
  "HYBRID_AI_PRUNE_ALLOW_LEASE_LESS=1"
check "(l) an owner-set RETENTION_DAYS is preserved" \
  "$(printf '%s\n' "$R_SET" | grep -E '^HYBRID_AI_PRUNE_QUARANTINE_RETENTION_DAYS=' || true)" \
  "HYBRID_AI_PRUNE_QUARANTINE_RETENTION_DAYS=30"
R_OFF="$(render_step8 'export HYBRID_AI_PRUNE_QUARANTINE_RETENTION_DAYS=')"
check "(l) an explicit empty RETENTION_DAYS (opt-out) survives a reinstall" \
  "$(printf '%s\n' "$R_OFF" | grep -E '^HYBRID_AI_PRUNE_QUARANTINE_RETENTION_DAYS=' || true)" \
  "HYBRID_AI_PRUNE_QUARANTINE_RETENTION_DAYS="
case_end "(l) install.sh writes both knobs with the documented defaults and preserves an owner value"

printf '%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
(( fail == 0 ))
