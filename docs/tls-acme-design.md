# TLS termination and ACME design (`jarvis.lan` -> `daemonhub.dev`)

Status: decision document. Later build tasks implement against this text.
Audience: the repo owner, and whoever runs the next build task.

This document decides how the hybrid-ai stack gets trusted HTTPS certificates
for `daemonhub.dev`, how the installer exposes that, how the status app proves a
certificate is healthy, and how the live host migrates from plain HTTP on
`jarvis.lan` without an outage. It is documentation only. It changes no code.

Everything below is grounded in the current repository:

- `status/Caddyfile` -- global `auto_https off` (line 4, TLS-off build only), global `admin off`
  (line 3), the `(trusted_only)` snippet at line 6 and `(secure_headers)` at
  line 11, then exactly three site blocks: `http://status.{$LOCAL_DOMAIN}` (line
  20), `http://hermes.{$LOCAL_DOMAIN}` (line 28) and `http://{$LOCAL_DOMAIN}`
  (line 35). The apex block carries `handle /status*`, `/hub*`, `/health`,
  `handle_path /ollama/*`, `/openwebui*`, `/chat*` and a catch-all.
- `docker-compose.yml` -- `proxy` service at line 349 (`caddy:2.11-alpine`,
  `hybrid-ai-proxy`, `restart: unless-stopped`, `depends_on` open-webui and
  status, `mem_limit: 128m`, `cpus: "0.5"`, publishes `"80:80"` only, mounts
  `./status/Caddyfile:/etc/caddy/Caddyfile:ro` and
  `${HYBRID_AI_DATA_DIR}/caddy:/data`, sets `LOCAL_DOMAIN` and
  `DO_NOT_TRACK`, `security_opt: no-new-privileges:true`, healthcheck probing
  `http://[IP_ADDRESS]:80/status/healthz`, json-file logging with rotation), and
  the `status` service, whose own healthcheck probes
  `http://[IP_ADDRESS]:8088/status/healthz` at line 326.
- `install.sh` -- `prompt_secret LOCAL_DOMAIN` at line 510, the stack env file
  written and `chmod 600` at line 894, the DNS-validation check for
  `$LOCAL_DOMAIN`, `hermes.$LOCAL_DOMAIN` and `status.$LOCAL_DOMAIN` at lines
  1787-1792 (log line 1789, `getent hosts` at 1791), the service-URL block at
  lines 2284-2289, `PI_LAN_IP="$(hostname -I ...)"` at line 1781, and the
  `-h|--help` usage block at the top of the file. Every line number here was
  re-checked with `grep -n` against the tree at `origin/main` after this branch
  was rebased onto it.
- `.env.example` -- `LOCAL_DOMAIN=yourhostname.com`, `HYBRID_AI_DATA_DIR`
  layout settings.
- `status/app.py` -- `GET /status/healthz`, `GET /status/health-summary`,
  `GET /status/api`, `GET /status`, `GET /hub`.
- `docs/` and `REPO_MAP.md` for file-naming conventions.

---

## 0. Decisions at a glance

| # | Decision |
|---|----------|
| D1 | DNS-01 is the installer default validation method. HTTP-01 and TLS-ALPN-01 are opt-in. |
| D2 | First DNS plugin is Cloudflare (`dns.providers.cloudflare`). Second documented provider is RFC 2136 dynamic DNS (`dns.providers.rfc2136`). |
| D3 | The Caddy image is built locally from `caddy/Dockerfile` with `xcaddy`, pinned to `caddy:2.11` base plus pinned plugin versions. A stock `caddy:2.11-alpine` image is never used for TLS. |
| D4 | The DNS API credential is a file, mounted with compose `secrets:` at `/run/secrets/cloudflare_dns_token`, never an env var, never an argument, never in git. |
| D5 | Certificates are issued for the apex and for a wildcard only, via DNS-01. Caddy >= 2.10 prefers the wildcard, so `hermes.` and `status.` reuse it instead of getting their own certificate. |
| D6 | `auto_https off` disables Caddy's certificate management, so it is never rendered. Every TLS-on mode renders `auto_https disable_redirects`, and the explicit `http://` block is the one 308. |
| D7 | HTTP->HTTPS redirects are explicit `http://` site blocks returning 308, keeping `(trusted_only)` on them. |
| D8 | Renewal is Caddy's own. No second issuer, no issuing systemd timer. One systemd timer runs a read-only watchdog. |
| D9 | Certificate health is proven by a live TLS handshake (SNI per hostname), never by reading private keys. |
| D10 | `TLS_ENABLED` defaults to `no`. The installer's existing behaviour is byte-for-byte unchanged while it is `no`. |
| D11 | `jarvis.lan` (`LOCAL_DOMAIN`) is not decommissioned. It stays in the Caddyfile as the fallback. |
| D12 | Staging CA is the default. Production is a deliberate second run. |

### Planning assumptions

Marked so a later reader can challenge them, not left open:

- (Assumption) The public DNS zone `daemonhub.dev` is hosted at Cloudflare and
  the owner holds an account-scoped API token capability. If the zone were
  hosted elsewhere, D2's RFC 2136 path applies instead.
- (Assumption) The Pi sits behind a home router with no inbound port forward on
  80/443, and may additionally be behind CGNAT. This is why DNS-01 is the
  default (section 1).
- (Assumption) Pi-hole is the LAN resolver, so dnsmasq drop-ins under
  `/etc/dnsmasq.d/` are the correct local-resolver surface (section 3).
- (Assumption) The existing install is the one described by `REPO_MAP.md`:
  `LOCAL_DOMAIN=jarvis.lan`, data under `HYBRID_AI_DATA_DIR`, containers
  `ollama`, `open-webui`, `status`, `hybrid-ai-proxy`, `openhands`, `hermes`.
- (Assumption) `openhands` stays loopback-only and gets no public hostname in
  this change. Only `daemonhub.dev`, `hermes.daemonhub.dev` and
  `status.daemonhub.dev` are published.

---

## 1. Validation method comparison and recommendation

### 1.1 What each method proves

| | **DNS-01** | **HTTP-01** | **TLS-ALPN-01** |
|---|---|---|---|
| Proof given to the CA | A TXT record at `_acme-challenge.<name>` containing a key authorisation | A file at `http://<name>/.well-known/acme-challenge/<token>` served on port 80 | A self-signed certificate with the `acme-tls/1` ALPN on port 443 |
| Proves control of | The DNS zone (or the delegated challenge name) | The HTTP endpoint on port 80 | The TLS endpoint on port 443 |
| Wildcard (`*.daemonhub.dev`) | **Yes** | No (CA forbids it) | No (CA forbids it) |
| Host must be internet-reachable | **No** | Yes, on port 80 | Yes, on port 443 |
| Works behind NAT / CGNAT / closed ports | **Yes** | No | No |
| Rate-limit exposure | Same limit as every other type: 5 failed authorizations per account per hostname per hour, DNS-01 included. Less exposed in practice only because propagation failures retry inside Caddy's own window instead of firing a fresh probe; test with the staging CA. | High. Each failed probe counts toward the 5 failures per account per hostname per hour. | High, same as HTTP-01. |
| Propagation wait | Yes. Caddy polls the authoritative nameservers until the TXT is visible. Typical 5-60 s on Cloudflare; up to several minutes on slow providers. Caddy's default bound is generous and the challenge is retried. | None; the CA fetches immediately. | None. |
| Blast radius of the credential | A DNS API token: can mint certificates for **any** name in the zone it can write. It cannot read data or touch the host. | No stored credential at all. | No stored credential at all. |
| Failure modes | Token expired or under-scoped; provider API outage; zone not yet delegated; TXT collisions when two challenges for the same name are in flight (Caddy serialises these). | Port 80 closed by the ISP or the router; CGNAT; captive portal intercepting the probe; a firewall rule blocking the CA's probe ranges; `trusted_only` aborting the probe. | Port 443 closed; an existing proxy answering 443 with the wrong cert; ALPN stripped by a middlebox. |

### 1.2 Recommendation

**Decision: DNS-01 is the installer default, with a Cloudflare API token.**

Justification, in the order that matters for this host:

1. The Pi has no inbound port forward and may be behind CGNAT. HTTP-01 and
   TLS-ALPN-01 both fail outright in that network position; DNS-01 does not
   care where the host is.
2. The owner has said validation will be done by DNS record. DNS-01 is the only
   method that expresses that.
3. One wildcard certificate (`*.daemonhub.dev`) covers every present and future
   service subdomain, so adding `status.`, `hermes.`, or a later `chat.` costs
   no new issuance or installer prompt.
4. The credential is the only cost, and it is a file on the Pi that cannot read
   application data and cannot run anything (section 2.7 quantifies it).

### 1.3 When HTTP-01 or TLS-ALPN-01 is the right choice instead

State this exactly, because the installer prints it:

- **Choose HTTP-01 when** the DNS zone is hosted somewhere with no usable
  provider API (no plugin, no RFC 2136), **and** the host is directly reachable
  on port 80 from the internet (a VPS, a forwarded port, a tunnel that
  terminates port 80).
- **Choose TLS-ALPN-01 when** the host is directly reachable on 443, port 80 is
  unavailable or already owned by something else, and you need per-host
  certificates without a DNS token. It cannot do wildcards, so every hostname
  is a separate authorisation.
- **Choose HTTP-01 or TLS-ALPN-01 over DNS-01 when** policy forbids holding a
  DNS write token at all -- for example a shared zone where a zone-wide DNS
  edit would let a compromise of this host redirect someone else's mail. That
  is a real reason to prefer a reachable host with no DNS credential.

### 1.4 User-facing tradeoff summary (the text the installer prints)

The installer prints this verbatim at first enablement, before the prompt:

```text
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
```

---

## 2. DNS provider integration

### 2.1 First provider: Cloudflare

**Decision: Cloudflare first, because `daemonhub.dev` is already on Cloudflare
(assumption stated in section 0), it has the fastest TXT propagation of the
mainstream providers, and its Caddy module is the most widely deployed.**

Exact Caddy module and directive:

- Caddy module: `dns.providers.cloudflare`
- Go import path: `github.com/caddy-dns/cloudflare`
- Caddyfile syntax:

```caddyfile
tls {
    dns cloudflare {file./run/secrets/cloudflare_dns_token}
    propagation_timeout 120s
    propagation_delay 10s
    resolvers 1.1.1.1 8.8.8.8
}
```

`{file.…}` is a Caddy placeholder that reads the token at request time, so the
value never enters the rendered Caddyfile, the container image, an env var, or
`docker inspect`.

### 2.2 Second provider, documented path: RFC 2136

**Decision: the second supported provider is RFC 2136 dynamic DNS updates, not a
second SaaS API.**

- Caddy module: `dns.providers.rfc2136`
- Go import path: `github.com/caddy-dns/rfc2136`
- Caddyfile syntax:

```caddyfile
tls {
    dns rfc2136 {
        key_name     {$RFC2136_KEY_NAME}
        key_alg      hmac-sha512
        key_secret   {file./run/secrets/rfc2136_key_secret}
        server       {$RFC2136_SERVER}
        zone         {$TLS_DOMAIN}
    }
}
```

Justification: a TSIG key is scoped to a zone by the *server*, not by a web UI,
so "this key may only update `daemonhub.dev`" is enforceable on the DNS side.
It also covers any registrar that offers dynamic updates, which is the common
case for self-hosters who are not on Cloudflare. It is second, not first,
because it needs server-side TSIG configuration that Cloudflare users do not
have to do.

Adding a third provider is a one-line change in the build file plus a new
`--tls-dns-provider` value; it is not specified here because it is not needed.

### 2.3 Baking the module into the image

**The stock `caddy:2.11-alpine` image contains no DNS provider modules.** This is
a hard fact, not a preference: an unbuilt image fails at startup with
`unrecognized directive: dns` and Caddy exits, taking the proxy down.

**Decision: build the image in `caddy/Dockerfile` with `xcaddy`, pinning both the
Caddy version and the plugin versions, and let compose build it via a `build:`
stanza so `docker compose build proxy` and CI exercise the same path.**

New file `caddy/Dockerfile`:

```dockerfile
# syntax=docker/dockerfile:1.7
# Caddy + the ACME DNS provider modules. The stock caddy:2.11-alpine image has
# no DNS providers, and the Caddyfile refuses to load without them.
FROM caddy:2.11-builder-alpine AS builder

ARG CADDY_VERSION=2.11.7
ARG CLOUDFLARE_DNS_VERSION=v0.2.4
ARG RFC2136_DNS_VERSION=v1.0.0

RUN xcaddy build "v${CADDY_VERSION}" \
      --with github.com/caddy-dns/cloudflare@${CLOUDFLARE_DNS_VERSION} \
      --with github.com/caddy-dns/rfc2136@${RFC2136_DNS_VERSION}

FROM caddy:2.11-alpine
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
RUN caddy version && caddy list-modules | grep -E '^dns\.providers\.(cloudflare|rfc2136)$'
```

Compose then uses:

```yaml
  proxy:
    build:
      context: ./caddy
      dockerfile: Dockerfile
    image: ${CADDY_IMAGE:-hybrid-ai-caddy:2.11.7-dns}
```

The `RUN ... caddy list-modules | grep` line is the build-time gate: a missing
module fails the build instead of failing at container start.

Explicit alternative, if a local image build is unacceptable on the Pi: publish
`hybrid-ai-caddy:2.11.7-dns` from CI (`.github/workflows/validate.yml` already
gates the repo) to GHCR and set `CADDY_IMAGE` in `.env` to that digest-pinned
reference. The installer prefers a local build and only sets `CADDY_IMAGE` when
the operator asks for it. Either way the stock image is never used for TLS.

### 2.4 Credential fields per provider

| Provider | Field | Where it comes from | Format |
|---|---|---|---|
| Cloudflare | API token with `Zone:DNS:Edit` and `Zone:Zone:Read`, restricted to zone `daemonhub.dev` | Cloudflare dashboard -> My Profile -> API Tokens -> Create Token -> Edit zone DNS template | 40-character opaque string, no prefix |
| RFC 2136 | `key_name` | TSIG key name configured on the nameserver | FQDN, e.g. `acme-daemonhub` or `acme-daemonhub.example.` |
| RFC 2136 | `key_alg` | Chosen by the operator | `hmac-sha256`, `hmac-sha384`, or `hmac-sha512` (use `hmac-sha512`) |
| RFC 2136 | `key_secret` | Produced by `tsig-keygen` / `dnssec-keygen -a HMAC-SHA512` | Base64 |
| RFC 2136 | `server` | Authoritative nameserver that accepts updates | `host:port`, port defaults to 53 |

### 2.5 Where the token is stored

| Item | Value |
|---|---|
| Path on host | `/etc/hybrid-ai/acme/cloudflare_dns_token` |
| Owner | `root:root` |
| Mode | `0600` (directory `/etc/hybrid-ai/acme` is `0700`) |
| Created by | The operator, with `sudo install -m 0600 -o root -g root /dev/null <path>` then an editor or a pipe from `pass`/1Password CLI. Never `echo` into a shell argument. |
| Path in container | `/run/secrets/cloudflare_dns_token` (compose `secrets:`, file driver) |
| Mode in container | `0444`, on an in-memory mount, visible only inside the `proxy` container |
| Referenced from | `status/Caddyfile` as `{file./run/secrets/cloudflare_dns_token}` |
| Not stored in | git, `.env`, `.env.example`, the image, a Dockerfile `ARG`, an env var, a command line, an install log |
| Overridable path | `HYBRID_AI_TLS_TOKEN_FILE` in `.env` (path only, never the value) |

For RFC 2136, the same rules apply to `/etc/hybrid-ai/acme/rfc2136_key_secret`,
mounted at `/run/secrets/rfc2136_key_secret`.

**The same file is mounted into the validation container.** `caddy validate`
provisions the TLS app, and the rendered solver reads its credential from
`/run/secrets/<name>` by design, so the credential must be present *inside* the
throwaway validator too. The installer therefore mounts
`${HYBRID_AI_TLS_TOKEN_FILE}` read-only at `/run/secrets/<name>` (the same name
the render reads) for the duration of the validation run, under `--network none`.
The validation container is short-lived and reaches no network, so the token
cannot leave the host. It is never copied, printed or passed as a value.

Before that container starts, the validator fails closed when the token file
cannot be presented: the variable is unset or empty, the path does not exist, it
is not a regular file, it is unreadable, or it is empty (0 bytes). Each message
names the path and the fix command and never contains the file's content; only
existence and length are reported. A non-DNS render (http-01, TLS-ALPN-01, or TLS
off) gets no extra mount and no token check: its validation invocation is
unchanged.

### 2.6 Scoping to the minimum

**Decision: the token is restricted to the single zone `daemonhub.dev`, with
`Zone:DNS:Edit` plus `Zone:Zone:Read` and no other permission.** Nothing else is
granted: no `Zone:Zone:Edit`, no `Account:*`, no analytics, no R2, no Workers.

Cloudflare does not offer per-record permissions. A token either may edit DNS in
a zone or may not. The achievable minimum is therefore "one zone, DNS records
only", and this design takes exactly that. To compensate for the missing
record-level limit, `daemonhub.dev` is a dedicated stack zone: it holds only the
records this stack needs, so a zone-wide DNS edit can damage nothing else.

If record-level isolation is ever required, the documented upgrade path is a
CNAME delegation: publish `_acme-challenge.daemonhub.dev` as a CNAME to a
challenge name in a separate small zone, and scope the token to that second zone
only. That path is not built here because it doubles the DNS surface for a risk
already bounded by the dedicated zone.

Verification that the scoping is what was intended. **The token must never
appear in argv or in shell history** (section 8.7 is the governing rule). Read
it into a variable in a root shell with history off, and hand the header to
`curl` on stdin with `-K -`:

```bash
sudo -i
HISTFILE=/dev/null

CF_TOKEN="$(cat /etc/hybrid-ai/acme/cloudflare_dns_token)"

# 1. The token itself is live.
printf 'header = "Authorization: Bearer %s"\n' "$CF_TOKEN" \
  | curl -sS -K - https://api.cloudflare.com/client/v4/user/tokens/verify \
  | jq '.result.status'
# expected: "active"

# 2. Reading the zone we own must succeed.
printf 'header = "Authorization: Bearer %s"\n' "$CF_TOKEN" \
  | curl -sS -K - 'https://api.cloudflare.com/client/v4/zones?name=daemonhub.dev' \
  | jq '.result | length'
# expected: 1

# 3. Any other zone must be refused.
printf 'header = "Authorization: Bearer %s"\n' "$CF_TOKEN" \
  | curl -sS -K - 'https://api.cloudflare.com/client/v4/zones?name=example.com' \
  | jq '.result | length'
# expected: 0

# 4. A write outside the DNS record scope (creating a second zone) must 403.
printf 'header = "Authorization: Bearer %s"\nContent-Type: application/json\n' \
  "$CF_TOKEN" \
  | curl -sS -K - -o /dev/null -w '%{http_code}\n' -X POST \
      --data '{"name":"scope-probe.example.com","account":{"id":"unknown"}}' \
      https://api.cloudflare.com/client/v4/zones
# expected: 403 (or 401)

unset CF_TOKEN
exit
```

Why this form is safe:

- The token is passed to `curl` through a config file on **stdin** (`-K -`), so
  `ps auxww` shows only `curl -sS -K - …` and never the header value.
- `HISTFILE=/dev/null` means no command you type in that shell is written to
  history. The assignment line still expands at run time, not at write time.
- `printf` is a shell builtin here, so the token is not an argument to an
  external `/usr/bin/printf` process either.
- `unset CF_TOKEN` before you exit removes it from the shell's environment.

### 2.7 What an attacker holding the token could and could not do

| Capability | Possible? | Why |
|---|---|---|
| Create, change or delete any DNS record in `daemonhub.dev` | **Yes** | `Zone:DNS:Edit` on the zone. This is the accepted residual risk. |
| Point `*.daemonhub.dev` anywhere, including an attacker's host | **Yes** | Same permission. |
| Obtain a certificate for any name in `daemonhub.dev` | **Yes** | It can satisfy DNS-01 for the zone. |
| Break mail or other records in `daemonhub.dev` | **Yes** | Same permission; mitigated by keeping the zone dedicated to the stack. |
| Read, write or delete records in any other zone | No | Token is zone-scoped; verified by check 3 above. |
| Change nameservers, DNSSEC, or zone settings | No | Needs `Zone:Zone:Edit`. |
| Read Cloudflare account settings, billing, API keys of other tokens | No | Needs `Account:*`. |
| Reach the Pi, read `webui_data`, read the OpenHands credential | No | The token is a DNS credential with no host access. |
| Escalate to a Cloudflare account takeover | No | No account-level permission. |

Mitigations that stay in force: the token lives `0600 root` on the host, is
mounted read-only into one container, Cloudflare audit-log notifications are
enabled for the zone, and the token is rotated by re-running the installer with
a new file (section 8.6).

---

## 3. Split-horizon DNS

**Decision: public authoritative records on Cloudflare, and a local dnsmasq
rewrite on Pi-hole so LAN clients resolve the same names to the internal Pi IP
and never hairpin through the router.**

### 3.1 Public authoritative records (Cloudflare, `daemonhub.dev` zone)

| Name | Type | Value | Proxy status | TTL |
|---|---|---|---|---|
| `daemonhub.dev` | A | the WAN address of the Pi's router, if a port forward exists; otherwise omitted | DNS only | 300 |
| `daemonhub.dev` | AAAA | the corresponding IPv6 address, if any; otherwise omitted | DNS only | 300 |
| `*.daemonhub.dev` | A | same as apex | DNS only | 300 |
| `_acme-challenge.daemonhub.dev` | TXT | written by Caddy per issuance | DNS only | 120 (Caddy manages) |

Key points:

- Records are **DNS only** (grey cloud). Cloudflare's orange-cloud proxy
  terminates TLS itself and would break the Pi's own certificate, the
  `trusted_only` IP allowlist, and the WebSocket traffic to Open WebUI.
- If there is no port forward (the default assumption, section 0), the apex and
  wildcard A records may be omitted entirely: DNS-01 does not need them, and
  `_acme-challenge` TXT alone is enough to issue. The only records then are the
  TXT records Caddy writes and whatever the owner wants for reference.
- A wildcard A record plus no apex A record is legal and common.

### 3.2 Local resolver rewrite (Pi-hole host, not this repo)

**These files are host state. They are not repo files and must not be committed.**

Pi-hole's embedded dnsmasq reads every `*.conf` in `/etc/dnsmasq.d/`:

```bash
sudo tee /etc/dnsmasq.d/05-hybrid-ai.conf >/dev/null <<'EOF'
# hybrid-ai :: split-horizon rewrite for daemonhub.dev.
# LAN clients get the Pi's LAN address; public clients get whatever the
# authoritative zone says. Managed by hand; not part of the hybrid-ai repo.

# Internal address of this Pi as seen from the LAN.
address=/daemonhub.dev/192.168.1.50

# Explicit per-service entries. They are redundant with the wildcard above but
# are kept so a single service can be pointed somewhere else (for example a
# test host) without touching the wildcard line.
address=/hermes.daemonhub.dev/192.168.1.50
address=/status.daemonhub.dev/192.168.1.50

# The Pi's loopback name, unchanged from today.
address=/jarvis.lan/192.168.1.50

# Local domain search, so `ping hermes` works on the LAN.
local=/daemonhub.dev/
domain=daemonhub.dev
EOF

sudo pihole restartdns
```

Notes on the exact semantics:

- `address=/daemonhub.dev/<ip>` is dnsmasq's wildcard form: it answers the apex
  **and every subdomain** under `daemonhub.dev` with `<ip>`, at any depth. There
  is exactly one such line in the drop-in; the per-service lines are
  documentation, not necessity.
- dnsmasq has no `*.` glob syntax in `address=`; the `/<domain>/` form is the
  wildcard. Do not write `address=/*.daemonhub.dev/…`; that matches a literal
  `*`.
- `local=/daemonhub.dev/` makes dnsmasq authoritative for the suffix so
  upstream servers are never asked.
- Do not add `server=/daemonhub.dev/[IP_ADDRESS]` alongside `address=`, because
  a `server=` for the same suffix would answer those queries and the split
  horizon silently breaks.
- Load order does not matter here. Files are read in lexical order, so Pi-hole's
  own `01-pihole.conf` loads **before** `05-hybrid-ai.conf`, but the `address=`
  entries in this drop-in name distinct domains and conflict with nothing
  Pi-hole writes.
- Verify the drop-in before restarting: `sudo dnsmasq --test` passes, and
  `grep -c '^address=/daemonhub.dev/' /etc/dnsmasq.d/05-hybrid-ai.conf`
  returns `1`.
- Replace `192.168.1.50` with the Pi's real LAN address
  (`hostname -I | awk '{print $1}'`, the same value `install.sh` derives at
  line 1781).

### 3.3 Verification

From a LAN client (a laptop on the same network):

```bash
dig +short hermes.daemonhub.dev @192.168.1.50      # -> 192.168.1.50
dig +short status.daemonhub.dev @192.168.1.50      # -> 192.168.1.50
dig +short daemonhub.dev @192.168.1.50             # -> 192.168.1.50
getent hosts daemonhub.dev                          # -> 192.168.1.50 (uses the client's resolver)
curl -sSI https://status.daemonhub.dev/status/healthz | head -1   # HTTP/2 200
```

From the Pi itself:

```bash
dig +short daemonhub.dev @127.0.0.1                 # -> 192.168.1.50 via Pi-hole
getent hosts hermes.daemonhub.dev                   # -> 192.168.1.50
```

`getent hosts` is what `install.sh` already uses for its subdomain check at line
1791, so the same code path validates the new names.

### 3.4 A client that uses public DNS

A LAN client configured with `8.8.8.8` (or any resolver that is not the Pi-hole)
gets the **public** answer. With no port forward, that is either NXDOMAIN or an
address that cannot be reached -- the classic split-horizon failure. It does not
break the Pi, and it does not break certificate issuance; it only means that
client cannot reach the services until it uses the LAN resolver.

Documented consequences:

- Hairpinning is avoided for correctly configured clients. A client on public DNS
  takes the WAN path, which either works (port forward present) or fails fast.
- Certificate validation is unaffected either way: the certificate is for the
  name, and the name resolves consistently from each resolver's point of view.
- The installer warns when `getent hosts` disagrees with the expected internal
  IP, and names the dnsmasq drop-in as the fix.

---

## 4. Caddy as TLS terminator

### 4.1 Proposed diff to `status/Caddyfile`

Neither existing snippet changes. `(trusted_only)` and `(secure_headers)` appear
below as unchanged context lines with the same tabs and the same text they carry
in `status/Caddyfile` -- `X-Frame-Options DENY`, `Referrer-Policy no-referrer`
and the `-Server` strip included. HSTS is **additive**: it goes in a new
`(hsts)` snippet and is never folded into `(secure_headers)`. Every HTTPS site
imports `trusted_only` exactly as the HTTP sites do today, from one place per
site: `@untrusted` is a named matcher and may be defined only once per site, so
the apex block imports it inside each protected handle and never at site level.

No assumption is needed here any more: `origin/main` carries `(secure_headers)`
at `status/Caddyfile:11` with exactly the text shown below, so the snippet is
context in this diff and not a proposed addition. The build task must leave it
alone.

```diff
 {
-	auto_https off
+	# DNS-01 does not need Caddy's automatic HTTP challenge listener or its
+	# automatic redirects: both are explicit below, so the behaviour is
+	# visible in this file. HTTP-01 mode is the one exception; see
+	# docs/tls-acme-design.md section 4.5.
+	auto_https {$ACME_AUTO_HTTPS:disable_redirects}
-	admin off
+	# Loopback INSIDE the container only, never published. This is what lets
+	# `caddy reload` apply a config change without a restart, which would
+	# drop in-flight WebSocket streams. The non-TLS build keeps `admin off`.
+	admin localhost:2019
+	email {$ACME_EMAIL}
+	acme_ca {$ACME_CA}
+	# Keep logs where the container's log collector already looks.
+	log {
+		output stdout
+		format json
+	}
 }

 (trusted_only) {
	@untrusted not remote_ip 127.0.0.1/8 ::1 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 fd7a:115c:a1e0::/48
	abort @untrusted
 }

 (secure_headers) {
	header {
		X-Content-Type-Options nosniff
		X-Frame-Options DENY
		Referrer-Policy no-referrer
		-Server
	}
 }

 http://status.{$LOCAL_DOMAIN} {
 	import trusted_only
 	import secure_headers
 
 	redir / /status 302
 	reverse_proxy status:8088
 }
 
 http://hermes.{$LOCAL_DOMAIN} {
 	import trusted_only
 	import secure_headers
 
 	reverse_proxy hermes:8501
 }
 
 http://{$LOCAL_DOMAIN} {
 	# Both snippets must be imported inside each handle: Caddy runs a matching
 	# handle before the site-level directives, so a site-level import alone
 	# would be bypassed and would leave these routes unprotected and unstamped.
 	# trusted_only guards the sensitive routes; secure_headers applies the
 	# uniform response headers (and removes Server) on every route, including
 	# the open aliases and the catch-all.
 	handle /status* {
 		import trusted_only
 		import secure_headers
 		reverse_proxy status:8088
 	}
 
 	handle /hub* {
 		import trusted_only
 		import secure_headers
 		reverse_proxy status:8088
 	}
 
 	handle /health {
 		import secure_headers
 		rewrite * /status/health-summary
 		reverse_proxy status:8088
 	}
 
 	handle_path /ollama/* {
 		import trusted_only
 		import secure_headers
 		reverse_proxy ollama:11434
 	}
 
 	# Friendly aliases restored after the Caddyfile refactor. The target is the
 	# site root because Open WebUI is served at the root (there is no /app/
 	# prefix). Deep links and query strings are preserved. These handles do not
 	# import trusted_only: their only target is the open catch-all below, which
 	# has its own login. See status/README.md.
 	#
 	# secure_headers is imported inside each route block so the header handler
 	# runs before the redirect, and so it cannot be reordered out of the block.
 	handle /openwebui* {
 		route {
 			import secure_headers
 			uri strip_prefix /openwebui
 			redir * {uri} 302
 		}
 	}
 
 	handle /chat* {
 		route {
 			import secure_headers
 			uri strip_prefix /chat
 			redir * {uri} 302
 		}
 	}
 
 	handle {
 		import secure_headers
 		reverse_proxy open-webui:8080
 	}
 }
 

+(hsts) {
+	header Strict-Transport-Security "max-age=31536000; includeSubDomains"
+}
+
+(tls_dns) {
+	# One DNS-01 challenge solves both the apex and the wildcard.
+	tls {
+		dns cloudflare {file./run/secrets/cloudflare_dns_token}
+		propagation_timeout 120s
+		propagation_delay 10s
+		resolvers 1.1.1.1 8.8.8.8
+	}
+}
+
+# --- HTTPS: daemonhub.dev ------------------------------------------------
+https://{$TLS_DOMAIN} {
+	# Same route map as the http:// site, so the snippets are placed the same way.
+	# trusted_only is imported inside each protected handle only, never at site
+	# level: it defines the named matcher @untrusted, and a named matcher may be
+	# defined once per site. There is also nothing to enforce at site level, since
+	# Caddy runs a matching handle before the site-level directives. This matches
+	# the non-TLS apex block. Adding TLS changes no route and no allowlist; it only
+	# changes the scheme and adds HSTS.
+	import secure_headers
+	import hsts
+	import tls_dns
+
+	handle /status* {
+		import trusted_only
+		import secure_headers
+		reverse_proxy status:8088
+	}
+	handle /hub* {
+		import trusted_only
+		import secure_headers
+		reverse_proxy status:8088
+	}
+	handle /health {
+		import secure_headers
+		rewrite * /status/health-summary
+		reverse_proxy status:8088
+	}
+	handle_path /ollama/* {
+		import trusted_only
+		import secure_headers
+		reverse_proxy ollama:11434
+	}
+	handle /openwebui* {
+		route {
+			import secure_headers
+			uri strip_prefix /openwebui
+			redir * {uri} 302
+		}
+	}
+	handle /chat* {
+		route {
+			import secure_headers
+			uri strip_prefix /chat
+			redir * {uri} 302
+		}
+	}
+	handle {
+		import secure_headers
+		reverse_proxy open-webui:8080
+	}
+}
+
+https://hermes.{$TLS_DOMAIN} {
+	import trusted_only
+	import secure_headers
+	import hsts
+	import tls_dns
+
+	reverse_proxy hermes:8501
+}
+
+https://status.{$TLS_DOMAIN} {
+	import trusted_only
+	import secure_headers
+	import hsts
+	import tls_dns
+
+	redir / /status 302
+	reverse_proxy status:8088
+}
+
+https://*.{$TLS_DOMAIN} {
+	# Wildcard catch-all. Unknown subdomain gets a bare 404, so a probe
+	# cannot enumerate services. No (hsts): HSTS is only for the three
+	# named hosts above.
+	import trusted_only
+	import secure_headers
+	import tls_dns
+
+	respond 404
+}
+
+# --- HTTP -> HTTPS redirect (port 80 stays open for redirect + HTTP-01) ---
+http://{$TLS_DOMAIN}, http://*.{$TLS_DOMAIN} {
+	import trusted_only
+	redir https://{host}{uri} 308
+}
```

Notes on the diff, all deliberate:

- **The HTTPS blocks mirror the current `http://` route map exactly.** Same
  handles, same order, same snippet placement; only the scheme changes and
  `(hsts)` is added. `(trusted_only)` is imported **inside each protected
  `handle` only**, exactly like the non-TLS apex block: it defines the named
  matcher `@untrusted`, and Caddy allows a named matcher to be defined once per
  site, so a site-level import alongside the per-handle imports is rejected
  outright (`matcher is defined more than once`). Nothing is lost: a matching
  `handle` runs before site-level directives, so a site-level import never
  enforced anything. The rule for every named-matcher snippet (`trusted_only`,
  `auth`): import it once per site -- at site level only when the block has no
  `handle`/`handle_path` children, otherwise inside each handle.
- **Two handles deliberately do not import `(trusted_only)`, and the HTTPS
  blocks keep that.** `handle /health` carries only `(secure_headers)` and
  `handle /openwebui*` / `handle /chat*` carry only `(secure_headers)` inside a
  `route` block. That is the state of `status/Caddyfile` today; this design does
  not tighten or loosen them, because changing them would be a behaviour change
  unrelated to TLS. Their target is the open catch-all, which has its own login.
- **The allowlist is neither removed nor widened.** `100.64.0.0/10` (rendered
  `[IP_ADDRESS]/10` in the checked-in file) and `fd7a:115c:a1e0::/48` remain.
  HTTPS is not authentication. A certificate proves the *server's* identity to
  the browser; it says nothing about the *client*. Removing the allowlist would
  turn a private host into a public one.
- **`(trusted_only)` and `(secure_headers)` are untouched.** Both appear in the
  diff as context only: no line inside either snippet is added, removed or
  modified. `(secure_headers)` keeps `X-Frame-Options DENY`,
  `Referrer-Policy no-referrer` and the `-Server` strip.
- **HSTS is additive, in a new `(hsts)` snippet.** It is imported by the three
  named `daemonhub.dev` HTTPS sites only -- never on `jarvis.lan`, never on the
  wildcard catch-all, and never merged into `(secure_headers)`. Sending HSTS on
  plain HTTP would be ignored at best and confusing at worst, and a wildcard
  site is exactly where a broad HSTS pin is least wanted.
- **One `tls` block per site, one issuance pair.** Caddy >= 2.10 prefers the
  wildcard, so a site named with an explicit subdomain is served from the
  wildcard certificate instead of getting a certificate of its own. Issuance is
  therefore exactly two certificates: `{$TLS_DOMAIN}` (apex) and
  `*.{$TLS_DOMAIN}`. `hermes.` and `status.` reuse the wildcard. Both are
  DNS-01 and share the same challenge name, so Caddy serialises them.
- **Accepted tradeoff: one wildcard key covers every subdomain.** The names
  that actually reach Certificate Transparency logs are `{$TLS_DOMAIN}` and
  `*.{$TLS_DOMAIN}` -- `hermes.` and `status.` are never disclosed there, which
  is the point of this choice. The cost is that a single private key serves all
  current and future subdomains: compromise of that key affects every host under
  the domain, not just the named ones. CT privacy was weighed against that blast
  radius and won.
- **No code change was needed to get this.** Caddy >= 2.10 applies wildcard
  preference on its own; the site blocks and their `tls` imports are unchanged.
- The wildcard catch-all is a change in behaviour: previously an unknown host
  did not match any site and Caddy answered 404 with its default page. Now it
  reaches a `respond 404` behind `trusted_only`.

### 4.2 Certificate and key storage

| Item | Value |
|---|---|
| Inside the container | `/data/caddy/certificates/` (Caddy's `$XDG_DATA_HOME` under `/data`) |
| On the host | `${HYBRID_AI_DATA_DIR}/caddy/caddy/certificates/` -- the `proxy` mount is `…/caddy:/data`, so `/data/caddy` lands one level deeper (outside the `status` container's read-only `webui_data` mount) |
| Production CA directory | `acme-v02.api.letsencrypt.org-directory/<hostname>/` |
| Staging CA directory | `acme-staging-v02.api.letsencrypt.org-directory/<hostname>/` |
| Files per host | `<host>.crt`, `<host>.key`, `<host>.json` (metadata: `sans`, `not_after`, `renewal_info`) |
| Owner | `root:root` inside the container (the caddy image runs as root by default and must, to bind 80/443 and write `/data`) |
| Modes | Caddy creates `0700` directories and `0600` files on first write. Do not relax them. |
| Parent directory owner | The installing user owns `${HYBRID_AI_DATA_DIR}/caddy`; Caddy's earlier writes may have created it as the container's root user. The installer ensures the directory exists and is `0700` before the first start, and never makes it group- or world-readable. |
| Read by | The `proxy` container only. **The `status` container must not mount it**, because it contains private keys; `status` never needs key material (section 6). |

Verified after issuance:

```bash
sudo ls -l "${HYBRID_AI_DATA_DIR}/caddy/caddy/certificates/acme-v02.api.letsencrypt.org-directory/daemonhub.dev/"
# expected: -rw------- root root  <host>.crt/.key/.json
sudo stat -c '%a %U:%G' "${HYBRID_AI_DATA_DIR}/caddy/caddy/certificates"
# expected: 700 root:root
```

### 4.3 Port publishing

```diff
     ports:
+      # 80 stays published: it carries the HTTP->HTTPS redirect, and in
+      # HTTP-01 mode it carries the challenge. 443 carries all HTTPS.
       - "80:80"
+      - "443:443"
+      - "443:443/udp"   # HTTP/3; harmless if the network drops it
```

`80:80` is retained because the redirect and HTTP-01 both need it. Dropping it
would leave `http://` clients on a connection error rather than a redirect, and
would break the existing HTTP-on-`jarvis.lan` fallback.

The compose `healthcheck` on the proxy keeps using `http://127.0.0.1:80/status/healthz`
and therefore still passes with TLS enabled: it is a plain HTTP liveness probe
inside the container, not a client request.

### 4.4 Compose changes, in full

```diff
   proxy:
-    image: caddy:2.11-alpine
+    build:
+      context: ./caddy
+      dockerfile: Dockerfile
+    image: ${CADDY_IMAGE:-hybrid-ai-caddy:2.11.7-dns}
     container_name: hybrid-ai-proxy
     restart: unless-stopped
     depends_on:
       - open-webui
       - status
     mem_limit: 128m
     cpus: "0.5"
     ports:
       - "80:80"
+      - "443:443"
+      - "443:443/udp"
     volumes:
       - ./status/Caddyfile:/etc/caddy/Caddyfile:ro
       # Caddy validates its config at boot; a syntax error here stops the
       # proxy only, leaving Open WebUI reachable on :3000.
       - ${HYBRID_AI_DATA_DIR:?HYBRID_AI_DATA_DIR must be set - run ./install.sh}/caddy:/data
+    secrets:
+      - cloudflare_dns_token
     environment:
       LOCAL_DOMAIN: ${LOCAL_DOMAIN:?LOCAL_DOMAIN must be set}
+      TLS_DOMAIN: ${TLS_DOMAIN:-}
+      ACME_EMAIL: ${ACME_EMAIL:-}
+      ACME_CA: ${ACME_CA:-https://acme-staging-v02.api.letsencrypt.org/directory}
+      ACME_AUTO_HTTPS: ${ACME_AUTO_HTTPS:-disable_redirects}
       DO_NOT_TRACK: "true"
     security_opt:
       - no-new-privileges:true
     healthcheck:
       test: ["CMD-SHELL", "wget -qO- http://127.0.0.1:80/status/healthz >/dev/null 2>&1 || exit 1"]
     logging:
       driver: "json-file"
       options:
         max-size: "5m"
         max-file: "2"
```

The context above is the `proxy` service as it stands at `origin/main`: image,
`container_name`, `restart`, `depends_on`, `mem_limit`, `cpus`, `ports`,
`volumes`, `environment`, `security_opt`, `healthcheck` (a plain HTTP liveness
probe on port 80, which therefore keeps passing with TLS enabled) and `logging`.
No context line changes; the diff only adds the `build:`/`image:` pair, the two
443 publishes, the `secrets:` entry and five environment keys.

plus, at the top level (compose file secrets are file-backed, no Swarm needed):

```yaml
secrets:
  cloudflare_dns_token:
    file: ${HYBRID_AI_TLS_TOKEN_FILE:?HYBRID_AI_TLS_TOKEN_FILE must be set when TLS is enabled}
```

When TLS is disabled the `secrets:` stanza and the `443` entries are **not**
emitted at all -- the installer selects a TLS-less variant so the compose file
is byte-for-byte equivalent to today's. In practice the installer renders the
`secrets:` block from a template fragment and validates with
`docker compose config -q`; an empty `secrets:` mapping is a compose error, so
it must be absent rather than empty.

Container hardening is unchanged: `no-new-privileges:true`, the same `mem_limit`
and `cpus`, the same read-only Caddyfile mount, the same 128 MB ceiling. The
`build:` stanza adds build-time, not run-time, surface.

### 4.5 `auto_https`, `admin`, and the HTTP-01 exception

- **DNS-01 (default):** global `auto_https disable_redirects`. Challenges are
  solved through DNS, and the explicit `http://` block in the same file is the
  only redirect (308). Certificate management stays ENABLED. `auto_https off`
  is a bug, not a mode: it disables Caddy's certificate management entirely, so
  the install "succeeds" and issues no certificate. The installer therefore
  never writes `off`; `ACME_AUTO_HTTPS=disable_redirects` in `.env`.
- **HTTP-01:** also `ACME_AUTO_HTTPS=disable_redirects`. With `off`, Caddy
  refuses to serve `/.well-known/acme-challenge/*` and issuance fails with
  `no solvers available for remaining challenges`. With `disable_redirects`,
  Caddy serves the challenge on port 80 and does not add its own redirect; the
  explicit `http://` block still provides the 308.
- **TLS-ALPN-01:** same as DNS-01, `auto_https disable_redirects`. The
  challenge is solved on the 443 listener, which the `https://` sites already
  own.
- **Admin API: TLS builds set `admin localhost:2019`; the non-TLS build keeps
  `admin off`.** This is the **one deliberate departure from `admin off`**, and
  it is deliberate because `caddy reload` needs an admin endpoint: without one,
  applying an edited Caddyfile means `docker compose restart proxy`, which drops
  every in-flight WebSocket stream, including an active Open WebUI chat.
  Reloading over the loopback admin endpoint applies the change with zero
  downtime instead.

  The binding is loopback **inside the container only**. Port 2019 is never
  published: there is no `2019:2019` mapping in `docker-compose.yml`, no
  `expose:`, and the container still runs `no-new-privileges:true`. The only way
  to reach it is `docker compose exec proxy …`, which runs a process in the
  container's own network namespace.

  Verify both halves:

```bash
# Inside the container: 2019 bound to loopback, nothing else new.
docker compose exec proxy ss -ltn
# expected: 127.0.0.1:2019, plus :80 and :443 listeners

# On the host: no 2019 listener at all.
ss -ltn | grep 2019 || echo "no host listener on 2019 (expected)"
```

### 4.6 Secrets at runtime

Requirement, restated because it is easy to get wrong: **Caddy must be able to
read the DNS token at runtime without the token landing in the image or in git.**

How each path is closed:

| Path | Closed by |
|---|---|
| Image | The token is never a `COPY`, never an `ARG`, never an `ENV` in `caddy/Dockerfile`. The build only copies the Caddy binary. |
| Git | `.gitignore` already ignores `.env`, `*.key`, `*.pem`, `*.crt`, `authkey*`, `runtime.env`. The token lives outside the repo entirely (`/etc/hybrid-ai/acme/`). |
| Env var | The token is not an environment variable, so it does not appear in `docker inspect` or `/proc/<pid>/environ`. |
| Command line | `install.sh` never accepts the token as an argument. It accepts a *path* (`--tls-token-file`), or reads the value silently from a TTY. |
| Rendered config | `{file./run/secrets/cloudflare_dns_token}` is a placeholder; the value is read at challenge time. |
| Logs | Caddy's JSON logs record the challenge type and names, not the token. The installer's redaction in `status/app.py` (`REDACTIONS`) already covers key-shaped strings. |

### 4.7 Login gate over the HTTPS sites (`basic_auth`)

Every `*.daemonhub.dev` HTTPS site — the apex, `hermes.`, `status.` and the
wildcard catch-all — can be gated behind HTTP Basic auth. The feature is
**off by default**: with `AUTH_ENABLED` unset or anything other than `on`, the
rendered `status/Caddyfile` is byte-identical to the file without the gate, and
the tracked `docker-compose.yml` differs only by the two pass-through
`environment:` lines (`HYBRID_AI_AUTH_USER` and `HYBRID_AI_AUTH_HASH`), both
defaulting empty.

**Mechanism.** A new managed region, `#@region auth`, wraps a reusable
`(auth)` snippet:

```
(auth) {
	basic_auth { {$HYBRID_AI_AUTH_USER} {$HYBRID_AI_AUTH_HASH} }
}
```

The renderer adds the `auth` variant to `tls_variants` only when
`AUTH_ENABLED=on`, exactly as the existing `dns`/`on`/`off` variants switch
regions. The two placeholders keep their runtime form; the proxy's compose
`environment:` block supplies `HYBRID_AI_AUTH_USER` and `HYBRID_AI_AUTH_HASH`
at container start. `AUTH_ENABLED` is render-time only and never reaches the
container.

**Placement rule.** `basic_auth` must be imported the same way as the sibling
`trusted_only` snippet: **inside every `handle`** of the apex block, because
Caddy runs a matching handle before the site-level directives, so a site-level
import alone would be bypassed. That is why `import auth` appears inside each
handled route and not once at site level. The `hermes.`, `status.` and
wildcard blocks have no handles, so there it imports at site level, next to
`trusted_only`.

**`/health` is exempt.** `handle /health` is deliberately left open: it is the
endpoint the external uptime monitor polls (see `status/README.md`, Endpoints
table). It serves one word with no detail. Gating it would break monitoring,
and it discloses nothing. Every other handle and the `hermes.`/`status.`/
wildcard site blocks are gated.

**Auth is additive.** The `basic_auth` gate layers on top of the
`trusted_only` network allowlist. Neither weakens the other: the allowlist
still aborts untrusted addresses before the handle runs, and the gate is
unchanged by it. The `http://*.jarvis.lan` sites and the http→https redirect
block import neither, so both name families work during the transition.

**Suppressed when TLS is off.** The `(auth)` snippet is imported only by the
`*.daemonhub.dev` HTTPS sites. With `TLS_ENABLED` not yes those sites do not
exist, so the snippet has nothing to import it and it is dead config. Real
Caddy rejects it: the top-level `basic_auth` directive is parsed as a site
address and the render fails with `parsed 'basic_auth' as a site address, but
it is a known directive; directives must appear in a site block`. So
`tls_variants` appends the `auth` variant only when `tls_is_on` AND
`tls_auth_is_on`: a TLS-off render is byte-identical to the auth-off render no
matter what `AUTH_ENABLED` says. This is suppression, not repair: there is
nothing to gate while TLS is off. `install.sh` prints a warning (never a hard
failure, never a change of exit status) in that combination so the operator is
not misled into thinking the gate is live.

**Compose env-file interpolation (`$`).** Docker Compose interpolates `$`
inside env-file values, so a bcrypt hash written raw (`$2a$14$...`) loses its
`$` fragments (`$iGdy2Gi` resolves to blank, and the deploy log shows `The
"iGdy2Gi" variable is not set. Defaulting to a blank string.`). The proxy's
`{$HYBRID_AI_AUTH_HASH}` placeholder then expands to a corrupted hash. The fix
is escape-at-write, unescape-for-validation: `install.sh` STEP 8 writes
`HYBRID_AI_AUTH_USER` and `HYBRID_AI_AUTH_HASH` with every `$` doubled (`$$`),
and Compose collapses it back to the operator's original bytes in the
container. The normalizer collapses to raw first and then escapes once
(`tls_compose_escape`), so it is idempotent: a raw value is escaped once, an
already-escaped value is byte-identical after a re-run, and a value carrying
`$$` never becomes `$$$$`. The in-repo reader of the literal value —
`tls_validate_caddyfile`, which passes the two variables to `caddy validate`
via `-e` — unescapes `$$`→`$` first (`tls_compose_unescape`), so validation
sees exactly what the container sees. Previously the validator passed the
in-process intact value and so never reproduced a corrupted runtime hash: a
validator/runtime divergence.

**Verification matrix.** `.github/workflows/validate.yml` renders the Caddyfile
with real Caddy for four flag combinations. The first three predate this
defect; the fourth closes the gap that let the TLS-off/auth-on render reach a
host deploy because CI never covered it:

| Case | TLS | AUTH_ENABLED | Variants | Expected |
|---|---|---|---|---|
| a | off | off | `off` | accepted; auth-off bytes |
| b | on | off | `on dns` | accepted; zero imports, zero snippets |
| c | on | on | `on dns auth` | accepted; gate emitted |
| d | off | on | `off` | accepted; byte-identical to case (a) |

Case (d) derives its variants from the live `tls_variants`, so an unpatched
`tls_variants` that renders `off auth` fails the "exactly `off`" and
byte-identical assertions before Caddy is ever invoked. The offline fixture
`scripts/test-auth-render.sh` covers the same case without Docker or Caddy.

**Fail-closed.** `tls_validate_caddyfile` already receives the proxy's runtime
env, so its env list now includes the two auth values. With `AUTH_ENABLED=on`
and an empty user or hash, the snippet expands to `basic_auth {  }`, which
`caddy validate` rejects — the install stops before the bad config reaches the
stack. The validator is never made tolerant of the empty case.

**Known limitation (owner-accepted, 2026-10-29).** Basic auth has no
server-side expiry. Browsers cache the credentials until closed, so the
practical session is per browser session, not exactly 24 hours. A `forward_auth`
session service that could expire credentials was considered and deferred
(Option B). The gate transmits credentials on every request, which is
acceptable only because every gated site is HTTPS: the http→https 308 happens
before any credential is sent, and no `http://` site is gated. The wildcard
catch-all now answers 401 before 404, a small enumeration-posture change,
recorded as accepted.

---

## 5. Renewal

### 5.1 Cadence

**Decision: rely on Caddy's built-in renewal. No second issuer, no competing
systemd timer.**

Justification: Caddy renews each certificate when roughly one third of its
lifetime remains -- for a 90-day Let's Encrypt certificate that is about 30 days
before expiry -- and it retries on failure while it still has time in hand. A
second timer calling `certbot renew` or `lego` would issue *separate*
certificates, doubling rate-limit consumption and creating two sources of truth
for what the proxy serves. The failure mode of a competing system is worse than
the failure mode of none.

What Caddy does, concretely: it schedules renewal from the certificate's
`not_after` metadata, checks its schedule on start and periodically while
running, and reloads the new certificate in place.

### 5.2 The one residual timer

**Decision: one systemd timer, `hybrid-ai-tls-check.timer`, runs
`scripts/tls-check.sh` read-only and alerts on failure. It never issues, never
renews, never writes to cert storage.**

- Unit: `deploy/hybrid-ai-tls-check.service` + `.timer`, daily at 06:10 (the
  backup timers already run at 03:30 and the prune at 04:20, so this slot is
  free and a failure is seen at breakfast rather than at 3 a.m.).
- `ExecStart=/usr/bin/env bash ${APP_DIR}/scripts/tls-check.sh --quiet`
- Exit code drives the alert; the unit is `Type=oneshot` and read-only, with
  `NoNewPrivileges=yes`, `ProtectSystem=strict`, `PrivateTmp=yes`.
- Its job is to catch the case Caddy's own retries cannot: a token that expired
  three weeks ago and a renewal that has been failing silently since.

### 5.3 Reload strategy

**Decision: reload, never restart, for certificate and configuration changes.**

- Caddy swaps renewed certificates in memory with no reload at all: the renewal
  path writes the new cert to `/data` and atomically replaces the in-memory
  `Certificate` object. No signal, no restart, no dropped connection.
- After editing `status/Caddyfile`, apply it with:

```bash
# Validate first -- a bad config must never reach the running proxy.
docker compose exec proxy caddy validate --config /etc/caddy/Caddyfile
# Apply. This uses the loopback admin endpoint inside the container.
docker compose exec proxy caddy reload --config /etc/caddy/Caddyfile
# Or, on the host, without entering the container:
docker compose -f docker-compose.yml -f openhands/docker-compose.openhands.yml \
  exec proxy caddy reload --config /etc/caddy/Caddyfile
```

- `caddy reload` performs a graceful, zero-downtime swap. **A container restart
  is not required**, and is actively discouraged: `docker compose restart proxy`
  drops every in-flight WebSocket, which includes an active Open WebUI chat
  stream.
- The non-TLS build keeps `admin off`, so there `caddy reload` fails with
  `connect: connection refused`. In that mode the apply path is
  `docker compose up -d proxy` after `caddy validate` in a throwaway container.
  This path is not used for TLS builds, which always have the loopback admin
  endpoint:

```bash
docker run --rm -v "$PWD/status/Caddyfile:/etc/caddy/Caddyfile:ro" \
  hybrid-ai-caddy:2.11.7-dns caddy validate --config /etc/caddy/Caddyfile
docker compose up -d proxy
```

**Decision: every TLS build sets `admin localhost:2019`, so `caddy reload`
works and a restart is never needed.** This is the one deliberate departure from
`admin off`, and it is required to honour "reload without restart": without an
admin endpoint, applying an edited Caddyfile means restarting the proxy, which
drops in-flight WebSocket streams. The listener is loopback-only **inside the
container**, published on no host port, and the container still runs with
`no-new-privileges:true`. Verify it as in section 4.5: `ss -ltn` inside the
container shows `[IP_ADDRESS]:2019` and nothing else new, and `ss -ltn` on the
host shows no 2019 listener. The non-TLS build keeps `admin off`.

### 5.4 Proving renewal works

Run all of this with the **staging** CA first. Staging issues untrusted
certificates, which is exactly why it is safe to repeat.

```bash
# 0. Point at staging and start.
#    .env:  ACME_CA=https://acme-staging-v02.api.letsencrypt.org/directory
docker compose up -d proxy
docker compose logs -f proxy | grep -E '"logger":"tls"'

# 1. Confirm the certificate exists in staging storage.
docker compose exec proxy sh -c \
  'ls -l /data/caddy/certificates/acme-staging-v02.api.letsencrypt.org-directory/'
# expected: daemonhub.dev/  wildcard_.daemonhub.dev/
#           Caddy >= 2.10 wildcard preference: hermes. and status. are served by
#           wildcard_.daemonhub.dev/ and get no certificate directory of their own.

# 2. Confirm the stored metadata carries the expected expiry and renewal window.
docker compose exec proxy sh -c \
  'cat /data/caddy/certificates/acme-staging-v02.api.letsencrypt.org-directory/daemonhub.dev/daemonhub.dev.json' \
  | jq '{sans, not_after, renewal_info}'
# expected: not_after ~90 days out (staging certs are 90-day), and a
#           renewal_info.renew_at roughly 30 days before not_after.

# 3. Confirm the served chain matches what is on disk (staging chain -> untrusted,
#    so the handshake is expected to fail verification; the certificate must
#    still be present and match the SAN).
openssl s_client -connect 127.0.0.1:443 -servername daemonhub.dev </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates -ext subjectAltName
# expected: issuer contains "STAGING", dates show ~90 days, SAN has
#           daemonhub.dev and *.daemonhub.dev

# 4. Force a renewal without waiting 60 days: move the certificate aside and
#    restart the proxy. Caddy sees no managed certificate and reissues.
docker compose stop proxy
sudo mv "${HYBRID_AI_DATA_DIR}/caddy/caddy/certificates/acme-staging-v02.api.letsencrypt.org-directory/daemonhub.dev" \
        "${HYBRID_AI_DATA_DIR}/caddy/caddy/certificates/staging-hold/daemonhub.dev.$(date +%s)"
docker compose start proxy
docker compose logs --since 2m proxy | grep -iE 'obtaining|renew|certificate' | head
# expected: "obtaining certificate" then "certificate obtained successfully"
```

Where renewal events appear:

- **Caddy logs** (`logger: "tls"`, `msg: "certificate obtained successfully"`,
  `msg: "renewing certificate"`, `msg: "renewal attempted"`). These are on
  stdout and therefore in `docker logs hybrid-ai-proxy` and in the container's
  `json-file` log (already capped at `max-size: 5m`, `max-file: 2`).
- **Cert storage metadata**: `<host>.json` under the active CA directory carries
  `not_after` and `renewal_info`; comparing `not_after` over time is the
  durable proof, independent of log rotation.
- **The audit record** (section 6.5): `scripts/tls-check.sh` appends one line
  per observation to `${HYBRID_AI_LOG_DIR}/tls-check.log`, so issuance and
  renewal show up as a jump in `not_after`.

Then switch to production:

```bash
# .env: ACME_CA=https://acme-v02.api.letsencrypt.org/directory
docker compose up -d proxy
docker compose logs -f proxy | grep -E '"logger":"tls"'
openssl s_client -connect 127.0.0.1:443 -servername daemonhub.dev </dev/null 2>/dev/null \
  | openssl x509 -noout -issuer -dates -ext subjectAltName
# expected: issuer "C = US, O = Let's Encrypt, CN = R11" (or similar), verify return code: 0
```

### 5.5 Rate limits and why staging is the default

| Let's Encrypt limit | Value | What it means here |
|---|---|---|
| Certificates per registered domain | 50 per week | A normal install uses 2-3. Only a loop of forced renewals exhausts it. |
| Duplicate certificates | 5 per week | Re-running an install that reissues the *same* names five times in a week hits this. This is the limit a careless debug loop breaks. |
| Failed validations | 5 per account per hostname per hour | A misconfigured token hits this after five attempts. |
| New orders per account | 300 per 3 hours | Not reachable at this scale. |

**Production is not the default** because a first-time install is exactly when
names, tokens and the Caddyfile are wrong, and every wrong attempt counts. With
`ACME_CA` defaulting to staging, a broken install can be retried all afternoon
for no cost, and the single switch to production happens when everything is
verified. The installer prints the staging issuer string in the success message
so an operator cannot mistake a staging certificate for a working one.

---

## 6. Health checks

### 6.1 What the check must assert

For each configured hostname (`daemonhub.dev`, `hermes.daemonhub.dev`,
`status.daemonhub.dev`):

| # | Assertion | How |
|---|---|---|
| 1 | A certificate is served at all | `ssl` handshake to `proxy:443` with SNI = hostname, from the `status` container |
| 2 | The chain validates against the system trust store | `ssl.create_default_context().verify_mode = CERT_REQUIRED`; `SSLError` on failure |
| 3 | The certificate matches the hostname (SAN) | `ssl.match_hostname` semantics -- Python's `check_hostname`, or explicit `getpeercert()['subjectAltName']` comparison when the chain is staging and verification is off |
| 4 | Not expired | `notAfter` vs now |
| 5 | Days to expiry above threshold | computed from `notAfter` |
| 6 | The served certificate equals the stored one | compare the leaf's SHA-256 fingerprint with the `.crt` on disk when readable (optional; `status` cannot read `/data` today, so this is a CLI-only assertion) |

Assertion 3 is checked separately from 2 on purpose: a staging certificate has a
valid chain shape and correct SANs but an untrusted issuer. Reporting "SAN wrong"
for a staging cert would send an operator down the wrong path.

### 6.2 Thresholds and exit codes

| Condition | Severity | Exit code |
|---|---|---|
| All hostnames fine, more than 14 days left | OK | `0` |
| Any hostname with fewer than **14** days left, but at least 7 | WARN | `1` |
| Any hostname with fewer than **7** days left, but not expired | CRITICAL | `2` |
| Any hostname expired | CRITICAL | `2` |
| No certificate served, chain invalid, or SAN mismatch | MISSING/INVALID | `3` |
| Could not connect to `proxy:443` at all, or TLS disabled | MISSING/INVALID | `3` |

Exact rule set, so an implementation has nothing to interpret:

```text
days = floor((notAfter - now) / 86400)
if TLS disabled:                                   exit 3  (SKIPPED, not an error)
elif connect fails or no cert or chain invalid:     exit 3
elif SAN does not contain hostname:                 exit 3
elif days <= 0:                                     exit 2
elif days < 7:                                      exit 2
elif days < 14:                                     exit 1
else:                                               exit 0
```

`14` and `7` are not arbitrary: Caddy starts renewing at ~30 days, so 14 days
still leaves two weeks of retries, and 7 days is the point at which a human
must be woken up. Both are compile-time constants in `scripts/tls-check.sh` and
are reported in the output so the log explains itself.

### 6.3 Proposed endpoint

**Decision: `GET /status/tls`, JSON, inside `status/app.py`.** Not a new service,
not a new container: the status app already serves `/status/healthz`,
`/status/health-summary`, `/status/api`, `/status`, `/hub`, and it is already on
a container that can reach `proxy:443` over the shared network.

Response body:

```json
{
  "enabled": true,
  "checked_at": "2026-10-28T01:05:29Z",
  "overall": "warn",
  "exit_code": 1,
  "hosts": [
    {
      "hostname": "hermes.daemonhub.dev",
      "certificate": true,
      "chain_valid": true,
      "san_match": true,
      "issuer": "C=US, O=Let's Encrypt, CN=R11",
      "not_after": "2027-01-20T00:00:00Z",
      "days_to_expiry": 84,
      "severity": "ok"
    }
  ]
}
```

Placement in `status/app.py`, concretely:

- New module-level constants next to `LOCAL_DOMAIN`:
  `TLS_ENABLED = os.getenv("TLS_ENABLED", "false").lower() in ("1","true","yes")`,
  `TLS_HOSTS = [h for h in os.getenv("TLS_HOSTS", "").split(",") if h]`,
  `TLS_WARN_DAYS = 14`, `TLS_CRIT_DAYS = 7`,
  `TLS_PROBE_ADDR = os.getenv("TLS_PROBE_ADDR", "proxy:443")`.
- A new function `collect_tls_status() -> Dict[str, Any]` beside `collect_status()`,
  using only the standard library (`ssl`, `socket`, `datetime`). It opens one
  connection per hostname with `server_hostname=<host>` and `verify_mode=CERT_NONE`
  for the metadata read, then a second with `CERT_REQUIRED` to prove the chain.
  The two-pass form is what lets a staging certificate report
  `"chain_valid": false` without hiding its SAN and dates.
- A new branch in `do_GET`, mirroring the existing `/status/api` branch:
  `/status/tls` returns `200` when `overall` is `ok`, `200` with
  `"overall":"warn"` on warn (a warn is not a failed probe), and `503` on
  critical or missing. The body is always the same JSON shape.
- **Read-only posture preserved:** the endpoint only dials `proxy:443` and reads
  no files, no Docker socket, no `/data`. It never touches private keys. It
  performs no writes. `/status/tls` is behind `(trusted_only)` via the existing
  proxy routing for `/status*`, so it is not a public probe.

In `status/Caddyfile`, no new site is needed: the apex block already routes
`/status*` to `status:8088`, and the `status.` site proxies everything. Both now
cover `/status/tls` automatically. The one line to add is in the status app's
own documentation comment at the top of the file (the endpoint list at
`status/app.py:53`), plus the `TLS_HOSTS` / `TLS_ENABLED` env vars in the
`status` service in `docker-compose.yml`:

```diff
     environment:
       TAILSCALE_IP: ${TAILSCALE_IP:-}
       STATUS_PORT: "8088"
       LOCAL_DOMAIN: ${LOCAL_DOMAIN:?LOCAL_DOMAIN must be set}
+      TLS_ENABLED: ${TLS_ENABLED:-false}
+      TLS_HOSTS: ${TLS_HOSTS:-}
+      TLS_PROBE_ADDR: proxy:443
```

### 6.4 How the existing endpoints surface it

- `/status/healthz` **does not change.** It is a liveness probe for Docker and
  must stay a constant, dependency-free `200 ok`. Making it depend on
  certificate state would restart a healthy proxy's healthcheck path for an
  unrelated reason and cascade into an outage.
- `/status/health-summary` gains one clause: overall is `fail` if TLS is enabled
  and `collect_tls_status()["overall"] == "critical"`. `warn` maps to the
  existing warning state, so the endpoint's `200`/`503` contract is unchanged.
- `/status/api` gains a `"tls"` key holding the same object as `/status/tls`.
- `/status` and `/hub` gain one row: "TLS certificates", showing the worst
  severity, the nearest expiry date, and the days remaining. Clicking it shows
  the per-host table.

### 6.5 Alerting and the audit record

**Decision: reuse what the host already has -- `doctor.sh`'s exit codes and the
existing monitoring/webhook/email path -- rather than adding an alerting
channel.**

- `scripts/tls-check.sh --quiet` is the CLI form of the same logic, for the
  systemd timer and for `doctor.sh`. It prints one line per host and exits with
  the codes from 6.2. `doctor.sh` gains a section that calls it and maps
  `1` to its own warning and `2`/`3` to its own failure, so `./doctor.sh` alone
  is still sufficient, and `./doctor.sh --quiet` still exits non-zero on a
  problem.
- `deploy/hybrid-ai-tls-check.service` runs it daily. The alert rides the
  existing path: the host already mails on non-zero exits from
  `hybrid-ai-check` and already has webhooks for deploy events, so the TLS unit
  reuses the same `OnFailure=` target as `hybrid-ai-check.service`. No new
  mail relay, no new webhook secret.
- The audit record is append-only text, one line per host per run, in
  `${HYBRID_AI_LOG_DIR}/tls-check.log` (`0600`, owned by the installing user):

```text
ts=2026-10-28T06:10:02Z host=daemonhub.dev issuer="CN=R11" not_after=2027-01-20T00:00:00Z days=84 severity=ok exit=0
ts=2026-10-28T06:10:02Z host=hermes.daemonhub.dev issuer="CN=R11" not_after=2027-01-20T00:00:00Z days=84 severity=ok exit=0
```

  A renewal is visible as a sudden jump in `days` for every host, and an
  issuance is the first line mentioning a host. Because `not_after` is recorded,
  the log answers "when did this certificate change?" without needing Docker
  logs, which are capped at 5 MB x 2 files.

---

## 7. Migration runbook outline

Governed by D11: **`jarvis.lan` is not decommissioned in this change.** The
dual-name period is the whole cutover, and it never ends until a later, separate
decision.

### 7.1 Dual-name period

Both names are in the Caddyfile at once:

| Name | Scheme | Purpose during cutover |
|---|---|---|
| `jarvis.lan` | http | Unchanged fallback. Existing bookmarks, `install.sh`-printed URLs, `OPENHANDS_SANDBOX_HOST`, status page links all keep working. |
| `daemonhub.dev`, `hermes.`, `status.` | https | New primary. Verified in parallel before anyone is told to switch. |

Both must resolve and both must serve. Nothing is removed from the Caddyfile in
this change; the HTTPS blocks are additions.

### 7.2 TTL lowering, first

Before any DNS change: lower every `daemonhub.dev` record TTL to **300 s** and
wait at least one old TTL (one hour, to be safe) so a rollback propagates
quickly. Do this at least an hour before the cutover window, not during it.

### 7.3 Order of operations

1. Lower DNS TTLs to 300 s; wait one hour. (No service impact.)
2. Create the Cloudflare API token, scoped as in section 2.6. Verify it with the
   four checks in 2.6.
3. Write the token to `/etc/hybrid-ai/acme/cloudflare_dns_token` (`0600 root`).
4. Enablement renders the TLS compose and builds the Caddy image. Run
   `./install.sh --tls` (step 7): the render adds the proxy `build:` stanza,
   then install.sh's build phase runs `docker compose build proxy`. Verify the
   BUILT image carries the DNS providers:
   `docker run --rm --entrypoint caddy hybrid-ai-caddy:2.11.7-dns list-modules | grep dns.providers`.
   A `docker compose build proxy` run BEFORE enablement has nothing to build
   (`WARN No services to build`): the stanza does not exist until the TLS-on
   render writes it. The stock `caddy:2.11-alpine` image is never used for TLS
   (section 2.3).
5. Add the dnsmasq drop-in on the Pi-hole host and `pihole restartdns`. Verify
   `dig @<pihole> daemonhub.dev` from a LAN client.
6. Create the public records that make sense: `_acme-challenge` TXT is written by
   Caddy; apex/wildcard A only if a port forward exists.
7. Set `.env` TLS keys with `ACME_CA` = **staging**. The installer accepts the
   `staging`/`production` label and normalizes it to the resolved CA URL in the
   stack `.env`, so the proxy container and the render validator both receive
   the URL. Run the installer with `--tls`.
8. Validate and apply the Caddyfile. Confirm staging issuance produces exactly
   two certificates -- the apex and the wildcard -- and that all four HTTPS site
   blocks are served from those two (section 5.4 step 1-3).
9. Verify every service over HTTPS on staging (browsers will warn; use `curl -k`
   or accept the warning).
10. Switch `ACME_CA` to production, apply, confirm the trusted chain
    (section 5.4).
11. Run the TLS health check; confirm exit `0` and ~90 days.
12. Print the new URLs; leave the old ones printed as well.
13. Watch for one week; keep the rollback trigger armed.

### 7.4 Which internal URLs change

| Surface | Before | After | Action |
|---|---|---|---|
| `install.sh` printed URLs (lines 2284-2289) | `http://daemonhub.dev` etc. on `LOCAL_DOMAIN` | `https://daemonhub.dev`, `https://hermes.…`, `https://status.…` | Print **both** during the dual-name period; `https` first, `http://jarvis.lan` second |
| `OPENHANDS_SANDBOX_HOST` | the LAN hostname | unchanged | OpenHands stays loopback-only; do not point it at the public name |
| `LOCAL_DOMAIN` | `jarvis.lan` | unchanged | New `TLS_DOMAIN` variable carries `daemonhub.dev`; `LOCAL_DOMAIN` keeps its meaning for the HTTP fallback |
| Status page links | `http://jarvis.lan/status` | add `https://status.daemonhub.dev/status` | Both links shown until the fallback retires |
| Bookmarks / docs | `http://jarvis.lan` | `https://daemonhub.dev` | User action, documented in the release note |
| Hermes / status subdomains | `http://hermes.jarvis.lan` | `https://hermes.daemonhub.dev` | Both live during cutover |

### 7.5 Verifying each service over HTTPS

Run from a LAN client, and repeat from the Pi itself:

```bash
for h in daemonhub.dev hermes.daemonhub.dev status.daemonhub.dev; do
  printf '%-28s ' "$h"
  curl -sS -o /dev/null -w '%{http_code} %{ssl_verify_result}\n' "https://$h/"
done
# expected: 200 0 / 200 0 / 302 0   (the status site redirects / to /status)

# The allowlist still applies over HTTPS: from a host outside the allowlist the
# connection must be closed, not served.
curl -sS --max-time 5 -o /dev/null -w '%{http_code}\n' https://daemonhub.dev/ || echo "aborted (expected)"
# expected: "aborted (expected)" or an empty-reply error -- NOT 200

# Redirect works.
curl -sSI http://daemonhub.dev/ | head -3
# expected: HTTP/1.1 308 Permanent Redirect, Location: https://daemonhub.dev/

# HSTS present on the HTTPS sites.
curl -sSI https://daemonhub.dev/ | grep -i strict-transport-security

# Services behind the proxy.
curl -sS https://status.daemonhub.dev/status/healthz          # -> ok
curl -sS https://daemonhub.dev/health                         # -> ok
curl -sS https://daemonhub.dev/status/api | jq '.overall'     # -> "ok"
curl -sS -o /dev/null -w '%{http_code}\n' https://hermes.daemonhub.dev/  # -> 200
```

### 7.6 Rollback

**Trigger (concrete):** roll back if any of these is true 30 minutes after the
production switch, and do not spend that window debugging a public site:

1. Any of the three hostnames returns a non-`2xx`/`3xx` over HTTPS when the
   equivalent `http://jarvis.lan` path returns `200`, or
2. the TLS health check exits `2` or `3`, or
3. certificate issuance for any site block fails twice in a row with a
   non-recoverable error (bad token, wrong zone), or
4. `docker compose ps` shows `hybrid-ai-proxy` not `healthy`, or
5. an untrusted client can retrieve content over HTTPS (allowlist bypass).

**Steps, in order, all reversible:**

```bash
# 1. Revert the Caddyfile to the previous version (HTTPS blocks removed).
git -C "${HYBRID_AI_APP_DIR}" stash push -- status/Caddyfile   # or restore from backup
docker compose exec proxy caddy validate --config /etc/caddy/Caddyfile
docker compose exec proxy caddy reload --config /etc/caddy/Caddyfile

# 2. Revert the port publish, so nothing new is listening.
#    Edit docker-compose.yml to drop 443 (keep 80), then:
docker compose up -d proxy

# 3. Revert .env TLS keys. Setting TLS_ENABLED=no is enough; the installer
#    renders the TLS-less compose variant on the next run.
sed -i 's/^TLS_ENABLED=.*/TLS_ENABLED=no/' "${HYBRID_AI_ENV_FILE}"

# 4. Revert DNS. Two independent halves:
#    a) Public: delete the _acme-challenge TXT records Caddy created and any
#       apex/wildcard A records added for this change. Restore TTLs to their
#       previous value.
#    b) Local: remove the dnsmasq drop-in and restart the resolver.
sudo rm -f /etc/dnsmasq.d/05-hybrid-ai.conf
sudo pihole restartdns

# 5. Confirm the fallback is untouched.
curl -sS http://jarvis.lan/status/healthz     # -> ok
curl -sS http://hermes.jarvis.lan/            # -> 200
curl -sS http://status.jarvis.lan/status/healthz  # -> ok
```

The certificate storage under `${HYBRID_AI_DATA_DIR}/caddy/caddy/certificates`
is deliberately **left in place** by a rollback: it holds no state that hurts,
and re-enabling TLS then resumes with the existing certificate instead of
issuing a duplicate and burning rate limit. Delete it only when the rollback is
permanent, and then delete the `acme-v02` directory as a whole.

`jarvis.lan` is the fallback at every step and is never changed by this
migration, which is why "rollback" is a matter of removing additions rather than
undoing a destructive change.

---

## 8. Installer surface

### 8.1 Prompts and defaults

| Prompt | Variable | Default | When asked |
|---|---|---|---|
| Enable HTTPS with Let's Encrypt? | `TLS_ENABLED` | `no` | Always, after `LOCAL_DOMAIN` |
| Base domain for certificates | `TLS_DOMAIN` | `daemonhub.dev` | Only if TLS enabled |
| ACME account email | `ACME_EMAIL` | none (required) | Only if TLS enabled |
| Validation method | `TLS_VALIDATION` | `dns` | Only if TLS enabled; prints the tradeoff text from section 1.4 first |
| DNS provider | `ACME_DNS_PROVIDER` | `cloudflare` | Only if `TLS_VALIDATION=dns` |
| Provider credential file path | `HYBRID_AI_TLS_TOKEN_FILE` | `/etc/hybrid-ai/acme/cloudflare_dns_token` | Only if `TLS_VALIDATION=dns`; the installer verifies it is a readable regular file, `0600`, and not inside the repo, and never prints its contents |
| Certificate authority | `ACME_CA` | staging | Only if TLS enabled; the prompt offers `staging` (default) or `production` and maps to the URL |

All prompts go through the existing `prompt_secret` helper so an existing `.env`
value is reused and no prompt repeats on re-run. The token itself is never
prompted by value: the operator is asked for the *path* and told how to create
the file.

### 8.2 Non-interactive flags and env equivalents

| Flag | Env equivalent | Value |
|---|---|---|
| `--tls` / `--no-tls` | `TLS_ENABLED=1` / `0` | Enable HTTPS |
| `--tls-domain <name>` | `TLS_DOMAIN=<name>` | Base domain |
| `--tls-email <addr>` | `ACME_EMAIL=<addr>` | ACME account email |
| `--tls-validation <dns\|http\|tlsalpn>` | `TLS_VALIDATION=<...>` | Validation method |
| `--tls-dns-provider <cloudflare\|rfc2136>` | `ACME_DNS_PROVIDER=<...>` | DNS plugin |
| `--tls-acme-ca <staging\|production\|url>` | `ACME_CA=<url>` | CA endpoint |
| `--tls-token-file <path>` | `HYBRID_AI_TLS_TOKEN_FILE=<path>` | **Path**, never the token |
| `--dry-run` | `HYBRID_AI_DRY_RUN=1` | Render and validate, change nothing |
| (existing) `--non-interactive` | -- | Never prompt; fail on a missing required value |
| (existing) `--no-start` | -- | Write config, do not touch Docker |

`--dry-run` prints every file it would write (paths only, plus a unified diff of
`status/Caddyfile` and `docker-compose.yml`), runs `docker compose config -q`
against the rendered compose file, validates the Caddyfile with
`caddy validate` in a throwaway container, and exits `0` without touching Docker
or any file. It is the required way to preview the change on the live host.

For a DNS-01 render that container also gets the operator's token file mounted
read-only at `/run/secrets/<name>`, still under `--network none`, so validation
provisions the TLS app exactly as the proxy will without needing the network. The
dry run therefore requires `HYBRID_AI_TLS_TOKEN_FILE` to name a non-empty,
readable regular file; otherwise it fails closed with the path and the fix and
writes nothing. A non-DNS render validates without any token mount. Because a
bare host `caddy` cannot be given that file, a DNS render is only validated when
docker is available: without it the step is a `[skip]` warning (return 3) and
the render is reported as not validated.

Parsing goes in the existing `for arg in "$@"` loop at the top of `install.sh`
and in the same style as `--wake-runpod`; an unknown flag still exits `2`.

### 8.3 Files the installer writes

| File | Content | Mode |
|---|---|---|
| `$ENV_FILE` (stack env, e.g. `.env`) | Adds `TLS_ENABLED`, `TLS_DOMAIN`, `ACME_EMAIL`, `ACME_CA`, `TLS_VALIDATION`, `ACME_DNS_PROVIDER`, `HYBRID_AI_TLS_TOKEN_FILE`, `TLS_HOSTS`, `ACME_AUTO_HTTPS`, `CADDY_IMAGE`. No secret values. | `0600` (unchanged) |
| `status/Caddyfile` | Rendered from `status/Caddyfile.tmpl` with the HTTPS blocks present or absent | `0644` (unchanged; not a secret) |
| `docker-compose.yml` | Rendered from `docker-compose.yml.tmpl`, TLS or non-TLS variant | `0644` |
| `${HYBRID_AI_LOG_DIR}/install.log` | Existing event log; gains `event tls_enabled`, `event tls_cert_issued host=…` lines. No token. | `0600` |
| `/etc/hybrid-ai/acme/` drop-in | **Not written by the installer.** The operator creates the token file. The installer only validates it. | `0700` dir / `0600` file |

The templates live beside the files they render, and the rendered files stay
tracked in git (they are the current state). This keeps `git diff` meaningful
after an install and keeps the non-TLS rendering byte-identical to today's
checked-in files.

### 8.4 Idempotency rules

Re-running the installer must be a no-op when nothing changed:

1. **No duplicated blocks.** Rendering is not appending. The template already
   contains the HTTPS blocks, marked with managed begin/end comments; the
   renderer strips any existing managed region and writes exactly one. Running
   twice produces a byte-identical file (`sha256sum` comparison is the test).
2. **Certificates are never clobbered.** The install never deletes
   `${HYBRID_AI_DATA_DIR}/caddy/caddy/certificates`. Reissuing is
   Caddy's decision, not the installer's. The only file the installer *moves* is
   under an explicit `--force-reissue`, and it moves rather than deletes.
3. **.env is rewritten, not appended** (existing behaviour: `mv -f` then
   `chmod 600`). New keys are added once; an existing value is preserved and
   printed as "already set", exactly as `prompt_secret` does today.
4. **Token file is never rewritten.** If the path exists with the right mode it
   is accepted; if it is missing, the installer stops before rendering anything.
5. **Re-run with `TLS_ENABLED=no`** removes the managed TLS region, drops the
   `443` publishes and the `secrets:` stanza, and leaves certificates on disk.
6. **Compose validation gates every render**: `docker compose config -q` runs
   before the file is moved into place; a broken render aborts with the previous
   file intact.

### 8.5 Validation rules

| Input | Rule | Failure |
|---|---|---|
| `TLS_DOMAIN` | Lowercase, 1-253 chars, at least two labels, only `a-z 0-9 -` and `.`, no leading/trailing hyphen, not an IP, not `.local` or `.lan`, not equal to `LOCAL_DOMAIN` | `die` with the reason |
| `ACME_EMAIL` | Exactly one `@`, non-empty local part, domain with at least one dot and no whitespace | `die` |
| `TLS_VALIDATION` | One of `dns`, `http`, `tlsalpn` | `die` |
| `ACME_DNS_PROVIDER` | One of `cloudflare`, `rfc2136` | `die` |
| `ACME_CA` | `staging`, `production`, or an `https://` URL | `die` |
| `HYBRID_AI_TLS_TOKEN_FILE` | Absolute path, exists, regular file, not a symlink out of `/etc/hybrid-ai`, mode `0600` or stricter, owner root, not under `HYBRID_AI_APP_DIR` | `die` with the exact fix command |
| `TLS_DOMAIN` + `TLS_VALIDATION=http` | Warn loudly: HTTP-01 cannot issue a wildcard, so the installation degrades to three per-host certificates and no wildcard | `warn`, continue |
| `TLS_DOMAIN` + no port forward, `TLS_VALIDATION=dns` | Nothing to check locally; the CA reports it | -- |
| DNS resolution of `TLS_DOMAIN` | If `getent hosts` fails, warn and print the dnsmasq lines from section 3.2 (same as today's subdomain check at line 1791) | `warn` |

**Which image validates the render.** The render gate adapts the rendered
Caddyfile in a throwaway container. A `dns` render names
`dns.providers.cloudflare` or `dns.providers.rfc2136`, and the caddyfile adapter
resolves those providers **at adapt time**. The stock `caddy:2.11-alpine` image
has no such modules, so it rejects a correct render. Therefore:

| Render | Image used to validate |
|---|---|
| `TLS_ENABLED=yes`, `TLS_VALIDATION=dns` | `${CADDY_IMAGE:-hybrid-ai-caddy:2.11.7-dns}` (section 2.3) |
| Everything else (`http`, `tlsalpn`, TLS off) | `caddy:2.11-alpine` |
| Any render, when `CADDY_VALIDATE_IMAGE` is set | `$CADDY_VALIDATE_IMAGE` (explicit override wins) |

**The token is mounted into the validator.** `caddy validate` provisions the TLS
app, and the rendered DNS solver reads its credential from
`{file./run/secrets/<name>}`. The throwaway validator therefore gets the
operator's token file as one extra read-only mount:

```
-v "${HYBRID_AI_TLS_TOKEN_FILE}:/run/secrets/<resolved secret name>:ro"
```

`<resolved secret name>` is the same name the render reads
(`cloudflare_dns_token` or `rfc2136_key_secret`). The mount is the only
difference in the invocation; `--network none`, `--rm`, the `-e` values and the
Caddyfile mount are unchanged, and a non-DNS render gets no extra mount at all.
The CI matrix step (`.github/workflows/validate.yml`) mounts its own dummy token
for the same reason.

**Fail-closed token checks, before any container starts.** On the DNS path only,
the validator dies when the token cannot be presented: `HYBRID_AI_TLS_TOKEN_FILE`
unset or empty, the path absent, not a regular file, unreadable, or empty
(0 bytes). Every message names the path and the fix command, and reports only
existence and length: the file's content is never echoed.

**Host-binary limitation.** A DNS render is never validated by a bare host
`caddy`, even when that binary is installed: it cannot be given the token file
without a mount, so it would fail provisioning with
`placeholder: failed to read file /run/secrets/...` and
`API token '' appears invalid`. The validator prefers the container whenever
docker is ready. With no docker it prints a `[skip]` warning (return 3, the same
non-fatal skip as every other validation step) stating that the token cannot be
presented to a bare host caddy. It does not attempt bind-mount tricks and does
not pass silently. Non-DNS renders keep the existing host-binary path unchanged.

**Build before validate.** On first enablement the proxy image does not exist
yet: STEP 9 `compose up` builds it, which is *after* this gate. The installer
therefore runs `docker build -t <resolved CADDY_IMAGE> ./caddy` before the
render is validated. The build is idempotent (an unchanged `caddy/Dockerfile`
is a cache hit) and comes only from the tracked `caddy/Dockerfile` with its
pinned tags, so the supply chain is unchanged. A build failure dies
fail-closed, with the previous files untouched. If docker is unavailable the
existing `rc=3` skip/warn path applies, as for every other validation step.

**`--dry-run` side effect.** The dry run writes no host file. Its one side
effect is that same `docker build`: a Docker image is build cache, not host
state, and validating the render is the dry run's whole value. The usage text
in `install.sh` states this.

### 8.6 Behaviour when TLS is disabled

**Requirement: with `TLS_ENABLED=no`, install behaviour is byte-for-byte
unchanged.** Concretely:

- No new interactive prompt appears (the TLS question defaults to `no` and is
  the only new prompt; with `--non-interactive` and no `TLS_ENABLED`, it takes
  `no` without asking).
- `status/Caddyfile` renders identically to the checked-in file today: same
  global block, same three `http://` sites, same snippets.
- `docker-compose.yml` renders identically: `caddy:2.11-alpine`, `"80:80"` only,
  no `secrets:`, no `build:`.
- `status/app.py` gains the endpoint but its behaviour with TLS off is inert:
  `/status/tls` returns HTTP `200` with
  `{"enabled": false, "overall": "skipped", "exit_code": 3, ...}`, and no other
  endpoint changes its answer, because a TLS check that is switched off is not a
  fault. The CLI `scripts/tls-check.sh`
  exits `3` in that state, and `doctor.sh` treats `3` as "skipped", not as a
  failure. That difference is deliberate: an HTTP monitor must not page, a CLI
  must be able to say "I did not do this".
- `install.sh` prints the same URLs it prints today.
- New `.env` keys are written with their defaults, so a later `--tls` run has
  something to read.

### 8.7 Secret hygiene rules (non-negotiable)

- No secret value may reach git. `.gitignore` already covers `.env`, `*.key`,
  `*.pem`, `*.crt`; the token lives outside the repo.
- No secret may reach a world-readable path. Token file `0600 root`, directory
  `0700 root`; `install.log` is `0600`; the rendered `.env` is `0600`.
- No secret may reach shell history. The installer never accepts a token value
  as an argument; the operator creates the file with an editor or a pipe, and
  the documented `curl` verification uses `$(sudo cat …)` only in a throwaway
  shell with `HISTFILE=/dev/null`.
- No secret may reach process arguments. `docker compose` uses a file-backed
  `secrets:` entry, not `environment:`. `ps auxww` shows no token.
- No secret may reach an image layer. `caddy/Dockerfile` copies one binary and
  nothing else; there is no `ARG` or `ENV` for credentials.
- Rotation is a file replacement plus `docker compose up -d proxy`; it does not
  require an edit to any tracked file.

---

## 9. Controls that must not be weakened

Restated explicitly, because every later task will be judged against this list.

1. **The trusted-network allowlist in `status/Caddyfile` stays as it is.** The
   loopback ranges, the RFC 1918 ranges, the `100.64.0.0/10` mesh range
   (rendered `[IP_ADDRESS]/10` in the checked-in file) and
   `fd7a:115c:a1e0::/48` all remain, and every HTTPS site imports
   `(trusted_only)` exactly once per site: inside each protected `handle` for
   the apex block, and at site level for the handle-free `hermes.`/`status.`/
   wildcard blocks.
   **HTTPS is not authentication.** A certificate proves the server to the
   client; it says nothing about the client. Adding TLS is never a reason to
   remove or widen the allowlist.
2. **Loopback-only binds stay loopback-only.** `ollama` publishes
   `127.0.0.1:11434`, `status` publishes nothing, `openhands` stays on
   `[IP_ADDRESS]:3001`. The Caddy admin endpoint is enabled on TLS builds and
   binds `localhost:2019` **inside the container**; it is never published on a
   host port, and the non-TLS build keeps `admin off`. Port 443 is the only new
   *published* listener, and it is behind the same allowlist as port 80.
3. **No secrets in git.** See 8.7. The token never enters the repo, the image,
   `.env`, an argument, or a log.
4. **The OpenHands credential stays read-only.** The agent's repo clone remains
   mounted read-only into Hermes at `/agent-repo`, and `OPENHANDS_WORKSPACE`
   remains outside the deployment directory so a sandbox cannot read `.env`.
   Nothing in this design gives the proxy or the status app access to that
   credential, and nothing widens the mount.
5. **Container hardening stays.** `no-new-privileges:true` on the proxy, the
   128 MB / 0.5 CPU caps, `restart: unless-stopped`, the capped `json-file`
   logging, read-only Caddyfile mount, read-only Docker socket for `status`.
   The one addition, `build:`, does not change run-time privileges.
6. **The status app's read-only posture stays.** It keeps the read-only Docker
   socket, the read-only `webui_data` mount, and the read-only log mounts. The
   new `/status/tls` endpoint only opens outbound TLS connections to
   `proxy:443`; it reads no files, reads no key material, and writes nothing.
   The certificate directory is deliberately **not** mounted into `status`,
   because it holds private keys.
7. **Certificate private keys are never readable by anything but the proxy.**
   Storage is `0700` directories and `0600` files, owned by container root.
   Health checks use a TLS handshake, not the key files.

   Caddy's `/data` bind source is `${HYBRID_AI_DATA_DIR}/caddy`, a sibling of
   `webui_data`, so the ACME key tree is **outside** the `webui_data` directory
   the `status` container mounts read-only at `/data/webui_data`. The parent
   directory is created by the installer as `0700`, owned by the installing
   user, and is never group- or world-readable.

   The old `${HYBRID_AI_DATA_DIR}/webui_data/caddy` directory is **not**
   removed or migrated: it is left in place as a harmless orphan and may be
   deleted after upgrade. A host that ever enabled TLS must inspect it for key
   material (`sudo ls -la "${HYBRID_AI_DATA_DIR}/webui_data/caddy"`) before
   deleting it, because an earlier Caddy run may have written private keys
   there.

---

## 10. Consolidated file list

Everything this design creates or changes. "Repo" means this git repository;
"host" means the Raspberry Pi's filesystem, outside git.

| # | Path | Repo / host | Action | Purpose | Permissions / owner |
|---|---|---|---|---|---|
| 1 | `docs/tls-acme-design.md` | repo | **create** | This document | `0644`, tracked |
| 2 | `status/Caddyfile` | repo | modify | Add `https://` site blocks, new `(hsts)` and `(tls_dns)` snippets, `http://` 308 redirect site, global `email`/`acme_ca`/`auto_https` vars, and `admin off` -> `admin localhost:2019` (loopback in-container only, never published; the non-TLS build keeps `admin off`). `(trusted_only)` and `(secure_headers)` stay byte-for-byte unchanged -- no line inside either may be added, removed or modified. | `0644` |
| 3 | `status/Caddyfile.tmpl` | repo | **create** | Managed-region template so the installer can render TLS/non-TLS variants idempotently (8.4) | `0644` |
| 4 | `docker-compose.yml` | repo | modify | Proxy `build:`/`image:`, `443:443` + `443:443/udp` publishes, `secrets:` entry and top-level `secrets:` block, `TLS_*`/`ACME_*` env; `status` service gains `TLS_ENABLED`/`TLS_HOSTS`/`TLS_PROBE_ADDR` | `0644` |
| 5 | `docker-compose.yml.tmpl` | repo | **create** | Same managed-region pattern for the TLS / non-TLS compose variants | `0644` |
| 6 | `install.sh` | repo | modify | New flags (8.2), TLS prompts after `LOCAL_DOMAIN` (8.1), validation (8.5), rendering + idempotency (8.3/8.4), `--dry-run`, DNS verification for `TLS_DOMAIN`, dual URL printing (7.4), `--help` text | `0755` |
| 7 | `scripts/lib/tls.sh` | repo | **create** | Installer helper sourced by `install.sh`: argument parsing for `--tls-*`, prompt text from 1.4, input validation, token-file checks, template rendering, compose/Caddyfile validation, dry-run output. Keeps `install.sh` readable. | `0644` (sourced, not executed) |
| 8 | `scripts/tls-check.sh` | repo | **create** | Certificate health CLI: live handshake per hostname, thresholds 14/7 days, exit codes 0/1/2/3 (6.2), one-line audit record to `${HYBRID_AI_LOG_DIR}/tls-check.log`, `--quiet`. Called by `doctor.sh` and the timer. | `0755` |
| 9 | `status/app.py` | repo | modify | `TLS_*` constants, `collect_tls_status()`, `GET /status/tls`, `"tls"` key in `/status/api`, TLS clause in `/status/health-summary`, TLS row in `/status` and `/hub`, endpoint list comment at line ~53. No new writes, no key access. | `0644` |
| 10 | `doctor.sh` | repo | modify | Call `scripts/tls-check.sh`, map exit `1` to warn, `2`/`3` to its own failure/skip handling, so one command still diagnoses everything | `0755` |
| 11 | `deploy/hybrid-ai-tls-check.service` | repo | **create** | Daily read-only watchdog unit (5.2): `Type=oneshot`, `NoNewPrivileges=yes`, `ProtectSystem=strict`, same `OnFailure=` target as `hybrid-ai-check.service` | `0644` |
| 12 | `deploy/hybrid-ai-tls-check.timer` | repo | **create** | `OnCalendar=*-*-* 06:10:00`, `Persistent=true` | `0644` |
| 13 | `caddy/Dockerfile` | repo | **create** | `xcaddy` build of Caddy 2.11.7 with `dns.providers.cloudflare` + `dns.providers.rfc2136`, pinned versions, with a build-time `caddy list-modules` gate (2.3) | `0644` |
| 14 | `caddy/.dockerignore` | repo | **create** | Keep the build context to one file; nothing from the repo or any secret can enter a layer | `0644` |
| 15 | `.env.example` | repo | modify | Document `TLS_ENABLED`, `TLS_DOMAIN`, `ACME_EMAIL`, `ACME_CA`, `TLS_VALIDATION`, `ACME_DNS_PROVIDER`, `HYBRID_AI_TLS_TOKEN_FILE`, `TLS_HOSTS`, `ACME_AUTO_HTTPS`, `CADDY_IMAGE` -- **paths and defaults only, no token** | `0644` |
| 16 | `REPO_MAP.md`, `CODE_INDEX.md` | repo | regenerate | Produced by the agent-context workflow, not by hand; listed so the build task runs it | generated |
| 17 | `/etc/hybrid-ai/acme/cloudflare_dns_token` | host | **create (operator)** | Cloudflare API token, `Zone:DNS:Edit` + `Zone:Zone:Read` on `daemonhub.dev` only | `0600`, `root:root`; parent dir `0700 root:root` |
| 18 | `/etc/hybrid-ai/acme/rfc2136_key_secret` | host | create (operator, only for the RFC 2136 provider) | TSIG secret for dynamic DNS updates | `0600`, `root:root` |
| 19 | `/etc/dnsmasq.d/05-hybrid-ai.conf` | host (Pi-hole) | **create** | Split-horizon rewrite for `daemonhub.dev` (3.2). Host state, not a repo file. | `0644`, `root:root`; read by `pihole-FTL` |
| 20 | `${HYBRID_AI_DATA_DIR}/caddy/caddy/certificates/` | host | created by Caddy | Certificate and key storage; `acme-v02…` and `acme-staging-v02…` subdirectories per CA | `0700` dirs, `0600` files, `root:root` (container root) |
| 21 | `${HYBRID_AI_LOG_DIR}/tls-check.log` | host | created by `tls-check.sh` | Append-only audit record of every issuance and renewal observation | `0600`, installing user |
| 22 | `${HYBRID_AI_LOG_DIR}/install.log` | host | appended by `install.sh` | Existing event log; gains `tls_enabled` / `tls_cert_issued` events, never a token | `0600` |

Not changed by this design, deliberately: `openhands/docker-compose.openhands.yml`,
`hermes/`, `openwebui/`, `backup/`, `runpod/`, `.gitignore` (already covers the
relevant patterns), `SECURITY.md`.

---

## 11. Secrets table

No secret value appears in this document, and none may appear in any file this
design touches.

| Secret | What it is | Where it is stored | Permissions | Who reads it | If leaked |
|---|---|---|---|---|---|
| Cloudflare ACME API token | Zone-scoped API token: `Zone:DNS:Edit` + `Zone:Zone:Read` on `daemonhub.dev` | `/etc/hybrid-ai/acme/cloudflare_dns_token` (host); mounted read-only at `/run/secrets/cloudflare_dns_token` | `0600 root:root` on host; `0444` on an in-memory mount inside the proxy container | `caddy` (the proxy container) only, via `{file./run/secrets/cloudflare_dns_token}` | Attacker can create/change/delete **any** record in `daemonhub.dev`, redirect all traffic for the zone, and obtain certificates for any name in it. Cannot touch other zones, cannot read account data, cannot reach the Pi, cannot escalate to account takeover (2.7). Rotate: new token, replace the file, `docker compose up -d proxy`. |
| RFC 2136 TSIG secret | HMAC key for dynamic DNS updates | `/etc/hybrid-ai/acme/rfc2136_key_secret` (host); `/run/secrets/rfc2136_key_secret` | Same as above | `caddy` only | Attacker can update records in the single zone the TSIG key is authorised for on that nameserver. Cannot read the zone, cannot update other zones, no host access. Rotate: regenerate TSIG on both sides. |
| `WEBUI_SECRET_KEY` (existing) | Open WebUI session signing key | `$ENV_FILE` | `0600` | `open-webui` | Existing risk, unchanged by this design. Not used by TLS. |
| `OPENROUTER_API_KEY` (existing) | Inference API key | `$ENV_FILE` | `0600` | `open-webui`, `openhands`, `hermes` | Existing risk, unchanged. Not used by TLS. |
| `RUNPOD_API_KEY` (existing) | RunPod control-plane key | `$ENV_FILE` | `0600` | `install.sh`, `openwebui` pipe | Existing risk, unchanged. Not used by TLS. |
| `ACME_EMAIL` | **Not a secret.** Account contact address | `$ENV_FILE`, rendered into the Caddyfile | `0600` file, `0644` config | `caddy` | Public metadata in the issued certificate's CA account and in CT logs. No access granted. |
| Certificate private keys | Per-host private keys | `${HYBRID_AI_DATA_DIR}/caddy/caddy/certificates/` | `0600`, `0700` dirs | `caddy` only; **not** mounted into `status` | Attacker can impersonate the site to clients that do not check the chain and can decrypt recorded traffic to that site if they also control the network path. Cannot reach any service credential. Rotate: delete the host directory and let Caddy reissue (section 5.4 step 4). |
| `TLS_HOSTS`, `TLS_DOMAIN`, `ACME_CA`, `TLS_VALIDATION`, `ACME_DNS_PROVIDER` | **Not secrets.** Configuration | `$ENV_FILE`, compose env | `0600` file | `caddy`, `status` | Reveal hostnames and the CA in use. No access granted. |

---

## 12. First-time enablement runbook for the current host

Target: the existing `jarvis.lan` Pi install, currently serving HTTP on port 80
with `LOCAL_DOMAIN=jarvis.lan`. Staging first, production last, `jarvis.lan`
untouched throughout.

Each step lists the command and the expected output. Stop at the first
unexpected result and follow the rollback in 7.6.

### Step 1 -- Pre-flight, no changes

```bash
cd "${HYBRID_AI_APP_DIR:-$HOME/hybrid-ai}"
git status --short          # expected: clean, or only files you intend to change
docker compose ps           # expected: ollama, open-webui, status, hybrid-ai-proxy Up/healthy
curl -sS http://jarvis.lan/status/healthz   # expected: ok
ss -lntp | grep -E ':(80|443)\s'            # expected: 80 only (docker-proxy)
```

### Step 2 -- Lower DNS TTLs (Cloudflare dashboard)

Set every `daemonhub.dev` record to TTL 300. Wait at least one hour before
Step 3.

Expected: dashboard shows 300 s. No command verifies this; propagation is
observed in Step 8.

### Step 3 -- Create and verify the API token

Cloudflare -> My Profile -> API Tokens -> Create Token -> "Edit zone DNS"
template -> Zone Resources: Include, Specific zone, `daemonhub.dev` -> add
`Zone:Zone:Read` -> Create.

```bash
sudo install -d -m 0700 -o root -g root /etc/hybrid-ai/acme
sudo install -m 0600 -o root -g root /dev/null /etc/hybrid-ai/acme/cloudflare_dns_token
sudoedit /etc/hybrid-ai/acme/cloudflare_dns_token    # paste the token, save, quit
sudo stat -c '%a %U:%G %n' /etc/hybrid-ai/acme /etc/hybrid-ai/acme/cloudflare_dns_token
# expected:
#   700 root:root /etc/hybrid-ai/acme
#   600 root:root /etc/hybrid-ai/acme/cloudflare_dns_token
```

Then run the four verification checks from section 2.6. Expected: `"active"`,
`1`, `0`, `403`.

### Step 4 -- Build the Caddy image

The proxy's `build:` stanza is part of the TLS-on compose render, so the build
happens during enablement, not before it. Do steps 7 and 8 first; install.sh
renders the compose, then its build phase runs `docker compose build proxy`.
Running `docker compose build proxy` before enablement prints
`WARN No services to build`, because no service declares a `build:` section yet.

After that build completes, verify the BUILT image:

```bash
docker run --rm --entrypoint caddy hybrid-ai-caddy:2.11.7-dns list-modules \
  | grep dns.providers
# expected:
#   dns.providers.cloudflare
#   dns.providers.rfc2136
docker image inspect hybrid-ai-caddy:2.11.7-dns --format '{{.Id}}'   # expected: sha256:…
```

The `caddy/Dockerfile` build-time gate runs that same `list-modules` check, so
a missing provider fails the BUILD, not the container at start. A build
failure means a plugin version pin is wrong. Fix the pin; do not fall back to
the stock `caddy:2.11-alpine` image, which carries no DNS providers and is never
used for TLS (section 2.3).

### Step 5 -- Local split-horizon DNS

```bash
sudo tee /etc/dnsmasq.d/05-hybrid-ai.conf >/dev/null <<'EOF'
# hybrid-ai :: split-horizon rewrite for daemonhub.dev.
# LAN clients get the Pi's LAN address; public clients get whatever the
# authoritative zone says. Managed by hand; not part of the hybrid-ai repo.

# Internal address of this Pi as seen from the LAN.
address=/daemonhub.dev/192.168.1.50

# Explicit per-service entries. They are redundant with the wildcard above but
# are kept so a single service can be pointed somewhere else (for example a
# test host) without touching the wildcard line.
address=/hermes.daemonhub.dev/192.168.1.50
address=/status.daemonhub.dev/192.168.1.50

# The Pi's loopback name, unchanged from today.
address=/jarvis.lan/192.168.1.50

# Local domain search, so `ping hermes` works on the LAN.
local=/daemonhub.dev/
domain=daemonhub.dev
EOF
sudo pihole restartdns
# expected: "Restarting pihole-FTL..." and it comes back within a few seconds

dig +short daemonhub.dev @127.0.0.1          # expected: 192.168.1.50
dig +short hermes.daemonhub.dev @127.0.0.1   # expected: 192.168.1.50
dig +short status.daemonhub.dev @127.0.0.1   # expected: 192.168.1.50
```

From a LAN laptop: `dig +short daemonhub.dev @192.168.1.50` -> `192.168.1.50`.
A laptop on public DNS is expected to answer differently; that is section 3.4,
not a fault.

### Step 6 -- Public records

With no port forward, add **nothing** except letting Caddy write the
`_acme-challenge` TXT. If a port forward exists, also add `daemonhub.dev` and
`*.daemonhub.dev` A records, **DNS only (grey cloud)**.

```bash
dig +short TXT _acme-challenge.daemonhub.dev @1.1.1.1   # expected: empty before Step 9
```

### Step 7 -- Dry run

```bash
./install.sh --tls --tls-domain daemonhub.dev --tls-email you@example.com \
             --tls-validation dns --tls-dns-provider cloudflare \
             --tls-acme-ca staging --dry-run
# expected: a unified diff showing the new https:// blocks and the 443 publish,
#           "compose config valid", "Caddyfile valid", and exit 0 with NO change
# The run may build hybrid-ai-caddy:2.11.7-dns first: validation of a DNS-01
# render needs the DNS-capable image (section 8.5). That image is cache, so the
# host files are still untouched.
# Validation provisions the TLS app with the DNS-01 token: the token file named
# by HYBRID_AI_TLS_TOKEN_FILE (section 2.5) is mounted read-only into the
# throwaway validator at /run/secrets/cloudflare_dns_token under --network none.
# A missing, unreadable or empty token file fails the dry run with the path and
# the fix; a host-only caddy cannot do this, so a DNS render is skipped (rc 3)
# when docker is unavailable.
git status --short          # expected: still clean
```

### Step 8 -- Enable TLS against staging

```bash
./install.sh --tls --tls-domain daemonhub.dev --tls-email you@example.com \
             --tls-validation dns --tls-dns-provider cloudflare \
             --tls-acme-ca staging
# The installer normalizes the `staging` label to the resolved CA URL in the
# stack .env; the proxy container and the Caddyfile validator both receive it.
# expected:
#   [ OK ] .env written (0600).
#   [ OK ] Caddyfile rendered with the HTTPS site blocks.
#   [ OK ] 443 published.
#   [ ! ] Certificate issued by the STAGING CA (not trusted by browsers yet).
docker compose logs --since 3m proxy | grep -E '"logger":"tls"' | tail -5
# expected: "obtaining certificate" ... "certificate obtained successfully" x4
```

### Step 9 -- Verify staging issuance and storage

```bash
docker compose exec proxy sh -c \
  'ls /data/caddy/certificates/acme-staging-v02.api.letsencrypt.org-directory/'
# expected: daemonhub.dev  wildcard_.daemonhub.dev   (hermes. and status. reuse the wildcard)

sudo stat -c '%a %U:%G' "${HYBRID_AI_DATA_DIR}/caddy/caddy/certificates"
# expected: 700 root:root

openssl s_client -connect 127.0.0.1:443 -servername daemonhub.dev </dev/null 2>/dev/null \
  | openssl x509 -noout -issuer -dates -ext subjectAltName
# expected: issuer contains "STAGING"; SAN includes daemonhub.dev, *.daemonhub.dev
```

### Step 10 -- Verify every service (staging; expect browser warnings)

```bash
curl -ksS https://status.daemonhub.dev/status/healthz        # expected: ok
curl -ksS https://daemonhub.dev/health                       # expected: ok
curl -ksS https://daemonhub.dev/status/api | jq '.overall'   # expected: "ok"
curl -ksS -o /dev/null -w '%{http_code}\n' https://hermes.daemonhub.dev/   # expected: 200
curl -sSI http://daemonhub.dev/ | head -2                    # expected: 308 + Location: https://...
curl -ksS -o /dev/null -w '%{http_code}\n' https://daemonhub.dev/status/tls  # expected: 200
```

Then prove the allowlist still holds: from a host outside the allowlist,
`curl -sS --max-time 5 https://daemonhub.dev/` must fail to return content.

### Step 11 -- Switch to production

```bash
sed -i 's|^ACME_CA=.*|ACME_CA=https://acme-v02.api.letsencrypt.org/directory|' .env
docker compose up -d proxy
docker compose logs --since 3m proxy | grep -E '"logger":"tls"' | tail -5
# expected: new orders against acme-v02, "certificate obtained successfully"

openssl s_client -connect 127.0.0.1:443 -servername hermes.daemonhub.dev </dev/null 2>/dev/null \
  | openssl x509 -noout -issuer -dates -ext subjectAltName
# expected: issuer "O = Let's Encrypt", verify return code: 0
```

### Step 12 -- Health check and audit line

```bash
./scripts/tls-check.sh; echo "exit=$?"
# expected: 3 OK lines with ~90 days, then exit=0
tail -3 "${HYBRID_AI_LOG_DIR}/tls-check.log"
# expected: one ts=… line per host with days≈90 severity=ok
./doctor.sh --quiet; echo "exit=$?"      # expected: exit=0
```

### Step 13 -- Dual-name verification, then announce

```bash
# Both names must serve. HTTPS first, the fallback second.
for u in https://daemonhub.dev/ https://hermes.daemonhub.dev/ \
         https://status.daemonhub.dev/status/healthz \
         http://jarvis.lan/status/healthz http://hermes.jarvis.lan/; do
  printf '%-52s ' "$u"
  curl -skS -o /dev/null -w '%{http_code}\n' "$u"
done
# expected: 200 200 200 200 200   (all five)
```

Update bookmarks and the release note. `jarvis.lan` stays published and listed
in the installer output.

### Step 14 -- Keep the rollback armed for one week

Leave `status/Caddyfile` and the previous `docker-compose.yml` in git history so
reverting is a `git checkout` of two files. The rollback trigger and steps are
section 7.6. If nothing fires in a week, lower the rigour: keep the daily
`tls-check` timer and stop watching manually.

---

## 13. Summary of the calls made

Short restatement, so a reviewer can disagree with a specific decision rather
than with the whole document.

1. **DNS-01 by default**, because the host has no inbound ports and the owner
   validates by DNS. HTTP-01/TLS-ALPN-01 remain available and are the right
   answer only for a directly reachable host that must not hold a DNS token.
2. **Cloudflare first, RFC 2136 second.** Cloudflare for propagation speed and
   an existing zone; RFC 2136 because a TSIG key is zone-scoped by the server.
3. **A locally built `xcaddy` image** pinned to Caddy 2.11.7 and plugin
   versions, with a build-time `list-modules` gate. The stock image is never
   used for TLS.
4. **Zone-scoped credential, accepted residual risk.** Cloudflare has no
   per-record permissions; the minimum is one zone with DNS edit. The zone is
   dedicated to this stack, and the CNAME-delegation upgrade path is documented.
5. **Token as a file-backed compose secret**, read with `{file.…}`. Never an env
   var, never an argument, never in the image.
6. **Split horizon via dnsmasq `address=/daemonhub.dev/<ip>`**, a host file
   outside the repo, with the wildcard form explained and the apex plus
   per-service entries written out.
7. **Explicit `https://` site blocks, explicit `http://` 308 redirects, and
   `auto_https disable_redirects`** for every TLS-on mode (never `off`, which
   would disable certificate management). Neither existing snippet changes:
   `(trusted_only)` and `(secure_headers)` are preserved byte-for-byte, and HSTS
   is additive in a new `(hsts)` snippet imported only by the three named
   `daemonhub.dev` sites. The allowlist is not widened.
8. **Caddy's own renewal, plus a read-only daily watchdog.** No second issuer.
   Reload in place, never restart, with the admin endpoint enabled on TLS builds
   as `admin localhost:2019` -- loopback inside the container, never published;
   the non-TLS build keeps `admin off`.
9. **Certificate health by live handshake**, with 14-day WARN and 7-day
   CRITICAL thresholds, exit codes 0/1/2/3, and a new `GET /status/tls`
   endpoint that never reads keys.
10. **Dual-name cutover, `jarvis.lan` kept.** Rollback is removal of additions,
    with a concrete five-condition trigger.
11. **`TLS_ENABLED` defaults to `no`,** and a disabled install stays
    byte-for-byte as it is today.

### Reviewer checklist

- **A later `git diff status/Caddyfile` must show no removed or modified line
  inside `(trusted_only)` or `(secure_headers)`.** Both snippets must be byte-
  identical to the snippet as restored by commit `5ea8f0c`, `(secure_headers)`
  still carrying
  `X-Frame-Options DENY`, `Referrer-Policy no-referrer` and `-Server`, and HSTS
  must arrive only through the new `(hsts)` snippet.
- The allowlist ranges are untouched: loopback, the RFC 1918 ranges, the mesh
  `[IP_ADDRESS]/10` (rendered `[IP_ADDRESS]/10`) and `fd7a:115c:a1e0::/48`.
- `docker compose exec proxy ss -ltn` shows `[IP_ADDRESS]:2019` and nothing else
  new, and `ss -ltn` on the host shows no 2019 listener.
