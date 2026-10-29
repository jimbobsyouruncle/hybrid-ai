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
