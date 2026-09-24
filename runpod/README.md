# `runpod/` — Cloud Inference Plane

Everything in this folder runs on the **rented GPU machine**, not on your Raspberry Pi.

| File | Purpose |
|---|---|
| `start.sh` | The pod's entrypoint. Joins your private network, arms the cost watchdog, starts the model server. |

---

## What this folder is responsible for

The Pi cannot run a 32-billion-parameter model — it does not have the memory or the compute. So when you need real capability, a GPU machine is rented by the minute from RunPod.

The problem with rented GPUs is that they bill continuously whether you are using them or not, and it is remarkably easy to leave one running overnight. `start.sh` solves that by making the pod responsible for its own shutdown: it watches its own GPU utilisation and stops itself after fifteen idle minutes. You never have to remember.

The three jobs `start.sh` performs, in order:

1. **Join the private network.** Connects to your Tailscale mesh as `runpod-worker`, giving it a `100.x.x.x` address reachable only by your own devices. No public ports are opened.
2. **Arm the watchdog.** A background loop samples GPU utilisation every 5 seconds and   keeps the peak across each 60-second window. A single non-zero reading in a window resets the idle counter to zero, so a long generation can never be interrupted. After 15 consecutive idle windows it calls RunPod's shutdown API. A failed `nvidia-smi` counts as *unknown*, not idle — five consecutive unreadable windows stop the pod as genuinely broken rather than billing it indefinitely.
3. **Serve the model.** Launches vLLM with an OpenAI-compatible API, with all request and statistics logging disabled.

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

### 3. Create the pod

RunPod console → **Pods** → **Deploy**:

| Setting | Value | Notes |
|---|---|---|
| GPU | 48 GB VRAM — A6000, A40, or L40S | Comfortable fit for a 32B AWQ model with room for context |
| Template | PyTorch 2.x / CUDA 12.x base image | Any image with Python 3.10+ and CUDA works |
| Container disk | 20 GB | Holds the OS layer only |
| Volume disk | 100 GB, mounted at `/workspace` | Persists model weights between restarts — worth it, see below |
| **HTTP ports** | **leave empty** | Critical. Exposing a port here would publish your model to the internet |
| TCP ports | leave empty | |

> **Why the volume is worth paying for:** the model is roughly 20 GB. Without a persistent volume it re-downloads on every single start, adding 10+ minutes to each cold start. With it, weights are cached and a cold start is 2–5 minutes. The volume bills even while stopped, but it is far cheaper than the GPU time wasted re-downloading.

> **Why no HTTP ports:** RunPod's proxy would make the model reachable from the public internet at a guessable URL, with no authentication. All access here is over the encrypted Tailscale mesh instead.

### 4. Set the pod's environment variables

In the pod template's **Environment Variables** section:

| Variable | Value | Required |
|---|---|---|
| `TRUST_REMOTE_CODE` | *(leave unset)* | No — **setting this to `1` lets code inside the model repository execute on the pod, with access to its credentials.** Only for a model you have specifically vetted |
| `VLLM_PORT` | `8000` | No — must match `VLLM_PORT` in the Pi's `.env` |
| `READY_TIMEOUT` | *(default)* | No — how long to wait for vLLM to report ready before treating the start as failed |
| `MAX_RESTARTS` | *(default)* | No — restart budget before the pod stops itself on a crash loop |
| `TAILSCALE_AUTH_KEY` | `tskey-auth-...` from step 1 | **Yes** — the pod cannot join your network without it |
| `RUNPOD_API_KEY` | `rpa_...` from step 2 | **Yes** — without it the watchdog is disabled and the pod bills forever |
| `RUNPOD_POD_ID` | *(do not set)* | Injected automatically by RunPod |
| `VLLM_MODEL` | `Qwen/Qwen2.5-Coder-32B-Instruct-AWQ` | No — this is the default |
| `IDLE_MINUTES` | `15` | No — lower it to `10` to be more aggressive about cost |
| `MAX_MODEL_LEN` | `16384` | No — raise for longer conversations, at the cost of GPU memory |
| `GPU_MEM_UTIL` | `0.92` | No — lower to `0.85` if you hit out-of-memory errors |
| `TS_HOSTNAME` | `runpod-worker` | No — **if you change it, add it to `PEER_HOSTNAMES` in `install.sh` to match** |

> If `RUNPOD_API_KEY` is missing, `start.sh` prints a warning and runs without a watchdog. The pod will then bill continuously until you stop it by hand. Do not skip this variable.

### 5. Install the script on the pod

Pick whichever fits how you work.

**Option A — paste it into the start command** (fastest to try):

Set the pod's Docker start command to:

```bash
bash -c "curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/hybrid-ai/main/runpod/start.sh -o /start.sh && chmod +x /start.sh && /start.sh"
```

Simple, but it fetches from GitHub on every boot. Fine for a public repo; use option B or C for anything private.

**Option B — store it on the persistent volume** (recommended):

SSH into the pod once and run:

```bash
mkdir -p /workspace/bin
curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/hybrid-ai/main/runpod/start.sh \
  -o /workspace/bin/start.sh
chmod +x /workspace/bin/start.sh
```

Then set the start command to `/workspace/bin/start.sh`. The script now lives on the volume and survives restarts with no external dependency.

**Option C — bake it into a custom image** (most robust):

```dockerfile
FROM runpod/pytorch:2.4.0-py3.11-cuda12.4.1-devel-ubuntu22.04

RUN apt-get update && apt-get install -y --no-install-recommends \
        curl ca-certificates jq iproute2 && \
    curl -fsSL https://tailscale.com/install.sh | sh && \
    pip install --no-cache-dir vllm && \
    rm -rf /var/lib/apt/lists/*

COPY runpod/start.sh /start.sh
RUN chmod +x /start.sh

ENTRYPOINT ["/start.sh"]
```

Dependencies are pre-installed, so cold starts are noticeably faster.

### 6. First boot and verification

Start the pod once manually. Watch the logs — you are looking for:

```
[start.sh] Mesh address acquired: 100.x.x.x
[start.sh] GPU: 1x NVIDIA RTX A6000 (49140 MiB each)
[start.sh] Arming idle watchdog: 15 min @ 0% GPU -> podStop
[start.sh] Launching vLLM -- model=Qwen/... tp=1 port=8000
```

Then confirm from the Pi:

```bash
tailscale status | grep runpod-
curl http://<pod-tailscale-ip>:8000/v1/models
```

Once the peer is visible, run `./install.sh` on the Pi so it records the address. From then on the pod can stay stopped — the pipe wakes it on demand.

---

## Understanding the design decisions

### Userspace networking

Tailscale normally creates a virtual network adapter using a Linux kernel feature called TUN. RunPod containers do not grant access to it. The `--tun=userspace-networking` flag makes Tailscale do the same work entirely in software instead. Marginally slower, but it requires no special privileges and works reliably in a container.

### Runtime State Capture

Every time the pod starts it gets a different network address, and potentially a different GPU count. Rather than have each component look these up independently — and risk them disagreeing — `start.sh` detects them once at boot and writes them to `/etc/runtime.env`. Anything needing those values reads that file. One source of truth, established at a single point in time.

### The watchdog's five-minute grace period

Loading a 32B model takes several minutes, and throughout that time the GPU genuinely reports 0% utilisation because it is waiting on disk reads. A naive watchdog would shut the pod down before it had finished starting. The initial `sleep 300` exists precisely to prevent that.

The counter also **resets to zero** on any non-zero reading. That means a ten-minute generation can never be interrupted partway through — the GPU is busy the entire time, so the idle count never accumulates.

### Why logging is disabled

vLLM logs request and response text by default, which would defeat the entire premise. Three separate switches turn it off:

| Setting | Stops |
|---|---|
| `--disable-log-requests` | Prompt and completion text |
| `--disable-log-stats` | Throughput and token statistics |
| `VLLM_CONFIGURE_LOGGING=0` | vLLM's logging subsystem entirely |

`HF_HUB_DISABLE_TELEMETRY=1` additionally stops Hugging Face reporting which models you download.

### The auth key is wiped after use

Once `tailscale up` succeeds, the key is written into Tailscale's own state file and is no longer needed in memory. `start.sh` unsets it immediately, so any other process on the pod that reads the environment cannot find it.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Pod stopped itself and the log shows `gpu_unreadable` | `nvidia-smi` failed for five consecutive windows — usually a driver fault, not idleness | Check `nvidia-smi` on a fresh pod; if it recurs, the host is faulty — redeploy on a different one |
| `TAILSCALE_AUTH_KEY is not set` | Variable missing from the pod template | Add it, then restart the pod |
| `tailscaled died during startup` | Auth key expired or already consumed | Check `/var/log/tailscaled.log`; generate a new reusable key |
| `No CUDA devices visible` | GPU not attached, or a CPU-only image | Verify the pod has a GPU; run `nvidia-smi` on the pod |
| Peer never appears in `tailscale status` | Key was not marked pre-approved | Regenerate with pre-approved enabled |
| Pod never stops, bill keeps growing | `RUNPOD_API_KEY` missing → watchdog disabled | Check the logs for the warning; add the variable |
| Pod stops while still in use | GPU genuinely idle between messages | Expected — the pipe wakes it again. Raise `IDLE_MINUTES` if it annoys you |
| Out of memory loading the model | `GPU_MEM_UTIL` too high, or GPU too small | Lower to `0.85`, reduce `MAX_MODEL_LEN`, or use a larger GPU |
| Cold start takes 10+ minutes | No persistent volume — weights re-downloading | Attach a 100 GB volume at `/workspace` |

**Manual stop**, if you ever need it:

```bash
# Key passed via header, not the URL -- URLs land in proxy and access logs.
curl -s -X POST "https://api.runpod.io/graphql" \
  -H "Authorization: Bearer $RUNPOD_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"query":"mutation{podStop(input:{podId:\"YOUR_POD_ID\"}){id desiredStatus}}"}'
```

---

## Swapping the model

Change `VLLM_MODEL` in the pod template, and `VLLM_MODEL_NAME` in the Pi's `.env`. **Both must match exactly** or vLLM will reject the request.

If you move to a model that is not AWQ-quantised, remove the `--quantization awq` flag from `start.sh` as well — passing it to an unquantised model causes a startup failure.
