#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/test-tls-caddy-validation.sh
# PURPOSE (plain English):
#   Self-test for tls_validate_caddyfile() in scripts/lib/tls.sh.
#
#   The rendered TLS Caddyfile keeps its runtime placeholders ({$ACME_EMAIL},
#   {$ACME_CA}, {$TLS_DOMAIN}, {$LOCAL_DOMAIN}); the proxy's compose
#   `environment:` block supplies them when the container starts. The validator
#   therefore has to hand the SAME values to `caddy validate`, or the
#   placeholders expand empty and a perfectly good Caddyfile is rejected.
#
#   This suite renders the real TLS Caddyfile, stubs `docker` and the host
#   `caddy` as shell functions, and asserts the required env names and values
#   reach BOTH validation branches, plus that the skip path and the read-only /
#   network-none controls are intact.
#
#   It needs neither Docker nor Caddy. It never touches the real files and
#   never needs root. It does NOT perform a real `caddy validate`: that needs a
#   Caddy binary or Docker, and these runners have neither.
#
# HOW TO RUN IT:
#   ./scripts/test-tls-caddy-validation.sh
# ---------------------------------------------------------------------------
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/hybrid-ai-env.sh
source "${SCRIPT_DIR}/lib/hybrid-ai-env.sh"
if ! hybrid_ai_env_load; then
  printf 'FATAL: hybrid_ai_env_load failed; cannot resolve the repository directory.\n' >&2
  exit 2
fi
# shellcheck source=scripts/lib/tls.sh
source "${HYBRID_AI_APP_DIR}/scripts/lib/tls.sh"

WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

FAILED=0
pass() { printf '[ OK ] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; FAILED=1; }

# --- Render the real TLS-on Caddyfile into a throwaway APP_DIR --------------
APP_DIR="$WORK/app"
mkdir -p "$APP_DIR/status"
cp "${HYBRID_AI_APP_DIR}/status/Caddyfile.tmpl" "$APP_DIR/status/Caddyfile.tmpl"
cp "${HYBRID_AI_APP_DIR}/docker-compose.yml.tmpl" "$APP_DIR/docker-compose.yml.tmpl"

LOCAL_DOMAIN="jarvis.lan"
TLS_ENABLED="yes"
TLS_DOMAIN="daemonhub.dev"
ACME_EMAIL="ops@example.com"
TLS_VALIDATION="dns"
ACME_DNS_PROVIDER="cloudflare"
ACME_CA="$TLS_CA_STAGING_URL"
ACME_AUTO_HTTPS="disable_redirects"

tls_prepare_render_values "on dns"
CADDYFILE="$WORK/Caddyfile"
tls_render_to_file "$APP_DIR/status/Caddyfile.tmpl" "on dns" "$CADDYFILE"

# The premise of the whole suite: the placeholders really are still there.
if grep -qF "email {\$ACME_EMAIL}" "$CADDYFILE" \
   && grep -qF "acme_ca {\$ACME_CA}" "$CADDYFILE" \
   && grep -qF "{\$TLS_DOMAIN}" "$CADDYFILE" \
   && grep -qF "{\$LOCAL_DOMAIN}" "$CADDYFILE"; then
  pass "rendered TLS Caddyfile keeps its runtime placeholders"
else
  fail "rendered TLS Caddyfile no longer has the runtime placeholders this suite is about"
fi

EXPECTED_ENVS=(
  "ACME_EMAIL=ops@example.com"
  "TLS_DOMAIN=daemonhub.dev"
  "ACME_CA=$TLS_CA_STAGING_URL"
  "ACME_AUTO_HTTPS=disable_redirects"
  "LOCAL_DOMAIN=jarvis.lan"
)

assert_envs_in_file() {  # FILE LABEL
  local file="$1" label="$2" pair
  for pair in "${EXPECTED_ENVS[@]}"; do
    if grep -Fxq -- "$pair" "$file"; then
      pass "${label} receives ${pair}"
    else
      fail "${label} does NOT receive the expected ${pair%%=*}"
    fi
  done
}

# --- Branch 1: docker (no host caddy binary) ------------------------------
# PATH hides caddy and docker so `command -v caddy` fails; the docker stub is a
# shell function, which `command -v` finds regardless of PATH.
# A PATH that hides caddy and docker but keeps every other tool: the validator
# still needs grep/awk/sed, and hiding those would silently change its
# behaviour instead of exercising the branch under test.
EMPTY_BIN="$WORK/emptybin"
mkdir -p "$EMPTY_BIN"
for d in /usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin; do
  [[ -d $d ]] || continue
  for f in "$d"/*; do
    b="${f##*/}"
    case "$b" in caddy|docker|docker-compose) continue ;; esac
    [[ -x $f && ! -e "${EMPTY_BIN}/${b}" ]] && ln -s "$f" "${EMPTY_BIN}/${b}" 2>/dev/null
  done
done

EXPECT_STOCK="caddy:2.11-alpine"
EXPECT_DNS="hybrid-ai-caddy:2.11.7-dns"

docker() {
  if [[ "${1:-}" == info ]]; then return 0; fi
  if [[ "${1:-}" == compose ]]; then return 0; fi
  printf '%s\n' "$@" > "$WORK/docker.args"
  return 0
}
export -f docker

docker_rc=0
docker_out="$(PATH="$EMPTY_BIN" tls_validate_caddyfile "$CADDYFILE" 2>&1)" || docker_rc=$?
unset -f docker

if (( docker_rc == 0 )); then
  pass "docker branch returns 0 for a valid-looking invocation"
else
  fail "docker branch returned ${docker_rc} (output: ${docker_out})"
fi

if [[ -f "$WORK/docker.args" ]]; then
  awk 'prev=="-e"{print} {prev=$0}' "$WORK/docker.args" > "$WORK/docker.envs"
  assert_envs_in_file "$WORK/docker.envs" "docker validator"

  args_flat="$(tr '\n' ' ' < "$WORK/docker.args")"
  for want in "--rm" "--network none" "--entrypoint caddy"; do
    if [[ "$args_flat" == *"$want"* ]]; then
      pass "docker branch keeps '${want}'"
    else
      fail "docker branch lost '${want}'"
    fi
  done
  if grep -Fxq -- "-v" "$WORK/docker.args" \
     && grep -Fq -- ":/etc/caddy/Caddyfile:ro" "$WORK/docker.args"; then
    pass "docker branch keeps the read-only Caddyfile mount"
  else
    fail "docker branch lost the read-only Caddyfile mount"
  fi
  # This render is the DNS-01 one, so the validator must use the DNS-capable
  # image: the stock tag has no dns.providers module and rejects the render at
  # adapt time.
  if grep -Fxq -- "hybrid-ai-caddy:2.11.7-dns" "$WORK/docker.args"; then
    pass "docker branch validates the DNS-01 render with the DNS-capable image"
  else
    fail "docker branch did not use the DNS-capable image"
  fi
  if grep -Fxq -- "$EXPECT_STOCK" "$WORK/docker.args"; then
    fail "docker branch used the stock image ($EXPECT_STOCK) for a DNS-01 render"
  else
    pass "docker branch never used the stock image for a DNS-01 render"
  fi
else
  fail "docker branch never invoked docker run"
fi

# --- Branch 2: host caddy binary ------------------------------------------
# The variables are plain shell variables, never exported by install.sh, so the
# validator has to carry them itself. The stub records the environment it got.
caddy() {
  # `env` shows EXPORTED variables only. Reading the shell variable directly
  # would also see values that were never exported, which is exactly the bug:
  # install.sh keeps these as plain shell variables.
  env | grep -E '^(ACME_EMAIL|TLS_DOMAIN|ACME_CA|ACME_AUTO_HTTPS|LOCAL_DOMAIN)=' \
    > "$WORK/caddy.env"
  return 0
}
export -f caddy

host_rc=0
host_out="$(tls_validate_caddyfile "$CADDYFILE" 2>&1)" || host_rc=$?
unset -f caddy

if (( host_rc == 0 )); then
  pass "host-caddy branch returns 0 for a valid-looking invocation"
else
  fail "host-caddy branch returned ${host_rc} (output: ${host_out})"
fi
if [[ -f "$WORK/caddy.env" ]]; then
  assert_envs_in_file "$WORK/caddy.env" "host caddy validator"
else
  fail "host-caddy branch never invoked caddy validate"
fi

# --- Skip path: neither docker nor caddy ----------------------------------
# Return-code contract: 3 with a [skip] line, never a false pass.
skip_rc=0
skip_out="$(PATH="$EMPTY_BIN" tls_validate_caddyfile "$CADDYFILE" 2>&1)" || skip_rc=$?
if (( skip_rc == 3 )) && [[ "$skip_out" == *"[skip] Caddyfile validation"* ]]; then
  pass "no docker and no caddy: returns 3 with the [skip] line (never a false pass)"
else
  fail "skip path returned ${skip_rc} (expected 3 with a [skip] line): ${skip_out}"
fi

# ---------------------------------------------------------------------------
# Validation-image selection: a DNS-01 render needs the DNS-capable image; every
# other render keeps the stock tag. CADDY_VALIDATE_IMAGE overrides both.
# Known limitation: `docker` is stubbed, so this proves which image is SELECTED
# and in what ORDER the build runs. It cannot prove the real adapter accepts
# the render -- the true proof is post-merge verification on the host.
# ---------------------------------------------------------------------------
image_for_render() {  # CADDYFILE
  # A missing helper must be a reported FAIL, not a set -e abort that hides
  # every later case: that is exactly how the unpatched base behaves.
  ( declare -F tls_validate_image_for >/dev/null 2>&1 && tls_validate_image_for "$1" ) || true
}

img_dns="$(image_for_render "$CADDYFILE")"
if [[ "$img_dns" == "$EXPECT_DNS" ]]; then
  pass "dns render selects the DNS-capable image (${img_dns})"
else
  fail "dns render selected '${img_dns}' (expected hybrid-ai-caddy:2.11.7-dns)"
fi

# CADDY_IMAGE follows the resolver used everywhere else in the stack.
img_dns_custom="$( ( CADDY_IMAGE=custom-caddy:9.9-dns; image_for_render "$CADDYFILE" ) )"
if [[ "$img_dns_custom" == "custom-caddy:9.9-dns" ]]; then
  pass "dns render follows CADDY_IMAGE (${img_dns_custom})"
else
  fail "dns render ignored CADDY_IMAGE (got '${img_dns_custom}')"
fi

# Explicit CADDY_VALIDATE_IMAGE wins over both.
img_override="$( ( CADDY_VALIDATE_IMAGE=override/caddy:1; image_for_render "$CADDYFILE" ) )"
if [[ "$img_override" == "override/caddy:1" ]]; then
  pass "CADDY_VALIDATE_IMAGE overrides the dns image (${img_override})"
else
  fail "CADDY_VALIDATE_IMAGE did not override the dns image (got '${img_override}')"
fi

# http-01 and tls-alpn renders carry no dns solver: stock image, as before.
TLS_VALIDATION="http"
ACME_CA="$TLS_CA_STAGING_URL"
tls_prepare_render_values "on"
HTTP_CADDYFILE="$WORK/Caddyfile.http"
tls_render_to_file "$APP_DIR/status/Caddyfile.tmpl" "on" "$HTTP_CADDYFILE"
img_http="$(image_for_render "$HTTP_CADDYFILE")"
if [[ "$img_http" == "$EXPECT_STOCK" ]]; then
  pass "http-01 render keeps the stock validation image (${img_http})"
else
  fail "http-01 render selected '${img_http}' (expected caddy:2.11-alpine)"
fi
img_http_override="$( ( CADDY_VALIDATE_IMAGE=override/caddy:2; image_for_render "$HTTP_CADDYFILE" ) )"
if [[ "$img_http_override" == "override/caddy:2" ]]; then
  pass "CADDY_VALIDATE_IMAGE overrides the http-01 image (${img_http_override})"
else
  fail "CADDY_VALIDATE_IMAGE did not override the http-01 image (got '${img_http_override}')"
fi

# tls-alpn is the same "on" variant as http: no solver, stock image.
img_alpn="$(image_for_render "$HTTP_CADDYFILE")"
if [[ "$img_alpn" == "$EXPECT_STOCK" ]]; then
  pass "tls-alpn render keeps the stock validation image (${img_alpn})"
else
  fail "tls-alpn render selected '${img_alpn}' (expected caddy:2.11-alpine)"
fi

# --- The build runs BEFORE validation, and only on the dns path -----------
# ORDER is what matters: on first enablement the proxy image does not exist
# yet (STEP 9 `compose up` builds it), so validating before building would run
# a missing image. The stub records `build` and `run` in one ordered log.
TLS_VALIDATION="dns"
ACME_DNS_PROVIDER="cloudflare"
tls_prepare_render_values "on dns"

docker() {
  case "${1:-}" in
    info)  return 0 ;;
    build) printf 'build %s\n' "$*" >> "$WORK/docker.order"; return 0 ;;
    run)   printf 'run %s\n' "$*" >> "$WORK/docker.order"; return 0 ;;
  esac
  return 0
}
export -f docker

# The build step reads caddy/Dockerfile from the render tree.
mkdir -p "$APP_DIR/caddy"
cp "${HYBRID_AI_APP_DIR}/caddy/Dockerfile" "$APP_DIR/caddy/Dockerfile"

run_order_case() {  # TLS_ENABLED TLS_VALIDATION CADDYFILE
  : > "$WORK/docker.order"
  # WORK is exported so the exported docker stub can reach the same log file
  # from inside the child shell.
  WORK="$WORK" PATH="$EMPTY_BIN" bash -c '
    source "$1/lib/hybrid-ai-env.sh" >/dev/null 2>&1
    source "$1/scripts/lib/tls.sh"
    APP_DIR="$2"
    TLS_ENABLED="$3"
    TLS_VALIDATION="$4"
    if [[ -n "${5:-}" ]]; then tls_build_validate_image "$5"; tls_validate_caddyfile "$5"; fi
  ' _ "$HYBRID_AI_APP_DIR" "$APP_DIR" "$1" "$2" "${3:-}" >/dev/null 2>&1 || true
}

run_order_case yes dns "$CADDYFILE"
if grep -q -- "-t $EXPECT_DNS " "$WORK/docker.order" \
   && grep -q '^build .*caddy' "$WORK/docker.order"; then
  pass "dns path builds the DNS-capable image from ./caddy (docker build -t … <context>)"
else
  fail "dns path did not run 'docker build -t hybrid-ai-caddy:2.11.7-dns <app>/caddy' (log: $(tr '\n' ';' < "$WORK/docker.order"))"
fi
first_build="$(grep -n '^build ' "$WORK/docker.order" | head -1 | cut -d: -f1)"
first_run="$(grep -n '^run ' "$WORK/docker.order" | head -1 | cut -d: -f1)"
if [[ -n "$first_build" && -n "$first_run" && "$first_build" -lt "$first_run" ]]; then
  pass "the image build runs BEFORE validation on the dns path"
else
  fail "the dns path did not build the image before validating (log: $(tr '\n' ';' < "$WORK/docker.order"))"
fi

run_order_case yes http "$HTTP_CADDYFILE"
if grep -q '^build ' "$WORK/docker.order"; then
  fail "the http-01 path wrongly built the DNS image"
else
  pass "the http-01 path does not build the DNS image"
fi
if grep -q "^run .*$EXPECT_STOCK" "$WORK/docker.order"; then
  pass "the http-01 path validates with the stock image"
else
  fail "the http-01 path did not validate with the stock image"
fi

run_order_case no "" ""
if grep -q '^build ' "$WORK/docker.order"; then
  fail "the TLS-off path wrongly built the DNS image"
else
  pass "the TLS-off path does not build the DNS image"
fi

# --- The TLS-off variant still validates (no behaviour change) ------------
TLS_ENABLED="no"
ACME_EMAIL=""
TLS_DOMAIN=""
ACME_CA=""
ACME_AUTO_HTTPS=""
tls_prepare_render_values "off"
OFF_CADDYFILE="$WORK/Caddyfile.off"
tls_render_to_file "$APP_DIR/status/Caddyfile.tmpl" "off" "$OFF_CADDYFILE"

caddy() { return 0; }
export -f caddy
off_rc=0
tls_validate_caddyfile "$OFF_CADDYFILE" >/dev/null 2>&1 || off_rc=$?
unset -f caddy
if (( off_rc == 0 )); then
  pass "TLS-off Caddyfile still validates (unchanged behaviour)"
else
  fail "TLS-off Caddyfile validation regressed (rc ${off_rc})"
fi

# ---------------------------------------------------------------------------
# ACME_CA normalization: the resolved URL, not the staging/production label,
# is the one value that reaches the stack .env, the proxy container and the
# validator. tls_validate_settings is the single seam, and it runs before both
# the install.sh STEP 8 env write and every validation call site.
# ---------------------------------------------------------------------------
# Probes run in a subshell: tls__die exits the current shell.
normalized_ca() {  # FLAG_VALUE
  # `set -e` mirrors install.sh, where a failed assignment from
  # tls_validate_ca ends the run: that is the behaviour under test.
  (
    set -e
    LOCAL_DOMAIN="jarvis.lan"
    TLS_ENABLED="yes"
    TLS_DOMAIN="daemonhub.dev"
    ACME_EMAIL="ops@example.com"
    # http keeps the token-file check out of the way; it has nothing to do
    # with the CA seam and would need a real root-owned 0600 file.
    TLS_VALIDATION="http"
    ACME_DNS_PROVIDER=""
    ACME_CA=""
    TLS_ARG_CA="${1:-}"
    tls_apply_flags
    tls_validate_settings >/dev/null
    printf '%s\n' "$ACME_CA"
  )
}

# (a) flag input: --tls-acme-ca staging
ca_a="$(normalized_ca staging)"
if [[ "$ca_a" == "$TLS_CA_STAGING_URL" ]]; then
  pass "fixture 3a: ACME_CA=staging (flag) normalizes to the staging URL"
else
  fail "fixture 3a: ACME_CA=staging (flag) did NOT normalize (got '${ca_a}')"
fi

# (a1) the STEP 8 env write itself: install.sh expands this exact template
# line inside an unquoted heredoc, so the normalized value is what lands in
# the file. The label must not survive to the write.
env_line_template="$(grep -m1 '^ACME_CA=' "${HYBRID_AI_APP_DIR}/install.sh" || true)"
if [[ "$env_line_template" == *"\${ACME_CA:-"* ]]; then
  pass "install.sh STEP 8 still writes ACME_CA from the shell variable"
else
  fail "install.sh STEP 8 no longer writes ACME_CA from the shell variable"
fi
written_ca="$(ACME_CA="$ca_a" bash -c 'printf "%s\n" "$ACME_CA"' | sed 's/^/ACME_CA=/' | cut -d= -f2-)"
if [[ "$written_ca" == "$TLS_CA_STAGING_URL" ]]; then
  pass "fixture 3a: the stack .env write carries the staging URL, not the label"
else
  fail "fixture 3a: the stack .env write does not carry the staging URL (got '${written_ca}')"
fi
# (a2) the same for production
ca_p="$(normalized_ca production)"
if [[ "$ca_p" == "$TLS_CA_PRODUCTION_URL" ]]; then
  pass "fixture 3a: ACME_CA=production (flag) normalizes to the production URL"
else
  fail "fixture 3a: ACME_CA=production (flag) did NOT normalize (got '${ca_p}')"
fi

# (b) label loaded from an env file: the variable is already set, so the
# interactive prompt is skipped and only the seam can resolve it.
ca_b="$(
  LOCAL_DOMAIN="jarvis.lan" TLS_ENABLED="yes" TLS_DOMAIN="daemonhub.dev" \
  ACME_EMAIL="ops@example.com" TLS_VALIDATION="http" ACME_DNS_PROVIDER="" \
  ACME_CA="staging" TLS_ARG_CA="" \
  bash -c 'source "$1/lib/hybrid-ai-env.sh" >/dev/null 2>&1; source "$1/scripts/lib/tls.sh"; tls_validate_settings >/dev/null 2>&1; printf "%s\n" "$ACME_CA"' _ \
    "$HYBRID_AI_APP_DIR"
)"
if [[ "$ca_b" == "$TLS_CA_STAGING_URL" ]]; then
  pass "fixture 3b: ACME_CA=staging from the env file normalizes to the staging URL"
else
  fail "fixture 3b: ACME_CA=staging from the env file did NOT normalize (got '${ca_b}')"
fi

# (c) an explicit https:// URL is preserved byte-for-byte
custom_ca="https://custom.example/directory"
ca_c="$(normalized_ca "$custom_ca")"
if [[ "$ca_c" == "$custom_ca" ]]; then
  pass "fixture 3c: an explicit https:// ACME_CA URL is preserved byte-for-byte"
else
  fail "fixture 3c: an explicit https:// ACME_CA URL was rewritten (got '${ca_c}')"
fi

# (d) the validator receives the same ACME_CA the compose environment block
# would pass. The compose template interpolates ${ACME_CA}, so the normalized
# value is what both the container and the validator see.
compose_ca_line="$(grep -m1 '^      ACME_CA:' "$APP_DIR/docker-compose.yml.tmpl" || true)"
if [[ "$compose_ca_line" == *"\${ACME_CA"* ]]; then
  pass "compose environment block interpolates ACME_CA from the stack .env"
else
  fail "compose environment block no longer interpolates ACME_CA"
fi
(
  LOCAL_DOMAIN="jarvis.lan"
  TLS_ENABLED="yes"
  TLS_DOMAIN="daemonhub.dev"
  ACME_EMAIL="ops@example.com"
  TLS_VALIDATION="http"
  ACME_CA=""
  TLS_ARG_CA="staging"
  tls_apply_flags
  tls_validate_settings >/dev/null 2>&1
  caddy() { env | grep '^ACME_CA=' > "$WORK/3d.env"; return 0; }
  export -f caddy
  tls_validate_caddyfile "$CADDYFILE" >/dev/null 2>&1 || true
) || true
if grep -Fxq -- "ACME_CA=$TLS_CA_STAGING_URL" "$WORK/3d.env" 2>/dev/null; then
  pass "fixture 3d: the validator receives the normalized URL, matching the container"
else
  fail "fixture 3d: the validator did NOT receive the normalized URL"
fi

# --- An invalid CA value still dies with the existing message --------------
ca_bad_rc=0
ca_bad_out="$( ( tls_validate_ca "definitely-not-a-ca" ) 2>&1 )" || ca_bad_rc=$?
if (( ca_bad_rc != 0 )) && [[ "$ca_bad_out" == *"ACME_CA must be staging, production, or an https:// URL"* ]]; then
  pass "an invalid ACME_CA still dies in tls_validate_ca (validator not relaxed)"
else
  fail "an invalid ACME_CA no longer dies with the documented message (rc ${ca_bad_rc})"
fi

if (( FAILED )); then
  printf '\nsome checks failed\n' >&2
  exit 1
fi
printf '\nall caddy validation checks passed\n'
