# `hermes/` — Hermes Agent system orchestrator

Hermes Agent is a persistent memory and skill orchestration engine. It sits alongside Open
WebUI, stores long-term user context and acquired skills in `hermes_data/`, and provides a
framework for custom tool skills. It runs as its own container, `hermes-agent`, and reaches
the OpenHands API by service name over a private network.

| File | Purpose |
|---|---|
| `docker-compose.hermes.yml` | Compose overlay adding the `hermes` service |
| `Dockerfile` | Builds the image: Hermes CLI plus the Hermes WebUI |

The service is defined only in the overlay. Compose must always run with all three files —
`docker-compose.yml`, `openhands/docker-compose.openhands.yml`,
`hermes/docker-compose.hermes.yml` — because a run that omits an overlay treats its service
as an orphan and `--remove-orphans` deletes it. `install.sh`, `doctor.sh` and
`openhands/scripts/openhands-control.sh` all pass the full set.

---

## Mounts

| Host path | Container path | Mode | Notes |
|---|---|---|---|
| `./hermes_data` | `/root/.hermes` | read-write | Persistent memory, SQLite state, FTS5 indexes and acquired skills. This is a subdirectory of the **deployment directory** — see the gaps below. |
| `./hermes_data/workspace` | `/root/workspace` | read-write | Persistent WebUI workspace; the same host folder the container also sees at `/root/.hermes/workspace`. |
| `${OPENHANDS_WORKSPACE}` | `/workspace` | **read-only** | The OpenHands clone. Read-only so Hermes can read code without editing it. |
| `${OPENHANDS_WORKSPACE}` | `/agent-repo` | **read-only** | The same clone again, under a name that makes its purpose explicit: the read-only view of the OpenHands working clone. Writes here fail inside the container. |
| `${AGENT_REPOS_DIR}` | `/agent-repos` | **read-only** | The agent repo reference tree: one read-only clone of every non-fork repo you own, each on its own default branch, built by `scripts/sync-agent-repos.sh`. Defaults to `${HOME}/hybrid-ai-repos` when unset. |

`${OPENHANDS_WORKSPACE}` is required. If it is unset, compose fails loudly with:

```
error while interpolating services.hermes.volumes... required variable OPENHANDS_WORKSPACE is missing a value: OPENHANDS_WORKSPACE must be set - run ./install.sh
```

The clone must never be the deployment directory. `scripts/setup-agent-workspace.sh` refuses
to create or use a workspace that is, or is inside, the deployment directory, so `.env` and
the log files stay out of reach of the read-only mount.

There is **no Docker socket** in this container. Hermes cannot start, stop, or inspect other
containers.

---

## The read-only agent repo reference tree (`/agent-repos`)

The OpenHands clone at `/workspace` and `/agent-repo` is a single repository, left on whatever
`ai/*` branch OpenHands last used. Hermes often needs a stable view of **all** your
repositories, each on its default branch, so a second, separate tree is mounted read-only at
`/agent-repos`.

`scripts/sync-agent-repos.sh` builds and maintains that tree under `AGENT_REPOS_DIR`
(default `${HOME}/hybrid-ai-repos`):

- It lists your repos through the public GitHub REST API
  (`GET /users/<owner>/repos?type=owner&per_page=100`) and keeps only non-fork repos owned by
  the account. **Forks are never copied.** No token is sent.
- Private repos the unauthenticated API cannot see are named in an optional local manifest,
  `agent-repos.local` (gitignored). Each line is `OWNER/NAME` to include, or `-OWNER/NAME` to
  exclude; `#` comments and blank lines are ignored.
- Missing repos are cloned on their default branch (`--single-branch`, no tags, no submodules,
  git hooks disabled, LFS smudge skipped). Existing repos fast-forward only; a dirty tree is
  skipped with a warning, never hard-reset.
- It is idempotent, reads no credentials, and writes only under `AGENT_REPOS_DIR`.
- It **refuses** a target that is, is inside, or contains the deployment directory or
  `OPENHANDS_WORKSPACE`, so mounting it read-only cannot expose `.env` or the logs.

`install.sh` runs it on every deploy, after the workspace setup, and its failure is a warning
(not a stop). To refresh on a schedule, install a timer **by hand**. A daily systemd timer:

```ini
# ~/.config/systemd/user/sync-agent-repos.service
[Unit]
Description=Sync the Hermes agent repo reference tree

[Service]
Type=oneshot
WorkingDirectory=%h/hybrid-ai
ExecStart=%h/hybrid-ai/scripts/sync-agent-repos.sh
```

```ini
# ~/.config/systemd/user/sync-agent-repos.timer
[Unit]
Description=Daily sync of the Hermes agent repo reference tree

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
```

Enable it with `systemctl --user enable --now sync-agent-repos.timer` and, to run it with the
user logged out, `sudo loginctl enable-linger "$USER"`. Or a crontab line:

```cron
17 4 * * * cd "$HOME/hybrid-ai" && ./scripts/sync-agent-repos.sh >> install.log 2>&1
```

---

## Networks

| Network | Defined in | Members | Why |
|---|---|---|---|
| `hybrid-ai` (the compose default) | `docker-compose.yml` | every service | Normal service-to-service traffic. |
| `coder-net` (`internal: true`) | `docker-compose.yml` | `hermes` and `openhands` only | Hermes reaches the OpenHands API at `http://openhands:3000` by service name. |

`coder-net` is `internal: true`: Docker gives it no route off the host. A container on it can
reach the other members, and nothing else — no LAN, no internet, no published host ports. It
adds no host port binds. `doctor.sh` checks that `coder-net` is internal and that it carries
exactly `hermes-agent` and `hybrid-ai-openhands`.

---

## Ports

| Variable | Default | Container port | Host bind | Reached by |
|---|---|---|---|---|
| `HERMES_PORT` | `8501` | `8501` | `8501` on **all interfaces** | browser, LAN + tailnet |
| `HERMES_API_PORT` | `8642` | `8642` | `8642` on **all interfaces** | browser, LAN + tailnet |

The container listens on `0.0.0.0` (`--host 0.0.0.0`), and the host binds are published on
every interface. See the gaps below.

---

## Processes

| Process | Role | Started by |
|---|---|---|
| WebUI (`bootstrap.py`) | The container main process, PID 1: serves the Hermes WebUI. | The compose `command:` |
| Hermes gateway / kanban dispatcher | A background process in the same container: drains the kanban queue. | The compose `command:` |

Both are started by the compose `command:`, not by the Dockerfile `CMD`. The compose
`command:` supersedes the image `CMD`, so what runs is the `command:` in
`docker-compose.hermes.yml`: it starts the gateway in the background, then `exec`s
`bootstrap.py` as PID 1.

The gateway runs as the **default** profile, pinned with `-p default`
(`hermes -p default gateway run --replace`). This is load-bearing: a sticky named
active profile stored in the bind-mounted `hermes_data/` (mounted at
`/root/.hermes/active_profile`) would otherwise capture a bare `hermes gateway run`
and be refused with `Profile '<name>' does not get a gateway of its own`. There is
only one gateway per host, and it is owned by the default profile. Pinning
`-p default` in the `command:` makes the gateway start after every container
create/recreate regardless of the sticky active profile.

Check the gateway with `./doctor.sh`, or by hand with a read-only probe:

```bash
docker top hermes-agent        # look for a "gateway run" process
```

A crashed gateway is **not** restarted until the container restarts. Nothing supervises the
background job, so a gateway that exits stays down while the WebUI keeps serving. Recreate the
container to bring it back.

The `--replace` flag keeps it to one gateway run instance across container restarts.

---

## Environment variables

Referenced by name only; values live in `.env`, which is gitignored.

| Name | Read by | Purpose |
|---|---|---|
| `OPENHANDS_WORKSPACE` | `docker-compose.hermes.yml` | Host path mounted at `/workspace` and `/agent-repo`. Required. |
| `AGENT_REPOS_DIR` | `docker-compose.hermes.yml`, `scripts/sync-agent-repos.sh` | Host path of the agent repo reference tree, mounted at `/agent-repos` read-only. Defaults to `${HOME}/hybrid-ai-repos` when unset. |
| `AGENT_REPOS_OWNER` | `scripts/sync-agent-repos.sh` | Account whose owned, non-fork repos are inventoried. Blank means: derive it from the owner in this clone's git origin URL. |
| `AGENT_REPOS_MANIFEST` | `scripts/sync-agent-repos.sh` | Optional local manifest of private repos. Blank means `./agent-repos.local`. |
| `HERMES_PORT` | `docker-compose.hermes.yml` | Host port for the WebUI. |
| `HERMES_API_PORT` | `docker-compose.hermes.yml` | Host port for the API. |
| `OPENROUTER_API_KEY` | container env, and each profile's own `.env` | Model provider for agent work. Each board-running profile (default, builder, reviewer) also needs `OPENROUTER_API_KEY` in its own profile `.env` under `hermes_data/` (e.g. `hermes_data/.env`, `hermes_data/profiles/builder/.env`, `hermes_data/profiles/reviewer/.env`); a profile without it stalls its board. |
| `LOCAL_DOMAIN` | container env | Used for local subdomain routing. |
| `HERMES_DATA_DIR` | `.env.example` only | Documented as the memory directory, but the overlay currently hardcodes `./hermes_data`. |

---

## Credentials: `BUILDER_GITHUB_TOKEN`

`BUILDER_GITHUB_TOKEN` is the GitHub credential the builder uses to push `ai/*` branches and
open pull requests. It is supplied to the builder/Hermes agent by name through the builder
agent environment only. It is not read from the deployment `.env` and not set by
`docker-compose.hermes.yml`. Its value is never placed in the deployment `.env`, in
`.env.example`, in the OpenHands sandbox, on the command line (argv), in a URL, in a commit, or
in any tracked file. It is separate from the read-only OpenHands token (see
[`../SECURITY.md`](../SECURITY.md#github-credential-separation)).

Create it as a fine-grained personal access token with:

- **Repository access:** Only select repositories.
- **Contents:** Read and write.
- **Pull requests:** Read and write.
- **Metadata:** Read-only.
- **Not granted:** no Administration, no Workflows, no organization scope.

Because the token has no Workflows permission, a push that edits anything under
`.github/workflows/` is rejected by GitHub. This is by design: workflow changes must be made
by a human with the right access.

---

## Reaching OpenHands from Hermes

Over `coder-net`, from inside the `hermes-agent` container, the OpenHands API answers at:

```
http://openhands:3000
```

**Can a job be created and followed to completion with only that URL?**

This is a documentation-based finding; no containers were recreated in this change (see the
validation note below). Read from the architecture:

- **Creating a job** against the OpenHands API over `http://openhands:3000` is expected to
  work: it is a REST call to the app server, which is the member of `coder-net`.
- **Following a job to completion** is expected to require the **sandbox agent-server**
  directly. OpenHands V1 starts one sandbox container per conversation and the client streams
  events from that sandbox, not through the app server. The endpoint is the per-conversation
  published port:

  ```
  http://${OPENHANDS_SANDBOX_HOST}:<sandbox_host_port>
  ```

  From inside a container the same sandbox is reached as
  `http://host.docker.internal:<sandbox_host_port>`. That port is published on the host by the
  sandbox, not offered on `coder-net`.

Per the scope of this change, no route, bind, or network was added to make the sandbox
reachable from Hermes. The endpoint is named above and the investigation stops here. Any
change to make the sandbox reachable belongs to the later phase that narrows the sandbox
ports.

---

## Pre-existing gaps (flagged, not fixed here)

These are existing properties of the service, recorded so they are not mistaken for
something this change introduced. They are addressed in a later phase.

| Gap | Detail | Why it is not fixed here |
|---|---|---|
| Hermes ports bind all interfaces | `8501` and `8642` are published on `0.0.0.0`, so anyone on the LAN or tailnet can reach them. | Narrowing the binds is out of scope; this change adds no binds and does not widen any. |
| Hermes mounts the deployment directory read-write | `./hermes_data` is a subdirectory of the deployment directory, mounted read-write at `/root/.hermes`. | The memory store must be writable; relocating it is a later phase. |
| Hermes runs as root | `hermes/Dockerfile` has no `USER` directive. This is a tracked `TODO(security)` in the Dockerfile and in `SECURITY.md`. | A non-root user is a separate change. |
| OpenHands sandbox ports publish on all interfaces | Sandboxes created by OpenHands publish their agent-server port on the host. Adjacent to this service, not part of it. | Later phase. |

---

## Validation note

The checks in this change ran without recreating containers (Docker was not running in the
build sandbox and no `.env` exists there). The compose configuration was validated by parsing
it, and `doctor.sh` was syntax-checked. The post-recreate checks — `docker network inspect
coder-net` showing exactly two members, a write test against `/agent-repo` failing, a request
from Hermes to `http://openhands:3000` succeeding, and `./doctor.sh` green — were **not**
run here; run them on the Pi after `./install.sh`.

---

## Related documentation

- [`../openhands/README.md`](../openhands/README.md) — the OpenHands service, its workspace
  clone, and the shared `coder-net` network.
- [`../SECURITY.md`](../SECURITY.md) — the `172.17.0.1` webhook exception and the read-only
  mount.
- [`../README.md`](../README.md) — architecture, networks and ports.
