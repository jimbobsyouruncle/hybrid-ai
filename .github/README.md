# `.github/` — Continuous Deployment

| File | Purpose |
|---|---|
| `workflows/deploy.yml` | On a push to `main`, reuses `validate.yml` and then updates the Pi over the Tailscale network. |
| `workflows/validate.yml` | Reusable source validation (`workflow_call` only). Called by `sast-checks.yml` on every pull request and by `deploy.yml` on every push to `main`. Holds no secrets. |
| `workflows/agent-context.yml` | Checks the checked-in `REPO_MAP.md` and `CODE_INDEX.md` are fresh on every pull request. Read-only; never commits. |
| `workflows/sast-checks.yml` | The single pull-request gate: ShellCheck, Semgrep, source validation, CodeQL and the Hermes non-root smoke test, ending in the `Security & SAST gate`. |
| `dependabot.yml` | Grouped pull request that opens weekly on Sunday at 22:00 America/New_York to bump the SHA-pinned GitHub Actions. GitHub Actions only. |

---

## What this does

Push a change to `main`, and GitHub rents a temporary computer that validates your code, joins your private network, SSHes into your Raspberry Pi, pulls the new version, and re-runs `install.sh`. If the site does not come back up, the build fails loudly with the relevant logs attached.

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

1. Joins the tailnet as an ephemeral node tagged `tag:ci`
2. Confirms the Pi is reachable, retrying for ~50 seconds while mesh routes establish
3. SSHes in and resets the Pi to the exact `github.sha` CI validated (not `origin/main`), after refusing any revision that is not an ancestor of `origin/main`
4. Execs `./scripts/deploy-remote.sh <sha>`, which first re-asserts `HEAD` equals `<sha>` and then runs `./install.sh --non-interactive` itself
5. Polls the health endpoint for up to two minutes
6. Runs `./doctor.sh --no-cloud` as a gate: warnings stay green, failures turn the deploy red
7. On failure, dumps the last 50 log lines into the workflow output so you can diagnose it without SSHing in yourself

**Why the revision is pinned, not `origin/main`.** `validate` tests the commit that
triggered the run (`GITHUB_SHA`). If the deploy reset to `origin/main`, and `main`
moved after validation, the Pi would run an unvalidated revision. A manual
**Run workflow** from a non-main branch would make the validated and deployed
trees differ outright. Resetting to the exact SHA, and asserting `HEAD` matches
it twice on the Pi — once in the workflow's remote script right after the reset,
and once as `scripts/deploy-remote.sh`'s first action — closes that gap. The
ancestor check keeps the target on the deployed line of history.

---

## The pull-request gate

`sast-checks.yml` is the one workflow that runs on every pull request to `main`. It has no `paths:` filter, so a docs-only pull request still produces the check the branch ruleset requires. It runs on `pull_request` (opened, synchronize, reopened — not `ready_for_review`, so marking a draft ready re-runs nothing), on manual `workflow_dispatch`, and on a weekly `schedule` (Mondays) for a CodeQL baseline and a Semgrep rule-drift check. There is no push-to-main trigger.

| Job | Check | What it catches |
|---|---|---|
| `shellcheck` | ShellCheck (Bash) | Common shell scripting bugs. Blocking. |
| `semgrep` | Semgrep (`--config auto --error`) | SAST findings from the community rulesets. Blocking. |
| `validate` | `Validate sources` | Calls the same reusable `validate.yml` the deploy uses (see Job 1 above). |
| `codeql` | `Analyze (python)` and `Analyze (actions)` | CodeQL advanced setup for Python and GitHub Actions. |
| `hermes-nonroot-smoke` | Hermes non-root smoke | Builds the Hermes image as uid/gid `10001` and runs it as `10001` with `--cap-drop ALL --security-opt no-new-privileges`, no secrets, and a `10001`-owned `/root/.hermes` seeded with a **decoy** agent (a valid Agent source root that writes a marker if imported). Checks `id -u`, HTTP 200 on 8501 within 180 s, liveness at +60 s, the gateway is up, and the local kanban patch is in `/opt/hermes-agent`. Then the pinning checks: PID 1 maps Python only from `/opt/hermes-agent` (never `/root/.hermes`), the decoy marker is absent, one `/api/onboarding/status` request (which imports `run_agent`) answers 200, `bash -lc 'command -v hermes'` resolves to `/usr/local/bin/hermes`, and `docker diff` shows no change under `/app` or `/opt`. Prints `docker diff` (paths only). |
| `gate` | **`Security & SAST gate`** | The single required check. Always runs; fails unless every job above succeeded. |

**CodeQL advanced setup.** CodeQL previously ran as GitHub "default setup", a dynamic workflow GitHub created and ran on each pull request and each push to `main`. This workflow replaces it with advanced setup: a checked-in `codeql` job, pinned to `github/codeql-action` `24c54180a607b1449ed407dd24f251e4e9147c8d` (`v4.38.3`), analysing `python` and `actions` with `build-mode: none`, publishing under the category `/language:<lang>`. Results also appear on the weekly schedule run under **Security → Code scanning**. The `codeql` job is the only job that widens permissions, adding `security-events: write` and `actions: read`; the workflow default is `contents: read`.

**One gate.** Branch protection needs one check, not several. `gate` depends on all five jobs with `if: always()`, so it runs even when an earlier job fails or is cancelled. It prints each result and exits non-zero unless every result is `success` — a failure, a cancellation and a skip all fail.

### Owner steps before and after merge

1. **Before merge:** **Settings → Code security → CodeQL analysis → disable default setup.** While it is on, GitHub rejects advanced-setup uploads and the `codeql` job fails.
2. **After the first green run:** ruleset `main-protection` → add required check `Security & SAST gate`.

---

## Keeping the pins current (Dependabot)

`dependabot.yml` keeps the SHA-pinned actions in the workflows current. It opens one grouped pull request weekly on Sunday at 22:00 America/New_York (all actions in a single group, commit prefix `ci`, at most 5 open at a time) that bumps every pin it finds.

Dependabot covers **GitHub Actions only**. These pins still move by hand and are easy to forget:

| Pin | Where | Why Dependabot does not cover it |
|---|---|---|
| `semgrep/semgrep@sha256:93963d…` | `workflows/sast-checks.yml` | Container image digest, not an action |
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

## Headless deploy (not active until migration)

`deploy/` and `scripts/deploy-*.sh` hold the in-repo pieces of a **headless
deploy**: a dedicated, unprivileged `hybrid-ai-deploy` account with a
forced-command SSH entrypoint that can do exactly one thing — start the system
unit `hybrid-ai-deploy@<sha>.service` for a 40-character commit.

**Nothing in this path is active yet, and `deploy.yml` is unchanged.** The
migration is two later owner steps: **card F**, `scripts/bootstrap.sh`, installs
the unit, the polkit rule, the scripts and the `authorized_keys` line on the host
and creates the account as a system account with `/bin/sh` and a locked password
(sshd runs the forced command through the login shell); a later card switches
`deploy.yml` to call the forced command instead of the current
`appleboy/ssh-action` step. See [`../deploy/README.md`](../deploy/README.md) for
the `authorized_keys` line, the install locations, the refusal exit codes and the
least-privilege statement.

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
| Validated revision is what runs | The deploy resets to the exact `github.sha` CI validated, and both the workflow and `scripts/deploy-remote.sh` assert `HEAD` equals it |

The workflow also prints disk usage of both data folders before and after, so every run leaves an audit trail showing nothing shrank.

---

## Setup

### 1. Generate a deploy SSH key

On your own machine — **not** on the Pi:

```bash
ssh-keygen -t ed25519 -C "github-actions-hybrid-ai" -f ~/.ssh/hybrid_ai_deploy
```

Copy the **public** half to the Pi:

```bash
ssh-copy-id -i ~/.ssh/hybrid_ai_deploy.pub pi@<your-pi-tailscale-ip>
```

Verify it works before going further:

```bash
ssh -i ~/.ssh/hybrid_ai_deploy pi@<your-pi-tailscale-ip> "echo connected"
```

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
| `PI_SSH_USER` | Usually `pi` | Your Pi's username |
| `PI_SSH_KEY` | **Private** key contents | `cat ~/.ssh/hybrid_ai_deploy` — include the BEGIN and END lines |
| `PI_REPO_PATH` | e.g. `/home/pi/hybrid-ai` | `pwd` in the repo folder on the Pi |
| `PI_SSH_HOST_KEY` | The Pi's SSH host key | `ssh-keyscan -t ed25519 $(tailscale ip -4) \| ssh-keygen -lf -` on the Pi — use the SHA256:... field, not the raw known_hosts line |

> `PI_SSH_KEY` takes the **private** key. That is correct and expected — GitHub needs it to authenticate. It is stored encrypted and masked in logs. This is also why the key should be dedicated to this purpose and authorised only on the Pi, never a key you use elsewhere.

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
| SSH `permission denied (publickey)` | Wrong key, or public half not installed | Re-run `ssh-copy-id`; confirm you pasted the **private** key into the secret |
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
