# openhands/ — natural-language code maintenance

A separate OpenHands service that maintains this project's code. Open WebUI stays the chat
and RAG interface; OpenHands gets a writable repository workspace and an isolated Docker
sandbox for editing and running commands.

| File | Purpose |
|---|---|
| `docker-compose.openhands.yml` | Compose overlay adding the service |
| `AGENTS.md` | Standing instructions the agent must read first |
| `prompts/` | Reusable task templates |
| `scripts/openhands-control.sh` | Start, stop, logs, status, workspace refresh |

---

## The workspace is a separate clone

**This is the most important thing on this page.** OpenHands does *not* work in the
deployment directory. It works in a dedicated clone, by default `~/hybrid-ai-agent`, created
and guarded by `scripts/setup-agent-workspace.sh`.

The reason is not tidiness. OpenHands mounts its workspace read-write and the sandbox runs as
your uid. If the workspace were the deployment directory, the sandbox could read:

- `.env` — your RunPod API key and Open WebUI session key
- `install.log`, `backup.log`

Mode 0600 would not help, because 0600 means "readable by your user" and the sandbox *is*
your user.

That matters because the sandbox is the component that processes **untrusted text** — log
files, diagnostic bundles, issue bodies, repository content. `AGENTS.md` tells the agent to
treat that text as data rather than instructions, but an instruction is a mitigation. A clone
is a boundary.

The secondary benefit is real too: the agent never edits files underneath a running stack.

```text
~/hybrid-ai            deployment. Has .env. Agent cannot see it.
~/hybrid-ai-agent      agent workspace. A clone. No credentials.
```

Your workflow: agent branches and commits in the workspace → you review the diff → you pull
into the deployment directory when satisfied.

`install.sh` sets this up. To do it by hand or verify it:

```bash
./scripts/setup-agent-workspace.sh
./scripts/setup-agent-workspace.sh --check
```

The script refuses to proceed if the workspace is, or is inside, the deployment directory,
and fails if a `.env` or log file is found in the clone.

---

## Access

Loopback only, by design. From your workstation:

```bash
ssh -L 3001:127.0.0.1:3001 <user>@<pi-tailnet-name-or-ip>
```

Then open `http://127.0.0.1:3001`.

There is no Caddy route and there must not be one. The controller mounts the Docker socket to
create sandbox containers, which is effectively host root. An IP allowlist is not a sufficient
control for a service that can execute arbitrary code as root.

---

## First-time setup

1. Run `./install.sh` — it creates the workspace clone and starts the service.
2. Open OpenHands through the SSH tunnel.
3. In **Settings → LLM**, choose a provider and model and enter the credential. It is stored
   in `~/.openhands`, outside the repo and outside the sandbox.
4. Start a conversation with: *"Read `/workspace/openhands/AGENTS.md` and follow it for all
   work in this repository."*
5. For a task, paste the relevant file from `prompts/` and add your specifics: `feature.md` for new behaviour, `fix-from-diagnostics.md` for working from a diagnostic bundle, `security-review.md` for a review pass.

---

## Always pass the overlay

```bash
docker compose -f docker-compose.yml \
               -f openhands/docker-compose.openhands.yml \
               --env-file .env <command>
```

The short form works for `logs` and `ps`, which is what makes the exception dangerous:
**`up -d --remove-orphans` without the overlay deletes the OpenHands container**, because
compose treats it as an orphan. `install.sh` uses `--remove-orphans` on every run.

`scripts/openhands-control.sh` always passes both files. Prefer it:

```bash
./openhands/scripts/openhands-control.sh status
./openhands/scripts/openhands-control.sh logs
./openhands/scripts/openhands-control.sh restart
./openhands/scripts/openhands-control.sh update
./openhands/scripts/openhands-control.sh workspace   # refresh the clone
```

State in `~/.openhands` survives container removal, so recovery is just `start` — but the
surprise is worth avoiding.

---

## Git workflow

```text
request → ai/* branch → tests → commit → you review → push → PR → you merge
```

The agent is instructed to stop after committing. Pushing and opening a PR need git
credentials in the sandbox; prefer a GitHub App or a fine-grained token scoped to this one
repository with Contents read/write and Pull requests read/write. Do not grant administration
or workflow permissions. Never enable automatic merge.

---

## Diagnostics workflow

Generate a bundle with `./collect-diagnostics.sh`, confirm the redaction looks right, copy it
into the agent workspace, and point the agent at it using `prompts/fix-from-diagnostics.md`.
Delete it when the branch is done.

Verify redaction before exposing a bundle to any cloud-hosted model.

---

## Security summary

| Control | Mechanism |
|---|---|
| No credential access | Workspace is a clone; `.env` is not in it |
| Not internet-reachable | Binds `127.0.0.1` only; no Caddy route |
| No automatic merge | Agent stops after commit; branch protection on `main` |
| Injection resistance | `AGENTS.md` classifies repo text and logs as untrusted data |
| Resource bounded | Memory and CPU limits so agent work cannot starve chat |
| Provider keys isolated | `~/.openhands`, mode 0700, outside repo and sandbox |

**Residual risk, stated plainly:** the controller has Docker socket access, which is
root-equivalent on this host. The workspace clone protects the *sandbox* — the part handling
untrusted input — but anything that compromises the controller itself already has the host.
Only trusted administrators should use this service, and every diff and test result deserves
review before you push it.
