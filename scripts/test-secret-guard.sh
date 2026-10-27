#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/test-secret-guard.sh
# PURPOSE (plain English):
#   Offline tests for the pre_tool_call secret guard
#   (hermes/agent-hooks/secret-guard.py) and for install.sh's STEP 9a-3, which
#   installs it 0755 into every Hermes profile and declares it there.
#
#   Fully offline: NO network, NO real ~/.hermes, NO live profile directories.
#   The hermes CLI is a stub on PATH that stores config in a fixture JSON file,
#   and the guard itself is fed JSON on stdin. Everything happens in a mktemp
#   directory that is removed on exit.
#
# WHAT IS PROVEN:
#   Block paths      a secret-file argument, an env-dump command, a
#                    secret-harvest shell command -> {"action":"block"} exit 0
#   Allow path       a benign payload -> {} exit 0
#   FAIL-CLOSED      malformed JSON, non-object JSON, empty stdin, wrong
#                    hook_event_name, missing tool_name, non-dict tool_input
#                    -> {"action":"block"} exit 2 (the baseline exited 1, i.e.
#                    it ALLOWED; that fail-open hole is what this change closes)
#   Installer        guard is 0755 at profiles/<p>/agent-hooks/secret-guard.py,
#                    declared exactly once, a peer hook survives, and a SECOND
#                    run changes nothing (same mode, no duplicate, config
#                    byte-identical)
#   Transport        with NO host hermes CLI, a stubbed `docker` whose
#                    `inspect ... hermes-agent` reports true runs the same
#                    config get/set through `docker exec` with the ABSOLUTE
#                    in-container CLI path and no host HERMES_HOME; no
#                    transport at all (docker absent, or the container not
#                    running) still records reason=hermes_missing and places
#                    nothing; the docker path is idempotent on a second run
#   Non-root         warns, records an event, writes nothing, exits 0
#
# POST-MERGE MANUAL CHECK (cannot run offline; needs a live host):
#   1. hermes -p <profile> hooks list          # the guard is listed
#   2. echo '{"hook_event_name":"pre_tool_call","tool_name":"terminal",
#      "tool_input":{"command":"printenv"}}' \
#      | hermes -p <profile> hooks test pre_tool_call
#      # expect a block decision from secret-guard.py
#   3. hermes -p <profile> hooks doctor        # no warnings for the guard
#
# USAGE:
#   bash scripts/test-secret-guard.sh
#
# EXIT CODES:
#   0  every case passed
#   1  one or more cases failed
#   2  a required tool is missing
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
GUARD="$REPO/hermes/agent-hooks/secret-guard.py"
[[ -f "$GUARD" ]] || { echo "FATAL: cannot find hermes/agent-hooks/secret-guard.py" >&2; exit 2; }
[[ -f "$REPO/install.sh" ]] || { echo "FATAL: cannot find install.sh" >&2; exit 2; }
for t in mktemp stat grep cmp install python3 jq; do
  command -v "$t" >/dev/null 2>&1 || { echo "error: $t is required" >&2; exit 2; }
done

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

# --- the guard, fed JSON on stdin -------------------------------------------
# run_guard <payload>  -> sets GUARD_OUT, GUARD_ERR, GUARD_RC
run_guard() {
  local payload="$1"
  GUARD_OUT="$WORK/out.json"
  GUARD_ERR="$WORK/err.txt"
  : > "$GUARD_OUT"; : > "$GUARD_ERR"
  GUARD_RC=0
  printf '%s' "$payload" | python3 "$GUARD" >"$GUARD_OUT" 2>"$GUARD_ERR" || GUARD_RC=$?
}

# assert_block <name> <expected reason class>
assert_block() {
  local name="$1" reason="$2" action
  check "$name: exit code is 2 (block)" "2" "$GUARD_RC"
  action="$(jq -r '.action // ""' "$GUARD_OUT" 2>/dev/null)"
  check "$name: stdout action is block" "block" "$action"
  if grep -qF -- "$reason" "$GUARD_ERR"; then
    ok "$name: stderr names the failure class '$reason'"
  else
    bad "$name: stderr did not name '$reason'"
  fi
}

# ---------------------------------------------------------------------------
echo "== block paths =="
run_guard '{"hook_event_name":"pre_tool_call","tool_name":"read_file","tool_input":{"path":"/root/.hermes/profiles/default/.env"}}'
check "secret-file argument: exit code is 0" "0" "$GUARD_RC"
check "secret-file argument: decision is block" "block" "$(jq -r '.action // ""' "$GUARD_OUT")"
if jq -r '.message // ""' "$GUARD_OUT" | grep -q 'secret material'; then
  ok "secret-file argument: message names secret material"
else
  bad "secret-file argument: message did not name secret material"
fi

run_guard '{"hook_event_name":"pre_tool_call","tool_name":"terminal","tool_input":{"command":"printenv"}}'
check "env dump command: exit code is 0" "0" "$GUARD_RC"
check "env dump command: decision is block" "block" "$(jq -r '.action // ""' "$GUARD_OUT")"
if jq -r '.message // ""' "$GUARD_OUT" | grep -q 'enumeration'; then
  ok "env dump command: message names enumeration"
else
  bad "env dump command: message did not name enumeration"
fi

run_guard '{"hook_event_name":"pre_tool_call","tool_name":"terminal","tool_input":{"command":"cat /srv/app/secret-store"}}'
check "secret-harvest shell command: exit code is 0" "0" "$GUARD_RC"
check "secret-harvest shell command: decision is block" "block" "$(jq -r '.action // ""' "$GUARD_OUT")"
if jq -r '.message // ""' "$GUARD_OUT" | grep -q 'harvest secrets'; then
  ok "secret-harvest shell command: message names harvesting"
else
  bad "secret-harvest shell command: message did not name harvesting"
fi

run_guard '{"hook_event_name":"pre_tool_call","tool_name":"cronjob_manage","tool_input":{"action":"create"}}'
check "persistence tool: exit code is 0" "0" "$GUARD_RC"
check "persistence tool: decision is approve" "approve" "$(jq -r '.action // ""' "$GUARD_OUT")"
check "persistence tool: rule key is the tool name" "guard:cronjob_manage" "$(jq -r '.rule_key // ""' "$GUARD_OUT")"

# ---------------------------------------------------------------------------
echo
echo "== allow path =="
run_guard '{"hook_event_name":"pre_tool_call","tool_name":"read_file","tool_input":{"path":"/workspace/project/hybrid-ai/README.md"}}'
check "benign payload: exit code is 0" "0" "$GUARD_RC"
check "benign payload: decision is {}" "{}" "$(jq -c '.' "$GUARD_OUT")"
check "benign payload: nothing on stderr" "" "$(cat "$GUARD_ERR")"

# ---------------------------------------------------------------------------
echo
echo "== fail-closed paths =="
run_guard 'this is not json {'
assert_block "malformed JSON" "unparseable payload"

run_guard '[1, 2, 3]'
assert_block "non-object JSON" "unexpected payload shape"

run_guard ''
assert_block "empty stdin" "unparseable payload"

run_guard '{"hook_event_name":"post_tool_call","tool_name":"read_file","tool_input":{}}'
assert_block "wrong hook_event_name" "unexpected event"

run_guard '{"hook_event_name":"pre_tool_call","tool_input":{}}'
assert_block "missing tool_name" "unexpected payload shape"

run_guard '{"hook_event_name":"pre_tool_call","tool_name":"","tool_input":{}}'
assert_block "empty tool_name" "unexpected payload shape"

run_guard '{"hook_event_name":"pre_tool_call","tool_name":"terminal","tool_input":"printenv"}'
assert_block "non-dict tool_input" "unexpected payload shape"

# The baseline's fail-open hole: an unparseable payload must never exit 1.
run_guard 'not-json-at-all'
if [[ "$GUARD_RC" == "1" ]]; then
  bad "fail-closed: an unparseable payload still exits 1 (the baseline's allow)"
else
  ok "fail-closed: an unparseable payload does not exit 1"
fi

# No secret value may ever appear on stderr, whatever the payload.
if grep -q 'SUPERSECRETVALUE' "$GUARD_ERR"; then
  bad "fail-closed: stderr echoed payload content"
else
  ok "fail-closed: stderr never echoes the payload"
fi

# ---------------------------------------------------------------------------
# Installer: same code path as install.sh STEP 9a-3, fixture directories only.
# ---------------------------------------------------------------------------
echo
echo "== installer step (fixture profiles, stubbed hermes) =="

APP="$WORK/app"
BIN="$WORK/bin"
BIN_ROOT="$WORK/bin-root"
DATA="$WORK/data"
SHIM="$WORK/shim"
mkdir -p "$APP/hermes/agent-hooks" "$BIN" "$BIN_ROOT" "$DATA/profiles/default" \
         "$DATA/profiles/builder" "$SHIM"
cp "$GUARD" "$APP/hermes/agent-hooks/secret-guard.py"
chmod +x "$APP/hermes/agent-hooks/secret-guard.py"

# Fixture configs, JSON on disk (valid YAML, and what `config get --json`
# prints). `default` already carries a PEER hook that must survive.
printf '{"hooks":{"pre_tool_call":[{"command":"/opt/peer/audit.py","timeout":5}]}}\n' \
  > "$DATA/profiles/default/config.yaml"
printf '{"profile":"builder"}\n' > "$DATA/profiles/builder/config.yaml"

# Stub hermes: config get/set only, backed by <profile>/config.yaml via jq.
# It deliberately REPLACES the list on set, exactly like the real CLI, so the
# installer's read-append-write is genuinely exercised.
cat > "$BIN/hermes" <<'EOF'
#!/usr/bin/env bash
# argv: -p <profile> config get <key> --json | -p <profile> config set <key> <value>
set -uo pipefail
printf '%s\n' "$*" >> "${HERMES_ARGV_LOG:-/dev/null}"
[[ "${1:-}" == "-p" ]] || { echo "stub hermes: expected -p" >&2; exit 64; }
profile="$2"; shift 2
[[ "${1:-}" == "config" ]] || { echo "stub hermes: expected config" >&2; exit 64; }
verb="${2:-}"; key="${3:-}"
cfg="${HERMES_HOME:-/nonexistent}/profiles/${profile}/config.yaml"
[[ -f "$cfg" ]] || { echo "stub hermes: no config at ${cfg}" >&2; exit 66; }
case "$verb" in
  get)
    jq -c --arg k "$key" 'getpath($k | split(".")) // null' "$cfg" 2>/dev/null || echo null
    ;;
  set)
    value="${4:-}"
    tmp="$(mktemp "${cfg}.XXXXXX")"
    if jq --arg k "$key" --argjson v "$value" \
        'setpath($k | split("."); $v)' "$cfg" > "$tmp" 2>/dev/null; then
      mv -f "$tmp" "$cfg"
    else
      rm -f "$tmp"
      echo "stub hermes: cannot coerce value for ${key}" >&2
      exit 65
    fi
    ;;
  *) echo "stub hermes: unknown verb ${verb}" >&2; exit 64 ;;
esac
EOF
chmod +x "$BIN/hermes"

# Stub docker, used only by the transport cases below. It answers
# `inspect -f '{{.State.Running}}' hermes-agent` from DOCKER_RUNNING and runs
# `exec hermes-agent <absolute-cli> ...` against the same fixture configs, so
# the docker path exercises the real get/set logic with no daemon at all.
# The absolute CLI path is required: a bare `hermes` would prove nothing.
cat > "$BIN/docker" <<'EOF'
#!/usr/bin/env bash
# argv: inspect -f <tmpl> hermes-agent | exec hermes-agent <cli> -p <p> config ...
set -uo pipefail
printf '%s\n' "$*" >> "${DOCKER_ARGV_LOG:-/dev/null}"
case "${1:-}" in
  inspect)
    printf '%s\n' "${DOCKER_RUNNING:-false}"
    [[ "${DOCKER_RUNNING:-false}" == "true" ]] || exit 1
    ;;
  exec)
    shift
    [[ "${1:-}" == "hermes-agent" ]] || { echo "stub docker: expected hermes-agent" >&2; exit 64; }
    shift
    cli="${1:-}"; shift
    [[ "$cli" == /* ]] || { echo "stub docker: CLI path is not absolute: ${cli}" >&2; exit 64; }
    [[ "${1:-}" == "-p" ]] || { echo "stub docker: expected -p" >&2; exit 64; }
    profile="${2:-}"; shift 2
    [[ "${1:-}" == "config" ]] || { echo "stub docker: expected config" >&2; exit 64; }
    verb="${2:-}"; key="${3:-}"
    cfg="${DOCKER_HERMES_ROOT:-/nonexistent}/profiles/${profile}/config.yaml"
    [[ -f "$cfg" ]] || { echo "stub docker: no config at ${cfg}" >&2; exit 66; }
    case "$verb" in
      get)
        jq -c --arg k "$key" 'getpath($k | split(".")) // null' "$cfg" 2>/dev/null || echo null
        ;;
      set)
        value="${4:-}"
        tmp="$(mktemp "${cfg}.XXXXXX")"
        if jq --arg k "$key" --argjson v "$value" \
            'setpath($k | split("."); $v)' "$cfg" > "$tmp" 2>/dev/null; then
          mv -f "$tmp" "$cfg"
        else
          rm -f "$tmp"
          echo "stub docker: cannot coerce value for ${key}" >&2
          exit 65
        fi
        ;;
      *) echo "stub docker: unknown verb ${verb}" >&2; exit 64 ;;
    esac
    ;;
  *)
    echo "stub docker: unsupported argv: $*" >&2
    exit 64
    ;;
esac
EOF
chmod +x "$BIN/docker"

# Two docker-only PATHs: the same stub with a controlling DOCKER_RUNNING, and
# the handful of tools install_secret_guard_hook needs. Neither carries a
# `hermes` binary, so the docker transport is the only one available.
BIN_DOCKER="$WORK/bin-docker"
BIN_MIN="$WORK/bin-min"
mkdir -p "$BIN_DOCKER" "$BIN_MIN"
cp "$BIN/docker" "$BIN_DOCKER/docker"
chmod +x "$BIN_DOCKER/docker"
for t in bash install stat cmp basename jq mktemp mv; do
  ln -s "$(command -v "$t")" "$BIN_MIN/$t"
done

# Root variant: only `id` differs, so it wins on PATH ahead of BIN.
# shellcheck disable=SC2016  # $@ must expand inside the generated stub
printf '#!/usr/bin/env bash\nif [[ "${1:-}" == "-u" ]]; then printf "0\\n"; exit 0; fi\nif [[ "${1:-}" == "-g" ]]; then printf "1000\\n"; exit 0; fi\nexec /usr/bin/id "$@"\n' > "$BIN_ROOT/id"
chmod +x "$BIN_ROOT/id"

# Extract the STEP 9a-3 function into a scratch shim. install.sh is a hard
# 2,000-line, set -Eeuo pipefail program that needs Docker at STEP 1; sourcing
# it is not possible offline. The shim gives the EXACT function body the same
# helpers install.sh provides and nothing else, so the code under test is the
# real code, byte-for-byte.
extract_function() {
  local name="$1"
  awk -v fn="$name" '
    $0 ~ "^" fn "\\(\\) \\{" { inside = 1 }
    inside { print }
    inside && /^\}$/ { exit }
  ' "$REPO/install.sh"
}

GUARD_FN="$(extract_function install_secret_guard_hook)"
if [[ -z "$GUARD_FN" ]]; then
  bad "could not extract install_secret_guard_hook from install.sh"
fi

cat > "$SHIM/step.sh" <<EOF
set -uo pipefail
warn()  { printf '[ ! ] %s\n' "\$*" >&2; }
ok()    { printf '[ OK ] %s\n' "\$*"; }
event() { local name="\$1"; shift; printf 'EVENT event=%s %s\n' "\$name" "\$*" >> "\${INSTALL_LOG:-/dev/null}"; }
APP_DIR="$APP"
HYBRID_AI_HERMES_DATA_DIR="$DATA"

$GUARD_FN
EOF

# Provide the extracted body too, in case awk missed it (defensive: the test
# must fail loudly, not silently pass).
if ! grep -q 'install_secret_guard_hook' "$SHIM/step.sh"; then
  bad "the shim does not contain install_secret_guard_hook"
fi

INSTALL_LOG="$WORK/install.log"
: > "$INSTALL_LOG"
GUARD_TARGET="$DATA/profiles/default/agent-hooks/secret-guard.py"

run_step() {
  local rc=0
  PATH="${RUN_PATH:-$BIN:$PATH}" INSTALL_LOG="$INSTALL_LOG" \
    HERMES_ARGV_LOG="${HERMES_ARGV_LOG:-/dev/null}" \
    DOCKER_ARGV_LOG="${DOCKER_ARGV_LOG:-/dev/null}" \
    DOCKER_RUNNING="${DOCKER_RUNNING:-false}" \
    DOCKER_HERMES_ROOT="${DOCKER_HERMES_ROOT:-$DATA}" \
    bash -c "source '$SHIM/step.sh'; install_secret_guard_hook" >> "$WORK/step.log" 2>&1 || rc=$?
  return "$rc"
}

# config_bytes <profile> - the config's content, whitespace-normalised, so a
# rewrite with a different key order still reads as a change.
config_bytes() { cat "$DATA/profiles/$1/config.yaml"; }

echo "-- first run --"
: > "$WORK/step.log"
: > "$WORK/hermes-argv.log"
RUN_PATH="$BIN_ROOT:$BIN:$PATH"
HERMES_ARGV_LOG="$WORK/hermes-argv.log"
rc=0
run_step || rc=$?
check "(i) the first run exits 0" "0" "$rc"
if [[ -f "$GUARD_TARGET" ]]; then
  ok "(i) the guard was installed for profile 'default'"
else
  bad "(i) the guard was NOT installed for profile 'default'"
fi
check "(i) the installed guard has mode 0755" "755" "$(stat -c '%a' "$GUARD_TARGET" 2>/dev/null)"
if cmp -s "$GUARD" "$GUARD_TARGET"; then
  ok "(i) the installed guard is byte-identical to the tracked source"
else
  bad "(i) the installed guard differs from the tracked source"
fi
check "(i) the guard was installed for profile 'builder' too" "755" \
  "$(stat -c '%a' "$DATA/profiles/builder/agent-hooks/secret-guard.py" 2>/dev/null)"

cnt="$(jq '[.hooks.pre_tool_call[] | select(.command | endswith("/agent-hooks/secret-guard.py"))] | length' \
  "$DATA/profiles/default/config.yaml" 2>/dev/null)"
check "(i) the guard is declared exactly once in 'default'" "1" "$cnt"
check "(i) the declared command is the CONTAINER path" \
  "/root/.hermes/profiles/default/agent-hooks/secret-guard.py" \
  "$(jq -r '.hooks.pre_tool_call[] | select(.command | endswith("/agent-hooks/secret-guard.py")) | .command' \
     "$DATA/profiles/default/config.yaml" 2>/dev/null)"
check "(i) the entry is fail_closed" "true" \
  "$(jq -r '.hooks.pre_tool_call[] | select(.command | endswith("/agent-hooks/secret-guard.py")) | .fail_closed' \
     "$DATA/profiles/default/config.yaml" 2>/dev/null)"
check "(i) the entry has a 10s timeout" "10" \
  "$(jq -r '.hooks.pre_tool_call[] | select(.command | endswith("/agent-hooks/secret-guard.py")) | .timeout' \
     "$DATA/profiles/default/config.yaml" 2>/dev/null)"

cnt_peer="$(jq '[.hooks.pre_tool_call[] | select(.command == "/opt/peer/audit.py")] | length' \
  "$DATA/profiles/default/config.yaml" 2>/dev/null)"
check "(i) the peer hook survived the write" "1" "$cnt_peer"
check "(i) the peer hook kept its timeout" "5" \
  "$(jq -r '.hooks.pre_tool_call[] | select(.command == "/opt/peer/audit.py") | .timeout' \
     "$DATA/profiles/default/config.yaml" 2>/dev/null)"

if grep -q 'hooks_auto_accept' "$DATA/profiles/default/config.yaml" "$DATA/profiles/builder/config.yaml"; then
  bad "(i) hooks_auto_accept was written (silent blanket trust)"
else
  ok "(i) hooks_auto_accept was NOT written"
fi

if grep -q 'EVENT event=secret_guard_hook_installed' "$INSTALL_LOG"; then
  ok "(i) secret_guard_hook_installed was recorded"
else
  bad "(i) secret_guard_hook_installed was not recorded"
fi

echo "-- second run (idempotency) --"
cp "$DATA/profiles/default/config.yaml" "$WORK/default.before"
cp "$DATA/profiles/builder/config.yaml" "$WORK/builder.before"
before_mode="$(stat -c '%a' "$GUARD_TARGET")"
before_mtime="$(stat -c '%Y' "$GUARD_TARGET")"
sleep 1
: > "$WORK/step.log"
: > "$WORK/hermes-argv.log"
rc=0
run_step || rc=$?
check "(j) the second run exits 0" "0" "$rc"
check "(j) the guard mode is unchanged" "$before_mode" "$(stat -c '%a' "$GUARD_TARGET" 2>/dev/null)"
check "(j) the guard mtime is unchanged (consent stays valid)" "$before_mtime" \
  "$(stat -c '%Y' "$GUARD_TARGET" 2>/dev/null)"
if cmp -s "$WORK/default.before" "$DATA/profiles/default/config.yaml"; then
  ok "(j) the 'default' config is byte-identical after the second run"
else
  bad "(j) the 'default' config changed on the second run"
fi
if cmp -s "$WORK/builder.before" "$DATA/profiles/builder/config.yaml"; then
  ok "(j) the 'builder' config is byte-identical after the second run"
else
  bad "(j) the 'builder' config changed on the second run"
fi
check "(j) the guard is still declared exactly once" "1" \
  "$(jq '[.hooks.pre_tool_call[] | select(.command | endswith("/agent-hooks/secret-guard.py"))] | length' \
     "$DATA/profiles/default/config.yaml" 2>/dev/null)"
if grep -q ' config set ' "$WORK/hermes-argv.log"; then
  bad "(j) the second run still called 'config set'"
else
  ok "(j) the second run called no 'config set'"
fi

echo "-- non-root (unwritable profile: warn + event + exit 0) --"
rm -rf "$DATA/profiles/default/agent-hooks"
cp "$WORK/default.before" "$DATA/profiles/default/config.yaml"
: > "$WORK/step.log"
: > "$INSTALL_LOG"
chmod 500 "$DATA/profiles/default"
rc=0
env PATH="$BIN_ROOT:$BIN:$PATH" INSTALL_LOG="$INSTALL_LOG" HERMES_ARGV_LOG=/dev/null \
  bash -c "source '$SHIM/step.sh'; install_secret_guard_hook" >> "$WORK/step.log" 2>&1 || rc=$?
chmod 755 "$DATA/profiles/default"
check "(k) an unwritable (non-root) profile still exits 0" "0" "$rc"
if [[ -f "$GUARD_TARGET" ]]; then
  bad "(k) the unwritable profile got a guard installed"
else
  ok "(k) nothing was written into the unwritable profile"
fi
if grep -q 'EVENT event=secret_guard_hook_failed .*reason=install_failed .*profile=default' "$INSTALL_LOG"; then
  ok "(k) install_failed was recorded with the profile name"
else
  bad "(k) install_failed was not recorded"
fi

echo "-- fail-safe: missing hermes CLI --"
rm -rf "$DATA/profiles/default/agent-hooks" "$DATA/profiles/builder/agent-hooks"
: > "$WORK/step.log"
: > "$INSTALL_LOG"
rc=0
# BIN_MIN holds neither hermes nor docker on purpose: the installer now also
# probes docker, and an ambient PATH on a Docker host would let the docker
# transport reach the LIVE hermes-agent container. This suite stays offline.
env PATH="$BIN_MIN" INSTALL_LOG="$INSTALL_LOG" HERMES_ARGV_LOG=/dev/null \
  bash -c "source '$SHIM/step.sh'; install_secret_guard_hook" >> "$WORK/step.log" 2>&1 || rc=$?
check "(m) a missing hermes CLI exits 0" "0" "$rc"
if grep -q 'EVENT event=secret_guard_hook_failed .*reason=hermes_missing' "$INSTALL_LOG"; then
  ok "(m) hermes_missing was recorded"
else
  bad "(m) hermes_missing was not recorded"
fi
for p in default builder; do
  check "(m) nothing was placed for '${p}'" "gone" \
    "$( [[ -e "$DATA/profiles/$p/agent-hooks/secret-guard.py" ]] && echo present || echo gone )"
done

echo "-- fail-safe: no profiles directory --"
: > "$INSTALL_LOG"
rc=0
env PATH="$BIN_ROOT:$BIN:$PATH" INSTALL_LOG="$INSTALL_LOG" HERMES_ARGV_LOG=/dev/null \
  HYBRID_AI_HERMES_DATA_DIR="$WORK/no-such-data" \
  bash -c "source '$SHIM/step.sh'; HYBRID_AI_HERMES_DATA_DIR='$WORK/no-such-data' APP_DIR='$APP'; install_secret_guard_hook" \
  >> "$WORK/step.log" 2>&1 || rc=$?
check "(n) a missing profiles dir exits 0" "0" "$rc"
if grep -q 'EVENT event=secret_guard_hook_skipped .*reason=no_profiles' "$INSTALL_LOG"; then
  ok "(n) no_profiles was recorded"
else
  bad "(n) no_profiles was not recorded"
fi

echo "-- fail-safe: unreadable config value --"
rm -rf "$DATA/profiles/default/agent-hooks"
cp "$WORK/default.before" "$DATA/profiles/default/config.yaml"
: > "$WORK/step.log"
: > "$INSTALL_LOG"
rc=0
env PATH="$BIN_ROOT:$BIN:$PATH" INSTALL_LOG="$INSTALL_LOG" HERMES_ARGV_LOG=/dev/null \
  bash -c "source '$SHIM/step.sh'; hermes() { return 1; }; install_secret_guard_hook" \
  >> "$WORK/step.log" 2>&1 || rc=$?
check "(o) a failing config get exits 0" "0" "$rc"
if grep -q 'EVENT event=secret_guard_hook_failed .*reason=config_get_failed' "$INSTALL_LOG"; then
  ok "(o) config_get_failed was recorded"
else
  bad "(o) config_get_failed was not recorded"
fi

# ---------------------------------------------------------------------------
# Transport: no host hermes CLI, a running hermes-agent container. Same code
# path as install.sh STEP 9a-3, reached through `docker exec`.
# ---------------------------------------------------------------------------
echo "-- docker transport (no host hermes, container running) --"
reset_fixtures() {
  rm -rf "$DATA/profiles/default/agent-hooks" "$DATA/profiles/builder/agent-hooks"
  printf '{"hooks":{"pre_tool_call":[{"command":"/opt/peer/audit.py","timeout":5}]}}\n' \
    > "$DATA/profiles/default/config.yaml"
  printf '{"profile":"builder"}\n' > "$DATA/profiles/builder/config.yaml"
}

reset_fixtures
: > "$WORK/step.log"
: > "$INSTALL_LOG"
: > "$WORK/docker-argv.log"
RUN_PATH="$BIN_DOCKER:$BIN_MIN"
DOCKER_ARGV_LOG="$WORK/docker-argv.log"
DOCKER_RUNNING="true"
rc=0
run_step || rc=$?
check "(p) the docker-transport run exits 0" "0" "$rc"
check "(p) the guard is installed 0755 for 'default' over docker" "755" \
  "$(stat -c '%a' "$DATA/profiles/default/agent-hooks/secret-guard.py" 2>/dev/null)"
check "(p) the guard is installed 0755 for 'builder' over docker" "755" \
  "$(stat -c '%a' "$DATA/profiles/builder/agent-hooks/secret-guard.py" 2>/dev/null)"
if cmp -s "$GUARD" "$DATA/profiles/default/agent-hooks/secret-guard.py"; then
  ok "(p) the docker-installed guard is byte-identical to the tracked source"
else
  bad "(p) the docker-installed guard differs from the tracked source"
fi
check "(p) the guard is declared exactly once in 'default' over docker" "1" \
  "$(jq '[.hooks.pre_tool_call[] | select(.command | endswith("/agent-hooks/secret-guard.py"))] | length' \
     "$DATA/profiles/default/config.yaml" 2>/dev/null)"
check "(p) the declared command is the CONTAINER path" \
  "/root/.hermes/profiles/default/agent-hooks/secret-guard.py" \
  "$(jq -r '.hooks.pre_tool_call[] | select(.command | endswith("/agent-hooks/secret-guard.py")) | .command' \
     "$DATA/profiles/default/config.yaml" 2>/dev/null)"
check "(p) the entry matcher is .*" ".*" \
  "$(jq -r '.hooks.pre_tool_call[] | select(.command | endswith("/agent-hooks/secret-guard.py")) | .matcher' \
     "$DATA/profiles/default/config.yaml" 2>/dev/null)"
check "(p) the entry has a 10s timeout" "10" \
  "$(jq -r '.hooks.pre_tool_call[] | select(.command | endswith("/agent-hooks/secret-guard.py")) | .timeout' \
     "$DATA/profiles/default/config.yaml" 2>/dev/null)"
check "(p) the entry is fail_closed" "true" \
  "$(jq -r '.hooks.pre_tool_call[] | select(.command | endswith("/agent-hooks/secret-guard.py")) | .fail_closed' \
     "$DATA/profiles/default/config.yaml" 2>/dev/null)"
check "(p) the peer hook survived the docker write" "1" \
  "$(jq '[.hooks.pre_tool_call[] | select(.command == "/opt/peer/audit.py")] | length' \
     "$DATA/profiles/default/config.yaml" 2>/dev/null)"
if grep -q 'EVENT event=secret_guard_hook_installed' "$INSTALL_LOG"; then
  ok "(p) secret_guard_hook_installed was recorded over docker"
else
  bad "(p) secret_guard_hook_installed was not recorded over docker"
fi
if grep -qF 'exec hermes-agent /opt/hermes-agent/.hermes/bin/hermes -p default config get hooks.pre_tool_call --json' \
    "$WORK/docker-argv.log"; then
  ok "(p) the docker get uses the ABSOLUTE in-container CLI path"
else
  bad "(p) the docker get did not use /opt/hermes-agent/.hermes/bin/hermes"
fi
if grep -qF 'exec hermes-agent /opt/hermes-agent/.hermes/bin/hermes -p builder config set hooks.pre_tool_call' \
    "$WORK/docker-argv.log"; then
  ok "(p) the docker set uses the ABSOLUTE in-container CLI path"
else
  bad "(p) the docker set did not use /opt/hermes-agent/.hermes/bin/hermes"
fi
if grep -q 'config get' "$WORK/docker-argv.log" \
   && ! grep -qE '(^| )(hermes)( |$)' "$WORK/docker-argv.log"; then
  ok "(p) no bare hermes was invoked inside the container"
else
  bad "(p) a bare hermes invocation reached the docker stub"
fi
if grep -qE 'HERMES_HOME|HYBRID_AI_HERMES_DATA_DIR|docker exec -e| exec .* -e ' "$WORK/docker-argv.log"; then
  bad "(p) a host HERMES_HOME / HYBRID_AI_HERMES_DATA_DIR was passed into the container"
else
  ok "(p) no host HERMES_HOME / HYBRID_AI_HERMES_DATA_DIR crossed into the container"
fi

echo "-- docker transport second run (idempotency) --"
cp "$DATA/profiles/default/config.yaml" "$WORK/default.docker.before"
cp "$DATA/profiles/builder/config.yaml" "$WORK/builder.docker.before"
before_mode="$(stat -c '%a' "$DATA/profiles/default/agent-hooks/secret-guard.py")"
before_mtime="$(stat -c '%Y' "$DATA/profiles/default/agent-hooks/secret-guard.py")"
sleep 1
: > "$WORK/step.log"
: > "$INSTALL_LOG"
: > "$WORK/docker-argv.log"
rc=0
run_step || rc=$?
check "(q) the second docker run exits 0" "0" "$rc"
check "(q) the guard mode is unchanged over docker" "$before_mode" \
  "$(stat -c '%a' "$DATA/profiles/default/agent-hooks/secret-guard.py" 2>/dev/null)"
check "(q) the guard mtime is unchanged over docker (consent stays valid)" "$before_mtime" \
  "$(stat -c '%Y' "$DATA/profiles/default/agent-hooks/secret-guard.py" 2>/dev/null)"
if cmp -s "$WORK/default.docker.before" "$DATA/profiles/default/config.yaml"; then
  ok "(q) the 'default' config is byte-identical after the second docker run"
else
  bad "(q) the 'default' config changed on the second docker run"
fi
if cmp -s "$WORK/builder.docker.before" "$DATA/profiles/builder/config.yaml"; then
  ok "(q) the 'builder' config is byte-identical after the second docker run"
else
  bad "(q) the 'builder' config changed on the second docker run"
fi
if grep -q ' config set ' "$WORK/docker-argv.log"; then
  bad "(q) the second docker run still called 'config set'"
else
  ok "(q) the second docker run called no 'config set'"
fi
if grep -q ' config get ' "$WORK/docker-argv.log"; then
  ok "(q) the second docker run still issued 'config get'"
else
  bad "(q) the second docker run issued no 'config get'"
fi

echo "-- fail-safe: no transport (container not running) --"
reset_fixtures
: > "$WORK/step.log"
: > "$INSTALL_LOG"
: > "$WORK/docker-argv.log"
DOCKER_RUNNING="false"
rc=0
run_step || rc=$?
check "(r) a stopped hermes-agent container exits 0" "0" "$rc"
if grep -q 'EVENT event=secret_guard_hook_failed .*reason=hermes_missing' "$INSTALL_LOG"; then
  ok "(r) hermes_missing was recorded for a stopped container"
else
  bad "(r) hermes_missing was not recorded for a stopped container"
fi
if [[ -e "$DATA/profiles/default/agent-hooks/secret-guard.py" \
   || -e "$DATA/profiles/builder/agent-hooks/secret-guard.py" ]]; then
  bad "(r) a guard was placed with no transport"
else
  ok "(r) nothing was placed with no transport"
fi
if grep -q 'exec ' "$WORK/docker-argv.log"; then
  bad "(r) the stopped container was still exec'd into"
else
  ok "(r) the stopped container was never exec'd into"
fi

echo "-- fail-safe: no transport (no docker on PATH) --"
reset_fixtures
: > "$WORK/step.log"
: > "$INSTALL_LOG"
RUN_PATH="$BIN_MIN"
DOCKER_RUNNING="true"
rc=0
run_step || rc=$?
check "(s) a docker-less PATH exits 0" "0" "$rc"
if grep -q 'EVENT event=secret_guard_hook_failed .*reason=hermes_missing' "$INSTALL_LOG"; then
  ok "(s) hermes_missing was recorded with no docker on PATH"
else
  bad "(s) hermes_missing was not recorded with no docker on PATH"
fi
if [[ -e "$DATA/profiles/default/agent-hooks/secret-guard.py" ]]; then
  bad "(s) a guard was placed with no docker on PATH"
else
  ok "(s) nothing was placed with no docker on PATH"
fi

# ---------------------------------------------------------------------------
echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
