# `.github/` — Continuous Deployment

| File | Purpose |
|---|---|
| `workflows/deploy.yml` | On a push to `main`, reuses `validate.yml` and then triggers the deploy unit on the Pi over the Tailscale network. |
| `workflows/validate.yml` | Reusable source validation (`workflow_call` only). Called by `sast-checks.yml` on every pull request and by `deploy.yml` on every push to `main`. Holds no secrets. |
| `workflows/sandbox-image.yml` | Builds and publishes the derived agent-server image to GHCR. Auto-publishes on a push to `main` that changes `openhands/agent-server/Dockerfile` (tag read from the `image_tag` default, guarded against overwriting an existing tag); `workflow_dispatch` is the manual rebuild path. |
| `workflows/agent-context.yml` | Checks the checked-in `REPO_MAP.md` and `CODE_INDEX.md` are fresh on every pull request. Read-only; never commits. |
| `workflows/sast-checks.yml` | The single pull-request gate: ShellCheck, Semgrep, source validation, CodeQL and the Hermes non-root smoke test, ending in the `Security & SAST gate`. |
| `dependabot.yml` | Grouped pull request that opens weekly on Sunday at 22:00 America/New_York to bump the SHA-pinned GitHub Actions. GitHub Actions only. |

---

## What this does

Push a change to `main`, and GitHub rents a temporary computer that validates your code, joins your private network, and asks your Raspberry Pi (over SSH, as the dedicated deploy account) to run the exactly-one-thing deploy unit. The unit pulls the new version and re-runs `install.sh`. If the site does not come back up, the build fails loudly with the relevant logs attached.

The interesting part is how it reaches your Pi. **Your Pi has no public IP address, no open firewall ports, and no port forwarding configured.** The GitHub runner temporarily joins your Tailscale network as a member tagged `tag:ci`, connects over the encrypted mesh, does its work, and disappears when the job ends.

This is strictly better than the conventional approach of exposing SSH to the internet. There is no permanent attack surface, because there is no permanently reachable service.

**This is entirely optional.** Everything works if you deploy by hand with `git pull && ./install.sh`. CI just removes the manual step.

---

## The deploy jobs

`deploy.yml` has two jobs. The first is now a thin caller of the reusable
`validate.yml`, which the pull-request gate calls too.

### Job 1 — `validate`

Runs on every pull request to `main` (through `sast-checks.yml`) and on every
push to `main` (through `deploy.yml`). Catches mistakes before they can reach
the Pi.

| Check | What it catches |
|---|---|
| `bash -n` on every `*.sh` in the repo | Syntax errors, unbalanced quotes |
| `py_compile` on every `*.py` in the repo | Python syntax errors, including `status/app.py`, which is bind-mounted with no build step |
| `build_pipe.py --check` | A forgotten rebuild — the pasted pipe not matching its reviewed sources |
| `pip install httpx==0.28.1` | Installs the pinned dependency the behavioural tests import (`runpod_core.py` imports `httpx`, which the job does not otherwise install) |
| `test_refactor.py` | Regressions in mesh enforcement, credential scrubbing, truncation detection |
| `scripts/test-bootstrap.sh` | Regressions in the one-time host bootstrap: account/layout creation, the layout/stack env split, migration moves, refusal exit codes, and no-secret-in-output |
| `docker compose config`, all three files | Malformed compose file, OpenHands overlay, or Hermes overlay |
| **Caddy allowlist assertion** | A sensitive route losing its `trusted_only` IP allowlist |
| **Hermes gateway pin assertion** | The `hermes -p default gateway run --replace` CMD being dropped from `hermes/Dockerfile` |
| **WebUI pin assertion** | The WebUI agent dir, interpreter, server cwd, local-venv disable, WebUI commit pin, or `--skip-agent-install` being dropped from `hermes/Dockerfile` |
| **Secret assertion** | Fails the build if `.env` or a data folder was ever committed |

That last check is the one worth understanding. If `.env` somehow got committed, this stops the deploy and tells you. Note that by then the credentials are already in git history and **must be rotated** — deleting the file in a later commit does not remove it from history, and anyone with a clone still has a copy.

The old advisory ShellCheck step is gone from validation. It was `continue-on-error`, so it never blocked anything. The blocking ShellCheck job in `sast-checks.yml` covers the same ground and does fail the gate.

### Job 2 — `deploy`

Only runs if `validate` passed.

1. Runs `scripts/deploy-image-gate.sh`, a fail-closed pre-flight gate that polls GHCR until the sandbox image tag pinned by `install.sh` STEP 8 is published, so the deploy cannot race the image build. It needs no token and no tailnet; `permissions` stay `contents: read`. Bounded at 36 minutes, just past the build workflow's 30-minute ceiling.
2. Joins the tailnet as an ephemeral node tagged `tag:ci`
3. Confirms the Pi is reachable, retrying for ~50 seconds while mesh routes establish
4. Connects as the dedicated `hybrid-ai-deploy` account and sends exactly one command string, `deploy <sha>`, through `scripts/deploy-trigger.sh`
5. The forced command on the Pi starts the system unit `hybrid-ai-deploy@<sha>.service`, which runs `scripts/deploy-instance.sh <sha>`: it refuses any revision that is not an ancestor of `origin/main`, resets to the exact `github.sha` CI validated, and asserts `HEAD` equals it
6. `scripts/deploy-instance.sh` hands off to `scripts/deploy-remote.sh <sha>`, which re-asserts `HEAD` and then runs `./install.sh --non-interactive`
7. `scripts/deploy-remote.sh` polls the health endpoint for up to two minutes and gates on `./doctor.sh --no-cloud`: warnings stay green, failures turn the deploy red
8. `scripts/deploy-remote.sh` also starts `scripts/run-post-deploy-verify.sh` in a transient `systemd-run` unit named `hybrid-ai-post-deploy-verify-<sha12>-<pid>`, which outlives the deploy unit and records `PASS`/`FAIL`/`TIMEOUT` for that commit in `/var/log/hybrid-ai-post-deploy-verify.log`. Its outcome never changes the deploy's exit status (see [`deploy/README.md`](../deploy/README.md#post-deploy-verification-after-the-workflow-has-finished))
9. The forced command reads back the unit result and prints the run log into the workflow output, so you can diagnose a failure without SSHing in yourself

**Why the revision is pinned, not `origin/main`.** `validate` tests the commit that
triggered the run (`GITHUB_SHA`). If the deploy reset to `origin/main`, and `main`
moved after validation, the Pi would run an unvalidated revision. A manual
**Run workflow** from a non-main branch would make the validated and deployed
trees differ outright. The client sends the exact SHA, the host refuses any
revision that is not an ancestor of `origin/main`, and the tree is reset to that
SHA with a `HEAD` assert — twice, once in `scripts/deploy-instance.sh` and once
as `scripts/deploy-remote.sh`'s first action. The ancestor check keeps the target
on the deployed line of history.

**Why the runner no longer runs a shell script on the Pi.** The deploy account's
SSH key is pinned to ONE forced command. It cannot run git, a shell, or a second
command. All the host-side work lives in the tracked scripts the unit runs. This
is what removes the admin-account login from the deploy path.

---

## The pull-request gate

`sast-checks.yml` is the one workflow that runs on every pull request to `main`. It has no `paths:` filter on its triggers, so a docs-only pull request still produces the `Security & SAST gate` check the branch ruleset requires. The only job that is filtered is `hermes-nonroot-smoke`, and only by an in-workflow `changes` job: it is skipped when the pull request touches neither `hermes/` nor the workflow itself, because such a pull request cannot change the image that job builds. Every other job, and `schedule`/`workflow_dispatch`, stay unfiltered. It runs on `pull_request` (opened, synchronize, reopened — not `ready_for_review`, so marking a draft ready re-runs nothing), on manual `workflow_dispatch`, and on a weekly `schedule` (Mondays) for a CodeQL baseline and a Semgrep rule-drift check. There is no push-to-main trigger.

| Job | Check | What it catches |
|---|---|---|
| `shellcheck` | ShellCheck (Bash) | Common shell scripting bugs. Blocking. |
| `semgrep` | Semgrep (`--config auto --error`) | SAST findings from the community rulesets. Blocking. On a pull request it scans only the files the PR changed (`--baseline-commit` against the PR base SHA); `workflow_dispatch` and the weekly `schedule` keep the full-tree scan. |
| `validate` | `Validate sources` | Calls the same reusable `validate.yml` the deploy uses (see Job 1 above). |
| `codeql` | `Analyze (python)` and `Analyze (actions)` | CodeQL advanced setup for Python and GitHub Actions. |
| `changes` | Detect Hermes changes | Diffs the PR base against HEAD for `hermes/` and this workflow, passing `github.base_ref` through `env:`. Fails closed (`set -euo pipefail`); an empty base (schedule, dispatch) sets the smoke to run. No third-party action. |
| `hermes-nonroot-smoke` | Hermes non-root smoke | Builds the Hermes image as uid/gid `10001` and runs it as `10001` with `--cap-drop ALL --security-opt no-new-privileges`, no secrets, and a `10001`-owned `/root/.hermes` seeded with a **decoy** agent (a valid Agent source root that writes a marker if imported). Checks `id -u`, HTTP 200 on 8501 within 180 s, liveness at +60 s, the gateway is up, and the local kanban patch is in `/opt/hermes-agent`. Then the pinning checks: PID 1 maps Python only from `/opt/hermes-agent` (never `/root/.hermes`), the decoy marker is absent, one `/api/onboarding/status` request (which imports `run_agent`) answers 200, `bash -lc 'command -v hermes'` resolves to `/usr/local/bin/hermes`, and `docker diff` shows no change under `/app` or `/opt`. Prints `docker diff` (paths only). Skipped when the `changes` job finds no change under `hermes/` or this workflow. |
| `gate` | **`Security & SAST gate`** | The single required check. Always runs; requires `success` from every job, with one exception: `hermes-nonroot-smoke` may be `skipped`, and only when `changes` succeeded. A `failure` or `cancelled` anywhere still reds it. |

**CodeQL advanced setup.** CodeQL previously ran as GitHub "default setup", a dynamic workflow GitHub created and ran on each pull request and each push to `main`. This workflow replaces it with advanced setup: a checked-in `codeql` job, pinned to `github/codeql-action` `24c54180a607b1449ed407dd24f251e4e9147c8d` (`v4.38.3`), analysing `python` and `actions` with `build-mode: none`, publishing under the category `/language:<lang>`. Results also appear on the weekly schedule run under **Security → Code scanning**. The `codeql` job is the only job that widens permissions, adding `security-events: write` and `actions: read`; the workflow default is `contents: read`.

**One gate.** Branch protection needs one check, not several. `gate` depends on all six jobs with `if: always()`, so it runs even when an earlier job fails or is cancelled. It prints each result and exits non-zero unless every result is `success`. The single exception is the Hermes non-root smoke, which may be `skipped` — and only because the `changes` job, itself required to succeed, proved the pull request cannot change the image the smoke builds. A failure or a cancellation anywhere, and a skip by any job other than `hermes-nonroot-smoke`, all fail the gate.

### Owner steps before and after merge

1. **Before merge:** **Settings → Code security → CodeQL analysis → disable default setup.** While it is on, GitHub rejects advanced-setup uploads and the `codeql` job fails.
2. **After the first green run:** ruleset `main-protection` → add required check `Security & SAST gate`.

---

## Keeping the pins current (Dependabot)

`dependabot.yml` keeps the SHA-pinned actions in the workflows current. It opens one grouped pull request weekly on Sunday at 22:00 America/New_York (all actions in a single group, commit prefix `ci`, at most 5 open at a time) that bumps every pin it finds.

Dependabot covers **GitHub Actions only**. These pins still move by hand and are easy to forget:

| Pin | Where | Why Dependabot does not cover it |
|---|---|---|
| `semgrep/semgrep:1.179.0@sha256:93963d…` | `workflows/sast-checks.yml` | Container image tag and digest, not an action |
| Compose / Dockerfile image tags | `docker-compose.yml`, `hermes/Dockerfile` | Container images, not actions |
| `httpx==0.28.1` | `workflows/validate.yml` | pip pin inside a workflow step |
| shared-actions `ref:` | `workflows/agent-context.yml` | A non-action git ref outside Dependabot's scope |
| Tailscale `version: '1.104.1'` | `workflows/deploy.yml` | An action input, not a versioned dependency |

---

## Agent context maps and freshness check

`REPO_MAP.md` and `CODE_INDEX.md` at the repository root are small, generated maps of the tracked tree. Coding agents read them instead of whole-code dumps, so context stays small and answers stay fast.

The **Agent context** workflow (`workflows/agent-context.yml`) enforces that they are fresh. On every pull request to `main` it checks out the generator at a pinned commit from `jimbobsyouruncle/shared-actions`, runs the fixture test (`scripts/test-check-agent-context.sh`), and runs `scripts/check-agent-context.sh` against the committed maps.

The check prints nothing and exits `0` when both maps match a fresh run. It exits `1` when a map is stale or missing, or when a retired `CONSOLIDATED_*.md` is still tracked. It exits `2` on a usage error or a generator failure (including a size overflow over `--max-bytes 20480`).

To refresh the maps yourself:

```bash
python3 <path-to-generate.py> --root . --output-dir . --max-bytes 20480
```

The workflow holds `permissions: contents: read`, adds no write permission, and never commits or pushes. The maps land only through reviewed pull requests.

---

## Headless deploy (active after bootstrap)

`deploy/` and `scripts/deploy-*.sh` hold the pieces of a **headless
deploy**: a dedicated, unprivileged `hybrid-ai-deploy` account with a
forced-command SSH entrypoint that can do exactly one thing — start the system
unit `hybrid-ai-deploy@<sha>.service` for a 40-character commit.

**This path is now the deploy.** `deploy.yml` connects as the dedicated
`hybrid-ai-deploy` account and sends exactly one command string, `deploy <sha>`,
through the tracked client `scripts/deploy-trigger.sh`. It no longer logs in as
the admin account and no longer runs a shell script on the Pi. The ancestor
check, the reset to that exact commit and the `HEAD` assert all run inside
`scripts/deploy-instance.sh`, which the system unit runs as root.

It becomes fully active when the owner runs **card F**, `scripts/bootstrap.sh`,
which installs the unit, the polkit rule, the scripts and the `authorized_keys`
line on the host and creates the account as a system account with `/bin/sh` and
a locked password (sshd runs the forced command through the login shell). Once
that bootstrap has run, every push to `main` takes this path. The bootstrap
installs those files once; `install.sh` re-applies the unit and the polkit rule
on every deploy, so a change to either file reaches the host without a by-hand
copy (effective from the next instantiation). See
[`../deploy/README.md`](../deploy/README.md) for the `authorized_keys` line, the
install locations, the refusal exit codes and the least-privilege statement.

The account holds no login beyond the forced command (its password is locked), no
sudo, and is in neither the `docker` nor the `systemd-journal` group. The polkit
rule grants only
`start` of a matching unit.

---


## Why your data is safe during a deploy

`git reset --hard` is a destructive command, and seeing it in a deploy script should make you pause. It is safe here because of a specific chain of guarantees:

| Guarantee | Mechanism |
|---|---|
| Backup credentials are untouched | They live in `~/.config/hybrid-ai-backup/` (or `/etc/credstore/hybrid-ai-backup/` in system mode), outside the repo entirely |
| `webui_data/` and `ollama_data/` are untracked | Listed in `.gitignore`, so `git reset` cannot see or touch them |
| `.env` survives | Also gitignored. `install.sh` reads existing values and preserves them |
| Login sessions survive | `WEBUI_SECRET_KEY` is reused, not regenerated, so cookies stay valid |
| Containers are never destroyed with volumes | The workflow runs `up -d`, never `down -v` |
| Failure is visible | A health-check failure fails the build with logs attached, and a `doctor.sh` exit 2 fails the build after the health report prints |
| Validated revision is what runs | The deploy asks the host to run exactly the `github.sha` CI validated. `scripts/deploy-instance.sh` refuses unless it is an ancestor of `origin/main`, resets to it and asserts `HEAD` equals it, and `scripts/deploy-remote.sh` re-asserts `HEAD` before reprovisioning |

The deploy prints disk usage of both data folders after the run, so every deploy leaves an audit trail showing nothing shrank.

---

## Setup

### 1. Generate a deploy SSH key

On your own machine — **not** on the Pi:

```bash
ssh-keygen -t ed25519 -C "github-actions-hybrid-ai" -f ~/.ssh/hybrid_ai_deploy
```

Install the **public** half on the Pi through the bootstrap, which writes it to
the dedicated `hybrid-ai-deploy` account and pins it to the forced command:

```bash
sudo ./scripts/bootstrap.sh --deploy-pubkey ~/.ssh/hybrid_ai_deploy.pub
```

Do not copy it to the admin account with `ssh-copy-id`: the deploy no longer logs
in as the admin account. See [`../deploy/README.md`](../deploy/README.md) for the
`authorized_keys` line and the install locations.

### 2. Create a Tailscale OAuth client

Tailscale admin console → **Settings** → **OAuth clients** → **Generate**:

- Scope: **`auth_keys`** (write)
- Tags: **`tag:ci`**

Save both the client ID and the secret.

### 3. Add the ACL rule

Admin console → **Access controls**. Without this, the runner joins the network but is not permitted to reach your Pi:

```jsonc
{
  "tagOwners": {
    "tag:ci": ["autogroup:admin"]
  },
  "acls": [
    // Your own devices can reach everything
    { "action": "accept", "src": ["autogroup:member"], "dst": ["*:*"] },

    // CI runners: SSH to the Pi only. Nothing else.
    { "action": "accept", "src": ["tag:ci"], "dst": ["100.x.x.x:22"] }
  ]
}
```

Replace `100.x.x.x` with your Pi's address from `tailscale ip -4`. Keep this rule as narrow as it is — the CI runner needs exactly one port on exactly one host.

### 4. Add the repository secrets

GitHub repo → **Settings** → **Secrets and variables** → **Actions** → **New repository secret**.

| Secret | Value | Where to get it |
|---|---|---|
| `TS_OAUTH_CLIENT_ID` | OAuth client ID | Step 2 |
| `TS_OAUTH_SECRET` | OAuth client secret | Step 2 |
| `PI_TAILSCALE_IP` | `100.x.x.x` | `tailscale ip -4` on the Pi |
| `PI_SSH_KEY` | **Private** key contents | `cat ~/.ssh/hybrid_ai_deploy` — include the BEGIN and END lines. The matching public key is pinned to the forced command on the `hybrid-ai-deploy` account |
| `PI_SSH_HOST_KEY` | The Pi's SSH host key fingerprint | `ssh-keyscan -t ed25519 $(tailscale ip -4) \| ssh-keygen -lf -` on the Pi — use the SHA256:... field, not the raw known_hosts line |
| `PI_SSH_USER` | **Unused** | May be deleted by the owner |
| `PI_REPO_PATH` | **Unused** | May be deleted by the owner |

> `PI_SSH_KEY` takes the **private** key. That is correct and expected — GitHub needs it to authenticate. It is stored encrypted and masked in logs. This is also why the key should be dedicated to this purpose and authorised only on the Pi, never a key you use elsewhere. It is now the key for the dedicated `hybrid-ai-deploy` account, and its `authorized_keys` line pins it to the forced command.

> `PI_SSH_USER` and `PI_REPO_PATH` are unused. The deploy no longer logs in as
> the admin account (the login name is the literal `hybrid-ai-deploy`), and the
> remote path is resolved on the host by `scripts/deploy-instance.sh`. The owner
> may delete both secrets.

### 5. Optional — require approval before deploying

The workflow declares `environment: production`. Under **Settings → Environments → production**, add yourself as a required reviewer and every deploy will pause for your approval.

Worth enabling if the Pi is doing anything you depend on.

### 6. Test it

```bash
git commit --allow-empty -m "test: verify deploy pipeline"
git push
```

Watch the **Actions** tab. First run takes 2–4 minutes.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Pi ... is unreachable over the tailnet` | ACL rule missing, or Pi offline | Verify the `tag:ci` ACL; check `tailscale status` on the Pi |
| SSH `permission denied (publickey)` | Wrong key, or public half not installed | Re-run `sudo ./scripts/bootstrap.sh --deploy-pubkey ~/.ssh/hybrid_ai_deploy.pub` on the Pi; confirm you pasted the **private** key into the secret. `ssh-copy-id` will not work — the deploy account's key is pinned to the forced command |
| `RUNPOD_API_KEY missing and --non-interactive was requested` | `.env` does not exist on the Pi yet | Run `./install.sh` interactively on the Pi once first |
| `Open WebUI failed its health check` | Container did not start | The workflow output includes the last 50 log lines — read those |
| OAuth client errors | Wrong scope or missing tag | Client needs `auth_keys` write scope and `tag:ci` |
| Workflow does not trigger | Only doc files changed | `paths-ignore` skips `**/*.md` by design. Use the manual **Run workflow** button |

---

## Manual deploy

The workflow is a convenience, not a dependency. This does the same thing:

```bash
ssh pi@<pi-tailscale-ip>
cd hybrid-ai
git pull
./install.sh
```

---

## Security notes

- **Least privilege.** The workflow declares `permissions: contents: read`. It can read your code and nothing else.
- **Ephemeral identity.** The runner's tailnet membership exists only for the duration of the job.
- **Narrow ACL.** `tag:ci` reaches port 22 on one host. Not your laptop, not the GPU pod.
- **Concurrency lock.** `concurrency: deploy-control-plane` prevents two runners reconfiguring the Pi simultaneously.
- **Secret masking.** GitHub redacts secret values from logs automatically — but avoid `echo`-ing them regardless, since masking is pattern-based and not infallible.
- **Rotate the deploy key** if you ever suspect the repository was accessed by someone else.
