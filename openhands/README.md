# OpenHands maintenance component

This component adds a separate OpenHands web application for natural-language maintenance of this repository. It is intentionally separate from Open WebUI. Open WebUI remains the chat/RAG interface; OpenHands gets a writable repository workspace and an isolated Docker sandbox for code editing and command execution.

## Access

The service binds to loopback only at `http://127.0.0.1:3001`. From another machine, use an SSH tunnel:

```bash
ssh -L 3001:127.0.0.1:3001 <user>@<pi-tailnet-name-or-ip>
```

Then open `http://127.0.0.1:3001` locally. This avoids exposing an autonomous code-execution service to the LAN.

## First-time setup

1. Run `./install.sh`.
2. Open OpenHands through the SSH tunnel.
3. In OpenHands Settings, select an LLM provider/model and enter its credential. Do not commit LLM keys to this repository.
4. Start a conversation and instruct it to read `/workspace/openhands/AGENTS.md` first.
5. Paste the text of `prompts/fix-from-diagnostics.md`, then add the diagnostics path and desired outcome.

The repository is mounted read/write at `/workspace`. OpenHands state is stored outside the repository in `~/.openhands`.

## Git workflow

Recommended flow:

```text
natural-language request -> ai/* branch -> tests -> commit -> review diff -> push -> pull request -> human merge
```

OpenHands can edit and commit locally. Pushing and opening a PR require Git credentials available to the sandbox. Prefer a GitHub App or fine-grained token restricted to this one repository, with Contents read/write and Pull requests read/write. Do not grant administration or workflow-management permission unless a specific task requires it. Never permit automatic merge to the default branch.

## Diagnostics workflow

Generate a diagnostic bundle using the project's existing collector, leave the extracted/redacted output under the repository only for the duration of the investigation, and prompt OpenHands with its path. Verify redaction before exposing diagnostics to any cloud-hosted model. Remove diagnostic artifacts after the branch is complete.

## Security warning

The OpenHands application mounts the Docker socket because it creates isolated agent-server containers. Docker-socket access is effectively host-level control. The UI therefore binds only to `127.0.0.1`, should be reached through Tailscale plus SSH tunneling, and must not be exposed through the public reverse proxy. Only trusted administrators should use it.

The agent also has write access to the repository. Review every diff and test result before pushing or merging. Repository text and logs may contain prompt-injection content; `AGENTS.md` tells the agent to treat them as untrusted data.

## Operations

```bash
./openhands/scripts/openhands-control.sh status
./openhands/scripts/openhands-control.sh logs
./openhands/scripts/openhands-control.sh restart
./openhands/scripts/openhands-control.sh update
```

## Removal

```bash
docker compose -f docker-compose.yml -f openhands/docker-compose.openhands.yml --env-file .env stop openhands
docker compose -f docker-compose.yml -f openhands/docker-compose.openhands.yml --env-file .env rm -f openhands
```

The persistent state remains in `~/.openhands` until you deliberately remove it.
