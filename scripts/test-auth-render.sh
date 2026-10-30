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
#     4. fail-closed: with AUTH_ENABLED=on and an empty user or hash, the
#        rendered block is empty and the validator rejects it (a stub `caddy`
#        expands the placeholders the way the container would).
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

# The (auth) snippet: defined once, with the two env placeholders and no
# literal credential.
n_basic_auth="$(grep -c 'basic_auth' "$WORK/on" || true)"
if [[ "$n_basic_auth" == "1" ]]; then
  pass "auth-on render defines basic_auth exactly once (the (auth) snippet)"
else
  fail "auth-on render has ${n_basic_auth} basic_auth lines (expected 1)"
fi
# The snippet must be the MULTI-LINE form: Caddy requires a block's `{` to be
# the last token on its line, so `basic_auth { user hash }` does not adapt.
auth_body_line="$(printf '\t\t'){\$HYBRID_AI_AUTH_USER} {\$HYBRID_AI_AUTH_HASH}"
if grep -qE '^[[:space:]]*basic_auth \{[[:space:]]*$' "$WORK/on" \
   && grep -qxF -- "$auth_body_line" "$WORK/on"; then
  pass "the (auth) snippet uses the multi-line form with the two env placeholders"
else
  fail "the (auth) snippet is not the expected multi-line placeholder form"
fi
if awk '/^\(auth\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$WORK/on" \
     | grep -qE 'basic_auth \{.*[^[:space:]]'; then
  fail "the (auth) snippet puts tokens after '{' on the same line (Caddy rejects this)"
else
  pass "the (auth) snippet puts no token after '{' on the same line"
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

# --- fail-closed: empty credentials render an invalid block -----------------
# A stub `caddy` that applies the same two rules the real caddyfile adapter
# applies, so the fail-closed cases exercise the shape production renders:
#   1. GRAMMAR: a block's `{` must be the last token on its line. Anything
#      after it is "Unexpected next token after '{' on same line" (the error
#      the inline `basic_auth { user hash }` form produced on the host).
#   2. ARGUMENTS: it expands the two auth placeholders from the exported
#      environment the way the container would, then requires exactly two
#      arguments. Real Caddy says "username and password cannot be empty or
#      missing" when either is blank.
# It never makes the validator tolerant: a failure is always a failure.
# Limitation: this is an approximation of the adapter. The true proof is a real
# `caddy validate` (and, post-merge, the host run).
caddy() {
  # The validator calls: caddy validate --adapter caddyfile --config FILE.
  local file="${5:-}" body bad_line
  bad_line="$(awk '
    {
      sub(/#.*/, "")
      # A standalone `{` token (a block opener) followed by more tokens on the
      # same line. `{$VAR}` and `{file./run/secrets/...}` are placeholders, not
      # block openers, so they need whitespace after the brace to match.
      if (match($0, /(^|[ \t])\{[ \t]+[^ \t]/)) { print NR; exit }
    }' "$file")"
  if [[ -n "$bad_line" ]]; then
    printf "caddy: adapting config using caddyfile: Unexpected next token after '{' on same line, at %s:%s\n" \
      "$file" "$bad_line" >&2
    return 1
  fi
  body="$(awk '
    /^[ \t]*basic_auth[ \t]*\{[ \t]*$/ { f = 1; next }
    f && /^[ \t]*\}[ \t]*$/ { f = 0; next }
    f { print }
  ' "$file")"
  body="${body//\{\$HYBRID_AI_AUTH_USER\}/${HYBRID_AI_AUTH_USER:-}}"
  body="${body//\{\$HYBRID_AI_AUTH_HASH\}/${HYBRID_AI_AUTH_HASH:-}}"
  # basic_auth needs exactly two arguments: a user name and a hash.
  local -a argv=()
  read -r -a argv <<< "${body:-}"
  if (( ${#argv[@]} != 2 )); then
    printf 'caddy: adapting config using caddyfile: basic_auth: username and password cannot be empty or missing (%d arguments)\n' \
      "${#argv[@]}" >&2
    return 1
  fi
  return 0
}
export -f caddy

AUTH_ENABLED="on"
TLS_ENABLED="yes"
TLS_DOMAIN="daemonhub.dev"
ACME_EMAIL="[EMAIL]"
TLS_VALIDATION="dns"
ACME_DNS_PROVIDER="cloudflare"
ACME_CA="$TLS_CA_STAGING_URL"

# Empty hash (user present): must FAIL validation.
HYBRID_AI_AUTH_USER="DUMMY_AUTH_USER_NOT_A_SECRET"
HYBRID_AI_AUTH_HASH=""
render "on dns auth" "$WORK/empty_hash"
empty_hash_rc=0
tls_validate_caddyfile "$WORK/empty_hash" >/dev/null 2>&1 || empty_hash_rc=$?
if (( empty_hash_rc != 0 )); then
  pass "fail-closed: AUTH_ENABLED=on with an empty hash is rejected"
else
  fail "fail-closed: AUTH_ENABLED=on with an empty hash was ACCEPTED"
fi

# Empty user (hash present): must FAIL validation.
HYBRID_AI_AUTH_USER=""
HYBRID_AI_AUTH_HASH="\$2a\$14\$DUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY"
render "on dns auth" "$WORK/empty_user"
empty_user_rc=0
tls_validate_caddyfile "$WORK/empty_user" >/dev/null 2>&1 || empty_user_rc=$?
if (( empty_user_rc != 0 )); then
  pass "fail-closed: AUTH_ENABLED=on with an empty user is rejected"
else
  fail "fail-closed: AUTH_ENABLED=on with an empty user was ACCEPTED"
fi

# Both present: must PASS validation.
HYBRID_AI_AUTH_USER="DUMMY_AUTH_USER_NOT_A_SECRET"
HYBRID_AI_AUTH_HASH="\$2a\$14\$DUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY"
render "on dns auth" "$WORK/ok_auth"
ok_rc=0
tls_validate_caddyfile "$WORK/ok_auth" >/dev/null 2>&1 || ok_rc=$?
if (( ok_rc == 0 )); then
  pass "AUTH_ENABLED=on with both credentials set validates"
else
  fail "AUTH_ENABLED=on with both credentials set was rejected (rc ${ok_rc})"
fi
unset -f caddy

if (( FAILED )); then
  printf '\nsome checks failed\n' >&2
  exit 1
fi
printf '\nall auth render checks passed\n'
