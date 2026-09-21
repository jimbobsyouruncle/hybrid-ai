# Security

This document records the threat model, the findings from a secure-code review against the OWASP Top 10 (2021) and OWASP ASVS, and the controls now enforced in the codebase.

---

## Threat model

**What is being protected:** the content of your prompts and documents, the credentials that control cloud spend, and the integrity of code that runs on trusted hardware.

**Who this defends against:**

| Adversary | Capability | Mitigated? |
|---|---|---|
| Passive network observer | Sees traffic between your home and the cloud | **Yes** — WireGuard via Tailscale, plus a hard mesh-range check |
| Opportunistic internet scanner | Probes for exposed services | **Yes** — no public ports; loopback binds; no RunPod HTTP proxy |
| Compromised process on the GPU pod | Reads memory, environment, process list, filesystem | **Partly** — keys are file-based and shredded, env scrubbed, logging off |
| Malicious model weights | Arbitrary code execution on the pod | **Yes** — `--trust-remote-code` off by default |
| Compromised upstream image or action | Supply-chain substitution | **Partly** — versions pinned; no digest pinning yet |
| Someone with repo read access | Harvests committed secrets | **Yes** — gitignore plus a CI assertion |
| Cloudflare (backup storage operator) | Reads stored backup data | **Yes** — restic encrypts on the Pi; R2 holds ciphertext only |
| Ransomware on the Pi | Deletes backups, then encrypts live data | **Partly** — credentials are scoped to one bucket; full mitigation needs Object Lock (see below) |
| The infrastructure provider | Full control of the host you rent | **No** — see limitations |

**Explicit non-goals.** RunPod operates the hardware and can in principle inspect the memory of a machine you rent. This design ensures nothing is *written down* — no logs, no disk persistence, no telemetry — and that data in transit is encrypted end to end. It does not make the GPU host a trusted enclave. **For genuinely sensitive material, use the local model on the Pi.**

Data at rest on the Pi is also unencrypted unless you enable full-disk encryption yourself. Anyone with physical possession of the drive — NVMe or SD — has your entire chat history.

**Backups are encrypted client-side.** restic encrypts before upload, so Cloudflare stores ciphertext it cannot read. The repository password is the whole of that guarantee — it is never transmitted, and restic has no recovery path if it is lost.

---

## Findings and remediation

Twelve issues were identified and fixed. Severity uses CVSS-style qualitative bands.

### HIGH

**H-1 · API key transmitted in URL query string** — *A09 Security Logging and Monitoring Failures / A01 Broken Access Control*

RunPod's documentation demonstrates authentication as `https://api.runpod.io/graphql?api_key=...`. Credentials in URLs are written to proxy logs, server access logs, and browser history, and leak via `Referer` headers. RunPod's own Python SDK uses an `Authorization: Bearer` header instead.

> **Fixed.** Both `runpod_pipe.py` and `start.sh` now send `Authorization: Bearer`. In `start.sh` the header is supplied through `curl --config` reading from a process substitution, so the key never appears in `argv` either.

**H-2 · Tailscale auth key exposed in the process list** — *A01 Broken Access Control*

`tailscale up --authkey=<value>` places the key in `/proc/<pid>/cmdline`, readable by every process on the pod. A reusable, pre-approved key grants the ability to join arbitrary devices to your private network.

> **Fixed.** The key is written to a `0600` file, passed as `--auth-key=file:<path>`, then `shred`ed. Tailscale documents the `file:` prefix for exactly this purpose.

**H-3 · Arbitrary code execution via `--trust-remote-code`** — *A08 Software and Data Integrity Failures*

This flag makes vLLM execute Python shipped inside the model repository, with full access to the pod and its credentials. Because weights are re-fetched on cold start, a model modified upstream would execute silently on the next run. Qwen2.5-Coder does not require it.

> **Fixed.** Removed from the default invocation. Opt in with `TRUST_REMOTE_CODE=1`, which emits a loud warning.

### MEDIUM

**M-1 · Model API bound to `0.0.0.0`** — *A01 Broken Access Control*

vLLM's API has no authentication whatsoever. Binding to all interfaces exposed it to every network the pod is attached to, including the provider's internal network.

> **Fixed.** Bound to `127.0.0.1`. In userspace-networking mode `tailscaled` forwards inbound mesh connections to loopback, so tailnet access is unaffected while every other interface is closed.

**M-2 · Shell injection via `source .env`** — *A03 Injection*

`install.sh` loaded configuration with `source`, which executes the file as shell code. A value containing `$(...)` or backticks would run as a command. The blast radius was limited because the file is machine-generated, but a restored backup or hand-edit could trigger it.

> **Fixed.** Replaced with a line-by-line parser that accepts only well-formed `KEY=value` pairs and assigns via `printf -v`, which never evaluates the value.

**M-3 · Mutable third-party action reference** — *A08 Software and Data Integrity Failures*

`ludeeus/action-shellcheck@master` runs whatever that branch points at today, inside a job with access to your secrets.

> **Fixed.** Pinned to a release tag. For anything handling credentials, pinning to a full commit SHA is stronger still.

**M-4 · Unpinned container images** — *A08 Software and Data Integrity Failures*

`ollama/ollama:latest` and `open-webui:main` change underneath you on every `pull`. `:main` in particular tracks a development branch.

> **Fixed.** Both pinned to explicit versions. Verify and bump deliberately.

**M-5 · No SSH host key verification** — *A02 Cryptographic Failures*

The deploy action connected without verifying the Pi's host key, so anything able to occupy that tailnet address could impersonate the Pi and capture the deploy key.

> **Fixed.** Added a `fingerprint` parameter sourced from a new `PI_SSH_HOST_KEY` secret. **Action required:** see setup below.

**M-6 · Verbose error disclosure** — *A09 Security Logging and Monitoring Failures*

Error paths echoed raw exception text and up to 500 characters of upstream response body into the chat window. Library exceptions frequently embed the full request, including headers.

> **Fixed.** Added a `_scrub()` helper that redacts anything matching a credential shape (`rpa_…`, `tskey-…`, `Authorization:`, `api_key=`) before display, with excerpts truncated.

### LOW

**L-1 · Unvalidated numeric configuration** — *A05 Security Misconfiguration.* A zero `POLL_INTERVAL` would busy-loop; an unbounded `MAX_TOKENS` would pin the GPU indefinitely. **Fixed** — bounds-checked in `_preflight()`.

**L-2 · Client-controlled `max_tokens`** — *A04 Insecure Design.* A request could exceed the configured ceiling, holding the billing meter open. **Fixed** — clamped with `min()`.

**L-3 · `--accept-routes` on the pod** — *A01.* The pod accepted subnet routes advertised by other nodes, widening the network reachable from a compromised pod for no benefit. **Fixed** — removed.

**L-4 · Credentials in documented shell commands** — *A09.* Example `curl` commands placed the API key in the URL, landing it in shell history. **Fixed** — all examples now use a header.

---

## Residual risks

Accepted, with rationale:

| Risk | Why accepted | Compensating control |
|---|---|---|
| Plaintext HTTP to vLLM | TLS inside an already-encrypted WireGuard tunnel adds certificate management for no meaningful gain | Mesh-range enforcement; loopback bind |
| vLLM has no authentication | It is unreachable except through the tailnet | Tailnet ACLs; loopback bind |
| `curl \| sh` installs Tailscale | Vendor-recommended install path | Prefer a custom image (option C in `runpod/README.md`), which removes runtime fetching |
| Provider can inspect pod memory | Inherent to rented compute | Keep sensitive work on the local model |
| No encryption at rest on the Pi | Out of scope for the default setup | Enable LUKS if the physical device is a concern |
| Images pinned by tag, not digest | Tags are mutable in principle | Digest pinning is the stronger option if you want it |

---

## Required action for existing deployments

**1. Add the SSH host key secret.** On the Pi:

```bash
ssh-keyscan -t ed25519 "$(tailscale ip -4)" 2>/dev/null
```

Add the output as a repository secret named `PI_SSH_HOST_KEY`. Without it the deploy job will fail — that is intentional, since the alternative is silently trusting any host.

**2. Rotate both credentials.** Earlier versions placed the RunPod key in URLs and the Tailscale key in the process list, so both should be considered exposed:

- RunPod console → Settings → API Keys → revoke and regenerate. Update the Pi's `.env` **and** the pod template.
- Tailscale admin → Settings → Keys → revoke and regenerate. Update the pod template.

**3. Confirm `--trust-remote-code` is off.** If you switched to a model that genuinely needs it, set `TRUST_REMOTE_CODE=1` explicitly and satisfy yourself the model repository is trustworthy.

---

## Ongoing practice

**Rotate quarterly.** Tailscale auth keys expire — a stale key means the pod silently stops rejoining. RunPod keys should be rotated in both locations at the same time.

**Verify the watchdog armed** after every pod template change. Its absence is a financial vulnerability:

```
[start.sh] Arming idle watchdog: 15 min @ 0% GPU -> podStop
```

**Set a hard spending cap** in RunPod billing as a backstop.

**Audit for committed secrets** before making a repository public:

```bash
git log -p | grep -iE 'rpa_[A-Za-z0-9]|tskey-|BEGIN [A-Z]* PRIVATE KEY'
```

If anything surfaces, rotate it. Rewriting history is not sufficient — clones and forks retain a copy.

**Preserve the logging discipline.** Every log line in this codebase contains metadata only. A single `print(messages)` left behind after debugging would write your entire conversation history into the container logs and undo the guarantees the rest of the system is built on.

---

## Backup subsystem security

| Control | Mechanism |
|---|---|
| Client-side encryption | restic encrypts on the Pi; R2 never sees plaintext |
| Credential separation | Backup keys live in `~/.config/hybrid-ai-backup/` (0700), outside the git repo and separate from `.env` |
| Permission enforcement | Both scripts refuse to run if credential files are not mode 0600 |
| Least-privilege token | R2 token scoped to **Object Read & Write** on **one bucket** — cannot create, delete, or reach other buckets |
| Passphrase not in environment | `RESTIC_PASSWORD_FILE` is used rather than `RESTIC_PASSWORD`, keeping it out of `/proc/<pid>/environ` |
| Safe config parsing | `r2.env` is parsed line by line, never `source`d, so a crafted value cannot execute |
| Service hardening | systemd units run as your user (not root) with `ProtectSystem=strict`, `ProtectHome=read-only`, `NoNewPrivileges`, and an explicit `ReadWritePaths` allowlist |
| Plaintext staging cleaned up | Consistent database snapshots are written to `.backup-staging/` (0700) and removed on exit, including on failure, via an EXIT trap |
| Working directories gitignored | `.backup-staging/`, `.restore-work/`, `.restore-test-*/`, `webui_data.pre-restore-*/`, `backup.log` |
| Metadata-only logging | Backup events record sizes, counts, and durations — never document names or chat content |

### Residual backup risk: deletion by a compromised host

The Pi's token can write **and** delete. An attacker with access could run `restic forget --prune` to destroy backup history before encrypting live data — the standard second stage of a targeted ransomware run.

restic's `backup` operation is inherently additive and never rewrites existing objects, so it composes cleanly with immutable storage. The hardened configuration is R2 **Object Lock** plus a non-deleting token, with `restic forget --prune` moved to a trusted machine; exclude the `/locks` path from any retention lock, since restic must clear its own locks.

Not enabled by default because it requires manual retention management. Documented in [`backup/README.md`](backup/README.md) for anyone whose threat model warrants it.

## Availability and observability review

A second review covered availability, error handling, and outcome logging. Eight issues were fixed. Each was checked against the security controls above so that no reliability fix weakened the privacy posture.

| ID | Issue | Fix |
|---|---|---|
| A-1 | Watchdog sampled GPU once a minute — short requests fell between samples and could shut down an in-use pod | Samples every 5s, uses the window peak |
| A-2 | Inherited `set -E` ERR trap could kill the watchdog on one flaky `nvidia-smi`, leaving the pod billing unmonitored | Trap cleared inside the subshell; all errors handled explicitly |
| A-3 | `nvidia-smi` failure was treated as 0% idle | "Unknown" tracked separately; 5 consecutive unreadable windows stops the pod |
| A-4 | `podStop` had one attempt; failure meant indefinite billing | 4 attempts with backoff, then local kill and a `critical` event |
| A-5 | A vLLM crash ended the script — pod stayed RUNNING but served nothing | Supervised restart loop with a finite budget, then self-stop |
| A-6 | Success assumed if the process was alive | Readiness probed against `/v1/models` before declaring ready |
| A-7 | Streams cut short looked identical to success | `[DONE]` and `finish_reason` tracked; user warned on truncation |
| A-8 | `install.sh` reported success when containers started, not when they served | Health gate polls both endpoints; exits non-zero with logs on failure |

### Security review of the logging additions

New logging was audited before being accepted:

- **No credential is passed to any log call.** Verified by grep across all three files for `API_KEY`, `AUTH_KEY`, `SECRET`, `tskey`, `rpa_`.
- **No message content is logged.** `_log_event` receives counts and durations only; never `messages`, `body`, `content`, or `delta`.
- **Defence in depth.** Every value is still passed through `_scrub()` before emission, so a credential arriving inside an exception string is redacted anyway.
- **`podstop_failure` does not echo the raw API response**, which can contain request headers. Only `errors[0].message`, truncated to 120 characters.
- **Logs are gitignored** (`install.log`, `*.log`) and created mode 0600.
- **`logger.propagate = False`** keeps these records out of Open WebUI's root logger, which may be configured more verbosely.
- **Retry logic is bounded and does not retry 4xx** other than 429, so an invalid key fails fast and loudly rather than being masked by retries.
- **`asyncio.CancelledError` is re-raised**, not swallowed — swallowing it would break task cancellation semantics.

## Final review (round 3)

A closing review covered correctness, maintainability, troubleshooting and user experience. Four defects were found and fixed, and one significant gap was closed.

### Defects

| ID | Severity | Issue | Fix |
|---|---|---|---|
| F-1 | **High** | `wait "$PID" \|\| true; exit_code=$?` always captured `0`, because `$?` reported the status of `true`. Every vLLM crash was logged as `exit_code=0` — destroying the one number you need when diagnosing why the server died | Capture inside `if wait ...; then ... else exit_code=$?; fi` |
| F-2 | Medium | `restore.sh --test` reported a scary `0/N verified` failure when `sqlite3` was merely absent, implying corrupt backups when nothing was wrong | Detects the missing tool and reports "cannot verify" distinctly from "verification failed" |
| F-3 | Low | The Open WebUI healthcheck assumed `curl` exists in the image. A missing binary would mark a perfectly healthy container "unhealthy" | Falls back through `curl` → `wget` → Python |
| F-4 | Low | `asyncio.Lock()` built in `__init__` binds to whichever event loop touches it first. If Open WebUI served the pipe from a different loop, it would produce intermittent "attached to a different loop" errors | Created lazily per-loop via `_get_wake_lock()` |

### Method note

An initial pass flagged roughly a dozen `[[ test ]] && command` lines as `set -e` hazards. **Empirical testing disproved this** — bash exempts every command in an `&&` list except the last, so those constructs are safe. They were left unchanged. Testing the assumption rather than acting on it avoided introducing churn into working code.

### New: `doctor.sh`

Diagnosis previously required running five commands and interpreting the output. `doctor.sh` now performs ~40 checks across host, configuration, containers, services, network, backups, and data integrity, and prints the specific remediation command for each problem found.

It is strictly read-only and starts, stops, or modifies nothing, so it is safe on a system already believed broken. Exit codes (`0` healthy / `1` warnings / `2` failures) make it usable from cron or monitoring.

Security properties of the new tool:

- **Reports credential names, never values.** `.env` keys are checked for presence only.
- **No credentials in the process list.** The R2 reachability probe receives a *file path* as an argument and parses it inside the subshell; secrets never reach `argv`.
- **Safe parsing.** Config is read line by line, never `source`d.
- **Validates the mesh guard.** Independently confirms `TAILSCALE_IP` falls inside `100.64.0.0/10`, so a misconfiguration is caught proactively rather than at send time.

It also surfaces three silent-failure modes that previously had no detection at all: backup timer disabled, **linger disabled** (user timers do not run when logged out, so backups silently never happen), and last-successful-backup age.

## Status page

The status page at `/status` exposes service state, log excerpts, and a diagnostic download, so it is treated as an attack surface rather than a convenience.

| Control | Mechanism |
|---|---|
| Holds no credentials | The container is never given `.env` or any API key. Only `TAILSCALE_IP` and `VLLM_PORT` — and the address is masked in all output |
| Reads no user content | Databases and uploads are measured (sizes, row counts) only; SQLite opened with a read-only URI |
| Read-only towards Docker | Socket mounted `:ro`; the app issues **only** HTTP GET. No code path starts, stops, or modifies a container |
| No file serving | No static handler exists and no user input is ever turned into a filesystem path, so path traversal is not reachable |
| Network restricted | Caddy permits `/status`, `/hub` and `/ollama` only from loopback, RFC1918, and `100.64.0.0/10`; others are aborted with no response body |
| Allowlist defined once | The trusted-network rule is a single reusable Caddy snippet imported by every protected route, so routes cannot drift apart and silently become more permissive |
| Unauthenticated Ollama API protected | `/ollama/` sits behind the same allowlist; Ollama's own port remains bound to `127.0.0.1` |
| Monitoring endpoint discloses nothing | `/health` returns one word (`ok`/`warn`/`fail`) with no detail, so it is safe to leave unrestricted for uptime checks |
| Not directly reachable | The status container publishes no ports; the proxy is the only route in |
| Container hardening | `read_only`, `cap_drop: ALL`, `no-new-privileges`, unprivileged user, tmpfs `/tmp`, all data mounts read-only |
| Output redacted | Log lines pass the same patterns as `collect-diagnostics.sh` — verified by testing all ten credential formats |
| Minimal supply chain | Python standard library only. No pip dependencies, no custom image build |
| Response hardening | Strict CSP, `nosniff`, `X-Frame-Options: DENY`, `no-referrer`, `no-store`; server version suppressed |

### Residual risk: Docker socket access

The container mounts the Docker socket to read container state and logs. **`:ro` makes the socket file read-only, not the Docker API** — anything able to talk to that socket can in principle control Docker, which is root-equivalent on the host.

Mitigations: the app is small and auditable, issues only GETs, holds no credentials, runs unprivileged with all capabilities dropped, and is unreachable from outside your own networks. For a shared or higher-risk deployment, place a filtering socket proxy (restricted to `CONTAINERS=1`, GET only) in front and repoint `DOCKER_SOCKET`. Documented in [`status/README.md`](status/README.md).

### Residual risk: no authentication by default

Access control is by source address only. That stops the internet; it does not stop a guest on your wifi or a compromised device you own. Optional basic auth is documented in `status/Caddyfile` and `status/README.md`. Not enabled by default because it adds a credential to manage for a single-user home system where network restriction is usually proportionate.

### Availability of the status page itself

| Concern | Mitigation |
|---|---|
| Slow render during an outage | Probes run in parallel via a thread pool — measured 20s → 5s under total failure |
| One failing probe breaking the page | Every probe is individually wrapped; failures degrade to a single visible row |
| Render exception returning a blank 500 | The exception is displayed (redacted) instead — a status page that goes silent when things break is worse than useless |
| Proxy misconfiguration locking you out | Open WebUI remains directly reachable on `:3000`; `install.sh` treats proxy failure as a warning, not a fatal error |

## Diagnostic collection

`collect-diagnostics.sh` produces a bundle intended to be pasted into AI chats and issue trackers, so it is treated as a data-egress path and designed accordingly.

| Control | Mechanism |
|---|---|
| Values never printed | `.env` is reported as `KEY=<REDACTED:length=N>` — name and length only |
| Layered pattern redaction | RunPod (`rpa_`), Tailscale (`tskey-`), AWS (`AKIA`/`ASIA`), GitHub (`ghp_`/`github_pat_`), JWTs, bearer and `Authorization` headers, `password=`/`token=`/`api_key=` assignments, credentials in URLs, private key blocks |
| Network detail reduced | Tailscale addresses masked to `100.x.x.N`; MAC and email addresses redacted |
| User content never read | Chat databases, uploads and vector stores are queried for **counts and sizes only** — never content |
| Self-audit | The finished file is re-scanned for eight secret patterns; matches are reported and the script exits `1` |
| Safe by default | Redaction is on unless `--no-redact` is passed, which prints a prominent warning both to the terminal and inside the file |
| Not committable | `diagnostics-*.txt` is gitignored; files are written mode 0600 |

**Verified by testing**, not by inspection: the redaction filter was run against realistic samples of all twelve credential formats, and the self-audit was confirmed to detect a deliberately planted key.

Two defects were found and fixed during that testing:

- **The self-audit was silently non-functional.** `grep -c … || echo 0` produced `"0\n0"` when nothing matched, because `grep -c` prints `0` *and* exits non-zero. The malformed value broke the numeric comparison, disabling the check. Now counts matches via `grep -o | wc -l`.
- **The configuration section rendered empty.** `printf` calls inside the parsing loop wrote to stdout rather than the report, so the single most diagnostically useful section was blank. Now wrapped so all output is captured.

Residual risk: regex redaction cannot catch a credential in an unanticipated format. The script states this plainly and instructs the user to review the file before sharing.

## Performance review (Raspberry Pi 5)

A review focused on runtime performance found one significant defect and three missed opportunities.

| ID | Issue | Fix |
|---|---|---|
| P-1 | **`OLLAMA_MAX_VRAM` was a no-op.** The install script computed a careful RAM budget and set a variable Ollama has never honoured and has since removed entirely. Memory was, in practice, completely uncapped | Replaced with `mem_limit` / `cpus` in Compose — real, kernel-enforced cgroup limits |
| P-2 | **No resource limits on any container.** A large model or a big document upload could consume all 16 GB and destabilise the host | Per-service memory and CPU caps, sized from detected RAM. Ollama is capped below total so a core remains free for the UI |
| P-3 | **Context silently capped at 4096 tokens.** Ollama applies this to every model regardless of capability, quietly truncating long chats and RAG results | `OLLAMA_CONTEXT_LENGTH` scaled to RAM (16384 at 16 GB), with `q8_0` KV-cache quantisation to keep the memory cost affordable |
| P-4 | **Status page polling cost.** Every refresh ran ~11 probes and pulled 250 log lines per service, every 30s, in every open tab — CPU competing directly with inference | 10s result cache, 120-line log scans, 60s refresh, and refresh suspended while the tab is hidden |

Hardware guidance was also corrected throughout. The previous advice implied more RAM permits larger models; on a bandwidth-bound board that is misleading. `doctor.sh` now warns when an oversized model is installed and when the system is booted from an SD card.

## Reporting a vulnerability

Open a private security advisory through GitHub's **Security → Advisories** tab rather than a public issue. Include reproduction steps and affected commit.

This is a personal-use project with no SLA, but security reports are taken seriously and credited.
