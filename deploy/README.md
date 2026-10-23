# deploy/ — headless deploy (one commit, one unit)

This directory holds the in-repo pieces of a **headless deploy**. A dedicated,
unprivileged `hybrid-ai-deploy` account gets a forced-command SSH entrypoint
that can do exactly one thing: start the systemd unit
`hybrid-ai-deploy@<sha>.service`, which deploys the 40-character commit `<sha>`.
The account cannot run git, read the journal, use sudo, or touch any other unit.

Nothing here is active on its own. Today's deploy path
(`.github/workflows/deploy.yml`) already calls this entrypoint through
`scripts/deploy-trigger.sh`; it becomes fully active once the owner runs the
bootstrap below.

> ## Active after bootstrap
>
> The host pieces here are inert until an owner migration runs. **Card F**,
> `scripts/bootstrap.sh`, installs the pieces on the host and adds the
> `authorized_keys` line, which makes the deploy pass live. `deploy.yml` has
> already been switched over: it connects as `hybrid-ai-deploy` and sends exactly
> `deploy <sha>`. Until the bootstrap runs, no account, unit or polkit rule
> exists on the host, so that connection fails closed at SSH auth with nothing
> run.

---

## What card F installs (one bootstrap, on the host)

Card F is one idempotent, root-run script, `scripts/bootstrap.sh`. It installs
the account, the files and the SSH key line on a host in a single command, and
migrates the current Pi to the same layout:

```sh
sudo ./scripts/bootstrap.sh --deploy-pubkey <key.pub> [--from <legacy-dir>]
```

Everything after the bootstrap runs from the forced command and the unit. The
bootstrap is the manual, one-time step; `install.sh` never runs it and never
calls `sudo`.

1. **The account** — a system account `hybrid-ai-deploy` (uid below `UID_MIN`).
   It has `/bin/sh` and a locked password, because sshd runs the forced command
   through the account's login shell; a nologin shell would refuse it.
   (`systemd` runs the unit as root, so the account is only the SSH identity.)
2. **The forced-command script** — `/opt/hybrid-ai/scripts/deploy-forced-command.sh`
   and its helpers under `/opt/hybrid-ai/scripts/`, readable and executable by
   the account. `/opt/hybrid-ai` is a root-owned clone of the public https
   remote at `origin/main`.
3. **The unit** — `deploy/hybrid-ai-deploy@.service`, copied to
   `/etc/systemd/system/hybrid-ai-deploy@.service` (root-owned), then
   `systemctl daemon-reload`. It is an instantiated unit started explicitly; it
   is never enabled. `scripts/bootstrap.sh` installs it on a fresh device, and
   **`install.sh` re-applies it on every deploy**, so a change to the tracked
   file reaches the host through the normal deploy instead of a by-hand copy. A
   deploy re-applies it while running inside the unit: the running instance
   keeps its loaded configuration, so the new content is effective from the
   next instantiation.
4. **The polkit rule** — `deploy/50-hybrid-ai-deploy.rules`, copied to
   `/etc/polkit-1/rules.d/50-hybrid-ai-deploy.rules` (or the distro's polkit
   rules directory, e.g. `/usr/share/polkit-1/rules.d/`), root-owned, then
   reload polkit. It grants the account `start` of a matching unit and nothing
   else. Like the unit, the bootstrap installs it on a fresh device and
   `install.sh` re-applies it, byte-identical, on every deploy, followed by
   `systemctl reload polkit`. The bootstrap refuses to run when polkitd is
   absent or predates `.rules` (JavaScript) support.
5. **The env file** — `/etc/hybrid-ai/hybrid-ai.env`, root-owned, mode `0644`.
   It is the LAYOUT file: it holds path and identity settings only, never a
   secret, so both `hybrid-ai-deploy` and `hybrid-ai-backup` can read it. (The
   stack's secrets live in `/etc/hybrid-ai/stack.env`, mode `0600`.) The unit
   passes its path by name only:
   `Environment=HYBRID_AI_ENV_FILE=/etc/hybrid-ai/hybrid-ai.env`. A bare
   invocation that does not name the layout file still finds it: when
   `HYBRID_AI_ENV_FILE` is unset and `$HYBRID_AI_APP_DIR/.env` is absent, the
   helper falls back to `HYBRID_AI_ENV_FILE_FALLBACK` (default
   `/etc/hybrid-ai/hybrid-ai.env`) when that file exists.
6. **The SSH key line** — one line in the account's `~/.ssh/authorized_keys`,
   restricted to the forced command (see below).

### The authorized_keys line

The key is pinned to the forced command and reduced to no forwarding of any
kind with the `restrict` option:

```
restrict,command="/opt/hybrid-ai/scripts/deploy-forced-command.sh" <key>
```

`restrict` disables PTY, X11, agent, and port forwarding. The `command=` option
makes sshd run the forced command no matter what the client asks for, with the
requested command placed in `SSH_ORIGINAL_COMMAND`. Because the forced command
accepts only `deploy <40-lowercase-hex>`, the key can start one matching deploy
unit — nothing more.

---

## Least privilege

The `hybrid-ai-deploy` account holds:

- **No login shell beyond the forced command.** sshd runs
  `deploy-forced-command.sh` for every connection, regardless of the requested
  command. Nothing else is reachable.
- **No sudo.** It is in no `sudoers` rule and needs none.
- **Not in the `docker` group.** It cannot talk to the Docker socket.
- **Not in the `systemd-journal` group.** It cannot read journald. Instead the
  unit writes each run's log to `$HYBRID_AI_LOG_DIR/deploy/<sha>.log` with mode
  `0640` and group `hybrid-ai-deploy`, so the account reads the log for its own
  run without any journal access.
- **Read access to the layout env file, and only that file.** The forced command
  resolves the host paths the same way the unit does, by reading
  `/etc/hybrid-ai/hybrid-ai.env` (parsed, never sourced). That file is mode
  `0644`, owned by root, so the `hybrid-ai-deploy` account AND the
  `hybrid-ai-backup` account both read it. It holds paths and names only. (An
  earlier draft used mode `0640` group `hybrid-ai-deploy`; that would have
  locked the backup account out, so it is `0644`.) The forced command pins
  `HYBRID_AI_STACK_ENV_FILE` at this layout file unconditionally, so it never
  reads the `0600` secrets file `/etc/hybrid-ai/stack.env` and an inherited
  value cannot point it back at that file. The account is never granted read
  access to `stack.env`, by mode, group or ACL.
- **One polkit action, one verb, one unit shape.** The polkit rule returns
  `polkit.Result.YES` only for `subject.user == "hybrid-ai-deploy"`,
  `action.id == "org.freedesktop.systemd1.manage-units"`, `verb == "start"`, and
  a unit matching `^hybrid-ai-deploy@[0-9a-f]{40}\.service$`. Everything else is
  the default deny.
- **A public fetch with no credentials.** `scripts/deploy-instance.sh` fetches
  main only from the public https remote, with git hooks disabled and credential
  helpers cleared, and refuses a credential-bearing origin.

The unit runs as root because it resets the program tree and reprovisions the
host. The commit it deploys is re-validated inside `scripts/deploy-instance.sh`,
refused unless it is an ancestor of `origin/main`, and its `HEAD` is asserted
after the reset.

---

## How a deploy flows

1. The GitHub deploy job runs `scripts/deploy-trigger.sh "$GITHUB_SHA"`. That
   client validates the sha, fetches the Pi's host key with `ssh-keyscan`,
   compares its SHA256 fingerprint with `PI_SSH_HOST_KEY`, then connects as
   `hybrid-ai-deploy` and sends exactly `deploy <40-hex>`.
2. sshd runs `deploy-forced-command.sh` with `SSH_ORIGINAL_COMMAND="deploy <40-hex>"`.
3. The script refuses anything but that exact form (exit 2), then asks the
   **system** manager to start `hybrid-ai-deploy@<sha>.service`.
4. The unit runs `scripts/deploy-instance.sh <sha>` as root. The script
   re-validates the sha, takes an exclusive lock, refuses a credential-bearing
   origin, fetches main from the public https remote, refuses unless `<sha>` is
   an ancestor of `origin/main`, resets to it, asserts `HEAD == <sha>`, and
   `exec`s the existing `scripts/deploy-remote.sh`.
5. `scripts/deploy-remote.sh` re-asserts `HEAD`, runs `install.sh`, and gates on
   `doctor.sh`. `install.sh` rebuilds the Hermes image only when its build
   inputs changed, and prints a per-phase duration summary
   (see `docs/TROUBLESHOOTING.md`, "The build phase of a deploy").
6. The forced command reads back the unit's result and prints the run log from
   `$HYBRID_AI_LOG_DIR/deploy/<sha>.log`.

---

## Post-deploy verification (after the workflow has finished)

The deploy cannot verify its own build: the workflow run it belongs to is still
in progress at that moment. So `scripts/deploy-remote.sh` starts
`/usr/local/sbin/run-post-deploy-verify.sh` and lets it finish afterwards.

What it does: poll `GET /repos/jimbobsyouruncle/hybrid-ai/actions/runs?head_sha=<sha>`
anonymously every 30 s for up to 60 minutes (curl and jq only, no token), wait
until every run for that commit is `completed`, require every conclusion to be
`success`, then compare `git -C /workspace rev-parse HEAD` with the deployed sha.
It writes one `waiting for <sha> at <UTC>` line up front, then exactly one
result line -- `PASS`, `FAIL: ...` or `TIMEOUT: ...`.

**It runs in its own transient unit**, not as a child of the deploy:

```
systemd-run --collect --unit=hybrid-ai-post-deploy-verify-<sha12>-<pid> ...
```

`deploy/hybrid-ai-deploy@.service` is `Type=oneshot` with the default
`KillMode=control-group`, so systemd kills everything left in the unit's cgroup
when it exits. An in-cgroup waiter is therefore killed at unit exit --
`setsid` escapes the session, not the cgroup. That was the original defect: a
0-byte log whose mtime matched unit exit. This is why the unit file must never
grow a `KillMode=` override: the transient unit is the fix, and a relaxed kill
mode would hide the class of bug instead of fixing it.

Paths (both resolved in `scripts/lib/hybrid-ai-env.sh`):

| Path | Default |
|---|---|
| Verifier | `/usr/local/sbin/run-post-deploy-verify.sh`, installed root:root 0755 by `install.sh` |
| Log | `/var/log/hybrid-ai-post-deploy-verify.log`, appended by the transient unit |

The hook is a warning, never a gate. All three paths leave the deploy's exit
code untouched: scheduled, scheduling failed
(`::warning::post-deploy verification could not be scheduled`), and script
absent (`::warning::post-deploy verification script is absent: <path>`). The
absent case is loud on purpose -- it used to be silent.

`--service-type=exec` is deliberate: it waits for `exec()` to succeed, so a
launch failure is reported instead of lost. `--no-block` would suppress exactly
that. `--collect` and `append:` are supported by the host's systemd 252.

Reading the log and the units: see
[`docs/TROUBLESHOOTING.md`](../docs/TROUBLESHOOTING.md#post-deploy-verification).

---

## Timeouts

The unit's `TimeoutStartSec=` is 45 min and the workflow's `Trigger deploy` step
is 60 min. The step must stay strictly longer than the unit, so the unit gives
up first and the step is still alive to report the real `Result=`. Do not invert
them.

---

## Exit codes

`scripts/deploy-trigger.sh` (the client the deploy job runs; it maps the remote
command's exit code to the job's exit code):

| Code | Meaning |
|---|---|
| `0` | Remote exit 0: the unit started and finished successfully; the job is green |
| `1` | Remote exit 2 (forced command refused the request), remote exit 3 (the unit failed), or any other non-zero remote code. Each prints an `::error::` line |
| `2` | Bad usage: the argument is missing, or is not a 40-lowercase-hex commit; nothing was sent |
| `3` | A local prerequisite failed (missing env, or the host key could not be fetched) |
| `4` | The Pi's host-key fingerprint did not match `PI_SSH_HOST_KEY`; ssh was never invoked |

`scripts/deploy-forced-command.sh`:

| Code | Meaning |
|---|---|
| `0` | The unit started and finished successfully |
| `2` | The command was refused (not exactly `deploy <40-lowercase-hex>`); nothing was run |
| `3` | The unit was started but did not finish successfully |

`scripts/deploy-instance.sh` (the unit's own exit codes; `exec` propagates
`deploy-remote.sh`'s code when it gets that far):

| Code | Meaning |
|---|---|
| `0` | Handed off to `deploy-remote.sh` (its exit code propagates through `exec`) |
| `2` | Missing argument, or not a 40-lowercase-hex commit |
| `3` | Another deploy holds the lock |
| `4` | The origin remote carries a credential (userinfo in its URL) |
| `5` | The public remote is unsafe (not https, or carries userinfo) |
| `6` | Fetching main from the public remote failed |
| `7` | The commit is not an ancestor of `origin/main` |
| `8` | `HEAD` is not the commit after `git reset --hard` |

These are also listed in [`docs/TROUBLESHOOTING.md`](../docs/TROUBLESHOOTING.md).

---

## Conversation prune units

Two units run the conversation quarantine sweep. They are ordinary system units,
not part of the headless deploy, and `hybrid-ai-prune.service` names
`/opt/hybrid-ai/deploy/README.md` as its `Documentation=` target — this section.

| Unit | What it does |
|---|---|
| `hybrid-ai-prune.service` | `Type=oneshot`, `User=root`, `ExecStart=/opt/hybrid-ai/scripts/prune-conversations.sh` |
| `hybrid-ai-prune.timer` | `OnCalendar=*-*-* 04:20:00`, `Persistent=true`, `Unit=hybrid-ai-prune.service` |

It runs as root because the conversations tree under the OpenHands workspace is
owned by root and by the stack's own users; a non-root run could not move those
directories.

`install.sh` installs and enables both units **unconditionally** — not gated on
`HYBRID_AI_BACKUP_MODE`, because pruning is unrelated to whether backups are
configured. It warns and records an event rather than failing if it is not root,
if `systemctl` is unavailable, or if a unit template is missing, so the schedule
can never fail a deploy. It also runs the service once at deploy time as
**catch-up only**, for a host that was off or had not re-deployed for a while; a
missing script there is a warning too. The timer is the primary mechanism.

`hybrid-ai-prune.service` carries no `Restart=` line at all, deliberately. A
failing prune must not loop; the failure stays visible in
`systemctl status hybrid-ai-prune`. For the same reason neither unit sets
filesystem sandboxing directives (`ProtectSystem=`, `PrivateTmp=`,
`ReadOnlyPaths=`, `InaccessiblePaths=`): the service has to move directories
under the workspace, and those flags would break the move.

The prune QUARANTINES and never deletes. The knobs and the inspection and restore
steps are in the root `README.md` and
[`../docs/TROUBLESHOOTING.md`](../docs/TROUBLESHOOTING.md#the-disk-keeps-filling-with-conversation-directories).

## Docker build-cache prune units

Two more units cap the Docker build cache, installed by the same
`install_prune_scheduler()` step and named, like their sibling, by this README
through the service's `Documentation=` target.

| Unit | What it does |
|---|---|
| `hybrid-ai-docker-prune.service` | `Type=oneshot`, `User=root`, `EnvironmentFile=-/opt/hybrid-ai/.env`, `After=docker.service`, `ExecStart=/opt/hybrid-ai/scripts/prune-docker-cache.sh` |
| `hybrid-ai-docker-prune.timer` | `OnCalendar=*-*-* 04:35:00`, `Persistent=true`, `Unit=hybrid-ai-docker-prune.service` |

The timer caps the Docker build cache at 15 GB (override
`HYBRID_AI_BUILD_CACHE_CAP`) daily at 04:35; it removes build cache only and
never touches images, containers, volumes or bind-mounted data. The service
carries no `Restart=` line, deliberately: a failing prune must not loop.
`scripts/prune-docker-cache.sh` probes `docker builder prune --help` at run time
and passes `--max-used-space` when the local Docker lists it, `--keep-storage`
otherwise, and logs and exits 0 when it lists neither, so an unknown Docker
never turns the timer into a hard failure.

---

## No retry policy

`hybrid-ai-deploy@.service` has **no `Restart=` policy at all**. An earlier
backup upload unit used `Restart=on-failure`, and its retry loop stopped
`hermes-agent` every 15 minutes (incident B1). A failed deploy must never be
retried automatically: a retry could reset the tree again and disturb the
running stack. A failed deploy stays failed and is diagnosed from its log.

---

## Tests

`scripts/test-deploy-trigger.sh`, `scripts/test-deploy-forced-command.sh` and
`scripts/test-deploy-instance.sh` cover all three halves offline — `ssh`,
`ssh-keyscan`, `ssh-keygen`, `systemctl`, `git` and `deploy-remote.sh` are stubbed
on `PATH`, so no Docker, no network and no root are needed. The trigger test
proves the exact command string and login name, the malformed-sha refusals, the
host-key mismatch refusal, the exit-code mapping, key-file removal on success and
failure, and that no weakened host-key option appears. The other two check the
unit has no `Restart=` line and that the polkit rule contains the exact user,
action, verb and unit regex. `scripts/test-bootstrap.sh` covers the host
bootstrap that installs the account, the unit, the polkit rule and the SSH key
line, entirely offline.
