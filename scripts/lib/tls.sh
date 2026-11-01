#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/lib/tls.sh
# PURPOSE (plain English):
#   The opt-in TLS/ACME part of ./install.sh. install.sh SOURCES this file; it
#   is never executed on its own.
#   It holds: the tradeoff text from docs/tls-acme-design.md section 1.4, the
#   prompts (section 8.1), the input validation (8.5), the token-file checks
#   (path only, 2.5), the managed-region template renderer (8.3/8.4), the
#   compose and Caddyfile validation, and the --dry-run report (8.2).
#
#   It never reads, prints or writes a token VALUE. Only the path is handled.
#   The caller (install.sh) provides: APP_DIR, ENV_FILE, NON_INTERACTIVE,
#   die(), warn(), ok() and log().
# ---------------------------------------------------------------------------

TLS_TOKEN_DIR="/etc/hybrid-ai/acme"
TLS_CA_STAGING_URL="https://acme-staging-v02.api.letsencrypt.org/directory"
TLS_CA_PRODUCTION_URL="https://acme-v02.api.letsencrypt.org/directory"
TLS_DEFAULT_DOMAIN="daemonhub.dev"
# Validation images. The stock tag is right for every render that does not
# carry the DNS solver: it has the caddyfile adapter. A DNS-01 render names
# `dns.providers.cloudflare`/`dns.providers.rfc2136`, which the caddyfile
# adapter resolves AT ADAPT TIME, so the stock image rejects a correct render.
# tls_validate_image_for() picks the DNS-capable image for those renders;
# CADDY_VALIDATE_IMAGE overrides both cases. Resolved at CALL time, not here:
# install.sh sources this file before the stack .env is loaded, so a CADDY_IMAGE
# from .env does not exist yet at source time.
TLS_STOCK_VALIDATE_IMAGE="caddy:2.11-alpine"
TLS_DNS_VALIDATE_IMAGE_DEFAULT="hybrid-ai-caddy:2.11.7-dns"

# --- Output helpers: reuse install.sh's, fall back when sourced alone ------
tls__warn() {
  if declare -F warn >/dev/null 2>&1; then warn "$*"; else printf '[ ! ] %s\n' "$*" >&2; fi
}
tls__ok() {
  if declare -F ok >/dev/null 2>&1; then ok "$*"; else printf '[ OK ] %s\n' "$*"; fi
}
tls__note() {
  if declare -F log >/dev/null 2>&1; then log "$*"; else printf '[ * ] %s\n' "$*"; fi
}
tls__die() {
  if declare -F die >/dev/null 2>&1; then die "$*"; else printf '[ X ] %s\n' "$*" >&2; exit 1; fi
}

# ---------------------------------------------------------------------------
# Section 1.4 -- the tradeoff text, printed verbatim before the prompt.
# ---------------------------------------------------------------------------
tls_print_tradeoff() {
  cat <<'EOF'

    How should the certificate authority prove you own the domain?

      dns    (recommended)  You add a TXT record that Caddy writes for you through
                            your DNS provider's API. Works even though this Pi has
                            no open ports to the internet, and it is the only method
                            that gives you one wildcard certificate for every
                            subdomain. Cost: a DNS API token is stored on this Pi.

      http                  The CA fetches a file over port 80 from the internet.
                            No token is stored anywhere, but your router must forward
                            port 80 and your ISP must not block it. No wildcard.

      tlsalpn               The CA checks a special certificate on port 443. No token
                            is stored, but port 443 must be reachable from the
                            internet. No wildcard.

    Pick 'http' or 'tlsalpn' if you cannot or will not store a DNS token and you can
    open a port. Pick 'dns' otherwise. Default: dns

EOF
}

# ---------------------------------------------------------------------------
# Small value helpers
# ---------------------------------------------------------------------------
tls_is_on() {
  case "${TLS_ENABLED:-no}" in
    1|yes|YES|Yes|true|TRUE|True) return 0 ;;
    *) return 1 ;;
  esac
}

# The login gate is a render-time switch: AUTH_ENABLED=on emits the (auth)
# snippet and every `import auth`. Any other value (the default, absent, "off")
# keeps the region out, so the rendered files are byte-identical to today's.
tls_auth_is_on() {
  case "${AUTH_ENABLED:-off}" in
    1|yes|YES|Yes|true|TRUE|True|on|ON|On) return 0 ;;
    *) return 1 ;;
  esac
}

# The warning install.sh prints when the gate is switched on but TLS is off. The
# snippet has nothing to import it (there are no HTTPS sites), so nothing is
# gated. Warning only: it never changes the installer's exit status.
tls_auth_without_tls_warning() {
  tls__warn "WARNING: AUTH_ENABLED is on but TLS is off — the login gate applies only to the TLS HTTPS sites; nothing is gated until TLS is enabled."
}

# Fail closed BEFORE any render. The render no longer carries the credentials, so
# `caddy validate` can no longer catch an empty value; this is the control that
# replaces it. Never tolerant of an empty credential or secret: with the auth
# variant live, a missing value would gate nothing (or gate with a forgeable
# cookie), so the install must stop and name every missing variable.
tls_auth_fail_closed() {
  tls_is_on && tls_auth_is_on || return 0
  local missing=()
  [[ -n "${HYBRID_AI_AUTH_USER:-}" ]] || missing+=(HYBRID_AI_AUTH_USER)
  [[ -n "${HYBRID_AI_AUTH_HASH:-}" ]] || missing+=(HYBRID_AI_AUTH_HASH)
  [[ -n "${HYBRID_AI_AUTH_COOKIE_SECRET:-}" ]] || missing+=(HYBRID_AI_AUTH_COOKIE_SECRET)
  if (( ${#missing[@]} > 0 )); then
    tls__die "AUTH_ENABLED=on with TLS on requires HYBRID_AI_AUTH_USER, HYBRID_AI_AUTH_HASH and HYBRID_AI_AUTH_COOKIE_SECRET; missing: ${missing[*]}"
  fi
}

# Compose interpolates `$` inside env-file values, so the operator's literal `$`
# bytes must reach the file doubled (`$$`); compose then yields the original
# bytes in the container. These two helpers are the single place that knows the
# rule. Escape on WRITE (install.sh STEP 8); unescape on READ (the validator,
# which must see exactly what the container sees). Collapsing first makes
# escaping IDEMPOTENT: a raw value is escaped once, an already-escaped value is
# left byte-identical, and a value already carrying `$$` never becomes `$$$$`.
tls_compose_unescape() {  # VALUE -> literal bytes
  local v="$1"
  printf '%s\n' "${v//\$\$/\$}"
}
tls_compose_escape() {  # VALUE -> env-file form
  local v
  v="$(tls_compose_unescape "$1")"
  printf '%s\n' "${v//\$/\$\$}"
}

tls_default_token_path() {
  case "${ACME_DNS_PROVIDER:-cloudflare}" in
    rfc2136) printf '%s\n' "${TLS_TOKEN_DIR}/rfc2136_key_secret" ;;
    *)       printf '%s\n' "${TLS_TOKEN_DIR}/cloudflare_dns_token" ;;
  esac
}

tls_secret_name() {
  case "${1:-cloudflare}" in
    rfc2136) printf '%s\n' "rfc2136_key_secret" ;;
    *)       printf '%s\n' "cloudflare_dns_token" ;;
  esac
}

# staging | production | https://... -> URL, or empty when the value is invalid.
tls_ca_url() {
  case "$1" in
    staging)    printf '%s\n' "$TLS_CA_STAGING_URL" ;;
    production) printf '%s\n' "$TLS_CA_PRODUCTION_URL" ;;
    https://*)  printf '%s\n' "$1" ;;
    *)          printf '%s\n' "" ;;
  esac
}

tls_ca_label() {
  case "$1" in
    "$TLS_CA_STAGING_URL")    printf '%s\n' "staging" ;;
    "$TLS_CA_PRODUCTION_URL") printf '%s\n' "production" ;;
    *)                        printf '%s\n' "$1" ;;
  esac
}

# ---------------------------------------------------------------------------
# Section 8.5 -- validation rules. Every function dies with the reason.
# ---------------------------------------------------------------------------
tls_validate_domain() {
  local d="${1:-}" re='^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'
  [[ -n $d ]] || tls__die "TLS_DOMAIN is empty. Set TLS_DOMAIN in ${ENV_FILE} or pass --tls-domain <name>."
  ((${#d} <= 253)) || tls__die "TLS_DOMAIN must be 253 characters or fewer (got ${#d})."
  [[ $d == *.* ]] || tls__die "TLS_DOMAIN must have at least two labels (got '${d}'). Pass --tls-domain example.org."
  [[ $d =~ $re ]] || tls__die "TLS_DOMAIN '${d}' may only contain a-z, 0-9, '-' and '.', with no leading or trailing hyphen in a label, and must be lowercase."
  if [[ $d =~ ^[0-9.]+$ ]]; then
    tls__die "TLS_DOMAIN must be a DNS name, not an IP address (got '${d}')."
  fi
  if [[ $d == *.local || $d == *.lan ]]; then
    tls__die "TLS_DOMAIN '${d}' is a private-use name (.local/.lan) that no public CA can certify."
  fi
  if [[ -n "${LOCAL_DOMAIN:-}" && "${d,,}" == "${LOCAL_DOMAIN,,}" ]]; then
    tls__die "TLS_DOMAIN must differ from LOCAL_DOMAIN (both are '${d}'). TLS_DOMAIN is the public certificate name; LOCAL_DOMAIN stays the http:// fallback. Pass --tls-domain <name>."
  fi
}

tls_validate_email() {
  local e="${1:-}"
  [[ -n $e ]] || tls__die "ACME_EMAIL is empty. Set ACME_EMAIL in ${ENV_FILE} or pass --tls-email <addr>."
  [[ $e != *[[:space:]]* ]] || tls__die "ACME_EMAIL must not contain whitespace (got '${e}')."
  if [[ $e == *@*@* ]]; then
    tls__die "ACME_EMAIL must contain exactly one '@' (got '${e}')."
  fi
  [[ $e == *@* ]] || tls__die "ACME_EMAIL must contain one '@' (got '${e}')."
  [[ -n ${e%%@*} ]] || tls__die "ACME_EMAIL needs a non-empty local part before '@' (got '${e}')."
  [[ ${e#*@} == *.* ]] || tls__die "ACME_EMAIL domain needs at least one dot (got '${e}')."
}

tls_validate_validation() {
  case "${1:-}" in
    dns|http|tlsalpn) ;;
    *) tls__die "TLS_VALIDATION must be one of dns, http or tlsalpn (got '${1:-}'). Pass --tls-validation <method>." ;;
  esac
}

tls_validate_dns_provider() {
  case "${1:-}" in
    cloudflare|rfc2136) ;;
    *) tls__die "ACME_DNS_PROVIDER must be cloudflare or rfc2136 (got '${1:-}'). Pass --tls-dns-provider <name>." ;;
  esac
}

tls_validate_ca() {
  local url
  url="$(tls_ca_url "${1:-}")"
  [[ -n $url ]] || tls__die "ACME_CA must be staging, production, or an https:// URL (got '${1:-}'). Pass --tls-acme-ca <staging|production|url>."
  printf '%s\n' "$url"
}

# Section 8.5, last row: the token file. PATH ONLY. Never a value.
tls_validate_token_file() {
  local f="${1:-}" mode uid real
  [[ -n $f ]] || tls__die "HYBRID_AI_TLS_TOKEN_FILE is empty. Set it in ${ENV_FILE} or pass --tls-token-file <path>."
  [[ $f == /* ]] || tls__die "HYBRID_AI_TLS_TOKEN_FILE must be an absolute path (got '${f}'). Pass --tls-token-file ${TLS_TOKEN_DIR}/$(basename -- "$f")."
  if [[ -n "${APP_DIR:-}" && ( $f == "$APP_DIR" || $f == "$APP_DIR"/* ) ]]; then
    tls__die "HYBRID_AI_TLS_TOKEN_FILE must live outside the repo and the app directory (${APP_DIR}). Fix: sudo install -d -m 0700 -o root -g root ${TLS_TOKEN_DIR} && sudo mv ${f} ${TLS_TOKEN_DIR}/ && then set HYBRID_AI_TLS_TOKEN_FILE=${TLS_TOKEN_DIR}/$(basename -- "$f")"
  fi
  if [[ ! -e $f ]]; then
    # Point at the canonical location when the given path is not already under
    # it, so the fix command is the one the design document documents.
    local target="$f"
    case "$target" in
      "${TLS_TOKEN_DIR}"/*) ;;
      *) target="${TLS_TOKEN_DIR}/$(basename -- "$target")" ;;
    esac
    tls__die "HYBRID_AI_TLS_TOKEN_FILE '${f}' does not exist. Fix: sudo install -d -m 0700 -o root -g root $(dirname -- "$target") && sudo install -m 0600 -o root -g root /dev/null ${target} && then write the token into that file with an editor or a pipe (never as a shell argument), and set HYBRID_AI_TLS_TOKEN_FILE=${target}."
  fi
  [[ -f $f ]] || tls__die "HYBRID_AI_TLS_TOKEN_FILE '${f}' is not a regular file. Fix: sudo install -m 0600 -o root -g root /dev/null ${f}"
  [[ -r $f ]] || tls__die "HYBRID_AI_TLS_TOKEN_FILE '${f}' is not readable. Fix: sudo chmod 600 ${f} && sudo chown root:root ${f}"
  # A symlink is allowed only while it still resolves inside the drop-in
  # directory; one that escapes is how a 0600 root file gets laundered into a
  # world-readable path.
  real="$(readlink -f -- "$f" 2>/dev/null || printf '%s' "$f")"
  case "$real" in
    "${TLS_TOKEN_DIR}"/*) ;;
    *) tls__die "HYBRID_AI_TLS_TOKEN_FILE '${f}' resolves outside ${TLS_TOKEN_DIR} (${real}). Move it: sudo install -d -m 0700 -o root -g root ${TLS_TOKEN_DIR} && sudo install -m 0600 -o root -g root ${f} ${TLS_TOKEN_DIR}/$(basename -- "$f") && then set HYBRID_AI_TLS_TOKEN_FILE=${TLS_TOKEN_DIR}/$(basename -- "$f")" ;;
  esac
  mode="$(stat -c '%a' -- "$f" 2>/dev/null || true)"
  [[ -n $mode ]] || tls__die "Could not read the mode of HYBRID_AI_TLS_TOKEN_FILE '${f}'. Fix: sudo chmod 600 ${f} && sudo chown root:root ${f}"
  if (( 8#$mode & 8#077 )); then
    tls__die "HYBRID_AI_TLS_TOKEN_FILE '${f}' is mode ${mode}; it must be 0600 or stricter. Fix: sudo chmod 600 ${f}"
  fi
  uid="$(stat -c '%u' -- "$f" 2>/dev/null || true)"
  [[ $uid == "0" ]] || tls__die "HYBRID_AI_TLS_TOKEN_FILE '${f}' is not owned by root (uid ${uid:-unknown}). Fix: sudo chown root:root ${f} && sudo chmod 600 ${f}"
}

# Flag over env, applied once .env has been loaded and before any prompt.
# install.sh records each --tls-* value in a TLS_ARG_* variable.
tls_apply_flags() {
  if [[ -n "${TLS_ARG_ENABLED:-}" ]];      then TLS_ENABLED="$TLS_ARG_ENABLED"; fi
  if [[ -n "${TLS_ARG_DOMAIN:-}" ]];       then TLS_DOMAIN="$TLS_ARG_DOMAIN"; fi
  if [[ -n "${TLS_ARG_EMAIL:-}" ]];        then ACME_EMAIL="$TLS_ARG_EMAIL"; fi
  if [[ -n "${TLS_ARG_VALIDATION:-}" ]];   then TLS_VALIDATION="$TLS_ARG_VALIDATION"; fi
  if [[ -n "${TLS_ARG_DNS_PROVIDER:-}" ]]; then ACME_DNS_PROVIDER="$TLS_ARG_DNS_PROVIDER"; fi
  if [[ -n "${TLS_ARG_CA:-}" ]];           then ACME_CA="$TLS_ARG_CA"; fi
  if [[ -n "${TLS_ARG_TOKEN_FILE:-}" ]];   then HYBRID_AI_TLS_TOKEN_FILE="$TLS_ARG_TOKEN_FILE"; fi
  return 0
}

# Resolve and validate everything, then derive the values the renderer needs.
# Sets: TLS_CA_URL, ACME_AUTO_HTTPS, TLS_HOSTS.
tls_validate_settings() {
  # Section 8.1 defaults, applied when a flag or .env value was not given.
  TLS_VALIDATION="${TLS_VALIDATION:-dns}"
  if [[ "$TLS_VALIDATION" == dns ]]; then
    ACME_DNS_PROVIDER="${ACME_DNS_PROVIDER:-cloudflare}"
  fi
  ACME_CA="${ACME_CA:-staging}"
  tls_validate_domain "${TLS_DOMAIN:-}"
  tls_validate_email "${ACME_EMAIL:-}"
  tls_validate_validation "${TLS_VALIDATION:-}"
  if [[ "${TLS_VALIDATION}" == dns ]]; then
    tls_validate_dns_provider "${ACME_DNS_PROVIDER:-}"
  fi
  TLS_CA_URL="$(tls_validate_ca "${ACME_CA:-}")"
  # Single seam: the resolved URL, not the staging/production label, is what
  # reaches the stack .env, the proxy's compose environment and the validator.
  # It runs here because tls_validate_settings precedes both the install.sh
  # STEP 8 env write and every validation call site.
  ACME_CA="$TLS_CA_URL"
  if [[ "${TLS_VALIDATION}" == dns ]]; then
    tls_validate_token_file "${HYBRID_AI_TLS_TOKEN_FILE:-}"
  fi
  if [[ "${TLS_VALIDATION}" == http ]]; then
    tls__warn "HTTP-01 cannot issue a wildcard certificate: this install gets three per-host certificates and no wildcard for *.${TLS_DOMAIN}."
  fi
  # Section 4.5: `auto_https off` disables Caddy's certificate management
  # entirely, so a DNS-01 install would report success and issue no
  # certificate. Both modes keep issuance with `disable_redirects`; the explicit
  # `http://` block below is the one 308 redirect, and HTTP-01 additionally
  # needs Caddy's challenge listener on port 80.
  export ACME_AUTO_HTTPS="disable_redirects"
  # Written to .env by install.sh; exported so it survives this function.
  export TLS_HOSTS="${TLS_DOMAIN},hermes.${TLS_DOMAIN},status.${TLS_DOMAIN}"
}

# ---------------------------------------------------------------------------
# Section 8.1 -- prompts. Each one is skipped when the value already exists,
# exactly as prompt_secret does today, and each has a flag/env equivalent.
# ---------------------------------------------------------------------------
tls_prompt_value() {  # VAR LABEL DEFAULT
  local __var="$1" __label="$2" __default="${3:-}" __val="" __cur
  __cur="${!__var:-}"
  if [[ -n $__cur ]]; then
    tls__ok "${__label}: already set."
    return 0
  fi
  if (( ${NON_INTERACTIVE:-0} )); then
    if [[ -n $__default ]]; then
      printf -v "$__var" '%s' "$__default"
      tls__ok "${__label}: ${__default} (default)."
      return 0
    fi
    tls__die "${__label} (${__var}) is required when TLS is enabled and --non-interactive was requested. Set ${__var} in ${ENV_FILE:-the stack .env} or pass its flag; see ./install.sh --help."
  fi
  while [[ -z $__val ]]; do
    read -r -p "    Enter ${__label}: " __val < /dev/tty
    if [[ -z $__val ]]; then tls__warn "Value cannot be empty."; fi
  done
  printf -v "$__var" '%s' "$__val"
}

tls_prompt_ca() {
  local __ans=""
  if [[ -n "${ACME_CA:-}" ]]; then
    tls__ok "Certificate authority: already set ($(tls_ca_label "${ACME_CA}"))."
    return 0
  fi
  if (( ${NON_INTERACTIVE:-0} )); then
    ACME_CA="$TLS_CA_STAGING_URL"
    tls__ok "Certificate authority: staging (default)."
    return 0
  fi
  while :; do
    read -r -p "    Certificate authority -- staging or production? [staging]: " __ans < /dev/tty
    case "${__ans,,}" in
      "") ACME_CA="$TLS_CA_STAGING_URL"; break ;;
      staging) ACME_CA="$TLS_CA_STAGING_URL"; break ;;
      production) ACME_CA="$TLS_CA_PRODUCTION_URL"; break ;;
      *) tls__warn "Answer staging or production." ;;
    esac
  done
}

tls_prompt_flow() {
  local __ans=""
  if [[ -n "${TLS_ENABLED:-}" ]]; then
    # Already answered (flag or .env): never ask again. A "no" stays silent so
    # the TLS-less run prints exactly what it always printed.
    if tls_is_on; then
      tls__ok "HTTPS with Let's Encrypt: already set (${TLS_ENABLED})."
    fi
  elif (( ${NON_INTERACTIVE:-0} )); then
    # Default is off, and off prints nothing extra: the TLS-less run must look
    # exactly like it did before this feature existed.
    TLS_ENABLED="no"
  else
    while :; do
      read -r -p "    Enable HTTPS with Let's Encrypt for this stack? [y/N]: " __ans < /dev/tty
      case "${__ans,,}" in
        "") TLS_ENABLED="no"; break ;;
        y|yes) TLS_ENABLED="yes"; break ;;
        n|no) TLS_ENABLED="no"; break ;;
        *) tls__warn "Answer y or n." ;;
      esac
    done
  fi
  tls_is_on || return 0

  tls_prompt_value TLS_DOMAIN "Base domain for certificates (e.g. daemonhub.dev)" "$TLS_DEFAULT_DOMAIN"
  tls_prompt_value ACME_EMAIL "ACME account email" ""
  (( ${NON_INTERACTIVE:-0} )) || tls_print_tradeoff
  tls_prompt_value TLS_VALIDATION "Validation method (dns, http or tlsalpn)" "dns"
  if [[ "${TLS_VALIDATION}" == dns ]]; then
    tls_prompt_value ACME_DNS_PROVIDER "DNS provider (cloudflare or rfc2136)" "cloudflare"
    if (( ${NON_INTERACTIVE:-0} )); then ACME_DNS_PROVIDER="${ACME_DNS_PROVIDER:-cloudflare}"; fi
    # The operator creates the file; the installer only checks it. Print the
    # exact command so the token never has to touch an argument or the history.
    if [[ -z "${HYBRID_AI_TLS_TOKEN_FILE:-}" ]] && ! (( ${NON_INTERACTIVE:-0} )); then
      cat <<EOF

    The installer never asks for the token itself, only for the file that holds it.
    Create it first, root-owned and 0600, then enter its path:

      sudo install -d -m 0700 -o root -g root ${TLS_TOKEN_DIR}
      sudo install -m 0600 -o root -g root /dev/null $(tls_default_token_path)
      sudoedit $(tls_default_token_path)     # or pipe it from your password manager

EOF
    fi
    tls_prompt_value HYBRID_AI_TLS_TOKEN_FILE \
      "Provider credential FILE path -- the token itself, never pasted here" \
      "$(tls_default_token_path)"
  fi
  tls_prompt_ca
  tls_validate_settings
  TLS_ENABLED="yes"
  tls__ok "TLS enabled for ${TLS_DOMAIN} via $(tls_ca_label "${TLS_CA_URL}") ($( [[ "${TLS_VALIDATION}" == dns ]] && printf 'DNS-01, %s' "${ACME_DNS_PROVIDER}" || printf '%s-01' "${TLS_VALIDATION}" ))."
}

# ---------------------------------------------------------------------------
# Section 8.3/8.4 -- managed-region rendering.
#
# A template marks one managed region per insertion point:
#   #@region NAME   start of the region
#   #@on            lines kept when TLS is enabled
#   #@off           lines kept when TLS is disabled
#   #@end           end of the region
# Marker lines are never written to the output. The rendered file is produced
# from the template alone, so a re-run replaces the file rather than appending
# to it, and no old region can survive.
# ---------------------------------------------------------------------------
tls_render_template() {  # TEMPLATE VARIANTS
  local template="$1" variants="$2"
  awk -v vars="$variants" '
    BEGIN { n = split(vars, v, " "); for (i = 1; i <= n; i++) want[v[i]] = 1 }
    {
      trimmed = $0
      sub(/^[ \t]+/, "", trimmed)
    }
    trimmed ~ /^#@region([ \t]|$)/ {
      if (in_region) { print "tls.sh: nested #@region in " FILENAME > "/dev/stderr"; exit 2 }
      in_region = 1; emit = 1; next
    }
    in_region && trimmed == "#@end" { in_region = 0; emit = 1; next }
    in_region && trimmed ~ /^#@[a-z]+$/ {
      emit = ((substr(trimmed, 3)) in want)
      next
    }
    in_region && !emit { next }
    { print }
  ' "$template"
}

# The variant names enabled for this run: one for TLS off, two for TLS on.
tls_variants() {
  local variants
  if tls_is_on; then
    if [[ "${TLS_VALIDATION:-dns}" == dns ]]; then
      variants="on dns"
    else
      variants="on"
    fi
  else
    variants="off"
  fi
  # The (auth) snippet is imported only by the HTTPS sites. With TLS off there
  # are no HTTPS sites, so the snippet would be dead config that real Caddy
  # rejects (it parses the top-level `forward_auth` directive as a site address).
  # Suppress it: a TLS-off render is byte-identical to the auth-off render no
  # matter what AUTH_ENABLED says.
  if tls_is_on && tls_auth_is_on; then
    variants="${variants} auth"
  fi
  printf '%s\n' "$variants"
}

# Replaces the allowlisted placeholders. Values are built only from validated
# input, never from free text handed in by the operator.
tls_substitute() {  # stdin -> stdout
  awk -v secret="${TLS_RENDER_SECRET_NAME:-}" -v solver="${TLS_RENDER_SOLVER:-}" \
      -v auto_https="${ACME_AUTO_HTTPS:-disable_redirects}" '
    function swap(line, token, value,   out, i, len) {
      out = ""; len = length(token)
      while ((i = index(line, token)) > 0) {
        out = out substr(line, 1, i - 1) value
        line = substr(line, i + len)
      }
      return out line
    }
    { print swap(swap(swap($0, "%TLS_SECRET_NAME%", secret), "%TLS_SOLVER_BLOCK%", solver), "{$ACME_AUTO_HTTPS:disable_redirects}", auto_https) }
  '
}

# RFC2136 values are interpolated into the rendered Caddyfile, so a newline plus
# `}` would inject an arbitrary directive (for example `admin`). Both inputs are
# validated BEFORE any interpolation, and no message echoes the secret value.
tls_validate_rfc2136_key_name() {  # VALUE
  local v="$1"
  [[ $v =~ ^[A-Za-z0-9._-]+$ ]] || tls__die "RFC2136_KEY_NAME must contain only letters, digits, '.', '_' or '-' (an RFC2136 TSIG key name). Remove whitespace, braces and control characters from RFC2136_KEY_NAME in ${ENV_FILE} and re-run."
}

tls_validate_rfc2136_server() {  # VALUE
  local v="$1"
  if [[ $v =~ [[:space:][:cntrl:]] || $v == *"{"* || $v == *"}"* ]]; then
    tls__die "RFC2136_SERVER must not contain whitespace, braces or control characters. Set RFC2136_SERVER in ${ENV_FILE} to the authoritative nameserver as host or host:port and re-run."
  fi
  [[ $v =~ ^([A-Za-z0-9.-]+|\[[0-9A-Fa-f:.]+\])(:[0-9]{1,5})?$ ]] || tls__die "RFC2136_SERVER must be a hostname or IP address with an optional :port (for example ns1.example.com:53). Fix RFC2136_SERVER in ${ENV_FILE} and re-run."
}

tls_solver_block() {
  local provider="$1" secret="$2"
  if [[ "${TLS_VALIDATION:-dns}" != dns ]]; then
    # HTTP-01 and TLS-ALPN-01 need no credential: Caddy answers the challenge
    # itself on the published port. A bare `tls` keeps the snippet importable.
    printf '\t# %s-01: no DNS credential, so Caddy answers the challenge on the\n\t# published port. Nothing to configure here.\n\ttls\n' \
      "$(printf '%s' "${TLS_VALIDATION}" | tr '[:lower:]' '[:upper:]')"
    return 0
  fi
  case "$provider" in
    rfc2136)
      printf '\ttls {\n\t\tdns rfc2136 {\n\t\t\tkey_name %s\n\t\t\tkey_alg hmac-sha512\n\t\t\tkey_secret {file./run/secrets/%s}\n\t\t\tserver %s\n\t\t\tzone %s\n\t\t}\n\t}\n' \
        "${RFC2136_KEY_NAME}" "$secret" "${RFC2136_SERVER}" "${TLS_DOMAIN}"
      ;;
    *)
      printf '\t# One DNS-01 challenge solves both the apex and the wildcard.\n\ttls {\n\t\tdns cloudflare {file./run/secrets/%s}\n\t\tpropagation_timeout 120s\n\t\tpropagation_delay 10s\n\t\tresolvers 1.1.1.1 1.0.0.1\n\t}\n' "$secret"
      ;;
  esac
}

tls_prepare_render_values() {  # VARIANTS
  local variants="$1"
  TLS_RENDER_SECRET_NAME=""
  TLS_RENDER_SOLVER=""
  [[ " $variants " == *" on "* ]] || return 0
  # The renderer owns this value too, so a render that did not go through
  # tls_validate_settings (the test harness, --dry-run) still emits a Caddyfile
  # that keeps certificate management.
  export ACME_AUTO_HTTPS="disable_redirects"
  if [[ "${TLS_VALIDATION:-dns}" == dns ]]; then
    if [[ "${ACME_DNS_PROVIDER:-cloudflare}" == rfc2136 ]]; then
      [[ -n "${RFC2136_KEY_NAME:-}" ]] || tls__die "ACME_DNS_PROVIDER=rfc2136 needs RFC2136_KEY_NAME (the TSIG key name) in ${ENV_FILE}."
      [[ -n "${RFC2136_SERVER:-}" ]] || tls__die "ACME_DNS_PROVIDER=rfc2136 needs RFC2136_SERVER (the authoritative nameserver, host:port) in ${ENV_FILE}."
      tls_validate_rfc2136_key_name "${RFC2136_KEY_NAME}"
      tls_validate_rfc2136_server "${RFC2136_SERVER}"
    fi
    TLS_RENDER_SECRET_NAME="$(tls_secret_name "${ACME_DNS_PROVIDER:-cloudflare}")"
  fi
  TLS_RENDER_SOLVER="$(tls_solver_block "${ACME_DNS_PROVIDER:-cloudflare}" "${TLS_RENDER_SECRET_NAME}")"
}

tls_render_to_file() {  # TEMPLATE VARIANTS OUTFILE
  local template="$1" variants="$2" out="$3"
  [[ -f $template ]] || tls__die "Missing template: ${template}"
  if ! tls_render_template "$template" "$variants" | tls_substitute > "$out"; then
    rm -f -- "$out"
    tls__die "Rendering ${template} failed."
  fi
  chmod 0644 "$out"
}

# ---------------------------------------------------------------------------
# Validation of the rendered artefacts. Missing tools are reported as a skip,
# never as a pass.
# ---------------------------------------------------------------------------
tls__docker_ready() {
  command -v docker >/dev/null 2>&1 || return 1
  docker info >/dev/null 2>&1 || return 1
  return 0
}

# True when the rendered Caddyfile carries the DNS-01 solver, i.e. a
# `dns cloudflare ...` / `dns rfc2136 ...` line inside the proxy's tls block.
# Read from the file, not from TLS_VALIDATION, so a temp or --dry-run render is
# classified by its own content.
tls__caddyfile_uses_dns_solver() {  # FILE
  grep -Eq '^[[:space:]]*dns[[:space:]]+(cloudflare|rfc2136)([[:space:]]|$)' "$1"
}

# The image the validator must run: the DNS-capable one for a DNS-01 render,
# the stock tag otherwise.
tls_validate_image_for() {  # FILE
  if tls__caddyfile_uses_dns_solver "$1"; then
    printf '%s\n' "${CADDY_VALIDATE_IMAGE:-${CADDY_IMAGE:-$TLS_DNS_VALIDATE_IMAGE_DEFAULT}}"
  else
    printf '%s\n' "${CADDY_VALIDATE_IMAGE:-$TLS_STOCK_VALIDATE_IMAGE}"
  fi
}

# Build the DNS-capable Caddy image before it is validated against. The proxy
# image is otherwise first built by STEP 9 `compose up`, which is AFTER the
# render+validate gate, so on first enablement the validator would have no
# image to run. Idempotent: an unchanged caddy/Dockerfile is a cache hit.
# Returns 3, like the other validation helpers, when docker is unavailable.
tls_build_validate_image() {  # [RENDERED_FILE]
  tls_is_on || return 0
  tls__caddyfile_uses_dns_solver "${1:-${APP_DIR}/status/Caddyfile}" || return 0
  # An explicit CADDY_VALIDATE_IMAGE is the operator's own image; it is not
  # ours to build.
  [[ -z "${CADDY_VALIDATE_IMAGE:-}" ]] || return 0
  if ! tls__docker_ready; then
    printf '[skip] Caddy image build for validation (docker unavailable)\n'
    return 3
  fi
  local image
  image="$(tls_validate_image_for "${1:-${APP_DIR}/status/Caddyfile}")"
  local context="${APP_DIR}/caddy"
  [[ -f "${context}/Dockerfile" ]] || tls__die "Missing ${context}/Dockerfile: cannot build ${image} to validate the DNS-01 render."
  if ! docker build -t "$image" "$context"; then
    tls__die "Building ${image} from ${context} failed. The previous files are unchanged."
  fi
  return 0
}

tls_validate_compose_file() {  # FILE [ENVFILE]
  # Default to the RESOLVED STACK env file when no explicit file was given:
  # an --env-file consumer must hand compose the 0600 secrets file, never the
  # 0644 layout file.
  local file="$1" envfile="${2:-${HYBRID_AI_STACK_ENV_FILE:-${ENV_FILE:-}}}"
  if ! command -v docker >/dev/null 2>&1; then
    printf '[skip] compose validation of %s (docker unavailable)\n' "$file"
    return 3
  fi
  if ! docker compose version >/dev/null 2>&1; then
    printf '[skip] compose validation of %s (docker unavailable)\n' "$file"
    return 3
  fi
  if ! docker info >/dev/null 2>&1; then
    printf '[skip] compose validation of %s (docker unavailable)\n' "$file"
    return 3
  fi
  # --project-directory pins relative paths (./status/Caddyfile, ./caddy) to the
  # repo even when the file being validated is a temporary copy elsewhere.
  local project_dir="${APP_DIR:-$(dirname -- "$file")}"
  if [[ -n $envfile && -f $envfile ]]; then
    docker compose --project-directory "$project_dir" -f "$file"       --env-file "$envfile" config -q
  else
    docker compose --project-directory "$project_dir" -f "$file" config -q
  fi
}

# Fail closed unless the token file can be mounted into the validation
# container. Existence, type, readability and length only: the credential itself
# is never read into a message, a log line or an argv.
tls__validate_token_for_mount() {
  local f="${HYBRID_AI_TLS_TOKEN_FILE:-}" size
  [[ -n $f ]] || tls__die "HYBRID_AI_TLS_TOKEN_FILE is empty: the DNS-01 render cannot be validated without its token file. Fix: set HYBRID_AI_TLS_TOKEN_FILE in ${ENV_FILE:-the stack .env} to the token path (for example ${TLS_TOKEN_DIR}/cloudflare_dns_token), or pass --tls-token-file <path>."
  if [[ ! -e $f ]]; then
    tls__die "HYBRID_AI_TLS_TOKEN_FILE '${f}' does not exist, so the DNS-01 render cannot be validated. Fix: sudo install -d -m 0700 -o root -g root $(dirname -- "$f") && sudo install -m 0600 -o root -g root /dev/null ${f} && then write the token into that file with an editor or a pipe (never as a shell argument)."
  fi
  if [[ ! -f $f ]]; then
    tls__die "HYBRID_AI_TLS_TOKEN_FILE '${f}' is not a regular file, so it cannot be mounted for validation. Fix: sudo install -m 0600 -o root -g root /dev/null ${f} && then write the token into it with an editor or a pipe."
  fi
  if [[ ! -r $f ]]; then
    tls__die "HYBRID_AI_TLS_TOKEN_FILE '${f}' is not readable, so it cannot be mounted for validation. Fix: sudo chmod 600 ${f} && sudo chown root:root ${f}"
  fi
  size="$(wc -c < "$f" 2>/dev/null || printf '0')"
  size="${size//[[:space:]]/}"
  if [[ -z $size || $size == 0 ]]; then
    tls__die "HYBRID_AI_TLS_TOKEN_FILE '${f}' is empty (0 bytes), so the DNS-01 solver would be rejected as an invalid token. Fix: write the token into ${f} with an editor or a pipe (never as a shell argument), then re-run."
  fi
}

tls_validate_caddyfile() {  # FILE
  # The rendered TLS Caddyfile keeps its runtime placeholders
  # ({$ACME_EMAIL}, {$ACME_CA}, {$TLS_DOMAIN}, {$LOCAL_DOMAIN}) because the
  # proxy's compose `environment:` block supplies them at container start. The
  # validator must see the same values, or the placeholders expand empty and
  # Caddy rejects the file before it reaches the stack.
  local file="$1" dns=0
  tls__caddyfile_uses_dns_solver "$file" && dns=1
  local -a envs=(
    "ACME_EMAIL=${ACME_EMAIL:-}"
    "TLS_DOMAIN=${TLS_DOMAIN:-}"
    "ACME_CA=${TLS_CA_URL:-${ACME_CA:-}}"
    "ACME_AUTO_HTTPS=${ACME_AUTO_HTTPS:-disable_redirects}"
    "LOCAL_DOMAIN=${LOCAL_DOMAIN:-}"
    # The auth-gated render no longer carries the credentials: the (auth)
    # snippet is `forward_auth auth:8080` and the auth service reads its own
    # environment. So there is nothing here to validate empty; the fail-closed
    # control moved to the installer (install.sh -> tls_auth_fail_closed, which
    # rejects an empty user, hash or cookie secret before any render).
  )
  # A DNS-01 render must be validated in a container: `caddy validate`
  # provisions the TLS app and the solver reads its credential from a file, and
  # a bare host caddy cannot be given that file.
  local -a token_mount=()
  if (( dns )); then
    if ! tls__docker_ready; then
      printf '[skip] Caddyfile validation of %s: docker is unavailable, and a bare host caddy cannot be given the DNS-01 token (it must be mounted into the container), so the render was NOT validated.\n' "$file"
      return 3
    fi
    tls__validate_token_for_mount
    token_mount=(
      -v "${HYBRID_AI_TLS_TOKEN_FILE}:/run/secrets/${TLS_RENDER_SECRET_NAME:-$(tls_secret_name "${ACME_DNS_PROVIDER:-cloudflare}")}:ro"
    )
  elif command -v caddy >/dev/null 2>&1; then
    # Plain shell variables that were never exported: export them for the
    # validator only, in a subshell, so the caller's environment is untouched.
    (
      local e
      for e in "${envs[@]}"; do export "${e?}"; done
      caddy validate --adapter caddyfile --config "$file"
    )
    return
  fi
  if tls__docker_ready; then
    local -a docker_env=()
    local e
    for e in "${envs[@]}"; do docker_env+=(-e "$e"); done
    docker run --rm --network none --entrypoint caddy \
      "${docker_env[@]}" \
      -v "${file}:/etc/caddy/Caddyfile:ro" ${token_mount[@]+"${token_mount[@]}"} \
      "$(tls_validate_image_for "$file")" \
      validate --adapter caddyfile --config /etc/caddy/Caddyfile
    return
  fi
  printf '[skip] Caddyfile validation of %s (caddy unavailable)\n' "$file"
  return 3
}

# ---------------------------------------------------------------------------
# Render both managed files, validate, then move into place atomically.
# ---------------------------------------------------------------------------
tls_render_and_install() {
  local variant variants caddy_dest compose_dest caddy_tmp compose_tmp
  if tls_is_on; then variant="on"; else variant="off"; fi
  variants="$(tls_variants)"
  tls_prepare_render_values "$variants"

  caddy_dest="${APP_DIR}/status/Caddyfile"
  compose_dest="${APP_DIR}/docker-compose.yml"
  caddy_tmp="$(mktemp "${caddy_dest}.XXXXXX")"
  compose_tmp="$(mktemp "${compose_dest}.XXXXXX")"

  tls_render_to_file "${APP_DIR}/status/Caddyfile.tmpl" "$variants" "$caddy_tmp"
  tls_render_to_file "${APP_DIR}/docker-compose.yml.tmpl" "$variants" "$compose_tmp"

  # Build the DNS-capable image BEFORE the render is validated against it: that
  # image otherwise does not exist until STEP 9 `compose up`. A build failure
  # dies here, while both files are still untouched.
  local brc=0
  tls_build_validate_image "$caddy_tmp" || brc=$?
  if (( brc == 3 )); then
    tls__warn "docker is unavailable: the Caddy validation image was NOT built."
  fi

  local rc=0
  tls_validate_compose_file "$compose_tmp" || rc=$?
  if (( rc == 3 )); then
    tls__warn "docker is unavailable: the rendered docker-compose.yml was NOT validated."
  elif (( rc != 0 )); then
    rm -f -- "$caddy_tmp" "$compose_tmp"
    tls__die "The rendered docker-compose.yml failed validation. The previous file is unchanged."
  fi
  rc=0
  tls_validate_caddyfile "$caddy_tmp" || rc=$?
  if (( rc == 3 )); then
    tls__warn "caddy is unavailable: the rendered status/Caddyfile was NOT validated."
  elif (( rc != 0 )); then
    rm -f -- "$caddy_tmp" "$compose_tmp"
    tls__die "The rendered Caddyfile failed validation. The previous file is unchanged."
  fi

  # Keep the file modes of the files being replaced: mktemp creates 0600.
  if [[ -e $caddy_dest ]]; then chmod --reference="$caddy_dest" "$caddy_tmp"; else chmod 0644 "$caddy_tmp"; fi
  if [[ -e $compose_dest ]]; then chmod --reference="$compose_dest" "$compose_tmp"; else chmod 0644 "$compose_tmp"; fi
  mv -f -- "$caddy_tmp" "$caddy_dest"
  mv -f -- "$compose_tmp" "$compose_dest"
  tls__ok "status/Caddyfile rendered (TLS ${variant})."
  tls__ok "docker-compose.yml rendered (TLS ${variant})."
  tls_print_ca_caution
}

# ---------------------------------------------------------------------------
# Section 8.2 -- --dry-run. Prints the files it would write and a unified diff
# of the two managed files. It writes no host file. Its ONE side effect is the
# `docker build` of the DNS-capable validation image, recorded at approval: a
# Docker image is build cache, not host state, and validating the render is the
# dry run's whole value.
# ---------------------------------------------------------------------------
tls_dry_run() {
  local variant variants caddy_tmp compose_tmp env_tmp
  if tls_is_on; then variant="on"; else variant="off"; fi
  variants="$(tls_variants)"
  tls_prepare_render_values "$variants"

  printf '[dry-run] TLS is %s.\n' "$variant"
  printf '[dry-run] would write: %s\n' "$ENV_FILE"
  printf '[dry-run] would write: %s/status/Caddyfile\n' "$APP_DIR"
  printf '[dry-run] would write: %s/docker-compose.yml\n' "$APP_DIR"

  caddy_tmp="$(mktemp)"
  compose_tmp="$(mktemp)"
  tls_render_to_file "${APP_DIR}/status/Caddyfile.tmpl" "$variants" "$caddy_tmp"
  tls_render_to_file "${APP_DIR}/docker-compose.yml.tmpl" "$variants" "$compose_tmp"

  tls__diff "${APP_DIR}/status/Caddyfile" "$caddy_tmp"
  tls__diff "${APP_DIR}/docker-compose.yml" "$compose_tmp"

  # A throwaway env file so compose can interpolate: paths, names and public
  # values only. No secret value is ever written here.
  env_tmp="$(mktemp)"
  {
    printf 'LOCAL_DOMAIN=%s\n' "${LOCAL_DOMAIN:-example.invalid}"
    printf 'HYBRID_AI_DATA_DIR=%s\n' "${HYBRID_AI_DATA_DIR:-${APP_DIR}}"
    printf 'HYBRID_AI_LOG_DIR=%s\n' "${HYBRID_AI_LOG_DIR:-${APP_DIR}}"
    printf 'BACKUP_LOG=%s\n' "${BACKUP_LOG:-${HYBRID_AI_LOG_DIR:-${APP_DIR}}/backup.log}"
    printf 'BACKUP_GROUP_GID=%s\n' "${BACKUP_GROUP_GID:-$(id -g 2>/dev/null || printf 1000)}"
    printf 'DOCKER_GID=%s\n' "${DOCKER_GID:-$(getent group docker 2>/dev/null | cut -d: -f3 || printf 999)}"
    printf 'STATUS_UID=%s\n' "${STATUS_UID:-$(id -u 2>/dev/null || printf 1000)}"
    printf 'HYBRID_AI_POST_DEPLOY_VERIFY_LOG=%s\n' "${HYBRID_AI_POST_DEPLOY_VERIFY_LOG:-/var/log/hybrid-ai-post-deploy-verify.log}"
    printf 'HYBRID_AI_TLS_TOKEN_FILE=%s\n' "${HYBRID_AI_TLS_TOKEN_FILE:-/etc/hybrid-ai/acme/cloudflare_dns_token}"
  } > "$env_tmp"

  local rc=0
  tls_validate_compose_file "$compose_tmp" "$env_tmp" || rc=$?
  if (( rc == 3 )); then
    printf '[dry-run] compose validation was NOT run (see the [skip] line above).\n'
  elif (( rc != 0 )); then
    rm -f -- "$caddy_tmp" "$compose_tmp" "$env_tmp"
    tls__die "The rendered docker-compose.yml failed validation."
  fi
  # The dry run's one side effect, and it is deliberate: a DNS-01 render is only
  # validatable with the DNS-capable image, so the image is built here. A Docker
  # image is build cache, not host state, and validating the render is the whole
  # point of the dry run.
  local brc=0
  tls_build_validate_image "$caddy_tmp" || brc=$?
  if (( brc == 0 )); then
    printf '[dry-run] built the validation image: %s\n' "$(tls_validate_image_for "$caddy_tmp")"
  elif (( brc == 3 )); then
    printf '[dry-run] Caddy image build was NOT run (docker unavailable).\n'
  fi
  rc=0
  tls_validate_caddyfile "$caddy_tmp" || rc=$?
  if (( rc == 3 )); then
    printf '[dry-run] Caddyfile validation was NOT run (see the [skip] line above).\n'
  elif (( rc != 0 )); then
    rm -f -- "$caddy_tmp" "$compose_tmp" "$env_tmp"
    tls__die "The rendered Caddyfile failed validation."
  fi

  rm -f -- "$caddy_tmp" "$compose_tmp" "$env_tmp"
  printf '[dry-run] no files were changed.\n'
}

tls__diff() {  # CURRENT RENDERED
  local current="$1" rendered="$2"
  if [[ ! -f $current ]]; then
    diff -u --label "a/${current#"${APP_DIR}"/}" --label "b/${current#"${APP_DIR}"/}" /dev/null "$rendered" || true
    return 0
  fi
  if cmp -s -- "$current" "$rendered"; then
    printf '(no change) %s\n' "$current"
    return 0
  fi
  diff -u --label "a/${current#"${APP_DIR}"/}" --label "b/${current#"${APP_DIR}"/}" "$current" "$rendered" || true
}

# ---------------------------------------------------------------------------
# Print the TLS URLs (section 7.4). install.sh prints the http:// set after
# this, so https comes first and the fallback second.
# ---------------------------------------------------------------------------
tls_print_urls() {
  tls_is_on || return 0
  printf '    Service Hub  : https://%s/hub\n' "${TLS_DOMAIN}"
  printf '    Open WebUI   : https://%s\n' "${TLS_DOMAIN}"
  printf '    Hermes Agent : https://hermes.%s\n' "${TLS_DOMAIN}"
  printf '    Status Page  : https://status.%s\n' "${TLS_DOMAIN}"
  printf '    Ollama API   : https://%s/ollama/\n' "${TLS_DOMAIN}"
  tls_print_ca_caution
}

# B3: a staging certificate is not trusted by any browser. Silence here looked
# like a broken install, so the completion output names the issuer and the fix.
tls_print_ca_caution() {
  tls_is_on || return 0
  local label
  label="$(tls_ca_label "${TLS_CA_URL:-${ACME_CA:-}}")"
  [[ $label == staging ]] || return 0
  printf '\n'
  tls__warn "The certificate is issued by the Let's Encrypt STAGING CA: browsers and clients will report it as untrusted, and it is not valid for public use."
  tls__warn "To switch to production, re-run: ./install.sh --tls-acme-ca production  (or set ACME_CA=production in the stack .env), then re-render with ./install.sh --dry-run --tls-acme-ca production to preview the change."
}

# ---------------------------------------------------------------------------
# Section 8.5, DNS row: warn when the certificate name does not resolve, and
# print the split-horizon lines from section 3.2.
# ---------------------------------------------------------------------------
tls_check_dns() {
  tls_is_on || return 0
  getent hosts "${TLS_DOMAIN}" >/dev/null 2>&1 && return 0
  local ip="${PI_LAN_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
  tls__warn "TLS_DOMAIN '${TLS_DOMAIN}' does not resolve from this host."
  cat <<EOF

  Add the split-horizon rewrite to the Pi-hole host (section 3.2 of
  docs/tls-acme-design.md), then restart the resolver:

    address=/${TLS_DOMAIN}/${ip:-<pi-lan-ip>}
    address=/hermes.${TLS_DOMAIN}/${ip:-<pi-lan-ip>}
    address=/status.${TLS_DOMAIN}/${ip:-<pi-lan-ip>}

    sudo pihole restartdns   # or: sudo systemctl restart pihole-FTL

EOF
}

# ---------------------------------------------------------------------------
# Read only the TLS-related keys from an existing env file. Used by the early
# --dry-run path, which runs before install.sh loads the whole file. Values are
# never printed. The process environment always wins.
# ---------------------------------------------------------------------------
tls_load_env_file_values() {  # FILE
  local file="$1" line key val
  [[ -f $file ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ ^[[:space:]]*# ]] && continue
    [[ $line =~ ^[[:space:]]*$ ]] && continue
    [[ $line =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    key="${BASH_REMATCH[1]}"
    val="${BASH_REMATCH[2]}"
    case "$key" in
      TLS_ENABLED|TLS_DOMAIN|ACME_EMAIL|ACME_CA|TLS_VALIDATION|ACME_DNS_PROVIDER|\
      HYBRID_AI_TLS_TOKEN_FILE|TLS_HOSTS|ACME_AUTO_HTTPS|CADDY_IMAGE|LOCAL_DOMAIN|\
      RFC2136_KEY_NAME|RFC2136_SERVER|AUTH_ENABLED|HYBRID_AI_AUTH_USER|\
      HYBRID_AI_AUTH_HASH|HYBRID_AI_AUTH_COOKIE_SECRET|\
      HYBRID_AI_AUTH_COOKIE_MAX_AGE) ;;
      *) continue ;;
    esac
    [[ -n "${!key:-}" ]] && continue
    val="${val%\"}"; val="${val#\"}"
    val="${val%\'}"; val="${val#\'}"
    printf -v "$key" '%s' "$val"
  done < "$file"
}
