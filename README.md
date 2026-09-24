# hybrid-ai

**A private, self-hosted AI platform that runs small models locally on a Raspberry Pi and borrows a cloud GPU only when it needs one — then shuts it off automatically.**

[![Deploy Control Plane](https://github.com/YOUR_USERNAME/hybrid-ai/actions/workflows/deploy.yml/badge.svg)](https://github.com/YOUR_USERNAME/hybrid-ai/actions/workflows/deploy.yml)
![Platform](https://img.shields.io/badge/platform-Raspberry%20Pi%204%20%7C%205-c51a4a)
![License](https://img.shields.io/badge/license-MIT-blue)

---

## What this is

Most self-hosted AI setups force a choice: run small models you own on hardware you control, or use large capable models on someone else's servers with your data in their logs.

This project refuses the tradeoff. A Raspberry Pi in your house runs the chat interface, stores every conversation, and holds your document library. Small models answer directly on the Pi. When you need real capability, a GPU server wakes up in the cloud, joins your private network, answers, and switches itself off after fifteen idle minutes — billing you for the minutes used rather than the hours available.

Your prompts travel over an encrypted private network. The cloud server keeps no logs. Nothing is stored anywhere except on the disk in your Pi.

**Concretely, that means:**

- Conversations, documents, and embeddings live on your hardware and never leave it.
- A 32-billion-parameter coding model on demand, typically a few dollars a month rather than a fixed subscription.
- No public ports, no port forwarding, no exposing your home network to the internet.
- Push to `main` and your Pi updates itself, without ever touching your data.
- One address for everything: `/openwebui` for chat, `/status` for health and job history, `/hub` for a directory of all of it.
- Nightly encrypted backups to Cloudflare R2 covering chats, documents, vectors, connections, pipes and their settings — a failed disk is an inconvenience, not a catastrophe.

---

## How it works

```
┌─────────────────────────────────────────────────────────────────┐
│  YOUR HOME                                                      │
│                                                                 │
│  ┌───────────────────────────────────────────────────────┐      │
│  │  Raspberry Pi  ::  local control plane                 │      │
│  │                                                        │      │
│  │   Open WebUI ──── chat UI, history, documents          │      │
│  │        │                                               │      │
│  │        ├──▶ Ollama ──── small models, runs on the Pi   │      │
│  │        │                                               │      │
│  │        └──▶ runpod_pipe.py ──┐                         │      │
│  │                              │                         │      │
│  │   ./webui_data   ./ollama_data   (your data, on disk)  │      │
│  └──────────────────────────────┼─────────────────────────┘      │
└─────────────────────────────────┼────────────────────────────────┘
                                  │
                   Tailscale encrypted mesh (100.x.x.x)
                     no public ports, WireGuard tunnel
                                  │
┌─────────────────────────────────┼────────────────────────────────┐
│  RUNPOD CLOUD                   ▼                                │
│  ┌────────────────────────────────────────────────────────┐      │
│  │  GPU pod  ::  cloud inference plane                     │      │
│  │                                                         │      │
│  │   start.sh ──▶ joins tailnet ──▶ vLLM (32B model)       │      │
│  │            └─▶ idle watchdog ──▶ self-shutdown @ 15min  │      │
│  │                                                         │      │
│  │   logging disabled · stopped by default · pay per minute│      │
│  └─────────────────────────────────────────────────────────┘      │
└──────────────────────────────────────────────────────────────────┘
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

Cold starts are the honest cost of this design. Subsequent messages in the same session are immediate, because the pod is already warm and the watchdog counter keeps resetting while you work.

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

Sixteen gigabytes removes the *capacity* limit on an 8B model but not the *bandwidth* limit, so it still runs at reading-pace-or-slower. This is precisely the problem this architecture solves: run a 3B model locally for fast, private, everyday work, and hand anything demanding to the GPU pod, where a 32B model runs at conversational speed.

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

Everything is reachable from one host, on port 80, through a reverse proxy:

| Path | What it serves | Who can reach it |
|---|---|---|
| `/hub` | Directory of all services, with live health | LAN + tailnet |
| `/openwebui` | The chat interface | Anyone (it has its own login) |
| `/status` | Service health, **scheduled job history**, logs, diagnostics | LAN + tailnet |
| `/ollama/` | Local model API, for scripts | LAN + tailnet |
| `/health` | One word — `ok`, `warn`, or `fail` — for uptime monitoring | Anyone |
| `/status/api` | The full status as JSON | LAN + tailnet |
| `:3000` | Open WebUI directly, bypassing the proxy | Unchanged |

> **Why `/openwebui` redirects rather than serving in place.** Open WebUI is a SvelteKit app whose asset URLs are absolute from the site root (`/_app/…`), and it has no base-path setting. Served under a subpath, the HTML loads but every asset 404s and you get a blank page — a [known upstream limitation](https://github.com/open-webui/open-webui/discussions/6650). So `/openwebui` issues a 302 to `/app/`, which Caddy strips before handing the request over. You get the memorable URL; the app gets the root-relative paths it needs. The Ollama API, being a plain REST API, *is* served under its path prefix properly.

## OpenHands code-maintenance agent

The project includes a separate OpenHands service for natural-language code maintenance. It works in a separate clone at `~/hybrid-ai-agent`; the deployment directory is not visible to the agent, creates isolated agent-server containers, and supports an inspect, branch, edit, test, and commit workflow. It is not embedded in Open WebUI and is bound to loopback only. Use an SSH tunnel over Tailscale. See [openhands/README.md](openhands/README.md).

The OpenHands controller uses the Docker socket to create sandboxes. Docker-socket access is effectively host-level control. Do not publish the OpenHands port through Caddy or expose it to the LAN or internet. Keep human review and branch protection enabled.

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
>
> A Pi 5 takes NVMe through the official M.2 HAT (or any PCIe-to-M.2 adapter). 256 GB is ample: a handful of models plus your entire chat history and vector store.
>
> An SD card will work, and everything in this project runs on one. But plan on replacing it periodically, buy a high-endurance model, and keep backups current. `install.sh` and `doctor.sh` both warn when they detect SD-card boot.

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
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker "$USER"

# 4. Tailscale
curl -fsSL https://tailscale.com/install.sh | sudo sh

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

If `docker run` fails with a permissions error, you skipped the log out and back in.

**Recommended hardening**, since this machine will hold your entire conversation history:

```bash
sudo apt-get install -y unattended-upgrades && sudo dpkg-reconfigure -plow unattended-upgrades
sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo systemctl restart ssh      # ensure your SSH key works BEFORE running this
```

### 3. OpenHands maintenance prerequisites

- Docker Engine and Compose v2, already required by the base project.
- The existing Pi 5 with 16 GB and NVMe recommended baseline. OpenHands adds a controller and temporary agent containers.
- An LLM provider/model configured in the OpenHands Settings UI. Its credentials are stored in OpenHands state under `~/.openhands`, not in repository `.env`.
- Optional GitHub credentials for push and pull-request creation. Prefer a GitHub App or fine-grained token restricted to this repository with Contents read/write and Pull requests read/write.
- Tailscale and SSH access to the Pi because the OpenHands UI is loopback-only.

### 4. External services

Three accounts. One is free, one is pay-as-you-go, one is free for personal use.

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

> This key is entered into the **RunPod pod template**, not into any file in this repo. See the table in [External account dependencies](#external-account-dependencies).

**OAuth client for CI** — only needed if you want automated deploys. Admin console → **Settings** → **OAuth clients** → **Generate**:

- Scope: `auth_keys` (write)
- Tags: `tag:ci`

You will also need an ACL rule permitting CI to reach the Pi. Admin console → **Access controls**:

```jsonc
{
  "tagOwners": { "tag:ci": ["autogroup:admin"] },
  "acls": [
    { "action": "accept", "src": ["autogroup:member"], "dst": ["*:*"] },
    { "action": "accept", "src": ["tag:ci"], "dst": ["100.x.x.x:22"] }  // your Pi
  ]
}
```

#### RunPod — on-demand GPU (pay as you go)

Rents GPU time by the minute. You only pay while the pod is running, which is why the idle watchdog matters so much.

| | |
|---|---|
| **Sign up** | [runpod.io](https://runpod.io) |
| **Cost** | Billed per minute of runtime. A 48 GB card runs roughly \$0.35–0.80/hr depending on type and region. Occasional personal use typically lands in single-digit dollars per month |
| **Credit** | Add \$10–25 to start |
| **Credentials needed** | API key + pod ID |

**API key** — Console → **Settings** → **API Keys** → **+ API Key**. Read/write permission. Format: `rpa_...`

**Creating the pod** — full walkthrough in [`runpod/README.md`](runpod/README.md). Summary:

- GPU: 48 GB VRAM (A6000, A40, or L40S) is the sweet spot for a 32B AWQ model
- Template: a PyTorch/CUDA base image
- Container disk: 20 GB · Volume: 100 GB mounted at `/workspace`
- **Do not expose any HTTP ports** — all access is over Tailscale
- After creation, copy the pod ID from the URL or pod card

> **Cost control:** set a spending limit in RunPod billing settings as a backstop. The watchdog is reliable, but a hard cap costs nothing and protects you from a misconfiguration.

#### Cloudflare R2 — encrypted offsite backups (pay as you go, pennies)

Stores your encrypted backups. Data is encrypted on the Pi before upload, so Cloudflare holds ciphertext it cannot read.

| | |
|---|---|
| **Sign up** | [cloudflare.com](https://cloudflare.com) — R2 must be enabled on the account before tokens can be created |
| **Cost** | ~\$0.015/GB/month stored, and **nothing for egress**. A typical setup costs well under a dollar a month |
| **Credentials needed** | Account ID, bucket name, R2 Access Key ID, Secret Access Key |

**Create the bucket:** R2 object storage → **Create bucket** → name it `hybrid-ai-backup`.

**Create a scoped token:** R2 → **Overview** → **Manage** next to **API Tokens** → **Create Account API token**:

- Permission: **Object Read & Write** — not *Admin*; this token cannot create or delete buckets
- Buckets: **Apply to specific buckets only** → select your bucket

Copy the Access Key ID and Secret Access Key immediately; the secret is shown once. Your **account ID** is on the R2 Overview page, and the endpoint derives from it: `https://<ACCOUNT_ID>.r2.cloudflarestorage.com`

> **Zero egress is the point.** With most providers, the day you restore 50 GB is the day you get a surprise bill. Restoring from R2 costs nothing in bandwidth — which matters precisely when you are already having a bad day.

#### GitHub — code hosting and automated deploys (free)

Optional. Everything works if you deploy by hand. CI just means `git push` updates the Pi for you.

| | |
|---|---|
| **Sign up** | [github.com](https://github.com) |
| **Cost** | Free — public repos get unlimited Actions minutes; private repos get 2,000/month |
| **Credentials needed** | Seven repository secrets, listed below |

### 5. Skills assumed

You should be comfortable with a Linux terminal over SSH, basic `git`, and editing files in `nano` or `vim`. Prior Docker experience helps but is not required — the install script handles it.

---

## External account dependencies

**Every credential this project uses, and exactly where each one goes.** This is the table to check first when something is not working.

| Credential | Service | Where you obtain it | Where it is loaded | How it gets there |
|---|---|---|---|---|
| `TAILSCALE_AUTH_KEY` | Tailscale | Admin → Settings → Keys | **RunPod pod template** environment variables | Pasted into the RunPod web console when creating the pod |
| `RUNPOD_API_KEY` | RunPod | Console → Settings → API Keys | **Both** the Pi's `.env` *and* the RunPod pod template | On the Pi: `install.sh` prompts you. On the pod: pasted into the template |
| `RUNPOD_POD_ID` | RunPod | Pod card or browser URL after creating the pod | Pi `.env` | `install.sh` prompts you |
| `WEBUI_SECRET_KEY` | *self-generated* | — | Pi `.env` | Auto-generated by `install.sh` on first run, then reused forever |
| `TAILSCALE_IP` | *auto-discovered* | — | Pi `.env` | `install.sh` finds it by querying the tailnet for the `runpod-worker` peer (legacy `runpod-vllm` also matched) |
| `AWS_ACCESS_KEY_ID` | Cloudflare R2 | R2 → Manage API Tokens | `~/.config/hybrid-ai-backup/r2.env` | `install.sh` prompts you |
| `AWS_SECRET_ACCESS_KEY` | Cloudflare R2 | R2 → Manage API Tokens | `~/.config/hybrid-ai-backup/r2.env` | `install.sh` prompts you |
| `RESTIC_REPOSITORY` | *derived* | Account ID + bucket name | `~/.config/hybrid-ai-backup/r2.env` | Built by `install.sh` |
| **Repository password** | *self-generated* | — | `~/.config/hybrid-ai-backup/repo-password` | Generated by `install.sh`. **Copy it into a password manager — there is no recovery** |
| `TS_OAUTH_CLIENT_ID` | Tailscale | Admin → Settings → OAuth clients | GitHub repository secret | Repo → Settings → Secrets and variables → Actions |
| `TS_OAUTH_SECRET` | Tailscale | Admin → Settings → OAuth clients | GitHub repository secret | Same |
| `PI_TAILSCALE_IP` | *your tailnet* | `tailscale ip -4` on the Pi | GitHub repository secret | Same |
| `PI_SSH_USER` | *your Pi* | Usually `pi` | GitHub repository secret | Same |
| `PI_SSH_KEY` | *self-generated* | `ssh-keygen -t ed25519` | GitHub repository secret | Paste the **private** key; the public half goes in the Pi's `~/.ssh/authorized_keys` |
| `PI_REPO_PATH` | *your Pi* | e.g. `/home/pi/hybrid-ai` | GitHub repository secret | Same |
| `PI_SSH_HOST_KEY` | *your Pi* | `ssh-keyscan -t ed25519 $(tailscale ip -4) \| ssh-keygen -lf -` | GitHub repository secret | Same — prevents host impersonation |

### Three places credentials live — and one place they must never

```
1. Pi: ./.env                          created by install.sh, mode 0600, gitignored
2. Pi: ~/.config/hybrid-ai-backup/     backup credentials, mode 0600,
                                       OUTSIDE the repo by design
3. RunPod pod template                 entered in the RunPod web console
4. GitHub repository secrets           Settings → Secrets and variables → Actions

NEVER: any file tracked by git.
```

Backup credentials sit outside the repository deliberately: no `git add`, no stray `tar czf` of the project folder, and no CI checkout can sweep them up. They are also separate from `.env`, so a compromise of the application stack does not automatically grant the ability to destroy your backup history.

`RUNPOD_API_KEY` is the one credential that appears in two places, which trips people up. The Pi needs it to *start* the pod; the pod needs it to *stop itself*. Same key, two destinations.

**If a key is ever exposed:** rotate it at the provider immediately. Deleting the commit is not enough — git history preserves it, and any clone or fork retains a copy.

---

## Installation

### Step 1 — Pi setup

```bash
git clone https://github.com/YOUR_USERNAME/hybrid-ai.git
cd hybrid-ai
chmod +x inschmod +x install.sh doctor.sh collect-diagnostics.sh \
         backup/backup.sh backup/restore.sh runpod/start.sh \
         scripts/setup-agent-workspace.sh \
         openhands/scripts/openhands-control.shtall.sh runpod/start.sh

sudo tailscale up          # follow the printed URL to authenticate
tailscale ip -4            # note this address for later
```

### Step 2 — Create the RunPod pod

Follow [`runpod/README.md`](runpod/README.md). At the end you will have a pod ID and a pod that has joined your tailnet once (so the Pi can discover its address).

### Step 3 — Run the installer

```bash
./install.sh
```

It prompts for your RunPod API key and pod ID, finds the pod on your tailnet, writes `.env`, and starts the stack — Ollama, Open WebUI, the status page, the proxy, and the OpenHands agent. Expect 5–10 minutes on first run while images download.

### Step 4 — Configure OpenHands

From your workstation, create a tunnel:

```bash
ssh -L 3001:127.0.0.1:3001 <user>@<pi-tailnet-name-or-ip>
```

Browse to `http://127.0.0.1:3001`, configure the LLM provider/model in Settings, and ask the agent to read `/workspace/openhands/AGENTS.md`. The UI is not added to the reverse proxy by design.

### Step 5 — Configure Open WebUI

1. Open `http://<your-pi-ip>:3000`
2. **Create the admin account** — the first account registered becomes the administrator
3. Pull a local model for everyday use:

   ```bash
   docker exec -it ollama ollama pull llama3.2:3b
   ```

4. Install the cloud pipe: **Workspace → Functions → +** → paste the entire contents of [`openwebui/runpod_pipe.py`](openwebui/runpod_pipe.py) → **Save** → toggle it **on**

### Step 6 — Verify

Open `http://<your-pi-ip>/hub` in a browser to see everything at once, or from the CLI:

```bash
./doctor.sh
```

Everything should report healthy. Then select the cloud model from the dropdown and send a message. You should see status updates as the pod resumes and the model loads, then streaming text. First run takes several minutes; that is the expected cold start.

### Step 7 — Backups

If you skipped the backup prompt during `./install.sh`, re-run it and answer yes. Then do the one thing that cannot be automated:

```bash
cat ~/.config/hybrid-ai-backup/repo-password
```

Put that in a password manager. If the SD card dies and the password dies with it, your backups are permanently unreadable — restic has no recovery path, by design.

Rehearse a restore before you need one:

```bash
./backup/restore.sh --test
```

### Step 8 — Automated deploys (optional)

Add the six GitHub secrets from the table above, push to `main`, and watch the Actions tab. See [`.github/README.md`](.github/README.md).

---

## Repository layout

| Path | What it holds | Documentation |
|---|---|---|
| `README.md` | This file — start here | — |
| `install.sh` | The one script you run on the Pi | Commented inline |
| `doctor.sh` | One-command health check — run this first when anything misbehaves | Commented inline |
| `collect-diagnostics.sh` | Bundles logs and status into one redacted file you can share or paste into an AI chat | Commented inline |
| `docker-compose.yml` | Blueprint for the Pi containers | Commented inline |
| `.gitignore` | Security control — keeps secrets and data out of git | Commented inline |
| `openwebui/` | The Python bridge to the cloud GPU | [`openwebui/README.md`](openwebui/README.md) |
| `status/` | Status page and reverse proxy | [`status/README.md`](status/README.md) |
| `runpod/` | Everything that runs on the rented GPU | [`runpod/README.md`](runpod/README.md) |
| `backup/` | Encrypted backups to Cloudflare R2, and restore tooling | [`backup/README.md`](backup/README.md) |
| `.github/` | CI/CD automation | [`.github/README.md`](.github/README.md) |
| `docs/` | Troubleshooting and operations | [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) |
| `SECURITY.md` | Threat model, secure-code review findings, disclosure policy | [`SECURITY.md`](SECURITY.md) |
| `webui_data/` | **Your data.** Chats, documents, vectors | Created at runtime, never committed |
| `ollama_data/` | Downloaded model files | Created at runtime, never committed |
| `openhands/` | Natural-language code-maintenance agent | [openhands/README.md](openhands/README.md) |
| `scripts/` | Agent workspace setup and isolation guard | Commented inline |

---

## Privacy design

Claims are only worth what enforces them. Each one below maps to a specific mechanism you can go and read:

| Claim | Enforced by | Where |
|---|---|---|
| Prompts never traverse the public internet | Address validated against `100.64.0.0/10` before any transmission; refuses to send otherwise | `runpod_pipe.py` → `_is_mesh_address()` |
| Proxy settings cannot reroute traffic | `trust_env=False` on the HTTP client | `runpod_pipe.py` → `pipe()` |
| The GPU server keeps no record of prompts | `--disable-log-requests`, `--disable-log-stats`, `VLLM_CONFIGURE_LOGGING=0` | `runpod/start.sh` |
| No telemetry leaves the Pi | `DO_NOT_TRACK`, `ANONYMIZED_TELEMETRY=false`, `SCARF_NO_ANALYTICS`, community sharing disabled | `docker-compose.yml` |
| Documents are embedded locally | `RAG_EMBEDDING_ENGINE=""` — computed in-container, stored in local Chroma | `docker-compose.yml` |
| No inbound ports are exposed | Tailscale mesh only; Ollama bound to `127.0.0.1`; no RunPod HTTP proxy | `docker-compose.yml`, pod config |
| The status page cannot leak credentials | It is given none — no `.env`, no API keys; read-only, unprivileged container | `docker-compose.yml`, `status/app.py` |
| The status page is not internet-reachable | Caddy allows `/status`, `/hub` and `/ollama` only from private ranges and `100.64.0.0/10` | `status/Caddyfile` |
| The unauthenticated Ollama API is not exposed | Same allowlist; Ollama's own port stays bound to `127.0.0.1` | `status/Caddyfile`, `docker-compose.yml` |
| Proxy customisation survives a rebuild | `status/` including your `Caddyfile` is captured in every backup | `backup/backup.sh` |
| Model repo code cannot execute on the pod | `--trust-remote-code` disabled by default | `runpod/start.sh` |
| Credentials never appear in URLs or process lists | Bearer headers; `--auth-key=file:` then shredded | `runpod_pipe.py`, `start.sh` |
| Errors cannot leak credentials | Regex scrubbing before any message is displayed | `runpod_pipe.py` → `_scrub()` |
| Backups are unreadable by Cloudflare | restic encrypts on the Pi before upload; R2 stores ciphertext only | `backup/backup.sh` |
| Backup credentials survive a repo compromise | Stored outside the repo, mode 0600, separate from `.env` | `~/.config/hybrid-ai-backup/` |
| Secrets cannot be committed | `.gitignore` plus a CI job that fails the build if they are | `.gitignore`, `deploy.yml` |
| Auth keys are not left in memory | Unset immediately after the pod joins the tailnet | `runpod/start.sh` |

**What this does not protect against.** RunPod is the infrastructure operator and can in principle observe the memory of a machine you rent from them. This design ensures nothing is *written down* — no logs, no disk persistence, no third-party analytics — and that data in transit is encrypted end to end. It does not make the GPU host a trusted enclave. For genuinely sensitive material, keep it on the local model.

---

## Operating costs

| Component | Typical cost |
|---|---|
| Raspberry Pi electricity | ~\$0.50–1.50/month |
| Tailscale | \$0 (free tier) |
| GitHub Actions | \$0 |
| RunPod GPU | Only while running — commonly a few dollars a month for occasional use |
| RunPod storage | Persistent volumes bill even when the pod is stopped; check current rates |
| Cloudflare R2 | ~\$0.015/GB/month stored, \$0 egress — typically well under \$1/month |

The watchdog is what makes this economical. Without it, one forgotten pod running for a weekend costs more than a year of everything else combined.

---

## Quick reference

```bash
# In a browser
#   http://<your-pi>/hub        everything, with live health
#   http://<your-pi>/status     health + scheduled job history

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
./backup/restore.sh --list         # list snapshots
./backup/restore.sh --test         # rehearse a restore — quarterly
./backup/restore.sh --latest       # full rebuild onto a new Pi
systemctl --user list-timers 'hybrid-ai-*'

# Manage local models
docker exec -it ollama ollama list
docker exec -it ollama ollama pull llama3.2:3b

# Check the tailnet
tailscale status
ttailscale status | grep runpod-

# Force-stop the GPU pod (belt and braces)
# Key passed via header, not the URL -- URLs land in proxy and access logs.
curl -s -X POST "https://api.runpod.io/graphql" \
  -H "Authorization: Bearer $RUNPOD_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"query":"mutation{podStop(input:{podId:\"YOUR_POD_ID\"}){id desiredStatus}}"}'
```

Problems? → open `http://<your-pi>/status`, or run `./doctor.sh`, then [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md). Still stuck? `./collect-diagnostics.sh` and share the result.  ·  Security posture → [`SECURITY.md`](SECURITY.md)

---

## License

MIT. See [`LICENSE`](LICENSE).

Built on [Open WebUI](https://github.com/open-webui/open-webui), [Ollama](https://ollama.com), [vLLM](https://github.com/vllm-project/vllm), [Tailscale](https://tailscale.com), and [RunPod](https://runpod.io) — each under its own license.
