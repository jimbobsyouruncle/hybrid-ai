#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/test-env-pin-migration.sh
# PURPOSE (plain English):
#   Offline tests for install.sh's stale OpenHands image-pin migration. They
#   need NO root, NO Docker and NO network: every host command install.sh probes
#   is stubbed on PATH, and the whole run is pointed at a scratch app/data tree
#   with --no-start so install.sh writes .env and stops before touching Docker.
#
#   The bug this covers: install.sh STEP 8 rewrites .env as ${VAR:-default}, so
#   a stale pin loaded from the existing .env survives every deploy and the new
#   default never takes effect on an already-deployed host. The migration
#   (STEP 2b) unsets the EXACT stale values after the .env load, so STEP 8 then
#   writes the new pins. Any owner-chosen value is left untouched.
#
# CASES:
#   (a) seeded .env with BOTH stale pins -> the written .env carries the NEW pins
#   (b) seeded .env with custom values  -> preserved byte-for-byte
#   (c) no .env                         -> the NEW defaults are written
#   (d) a second run over the migrated .env -> no change, no migration logged
#
# USAGE:
#   bash scripts/test-env-pin-migration.sh
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

STALE_IMAGE="docker.openhands.dev/openhands/openhands:1.8"
NEW_IMAGE="docker.openhands.dev/openhands/openhands:1.10"
STALE_TAG="1.26.0-python"
NEW_TAG="1.37.1-python-hybrid.3"

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
echo "== (a) both stale pins are migrated to the new defaults =="
: > "$LOG"
{
  printf 'OPENHANDS_IMAGE=%s\n' "$STALE_IMAGE"
  printf 'OPENHANDS_AGENT_IMAGE_TAG=%s\n' "$STALE_TAG"
} > "$STACK"
chmod 600 "$STACK"
rc=0
run_install "$LOG" || rc=$?
check "install.sh exits 0 with --no-start" "0" "$rc"
check "OPENHANDS_IMAGE is the new pin" "$NEW_IMAGE" "$(env_value "$STACK" OPENHANDS_IMAGE)"
check "OPENHANDS_AGENT_IMAGE_TAG is the new pin" "$NEW_TAG" "$(env_value "$STACK" OPENHANDS_AGENT_IMAGE_TAG)"
if grep -q 'Migrating OPENHANDS_IMAGE' "$LOG" \
   && grep -q 'Migrating OPENHANDS_AGENT_IMAGE_TAG' "$LOG"; then
  ok "one migration line per stale pin was logged"
else
  bad "the migration was not logged"
  sed 's/^/      /' "$LOG" >&2
fi

# ---------------------------------------------------------------------------
echo
echo "== (b) owner-chosen custom values are preserved =="
: > "$LOG"
CUSTOM_IMAGE="docker.openhands.dev/openhands/openhands:1.9-custom"
CUSTOM_TAG="custom"
{
  printf 'OPENHANDS_IMAGE=%s\n' "$CUSTOM_IMAGE"
  printf 'OPENHANDS_AGENT_IMAGE_TAG=%s\n' "$CUSTOM_TAG"
} > "$STACK"
chmod 600 "$STACK"
rc=0
run_install "$LOG" || rc=$?
check "install.sh exits 0 with custom pins" "0" "$rc"
check "custom OPENHANDS_IMAGE is preserved" "$CUSTOM_IMAGE" "$(env_value "$STACK" OPENHANDS_IMAGE)"
check "custom OPENHANDS_AGENT_IMAGE_TAG is preserved" "$CUSTOM_TAG" "$(env_value "$STACK" OPENHANDS_AGENT_IMAGE_TAG)"
if grep -q 'Migrating OPENHANDS_IMAGE\|Migrating OPENHANDS_AGENT_IMAGE_TAG' "$LOG"; then
  bad "a custom value was wrongly migrated"
else
  ok "no migration was logged for custom values"
fi

# ---------------------------------------------------------------------------
echo
echo "== (c) with no .env the new defaults are written =="
: > "$LOG"
rm -f "$STACK"
rc=0
run_install "$LOG" || rc=$?
check "install.sh exits 0 with no .env" "0" "$rc"
check "the new OPENHANDS_IMAGE default was written" "$NEW_IMAGE" "$(env_value "$STACK" OPENHANDS_IMAGE)"
check "the new OPENHANDS_AGENT_IMAGE_TAG default was written" "$NEW_TAG" "$(env_value "$STACK" OPENHANDS_AGENT_IMAGE_TAG)"

# ---------------------------------------------------------------------------
echo
echo "== (d) a second run over the migrated .env changes nothing =="
: > "$LOG"
{
  printf 'OPENHANDS_IMAGE=%s\n' "$STALE_IMAGE"
  printf 'OPENHANDS_AGENT_IMAGE_TAG=%s\n' "$STALE_TAG"
} > "$STACK"
chmod 600 "$STACK"
run_install "$WORK/first.log" || true
IMAGE_AFTER_1="$(env_value "$STACK" OPENHANDS_IMAGE)"
TAG_AFTER_1="$(env_value "$STACK" OPENHANDS_AGENT_IMAGE_TAG)"
: > "$LOG"
rc=0
run_install "$LOG" || rc=$?
check "a second install.sh run exits 0" "0" "$rc"
check "OPENHANDS_IMAGE is unchanged on the second run" "$IMAGE_AFTER_1" "$(env_value "$STACK" OPENHANDS_IMAGE)"
check "OPENHANDS_AGENT_IMAGE_TAG is unchanged on the second run" "$TAG_AFTER_1" "$(env_value "$STACK" OPENHANDS_AGENT_IMAGE_TAG)"
if grep -q 'Migrating OPENHANDS_IMAGE\|Migrating OPENHANDS_AGENT_IMAGE_TAG' "$LOG"; then
  bad "the migration re-ran on an already-migrated .env"
else
  ok "the migration is idempotent (nothing logged on the second run)"
fi

# ---------------------------------------------------------------------------
echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
