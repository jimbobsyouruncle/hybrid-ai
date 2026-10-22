#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/lib/build-gate.sh
# PURPOSE (plain English):
#   Decide whether a deploy has to rebuild the Hermes image, and how to show
#   progress while a slow phase runs.
#
#   Sourcing this file defines functions only. It runs nothing and prints
#   nothing, so callers may source it under `set -euo pipefail`.
#
# WHAT THE GATE DOES:
#   The image records the hash of its build inputs in a LABEL
#   (org.hybrid-ai.build-inputs-sha). This library computes the hash of the
#   inputs as they are NOW. The deploy rebuilds when the two differ, and also
#   when it cannot prove they match: no image, no label, an empty label, a
#   label that is not a 64-hex sha, or any error along the way.
#
#   Inputs, hashed in this order with LC_ALL=C sorting for patches:
#     * hermes/Dockerfile, full content
#     * every file under hermes/patches/, as "<relative path> <sha256>"
#     * HERMES_COMMIT, HERMES_INSTALL_SHA256, HERMES_WEBUI_COMMIT, resolved as
#       environment value, else env-file value, else Dockerfile ARG default
#     * the base image digest parsed from the FROM line
#
# PUBLIC FUNCTIONS:
#   build_gate_inputs_sha <repo-root> [env-file]
#       Print the 64-hex build-inputs sha. Non-zero when it cannot be derived.
#   build_gate_decide <repo-root> [env-file] [image-ref]
#       Set BUILD_GATE_DECISION (rebuild|cache), BUILD_GATE_REASON and
#       BUILD_GATE_SHA. Always returns 0.
#   hybrid_progress_start <phase> / hybrid_progress_stop
#       Background heartbeat: one log line per HYBRID_PROGRESS_INTERVAL seconds
#       (default 60, 0 or less disables it) with elapsed seconds and the phase.
#       The loop is always killed by hybrid_progress_stop.
# ---------------------------------------------------------------------------

# Build-input tracking is only meaningful when the pin is readable.
BUILD_GATE_LABEL="org.hybrid-ai.build-inputs-sha"

build_gate_file_sha() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 -- "$1" | awk '{print $1}'
  else
    return 1
  fi
}

build_gate_stream_sha() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    return 1
  fi
}

# The ARG default from the Dockerfile. Empty when the ARG is absent or has no
# default.
build_gate_arg_default() {
  awk -v name="$2" '
    $1 == "ARG" {
      for (i = 2; i <= NF; i++) {
        eq = index($i, "=")
        if (eq == 0) continue
        if (substr($i, 1, eq - 1) != name) continue
        v = substr($i, eq + 1)
        gsub(/^"|"$/, "", v)
        print v
        exit
      }
    }
  ' "$1"
}

# KEY=VALUE from an env file. Comments, blank lines and CRLF are tolerated.
build_gate_envfile_value() {
  [[ -f "$1" ]] || return 0
  awk -v name="$2" '
    {
      line = $0
      sub(/\r$/, "", line)
      if (line ~ /^[[:space:]]*#/) next
      eq = index(line, "=")
      if (eq == 0) next
      k = substr(line, 1, eq - 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
      if (k != name) next
      v = substr(line, eq + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      if (v ~ /^["\047].*["\047]$/) v = substr(v, 2, length(v) - 2)
      print v
      exit
    }
  ' "$1"
}

# Environment wins, then the env file, then the Dockerfile default. This is
# the order compose itself applies to a build arg.
build_gate_arg_value() {
  local dockerfile="$1" envfile="$2" name="$3" value=""
  value="${!name:-}"
  [[ -n "$value" ]] || value="$(build_gate_envfile_value "$envfile" "$name")"
  [[ -n "$value" ]] || value="$(build_gate_arg_default "$dockerfile" "$name")"
  printf '%s' "$value"
}

# The pinned digest from the first FROM line that carries one, as
# "sha256:<64 hex>". Prints "unpinned" when the base is a floating tag.
build_gate_base_digest() {
  awk '
    toupper($1) == "FROM" {
      for (i = 2; i <= NF; i++) {
        if (match($i, /@sha256:[0-9a-f]+/)) {
          d = substr($i, RSTART + 1, RLENGTH - 1)
          if (length(d) == 71) { print d; found = 1; exit }
        }
      }
    }
    END { if (!found) print "unpinned" }
  ' "$1"
}

build_gate_inputs_sha() {
  local root="$1" envfile="${2:-}"
  local dockerfile="$root/hermes/Dockerfile"
  local base body="" rel sha

  [[ -f "$dockerfile" ]] || return 1
  base="$(build_gate_base_digest "$dockerfile")"
  [[ "$base" != "unpinned" ]] || return 1

  sha="$(build_gate_file_sha "$dockerfile")" || return 1
  body="dockerfile ${sha}"$'\n'

  if [[ -d "$root/hermes/patches" ]]; then
    while IFS= read -r rel; do
      sha="$(build_gate_file_sha "$root/$rel")" || return 1
      body+="patch ${rel} ${sha}"$'\n'
    done < <(cd "$root" && LC_ALL=C find hermes/patches -type f | LC_ALL=C sort)
  fi

  body+="arg HERMES_COMMIT $(build_gate_arg_value "$dockerfile" "$envfile" HERMES_COMMIT)"$'\n'
  body+="arg HERMES_INSTALL_SHA256 $(build_gate_arg_value "$dockerfile" "$envfile" HERMES_INSTALL_SHA256)"$'\n'
  body+="arg HERMES_WEBUI_COMMIT $(build_gate_arg_value "$dockerfile" "$envfile" HERMES_WEBUI_COMMIT)"$'\n'
  body+="base ${base}"$'\n'

  printf '%s' "$body" | build_gate_stream_sha
}

# Sets BUILD_GATE_DECISION, BUILD_GATE_REASON and BUILD_GATE_SHA. Every failure
# path decides "rebuild", so a gate that cannot answer builds.
# Those three are this function's output; the caller reads them, so inside the
# function they look unused.
# shellcheck disable=SC2034
build_gate_decide() {
  local root="$1" envfile="${2:-}" image="${3:-hybrid-ai-hermes:latest}"
  local sha="" label="" rc=0

  BUILD_GATE_DECISION="rebuild"
  BUILD_GATE_REASON="inputs-unavailable"
  BUILD_GATE_SHA="unknown"

  sha="$(build_gate_inputs_sha "$root" "$envfile" 2>/dev/null)" || rc=$?
  [[ $rc -eq 0 && -n "$sha" ]] || return 0
  BUILD_GATE_SHA="$sha"
  BUILD_GATE_REASON="image-absent"

  command -v docker >/dev/null 2>&1 || { BUILD_GATE_REASON="no-docker"; return 0; }

  label="$(docker image inspect \
    --format "{{ index .Config.Labels \"${BUILD_GATE_LABEL}\" }}" \
    "$image" 2>/dev/null)" || rc=$?
  [[ $rc -eq 0 ]] || return 0

  if [[ -z "$label" || "$label" == "<no value>" ]]; then
    BUILD_GATE_REASON="label-missing"
    return 0
  fi
  if [[ ! "$label" =~ ^[0-9a-f]{64}$ ]]; then
    BUILD_GATE_REASON="label-unparsable"
    return 0
  fi
  if [[ "$label" != "$sha" ]]; then
    BUILD_GATE_REASON="inputs-changed"
    return 0
  fi

  BUILD_GATE_DECISION="cache"
  BUILD_GATE_REASON="inputs-unchanged"
  return 0
}

# --- progress heartbeat ----------------------------------------------------
# One line per interval while a long phase runs, so a silent wait is visible in
# the install log. Interval 0 (or bad input) disables the heartbeat.
hybrid_progress_start() {
  local phase="$1"
  local interval="${HYBRID_PROGRESS_INTERVAL:-60}"

  [[ "$interval" =~ ^[0-9]+$ ]] || interval=60
  (( interval > 0 )) || return 0

  HYBRID_PROGRESS_START=$SECONDS

  (
    while :; do
      # `wait` on a background sleep is interruptible, so the kill below takes
      # effect at once instead of at the end of the interval.
      sleep "$interval" &
      wait $! || exit 0
      elapsed=$(( SECONDS - HYBRID_PROGRESS_START ))
      if declare -F log >/dev/null 2>&1; then
        log "progress: phase=${phase} elapsed=${elapsed}s"
      else
        printf 'progress: phase=%s elapsed=%ss\n' "$phase" "$elapsed"
      fi
    done
  ) &
  HYBRID_PROGRESS_PID=$!
}

hybrid_progress_stop() {
  if [[ -n "${HYBRID_PROGRESS_PID:-}" ]]; then
    kill "$HYBRID_PROGRESS_PID" 2>/dev/null || true
    wait "$HYBRID_PROGRESS_PID" 2>/dev/null || true
    HYBRID_PROGRESS_PID=""
  fi
  return 0
}
