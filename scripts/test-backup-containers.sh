#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/test-backup-containers.sh
# PURPOSE (plain English):
#   Offline tests for backup/backup-containers.sh, the ONE root helper that is
#   allowed to talk to Docker in system mode. They need no Docker, no network
#   and no root: a stub `docker` records the argv it is given, and a stub `id`
#   lets the root-only gate be exercised from an unprivileged test run.
#
# COVERED:
#   a) non-root -> exit 1 (root-only gate)
#   b) an unknown verb, and a verb plus an extra argument -> exit 2
#   c) pause    -> pauses exactly the fixed APP_CONTAINERS that are running,
#                  records them under the runtime dir, never stops/starts one
#   d) unpause  -> is idempotent and succeeds (exit 0) when nothing was paused
#   e) the helper takes NO container name from its arguments: `pause open-webui`
#      is a usage error, not a pause of open-webui
#   f) host-info -> writes docker's version and the model list under the
#                   runtime dir only
#   g) it never issues `docker stop`, `docker start`, `docker kill` or
#      `docker rm` in any verb
#
# USAGE:
#   bash scripts/test-backup-containers.sh
#
# EXIT CODES:
#   0  every case passed
#   1  one or more cases failed
#   2  a required tool is missing
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_SRC="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
HELPER="$REPO_SRC/backup/backup-containers.sh"

if [[ ! -f "$HELPER" ]]; then
  echo "FATAL: cannot find $HELPER" >&2
  exit 2
fi
command -v mktemp >/dev/null 2>&1 || { echo "error: mktemp is required" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$(( PASS + 1 )); printf 'ok   %s\n' "$*"; }
bad()  { FAIL=$(( FAIL + 1 )); printf 'FAIL %s\n' "$*" >&2; }
assert() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

BIN="$WORK/bin"; mkdir -p "$BIN"
DOCKER_LOG="$WORK/docker.log"
RUN_DIR="$WORK/run"
export DOCKER_LOG

# Stub docker: record argv; report a running status for the containers we want
# "up"; return 0 for pause/unpause. It never actually touches a container.
cat > "$BIN/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_LOG"
case "$1" in
  inspect)
    # $* == inspect -f {{.State.Status}} <name>
    name="${@: -1}"
    case "${RUNNING_NAMES:-}" in
      *"${name}"*) echo running ;;
      *) echo exited ;;
    esac
    exit 0 ;;
  exec)
    # ollama list -> a header plus one model name
    printf 'NAME\tSIZE\nllama3:latest\t4GB\n'
    exit 0 ;;
  version) echo '27.0.0'; exit 0 ;;
  *) exit 0 ;;
esac
EOF

# Stub id: `id -u` prints the UID override; `id <user>` succeeds when the user
# is in ID_USERS. This is how the root-only gate is exercised without root.
cat > "$BIN/id" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-u" ]]; then
  echo "${ID_UID_OVERRIDE:-0}"
  exit 0
fi
case " ${ID_USERS:-} " in
  *" ${1:-} "*) exit 0 ;;
  *) exit 1 ;;
esac
EOF

# Stub chown so handing files to the service account never needs root.
cat > "$BIN/chown" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

chmod +x "$BIN"/*

run_helper() { # env... -- verb...
  local -a envs=() args=()
  local seen=0
  for a in "$@"; do
    if [[ "$a" == "--" ]]; then seen=1; continue; fi
    if (( seen )); then args+=("$a"); else envs+=("$a"); fi
  done
  : > "$DOCKER_LOG"
  HELPER_RC=0
  env "${envs[@]}" bash "$HELPER" "${args[@]}" > "$WORK/out" 2>&1 || HELPER_RC=$?
}

BASE_ENV=(
  "PATH=$BIN:$PATH"
  "BACKUP_CONTROL_RUN_DIR=$RUN_DIR"
  "RUNNING_NAMES=open-webui hermes-agent ollama"
  "ID_UID_OVERRIDE=0"
  "ID_USERS=hybrid-ai-backup"
)

echo "== backup-containers.sh tests =="

# a) root-only gate: a non-root caller is refused with exit 1.
run_helper "PATH=$BIN:$PATH" "BACKUP_CONTROL_RUN_DIR=$RUN_DIR" "ID_UID_OVERRIDE=1000" -- pause
assert "non-root is refused" test "$HELPER_RC" -eq 1

# b) usage errors: no verb, and an unknown verb -> exit 2.
run_helper "${BASE_ENV[@]}" --
assert "no verb is a usage error" test "$HELPER_RC" -eq 2
run_helper "${BASE_ENV[@]}" -- frobnicate
assert "unknown verb is a usage error" test "$HELPER_RC" -eq 2

# e) no container name may come from the arguments.
run_helper "${BASE_ENV[@]}" -- pause open-webui
assert "a container name argument is a usage error (never taken from argv)" test "$HELPER_RC" -eq 2
assert "the rejected invocation issued no docker command" bash -c "[[ ! -s '$DOCKER_LOG' ]]"

# c) pause pauses exactly the fixed set that is running and records it.
rm -rf "$RUN_DIR"
run_helper "${BASE_ENV[@]}" -- pause
assert "pause succeeds" test "$HELPER_RC" -eq 0
assert "pause pauses open-webui"       bash -c "grep -qx 'pause open-webui' '$DOCKER_LOG'"
assert "pause pauses hermes-agent"     bash -c "grep -qx 'pause hermes-agent' '$DOCKER_LOG'"
assert "pause records exactly the paused set" \
  bash -c "[[ \"\$(cat '$RUN_DIR/paused')\" == \$'open-webui\nhermes-agent' ]]"
assert "pause never stops a container"  bash -c "! grep -Eq '^(stop|start|kill|rm) ' '$DOCKER_LOG'"
assert "pause never starts a container" bash -c "! grep -q '^start ' '$DOCKER_LOG'"

# c2) a container that is not running is skipped, never started.
rm -rf "$RUN_DIR"
run_helper "PATH=$BIN:$PATH" "BACKUP_CONTROL_RUN_DIR=$RUN_DIR" \
  "RUNNING_NAMES=open-webui" "ID_UID_OVERRIDE=0" "ID_USERS=hybrid-ai-backup" -- pause
assert "pause skips a container that is not running" \
  bash -c "! grep -qx 'pause hermes-agent' '$DOCKER_LOG'"
assert "pause records only the running container" \
  bash -c "[[ \"\$(cat '$RUN_DIR/paused')\" == 'open-webui' ]]"

# d) unpause is idempotent and succeeds when nothing is paused.
rm -rf "$RUN_DIR"
run_helper "${BASE_ENV[@]}" -- unpause
assert "unpause succeeds when nothing is paused" test "$HELPER_RC" -eq 0
assert "unpause unpauses the fixed set" \
  bash -c "grep -qx 'unpause open-webui' '$DOCKER_LOG' && grep -qx 'unpause hermes-agent' '$DOCKER_LOG'"
assert "unpause never stops or starts a container" \
  bash -c "! grep -Eq '^(stop|start|kill|rm) ' '$DOCKER_LOG'"
assert "unpause clears the paused record" bash -c "[[ ! -e '$RUN_DIR/paused' ]]"

# f) host-info writes docker's version and the model list under the run dir.
rm -rf "$RUN_DIR"
run_helper "${BASE_ENV[@]}" -- host-info
assert "host-info succeeds" test "$HELPER_RC" -eq 0
assert "host-info records docker's server version" \
  bash -c "grep -qx '27.0.0' '$RUN_DIR/host-info/platform-docker.txt'"
assert "host-info records the model names" \
  bash -c "grep -qx 'llama3:latest' '$RUN_DIR/host-info/ollama-models.txt'"
assert "host-info never stops or starts a container" \
  bash -c "! grep -Eq '^(stop|start|kill|rm) ' '$DOCKER_LOG'"

# g) the helper never writes outside its runtime directory. The only paths that
# may hold files are the runtime dir, the stub bin, the docker-argv log and the
# scratch output file the test itself writes. Anything else is a violation.
OUTSIDE="$(mktemp)"
find "$WORK" -type f \
  ! -path "$RUN_DIR/*" ! -path "$BIN/*" ! -path "$DOCKER_LOG" ! -path "$WORK/out" \
  > "$OUTSIDE" 2>/dev/null || true
assert "the helper wrote only under its runtime directory" \
  bash -c "[[ ! -s '$OUTSIDE' ]]"
rm -f "$OUTSIDE"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
