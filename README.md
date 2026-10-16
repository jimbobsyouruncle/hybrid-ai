# hybrid-ai

**A private, self-hosted AI platform that runs small models locally on a Raspberry Pi and borrows a cloud GPU only when it needs one — then shuts it off automatically.**

[![Deploy Control Plane](https://github.com/jimbobsyouruncle/hybrid-ai/actions/workflows/deploy.yml/badge.svg)](https://github.com/jimbobsyouruncle/hybrid-ai/actions/workflows/deploy.yml)
![Platform](https://img.shields.io/badge/platform-Raspberry%20Pi%204%20%7C%205-c51a4a)
![License](https://img.shields.io/badge/license-MIT-blue)

---

## What this is

Most self-hosted AI setups force a choice: run small models you own on hardware you control, or use large capable models on someone else's servers with your data in their logs.

This project refuses the tradeoff. A Raspberry Pi in your house runs the chat interface, stores every conversation, manages persistent memory via Hermes Agent, and holds your document library. Small models answer directly on the Pi. When you need real capability, a GPU server wakes up in the cloud, joins your private network, answers, and switches itself off after fifteen idle minutes — billing you for the minutes used rather than the hours available. An optional OpenRouter integration provides a serverless fallback when spinning up the dedicated GPU isn't necessary.

Your RunPod prompts travel over an encrypted private network. The cloud server keeps no logs. Nothing is stored anywhere except on the disk in your Pi.

**Concretely, that means:**

- Conversations, documents, embeddings, and agent memories live on your hardware and never leave it.
- A 32-billion-parameter coding model on demand, typically a few dollars a month rather than a fixed subscription.
- Optional fallback to OpenRouter for fast, serverless cloud inference without cold boots.
- Autonomous workflow orchestration and persistent long-term memory via Hermes Agent.
- No public ports, no port forwarding, no exposing your home network to the internet.
- Push to `main` and your Pi updates itself, without ever touching your data.
- Streamlined local DNS: `yourdomain.com` for chat, `hermes.` for orchestration, `openhands.` for maintenance, and `status.` for health.
- Nightly encrypted backups to Cloudflare R2 covering chats, documents, vectors, memories, connections, pipes, and settings — a failed disk is an inconvenience, not a catastrophe.

---

## How it works

```
+──────────────────────────────────────────────────────────────────+
|  YOUR HOME                                                       |
|                                                                  |
|  +────────────────────────────────────────────────────────────+  |
|  |  Raspberry Pi  ::  local control plane                     |  |
|  |                                                            |  |
|  |   Open WebUI ---- chat UI, history, documents              |  |
|  |   Hermes Agent -- system orchestration, memory, skills     |  |
|  |        |                                                   |  |
|  |        +---> Ollama ---- small models, runs on the Pi      |  |
|  |        |                                                   |  |
|  |        +---> runpod_pipe.py --+                            |  |
|  |        +---> OpenRouter API --|--> (Serverless fallback)   |  |
|  |                               |                            |  |
|  |   ./webui_data  ./ollama_data  ./hermes_data               |  |
|  +───────────────────────────────┼────────────────────────────+  |
+──────────────────────────────────┼───────────────────────────────+
                                   |
                    Tailscale encrypted mesh (100.x.x.x)
                     no public ports, WireGuard tunnel
                                   |
+──────────────────────────────────┼───────────────────────────────+
|  RUNPOD CLOUD                    V                               |
|  +────────────────────────────────────────────────────────────+  |
|  |  GPU pod  ::  cloud inference plane                        |  |
|  |                                                            |  |
|  |   start.sh ---> joins tailnet ---> vLLM (32B model)        |  |
|  |            +--> idle watchdog ---> self-shutdown @ 15min   |  |
|  |                                                            |  |
|  |   logging disabled . stopped by default . pay per minute   |  |
|  +────────────────────────────────────────────────────────────+  |
+───────────────────────────────────────────────────────────────+
```

**A request to the cloud model, end to end:**

| # | What happens | Roughly how long |
|---|---|---|
| 1 | You pick the cloud model and send a message | — |
| 2 | The pipe confirms the destination is inside your private network | instant |
| 3 | The pipe asks RunPod to resume the stopped pod | 2–5 s |
| 4 | `start.sh` joins Tailscale, arms the watchdog, launches vLLM | 30–60 s |
| 5 | The pipe polls until the model reports ready | 2–5 min (cold) |
| 6 | Your prompt streams over the tunnel; text appears as it's written | — |
| 7 | 15 minutes idle → the pod stops itself, billing ends | automatic |

Cold starts are the honest cost of this design. Subsequent messages in the same session are immediate, because the pod is already warm and the watchdog counter keeps resetting while you work. If you prefer to bypass the cold start entirely for a quick query, the OpenRouter fallback provides instant access to cloud models on a per-token basis.

### Networks and ports

All containers join one shared Docker network, `hybrid-ai`, and reach each other by service name (for example, Open WebUI talks to Ollama at `http://ollama:11434`).

This project adds a second, private network for the two code-aware services:

| Network | Defined in | Members | Reachable from | Purpose |
|---|---|---|---|---|
| `hybrid-ai` | `docker-compose.yml` (the compose default) | every service | the host and each other | normal service-to-service traffic |
| `coder-net` | `docker-compose.yml`, `internal: true` | `openhands` and `hermes` only | each other only — no host, LAN, or internet route | Hermes reaches the OpenHands API at `http://openhands:3000` by service name |

`coder-net` is `internal: true`, so Docker gives it no route off the host. It publishes no ports, and adding it does not create any host port binding. The OpenHands UI keeps its existing binds on `127.0.0.1` and `172.17.0.1` — see [openhands/README.md](openhands/README.md) and [SECURITY.md](SECURITY.md).

Host ports, and who can reach them:

| Service | Host bind | Reached by |
|---|---|---|
| Open WebUI | `3000` on all interfaces | your browser, on the LAN and tailnet |
| Hermes Agent UI | `${HERMES_PORT:-8501}` on all interfaces | your browser, on the LAN and tailnet |
| Hermes Agent API | `${HERMES_API_PORT:-8642}` on all interfaces | your browser, on the LAN and tailnet |
| Ollama | `127.0.0.1:11434` | the Pi only |
| OpenHands | `127.0.0.1:${OPENHANDS_PORT:-3001}` | you, over an SSH tunnel |
| OpenHands | `172.17.0.1:${OPENHANDS_PORT:-3001}` | Docker sandboxes only, for webhooks |
| Status page, proxy | none (behind Caddy) | the proxy |

The Hermes binds on all interfaces and the OpenHands sandbox ports are pre-existing gaps, recorded in [SECURITY.md](SECURITY.md) and [hermes/README.md](hermes/README.md); a later phase narrows them. This change adds no host binds.

---

## Performance on a Raspberry Pi 5

**Short answer: yes, a Pi 5 with 16 GB is comfortably enough** — but not for the reason most people assume, and the extra RAM does not buy what you might expect.

### The real constraint is memory bandwidth, not capacity

The Pi 5's LPDDR4X provides roughly 17 GB/s. Generating one token requires reading *every* model weight once, so throughput is capped at approximately `bandwidth ÷ model size`, no matter how much RAM you have:

| Local model | Throughput | Verdict |
|---|---|---|
| 1B (`llama3.2:1b`) | ~17–21 tok/s | Very responsive |
| **3B (`llama3.2:3b`)** | **~5–8 tok/s** | **Sweet spot — recommended default** |
| 7–8B | ~1–3 tok/s | Fits in 16 GB, too slow to chat with |

Sixteen gigabytes removes the *capacity* limit on an 8B model but not the *bandwidth* limit, so it still runs at reading-pace-or-slower. This is precisely the problem this architecture solves: run a 3B model locally for fast, private, everyday work, and hand anything demanding to the GPU pod or OpenRouter, where a 32B model runs at conversational speed.

### What the extra RAM actually buys you

| Benefit | Why |
|---|---|
| **30-minute model keep-alive** | Room to keep a model resident far longer, so follow-up questions skip the multi-second reload. `install.sh` sets this automatically at 16 GB |
| **16k context instead of 4k** | Ollama silently caps *every* model at 4096 tokens unless told otherwise. More RAM affords a bigger KV cache |
| **Comfortable document embedding** | Open WebUI's most memory-hungry operation gets 3 GB of headroom |
| **No swapping** | Everything stays resident, which matters enormously when swap means writing to storage |

### Storage: NVMe is the assumed baseline

After model choice, storage is the biggest performance factor, and this project assumes NVMe.

| | NVMe via PCIe HAT | SD card |
|---|---|---|
| Model load (first response) | Fast — a few seconds | Several times slower |
| Vector DB sustained writes | Comfortable | Wears the card out, often within months |
| Swap behaviour, if it happens | Survivable | Punishing |

On NVMe, the 30-minute keep-alive that `install.sh` configures at 16 GB matters less for the *first* load and more for avoiding repeats — but either way the cold start stops being something you notice.

`install.sh` and `doctor.sh` detect the storage type automatically and report it; no configuration is needed.

### What this project tunes for you

`install.sh` detects your RAM and sets enforced Docker memory limits, CPU shares that leave a core free for the UI, context length, keep-alive, and KV-cache quantisation. Nothing to configure by hand.

> **A correction worth knowing about:** earlier versions of this project set `OLLAMA_MAX_VRAM`, computed from a careful RAM budget. That variable was **never honoured by Ollama and has since been removed upstream** — it was pure placebo. Memory is now capped with real, kernel-enforced Docker limits.

## Addresses

During setup, `install.sh` configures a local domain (e.g., `yourhostname.com`). All services route through a Caddy reverse proxy using local DNS:

| URL | What it serves | Who can reach it |
|---|---|---|
| `http://yourhostname.com/hub` | Directory of all services, with live health | LAN + tailnet |
| `http://yourhostname.com` | Open WebUI (The chat interface) | Anyone (it has its own login) |
| `http://hermes.yourhostname.com` | Hermes Agent UI (System orchestrator) | LAN + tailnet |
| `http://status.yourhostname.com` | Service health, scheduled jobs, logs, diagnostics | LAN + tailnet |
| `http://openhands.yourhostname.com` | OpenHands autonomous coding workspace | LAN + tailnet |
| `http://yourhostname.com/ollama/` | Local model API, for scripts | LAN + tailnet |
| `http://yourhostname.com/health` | One word — `ok`, `warn`, or `fail` | Anyone |

> **DNS Note:** `install.sh` will check if your chosen domain resolves to the Pi's IP address and provide exact Pi-hole A-Record configurations if it doesn't.

## Hermes Agent system orchestrator

The project includes **Hermes Agent**, a persistent memory and skill orchestration engine. Hermes sits alongside Open WebUI, managing long-term user context, storing explicit memories in `hermes_data/`, and providing a framework for custom tool skills. It operates independently of the chat interface, ensuring that your AI assistant retains knowledge of your preferences, environment, and ongoing projects across distinct chat sessions.

Hermes reads the OpenHands working clone at `/agent-repo` (mounted read-only) and reaches the OpenHands API at `http://openhands:3000` over the internal `coder-net` network. See [hermes/README.md](hermes/README.md).

## OpenHands code-maintenance agent

The project includes a separate OpenHands service for natural-language code maintenance. It works in a separate clone at `~/hybrid-ai-agent` (on a bootstrapped host, `/var/lib/hybrid-ai-agent`); the deployment directory is not visible to the agent, creates isolated agent-server containers, and supports an inspect, branch, edit, test, and commit workflow.

The OpenHands controller uses the Docker socket to create sandboxes. Docker-socket access is effectively host-level control. Keep human review and branch protection enabled. See [openhands/README.md](openhands/README.md).

The same clone is mounted read-only into Hermes at `/agent-repo`, and OpenHands joins the internal `coder-net` network so Hermes can call its API by service name. Neither change adds a host port.

## Prerequisites

Work through this section completely before running anything. Roughly 45 minutes end to end, most of it waiting for downloads.

### 1. Hardware

| Item | Minimum | Recommended | Notes |
|---|---|---|---|
| Raspberry Pi | Pi 4, 4 GB RAM | **Pi 5, 16 GB** | See [Performance](#performance-on-a-raspberry-pi-5). 16 GB buys longer keep-alive, bigger context, and comfortable embedding — not faster large models |
| Storage | 32 GB SD card | **256 GB+ NVMe SSD via the PCIe HAT** | Strongly recommended, not a nice-to-have — see below |
| Power supply | Official Pi PSU | Official Pi PSU | Underpowered supplies cause data corruption that looks like software bugs |
| Cooling | Heatsink | Active cooler | A throttled Pi makes embedding painfully slow |
| Network | Wired Ethernet | Wired Ethernet | Wi-Fi works, but wired is far more reliable for an always-on service |

> **Use an NVMe SSD.** This is the recommended baseline for this project, for two reasons. **Endurance:** the vector database writes constantly, and SD cards wear out under that load — often within months. **Speed:** models load several times faster, which is the difference between a first response that arrives in a couple of seconds and one that takes twenty.

**Already on NVMe?** Nothing to configure — `install.sh` detects it and `doctor.sh` confirms it. Two things worth verifying once:

```bash
findmnt -n -o SOURCE /            # should show /dev/nvme0n1p2, not mmcblk
sudo rpi-eeprom-config | grep BOOT_ORDER   # NVMe must precede SD in the order
```

If `BOOT_ORDER` still prefers the SD card, the Pi may silently boot from a stale card while the NVMe sits idle. `sudo raspi-config` → Advanced → Boot Order → NVMe/USB fixes it.

### 2. Operating system and readiness state

**Required:** Raspberry Pi OS (64-bit), Bookworm or newer. The 64-bit build is not optional — Ollama and the ARM container images will not run on 32-bit.

Verify you are 64-bit:

```bash
uname -m          # must print: aarch64
```

If it prints `armv7l`, you are on 32-bit and need to reflash with Raspberry Pi Imager, selecting **Raspberry Pi OS (64-bit)**.

**Bring the Pi to a ready state:**

```bash
# 1. Update everything
sudo apt-get update && sudo apt-get full-upgrade -y

# 2. Base tooling (sqlite3, rsync and restic support the backup subsystem)
sudo apt-get install -y git jq curl openssl ca-certificates sqlite3 rsync restic

# 3. Docker Engine + Compose v2
curl -fsSL [https://get.docker.com](https://get.docker.com) | sudo sh
sudo usermod -aG docker "$USER"

# 4. Tailscale
curl -fsSL [https://tailscale.com/install.sh](https://tailscale.com/install.sh) | sudo sh

# 5. LOG OUT AND BACK IN  -- required for the docker group to apply
exit
```

**Confirm readiness.** All of these must pass before you continue:

```bash
uname -m                        # aarch64
findmnt -n -o SOURCE /          # nvme0n1... recommended (mmcblk = SD card)
docker run --rm hello-world     # succeeds with no sudo
docker compose version          # v2.x or newer
git --version                   # any version
jq --version                    # any version
sqlite3 --version               # any version
restic version                  # any version
tailscale version               # any version
```

---

## Agent context maps

Two files at the repository root give coding agents a small map of the codebase instead of making them read every file:

| File | What it holds |
|---|---|
| `REPO_MAP.md` | Every tracked file, grouped by directory, with a one-line description |
| `CODE_INDEX.md` | Per-file code structure — function signatures, shell function names, workflow job ids, compose services — without any file bodies |

Agents read these maps first and open only the files they actually need. That keeps context small and answers faster than dumping whole files into the prompt.

Both files are generated from the tracked file list, are deterministic (no timestamps or commit SHAs), and must stay under 20480 bytes each. Regenerate them after any change that adds, removes, or renames a tracked file:

```bash
python3 <path-to-generate.py> --root . --output-dir . --max-bytes 20480
```

`scripts/check-agent-context.sh` verifies they are fresh. It compares the committed maps against a fresh generator run and exits:

| Exit | Meaning |
|---|---|
| `0` | Both maps match a fresh run |
| `1` | A map is stale or missing, or a retired `CONSOLIDATED_*.md` is still tracked |
| `2` | Usage error, or the generator failed (including a size overflow) |

The **Agent context** pull request workflow (`.github/workflows/agent-context.yml`) runs that check on every pull request so a stale map cannot merge. The maps land only through reviewed pull requests — nothing regenerates and commits them automatically.

---


### 3. External services

Four accounts. One is free, two are pay-as-you-go, one is free for personal use.

#### Tailscale — private networking (free tier is sufficient)

Creates an encrypted private network between your Pi, your laptop, and the GPU pod. This is what removes the need for any public ports.

| | |
|---|---|
| **Sign up** | [tailscale.com](https://tailscale.com) — sign in with Google, Microsoft, or GitHub |
| **Cost** | Free personal plan covers up to 100 devices |
| **Credentials needed** | An ephemeral auth key (for the pod) and an OAuth client (for CI) |

**Auth key for the GPU pod** — Admin console → **Settings** → **Keys** → **Generate auth key**:

- ☑ **Reusable** — the pod restarts often and needs to rejoin each time
- ☑ **Ephemeral** — stopped pods are removed automatically instead of accumulating as dead entries
- ☑ **Pre-approved** — joins without waiting for you to click approve
- Expiry: 90 days (set a calendar reminder to rotate it)

Copy it immediately; it is shown once. Format: `tskey-auth-...`

#### RunPod — on-demand GPU (pay as you go)

Rents GPU time by the minute. You only pay while the pod is running, which is why the idle watchdog matters so much.

| | |
|---|---|
| **Sign up** | [runpod.io](https://runpod.io) |
| **Cost** | Billed per minute of runtime. Occasional personal use typically lands in single-digit dollars per month |
| **Credit** | Add $10–25 to start |
| **Credentials needed** | SSH Public Key(s) + API key + pod ID |

**1. SSH Public Key Injection** — RunPod Console → Settings / Credentials → SSH Public Keys.
**2. API key** — Console → Settings → API Keys → + API Key. Format: `rpa_...`
**3. Creating the pod** — full walkthrough in [`runpod/README.md`](runpod/README.md).

#### OpenRouter — serverless cloud inference (pay as you go)

Provides instant, serverless access to large models as a fallback when the RunPod instance is spun down or unneeded.

| | |
|---|---|
| **Sign up** | [openrouter.ai](https://openrouter.ai) |
| **Cost** | Billed per million tokens. Extremely inexpensive for casual coding and queries |
| **Credentials needed** | API key (`sk-or-...`) |

#### Cloudflare R2 — encrypted offsite backups (pay as you go, pennies)

Stores your encrypted backups. Data is encrypted on the Pi before upload.

| | |
|---|---|
| **Sign up** | [cloudflare.com](https://cloudflare.com) |
| **Cost** | ~$0.015/GB/month stored, and **nothing for egress** |
| **Credentials needed** | Account ID, bucket name, R2 Access Key ID, Secret Access Key |

**Create the bucket:** R2 object storage → **Create bucket** → name it `hybrid-ai-backup`.
**Create a scoped token:** R2 → Overview → Manage API Tokens → Create Account API token with **Object Read & Write** strictly for that bucket.

#### GitHub — code hosting and automated deploys (free)

Optional. Everything works if you deploy by hand. CI just means `git push` updates the Pi for you.

---

## External account dependencies

**Every credential this project uses, and exactly where each one goes.** This is the table to check first when something is not working.

| Credential | Service | Where you obtain it | Where it is loaded | How it gets there |
|---|---|---|---|---|
| `LOCAL_DOMAIN` | *your network* | Chosen during install | Pi `.env` | `install.sh` prompts you |
| `TAILSCALE_AUTH_KEY` | Tailscale | Admin → Settings → Keys | **RunPod pod template** | Pasted into the RunPod web console |
| `RUNPOD_API_KEY` | RunPod | Console → Settings → API Keys | Pi `.env` & pod template | `install.sh` prompts you / pasted in template |
| `RUNPOD_POD_ID` | RunPod | Pod card or URL | Pi `.env` | `install.sh` prompts you |
| `OPENROUTER_API_KEY` | OpenRouter | Account → Keys | Pi `.env` | `install.sh` prompts you |
| `WEBUI_SECRET_KEY` | *self-generated* | — | Pi `.env` | Auto-generated by `install.sh` |
| `TAILSCALE_IP` | *auto-discovered* | — | Pi `.env` | `install.sh` queries the tailnet for the peer |
| `RUNPOD_AUTO_WAKE` | *your choice* | — | Pi `.env` | Default `0`. Set `1` or `true` to let `install.sh` start an offline pod |
| `AWS_ACCESS_KEY_ID` | Cloudflare R2 | R2 → Manage API Tokens | `~/.config/hybrid-ai-backup/r2.env` | `install.sh` prompts you |
| `AWS_SECRET_ACCESS_KEY` | Cloudflare R2 | R2 → Manage API Tokens | `~/.config/hybrid-ai-backup/r2.env` | `install.sh` prompts you |
| `RESTIC_REPOSITORY` | *derived* | Account ID + bucket name | `~/.config/hybrid-ai-backup/r2.env` | Built by `install.sh` |
| **Repository password** | *self-generated* | — | `~/.config/hybrid-ai-backup/repo-password` | Generated by `install.sh`. **Store off-device.** |

In **system mode** (`HYBRID_AI_BACKUP_MODE=system`) the two backup units read the
R2 credentials from a root-owned store instead:
`/etc/credstore/hybrid-ai-backup/r2.env` and
`/etc/credstore/hybrid-ai-backup/repo-password` (both mode 0600), delivered to
the upload unit by `LoadCredential=`. The capture unit holds no credentials at
all. See [`backup/README.md`](backup/README.md#system-mode-fresh-install-and-migration).

### Three places credentials live — and one place they must never

```
1. Pi: ./.env                          created by install.sh, mode 0600, gitignored
2. Pi: ~/.config/hybrid-ai-backup/     backup credentials, mode 0600, OUTSIDE the repo
   Pi: /etc/credstore/hybrid-ai-backup/  system-mode backup credentials, root 0600
3. RunPod pod template                 entered in the RunPod web console
4. GitHub repository secrets           Settings → Secrets and variables → Actions

NEVER: any file tracked by git.
```

Backup credentials sit outside the repository deliberately: no `git add`, no stray `tar czf` of the project folder, and no CI checkout can sweep them up.

---

## Installation

### One-time host bootstrap

The host bootstrap is the ONE privileged command you run per device. It creates
the system accounts, the `/opt`, `/var/lib`, `/var/log` and `/etc` layout, the
system-mode backup credential store, and the headless deploy account, then hands
off to `install.sh`. It is idempotent: a second run changes nothing.

**Fresh install** (a brand-new device with no existing data):

```bash
sudo ./scripts/bootstrap.sh --deploy-pubkey ~/.ssh/hybrid-ai-deploy.pub
```

**Migration** (the current Pi, moving the existing data into the new layout):

```bash
sudo ./scripts/bootstrap.sh --deploy-pubkey ~/.ssh/hybrid-ai-deploy.pub --from /home/pi/hybrid-ai
```

`--from` moves the existing data — it never copies or merges. `--login-user`
defaults to `SUDO_USER`. The deploy public key is the key the headless deploy
uses; passing a private key, several keys, or a line that already carries
options is refused. See [`deploy/README.md`](deploy/README.md) and
[`SECURITY.md`](SECURITY.md) for what the bootstrap does, and
[`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) for its exit codes.

### Step 1 — Pi setup

```bash
git clone [https://github.com/jimbobsyouruncle/hybrid-ai.git](https://github.com/jimbobsyouruncle/hybrid-ai.git)
cd hybrid-ai
chmod +x install.sh doctor.sh collect-diagnostics.sh \
         backup/backup.sh backup/restore.sh runpod/start.sh \
         scripts/setup-agent-workspace.sh \
         openhands/scripts/openhands-control.sh

sudo tailscale up          # follow the printed URL to authenticate
tailscale ip -4            # note this address for later
```

### Step 2 — Create the RunPod pod

Follow [`runpod/README.md`](runpod/README.md). At the end you will have a pod ID and a pod that has joined your tailnet once.

### Step 3 — Run the installer

```bash
./install.sh
```

It prompts for your local domain, OpenRouter API key, RunPod API key, and pod ID. It will generate your `.env` and start the stack — Ollama, Open WebUI, Hermes Agent, the status proxy, and OpenHands.

The installer only *looks* for the GPU pod on your tailnet (a read-only `tailscale status`). It does **not** start the paid pod, and neither does the CI deploy, which runs `./install.sh --non-interactive` on every push to `main`. The pod starts on demand when you pick the cloud model in Open WebUI. To make the installer start an offline pod too, set `RUNPOD_AUTO_WAKE=1` (or `true`) in `.env`, or run `./install.sh --wake-runpod` for a single run. The default is `RUNPOD_AUTO_WAKE=0`.

### Step 4 — Verify Local DNS

If `install.sh` flags that your subdomains (e.g., `openhands.yourhostname.com`) are missing, add the exact A-Records it prints to your local Pi-hole or DNS server, pointing to the Pi's local IP address.

### Step 5 — Configure Open WebUI

1. Open `http://yourhostname.com`
2. **Create the admin account** — the first account registered becomes the administrator
3. Pull a local model for everyday use:

   ```bash
   docker exec -it ollama ollama pull llama3.2:3b
   ```

4. Install the cloud pipe: **Workspace → Functions → +** → paste the entire contents of [`openwebui/runpod_pipe.py`](openwebui/runpod_pipe.py) → **Save** → toggle it **on**.

### Step 6 — Verify Subsystems

Open `http://yourhostname.com/hub` in a browser to see everything at once, or from the CLI:

```bash
./doctor.sh
```

Everything should report healthy. Ensure you can access `http://hermes.yourhostname.com` to manage long-term agent memory and `http://openhands.yourhostname.com` to verify workspace isolation.

### Step 7 — Backups

If you skipped the backup prompt during `./install.sh`, re-run it and answer yes. Then do the one thing that cannot be automated:

```bash
cat ~/.config/hybrid-ai-backup/repo-password
```

Put that in a password manager. Rehearse a restore before you need one:

```bash
./backup/restore.sh --test
```

---

## Repository layout

| Path | What it holds | Documentation |
|---|---|---|
| `README.md` | This file — start here | — |
| `REPO_MAP.md` | Agent context map — tracked files by directory | Generated; see [Agent context maps](#agent-context-maps) |
| `CODE_INDEX.md` | Agent context index — per-file code structure | Generated; see [Agent context maps](#agent-context-maps) |
| `install.sh` | The one script you run on the Pi | Commented inline |
| `scripts/bootstrap.sh` | The ONE privileged, one-time host bootstrap (accounts, FHS layout, migration) | Commented inline; see [`deploy/README.md`](deploy/README.md) |
| `doctor.sh` | One-command health check | Commented inline |
| `collect-diagnostics.sh` | Bundles logs and status into one redacted file | Commented inline |
| `docker-compose.yml` | Blueprint for the Pi containers | Commented inline |
| `openwebui/` | The Python bridge to the cloud GPU | [`openwebui/README.md`](openwebui/README.md) |
| `status/` | Status page and reverse proxy | [`status/README.md`](status/README.md) |
| `runpod/` | Everything that runs on the rented GPU | [`runpod/README.md`](runpod/README.md) |
| `hermes/` | Hermes Agent system orchestrator | [hermes/README.md](hermes/README.md) |
| `openhands/` | Natural-language code-maintenance agent | [openhands/README.md](openhands/README.md) |
| `backup/` | Encrypted backups to Cloudflare R2 | [`backup/README.md`](backup/README.md) |
| `deploy/` | Headless deploy pieces (**not active until migration**) | [`deploy/README.md`](deploy/README.md) |
| `webui_data/` | **Your data.** Chats, documents, vectors | Created at runtime, never committed |
| `hermes_data/` | **Your data.** Persistent agent memories/skills | Created at runtime, never committed |
| `ollama_data/` | Downloaded model files | Created at runtime, never committed |

---

## Headless deploy (not active until migration)

The `deploy/` directory and `scripts/deploy-*.sh` hold the in-repo pieces of a
**headless deploy**: a dedicated, unprivileged `hybrid-ai-deploy` account that
can do exactly one thing over SSH — start the system unit
`hybrid-ai-deploy@<sha>.service` for a 40-character commit, which runs
`scripts/deploy-instance.sh` and then the existing `scripts/deploy-remote.sh`.

**Nothing in this path is active yet.** Today's deploy runs through
`.github/workflows/deploy.yml`, unchanged. The migration happens in two later
owner steps: **card F** installs the unit, the polkit rule, the scripts and the
`authorized_keys` line on the host; a later card switches `deploy.yml` over to
the forced command. Until then these files are inert source and documentation.

The account holds no login shell beyond the forced command, no sudo, and is in
neither the `docker` nor the `systemd-journal` group. Full detail, including the
`authorized_keys` line and the refusal exit codes, is in
[`deploy/README.md`](deploy/README.md).

---

## Host paths (relocation)

Every host path the project uses is worked out in ONE place,
`scripts/lib/hybrid-ai-env.sh`. Each script sources it, and every compose call
passes the resolved `--env-file` and `--project-directory`. With no settings,
every path is exactly the default above.

| Setting | Meaning | Default |
|---|---|---|
| `HYBRID_AI_APP_DIR` | Program/repository directory | the repo directory |
| `HYBRID_AI_ENV_FILE` | The layout env file (host paths) | `$HYBRID_AI_APP_DIR/.env` |
| `HYBRID_AI_STACK_ENV_FILE` | The stack env file handed to `docker compose --env-file` | the resolved `HYBRID_AI_ENV_FILE` |
| `HYBRID_AI_DATA_DIR` | Durable data (`hermes_data/`, `webui_data/`, `ollama_data/`) | the repo directory |
| `HYBRID_AI_LOG_DIR` | Logs (`install.log`, `backup.log`) | the repo directory |
| `HYBRID_AI_WORK_DIR` | Backup/restore scratch (`.backup-staging`, `.restore-work`, `.restore-test-*`) | the repo directory |

Resolution order is: the process environment, then the env file (parsed line by
line, **never** sourced), then the default. A set value must be an absolute path
with no whitespace, control character, `:` or `,`, and it must not be `/`.

`HYBRID_AI_STACK_ENV_FILE` is the split that makes one-time bootstrap possible.
The layout file (`HYBRID_AI_ENV_FILE`) holds host paths and control settings and
never a secret; the stack file holds the runtime config and secrets and is what
`install.sh` writes. With `HYBRID_AI_STACK_ENV_FILE` unset the two are the same
path, so nothing changes. On a bootstrapped host `scripts/bootstrap.sh` points
the stack file at `/etc/hybrid-ai/stack.env`, and the layout file is the single
source of truth for the paths and the `HYBRID_AI_UID`/`HYBRID_AI_GID` identity:
`install.sh` restores those from the layout file after it reads the stack file,
so a legacy stack file that still carries empty `HYBRID_AI_UID=` lines cannot
drop the stack to root. If the layout file exists but cannot be read, the helper
exits non-zero and names the setting instead of quietly using a default.

The settings that already existed keep their names and defaults:
`OPENHANDS_WORKSPACE`, `AGENT_REPOS_DIR`, `OPENHANDS_STATE_DIR`,
`BACKUP_CONF_DIR`, `RESTIC_CACHE_DIR`, `BACKUP_LOG`, and `HYBRID_AI_UID` /
`HYBRID_AI_GID`.

A split layout for a dedicated system account looks like this (commented example
in `.env.example`):

```
HYBRID_AI_APP_DIR=/opt/hybrid-ai
HYBRID_AI_DATA_DIR=/var/lib/hybrid-ai
HYBRID_AI_ENV_FILE=/etc/hybrid-ai/hybrid-ai.env
HYBRID_AI_LOG_DIR=/var/log/hybrid-ai
HYBRID_AI_WORK_DIR=/var/lib/hybrid-ai/work
```

`./doctor.sh` prints every resolved path (never an env-file value) and warns when
a set path does not exist. The isolation guards still refuse a workspace, agent
repo tree or backup credential directory that is, is inside, or contains any
protected tree, whichever layout is in use.

---

## Privacy design

Claims are only worth what enforces them. Each one below maps to a specific mechanism you can go and read:

| Claim | Enforced by | Where |
|---|---|---|
| Prompts never traverse the public internet | Address validated against `100.64.0.0/10` before any transmission | `runpod_pipe.py` → `_is_mesh_address()` |
| The GPU server keeps no record of prompts | `--disable-log-requests`, `VLLM_CONFIGURE_LOGGING=0` | `runpod/start.sh` |
| **OpenRouter inference (Optional fallback)** | **Prompts sent to OpenRouter are subject to their privacy policy. Use local Ollama or RunPod for strict privacy.** | `.env` config |
| No telemetry leaves the Pi | `DO_NOT_TRACK`, `SCARF_NO_ANALYTICS` | `docker-compose.yml` |
| Documents are embedded locally | `RAG_EMBEDDING_ENGINE=""` — computed in-container | `docker-compose.yml` |
| No inbound ports are exposed | Subdomain routing handled strictly internally by Caddy | `status/Caddyfile` |
| The status page cannot leak credentials | It is given none — no `.env`, no API keys | `docker-compose.yml`, `status/app.py` |
| Backups are unreadable by Cloudflare | restic encrypts on the Pi before upload; R2 stores ciphertext only | `backup/backup.sh` |

---

## Operating costs

| Component | Typical cost |
|---|---|
| Raspberry Pi electricity | ~$0.50–1.50/month |
| Tailscale | $0 (free tier) |
| RunPod GPU | Only while running — commonly a few dollars a month for occasional use |
| OpenRouter | Billed per million tokens — typically pennies for standard queries |
| RunPod storage | Persistent volumes bill even when the pod is stopped; check current rates |
| Cloudflare R2 | ~$0.015/GB/month stored, $0 egress — typically well under $1/month |

---

## Quick reference

```bash
# Health check — run this first when something is wrong
./doctor.sh

# Stuck? Bundle everything (secrets redacted) to share or paste into an AI chat
./collect-diagnostics.sh

# Status and logs
docker compose --env-file .env ps
docker compose --env-file .env logs -f open-webui

# Restart after config changes
./install.sh

# Backups (automatic nightly at 03:15; these are manual controls)
./backup/backup.sh                 # run now
./backup/restore.sh --test         # rehearse a restore — quarterly
./backup/restore.sh --latest       # full rebuild onto a new Pi

# Manage local models
docker exec -it ollama ollama list
docker exec -it ollama ollama pull llama3.2:3b
```

Problems? → open `http://status.<LOCAL_DOMAIN>`, or run `./doctor.sh`, then [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md).

---

## License

MIT. See [`LICENSE`](LICENSE).
