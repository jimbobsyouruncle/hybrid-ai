#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/test-auth-render.sh
# PURPOSE (plain English):
#   Self-test for the env-gated login gate (Caddy basic_auth) over the
#   *.daemonhub.dev HTTPS sites. It renders the managed Caddyfile template in a
#   throwaway tree and checks:
#     1. auth OFF: the render is byte-identical to the tracked status/Caddyfile
#        and contains zero `basic_auth` and zero `import auth` lines,
#     2. auth ON: `import auth` appears once per gated site/handle, the (auth)
#        snippet is defined exactly once with the two env placeholders, and the
#        gate is absent from `handle /health` and from every http:// site,
#     3. TLS ON, auth OFF (the documented default combination): every
#        `import auth` is gated by the auth variant too, so the render has zero
#        imports and zero (auth) definitions and is not byte-identical to the
#        auth-on render. Without this case a TLS-on render keeps the imports but
#        drops the snippet, and real Caddy rejects it with
#        `File to import not found: auth`,
#     4. TLS OFF, auth ON: the (auth) snippet is suppressed entirely, because
#        the HTTPS sites that import it do not exist with TLS off. The render
#        must be byte-identical to the auth-off render (zero basic_auth, zero
#        (auth), zero `import auth`) AND the installer must print the
#        auth-without-TLS warning. Real Caddy rejects the opposite render with
#        `parsed 'forward_auth' as a site address, but it is a known directive`,
#     5. fail-closed: with AUTH_ENABLED=on and an empty user, hash or cookie
#        secret, the installer's tls_auth_fail_closed check rejects the install
#        before any render, naming every missing variable.
#   It never touches the real files and needs no root, Docker or Caddy.
#
# HOW TO RUN IT:
#   ./scripts/test-auth-render.sh
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

APP_DIR="$WORK/app"
mkdir -p "$APP_DIR/status"
cp "${HYBRID_AI_APP_DIR}/status/Caddyfile.tmpl" "$APP_DIR/status/Caddyfile.tmpl"

FAILED=0
pass() { printf '[ OK ] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; FAILED=1; }

render() {  # VARIANTS OUTFILE
  local variants="$1" out="$2"
  tls_prepare_render_values "$variants"
  tls_render_to_file "$APP_DIR/status/Caddyfile.tmpl" "$variants" "$out"
}

# --- auth OFF: byte-identical to the tracked file, no gate anywhere ---------
LOCAL_DOMAIN="jarvis.lan"
TLS_ENABLED="no"
AUTH_ENABLED="off"
render off "$WORK/off"

if cmp -s -- "${HYBRID_AI_APP_DIR}/status/Caddyfile" "$WORK/off"; then
  pass "auth-off render is byte-identical to the tracked status/Caddyfile"
else
  fail "auth-off render differs from the tracked status/Caddyfile"
  diff -u "${HYBRID_AI_APP_DIR}/status/Caddyfile" "$WORK/off" >&2 || true
fi

n_auth_off="$(grep -c 'basic_auth' "$WORK/off" || true)"
if [[ "$n_auth_off" == "0" ]]; then
  pass "auth-off render contains zero basic_auth lines"
else
  fail "auth-off render contains ${n_auth_off} basic_auth lines (expected 0)"
fi
n_import_off="$(grep -c 'import auth' "$WORK/off" || true)"
if [[ "$n_import_off" == "0" ]]; then
  pass "auth-off render contains zero 'import auth' lines"
else
  fail "auth-off render contains ${n_import_off} 'import auth' lines (expected 0)"
fi

# tls_variants must reflect the switch: off by default, "auth" appended only
# when AUTH_ENABLED=on.
AUTH_ENABLED="off"
if [[ "$(tls_variants)" == "off" ]]; then
  pass "tls_variants omits the auth variant when AUTH_ENABLED=off"
else
  fail "tls_variants included the auth variant with AUTH_ENABLED=off"
fi

# --- auth ON: the gate is emitted in exactly the right places ---------------
TLS_ENABLED="yes"
TLS_DOMAIN="daemonhub.dev"
ACME_EMAIL="[EMAIL]"
TLS_VALIDATION="dns"
ACME_DNS_PROVIDER="cloudflare"
ACME_CA="$TLS_CA_STAGING_URL"
AUTH_ENABLED="on"
# Dummy placeholders only: no real password, no real bcrypt hash.
HYBRID_AI_AUTH_USER="DUMMY_AUTH_USER_NOT_A_SECRET"
HYBRID_AI_AUTH_HASH="\$2a\$14\$DUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY"

if [[ "$(tls_variants)" == "on dns auth" ]]; then
  pass "tls_variants appends the auth variant when AUTH_ENABLED=on"
else
  fail "tls_variants did not append the auth variant with AUTH_ENABLED=on (got '$(tls_variants)')"
fi

render "on dns auth" "$WORK/on"

# The (auth) snippet: defined once, a three-line forward_auth to the auth
# service. Credentials never enter the Caddyfile any more.
n_basic_auth="$(grep -c 'basic_auth' "$WORK/on" || true)"
if [[ "$n_basic_auth" == "0" ]]; then
  pass "auth-on render contains zero basic_auth tokens (the gate is forward_auth)"
else
  fail "auth-on render has ${n_basic_auth} basic_auth lines (expected 0)"
fi
# The snippet must be the THREE-LINE form: Caddy requires a block's `{` to be
# the last token on its line, so `forward_auth auth:8080 { uri /verify }` does
# not adapt. The body doubles as a proof that no credential placeholder remains.
auth_snippet="$(printf '(auth) {\n\tforward_auth auth:8080 {\n\t\turi /verify\n\t}\n}')"
if awk '/^\(auth\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$WORK/on" \
     | diff -q -- - <(printf '%s\n' "$auth_snippet") >/dev/null; then
  pass "the (auth) snippet is the three-line forward_auth form"
else
  fail "the (auth) snippet is not the expected three-line forward_auth form"
  awk '/^\(auth\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$WORK/on" >&2
fi
if grep -q 'HYBRID_AI_AUTH_USER\|HYBRID_AI_AUTH_HASH' "$WORK/on"; then
  fail "an auth credential placeholder survived into the Caddyfile render"
else
  pass "no auth credential placeholder appears in the Caddyfile render"
fi
# The login endpoint must be reachable WITHOUT the gate; it is a plain handle.
if awk '/^[[:space:]]*handle \/auth\* \{/{f=1} f{print} f&&/^[[:space:]]*\}$/{exit}' "$WORK/on" \
     | grep -qE 'import auth|forward_auth'; then
  fail "the /auth* handle is gated (the login endpoint must be reachable)"
else
  pass "the /auth* handle is NOT gated (login endpoint reachable)"
fi
if awk '/^[[:space:]]*handle \/auth\* \{/{f=1} f{print} f&&/^[[:space:]]*\}$/{exit}' "$WORK/on" \
     | grep -q '^[[:space:]]*import trusted_only'; then
  pass "the /auth* handle imports trusted_only (LAN + tailnet only)"
else
  fail "the /auth* handle does not import trusted_only"
fi

# `import auth` is the gate; it must appear once per gated site or handle.
# Apex HTTPS handles: /status*, /hub*, /ollama/*, /openwebui*, /chat* and the
# catch-all = 6. Site level of hermes., status. and the wildcard = 3. Total 9.
GATED=9
n_import="$(grep -c 'import auth' "$WORK/on" || true)"
if [[ "$n_import" == "$GATED" ]]; then
  pass "auth-on render has ${n_import} 'import auth' lines (one per gated block)"
else
  fail "auth-on render has ${n_import} 'import auth' lines (expected ${GATED})"
fi

# The gate must not sit inside `handle /health` (the open uptime endpoint).
if awk '/^[[:space:]]*handle \/health \{/{f=1} f{print} f&&/^[[:space:]]*\}$/{exit}' "$WORK/on" \
     | grep -q 'import auth'; then
  fail "the gate is present inside handle /health (must stay open)"
else
  pass "handle /health is NOT gated (uptime monitor stays open)"
fi

# No gate on any http:// site or on the http->https redirect block. Every
# `import auth` must appear inside the HTTPS region, i.e. after the first
# `https://` site line. The http:// jarvis.lan sites and the redirect block all
# come before that region.
first_https="$(grep -n '^https://' "$WORK/on" | head -1 | cut -d: -f1)"
first_import="$(grep -n 'import auth' "$WORK/on" | head -1 | cut -d: -f1)"
if [[ -n "$first_https" && -n "$first_import" && "$first_import" -gt "$first_https" ]]; then
  pass "every 'import auth' is inside the HTTPS region (no http:// site is gated)"
else
  fail "an 'import auth' appears before the first https:// site"
fi

if awk '/^http:\/\/\{\$TLS_DOMAIN\}, http:\/\/\*\.\{\$TLS_DOMAIN\} \{/{f=1} f{print} f&&/^\}$/{exit}' "$WORK/on" \
     | grep -q 'import auth'; then
  fail "the gate is present in the http->https redirect block"
else
  pass "the http->https redirect block is NOT gated"
fi

# No plaintext placeholder survived expansion, and the dummy values are the
# only credential-shaped strings (they are obvious placeholders).
if grep -q 'DUMMY_AUTH_USER_NOT_A_SECRET' "$WORK/on" \
   || grep -q 'DUMMYDUMMY' "$WORK/on"; then
  fail "a literal test credential leaked into the rendered file"
else
  pass "no literal credential or hash is written into the rendered file"
fi

# --- TLS ON, auth OFF: no gate and no dangling import -----------------------
# The documented default: TLS_ENABLED=yes with AUTH_ENABLED=off. Every
# `import auth` must be gated by the auth variant as well as defined by it, so
# no import survives without its snippet. Real Caddy rejects the opposite with
# `File to import not found: auth`.
TLS_ENABLED="yes"
TLS_DOMAIN="daemonhub.dev"
ACME_EMAIL="[EMAIL]"
TLS_VALIDATION="dns"
ACME_DNS_PROVIDER="cloudflare"
ACME_CA="$TLS_CA_STAGING_URL"
AUTH_ENABLED="off"
HYBRID_AI_AUTH_USER=""
HYBRID_AI_AUTH_HASH=""

if [[ "$(tls_variants)" == "on dns" ]]; then
  pass "tls_variants is 'on dns' with TLS on and AUTH_ENABLED=off"
else
  fail "tls_variants is not 'on dns' with TLS on and AUTH_ENABLED=off (got '$(tls_variants)')"
fi

render "on dns" "$WORK/tls_authoff"

n_import_tls_off="$(grep -c 'import auth' "$WORK/tls_authoff" || true)"
if [[ "$n_import_tls_off" == "0" ]]; then
  pass "TLS-on/auth-off render contains zero 'import auth' lines"
else
  fail "TLS-on/auth-off render contains ${n_import_tls_off} 'import auth' lines (expected 0)"
fi

n_snippet_tls_off="$(grep -c '^(auth) {' "$WORK/tls_authoff" || true)"
if [[ "$n_snippet_tls_off" == "0" ]]; then
  pass "TLS-on/auth-off render defines zero (auth) snippets"
else
  fail "TLS-on/auth-off render defines ${n_snippet_tls_off} (auth) snippets (expected 0)"
fi

if cmp -s -- "$WORK/on" "$WORK/tls_authoff"; then
  fail "TLS-on/auth-off render is byte-identical to the auth-on render (the gate is not gated)"
else
  pass "TLS-on/auth-off render differs from the auth-on render"
fi

# --- TLS OFF, auth ON: the gate is suppressed and a warning is printed ------
# The (auth) snippet is imported only by the HTTPS sites. With TLS off there
# are no HTTPS sites, so the snippet is dead config and real Caddy rejects it
# (`parsed 'basic_auth' as a site address, but it is a known directive`). The
# correct behaviour is SUPPRESS: the render is byte-identical to the auth-off
# render no matter what AUTH_ENABLED says. Unpatched, tls_variants returned
# "off auth" and emitted the snippet, so this case fails against the base.
TLS_ENABLED="no"
AUTH_ENABLED="on"
HYBRID_AI_AUTH_USER="DUMMY_AUTH_USER_NOT_A_SECRET"
HYBRID_AI_AUTH_HASH="\$2a\$14\$DUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY"

if [[ "$(tls_variants)" == "off" ]]; then
  pass "tls_variants is exactly 'off' with TLS off and AUTH_ENABLED=on (gate suppressed)"
else
  fail "tls_variants is not 'off' with TLS off and AUTH_ENABLED=on (got '$(tls_variants)')"
fi

# Render from the LIVE tls_variants, not a literal: an unpatched tls_variants
# returns "off auth" here and emits the snippet, so the byte-identical and
# zero-snippet checks fail too, not just the variants check above.
render "$(tls_variants)" "$WORK/tls_authon"

if cmp -s -- "$WORK/off" "$WORK/tls_authon"; then
  pass "TLS-off/auth-on render is byte-identical to the auth-off render"
else
  fail "TLS-off/auth-on render differs from the auth-off render"
  diff -u "$WORK/off" "$WORK/tls_authon" >&2 || true
fi

n_basic_auth_d="$(grep -c 'basic_auth' "$WORK/tls_authon" || true)"
if [[ "$n_basic_auth_d" == "0" ]]; then
  pass "TLS-off/auth-on render contains zero basic_auth lines"
else
  fail "TLS-off/auth-on render contains ${n_basic_auth_d} basic_auth lines (expected 0)"
fi
n_snippet_d="$(grep -c '^(auth) {' "$WORK/tls_authon" || true)"
if [[ "$n_snippet_d" == "0" ]]; then
  pass "TLS-off/auth-on render defines zero (auth) snippets"
else
  fail "TLS-off/auth-on render defines ${n_snippet_d} (auth) snippets (expected 0)"
fi
n_import_d="$(grep -c 'import auth' "$WORK/tls_authon" || true)"
if [[ "$n_import_d" == "0" ]]; then
  pass "TLS-off/auth-on render contains zero 'import auth' lines"
else
  fail "TLS-off/auth-on render contains ${n_import_d} 'import auth' lines (expected 0)"
fi

# The warning string install.sh emits in this exact combination, kept verbatim.
EXPECTED_WARNING="WARNING: AUTH_ENABLED is on but TLS is off — the login gate applies only to the TLS HTTPS sites; nothing is gated until TLS is enabled."
if tls_auth_without_tls_warning 2>&1 | grep -qF -- "$EXPECTED_WARNING"; then
  pass "the auth-without-TLS warning is emitted verbatim"
else
  fail "the auth-without-TLS warning was not emitted verbatim"
fi

# --- the env allowlist covers the two new names ------------------------------
# tls_load_env_file_values feeds the renderer the auth values it must see. It is
# an allowlist, so a name it does not list is silently dropped. The cookie
# secret and the max-age must both be read back from a stack env file. This case
# FAILS against the unpatched base, whose allowlist named only USER and HASH.
ALLOWLIST_FILE="$WORK/allowlist.env"
cat > "$ALLOWLIST_FILE" <<'ENVEOF'
HYBRID_AI_AUTH_COOKIE_SECRET=dummy-cookie-secret-not-a-secret
HYBRID_AI_AUTH_COOKIE_MAX_AGE=12345
ENVEOF
unset HYBRID_AI_AUTH_COOKIE_SECRET HYBRID_AI_AUTH_COOKIE_MAX_AGE
tls_load_env_file_values "$ALLOWLIST_FILE"
if [[ "${HYBRID_AI_AUTH_COOKIE_SECRET:-}" == "dummy-cookie-secret-not-a-secret" ]]; then
  pass "tls_load_env_file_values reads HYBRID_AI_AUTH_COOKIE_SECRET"
else
  fail "tls_load_env_file_values dropped HYBRID_AI_AUTH_COOKIE_SECRET (got '${HYBRID_AI_AUTH_COOKIE_SECRET:-}')"
fi
if [[ "${HYBRID_AI_AUTH_COOKIE_MAX_AGE:-}" == "12345" ]]; then
  pass "tls_load_env_file_values reads HYBRID_AI_AUTH_COOKIE_MAX_AGE"
else
  fail "tls_load_env_file_values dropped HYBRID_AI_AUTH_COOKIE_MAX_AGE (got '${HYBRID_AI_AUTH_COOKIE_MAX_AGE:-}')"
fi

# --- fail-closed: relocated to the installer --------------------------------
# The gate no longer carries the credentials, so `caddy validate` can no longer
# see them empty. The control moved to the installer: tls_auth_fail_closed runs
# BEFORE any render and dies when AUTH_ENABLED=on (with TLS on) and the user,
# hash or cookie secret is empty. It is never tolerant of an empty value. The
# three reject directions below all FAIL against the unpatched base, which had
# no such check at all (the base relied on `caddy validate`, and this render
# carries no placeholder for it to reject).
TLS_ENABLED="yes"
AUTH_ENABLED="on"

check_fail_closed() {  # NAME MSG_OUT
  local name="$1" msg="$2"
  if grep -q "$name" <<<"$msg"; then
    pass "fail-closed: empty ${name} is rejected and named in the message"
  else
    fail "fail-closed: empty ${name} reject message did not name it (got: ${msg})"
  fi
}

# Empty hash (user and secret present): must be REJECTED.
HYBRID_AI_AUTH_USER="DUMMY_AUTH_USER_NOT_A_SECRET"
HYBRID_AI_AUTH_HASH=""
HYBRID_AI_AUTH_COOKIE_SECRET="dummy-cookie-secret-not-a-secret"
msg=""
if ! msg="$(tls_auth_fail_closed 2>&1)"; then
  check_fail_closed HYBRID_AI_AUTH_HASH "$msg"
else
  fail "fail-closed: AUTH_ENABLED=on with an empty hash was ACCEPTED"
fi

# Empty user (hash and secret present): must be REJECTED.
HYBRID_AI_AUTH_USER=""
HYBRID_AI_AUTH_HASH="\$2a\$14\$DUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY"
HYBRID_AI_AUTH_COOKIE_SECRET="dummy-cookie-secret-not-a-secret"
msg=""
if ! msg="$(tls_auth_fail_closed 2>&1)"; then
  check_fail_closed HYBRID_AI_AUTH_USER "$msg"
else
  fail "fail-closed: AUTH_ENABLED=on with an empty user was ACCEPTED"
fi

# Empty cookie secret (both credentials present): must be REJECTED.
HYBRID_AI_AUTH_USER="DUMMY_AUTH_USER_NOT_A_SECRET"
HYBRID_AI_AUTH_HASH="\$2a\$14\$DUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY"
HYBRID_AI_AUTH_COOKIE_SECRET=""
msg=""
if ! msg="$(tls_auth_fail_closed 2>&1)"; then
  check_fail_closed HYBRID_AI_AUTH_COOKIE_SECRET "$msg"
else
  fail "fail-closed: AUTH_ENABLED=on with an empty cookie secret was ACCEPTED"
fi

# All present: must PASS (return 0, no message).
HYBRID_AI_AUTH_USER="DUMMY_AUTH_USER_NOT_A_SECRET"
HYBRID_AI_AUTH_HASH="\$2a\$14\$DUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY"
HYBRID_AI_AUTH_COOKIE_SECRET="dummy-cookie-secret-not-a-secret"
if tls_auth_fail_closed >/dev/null 2>&1; then
  pass "AUTH_ENABLED=on with user, hash and cookie secret set passes the fail-closed check"
else
  fail "AUTH_ENABLED=on with all three set was rejected by the fail-closed check"
fi

# The check is scoped to the auth variant: with TLS off there is no gate, so it
# must not fire (the installer warns instead).
TLS_ENABLED="no"
if tls_auth_fail_closed >/dev/null 2>&1; then
  pass "fail-closed check does not fire with TLS off (no gate to protect)"
else
  fail "fail-closed check fired with TLS off (it must only guard the auth variant)"
fi

if (( FAILED )); then
  printf '\nsome checks failed\n' >&2
  exit 1
fi
printf '\nall auth render checks passed\n'
