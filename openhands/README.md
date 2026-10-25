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

## Conversation directories and the quarantine

The workspace is bind-mounted read-write into the sandbox as `/workspace`, so the
agent's conversations live on the host at:

```text
${OPENHANDS_WORKSPACE}/conversations/<conversation-id>/     one directory per conversation
${OPENHANDS_WORKSPACE}/conversations/<conversation-id>/owner_lease.json
```

`owner_lease.json` is the lease that says whether a conversation is still owned by
a running process. Fields observed on a live host: `owner_instance_id`,
`generation`, `expires_at`, `owner_host`, `owner_pid`. `expires_at` carries the
deadline; the sweep reads it as epoch seconds (a value above 1e12 is read as
milliseconds) or as an ISO-8601 string, and an ISO-8601 value without a zone is
read as UTC.

These directories are **invisible to the OpenHands conversation API**: a live host
reported 0 conversations while 29 directories, about 8.3 GB, sat on disk. The app
forgets a conversation long before its directory leaves the workspace, so an
API-driven cleanup cannot see them. `scripts/prune-conversations.sh` therefore
walks the directory tree.

The sweep QUARANTINES, it never deletes. A stale directory is moved to:

```text
<dirname of HYBRID_AI_DATA_DIR>/hybrid-ai-conversation-quarantine/<YYYYMMDD>/<conversation-id>/
```

That root is on the same filesystem as the conversations tree, is created mode
0750 and root-owned, and is asserted to sit outside every tree the backup captures
(`HYBRID_AI_DATA_DIR`, `HYBRID_AI_APP_DIR`, `HYBRID_AI_WORK_DIR`,
`HYBRID_AI_HERMES_DATA_DIR`, `HYBRID_AI_WEBUI_DATA_DIR`, `OPENHANDS_WORKSPACE`).
If it does not, the sweep refuses to move anything. `HYBRID_AI_PRUNE_QUARANTINE_BASE`
overrides the root and is still subject to the same assertion.

Moving a directory back into `conversations/` restores it, because nothing was
deleted. Permission to move it is checked before the move: a symlinked or
non-plain-token directory name is refused and never followed, a directory whose
lease is missing, unreadable or unrecognised is refused and never moved — reported
as a refusal, not as kept-live, so an unreadable lease fails closed — and a
directory reached by a running container is skipped. The schedule, the knobs and
the inspection steps are in
[`../docs/TROUBLESHOOTING.md`](../docs/TROUBLESHOOTING.md#the-disk-keeps-filling-with-conversation-directories).

---

## Sandbox git ownership and `/etc/gitconfig`

Git inside the sandbox needs a nudge, and this is why.

The sandbox runs as the image's unprivileged uid (10001). The bind-mounted workspace is owned
by the host account, so the two uids differ. Git compares uids, not permissions, so it refuses
the mount and exits 128 with:

```
fatal: detected dubious ownership in repository at '/workspace/project/...'
```

`sudo git` does not help: git compares the process uid, so root does not bypass the check.
The `SANDBOX_USER_ID` line in the overlay is inert — app-server 1.10.0 and agent-server 1.37.1
never read it.

The fix is a system git config, `openhands/sandbox-gitconfig`, mounted read-only at
`/etc/gitconfig` in every new sandbox. It lists only the two workspace roots:

```ini
[safe]
	directory = /workspace
	directory = /workspace/project/*
```

The blanket `safe.directory = '*'` is deliberately not used: it would mark every repository on
the system trusted, including any untrusted clone. Wildcard matching needs git 2.47 or newer;
the image ships 2.47.3. `install.sh` copies the file into the workspace so the mount source
exists before Docker starts a sandbox.

Verify in a fresh sandbox:

```bash
docker exec <sandbox> git -C /workspace/project/hybrid-ai remote -v   # exits 0
docker exec <sandbox> git -C /workspace/project/hybrid-ai merge-base origin/main HEAD
```

An existing sandbox keeps the mounts it was created with. After changing anything here, re-run
`./install.sh` and start a new conversation.

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
`ghcr.io/jimbobsyouruncle/openhands-agent-server-hybrid:1.37.1-python-hybrid.3` (see
[Derived sandbox image](#derived-sandbox-image-shellcheck-and-other-tooling) below).
Neither that name nor the CDN alias `docker.openhands.dev/openhands/agent-server` is
the canonical string, so the app server honours `AGENT_SERVER_IMAGE_TAG`. That is what
makes the `1.37.1-python-hybrid.3` pin work.

If you set your own repository or tag, `install.sh` leaves both untouched. It migrates
only the exact stale values on upgrade, and the stock default pair together (see the
cut-over notes below).

---

## Derived sandbox image (shellcheck, semgrep and other tooling)

The deployed base image does not ship `shellcheck` or `semgrep`, so the repository's
own ShellCheck and Semgrep (SAST) gates (`sast-checks.yml`) cannot run inside a
sandbox. An agent handed a failure therefore cannot reproduce or fix it locally. The
derived image closes that gap. It adds, on top of
`docker.openhands.dev/openhands/agent-server:1.37.1-python`:

| Package | Why |
|---|---|
| `shellcheck` | Reproduce the repo's CI ShellCheck gate inside the sandbox |
| `semgrep` | Reproduce the repo's CI Semgrep (SAST) gate inside the sandbox |
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

`semgrep` is the pinned **1.179.0** aarch64 wheel installed with the base image's
`python3 -m pip`, matching the gate's `semgrep/semgrep:1.179.0` image. Its sha256 is
verified before install and the build asserts `semgrep --version` reports `1.179.0`,
so a wrong wheel or version fails closed. Rule-drift residual: the gate's
`--config auto` fetches rules remotely from the Semgrep registry and those rules are
**not** version-pinned to the binary, so a green local scan cannot guarantee a green
gate. Locally, `--config auto` also needs metrics/egress; semgrep refuses to run it
with `SEMGREP_SEND_METRICS=off`. CI remains the authority.

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
  `OPENHANDS_AGENT_IMAGE_TAG` to `1.37.1-python-hybrid.3`.
- A previously deployed host has the OLD default pair written verbatim in `.env`
  (`docker.openhands.dev/openhands/agent-server` AND `1.37.1-python`). Since
  STEP 8 rewrites `.env` as `${VAR:-default}`, those explicit values would
  survive every deploy, so STEP 2b unsets them. The migration is **pair-exact**:
  it unsets BOTH variables only when BOTH load as the old pair. If the owner
  customised EITHER half, both are preserved and the pin is logged as left
  alone — two independent unsets keyed off the value alone would silently reset
  a custom tag to the new default.
- A host that already cut over carries an earlier hybrid tag verbatim
  (`ghcr.io/jimbobsyouruncle/openhands-agent-server-hybrid` AND
  `1.37.1-python-hybrid.1` or `1.37.1-python-hybrid.2`). STEP 2b unsets each
  pair too, so STEP 8 writes the current hybrid.3 default. The hybrid.2 build
  raised the image's ShellCheck to 0.11.0; hybrid.3 adds Semgrep 1.179.0 to
  match the SAST gate. Those branches are pair-exact as well, so a customised
  repository or tag stays put.
- The new repository is **not** an OpenHands-canonical name (only
  `ghcr.io/openhands/agent-server` is), so the app server does not re-pin the
  tag and `1.37.1-python-hybrid.3` should be honoured. That is pending the
  post-merge live check.
- **Rollback:** reverting the merge does NOT revert a deployed host's `.env` —
  the migration already rewrote it. A rollback must re-set the old pin in `.env`
  (or unset both variables) and re-run `install.sh`.

**`./doctor.sh` now detects drift.** A live sandbox was seen running the stock
`docker.openhands.dev/openhands/agent-server:1.33.0-python` (no shellcheck, no
semgrep) even though the stack had defaulted to the hybrid pin since
2026-10-19. Two different faults look identical from the UI, so the
"OpenHands sandbox" section grew a warn-only probe. It resolves the expected
pin from `OPENHANDS_AGENT_IMAGE_REPOSITORY` / `OPENHANDS_AGENT_IMAGE_TAG`
(same defaults as `install.sh`, so the two cannot disagree), then:

1. reads `AGENT_SERVER_IMAGE_REPOSITORY` and `AGENT_SERVER_IMAGE_TAG` from the
   `hybrid-ai-openhands` container and compares the pair with the pin;
2. reads every live `oh-agent-server-*` container's real image with
   `docker inspect -f '{{.Config.Image}}'` and compares it with
   `repository:tag`.

The two warn branches mean different things:

- **`OpenHands app-server does not carry the pinned sandbox image env`** — the
  env never reached the app-server. The host `.env` carries explicit
  `OPENHANDS_AGENT_IMAGE_*` values, which `${VAR:-default}` in `install.sh`
  preserves on every deploy.
- **`<sandbox> runs image <stock>, not the pinned <pin>`** — a sandbox keeps
  the config it was created with, so an env fix never reaches a running one.
  If a **fresh** sandbox is still stock while the app-server carries the
  hybrid pair, then the app-server build does not honour the override. That is
  a finding to report and investigate upstream at the deployed app-server tag
  (or answer with a pin bump) — not something to patch around in this stack.

The probe is warning-only: it calls `warn`/`pass` and a skip note, never
`fail()`, so it can never turn a deploy red. Docker absent, `docker inspect`
failing, or `hybrid-ai-openhands` missing each print a skip note and leave the
exit code untouched.

**Post-merge decision tree:**

| What doctor reports | Meaning | What to do |
|---|---|---|
| app env ≠ hybrid pair | host `.env` carries explicit `OPENHANDS_AGENT_IMAGE_*` | unset them by name, re-run `./install.sh`, start a fresh sandbox |
| app env = hybrid pair, but a fresh sandbox is stock | the app-server build ignores the override | investigate upstream at the deployed app-server tag, or bump the pin |
| app env and every sandbox are hybrid | the earlier stock observation was a stale pre-cutover sandbox | remove stale sandboxes and re-check |

`scripts/test-doctor-sandbox-image.sh` proves all of this offline against a
fixture-driven docker stub, without a daemon or network.

**Publishing is automatic on a merge to `main`.** A push to `main` that changes
`openhands/agent-server/Dockerfile` builds and pushes the image with no human in
the loop. The tag is not supplied by hand: it is read from the `default:` of the
`image_tag` input in `.github/workflows/sandbox-image.yml`, so the same merge that
edits the Dockerfile **must** bump that default. A push-triggered run whose
resolved tag already exists on GHCR fails before building (tag immutability guard)
and names the required bump, so a forgotten bump cannot silently overwrite a
published tag. A concurrency group serialises builds (`cancel-in-progress: false`).

**Manual rebuild:** **Actions → "sandbox-image" → Run workflow**, and set the
`image_tag` input (default `1.37.1-python-hybrid.3`). This path is an explicit
owner action, so it deliberately skips the immutability guard and may re-push a
tag. The workflow builds `linux/arm64` only and pushes to:

```text
ghcr.io/jimbobsyouruncle/openhands-agent-server-hybrid:<tag>
```

**The deploy waits on this image.** Before the deploy workflow triggers the
remote install it runs `scripts/deploy-image-gate.sh`, which polls GHCR until the
pinned tag's manifest exists (fail closed). That closes the race in which a
deploy started `install.sh` before the image was published — the race behind the
"OpenHands workspace ACLs not applied" warning.

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

- **Repository access:** Only select repositories: `hybrid-ai`, `shared-actions`, `runpod-hybrid-worker`.
- **Contents:** Read-only.
- **Metadata:** Read-only.

This is enough to clone and fetch. Do not grant Pull requests, Administration, or Workflows
permissions. The write capability (push and PR) belongs to the builder token, which stays out
of the sandbox.

The app-server used to clone with `https://<token>@github.com/...`, and git stored that URL
verbatim in `project/<repo>/.git/config`, leaving the token on disk in plain text. The pinned
agent-server (the pin that stops this is >= 1.37.0; this repo pins `1.37.1-python-hybrid.3`) no
longer writes the token into the clone URL. Detection remains the control: `./doctor.sh` runs
`scripts/check-git-remotes.sh` over the agent-clone roots and reports any `remote.*.url`,
`remote.*.pushurl`, `url.<base>.insteadOf` or `url.<base>.pushInsteadOf` that embeds a
credential, naming only the path and the config key, never the URL or the token. A finding now
FAILS the deploy (doctor exit 2 -> deploy step exit 4). The pin stops the write, detection stays
the control, and a credential still on disk is a defect.

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
