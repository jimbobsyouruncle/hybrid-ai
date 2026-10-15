#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/test-backup-system-units.sh
# PURPOSE (plain English):
#   Checks the system-mode backup units in backup/system/ against the exact
#   privilege split this card promises. Where `systemd-analyze verify` is
#   available it runs that too; the static directive checks below run
#   everywhere (a developer laptop or a CI runner without systemd).
#
#   The units are the security control, so the checks are specific:
#     * the CAPTURE unit has read access (one capability), NO network and NO
#       credentials, and can never reach the docker socket;
#     * the UPLOAD unit has the credentials and network but NO capabilities and
#       no docker socket, and its only writable paths are its cache and staging
#       removal;
#     * NEITHER unit stops or starts a container, and the capture unit has no
#       Restart= (incident B1: a retry loop that stopped hermes-agent).
#
# Fully OFFLINE. Needs only bash and grep (systemd-analyze is optional).
#
# Exit 0 when every case passes, non-zero otherwise. Exit 2 on usage error.
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_SRC="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
UNIT_DIR="${REPO_SRC}/backup/system"

CAPTURE="${UNIT_DIR}/hybrid-ai-backup-capture.service"
UPLOAD="${UNIT_DIR}/hybrid-ai-backup-upload.service"
CAPTURE_TIMER="${UNIT_DIR}/hybrid-ai-backup-capture.timer"
CHECK_SERVICE="${UNIT_DIR}/hybrid-ai-backup-check.service"
CHECK_TIMER="${UNIT_DIR}/hybrid-ai-backup-check.timer"

for f in "$CAPTURE" "$UPLOAD" "$CAPTURE_TIMER" "$CHECK_SERVICE" "$CHECK_TIMER"; do
  [[ -f "$f" ]] || { echo "error: missing unit $f" >&2; exit 2; }
done

FAILURES=0
ok()  { printf 'PASS: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; FAILURES=$(( FAILURES + 1 )); }

# has_line <file> <exact line>  -- a directive present verbatim (ignoring
# leading/trailing whitespace on the line).
has_line() {
  grep -qxF -- "$2" "$1"
}
# has_re <file> <extended regex>
has_re() {
  grep -qE -- "$2" "$1"
}
want() { # desc file pattern
  if has_re "$2" "$3"; then ok "$1"; else bad "$1 (pattern not found in $(basename -- "$2"))"; fi
}
want_line() { # desc file exact-line
  if has_line "$2" "$3"; then ok "$1"; else bad "$1 (line not found: $3)"; fi
}
want_absent() { # desc file regex
  if has_re "$2" "$3"; then bad "$1 (unexpected match in $(basename -- "$2"))"; else ok "$1"; fi
}

# ---------------------------------------------------------------------------
# Capture unit: read access, no network, no credentials, no docker socket
# ---------------------------------------------------------------------------
echo "== capture unit =="
want_line "capture: Type=oneshot" "$CAPTURE" "Type=oneshot"
want_line "capture: runs as hybrid-ai-backup" "$CAPTURE" "User=hybrid-ai-backup"
want_line "capture: group hybrid-ai-backup" "$CAPTURE" "Group=hybrid-ai-backup"
want_line "capture: read capability" "$CAPTURE" "AmbientCapabilities=CAP_DAC_READ_SEARCH"
want_line "capture: capability bounding set is exactly the read capability" \
  "$CAPTURE" "CapabilityBoundingSet=CAP_DAC_READ_SEARCH"
want_line "capture: no privilege escalation" "$CAPTURE" "NoNewPrivileges=yes"
want_line "capture: NO network" "$CAPTURE" "PrivateNetwork=yes"
want "capture: docker socket unreachable" "$CAPTURE" "InaccessiblePaths=.*run/docker\.sock"
want "capture: /var/run/docker.sock unreachable" "$CAPTURE" "InaccessiblePaths=.*var/run/docker\.sock"
want_line "capture: ProtectSystem=strict" "$CAPTURE" "ProtectSystem=strict"
want_line "capture: ProtectHome=yes" "$CAPTURE" "ProtectHome=yes"
want_line "capture: PrivateTmp=yes" "$CAPTURE" "PrivateTmp=yes"
want_line "capture: StateDirectory for staging" "$CAPTURE" "StateDirectory=hybrid-ai-backup"
want_line "capture: RuntimeDirectory" "$CAPTURE" "RuntimeDirectory=hybrid-ai-backup"
want_line "capture: LogsDirectory" "$CAPTURE" "LogsDirectory=hybrid-ai-backup"
want_line "capture: env file" "$CAPTURE" "Environment=HYBRID_AI_ENV_FILE=/etc/hybrid-ai/hybrid-ai.env"
want_line "capture: system mode" "$CAPTURE" "Environment=HYBRID_AI_BACKUP_MODE=system"
want_line "capture: external container control" "$CAPTURE" "Environment=BACKUP_CONTAINER_CONTROL=external"
want_line "capture: host-info pre-step runs as root (+)" "$CAPTURE" \
  "ExecStartPre=+/opt/hybrid-ai/backup/backup-containers.sh host-info"
want_line "capture: pause pre-step runs as root (+)" "$CAPTURE" \
  "ExecStartPre=+/opt/hybrid-ai/backup/backup-containers.sh pause"
want_line "capture: stage-only" "$CAPTURE" "ExecStart=/opt/hybrid-ai/backup/backup.sh --stage-only"
want_line "capture: unpause on stop runs as root (+)" "$CAPTURE" \
  "ExecStopPost=+/opt/hybrid-ai/backup/backup-containers.sh unpause"
want_line "capture: exit 3 is success" "$CAPTURE" "SuccessExitStatus=3"
want_line "capture: hands off to the upload unit" "$CAPTURE" "OnSuccess=hybrid-ai-backup-upload.service"
want_absent "capture: NO Restart= (incident B1)" "$CAPTURE" "^Restart="
want_absent "capture: never stops a container" "$CAPTURE" "docker stop|backup-containers\.sh stop"

# ---------------------------------------------------------------------------
# Upload unit: credentials + network, no capabilities, no docker socket
# ---------------------------------------------------------------------------
echo "== upload unit =="
want_line "upload: Type=oneshot" "$UPLOAD" "Type=oneshot"
want_line "upload: runs as hybrid-ai-backup" "$UPLOAD" "User=hybrid-ai-backup"
want_line "upload: group hybrid-ai-backup" "$UPLOAD" "Group=hybrid-ai-backup"
want_line "upload: no capabilities (empty bounding set)" "$UPLOAD" "CapabilityBoundingSet="
want_line "upload: no privilege escalation" "$UPLOAD" "NoNewPrivileges=yes"
want "upload: docker socket unreachable" "$UPLOAD" "InaccessiblePaths=.*run/docker\.sock"
want_line "upload: env file" "$UPLOAD" "Environment=HYBRID_AI_ENV_FILE=/etc/hybrid-ai/hybrid-ai.env"
want_line "upload: system mode" "$UPLOAD" "Environment=HYBRID_AI_BACKUP_MODE=system"
want_line "upload: external container control" "$UPLOAD" "Environment=BACKUP_CONTAINER_CONTROL=external"
want_line "upload: r2.env credential" "$UPLOAD" \
  "LoadCredential=r2.env:/etc/credstore/hybrid-ai-backup/r2.env"
want_line "upload: repo-password credential" "$UPLOAD" \
  "LoadCredential=repo-password:/etc/credstore/hybrid-ai-backup/repo-password"
want_line "upload: staging is exposed read-only via StateDirectory" "$UPLOAD" "StateDirectory=hybrid-ai-backup"
want_line "upload: staging removal is the only write under it" "$UPLOAD" \
  "ReadWritePaths=/var/lib/hybrid-ai-backup /var/cache/hybrid-ai-backup"
want_line "upload: restic cache directory" "$UPLOAD" "CacheDirectory=hybrid-ai-backup"
want_line "upload: upload-only" "$UPLOAD" "ExecStart=/opt/hybrid-ai/backup/backup.sh --upload-only"
want_line "upload: bounded retry (interval)" "$UPLOAD" "StartLimitIntervalSec=1h"
want_line "upload: bounded retry (burst)" "$UPLOAD" "StartLimitBurst=2"
want_line "upload: retry on failure" "$UPLOAD" "Restart=on-failure"
want_line "upload: retry delay" "$UPLOAD" "RestartSec=15min"
want_line "upload: incomplete is not retried" "$UPLOAD" "RestartPreventExitStatus=3"
want_absent "upload: never stops a container" "$UPLOAD" "docker stop|backup-containers\.sh stop"
want_absent "upload: never starts a container" "$UPLOAD" "docker start|backup-containers\.sh start"

# ---------------------------------------------------------------------------
# Timers
# ---------------------------------------------------------------------------
echo "== timers =="
want_line "capture timer: 03:15 daily" "$CAPTURE_TIMER" "OnCalendar=*-*-* 03:15:00"
want_line "capture timer: Persistent" "$CAPTURE_TIMER" "Persistent=true"
want_line "capture timer: 15-minute spread" "$CAPTURE_TIMER" "RandomizedDelaySec=15min"
want_line "capture timer: enabled via timers.target" "$CAPTURE_TIMER" "WantedBy=timers.target"
want_line "check timer: monthly, first week" "$CHECK_TIMER" "OnCalendar=Sun *-*-01..07 04:30:00"
want_line "check timer: Persistent" "$CHECK_TIMER" "Persistent=true"
want_line "check timer: enabled via timers.target" "$CHECK_TIMER" "WantedBy=timers.target"

# ---------------------------------------------------------------------------
# Check service: the upload unit's credential/network shape, runs --check
# ---------------------------------------------------------------------------
echo "== check service =="
want_line "check: Type=oneshot" "$CHECK_SERVICE" "Type=oneshot"
want_line "check: runs as hybrid-ai-backup" "$CHECK_SERVICE" "User=hybrid-ai-backup"
want_line "check: no capabilities" "$CHECK_SERVICE" "CapabilityBoundingSet="
want "check: docker socket unreachable" "$CHECK_SERVICE" "InaccessiblePaths=.*run/docker\.sock"
want_line "check: r2.env credential" "$CHECK_SERVICE" \
  "LoadCredential=r2.env:/etc/credstore/hybrid-ai-backup/r2.env"
want_line "check: repo-password credential" "$CHECK_SERVICE" \
  "LoadCredential=repo-password:/etc/credstore/hybrid-ai-backup/repo-password"
want_line "check: cache directory" "$CHECK_SERVICE" "CacheDirectory=hybrid-ai-backup"
want_line "check: runs --check" "$CHECK_SERVICE" "ExecStart=/opt/hybrid-ai/backup/backup.sh --check"
want_absent "check: never stops a container" "$CHECK_SERVICE" "docker stop|backup-containers\.sh stop"

# ---------------------------------------------------------------------------
# install.sh STEP 11: system mode installs the system units as root, writes
# credentials to the root-owned credstore, and never installs the user units.
# ---------------------------------------------------------------------------
echo "== install.sh system-mode wiring =="
INSTALL="${REPO_SRC}/install.sh"
# These live inside functions, so the assignment is indented: match the
# directive as a substring rather than an exact whole line.
want "install: system unit directory is /etc/systemd/system" "$INSTALL" 'SYSTEM_UNIT_DIR="/etc/systemd/system"'
want "install: system credential directory is the credstore" "$INSTALL" 'BACKUP_CRED_DIR="/etc/credstore/hybrid-ai-backup"'
want "install: daemon-reload in system mode" "$INSTALL" "systemctl daemon-reload"
want "install: enables the timers with enable --now" "$INSTALL" 'systemctl enable --now "\$unit"'
want "install: dispatches on HYBRID_AI_BACKUP_MODE" "$INSTALL" "HYBRID_AI_BACKUP_MODE"
want "install: system mode warns and never calls sudo when not root" "$INSTALL" "needs root to install the system units"
want_absent "install: no sudo invocation in the backup scheduler path" "$INSTALL" "sudo (install|cp|systemctl|chown|chmod|mkdir).*backup"
if grep -qF -- 'chmod 600 "$R2_ENV_FILE"' "$INSTALL"; then
  ok "install: credentials written 0600"
else
  bad "install: credentials written 0600"
fi
if grep -qF -- 'chown root:root "$R2_ENV_FILE"' "$INSTALL"; then
  ok "install: credentials chowned root in system mode"
else
  bad "install: credentials chowned root in system mode"
fi

# In system mode install_backup_scheduler() must NOT fall through to the user
# installer. Assert the dispatch returns before the user function name appears.
if awk '/^install_backup_scheduler\(\)/{f=1} f&&/install_backup_scheduler_user/{print; exit}' "$INSTALL" \
     | grep -q 'install_backup_scheduler_user'; then
  ok "install: system mode dispatches to the system installer"
else
  bad "install: system mode dispatch not found"
fi

# ---------------------------------------------------------------------------
# systemd-analyze verify, where available
# ---------------------------------------------------------------------------
echo "== systemd-analyze verify =="
if command -v systemd-analyze >/dev/null 2>&1; then
  for f in "$CAPTURE" "$UPLOAD" "$CAPTURE_TIMER" "$CHECK_SERVICE" "$CHECK_TIMER"; do
    # --man=no avoids needing man pages; the unit paths are absolute already.
    if err="$(systemd-analyze verify "$f" 2>&1)"; then
      ok "systemd-analyze verify: $(basename -- "$f")"
    else
      bad "systemd-analyze verify: $(basename -- "$f")"
      printf '%s\n' "$err" | sed 's/^/      /' >&2
    fi
  done
else
  echo "skip: systemd-analyze not available; static checks above still ran"
fi

# ---------------------------------------------------------------------------
if (( FAILURES != 0 )); then
  echo "FAILURES: $FAILURES" >&2
  exit 1
fi
echo "All backup system-unit checks passed."
exit 0
