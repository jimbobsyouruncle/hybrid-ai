#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/test-agent-image-hybrid-cutover.sh
# PURPOSE (plain English):
#   Offline tests for install.sh's STEP 2b cut-over of the sandbox image pin
#   from the stock agent-server to the derived hybrid image. They need NO root,
#   NO Docker and NO network: every host command install.sh probes is stubbed on
#   PATH, and the whole run is pointed at a scratch app/data tree with --no-start
#   so install.sh writes .env and stops before touching Docker.
#
#   The bug this covers: a deployed host carries the OLD default pair verbatim
#   (docker.openhands.dev/openhands/agent-server AND 1.37.1-python) written by a
#   previous deploy. install.sh STEP 8 rewrites .env as ${VAR:-default}, so the
#   stale explicit values survive every deploy and the new hybrid defaults never
#   take effect. The migration (STEP 2b) is PAIR-EXACT: it unsets BOTH variables
#   only when BOTH load as the OLD default pair. If the owner customised EITHER
#   half, both are preserved and the pin is logged as left alone -- two
#   independent unsets would silently reset a custom tag to the new default.
#
#   A SECOND PAIR-EXACT migration covers the tag bump of the hybrid image itself:
#   a host that already cut over carries the hybrid.1 pair verbatim, and STEP 8
#   would preserve it as an owner pin, so STEP 2b unsets it to let STEP 8 write
#   the current hybrid default. A THIRD pair-exact migration covers the hybrid.2
#   to hybrid.3 bump (the semgrep parity tag) for the same reason. Both are
#   pair-exact: a host with a customised either half stays on its owner-chosen
#   pin.
#
# CASES:
#   (a) legacy default pair in .env        -> both migrated to the new defaults
#   (b) owner-chosen repository and/or tag -> preserved byte-for-byte
#   (c) no .env                            -> the new defaults are written
#   (d) a second run over the migrated .env -> no change, no migration logged
#   (e) old repository + custom tag        -> BOTH preserved (partial match)
#   (f) hybrid.1 pair in .env              -> both migrated to the hybrid.3 defaults
#   (g) hybrid repository + custom tag     -> BOTH preserved (partial match)
#   (h) a second run over the hybrid-migrated .env -> no change, no migration logged
#   (i) hybrid.2 pair in .env              -> both migrated to the hybrid.3 defaults
#   (j) hybrid.2 repository + custom tag   -> BOTH preserved (partial match)
#   (k) a second run over the hybrid.2-migrated .env -> no change, no migration logged
#
# USAGE:
#   bash scripts/test-agent-image-hybrid-cutover.sh
#
# EXIT CODES:
#   0  every case passed
#   1  one or more cases failed
#   2  a required tool is missing
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
[[ -f "${REPO}/install.sh" ]] || { echo "FATAL: cannot find install.sh" >&2; exit 2; }
for t in mktemp stat grep; do
  command -v "$t" >/dev/null 2>&1 || { echo "error: $t is required" >&2; exit 2; }
done

# Old stock pin (what a previously deployed host has in .env) and the new
# derived hybrid pin it must migrate to. HYBRID_1_TAG and HYBRID_2_TAG are the
# earlier hybrid builds a cut-over host carries; each migration bumps them to
# NEW_TAG (the hybrid.3 build).
OLD_REPO="docker.openhands.dev/openhands/agent-server"
OLD_TAG="1.37.1-python"
NEW_REPO="ghcr.io/jimbobsyouruncle/openhands-agent-server-hybrid"
NEW_TAG="1.37.1-python-hybrid.3"
HYBRID_1_TAG="1.37.1-python-hybrid.1"
HYBRID_2_TAG="1.37.1-python-hybrid.2"

PASS=0
FAIL=0
ok()   { PASS=$(( PASS + 1 )); printf 'ok   %s\n' "$*"; }
bad()  { FAIL=$(( FAIL + 1 )); printf 'FAIL %s\n' "$*" >&2; }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi; }

WORK="$(mktemp -d)"
if [[ "${KEEP:-0}" == "1" ]]; then
  printf 'keeping %s\n' "$WORK"
else
  trap 'rm -rf -- "$WORK"' EXIT
fi

# Optional: point the harness at a different install.sh (used to demonstrate the
# migration FAILS against the unpatched base). Defaults to this repo's copy.
INSTALL_SOURCE="${INSTALL_SH:-$REPO/install.sh}"
[[ -f "$INSTALL_SOURCE" ]] || { echo "FATAL: cannot find install.sh at $INSTALL_SOURCE" >&2; exit 2; }

# --- scratch app + layout ----------------------------------------------------
APP="$WORK/app"
BIN="$WORK/bin"
mkdir -p "$APP/scripts/lib" "$BIN" "$WORK/data" "$WORK/log" "$WORK/work" \
         "$WORK/ws" "$WORK/repos" "$WORK/ohstate" "$WORK/conf" "$WORK/restic" \
         "$WORK/etc/hybrid-ai" "$WORK/ws/.git/info"
cp "$INSTALL_SOURCE" "$APP/install.sh"
cp "$REPO/scripts/lib/hybrid-ai-env.sh" "$APP/scripts/lib/"
[ -f "$REPO/scripts/lib/build-gate.sh" ] || { echo "FATAL: scripts/lib/build-gate.sh is missing; the build gate does not exist in this tree." >&2; exit 2; }
cp "$REPO/scripts/lib/build-gate.sh" "$APP/scripts/lib/"

# install.sh sources scripts/lib/tls.sh and its TLS render step reads the
# tracked templates, so the scratch app tree must carry them too.
mkdir -p "$APP/status"
cp "$REPO/scripts/lib/tls.sh" "$APP/scripts/lib/"
cp "$REPO/status/Caddyfile.tmpl" "$APP/status/Caddyfile.tmpl"
cp "$REPO/docker-compose.yml.tmpl" "$APP/docker-compose.yml.tmpl"
# The agent scripts are not under test here; stub them so the run is quiet.
printf '#!/usr/bin/env bash\nexit 0\n' > "$APP/scripts/setup-agent-workspace.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$APP/scripts/sync-agent-repos.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$APP/scripts/check-hermes-nonroot.sh"
chmod +x "$APP/scripts/"*.sh

LAYOUT="$WORK/etc/hybrid-ai/hybrid-ai.env"
STACK="$WORK/etc/hybrid-ai/stack.env"
{
  printf 'HYBRID_AI_APP_DIR=%s\n' "$APP"
  printf 'HYBRID_AI_ENV_FILE=%s\n' "$LAYOUT"
  printf 'HYBRID_AI_STACK_ENV_FILE=%s\n' "$STACK"
  printf 'HYBRID_AI_DATA_DIR=%s\n' "$WORK/data"
  printf 'HYBRID_AI_LOG_DIR=%s\n' "$WORK/log"
  printf 'HYBRID_AI_WORK_DIR=%s\n' "$WORK/work"
  printf 'OPENHANDS_WORKSPACE=%s\n' "$WORK/ws"
  printf 'AGENT_REPOS_DIR=%s\n' "$WORK/repos"
  printf 'OPENHANDS_STATE_DIR=%s\n' "$WORK/ohstate"
  printf 'BACKUP_CONF_DIR=%s\n' "$WORK/conf"
  printf 'RESTIC_CACHE_DIR=%s\n' "$WORK/restic"
  printf 'HYBRID_AI_HERMES_HOME_DIR=%s\n' "$WORK/hermes"
  printf 'HYBRID_AI_BACKUP_MODE=system\n'
  printf 'BACKUP_CONTAINER_CONTROL=external\n'
  printf 'HYBRID_AI_UID=1000\n'
  printf 'HYBRID_AI_GID=1000\n'
} > "$LAYOUT"
chmod 644 "$LAYOUT"

# --- stubs -------------------------------------------------------------------
for d in docker git jq openssl sqlite3 rsync tailscale hostname nproc \
         loginctl setfacl apt-get sudo restic; do
  # shellcheck disable=SC2016  # $0 must expand inside the generated stub
  printf '#!/usr/bin/env bash\nprintf "%%s stub\\n" "$0"\nexit 0\n' > "$BIN/$d"
done
# `id` answers without a real account; chown is a no-op.
# shellcheck disable=SC2016  # $@ must expand inside the generated stub
printf '#!/usr/bin/env bash\nif [[ "${1:-}" == "-u" ]]; then printf "1000\\n"; exit 0; fi\nif [[ "${1:-}" == "-g" ]]; then printf "1000\\n"; exit 0; fi\nexec /usr/bin/id "$@"\n' > "$BIN/id"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/chown"
# sleep returns at once so the wait loops spin without real delay.
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/sleep"
# getent resolves a docker group and any host name.
cat > "$BIN/getent" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  group) printf 'docker:x:999:\n' ;;
  hosts) printf '[IP_ADDRESS] %s\n' "${2:-}" ;;
esac
exit 0
EOF
# curl: every endpoint is healthy.
cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$BIN"/*

run_install() { # log
  local log="$1" rc=0
  env -u HYBRID_AI_APP_DIR -u HYBRID_AI_DATA_DIR -u HYBRID_AI_LOG_DIR \
      -u HYBRID_AI_WORK_DIR -u HYBRID_AI_STACK_ENV_FILE \
      -u OPENHANDS_WORKSPACE -u AGENT_REPOS_DIR -u OPENHANDS_STATE_DIR \
      -u BACKUP_CONF_DIR -u RESTIC_CACHE_DIR -u HYBRID_AI_HERMES_HOME_DIR \
      -u HYBRID_AI_BACKUP_MODE -u BACKUP_CONTAINER_CONTROL \
      -u HYBRID_AI_UID -u HYBRID_AI_GID -u HYBRID_AI_LAYOUT_UID -u HYBRID_AI_LAYOUT_GID \
      -u OPENHANDS_IMAGE -u OPENHANDS_AGENT_IMAGE_TAG \
      -u OPENHANDS_AGENT_IMAGE_REPOSITORY \
      PATH="$BIN:$PATH" \
      HYBRID_AI_ENV_FILE="$LAYOUT" \
      LOCAL_DOMAIN=example.test OPENROUTER_API_KEY=stub RUNPOD_API_KEY=stub \
      RUNPOD_POD_ID=stub RUNPOD_HOST=stub PI_HOST=stub \
      OPENHANDS_SANDBOX_HOST=example.test PEER_HOSTNAMES="none" \
      USER=fixture \
      bash "$APP/install.sh" --non-interactive --no-start >> "$log" 2>&1 || rc=$?
  return "$rc"
}

# Read the effective value of KEY from the written .env (empty when absent).
env_value() { # file key
  grep -E "^$2=" "$1" 2>/dev/null | head -n1 | cut -d= -f2-
}

LOG="$WORK/install.log"

# ---------------------------------------------------------------------------
echo "== (a) legacy default pair in .env is migrated to the new defaults =="
: > "$LOG"
{
  printf 'OPENHANDS_AGENT_IMAGE_REPOSITORY=%s\n' "$OLD_REPO"
  printf 'OPENHANDS_AGENT_IMAGE_TAG=%s\n' "$OLD_TAG"
} > "$STACK"
chmod 600 "$STACK"
rc=0
run_install "$LOG" || rc=$?
check "install.sh exits 0 with --no-start" "0" "$rc"
check "OPENHANDS_AGENT_IMAGE_REPOSITORY is the new hybrid default" "$NEW_REPO" "$(env_value "$STACK" OPENHANDS_AGENT_IMAGE_REPOSITORY)"
check "OPENHANDS_AGENT_IMAGE_TAG is the new hybrid default" "$NEW_TAG" "$(env_value "$STACK" OPENHANDS_AGENT_IMAGE_TAG)"
if grep -q 'Migrating the stock agent-server pin' "$LOG"; then
  ok "the pair migration was logged"
else
  bad "the pair migration was not logged"
  sed 's/^/      /' "$LOG" >&2
fi

# ---------------------------------------------------------------------------
echo
echo "== (b) owner-chosen repository and/or tag are preserved =="
CUSTOM_REPO="registry.example.test/agent-server"
CUSTOM_TAG="owner-custom"
{
  printf 'OPENHANDS_AGENT_IMAGE_REPOSITORY=%s\n' "$CUSTOM_REPO"
  printf 'OPENHANDS_AGENT_IMAGE_TAG=%s\n' "$CUSTOM_TAG"
} > "$STACK"
chmod 600 "$STACK"
BEFORE="$(grep -E '^OPENHANDS_AGENT_IMAGE_(REPOSITORY|TAG)=' "$STACK")"
: > "$LOG"
rc=0
run_install "$LOG" || rc=$?
AFTER="$(grep -E '^OPENHANDS_AGENT_IMAGE_(REPOSITORY|TAG)=' "$STACK")"
check "install.sh exits 0 with a custom pair" "0" "$rc"
check "the custom repository is preserved" "$CUSTOM_REPO" "$(env_value "$STACK" OPENHANDS_AGENT_IMAGE_REPOSITORY)"
check "the custom tag is preserved" "$CUSTOM_TAG" "$(env_value "$STACK" OPENHANDS_AGENT_IMAGE_TAG)"
check "the seeded repository and tag lines are preserved byte-for-byte" "$BEFORE" "$AFTER"
if grep -q 'Migrating the stock agent-server pin' "$LOG"; then
  bad "a custom pair was wrongly migrated"
else
  ok "no pair migration was logged for a custom pair"
fi

# ---------------------------------------------------------------------------
echo
echo "== (c) with no .env the new defaults are written =="
: > "$LOG"
rm -f "$STACK"
rc=0
run_install "$LOG" || rc=$?
check "install.sh exits 0 with no .env" "0" "$rc"
check "the new default repository was written" "$NEW_REPO" "$(env_value "$STACK" OPENHANDS_AGENT_IMAGE_REPOSITORY)"
check "the new default tag was written" "$NEW_TAG" "$(env_value "$STACK" OPENHANDS_AGENT_IMAGE_TAG)"

# ---------------------------------------------------------------------------
echo
echo "== (d) a second run over the migrated .env changes nothing =="
# Seed the OLD pair, run once (migrating), then run again and prove no change.
{
  printf 'OPENHANDS_AGENT_IMAGE_REPOSITORY=%s\n' "$OLD_REPO"
  printf 'OPENHANDS_AGENT_IMAGE_TAG=%s\n' "$OLD_TAG"
} > "$STACK"
chmod 600 "$STACK"
run_install "$WORK/first.log" || true
check "the first run migrated the repository" "$NEW_REPO" "$(env_value "$STACK" OPENHANDS_AGENT_IMAGE_REPOSITORY)"
check "the first run migrated the tag" "$NEW_TAG" "$(env_value "$STACK" OPENHANDS_AGENT_IMAGE_TAG)"
REPO_AFTER_1="$(env_value "$STACK" OPENHANDS_AGENT_IMAGE_REPOSITORY)"
TAG_AFTER_1="$(env_value "$STACK" OPENHANDS_AGENT_IMAGE_TAG)"
: > "$LOG"
rc=0
run_install "$LOG" || rc=$?
check "a second install.sh run exits 0" "0" "$rc"
check "the repository is unchanged on the second run" "$REPO_AFTER_1" "$(env_value "$STACK" OPENHANDS_AGENT_IMAGE_REPOSITORY)"
check "the tag is unchanged on the second run" "$TAG_AFTER_1" "$(env_value "$STACK" OPENHANDS_AGENT_IMAGE_TAG)"
if grep -q 'Migrating the stock agent-server pin' "$LOG"; then
  bad "the migration re-ran on an already-migrated .env"
else
  ok "the migration is idempotent (nothing logged on the second run)"
fi

# ---------------------------------------------------------------------------
echo
echo "== (e) old repository + custom tag are BOTH preserved (partial match) =="
CUSTOM_TAG_E="1.38.0-python"
{
  printf 'OPENHANDS_AGENT_IMAGE_REPOSITORY=%s\n' "$OLD_REPO"
  printf 'OPENHANDS_AGENT_IMAGE_TAG=%s\n' "$CUSTOM_TAG_E"
} > "$STACK"
chmod 600 "$STACK"
BEFORE_E="$(grep -E '^OPENHANDS_AGENT_IMAGE_(REPOSITORY|TAG)=' "$STACK")"
: > "$LOG"
rc=0
run_install "$LOG" || rc=$?
AFTER_E="$(grep -E '^OPENHANDS_AGENT_IMAGE_(REPOSITORY|TAG)=' "$STACK")"
check "install.sh exits 0 with an old repository + custom tag" "0" "$rc"
check "the old repository is preserved" "$OLD_REPO" "$(env_value "$STACK" OPENHANDS_AGENT_IMAGE_REPOSITORY)"
check "the custom tag is preserved" "$CUSTOM_TAG_E" "$(env_value "$STACK" OPENHANDS_AGENT_IMAGE_TAG)"
check "the seeded repository and tag lines are preserved byte-for-byte" "$BEFORE_E" "$AFTER_E"
if grep -q 'Migrating the stock agent-server pin' "$LOG"; then
  bad "a partial match was wrongly migrated"
elif grep -q 'Leaving the OpenHands agent-server image pin alone' "$LOG"; then
  ok "the pin was logged as left alone"
else
  bad "the left-alone pin was not logged"
fi

# ---------------------------------------------------------------------------
echo
echo "== (f) hybrid.1 pair in .env is migrated to the hybrid.3 defaults =="
{
  printf 'OPENHANDS_AGENT_IMAGE_REPOSITORY=%s\n' "$NEW_REPO"
  printf 'OPENHANDS_AGENT_IMAGE_TAG=%s\n' "$HYBRID_1_TAG"
} > "$STACK"
chmod 600 "$STACK"
: > "$LOG"
rc=0
run_install "$LOG" || rc=$?
check "install.sh exits 0 migrating the hybrid.1 pair" "0" "$rc"
check "the repository stays the hybrid default" "$NEW_REPO" "$(env_value "$STACK" OPENHANDS_AGENT_IMAGE_REPOSITORY)"
check "the hybrid.1 tag is bumped to hybrid.3" "$NEW_TAG" "$(env_value "$STACK" OPENHANDS_AGENT_IMAGE_TAG)"
if grep -q 'Migrating the derived hybrid image pin' "$LOG"; then
  ok "the hybrid.1 -> hybrid.3 migration was logged"
else
  bad "the hybrid.1 -> hybrid.3 migration was not logged"
  sed 's/^/      /' "$LOG" >&2
fi

# ---------------------------------------------------------------------------
echo
echo "== (g) hybrid repository + custom tag are BOTH preserved (partial match) =="
CUSTOM_TAG_G="hybrid-local-build"
{
  printf 'OPENHANDS_AGENT_IMAGE_REPOSITORY=%s\n' "$NEW_REPO"
  printf 'OPENHANDS_AGENT_IMAGE_TAG=%s\n' "$CUSTOM_TAG_G"
} > "$STACK"
chmod 600 "$STACK"
BEFORE_G="$(grep -E '^OPENHANDS_AGENT_IMAGE_(REPOSITORY|TAG)=' "$STACK")"
: > "$LOG"
rc=0
run_install "$LOG" || rc=$?
AFTER_G="$(grep -E '^OPENHANDS_AGENT_IMAGE_(REPOSITORY|TAG)=' "$STACK")"
check "install.sh exits 0 with a hybrid repository + custom tag" "0" "$rc"
check "the hybrid repository is preserved" "$NEW_REPO" "$(env_value "$STACK" OPENHANDS_AGENT_IMAGE_REPOSITORY)"
check "the custom tag is preserved" "$CUSTOM_TAG_G" "$(env_value "$STACK" OPENHANDS_AGENT_IMAGE_TAG)"
check "the seeded repository and tag lines are preserved byte-for-byte" "$BEFORE_G" "$AFTER_G"
if grep -q 'Migrating the derived hybrid image pin' "$LOG"; then
  bad "a partial hybrid match was wrongly migrated"
elif grep -q 'Leaving the OpenHands agent-server image pin alone' "$LOG"; then
  ok "the partial hybrid pin was logged as left alone"
else
  bad "the left-alone hybrid pin was not logged"
fi

# ---------------------------------------------------------------------------
echo
echo "== (h) a second run over the hybrid-migrated .env changes nothing =="
{
  printf 'OPENHANDS_AGENT_IMAGE_REPOSITORY=%s\n' "$NEW_REPO"
  printf 'OPENHANDS_AGENT_IMAGE_TAG=%s\n' "$HYBRID_1_TAG"
} > "$STACK"
chmod 600 "$STACK"
run_install "$WORK/first-hybrid.log" || true
check "the first run bumped the tag to hybrid.3" "$NEW_TAG" "$(env_value "$STACK" OPENHANDS_AGENT_IMAGE_TAG)"
TAG_AFTER_H1="$(env_value "$STACK" OPENHANDS_AGENT_IMAGE_TAG)"
: > "$LOG"
rc=0
run_install "$LOG" || rc=$?
check "a second install.sh run exits 0" "0" "$rc"
check "the tag is unchanged on the second run" "$TAG_AFTER_H1" "$(env_value "$STACK" OPENHANDS_AGENT_IMAGE_TAG)"
if grep -q 'Migrating the derived hybrid image pin' "$LOG"; then
  bad "the hybrid migration re-ran on an already-migrated .env"
else
  ok "the hybrid migration is idempotent (nothing logged on the second run)"
fi

# ---------------------------------------------------------------------------
echo
echo "== (i) hybrid.2 pair in .env is migrated to the hybrid.3 defaults =="
{
  printf 'OPENHANDS_AGENT_IMAGE_REPOSITORY=%s\n' "$NEW_REPO"
  printf 'OPENHANDS_AGENT_IMAGE_TAG=%s\n' "$HYBRID_2_TAG"
} > "$STACK"
chmod 600 "$STACK"
: > "$LOG"
rc=0
run_install "$LOG" || rc=$?
check "install.sh exits 0 migrating the hybrid.2 pair" "0" "$rc"
check "the repository stays the hybrid default" "$NEW_REPO" "$(env_value "$STACK" OPENHANDS_AGENT_IMAGE_REPOSITORY)"
check "the hybrid.2 tag is bumped to hybrid.3" "$NEW_TAG" "$(env_value "$STACK" OPENHANDS_AGENT_IMAGE_TAG)"
if grep -q 'Migrating the derived hybrid image pin' "$LOG"; then
  ok "the hybrid.2 -> hybrid.3 migration was logged"
else
  bad "the hybrid.2 -> hybrid.3 migration was not logged"
  sed 's/^/      /' "$LOG" >&2
fi

# ---------------------------------------------------------------------------
echo
echo "== (j) hybrid.2 repository + custom tag are BOTH preserved (partial match) =="
CUSTOM_TAG_J="hybrid-local-build"
{
  printf 'OPENHANDS_AGENT_IMAGE_REPOSITORY=%s\n' "$NEW_REPO"
  printf 'OPENHANDS_AGENT_IMAGE_TAG=%s\n' "$CUSTOM_TAG_J"
} > "$STACK"
chmod 600 "$STACK"
BEFORE_J="$(grep -E '^OPENHANDS_AGENT_IMAGE_(REPOSITORY|TAG)=' "$STACK")"
: > "$LOG"
rc=0
run_install "$LOG" || rc=$?
AFTER_J="$(grep -E '^OPENHANDS_AGENT_IMAGE_(REPOSITORY|TAG)=' "$STACK")"
check "install.sh exits 0 with a hybrid repository + custom tag" "0" "$rc"
check "the hybrid repository is preserved" "$NEW_REPO" "$(env_value "$STACK" OPENHANDS_AGENT_IMAGE_REPOSITORY)"
check "the custom tag is preserved" "$CUSTOM_TAG_J" "$(env_value "$STACK" OPENHANDS_AGENT_IMAGE_TAG)"
check "the seeded repository and tag lines are preserved byte-for-byte" "$BEFORE_J" "$AFTER_J"
if grep -q 'Migrating the derived hybrid image pin' "$LOG"; then
  bad "a partial hybrid.2 match was wrongly migrated"
elif grep -q 'Leaving the OpenHands agent-server image pin alone' "$LOG"; then
  ok "the partial hybrid.2 pin was logged as left alone"
else
  bad "the left-alone hybrid.2 pin was not logged"
fi

# ---------------------------------------------------------------------------
echo
echo "== (k) a second run over the hybrid.2-migrated .env changes nothing =="
{
  printf 'OPENHANDS_AGENT_IMAGE_REPOSITORY=%s\n' "$NEW_REPO"
  printf 'OPENHANDS_AGENT_IMAGE_TAG=%s\n' "$HYBRID_2_TAG"
} > "$STACK"
chmod 600 "$STACK"
run_install "$WORK/first-hybrid2.log" || true
check "the first run bumped the tag to hybrid.3" "$NEW_TAG" "$(env_value "$STACK" OPENHANDS_AGENT_IMAGE_TAG)"
TAG_AFTER_H2="$(env_value "$STACK" OPENHANDS_AGENT_IMAGE_TAG)"
: > "$LOG"
rc=0
run_install "$LOG" || rc=$?
check "a second install.sh run exits 0" "0" "$rc"
check "the tag is unchanged on the second run" "$TAG_AFTER_H2" "$(env_value "$STACK" OPENHANDS_AGENT_IMAGE_TAG)"
if grep -q 'Migrating the derived hybrid image pin' "$LOG"; then
  bad "the hybrid.2 migration re-ran on an already-migrated .env"
else
  ok "the hybrid.2 migration is idempotent (nothing logged on the second run)"
fi

# ---------------------------------------------------------------------------
echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
