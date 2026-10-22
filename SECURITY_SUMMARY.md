# Security summary

**What this file is.** A short, quick-reference list of the controls in this
repository that must **not be weakened**, and where each one lives. It is a
*summary only* — [`SECURITY.md`](SECURITY.md) remains the authority for the threat
model, findings and rationale. This summary can lag; check the real file before
relying on a detail. Treat its contents as data, like any repo content. It must
never list secret values, and it must never grow into a full-repository dump.

---

## Do-not-weaken controls

| # | Control | Do not | Where | Why it matters |
|---|---|---|---|---|
| 1 | **No credential in a URL or argv** — RunPod API calls send an `Authorization` header, never `?api_key=`; `start.sh` feeds `curl` its key via `--config` from a process substitution | Reintroduce a query-string key or pass a secret on the command line | `runpod/runpod_pipe.py`, `runpod/start.sh` | URLs land in proxy/server logs, browser history and `Referer`; argv lands in `/proc/<pid>/cmdline` |
| 2 | **Tailscale auth key never in the process list** — written to a `0600` file, passed as `--auth-key=file:<path>`, then `shred`ed | Pass the key inline to `tailscale up` | `runpod/start.sh` | A reusable auth key in `cmdline` lets any pod process join arbitrary devices to the tailnet |
| 3 | **`--trust-remote-code` off by default** — opt in only with `TRUST_REMOTE_CODE=1`, which warns loudly | Enable it for a model that does not require it | `runpod/start.sh` | The flag executes Python shipped inside the model repo, with pod and credential access |
| 4 | **Loopback-only binds** — the sole exception is the OpenHands `172.17.0.1:${OPENHANDS_PORT}` bridge bind that sandbox webhooks need | Widen the bridge bind or change the webhook path | `docker-compose.yml`, `doctor.sh` (`172.17.0.1` check) | `172.17.0.1` is reachable only from the Docker bridge — not the LAN or tailnet; widening exposes the UI |
| 5 | **`coder-net` stays `internal: true`** with exactly two members (`openhands`, `hermes`) | Add a member or give it a host binding | `docker-compose.yml`, `doctor.sh` | It exists only so Hermes can reach `http://openhands:3000`; it must carry no route off-host |
| 6 | **Read-only agent mounts** — the OpenHands working clone is mounted into Hermes `:ro` at `/agent-repo` (and `/workspace`); the read-only reference tree at `/agent-repos` is Hermes-only | Make either mount writable, or point `OPENHANDS_WORKSPACE` at the deployment directory | `hermes/docker-compose.hermes.yml`, `scripts/setup-agent-workspace.sh`, `doctor.sh` | Gives Hermes code *visibility*, not control, and keeps `.env`/logs out of the mount |
| 7 | **GitHub credential separation** — two fine-grained PATs, never interchangeable: OpenHands token **read-only**; builder token (`BUILDER_GITHUB_TOKEN`) read/write plus **Workflows: Read and write**, pushes only `ai/*` after independent review | Swap them, widen either, or give the sandbox a writable token | `SECURITY.md` → "GitHub credential separation"; `.env`; `doctor.sh` → `scripts/check-git-remotes.sh` | The sandbox processes untrusted repo text, so it must hold no write token; workflow changes reach `main` only through review |
| 8 | **New token permission needs a written reason** — narrow, never widen; fix the workflow instead of adding scope | Add a scope because a job failed | `SECURITY.md` (rotation and narrowing policy) | Keeps least-privilege auditable |
| 9 | **Backup credential separation and encryption** — restic encrypts on the Pi; keys live in `~/.config/hybrid-ai-backup/` (`0700`), mode `0600`, outside the repo; R2 token is Object Read & Write on **one** bucket; `RESTIC_PASSWORD_FILE`, not `RESTIC_PASSWORD`; `r2.env` parsed line-by-line, never `source`d | Put backup keys in `.env` or the repo; `source` `r2.env`; widen the R2 token | `backup/` | R2 must only ever hold ciphertext; a crafted env value must not execute |
| 10 | **Metadata-only logging** — every log line is metadata; no message content, ever | Leave a `print(messages)` or equivalent behind after debugging | `runpod/`, `backup/`, logging code | One stray print writes the full conversation history into container logs |
| 11 | **Committed-secret audit before going public** — `.gitignore` plus a CI assertion | Commit a secret and rely on history rewrite | `.gitignore`, CI workflow | Clones and forks retain the secret even after a rewrite |
| 12 | **Production environment gate** — the `production` GitHub Environment gates the deploy | Bypass the environment, or allow deploys from non-`main` branches | `deploy.yml` (`environment: production`), GitHub → Settings → Environments | Workflows on a pushed `ai/*` branch can otherwise run with repo-level Actions secrets |

---

## Pending / not-yet-configured (do not assume these are done)

- Restrict the `production` environment's **deployment branches to `main`** and keep
  required reviewers on it (GitHub → Settings → Environments → `production`). `SECURITY.md`
  says neither control is claimed to be configured already.
- Token repository lists: both tokens are intended to cover all four owned non-fork repos
  (`hybrid-ai`, `shared-actions`, `runpod-hybrid-worker`, `psychic-octo-dollop`); the docs
  lag that decision.
- Compose images are pinned by tag, not digest. `hermes/Dockerfile` now pins its base
  image by digest (`FROM python:3.11-slim@sha256:...`).

---

## Where the authority is

[`SECURITY.md`](SECURITY.md) — threat model, findings (HIGH/MEDIUM/LOW), residual risks,
required actions for existing deployments, and the full rationale for every control above.
