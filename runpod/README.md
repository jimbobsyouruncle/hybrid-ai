# `runpod/` — Cloud Inference Plane

Everything in this folder runs on the **rented GPU machine**, not on your Raspberry Pi.

| File | Purpose |
|---|---|
| `start.sh` | The pod's entrypoint. Injects SSH public keys, joins your private Tailscale network, arms the cost watchdog, and starts the vLLM model server. |

---

## What this folder is responsible for

The Pi cannot run a 32-billion-parameter model — it does not have the memory or the compute. So when you need real capability, a GPU machine is rented by the minute from RunPod.

The problem with rented GPUs is that they bill continuously whether you are using them or not, and it is remarkably easy to leave one running overnight. `start.sh` solves that by making the pod responsible for its own shutdown: it watches its own GPU utilisation and stops itself after fifteen idle minutes. You never have to remember.

The main jobs `start.sh` performs, in order:

1. **Inject SSH Public Keys.** Reads RunPod's account-injected `$PUBLIC_KEY` environment variable, appends it to `/root/.ssh/authorized_keys`, and launches `sshd` internally so you can SSH directly into the container over Tailscale without exposing port 22 to the public internet.
2. **Join the private network.** Connects to your Tailscale mesh as `runpod-worker`, giving it a `100.x.x.x` address reachable only by your own devices. No public ports are opened in RunPod.
3. **Arm the watchdog.** A background loop samples GPU utilisation every 5 seconds and keeps the peak across each 60-second window. A single non-zero reading in a window resets the idle counter to zero, so a long generation can never be interrupted. After 15 consecutive idle windows it calls RunPod's shutdown API. A failed `nvidia-smi` counts as *unknown*, not idle — five consecutive unreadable windows stop the pod as genuinely broken rather than billing it indefinitely.
4. **Serve the model.** Launches vLLM with an OpenAI-compatible API bound strictly to `127.0.0.1`, with all request and statistics logging disabled.

---

## Setting up the pod, step by step

### 1. Get a Tailscale auth key

Tailscale admin console → **Settings** → **Keys** → **Generate auth key**:

| Option | Setting | Why |
|---|---|---|
| Reusable | ☑ **on** | The pod stops and starts constantly and must rejoin each time |
| Ephemeral | ☑ **on** | Stopped pods vanish from your device list instead of piling up as dead entries |
| Pre-approved | ☑ **on** | Joins without waiting for manual approval, which would break unattended restarts |
| Expiry | 90 days | Set a calendar reminder to rotate |

Copy it now — it is displayed only once. Format: `tskey-auth-...`

### 2. Get a RunPod API key

RunPod console → **Settings** → **API Keys** → **+ API Key**, read/write. Format: `rpa_...`

This is the same key you give to the Pi. The Pi uses it to *start* the pod; the pod uses it to *stop itself*.

### 3. Build and Publish the Custom Container Image

Official vLLM Docker images hardcode `vllm serve` as their default `ENTRYPOINT`. Attempting to pass a startup script string via RunPod's "Docker Start Command" UI field forces vLLM to parse the script as compilation flags, causing container boot failures. 

To bypass this, you must build a custom container image hosted on GitHub Container Registry (GHCR) that overrides the container `ENTRYPOINT`.

#### Local Repository Setup
In your dedicated container repository (e.g., `runpod-hybrid-worker`), create the following file structure:

```text
runpod-hybrid-worker/
├── .gitattributes
├── Dockerfile
├── runpod/
│   └── start.sh
└── .github/
    └── workflows/
        └── build.yml
```

1. **Line Ending Normalization (`.gitattributes`):**
   To prevent Windows line endings (`CRLF`) from corrupting the Linux bash script, enforce `LF` in `.gitattributes`:
   ```text
   * text=auto eol=lf
   *.sh text eol=lf
   ```

2. **Dockerfile (`Dockerfile`):**
   ```dockerfile
   FROM vllm/vllm-openai:v0.30.0

   ENV DEBIAN_FRONTEND=noninteractive

   RUN apt-get update -qq && apt-get install -y -qq \
       curl \
       jq \
       iproute2 \
       ca-certificates \
       openssh-server \
       && curl -fsSL [https://tailscale.com/install.sh](https://tailscale.com/install.sh) | sh \
       && rm -rf /var/lib/apt/lists/*

   RUN mkdir -p /var/run/sshd && \
       mkdir -p /root/.ssh && \
       chmod 700 /root/.ssh

   COPY runpod/start.sh /start.sh
   RUN chmod +x /start.sh

   ENTRYPOINT ["/bin/bash", "-lc", "exec /start.sh"]
   ```

3. **Automated Build Pipeline (`.github/workflows/build.yml`):**
   ```yaml
   name: Build and Push RunPod Worker

   on:
     push:
       branches: [ "main" ]
       paths:
         - 'Dockerfile'
         - 'runpod/start.sh'
         - '.github/workflows/build.yml'

   jobs:
     build:
       runs-on: ubuntu-latest
       permissions:
         contents: read
         packages: write

       steps:
         - name: Checkout repository
           uses: actions/checkout@v4

         - name: Log in to GitHub Container Registry
           uses: docker/login-action@v3
           with:
             registry: ghcr.io
             username: ${{ github.actor }}
             password: ${{ secrets.GITHUB_TOKEN }}

         - name: Build and push Docker image
           uses: docker/build-push-action@v5
           with:
             context: .
             push: true
             tags: ghcr.io/${{ github.repository }}:latest
   ```

4. **Publishing & Package Visibility:**
   * Push your changes to GitHub: `git add . && git commit -m "Build worker" && git push`
   * Once the GitHub Action completes, go to your GitHub repository → **Packages** → click your container image → **Package Settings**.
   * Under **Danger Zone**, set **Package Visibility** to **Public**.

### 4. Deploy the Pod on RunPod

RunPod console → **Pods** → **Deploy Pod**:

| Setting | Value | Notes |
|---|---|---|
| Container Image | `ghcr.io/YOUR_GITHUB_USERNAME/YOUR_REPO_NAME:latest` | Your public custom worker image |
| Docker Start Command | **leave empty** | The Dockerfile `ENTRYPOINT` handles execution |
| GPU | 48 GB VRAM — A6000, A40, or L40S | Comfortable fit for a 32B AWQ model with room for context |
| Container disk | 20 GB | Holds the OS layer only |
| Volume disk | 100 GB, mounted at `/workspace` | Persists model weights between restarts |
| **HTTP ports** | **leave empty** | Critical. Exposing ports here bypasses Tailscale encryption |
| **TCP ports** | **leave empty** | Critical. SSH and vLLM run strictly inside the Tailscale mesh |

> **Why the volume is worth paying for:** the model is roughly 20 GB. Without a persistent volume it re-downloads on every single start, adding 10+ minutes to each cold start. With it, weights are cached and a cold start is 2–5 minutes.

### 5. Set the pod's environment variables

In the pod template's **Environment Variables** section:

| Variable | Value | Required |
|---|---|---|
| `TAILSCALE_AUTH_KEY` | `tskey-auth-...` or secret reference | **Yes** — the pod cannot join your network without it |
| `RUNPOD_API_KEY` | `rpa_...` or secret reference | **Yes** — without it the watchdog is disabled and the pod bills forever |
| `RUNPOD_POD_ID` | *(do not set)* | Injected automatically by RunPod |
| `PUBLIC_KEY` | *(do not set)* | Injected automatically by RunPod from your account settings |
| `VLLM_MODEL` | `Qwen/Qwen2.5-Coder-32B-Instruct-AWQ` | No — this is the default |
| `IDLE_MINUTES` | `15` | No — lower it to `10` to be more aggressive about cost |
| `MAX_MODEL_LEN` | `16384` | No — raise for longer conversations, at the cost of GPU memory |
| `GPU_MEM_UTIL` | `0.92` | No — lower to `0.85` if you hit out-of-memory errors |
| `TS_HOSTNAME` | `runpod-worker` | No — if you change it, update `PEER_HOSTNAMES` in `install.sh` |
| `VLLM_PORT` | `8000` | No — must match `VLLM_PORT` in the Pi's `.env` |

---

## First boot and verification

Start the pod once manually. Watch the logs — you are looking for:

```text
[start.sh] Injecting RunPod public SSH keys...
[start.sh] SSH daemon started. Accessible via Tailscale on port 22.
[start.sh] Starting tailscaled (userspace-networking)...
[start.sh] Mesh address acquired: 100.x.x.x
[start.sh] Arming idle watchdog: 15 min @ 0% GPU -> podStop
[start.sh] Launching vLLM -- model=Qwen/... tp=1 port=8000
```

Confirm connection over Tailscale from your local machine or Pi:

```bash
# 1. Check peer presence
tailscale status | grep runpod-worker

# 2. Test SSH access over Tailscale
ssh root@100.x.x.x

# 3. Test model endpoint over Tailscale
curl [http://100.](http://100.)x.x.x:8000/v1/models
```

---

## Design Decisions & Architecture

### Custom Image vs Command Overrides
Official vLLM images wrap execution inside an immutable `vllm serve` entrypoint. Building a custom container via GitHub Actions ensures our init script runs as PID 1, allowing Tailscale, OpenSSH, and the GPU watchdog to initialize cleanly before vLLM boots.

### Userspace Networking & SSH Isolation
Tailscale runs with `--tun=userspace-networking` so it requires no elevated kernel privileges (`/dev/net/tun`) inside RunPod. OpenSSH binds internally to the container network, accepting RunPod's injected `$PUBLIC_KEY` variable without exposing port 22 or vLLM port 8000 to the public internet.

### Runtime State Capture
Every time the pod starts, it detects its network address and CUDA GPU topology once, writing them to `/etc/runtime.env`. Subshells and watchdog routines read this file as a single source of truth.

### Zero-Trace Logging Posture
vLLM request, token, and prompt persistences are explicitly disabled via runtime flags (`--disable-log-requests`, `--disable-log-stats`, `VLLM_CONFIGURE_LOGGING=0`, `HF_HUB_DISABLE_TELEMETRY=1`).

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `vllm serve: error: argument --compilation-config: Invalid JSON` | You passed a start script string into RunPod's "Start Command" field on a stock image | Use the custom GHCR image built from this directory; leave "Start Command" empty |
| `/start.sh: \r: command not found` | Script saved with Windows `CRLF` line endings | Ensure `.gitattributes` enforces `eol=lf` and rebuild image via GitHub Actions |
| RunPod error `Error pulling image: access denied` | GHCR package visibility is set to Private | GitHub package settings → Change package visibility to **Public** |
| Pod stopped itself and log shows `gpu_unreadable` | `nvidia-smi` failed 5 consecutive times (driver issue) | Deploy pod on a different RunPod host |
| `TAILSCALE_AUTH_KEY is not set` | Variable missing from the pod template | Add variable/secret to pod environment |
| SSH connection refused over Tailscale | `PUBLIC_KEY` variable missing or empty | Ensure public key is uploaded in RunPod Account Settings |

---

## Swapping the model

Change `VLLM_MODEL` in the pod template, and `VLLM_MODEL_NAME` in the Pi's `.env`. **Both must match exactly** or vLLM will reject the request.

If you move to a model that is not AWQ-quantised, set `VLLM_QUANTIZATION` accordingly or leave it empty — passing `awq` to an unquantised model causes a startup failure.
