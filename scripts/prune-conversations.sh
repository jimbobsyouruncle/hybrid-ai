#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/prune-conversations.sh
# PURPOSE (plain English):
#   Move stale OpenHands conversation directories out of
#   ${OPENHANDS_WORKSPACE}/conversations/ and into a date-stamped quarantine
#   root. QUARANTINE ONLY. Nothing is ever deleted, so an operator can always
#   move a directory back and no conversation history is lost.
#
#   A directory is moved only when ALL of these hold:
#     1. it is a real directory (not a symlink) whose name is a plain token,
#     2. its own path does not escape the conversations root,
#     3. its owner_lease.json is readable AND its expiry is in the past by more
#        than the grace period (an unreadable lease is treated as live
#        forever),
#     4. its mtime is older than the age limit,
#     5. no running container mounts it,
#     6. the move cap has not been reached, the destination name is free, and
#        the quarantine lives on the same filesystem.
#
#   Every degraded condition (missing root, missing python3, no docker, an
#   unreadable lease) is logged and the script still reaches the summary line
#   and exits 0. Nothing here needs systemd; `systemctl` is never called.
#
# CONFIGURATION (all overridable by environment; seconds are used internally so
# an offline harness can drive cases quickly):
#   HYBRID_AI_PRUNE_AGE_SECONDS         default 604800 (7 days)
#       A directory whose mtime is NEWER than this many seconds is kept.
#   HYBRID_AI_PRUNE_GRACE_SECONDS       default 86400 (24 hours)
#       An expired lease is kept until it has been expired this long.
#   HYBRID_AI_PRUNE_MAX_MOVES           default 20
#       Upper bound on moves for one run. Further eligible directories are
#       refused with reason=cap-reached.
#   HYBRID_AI_PRUNE_QUARANTINE_BASE     optional
#       Quarantine root override. Default: the sibling directory
#       <dirname HYBRID_AI_DATA_DIR>/hybrid-ai-conversation-quarantine.
#       It is still checked against every tree the backup captures.
#
#   All host paths come from scripts/lib/hybrid-ai-env.sh, the one resolver.
#   No default in that file is changed here.
#
# LEASE SCHEMA (observed, not assumed):
#   A live lease file read on a host running this stack looked like:
#     {"owner_instance_id": "...", "generation": 1,
#      "expires_at": <float epoch seconds>, "owner_host": "...",
#      "owner_pid": 10}
#   So the field carrying the deadline was `expires_at` (epoch seconds, float)
#   and generation was spelled `generation`, not `gen`. The parser below accepts
#   every key in EXPIRY_KEYS because the shape is host-observed and may vary.
#   No live lease file was visible? Then the header above is the host-observed
#   record and unknown shapes are KEPT: an unrecognised lease never authorises
#   a move. owner_host and gen/generation are logged as context only; they are
#   never used to decide a move.
#
#   Expiry values may be an epoch number in seconds (a value above 1e12 is
#   read as milliseconds) or an ISO-8601 string with a trailing Z or an offset.
#   An ISO-8601 string without a zone is read as UTC.
#
# WHY THE BACKUP LIST MATTERS:
#   backup/backup.sh captures HYBRID_AI_DATA_DIR, the app tree
#   (openhands/, hermes/, scripts/, status/, compose files), the work tree
#   through its staging directory, hermes_data, webui_data and the .openhands
#   state. A quarantine inside any of those would be swept into the next
#   snapshot and the later upload, so the assertion below refuses to move
#   anything unless the quarantine root is proven outside all of them.
#
# USAGE:
#   ./scripts/prune-conversations.sh
#
# EXIT CODES:
#   0  always: moved, kept, or refused. Read the summary line for what happened.
# ---------------------------------------------------------------------------
set -u
set -o pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/hybrid-ai-env.sh
source "${SCRIPT_DIR}/lib/hybrid-ai-env.sh"

# --- Output helpers (match install.sh / backup.sh) --------------------------
if [[ -t 1 ]]; then
  C_RST=$'\033[0m'; C_INF=$'\033[36m'; C_WRN=$'\033[33m'; C_ERR=$'\033[31m'
else
  C_RST=""; C_INF=""; C_WRN=""; C_ERR=""
fi
log()  { printf '%s[ * ]%s %s\n' "$C_INF" "$C_RST" "$*"; }
warn() { printf '%s[ ! ]%s %s\n' "$C_WRN" "$C_RST" "$*" >&2; }
refuse() { printf '%s[ X ]%s %s\n' "$C_ERR" "$C_RST" "$*" >&2; }

# --- Configuration ---------------------------------------------------------
PRUNE_AGE_SECONDS="${HYBRID_AI_PRUNE_AGE_SECONDS:-604800}"
PRUNE_GRACE_SECONDS="${HYBRID_AI_PRUNE_GRACE_SECONDS:-86400}"
PRUNE_MAX_MOVES="${HYBRID_AI_PRUNE_MAX_MOVES:-20}"
PRUNE_QUARANTINE_BASE="${HYBRID_AI_PRUNE_QUARANTINE_BASE:-}"

EXPIRY_KEYS="expiry expires_at expires expire_at expiresAt expiry_epoch expires_at_epoch"

SCANNED=0
KEPT_LIVE=0
KEPT_RECENT=0
MOVED=0
REFUSED=0
REFUSAL_REASONS=()
QUARANTINE_RUN_DIR="none"
SUMMARY_DONE=0
DOCKER_UNAVAILABLE_LOGGED=0

summary() {
  (( SUMMARY_DONE )) && return 0
  SUMMARY_DONE=1
  local reasons="none"
  if (( ${#REFUSAL_REASONS[@]} > 0 )); then
    reasons="$(printf '%s | ' "${REFUSAL_REASONS[@]}")"
    reasons="${reasons% | }"
  fi
  log "summary: scanned=${SCANNED} kept-live=${KEPT_LIVE} kept-recent=${KEPT_RECENT} moved=${MOVED} refused=${REFUSED} quarantine=${QUARANTINE_RUN_DIR} refusals=${reasons}"
}

# Every path ends here: log the summary once and exit 0. The trap is a backstop
# for an unexpected exit, so a degraded run still reports its counts.
finish() { summary; exit 0; }
trap 'summary' EXIT

# Count a refusal and remember why, so the summary line names every reason.
deny() {
  REFUSED=$(( REFUSED + 1 ))
  REFUSAL_REASONS+=("$1")
  refuse "refused: $1"
}

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }

# Canonical form of a path, or non-zero when realpath cannot produce one.
canon() { realpath -m -- "$1" 2>/dev/null; }

# True when $1 is $2 or lives under $2 (both already canonical).
path_within() { [[ "$1" == "$2" || "$1" == "$2"/* ]]; }

# --- Degraded-config refusals ---------------------------------------------
for _knob in PRUNE_AGE_SECONDS PRUNE_GRACE_SECONDS PRUNE_MAX_MOVES; do
  if ! is_uint "${!_knob}"; then
    warn "config: ${_knob} is not a whole number of seconds (value not printed); refusing to move anything."
    QUARANTINE_RUN_DIR="none"
    finish
  fi
done
unset _knob

# --- The conversations root ------------------------------------------------
if [[ -z "${OPENHANDS_WORKSPACE:-}" ]]; then
  warn "root: OPENHANDS_WORKSPACE is empty; refusing to sweep."
  finish
fi

WORKSPACE_REAL="$(canon "$OPENHANDS_WORKSPACE")" || WORKSPACE_REAL=""
if [[ -z "$WORKSPACE_REAL" ]]; then
  warn "root: cannot canonicalize OPENHANDS_WORKSPACE; refusing to sweep."
  finish
fi

CONV_ROOT="${OPENHANDS_WORKSPACE%/}/conversations"
CONV_ROOT_REAL="$(canon "$CONV_ROOT")" || CONV_ROOT_REAL=""
if [[ -z "$CONV_ROOT_REAL" ]]; then
  warn "root: cannot canonicalize ${CONV_ROOT}; refusing to sweep."
  finish
fi
if [[ "$CONV_ROOT_REAL" != "${WORKSPACE_REAL}/conversations" ]]; then
  warn "root: ${CONV_ROOT_REAL} is not ${WORKSPACE_REAL}/conversations; refusing to sweep."
  finish
fi
if [[ ! -e "$CONV_ROOT_REAL" ]]; then
  warn "root: ${CONV_ROOT_REAL} does not exist; nothing to do."
  finish
fi
if [[ ! -d "$CONV_ROOT_REAL" ]]; then
  warn "root: ${CONV_ROOT_REAL} is not a directory; nothing to do."
  finish
fi

# --- The quarantine root --------------------------------------------------
if [[ -n "$PRUNE_QUARANTINE_BASE" ]]; then
  QUARANTINE_BASE_RAW="$PRUNE_QUARANTINE_BASE"
else
  if [[ -z "${HYBRID_AI_DATA_DIR:-}" ]]; then
    warn "quarantine: HYBRID_AI_DATA_DIR is empty, so the default quarantine root cannot be derived; refusing to sweep."
    finish
  fi
  QUARANTINE_BASE_RAW="$(dirname -- "${HYBRID_AI_DATA_DIR%/}")/hybrid-ai-conversation-quarantine"
fi

QUARANTINE_BASE="$(canon "$QUARANTINE_BASE_RAW")" || QUARANTINE_BASE=""
if [[ -z "$QUARANTINE_BASE" ]]; then
  warn "quarantine: cannot canonicalize the quarantine root; refusing to sweep."
  finish
fi
if [[ "$QUARANTINE_BASE" == "/" ]]; then
  warn "quarantine: the quarantine root resolved to /; refusing to sweep."
  finish
fi

# --- Backup assertion: the quarantine must never enter a captured tree ------
backup_assert_ok() {
  local name val cval
  for name in HYBRID_AI_DATA_DIR HYBRID_AI_APP_DIR HYBRID_AI_WORK_DIR \
              HYBRID_AI_HERMES_DATA_DIR HYBRID_AI_WEBUI_DATA_DIR OPENHANDS_WORKSPACE; do
    val="${!name:-}"
    if [[ -z "$val" ]]; then
      warn "backup-assertion: ${name} is unset or empty; refusing to move anything."
      return 1
    fi
    cval="$(canon "$val")" || cval=""
    if [[ -z "$cval" ]]; then
      warn "backup-assertion: cannot canonicalize ${name}; refusing to move anything."
      return 1
    fi
    if path_within "$QUARANTINE_BASE" "${cval%/}"; then
      warn "backup-assertion: ${QUARANTINE_BASE} is inside ${name} (${cval}), which the backup captures; refusing to move anything."
      return 1
    fi
  done
  return 0
}

if ! backup_assert_ok; then
  finish
fi

# --- Create the run directory ---------------------------------------------
QUARANTINE_RUN_DIR="${QUARANTINE_BASE}/$(date -u +%Y%m%d)"
if ! install -d -m 0750 -- "$QUARANTINE_BASE" 2>/dev/null; then
  warn "quarantine: cannot create ${QUARANTINE_BASE}; refusing to sweep."
  QUARANTINE_RUN_DIR="none"
  finish
fi
if ! install -d -m 0750 -- "$QUARANTINE_RUN_DIR" 2>/dev/null; then
  warn "quarantine: cannot create ${QUARANTINE_RUN_DIR}; refusing to sweep."
  QUARANTINE_RUN_DIR="none"
  finish
fi
if (( EUID == 0 )); then
  for _qdir in "$QUARANTINE_BASE" "$QUARANTINE_RUN_DIR"; do
    if [[ "$(stat -c %u -- "$_qdir" 2>/dev/null)" != "0" ]]; then
      warn "quarantine: ${_qdir} is not owned by uid 0 while running as root; refusing to move anything."
      QUARANTINE_RUN_DIR="none"
      finish
    fi
  done
  unset _qdir
fi

# --- Filesystem facts -----------------------------------------------------
NOW_EPOCH="$(date -u +%s)"
CONV_FS="$(stat -c %d -- "$CONV_ROOT_REAL" 2>/dev/null)" || CONV_FS=""
QUARANTINE_FS="$(stat -c %d -- "$QUARANTINE_RUN_DIR" 2>/dev/null)" || QUARANTINE_FS=""

# --- Lease guard ----------------------------------------------------------
# Prints "<verdict>|<detail>" where verdict is expired, live, or keep.
lease_verdict() {
  python3 - "$1" "$NOW_EPOCH" "$PRUNE_GRACE_SECONDS" "$EXPIRY_KEYS" <<'PY'
import datetime
import json
import os
import sys

dir_path, now_s, grace_s, keys = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), sys.argv[4].split()
lease = os.path.join(dir_path, "owner_lease.json")

try:
    with open(lease, "r", encoding="utf-8", errors="replace") as handle:
        raw = handle.read()
except FileNotFoundError:
    print("keep|lease-missing")
    raise SystemExit(0)
except OSError:
    print("keep|lease-unreadable")
    raise SystemExit(0)

if not raw.strip():
    print("keep|lease-empty")
    raise SystemExit(0)

try:
    data = json.loads(raw)
except (ValueError, UnicodeDecodeError):
    print("keep|lease-unparsable-json")
    raise SystemExit(0)

if not isinstance(data, dict):
    print("keep|lease-not-an-object")
    raise SystemExit(0)

value = None
for key in keys:
    if key in data and data[key] is not None:
        value = data[key]
        break

if value is None:
    print("keep|lease-no-expiry-key")
    raise SystemExit(0)

expiry = None
if isinstance(value, bool):
    expiry = None
elif isinstance(value, (int, float)):
    expiry = float(value)
elif isinstance(value, str):
    text = value.strip()
    try:
        expiry = float(text)
    except ValueError:
        candidate = text
        if candidate.endswith("Z") or candidate.endswith("z"):
            candidate = candidate[:-1] + "+00:00"
        try:
            parsed = datetime.datetime.fromisoformat(candidate)
        except ValueError:
            expiry = None
        else:
            if parsed.tzinfo is None:
                parsed = parsed.replace(tzinfo=datetime.timezone.utc)
            expiry = parsed.timestamp()

if expiry is None:
    print("keep|lease-expiry-unparsable")
    raise SystemExit(0)

if expiry > 1e12:
    expiry = expiry / 1000.0

context = "owner_host={} gen={}".format(
    data.get("owner_host", "unknown"),
    data.get("generation", data.get("gen", "unknown")),
)

if expiry >= now_s:
    print("live|lease-valid {}".format(context))
elif now_s - expiry < grace_s:
    print("live|lease-in-grace {}".format(context))
else:
    print("expired|lease-expired {} expired_for={:.0f}s".format(context, now_s - expiry))
PY
}

# --- Container guard ------------------------------------------------------
# The program is passed with -c so STDIN stays free for `docker inspect` JSON.
read -r -d '' CONTAINER_GUARD_PY <<'PY'
import json
import os
import sys

target = os.path.realpath(sys.argv[1])

try:
    data = json.load(sys.stdin)
except (ValueError, UnicodeDecodeError):
    print("unknown")
    raise SystemExit(0)

if not isinstance(data, list):
    print("unknown")
    raise SystemExit(0)


def inside(path):
    if not isinstance(path, str) or not path:
        return False
    resolved = os.path.realpath(path)
    return resolved == target or resolved.startswith(target + os.sep)


for container in data:
    if not isinstance(container, dict):
        continue
    config = container.get("Config") or {}
    if inside(config.get("WorkingDir")):
        print("live")
        raise SystemExit(0)
    for mount in container.get("Mounts") or []:
        if isinstance(mount, dict) and inside(mount.get("Source")):
            print("live")
            raise SystemExit(0)

print("none")
PY

# Reads `docker inspect` JSON on stdin; prints live, none, or unknown.
container_uses_dir() {
  python3 -c "$CONTAINER_GUARD_PY" "$1"
}

container_verdict() {
  local dir="$1" ps_out inspect_out
  if ! command -v docker >/dev/null 2>&1; then
    printf '%s' "unavailable"
    return 0
  fi
  # A present docker CLI with an unreachable daemon is UNAVAILABLE, exactly like
  # an absent CLI: the guard cannot see containers, so it logs that and the
  # lease and age guards still decide. That is a degraded path, not a failure.
  if ! ps_out="$(docker ps --no-trunc --format '{{.ID}}' 2>/dev/null)"; then
    printf '%s' "unavailable"
    return 0
  fi
  local -a ids=()
  local id
  while IFS= read -r id; do
    [[ -n "$id" ]] && ids+=("$id")
  done <<< "$ps_out"
  if (( ${#ids[@]} == 0 )); then
    printf '%s' "none"
    return 0
  fi
  if ! inspect_out="$(docker inspect -- "${ids[@]}" 2>/dev/null)"; then
    printf '%s' "unavailable"
    return 0
  fi
  printf '%s' "$inspect_out" | container_uses_dir "$dir"
}

if ! command -v python3 >/dev/null 2>&1; then
  warn "lease-guard: python3 is missing, so no lease can be read; every directory is kept (degraded path)."
fi

# --- The sweep ------------------------------------------------------------
while IFS= read -r -d '' entry; do
  SCANNED=$(( SCANNED + 1 ))
  name="${entry##*/}"

  if [[ -L "$entry" ]]; then
    deny "${name}: symlink"
    continue
  fi
  if [[ ! -d "$entry" ]]; then
    continue
  fi
  if [[ ! "$name" =~ ^[A-Za-z0-9._-]+$ ]]; then
    deny "${name}: unsafe-name"
    continue
  fi
  entry_real="$(canon "$entry")" || entry_real=""
  if [[ "$entry_real" != "${CONV_ROOT_REAL}/${name}" ]]; then
    deny "${name}: path-escape"
    continue
  fi

  # Lease guard: conservative. An unreadable or absent lease is live forever.
  if ! command -v python3 >/dev/null 2>&1; then
    KEPT_LIVE=$(( KEPT_LIVE + 1 ))
    log "kept-live: ${name} (reason=no-python3)"
    continue
  fi
  verdict_line="$(lease_verdict "$entry_real")" || verdict_line=""
  verdict="${verdict_line%%|*}"
  detail="${verdict_line#*|}"
  case "$verdict" in
    live)
      KEPT_LIVE=$(( KEPT_LIVE + 1 ))
      log "kept-live: ${name} (reason=${detail})"
      continue
      ;;
    expired)
      ;;
    *)
      deny "${name}: ${detail:-lease-unparsable}"
      continue
      ;;
  esac

  # Age guard: a recently touched directory is kept even with a stale lease.
  mtime="$(stat -c %Y -- "$entry_real" 2>/dev/null)" || mtime=""
  if [[ -z "$mtime" ]] || ! is_uint "$mtime"; then
    deny "${name}: mtime-unreadable"
    continue
  fi
  if (( NOW_EPOCH - mtime < PRUNE_AGE_SECONDS )); then
    KEPT_RECENT=$(( KEPT_RECENT + 1 ))
    log "kept-recent: ${name} (mtime_age=$(( NOW_EPOCH - mtime ))s)"
    continue
  fi

  # Container guard: a running container that mounts the directory keeps it.
  cverdict="$(container_verdict "$entry_real")" || cverdict="unknown"
  case "$cverdict" in
    none)
      ;;
    live)
      KEPT_LIVE=$(( KEPT_LIVE + 1 ))
      log "kept-live: ${name} (reason=container-live)"
      continue
      ;;
    unavailable)
      if (( ! DOCKER_UNAVAILABLE_LOGGED )); then
        DOCKER_UNAVAILABLE_LOGGED=1
        log "container-guard=unavailable (no usable docker); relying on the lease guard"
      fi
      ;;
    *)
      KEPT_LIVE=$(( KEPT_LIVE + 1 ))
      log "kept-live: ${name} (reason=container-guard-unknown)"
      continue
      ;;
  esac

  if (( MOVED >= PRUNE_MAX_MOVES )); then
    deny "${name}: cap-reached (${PRUNE_MAX_MOVES})"
    continue
  fi

  dest="${QUARANTINE_RUN_DIR}/${name}"
  if [[ -e "$dest" || -L "$dest" ]]; then
    deny "${name}: destination-exists"
    continue
  fi
  entry_fs="$(stat -c %d -- "$entry_real" 2>/dev/null)" || entry_fs=""
  same_fs=1
  if [[ -z "$entry_fs" ]] || [[ -z "$CONV_FS" ]] || [[ -z "$QUARANTINE_FS" ]]; then
    same_fs=0
  fi
  if [[ "$entry_fs" != "$CONV_FS" ]]; then
    same_fs=0
  fi
  if [[ "$entry_fs" != "$QUARANTINE_FS" ]]; then
    same_fs=0
  fi
  if (( ! same_fs )); then
    deny "${name}: cross-device"
    continue
  fi
  unset same_fs

  if mv -n -- "$entry_real" "$dest" 2>/dev/null && [[ -d "$dest" && ! -e "$entry_real" ]]; then
    MOVED=$(( MOVED + 1 ))
    log "moved: ${name} -> ${QUARANTINE_RUN_DIR}"
  else
    deny "${name}: move-failed"
  fi
done < <(find "$CONV_ROOT_REAL" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)

finish
