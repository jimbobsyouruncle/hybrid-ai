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
tailscale status | grep -E 'runpod-vllm|^100\.'

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

**Long conversations get truncated.** Ollama silently caps every model at 4096 tokens unless told otherwise. `install.sh` raises `OLLAMA_CONTEXT_LENGTH` based on RAM (16384 at 16 GB); increase it in `.env` and re-run `./install.sh` if needed, at the cost of KV cache memory.

**`model requires more system memory than is available`**

```bash
free -h
grep OLLAMA_MAX_VRAM .env
```

`install.sh` sets a conservative ceiling deliberately. Use a smaller model rather than raising it — exceeding physical RAM pushes the Pi into swap, which is dramatically worse than simply using a smaller model — even on NVMe.

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

A healthy run logs `backup_success` followed by `retention_applied`.

### Backup events

| Event | Meaning | Action |
|---|---|---|
| `backup_success` | Completed; check `staged_mb` and `duration_s` | — |
| `cold_copy_fallback` | Online snapshot failed; containers stopped briefly | Install `sqlite3` to avoid the outage |
| `backup_failed` | Run aborted | See `detail` and `backup.log` |
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
