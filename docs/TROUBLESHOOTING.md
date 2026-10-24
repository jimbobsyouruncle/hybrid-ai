# Troubleshooting & Operations

Start with [Diagnostic triage](#diagnostic-triage) to find which layer is failing, then jump to that section.

---

## Start here

**In a browser:** `http://<your-pi>/status`

Service health, **last run status for every scheduled job**, recent errors, log tails, and a one-click diagnostic download. Usually the fastest way to see what is wrong. `http://<your-pi>/hub` lists every service with live health.

**On the command line:**

```bash
./doctor.sh
```

One command. It checks the host, configuration, containers, services, network, backups, and data integrity, then prints exactly what is wrong and the command to fix it. It is entirely read-only, so it is always safe to run — including on a system you think is already broken.

```
./doctor.sh              full report
./doctor.sh --quiet      problems only (good for cron)
./doctor.sh --no-cloud   skip checks that contact RunPod or R2
```

Exit codes: `0` healthy, `1` warnings only, `2` something is broken. That makes it usable in monitoring:

```bash
# Email yourself if anything is wrong
0 8 * * * cd ~/hybrid-ai && ./doctor.sh --quiet || mail -s "hybrid-ai needs attention" you@example.com
```

If `doctor.sh` points at a specific area, jump to that section below.

---

## Still stuck? Collect a diagnostic bundle

```bash
./collect-diagnostics.sh
```

This gathers everything relevant — system info, container states, the last 100 log lines from each service, configuration, network status, database health, and backup status — into a single text file designed to be **shared safely**.

```
./collect-diagnostics.sh                 full report
./collect-diagnostics.sh --lines 300     more log history
./collect-diagnostics.sh --output FILE   write somewhere specific
./collect-diagnostics.sh --no-redact     UNSAFE — local debugging only
```

### What it removes

Every value that could be a credential is stripped before it is written:

| Data | How it appears in the report |
|---|---|
| `.env` values | `RUNPOD_API_KEY  <REDACTED:length=37>` — name and length only |
| RunPod / Tailscale / AWS / GitHub keys, JWTs, bearer tokens | `<REDACTED:...>` |
| Passwords embedded in URLs | `https://<REDACTED:userinfo>@…` |
| Private key blocks | `<REDACTED:private-key-block>` |
| Tailscale addresses | Masked to `100.x.x.N` |
| MAC addresses, email addresses | `<REDACTED:mac>`, `<REDACTED:email>` |
| **Chat content, documents, vectors** | **Never read at all** — only counts and sizes |

Knowing that a key is *present and 64 characters long* is almost always enough to diagnose a problem. The actual value never is.

The final section of every report is a **self-audit** that re-scans the finished file for anything still secret-shaped and warns you if it finds something. The script exits `1` in that case.

> Redaction is best-effort pattern matching, not a guarantee. **Skim the file before sharing it** — `less diagnostics-*.txt`. The script reminds you.

### Using it with an AI assistant

The report opens with a context header explaining the architecture and the non-obvious behaviours — that a stopped GPU pod is *normal*, that cold starts legitimately take minutes, that the Pi has no GPU. That framing prevents an assistant from confidently misdiagnosing intentional design as a fault.

Paste the file and describe the symptom:

> "Here is a diagnostic report from my self-hosted AI stack. The cloud model times out every time, but local models work fine. What's the root cause?"

Bundles are gitignored and written mode 0600.

---

## Scheduled jobs

The status page shows the last outcome of every job, parsed from the structured event logs:

| Job | Written by | Expected cadence |
|---|---|---|
| Backup | `backup.sh` | Nightly, 03:15 |
| Integrity check | `backup.sh --check` | Monthly |
| Restore rehearsal | `restore.sh --test` | Quarterly, manual |
| Retention prune | `backup.sh` | With each backup |
| Install / deploy | `install.sh` | On each run |

A job goes **warn** when it is overdue (a backup older than 36 hours, an integrity check older than 45 days) and **fail** when its last run errored. "Never run" is reported for backups and integrity checks, since those are expected to have happened.

The **Deploy verification** tile is not a scheduled job: it reports the latest post-deploy verifier verdict, parsed from that verifier's own log. `ok` names the verified revision and when the verdict was written; `fail` quotes a `FAIL`/`TIMEOUT` verdict; `warn` means no verdict is readable yet (the log is absent, empty, a directory, unreadable by the status container, or has no parseable header). See the tile table in [`status/README.md`](../status/README.md) for the detail.

From the CLI:

```bash
grep '^EVENT' backup.log | tail -20
grep '^EVENT' install.log | tail -10
curl -s http://localhost/status/api | jq '.jobs'
```

---

## Status page problems

| Symptom | Cause | Fix |
|---|---|---|
| `/status`, `/hub` or `/ollama` refuses the connection | You are outside the allowlist (private LAN + tailnet only) | Connect over the LAN or Tailscale. See `status/Caddyfile` |
| `/openwebui` returns 302 | **Expected.** It redirects to the site root `/` — see the note in the README | Nothing to fix |
| `/health` returns 503 | **Expected** when any check is degraded — that is the endpoint working | Open `/status` to see which check |
| Blank Open WebUI page under a subpath | Open WebUI cannot be served from a subpath | Use `/openwebui` (which redirects to the site root), never a custom prefix |
| Port 80 in use, proxy will not start | Another web server on the Pi | `sudo ss -tlnp \| grep :80` |
| Page loads, containers show "not found" | Socket group mismatch | Compare `DOCKER_GID` in `.env` with `stat -c '%g' /var/run/docker.sock`, then `./install.sh` |
| Everything on the page fails | Status container cannot reach the others | `docker network inspect hybrid-ai` |

Full detail in [`status/README.md`](../status/README.md). The status page is optional — chat works without it, which is why `doctor.sh` reports its absence as a warning rather than a failure.

---

## A red deploy caused by doctor.sh

The automated deploy runs `doctor.sh --no-cloud` on the Pi as its final gate. It reads the exit code instead of discarding it, so a broken host turns the deploy red. This is the difference that makes the gate useful:

| `doctor.sh` exit code | Meaning | Deploy result |
|---|---|---|
| `0` | Everything healthy | Green, deploy continues |
| `1` | Warnings only — working, but something needs attention | Green, prints `::warning::doctor.sh reported warnings` |
| `2` | One or more failures — something is actually broken | Red, prints `::error::doctor.sh reported failures` |
| any other | Unexpected | Red, treated the same as `2` |

How to read it from the Actions page:

1. Open the failed **deploy** job and scroll to the `Health report` section.
2. The `::error::doctor.sh reported failures` line is printed last, after the health report, the persistent-data `du`, and the backup-timer line. Those informational lines still print on a failed deploy.
3. Above that line, find the `FAIL` rows in the report. Each one names the check and the command to fix it.
4. SSH in and re-run `./doctor.sh` by hand to reproduce and iterate — it is read-only, so it is safe to run repeatedly.
5. Fix the failure, then re-run the deploy.

A missing or non-executable `doctor.sh` is also an error, not a skip. The old inline script ran it only if executable and ignored its exit code; that skip is gone, because a health gate that quietly does not run is worse than no gate. If the deploy reports `doctor.sh is missing or not executable`, the file was removed from the checkout — restore it from the repository.

Warnings (`exit 1`) never fail the deploy. If you want to silence one, fix the underlying warning rather than masking the exit code.

---

## Post-deploy verification

Every deploy starts `scripts/run-post-deploy-verify.sh` in a **transient**
systemd unit named `hybrid-ai-post-deploy-verify-<sha12>-<pid>`. It outlives the
deploy unit, waits for the GitHub Actions run(s) for the deployed commit to
finish, then checks the host is on that commit. Why a transient unit:
[`deploy/README.md`](../deploy/README.md#post-deploy-verification-after-the-workflow-has-finished).

Read the result:

```
sudo tail -n 20 /var/log/hybrid-ai-post-deploy-verify.log
sudo journalctl -u 'hybrid-ai-post-deploy-verify-*' --since -2h
```

Each run appends a `waiting for <sha> at <UTC>` line and then exactly one
result line:

| Line | Meaning |
|---|---|
| `PASS` | Every workflow run for that commit concluded `success`, and `/workspace` is on that commit |
| `FAIL: run <id> conclusion <c>` | One run, and it did not succeed (`failure`, `cancelled`, `timed_out`, ...) |
| `FAIL: run conclusions: <list>` | Several runs; the list is one word per run, in API order |
| `FAIL: deployed tree is on <sha>, expected <sha>` | CI was green, but the host is on a different commit (interrupted deploy, or a manual `git reset`) |
| `FAIL: github api returned HTTP <code>` | The API refused (401/403/404, or 429 rate limit). The request is anonymous, so a 403 usually means the anonymous rate limit |
| `FAIL: cannot read HEAD of the deployed tree at /workspace` | The deployment directory is absent or not a git checkout |
| `FAIL: ... that jq could not parse` | The API returned a body this script does not understand (proxy or captive portal, usually) |
| `TIMEOUT: no completed run for <sha> after 60 minutes` | No run for that commit finished inside an hour |

The most common **silent** failure used to be a 0-byte log: the verifier was
killed when the deploy unit exited, so nothing was written and nothing said so.
`doctor.sh` now catches it. It reads the log as data, takes the **last**
`waiting for <sha> at <ts>` line as the run of interest, and reads the first
verdict line after it. It never compares the log's mtime with anything: `doctor`
runs during a deploy, after the new tree is checked out but before that deploy's
verifier can have written, so an mtime comparison would warn on every deploy by
construction. Instead, the previous deploy's verdict is surfaced in the **next**
deploy's Actions log through these warnings.

| Situation | doctor.sh |
|---|---|
| Log absent | prints `- post-deploy verification log skipped (log not present (...))`, counts nothing |
| Log is 0 bytes | **warns**: "the post-deploy verifier never wrote anything", with the `journalctl` remedy |
| Last waiting line, verdict `PASS` | **passes**: `post-deploy verification passed for <sha12> (verdict written <ts>)`. There is no comparison with the deployed `HEAD`, so a `PASS` for any sha passes |
| Verdict `FAIL: ...` or `TIMEOUT: ...` | **warns**: "post-deploy verification reported '\<verdict\>' for \<sha12\>", with the `journalctl` remedy |
| Waiting line, no verdict, wait started more than 65 minutes ago | **warns**: the verification was abandoned |
| Waiting line, no verdict, wait started within 65 minutes | prints a skip note: the verification is still running. Back-to-back deploys are legitimate |
| Non-empty log with no parseable waiting line | **warns**: the waiting line cannot be parsed. It never passes silently |
| Log unreadable, git tree unreadable, or unparseable waiting timestamp | prints a skip note, counts nothing |

None of these can fail the host: the check is warning-only, so the worst it can
do is exit 1. If the deploy printed `::warning::post-deploy verification script
is absent: <path>`, `install.sh` never placed the verifier -- re-run
`./install.sh` as root, then check `ls -l /usr/local/sbin/run-post-deploy-verify.sh`.
The deploy's own exit status never depends on the verifier.

---

## Headless deploy: refusal exit codes

The headless deploy path (`deploy/`, `scripts/deploy-*.sh`, the
**active after bootstrap** system unit) reports every refusal with its own exit
code. Read the code to know which control fired.

The client the deploy job runs first, `scripts/deploy-trigger.sh`:

| Exit | Meaning | Fix |
|---|---|---|
| `0` | Remote exit 0: the unit started and finished successfully; the job is green | — |
| `1` | The remote command failed. Remote exit 2 means the forced command refused the request (see below); remote exit 3 means the unit failed; any other code is an SSH-level failure | Read the `::error::` line above the exit |
| `2` | Bad usage: the argument is missing, or is not a 40-lowercase-hex commit; nothing was sent | Pass exactly one full 40-hex commit |
| `3` | A local prerequisite failed: a required env value is missing, or the host key could not be fetched | Check the step `env:` block and that the Pi answers `ssh-keyscan` |
| `4` | The Pi's host-key fingerprint did not match `PI_SSH_HOST_KEY`; ssh was never invoked | See "Headless deploy: host-key mismatch" below |

The forced-command SSH entrypoint, `scripts/deploy-forced-command.sh`:

| Exit | Meaning | Fix |
|---|---|---|
| `0` | The unit started and finished successfully | — |
| `2` | The command was refused: it was not exactly `deploy <40-lowercase-hex>` (extra arguments, another verb, shell metacharacters, or an empty command). Nothing was run | Send exactly `ssh <host> deploy <40-lowercase-hex>` |
| `3` | The unit was started but did not finish successfully | Read the run log (below); the deploy failed inside `deploy-remote.sh` or the unit |

The unit's script, `scripts/deploy-instance.sh` (run as root by
`hybrid-ai-deploy@<sha>.service`):

| Exit | Meaning | Fix |
|---|---|---|
| `0` | Handed off to `deploy-remote.sh` (its exit code then propagates through `exec`) | — |
| `2` | Missing argument, or not a 40-lowercase-hex commit | Pass the full 40-character lowercase hex commit |
| `3` | Another deploy holds the lock | Wait for the running deploy to finish, then retry |
| `4` | The origin remote carries a credential (userinfo in its URL) | Remove the credential from the origin URL; the deploy fetches only from the public https remote |
| `5` | The public remote is unsafe (not https, or carries userinfo) | Point `HYBRID_AI_DEPLOY_PUBLIC_REMOTE` at the public https remote, by name only |
| `6` | Fetching main from the public remote failed | Check network and the remote URL, then retry |
| `7` | The commit is not an ancestor of `origin/main` | Deploy a commit that is on `main` |
| `8` | `HEAD` is not the commit after `git reset --hard` | Investigate the checkout; the reset did not land on the validated revision |

Every run's output is written to `$HYBRID_AI_LOG_DIR/deploy/<sha>.log` (mode
`0640`, group `hybrid-ai-deploy`). The deploy account reads its own run log there
without any systemd-journal access. Full detail is in
[`deploy/README.md`](../deploy/README.md).

### Headless deploy: the forced command refused the request

Symptom: the deploy job fails with `::error::forced command refused the request`.

`scripts/deploy-forced-command.sh` accepts EXACTLY one string:
`deploy <40-lowercase-hex>`. It refused what it received. The usual causes:

- The sha was not 40 lowercase hex characters (a short sha, or uppercase).
- The client sent extra arguments, or a second command.
- Something other than `scripts/deploy-trigger.sh` connected and asked for a
  different command.

The client sends exactly the two-token string. If this fires, check that the
deploy step still calls `scripts/deploy-trigger.sh "$GITHUB_SHA"` and that the
client was not modified to add arguments. Nothing ran on the host.

### Headless deploy: the deploy unit failed

Symptom: the deploy job fails with `::error::deploy unit failed`.

The forced command started `hybrid-ai-deploy@<sha>.service`, but the unit did not
finish successfully. The job log above the error carries the unit name
(`unit:`), its `result:` and the run log. The run log names the failing control
in `scripts/deploy-instance.sh` or `scripts/deploy-remote.sh` (an ancestor
refusal, a HEAD mismatch, a doctor.sh failure). Fix the reported problem, then
push again.

### Headless deploy: the host ran a stale installed unit

Symptom: the unit gives up earlier than the tree says it should (for example
`Result=timeout` at 20 min while `deploy/hybrid-ai-deploy@.service` says
`TimeoutStartSec=45min`), or an older copy of the unit is missing a directive
the tree has.

Cause: `/etc/systemd/system/hybrid-ai-deploy@.service` was installed by an
earlier `scripts/bootstrap.sh` and never refreshed. This happened on 2026-10-22:
the host enforced a stale `TimeoutStartSec=20min` and SIGTERM'd a deploy
mid-build, and the raise to 45 min had to be copied over by hand.

This is now self-healing. `install.sh` re-applies the unit (and the polkit rule)
on every deploy, so the **next** deploy replaces the stale file and the one
after that runs with it: a deploy re-applies the unit while running inside it,
and the running instance keeps its loaded configuration. To fix it immediately
instead of waiting for the next deploy, re-run `./install.sh` as root and then
`sudo systemctl daemon-reload`. Compare the installed copy against the tree with
`diff /etc/systemd/system/hybrid-ai-deploy@.service deploy/hybrid-ai-deploy@.service`.

### Headless deploy: host-key mismatch

Symptom: the deploy job fails with
`::error::deploy-trigger.sh: the Pi's host-key fingerprint does not match PI_SSH_HOST_KEY; refusing to connect.`

`scripts/deploy-trigger.sh` fetched the Pi's ed25519 host key and its SHA256
fingerprint did not equal the `PI_SSH_HOST_KEY` secret. No authentication was
attempted and nothing ran on the host. This is the control working: it stops
anything occupying the Pi's address from impersonating it and harvesting the
deploy key. The usual causes:

- The Pi was reinstalled or reimaged, so its host key changed. Get the new
  fingerprint with `ssh-keyscan -t ed25519 <pi-magicdns-name> | ssh-keygen -lf -` and update
  the `PI_SSH_HOST_KEY` secret.
- The secret holds a raw known_hosts line instead of the `SHA256:...` field.
  Replace it with the `SHA256:...` value only.
- The runner reached the wrong host. Check `PI_TAILSCALE_FULL_DOMAIN`.

Never "fix" this by disabling host-key checking. There is no
`StrictHostKeyChecking=no` and no `accept-new` path by design.

---

## The build phase of a deploy: gate, timestamps, timeouts

Every deploy runs `install.sh` on the Pi. Its log now answers three questions
that used to need guesswork: did the build run, how long did each phase take,
and which ceiling fires first.

### Did the build run?

The Hermes image carries a label, `org.hybrid-ai.build-inputs-sha`, holding the
sha256 of the inputs it was built from: the Dockerfile, every file under
`hermes/patches/`, the three pinned ARGs (`HERMES_COMMIT`,
`HERMES_INSTALL_SHA256`, `HERMES_WEBUI_COMMIT`) and the base-image digest on the
`FROM` line. `install.sh` recomputes that sha and compares it with the label on
`hybrid-ai-hermes:latest`.

The install log prints exactly one of:

```
[ * ] 2026-01-01T00:00:00Z build-gate: cache hit (<sha>)
[ * ] 2026-01-01T00:00:00Z build-gate: rebuild (<reason>)
```

A `cache hit` skips `docker compose build` entirely; the stack is only started
(`up -d --remove-orphans`). The reason on a rebuild is one of:

| Reason | Meaning |
| `inputs-changed` | The sha differs from the label: the Dockerfile, a patch, an ARG or the base digest moved |
| `image-absent` | `docker image inspect` found no `hybrid-ai-hermes:latest` |
| `label-missing` | The image has no label, or it is empty |
| `label-unparsable` | The label is not a 64-character lowercase hex sha |
| `inputs-unavailable` | The inputs could not be hashed (Dockerfile missing, `FROM` not pinned) |
| `no-docker` | `docker` is not on `PATH` |

Only `inputs-changed` means someone changed the build inputs. Everything else
is the gate failing toward building, which is deliberate: a gate that cannot
prove a match must build rather than serve a stale image.

If the gate reports `rebuild (inputs-changed)` on a deploy that changed nothing,
the build inputs really did move on disk. Diff the Dockerfile, the patches and
the three ARGs against the commit the running image was built from. Do not edit
the label by hand.

### Which phase took the time?

Every `log()` line in `install.sh` starts with a UTC stamp
(`YYYY-MM-DDTHH:MM:SSZ`), so `install.log` can be read against the systemd
journal. While images are pulled, images are built and services are verified,
a heartbeat prints one line per 60 s:

```
[ * ] 2026-01-01T00:00:60Z progress: phase=build elapsed=60s
```

The end of the run prints a per-phase summary:

```
[ * ] 2026-01-01T00:05:00Z Phase durations (s): pull=12 build=203 up=9 verify=31
```

The same numbers are appended to the install log as
`EVENT ... event=phase_durations`. A build that takes minutes on a deploy whose
gate said `cache hit` is a gate bug, not a slow build.

### The two ceilings no longer race

| Control | Ceiling |
| `.github/workflows/deploy.yml`, `Trigger deploy` step | 60 min |
| `deploy/hybrid-ai-deploy@.service`, `TimeoutStartSec=` | 45 min |

The step is strictly longer on purpose. The unit gives up first, so the step is
still alive to report the real `Result=` instead of being killed while the host
is mid-deploy. If the unit times out, the log says so and nothing is left
running: the unit has no `Restart=`, so there is no retry loop.

The host's copy of the unit is re-applied by `install.sh` on every deploy, so
these two numbers cannot drift apart on an already-bootstrapped host. If the
host still times out at an older ceiling, see "the host ran a stale installed
unit" above.

---

## Host bootstrap: refusal exit codes

`scripts/bootstrap.sh` is the ONE privileged, one-time command run per device.
Every refusal class has its own exit code, so a failed run tells you which
control fired.

| Exit | Meaning | Fix |
|---|---|---|
| `0` | Success, including a no-change re-run | — |
| `1` | Usage error, or an existing host object (account, directory, file) that fails verification | Fix the invocation, or reconcile the existing object by hand |
| `2` | Not run as root | Re-run with `sudo` |
| `3` | The deploy public key was refused: a private key, more than one key, or a line that already carries options | Pass exactly one public key, with no options |
| `4` | `/opt/hybrid-ai` exists but is not a clone of the public remote, or its origin carries a credential | Move the existing `/opt/hybrid-ai` aside, or remove the credential from its origin URL |
| `5` | polkitd is absent, or its version predates `.rules` (JavaScript) support | Install or upgrade polkit; the bootstrap never edits polkit's own config |
| `6` | A migration move is cross-device, or a move target already exists and is not empty (refused BEFORE any move) | Put the data on one filesystem, or empty the target, then re-run |
| `7` | `install.sh` failed | Read the install log under `HYBRID_AI_LOG_DIR`; the cut-off steps did not run |
| `8` | `doctor.sh` reported failures (exit `2` or any code other than `0`/`1`) | Fix the reported problem, then re-run the bootstrap. Warnings (`1`) do not stop the run |

In migration mode the three cut-off steps (disable the login account's timers,
remove the deploy key line from the login account's `authorized_keys`, remove the
login account from the `docker` group) run ONLY when `install.sh` succeeds and
`doctor.sh` exits `0` or `1`. Doctor warnings (`exit 1`) do not stop the run, so
only `exit 2` or any other non-zero code triggers `8`. On exit `7` or `8` none of
the cut-off steps runs. Full detail is in
[`deploy/README.md`](../deploy/README.md) and [`SECURITY.md`](../SECURITY.md).

### Re-running after exit 7

Exit `7` means `install.sh` failed while the migration moves had already
completed. The script is safe to re-run: the moves are idempotent, so a second
run skips anything already in place and continues from where it stopped.

```bash
sudo /opt/hybrid-ai/scripts/bootstrap.sh --deploy-pubkey <pub> --from <legacy checkout>
```

The most common cause of exit `7` on a first run is the Hermes image build. The
build downloads the pinned installer over the network; a transient HTTP 429 or
5xx used to fail the build, and with it `install.sh` and the bootstrap. The
download now retries (`curl --retry 5 --retry-all-errors --retry-delay 5`) and
the pinned sha256 is still checked before the installer runs, so simply re-running
is usually enough. See [`hermes/README.md`](../hermes/README.md).

Note that the first run MOVED the legacy `.env` to the stack env file
(`/etc/hybrid-ai/stack.env`). A re-run stops the stack with whichever env file is
readable, so the missing legacy `.env` is not an error on the second run.

### The Hermes health wait

`install.sh` waits for `hermes-agent` to answer its health endpoint. That wait is
now 300 s (raised from 120 s), because the first start on a Pi builds and imports
the agent tree and can take several minutes on a cold cache. A failed wait sets
`HEALTH_FAILED`, so `install.sh` exits non-zero, logs `install_failed
reason=healthcheck`, and does NOT log `install_success`. The bootstrap then stops
with exit `7` instead of cutting over an unhealthy Hermes. `OpenHands` and the
status page still only warn. If the wait keeps failing, run `./doctor.sh`, then
check the Hermes container logs.

### `OPENHANDS_WORKSPACE is ... a protected directory` after bootstrap

`scripts/setup-agent-workspace.sh` and `scripts/sync-agent-repos.sh` refuse a
workspace or repo tree that is inside `HYBRID_AI_DATA_DIR`. The bootstrap now
renders these two paths as SIBLINGS of the data dir, `/var/lib/hybrid-ai-agent`
and `/var/lib/hybrid-ai-repos`, never as `/var/lib/hybrid-ai/agent-*`. A run
against a tree that an earlier, wrong bootstrap left under `/var/lib/hybrid-ai/`
moves the misplaced `agent-workspace` / `agent-repos` child up to its sibling with
a same-device rename before the hand-off. If BOTH the child copy and the sibling
copy hold data, the re-run refuses with exit `6` before any move: merge them by
hand, empty one, then re-run. See
[`openhands/README.md`](../openhands/README.md).

---

## Relocated paths (split layout)

Every host path resolves through `scripts/lib/hybrid-ai-env.sh`. If you set
`HYBRID_AI_APP_DIR`, `HYBRID_AI_ENV_FILE`, `HYBRID_AI_STACK_ENV_FILE`,
`HYBRID_AI_DATA_DIR`, `HYBRID_AI_LOG_DIR` or `HYBRID_AI_WORK_DIR` (in the
environment or the env file), a mistake shows up as one of these:

| Symptom | Cause | Fix |
|---|---|---|
| `hybrid-ai-env: ... must be an absolute path` (or whitespace / `:` / `,` / `/`) | A relocated path is relative or contains a forbidden character | Use a plain absolute path. The helper refuses the value rather than guessing |
| `hybrid-ai-env: ... exists and cannot be read. refusing to fall back to the built-in defaults` | `HYBRID_AI_ENV_FILE` or `HYBRID_AI_STACK_ENV_FILE` names a file that exists but this user cannot read | Fix the file's permissions, or run as a user that can read it. The helper fails closed rather than silently using the wrong paths |
| `doctor.sh` prints `<NAME> = <path>` then warns it does not exist | The setting is named but the directory was never created | Create the directory, or unset the setting to fall back to the default |
| Compose cannot find the env file | The stack file moved, or `HYBRID_AI_STACK_ENV_FILE` is unset while compose reads a different file | Point `HYBRID_AI_STACK_ENV_FILE` at the file compose and the installer share. With it unset it defaults to `HYBRID_AI_ENV_FILE` |
| `HYBRID_AI_BACKUP_CRED_DIR is inside ...` | Backup credentials were placed inside the app, data or work tree | Move `HYBRID_AI_BACKUP_CRED_DIR` (in user mode, `BACKUP_CONF_DIR`) outside every relocated tree |
| `OPENHANDS_WORKSPACE is ... a protected directory` | The workspace is, is inside, or contains a relocated tree | Use a sibling path outside every tree that holds credentials or state |

`./doctor.sh` is the quick check: it prints each resolved path (never a value from the env
file) and warns about any set path that does not exist.

### The layout fallback on a bootstrapped host

When `HYBRID_AI_ENV_FILE` is unset and `$HYBRID_AI_APP_DIR/.env` does not
exist, the helper falls back to the host LAYOUT file
`/etc/hybrid-ai/hybrid-ai.env` if that file exists. This is what makes a bare
`sudo /opt/hybrid-ai/doctor.sh --no-cloud` report the paths the units actually
use: the layout file is read, so `HYBRID_AI_BACKUP_MODE=system` takes effect,
`BACKUP_LOG` resolves to `/var/log/hybrid-ai-backup/backup.log`, and
`HYBRID_AI_BACKUP_CRED_DIR` resolves to `/etc/credstore/hybrid-ai-backup`.

The fallback location is a named environment variable,
`HYBRID_AI_ENV_FILE_FALLBACK` (default `/etc/hybrid-ai/hybrid-ai.env`). An
explicit `HYBRID_AI_ENV_FILE` always wins and the fallback is then never
consulted; an existing `$HYBRID_AI_APP_DIR/.env` is never replaced. Only the
`0644` layout file is probed -- never the `0600` secrets file.

Bare invocations on a bootstrapped host need root or an explicit
`HYBRID_AI_ENV_FILE`. As root, `sudo ./doctor.sh --no-cloud` reads the layout
file and reports the system-mode paths. As a non-root account that cannot read
the layout file, the helper fails closed with the setting name and path (no
value) instead of silently using user-mode defaults. Pass the layout file
explicitly when you are not root:

```bash
HYBRID_AI_ENV_FILE=/etc/hybrid-ai/hybrid-ai.env ./doctor.sh --no-cloud
```


### The layout file and the stack file

Two files matter here. `HYBRID_AI_ENV_FILE` is the LAYOUT file: it holds path
and identity settings only, never a secret. `HYBRID_AI_STACK_ENV_FILE` is the
STACK file: the one handed to `docker compose --env-file`, alongside the three
compose files (`docker-compose.yml`, `openhands/docker-compose.openhands.yml`
and `hermes/docker-compose.hermes.yml`); `install.sh` writes it, and it holds the
secrets. On a bootstrapped host the layout file
is `/etc/hybrid-ai/hybrid-ai.env` and the stack file is
`/etc/hybrid-ai/stack.env`; they are separate files, and `install.sh` writes ONLY
the stack file. When `HYBRID_AI_STACK_ENV_FILE` is unset the two resolve to the
same path, which is today's single-file behaviour.

For the settings that decide host paths and the stack's identity
(`HYBRID_AI_UID`, `HYBRID_AI_GID`, `OPENHANDS_WORKSPACE`, `AGENT_REPOS_DIR`,
`OPENHANDS_STATE_DIR`), the LAYOUT file wins. `install.sh` reads the stack file
for runtime config and secrets, then restores those settings from the layout
file before it writes the new stack file. This matters after a migration: the
legacy `.env` becomes the stack file and still carries the OLD values (an empty
`HYBRID_AI_UID=`, the login account's workspace paths). Without the restore, the
empty id would make the whole stack run as uid 0 and the old paths would point
the containers at trees the migration had already moved away.

If the whole stack unexpectedly runs as root (`docker compose --env-file .env -f
docker-compose.yml -f openhands/docker-compose.openhands.yml -f
hermes/docker-compose.hermes.yml ps` shows `root` for the Hermes or status
container), check `HYBRID_AI_UID` in the layout
file, then confirm the stack file's copy after the next `install.sh` run matches
it.

### `HYBRID_AI_STACK_ENV_FILE` names the root-only secrets file on a deploy

Symptom: a deploy fails and the run log shows

```
hybrid-ai-env: HYBRID_AI_STACK_ENV_FILE is set to /etc/hybrid-ai/stack.env, but that file exists and cannot be read.
hybrid-ai-env: refusing to fall back to the built-in defaults.
```

The forced command runs as `hybrid-ai-deploy`, which cannot read
`/etc/hybrid-ai/stack.env` (mode `0600`, root-only). A helper that resolves host
paths fails closed when a named env file exists but this account cannot read it,
so the deploy stops before the unit starts.

Cause: a deploy-side caller exported or consumed the root-only secrets path
(`/etc/hybrid-ai/stack.env`) instead of the `0644` LAYOUT file
(`/etc/hybrid-ai/hybrid-ai.env`). Because `HYBRID_AI_STACK_ENV_FILE` is read from
the environment before the layout file, an inherited value pointed the helper
back at the file this account is deliberately not allowed to read.

Fix: the forced command now pins `HYBRID_AI_STACK_ENV_FILE` at the layout file
unconditionally, so it reads only paths it is allowed to read and never the
`0600` secrets file. Check that the deploy caller passed
`HYBRID_AI_ENV_FILE=/etc/hybrid-ai/hybrid-ai.env` (or nothing, in which case the
helper falls back to the default layout file `/etc/hybrid-ai/hybrid-ai.env` when
`$HYBRID_AI_APP_DIR/.env` does not exist) and did not export
`HYBRID_AI_STACK_ENV_FILE`. Do NOT grant the deploy account read access to
`stack.env` -- not by mode, group or ACL. The fix belongs in the forced command,
not in the secrets file's permissions.

---

## Manual triage

If you prefer to check by hand, or `doctor.sh` itself will not run, these five commands isolate the failing layer. The first one that fails tells you which section to read.

The stack is three compose files, always applied together and in this order:
`docker-compose.yml`, `openhands/docker-compose.openhands.yml` and
`hermes/docker-compose.hermes.yml`. Every compose command must pass all three,
with `--env-file` naming the stack env file; the commands below run from the repo
root. (The code passes `--project-directory` explicitly; compose otherwise uses
the current directory.) A command that omits either overlay does not see those
services, so an
`up -d --remove-orphans` run DELETES the OpenHands and Hermes containers:
compose treats them as orphans.

```bash
# 1. Are the containers running?
docker compose --env-file .env \
  -f docker-compose.yml \
  -f openhands/docker-compose.openhands.yml \
  -f hermes/docker-compose.hermes.yml ps

# 2. Is the web UI responding?
curl -fsS http://localhost:3000/health && echo " OK"

# 3. Is the local model engine responding?
curl -fsS http://127.0.0.1:11434/api/tags | jq '.models[].name'

# 4. Is the tailnet up, and is the pod known?
tailscale status | grep -E 'runpod-|^100\.'

# 5. Is the GPU pod awake and serving?
source .env && curl -fsS --max-time 5 "http://${TAILSCALE_IP}:8000/v1/models" | jq .
```

| Fails at | Go to |
|---|---|
| 1 | [Containers](#containers) |
| 2 | [Open WebUI](#open-webui) |
| 3 | [Ollama](#ollama-local-models) |
| 4 | [Tailscale](#tailscale-networking) |
| 5 | [Cloud pod](#cloud-gpu-pod) — often expected; the pod is stopped by design |

Step 5 failing with "connection refused" is **normal** when you have not used the cloud model recently. That is the pod saving you money.

---

## Containers

**Nothing listed by the three-file compose `ps`** (`docker-compose.yml` plus the
`openhands/docker-compose.openhands.yml` and `hermes/docker-compose.hermes.yml`
overlays)

You are probably in the wrong directory, or `.env` does not exist.

```bash
cd ~/hybrid-ai
ls -la .env || ./install.sh
```

**`permission denied while trying to connect to the Docker daemon`**

Your user is not in the `docker` group, or you have not logged out since being added.

```bash
sudo usermod -aG docker "$USER"
exit          # log out and back in -- newgrp is not sufficient
```

**A container is stuck in the `paused` state**

A backup was interrupted partway through its capture. Resume it:

```bash
docker unpause open-webui
```

`backup.sh` normally unpauses from its EXIT trap even on failure, so this is rare — but a hard kill (`kill -9`, power loss) can leave it frozen.

**A container restarts in a loop**

```bash
docker compose --env-file .env \
  -f docker-compose.yml \
  -f openhands/docker-compose.openhands.yml \
  -f hermes/docker-compose.hermes.yml logs --tail 100 open-webui
docker compose --env-file .env \
  -f docker-compose.yml \
  -f openhands/docker-compose.openhands.yml \
  -f hermes/docker-compose.hermes.yml logs --tail 100 ollama
```

Most common causes: the disk is full, or `.env` is missing a required value.

**`no space left on device`**

```bash
df -h /
docker system prune -a --volumes=false   # safe: does not touch bind mounts
du -sh webui_data ollama_data
docker exec -it ollama ollama list       # unused models are usually the culprit
```

Note `--volumes=false`. Your data is in bind mounts, not Docker volumes, so this is safe — but get in the habit of being explicit.

**Full reset without losing data**

```bash
docker compose --env-file .env \
  -f docker-compose.yml \
  -f openhands/docker-compose.openhands.yml \
  -f hermes/docker-compose.hermes.yml down      # NEVER add -v
./install.sh
```

**Permission errors after switching Hermes to a non-root uid**

The Hermes image now runs as a dedicated non-root uid when `HYBRID_AI_UID` is
set in `.env`. If the files under `hermes_data` were still created by root, the
non-root process cannot read or write them. You see this as `permission denied`
in the Hermes logs, or as a failed start.

`install.sh` refuses to start in this state and reports a count of files, not
their names. `./doctor.sh` warns about it too. The fix is to give the uid
ownership of the data directory:

```bash
# Set to the same value as HYBRID_AI_UID in .env.
sudo chown -R 10001:10001 hermes_data
./install.sh
```

To undo the switch, comment out `HYBRID_AI_UID` and `HYBRID_AI_GID` in `.env`
(leave them unset). Hermes then runs as uid 0 again, exactly as before the
migration.

---

## Open WebUI

**Cannot reach the page from another device**

```bash
curl -fsS http://localhost:3000/health       # works locally?
tailscale ip -4                              # use THIS address from elsewhere
```

If it works locally but not remotely, the other device is not on your tailnet.

**Logged out after a deploy**

`WEBUI_SECRET_KEY` changed. It should never change — `install.sh` reuses it. Check whether `.env` was deleted or regenerated from scratch.

**Forgot the admin password**

```bash
docker exec -it open-webui python -c "
from open_webui.apps.webui.models.auths import Auths
from open_webui.utils.utils import get_password_hash
Auths.update_user_password_by_id('YOUR_USER_ID', get_password_hash('newpassword'))
"
```

Find your user ID under **Admin Panel → Users**.

**Uploaded documents are not being found**

Ensure you selected the document (`#` in the message box) or attached the collection to the chat. Then check the vector store is actually growing:

```bash
du -sh webui_data/vector_db
```

If it is empty after uploading, embedding is failing. Check `docker compose --env-file .env -f docker-compose.yml -f openhands/docker-compose.openhands.yml -f hermes/docker-compose.hermes.yml logs open-webui` for errors — on a 4 GB Pi this is usually memory pressure.

**Embedding is extremely slow**

Expected on a Pi. Mitigations: process fewer documents at a time, use a smaller embedding model, and ensure you are not thermally throttled:

```bash
vcgencmd measure_temp           # sustained >80C means throttling
vcgencmd get_throttled          # 0x0 is healthy
```

---

## Ollama (local models)

**No models listed**

```bash
docker exec -it ollama ollama pull llama3.2:3b
```

**Model download fails partway**

Usually disk space or a dropped connection. Re-running `pull` resumes.

**Responses are extremely slow**

Almost always the model is too large for the hardware — and the limit is **memory bandwidth, not RAM**. The Pi 5 has ~17 GB/s, and every token requires reading every weight, so:

| Model | Throughput on a Pi 5 | Usable interactively? |
|---|---|---|
| 1B | ~17–21 tok/s | Yes, very |
| **3B** | **~5–8 tok/s** | **Yes — the sweet spot** |
| 7–8B | ~1–3 tok/s | No, even with 16 GB |

A 16 GB board *loads* an 8B model fine and still crawls. That is physics, not misconfiguration. Drop to 3B locally and send hard work to the GPU pod:

```bash
docker exec -it ollama ollama pull llama3.2:3b
docker exec -it ollama ollama rm llama3.1:8b     # reclaim the space
```

Other things worth checking:

```bash
./doctor.sh                       # flags oversized models and SD-card boot
vcgencmd measure_temp             # sustained >80C means throttling
findmnt -n -o SOURCE /            # mmcblk = SD card; NVMe is much faster
docker stats --no-stream          # is something else eating CPU?
```

**Booted from the wrong disk.** If you installed an NVMe drive but the Pi still boots the SD card, everything runs at SD speed while the SSD sits idle:

```bash
findmnt -n -o SOURCE /                      # want nvme0n1..., not mmcblk...
sudo rpi-eeprom-config | grep BOOT_ORDER    # NVMe should come first
```

Fix with `sudo raspi-config` → Advanced Options → Boot Order → NVMe/USB Boot.

**First response slow, later ones fast.** Normal — the model is loading from disk. On 16 GB `install.sh` sets a 30-minute keep-alive so it stays resident. NVMe makes the initial load several times faster.

**Long conversations get truncated.** Ollama caps every model at 4096 tokens unless told otherwise. `install.sh` raises `OLLAMA_CONTEXT_LENGTH` based on RAM (16384 at 16 GB); increase it in `.env` and re-run `./install.sh` if needed, at the cost of KV cache memory.

If conversations still truncate at 4096 after that, the **pinned Ollama image
is too old to honour the variable** — it is accepted and ignored. `install.sh`
now checks for this after start and warns. Confirm and fix:

```bash
docker exec ollama ollama --version
grep OLLAMA_IMAGE .env          # bump to a current release, then ./install.sh
```

**Ollama panics on model load: `V cache quantization requires flash_attn`.**
`OLLAMA_KV_CACHE_TYPE=q8_0` requires flash attention to be active. When Ollama
auto-disables flash attention for a model architecture that does not support
it, the runner aborts rather than degrading. The default is now `f16`; if you
opted into `q8_0`, revert it in `.env` and re-run `./install.sh`.

**`model requires more system memory than is available`**

```bash
free -h
grep -E 'OLLAMA_MEM_LIMIT|OLLAMA_CONTEXT_LENGTH' .env
docker stats --no-stream ollama
```

`OLLAMA_MAX_VRAM` no longer exists anywhere in this project — it was never
honoured by Ollama and has been removed upstream. The real ceiling is
`OLLAMA_MEM_LIMIT`, a kernel-enforced Docker cgroup limit, which `install.sh`
sets conservatively and deliberately. Use a smaller model rather than raising it — exceeding physical RAM pushes the Pi into swap, which is dramatically worse than simply using a smaller model — even on NVMe.

---

## OpenHands maintenance agent

OpenHands is optional. Chat, the cloud pipe and backups all work without it,
so `install.sh` warns rather than failing when it does not come up.

**`OpenHands workspace ACLs not applied` during a deploy.** That warning comes
from `prepare_openhands_workspace`, which runs `docker pull` on the pinned
agent-server image before it applies the workspace ACLs. If the pull fails — for
example because the deploy raced the image build and the tag's manifest was not
published yet — the ACL step is skipped and the warning prints. The deploy
workflow now gates on the image manifest before it triggers the remote install:
`scripts/deploy-image-gate.sh` polls GHCR for the tag pinned by `install.sh`
STEP 8 and fails closed if it never appears, so a deploy can no longer start
against a missing image. If you still see the warning, the host's own
`OPENHANDS_AGENT_IMAGE_TAG` in `.env` may differ from the repo default the gate
checks (the gate does not read a host-customised tag); confirm the tag exists
with `docker manifest inspect <repo>:<tag>` and re-run
`./openhands/scripts/openhands-control.sh start`.

**The container vanished after a deploy or re-install.** Almost certainly a
`docker compose up -d --remove-orphans` that omitted one of the two overlay
files (`openhands/docker-compose.openhands.yml` or
`hermes/docker-compose.hermes.yml`), which makes compose treat OpenHands as an
orphan and delete it. State in
`~/.openhands` survives, so recovery is just a start:

```bash
./openhands/scripts/openhands-control.sh start
```

Use that wrapper rather than bare `docker compose` — it always passes all three
files (`docker-compose.yml`, `openhands/docker-compose.openhands.yml` and
`hermes/docker-compose.hermes.yml`).

**`OPENHANDS_WORKSPACE must be set`.** The overlay deliberately has no default
for the workspace, so it fails loudly rather than silently mounting the
deployment directory (which holds `.env`). Run `./install.sh`, or create the
clone by hand:

```bash
./scripts/setup-agent-workspace.sh
./scripts/setup-agent-workspace.sh --check
```

**`SECURITY: .env found inside the agent workspace`.** Something copied rather
than cloned. Remove the file — its presence defeats the isolation the separate
workspace exists to provide.

**The workspace-root `AGENTS.md` looks stale.** `setup-agent-workspace.sh`
refreshes the existing clone on every run: it fetches, then fast-forwards only
when the tree is clean and on the default branch. If it warns that it skipped
the refresh, the clone is dirty or on another branch, or the fetch failed — it
never resets or discards work. Bring it up to date by hand, or re-run:

```bash
./scripts/setup-agent-workspace.sh
```

**A multi-repo job edits the wrong tree.** The workspace root
(`${OPENHANDS_WORKSPACE}`) is a hybrid-ai clone holding `AGENTS.md`; it is not
the target of a job unless the task says so. A job on another owned repository
is cloned into `${OPENHANDS_WORKSPACE}/project/<repo-name>`, and the agent
works only inside that clone. Repositories do not all use `main`, so the agent
fetches and branches from the remote default branch rather than a local `main`
or `master`.

**The UI will not load.** It binds to loopback only and there is no Caddy
route, by design. Reach it through a tunnel:

```bash
ssh -L 3001:127.0.0.1:3001 <user>@<pi-tailnet-name>
./openhands/scripts/openhands-control.sh logs
```

**First start times out.** The image is large and the first pull on a Pi can
exceed the health-check window. Watch the pull, then re-check.

**`500: Sandbox entered error state` on every dispatch.** The app-server gives a
new sandbox only its built-in startup grace to answer `/health` (15 s in the
1.10 build), but this Pi's agent-server answers at ~21 s. A start that loses
that race is marked terminally `ERROR` and never recovers, so every dispatch
fails. The circuit is `OPENHANDS_STARTUP_GRACE_SECONDS`, which the overlay
passes to the app-server as `SANDBOX_STARTUP_GRACE_SECONDS`.

| Symptom | Cause | Fix |
|---|---|---|
| `500: Sandbox entered error state` on builder dispatches | Startup-grace race: the app-server's built-in 15 s grace expires before this Pi's agent-server answers `/health` at ~21 s | Set `OPENHANDS_STARTUP_GRACE_SECONDS` (default 120) in `.env`, then: `./openhands/scripts/openhands-control.sh start`. Keep it in `openhands/docker-compose.openhands.yml` so a deploy cannot revert it. |
| Doctor warns that sandbox starts were marked terminally ERROR | The same race, detected live: recent `app-conversations/start-tasks/search` rows are `ERROR` with `Sandbox entered error state` | Same as above. The warning is advisory only; it never fails the deploy. |

The start-tasks timestamps are offset-less UTC (e.g. `2026-10-18T22:03:34.402382`),
so doctor.sh parses them with `date -u -d`; a naive `date -d` would read them in
the host's local zone and count stale rows as recent.

---

## Sandbox ports reachable from the LAN

OpenHands publishes each sandbox agent server on a random host port. Without rules in
Docker's `DOCKER-USER` chain, Docker forwards those ports from every interface, so a client
on the LAN or the tailnet can reach a running sandbox. `scripts/sandbox-firewall.sh` closes
that with a tagged rule set: an inbound DROP into `docker0`, four CIDR DROPs for the RFC1918
supernets and the tailnet/CGNAT range, a per-bridge DROP onto the stack networks, the
per-bridge ACCEPTs the app and the sandboxes need, and two port-53 ACCEPTs for sandbox DNS.

**What the doctor warning means.** A line like

```
! Sandbox firewall: DOCKER-USER is missing the DROP from external interfaces into docker0, so sandbox ports may be reachable from the LAN
```

means at least one of the tagged rules is not in the chain. What a missing rule costs:

- a missing DROP from external interfaces into `docker0` leaves the sandbox ports open;
- a missing CIDR DROP lets a sandbox reach the LAN or the tailnet;
- a missing DROP from `docker0` to other Docker networks lets a sandbox pivot onto the stack
  networks;
- a missing ACCEPT on the app path (the control ports, or sandbox to app on TCP 3000) breaks
  conversation creation: the secret fetch and the webhook delivery both fail;
- a missing DNS ACCEPT is not an exposure. It breaks sandbox DNS: the resolver answer comes
  from inside the dropped RFC1918 space, so without that ACCEPT the sandbox still reaches
  READY, then records `prompt_tokens: 0` with no actions.

`doctor.sh` counts this as a warning, so the run exits 1, never 2. It is read-only: it never
inserts, appends, deletes or flushes a rule.

**The remedy.** As root, on the host:

```bash
sudo ./scripts/sandbox-firewall.sh apply
```

The script is idempotent — it adds only what is missing and leaves every other rule
untouched. It never deletes, flushes or removes a chain.

**The note about a tagged rule.** `apply` may print a line like

```
sandbox-firewall: note: a rule tagged hybrid-ai-sandbox-egress in DOCKER-USER is not part of the current policy ...
```

That note is informational: the tagged rule is outside today's policy, from an older release
or differing only in how `iptables -S` prints it. The script never deletes it, so do not
delete it by hand; inspect the chain with `iptables -S DOCKER-USER` and raise it as an item.

Re-running `./install.sh` also applies it, and so does a deploy.

For the boot unit, `install.sh` installs and enables `hybrid-ai-firewall.service` on
every deploy, so a normal deploy leaves it enabled and it re-applies the rules after
`docker.service` on every boot. Re-run `./install.sh` as root (or reboot) to pick that up.
The manual command below is the fallback for a host that has not deployed since the
unit was added, or where the install step warned (for example it ran without root):

```bash
sudo systemctl enable --now hybrid-ai-firewall.service
```

**Verify by hand.** The chain is root-owned, so this needs `sudo`:

```bash
sudo iptables -S DOCKER-USER
```

You should see 14 rules for the two bridges carrying `--comment "hybrid-ai-sandbox-egress"`:
one conntrack ACCEPT, four per-bridge ACCEPTs (control ports and TCP 3000), two per-bridge
DROPs, four CIDR DROPs, the two `--dport 53` ACCEPTs, and the final inbound `! -i lo -o
docker0` DROP. The two `--dport 53` ACCEPTs must appear above all four CIDR DROPs; if they
do not, sandbox DNS is broken and the script's ordering self-check will fail once it runs.
`hybrid-ai-firewall.service` exits non-zero when the script cannot apply them (for example,
Docker has not created `DOCKER-USER` yet), so a failure stays visible in `systemctl status
hybrid-ai-firewall` rather than passing silently.

**What a SKIPPED check means.** A dim line such as

```
- sandbox firewall check skipped (iptables not installed)
```

is not a failure and not a warning. It means the check could not read the chain, so it
counted nothing and left the exit code exactly as it would have been. The reasons are:

| Skip reason | Meaning |
|---|---|
| `not a Linux host` | `uname -s` is not Linux, so there is no iptables to read. |
| `iptables not installed` | No `iptables` binary on `PATH`. Install it, or check on the Pi itself. |
| `cannot read DOCKER-USER (needs root, or Docker is not up)` | The probe was refused — usually a non-root run, or Docker has not created the chain yet. Re-run with `sudo`, or start Docker. |
| `empty DOCKER-USER listing` / `unexpected DOCKER-USER listing` | The output could not be parsed, so the check declines to guess. |

To read the chain on a host where the check skipped, use `sudo iptables -S DOCKER-USER`
directly.

---

## `fatal: detected dubious ownership in repository at '/workspace/project/...'`

Git inside an OpenHands sandbox refuses the mounted workspace and exits 128.

Cause: the sandbox runs as the image's unprivileged uid (10001), while the bind-mounted
workspace is owned by the host account. Git compares uids, not permissions, so it rejects the
repository. `sudo git` fails the same way, because git compares the process uid. The
`SANDBOX_USER_ID` line in the overlay is inert — app-server 1.10.0 and agent-server 1.37.1 never
read it.

The shipped fix is a system git config. `install.sh` copies the source file
`openhands/sandbox-gitconfig` to `$OPENHANDS_WORKSPACE/.sandbox-gitconfig` with mode `0644`,
chowned to the stack uid/gid, and the overlay bind-mounts it read-only at `/etc/gitconfig` in
every new sandbox. It lists the two workspace roots and nothing else:

```ini
[safe]
	directory = /workspace
	directory = /workspace/project/*
```

Verify in a fresh sandbox:

```bash
docker exec <sandbox> git -C /workspace/project/hybrid-ai remote -v   # exits 0
docker exec <sandbox> git -C /workspace/project/hybrid-ai merge-base origin/main HEAD
```

If you still see this, the sandbox predates the fix or the mount is missing. Re-run
`./install.sh`, then start a new conversation: an existing sandbox keeps the mounts it was
created with.

Do not use `safe.directory '*'`. It marks every repository on the system trusted, including any
untrusted clone. Do not edit `.git/config` — the config is a system file, mounted read-only.

---

## Agent clone embeds a credential in its git remote

`./doctor.sh` fails for every agent clone whose git config stores a
credential inside a remote URL:

```
✗ Credential embedded in a git remote: <path>/.git/config: remote.origin.url
```

Only the file path and the config key are shown. The URL, the userinfo and the
token are never printed — not on stdout, not on stderr. `scripts/check-git-remotes.sh`
is the read-only check behind the failure; it scans the roots named by
`OPENHANDS_WORKSPACE` (its root clone and `project/*/`) and `AGENT_REPOS_DIR`
(`*/`), to a depth of four, and never follows a symlink.

This is a failure, not a warning. As of the agent-server `1.37.1` upgrade the
token is no longer written into clone URLs, so a credential still on disk is a
defect rather than a tolerable legacy artefact: `doctor.sh` exits `2` and the
deploy step exits `4` (red). An unreadable `.git/config` or a missing check
script is still only a warning — neither proves a credential is present.

**What the failure means.** OpenHands' app-server clones with a URL of the form
`https://<token>@github.com/<owner>/<repo>.git`. Git writes that URL verbatim
into `project/<repo>/.git/config` as `remote.<name>.url` (and sometimes
`pushurl`, or a `url.<base>.insteadOf` shim). The token is therefore sitting on
disk in plain text. Anyone who can read that file can read the token.

**Rotate the token in GitHub.** The credential is already on disk, so treat it
as exposed. In GitHub, open **Settings → Developer settings → Personal access
tokens** and revoke the OpenHands token, then create its replacement with the
same read-only scope (see the OpenHands token column in
[`SECURITY.md`](../SECURITY.md#github-credential-separation)). Put the new value
in `OPENHANDS_GITHUB_TOKEN` (or wherever the deploy supplies it) and restart
OpenHands. Because the token is read-only, the blast radius of the leak is
read access to the repositories it can see, not write access.

**Why hand-stripping does not hold.** Editing the URL out of `.git/config` by
hand fixes the file that exists right now. The next time OpenHands clones or
re-clones that project — which the agent-server does on demand — it writes the
`https://<token>@...` URL straight back. The strip looks like a fix for a few
minutes and then silently regresses. That is why detection, not removal, is the
control until the upgrade.

**The real fix: upgrade the agent-server.** An OpenHands agent-server at
**`1.37.0` or newer** stops embedding credentials in the clone URL and uses a
credential helper instead, so nothing sensitive lands in `.git/config`. That
pin has now shipped: the stack defaults to agent-server
**`1.37.1-python-hybrid.3`** and app-server **`:1.10`**. The default repository is
the derived hybrid image
`ghcr.io/jimbobsyouruncle/openhands-agent-server-hybrid` (it adds
shellcheck/semgrep/sqlite3/rsync/restic on top of the stock agent-server), not the
canonical `ghcr.io/openhands/agent-server`: the app server reserves the canonical
repository for its own bundled SDK version and silently re-pins the tag when it is
set, so a non-canonical repository lets the tag take effect. The hybrid image
installs the pinned ShellCheck **0.11.0** binary to `/usr/local/bin/shellcheck` so
the sandbox PATH matches the CI gate's version (`ludeeus/action-shellcheck` 2.0.0,
track `stable`), and the pinned Semgrep **1.179.0** wheel so it matches the SAST
gate (`semgrep/semgrep:1.179.0`); apt's older shellcheck package is deliberately
not used.

On upgrade, `install.sh` STEP 2b unsets one exact stale value at a time; STEP 8's
`${VAR:-default}` then writes the current default in its place. It clears the
stale app-server pin `docker.openhands.dev/openhands/openhands:1.8`, the stale
agent tag `1.26.0-python` and the canonical agent repository
`ghcr.io/openhands/agent-server`. Three migrations match the repository and tag
as a PAIR, so a host that customised either half keeps its owner-chosen pin: the
OLD default pair (`docker.openhands.dev/openhands/agent-server` AND
`1.37.1-python`), and the earlier hybrid tags `1.37.1-python-hybrid.1` and
`1.37.1-python-hybrid.2` (bumped to the current hybrid.3 default). Any other
repository or tag is an owner pin and is left untouched, and STEP 8 preserves an
explicit owner value too. A clone made before the upgrade can still carry a stale
embedded credential, so rotate the token and re-check to confirm the old value is
gone.

---

## Agent repo reference tree: inventory rows and skips

`scripts/sync-agent-repos.sh` keeps the read-only reference tree at
`AGENT_REPOS_DIR` and writes `${AGENT_REPOS_DIR}/INVENTORY.md` after each run.
`install.sh` runs it near the start of every deploy, before it loads `.env`, so
the tree is current even if a later install step fails or stops. A sync failure
is only a warning; `install.sh` carries on.
Each row is one repository with its default branch, HEAD short SHA, status and
last sync time (UTC). The status is exactly one of:

| Status | Meaning |
|---|---|
| `cloned` | The repo was missing and is now cloned. |
| `updated` | An existing clone fast-forwarded to a newer default-branch commit. |
| `up-to-date` | An existing clone was already at the remote head; nothing changed. |
| `skipped:<reason>` | Left untouched this run. The reason is `dirty`, `symlinks`, `credential-remote`, or `not-a-repo`. |
| `error` | A clone or fetch failed, or a git config could not be read. |
| `stale` | Present on disk but no longer in the inventory (for example a repo you excluded in the manifest). Left in place; never deleted. |

A normal run exits `0` when all is well, `1` when anything was skipped, and `2`
on any error. A `stale` row on its own does not change the exit code: the run
warns and still exits `0`, because a stray clone is only informational there and
is never deleted. Verify the tree without touching it or the network:

```bash
./scripts/sync-agent-repos.sh --check
```

`--check` reads `INVENTORY.md` and confirms each listed directory exists and its
HEAD still matches. It exits `0` ok; `1` when the inventory is older than
`AGENT_REPOS_MAX_AGE_HOURS` (default 48) or a skipped row is present; `2` when a
directory is missing, a HEAD mismatches, or the inventory is missing or
unreadable. `doctor.sh` runs this and warns (never fails) on anything but `0`.

**`skipped:dirty`.** The clone has uncommitted changes. This script only
fast-forwards and never discards work, so it leaves the tree alone. Commit or
discard the changes, or delete the clone and let the next run re-clone it.

**`skipped:symlinks`.** The clone's working tree contains a symlink. Clones are
made with `core.symlinks=false` so a repository cannot plant a symlink that
points outside the tree, but an older clone may already hold one. The script
never deletes anything, so it skips the repo and records the reason. Re-clone
that one repository by hand: delete the offending clone directory and run the
sync again, or `git clone` it yourself. Do not delete the whole tree.

**`skipped:credential-remote`.** A remote URL in the clone's git config embeds
a credential. The script refuses to fetch from it. Rotate the token in GitHub
(see the section above), then delete and re-clone that repository so the stored
URL is replaced.

**`stale`.** The directory is on disk but is no longer in the inventory, usually
because it was excluded in `agent-repos.local`. It is left in place and never
deleted; remove it by hand if you no longer want it there. A run that finds only
stale directories prints the `stale:` warning, records the row and reports it in
the totals, but still exits `0`. `--check` is what enforces staleness: it exits
`1` while a `stale` row is present in a fresh inventory.

---

## Kanban board not dispatching / gateway not running

The Hermes WebUI and the Hermes gateway run in the same container. The WebUI is PID 1; the
gateway runs in the background and drains the kanban queue. Nothing supervises the background
job, so if the gateway exits the board stops dispatching while the WebUI keeps serving. The
gateway is not restarted until the container restarts.

`./doctor.sh` reports this as a warning against `hermes-agent`:

```
Hermes gateway process NOT running inside hermes-agent
```

Confirm it by hand with a read-only probe — look for a "gateway run" process:

```bash
docker top hermes-agent
```

**`Profile '<name>' does not get a gateway of its own`** in `docker logs hermes-agent`.
A sticky named active profile (for example `ciso`) stored in the bind-mounted
`hermes_data/active_profile` captures a bare `hermes gateway run` and is refused a
gateway, because there is only one gateway per host and it is owned by the default
profile. The fix is already pinned in the image `CMD` (the compose overlay sets no
`command:`): `hermes -p default gateway run --replace`. Do not switch the active profile
back to `default` by hand; the `-p default` pin makes the gateway start as the default
profile after every container create/recreate regardless of the sticky active profile.

**Fix: recreate the container.** Recreating restarts the gateway in the background and leaves the
kanban data in `hermes_data/` untouched:

```bash
${COMPOSE_CMD} up -d --force-recreate hermes
```

`${COMPOSE_CMD}` is the full compose invocation `doctor.sh` uses (project `hybrid-ai`, all three
compose files). Recreate rather than `docker exec` into the container: the background gateway is
what the image `CMD` starts, and an `exec`ed one is not tracked as that process.

---

## The Hermes image at a pinned commit: smoke-job failure modes

The `hermes-nonroot-smoke` CI job builds `hermes/Dockerfile` and runs the image as uid
`10001` on a data volume seeded with a **decoy** agent (a valid Agent source root that would
leave a marker if imported). It runs on every pull request that can change the image — the
`changes` job diffs the PR base for `hermes/` and this workflow — and unconditionally on the
weekly schedule and manual dispatch. It fails closed on these modes. Each maps to one build or
configuration change.

| Symptom | Cause | Fix |
|---|---|---|
| The build fails on `sha256sum -c -` for `/tmp/hermes-install.sh` | The installer at `HERMES_COMMIT` no longer matches `HERMES_INSTALL_SHA256`. Upstream rewrote `scripts/install.sh` at a tag, or the pin moved without the checksum. | Download `https://raw.githubusercontent.com/NousResearch/hermes-agent/<sha>/scripts/install.sh` and set `HERMES_INSTALL_SHA256` to its sha256. Never disable the check. |
| The build fails on `git rev-parse` for `/app`, or `--detach` fails | The WebUI clone at `HERMES_WEBUI_COMMIT` no longer resolves, or `main` moved. | Set `HERMES_WEBUI_COMMIT` to a commit that still exists and bump the matching string in `validate.yml`. Never clone `main` and never drop the `git rev-parse` assert. |
| The build fails on `test -x /opt/hermes-agent/.hermes/venv/bin/python` | `/opt/manifest.json` names no venv, or the venv has no interpreter. | The Agent install changed shape. Do not hand-edit the manifest; rebuild and re-check the Agent pin. |
| `git apply` fails, or `rev-parse HEAD` is not `HERMES_COMMIT` | The local patch no longer applies at the pin, or the checkout is at a different commit. | Rebase `patches/0001-kanban-prompt-body-chars.patch` onto the pinned commit, or bump `HERMES_COMMIT` deliberately. |
| `exec: /opt/hermes-agent/.hermes/bin/hermes: not found`, or the WebUI exits at once | The launcher is missing or not on `PATH`. The old failure was the launcher living under the `/root/.hermes` mount point, which the volume hid. | Confirm the build published `/opt/hermes-agent/.hermes/bin/hermes` and that `ENV PATH` names it. Never put the launcher under `/root` — that tree is `chown`ed to the runtime uid. |
| The login-shell step fails: `command -v hermes` is empty or not `/usr/local/bin/hermes` | The `/usr/local/bin/hermes` symlink is missing, or `PATH` no longer reaches `/usr/local/bin` in a login shell. | Keep the root-owned `ln -sfn ${HERMES_INSTALL_DIR}/.hermes/bin/hermes /usr/local/bin/hermes` step. A login shell rebuilds `PATH` from `/etc/profile`, so a shell-only prepend is not enough. |
| The gateway-not-running step fails (`docker top` finds no `gateway run`) | The image `CMD` did not start the gateway, or the profile pin was dropped. | Keep `hermes -p default gateway run --replace` in `hermes/Dockerfile`'s `CMD`. `validate.yml` asserts the exact string and fails closed if it is gone. |
| `bootstrap.py: error: unrecognized arguments: --port` | A `--port` flag was added. `bootstrap.py` takes the port **positionally**. | Use `... bootstrap.py --host 0.0.0.0 --foreground --no-browser --skip-agent-install 8501`. |
| `Hermes Agent was not found and auto-install was disabled.` and PID 1 exits | `--skip-agent-install` is set and the pinned agent was not found where `HERMES_WEBUI_AGENT_DIR` points. This is the intended fail-closed behaviour. | Confirm `HERMES_WEBUI_AGENT_DIR=/opt/hermes-agent` and that the agent installed. Never remove `--skip-agent-install`; without it bootstrap downloads an unpinned installer from `main`. |
| The PID 1 maps step reports a path under `/root/.hermes` | The WebUI resolved the agent dir or interpreter from the data volume (the old copy). | Confirm `HERMES_WEBUI_AGENT_DIR` and `HERMES_WEBUI_PYTHON` are set in the image ENV and that the `/opt/hermes-agent/.hermes/venv` symlink exists. Do not delete the data-volume copy to make this pass — pin the image instead. |
| The dependency-lease step fails: `HERMES_HOME` is under `/opt` | `HERMES_HOME` was pointed at the read-only install dir, moving the runtime generation lease (`installs/<key>/environments/<uuid>/.leases`) off the writable volume. | Leave `HERMES_HOME` unset so `get_default_hermes_root()` falls back to `$HOME/.hermes`. Never make `/opt` writable to route around it. |
| The decoy-marker step finds `/root/.hermes/DECOY_AGENT_IMPORTED` | The WebUI imported the data-volume copy. Same cause as the row above. | Same fix. The marker must never appear. |
| `Python environment cannot import both WebUI dependencies and Hermes Agent, and local .venv creation is disabled` | The pinned interpreter (`HERMES_WEBUI_PYTHON`) cannot import `run_agent` and a YAML backend. | This is the intended fail-closed path (`HERMES_WEBUI_DISABLE_LOCAL_VENV=1`); without it bootstrap would create `/app/.venv` at runtime. Re-check the Agent pin and the `/opt/manifest.json` venv. Do not re-enable the local venv. |
| The `docker diff` step reports paths under `/app` or `/opt` | The runtime uid wrote under the WebUI or agent code: a git checkout (the image ships none), or missing build-time bytecode. | Do not make the trees writable. Confirm the build byte-compiles `/app` and `/opt/hermes-agent` with the pinned interpreter and removes `.git`. If Hermes needs to write there, stop and report rather than loosen the tree. |

---

## Cards stay in Triage, gateway is running

A running gateway is not enough. With `kanban.auto_decompose` enabled, the decomposer picks up
each Triage card within about 60 seconds. If it cannot, cards stay in Triage and the board goes
quiet — with no error anywhere, because the gateway itself keeps running.

`./doctor.sh` reports the stall in the Containers section, naming the board and the affected task
ids only:

```
Kanban Triage stalled on board <board>: 2 task(s) older than 15m (ids: 41 57); 2 have no event other than 'created'
```

A card whose only event is `created` is the failure signature: the decomposer never touched it.
Tune the threshold with `DOCTOR_TRIAGE_STALL_MIN` (default 15 minutes, read from the environment,
not from `.env`):

```bash
DOCTOR_TRIAGE_STALL_MIN=5 ./doctor.sh
```

**Cause.** The decomposer runs on the Hermes auxiliary provider. When no GPU pod is warm it falls
back to OpenRouter, so a missing or blank `OPENROUTER_API_KEY` makes every decompose tick fail.
This is exactly what happened on 2026-10-13: the key was commented out in `hermes_data/.env` and
every 60s tick failed for about 35 minutes with no visible signal.

**Check the auxiliary provider and credential.** `doctor.sh` also warns when the deployment `.env`
or a board-running profile (`hermes_data/.env`, `hermes_data/profiles/builder/.env`,
`hermes_data/profiles/reviewer/.env`) has no OpenRouter key:

```
OPENROUTER_API_KEY is missing or empty in hermes_data/.env
```

```bash
hermes -p default config get auxiliary          # which provider the decomposer uses
grep -c '^OPENROUTER_API_KEY=' hermes_data/.env # 1 means the line is uncommented
```

**A board database that cannot be read** is reported instead of being treated as healthy:

```
Kanban Triage not stalled: cannot query board <board>
```

That means the kanban DB is corrupt, locked, not a SQLite file, or unreadable. Inspect it
read-only, for example: `sqlite3 "file:hermes_data/kanban/boards/<board>/kanban.db?mode=ro" 'PRAGMA quick_check;'`.

**Fix.** Restore the key in the relevant `.env` (see `.env.example` for the format), then recreate
the container so the gateway and decomposer pick it up:

```bash
${COMPOSE_CMD} up -d --force-recreate hermes
```

---

## Kanban PR-acceptance gate: `infra` verdict, "GitHub acceptance evidence unavailable"

When a card completes, the PR-acceptance gate
(`hermes_cli/kanban_pr_acceptance.py`) shells out to `gh api ...` to collect GitHub evidence.
If it cannot, it records the **`infra`** verdict with the message
`GitHub acceptance evidence unavailable`, and the card is not accepted on GitHub evidence. This
is a **fail-closed** behaviour and must not be relaxed. Two causes:

| Cause | Detail | Remedy |
|---|---|---|
| `gh` is missing | The gate runs inside the Hermes container, which previously shipped no `gh`. | Fixed by the image: `hermes/Dockerfile` installs a pinned `gh 2.103.0` at `/usr/local/bin/gh`. Rebuild/redeploy the image so the layer is present. Confirm with `docker exec hermes-agent gh --version`. |
| `gh` exits 4 | `gh` is present but unauthenticated: `GH_TOKEN` (or `GITHUB_TOKEN`) is absent from the **assignee profile's `.env`** (`hermes_data/profiles/<profile>/.env`). | Owner by-hand step: add the `GH_TOKEN` key to that profile `.env` through a masked prompt. Read-only scopes; no permission widening. Never place the value in a tracked file, image, branch, commit, or log. |

Check which cause applies, read-only:

```bash
docker exec hermes-agent gh --version          # exit 4 / "command not found" tells you which
docker exec hermes-agent gh auth status        # unauthenticated -> the token key is absent
```

Then recreate the container so the profile env is re-read:

```bash
${COMPOSE_CMD} up -d --force-recreate hermes
```

Do not work around this by disabling the gate, by widening any token scope, or by letting the gate
pass with no evidence. See [`../hermes/README.md`](../hermes/README.md) and
[`../SECURITY.md`](../SECURITY.md#github-credential-separation).

---

## Tailscale networking

**`tailscale status` reports `Stopped` or `NeedsLogin`**

```bash
sudo tailscale up
```

**The Pi's address changed**

Unusual, but it happens after certain account changes.

```bash
tailscale ip -4
```

Update the `PI_TAILSCALE_FULL_DOMAIN` GitHub secret if you use CI.

**`runpod-vllm` peer does not appear**

Expected when the pod is stopped — but the entry should persist even then. If it has vanished entirely, the ephemeral node was cleaned up. Start the pod once manually, then:

```bash
./install.sh
```

**The peer appears but is unreachable**

```bash
source .env
tailscale ping "$TAILSCALE_IP"
tailscale netcheck                   # diagnoses NAT / relay problems
```

If `tailscale ping` works but HTTP does not, vLLM has not finished starting. Check the pod's logs in the RunPod console.

**A hostname mismatch**

`TS_HOSTNAME` on the pod and `PEER_HOSTNAME` in `install.sh` must match. Both default to `runpod-vllm`. If you changed one, change the other.

---

## Cloud GPU pod

**"Cannot reach the inference pod"**

Work through it in this order:

```bash
# 1. Is the pod even known to the tailnet?
tailscale status | grep runpod-vllm

# 2. Does .env hold a plausible address?
grep TAILSCALE_IP .env          # must start with 100.

# 3. Is the pod running? Check the RunPod console.

# 4. Can we reach the model API?
source .env && curl -v --max-time 10 "http://${TAILSCALE_IP}:8000/v1/models"
```

**"Refusing to transmit: ... outside the Tailscale mesh range"**

Working as designed. `TAILSCALE_IP` is not a `100.64–127.x.x` address, which means prompts would leave the encrypted tunnel. Fix the address:

```bash
./install.sh
```

Do not disable `ENFORCE_MESH_ONLY` to make this message go away. It is the control preventing a silent data leak.

**Warm-up times out**

Cold starts legitimately take 2–5 minutes, longer without a persistent volume. Check the pod logs for:

```
[start.sh] Launching vLLM -- model=... tp=1 port=8000
```

If that line never appears, the failure is earlier — usually Tailscale auth or a missing GPU. If it appears but readiness never follows, the model is still downloading. Attach a 100 GB volume at `/workspace` so weights are cached between runs.

**The pod will not stop**

```bash
# Check the watchdog armed at boot -- look for this in the pod's logs:
#   [start.sh] Arming idle watchdog: 15 min @ 0% GPU -> podStop

# Force it:
source .env
# Key passed via header, not the URL -- URLs land in proxy and access logs.
curl -s -X POST "https://api.runpod.io/graphql" \
  -H "Authorization: Bearer $RUNPOD_API_KEY" \
  -H 'Content-Type: application/json' \
  -d "{\"query\":\"mutation{podStop(input:{podId:\\\"$RUNPOD_POD_ID\\\"}){id desiredStatus}}\"}"
```

If the watchdog never armed, `RUNPOD_API_KEY` is missing from the **pod template** — a different place from the Pi's `.env`.

**The pod stops while I am still using it**

The GPU was genuinely idle for 15 minutes — reading a long answer does not count as activity. The pipe wakes it again automatically. If the cold start is disruptive, raise `IDLE_MINUTES` on the pod, accepting the higher cost.

**Out-of-memory on startup**

Lower `GPU_MEM_UTIL` to `0.85`, reduce `MAX_MODEL_LEN` to `8192`, or move to a larger GPU.

---

## Cost control

**Verify the watchdog is armed.** After starting the pod, its logs must contain:

```
[start.sh] Arming idle watchdog: 15 min @ 0% GPU -> podStop
```

If instead you see `WARNING: ... idle watchdog DISABLED`, stop the pod immediately and add `RUNPOD_API_KEY` to the pod template.

**Set a hard spending cap** in RunPod billing settings. The watchdog is reliable, but a cap costs nothing and protects against misconfiguration.

**Check for forgotten pods weekly:**

```bash
# Key passed via header, not the URL -- URLs land in proxy and access logs.
curl -s -X POST "https://api.runpod.io/graphql" \
  -H "Authorization: Bearer $RUNPOD_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"query":"query{myself{pods{id name desiredStatus costPerHr}}}"}' | jq
```

**Remember that storage bills while stopped.** A persistent volume charges 24/7 even with the pod off. It is still worth having — re-downloading 20 GB of weights on every start costs more in GPU time than the volume does.

---

## The disk keeps filling with conversation directories

Every OpenHands conversation leaves its own directory under
`${OPENHANDS_WORKSPACE}/conversations/`, each with an `owner_lease.json` lease
file. Those directories are **invisible to the OpenHands conversation API**: a live
host reported 0 conversations while 29 directories, about 8.3 GB, sat on disk. So
neither the UI nor an API call will free the space, and `doctor.sh` only warns when
the tree passes about 1 GiB or 10 directories.

The fix is the quarantine sweep, `scripts/prune-conversations.sh`, run by
`hybrid-ai-prune.timer` daily at 04:20. It **quarantines, it never deletes**: a
stale directory is moved into a date-stamped quarantine root and a plain `mv`
back restores it.

### Did the timer run?

```bash
systemctl list-timers hybrid-ai-prune.timer     # last and next run
systemctl status hybrid-ai-prune                # last service run, exit status
journalctl -u hybrid-ai-prune --since '-2 days'
```

The service is `Type=oneshot` with no `Restart=`, so a failure does not loop. A
`Failed` status is the place to start; the script itself always exits 0 and reports
what it did in its summary line.

### Read the summary line

The last log line of every run is:

```text
summary: scanned=N kept-live=N kept-recent=N moved=N refused=N quarantine=<dir> refusals=<reasons>
```

| Field | Meaning |
|---|---|
| `scanned` | Directories seen at the top level of the conversations root |
| `kept-live` | Kept: lease still valid, inside its grace period, or a running container mounts it |
| `kept-recent` | Kept: mtime newer than `HYBRID_AI_PRUNE_AGE_SECONDS` |
| `moved` | Moved into the quarantine |
| `refused` | Refused, with the reasons listed in `refusals` |
| `quarantine` | The per-run directory, `<root>/<UTC YYYYMMDD>`; `none` when the run refused to sweep |

`refusals` names each reason: `symlink`, `unsafe-name`, `path-escape`,
`lease-missing`, `lease-unreadable`, `lease-empty`, `lease-unparsable-json`,
`lease-not-an-object`, `lease-no-expiry-key`, `lease-expiry-unparsable`,
`mtime-unreadable`, `cap-reached`, `destination-exists`, `cross-device`,
`move-failed`.

Read the common ones this way:

| What you see | What it means | What to do |
|---|---|---|
| `moved=0` and every entry `kept-live` | The leases are still valid, so the sweep is working as designed | Wait. Check again once the app has been idle for `HYBRID_AI_PRUNE_GRACE_SECONDS` |
| `refused=... cap-reached` | More eligible directories than one run may move | Raise `HYBRID_AI_PRUNE_MAX_MOVES`, or let the next daily run continue |
| `quarantine=none`, `moved=0` | The run refused to sweep: a path would not canonicalise, the root was missing, or the quarantine root was inside a backup-captured tree | Read the `[ ! ]` warning line above the summary; it names the setting |
| `cross-device` | The quarantine root is on another filesystem | Point `HYBRID_AI_PRUNE_QUARANTINE_BASE` at the same filesystem as the conversations tree |
| A `container-guard=unavailable` line | No usable `docker`, so only the lease and age guards decided | Not a failure; install or start Docker to enable the container check |

A degraded run (missing conversations root, missing `python3`, no Docker) still
logs and exits 0. The units call no `systemctl`, so the script runs by hand too.

### Inspect and restore the quarantine

The default root is `$(dirname "$HYBRID_AI_DATA_DIR")/hybrid-ai-conversation-quarantine`,
created mode 0750 and root-owned, one subdirectory per UTC run date:

```bash
Q="$(dirname "$(grep -E '^HYBRID_AI_DATA_DIR=' /etc/hybrid-ai/hybrid-ai.env | cut -d= -f2-)")/hybrid-ai-conversation-quarantine"
sudo ls -la "$Q"                 # one directory per run date
sudo du -sh "$Q"/*               # space held per run
```

Restoring is a plain move back; nothing was deleted, so nothing has to be decoded:

```bash
sudo mv "$Q/20260101/<conversation-id>" "$OPENHANDS_WORKSPACE/conversations/"
```

The quarantine root is deliberately outside every tree the backup captures, so
quarantined directories are **not** in a backup and will not be swept into the next
snapshot. Keep what you want by hand, and delete from the quarantine yourself once
you are sure; the script never does.

### Tune the knobs

Set these in `.env` (or the layout env file on a bootstrapped host) and re-run
`./install.sh`:

| Setting | Default | Meaning |
|---|---|---|
| `HYBRID_AI_PRUNE_AGE_SECONDS` | `604800` | Seconds. A directory with a newer mtime is kept |
| `HYBRID_AI_PRUNE_GRACE_SECONDS` | `86400` | Seconds. An expired lease is kept this long after expiry |
| `HYBRID_AI_PRUNE_MAX_MOVES` | `20` | Count. Moves allowed in one run |
| `HYBRID_AI_PRUNE_QUARANTINE_BASE` | unset | Quarantine root override; still asserted outside every captured tree |

A non-numeric value in any of the three numeric knobs is a refusal: the run logs a
warning and moves nothing.

---

## Backup and recovery

Backups are handled by restic to Cloudflare R2, encrypted on the Pi. Full documentation is in [`backup/README.md`](../backup/README.md); this section covers diagnosis.

### Is it working?

```bash
systemctl --user list-timers 'hybrid-ai-*'        # next scheduled run
grep '^EVENT' backup.log | tail -20               # recent outcomes
journalctl --user -u hybrid-ai-backup.service -n 50
./backup/restore.sh --list                        # snapshots that exist
```

A healthy run logs `backup_success` followed by `retention_applied`. A run that uploaded but missed durable state logs `backup_incomplete` and exits **3** — it is expected sometimes and is not retried. Every unit lists exit 3 in both `SuccessExitStatus=` (so systemd does not report it as a failed unit) and `RestartPreventExitStatus=` (so it is not retried).

### System mode (two units, one account)

With `HYBRID_AI_BACKUP_MODE=system` there are two units, not one, and the
commands change scope. Use `--system` and the two unit names:

```bash
systemctl list-timers 'hybrid-ai-*'                       # next capture
journalctl --system -u hybrid-ai-backup-capture.service -n 50
journalctl --system -u hybrid-ai-backup-upload.service  -n 50
systemctl start hybrid-ai-backup-capture.service          # run one now
cat /var/lib/hybrid-ai-backup/.backup-staging/STATUS                      # complete|incomplete
```

The capture unit stops a run by exit code:

| Exit | Meaning | What happens |
|---|---|---|
| 0 | capture complete | `STATUS` is `complete`; `OnSuccess=` starts the upload unit |
| 3 | capture incomplete (durable state was missed) | `STATUS` is `incomplete`; `SuccessExitStatus=3` still starts the upload, which tags the snapshot `complete:false`. The upload never retries it (`RestartPreventExitStatus=3`) |
| 1 | capture failed | no upload; the capture unit has no `Restart=`, so it does not loop |
| killed | capture interrupted | `ExecStopPost=+backup-containers.sh unpause` resumes the containers |

If a capture is killed hard, `unpause` is idempotent, so it is always safe to run
by hand as root:

```bash
sudo /opt/hybrid-ai/backup/backup-containers.sh unpause
```

The upload unit holds the R2 credentials (from
`/etc/credstore/hybrid-ai-backup/`) and retries a transient failure, bounded to
`StartLimitBurst=2` per `StartLimitIntervalSec=1h`. The capture unit holds no
credentials and has no network.

Every system-mode unit pins `HYBRID_AI_STACK_ENV_FILE` at the 0644 layout file
(`/etc/hybrid-ai/hybrid-ai.env`), never the 0600 root-only `stack.env`. The
backup account has no read access to `stack.env` and needs none; the layout file
holds only names and paths. Without the pin the shared env helper fails closed
(`HYBRID_AI_STACK_ENV_FILE ... exists and cannot be read`) and the unit exits 1
before restic runs.

The credential files under `$CREDENTIALS_DIRECTORY` are systemd's
`LoadCredential=` tmpfs copies, materialised 0400/0440 and recreated each start.
`backup.sh` accepts 0400 or 0440 there; a file read from
`HYBRID_AI_BACKUP_CRED_DIR` must still be exactly 0600. On the systemd path a
mode error names that rule, not an impossible `chmod 600`.

**The backup log: one path, in the units' `LogsDirectory=`.** In system mode the
units run under `ProtectSystem=strict`, so the only directory they can write is
the one systemd grants by name. `backup.sh` resolves `BACKUP_LOG` from the mode:
system mode gives `/var/log/hybrid-ai-backup/backup.log` (the units'
`LogsDirectory=hybrid-ai-backup`), user mode keeps `$HYBRID_AI_LOG_DIR/backup.log`.
`doctor.sh` reads the SAME resolved path, so "no successful backup recorded yet"
now means a genuinely missing event, not a path mismatch.

**`tee: /var/log/hybrid-ai-backup/backup.log: Read-only file system`.** The unit
has no write access to its log path — almost always an old unit file that predates
`LogsDirectory=hybrid-ai-backup`. Re-run `./install.sh` as root to refresh the
units, then:

```bash
sudo systemctl daemon-reload
sudo systemctl restart hybrid-ai-backup-capture.timer
```

If the unit is in a failed state from an earlier run, clear it first:
`sudo systemctl reset-failed hybrid-ai-backup-upload.service`. A `systemd-analyze
verify` on a stale file may also need the daemon-reload before the new
directives take effect.

**`unable to open cache: ... permission denied`.** The restic cache directory
(or a per-repo subdirectory under it) is owned by another uid, usually after an
earlier manual `sudo` run. This is non-fatal: `backup.sh` probes the cache and,
when it is not writable, logs `restic_cache_unwritable` and falls back to a
writable cache under the unit's runtime directory (`restic_cache_fallback`), so
the backup still succeeds with no manual `chown`. To restore the intended cache:

```bash
sudo chown -R hybrid-ai-backup:hybrid-ai-backup /var/cache/hybrid-ai-backup
```

**A bare `sudo ./backup/backup.sh` says `No credentials at /root/.config/...`.**
A manual `sudo` run resolves USER-mode paths, even on a system-mode host. Name
the layout file so the script reads the system-mode settings:

```bash
sudo env HYBRID_AI_ENV_FILE=/etc/hybrid-ai/hybrid-ai.env ./backup/backup.sh --check
```

**`skip: <unit> (host paths not installed)`.** The static test
`scripts/test-backup-system-units.sh` runs `systemd-analyze verify` on the
system units. On a host that has no `/opt/hybrid-ai` (the builder host,
`ubuntu-latest`), verify reports only the missing-host-path diagnostic for each
`ExecStart=`, so the test prints that skip line and does not count a failure. Any
OTHER diagnostic is a real failure, alone or mixed with the host-path line.

### Backup events

| Event | Meaning | Action |
|---|---|---|
| `backup_success` | Completed and every discovered database was captured; check `staged_mb` and `duration_s` | — |
| `backup_incomplete` | Uploaded, but durable state was missing; snapshot is tagged `complete:false` and the run exits 3 | Inspect the events alongside it: `db_path_rejected`, `hermes_data_unreadable`, `rsync_partial`, `cold_copy_fallback`. Not retried automatically |
| `db_path_rejected` | A discovered path failed the name allow-list; count only, the name is never logged | Investigate what wrote that name under `hermes_data` |
| `hermes_data_unreadable` | `find` could not read part of `hermes_data`, or it is not a readable directory | Fix permissions/ownership; the files are missing from this snapshot |
| `rsync_partial` | An `rsync` finished partial (exit 23/24); `source` names the tree | Re-run once the source is stable; some durable state is missing |
| `non_sqlite_db_skipped` | A file matched `*.db` but is not SQLite | None; the file is intentionally skipped |
| `cold_copy_fallback` | Online capture failed; containers stopped briefly for a verified cold copy | Install `sqlite3` to avoid the outage |
| `backup_failed` | Run aborted (exit 1) | See `detail` and `backup.log` |
| `backup_log_write_failed` | The run succeeded, but the log could not be written (restic's status, not tee's, decides success) | Check the log path's permissions; the backup itself is safe |
| `restic_cache_unwritable` | The configured restic cache is not writable by this uid | Informational; `backup.sh` selects a fallback cache |
| `restic_cache_fallback` | A writable fallback cache was selected | To restore the intended cache, `chown -R hybrid-ai-backup:hybrid-ai-backup` it |
| `retention_failed` | Pruning failed — backup itself is safe | Check R2 permissions |
| `check_failed` | **Repository integrity failure** | **Do not prune.** See below |
| `restore_test_success` | Rehearsal passed; backups are restorable | — |
| `restore_test_failed` | **Recovered databases are corrupt** | Investigate immediately |

### Common problems

**Backups never run overnight.** User services stop when you log out unless linger is enabled:

```bash
loginctl show-user "$USER" | grep Linger
sudo loginctl enable-linger "$USER"
```

**`repository is already locked`.** A previous run was killed. Confirm nothing is running, then:

```bash
set -a; source ~/.config/hybrid-ai-backup/r2.env; set +a
restic unlock
```

**`wrong password or no key found`.** The repository password does not match. There is no recovery mechanism — this is why it belongs in a password manager.

**`Could not snapshot ... via SQLite API`.** `sqlite3` is missing, so the script fell back to stopping Open WebUI and copying cold. Correct, but causes a brief outage:

```bash
sudo apt-get install -y sqlite3
```

**Integrity check failed.** Stop automated pruning immediately — pruning a damaged repository can destroy recoverable data:

```bash
systemctl --user stop hybrid-ai-backup.timer
restic check --read-data          # full verification
restic repair index               # rebuild the index
```

Treat existing snapshots as suspect until a `--test` restore passes.

**Backup is slow.** The first run uploads everything. Later runs are block-level incremental and usually finish in seconds. If every run is slow, check whether something is rewriting large files nightly.

### "Will my connections and pipes come back?"

Yes. Open WebUI keeps nearly all of its state in SQLite rather than config files, so model connections, functions/pipes (source *and* valve values), tools, knowledge bases, users, groups, API keys and admin settings are all inside `webui.db` and therefore inside every backup.

Verify a snapshot actually contains them:

```bash
./backup/restore.sh --test
# then, against the scratch copy:
sqlite3 .restore-test-*/**/databases/webui.db \
  "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;"
sqlite3 .restore-test-*/**/databases/webui.db \
  "SELECT id, is_active FROM function;"
```

Not in the databases, but still captured under `host/`: your Ollama model list, custom Modelfiles, container versions, compose overrides and git state. Only model *weights* and Tailscale machine identity are excluded, and both are handled during restore.

### Restoring

```bash
./backup/restore.sh --test        # rehearsal, touches nothing live
./backup/restore.sh --list        # choose a snapshot
./backup/restore.sh               # interactive restore
./backup/restore.sh --latest      # newest snapshot
```

The restore script verifies recovered databases **before** overwriting anything, and moves your current data to `webui_data.pre-restore-<timestamp>` rather than deleting it. If a restore goes wrong, your original data is still there.

**Rebuilding on new hardware:** see the walkthrough in [`backup/README.md`](../backup/README.md). The short version is: complete the prerequisites, clone the repo, recreate `~/.config/hybrid-ai-backup/` from your password manager, run `./backup/restore.sh --latest`, then `./install.sh`. Model weights are not backed up — re-pull them.

### Verify quarterly

```bash
./backup/restore.sh --test
```

The monthly timer verifies the *repository*. Only `--test` proves the *data* comes back usable, by running SQLite's own integrity check against every recovered database.

## Routine maintenance

**Weekly**

```bash
./doctor.sh                       # covers disk, health, backup freshness
sudo apt-get update && sudo apt-get upgrade -y
```

**Monthly**

```bash
./install.sh                         # pulls current images and restarts
docker image prune -f
docker exec -it ollama ollama list   # remove models you no longer use
```

**Quarterly**

- Rotate the Tailscale auth key (they expire — a stale key means the pod silently stops rejoining)
- Rotate `RUNPOD_API_KEY`, updating it in both the Pi's `.env` and the pod template
- Review RunPod billing for anything unexpected
- Test a restore: `./backup/restore.sh --test`. An untested backup is a hypothesis
- Confirm backup timers are still active: `systemctl --user list-timers 'hybrid-ai-*'`

**Storage health.** NVMe is recommended and far more durable than an SD card, but no disk is immortal. Warning signs are filesystem errors in `dmesg` and sudden read-only remounts. Check with:

```bash
dmesg | grep -iE 'mmcblk|nvme|i/o error'
```

Any I/O errors mean replace the drive now, while you still can.

On NVMe you can also read the drive's own health counters:

```bash
sudo nvme smart-log /dev/nvme0 2>/dev/null | grep -iE 'percentage_used|media_errors|critical_warning'
```

`percentage_used` is the controller's estimate of consumed write endurance. Anything under 10% after a year of normal use is healthy.

If you are still on an SD card, treat the above warning signs as urgent — cards fail far sooner under this workload.

---

## Reading the event logs

Both the installer and the pod emit structured, greppable records of what happened. **Every line is metadata only** — durations, counts, states, exit codes. No prompt or response text is ever written to either log, by design.

### Where they are

| Log | Location | Contents |
|---|---|---|
| Installer | `${HYBRID_AI_LOG_DIR:?HYBRID_AI_LOG_DIR must be set - run ./install.sh}/install.log` on the Pi (gitignored, mode 0600) | One entry per `install.sh` run |
| Backup | `${HYBRID_AI_LOG_DIR:?HYBRID_AI_LOG_DIR must be set - run ./install.sh}/backup.log` on the Pi | One entry per backup/restore run |
| Pod | `/var/log/hybrid-ai-events.log` and the RunPod console | Pod lifecycle, watchdog, vLLM health |
| Pipe | `docker compose --env-file .env -f docker-compose.yml -f openhands/docker-compose.openhands.yml -f hermes/docker-compose.hermes.yml logs open-webui` | Per-request outcomes |

Each path is resolved by `scripts/lib/hybrid-ai-env.sh`. With no settings the
helper default is the deployment directory. The compose bind sources are
fail-closed (`:?`), so a compose parse with no settings is refused with a
`run ./install.sh` message rather than silently falling back.

### Pod events

```bash
grep '^EVENT' /var/log/hybrid-ai-events.log
```

| Event | Meaning | Action |
|---|---|---|
| `tailnet_joined` | Pod reached your private network | — |
| `runtime_state_captured` | GPU count and address recorded | — |
| `watchdog_armed` / `watchdog_active` | Cost control running | **Confirm this appears on every boot** |
| `watchdog_disabled` | `RUNPOD_API_KEY` missing | **Urgent** — pod will bill forever |
| `vllm_ready` | Model is serving; `load_seconds` shows cold-start cost | — |
| `vllm_ready_timeout` | Process alive but not serving | Check pod logs for OOM |
| `vllm_exited` | Server died unexpectedly | Inspect `exit_code` |
| `vllm_restarting` | Supervisor recovering | Repeated entries mean instability |
| `vllm_restart_budget_exhausted` | Gave up; pod stopped | Model cannot start — check VRAM and model name |
| `idle_window` | Idle minute counted | Normal |
| `idle_counter_reset` | Activity seen, counter cleared | Normal |
| `gpu_unreadable` | `nvidia-smi` failing | 5 consecutive windows stops the pod |
| `podstop_success` | Pod stopped cleanly | Normal end of session |
| `podstop_failure` | One attempt failed; retrying | Watch for exhaustion |
| `podstop_exhausted` | **All retries failed** | **Stop the pod manually now** |

The two to alert on are `watchdog_disabled` and `podstop_exhausted`. Both mean the pod may bill indefinitely.

### Pipe events

```bash
docker compose --env-file .env \
  -f docker-compose.yml \
  -f openhands/docker-compose.openhands.yml \
  -f hermes/docker-compose.hermes.yml logs open-webui | grep runpod_pipe
```

Each request carries a `request_id`, so you can trace one conversation end to end:

| Event | Meaning |
|---|---|
| `request_started` | Turn count and effective token cap |
| `pod_ready` | `wake_seconds` — how long the cold start took |
| `request_success` | Completed normally |
| `request_truncated` | Hit the token ceiling; user was told |
| `request_degraded` | Stream ended without `[DONE]` — partial answer |
| `request_failed` | See `reason` field |
| `request_cancelled` | User pressed stop |
| `request_rejected` | Failed preflight; never left the Pi |
| `runpod_api_retry` | Transient API failure being retried |

Trace a single request:

```bash
docker compose --env-file .env \
  -f docker-compose.yml \
  -f openhands/docker-compose.openhands.yml \
  -f hermes/docker-compose.hermes.yml logs open-webui | grep 'request_id=a1b2c3d4'
```

Measure typical cold-start latency:

```bash
docker compose --env-file .env \
  -f docker-compose.yml \
  -f openhands/docker-compose.openhands.yml \
  -f hermes/docker-compose.hermes.yml logs open-webui \
  | grep -o 'wake_seconds=[0-9.]*' | cut -d= -f2 | sort -n | tail -5
```

### Installer events

```bash
grep '^EVENT' install.log
```

`install_success` confirms both services passed their health checks. `install_failed reason=healthcheck` means containers started but are not serving — the script exits non-zero and prints container logs.

---

## Uninstall and re-install problems

`scripts/uninstall.sh` is safe to re-run, so most of these clear on a second
run. Always try `sudo scripts/uninstall.sh --dry-run` first: it prints the full
plan and changes nothing.

### The second run takes the remnants path

After a software-only uninstall `/opt/hybrid-ai` is gone, so the script reports
`remnants only` and lists what is left by name. That is expected. It removes the
known containers by name (no compose call, because there is no compose file to
read) and, with `--remove-data`, the data directories. A third run then reports
`nothing found` and exits 0.

If the containers are already gone, `docker rm -f` warns and continues. The exit
code stays 0.

### A refused out-of-allowlist layout path

If the layout file names a path outside the allowlist, the script refuses it and
prints a message naming the setting, for example:

```
[ ! ] refusing to remove /srv/elsewhere (setting HYBRID_AI_DATA_DIR): outside the allowlist. It is left untouched.
```

The path survives. To remove it, do so by hand, or correct the setting in
`/etc/hybrid-ai/hybrid-ai.env` and run again. The allowlist is exact:
`/opt/hybrid-ai`, `/var/lib/hybrid-ai*`, `/var/log/hybrid-ai*`,
`/var/cache/hybrid-ai-backup`, `/etc/hybrid-ai`,
`/etc/credstore/hybrid-ai-backup`, the `hybrid-ai-*` unit files, and the polkit
rule file. The script parses the layout file and never sources it, and it never
reads or prints a value from `stack.env` or the credential store.

### The stack comes back after uninstall

The GitHub `deploy.yml` workflow runs on every push to `main`, and a push
re-installs the stack. Disable that workflow before you decommission.

### Images and the build cache are still there

They are kept on purpose, so a re-install does not re-pull everything. Remove
them by hand if you want the disk back:

```bash
docker image prune -a
docker builder prune
```

The `hybrid-ai` and `hybrid-ai-backup` system accounts are kept too. Remove them
by hand with `userdel`/`groupdel` if you are sure nothing else uses them.
