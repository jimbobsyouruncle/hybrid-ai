# `status/` — Status Page

| File | Purpose |
|---|---|
| `app.py` | The status service — a small standard-library-only Python web app |
| `Caddyfile` | Reverse proxy config giving you one address for everything, and the IP allowlist protecting `/status` |

---

## Routes

The `http://{$LOCAL_DOMAIN}` block:

| Path | Serves | Access |
|---|---|---|
| `/status*` | Health, **job history**, errors, log tails, diagnostics, and `/status/api` as JSON | LAN + tailnet |
| `/hub*` | Directory of all services with live health | LAN + tailnet |
| `/health` | One word: `ok` / `warn` / `fail` (rewritten to `/status/health-summary`) | open |
| `/ollama/*` | Ollama REST API (prefix stripped) | LAN + tailnet |
| `/openwebui*` | 302 to the site root (deep links preserved) | open |
| `/chat*` | 302 to the site root (deep links preserved) | open |
| anything else | Open WebUI, proxied straight through | open |

Two more site blocks: `http://status.{$LOCAL_DOMAIN}` redirects `/` to `/status` with a 302 and proxies to `status:8088`; `http://hermes.{$LOCAL_DOMAIN}` proxies to `hermes:8501`. Both import the same allowlist and the same response-header snippet. The `/openwebui` and `/chat` aliases redirect to the site root; they carry no allowlist, because their only target is the open catch-all below, which has its own login.

### Why Open WebUI is served at the root

Open WebUI is a SvelteKit app requesting assets from absolute root paths (`/_app/…`, `/static/…`) with no base-path setting. Serve it under a prefix and strip that prefix, and the HTML arrives but every asset request lands at the root, misses the route, and 404s — a blank page. This is a long-standing upstream limitation, not a misconfiguration here.

So the Caddyfile serves it from the site root: the `http://{$LOCAL_DOMAIN}` block's catch-all `handle` proxies to `open-webui:8080` with no prefix to strip. There is no `/app/` prefix. The friendly `/openwebui` and `/chat` aliases exist again: each answers with a 302 to the site root, and a deep link such as `/openwebui/some/path?q=1` redirects to `/some/path?q=1`, keeping the query string. Port `3000` also stays published, so a direct address keeps working.

The Ollama API is a plain REST API with no asset loading, so it *is* served properly under the `/ollama/` prefix.

> **Security note on `/ollama/`:** Ollama has no authentication. Anyone who can reach it can run inference, pull models, and fill your disk. It is behind the same strict allowlist, and Ollama's own port stays bound to `127.0.0.1`. It is exposed here only so scripts on your own machines have one consistent address.

## What it is

```
http://<your-pi>/status
```

A single page showing whether everything is working, what recently went wrong, and a button that builds a diagnostic bundle you can download and share. It exists for the moment when something is broken and you would rather look at a screen than SSH in and start typing commands.

It shows:

- **Services** — Open WebUI, Ollama, Hermes Agent, OpenHands, and the GPU pod, with response times
- **Scheduled jobs** — the last outcome of every backup, integrity check, restore rehearsal, retention prune and install, with staleness detection
- **System checks** — container states, disk, memory, installed models, backup freshness, deploy verification, database health
- **Recent errors** — filtered from the last 120 log lines of each service
- **Log tails** — collapsible, last 40 lines per service
- **Download diagnostic** — one click, no terminal

The page auto-refreshes every 60 seconds, and pauses refreshing while a download is in progress or the tab is hidden.

`http://<your-pi>/` now serves Open WebUI through the same proxy. Port `3000` stays published, so existing bookmarks keep working.

---

## Security

This page reveals service state, log excerpts, and offers a downloadable bundle. That is useful to you and useful to an attacker, so it is locked down deliberately.

### It holds no secrets

The status container is **not given `.env`**, any API key, or any credential. It cannot leak what it was never given. Its whole configuration is `STATUS_PORT`, `LOCAL_DOMAIN`, `OLLAMA_URL`, `WEBUI_URL`, `HERMES_URL`, `OPENHANDS_URL`, `WEBUI_DATA_PATH`, `BACKUP_LOG_PATH`, `INSTALL_LOG_PATH`, `POST_DEPLOY_VERIFY_LOG_PATH`, `RUNPOD_HOST`, `RUNPOD_KEY_PRESENT`, `PI_HOST`, `VLLM_PORT`, `PYTHONDONTWRITEBYTECODE` and `DO_NOT_TRACK` — service addresses, host names, port numbers, container-side file paths and two static flags. None of it is a secret; the one hostname that could be sensitive, `RUNPOD_HOST`, is masked in all output anyway. `RUNPOD_KEY_PRESENT` is a derived presence boolean — `1` when the host has `RUNPOD_API_KEY` set, empty otherwise — not a credential. Retrieving the key value itself from this container is impossible: compose passes only `${RUNPOD_API_KEY:+1}`, so the value never enters it. `RUNPOD_HOST` is a MagicDNS **name**, never a stored address: the container resolves it through the `dns:` resolver on the status service each time the GPU pod tile is probed, and only the resolved address is validated against `[IP_ADDRESS]/10`.

This is why the web diagnostic is deliberately narrower than `./collect-diagnostics.sh`: the CLI tool can report which config keys are set and how long their values are, because it runs as you on the host. The web service cannot, because giving it that access would make it worth attacking.

### It never reads your content

Chat databases, uploads, and the vector store are **measured** — file sizes, row counts — never opened for their contents. The SQLite connection is opened with a read-only URI so it cannot lock out the running application.

### Access is restricted by source address

Caddy allows `/status`, `/hub` and `/ollama` only from loopback, RFC1918 private ranges, the Tailscale mesh (100.64.0.0/10), and the Tailscale IPv6 ULA range (fd7a:115c:a1e0::/48). The `trusted_only` snippet is imported inside each protected `handle` block, not at site level, because Caddy evaluates a matching `handle` before a site-level `abort`/`respond` — a site-level import on its own is bypassed by the handle routes. Anything else gets the connection closed with no response body, revealing nothing about what runs here.

The status container publishes **no ports of its own**. The proxy is the only route in, which is what stops the allowlist being bypassed by connecting directly.

### System checks

Each system check is a row with a state (`ok`, `warn`, `fail` or `info`), a one-line detail, and — when something needs attention — the exact command to run next.

| Tile | Reads | States |
|---|---|---|
| Containers | Docker socket (GET only) | `ok` running, `warn` not found / unhealthy, `info` stopped |
| Resources | Disk and memory | `ok`, `warn` above 80 %, `fail` above 90 % |
| Local models | Ollama `/api/tags` | `ok`, `warn` none installed, `fail` unreachable |
| Backups | `backup.log` | `ok` within 36 h, `warn` within 168 h, `fail` older; `warn` when the log is absent, unreadable or empty |
| Deploy verification | The post-deploy verifier log | `ok` on `PASS`, `fail` on `FAIL`/`TIMEOUT`, `warn` when nothing is readable yet |
| Data | `webui.db` (read-only) | `ok`, `warn` missing or unreadable |

#### Backups

The **Backups** tile reads the same log the backup system writes, mounted
read-only as a single file at `/data/backup.log` (`BACKUP_LOG_PATH`). The host
side of that mount is `${BACKUP_LOG:?BACKUP_LOG must be set - run ./install.sh}`:
`scripts/lib/hybrid-ai-env.sh` resolves it once from the mode, and `install.sh`
writes that resolved value into the stack env file. In system mode it is the
units' `LogsDirectory=` file (`/var/log/hybrid-ai-backup/backup.log`); in user
mode it is `$HYBRID_AI_LOG_DIR/backup.log`, exactly as before. Writer and reader
therefore name one path, which is why `Backup: ok` appears after a real success.

A log the container cannot open, a log that does not exist, and a log that
exists but is empty are three different faults, so the tile gives three
different messages. Each one is `warn`; none is ever reported as `ok`.

| Situation | Detail | Hint says |
|---|---|---|
| The mounted path does not exist | `no backup log found` | Re-run `./install.sh` |
| The file exists but `open()` raises `OSError` | `backup log not readable — permission denied for uid <n>, owner <uid>:<gid>` | `BACKUP_GROUP_GID` must be the backup group's gid |
| The file exists but holds no lines | `backup log is empty` | Run `./backup/backup.sh` |
| Lines exist, no `event=backup_success` | `no successful backup recorded` | Run one now: `./backup/backup.sh` |

When the last success is stale enough to warn or fail, the tile's hint names the
journal command for the mode this host installed, read from the **last**
`backup_schedule_installed` event in the install log (already mounted read-only
at `INSTALL_LOG_PATH`): `mode=system` names
`sudo journalctl -u hybrid-ai-backup-upload.service -n 50`, anything else (user
mode, no such event, or an unreadable or missing log) keeps the user-mode
string `journalctl --user -u hybrid-ai-backup.service -n 50`. The Jobs tile's
Backup-overdue hint uses the same command.

A failed run writes **two** `event=backup_failed` lines (`backup.sh`'s `die()`
logs one and the `ERR` trap calls `die` again), so the detail counts **distinct
`ts=` values — failed runs — not lines**. `event=backup_incomplete` is counted
once per line, as before.

The unreadable case names the reader's uid and the file's **numeric** owner ids
from `os.stat` — the same kind of detail the tile already shows, and no path or
file content beyond it. This matters because the two cases used to look
identical: a host whose backups worked but whose log the container could not
read reported the same quiet message as a host with no log at all.

The reader reaches the log through exactly one supplementary group. In system
mode the writer keeps the log at mode **0640** owned by `hybrid-ai-backup`, and
`docker-compose.yml` gives this service that group's gid through
`BACKUP_GROUP_GID` (`group_add`). The service still runs as uid 1000, keeps its
primary gid for the Docker socket, drops every capability, and stays read-only
with `no-new-privileges`. In user mode `BACKUP_GROUP_GID` is the container's own
primary gid, so it gains nothing.

#### Deploy verification

A deploy runs `scripts/run-post-deploy-verify.sh` in a transient unit after every deploy. That unit appends one block per run to its log: a header `waiting for <40-hex-sha> at <UTC-timestamp>`, then exactly one verdict — `PASS`, `FAIL: <detail>` or `TIMEOUT: <detail>`. The **Deploy verification** tile reads the **last** block:

- **`ok`** — the revision verified: the tile names the short sha and the timestamp.
- **`fail`** — the verifier reported `FAIL` or `TIMEOUT`; the tile quotes the verdict and points at `journalctl -u 'hybrid-ai-post-deploy-verify-*'` for the full run.
- **`warn`** — no verdict is readable: the log is absent, empty, a directory (Docker creates one when the bind source does not exist yet), unreadable by the status container, or has no parseable `waiting for` line. The detail says which.

The log is mounted **read-only, single file** into the container at `/data/post-deploy-verify.log` from `${HYBRID_AI_POST_DEPLOY_VERIFY_LOG:-/var/log/hybrid-ai-post-deploy-verify.log}`, the same pattern as `backup.log` and `install.log`. It holds only shas, timestamps and verdict lines — no credential, no environment value — and every emitted string still passes `redact()`.

This complements the check `doctor.sh` added in PR #94, which surfaces the verdict at the **next** deploy; this tile is visible within about a minute of the verdict being written.

### Response headers are uniform across the proxy

Every route through the proxy answers with the same four response-header operations, defined once in the `(secure_headers)` snippet:

```
(secure_headers) {
    header {
        X-Content-Type-Options nosniff
        X-Frame-Options DENY
        Referrer-Policy no-referrer
        -Server
    }
}
```

- `X-Content-Type-Options: nosniff` stops a browser from guessing a content type and running, say, a log tail as HTML.
- `X-Frame-Options: DENY` stops the status page being framed, which blocks clickjacking.
- `Referrer-Policy: no-referrer` stops URLs leaving your network when you follow a link from a page it serves.
- `-Server` deletes the `Server` header, so neither Caddy's version nor an upstream's is advertised. It applies to proxied responses and to the 302s Caddy generates itself.

The snippet deliberately adds **no** `Content-Security-Policy` and **no** `Cache-Control`. `app.py` already sets a strict CSP and `Cache-Control: no-store` on every response it serves, and the bare `header` form replaces rather than appends, so the app's values pass through untouched.

`secure_headers` is imported inside every handle and on every site, not once at site level. Caddy runs a matching `handle` before site-level directives, so a site-level import alone would leave the catch-all (Open WebUI), `/ollama/*`, the `hermes.` site, and the alias 302s unstamped. The two alias handles import it inside their `route { }` block so the header handler runs before the redirect and cannot be reordered out.

### The container is starved of privilege

`read_only: true`, `cap_drop: ALL`, `no-new-privileges`, an unprivileged user, a 16 MB tmpfs for `/tmp`, and every data mount read-only.

### Output is redacted anyway

Log lines pass through the same patterns as `collect-diagnostics.sh` — RunPod and Tailscale keys, AWS and GitHub tokens, JWTs, bearer headers, credentials in URLs, private key blocks — as defence in depth, in case some upstream component wrote a credential into a log.

### The Docker socket caveat — read this

The status container mounts the Docker socket. It is mounted `:ro` and **this app only ever issues HTTP GET requests** — there is no code path in `app.py` that starts, stops, or modifies a container.

But you should understand what `:ro` actually means here: it makes the *socket file* read-only, **not the Docker API**. Anything that can talk to that socket can in principle control Docker, and controlling Docker is equivalent to root on the host.

The mitigations are that the app is tiny and auditable, issues only GETs, holds no credentials, and is unreachable except from your own networks. If your threat model needs more, put a filtering socket proxy in front of it (restricted to `CONTAINERS=1`, `GET` only) and point `DOCKER_SOCKET` at that instead. For a single-user home system the current arrangement is a reasonable trade; for anything shared, add the proxy.

### Adding a password

Network restriction stops the internet. It does not stop a guest on your wifi or another device you own that gets compromised. The proxy can gate every `*.daemonhub.dev` HTTPS site (the apex, `hermes.`, `status.` and the wildcard catch-all) behind a login page. This is **additive** to the network allowlist: it never replaces it.

The gate is off by default. With it off, the rendered Caddyfile is byte-identical to the one without the gate, and the `http://*.jarvis.lan` names stay open during the transition.

When the gate is on, Caddy's `(auth)` snippet does a `forward_auth` to a small `auth` service. Caddy asks the service to `/verify` on every request. A valid session cookie passes; anything else gets the login page, and the service sends the browser back to where it was headed after a successful login. The service issues a signed cookie (`hybrid_ai_auth`) whose `Domain` is your `TLS_DOMAIN`, so one login covers the apex, `hermes.`, `status.` and the wildcard. The cookie lives for `HYBRID_AI_AUTH_COOKIE_MAX_AGE` seconds (default 86400, one day).

1. Generate a bcrypt hash. The plaintext never enters the repository:

   ```bash
   docker run --rm caddy:2.11-alpine caddy hash-password
   ```

2. Generate the cookie signing key once, by hand:

   ```bash
   openssl rand -hex 32
   ```

3. In the stack env file (`.env`, mode `0600`), set:

   ```
   AUTH_ENABLED=on
   HYBRID_AI_AUTH_USER=<your-user-name>
   HYBRID_AI_AUTH_HASH=<the-bcrypt-hash-from-step-1>
   HYBRID_AI_AUTH_COOKIE_SECRET=<the-hex-output-from-step-2>
   HYBRID_AI_AUTH_COOKIE_MAX_AGE=86400
   ```

   Paste the hash **as-is**. Docker Compose interpolates `$` in env-file
   values, so `install.sh` writes the user, the hash and the cookie secret with
   every `$` doubled (`$$`) when it rewrites `.env`; Compose collapses that back
   to one `$` for the container. Do not add the `$$` yourself, and do not worry
   if a later `install.sh` run shows the doubled form — it is idempotent.

   With TLS off, `AUTH_ENABLED=on` gates nothing: the gate renders only on the
   `*.daemonhub.dev` HTTPS sites, which do not exist until TLS is enabled.
   `install.sh` prints a warning in that combination. See
   `docs/tls-acme-design.md` section 4.7.

4. Apply it:

   ```bash
   ./install.sh
   ```

The install fail-closes before it renders anything: with TLS on and `AUTH_ENABLED=on`, an empty `HYBRID_AI_AUTH_USER`, `HYBRID_AI_AUTH_HASH` or `HYBRID_AI_AUTH_COOKIE_SECRET` stops the install with a message naming every missing variable. The auth service refuses to start without them too, as a second layer.

The credentials reach only the `auth` service; they no longer go to the proxy container, and no credential literal is ever written into a tracked file.

`/health` is deliberately exempt: it is the open endpoint the external uptime monitor polls, so it answers without a prompt. Every other route on the gated sites, and the `hermes.`, `status.` and wildcard site blocks, require a login.

**Sessions and rotation.** The login page's session expires after `HYBRID_AI_AUTH_COOKIE_MAX_AGE` seconds. To log everyone out at once, replace `HYBRID_AI_AUTH_COOKIE_SECRET` with a fresh `openssl rand -hex 32` and re-run `install.sh`: every cookie signed with the old key stops verifying. Changing the password or the user name does not drop existing sessions; rotate the secret when you need that.

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

**A stopped GPU pod reports `info`, never `fail`.** The pod is stopped most of the time on purpose, to avoid billing. Colouring that red would train you to ignore red, and the first thing an alert system must do is stay worth believing. So the tile reports wake readiness, not reachability: an unresolved MagicDNS name is `info` when a RunPod API key is configured (the pod can be woken on demand) and `warn` when none is (it cannot be woken, so the hint points at `sudo ./install.sh` to set `RUNPOD_API_KEY`).

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
| `backup.log` mounted as a directory | Docker created it before the file existed | `./install.sh` now detects and repairs this automatically. The host side is the resolved `BACKUP_LOG` (`${BACKUP_LOG:?BACKUP_LOG must be set - run ./install.sh}`) |
| Backups says "no successful backup recorded" though backups succeed | The container is reading a different file than the units write | `BACKUP_LOG` must resolve to the units' log in system mode. Re-run `./install.sh` so the stack env file carries the resolved value; see `docs/TROUBLESHOOTING.md` |
| Download button fails | The service errored while building | Check `docker compose --env-file .env logs status` |
| Page loads but every check fails | The status container cannot reach the others | Confirm all are on the `hybrid-ai` network: `docker network inspect hybrid-ai` |

### Backed up

`status/` — including your `Caddyfile` with any allowlist changes — is captured in every backup under `host/status/`. `restore.sh` offers to put your customised version back if it differs from what is in git. Your proxy configuration survives a rebuild onto new hardware.

To disable the status page entirely, remove the `status` and `proxy` services from `docker-compose.yml` and re-run `./install.sh`. Nothing else depends on them.
