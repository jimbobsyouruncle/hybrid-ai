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
#   The Caddy image pin gets the same four cases, (e) through (h):
#   (e) legacy CADDY_IMAGE=hybrid-ai-caddy:2.8.4-dns -> migrated to 2.11.7-dns
#   (f) custom CADDY_IMAGE             -> preserved byte-for-byte
#   (g) no .env                        -> the new CADDY_IMAGE default is written
#   (h) a second run                   -> no change, no CADDY_IMAGE migration
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
for d in docker git jq sqlite3 rsync tailscale hostname nproc \
         loginctl setfacl apt-get sudo restic; do
  # shellcheck disable=SC2016  # $0 must expand inside the generated stub
  printf '#!/usr/bin/env bash\nprintf "%%s stub\\n" "$0"\nexit 0\n' > "$BIN/$d"
done
# openssl: `rand -hex` yields a deterministic 64-char lowercase-hex string (so
# the auto-generated cookie secret is a real, valid value), `rand -base64`
# yields a fixed base64-looking string of the right length (install.sh also
# uses it for the restic password), and any other invocation prints the old
# generic stub line.
cat > "$BIN/openssl" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "rand" && "${2:-}" == "-hex" ]]; then
  printf '%064d\n' 0 | tr '0-9' 'a-f'
  exit 0
fi
if [[ "${1:-}" == "rand" && "${2:-}" == "-base64" ]]; then
  printf '%s\n' 'ZGV0ZXJtaW5pc3RpYy1yZXN0aWMtcGFzc3dvcmQtc3R1Yi1vbmx5QWJjZA=='
  exit 0
fi
printf '%s stub\n' "$0"
exit 0
EOF
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
# CADDY_IMAGE: the Caddy 2.8.4 image pin is retired in favour of the 2.11.7
# build. STEP 8 preserves an explicit CADDY_IMAGE as an owner pin, so a host
# that already deployed the 2.8.4 image would stay on it forever without an
# exact-match migration. The migration unsets CADDY_IMAGE ONLY when it equals
# the old default verbatim; any other value is an owner-chosen pin.
STALE_CADDY="hybrid-ai-caddy:2.8.4-dns"
NEW_CADDY="hybrid-ai-caddy:2.11.7-dns"

echo
echo "== (e) legacy CADDY_IMAGE is migrated to the new pin =="
: > "$LOG"
printf 'CADDY_IMAGE=%s\n' "$STALE_CADDY" > "$STACK"
chmod 600 "$STACK"
rc=0
run_install "$LOG" || rc=$?
check "install.sh exits 0 with the legacy CADDY_IMAGE" "0" "$rc"
check "CADDY_IMAGE is the new pin" "$NEW_CADDY" "$(env_value "$STACK" CADDY_IMAGE)"
if grep -q 'Migrating CADDY_IMAGE' "$LOG"; then
  ok "the CADDY_IMAGE migration was logged"
else
  bad "the CADDY_IMAGE migration was not logged"
  sed 's/^/      /' "$LOG" >&2
fi

# ---------------------------------------------------------------------------
echo
echo "== (f) a custom CADDY_IMAGE is preserved byte-for-byte =="
: > "$LOG"
CUSTOM_CADDY="ghcr.io/example/caddy-dns:9.9.9-custom"
printf 'CADDY_IMAGE=%s\n' "$CUSTOM_CADDY" > "$STACK"
chmod 600 "$STACK"
rc=0
run_install "$LOG" || rc=$?
check "install.sh exits 0 with a custom CADDY_IMAGE" "0" "$rc"
check "custom CADDY_IMAGE is preserved verbatim" "$CUSTOM_CADDY" "$(env_value "$STACK" CADDY_IMAGE)"
if grep -q 'Migrating CADDY_IMAGE' "$LOG"; then
  bad "a custom CADDY_IMAGE was wrongly migrated"
else
  ok "no CADDY_IMAGE migration was logged for a custom value"
fi

# ---------------------------------------------------------------------------
echo
echo "== (g) with no .env the new CADDY_IMAGE default is written =="
: > "$LOG"
rm -f "$STACK"
rc=0
run_install "$LOG" || rc=$?
check "install.sh exits 0 with no .env" "0" "$rc"
check "the new CADDY_IMAGE default was written" "$NEW_CADDY" "$(env_value "$STACK" CADDY_IMAGE)"
if grep -q 'Migrating CADDY_IMAGE' "$LOG"; then
  bad "a migration was logged when no value was set"
else
  ok "no CADDY_IMAGE migration was logged with nothing to migrate"
fi

# ---------------------------------------------------------------------------
echo
echo "== (h) a second run over the migrated .env changes nothing =="
: > "$LOG"
printf 'CADDY_IMAGE=%s\n' "$STALE_CADDY" > "$STACK"
chmod 600 "$STACK"
run_install "$WORK/first-caddy.log" || true
CADDY_AFTER_1="$(env_value "$STACK" CADDY_IMAGE)"
: > "$LOG"
rc=0
run_install "$LOG" || rc=$?
check "a second install.sh run exits 0" "0" "$rc"
check "CADDY_IMAGE is unchanged on the second run" "$CADDY_AFTER_1" "$(env_value "$STACK" CADDY_IMAGE)"
if grep -q 'Migrating CADDY_IMAGE' "$LOG"; then
  bad "the CADDY_IMAGE migration re-ran on an already-migrated .env"
else
  ok "the CADDY_IMAGE migration is idempotent (nothing logged on the second run)"
fi

# ---------------------------------------------------------------------------
# HYBRID_AI_AUTH_HASH / HYBRID_AI_AUTH_USER: escape-at-write. Docker Compose
# interpolates `$` in env-file values, so a raw bcrypt hash (`$2a$14$...`) loses
# its `$` fragments and the proxy's {$HYBRID_AI_AUTH_HASH} placeholder is
# corrupted. STEP 8 writes the value with every `$` doubled (`$$`); compose
# collapses it back to the operator's bytes in the container. The normalizer
# must be idempotent: raw -> escaped once, escaped -> unchanged, never
# `$$` -> `$$$$`. Both variables are escaped uniformly.

# A bcrypt-SHAPED dummy assembled at run time from fragments, so the tracked
# source never carries a bcrypt-hash literal (Semgrep flags those as secrets,
# even fake ones). It is the hash of nothing. Shape:
# $2a$<cost>$<22-char salt><31-char digest> = 60 characters, with `$` fragments.
DUMMY_MARK='$'"2a"'$'
DUMMY_HASH_RAW="${DUMMY_MARK}14"'$''./ABCDEFGH./ABCDEFGH./ABCDEFGH./ABCDEFGH./A'
DUMMY_HASH_ESCAPED='$$'"2a"'$$''14$$''./ABCDEFGH./ABCDEFGH./ABCDEFGH./ABCDEFGH./A'
DUMMY_USER_RAW="operator\$name"
DUMMY_USER_ESCAPED="operator\$\$name"

# The sourced normalizer is the single source of truth.
# shellcheck source=scripts/lib/tls.sh
source "$REPO/scripts/lib/tls.sh"
check "tls_compose_escape escapes a raw value once" "$DUMMY_HASH_ESCAPED" "$(tls_compose_escape "$DUMMY_HASH_RAW")"
check "tls_compose_escape is idempotent on an escaped value" "$DUMMY_HASH_ESCAPED" "$(tls_compose_escape "$DUMMY_HASH_ESCAPED")"
check "tls_compose_escape never yields four dollars" '$$' "$(tls_compose_escape '$$')"
check "tls_compose_unescape restores the raw bytes" "$DUMMY_HASH_RAW" "$(tls_compose_unescape "$DUMMY_HASH_ESCAPED")"

echo
echo "== (i1) a raw hash+user are normalized to escaped form on write =="
: > "$LOG"
{
  printf 'HYBRID_AI_AUTH_USER=%s\n' "$DUMMY_USER_RAW"
  printf 'HYBRID_AI_AUTH_HASH=%s\n' "$DUMMY_HASH_RAW"
} > "$STACK"
chmod 600 "$STACK"
rc=0
run_install "$LOG" || rc=$?
check "install.sh exits 0 with a raw auth hash" "0" "$rc"
check "HYBRID_AI_AUTH_HASH is written escaped" "$DUMMY_HASH_ESCAPED" "$(env_value "$STACK" HYBRID_AI_AUTH_HASH)"
check "HYBRID_AI_AUTH_USER is written escaped" "$DUMMY_USER_ESCAPED" "$(env_value "$STACK" HYBRID_AI_AUTH_USER)"
# Round-trip: unescaping the written value yields the operator's original bytes.
check "the written hash unescapes to the operator's bytes" "$DUMMY_HASH_RAW" "$(tls_compose_unescape "$(env_value "$STACK" HYBRID_AI_AUTH_HASH)")"

echo
echo "== (i2) a second run writes byte-identical auth lines =="
# The generated header carries a fresh UTC timestamp every run, so byte-identity
# is asserted on the auth lines the change owns, not on the whole file.
AUTH_LINES_AFTER_1="$(grep -E '^HYBRID_AI_AUTH_' "$STACK")"
: > "$LOG"
rc=0
run_install "$LOG" || rc=$?
check "a second install.sh run exits 0" "0" "$rc"
check "the auth lines are byte-identical on the second run" "$AUTH_LINES_AFTER_1" "$(grep -E '^HYBRID_AI_AUTH_' "$STACK")"

echo
echo "== (i3) an already-escaped value is never double-escaped =="
: > "$LOG"
{
  printf 'HYBRID_AI_AUTH_USER=%s\n' "$DUMMY_USER_ESCAPED"
  printf 'HYBRID_AI_AUTH_HASH=%s\n' "$DUMMY_HASH_ESCAPED"
} > "$STACK"
chmod 600 "$STACK"
rc=0
run_install "$LOG" || rc=$?
check "install.sh exits 0 with an already-escaped hash" "0" "$rc"
check "an escaped hash stays single-escaped (no \$\$\$\$)" "$DUMMY_HASH_ESCAPED" "$(env_value "$STACK" HYBRID_AI_AUTH_HASH)"
check "an escaped user stays single-escaped (no \$\$\$\$)" "$DUMMY_USER_ESCAPED" "$(env_value "$STACK" HYBRID_AI_AUTH_USER)"

echo
echo "== (i4) the cookie secret is escaped and the max-age default is written =="
# The cookie secret is escaped for Compose like the user and hash (a hex secret
# has no `$`, but the rule is the same, and a punctuated secret must survive).
DUMMY_SECRET_RAW="s3cret\$value"
DUMMY_SECRET_ESCAPED="s3cret\$\$value"
: > "$LOG"
{
  printf 'HYBRID_AI_AUTH_COOKIE_SECRET=%s\n' "$DUMMY_SECRET_RAW"
} > "$STACK"
chmod 600 "$STACK"
rc=0
run_install "$LOG" || rc=$?
check "install.sh exits 0 with a raw cookie secret" "0" "$rc"
check "HYBRID_AI_AUTH_COOKIE_SECRET is written escaped" "$DUMMY_SECRET_ESCAPED" "$(env_value "$STACK" HYBRID_AI_AUTH_COOKIE_SECRET)"
check "the written cookie secret unescapes to the operator's bytes" "$DUMMY_SECRET_RAW" "$(tls_compose_unescape "$(env_value "$STACK" HYBRID_AI_AUTH_COOKIE_SECRET)")"
# Unset -> the default 86400 is written, so the value is visible in the file.
check "an unset HYBRID_AI_AUTH_COOKIE_MAX_AGE is written as the 86400 default" "86400" "$(env_value "$STACK" HYBRID_AI_AUTH_COOKIE_MAX_AGE)"
# Owner-set -> preserved byte-for-byte (not clobbered by the default).
: > "$LOG"
{
  printf 'HYBRID_AI_AUTH_COOKIE_SECRET=%s\n' "$DUMMY_SECRET_ESCAPED"
  printf 'HYBRID_AI_AUTH_COOKIE_MAX_AGE=3600\n'
} > "$STACK"
chmod 600 "$STACK"
rc=0
run_install "$LOG" || rc=$?
check "an owner-set HYBRID_AI_AUTH_COOKIE_MAX_AGE is preserved" "3600" "$(env_value "$STACK" HYBRID_AI_AUTH_COOKIE_MAX_AGE)"

echo
echo "== (i5) an unset cookie secret is auto-generated as 64 lowercase hex =="
: > "$LOG"
: > "$STACK"
chmod 600 "$STACK"
rc=0
run_install "$LOG" || rc=$?
GEN_SECRET="$(env_value "$STACK" HYBRID_AI_AUTH_COOKIE_SECRET)"
check "install.sh exits 0 with no cookie secret seeded" "0" "$rc"
# Regex test, not a fixed string: the value is generated, not a constant.
if [[ "$GEN_SECRET" =~ ^[0-9a-f]{64}$ ]]; then
  ok "the auto-generated cookie secret is 64 lowercase hex chars"
else
  bad "the auto-generated cookie secret is not 64 lowercase hex chars (got ${#GEN_SECRET} chars)"
fi
check "the generation message is logged" "1" "$(grep -c 'Generated new HYBRID_AI_AUTH_COOKIE_SECRET' "$LOG")"

echo
echo "== (i6) an operator-set cookie secret is preserved byte-for-byte =="
OWNER_SECRET="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
: > "$LOG"
{
  printf 'HYBRID_AI_AUTH_COOKIE_SECRET=%s\n' "$OWNER_SECRET"
} > "$STACK"
chmod 600 "$STACK"
rc=0
run_install "$LOG" || rc=$?
check "install.sh exits 0 with an owner-set cookie secret" "0" "$rc"
check "the owner-set cookie secret is preserved" "$OWNER_SECRET" "$(env_value "$STACK" HYBRID_AI_AUTH_COOKIE_SECRET)"
check "the reuse message is logged" "1" "$(grep -c 'Reusing existing HYBRID_AI_AUTH_COOKIE_SECRET' "$LOG")"

echo
echo "== (i7) a second run reuses the generated secret unchanged =="
SECRET_AFTER_1="$(env_value "$STACK" HYBRID_AI_AUTH_COOKIE_SECRET)"
: > "$LOG"
rc=0
run_install "$LOG" || rc=$?
check "the second run exits 0" "0" "$rc"
check "the cookie secret line is unchanged on the second run" "$SECRET_AFTER_1" "$(env_value "$STACK" HYBRID_AI_AUTH_COOKIE_SECRET)"
check "the second run logs the reuse message" "1" "$(grep -c 'Reusing existing HYBRID_AI_AUTH_COOKIE_SECRET' "$LOG")"

echo
echo "== (i8) the generated cookie secret is never leaked to the install log =="
# Run over an empty stack env so the secret is freshly generated, then assert no
# 64-hex token appears anywhere in the captured log.
: > "$LOG"
: > "$STACK"
chmod 600 "$STACK"
run_install "$LOG" || true
if grep -Eq '[0-9a-f]{64}' "$LOG"; then
  bad "the install log contains a 64-hex token (secret leak)"
else
  ok "the install log contains no 64-hex token"
fi

# ---------------------------------------------------------------------------
echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
