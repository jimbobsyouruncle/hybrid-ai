#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/test-tls-installer-render.sh
# PURPOSE (plain English):
#   Self-test for the TLS installer renderer in scripts/lib/tls.sh. It copies
#   the two managed-region templates into a throwaway APP_DIR, renders the
#   TLS-off and TLS-on variants, and checks three things:
#     1. the TLS-off render is byte-identical to the tracked status/Caddyfile
#        and docker-compose.yml,
#     2. rendering twice produces byte-identical files (idempotency),
#     3. the TLS-on render keeps the controls section 9 requires.
#   It never touches the real files and never needs root, Docker or Caddy.
#
# HOW TO RUN IT:
#   ./scripts/test-tls-installer-render.sh
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
cp "${HYBRID_AI_APP_DIR}/docker-compose.yml.tmpl" "$APP_DIR/docker-compose.yml.tmpl"

FAILED=0
pass() { printf '[ OK ] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; FAILED=1; }

render() {  # VARIANTS OUTDIR
  local variants="$1" out="$2"
  mkdir -p "$out"
  tls_prepare_render_values "$variants"
  tls_render_to_file "$APP_DIR/status/Caddyfile.tmpl" "$variants" "$out/Caddyfile"
  tls_render_to_file "$APP_DIR/docker-compose.yml.tmpl" "$variants" "$out/docker-compose.yml"
}

# --- TLS off ---------------------------------------------------------------
LOCAL_DOMAIN="jarvis.lan"
TLS_ENABLED="no"
render off "$WORK/off1"
render off "$WORK/off2"

if cmp -s -- "${HYBRID_AI_APP_DIR}/status/Caddyfile" "$WORK/off1/Caddyfile"; then
  pass "TLS-off Caddyfile render is byte-identical to the tracked file"
else
  fail "TLS-off Caddyfile render differs from the tracked file"
  diff -u "${HYBRID_AI_APP_DIR}/status/Caddyfile" "$WORK/off1/Caddyfile" >&2 || true
fi

if cmp -s -- "${HYBRID_AI_APP_DIR}/docker-compose.yml" "$WORK/off1/docker-compose.yml"; then
  pass "TLS-off compose render is byte-identical to the tracked file"
else
  fail "TLS-off compose render differs from the tracked file"
  diff -u "${HYBRID_AI_APP_DIR}/docker-compose.yml" "$WORK/off1/docker-compose.yml" >&2 || true
fi

if cmp -s -- "$WORK/off1/Caddyfile" "$WORK/off2/Caddyfile" \
   && cmp -s -- "$WORK/off1/docker-compose.yml" "$WORK/off2/docker-compose.yml"; then
  pass "TLS-off render is idempotent (two runs identical)"
else
  fail "TLS-off render is not idempotent"
fi

# Caddy /data isolation: the proxy bind source must be a sibling of webui_data
# (${HYBRID_AI_DATA_DIR}/caddy), so once TLS is enabled ACME private keys land
# OUTSIDE the tree the status container mounts read-only.
off_compose="$WORK/off1/docker-compose.yml"
mount_prefix="      - \${HYBRID_AI_DATA_DIR:?HYBRID_AI_DATA_DIR must be set - run ./install.sh}"
proxy_data_line="${mount_prefix}/caddy:/data"
status_ro_line="${mount_prefix}/webui_data:/data/webui_data:ro"
if grep -Fxq -- "$proxy_data_line" "$off_compose" \
   && ! grep -Fq -- 'webui_data/caddy' "$off_compose"; then
  pass "Caddy /data is isolated: proxy bind source is …/caddy, outside webui_data"
else
  fail "Caddy /data is NOT isolated: proxy bind source is missing …/caddy or still under webui_data"
fi
if grep -Fxq -- "$status_ro_line" "$off_compose"; then
  pass "status read-only webui_data mount line is present and byte-unchanged"
else
  fail "status read-only webui_data mount line changed or is missing"
fi

# --- TLS on ----------------------------------------------------------------
TLS_ENABLED="yes"
TLS_DOMAIN="daemonhub.dev"
ACME_EMAIL="admin@daemonhub.dev"
TLS_VALIDATION="dns"
ACME_DNS_PROVIDER="cloudflare"
ACME_CA="$TLS_CA_STAGING_URL"
render "on dns" "$WORK/on1"
render "on dns" "$WORK/on2"

if cmp -s -- "$WORK/on1/Caddyfile" "$WORK/on2/Caddyfile" \
   && cmp -s -- "$WORK/on1/docker-compose.yml" "$WORK/on2/docker-compose.yml"; then
  pass "TLS-on render is idempotent (two runs identical)"
else
  fail "TLS-on render is not idempotent"
fi

# Exactly one managed region produces exactly one HTTPS site block.
n_https="$(grep -c '^https://' "$WORK/on1/Caddyfile" || true)"
if [[ "$n_https" == "4" ]]; then
  pass "TLS-on Caddyfile has exactly 4 https:// sites"
else
  fail "TLS-on Caddyfile has ${n_https} https:// sites (expected 4)"
fi

for snippet in '(trusted_only)' '(secure_headers)'; do
  if diff -q <(awk -v s="$snippet" 'index($0,s)==1{f=1} f{print} f&&/^}/{exit}' "${HYBRID_AI_APP_DIR}/status/Caddyfile") \
             <(awk -v s="$snippet" 'index($0,s)==1{f=1} f{print} f&&/^}/{exit}' "$WORK/on1/Caddyfile") >/dev/null; then
    pass "${snippet} is byte-for-byte unchanged in the TLS-on render"
  else
    fail "${snippet} changed in the TLS-on render"
  fi
done

expect() {  # FILE PATTERN MESSAGE
  if grep -q -- "$2" "$1"; then pass "$3"; else fail "$3"; fi
}
reject() {  # FILE PATTERN MESSAGE
  if grep -q -- "$2" "$1"; then fail "$3"; else pass "$3"; fi
}

expect "$WORK/on1/Caddyfile" '100\.64\.0\.0/10 fd7a:115c:a1e0::/48' \
  "allowlist (RFC1918 + mesh /10 + fd7a:115c:a1e0::/48) preserved"
expect "$WORK/on1/Caddyfile" '127\.0\.0\.1/8 ::1' "loopback allowlist entry preserved"
expect "$WORK/on1/Caddyfile" $'^\tadmin localhost:2019$' \
  "TLS-on Caddyfile binds admin on in-container loopback"
expect "$WORK/off1/Caddyfile" 'admin off' "TLS-off Caddyfile keeps admin off"

# B1: `auto_https off` disables Caddy's certificate management, so a DNS-01
# install would "succeed" and issue no certificate. The explicit http:// block
# is the 308 redirect, so disable_redirects is the correct value.
expect "$WORK/on1/Caddyfile" '^[[:space:]]*auto_https disable_redirects$' \
  "TLS-on DNS-01 Caddyfile keeps certificate management (auto_https disable_redirects)"
reject "$WORK/on1/Caddyfile" 'auto_https off' \
  "TLS-on DNS-01 Caddyfile does not disable certificate management (no auto_https off)"

expect "$WORK/on1/docker-compose.yml" '^      - "443:443"$' "TLS-on compose publishes 443"
reject "$WORK/off1/docker-compose.yml" '"443:443"' "TLS-off compose does not publish 443"
expect "$WORK/on1/docker-compose.yml" '^secrets:' "TLS-on compose declares a file-backed secret"
expect "$WORK/on1/docker-compose.yml" 'file: .*HYBRID_AI_TLS_TOKEN_FILE' \
  "TLS-on compose secret is file-backed, not environment-backed"
reject "$WORK/off1/docker-compose.yml" '^secrets:' "TLS-off compose has no secrets: block"
reject "$WORK/on1/docker-compose.yml" '2019:2019' "admin port is never published"
expect "$WORK/on1/docker-compose.yml" 'no-new-privileges:true' \
  "container hardening preserved in the TLS-on compose"
expect "$WORK/on1/docker-compose.yml" 'mem_limit: 128m' \
  "proxy memory cap preserved in the TLS-on compose"

# --- TLS on, RFC 2136 + HTTP-01 variants render too ------------------------
ACME_DNS_PROVIDER="rfc2136"
RFC2136_KEY_NAME="acme-daemonhub"
RFC2136_SERVER="ns1.daemonhub.dev:53"
render "on dns" "$WORK/rfc2136"
expect "$WORK/rfc2136/Caddyfile" 'dns rfc2136 {' "rfc2136 solver block renders"
expect "$WORK/rfc2136/docker-compose.yml" 'rfc2136_key_secret' "rfc2136 secret name renders"

ACME_DNS_PROVIDER="cloudflare"
TLS_VALIDATION="http"
render "on dns" "$WORK/http01"
expect "$WORK/http01/Caddyfile" 'redir https://{host}{uri} 308' \
  "http-01 render keeps the HTTP->HTTPS redirect"
expect "$WORK/http01/Caddyfile" '^[[:space:]]*auto_https disable_redirects$' \
  "http-01 render keeps certificate management (auto_https disable_redirects)"
reject "$WORK/http01/Caddyfile" 'auto_https off' \
  "http-01 render does not disable certificate management"

# --- TLS-ALPN-01: the other non-http mode keeps certificate management ------
TLS_VALIDATION="tlsalpn"
ACME_DNS_PROVIDER="cloudflare"
render "on" "$WORK/tlsalpn"
expect "$WORK/tlsalpn/Caddyfile" '^[[:space:]]*auto_https disable_redirects$' \
  "tls-alpn-01 render keeps certificate management (auto_https disable_redirects)"
reject "$WORK/tlsalpn/Caddyfile" 'auto_https off' \
  "tls-alpn-01 render does not disable certificate management"

# --- B3: the completion output names a staging issuer and the fix ----------
TLS_VALIDATION="dns"
ACME_DNS_PROVIDER="cloudflare"
ACME_CA="$TLS_CA_STAGING_URL"
TLS_CA_URL="$(tls_validate_ca "$ACME_CA")"
staging_banner="$(tls_print_ca_caution 2>&1 || true)"
if [[ "$staging_banner" == *STAGING* ]] \
   && [[ "$staging_banner" == *"--tls-acme-ca production"* ]] \
   && [[ "$staging_banner" == *"ACME_CA=production"* ]]; then
  pass "staging CA completion output warns about untrusted certificates and names the fix"
else
  fail "staging CA completion output did not warn about untrusted certificates and the fix"
fi

ACME_CA="$TLS_CA_PRODUCTION_URL"
TLS_CA_URL="$(tls_validate_ca "$ACME_CA")"
production_banner="$(tls_print_ca_caution 2>&1 || true)"
if [[ -z "$production_banner" ]]; then
  pass "production CA completion output carries no staging warning"
else
  fail "production CA completion output printed a staging warning"
fi

# --- M1: RFC 2136 values are validated BEFORE interpolation ----------------
# tls__die exits the current shell, so every probe runs in a subshell.
# The payload is the audit finding: a newline plus `}` closes the dns block and
# injects an arbitrary directive. It must be refused, not rendered.
try_prepare() {  # -> 0 accepted, non-zero refused; stderr kept in $WORK/inject.err
  ( tls_prepare_render_values "on dns" ) >/dev/null 2>"$WORK/inject.err"
}

ACME_DNS_PROVIDER="rfc2136"
TLS_VALIDATION="dns"
ENV_FILE="fixture.env"
RFC2136_KEY_NAME="acme-daemonhub"
RFC2136_SERVER=$'ns1.daemonhub.dev:53\n\t}\n\tadmin off\n\tx {'
if try_prepare; then
  fail "RFC2136_SERVER newline-injection payload was accepted"
else
  pass "RFC2136_SERVER newline-injection payload is rejected"
fi
if grep -q 'RFC2136_SERVER' "$WORK/inject.err"; then
  pass "the injection refusal names RFC2136_SERVER"
else
  fail "the injection refusal does not name RFC2136_SERVER"
fi

RFC2136_SERVER="ns1.daemonhub.dev:53"
RFC2136_KEY_NAME=$'acme\n\t} admin off\nx {'
if try_prepare; then
  fail "RFC2136_KEY_NAME newline-injection payload was accepted"
else
  pass "RFC2136_KEY_NAME newline-injection payload is rejected"
fi

RFC2136_KEY_NAME="acme-daemonhub"
RFC2136_SERVER="ns1.daemonhub.dev;rm -rf /"
if try_prepare; then
  fail "RFC2136_SERVER with a shell metacharacter was accepted"
else
  pass "RFC2136_SERVER with a shell metacharacter is rejected"
fi

RFC2136_SERVER="[::1]:53"
if try_prepare; then
  pass "RFC2136_SERVER accepts an IP literal with a port"
else
  fail "RFC2136_SERVER refused a valid IP literal with a port"
fi


if (( FAILED )); then
  printf '\nsome checks failed\n' >&2
  exit 1
fi
printf '\nall render checks passed\n'
