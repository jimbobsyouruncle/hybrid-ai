#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/lib/hybrid-ai-env.sh
# PURPOSE (plain English):
#   The ONE place that works out where this project keeps its files on the
#   host. Source it; do not run it.
#
#   It resolves a small set of NAMED settings and exports them, so every
#   script and every compose call agrees on the same paths:
#
#     HYBRID_AI_APP_DIR   the program/repository directory (default: repo dir)
#     HYBRID_AI_ENV_FILE  the env file           (default: $HYBRID_AI_APP_DIR/.env)
#     HYBRID_AI_DATA_DIR  durable data           (default: repo dir)
#     HYBRID_AI_LOG_DIR   logs                    (default: repo dir)
#     HYBRID_AI_WORK_DIR  scratch/work            (default: repo dir)
#
#   It also resolves the settings that already existed, with the SAME names and
#   the SAME defaults as before, so a host that sets none of them keeps exactly
#   the paths it has today:
#
#     HYBRID_AI_UID, HYBRID_AI_GID, OPENHANDS_WORKSPACE, AGENT_REPOS_DIR,
#     OPENHANDS_STATE_DIR, BACKUP_CONF_DIR, RESTIC_CACHE_DIR, BACKUP_LOG
#
#   With NO settings, every resolved path equals today's, byte for byte.
#
# RESOLUTION ORDER (per setting):
#   1. the process environment   (an exported variable)
#   2. the env file, parsed LINE BY LINE -- never sourced
#   3. the built-in default
#
# WHY PARSE AND NEVER SOURCE:
#   `source` executes the file as shell code, so a value containing $(...) or
#   backticks would run as a command. The parser here only reads KEY=VALUE
#   lines; the value is treated as DATA, never as code.
#
# SAFETY RULES (a SET value -- from the environment or the env file):
#   * must be an absolute path (a relative path is refused)
#   * must not contain whitespace, a control character, ':' or ','
#   * must not be '/' itself
#   A refused value prints a clear message and the helper exits non-zero, so a
#   strict caller (set -e) stops before it touches a wrong path.
#
# SECURITY: this file never prints a value from the env file. It only puts
#   values into exports. Keep it that way.
# ---------------------------------------------------------------------------

# --- Where is the repository? (this file lives at <repo>/scripts/lib/) ------
_HYBRID_AI_ENV_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HYBRID_AI_DEFAULT_REPO_DIR="$(cd -- "${_HYBRID_AI_ENV_LIB_DIR}/../.." && pwd)"

# --- Small helpers ----------------------------------------------------------

# Print the canonical form of a path. realpath -m does not require the path to
# exist yet (staging/restore directories usually do not), and it collapses
# ".." textually as well as resolving symlinks on the parts that do exist.
_hybrid_ai_canon() {
  local p
  p="$(realpath -m -- "$1" 2>/dev/null)" || p="$1"
  printf '%s' "$p"
}

# Expand a leading ~ by hand. A value read from a file is not tilde-expanded by
# the shell, and mounting a literal "~/data" directory is a confusing failure.
_hybrid_ai_expand_tilde() {
  # Match a literal "~" on purpose: a value read from a file is not expanded.
  # shellcheck disable=SC2088
  case "$1" in
    "~/"*) printf '%s' "${HOME:-}/${1#\~/}" ;;
    "~")   printf '%s' "${HOME:-}" ;;
    *)     printf '%s' "$1" ;;
  esac
}

# Read ONE key from a file, line by line, never sourcing. Returns the LAST
# match (last wins), matching install.sh's loader. Quotes are stripped.
_hybrid_ai_file_get() {
  local file="$1" key="$2" line candidate
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*${key}=(.*)$ ]] || continue
    candidate="${BASH_REMATCH[1]}"
    candidate="${candidate%\"}"; candidate="${candidate#\"}"
    candidate="${candidate%\'}"; candidate="${candidate#\'}"
    printf '%s' "$candidate"
  done < "$file"
}

# Refuse a value that is not a usable absolute path. Prints a clear message and
# returns 1. The message names the SETTING and the reason -- never a value that
# came from the env file (the reason is enough to fix it).
_hybrid_ai_validate_path() {
  local name="$1" val="$2"
  if [[ -z "$val" ]]; then
    printf 'hybrid-ai-env: %s is empty; give an absolute path or leave it unset.\n' "$name" >&2
    return 1
  fi
  if [[ "$val" == "/" ]]; then
    printf 'hybrid-ai-env: %s must not be "/".\n' "$name" >&2
    return 1
  fi
  case "$val" in
    *[[:cntrl:]]*)
      printf 'hybrid-ai-env: %s contains a control character.\n' "$name" >&2
      return 1 ;;
    *[[:space:]]*)
      printf 'hybrid-ai-env: %s contains whitespace.\n' "$name" >&2
      return 1 ;;
    *:*|*,*)
      printf 'hybrid-ai-env: %s contains ":" or ",", which is not allowed in a path here.\n' "$name" >&2
      return 1 ;;
  esac
  case "$val" in
    /*) ;;
    *)
      printf 'hybrid-ai-env: %s must be an absolute path.\n' "$name" >&2
      return 1 ;;
  esac
  return 0
}

# Resolve one PATH setting: environment, then env file, then default.
# Sets the variable named by $1. Set values are validated; defaults are used
# as-is (they are trusted, built-in absolute paths).
_hybrid_ai_resolve_path() {
  local name="$1" default="$2" envfile="$3" val origin
  val="${!name:-}"
  if [[ -n "$val" ]]; then
    origin="environment"
  else
    val="$(_hybrid_ai_file_get "$envfile" "$name")"
    if [[ -n "$val" ]]; then origin="env file"; else origin="default"; fi
  fi
  if [[ "$origin" == "default" ]]; then
    val="$default"
  else
    val="$(_hybrid_ai_expand_tilde "$val")"
    if ! _hybrid_ai_validate_path "$name" "$val"; then
      printf 'hybrid-ai-env: refused the %s value for %s.\n' "$origin" "$name" >&2
      return 1
    fi
    # Remember that this setting was SET (so doctor.sh can warn, and only warn,
    # about a set path that does not exist yet).
    HYBRID_AI_EXPLICIT_SETTINGS="${HYBRID_AI_EXPLICIT_SETTINGS:-} ${name}"
  fi
  printf -v "$name" '%s' "$(_hybrid_ai_canon "$val")"
  export "${name?}"
  return 0
}

# Resolve one ENUM setting: environment, then env file, then default. The value
# must be one of the allowed words; any other value is refused (non-zero exit),
# so a typo cannot silently select the wrong behaviour. The message names the
# SETTING and the allowed words -- never the rejected value, which may have come
# from the env file.
_hybrid_ai_resolve_enum() {
  local name="$1" default="$2" allowed="$3" envfile="$4" val origin a matched
  val="${!name:-}"
  if [[ -n "$val" ]]; then
    origin="environment"
  else
    val="$(_hybrid_ai_file_get "$envfile" "$name")"
    if [[ -n "$val" ]]; then origin="env file"; else origin="default"; fi
  fi
  if [[ "$origin" == "default" ]]; then
    val="$default"
  else
    matched=0
    for a in $allowed; do [[ "$val" == "$a" ]] && matched=1; done
    if (( ! matched )); then
      printf 'hybrid-ai-env: %s must be one of: %s.\n' "$name" "$allowed" >&2
      printf 'hybrid-ai-env: refused the %s value for %s.\n' "$origin" "$name" >&2
      return 1
    fi
  fi
  printf -v "$name" '%s' "$val"
  export "${name?}"
  return 0
}

# Resolve one NON-path setting (a uid, gid, or other scalar): environment, then
# env file, then default. No path validation is applied.
_hybrid_ai_resolve_scalar() {
  local name="$1" default="$2" envfile="$3" val
  val="${!name:-}"
  if [[ -z "$val" ]]; then
    val="$(_hybrid_ai_file_get "$envfile" "$name")"
  fi
  if [[ -z "$val" ]]; then val="$default"; fi
  printf -v "$name" '%s' "$val"
  export "${name?}"
  return 0
}

# --- Resolve everything -----------------------------------------------------
hybrid_ai_env_load() {
  # Bootstrap: find the env file we will read values from. Prefer an explicit
  # HYBRID_AI_ENV_FILE, then an explicit HYBRID_AI_APP_DIR, then the default
  # repository directory.
  local boot_env
  if [[ -n "${HYBRID_AI_ENV_FILE:-}" ]]; then
    boot_env="${HYBRID_AI_ENV_FILE}"
  elif [[ -n "${HYBRID_AI_APP_DIR:-}" ]]; then
    boot_env="$(_hybrid_ai_canon "$HYBRID_AI_APP_DIR")/.env"
  else
    boot_env="${HYBRID_AI_DEFAULT_REPO_DIR}/.env"
  fi

  # APP_DIR: environment, then the bootstrap env file, then the repo dir.
  _hybrid_ai_resolve_path HYBRID_AI_APP_DIR "$HYBRID_AI_DEFAULT_REPO_DIR" "$boot_env" || return 1

  # ENV_FILE: environment, then the bootstrap env file, then $APP_DIR/.env.
  local env_default="${HYBRID_AI_APP_DIR}/.env"
  if [[ -n "${HYBRID_AI_ENV_FILE:-}" ]]; then
    boot_env="${HYBRID_AI_ENV_FILE}"
  else
    local from_file
    from_file="$(_hybrid_ai_file_get "$boot_env" HYBRID_AI_ENV_FILE)"
    if [[ -n "$from_file" ]]; then
      boot_env="$(_hybrid_ai_expand_tilde "$from_file")"
    else
      boot_env="$env_default"
    fi
  fi
  _hybrid_ai_resolve_path HYBRID_AI_ENV_FILE "$env_default" "$boot_env" || return 1

  # From here on, read values from the RESOLVED env file.
  local ef="$HYBRID_AI_ENV_FILE"
  local repo_default="$HYBRID_AI_DEFAULT_REPO_DIR"

  _hybrid_ai_resolve_path HYBRID_AI_DATA_DIR "$repo_default" "$ef" || return 1
  _hybrid_ai_resolve_path HYBRID_AI_LOG_DIR  "$repo_default" "$ef" || return 1
  _hybrid_ai_resolve_path HYBRID_AI_WORK_DIR "$repo_default" "$ef" || return 1

  # Kept settings -- same names, same defaults as before this helper existed.
  _hybrid_ai_resolve_scalar HYBRID_AI_UID "" "$ef" || return 1
  _hybrid_ai_resolve_scalar HYBRID_AI_GID "" "$ef" || return 1
  _hybrid_ai_resolve_path OPENHANDS_WORKSPACE "${HOME:-}/hybrid-ai-agent" "$ef" || return 1
  _hybrid_ai_resolve_path AGENT_REPOS_DIR     "${HOME:-}/hybrid-ai-repos" "$ef" || return 1
  _hybrid_ai_resolve_path OPENHANDS_STATE_DIR "${HOME:-}/.openhands"      "$ef" || return 1
  _hybrid_ai_resolve_path BACKUP_CONF_DIR     "${HOME:-}/.config/hybrid-ai-backup" "$ef" || return 1
  _hybrid_ai_resolve_path RESTIC_CACHE_DIR    "${HOME:-}/.cache/restic"   "$ef" || return 1
  # Durable per-user Hermes state captured by the backup. Derived from HOME by
  # default (exactly where backup.sh and restore.sh already looked), but now a
  # named path setting so a system-mode unit can relocate it.
  _hybrid_ai_resolve_path HYBRID_AI_HERMES_HOME_DIR "${HOME:-}/.hermes" "$ef" || return 1

  # --- Mode selectors -------------------------------------------------------
  # HYBRID_AI_BACKUP_MODE picks WHICH system units run the backup. "user" keeps
  # today's per-user units; "system" selects the two-unit privilege split. Any
  # other value is refused. It selects units only -- backup.sh's own behaviour
  # is chosen by its --stage-only/--upload-only flags, not by this setting.
  _hybrid_ai_resolve_enum HYBRID_AI_BACKUP_MODE "user" "user system" "$ef" || return 1
  # BACKUP_CONTAINER_CONTROL=external tells backup.sh that a root helper pauses
  # and unpauses the containers, so backup.sh itself must call no docker command.
  # Default "self" is today's behaviour (the script pauses/execs docker itself).
  _hybrid_ai_resolve_enum BACKUP_CONTAINER_CONTROL "self" "self external" "$ef" || return 1

  # --- Derived paths (names unchanged) --------------------------------------
  HYBRID_AI_HERMES_DATA_DIR="${HYBRID_AI_DATA_DIR}/hermes_data"
  HYBRID_AI_WEBUI_DATA_DIR="${HYBRID_AI_DATA_DIR}/webui_data"
  HYBRID_AI_OLLAMA_DATA_DIR="${HYBRID_AI_DATA_DIR}/ollama_data"
  HYBRID_AI_INSTALL_LOG="${HYBRID_AI_LOG_DIR}/install.log"
  HYBRID_AI_BACKUP_STAGING_DIR="${HYBRID_AI_WORK_DIR}/.backup-staging"
  HYBRID_AI_RESTORE_WORK_DIR="${HYBRID_AI_WORK_DIR}/.restore-work"
  export HYBRID_AI_HERMES_DATA_DIR HYBRID_AI_WEBUI_DATA_DIR HYBRID_AI_OLLAMA_DATA_DIR
  export HYBRID_AI_INSTALL_LOG HYBRID_AI_BACKUP_STAGING_DIR HYBRID_AI_RESTORE_WORK_DIR

  # BACKUP_LOG keeps its name and default: $LOG_DIR/backup.log. The resolved
  # value is exported so backup.sh/restore.sh/doctor.sh share one path.
  _hybrid_ai_resolve_path BACKUP_LOG "${HYBRID_AI_LOG_DIR}/backup.log" "$ef" || return 1

  # --- Mode-derived unit names and credential directory ---------------------
  # ONE place resolves which backup units a mode uses, so install.sh, doctor.sh,
  # deploy-remote.sh, collect-diagnostics.sh and backup.sh cannot disagree. In
  # system mode the credentials live in the root-owned credstore the units read;
  # in user mode they live in BACKUP_CONF_DIR, exactly as today. Names and paths
  # only -- never a value.
  if [[ "$HYBRID_AI_BACKUP_MODE" == "system" ]]; then
    HYBRID_AI_BACKUP_TIMER_UNIT="hybrid-ai-backup-capture.timer"
    HYBRID_AI_BACKUP_SERVICE_UNIT="hybrid-ai-backup-capture.service"
    HYBRID_AI_BACKUP_CHECK_TIMER_UNIT="hybrid-ai-backup-check.timer"
    HYBRID_AI_BACKUP_SYSTEMCTL_SCOPE="--system"
    HYBRID_AI_BACKUP_JOURNAL_SCOPE="--system"
    _hybrid_ai_backup_cred_default="/etc/credstore/hybrid-ai-backup"
  else
    HYBRID_AI_BACKUP_TIMER_UNIT="hybrid-ai-backup.timer"
    HYBRID_AI_BACKUP_SERVICE_UNIT="hybrid-ai-backup.service"
    HYBRID_AI_BACKUP_CHECK_TIMER_UNIT="hybrid-ai-check.timer"
    HYBRID_AI_BACKUP_SYSTEMCTL_SCOPE="--user"
    HYBRID_AI_BACKUP_JOURNAL_SCOPE="--user"
    _hybrid_ai_backup_cred_default="$BACKUP_CONF_DIR"
  fi
  # The credential directory is a NAMED path setting (env file or environment may
  # relocate it) whose DEFAULT follows the mode. Names and paths only.
  _hybrid_ai_resolve_path HYBRID_AI_BACKUP_CRED_DIR "$_hybrid_ai_backup_cred_default" "$ef" || return 1
  unset _hybrid_ai_backup_cred_default
  export HYBRID_AI_BACKUP_CRED_DIR HYBRID_AI_BACKUP_TIMER_UNIT
  export HYBRID_AI_BACKUP_SERVICE_UNIT HYBRID_AI_BACKUP_CHECK_TIMER_UNIT
  export HYBRID_AI_BACKUP_SYSTEMCTL_SCOPE HYBRID_AI_BACKUP_JOURNAL_SCOPE

  return 0
}

if ! hybrid_ai_env_load; then
  # A sourced refusal must be a NON-ZERO EXIT of the calling script, not a
  # warning that lets it blunder on with half-resolved paths.
  exit 1
fi
