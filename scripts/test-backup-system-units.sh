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
# ---------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -- "${HERE}/.." && pwd)"
UNITS="${REPO}/backup/system"

PASS=0
FAIL=0
ok()  { PASS=$(( PASS + 1 )); printf 'ok   %s\n' "$*"; }
bad() { FAIL=$(( FAIL + 1 )); printf 'FAIL %s\n' "$*" >&2; }

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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
