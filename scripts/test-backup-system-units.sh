#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/test-backup-system-units.sh
# PURPOSE (plain English):
#   Proves the privilege split encoded in backup/system/ is actually there.
#
#   The units ARE the security control: the capture unit must hold the read
#   capability and NO network or credentials, and the upload unit must hold the
#   credentials and NO read capability or docker access. A future edit that
#   quietly drops AmbientCapabilities= or adds a second capability to the
#   capture unit, or that gives the upload unit a capability, would undo the
#   split. This static test fails when any of those directives is missing or
#   wrong. It needs no Docker, no network and no root -- only bash.
#
#   It also runs `systemd-analyze verify` the RIGHT way. On systemd >= 245,
#   verify exits non-zero when an ExecStart= binary is absent, and /opt/hybrid-ai
#   exists on no builder host or CI runner. So: if every diagnostic line is the
#   missing-host-path form, print a skip and pass; ANY other diagnostic -- alone
#   or mixed with the host-path line -- is a hard failure. Both directions are
#   proved with a stub systemd-analyze placed FIRST on PATH.
#
#   It also covers the two residual system-mode defects:
#     * D2 -- the upload and check units must pin HYBRID_AI_STACK_ENV_FILE at the
#       0644 LAYOUT file, or the env helper fail-closes on the 0600 root-only
#       stack file before restic runs. A 0644 layout file naming a 0600 root-only
#       stack file is exercised offline as an unprivileged uid; when run as root
#       the case drops to an unprivileged uid (setpriv/runuser) and prints SKIP
#       (never a pass) if it cannot. A SKIP on a non-root runner is a FAILURE.
#     * D5 -- exit 3 (an INCOMPLETE upload/check) must be a SUCCESS status.
# ---------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -- "${HERE}/.." && pwd)"
UNITS="${REPO}/backup/system"

PASS=0
FAIL=0
SKIP=0
D2_TMPDIRS=()
cleanup_tmp() {
  local d
  for d in "${D2_TMPDIRS[@]:-}"; do
    [[ -n "$d" ]] || continue
    # A fixture may leave a 0555 directory behind (the D6b/D7 unwritable
    # fixtures). Restore write permission before removal so the trap is quiet.
    chmod -R u+rwX "$d" 2>/dev/null || true
    rm -rf "$d" 2>/dev/null || true
  done
}
trap cleanup_tmp EXIT
ok()   { PASS=$(( PASS + 1 )); printf 'ok   %s\n' "$*"; }
bad()  { FAIL=$(( FAIL + 1 )); printf 'FAIL %s\n' "$*" >&2; }
skip() { SKIP=$(( SKIP + 1 )); printf 'SKIP %s\n' "$*"; }

# Assert that a unit FILE contains an exact directive LINE. Matching a whole
# line (not a substring) so `CapabilityBoundingSet=` cannot be satisfied by
# `CapabilityBoundingSet=CAP_DAC_READ_SEARCH` on the upload unit, and a
# `# Restart=` comment cannot satisfy a real `Restart=` requirement.
has_line() { # file expected-line desc
  local file="$1" want="$2" desc="$3"
  if grep -Fxq -- "$want" "$file"; then ok "$desc"; else bad "$desc (missing: $want)"; fi
}
hasnt_regex() { # file regex desc
  local file="$1" re="$2" desc="$3"
  if grep -Eq -- "$re" "$file"; then bad "$desc (unexpected: $re)"; else ok "$desc"; fi
}

CAP="${UNITS}/hybrid-ai-backup-capture.service"
UP="${UNITS}/hybrid-ai-backup-upload.service"
CTIMER="${UNITS}/hybrid-ai-backup-capture.timer"
CHECK="${UNITS}/hybrid-ai-backup-check.service"
CHECKTIMER="${UNITS}/hybrid-ai-backup-check.timer"

for f in "$CAP" "$UP" "$CTIMER" "$CHECK" "$CHECKTIMER"; do
  [[ -f "$f" ]] || { bad "missing unit file ${f}"; }
done
if (( FAIL > 0 )); then
  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
  exit 1
fi

# ---------------------------------------------------------------------------
# capture unit: read capability, no network, no credentials, no docker
# ---------------------------------------------------------------------------
echo "== capture unit =="
has_line "$CAP" 'Type=oneshot'                       "capture is Type=oneshot"
has_line "$CAP" 'User=hybrid-ai-backup'              "capture runs as hybrid-ai-backup"
has_line "$CAP" 'Group=hybrid-ai-backup'             "capture group is hybrid-ai-backup"
has_line "$CAP" 'AmbientCapabilities=CAP_DAC_READ_SEARCH' "capture has the read capability"
has_line "$CAP" 'CapabilityBoundingSet=CAP_DAC_READ_SEARCH' "capture bounding set is exactly the read capability"
has_line "$CAP" 'NoNewPrivileges=yes'                "capture sets NoNewPrivileges=yes"
has_line "$CAP" 'PrivateNetwork=yes'                 "capture has no network"
has_line "$CAP" 'InaccessiblePaths=-/run/docker.sock'      "capture cannot reach /run/docker.sock"
has_line "$CAP" 'InaccessiblePaths=-/var/run/docker.sock'  "capture cannot reach /var/run/docker.sock"
has_line "$CAP" 'ProtectSystem=strict'               "capture protects system"
has_line "$CAP" 'ProtectHome=yes'                    "capture protects home"
has_line "$CAP" 'PrivateTmp=yes'                     "capture has a private tmp"
has_line "$CAP" 'StateDirectory=hybrid-ai-backup'    "capture has a state directory (staging)"
has_line "$CAP" 'RuntimeDirectory=hybrid-ai-backup'  "capture has a runtime directory"
has_line "$CAP" 'LogsDirectory=hybrid-ai-backup'     "capture has a logs directory for the backup log"
has_line "$CAP" 'Environment=HYBRID_AI_ENV_FILE=/etc/hybrid-ai/hybrid-ai.env' "capture reads the system env file"
has_line "$CAP" 'Environment=HYBRID_AI_BACKUP_MODE=system'    "capture selects system mode"
has_line "$CAP" 'Environment=BACKUP_CONTAINER_CONTROL=external' "capture treats container control as external"
has_line "$CAP" 'ExecStartPre=+/opt/hybrid-ai/backup/backup-containers.sh host-info' "capture collects host info first"
has_line "$CAP" 'ExecStartPre=+/opt/hybrid-ai/backup/backup-containers.sh pause'     "capture pauses containers second"
has_line "$CAP" 'ExecStart=/opt/hybrid-ai/backup/backup.sh --stage-only'             "capture runs the stage-only phase"
has_line "$CAP" 'ExecStopPost=+/opt/hybrid-ai/backup/backup-containers.sh unpause'   "capture unpauses on exit"
has_line "$CAP" 'SuccessExitStatus=3'                "capture treats exit 3 as success"
hasnt_regex "$CAP" '^Restart='                       "capture has NO Restart= (never loops)"
# The upload unit is started by the capture's OnSuccess.
if grep -Fxq -- 'OnSuccess=hybrid-ai-backup-upload.service' "$CAP"; then
  ok "capture starts the upload unit on success"
else
  bad "capture must have OnSuccess=hybrid-ai-backup-upload.service"
fi

# ---------------------------------------------------------------------------
# upload unit: credentials and network, no capability, no docker
# ---------------------------------------------------------------------------
echo "== upload unit =="
has_line "$UP" 'User=hybrid-ai-backup'               "upload runs as hybrid-ai-backup"
has_line "$UP" 'Group=hybrid-ai-backup'              "upload group is hybrid-ai-backup"
has_line "$UP" 'CapabilityBoundingSet='              "upload has an empty capability set"
has_line "$UP" 'NoNewPrivileges=yes'                 "upload sets NoNewPrivileges=yes"
has_line "$UP" 'LoadCredential=r2.env:/etc/credstore/hybrid-ai-backup/r2.env'          "upload loads r2.env from credstore"
has_line "$UP" 'LoadCredential=repo-password:/etc/credstore/hybrid-ai-backup/repo-password' "upload loads repo-password from credstore"
has_line "$UP" 'InaccessiblePaths=-/run/docker.sock'      "upload cannot reach /run/docker.sock"
has_line "$UP" 'InaccessiblePaths=-/var/run/docker.sock'  "upload cannot reach /var/run/docker.sock"
has_line "$UP" 'ProtectSystem=strict'                "upload protects system"
has_line "$UP" 'ProtectHome=yes'                     "upload protects home"
has_line "$UP" 'CacheDirectory=hybrid-ai-backup'     "upload has a cache directory (restic cache)"
has_line "$UP" 'Environment=RESTIC_CACHE_DIR=/var/cache/hybrid-ai-backup' "upload points RESTIC_CACHE_DIR at its cache"
has_line "$UP" 'StateDirectory=hybrid-ai-backup'     "upload sees the staging state directory"
has_line "$UP" 'ExecStart=/opt/hybrid-ai/backup/backup.sh --upload-only' "upload runs the upload-only phase"
has_line "$UP" 'Restart=on-failure'                  "upload retries a transient failure"
has_line "$UP" 'RestartSec=15min'                    "upload retry delay is bounded"
has_line "$UP" 'StartLimitIntervalSec=1h'            "upload limits retries per hour"
has_line "$UP" 'StartLimitBurst=2'                   "upload retries at most twice"
has_line "$UP" 'RestartPreventExitStatus=3'          "upload never retries an incomplete capture"
# Staging read-only except its own removal: strict filesystem plus ONE write path.
has_line "$UP" 'ReadWritePaths=-/var/lib/hybrid-ai-backup' "upload may only write the staging root (to remove it)"
hasnt_regex "$UP" '^(AmbientCapabilities|CapabilityBoundingSet)=[^ ]' "upload grants no capability"

# ---------------------------------------------------------------------------
# timers and the monthly check
# ---------------------------------------------------------------------------
echo "== timers and check unit =="
has_line "$CTIMER" 'OnCalendar=*-*-* 03:15:00'   "capture timer runs nightly at 03:15"
has_line "$CTIMER" 'Persistent=true'             "capture timer catches up after downtime"
has_line "$CTIMER" 'RandomizedDelaySec=15min'    "capture timer spreads the start"
has_line "$CHECK"  'ExecStart=/opt/hybrid-ai/backup/backup.sh --check' "check unit runs --check"
has_line "$CHECK"  'LoadCredential=r2.env:/etc/credstore/hybrid-ai-backup/r2.env' "check unit loads the same credentials"
has_line "$CHECK"  'CapabilityBoundingSet='      "check unit has no capability (upload shape)"
has_line "$CHECK"  'CacheDirectory=hybrid-ai-backup' "check unit shares the restic cache directory"
has_line "$CHECKTIMER" 'OnCalendar=Sun *-*-01..07 04:30:00' "check timer runs monthly"
has_line "$CHECKTIMER" 'Persistent=true'         "check timer catches up after downtime"

# ---------------------------------------------------------------------------
# every Exec line: absolute path, and NO '-' prefix
# ---------------------------------------------------------------------------
echo "== exec lines =="
EXEC_BAD=0
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  # strip "ExecStartPre=" etc, keep the value
  val="${line#*=}"
  # a leading '+' is required on the privileged helper lines and allowed; it is
  # not the '-' prefix that would swallow a failure, so only reject '-' here.
  case "$val" in
    -*) printf 'FAIL exec line uses a "-" prefix: %s\n' "$line" >&2; EXEC_BAD=1 ;;
  esac
  # first token after any '+' must be an absolute /opt/hybrid-ai path
  prog="${val#+}"
  prog="${prog%% *}"
  case "$prog" in
    /opt/hybrid-ai/*) ;;
    *) printf 'FAIL exec line is not an absolute /opt/hybrid-ai path: %s\n' "$line" >&2; EXEC_BAD=1 ;;
  esac
done < <(grep -E '^Exec(Start|StartPre|StopPost|StartPost|Reload)=' "$CAP" "$UP" "$CHECK")
if (( EXEC_BAD == 0 )); then ok "every Exec line is absolute and has no '-' prefix"; else bad "one or more Exec lines are malformed"; fi

# ---------------------------------------------------------------------------
# D5: exit 3 (an INCOMPLETE upload/check) must be a SUCCESS for systemd, so the
# unit is not reported as failed. SuccessExitStatus=3 must sit alongside
# RestartPreventExitStatus=3 in BOTH units; the capture unit already had both.
# ---------------------------------------------------------------------------
echo "== D5: exit 3 is a success status =="
has_line "$UP"    'SuccessExitStatus=3'        "upload treats exit 3 as success"
has_line "$CHECK" 'SuccessExitStatus=3'        "check treats exit 3 as success"
has_line "$UP"    'RestartPreventExitStatus=3' "upload still never retries exit 3"
has_line "$CHECK" 'RestartPreventExitStatus=3' "check still never retries exit 3"

# ---------------------------------------------------------------------------
# D2: on a bootstrapped host the upload/check units must resolve their host
# paths from the 0644 LAYOUT file, not fail closed on the 0600 root-only stack
# file. Both units pin HYBRID_AI_STACK_ENV_FILE at the layout file, mirroring the
# capture unit and PR #46. The static check below proves the pin; the dynamic
# fixture proves the resolution offline: a 0644 layout file names a 0600
# root-only stack file, and the env helper is sourced as an unprivileged uid.
# Without the pin the helper fail-closes with its OWN message and the unit exits
# 1 before restic runs -- the exact defect.
# ---------------------------------------------------------------------------
echo "== D2: upload-path env resolution on a bootstrapped host =="

# Static: each unit must pin STACK_ENV_FILE at exactly the file its ENV_FILE
# names (the layout file).
for _u in "$UP" "$CHECK"; do
  _env_val="$(sed -n 's/^Environment=HYBRID_AI_ENV_FILE=//p' "$_u" | head -1)"
  _stack_val="$(sed -n 's/^Environment=HYBRID_AI_STACK_ENV_FILE=//p' "$_u" | head -1)"
  if [[ -n "$_env_val" && "$_stack_val" == "$_env_val" ]]; then
    ok "$(basename -- "$_u") pins STACK_ENV_FILE at its layout file"
  else
    bad "$(basename -- "$_u") must pin STACK_ENV_FILE at its layout file (env='${_env_val}' stack='${_stack_val}')"
  fi
done
unset _u _env_val _stack_val

# Dynamic fixture. A 0644 LAYOUT file names a 0600 root-only STACK file; the
# helper is sourced as an unprivileged uid, so the stack file is unreadable to
# it exactly as on the bootstrapped host.
D2DIR="$(mktemp -d)"
D2_TMPDIRS+=("$D2DIR")
LAYOUT="$D2DIR/layout.env"
STACK="$D2DIR/stack.env"
D2DATA="$D2DIR/data"; D2WORK="$D2DIR/work"; mkdir -p "$D2DATA" "$D2WORK"
cat > "$LAYOUT" <<EOF
HYBRID_AI_STACK_ENV_FILE=${STACK}
HYBRID_AI_DATA_DIR=${D2DATA}
HYBRID_AI_WORK_DIR=${D2WORK}
HYBRID_AI_BACKUP_MODE=system
EOF
chmod 0644 "$LAYOUT"
printf 'HYBRID_AI_DATA_DIR=/var/lib/hybrid-ai\n' > "$STACK"
# Copy the helper so an unprivileged uid can read it without touching the repo.
HELPER_COPY="$D2DIR/hybrid-ai-env.sh"
cp "${REPO}/scripts/lib/hybrid-ai-env.sh" "$HELPER_COPY"
chmod 0644 "$HELPER_COPY"

# Privilege drop. As root the case MUST drop to an unprivileged uid (a 0600 file
# is readable to root). As a non-root runner it runs as-is; a SKIP there is a
# FAILURE, so the case is only ever skipped on a root host that cannot drop.
if (( EUID == 0 )); then
  D2_NUID="$(id -u nobody 2>/dev/null || echo 65534)"
  D2_NGID="$(id -g nobody 2>/dev/null || echo 65534)"
  if command -v setpriv >/dev/null 2>&1; then
    d2_pre=(setpriv --reuid="$D2_NUID" --regid="$D2_NGID" --clear-groups)
  elif command -v runuser >/dev/null 2>&1; then
    d2_pre=(runuser -u nobody --)
  else
    d2_pre=()
  fi
  chmod 0755 "$D2DIR" "$D2DATA" "$D2WORK"
  chown 0:0 "$STACK" 2>/dev/null || true
  chmod 0600 "$STACK"
else
  d2_pre=()
  # No root: a 0600 file owned by this uid would be readable, so make the stack
  # file unreadable to this uid (the only way without root). The property under
  # test -- exists but unreadable to the running uid -- is the same.
  chmod 000 "$STACK"
fi

if (( ${#d2_pre[@]} > 0 )) && ! "${d2_pre[@]}" true >/dev/null 2>&1; then
  skip "D2 env-resolution case (running as root and cannot drop privileges)"
elif (( EUID == 0 )) && (( ${#d2_pre[@]} == 0 )); then
  skip "D2 env-resolution case (no setpriv/runuser to drop privileges)"
else
  # env -i POISONS every inherited variable, and STACK_ENV_FILE is set
  # explicitly (empty for the no-pin case), so no :- fallback can re-point it.
  run_env_probe() {  # <stack-env-file-value>; sets D2_RC and D2_OUT
    local rc=0
    D2_OUT="$("${d2_pre[@]}" env -i \
        HOME=/nonexistent \
        PATH="/usr/bin:/bin" \
        HYBRID_AI_ENV_FILE="$LAYOUT" \
        HYBRID_AI_STACK_ENV_FILE="$1" \
        bash -c "source '$HELPER_COPY'; printf '%s' \"\$HYBRID_AI_STACK_ENV_FILE\"" 2>&1)" || rc=$?
    D2_RC="$rc"
  }

  # (a) The upload unit's own pinned value must resolve without fail-closing.
  #     On the unpatched base commit there is NO pin, so the helper reads the
  #     0600 stack file and fail-closes with its own message -> this FAILS.
  UP_STACK_VAL="$(sed -n 's/^Environment=HYBRID_AI_STACK_ENV_FILE=//p' "$UP" | head -1)"
  run_env_probe "$UP_STACK_VAL"
  if [[ "$D2_RC" == "0" && "$D2_OUT" != *"cannot be read"* ]]; then
    ok "D2: the upload unit's pinned STACK_ENV_FILE resolves without fail-closing"
  else
    bad "D2: upload-path env resolution fail-closed (rc=$D2_RC): $D2_OUT"
  fi

  # (b) With the pin pointed at the layout file (the fixed shape) the helper
  #     resolves STACK_ENV_FILE to the layout file and succeeds.
  run_env_probe "$LAYOUT"
  if [[ "$D2_RC" == "0" && "$D2_OUT" == "$LAYOUT" ]]; then
    ok "D2: pinning STACK_ENV_FILE at the layout file resolves to that file"
  else
    bad "D2: pinned layout resolution wrong (rc=$D2_RC out=$D2_OUT)"
  fi

  # (c) Negative control: NO pin -> the helper reads the unreadable stack file
  #     and fails closed with its own message. This is the reproduced defect.
  run_env_probe ""
  if [[ "$D2_RC" != "0" && "$D2_OUT" == *"HYBRID_AI_STACK_ENV_FILE"* && "$D2_OUT" == *"cannot be read"* ]]; then
    ok "D2: without the pin the helper fails closed (the reproduced defect)"
  else
    bad "D2: expected a fail-closed without the pin (rc=$D2_RC): $D2_OUT"
  fi
  unset UP_STACK_VAL
fi

# ---------------------------------------------------------------------------
# D6a / D9: one resolved BACKUP_LOG path for the units, doctor.sh and
# install.sh. The units must grant write access to the log directory
# (LogsDirectory=) so they can create/append it under ProtectSystem=strict, and
# the path the helper resolves in system mode must equal the units' log path.
# ---------------------------------------------------------------------------
echo "== D6a/D9: the units grant the log path and agree on BACKUP_LOG =="
has_line "$UP"    'LogsDirectory=hybrid-ai-backup' "upload has a logs directory for the backup log"
has_line "$CHECK" 'LogsDirectory=hybrid-ai-backup' "check has a logs directory for the backup log"
# Neither unit hardcodes a BACKUP_LOG that could diverge from the helper's
# system-mode resolution. The helper owns the path; the units grant the dir.
hasnt_regex "$UP"    '^Environment=BACKUP_LOG=' "upload does not pin a divergent BACKUP_LOG"
hasnt_regex "$CHECK" '^Environment=BACKUP_LOG=' "check does not pin a divergent BACKUP_LOG"

# Resolve BACKUP_LOG the way a system-mode unit does: HYBRID_AI_BACKUP_MODE is
# the ONLY setting that steers it (no inherited BACKUP_LOG). Poison the ambient
# environment so a stray exported BACKUP_LOG from the root deploy path cannot
# mask the unit-path resolution. `env -i` strips the ambient environment (there
# is no `:-` fallback in the helper that could re-read an inherited value), and
# a decoy BACKUP_LOG is exported here to prove the poisoning is effective.
HELPER_SRC="${REPO}/scripts/lib/hybrid-ai-env.sh"
export BACKUP_LOG="/decoy/should/never/be/read/backup.log"
unit_backup_log() { # <mode> <envfile>
  env -i HOME=/nonexistent PATH="/usr/bin:/bin" \
      HYBRID_AI_ENV_FILE="$2" HYBRID_AI_BACKUP_MODE="$1" \
      bash -c "source '$HELPER_SRC' >/dev/null 2>&1; printf '%s' \"\$BACKUP_LOG\""
}
SYSMODE_ENV="$(mktemp)"
D2_TMPDIRS+=("$SYSMODE_ENV")
printf 'HYBRID_AI_BACKUP_MODE=system\n' > "$SYSMODE_ENV"
UNIT_LOG="$(unit_backup_log system "$SYSMODE_ENV")"
if [[ "$UNIT_LOG" == "/var/log/hybrid-ai-backup/backup.log" ]]; then
  ok "the helper resolves the system-mode BACKUP_LOG to the units' LogsDirectory path"
else
  bad "system-mode BACKUP_LOG resolved to '${UNIT_LOG}', expected /var/log/hybrid-ai-backup/backup.log"
fi
# The decoy exported above must NOT have leaked through: the unit identity and a
# bare user-mode identity each resolve their OWN path, never /decoy/...
if [[ "$UNIT_LOG" != "/decoy/should/never/be/read/backup.log" ]]; then
  ok "an inherited BACKUP_LOG does not mask the unit-path resolution"
else
  bad "an inherited BACKUP_LOG leaked into the unit-path resolution"
fi
# The capture unit's hardcoded BACKUP_LOG (it predates this card and stays
# byte-identical) must equal the helper-resolved system-mode path.
CAP_LOG="$(sed -n 's/^Environment=BACKUP_LOG=//p' "$CAP" | head -1)"
if [[ -n "$CAP_LOG" && "$CAP_LOG" == "$UNIT_LOG" ]]; then
  ok "the capture unit's BACKUP_LOG equals the helper-resolved system-mode path"
else
  bad "capture BACKUP_LOG '${CAP_LOG}' != helper system-mode path '${UNIT_LOG}'"
fi
# And a bare-shell USER-mode identity resolves the user-mode path, separately.
# With no settings the log dir defaults to the repo directory, exactly as today.
USER_LOG="$(unit_backup_log user "$SYSMODE_ENV")"
if [[ "$USER_LOG" == "${REPO}/backup.log" ]]; then
  ok "a bare user-mode identity still resolves the user-mode BACKUP_LOG"
else
  bad "user-mode BACKUP_LOG resolved to '${USER_LOG}', expected ${REPO}/backup.log"
fi
unset CAP_LOG UNIT_LOG USER_LOG SYSMODE_ENV BACKUP_LOG

# ---------------------------------------------------------------------------
# D6b: the tee-failure fixture. Point BACKUP_LOG at a path that genuinely
# cannot be written and run the real backup.sh. On unpatched main the pipeline's
# exit is tee's, so restic success is mislabelled a failure; the patched script
# decides on restic's status and records a non-fatal warning.
# ---------------------------------------------------------------------------
echo "== D6b: a failed log write must not fail a successful backup =="

# Build an offline fixture: a scratch repo with the real backup.sh, the shared
# helper, and stubs for restic/docker/sqlite3. restic SUCCEEDS; BACKUP_LOG is a
# path under a directory this uid cannot write.
D6B="$(mktemp -d)"
D2_TMPDIRS+=("$D6B")
D6B_APP="$D6B/app"; mkdir -p "$D6B_APP/scripts/lib" "$D6B_APP/backup" \
  "$D6B_APP/webui_data" "$D6B_APP/hermes_data"
cp "${REPO}/scripts/lib/hybrid-ai-env.sh" "$D6B_APP/scripts/lib/"
cp "${REPO}/scripts/lib/read-probe.sh" "$D6B_APP/scripts/lib/"
cp "${REPO}/backup/backup.sh" "$D6B_APP/backup/"
: > "$D6B_APP/docker-compose.yml"
chmod +x "$D6B_APP/backup/backup.sh"

D6B_BIN="$D6B/bin"; mkdir -p "$D6B_BIN"
cat > "$D6B_BIN/restic" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  snapshots) exit 0 ;;
  backup)    printf 'restic: snapshot saved\n'; exit 0 ;;
  forget)    printf 'restic: retention applied\n'; exit 0 ;;
  version)   echo "restic 0.0.0 (test stub)"; exit 0 ;;
  *)         exit 0 ;;
esac
STUB
cat > "$D6B_BIN/docker" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
cat > "$D6B_BIN/sqlite3" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
cat > "$D6B_BIN/systemctl" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$D6B_BIN"/*

D6B_CONF="$D6B/conf"; mkdir -p "$D6B_CONF"; chmod 700 "$D6B_CONF"
printf 'RESTIC_REPOSITORY=s3:https://example.invalid/bucket\nAWS_ACCESS_KEY_ID=t\nAWS_SECRET_ACCESS_KEY=t\n' > "$D6B_CONF/r2.env"
printf 'pw\n' > "$D6B_CONF/repo-password"
chmod 600 "$D6B_CONF/r2.env" "$D6B_CONF/repo-password"
D6B_WORK="$D6B/work"; mkdir -p "$D6B_WORK"
D6B_LOG="$D6B/ro/backup.log"
D6B_LOG_ALT="$D6B/logs/backup.log"

# Choose a genuinely unwritable BACKUP_LOG. When root, drop to an unprivileged
# uid (setpriv/runuser) so the read-only directory really refuses the write; if
# we cannot drop privileges, print SKIP (never pass) and name the runner.
D6B_PRE=()
D6B_SKIP_REASON=""
if (( EUID == 0 )); then
  D6B_NUID="$(id -u nobody 2>/dev/null || echo 65534)"
  D6B_NGID="$(id -g nobody 2>/dev/null || echo 65534)"
  if command -v setpriv >/dev/null 2>&1; then
    D6B_PRE=(setpriv --reuid="$D6B_NUID" --regid="$D6B_NGID" --clear-groups)
  elif command -v runuser >/dev/null 2>&1; then
    D6B_PRE=(runuser -u nobody --)
  else
    D6B_SKIP_REASON="running as root (uid 0) with no setpriv/runuser to drop privileges"
  fi
  if (( ${#D6B_PRE[@]} > 0 )) && ! "${D6B_PRE[@]}" true >/dev/null 2>&1; then
    D6B_SKIP_REASON="running as root (uid 0) and setpriv/runuser cannot drop privileges"
    D6B_PRE=()
  fi
  if (( ${#D6B_PRE[@]} > 0 )); then
    # The dropped uid must be able to read the fixture's 0600 credential files,
    # so hand it the whole tree; the read-only log dir is then re-secured below.
    chown -R "$D6B_NUID:$D6B_NGID" "$D6B" 2>/dev/null || true
  fi
fi

if [[ -n "$D6B_SKIP_REASON" ]]; then
  # A SKIP is honest only on a local host that genuinely cannot drop privileges.
  # On CI it must be a FAILURE: the runner's identity is printed either way, so a
  # green build can never hide an unrun tee-failure case.
  if [[ "${GITHUB_ACTIONS:-}" == "true" || -n "${CI:-}" ]]; then
    bad "D6b tee-failure case SKIPPED in CI (${D6B_SKIP_REASON}; runner=$(id -un) uid=$(id -u))"
  else
    skip "D6b tee-failure case (${D6B_SKIP_REASON}; runner=$(id -un) uid=$(id -u))"
  fi
else
  # A read-only directory holding the log path, and a writable one for the
  # negative control. The read-only directory is chmod 0555 (no write for its
  # owner), so even the uid that owns it cannot write; root would bypass that,
  # which is why root drops privileges above.
  mkdir -p "$(dirname "$D6B_LOG")" "$(dirname "$D6B_LOG_ALT")"
  chmod 0755 "$D6B" 2>/dev/null || true
  chmod 0555 "$(dirname "$D6B_LOG")"
  chmod 0777 "$(dirname "$D6B_LOG_ALT")"

  # Prove the fixture is unwritable BEFORE running: the assertion the brief
  # requires, so a broken fixture cannot silently turn into a pass.
  if "${D6B_PRE[@]}" bash -c "[[ ! -w '$D6B_LOG' ]] && [[ ! -w '$(dirname "$D6B_LOG")' ]]"; then
    D6B_RC=0
    "${D6B_PRE[@]}" env \
        HOME="$D6B_WORK" PATH="$D6B_BIN:/usr/bin:/bin" \
        HYBRID_AI_APP_DIR="$D6B_APP" HYBRID_AI_DATA_DIR="$D6B_APP" \
        HYBRID_AI_WORK_DIR="$D6B_WORK" HYBRID_AI_LOG_DIR="$D6B_WORK" \
        HYBRID_AI_BACKUP_MODE=system HYBRID_AI_BACKUP_CRED_DIR="$D6B_CONF" \
        BACKUP_LOG="$D6B_LOG" BACKUP_NO_PAUSE=1 \
        bash "$D6B_APP/backup/backup.sh" --non-interactive \
        > "$D6B/out" 2>&1 || D6B_RC=$?
    # restic succeeded, so the run must succeed even though tee could not write.
    if (( D6B_RC == 0 )); then
      ok "D6b: a successful restic backup exits 0 despite an unwritable log"
    else
      bad "D6b: a successful restic backup exited ${D6B_RC} because the log could not be written"
    fi
    if grep -q 'backup_success' "$D6B/out"; then
      ok "D6b: the run reports backup_success"
    else
      bad "D6b: the run did not report backup_success"
    fi
    if grep -qiE 'could not be written|log .*not writable' "$D6B/out"; then
      ok "D6b: a non-fatal log-write warning is printed"
    else
      bad "D6b: no non-fatal log-write warning was printed"
    fi
    # Negative control: a FAILING restic must still abort with backup_failed.
    cat > "$D6B_BIN/restic" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  snapshots) exit 0 ;;
  backup)    printf 'restic: boom\n' >&2; exit 1 ;;
  *)         exit 0 ;;
esac
STUB
    chmod +x "$D6B_BIN/restic"
    D6B_RC2=0
    "${D6B_PRE[@]}" env \
        HOME="$D6B_WORK" PATH="$D6B_BIN:/usr/bin:/bin" \
        HYBRID_AI_APP_DIR="$D6B_APP" HYBRID_AI_DATA_DIR="$D6B_APP" \
        HYBRID_AI_WORK_DIR="$D6B_WORK" HYBRID_AI_LOG_DIR="$D6B_WORK" \
        HYBRID_AI_BACKUP_MODE=system HYBRID_AI_BACKUP_CRED_DIR="$D6B_CONF" \
        BACKUP_LOG="$D6B_LOG_ALT" BACKUP_NO_PAUSE=1 \
        bash "$D6B_APP/backup/backup.sh" --non-interactive \
        > "$D6B/out2" 2>&1 || D6B_RC2=$?
    if (( D6B_RC2 != 0 )) && grep -q 'restic backup failed' "$D6B/out2"; then
      ok "D6b: a failing restic still dies with 'restic backup failed'"
    else
      bad "D6b: a failing restic did not abort as expected (rc=${D6B_RC2})"
    fi

    # D7: an unwritable restic cache must self-heal, not fail. Reuse the fixture
    # with a pre-existing, unwritable cache and a writable runtime directory.
    cat > "$D6B_BIN/restic" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  snapshots) exit 0 ;;
  backup)    printf 'restic-cache=%s\n' "${RESTIC_CACHE_DIR:-unset}"; exit 0 ;;
  forget)    exit 0 ;;
  *)         exit 0 ;;
esac
STUB
    chmod +x "$D6B_BIN/restic"
    D7_CACHE="$D6B/cache"; D7_RUNTIME="$D6B/run"
    mkdir -p "$D7_CACHE/repoX" "$D7_RUNTIME"
    chmod 0555 "$D7_CACHE/repoX" "$D7_CACHE"
    D7_RC=0
    "${D6B_PRE[@]}" env \
        HOME="$D6B_WORK" PATH="$D6B_BIN:/usr/bin:/bin" \
        HYBRID_AI_APP_DIR="$D6B_APP" HYBRID_AI_DATA_DIR="$D6B_APP" \
        HYBRID_AI_WORK_DIR="$D6B_WORK" HYBRID_AI_LOG_DIR="$D6B_WORK" \
        HYBRID_AI_BACKUP_MODE=system HYBRID_AI_BACKUP_CRED_DIR="$D6B_CONF" \
        BACKUP_LOG="$D6B_LOG_ALT" RESTIC_CACHE_DIR="$D7_CACHE" \
        RUNTIME_DIRECTORY="$D7_RUNTIME" BACKUP_NO_PAUSE=1 \
        bash "$D6B_APP/backup/backup.sh" --non-interactive \
        > "$D6B/out3" 2>&1 || D7_RC=$?
    if (( D7_RC == 0 )); then
      ok "D7: an unwritable restic cache does not fail the run"
    else
      bad "D7: an unwritable restic cache failed the run (rc=${D7_RC})"
    fi
    if grep -q 'restic_cache_fallback' "$D6B/out3"; then
      ok "D7: a writable fallback cache was selected"
    else
      bad "D7: no fallback cache was selected"
    fi
    if grep -q "restic-cache=${D7_RUNTIME}/restic-cache" "$D6B/out3"; then
      ok "D7: restic ran against the fallback cache under the runtime directory"
    else
      bad "D7: restic did not use the runtime fallback cache"
    fi
  else
    bad "D6b fixture is not actually unwritable; the case cannot run"
  fi
fi

# ---------------------------------------------------------------------------
# systemd-analyze verify, with both stub directions
# ---------------------------------------------------------------------------
echo "== systemd-analyze verify =="

# The real verify, in a helper so the stub test can reuse the same logic. The
# rule lives here once:
#   * every diagnostic is the missing-host-path form -> skip, pass
#   * any other diagnostic (alone or mixed)          -> fail
#   * systemd-analyze absent                         -> skip, pass
run_verify() {
  local unit="$1" out rc
  out="$(systemd-analyze verify "$unit" 2>&1)"
  rc=$?
  if (( rc == 0 )); then
    return 0
  fi
  # Every non-empty line must be the host-path diagnostic for THIS unit.
  local base line hostpath_ok=1
  base="$(basename -- "$unit")"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    case "$line" in
      "${base}:"*"is not executable: No such file or directory") ;;
      *) hostpath_ok=0 ;;
    esac
  done <<< "$out"
  if (( hostpath_ok )); then
    printf 'skip: %s (host paths not installed)\n' "$base"
    return 0
  fi
  printf '%s\n' "$out" >&2
  return 1
}

if ! command -v systemd-analyze >/dev/null 2>&1; then
  printf 'skip: systemd-analyze not available\n'
else
  # 1. The real verify on a host with no /opt/hybrid-ai must exit 0 (it skips).
  #    Run it over every unit, not just the capture unit.
  REAL_OK=1
  for u in "$CAP" "$UP" "$CHECK"; do
    run_verify "$u" || REAL_OK=0
  done
  if (( REAL_OK )); then ok "real systemd-analyze verify passes on a host without /opt/hybrid-ai"; else bad "real systemd-analyze verify did not pass"; fi

  # 2. A stub that prints ONLY the host-path line -> skip, exit 0.
  STUBDIR="$(mktemp -d)"
  cat > "${STUBDIR}/systemd-analyze" <<'STUB'
#!/usr/bin/env bash
base="$(basename -- "${@: -1}")"
printf '%s: Command /opt/hybrid-ai/backup/backup.sh is not executable: No such file or directory\n' "$base"
exit 1
STUB
  chmod +x "${STUBDIR}/systemd-analyze"
  if PATH="${STUBDIR}:$PATH" run_verify "$CAP" >/dev/null; then
    ok "host-path-only stub -> skip, exit 0"
  else
    bad "host-path-only stub should skip and exit 0"
  fi

  # 3. A stub that prints the host-path line AND one unrelated diagnostic ->
  #    hard failure, exit 1.
  cat > "${STUBDIR}/systemd-analyze" <<'STUB'
#!/usr/bin/env bash
base="$(basename -- "${@: -1}")"
printf '%s: Command /opt/hybrid-ai/backup/backup.sh is not executable: No such file or directory\n' "$base"
printf '%s: Unknown key %s in section [Service], ignoring.\n' "$base" 'Bogus=1'
exit 1
STUB
  chmod +x "${STUBDIR}/systemd-analyze"
  if PATH="${STUBDIR}:$PATH" run_verify "$CAP" >/dev/null 2>&1; then
    bad "host-path + unrelated diagnostic must be a hard failure"
  else
    ok "host-path + one unrelated diagnostic -> failure, exit 1"
  fi
  rm -rf "$STUBDIR"
fi

printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
(( FAIL == 0 ))
