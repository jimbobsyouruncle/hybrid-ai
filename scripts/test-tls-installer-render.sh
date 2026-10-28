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

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/tls.sh
source "${REPO_DIR}/scripts/lib/tls.sh"

WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

APP_DIR="$WORK/app"
mkdir -p "$APP_DIR/status"
cp "${REPO_DIR}/status/Caddyfile.tmpl" "$APP_DIR/status/Caddyfile.tmpl"
cp "${REPO_DIR}/docker-compose.yml.tmpl" "$APP_DIR/docker-compose.yml.tmpl"

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

if cmp -s -- "${REPO_DIR}/status/Caddyfile" "$WORK/off1/Caddyfile"; then
  pass "TLS-off Caddyfile render is byte-identical to the tracked file"
else
  fail "TLS-off Caddyfile render differs from the tracked file"
  diff -u "${REPO_DIR}/status/Caddyfile" "$WORK/off1/Caddyfile" >&2 || true
fi

if cmp -s -- "${REPO_DIR}/docker-compose.yml" "$WORK/off1/docker-compose.yml"; then
  pass "TLS-off compose render is byte-identical to the tracked file"
else
  fail "TLS-off compose render differs from the tracked file"
  diff -u "${REPO_DIR}/docker-compose.yml" "$WORK/off1/docker-compose.yml" >&2 || true
fi

if cmp -s -- "$WORK/off1/Caddyfile" "$WORK/off2/Caddyfile" \
   && cmp -s -- "$WORK/off1/docker-compose.yml" "$WORK/off2/docker-compose.yml"; then
  pass "TLS-off render is idempotent (two runs identical)"
else
  fail "TLS-off render is not idempotent"
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
  if diff -q <(awk -v s="$snippet" 'index($0,s)==1{f=1} f{print} f&&/^}/{exit}' "${REPO_DIR}/status/Caddyfile") \
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

if (( FAILED )); then
  printf '\nsome checks failed\n' >&2
  exit 1
fi
printf '\nall render checks passed\n'
