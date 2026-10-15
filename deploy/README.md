# deploy/ — headless deploy (one commit, one unit)

This directory holds the in-repo pieces of a **headless deploy**. A dedicated,
unprivileged `hybrid-ai-deploy` account gets a forced-command SSH entrypoint
that can do exactly one thing: start the systemd unit
`hybrid-ai-deploy@<sha>.service`, which deploys the 40-character commit `<sha>`.
The account cannot run git, read the journal, use sudo, or touch any other unit.

Nothing here is active on its own. Today's deploy path
(`.github/workflows/deploy.yml`) is unchanged.

> ## Not active until the owner's migration
>
> Every file in this directory is inert until an owner migration runs. **Card F**
> installs the pieces on the host and adds the `authorized_keys` line; a later
> card switches `.github/workflows/deploy.yml` over to this entrypoint. Until
> both happen, this is documentation and source only — nothing is created on any
> host, no account exists, no unit runs, no polkit rule is loaded.

---

## What card F installs (one bootstrap, on the host)

Installing the account, the files and the SSH key line on a host is card F's
job. It is the manual bootstrap; everything after it runs from the forced
command and the unit.

1. **The account** — a no-login system account `hybrid-ai-deploy`
   (`systemd` runs the unit as root, so the account is only the SSH identity).
2. **The forced-command script** — `/opt/hybrid-ai/scripts/deploy-forced-command.sh`
   and its helpers under `/opt/hybrid-ai/scripts/`, readable and executable by
   the account.
3. **The unit** — `deploy/hybrid-ai-deploy@.service`, copied to
   `/etc/systemd/system/hybrid-ai-deploy@.service` (root-owned), then
   `systemctl daemon-reload`. It is an instantiated unit started explicitly; it
   is never enabled.
4. **The polkit rule** — `deploy/50-hybrid-ai-deploy.rules`, copied to
   `/etc/polkit-1/rules.d/50-hybrid-ai-deploy.rules` (or the distro's polkit
   rules directory, e.g. `/usr/share/polkit-1/rules.d/`), root-owned, then
   reload polkit. It grants the account `start` of a matching unit and nothing
   else.
5. **The env file** — `/etc/hybrid-ai/hybrid-ai.env` (root-owned), the same
   system env file the system-mode backup units read. The unit passes its path
   by name only: `Environment=HYBRID_AI_ENV_FILE=/etc/hybrid-ai/hybrid-ai.env`.
6. **The SSH key line** — in the account's `~/.ssh/authorized_keys`, restricted
   to the forced command (see below).

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
- **Read access to the system env file.** The forced command resolves the host
  paths the same way the unit does, by reading
  `/etc/hybrid-ai/hybrid-ai.env` (parsed, never sourced). Card F should make
  that file readable by the account (e.g. mode `0640`, group
  `hybrid-ai-deploy`) so both sides agree on `$HYBRID_AI_LOG_DIR`. The file
  holds paths and names only.
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

1. The client runs `ssh hybrid-ai-deploy@<host> deploy <40-hex>`.
2. sshd runs `deploy-forced-command.sh` with `SSH_ORIGINAL_COMMAND="deploy <40-hex>"`.
3. The script refuses anything but that exact form (exit 2), then asks the
   **system** manager to start `hybrid-ai-deploy@<sha>.service`.
4. The unit runs `scripts/deploy-instance.sh <sha>` as root. The script
   re-validates the sha, takes an exclusive lock, refuses a credential-bearing
   origin, fetches main from the public https remote, refuses unless `<sha>` is
   an ancestor of `origin/main`, resets to it, asserts `HEAD == <sha>`, and
   `exec`s the existing `scripts/deploy-remote.sh`.
5. `scripts/deploy-remote.sh` re-asserts `HEAD`, runs `install.sh`, and gates on
   `doctor.sh`.
6. The forced command reads back the unit's result and prints the run log from
   `$HYBRID_AI_LOG_DIR/deploy/<sha>.log`.

---

## Exit codes

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

## No retry policy

`hybrid-ai-deploy@.service` has **no `Restart=` policy at all**. An earlier
backup upload unit used `Restart=on-failure`, and its retry loop stopped
`hermes-agent` every 15 minutes (incident B1). A failed deploy must never be
retried automatically: a retry could reset the tree again and disturb the
running stack. A failed deploy stays failed and is diagnosed from its log.

---

## Tests

`scripts/test-deploy-forced-command.sh` and `scripts/test-deploy-instance.sh`
cover both halves offline — `systemctl`, `git` and `deploy-remote.sh` are stubbed
on `PATH`, so no Docker, no network and no root are needed. They also check the
unit has no `Restart=` line and that the polkit rule contains the exact user,
action, verb and unit regex.
