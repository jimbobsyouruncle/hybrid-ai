#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/test-agent-image-repo-migration.sh
# PURPOSE (plain English):
#   Offline tests for install.sh's stale agent-server image REPOSITORY migration.
#   They need NO root, NO Docker and NO network: every host command install.sh
#   probes is stubbed on PATH, and the whole run is pointed at a scratch app/data
#   tree with --no-start so install.sh writes .env and stops before touching Docker.
#
#   The bug this covers: the app server reserves the canonical repository
#   ghcr.io/openhands/agent-server for its own bundled SDK version. When that
#   exact string is set it silently re-pins AGENT_SERVER_IMAGE_TAG to the bundled
#   version, so a newer tag such as 1.37.1-python never takes effect. Older
#   installs wrote that canonical repository into .env. The migration (STEP 2b)
#   unsets the EXACT stale value after the .env load, so STEP 8 then writes the
#   new default. Any owner-chosen value is left untouched.
#
# CASES:
#   (a) seeded .env with the canonical repository -> the written .env carries the
#       new default repository, the tag is unchanged, and the migration is logged
#   (b) seeded .env with a custom repository  -> preserved byte-for-byte
#   (c) no .env                               -> the new default is written
#   (d) a second run over the migrated .env   -> no change, no migration logged
#
# USAGE:
#   bash scripts/test-agent-image-repo-migration.sh
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

STALE_REPO="ghcr.io/openhands/agent-server"
NEW_REPO="docker.openhands.dev/openhands/agent-server"
NEW_TAG="1.37.1-python"

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

# --- scratch app + layout ----------------------------------------------------
APP="$WORK/app"
BIN="$WORK/bin"
mkdir -p "$APP/scripts/lib" "$BIN" "$WORK/data" "$WORK/log" "$WORK/work" \
         "$WORK/ws" "$WORK/repos" "$WORK/ohstate" "$WORK/conf" "$WORK/restic" \
         "$WORK/etc/hybrid-ai" "$WORK/ws/.git/info"
cp "$REPO/install.sh" "$APP/install.sh"
cp "$REPO/scripts/lib/hybrid-ai-env.sh" "$APP/scripts/lib/"
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
echo "== (a) the canonical repository is migrated to the new default =="
: > "$LOG"
{
  printf 'OPENHANDS_AGENT_IMAGE_REPOSITORY=%s\n' "$STALE_REPO"
  printf 'OPENHANDS_AGENT_IMAGE_TAG=%s\n' "$NEW_TAG"
} > "$STACK"
chmod 600 "$STACK"
rc=0
run_install "$LOG" || rc=$?
check "install.sh exits 0 with --no-start" "0" "$rc"
check "OPENHANDS_AGENT_IMAGE_REPOSITORY is the new default" "$NEW_REPO" "$(env_value "$STACK" OPENHANDS_AGENT_IMAGE_REPOSITORY)"
check "OPENHANDS_AGENT_IMAGE_TAG is unchanged" "$NEW_TAG" "$(env_value "$STACK" OPENHANDS_AGENT_IMAGE_TAG)"
if grep -q 'Migrating OPENHANDS_AGENT_IMAGE_REPOSITORY' "$LOG"; then
  ok "the repository migration was logged"
else
  bad "the repository migration was not logged"
  sed 's/^/      /' "$LOG" >&2
fi

# ---------------------------------------------------------------------------
echo
echo "== (b) an owner-chosen repository is preserved =="
: > "$LOG"
CUSTOM_REPO="registry.example.test/agent-server"
{
  printf 'OPENHANDS_AGENT_IMAGE_REPOSITORY=%s\n' "$CUSTOM_REPO"
  printf 'OPENHANDS_AGENT_IMAGE_TAG=%s\n' "$NEW_TAG"
} > "$STACK"
chmod 600 "$STACK"
# install.sh regenerates the whole .env, so compare the seeded keys byte-for-byte.
BEFORE="$(grep -E '^OPENHANDS_AGENT_IMAGE_(REPOSITORY|TAG)=' "$STACK")"
rc=0
run_install "$LOG" || rc=$?
AFTER="$(grep -E '^OPENHANDS_AGENT_IMAGE_(REPOSITORY|TAG)=' "$STACK")"
check "install.sh exits 0 with a custom repository" "0" "$rc"
check "the custom repository is preserved" "$CUSTOM_REPO" "$(env_value "$STACK" OPENHANDS_AGENT_IMAGE_REPOSITORY)"
check "the seeded repository and tag lines are preserved byte-for-byte" "$BEFORE" "$AFTER"
if grep -q 'Migrating OPENHANDS_AGENT_IMAGE_REPOSITORY' "$LOG"; then
  bad "a custom repository was wrongly migrated"
else
  ok "no repository migration was logged for a custom value"
fi

# ---------------------------------------------------------------------------
echo
echo "== (c) with no .env the new default repository is written =="
: > "$LOG"
rm -f "$STACK"
rc=0
run_install "$LOG" || rc=$?
check "install.sh exits 0 with no .env" "0" "$rc"
check "the new default repository was written" "$NEW_REPO" "$(env_value "$STACK" OPENHANDS_AGENT_IMAGE_REPOSITORY)"
check "the tag default was written" "$NEW_TAG" "$(env_value "$STACK" OPENHANDS_AGENT_IMAGE_TAG)"

# ---------------------------------------------------------------------------
echo
echo "== (d) a second run over the migrated .env changes nothing =="
: > "$LOG"
{
  printf 'OPENHANDS_AGENT_IMAGE_REPOSITORY=%s\n' "$STALE_REPO"
  printf 'OPENHANDS_AGENT_IMAGE_TAG=%s\n' "$NEW_TAG"
} > "$STACK"
chmod 600 "$STACK"
run_install "$WORK/first.log" || true
REPO_AFTER_1="$(env_value "$STACK" OPENHANDS_AGENT_IMAGE_REPOSITORY)"
TAG_AFTER_1="$(env_value "$STACK" OPENHANDS_AGENT_IMAGE_TAG)"
check "the first run migrated the repository" "$NEW_REPO" "$REPO_AFTER_1"
: > "$LOG"
rc=0
run_install "$LOG" || rc=$?
check "a second install.sh run exits 0" "0" "$rc"
check "the repository is unchanged on the second run" "$REPO_AFTER_1" "$(env_value "$STACK" OPENHANDS_AGENT_IMAGE_REPOSITORY)"
check "the tag is unchanged on the second run" "$TAG_AFTER_1" "$(env_value "$STACK" OPENHANDS_AGENT_IMAGE_TAG)"
if grep -q 'Migrating OPENHANDS_AGENT_IMAGE_REPOSITORY' "$LOG"; then
  bad "the migration re-ran on an already-migrated .env"
else
  ok "the migration is idempotent (nothing logged on the second run)"
fi

# ---------------------------------------------------------------------------
echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
