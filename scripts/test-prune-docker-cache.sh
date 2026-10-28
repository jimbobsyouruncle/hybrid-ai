#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/test-prune-docker-cache.sh
# PURPOSE (plain English):
#   Prove scripts/prune-docker-cache.sh caps the Docker build cache, probes the
#   right cap flag, and degrades safely, entirely offline.
#
#   There is no Docker and no systemd on a CI runner, so this harness never
#   touches a real daemon. docker, df and date are stubbed on PATH and every
#   case drives the script through those stubs and reads back the recorded
#   docker argv. The unit files are asserted statically by grep.
#
#   Cases proven here (each a clear PASS or FAIL):
#     (a) docker CLI absent     -> exit 0, logs "docker CLI not found".
#     (b) daemon unreachable    -> exit 0, prune never invoked.
#     (c) success, --max-used-space listed -> prune invoked with
#         "--max-used-space 15GB" and exit 0.
#     (d) HYBRID_AI_BUILD_CACHE_CAP override reaches the argv.
#     (e) only --keep-storage listed -> that flag is used, not --max-used-space.
#     (f) prune failure -> exit 1.
#     (g) neither flag listed -> exit 0 without invoking prune.
#     (h) free space is logged before and after, and a failing df never changes
#         the exit status.
#     (i) the unit files carry the required directive lines, and the service has
#         no Restart=.
#     (j) the script is cache-only: no rmi / system prune / path deletion.
#
#   Fully offline: no Docker, no network, no root, no systemd. The harness FAILS
#   LOUDLY (non-zero) when the script under test is missing or not executable.
#
# Usage:
#   bash scripts/test-prune-docker-cache.sh
#
# Exit 0 when every assertion passes, 1 otherwise.
# ---------------------------------------------------------------------------
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
PRUNE="${SCRIPT_DIR}/prune-docker-cache.sh"
SERVICE="${REPO}/deploy/hybrid-ai-docker-prune.service"
TIMER="${REPO}/deploy/hybrid-ai-docker-prune.timer"

if [[ ! -f "$PRUNE" ]]; then
  printf 'FAIL: the script under test is missing: %s\n' "$PRUNE" >&2
  exit 1
fi
if [[ ! -x "$PRUNE" ]]; then
  printf 'FAIL: the script under test is not executable: %s\n' "$PRUNE" >&2
  exit 1
fi

pass=0 fail=0
ok()   { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (want '$3' got '$2')"; fi; }
has() { if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1 (missing '$3')"; fi; }
# Search $1 for a command matching ERE $2, comment lines stripped first. The
# regex is written with a (^|[^[:alnum:]_]) boundary, not `[^#].*`, so a
# command that begins at column 0 is caught.
cache_only_offenders() {  # $1 = file, $2 = ERE
  grep -vE '^[[:space:]]*#' "$1" 2>/dev/null | grep -E "$2"
}

WORK="$(mktemp -d)"
STUB_BIN="$(mktemp -d)"
BIN_MIN="$(mktemp -d)"
trap 'rm -rf "$WORK" "$STUB_BIN" "$BIN_MIN"' EXIT

# --- docker stub -----------------------------------------------------------
# Behaviour follows DOCKER_INFO_RC, DOCKER_PRUNE_RC and DOCKER_HELP
# (max|keep|none|fail). Every call is appended to DOCKER_ARGV_LOG.
cat > "${STUB_BIN}/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${DOCKER_ARGV_LOG:-/dev/null}"
case "${1:-}" in
  info)
    exit "${DOCKER_INFO_RC:-0}"
    ;;
  builder)
    if [[ "${2:-}" == "prune" ]]; then
      for a in "$@"; do
        if [[ "$a" == "--help" ]]; then
          case "${DOCKER_HELP:-max}" in
            max)
              printf 'Usage:  docker builder prune [OPTIONS]\n'
              printf '  -f, --force          Do not prompt for confirmation\n'
              printf '      --max-used-space bytes   Maximum amount of used space\n'
              ;;
            keep)
              printf 'Usage:  docker builder prune [OPTIONS]\n'
              printf '  -f, --force          Do not prompt for confirmation\n'
              printf '      --keep-storage bytes     Amount of disk space to keep\n'
              ;;
            fail)
              exit 1
              ;;
            *)
              printf 'Usage:  docker builder prune [OPTIONS]\n'
              printf '  -f, --force          Do not prompt for confirmation\n'
              ;;
          esac
          exit 0
        fi
      done
      exit "${DOCKER_PRUNE_RC:-0}"
    fi
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
STUB
chmod +x "${STUB_BIN}/docker"

# --- df stub: a plausible table, or a failure ------------------------------
cat > "${STUB_BIN}/df" <<'STUB'
#!/usr/bin/env bash
[[ "${DF_RC:-0}" == "0" ]] || exit "${DF_RC}"
printf 'Filesystem     1024-blocks    Used Available Capacity Mounted on\n'
printf 'overlay          10000000 5000000   5000000      50%% /\n'
STUB
chmod +x "${STUB_BIN}/df"

# --- date stub: a fixed UTC timestamp --------------------------------------
cat > "${STUB_BIN}/date" <<'STUB'
#!/usr/bin/env bash
printf '2026-01-01T00:00:00Z\n'
STUB
chmod +x "${STUB_BIN}/date"

# --- a PATH with NO docker anywhere ----------------------------------------
# Symlink the handful of utilities the script needs out of the SYSTEM path, and
# deliberately leave docker out, so `command -v docker` fails for case (a).
for b in bash awk df date mktemp env cat grep sed ln rm; do
  p="$(PATH=/usr/bin:/bin command -v "$b" 2>/dev/null || true)"
  [[ -n "$p" ]] && ln -sf "$p" "${BIN_MIN}/${b}"
done

# --- run the script under test ---------------------------------------------
RUN_OUT=""; RUN_RC=0
run_prune() { # extra env assignments...
  local rc=0
  RUN_OUT="$(env PATH="${STUB_BIN}:/usr/bin:/bin" \
    "DOCKER_ARGV_LOG=${DOCKER_ARGV_LOG}" "$@" bash "$PRUNE" 2>&1)" || rc=$?
  RUN_RC="$rc"
}

# Lines in the docker argv log that are actual prune invocations (not --help).
prune_invocations() {
  grep -E '(^| )builder prune( |$)' "$DOCKER_ARGV_LOG" 2>/dev/null \
    | grep -v -- '--help' || true
}

printf 'prune-docker-cache tests\n\n'

# --- (a) docker CLI absent --------------------------------------------------
DOCKER_ARGV_LOG="$WORK/argv-a.log"; : > "$DOCKER_ARGV_LOG"
rc=0
RUN_OUT="$(env PATH="$BIN_MIN" DOCKER_ARGV_LOG="$DOCKER_ARGV_LOG" bash "$PRUNE" 2>&1)" || rc=$?
check "(a) exit code is 0" "$rc" "0"
has   "(a) logs that docker is absent" "$RUN_OUT" "docker CLI not found"
check "(a) prune was never invoked" "$(prune_invocations | wc -l | tr -d ' ')" "0"

# --- (b) daemon unreachable -------------------------------------------------
DOCKER_ARGV_LOG="$WORK/argv-b.log"; : > "$DOCKER_ARGV_LOG"
run_prune DOCKER_INFO_RC=1 DOCKER_HELP=max
check "(b) exit code is 0" "$RUN_RC" "0"
has   "(b) logs the unreachable daemon" "$RUN_OUT" "docker daemon unreachable"
check "(b) prune was never invoked" "$(prune_invocations | wc -l | tr -d ' ')" "0"

# --- (c) --max-used-space listed -> probed flag and default cap -------------
DOCKER_ARGV_LOG="$WORK/argv-c.log"; : > "$DOCKER_ARGV_LOG"
run_prune DOCKER_INFO_RC=0 DOCKER_HELP=max
check "(c) exit code is 0" "$RUN_RC" "0"
has   "(c) prune was invoked" "$(prune_invocations)" "builder prune"
has   "(c) --max-used-space was passed" "$(prune_invocations)" "--max-used-space"
has   "(c) the default cap 15GB was passed" "$(prune_invocations)" "15GB"
if [[ "$(prune_invocations)" != *"--keep-storage"* ]]; then
  ok "(c) --keep-storage was not passed"
else
  bad "(c) --keep-storage was not passed (got '$(prune_invocations)')"
fi

# --- (d) cap override reaches the argv --------------------------------------
DOCKER_ARGV_LOG="$WORK/argv-d.log"; : > "$DOCKER_ARGV_LOG"
run_prune DOCKER_INFO_RC=0 DOCKER_HELP=max HYBRID_AI_BUILD_CACHE_CAP=5GB
check "(d) exit code is 0" "$RUN_RC" "0"
has   "(d) the overridden cap 5GB was passed" "$(prune_invocations)" "5GB"
has   "(d) the probed flag was still used" "$(prune_invocations)" "--max-used-space"
if [[ "$(prune_invocations)" != *"15GB"* ]]; then
  ok "(d) the default 15GB cap was not used"
else
  bad "(d) the default 15GB cap was not used (got '$(prune_invocations)')"
fi

# --- (e) only --keep-storage listed -> fallback -----------------------------
DOCKER_ARGV_LOG="$WORK/argv-e.log"; : > "$DOCKER_ARGV_LOG"
run_prune DOCKER_INFO_RC=0 DOCKER_HELP=keep
check "(e) exit code is 0" "$RUN_RC" "0"
has   "(e) --keep-storage was passed" "$(prune_invocations)" "--keep-storage"
has   "(e) the default cap 15GB was passed" "$(prune_invocations)" "15GB"
if [[ "$(prune_invocations)" != *"--max-used-space"* ]]; then
  ok "(e) --max-used-space was not passed"
else
  bad "(e) --max-used-space was not passed (got '$(prune_invocations)')"
fi

# --- (f) prune failure -> exit 1 --------------------------------------------
DOCKER_ARGV_LOG="$WORK/argv-f.log"; : > "$DOCKER_ARGV_LOG"
run_prune DOCKER_INFO_RC=0 DOCKER_HELP=max DOCKER_PRUNE_RC=1
check "(f) exit code is 1" "$RUN_RC" "1"
has   "(f) the failure was logged" "$RUN_OUT" "docker builder prune failed"

# --- (g) no supported flag -> exit 0, prune not invoked ---------------------
DOCKER_ARGV_LOG="$WORK/argv-g.log"; : > "$DOCKER_ARGV_LOG"
run_prune DOCKER_INFO_RC=0 DOCKER_HELP=none
check "(g) exit code is 0" "$RUN_RC" "0"
has   "(g) logs no supported cache-cap flag" "$RUN_OUT" "no supported cache-cap flag"
check "(g) prune was never invoked" "$(prune_invocations | wc -l | tr -d ' ')" "0"

# (g2) a --help that itself fails (unknown builder) is the same degraded path.
DOCKER_ARGV_LOG="$WORK/argv-g2.log"; : > "$DOCKER_ARGV_LOG"
run_prune DOCKER_INFO_RC=0 DOCKER_HELP=fail
check "(g2) exit code is 0 when --help fails" "$RUN_RC" "0"
check "(g2) prune was never invoked" "$(prune_invocations | wc -l | tr -d ' ')" "0"

# --- (h) free space logged before and after; df failure is harmless ---------
DOCKER_ARGV_LOG="$WORK/argv-h.log"; : > "$DOCKER_ARGV_LOG"
run_prune DOCKER_INFO_RC=0 DOCKER_HELP=max
check "(h) exit code is 0" "$RUN_RC" "0"
has   "(h) before free-space is logged" "$RUN_OUT" "before free-space="
has   "(h) after free-space is logged" "$RUN_OUT" "after free-space="

DOCKER_ARGV_LOG="$WORK/argv-h2.log"; : > "$DOCKER_ARGV_LOG"
run_prune DOCKER_INFO_RC=0 DOCKER_HELP=max DF_RC=1
check "(h) a failing df leaves the exit code 0" "$RUN_RC" "0"
has   "(h) a failing df logs free-space=unknown" "$RUN_OUT" "free-space=unknown"

# --- (i) unit files ---------------------------------------------------------
printf '\n'
check "(i) service exists" "$([[ -f "$SERVICE" ]] && echo yes || echo no)" "yes"
check "(i) timer exists" "$([[ -f "$TIMER" ]] && echo yes || echo no)" "yes"

service_line() { grep -qxF "$1" "$SERVICE" 2>/dev/null && echo yes || echo no; }
timer_line()   { grep -qxF "$1" "$TIMER" 2>/dev/null && echo yes || echo no; }

check "(i) service Type=oneshot" "$(service_line 'Type=oneshot')" "yes"
check "(i) service User=root" "$(service_line 'User=root')" "yes"
check "(i) service WorkingDirectory" "$(service_line 'WorkingDirectory=/opt/hybrid-ai')" "yes"
check "(i) service ExecStart" "$(service_line 'ExecStart=/opt/hybrid-ai/scripts/prune-docker-cache.sh')" "yes"
check "(i) service EnvironmentFile=- (missing file non-fatal)" "$(service_line 'EnvironmentFile=-/opt/hybrid-ai/.env')" "yes"
check "(i) service After=docker.service" "$(service_line 'After=docker.service')" "yes"
if grep -qE '^[[:space:]]*Restart=' "$SERVICE"; then
  bad "(i) service must carry no Restart= line"
else
  ok "(i) service carries no Restart= line"
fi
check "(i) timer OnCalendar 04:35:00" "$(timer_line 'OnCalendar=*-*-* 04:35:00')" "yes"
check "(i) timer Persistent=true" "$(timer_line 'Persistent=true')" "yes"
check "(i) timer Unit" "$(timer_line 'Unit=hybrid-ai-docker-prune.service')" "yes"
check "(i) timer WantedBy=timers.target" "$(timer_line 'WantedBy=timers.target')" "yes"

# --- (j) cache-only: no rmi / system prune / other prune / path deletion ----
printf '\n'
RMI_ERE='(^|[^[:alnum:]_])docker[[:space:]]+rmi'
WIDE_PRUNE_ERE='(^|[^[:alnum:]_])docker[[:space:]]+(system|container|volume|network|image)[[:space:]]+prune'
RM_ERE='(^|[[:space:];|&(])rm[[:space:]]+-'
# Any of the three, for the negative controls.
OFFENDERS_ERE="${RMI_ERE}|${WIDE_PRUNE_ERE}|${RM_ERE}"
if cache_only_offenders "$PRUNE" "$RMI_ERE" | grep -q .; then
  bad "(j) the script must not invoke docker rmi"
else
  ok "(j) the script does not invoke docker rmi"
fi
if cache_only_offenders "$PRUNE" "$WIDE_PRUNE_ERE" | grep -q .; then
  bad "(j) the script must only prune the build cache"
else
  ok "(j) the script prunes only the build cache"
fi
if cache_only_offenders "$PRUNE" "$RM_ERE" | grep -q .; then
  bad "(j) the script must not delete paths"
else
  ok "(j) the script does not delete paths"
fi

# --- (j2) the cache-only guard fires on a line-initial command --------------
# The guard above is the only thing enforcing the cache-only invariant, so this
# proves it does not silently rot: each offending form is appended at column 0
# to its own copy of the script and the helper must FIND it. The unmodified copy
# is the negative control.
neg_copy="$WORK/prune-neg.sh"
cp "$PRUNE" "$neg_copy"
check "(j2) the unmodified script yields no offenders" \
  "$(cache_only_offenders "$neg_copy" "$OFFENDERS_ERE" | wc -l | tr -d ' ')" "0"

for form_ere in \
  "docker rmi --force some-image:tag|$RMI_ERE" \
  "docker system prune -af|$WIDE_PRUNE_ERE" \
  "rm -rf /var/lib/hybrid-ai/x|$RM_ERE"
do
  form="${form_ere%%|*}"
  ere="${form_ere#*|}"
  pos_copy="$WORK/prune-pos-$(printf '%s' "$form" | tr -cs 'A-Za-z0-9' '-').sh"
  cp "$PRUNE" "$pos_copy"
  printf '%s\n' "$form" >> "$pos_copy"
  if cache_only_offenders "$pos_copy" "$ere" | grep -q .; then
    ok "(j2) the guard fires on line-initial '${form}'"
  else
    bad "(j2) the guard fires on line-initial '${form}'"
  fi
done
check "(j2) the real script still yields no offenders" \
  "$(cache_only_offenders "$PRUNE" "$OFFENDERS_ERE" | wc -l | tr -d ' ')" "0"

# --- (k)/(l) install.sh writes and preserves HYBRID_AI_BUILD_CACHE_CAP -------
# The unit reads the cap from the stack .env. install.sh STEP 8 rewrites that
# file from a ${VAR:-default} template, so this fixture proves the default is
# written when the owner has not set one, and that an owner value survives a
# second run byte-for-byte. install.sh runs as a non-root fixture with every
# host command stubbed and --no-start, exactly like test-env-pin-migration.sh.
printf '\n'
I_APP="$WORK/install-app"
I_BIN="$WORK/install-bin"
mkdir -p "$I_APP/scripts/lib" "$I_BIN" "$WORK/i-data" "$WORK/i-log" \
         "$WORK/i-work" "$WORK/i-ws/.git/info" "$WORK/i-repos" "$WORK/i-ohstate" \
         "$WORK/i-conf" "$WORK/i-restic" "$WORK/i-etc"
cp "$REPO/install.sh" "$I_APP/install.sh"
cp "$REPO/scripts/lib/hybrid-ai-env.sh" "$I_APP/scripts/lib/"
cp "$REPO/scripts/lib/build-gate.sh" "$I_APP/scripts/lib/"

# install.sh sources scripts/lib/tls.sh and its TLS render step reads the
# tracked templates, so the scratch app tree must carry them too.
mkdir -p "$I_APP/status"
cp "$REPO/scripts/lib/tls.sh" "$I_APP/scripts/lib/"
cp "$REPO/status/Caddyfile.tmpl" "$I_APP/status/Caddyfile.tmpl"
cp "$REPO/docker-compose.yml.tmpl" "$I_APP/docker-compose.yml.tmpl"
printf '#!/usr/bin/env bash\nexit 0\n' > "$I_APP/scripts/setup-agent-workspace.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$I_APP/scripts/sync-agent-repos.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$I_APP/scripts/check-hermes-nonroot.sh"
chmod +x "$I_APP/scripts/"*.sh

I_LAYOUT="$WORK/i-etc/hybrid-ai.env"
I_STACK="$WORK/i-etc/stack.env"
{
  printf 'HYBRID_AI_APP_DIR=%s\n' "$I_APP"
  printf 'HYBRID_AI_ENV_FILE=%s\n' "$I_LAYOUT"
  printf 'HYBRID_AI_STACK_ENV_FILE=%s\n' "$I_STACK"
  printf 'HYBRID_AI_DATA_DIR=%s\n' "$WORK/i-data"
  printf 'HYBRID_AI_LOG_DIR=%s\n' "$WORK/i-log"
  printf 'HYBRID_AI_WORK_DIR=%s\n' "$WORK/i-work"
  printf 'OPENHANDS_WORKSPACE=%s\n' "$WORK/i-ws"
  printf 'AGENT_REPOS_DIR=%s\n' "$WORK/i-repos"
  printf 'OPENHANDS_STATE_DIR=%s\n' "$WORK/i-ohstate"
  printf 'BACKUP_CONF_DIR=%s\n' "$WORK/i-conf"
  printf 'RESTIC_CACHE_DIR=%s\n' "$WORK/i-restic"
  printf 'HYBRID_AI_HERMES_HOME_DIR=%s\n' "$WORK/i-hermes"
  printf 'HYBRID_AI_BACKUP_MODE=system\n'
  printf 'BACKUP_CONTAINER_CONTROL=external\n'
  printf 'HYBRID_AI_UID=1000\n'
  printf 'HYBRID_AI_GID=1000\n'
} > "$I_LAYOUT"
chmod 644 "$I_LAYOUT"
# shellcheck disable=SC2016  # $0 must expand inside the generated stub
for d in docker git jq openssl sqlite3 rsync tailscale hostname nproc \
         loginctl setfacl apt-get sudo restic; do
  printf '#!/usr/bin/env bash\nprintf "%%s stub\\n" "$0"\nexit 0\n' > "$I_BIN/$d"
done
# shellcheck disable=SC2016  # $@ must expand inside the generated stub
printf '#!/usr/bin/env bash\nif [[ "${1:-}" == "-u" ]]; then printf "1000\\n"; exit 0; fi\nif [[ "${1:-}" == "-g" ]]; then printf "1000\\n"; exit 0; fi\nexec /usr/bin/id "$@"\n' > "$I_BIN/id"
printf '#!/usr/bin/env bash\nexit 0\n' > "$I_BIN/chown"
printf '#!/usr/bin/env bash\nexit 0\n' > "$I_BIN/sleep"
cat > "$I_BIN/getent" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  group) printf 'docker:x:999:\n' ;;
  hosts) printf '10.0.0.1 %s\n' "${2:-}" ;;
esac
exit 0
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$I_BIN/curl"
chmod +x "$I_BIN"/*

run_install() {
  local log="$1" rc=0
  env -u HYBRID_AI_APP_DIR -u HYBRID_AI_DATA_DIR -u HYBRID_AI_LOG_DIR \
      -u HYBRID_AI_WORK_DIR -u HYBRID_AI_STACK_ENV_FILE \
      -u OPENHANDS_WORKSPACE -u AGENT_REPOS_DIR -u OPENHANDS_STATE_DIR \
      -u BACKUP_CONF_DIR -u RESTIC_CACHE_DIR -u HYBRID_AI_HERMES_HOME_DIR \
      -u HYBRID_AI_BACKUP_MODE -u BACKUP_CONTAINER_CONTROL \
      -u HYBRID_AI_UID -u HYBRID_AI_GID \
      -u OPENHANDS_IMAGE -u OPENHANDS_AGENT_IMAGE_TAG \
      -u HYBRID_AI_BUILD_CACHE_CAP \
      PATH="$I_BIN:$PATH" \
      HYBRID_AI_ENV_FILE="$I_LAYOUT" \
      LOCAL_DOMAIN=example.test OPENROUTER_API_KEY=stub RUNPOD_API_KEY=stub \
      RUNPOD_POD_ID=stub RUNPOD_HOST=stub PI_HOST=stub \
      OPENHANDS_SANDBOX_HOST=example.test PEER_HOSTNAMES="none" \
      USER=fixture \
      bash "$I_APP/install.sh" --non-interactive --no-start >> "$log" 2>&1 || rc=$?
  return "$rc"
}
env_value() { grep -E "^$2=" "$1" 2>/dev/null | head -n1 | cut -d= -f2-; }

I_LOG="$WORK/install.log"
: > "$I_LOG"
rm -f "$I_STACK"
rc=0
run_install "$I_LOG" || rc=$?
check "(k) install.sh exits 0 with --no-start" "$rc" "0"
check "(k) the 15GB cap default was written" "$(env_value "$I_STACK" HYBRID_AI_BUILD_CACHE_CAP)" "15GB"

: > "$I_LOG"
printf 'HYBRID_AI_BUILD_CACHE_CAP=7GB\n' > "$I_STACK"
chmod 600 "$I_STACK"
rc=0
run_install "$I_LOG" || rc=$?
check "(l) install.sh exits 0 with an owner cap" "$rc" "0"
check "(l) the owner cap 7GB was preserved" "$(env_value "$I_STACK" HYBRID_AI_BUILD_CACHE_CAP)" "7GB"
AFTER_ONE="$(env_value "$I_STACK" HYBRID_AI_BUILD_CACHE_CAP)"
: > "$I_LOG"
rc=0
run_install "$I_LOG" || rc=$?
check "(l) a second run exits 0" "$rc" "0"
check "(l) the owner cap is byte-for-byte identical" "$AFTER_ONE" "$(env_value "$I_STACK" HYBRID_AI_BUILD_CACHE_CAP)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
