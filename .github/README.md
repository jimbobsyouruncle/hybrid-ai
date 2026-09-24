# `.github/` — Continuous Deployment

| File | Purpose |
|---|---|
| `workflows/deploy.yml` | Validates the code, then updates the Pi over the Tailscale network whenever you push to `main`. |

---

## What this does

Push a change to `main`, and GitHub rents a temporary computer that validates your code, joins your private network, SSHes into your Raspberry Pi, pulls the new version, and re-runs `install.sh`. If the site does not come back up, the build fails loudly with the relevant logs attached.

The interesting part is how it reaches your Pi. **Your Pi has no public IP address, no open firewall ports, and no port forwarding configured.** The GitHub runner temporarily joins your Tailscale network as a member tagged `tag:ci`, connects over the encrypted mesh, does its work, and disappears when the job ends.

This is strictly better than the conventional approach of exposing SSH to the internet. There is no permanent attack surface, because there is no permanently reachable service.

**This is entirely optional.** Everything works if you deploy by hand with `git pull && ./install.sh`. CI just removes the manual step.

---

## The two jobs

### Job 1 — `validate`

Runs on every push. Catches mistakes before they can reach the Pi.

| Check | What it catches |
|---|---|
| `bash -n` on every `*.sh` in the repo | Syntax errors, unbalanced quotes |
| ShellCheck | Common shell bugs (advisory — reports but does not block) |
| `py_compile` on every `*.py` in the repo | Python syntax errors, including `status/app.py`, which is bind-mounted with no build step |
| `build_pipe.py --check` | A forgotten rebuild — the pasted pipe not matching its reviewed sources |
| `test_refactor.py` | Regressions in mesh enforcement, credential scrubbing, truncation detection |
| `docker compose config`, both files | Malformed compose file or OpenHands overlay |
| **Secret assertion** | Fails the build if `.env` or a data folder was ever committed |

That last check is the one worth understanding. If `.env` somehow got committed, this stops the deploy and tells you. Note that by then the credentials are already in git history and **must be rotated** — deleting the file in a later commit does not remove it from history, and anyone with a clone still has a copy.

### Job 2 — `deploy`

Only runs if `validate` passed.

1. Joins the tailnet as an ephemeral node tagged `tag:ci`
2. Confirms the Pi is reachable, retrying for ~50 seconds while mesh routes establish
3. SSHes in, runs `git reset --hard origin/main`, then `./install.sh --non-interactive`
4. Polls the health endpoint for up to two minutes
5. On failure, dumps the last 50 log lines into the workflow output so you can diagnose it without SSHing in yourself

---

## Why your data is safe during a deploy

`git reset --hard` is a destructive command, and seeing it in a deploy script should make you pause. It is safe here because of a specific chain of guarantees:

| Guarantee | Mechanism |
|---|---|
| Backup credentials are untouched | They live in `~/.config/hybrid-ai-backup/`, outside the repo entirely |
| `webui_data/` and `ollama_data/` are untracked | Listed in `.gitignore`, so `git reset` cannot see or touch them |
| `.env` survives | Also gitignored. `install.sh` reads existing values and preserves them |
| Login sessions survive | `WEBUI_SECRET_KEY` is reused, not regenerated, so cookies stay valid |
| Containers are never destroyed with volumes | The workflow runs `up -d`, never `down -v` |
| Failure is visible | Health check failure fails the build with logs attached |

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
