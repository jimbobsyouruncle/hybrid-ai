# `status/` — Status Page

| File | Purpose |
|---|---|
| `app.py` | The status service — a small standard-library-only Python web app |
| `Caddyfile` | Reverse proxy config giving you one address for everything, and the IP allowlist protecting `/status` |

---

## Routes

| Path | Serves | Access |
|---|---|---|
| `/hub` | Directory of all services with live health | LAN + tailnet |
| `/status` | Health, **job history**, errors, log tails, diagnostics | LAN + tailnet |
| `/openwebui`, `/chat` | 302 redirect to `/app/` | open |
| `/app/*` | Open WebUI (prefix stripped) | open |
| `/ollama/*` | Ollama REST API (prefix stripped) | LAN + tailnet |
| `/health` | One word: `ok` / `warn` / `fail` | open |
| `/status/api` | Full status as JSON | LAN + tailnet |

### Why `/openwebui` redirects instead of serving in place

Open WebUI is a SvelteKit app requesting assets from absolute root paths (`/_app/…`, `/static/…`) with no base-path setting. Serve it under a prefix and strip that prefix, and the HTML arrives but every asset request lands at the root, misses the route, and 404s — a blank page. This is a long-standing upstream limitation, not a misconfiguration here.

So `/openwebui` issues a **302 to `/app/`**, a prefix Caddy strips before proxying. You get a memorable URL; the app gets the root-relative paths it needs. It is a 302 rather than 301 so browsers do not cache it permanently, leaving the door open for a true rewrite if upstream ever adds base-path support.

The Ollama API is a plain REST API with no asset loading, so it *is* served properly under `/ollama/`.

> **Security note on `/ollama/`:** Ollama has no authentication. Anyone who can reach it can run inference, pull models, and fill your disk. It is behind the same strict allowlist, and Ollama's own port stays bound to `127.0.0.1`. It is exposed here only so scripts on your own machines have one consistent address.

## What it is

```
http://<your-pi>/status
```

A single page showing whether everything is working, what recently went wrong, and a button that builds a diagnostic bundle you can download and share. It exists for the moment when something is broken and you would rather look at a screen than SSH in and start typing commands.

It shows:

- **Services** — Open WebUI, Ollama, and the GPU pod, with response times
- **Scheduled jobs** — the last outcome of every backup, integrity check, restore rehearsal, retention prune and install, with staleness detection
- **System checks** — container states, disk, memory, installed models, backup freshness, database health
- **Recent errors** — filtered from the last 250 log lines of each service
- **Log tails** — collapsible, last 40 lines per service
- **Download diagnostic** — one click, no terminal

The page auto-refreshes every 30 seconds, and pauses refreshing while a download is in progress or the tab is hidden.

`http://<your-pi>/` now serves Open WebUI through the same proxy. Port `3000` stays published, so existing bookmarks keep working.

---

## Security

This page reveals service state, log excerpts, and offers a downloadable bundle. That is useful to you and useful to an attacker, so it is locked down deliberately.

### It holds no secrets

The status container is **not given `.env`**, any API key, or any credential. It cannot leak what it was never given. The only configuration it receives is `TAILSCALE_IP` and `VLLM_PORT` — a private mesh address and a port number, and the address is masked in all output anyway.

This is why the web diagnostic is deliberately narrower than `./collect-diagnostics.sh`: the CLI tool can report which config keys are set and how long their values are, because it runs as you on the host. The web service cannot, because giving it that access would make it worth attacking.

### It never reads your content

Chat databases, uploads, and the vector store are **measured** — file sizes, row counts — never opened for their contents. The SQLite connection is opened with a read-only URI so it cannot lock out the running application.

### Access is restricted by source address

Caddy allows `/status` only from loopback, RRC1918 private ranges, and the Tailscale mesh (`100.64.0.0/10`). Anything else gets the connection closed with no response body, revealing nothing about what runs here.

The status container publishes **no ports of its own**. The proxy is the only route in, which is what stops the allowlist being bypassed by connecting directly.

### The container is starved of privilege

`read_only: true`, `cap_drop: ALL`, `no-new-privileges`, an unprivileged user, a 16 MB tmpfs for `/tmp`, and every data mount read-only.

### Output is redacted anyway

Log lines pass through the same patterns as `collect-diagnostics.sh` — RunPod and Tailscale keys, AWS and GitHub tokens, JWTs, bearer headers, credentials in URLs, private key blocks — as defence in depth, in case some upstream component wrote a credential into a log.

### The Docker socket caveat — read this

The status container mounts the Docker socket. It is mounted `:ro` and **this app only ever issues HTTP GET requests** — there is no code path in `app.py` that starts, stops, or modifies a container.

But you should understand what `:ro` actually means here: it makes the *socket file* read-only, **not the Docker API**. Anything that can talk to that socket can in principle control Docker, and controlling Docker is equivalent to root on the host.

The mitigations are that the app is tiny and auditable, issues only GETs, holds no credentials, and is unreachable except from your own networks. If your threat model needs more, put a filtering socket proxy in front of it (restricted to `CONTAINERS=1`, `GET` only) and point `DOCKER_SOCKET` at that instead. For a single-user home system the current arrangement is a reasonable trade; for anything shared, add the proxy.

### Adding a password

Network restriction stops the internet. It does not stop a guest on your wifi or another device you own that gets compromised. To add a password, generate a hash:

```bash
docker run --rm caddy:2-alpine caddy hash-password --plaintext 'your-password'
```

Then add this inside the `handle /status*` block in `Caddyfile`, above `reverse_proxy`:

```
basic_auth {
    admin <paste-the-hash-here>
}
```

Restart with `./install.sh`. The hash is safe to commit; the plaintext never is.

---

## Endpoints

| Method | Path | Returns |
|---|---|---|
| `GET` | `/hub` | The landing page |
| `GET` | `/status` | The status page |
| `GET` | `/status/api` | The same data as JSON — useful for scripting or monitoring |
| `POST` | `/status/diagnostic` | Builds a bundle and returns it as a download |
| `GET` | `/status/healthz` | Liveness probe used by Docker and Caddy |
| `GET` | `/status/health-summary` | One word, served at `/health`. `200` when ok, `503` when degraded, no detail disclosed — safe for an external uptime monitor |

The JSON endpoint makes external monitoring easy:

```bash
curl -s http://localhost/status/api | jq -r '.overall'
curl -s http://localhost/status/api | jq -r '.checks[] | select(.state!="ok") | "\(.name): \(.detail)"'
```

---

## Why standard library only

No Flask, no FastAPI, nothing from pip. Fewer dependencies means a smaller supply-chain surface and nothing extra to keep patched — which matters more than usual for a service that touches the Docker socket.

It also means no build step: `app.py` is mounted read-only into the stock `python:3.12-slim` image, so there is no waiting for a Docker build on a Raspberry Pi and no custom image to rebuild when you edit the file.

---

## Design notes

**A stopped GPU pod reports `info`, never `fail`.** The pod is stopped most of the time on purpose, to avoid billing. Colouring that red would train you to ignore red, and the first thing an alert system must do is stay worth believing.

**Hints are commands, not descriptions.** Every non-healthy check carries the actual command to run next, so the page ends the investigation rather than starting one.

**Docker's log stream is demultiplexed.** When a container has no TTY, Docker interleaves stdout and stderr with 8-byte binary headers. `demux_docker_stream()` unpacks them; without it you get control characters scattered through the output.

**Probes run in parallel.** Each has a short timeout, but run sequentially a total outage would make every probe wait out its timeout in turn — 20+ seconds to render, slowest exactly when you are staring at it. In parallel the page is as slow as the single slowest probe, not the sum. Measured: ~20s down to ~5s under total outage.

**Job history comes from event logs, not systemd.** The container is isolated from the host's systemd on purpose. `backup.sh` and `install.sh` write structured `EVENT ts=… event=… key=value` lines, and the status page parses the last outcome of each. Slightly indirect, but it avoids handing this container host access it does not otherwise need.

**Every probe fails safe.** Each one is individually wrapped, so an unreachable Docker socket or a missing file degrades that single row rather than breaking the page. If page rendering itself throws, the error is displayed instead of a blank 500 — a status page that goes silent when things break is worse than useless.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `/status` returns 403 or nothing | Your client is outside the allowlist | Connect over the LAN or tailnet. Check the ranges in `Caddyfile` |
| Port 80 already in use | Another web server is running | `sudo ss -tlnp \| grep :80`; stop it, or change the published port in `docker-compose.yml` |
| Containers show "not found" | Socket permissions | Confirm `DOCKER_GID` in `.env` matches `stat -c '%g' /var/run/docker.sock`, then re-run `./install.sh` |
| Logs are empty on the page | The app cannot read the socket | Same as above — check `docker compose --env-file .env logs status` |
| `backup.log` mounted as a directory | Docker created it before the file existed | `./install.sh` now detects and repairs this automatically |
| Download button fails | The service errored while building | Check `docker compose --env-file .env logs status` |
| Page loads but every check fails | The status container cannot reach the others | Confirm all are on the `hybrid-ai` network: `docker network inspect hybrid-ai` |

### Backed up

`status/` — including your `Caddyfile` with any `basic_auth` hash or allowlist changes — is captured in every backup under `host/status/`. `restore.sh` offers to put your customised version back if it differs from what is in git. Your proxy configuration survives a rebuild onto new hardware.

To disable the status page entirely, remove the `status` and `proxy` services from `docker-compose.yml` and re-run `./install.sh`. Nothing else depends on them.
