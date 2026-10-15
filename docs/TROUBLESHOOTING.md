# Troubleshooting & Operations

Start with [Diagnostic triage](#diagnostic-triage) to find which layer is failing, then jump to that section.

---

## Start here

**In a browser:** `http://<your-pi>/status`

Service health, **last run status for every scheduled job**, recent errors, log tails, and a one-click diagnostic download. Usually the fastest way to see what is wrong. `http://<your-pi>/hub` lists every service with live health.

**On the command line:**

```bash
./doctor.sh
```

One command. It checks the host, configuration, containers, services, network, backups, and data integrity, then prints exactly what is wrong and the command to fix it. It is entirely read-only, so it is always safe to run — including on a system you think is already broken.

```
./doctor.sh              full report
./doctor.sh --quiet      problems only (good for cron)
./doctor.sh --no-cloud   skip checks that contact RunPod or R2
```

Exit codes: `0` healthy, `1` warnings only, `2` something is broken. That makes it usable in monitoring:

```bash
# Email yourself if anything is wrong
0 8 * * * cd ~/hybrid-ai && ./doctor.sh --quiet || mail -s "hybrid-ai needs attention" you@example.com
```

If `doctor.sh` points at a specific area, jump to that section below.

---

## Still stuck? Collect a diagnostic bundle

```bash
./collect-diagnostics.sh
```

This gathers everything relevant — system info, container states, the last 100 log lines from each service, configuration, network status, database health, and backup status — into a single text file designed to be **shared safely**.

```
./collect-diagnostics.sh                 full report
./collect-diagnostics.sh --lines 300     more log history
./collect-diagnostics.sh --output FILE   write somewhere specific
./collect-diagnostics.sh --no-redact     UNSAFE — local debugging only
```

### What it removes

Every value that could be a credential is stripped before it is written:

| Data | How it appears in the report |
|---|---|
| `.env` values | `RUNPOD_API_KEY  <REDACTED:length=37>` — name and length only |
| RunPod / Tailscale / AWS / GitHub keys, JWTs, bearer tokens | `<REDACTED:...>` |
| Passwords embedded in URLs | `https://<REDACTED:userinfo>@…` |
| Private key blocks | `<REDACTED:private-key-block>` |
| Tailscale addresses | Masked to `100.x.x.N` |
| MAC addresses, email addresses | `<REDACTED:mac>`, `<REDACTED:email>` |
| **Chat content, documents, vectors** | **Never read at all** — only counts and sizes |

Knowing that a key is *present and 64 characters long* is almost always enough to diagnose a problem. The actual value never is.

The final section of every report is a **self-audit** that re-scans the finished file for anything still secret-shaped and warns you if it finds something. The script exits `1` in that case.

> Redaction is best-effort pattern matching, not a guarantee. **Skim the file before sharing it** — `less diagnostics-*.txt`. The script reminds you.

### Using it with an AI assistant

The report opens with a context header explaining the architecture and the non-obvious behaviours — that a stopped GPU pod is *normal*, that cold starts legitimately take minutes, that the Pi has no GPU. That framing prevents an assistant from confidently misdiagnosing intentional design as a fault.

Paste the file and describe the symptom:

> "Here is a diagnostic report from my self-hosted AI stack. The cloud model times out every time, but local models work fine. What's the root cause?"

Bundles are gitignored and written mode 0600.

---

## Scheduled jobs

The status page shows the last outcome of every job, parsed from the structured event logs:

| Job | Written by | Expected cadence |
|---|---|---|
| Backup | `backup.sh` | Nightly, 03:15 |
| Integrity check | `backup.sh --check` | Monthly |
| Restore rehearsal | `restore.sh --test` | Quarterly, manual |
| Retention prune | `backup.sh` | With each backup |
| Install / deploy | `install.sh` | On each run |

A job goes **warn** when it is overdue (a backup older than 36 hours, an integrity check older than 45 days) and **fail** when its last run errored. "Never run" is reported for backups and integrity checks, since those are expected to have happened.

From the CLI:

```bash
grep '^EVENT' backup.log | tail -20
grep '^EVENT' install.log | tail -10
curl -s http://localhost/status/api | jq '.jobs'
```

---

## Status page problems

| Symptom | Cause | Fix |
|---|---|---|
| `/status`, `/hub` or `/ollama` refuses the connection | You are outside the allowlist (private LAN + tailnet only) | Connect over the LAN or Tailscale. See `status/Caddyfile` |
| `/openwebui` returns 302 | **Expected.** It redirects to `/app/` — see the note in the README | Nothing to fix |
| `/health` returns 503 | **Expected** when any check is degraded — that is the endpoint working | Open `/status` to see which check |
| Blank Open WebUI page under a subpath | Open WebUI cannot be served from a subpath | Use `/openwebui` (which redirects) or `/app/`, never a custom prefix |
| Port 80 in use, proxy will not start | Another web server on the Pi | `sudo ss -tlnp \| grep :80` |
| Page loads, containers show "not found" | Socket group mismatch | Compare `DOCKER_GID` in `.env` with `stat -c '%g' /var/run/docker.sock`, then `./install.sh` |
| Everything on the page fails | Status container cannot reach the others | `docker network inspect hybrid-ai` |

Full detail in [`status/README.md`](../status/README.md). The status page is optional — chat works without it, which is why `doctor.sh` reports its absence as a warning rather than a failure.

---

## A red deploy caused by doctor.sh

The automated deploy runs `doctor.sh --no-cloud` on the Pi as its final gate. It reads the exit code instead of discarding it, so a broken host turns the deploy red. This is the difference that makes the gate useful:

| `doctor.sh` exit code | Meaning | Deploy result |
|---|---|---|
| `0` | Everything healthy | Green, deploy continues |
| `1` | Warnings only — working, but something needs attention | Green, prints `::warning::doctor.sh reported warnings` |
| `2` | One or more failures — something is actually broken | Red, prints `::error::doctor.sh reported failures` |
| any other | Unexpected | Red, treated the same as `2` |

How to read it from the Actions page:

1. Open the failed **deploy** job and scroll to the `Health report` section.
2. The `::error::doctor.sh reported failures` line is printed last, after the health report, the persistent-data `du`, and the backup-timer line. Those informational lines still print on a failed deploy.
3. Above that line, find the `FAIL` rows in the report. Each one names the check and the command to fix it.
4. SSH in and re-run `./doctor.sh` by hand to reproduce and iterate — it is read-only, so it is safe to run repeatedly.
5. Fix the failure, then re-run the deploy.

A missing or non-executable `doctor.sh` is also an error, not a skip. The old inline script ran it only if executable and ignored its exit code; that skip is gone, because a health gate that quietly does not run is worse than no gate. If the deploy reports `doctor.sh is missing or not executable`, the file was removed from the checkout — restore it from the repository.

Warnings (`exit 1`) never fail the deploy. If you want to silence one, fix the underlying warning rather than masking the exit code.

---

## Manual triage

If you prefer to check by hand, or `doctor.sh` itself will not run, these five commands isolate the failing layer. The first one that fails tells you which section to read.

```bash
# 1. Are the containers running?
docker compose --env-file .env ps

# 2. Is the web UI responding?
curl -fsS http://localhost:3000/health && echo " OK"

# 3. Is the local model engine responding?
curl -fsS http://127.0.0.1:11434/api/tags | jq '.models[].name'

# 4. Is the tailnet up, and is the pod known?
tailscale status | grep -E 'runpod-|^100\.'

# 5. Is the GPU pod awake and serving?
source .env && curl -fsS --max-time 5 "http://${TAILSCALE_IP}:8000/v1/models" | jq .
```

| Fails at | Go to |
|---|---|
| 1 | [Containers](#containers) |
| 2 | [Open WebUI](#open-webui) |
| 3 | [Ollama](#ollama-local-models) |
| 4 | [Tailscale](#tailscale-networking) |
| 5 | [Cloud pod](#cloud-gpu-pod) — often expected; the pod is stopped by design |

Step 5 failing with "connection refused" is **normal** when you have not used the cloud model recently. That is the pod saving you money.

---

## Containers

**Nothing listed by `docker compose ps`**

You are probably in the wrong directory, or `.env` does not exist.

```bash
cd ~/hybrid-ai
ls -la .env || ./install.sh
```

**`permission denied while trying to connect to the Docker daemon`**

Your user is not in the `docker` group, or you have not logged out since being added.

```bash
sudo usermod -aG docker "$USER"
exit          # log out and back in -- newgrp is not sufficient
```

**A container is stuck in the `paused` state**

A backup was interrupted partway through its capture. Resume it:

```bash
docker unpause open-webui
```

`backup.sh` normally unpauses from its EXIT trap even on failure, so this is rare — but a hard kill (`kill -9`, power loss) can leave it frozen.

**A container restarts in a loop**

```bash
docker compose --env-file .env logs --tail 100 open-webui
docker compose --env-file .env logs --tail 100 ollama
```

Most common causes: the disk is full, or `.env` is missing a required value.

**`no space left on device`**

```bash
df -h /
docker system prune -a --volumes=false   # safe: does not touch bind mounts
du -sh webui_data ollama_data
docker exec -it ollama ollama list       # unused models are usually the culprit
```

Note `--volumes=false`. Your data is in bind mounts, not Docker volumes, so this is safe — but get in the habit of being explicit.

**Full reset without losing data**

```bash
docker compose --env-file .env down      # NEVER add -v
./install.sh
```

**Permission errors after switching Hermes to a non-root uid**

The Hermes image now runs as a dedicated non-root uid when `HYBRID_AI_UID` is
set in `.env`. If the files under `hermes_data` were still created by root, the
non-root process cannot read or write them. You see this as `permission denied`
in the Hermes logs, or as a failed start.

`install.sh` refuses to start in this state and reports a count of files, not
their names. `./doctor.sh` warns about it too. The fix is to give the uid
ownership of the data directory:

```bash
# Set to the same value as HYBRID_AI_UID in .env.
sudo chown -R 10001:10001 hermes_data
./install.sh
```

To undo the switch, comment out `HYBRID_AI_UID` and `HYBRID_AI_GID` in `.env`
(leave them unset). Hermes then runs as uid 0 again, exactly as before the
migration.

---

## Open WebUI

**Cannot reach the page from another device**

```bash
curl -fsS http://localhost:3000/health       # works locally?
tailscale ip -4                              # use THIS address from elsewhere
```

If it works locally but not remotely, the other device is not on your tailnet.

**Logged out after a deploy**

`WEBUI_SECRET_KEY` changed. It should never change — `install.sh` reuses it. Check whether `.env` was deleted or regenerated from scratch.

**Forgot the admin password**

```bash
docker exec -it open-webui python -c "
from open_webui.apps.webui.models.auths import Auths
from open_webui.utils.utils import get_password_hash
Auths.update_user_password_by_id('YOUR_USER_ID', get_password_hash('newpassword'))
"
```

Find your user ID under **Admin Panel → Users**.

**Uploaded documents are not being found**

Ensure you selected the document (`#` in the message box) or attached the collection to the chat. Then check the vector store is actually growing:

```bash
du -sh webui_data/vector_db
```

If it is empty after uploading, embedding is failing. Check `docker compose logs open-webui` for errors — on a 4 GB Pi this is usually memory pressure.

**Embedding is extremely slow**

Expected on a Pi. Mitigations: process fewer documents at a time, use a smaller embedding model, and ensure you are not thermally throttled:

```bash
vcgencmd measure_temp           # sustained >80C means throttling
vcgencmd get_throttled          # 0x0 is healthy
```

---

## Ollama (local models)

**No models listed**

```bash
docker exec -it ollama ollama pull llama3.2:3b
```

**Model download fails partway**

Usually disk space or a dropped connection. Re-running `pull` resumes.

**Responses are extremely slow**

Almost always the model is too large for the hardware — and the limit is **memory bandwidth, not RAM**. The Pi 5 has ~17 GB/s, and every token requires reading every weight, so:

| Model | Throughput on a Pi 5 | Usable interactively? |
|---|---|---|
| 1B | ~17–21 tok/s | Yes, very |
| **3B** | **~5–8 tok/s** | **Yes — the sweet spot** |
| 7–8B | ~1–3 tok/s | No, even with 16 GB |

A 16 GB board *loads* an 8B model fine and still crawls. That is physics, not misconfiguration. Drop to 3B locally and send hard work to the GPU pod:

```bash
docker exec -it ollama ollama pull llama3.2:3b
docker exec -it ollama ollama rm llama3.1:8b     # reclaim the space
```

Other things worth checking:

```bash
./doctor.sh                       # flags oversized models and SD-card boot
vcgencmd measure_temp             # sustained >80C means throttling
findmnt -n -o SOURCE /            # mmcblk = SD card; NVMe is much faster
docker stats --no-stream          # is something else eating CPU?
```

**Booted from the wrong disk.** If you installed an NVMe drive but the Pi still boots the SD card, everything runs at SD speed while the SSD sits idle:

```bash
findmnt -n -o SOURCE /                      # want nvme0n1..., not mmcblk...
sudo rpi-eeprom-config | grep BOOT_ORDER    # NVMe should come first
```

Fix with `sudo raspi-config` → Advanced Options → Boot Order → NVMe/USB Boot.

**First response slow, later ones fast.** Normal — the model is loading from disk. On 16 GB `install.sh` sets a 30-minute keep-alive so it stays resident. NVMe makes the initial load several times faster.

**Long conversations get truncated.** Ollama caps every model at 4096 tokens unless told otherwise. `install.sh` raises `OLLAMA_CONTEXT_LENGTH` based on RAM (16384 at 16 GB); increase it in `.env` and re-run `./install.sh` if needed, at the cost of KV cache memory.

If conversations still truncate at 4096 after that, the **pinned Ollama image
is too old to honour the variable** — it is accepted and ignored. `install.sh`
now checks for this after start and warns. Confirm and fix:

```bash
docker exec ollama ollama --version
grep OLLAMA_IMAGE .env          # bump to a current release, then ./install.sh
```

**Ollama panics on model load: `V cache quantization requires flash_attn`.**
`OLLAMA_KV_CACHE_TYPE=q8_0` requires flash attention to be active. When Ollama
auto-disables flash attention for a model architecture that does not support
it, the runner aborts rather than degrading. The default is now `f16`; if you
opted into `q8_0`, revert it in `.env` and re-run `./install.sh`.

**`model requires more system memory than is available`**

```bash
free -h
grep -E 'OLLAMA_MEM_LIMIT|OLLAMA_CONTEXT_LENGTH' .env
docker stats --no-stream ollama
```

`OLLAMA_MAX_VRAM` no longer exists anywhere in this project — it was never
honoured by Ollama and has been removed upstream. The real ceiling is
`OLLAMA_MEM_LIMIT`, a kernel-enforced Docker cgroup limit, which `install.sh`
sets conservatively and deliberately. Use a smaller model rather than raising it — exceeding physical RAM pushes the Pi into swap, which is dramatically worse than simply using a smaller model — even on NVMe.

---

## OpenHands maintenance agent

OpenHands is optional. Chat, the cloud pipe and backups all work without it,
so `install.sh` warns rather than failing when it does not come up.

**The container vanished after a deploy or re-install.** Almost certainly a
`docker compose up -d --remove-orphans` that omitted the overlay file, which
makes compose treat OpenHands as an orphan and delete it. State in
`~/.openhands` survives, so recovery is just a start:

```bash
./openhands/scripts/openhands-control.sh start
```

Use that wrapper rather than bare `docker compose` — it always passes both
files.

**`OPENHANDS_WORKSPACE must be set`.** The overlay deliberately has no default
for the workspace, so it fails loudly rather than silently mounting the
deployment directory (which holds `.env`). Run `./install.sh`, or create the
clone by hand:

```bash
./scripts/setup-agent-workspace.sh
./scripts/setup-agent-workspace.sh --check
```

**`SECURITY: .env found inside the agent workspace`.** Something copied rather
than cloned. Remove the file — its presence defeats the isolation the separate
workspace exists to provide.

**The workspace-root `AGENTS.md` looks stale.** `setup-agent-workspace.sh`
refreshes the existing clone on every run: it fetches, then fast-forwards only
when the tree is clean and on the default branch. If it warns that it skipped
the refresh, the clone is dirty or on another branch, or the fetch failed — it
never resets or discards work. Bring it up to date by hand, or re-run:

```bash
./scripts/setup-agent-workspace.sh
```

**A multi-repo job edits the wrong tree.** The workspace root
(`${OPENHANDS_WORKSPACE}`) is a hybrid-ai clone holding `AGENTS.md`; it is not
the target of a job unless the task says so. A job on another owned repository
is cloned into `${OPENHANDS_WORKSPACE}/project/<repo-name>`, and the agent
works only inside that clone. Repositories do not all use `main`, so the agent
fetches and branches from the remote default branch rather than a local `main`
or `master`.

**The UI will not load.** It binds to loopback only and there is no Caddy
route, by design. Reach it through a tunnel:

```bash
ssh -L 3001:127.0.0.1:3001 <user>@<pi-tailnet-name>
./openhands/scripts/openhands-control.sh logs
```

**First start times out.** The image is large and the first pull on a Pi can
exceed the health-check window. Watch the pull, then re-check.

---

## Agent clone embeds a credential in its git remote

`./doctor.sh` prints a warning for every agent clone whose git config stores a
credential inside a remote URL:

```
! Credential embedded in a git remote: <path>/.git/config: remote.origin.url
```

Only the file path and the config key are shown. The URL, the userinfo and the
token are never printed — not on stdout, not on stderr. `scripts/check-git-remotes.sh`
is the read-only check behind the warning; it scans the roots named by
`OPENHANDS_WORKSPACE` (its root clone and `project/*/`) and `AGENT_REPOS_DIR`
(`*/`), to a depth of four, and never follows a symlink.

This is a warning, never a failure. A deploy stays green (exit `1`), because a
single live clone trips the check today and turning it into a red deploy would
block every deploy until the upstream fix lands.

**What the warning means.** OpenHands' app-server clones with a URL of the form
`https://<token>@github.com/<owner>/<repo>.git`. Git writes that URL verbatim
into `project/<repo>/.git/config` as `remote.<name>.url` (and sometimes
`pushurl`, or a `url.<base>.insteadOf` shim). The token is therefore sitting on
disk in plain text. Anyone who can read that file can read the token.

**Rotate the token in GitHub.** The credential is already on disk, so treat it
as exposed. In GitHub, open **Settings → Developer settings → Personal access
tokens** and revoke the OpenHands token, then create its replacement with the
same read-only scope (see the OpenHands token column in
[`SECURITY.md`](../SECURITY.md#github-credential-separation)). Put the new value
in `OPENHANDS_GITHUB_TOKEN` (or wherever the deploy supplies it) and restart
OpenHands. Because the token is read-only, the blast radius of the leak is
read access to the repositories it can see, not write access.

**Why hand-stripping does not hold.** Editing the URL out of `.git/config` by
hand fixes the file that exists right now. The next time OpenHands clones or
re-clones that project — which the agent-server does on demand — it writes the
`https://<token>@...` URL straight back. The strip looks like a fix for a few
minutes and then silently regresses. That is why detection, not removal, is the
control until the upgrade.

**The real fix: upgrade the agent-server.** An OpenHands agent-server at
**`1.37.0` or newer** stops embedding credentials in the clone URL and uses a
credential helper instead, so nothing sensitive lands in `.git/config`. That
upgrade is tracked separately. Until it ships, expect the warning on every
deploy and after every new clone, and re-check after rotating the token to
confirm the old value is gone.

---

## Agent repo reference tree: inventory rows and skips

`scripts/sync-agent-repos.sh` keeps the read-only reference tree at
`AGENT_REPOS_DIR` and writes `${AGENT_REPOS_DIR}/INVENTORY.md` after each run.
`install.sh` runs it near the start of every deploy, before it loads `.env`, so
the tree is current even if a later install step fails or stops. A sync failure
is only a warning; `install.sh` carries on.
Each row is one repository with its default branch, HEAD short SHA, status and
last sync time (UTC). The status is exactly one of:

| Status | Meaning |
|---|---|
| `cloned` | The repo was missing and is now cloned. |
| `updated` | An existing clone fast-forwarded to a newer default-branch commit. |
| `up-to-date` | An existing clone was already at the remote head; nothing changed. |
| `skipped:<reason>` | Left untouched this run. The reason is `dirty`, `symlinks`, `credential-remote`, or `not-a-repo`. |
| `error` | A clone or fetch failed, or a git config could not be read. |
| `stale` | Present on disk but no longer in the inventory (for example a repo you excluded in the manifest). Left in place; never deleted. |

A normal run exits `0` when all is well, `1` when anything was skipped or is
stale, and `2` on any error. Verify the tree without touching it or the network:

```bash
./scripts/sync-agent-repos.sh --check
```

`--check` reads `INVENTORY.md` and confirms each listed directory exists and its
HEAD still matches. It exits `0` ok; `1` when the inventory is older than
`AGENT_REPOS_MAX_AGE_HOURS` (default 48) or a skipped row is present; `2` when a
directory is missing, a HEAD mismatches, or the inventory is missing or
unreadable. `doctor.sh` runs this and warns (never fails) on anything but `0`.

**`skipped:dirty`.** The clone has uncommitted changes. This script only
fast-forwards and never discards work, so it leaves the tree alone. Commit or
discard the changes, or delete the clone and let the next run re-clone it.

**`skipped:symlinks`.** The clone's working tree contains a symlink. Clones are
made with `core.symlinks=false` so a repository cannot plant a symlink that
points outside the tree, but an older clone may already hold one. The script
never deletes anything, so it skips the repo and records the reason. Re-clone
that one repository by hand: delete the offending clone directory and run the
sync again, or `git clone` it yourself. Do not delete the whole tree.

**`skipped:credential-remote`.** A remote URL in the clone's git config embeds
a credential. The script refuses to fetch from it. Rotate the token in GitHub
(see the section above), then delete and re-clone that repository so the stored
URL is replaced.

**`stale`.** The directory is on disk but is no longer in the inventory, usually
because it was excluded in `agent-repos.local`. It is left in place and never
deleted; remove it by hand if you no longer want it there.

---

## Kanban board not dispatching / gateway not running

The Hermes WebUI and the Hermes gateway run in the same container. The WebUI is PID 1; the
gateway runs in the background and drains the kanban queue. Nothing supervises the background
job, so if the gateway exits the board stops dispatching while the WebUI keeps serving. The
gateway is not restarted until the container restarts.

`./doctor.sh` reports this as a warning against `hermes-agent`:

```
Hermes gateway process NOT running inside hermes-agent
```

Confirm it by hand with a read-only probe — look for a "gateway run" process:

```bash
docker top hermes-agent
```

**`Profile '<name>' does not get a gateway of its own`** in `docker logs hermes-agent`.
A sticky named active profile (for example `ciso`) stored in the bind-mounted
`hermes_data/active_profile` captures a bare `hermes gateway run` and is refused a
gateway, because there is only one gateway per host and it is owned by the default
profile. The fix is already pinned in the image `CMD` (the compose overlay sets no
`command:`): `hermes -p default gateway run --replace`. Do not switch the active profile
back to `default` by hand; the `-p default` pin makes the gateway start as the default
profile after every container create/recreate regardless of the sticky active profile.

**Fix: recreate the container.** Recreating restarts the gateway in the background and leaves the
kanban data in `hermes_data/` untouched:

```bash
${COMPOSE_CMD} up -d --force-recreate hermes
```

`${COMPOSE_CMD}` is the full compose invocation `doctor.sh` uses (project `hybrid-ai`, all three
compose files). Recreate rather than `docker exec` into the container: the background gateway is
what the image `CMD` starts, and an `exec`ed one is not tracked as that process.

---

## The Hermes image at a pinned commit: smoke-job failure modes

The `hermes-nonroot-smoke` CI job builds `hermes/Dockerfile` and runs the image as uid
`10001` on a data volume seeded with a **decoy** agent (a valid Agent source root that would
leave a marker if imported). It fails closed on these modes. Each maps to one build or
configuration change.

| Symptom | Cause | Fix |
|---|---|---|
| The build fails on `sha256sum -c -` for `/tmp/hermes-install.sh` | The installer at `HERMES_COMMIT` no longer matches `HERMES_INSTALL_SHA256`. Upstream rewrote `scripts/install.sh` at a tag, or the pin moved without the checksum. | Download `https://raw.githubusercontent.com/NousResearch/hermes-agent/<sha>/scripts/install.sh` and set `HERMES_INSTALL_SHA256` to its sha256. Never disable the check. |
| The build fails on `git rev-parse` for `/app`, or `--detach` fails | The WebUI clone at `HERMES_WEBUI_COMMIT` no longer resolves, or `main` moved. | Set `HERMES_WEBUI_COMMIT` to a commit that still exists and bump the matching string in `validate.yml`. Never clone `main` and never drop the `git rev-parse` assert. |
| The build fails on `test -x /opt/hermes-agent/.hermes/venv/bin/python` | `/opt/manifest.json` names no venv, or the venv has no interpreter. | The Agent install changed shape. Do not hand-edit the manifest; rebuild and re-check the Agent pin. |
| `git apply` fails, or `rev-parse HEAD` is not `HERMES_COMMIT` | The local patch no longer applies at the pin, or the checkout is at a different commit. | Rebase `patches/0001-kanban-prompt-body-chars.patch` onto the pinned commit, or bump `HERMES_COMMIT` deliberately. |
| `exec: /opt/hermes-agent/.hermes/bin/hermes: not found`, or the WebUI exits at once | The launcher is missing or not on `PATH`. The old failure was the launcher living under the `/root/.hermes` mount point, which the volume hid. | Confirm the build published `/opt/hermes-agent/.hermes/bin/hermes` and that `ENV PATH` names it. Never put the launcher under `/root` — that tree is `chown`ed to the runtime uid. |
| The login-shell step fails: `command -v hermes` is empty or not `/usr/local/bin/hermes` | The `/usr/local/bin/hermes` symlink is missing, or `PATH` no longer reaches `/usr/local/bin` in a login shell. | Keep the root-owned `ln -sfn ${HERMES_INSTALL_DIR}/.hermes/bin/hermes /usr/local/bin/hermes` step. A login shell rebuilds `PATH` from `/etc/profile`, so a shell-only prepend is not enough. |
| The gateway-not-running step fails (`docker top` finds no `gateway run`) | The image `CMD` did not start the gateway, or the profile pin was dropped. | Keep `hermes -p default gateway run --replace` in `hermes/Dockerfile`'s `CMD`. `validate.yml` asserts the exact string and fails closed if it is gone. |
| `bootstrap.py: error: unrecognized arguments: --port` | A `--port` flag was added. `bootstrap.py` takes the port **positionally**. | Use `... bootstrap.py --host 0.0.0.0 --foreground --no-browser --skip-agent-install 8501`. |
| `Hermes Agent was not found and auto-install was disabled.` and PID 1 exits | `--skip-agent-install` is set and the pinned agent was not found where `HERMES_WEBUI_AGENT_DIR` points. This is the intended fail-closed behaviour. | Confirm `HERMES_WEBUI_AGENT_DIR=/opt/hermes-agent` and that the agent installed. Never remove `--skip-agent-install`; without it bootstrap downloads an unpinned installer from `main`. |
| The PID 1 maps step reports a path under `/root/.hermes` | The WebUI resolved the agent dir or interpreter from the data volume (the old copy). | Confirm `HERMES_WEBUI_AGENT_DIR` and `HERMES_WEBUI_PYTHON` are set in the image ENV and that the `/opt/hermes-agent/.hermes/venv` symlink exists. Do not delete the data-volume copy to make this pass — pin the image instead. |
| The dependency-lease step fails: `HERMES_HOME` is under `/opt` | `HERMES_HOME` was pointed at the read-only install dir, moving the runtime generation lease (`installs/<key>/environments/<uuid>/.leases`) off the writable volume. | Leave `HERMES_HOME` unset so `get_default_hermes_root()` falls back to `$HOME/.hermes`. Never make `/opt` writable to route around it. |
| The decoy-marker step finds `/root/.hermes/DECOY_AGENT_IMPORTED` | The WebUI imported the data-volume copy. Same cause as the row above. | Same fix. The marker must never appear. |
| `Python environment cannot import both WebUI dependencies and Hermes Agent, and local .venv creation is disabled` | The pinned interpreter (`HERMES_WEBUI_PYTHON`) cannot import `run_agent` and a YAML backend. | This is the intended fail-closed path (`HERMES_WEBUI_DISABLE_LOCAL_VENV=1`); without it bootstrap would create `/app/.venv` at runtime. Re-check the Agent pin and the `/opt/manifest.json` venv. Do not re-enable the local venv. |
| The `docker diff` step reports paths under `/app` or `/opt` | The runtime uid wrote under the WebUI or agent code: a git checkout (the image ships none), or missing build-time bytecode. | Do not make the trees writable. Confirm the build byte-compiles `/app` and `/opt/hermes-agent` with the pinned interpreter and removes `.git`. If Hermes needs to write there, stop and report rather than loosen the tree. |

---

## Cards stay in Triage, gateway is running

A running gateway is not enough. With `kanban.auto_decompose` enabled, the decomposer picks up
each Triage card within about 60 seconds. If it cannot, cards stay in Triage and the board goes
quiet — with no error anywhere, because the gateway itself keeps running.

`./doctor.sh` reports the stall in the Containers section, naming the board and the affected task
ids only:

```
Kanban Triage stalled on board <board>: 2 task(s) older than 15m (ids: 41 57); 2 have no event other than 'created'
```

A card whose only event is `created` is the failure signature: the decomposer never touched it.
Tune the threshold with `DOCTOR_TRIAGE_STALL_MIN` (default 15 minutes, read from the environment,
not from `.env`):

```bash
DOCTOR_TRIAGE_STALL_MIN=5 ./doctor.sh
```

**Cause.** The decomposer runs on the Hermes auxiliary provider. When no GPU pod is warm it falls
back to OpenRouter, so a missing or blank `OPENROUTER_API_KEY` makes every decompose tick fail.
This is exactly what happened on 2026-10-13: the key was commented out in `hermes_data/.env` and
every 60s tick failed for about 35 minutes with no visible signal.

**Check the auxiliary provider and credential.** `doctor.sh` also warns when the deployment `.env`
or a board-running profile (`hermes_data/.env`, `hermes_data/profiles/builder/.env`,
`hermes_data/profiles/reviewer/.env`) has no OpenRouter key:

```
OPENROUTER_API_KEY is missing or empty in hermes_data/.env
```

```bash
hermes -p default config get auxiliary          # which provider the decomposer uses
grep -c '^OPENROUTER_API_KEY=' hermes_data/.env # 1 means the line is uncommented
```

**A board database that cannot be read** is reported instead of being treated as healthy:

```
Kanban Triage not stalled: cannot query board <board>
```

That means the kanban DB is corrupt, locked, not a SQLite file, or unreadable. Inspect it
read-only, for example: `sqlite3 "file:hermes_data/kanban/boards/<board>/kanban.db?mode=ro" 'PRAGMA quick_check;'`.

**Fix.** Restore the key in the relevant `.env` (see `.env.example` for the format), then recreate
the container so the gateway and decomposer pick it up:

```bash
${COMPOSE_CMD} up -d --force-recreate hermes
```

---

## Tailscale networking

**`tailscale status` reports `Stopped` or `NeedsLogin`**

```bash
sudo tailscale up
```

**The Pi's address changed**

Unusual, but it happens after certain account changes.

```bash
tailscale ip -4
```

Update the `PI_TAILSCALE_IP` GitHub secret if you use CI.

**`runpod-vllm` peer does not appear**

Expected when the pod is stopped — but the entry should persist even then. If it has vanished entirely, the ephemeral node was cleaned up. Start the pod once manually, then:

```bash
./install.sh
```

**The peer appears but is unreachable**

```bash
source .env
tailscale ping "$TAILSCALE_IP"
tailscale netcheck                   # diagnoses NAT / relay problems
```

If `tailscale ping` works but HTTP does not, vLLM has not finished starting. Check the pod's logs in the RunPod console.

**A hostname mismatch**

`TS_HOSTNAME` on the pod and `PEER_HOSTNAME` in `install.sh` must match. Both default to `runpod-vllm`. If you changed one, change the other.

---

## Cloud GPU pod

**"Cannot reach the inference pod"**

Work through it in this order:

```bash
# 1. Is the pod even known to the tailnet?
tailscale status | grep runpod-vllm

# 2. Does .env hold a plausible address?
grep TAILSCALE_IP .env          # must start with 100.

# 3. Is the pod running? Check the RunPod console.

# 4. Can we reach the model API?
source .env && curl -v --max-time 10 "http://${TAILSCALE_IP}:8000/v1/models"
```

**"Refusing to transmit: ... outside the Tailscale mesh range"**

Working as designed. `TAILSCALE_IP` is not a `100.64–127.x.x` address, which means prompts would leave the encrypted tunnel. Fix the address:

```bash
./install.sh
```

Do not disable `ENFORCE_MESH_ONLY` to make this message go away. It is the control preventing a silent data leak.

**Warm-up times out**

Cold starts legitimately take 2–5 minutes, longer without a persistent volume. Check the pod logs for:

```
[start.sh] Launching vLLM -- model=... tp=1 port=8000
```

If that line never appears, the failure is earlier — usually Tailscale auth or a missing GPU. If it appears but readiness never follows, the model is still downloading. Attach a 100 GB volume at `/workspace` so weights are cached between runs.

**The pod will not stop**

```bash
# Check the watchdog armed at boot -- look for this in the pod's logs:
#   [start.sh] Arming idle watchdog: 15 min @ 0% GPU -> podStop

# Force it:
source .env
# Key passed via header, not the URL -- URLs land in proxy and access logs.
curl -s -X POST "https://api.runpod.io/graphql" \
  -H "Authorization: Bearer $RUNPOD_API_KEY" \
  -H 'Content-Type: application/json' \
  -d "{\"query\":\"mutation{podStop(input:{podId:\\\"$RUNPOD_POD_ID\\\"}){id desiredStatus}}\"}"
```

If the watchdog never armed, `RUNPOD_API_KEY` is missing from the **pod template** — a different place from the Pi's `.env`.

**The pod stops while I am still using it**

The GPU was genuinely idle for 15 minutes — reading a long answer does not count as activity. The pipe wakes it again automatically. If the cold start is disruptive, raise `IDLE_MINUTES` on the pod, accepting the higher cost.

**Out-of-memory on startup**

Lower `GPU_MEM_UTIL` to `0.85`, reduce `MAX_MODEL_LEN` to `8192`, or move to a larger GPU.

---

## Cost control

**Verify the watchdog is armed.** After starting the pod, its logs must contain:

```
[start.sh] Arming idle watchdog: 15 min @ 0% GPU -> podStop
```

If instead you see `WARNING: ... idle watchdog DISABLED`, stop the pod immediately and add `RUNPOD_API_KEY` to the pod template.

**Set a hard spending cap** in RunPod billing settings. The watchdog is reliable, but a cap costs nothing and protects against misconfiguration.

**Check for forgotten pods weekly:**

```bash
# Key passed via header, not the URL -- URLs land in proxy and access logs.
curl -s -X POST "https://api.runpod.io/graphql" \
  -H "Authorization: Bearer $RUNPOD_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"query":"query{myself{pods{id name desiredStatus costPerHr}}}"}' | jq
```

**Remember that storage bills while stopped.** A persistent volume charges 24/7 even with the pod off. It is still worth having — re-downloading 20 GB of weights on every start costs more in GPU time than the volume does.

---

## Backup and recovery

Backups are handled by restic to Cloudflare R2, encrypted on the Pi. Full documentation is in [`backup/README.md`](../backup/README.md); this section covers diagnosis.

### Is it working?

```bash
systemctl --user list-timers 'hybrid-ai-*'        # next scheduled run
grep '^EVENT' backup.log | tail -20               # recent outcomes
journalctl --user -u hybrid-ai-backup.service -n 50
./backup/restore.sh --list                        # snapshots that exist
```

A healthy run logs `backup_success` followed by `retention_applied`. A run that uploaded but missed durable state logs `backup_incomplete` and exits **3** — it is expected sometimes and is not retried.

### Backup events

| Event | Meaning | Action |
|---|---|---|
| `backup_success` | Completed and every discovered database was captured; check `staged_mb` and `duration_s` | — |
| `backup_incomplete` | Uploaded, but durable state was missing; snapshot is tagged `complete:false` and the run exits 3 | Inspect the events alongside it: `db_path_rejected`, `hermes_data_unreadable`, `rsync_partial`, `cold_copy_fallback`. Not retried automatically |
| `db_path_rejected` | A discovered path failed the name allow-list; count only, the name is never logged | Investigate what wrote that name under `hermes_data` |
| `hermes_data_unreadable` | `find` could not read part of `hermes_data`, or it is not a readable directory | Fix permissions/ownership; the files are missing from this snapshot |
| `rsync_partial` | An `rsync` finished partial (exit 23/24); `source` names the tree | Re-run once the source is stable; some durable state is missing |
| `non_sqlite_db_skipped` | A file matched `*.db` but is not SQLite | None; the file is intentionally skipped |
| `cold_copy_fallback` | Online capture failed; containers stopped briefly for a verified cold copy | Install `sqlite3` to avoid the outage |
| `backup_failed` | Run aborted (exit 1) | See `detail` and `backup.log` |
| `retention_failed` | Pruning failed — backup itself is safe | Check R2 permissions |
| `check_failed` | **Repository integrity failure** | **Do not prune.** See below |
| `restore_test_success` | Rehearsal passed; backups are restorable | — |
| `restore_test_failed` | **Recovered databases are corrupt** | Investigate immediately |

### Common problems

**Backups never run overnight.** User services stop when you log out unless linger is enabled:

```bash
loginctl show-user "$USER" | grep Linger
sudo loginctl enable-linger "$USER"
```

**`repository is already locked`.** A previous run was killed. Confirm nothing is running, then:

```bash
set -a; source ~/.config/hybrid-ai-backup/r2.env; set +a
restic unlock
```

**`wrong password or no key found`.** The repository password does not match. There is no recovery mechanism — this is why it belongs in a password manager.

**`Could not snapshot ... via SQLite API`.** `sqlite3` is missing, so the script fell back to stopping Open WebUI and copying cold. Correct, but causes a brief outage:

```bash
sudo apt-get install -y sqlite3
```

**Integrity check failed.** Stop automated pruning immediately — pruning a damaged repository can destroy recoverable data:

```bash
systemctl --user stop hybrid-ai-backup.timer
restic check --read-data          # full verification
restic repair index               # rebuild the index
```

Treat existing snapshots as suspect until a `--test` restore passes.

**Backup is slow.** The first run uploads everything. Later runs are block-level incremental and usually finish in seconds. If every run is slow, check whether something is rewriting large files nightly.

### "Will my connections and pipes come back?"

Yes. Open WebUI keeps nearly all of its state in SQLite rather than config files, so model connections, functions/pipes (source *and* valve values), tools, knowledge bases, users, groups, API keys and admin settings are all inside `webui.db` and therefore inside every backup.

Verify a snapshot actually contains them:

```bash
./backup/restore.sh --test
# then, against the scratch copy:
sqlite3 .restore-test-*/**/databases/webui.db \
  "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;"
sqlite3 .restore-test-*/**/databases/webui.db \
  "SELECT id, is_active FROM function;"
```

Not in the databases, but still captured under `host/`: your Ollama model list, custom Modelfiles, container versions, compose overrides and git state. Only model *weights* and Tailscale machine identity are excluded, and both are handled during restore.

### Restoring

```bash
./backup/restore.sh --test        # rehearsal, touches nothing live
./backup/restore.sh --list        # choose a snapshot
./backup/restore.sh               # interactive restore
./backup/restore.sh --latest      # newest snapshot
```

The restore script verifies recovered databases **before** overwriting anything, and moves your current data to `webui_data.pre-restore-<timestamp>` rather than deleting it. If a restore goes wrong, your original data is still there.

**Rebuilding on new hardware:** see the walkthrough in [`backup/README.md`](../backup/README.md). The short version is: complete the prerequisites, clone the repo, recreate `~/.config/hybrid-ai-backup/` from your password manager, run `./backup/restore.sh --latest`, then `./install.sh`. Model weights are not backed up — re-pull them.

### Verify quarterly

```bash
./backup/restore.sh --test
```

The monthly timer verifies the *repository*. Only `--test` proves the *data* comes back usable, by running SQLite's own integrity check against every recovered database.

## Routine maintenance

**Weekly**

```bash
./doctor.sh                       # covers disk, health, backup freshness
sudo apt-get update && sudo apt-get upgrade -y
```

**Monthly**

```bash
./install.sh                         # pulls current images and restarts
docker image prune -f
docker exec -it ollama ollama list   # remove models you no longer use
```

**Quarterly**

- Rotate the Tailscale auth key (they expire — a stale key means the pod silently stops rejoining)
- Rotate `RUNPOD_API_KEY`, updating it in both the Pi's `.env` and the pod template
- Review RunPod billing for anything unexpected
- Test a restore: `./backup/restore.sh --test`. An untested backup is a hypothesis
- Confirm backup timers are still active: `systemctl --user list-timers 'hybrid-ai-*'`

**Storage health.** NVMe is recommended and far more durable than an SD card, but no disk is immortal. Warning signs are filesystem errors in `dmesg` and sudden read-only remounts. Check with:

```bash
dmesg | grep -iE 'mmcblk|nvme|i/o error'
```

Any I/O errors mean replace the drive now, while you still can.

On NVMe you can also read the drive's own health counters:

```bash
sudo nvme smart-log /dev/nvme0 2>/dev/null | grep -iE 'percentage_used|media_errors|critical_warning'
```

`percentage_used` is the controller's estimate of consumed write endurance. Anything under 10% after a year of normal use is healthy.

If you are still on an SD card, treat the above warning signs as urgent — cards fail far sooner under this workload.

---

## Reading the event logs

Both the installer and the pod emit structured, greppable records of what happened. **Every line is metadata only** — durations, counts, states, exit codes. No prompt or response text is ever written to either log, by design.

### Where they are

| Log | Location | Contents |
|---|---|---|
| Installer | `install.log` on the Pi (gitignored, mode 0600) | One entry per `install.sh` run |
| Pod | `/var/log/hybrid-ai-events.log` and the RunPod console | Pod lifecycle, watchdog, vLLM health |
| Pipe | `docker compose logs open-webui` | Per-request outcomes |

### Pod events

```bash
grep '^EVENT' /var/log/hybrid-ai-events.log
```

| Event | Meaning | Action |
|---|---|---|
| `tailnet_joined` | Pod reached your private network | — |
| `runtime_state_captured` | GPU count and address recorded | — |
| `watchdog_armed` / `watchdog_active` | Cost control running | **Confirm this appears on every boot** |
| `watchdog_disabled` | `RUNPOD_API_KEY` missing | **Urgent** — pod will bill forever |
| `vllm_ready` | Model is serving; `load_seconds` shows cold-start cost | — |
| `vllm_ready_timeout` | Process alive but not serving | Check pod logs for OOM |
| `vllm_exited` | Server died unexpectedly | Inspect `exit_code` |
| `vllm_restarting` | Supervisor recovering | Repeated entries mean instability |
| `vllm_restart_budget_exhausted` | Gave up; pod stopped | Model cannot start — check VRAM and model name |
| `idle_window` | Idle minute counted | Normal |
| `idle_counter_reset` | Activity seen, counter cleared | Normal |
| `gpu_unreadable` | `nvidia-smi` failing | 5 consecutive windows stops the pod |
| `podstop_success` | Pod stopped cleanly | Normal end of session |
| `podstop_failure` | One attempt failed; retrying | Watch for exhaustion |
| `podstop_exhausted` | **All retries failed** | **Stop the pod manually now** |

The two to alert on are `watchdog_disabled` and `podstop_exhausted`. Both mean the pod may bill indefinitely.

### Pipe events

```bash
docker compose --env-file .env logs open-webui | grep runpod_pipe
```

Each request carries a `request_id`, so you can trace one conversation end to end:

| Event | Meaning |
|---|---|
| `request_started` | Turn count and effective token cap |
| `pod_ready` | `wake_seconds` — how long the cold start took |
| `request_success` | Completed normally |
| `request_truncated` | Hit the token ceiling; user was told |
| `request_degraded` | Stream ended without `[DONE]` — partial answer |
| `request_failed` | See `reason` field |
| `request_cancelled` | User pressed stop |
| `request_rejected` | Failed preflight; never left the Pi |
| `runpod_api_retry` | Transient API failure being retried |

Trace a single request:

```bash
docker compose --env-file .env logs open-webui | grep 'request_id=a1b2c3d4'
```

Measure typical cold-start latency:

```bash
docker compose --env-file .env logs open-webui \
  | grep -o 'wake_seconds=[0-9.]*' | cut -d= -f2 | sort -n | tail -5
```

### Installer events

```bash
grep '^EVENT' install.log
```

`install_success` confirms both services passed their health checks. `install_failed reason=healthcheck` means containers started but are not serving — the script exits non-zero and prints container logs.
