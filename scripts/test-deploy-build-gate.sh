#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/test-deploy-build-gate.sh
# PURPOSE (plain English):
#   Offline tests for the deploy build gate, the timestamped log and the
#   progress heartbeat. No Docker daemon and no network: a fake `docker` on PATH
#   answers `image inspect`, and the tests run against a scratch fixture tree.
#
# CASES (each printed by name):
#   a) inputs unchanged, image label matches -> no --build
#   b) one ARG changed -> build
#   c) image absent (inspect fails) -> build
#   d) label unreadable/empty/unparsable -> build
#   e) label present but different -> build
#   f) label present and equal -> no build
#   g) progress cadence: at least one line per interval during pull and build
#   h) timestamp format: every log line matches the UTC stamp pattern
#
# USAGE:
#   bash scripts/test-deploy-build-gate.sh
#
# EXIT CODES:
#   0  every case passed
#   1  one or more cases failed
#   2  a required tool is missing
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
for t in mktemp grep cmp sed; do
  command -v "$t" >/dev/null 2>&1 || { echo "error: $t is required" >&2; exit 2; }
done

LIB="$REPO/scripts/lib/build-gate.sh"
if [[ ! -f "$LIB" ]]; then
  echo "FATAL: ${LIB} is missing; the build gate does not exist in this tree." >&2
  exit 2
fi

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

# --- fixture tree ------------------------------------------------------------
# A miniature repo: hermes/Dockerfile with the three ARGs and a pinned FROM, one
# patch, and an env file that can override an ARG.
FIX="$WORK/fixture"
mkdir -p "$FIX/hermes/patches" "$WORK/bin"
BASE_DIGEST="sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
cat > "$FIX/hermes/Dockerfile" <<EOF
FROM python:3.11-slim@${BASE_DIGEST}
ARG BUILD_INPUTS_SHA=unknown
LABEL org.hybrid-ai.build-inputs-sha="\$BUILD_INPUTS_SHA"
ARG HERMES_COMMIT=3d0a61ac94e1181985177fdd975c4efeb478e9b7
ARG HERMES_INSTALL_SHA256=25d3c95550e5ed7c0eec180a7d78dde765721c4e33639ab257c154c0a6e7554f
ARG HERMES_WEBUI_COMMIT=1e2e4dde6520e5d96bb5b20dfb2f65aa890eeb5e
EOF
printf 'patch body\n' > "$FIX/hermes/patches/0001-kanban-prompt-body-chars.patch"
: > "$FIX/empty.env"

# Fake docker: prints whatever DOCKER_LABEL says and honours DOCKER_INSPECT_RC.
cat > "$WORK/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${DOCKER_ARGV_LOG:-/dev/null}"
case "${1:-} ${2:-}" in
  "image inspect")
    [[ "${DOCKER_INSPECT_RC:-0}" == "0" ]] || exit "${DOCKER_INSPECT_RC}"
    printf '%s\n' "${DOCKER_LABEL-}"
    exit 0
    ;;
esac
exit 0
EOF
chmod +x "$WORK/bin/docker"
export PATH="$WORK/bin:$PATH"
export DOCKER_ARGV_LOG="$WORK/docker-argv.log"

# decide <envfile> -> "build|cache:reason"
decide() {
  bash -c '
    set -uo pipefail
    source "$1" || exit 9
    build_gate_decide "$2" "${3:-}" hybrid-ai-hermes:latest
    printf "%s:%s\n" "$BUILD_GATE_DECISION" "$BUILD_GATE_REASON"
  ' _ "$LIB" "$FIX" "${1:-}" 2>/dev/null
}
# The sha the gate computes right now.
current_sha() {
  bash -c 'set -uo pipefail; source "$1" || exit 9; build_gate_inputs_sha "$2" "${3:-}"' \
    _ "$LIB" "$FIX" "${1:-}" 2>/dev/null
}

echo "== a) inputs unchanged, image label matches -> no --build =="
SHA_A="$(current_sha "$FIX/empty.env")"
if [[ ! "$SHA_A" =~ ^[0-9a-f]{64}$ ]]; then
  bad "a) the gate did not produce a 64-hex sha (got '${SHA_A}')"
else
  DOCKER_INSPECT_RC=0 DOCKER_LABEL="$SHA_A" check "a) cache hit" \
    "cache:inputs-unchanged" "$(DOCKER_INSPECT_RC=0 DOCKER_LABEL="$SHA_A" decide "$FIX/empty.env")"
fi

echo "== b) one ARG changed -> build =="
cp "$FIX/hermes/Dockerfile" "$WORK/Dockerfile.orig"
printf 'HERMES_WEBUI_COMMIT=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n' > "$WORK/arg.env"
check "b) env override of one ARG builds" "rebuild:inputs-changed" \
  "$(DOCKER_INSPECT_RC=0 DOCKER_LABEL="$SHA_A" decide "$WORK/arg.env")"
# The same change expressed in the Dockerfile must also build.
sed -i 's/^ARG HERMES_COMMIT=.*/ARG HERMES_COMMIT=0000000000000000000000000000000000000000/' \
  "$FIX/hermes/Dockerfile"
check "b) Dockerfile ARG change builds" "rebuild:inputs-changed" \
  "$(DOCKER_INSPECT_RC=0 DOCKER_LABEL="$SHA_A" decide "$FIX/empty.env")"
cp "$WORK/Dockerfile.orig" "$FIX/hermes/Dockerfile"
check "b) restoring the Dockerfile restores the sha" "$SHA_A" "$(current_sha "$FIX/empty.env")"

echo "== c) image absent (inspect fails) -> build =="
check "c) missing image builds" "rebuild:image-absent" \
  "$(DOCKER_INSPECT_RC=1 DOCKER_LABEL="$SHA_A" decide "$FIX/empty.env")"

echo "== d) label unreadable/empty/unparsable -> build =="
check "d) empty label builds" "rebuild:label-missing" \
  "$(DOCKER_INSPECT_RC=0 DOCKER_LABEL="" decide "$FIX/empty.env")"
check "d) missing label builds" "rebuild:label-missing" \
  "$(DOCKER_INSPECT_RC=0 DOCKER_LABEL="<no value>" decide "$FIX/empty.env")"
check "d) unparsable label builds" "rebuild:label-unparsable" \
  "$(DOCKER_INSPECT_RC=0 DOCKER_LABEL="not-a-sha" decide "$FIX/empty.env")"

echo "== e) label present but different -> build =="
check "e) different label builds" "rebuild:inputs-changed" \
  "$(DOCKER_INSPECT_RC=0 DOCKER_LABEL="$(printf 'b%.0s' {1..64})" decide "$FIX/empty.env")"

echo "== f) label present and equal -> no build =="
check "f) equal label is a cache hit" "cache:inputs-unchanged" \
  "$(DOCKER_INSPECT_RC=0 DOCKER_LABEL="$SHA_A" decide "$FIX/empty.env")"

echo "== g) progress cadence: one line per interval during pull and build =="
PROG_LOG="$WORK/progress.log"
: > "$PROG_LOG"
HYBRID_PROGRESS_INTERVAL=1 bash -c '
  set -uo pipefail
  source "$1"
  INTERVAL="${HYBRID_PROGRESS_INTERVAL:-60}"
  log() { printf "[ * ] %s %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
  for phase in pull build; do
    hybrid_progress_start "$phase"
    # Two intervals plus a margin: the heartbeat must fire at least twice.
    sleep $(( INTERVAL * 2 + 1 ))
    hybrid_progress_stop
  done
' _ "$LIB" > "$PROG_LOG" 2>&1
pull_lines="$(grep -c 'phase=pull' "$PROG_LOG" || true)"
build_lines="$(grep -c 'phase=build' "$PROG_LOG" || true)"
check "g) at least one pull line per interval" "yes" \
  "$([[ "${pull_lines:-0}" -ge 2 ]] && echo yes || echo "no(${pull_lines:-0})")"
check "g) at least one build line per interval" "yes" \
  "$([[ "${build_lines:-0}" -ge 2 ]] && echo yes || echo "no(${build_lines:-0})")"
# The loop must be gone once stopped: no line appears after the stop call.
before="$(grep -c 'phase=build' "$PROG_LOG" || true)"
sleep 2
check "g) the heartbeat stops after hybrid_progress_stop" "$before" \
  "$(grep -c 'phase=build' "$PROG_LOG" || true)"

echo "== h) timestamp format on every log line =="
TS_RE='^\[ \* \] [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z '
stamped="$(grep -c '^\[ \* \]' "$PROG_LOG" || true)"
unstamped="$(grep '^\[ \* \]' "$PROG_LOG" | grep -cvE "$TS_RE" || true)"
check "h) the harness emitted log lines" "yes" \
  "$([[ "${stamped:-0}" -ge 1 ]] && echo yes || echo no)"
check "h) every log line carries a UTC stamp" "0" "${unstamped:-0}"

# install.sh must use the same stamp shape, or case h proves nothing about it.
INSTALL_TS="$(grep -c 'date -u +%Y-%m-%dT%H:%M:%SZ' "$REPO/install.sh" || true)"
check "h) install.sh stamps log() with a UTC date" "yes" \
  "$([[ "${INSTALL_TS:-0}" -ge 1 ]] && echo yes || echo no)"

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
exit 0
