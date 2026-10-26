#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/test-install-tailscale-migration.sh
# PURPOSE (plain English):
#   Offline tests for install.sh's TAILSCALE_IP retirement. They need NO root,
#   NO Docker and NO network: every host command install.sh probes is stubbed
#   on PATH, and the whole run is pointed at a scratch app/data tree with
#   --no-start so install.sh writes .env and stops before touching Docker.
#
#   The change this covers: the deployment used to record the GPU pod's mesh
#   address in .env as TAILSCALE_IP, and every consumer read that stored copy.
#   A RunPod worker's address changes whenever the pod is recreated, so the copy
#   went stale. No component reads TAILSCALE_IP any more: the single stored
#   value is the pod's MagicDNS NAME (RUNPOD_HOST), resolved at use time.
#   STEP 2b drops the old address ONLY when it matches what RUNPOD_HOST
#   resolves to today, and preserves it verbatim otherwise.
#
# CASES:
#   (a) legacy in-mesh value + a name that resolves to exactly that value ->
#       migrated: the value is replaced by the name and the migration is logged
#   (b) custom/mismatched value -> preserved byte-for-byte, with a log line
#   (c) no .env                 -> the new default is written (RUNPOD_HOST set)
#   (d) a second run            -> no change, byte-identical .env
#
# USAGE:
#   bash scripts/test-install-tailscale-migration.sh [path-to-install.sh]
#
#   The optional argument points the harness at a different install.sh (for
#   example an unpatched copy from origin/main). That is how the "fails against
#   the base" evidence in the pull request was produced.
#
# EXIT CODES:
#   0  every case passed
#   1  one or more cases failed
#   2  a required tool is missing
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
INSTALL_UNDER_TEST="${1:-${REPO}/install.sh}"
[[ -f "$INSTALL_UNDER_TEST" ]] || { echo "FATAL: cannot find ${INSTALL_UNDER_TEST}" >&2; exit 2; }
for t in mktemp stat grep cut; do
  command -v "$t" >/dev/null 2>&1 || { echo "error: $t is required" >&2; exit 2; }
done

# The legacy address and the address the MagicDNS name deliberately resolve to
# when the peer is the same one. Case (b) uses a value that is a DIFFERENT peer,
# so it must not be migrated.
MESH_IP="100.64.0.9"
OTHER_IP="100.64.0.10"
POD_NAME="runpod-worker.example.test"

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
cp "$INSTALL_UNDER_TEST" "$APP/install.sh"
cp "$REPO/scripts/lib/hybrid-ai-env.sh" "$APP/scripts/lib/"
cp "$REPO/scripts/lib/tailscale-resolve.sh" "$APP/scripts/lib/"
[ -f "$REPO/scripts/lib/build-gate.sh" ] || { echo "FATAL: scripts/lib/build-gate.sh is missing; the build gate does not exist in this tree." >&2; exit 2; }
cp "$REPO/scripts/lib/build-gate.sh" "$APP/scripts/lib/"
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
for d in docker git jq openssl sqlite3 rsync hostname nproc \
         loginctl setfacl apt-get sudo restic; do
  # shellcheck disable=SC2016  # $0 must expand inside the generated stub
  printf '#!/usr/bin/env bash\nprintf "%%s stub\\n" "$0"\nexit 0\n' > "$BIN/$d"
done
# `id` answers without a real account; chown is a no-op.
# shellcheck disable=SC2016  # $1 and $@ must expand inside the generated stub
printf '#!/usr/bin/env bash\nif [[ "${1:-}" == "-u" ]] || [[ "${1:-}" == "-g" ]]; then printf "1000\\n"; exit 0; fi\nexec /usr/bin/id "$@"\n' > "$BIN/id"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/chown"
# sleep returns at once so the wait loops spin without real delay.
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/sleep"
# getent resolves a docker group and the pod's MagicDNS name.
cat > "$BIN/getent" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
  group) printf 'docker:x:999:\n' ;;
  ahostsv4)
    case "\${2:-}" in
      ${POD_NAME}) printf '${MESH_IP}  STREAM ${POD_NAME}\n' ;;
    esac ;;
  hosts) printf '192.0.2.10 %s\n' "\${2:-}" ;;
esac
exit 0
EOF
# curl: every endpoint is healthy.
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/curl"
# tailscale: connected, and the pod name resolves to the SAME address the legacy
# value carries. That is what makes case (a) an exact match.
cat > "$BIN/tailscale" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    status) printf '{"BackendState":"Running","Peer":{}}\n'; exit 0 ;;
    ip) printf '${MESH_IP}\n'; exit 0 ;;
  esac
done
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
      -u OPENHANDS_AGENT_IMAGE_REPOSITORY -u TAILSCALE_IP \
      PATH="$BIN:$PATH" \
      HYBRID_AI_ENV_FILE="$LAYOUT" \
      LOCAL_DOMAIN=example.test OPENROUTER_API_KEY=stub RUNPOD_API_KEY=stub \
      RUNPOD_POD_ID=stub RUNPOD_HOST="$POD_NAME" PI_HOST=stub \
      OPENHANDS_SANDBOX_HOST=example.test PEER_HOSTNAMES="none" \
      USER=fixture \
      bash "$APP/install.sh" --non-interactive --no-start >> "$log" 2>&1 || rc=$?
  return "$rc"
}

# Read the effective value of KEY from the written .env (empty when absent).
env_value() { # file key
  grep -E "^$2=" "$1" 2>/dev/null | tail -n1 | cut -d= -f2-
}

LOG="$WORK/install.log"

# ---------------------------------------------------------------------------
echo "== (a) a legacy value matching the resolved address is migrated =="
: > "$LOG"
{
  printf 'TAILSCALE_IP=%s\n' "$MESH_IP"
  printf 'RUNPOD_HOST=%s\n' "$POD_NAME"
} > "$STACK"
chmod 600 "$STACK"
rc=0
run_install "$LOG" || rc=$?
check "install.sh exits 0 with --no-start" "0" "$rc"
if grep -q 'Migrating TAILSCALE_IP to the MagicDNS name' "$LOG"; then
  ok "the migration was logged"
else
  bad "the migration was not logged"
  sed 's/^/      /' "$LOG" >&2
fi
check "RUNPOD_HOST is the MagicDNS name" "$POD_NAME" "$(env_value "$STACK" RUNPOD_HOST)"
if grep -qE '^TAILSCALE_IP=' "$STACK"; then
  bad "the migrated .env still carries a TAILSCALE_IP line"
else
  ok "the migrated .env carries no TAILSCALE_IP line"
fi

# ---------------------------------------------------------------------------
echo
echo "== (b) a custom or mismatched value is preserved byte-for-byte =="
: > "$LOG"
{
  printf 'TAILSCALE_IP=%s\n' "$OTHER_IP"
  printf 'RUNPOD_HOST=%s\n' "$POD_NAME"
} > "$STACK"
chmod 600 "$STACK"
rc=0
run_install "$LOG" || rc=$?
check "install.sh exits 0 with a mismatched value" "0" "$rc"
if grep -q 'Leaving the stored TAILSCALE_IP alone' "$LOG"; then
  ok "the preservation was logged"
else
  bad "the preservation was not logged"
  sed 's/^/      /' "$LOG" >&2
fi
check "the legacy value is preserved verbatim" "$OTHER_IP" "$(env_value "$STACK" TAILSCALE_IP)"
if grep -q 'Migrating TAILSCALE_IP' "$LOG"; then
  bad "a mismatched value was wrongly migrated"
else
  ok "no migration was logged for a mismatched value"
fi

# ---------------------------------------------------------------------------
echo
echo "== (c) with no .env the MagicDNS name is written =="
: > "$LOG"
rm -f "$STACK"
rc=0
run_install "$LOG" || rc=$?
check "install.sh exits 0 with no .env" "0" "$rc"
check "RUNPOD_HOST was written from the environment" "$POD_NAME" "$(env_value "$STACK" RUNPOD_HOST)"
if grep -qE '^TAILSCALE_IP=' "$STACK"; then
  bad "a fresh .env carries a TAILSCALE_IP line"
else
  ok "a fresh .env carries no TAILSCALE_IP line"
fi

# ---------------------------------------------------------------------------
echo
echo "== (d) a second run over the migrated .env changes nothing =="
# The generated header stamps the run's start time, so the header line itself
# differs on every run (that is upstream behaviour, not this migration). The
# comparison below normalises that one line and the template's pre-existing
# trailing spaces; everything else must be byte-identical.
normalise() { # file
  sed -e 's/^# GENERATED BY install\.sh -- .*$/# GENERATED BY install.sh/' \
      -e 's/[[:space:]]*$//' "$1"
}
: > "$LOG"
{
  printf 'TAILSCALE_IP=%s\n' "$MESH_IP"
  printf 'RUNPOD_HOST=%s\n' "$POD_NAME"
} > "$STACK"
chmod 600 "$STACK"
run_install "$WORK/first-run.log" || true
normalise "$STACK" > "$WORK/first.env"
: > "$LOG"
rc=0
run_install "$LOG" || rc=$?
normalise "$STACK" > "$WORK/second.env"
check "a second install.sh run exits 0" "0" "$rc"
if cmp -s "$WORK/first.env" "$WORK/second.env"; then
  ok "the .env is unchanged after the second run"
else
  bad "the .env changed on the second run"
  diff "$WORK/first.env" "$WORK/second.env" | sed 's/^/      /' >&2
fi
if grep -q 'Migrating TAILSCALE_IP' "$LOG"; then
  bad "the migration re-ran on an already-migrated .env"
else
  ok "the migration is idempotent (nothing logged on the second run)"
fi

# ---------------------------------------------------------------------------
echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
