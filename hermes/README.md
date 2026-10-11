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
| `${OPENHANDS_WORKSPACE}` | `/workspace` | **read-only** | The OpenHands clone. Read-only so Hermes can read code without editing it. |
| `${OPENHANDS_WORKSPACE}` | `/agent-repo` | **read-only** | The same clone again, under a name that makes its purpose explicit: the read-only view of the OpenHands working clone. Writes here fail inside the container. |

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

## Environment variables

Referenced by name only; values live in `.env`, which is gitignored.

| Name | Read by | Purpose |
|---|---|---|
| `OPENHANDS_WORKSPACE` | `docker-compose.hermes.yml` | Host path mounted at `/workspace` and `/agent-repo`. Required. |
| `HERMES_PORT` | `docker-compose.hermes.yml` | Host port for the WebUI. |
| `HERMES_API_PORT` | `docker-compose.hermes.yml` | Host port for the API. |
| `OPENROUTER_API_KEY` | container env | Model provider for agent work. |
| `LOCAL_DOMAIN` | container env | Used for local subdomain routing. |
| `HERMES_DATA_DIR` | `.env.example` only | Documented as the memory directory, but the overlay currently hardcodes `./hermes_data`. |

---

## Credentials: `BUILDER_GITHUB_TOKEN`

`BUILDER_GITHUB_TOKEN` is the GitHub credential the builder uses to push `ai/*` branches and
open pull requests. It is referenced by name only; the value lives in `.env`, which is
gitignored. It is separate from the read-only OpenHands token and never enters the OpenHands
sandbox (see [`../SECURITY.md`](../SECURITY.md#github-credential-separation)).

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
