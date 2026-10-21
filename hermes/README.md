# `hermes/` — Hermes Agent system orchestrator

Hermes Agent is a persistent memory and skill orchestration engine. It sits alongside Open
WebUI, stores long-term user context and acquired skills in `hermes_data/`, and provides a
framework for custom tool skills. It runs as its own container, `hermes-agent`, and reaches
the OpenHands API by service name over a private network.

| File | Purpose |
|---|---|
| `docker-compose.hermes.yml` | Compose overlay adding the `hermes` service |
| `Dockerfile` | Builds the image: a pinned Hermes Agent install plus the Hermes WebUI |
| `patches/0001-kanban-prompt-body-chars.patch` | The one local patch the build applies to the pinned Hermes checkout |

The image installs the base CLI tooling its own harnesses need: `git`, `curl`, `coreutils`,
`findutils`, `build-essential`, `libxi6`, plus **`sqlite3`**, **`jq`**, **`rsync`** and
**`restic`** (`apt-get install --no-install-recommends`, apt lists cleaned in the same layer).
A runtime `apt-get install` cannot supply them — the runtime uid has no root and the image
cleans the apt lists — so they are baked in. `scripts/test-backup.sh` needs `sqlite3` and
`rsync`, `backup/backup.sh` and `backup/restore.sh` need `restic`, and `collect-diagnostics.sh`
needs `jq`.

The service is defined only in the overlay. Compose must always run with all three files —
`docker-compose.yml`, `openhands/docker-compose.openhands.yml`,
`hermes/docker-compose.hermes.yml` — because a run that omits an overlay treats its service
as an orphan and `--remove-orphans` deletes it. `install.sh`, `doctor.sh` and
`openhands/scripts/openhands-control.sh` all pass the full set.

---

## Both code trees are pinned in the image, outside the data volume

Neither the Hermes Agent code nor the WebUI code is stored in `hermes_data/`. The image
builds **two** pinned trees, both root-owned and outside every mount:

| Tree | Path | Pin |
|---|---|---|
| Hermes Agent | `/opt/hermes-agent` | `HERMES_COMMIT=3d0a61ac94e1181985177fdd975c4efeb478e9b7`, plus the local patch in `patches/` |
| Hermes WebUI | `/app` | `HERMES_WEBUI_COMMIT=1e2e4dde6520e5d96bb5b20dfb2f65aa890eeb5e` |

This is deliberate:

- `/root/.hermes` is the mount point for the `hermes_data` volume. Anything the image wrote
  there would be hidden the moment the volume is mounted, so the code must not live there.
  The image's `/root/.hermes` is empty: the build installs under `/opt` and deletes its
  throwaway home.
- The build downloads the agent installer to a file and checks its sha256 **before** running
  it. A mismatch fails the build. The installer is never piped from the network into a shell.
  The download retries on a transient failure (`curl -fsSL --retry 5 --retry-all-errors
  --retry-delay 5`), so an HTTP 429 or 5xx from the raw host does not fail the image build,
  `install.sh`, or the bootstrap. The sha256 check still runs on every attempt, before the
  installer executes.
- The WebUI is cloned, checked out at its pin, and asserted with `git rev-parse`; a mismatch
  fails the build. `.git` is then removed, so neither tree carries a checkout fingerprint.
- `/opt/hermes-agent` and `/app` are both root-owned and outside every mount, so they are
  **immutable to the runtime uid** (uid `10001`). The launcher on `PATH` is the install's own
  `/opt/hermes-agent/.hermes/bin/hermes`, also root-owned, plus a root-owned
  `/usr/local/bin/hermes` symlink so `hermes` resolves in every shell, including a login shell
  that rebuilds `PATH` from `/etc/profile`.
- Both trees are byte-compiled at build time by the interpreter that runs them, so the
  runtime uid never writes bytecode. This matters for the WebUI, whose Python can run with
  `-I`, which ignores `PYTHONDONTWRITEBYTECODE`.

### The WebUI is pinned to the `/opt` agent, never the data-volume copy

The WebUI is container PID 1: it hosts every chat and its tools. `bootstrap.py` picks the
Agent directory by trying `HERMES_WEBUI_AGENT_DIR` first, then `$HERMES_HOME/hermes-agent`
(the data volume), and only then `/opt/hermes-agent`. A production volume that still holds
the old `/root/.hermes/hermes-agent` copy therefore wins unless the image pins the agent dir
and its interpreter. The image sets:

- `HERMES_WEBUI_AGENT_DIR=/opt/hermes-agent` — force the code to the pinned tree.
- `HERMES_WEBUI_PYTHON=/opt/hermes-agent/.hermes/venv/bin/python` — a **stable root-owned
  path** created at build time from `/opt/manifest.json` (`discover_launcher_python` looks
  for `<agent_dir>/venv` or `.venv`, which `/opt/hermes-agent` does not have; its venv lives
  under `installs/<key>/venv`). The build fails if the manifest has no venv or the venv has
  no interpreter.
- `HERMES_WEBUI_SERVER_CWD=/root/.hermes/webui` — the server cwd defaults to the agent dir,
  which is now read-only to the runtime uid; this points it at a **runtime-writable** path
  inside the data volume.

The WebUI `CMD` also passes `bootstrap.py --skip-agent-install`, so a missing agent **fails
closed** with "Hermes Agent was not found and auto-install was disabled." instead of
downloading the UNPINNED installer from NousResearch main.

The old data-volume copy **must stay on the Pi** (rollback) until the migration card. The
pinning wins without deleting it.

### Runtime dependency state (the `.leases` file) stays on the volume

The WebUI is pinned to the `/opt` code, but the runtime **dependency state** must still live
on the writable data volume. `pm/environments.py::install_state_dir(project)` resolves to
`dependency_home_root()/installs/<install_key>`, where the root is
`get_default_hermes_root()`: `$HERMES_HOME` when set, otherwise `$HOME/.hermes`. When the
pinned venv is selected at boot (`pm/environments.py::activate_dependencies`), the process
pins that generation by writing `<install_state_dir>/environments/<uuid>/.leases`
(`hermes_cli/runtime_state.py::lease_directory`). The root is pinned to the volume with
`HERMES_HOME=/root/.hermes`, so for the `/opt` install `installs/<install_key>` is
`/root/.hermes/installs/ffad…` — the data volume.

So the image sets `HERMES_HOME=/root/.hermes` (the `hermes_data` mount) explicitly, rather
than leaving it unset or inheriting a value. Setting `HERMES_HOME=/opt/hermes-agent` would
move `.leases` (and the whole generation tree) into the read-only `/opt` tree and break the
runtime uid; pinning it to the volume keeps the lease writable. The supported setting for
this routing is `HERMES_HOME`; the smoke job asserts it is the data volume, alongside the
`docker diff` check that the runtime never writes under `/opt`.

The Hermes PM also writes **install state** into the sealed `/opt` tree — `install-stamp.json`,
`tools/facts.json`, `installs/<key>/facts.json`, and `installs/<key>/pm-runtime` with its
generations. The build wrote those as mode `0600`/`0700`, so the runtime uid could not read
them: every dispatch printed the install-out-of-sync banner, `hermes pm doctor` refused, and the
bundled tools under `tools/` were never put on `PATH`. The image now `chmod -R a+rX`es those
paths at **build** time (state files `0644`, the `pm-runtime` and generation directories `0755`),
so the runtime uid can read them and `hermes pm doctor` runs. A build-time `chmod` adds no write
at runtime, so `docker diff` stays clean. Ownership is untouched — `chmod` only, never `chown` —
so `/opt/hermes-agent` stays root-owned with no group/other write bit, and the immutability
assertions in the `Dockerfile` stay green. The stamp's `distribution` is set to `docker` in the
same step that sets `updateMechanism=external`, which is the value `hermes_cli/steward.py`
expects for a sealed `/opt` tree (`sealed_steward()` otherwise returns `unknown`).

### Upgrading Hermes or the WebUI

An upgrade is a pull request that changes the pins and re-checks the patch:

1. **Agent:** set `HERMES_COMMIT` in `hermes/Dockerfile` to the new commit and
   `HERMES_INSTALL_SHA256` to the sha256 of
   `https://raw.githubusercontent.com/NousResearch/hermes-agent/<sha>/scripts/install.sh`.
   Confirm `patches/0001-kanban-prompt-body-chars.patch` still applies at that commit.
2. **WebUI:** set `HERMES_WEBUI_COMMIT` to the new commit. The build asserts `git rev-parse`.
   Also bump the matching string in the `validate.yml` assertion so the check tracks the pin.
3. Let CI prove it: the `hermes-nonroot-smoke` job (which runs on any pull request touching
   `hermes/` or the workflow, and unconditionally on the weekly schedule and manual dispatch)
   builds the image, runs it as uid `10001`
   with a **decoy** agent on the data volume, and checks PID 1 maps only `/opt/hermes-agent`,
   the decoy was never imported, a login shell resolves `hermes`, and nothing under `/app` or
   `/opt` changed.

`hermes update` run inside the container **no longer applies**: the image tracks a pinned
commit and the install tree is sealed (no `.git`). Update the pin instead.

Runtime tool installs (browsers, extra packages) land under `$HERMES_HOME`, that is the
`hermes_data` volume at `/root/.hermes`, not under the install dir. They are rebuildable
and are excluded from the backup.

---

## Mounts

| Host path | Container path | Mode | Notes |
|---|---|---|---|
| *none (baked into the image)* | `/opt/hermes-agent` | **read-only to the runtime uid** | The pinned Hermes Agent code and its toolchain. Root-owned, outside every mount, so the runtime never writes here. The WebUI is pinned to it with `HERMES_WEBUI_AGENT_DIR`. |
| *none (baked into the image)* | `/app` | **read-only to the runtime uid** | The pinned Hermes WebUI code (the container PID 1). Root-owned; byte-compiled at build. `.git` is removed, so it carries no checkout fingerprint. |
| `${HYBRID_AI_DATA_DIR}/hermes_data` | `/root/.hermes` | read-write | Persistent memory, SQLite state, FTS5 indexes and acquired skills. With the default layout this is `./hermes_data` under the deployment directory — see the gaps below. The image's own `/root/.hermes` is empty; the code is not stored here. |
| `${HYBRID_AI_DATA_DIR}/hermes_data/workspace` | `/root/workspace` | read-write | Persistent WebUI workspace; the same host folder the container also sees at `/root/.hermes/workspace`. |
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
  git hooks disabled, LFS smudge skipped, symlinks disabled). Existing repos fast-forward only;
  a dirty tree is skipped with a warning, never hard-reset. Before any fetch it refuses a clone
  whose git config embeds a credential in a remote URL. A tree that already contains a symlink
  is skipped as `skipped:symlinks` and left untouched.
- It takes an `flock` so two runs cannot collide, and it is idempotent, reads no credentials,
  and writes only under `AGENT_REPOS_DIR`.
- It **refuses** a target that is, is inside, or contains any protected tree —
  `HYBRID_AI_APP_DIR`, `HYBRID_AI_DATA_DIR`, `HYBRID_AI_LOG_DIR`,
  `HYBRID_AI_WORK_DIR`, the directory the env file lives in, `OPENHANDS_WORKSPACE`
  or `BACKUP_CONF_DIR` — so mounting it read-only cannot expose the env file, the
  logs, or the backup credentials.

### Inventory and verification

Each run writes `${AGENT_REPOS_DIR}/INVENTORY.md` atomically. The file holds the run time
(UTC), a totals line, and one row per repository:

| Repository | Default branch | HEAD | Status | Last sync (UTC) |
| --- | --- | --- | --- | --- |

Status is exactly one of `cloned`, `updated`, `up-to-date`, `skipped:<reason>`, `error`, or
`stale` (present on disk but no longer in the inventory; left in place, never deleted). No URL
appears anywhere in the file.

Two flags read the tree without changing it:

```bash
./scripts/sync-agent-repos.sh --dry-run   # list the planned action per repo; writes nothing
./scripts/sync-agent-repos.sh --check     # offline; verify INVENTORY.md against the tree
```

`--dry-run` lists the API and manifest inventories and the action each repo would get (clone,
update, or a skip reason). It does no clone, no fetch, and writes no file.

`--check` uses no network. It reads `INVENTORY.md`, then confirms every listed directory exists
and its HEAD still matches. Exit codes: `0` ok; `1` the inventory is older than
`AGENT_REPOS_MAX_AGE_HOURS` (default 48) or a skipped row exists; `2` a directory is missing, a
HEAD does not match, or the inventory is missing or unreadable. `doctor.sh` runs this check and
warns (never fails) when it is not `0`.

A normal run exits `0` when all is well, `1` when anything was skipped or is stale, and `2` on
any error.

`install.sh` runs it near the start of every deploy, before it loads `.env`, and its failure is
a warning (not a stop). To refresh on a schedule, install a timer **by hand**. A daily systemd
timer:

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
| WebUI (`bootstrap.py`) | The container main process, PID 1: serves the Hermes WebUI. | The image `CMD` |
| Hermes gateway / kanban dispatcher | A background process in the same container: drains the kanban queue. | The image `CMD` |

Both are started by the **image `CMD`** in `hermes/Dockerfile`. The compose overlay no
longer sets a `command:`, so the `CMD` is the single start command: it starts the gateway
in the background, then `exec`s `bootstrap.py` as PID 1. The port is positional
(`bootstrap.py` takes the port as an argument; it has no `--port` flag).

Keeping the start command in one place is deliberate: an image `CMD` that production never
ran (because compose overrode it) is exactly how the `--port` bug reached the Pi. The
`validate` workflow and the `hermes-nonroot-smoke` job both assert against
`hermes/Dockerfile`. The smoke job runs whenever a pull request touches `hermes/` or the
workflow (and unconditionally on the weekly schedule and manual dispatch).

The gateway runs as the **default** profile, pinned with `-p default`
(`hermes -p default gateway run --replace`). This is load-bearing: a sticky named
active profile stored in the bind-mounted `hermes_data/` (mounted at
`/root/.hermes/active_profile`) would otherwise capture a bare `hermes gateway run`
and be refused with `Profile '<name>' does not get a gateway of its own`. There is
only one gateway per host, and it is owned by the default profile. Pinning
`-p default` in the `CMD` makes the gateway start after every container
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
| `HYBRID_AI_HERMES_HOME_DIR` | `backup/backup.sh`, `backup/restore.sh`, `scripts/lib/hybrid-ai-env.sh` | The per-user Hermes home the system-mode backup captures. Default `$HOME/.hermes`; the host bootstrap sets it to `/var/lib/hybrid-ai/hermes-home`, created empty and owned by the `hybrid-ai` account. |
| `OPENHANDS_WORKSPACE` | `docker-compose.hermes.yml` | Host path mounted at `/workspace` and `/agent-repo`. Required. |
| `AGENT_REPOS_DIR` | `docker-compose.hermes.yml`, `scripts/sync-agent-repos.sh` | Host path of the agent repo reference tree, mounted at `/agent-repos` read-only. Defaults to `${HOME}/hybrid-ai-repos` when unset. |
| `AGENT_REPOS_OWNER` | `scripts/sync-agent-repos.sh` | Account whose owned, non-fork repos are inventoried. Blank means: derive it from the owner in this clone's git origin URL. |
| `AGENT_REPOS_MANIFEST` | `scripts/sync-agent-repos.sh` | Optional local manifest of private repos. Blank means `./agent-repos.local`. |
| `AGENT_REPOS_MAX_AGE_HOURS` | `scripts/sync-agent-repos.sh` | Freshness window, in hours, for `--check` (default 48). Older than this reports the tree stale. |
| `HERMES_PORT` | `docker-compose.hermes.yml` | Host port for the WebUI. |
| `HERMES_API_PORT` | `docker-compose.hermes.yml` | Host port for the API. |
| `HERMES_COMMIT` | `hermes/Dockerfile` (build arg) | The pinned Hermes Agent commit the image installs from. Bump only with a re-checked patch and a new installer sha256. |
| `HERMES_INSTALL_SHA256` | `hermes/Dockerfile` (build arg) | sha256 of the pinned installer script. The build fails on mismatch. |
| `HERMES_INSTALL_DIR` | `hermes/Dockerfile` (build arg) | Where the pinned code installs. Default `/opt/hermes-agent`, outside every mount. |
| `HERMES_WEBUI_COMMIT` | `hermes/Dockerfile` (build arg) | The pinned Hermes WebUI commit the image clones into `/app`. The build asserts `git rev-parse`. |
| `HERMES_WEBUI_AGENT_DIR` | image `ENV` | Forces the WebUI agent dir to `/opt/hermes-agent`, ahead of the data-volume copy. |
| `HERMES_WEBUI_PYTHON` | image `ENV` | Forces the WebUI interpreter to the stable root-owned `/opt/hermes-agent/.hermes/venv/bin/python`. |
| `HERMES_WEBUI_SERVER_CWD` | image `ENV` | The server's working directory; a runtime-writable path (`/root/.hermes/webui`) in the data volume, since the agent dir is read-only to the runtime uid. |
| `HERMES_WEBUI_DISABLE_LOCAL_VENV` | image `ENV` | `1` makes bootstrap fail closed instead of creating `/app/.venv` at runtime (a write into the read-only WebUI tree) when the pinned interpreter cannot import both the WebUI deps and the Agent. |
| `HERMES_HOME` | image `ENV` | Pins runtime dependency state (incl. the venv generation `.leases`) to the data volume `/root/.hermes`. Must never be `/opt/hermes-agent`, which is read-only to the runtime uid. |
| `HYBRID_AI_UID` | `docker-compose.hermes.yml`, `docker-compose.yml` (status `user:`), `openhands/docker-compose.openhands.yml` (`SANDBOX_USER_ID`), `hermes/Dockerfile`, `install.sh`, `doctor.sh` | Dedicated non-root uid. Drives the Hermes container uid, the status-container `user:`, and the OpenHands sandbox uid, so the whole stack runs as that account. Unset keeps today's behaviour: the login account's uid. Set by the account migration. |
| `HYBRID_AI_GID` | `docker-compose.hermes.yml`, `hermes/Dockerfile`, `install.sh` | Group id matching `HYBRID_AI_UID`. Unset keeps the login account's gid. |
| `HYBRID_AI_DATA_DIR` | `docker-compose.yml`, `hermes/docker-compose.hermes.yml`, `scripts/lib/hybrid-ai-env.sh` | Host data root. `hermes_data/`, `webui_data/` and `ollama_data/` live under it, names unchanged. The helper default is the repo directory; the compose bind source is fail-closed (`${HYBRID_AI_DATA_DIR:?HYBRID_AI_DATA_DIR must be set - run ./install.sh}/hermes_data`), so compose refuses to parse unless the installer has exported it. |
| `OPENROUTER_API_KEY` | container env, and each profile's own `.env` | Model provider for agent work. Each board-running profile (default, builder, reviewer) also needs `OPENROUTER_API_KEY` in its own profile `.env` under `hermes_data/` (e.g. `hermes_data/.env`, `hermes_data/profiles/builder/.env`, `hermes_data/profiles/reviewer/.env`); a profile without it stalls its board. |
| `LOCAL_DOMAIN` | container env | Used for local subdomain routing. |
| `HERMES_DATA_DIR` | `.env.example` only | Documented as the memory directory; the overlay now binds `${HYBRID_AI_DATA_DIR:?HYBRID_AI_DATA_DIR must be set - run ./install.sh}/hermes_data`. |

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

- **Repository access:** Only select repositories: `hybrid-ai`, `shared-actions`, `runpod-hybrid-worker`.
- **Contents:** Read and write.
- **Pull requests:** Read and write.
- **Metadata:** Read-only.
- **Workflows:** Read and write.
- **Not granted:** no Administration, no organization scope.

The token can push changes under `.github/workflows/`, so workflow changes reach `main` only
through a reviewed pull request. The builder pushes only `ai/*` branches, and only after
independent review. The written reason for the Workflows permission and the compensating controls
are recorded in
[`../SECURITY.md`](../SECURITY.md#github-credential-separation).

---

## Reaching OpenHands from Hermes

Over `coder-net`, from inside the `hermes-agent` container, the OpenHands API answers at:

```
http://openhands:3000
```

**Can a job be created and followed to completion with only that URL?**

Yes. Creating a job and following it — status, event stream and per-file diff — are all served
by the OpenHands app REST API at `http://openhands:3000` over `coder-net`:

- **Creating a job** against the OpenHands API over `http://openhands:3000` works: it is a
  REST call to the app server, which is the member of `coder-net`. The start-tasks route
  creates the job.
- **Following a job** uses the same app API: `GET /api/v1/app-conversations` lists the
  conversations, the start-tasks route reports their status, and `events/search` streams the
  events and per-file diff. The builder follows a whole run this way, reading it from inside
  the `hermes-agent` container. The sandbox agent-server is not needed for this.

The sandbox agent-server host port is published by the sandbox on the host and is **not**
reachable from the Hermes container. It is not needed to follow a job.

No route, bind, or network was added, and none is needed. Any change to narrow the sandbox
ports belongs to a later phase.

---

## Pre-existing gaps (flagged, not fixed here)

These are existing properties of the service, recorded so they are not mistaken for
something this change introduced. They are addressed in a later phase.

| Gap | Detail | Why it is not fixed here |
|---|---|---|
| Hermes ports bind all interfaces | `8501` and `8642` are published on `0.0.0.0`, so anyone on the LAN or tailnet can reach them. | Narrowing the binds is out of scope; this change adds no binds and does not widen any. |
| Hermes mounts the deployment directory read-write | `./hermes_data` is a subdirectory of the deployment directory, mounted read-write at `/root/.hermes`. | The memory store must be writable; relocating it is a later phase. |
| Hermes runs as root | **Fixed in the image.** `hermes/Dockerfile` creates a dedicated `hermes` group/user and ends with `USER ${HYBRID_AI_UID}:${HYBRID_AI_GID}` (default `10001`); the compose overlay passes the ids through from `.env`, sets `user:`, and pins `no-new-privileges`. A host keeps the legacy uid 0 until the account migration sets `HYBRID_AI_UID`. | Merging needs no admin action: unset keeps uid 0. |
| OpenHands sandbox ports publish on all interfaces | Sandboxes created by OpenHands publish their agent-server port on the host. Adjacent to this service, not part of it. | Later phase. |

---

## Validation note

The checks in this change ran without recreating containers (Docker was not running in the
build sandbox and no `.env` exists there). The compose configuration was validated by parsing
it, and `doctor.sh` was syntax-checked. The post-recreate checks — `docker network inspect
coder-net` showing exactly two members, a write test against `/agent-repo` failing, a request
from Hermes to `http://openhands:3000` succeeding, and `./doctor.sh` green — were **not**
run here; run them on the Pi after `./install.sh`.

The CLI-tooling and PM install-state change is also a build-only edit; the image was not built
here. Verify after merge on the Pi: a plain dispatch prints no install-out-of-sync banner,
`hermes pm doctor` exits `0`, the bundled `ffmpeg`, `node`, `npm` and `rg` resolve for Hermes
children, `scripts/test-backup.sh` runs to completion, and
`command -v sqlite3 jq rsync restic` all resolve inside the container.

---

## Related documentation

- [`../openhands/README.md`](../openhands/README.md) — the OpenHands service, its workspace
  clone, and the shared `coder-net` network.
- [`../SECURITY.md`](../SECURITY.md) — the `172.17.0.1` webhook exception and the read-only
  mount.
- [`../README.md`](../README.md) — architecture, networks and ports.
