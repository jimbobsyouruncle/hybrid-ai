# `openwebui/` — Cloud Inference Middleware

| File | Purpose |
|---|---|
| `runpod_pipe.py` | The bridge between the chat window on your Pi and the GPU model in the cloud. |

---

## What a "pipe" is

Open WebUI lets you add custom Python code that appears in the model dropdown as though it were just another model. It calls these **pipes**. From your point of view you pick "Qwen2.5-Coder-32B (RunPod)" and type a message; behind the scenes, this file runs.

That indirection is what makes the on-demand GPU feel seamless. All the machinery — waking a stopped server, waiting for a 20 GB model to load, streaming the reply back — happens inside one file that presents itself as an ordinary model.

---

## What it does, in order

```
You send a message
        │
        ▼
1. SAFETY CHECK   Is the destination inside 100.64.0.0/10?
                  If not, refuse to send anything at all.
        │
        ▼
2. WAKE           Ask RunPod to resume the pod (normally stopped).
                  If it is already running, skip ahead.
        │
        ▼
3. WAIT           Poll /v1/models every 5 seconds until the model
                  reports ready. Connection errors here are normal.
        │
        ▼
4. STREAM         POST the prompt, yield each fragment as it arrives
                  so text appears progressively in the chat.
        │
        ▼
Shutdown is NOT handled here — the pod stops itself after 15 idle
minutes via the watchdog in runpod/start.sh.
```

---

## Installing it

1. Open WebUI → **Workspace** → **Functions**
2. Click **+**
3. Paste the **entire** contents of `runpod_pipe.py`, including the block of text at the very top
4. **Save**, then toggle the function **on**
5. The model now appears in the dropdown

> **Do not remove the triple-quoted block at the top of the file.** Those lines are not a comment — Open WebUI parses them to read the function's title, version, and required Python packages (`httpx`). Without them, the function will not install correctly.

---

## Configuration

You should not need to edit this file to configure it. Every setting reads from an environment variable first, and those come from the `.env` that `install.sh` generated, passed through by `docker-compose.yml`.

To change something temporarily, use **Functions → RunPod vLLM → ⚙️ (Valves)** in the UI.

| Valve | Default | What it does |
|---|---|---|
| `RUNPOD_API_KEY` | from `.env` | Starts and queries the pod. Never used to transmit prompts. |
| `RUNPOD_POD_ID` | from `.env` | Which pod to wake |
| `TAILSCALE_IP` | from `.env` | The pod's private address, discovered by `install.sh` |
| `VLLM_PORT` | `8000` | Port vLLM listens on |
| `MODEL_NAME` | `Qwen/Qwen2.5-Coder-32B-Instruct-AWQ` | **Must match `VLLM_MODEL` on the pod exactly** |
| `MODEL_DISPLAY_NAME` | `Qwen2.5-Coder-32B (RunPod)` | The label shown in the dropdown |
| `WARMUP_TIMEOUT` | `600` | Seconds to wait for the model before giving up |
| `POLL_INTERVAL` | `5.0` | Seconds between readiness checks |
| `REQUEST_TIMEOUT` | `900` | Read timeout for one response. Raise for very long generations |
| `MAX_TOKENS` | `4096` | Default response length cap |
| `EMIT_STATUS` | `true` | Show "waiting for model…" progress in the chat |
| `ENFORCE_MESH_ONLY` | `true` | **Security control — leave this on.** See below |

---

## `ENFORCE_MESH_ONLY` — why this exists

This is the single most important setting in the file.

Tailscale assigns every device an address in the range `100.64.0.0/10` (that is, `100.64.x.x` through `100.127.x.x`). Traffic between those addresses is encrypted with WireGuard and never touches the public internet.

If `TAILSCALE_IP` were ever wrong — a typo, a stale value after a pod was recreated, a pasted public address — your prompts would be sent **unencrypted to whatever is at that address**. The failure would be silent. Everything would appear to work.

With this valve enabled, the pipe checks the address before transmitting anything and refuses outright if it falls outside the mesh range. You get a clear error in the chat window instead of quietly leaking data.

Leave it on. The only legitimate reason to disable it is if you deliberately run vLLM somewhere other than a tailnet, in which case you have accepted that tradeoff knowingly.

A second, quieter control sits alongside it: the HTTP client is created with `trust_env=False`, which means any `HTTP_PROXY` or `HTTPS_PROXY` environment variable present in the container is ignored. A stray proxy setting cannot silently reroute your prompts.

---

## Understanding the code

A few patterns in this file are worth explaining if you have not met them before.

**Async generators.** The `pipe()` function is declared `async def` and uses `yield` rather than `return`. Instead of producing one result at the end, it produces a sequence of results over time. That is what creates the typewriter effect — each fragment of text is handed to the UI the moment it arrives.

**Server-Sent Events.** vLLM streams its reply as a series of lines, each looking like `data: {...json...}`, ending with the literal `data: [DONE]`. The loop near the bottom of `pipe()` strips the `data: ` prefix, parses the JSON, and extracts the new text from `choices[0].delta.content`.

**GraphQL.** RunPod's API uses GraphQL rather than conventional REST. The important quirk: errors can arrive with an HTTP 200 OK status, buried in an `errors` key in the response body. That is why `_graphql()` checks for that key explicitly rather than trusting the status code alone.

**`time.monotonic()`.** Used instead of `time.time()` for measuring elapsed time. It is a clock that only ever moves forward and cannot jump if the system clock is adjusted — the correct tool for "has 600 seconds passed yet".

**The warm cache.** After a successful readiness check, `_warm_until` suppresses further checks for 60 seconds. During an active back-and-forth conversation this avoids a pointless network round trip before every single message.

---

## Error messages and what they mean

Every error path produces a specific, actionable message rather than a stack trace. What you will see, and what to do:

| Message in chat | Cause | Fix |
|---|---|---|
| `RUNPOD_API_KEY is not set` | `.env` is missing the key | Re-run `./install.sh` on the Pi |
| `TAILSCALE_IP is empty` | The pod has never joined the tailnet | Start the pod once manually, then re-run `./install.sh` |
| `Refusing to transmit: ... outside the Tailscale mesh range` | The address is not `100.64–127.x.x` | Fix `TAILSCALE_IP`. **Do not** just disable the check |
| `Cannot reach the inference pod` | The tailnet route is down, or the ephemeral node was reaped | `tailscale status \| grep runpod-vllm` on the Pi; if absent, re-run `./install.sh` |
| `Pod warm-up timed out` | Model took longer than `WARMUP_TIMEOUT` | Check the pod's logs. A cold start with no persistent volume can exceed 10 minutes |
| `Stream timed out` | Generation exceeded `REQUEST_TIMEOUT`, or the pod stopped mid-reply | Raise `REQUEST_TIMEOUT` in the Valves |
| `RunPod control plane error` | API rejected the request | Usually an invalid key or a wrong pod ID |
| `HTTP 401 from RunPod` | Key is invalid or revoked | Generate a new one in the RunPod console |

---

## Adding a second cloud model

The `pipes()` method returns the list of models shown in the dropdown. To offer more than one, return additional entries and branch on the selected `model` field inside `pipe()`:

```python
def pipes(self):
    return [
        {"id": "vllm-coder", "name": "Qwen2.5-Coder-32B (RunPod)"},
        {"id": "vllm-general", "name": "Llama-3.3-70B (RunPod)"},
    ]
```

Each additional model needs either its own pod, or a pod running vLLM with multiple models loaded. Be aware the second option multiplies GPU memory requirements.

---

## A note on logging

Every status message and error in this file contains **metadata only** — timings, HTTP codes, pod state. None of them include message content.

If you extend this file, preserve that. A single `print(messages)` added while debugging, left in place, would write your entire conversation history into the container logs and quietly undo the privacy guarantees the rest of the system is built around.
