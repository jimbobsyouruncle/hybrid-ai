# hybrid-ai

**A private, self-hosted AI platform that runs small models locally on a Raspberry Pi and borrows a cloud GPU only when it needs one — then shuts it off automatically.**

[![Deploy Control Plane](https://github.com/jimbobsyouruncle/hybrid-ai/actions/workflows/deploy.yml/badge.svg)](https://github.com/jimbobsyouruncle/hybrid-ai/actions/workflows/deploy.yml)
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
+──────────────────────────────────────────────────────────────────+
|  YOUR HOME                                                       |
|                                                                  |
|  +────────────────────────────────────────────────────────────+  |
|  |  Raspberry Pi  ::  local control plane                     |  |
|  |                                                            |  |
|  |   Open WebUI ---- chat UI, history, documents              |  |
|  |        |                                                   |  |
|  |        +---> Ollama ---- small models, runs on the Pi      |  |
|  |        |                                                   |  |
|  |        +---> runpod_pipe.py --+                            |  |
|  |                               |                            |  |
|  |   ./webui_data   ./ollama_data   (your data, on disk)      |  |
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

If `docker run` fails with a permissions error, you skipped the log out and back in.

**Recommended hardening**, since this machine will hold your entire conversation history:

```bash
sudo apt-get install -y unattended-upgrades && sudo dpkg-reconfigure -plow unattended-upgrades
if sudo sh -c 'ls /home/*/.ssh/authorized_keys /root/.ssh/authorized_keys 2>/dev/null | xargs grep -qs "^ssh-"'; then
    echo "SSH public key found. Disabling password authentication over SSH..."
    sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    sudo systemctl reload ssh
else
    echo "ERROR: No valid SSH public key found in /home/*/.ssh/ or /root/.ssh/. Password auth unchanged." >&2
fi
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
|
