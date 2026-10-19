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

The script refuses to proceed if the workspace is, is inside, or contains any protected tree
— `HYBRID_AI_APP_DIR`, `HYBRID_AI_DATA_DIR`, `HYBRID_AI_LOG_DIR`, `HYBRID_AI_WORK_DIR`, the
directory the env file lives in, the directory the STACK env file
(`HYBRID_AI_STACK_ENV_FILE`) lives in, or `BACKUP_CONF_DIR` — and fails if an env file or log
file is found in the clone. On a bootstrapped host the layout file
(`/etc/hybrid-ai/hybrid-ai.env`) and the stack file (`/etc/hybrid-ai/stack.env`) are two
different files, and BOTH of their directories are guarded. A bare invocation that does not
name the layout file still finds it: when `HYBRID_AI_ENV_FILE` is unset and
`$HYBRID_AI_APP_DIR/.env` is absent, the helper falls back to
`HYBRID_AI_ENV_FILE_FALLBACK` (default `/etc/hybrid-ai/hybrid-ai.env`) when it exists.

On a bootstrapped host the workspace and the repo tree are SIBLINGS of the data dir, never
children of it: `scripts/bootstrap.sh` renders `OPENHANDS_WORKSPACE=/var/lib/hybrid-ai-agent`
and `AGENT_REPOS_DIR=/var/lib/hybrid-ai-repos`, both owned by the `hybrid-ai` account. This
keeps them outside `HYBRID_AI_DATA_DIR` (`/var/lib/hybrid-ai`), which the guards above refuse.
A re-run against a tree an earlier, wrong bootstrap left under `/var/lib/hybrid-ai/agent-*`
moves that child up to its sibling with a same-device rename; if both copies hold data it
refuses with exit `6` before any move.

On every run it also refreshes the existing clone, so the workspace-root copy of
`openhands/AGENTS.md` stays current without a manual pull. The refresh fetches, then
fast-forwards only when the clone is clean and on its default branch. If the tree is dirty, on
another branch, or the fetch fails, it warns and skips rather than resetting or discarding
work. A failed fetch is a warning, so `install.sh` continues.

### Multi-repo jobs: `project/<repo-name>`

The workspace root is a hybrid-ai clone. It holds these instructions, and it is not the target
of a job unless the task says so. When a job names a repository, OpenHands clones that
repository into `project/<repo-name>` inside the workspace
(`${OPENHANDS_WORKSPACE}/project/<repo-name>`). The agent works only in that clone, so a job on
another owned repository never edits the hybrid-ai clone at the root.

```text
~/hybrid-ai-agent                    workspace root. A hybrid-ai clone with AGENTS.md.
~/hybrid-ai-agent/project/<repo>     the job's own clone. This is where work happens.
```

Owned repositories do not all use `main`, so `AGENTS.md` tells the agent to fetch and read the
remote default branch (`git symbolic-ref --short refs/remotes/origin/HEAD`) before branching,
and to branch from `origin/<default>` rather than a local `main` or `master`.

---

## The clone is also visible to Hermes, read-only

Hermes reads the same clone at `/agent-repo`, mounted read-only
(`${OPENHANDS_WORKSPACE}:/agent-repo:ro`). It is never the deployment directory — the same
script above refuses that — and `:ro` means Hermes can read the code OpenHands is working on
but cannot modify it. Writes to `/agent-repo` fail inside the Hermes container.

Hermes also mounts a second, separate tree read-only at `/agent-repos`
(`${AGENT_REPOS_DIR}:/agent-repos:ro`, default `${HOME}/hybrid-ai-repos`). That tree holds one
read-only clone of every non-fork repository you own, each on its own default branch, and is
built by `scripts/sync-agent-repos.sh`. It is separate from this working clone so Hermes can
read all your code — including agent-context markdown files once they exist — regardless of
which `ai/*` branch OpenHands last left checked out here. See
[`../hermes/README.md`](../hermes/README.md#the-read-only-agent-repo-reference-tree-agent-repos).

OpenHands and Hermes share one dedicated Docker network, `coder-net`, defined in
`docker-compose.yml` with `internal: true`. It has exactly two members — `openhands` and
`hermes` — and no route off the host: no LAN, no internet, no published ports. Hermes uses it
to reach the OpenHands API at `http://openhands:3000` by service name.

This adds no host port bindings. OpenHands keeps its existing `127.0.0.1` bind for the UI and
its `172.17.0.1` bind for sandbox webhooks, both unchanged (see the note in
"Security summary" below).

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
   in `${OPENHANDS_STATE_DIR}` (default `~/.openhands`), outside the repo and outside the sandbox.
4. Start a conversation with: *"Read `/workspace/openhands/AGENTS.md` and follow it."* The
   file tells the agent to work in the job's own clone under `project/<repo-name>`, so the
   same instruction works for a job on any owned repository, not just hybrid-ai.
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

`scripts/openhands-control.sh` always passes both files, the resolved `--env-file`, and
`--project-directory "$HYBRID_AI_APP_DIR"`. Prefer it:

```bash
./openhands/scripts/openhands-control.sh status
./openhands/scripts/openhands-control.sh logs
./openhands/scripts/openhands-control.sh restart
./openhands/scripts/openhands-control.sh update
./openhands/scripts/openhands-control.sh workspace   # refresh the clone
```

State in `${OPENHANDS_STATE_DIR}` (default `~/.openhands`) survives container removal, so recovery is just `start` — but the
surprise is worth avoiding.

---

## Sandbox image repository and tag

The sandbox runs the agent-server image named by two settings in `.env`:
`OPENHANDS_AGENT_IMAGE_REPOSITORY` and `OPENHANDS_AGENT_IMAGE_TAG`. The overlay passes
them to the app server as `AGENT_SERVER_IMAGE_REPOSITORY` and `AGENT_SERVER_IMAGE_TAG`.

The repository value matters because the app server reserves the canonical string
`ghcr.io/openhands/agent-server` for the SDK version bundled inside the app-server
image. When that exact string is set, the app server silently rewrites the tag to its
bundled SDK version and logs a warning. A newer tag such as `1.37.1-python` is then
ignored, so the sandbox keeps running the old SDK. No app-server release bundles an SDK
at or above 1.37, so pinning a newer tag on the canonical repository can never take
effect.

The default here is now the derived hybrid image,
`ghcr.io/jimbobsyouruncle/openhands-agent-server-hybrid:1.37.1-python-hybrid.2` (see
[Derived sandbox image](#derived-sandbox-image-shellcheck-and-other-tooling) below).
Neither that name nor the CDN alias `docker.openhands.dev/openhands/agent-server` is
the canonical string, so the app server honours `AGENT_SERVER_IMAGE_TAG`. That is what
makes the `1.37.1-python-hybrid.2` pin work.

If you set your own repository or tag, `install.sh` leaves both untouched. It migrates
only the exact stale values on upgrade, and the stock default pair together (see the
cut-over notes below).

---

## Derived sandbox image (shellcheck and other tooling)

The deployed base image does not ship `shellcheck`, so the repository's own
ShellCheck gate (`sast-checks.yml`, the `ludeeus/action-shellcheck` job) cannot run
inside a sandbox. An agent handed a ShellCheck failure therefore cannot reproduce or
fix it locally. The derived image closes that gap. It adds, on top of
`docker.openhands.dev/openhands/agent-server:1.37.1-python`:

| Package | Why |
|---|---|
| `shellcheck` | Reproduce the repo's CI ShellCheck gate inside the sandbox |
| `sqlite3` | Inspect the Open WebUI SQLite database |
| `rsync` | Move files in and out of the agent workspace |
| `restic` | Verify and read the backup repository |

`jq` is already in the base image, so it is not reinstalled.

`shellcheck` is **not** the apt package. The CI gate (`ludeeus/action-shellcheck`
2.0.0, track `stable`) runs ShellCheck **0.11.0**, while apt still ships 0.10.0. The
Dockerfile therefore installs the pinned upstream **0.11.0** static `linux/arm64`
binary to `/usr/local/bin/shellcheck`, verifying its sha256 before install so a
mismatch fails the build. PATH must resolve 0.11.0 to match the gate; fix a future
divergence by raising the image to the gate's version, never by weakening the gate.
`curl` and `xz-utils` are pulled in as the fetch and extract dependencies for that
download and are otherwise benign.

The Dockerfile is `openhands/agent-server/Dockerfile`. It installs the packages and
the pinned binary as root in one layer, then ends with `USER openhands`; it sets no
`ENTRYPOINT` and no `CMD`, so the base image's
`tini -- /usr/local/bin/openhands-agent-server` is inherited unchanged and the sandbox
still runs as the unprivileged `openhands` account.

**This image is now the deployed default.** The cut-over has landed:

- `install.sh` (STEP 8 `.env` template and the `docker pull` fallback),
  `.env.example`, and `openhands/docker-compose.openhands.yml` all default
  `OPENHANDS_AGENT_IMAGE_REPOSITORY` to
  `ghcr.io/jimbobsyouruncle/openhands-agent-server-hybrid` and
  `OPENHANDS_AGENT_IMAGE_TAG` to `1.37.1-python-hybrid.2`.
- A previously deployed host has the OLD default pair written verbatim in `.env`
  (`docker.openhands.dev/openhands/agent-server` AND `1.37.1-python`). Since
  STEP 8 rewrites `.env` as `${VAR:-default}`, those explicit values would
  survive every deploy, so STEP 2b unsets them. The migration is **pair-exact**:
  it unsets BOTH variables only when BOTH load as the old pair. If the owner
  customised EITHER half, both are preserved and the pin is logged as left
  alone — two independent unsets keyed off the value alone would silently reset
  a custom tag to the new default.
- A host that already cut over carries the first hybrid tag verbatim
  (`ghcr.io/jimbobsyouruncle/openhands-agent-server-hybrid` AND
  `1.37.1-python-hybrid.1`). STEP 2b unsets that pair too, so STEP 8 writes the
  current hybrid.2 default, which raises the image's ShellCheck to 0.11.0. That
  branch is pair-exact as well, so a customised repository or tag stays put.
- The new repository is **not** an OpenHands-canonical name (only
  `ghcr.io/openhands/agent-server` is), so the app server does not re-pin the
  tag and `1.37.1-python-hybrid.2` should be honoured. That is pending the
  post-merge live check.
- **Rollback:** reverting the merge does NOT revert a deployed host's `.env` —
  the migration already rewrote it. A rollback must re-set the old pin in `.env`
  (or unset both variables) and re-run `install.sh`.

Build and publish it by hand: **Actions → "sandbox-image" → Run workflow**, and set
the `image_tag` input (default `1.37.1-python-hybrid.2`). The workflow is
`workflow_dispatch` only — nothing publishes on a push, a merge or a schedule. It
builds `linux/arm64` only and pushes to:

```text
ghcr.io/jimbobsyouruncle/openhands-agent-server-hybrid:<tag>
```

**Publishing now feeds the running system.** The cut-over above makes this image
the deployment default, so a newly published tag only changes what runs once the
`.env` pin (or the default) points at it.

---

## Git workflow

```text
request -> ai/* branch -> commit (OpenHands) -> independent review -> builder pushes + opens PR -> merge
```

The agent is instructed to stop after committing. OpenHands never pushes and never opens a
PR; the builder does that after an independent review (see
[`../SECURITY.md`](../SECURITY.md#github-credential-separation)). Never enable automatic merge.

The OpenHands token is read-only. Use a fine-grained personal access token with:

- **Repository access:** Only select repositories (this project only).
- **Contents:** Read-only.
- **Metadata:** Read-only.

This is enough to clone and fetch. Do not grant Pull requests, Administration, or Workflows
permissions. The write capability (push and PR) belongs to the builder token, which stays out
of the sandbox.

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
| Not internet-reachable | Binds `127.0.0.1` (UI) and `172.17.0.1` (sandbox webhooks) only; no Caddy route |
| Sandboxes can reach the API without a public port | `172.17.0.1:${OPENHANDS_PORT:-3001}` bind, reachable from the Docker bridge only, never the LAN |
| Hermes reads the clone without being able to change it | `${OPENHANDS_WORKSPACE}:/agent-repo:ro`, and the separate `${AGENT_REPOS_DIR}:/agent-repos:ro` tree |
| Hermes-only API path, no host port | internal `coder-net`, members `openhands` and `hermes` |
| No automatic merge | Agent stops after commit; branch protection on `main` |
| Injection resistance | `AGENTS.md` classifies repo text and logs as untrusted data |
| Resource bounded | Memory and CPU limits so agent work cannot starve chat |
| Provider keys isolated | `${OPENHANDS_STATE_DIR}` (default `~/.openhands`), mode 0700, outside repo and sandbox |

**Residual risk, stated plainly:** the controller has Docker socket access, which is
root-equivalent on this host. The workspace clone protects the *sandbox* — the part handling
untrusted input — but anything that compromises the controller itself already has the host.
Only trusted administrators should use this service, and every diff and test result deserves
review before you push it.
