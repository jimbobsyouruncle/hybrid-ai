#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/test-tls-dry-run-renewal.sh
# PURPOSE (plain English):
#   Proves scripts/tls-dry-run-renewal.sh refuses to touch production and
#   refuses to guess when the ACME directory is unset, and that --check-only
#   changes nothing.
#
#   Offline only: a fake `docker` earlier on PATH, fixture env files, and a
#   mktemp tree. No real docker, no network, no root.
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN="${SCRIPT_DIR}/tls-dry-run-renewal.sh"

pass=0
fail=0
skip=0
ok()   { printf 'ok   %s\n' "$1"; pass=$(( pass + 1 )); }
bad()  { printf 'FAIL %s\n' "$1"; fail=$(( fail + 1 )); }

if [[ ! -f "$DRY_RUN" ]]; then
  printf 'FAIL missing %s\n' "$DRY_RUN"
  exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hybrid-ai-tls-dryrun-test.XXXXXX")" || exit 1
# Resolve the STACK file the shared resolver names, in a SUBSHELL: sourcing the
# helper here would export repo-default paths and shadow the fixture env files
# passed with --env-file below.
STACK_ENV_FILE="$(bash -c '
  # shellcheck source=scripts/lib/hybrid-ai-env.sh
  source "$1/lib/hybrid-ai-env.sh" >/dev/null 2>&1 || exit 1
  printf "%s" "$HYBRID_AI_STACK_ENV_FILE"
' _ "$SCRIPT_DIR" 2>/dev/null || true)"
[[ -n "$STACK_ENV_FILE" ]] || STACK_ENV_FILE=""
# Idempotent: called on the normal exit path AND from the trap.
cleanup() {
  [[ -n "${WORK:-}" ]] || return 0
  rm -rf "$WORK"
  WORK=""
}
trap cleanup EXIT

# --- fake docker: records calls, never touches a real daemon --------------
FAKE_BIN="$WORK/bin"
mkdir -p "$FAKE_BIN"
DOCKER_CALLS="$WORK/docker.calls"
: > "$DOCKER_CALLS"
cat > "$FAKE_BIN/docker" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_DOCKER_CALLS"
exit 0
FAKE
chmod 0755 "$FAKE_BIN/docker"
export FAKE_DOCKER_CALLS="$DOCKER_CALLS"
export PATH="$FAKE_BIN:$PATH"

assert_exit() {
  local label="$1" want="$2" got="$3"
  if [[ "$got" == "$want" ]]; then
    ok "$label -> exit $got"
  else
    bad "$label -> want exit $want, got $got"
  fi
}

COMPOSE="$WORK/docker-compose.yml"
: > "$COMPOSE"

# --- fixture 1: ACME_CA points at production -----------------------------
PROD_ENV="$WORK/prod.env"
printf 'ACME_CA=https://acme-v02.api.letsencrypt.org/directory\nLOCAL_DOMAIN=tls-test.example\n' > "$PROD_ENV"

out="$(bash "$DRY_RUN" --env-file "$PROD_ENV" --compose-file "$COMPOSE" --cert-root "$WORK/certs" 2>&1)"; rc=$?
assert_exit "production ACME_CA, full run" 2 "$rc"
if printf '%s\n' "$out" | grep -qi 'production'; then
  ok "production refusal names the problem"
else
  bad "production refusal did not name the problem"
fi

out="$(bash "$DRY_RUN" --check-only --env-file "$PROD_ENV" --compose-file "$COMPOSE" --cert-root "$WORK/certs" 2>&1)"; rc=$?
assert_exit "production ACME_CA, --check-only" 2 "$rc"

if [[ -s "$DOCKER_CALLS" ]]; then
  bad "the production refusal still invoked docker"
else
  ok "no docker call was made for the production refusal"
fi

# --- fixture 2: ACME_CA unset -------------------------------------------
UNSET_ENV="$WORK/unset.env"
printf 'LOCAL_DOMAIN=tls-test.example\n' > "$UNSET_ENV"

out="$(bash "$DRY_RUN" --env-file "$UNSET_ENV" --compose-file "$COMPOSE" --cert-root "$WORK/certs" 2>&1)"; rc=$?
assert_exit "unset ACME_CA, full run" 2 "$rc"

out="$(bash "$DRY_RUN" --check-only --env-file "$UNSET_ENV" --compose-file "$COMPOSE" --cert-root "$WORK/certs" 2>&1)"; rc=$?
assert_exit "unset ACME_CA, --check-only" 2 "$rc"

# --- fixture 3: staging CA, missing cert root ---------------------------
STAGING_ENV="$WORK/staging.env"
printf 'ACME_CA=https://acme-staging-v02.api.letsencrypt.org/directory\nLOCAL_DOMAIN=tls-test.example\n' > "$STAGING_ENV"
MISSING_ROOT="$WORK/no-such-cert-root"

out="$(bash "$DRY_RUN" --check-only --env-file "$STAGING_ENV" --compose-file "$COMPOSE" --cert-root "$MISSING_ROOT" 2>&1)"; rc=$?
assert_exit "staging ACME_CA, missing cert root, --check-only" 1 "$rc"
if printf '%s\n' "$out" | grep -qi 'certificate root'; then
  ok "the staging check-only run reports the missing certificate root"
else
  bad "the staging check-only run did not report the missing certificate root"
fi
if [[ -e "$MISSING_ROOT" ]]; then
  bad "--check-only created the missing certificate root"
else
  ok "--check-only changed nothing (cert root still absent)"
fi
if [[ -s "$DOCKER_CALLS" ]]; then
  bad "--check-only invoked docker"
else
  ok "--check-only made no docker call"
fi

# --- fixture 4: staging CA with a readable cert root, --check-only ------
mkdir -p "$WORK/certs"
HELD_BEFORE="$(find "$WORK/certs" | sort | md5sum)"
out="$(bash "$DRY_RUN" --check-only --env-file "$STAGING_ENV" --compose-file "$COMPOSE" --cert-root "$WORK/certs" 2>&1)"; rc=$?
assert_exit "staging ACME_CA, readable root, --check-only" 0 "$rc"
HELD_AFTER="$(find "$WORK/certs" | sort | md5sum)"
if [[ "$HELD_BEFORE" == "$HELD_AFTER" ]]; then
  ok "--check-only left the certificate root unchanged"
else
  bad "--check-only modified the certificate root"
fi

# --- fixture 5: staging full run without --yes -------------------------
out="$(bash "$DRY_RUN" --env-file "$STAGING_ENV" --compose-file "$COMPOSE" --cert-root "$WORK/certs" 2>&1)"; rc=$?
assert_exit "staging full run without --yes" 2 "$rc"

printf '\n%d/%d checks pass\n' "$pass" "$(( pass + fail ))"
cleanup
if (( fail > 0 )); then
  printf '%d failed, %d skipped\n' "$fail" "$skip"
  exit 1
fi
[[ "$skip" -gt 0 ]] && printf '%d skipped\n' "$skip"
exit 0
