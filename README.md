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
