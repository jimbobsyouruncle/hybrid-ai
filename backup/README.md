# `backup/` — Encrypted Offsite Backups

| File | Purpose |
|---|---|
| `backup.sh` | Snapshots your data consistently and uploads it, encrypted, to Cloudflare R2 |
| `restore.sh` | Brings it all back — including a rehearsal mode that touches nothing live |
| `hybrid-ai-backup.{service,timer}` | Nightly schedule at 03:15 (**user mode**, the default) |
| `hybrid-ai-check.{service,timer}` | Monthly integrity verification (**user mode**) |
| `system/` | The **system mode** units: a two-unit nightly privilege split (capture and upload), plus the monthly integrity-check unit (see below) |
| `backup-containers.sh` | Root-only helper the system-mode capture unit calls; the only part of a system-mode backup that touches Docker |

There are two ways to run the nightly backup, chosen by the
`HYBRID_AI_BACKUP_MODE` setting:

- **user** (the default) — today's per-user units, unchanged.
- **system** — two system units under a dedicated unprivileged account that
  together can capture all durable state without root and without any account in
  the `docker` group. See [System mode](#system-mode-fresh-install-and-migration).

---

## What is protected, and what is not

**The short version:** everything you configured through the Open WebUI interface is in the databases, and the databases are backed up. A rebuilt Pi comes back with your connections, pipes, valve settings, knowledge bases, users and groups exactly as they were.

### Inside the databases (fully covered)

Open WebUI stores essentially all of its state in SQLite, not in config files. That means these are all captured:

| What | Where it lives | Notes |
|---|---|---|
| Chat history and folders | `webui.db` → `chat`, `folder` | |
| **Model connections** | `webui.db` → `config` | Ollama and any OpenAI-compatible endpoints, including their API keys |
| **Functions / pipes** | `webui.db` → `function` | The Python **source** *and* the **valve values** you set — your RunPod pipe comes back configured, not just installed |
| **Tools** | `webui.db` → `tool` | Source and settings |
| Custom models / presets | `webui.db` → `model` | System prompts, parameters, per-model access control |
| Knowledge bases | `webui.db` → `knowledge`, `knowledge_file` | Definitions and file links |
| Users, groups, permissions | `webui.db` → `user`, `auth`, `group`, `group_member` | |
| API keys, prompts, memories | `webui.db` | |
| Admin panel settings | `webui.db` → `config` | Open WebUI persists runtime config to the database, where it takes precedence over environment variables |
| Vector store metadata | `vector_db/chroma.sqlite3` | |

### Outside the databases (also covered)

| What | Where |
|---|---|
| Uploaded documents | `webui_data/uploads/` |
| **ChromaDB binary vector index** | `webui_data/vector_db/<uuid>/*.bin` |
| `.env` configuration | Repo root — encrypted in the backup |
| Ollama **model list** and custom Modelfiles | `host/` — used by `restore.sh` to re-pull automatically |
| Container image versions in use | `host/container-images.txt` |
| Local edits to compose files and the pipe | `host/` |
| Git commit and any uncommitted changes | `host/git-state.txt`, `host/uncommitted.patch` |

### Deliberately not covered

| What | Why | What you do instead |
|---|---|---|
| Ollama model **weights** | Tens of GB, freely re-downloadable. Backing them up would dominate the cost for zero benefit | `restore.sh` re-pulls them from the captured list, automatically |
| Tailscale machine identity | Not transferable by design — that is what makes the network trustworthy | `sudo tailscale up` on the new Pi |
| Docker images | Pinned by version in `docker-compose.yml` | `install.sh` pulls them |
| systemd units, linger | Generated deterministically | `install.sh` reinstalls them |
| Cached embeddings model | Re-downloaded on first use | Nothing |

**Net effect:** a bare new Pi needs the prerequisites installed, the repo cloned, your backup credentials recreated, and one `restore.sh` run. Then `sudo tailscale up` and `./install.sh`. Everything else returns on its own.

### The quarantine is deliberately outside every captured tree

`scripts/prune-conversations.sh` moves stale OpenHands conversation directories
into a quarantine root that is deliberately outside every tree this backup
captures, because a quarantine inside a captured tree would be swept into the next
snapshot and the later upload — growing the backup by the very data the sweep was
meant to take off the disk. The script asserts this and refuses to move anything
if the quarantine root is inside `HYBRID_AI_DATA_DIR`, `HYBRID_AI_APP_DIR`,
`HYBRID_AI_WORK_DIR`, `HYBRID_AI_HERMES_DATA_DIR`, `HYBRID_AI_WEBUI_DATA_DIR` or
`OPENHANDS_WORKSPACE`. Quarantined conversations are therefore **not** in a backup
and are kept by hand. The sweep itself never deletes a conversation directory; its
one deletion is confined to quarantine run directories past
`HYBRID_AI_PRUNE_QUARANTINE_RETENTION_DAYS` (default `90`, empty or `0` opts out).

## The thing that makes this actually work

Open WebUI stores everything in SQLite. ChromaDB stores vectors in SQLite too.

**Copying a SQLite file while the application is writing to it produces a corrupt copy.** It will look fine. It will upload without error. It will fail to open on the day you actually need it — which is the worst possible moment to discover the problem. This is the single most common way self-hosted backup setups turn out to be worthless.

So `backup.sh` never copies the live database files. When the stack can be paused, it copies each database **with its `-wal`, `-shm` and `-journal` sidecars** into staging without opening the live files, then checkpoints the **staged** copy and requires `PRAGMA quick_check` to pass. When pausing is not possible (or `BACKUP_NO_PAUSE=1`), it uses SQLite's online backup (`.backup`) instead. Either way the live files and their sidecars are excluded from the upload.

`VACUUM INTO` is **never** used. Its only way to name the output is to splice that name into SQL text, and the names come from container-written data. A discovered name is treated as hostile: it must pass an allow-list (every path component matches `[A-Za-z0-9._@+-]+`, is not `.` or `..`, and does not start with `-`) before it reaches any copy or `sqlite3` call. A name that fails is never touched; it is counted (`db_path_rejected`) and the run is marked **incomplete**.

### The second consistency problem: ChromaDB is split in two

Chroma keeps document metadata in `chroma.sqlite3` but keeps the actual vector index in separate binary files — `data_level0.bin`, `header.bin`, `length.bin`, `link_lists.bin` — inside UUID-named directories.

Snapshotting the SQLite half at 03:15:00 and copying the binary half at 03:15:04 means that if a document was embedded in between, **the two halves disagree**. You would restore a knowledge base whose metadata references vectors that are not in the index.

So the backup briefly **pauses** the Open WebUI container for the capture. `docker pause` freezes the process with `SIGSTOP` — no shutdown, no restart, no dropped connections, typically 2–10 seconds. Everything is then captured from a single frozen point in time. The container is unpaused before the slow upload begins, and also from the EXIT trap, so a crash mid-run cannot leave it frozen.

Set `BACKUP_NO_PAUSE=1` to skip this. Zero downtime, but only safe if you are certain nothing is being embedded during the backup window.

If a consistent online snapshot cannot be taken at all, the script **stops Open WebUI, copies cold, and restarts it**. A brief outage is strictly better than a backup you cannot restore. It never silently falls back to a hot copy.

### Incomplete runs are reported honestly

Some runs cannot capture everything. A discovered path fails the allow-list, an entry under `hermes_data` cannot be read, an `rsync` finishes partial (exit 23 or 24), a database cannot be captured and still fails `quick_check` after the cold copy. In every case the script does **not** pretend the snapshot is whole:

- it still uploads what it has, tagged `complete:false`;
- it logs `backup_incomplete` (never `backup_success`);
- it exits with code **3**. No unit retries it: every unit except the capture unit lists 3 in `RestartPreventExitStatus=`, and the capture unit has no `Restart=` policy at all. The system-mode units also list 3 in `SuccessExitStatus=` (so systemd does not report a successful-but-INCOMPLETE run as a failed unit); the upload and check units gained that line so an INCOMPLETE upload or check is no longer shown as a failure. It is the user-mode units that carry `RestartPreventExitStatus=` alone, with no `SuccessExitStatus=`.

`backup_failed` (exit 1) stays reserved for a run that aborted. An incomplete run is a distinct, non-retryable outcome. `doctor.sh` counts both `backup_failed` and `backup_incomplete` **since the last `backup_success`**, so a clean run resets the counters, and it counts **distinct runs** (distinct `ts=` values), not lines: a failed run writes two `backup_failed` lines, so the count is per run.

The backup unit also **bounds its own retries**. `hybrid-ai-backup.service` sets `StartLimitIntervalSec=1h` and `StartLimitBurst=2`, so even a hard failure (exit 1) can be retried at most twice in an hour before systemd gives up. This is what stops a run that fails the same way every time from trying again every 15 minutes.

### When the backup cannot read the data

With `HYBRID_AI_UID` set, the stack writes `hermes_data` as that uid — the container's own user, not yours. The nightly backup runs as *you*, from a systemd **user** unit. If your account cannot read that tree, nothing under it can be captured, and no retry will ever change that.

Before it touches a single container, `backup.sh` checks whether it can read `hermes_data` and `webui_data`. If it cannot, it:

- logs `backup_data_unreadable` with the tree name and **both** uids (the owner, and the uid the backup runs as) — and prints the same pair in plain English, with the fix;
- marks the run **INCOMPLETE** and exits **3**, so systemd never retries it;
- **stops no container**. There is nothing to gain from an outage here, so there is no cold copy and no stopped `hermes-agent`.

The fix is to run the backup as the account that owns the data, or to grant this account read access to the tree.

### `BACKUP_ALLOW_AGENT_STOP`

The cold-copy fallback stops the container that owns a database that could not be captured online, copies the database cold, and restarts the container. For Open WebUI that is a brief, harmless outage. For `hermes-agent` it is **not** harmless: stopping the agent kills any agent session that is running at that moment.

So the backup refuses to stop `hermes-agent` unless you explicitly opt in:

```bash
BACKUP_ALLOW_AGENT_STOP=1 ./backup/backup.sh   # or set it in the unit's Environment=
```

- **What it does:** permits the cold-copy fallback to stop `hermes-agent` (and only that container) so a `hermes_data` database can be copied cold.
- **Why it is off by default:** stopping the agent destroys in-flight work for a database that a retry could not capture anyway.
- **When to set it:** only when you accept that a backup run may interrupt an active agent session — for example, a one-off manual run to recover a specific database.
- **When it is not set:** the cold copy *declines* to stop the agent, logs `cold_copy_agent_stop_declined`, leaves that database out of the snapshot, and marks the run INCOMPLETE (exit 3). It never stops the container and never fails the run.

`restore.sh --test` closes the loop by running `PRAGMA integrity_check` against the recovered databases, which is SQLite auditing its own files. That is the step that proves the whole chain works.

---

## Why restic and R2

**restic** encrypts on the Pi before anything is transmitted, so Cloudflare holds ciphertext it cannot read. It deduplicates at block level, so the second backup of a 2 GB database uploads only the few megabytes that changed. And it keeps snapshots, so you can recover "last Tuesday", not merely "latest" — which is what saves you when corruption went unnoticed for a week.

**Cloudflare R2** charges roughly \$0.015/GB/month and **nothing for egress**. That second point matters more than it looks: with most providers, the day you restore 50 GB is the day you get an unexpected bill. Restoring from R2 costs nothing in bandwidth.

A typical setup — a few thousand chats, a few hundred documents — lands well under a dollar a month.

---

## Setup

`./install.sh` walks you through this interactively. What it needs first:

### 1. Create an R2 bucket

Cloudflare dashboard → **R2 object storage** → **Create bucket**. Name it `hybrid-ai-backup`. Any location works; pick one near you.

### 2. Create a scoped API token

**R2** → **Overview** → **Manage** next to **API Tokens** → **Create Account API token**:

| Setting | Value | Why |
|---|---|---|
| Permission | **Object Read & Write** | Not *Admin*. This token cannot create or delete buckets, only work with objects |
| Buckets | **Apply to specific buckets only** → your bucket | Least privilege. A leaked token reaches one bucket, nothing else |

Copy the **Access Key ID** and **Secret Access Key** now — the secret is shown once.

You also need your **account ID**, visible on the R2 Overview page. The endpoint is derived from it: `https://<ACCOUNT_ID>.r2.cloudflarestorage.com`.

### 3. Run the installer

```bash
./install.sh
```

It prompts for those four values, generates a strong repository password, writes everything to `~/.config/hybrid-ai-backup/` with mode 0600, initialises the encrypted repository, installs the systemd timers, and offers to run the first backup.

### 4. Store the repository password off the Pi

```bash
cat ~/.config/hybrid-ai-backup/repo-password
```

Put it in a password manager. **Now, not later.**

restic has no recovery mechanism. If the drive dies and the password dies with it, your backups are permanently unreadable — by design. That property is exactly what makes the encryption trustworthy, and exactly what makes this step non-optional.

---

## Where credentials live

```
~/.config/hybrid-ai-backup/          (0700)
├── r2.env           (0600)  R2 keys + repository URL
└── repo-password    (0600)  the encryption key
```

**Deliberately outside the git repository.** No `git add`, no stray `tar czf` of the project folder, and no CI checkout can sweep them up. They are also kept separate from `.env`, so a compromise of the application stack does not automatically hand over the ability to destroy your backup history.

Both scripts **refuse to run** if either file is not mode 0600 — with one
exception for systemd: a file resolved under `$CREDENTIALS_DIRECTORY` (the
`LoadCredential=` tmpfs copy, materialised 0400/0440 root-owned and recreated on
every start) is accepted at mode 0400 or 0440, because it can never be
`chmod 600`. A file read from `HYBRID_AI_BACKUP_CRED_DIR` — the user-mode path —
still has to be exactly 0600, and the failure message keeps the `chmod 600`
advice. On the systemd path the message names the real rule instead (no
impossible `chmod` advice). They also
**refuse to run** when `HYBRID_AI_BACKUP_CRED_DIR` is, or is inside,
`HYBRID_AI_APP_DIR`, `HYBRID_AI_DATA_DIR` or `HYBRID_AI_WORK_DIR`: a credential
directory inside one of those trees would be swept up by a git operation or by
the very data a restore writes. In user mode `HYBRID_AI_BACKUP_CRED_DIR` is
`BACKUP_CONF_DIR`, so the boundary is the same one as before.

`backup.sh` runs that check only on the phases that actually read a credential
file. A `--stage-only` capture (the system-mode capture unit) loads no
credential and uses no network, so it is exempt; every other phase, including
`--dry-run`, still refuses a misplaced credential directory. `restore.sh` always
reads a credential file, so its check always applies.

In system mode the units read the credentials from the root-owned credstore
`/etc/credstore/hybrid-ai-backup/` via `LoadCredential=`; when that is set, the
systemd-provided `$CREDENTIALS_DIRECTORY` takes precedence and the location
check does not apply (systemd chose a private tmpfs it owns). A manual
system-mode `backup.sh` or `restore.sh` run reads them from
`HYBRID_AI_BACKUP_CRED_DIR`, which resolves to that same credstore.

---

## Where the data lives

Both scripts take every host path from the shared helper
`scripts/lib/hybrid-ai-env.sh`. With no settings the layout is exactly the
default. When `HYBRID_AI_DATA_DIR` and `HYBRID_AI_WORK_DIR` move, the snapshot
layout does **not** change: the manifest is still "layout v2", with paths
relative to `HYBRID_AI_DATA_DIR` and the same names. A snapshot taken before a
relocation restores into the split layout.

| Setting | Used for | Default |
|---|---|---|
| `HYBRID_AI_DATA_DIR` | the data being backed up (`webui_data/`, `hermes_data/`, `ollama_data/`) | the repo directory |
| `HYBRID_AI_LOG_DIR` | the default location of `backup.log` in user mode | the repo directory |
| `BACKUP_LOG` | the backup log file; in system mode it defaults to the units' `LogsDirectory=` (`/var/log/hybrid-ai-backup/backup.log`), in user mode to `$HYBRID_AI_LOG_DIR/backup.log` | mode-dependent |
| `HYBRID_AI_WORK_DIR` | `.backup-staging`, `.restore-work`, `.restore-test-*` | the repo directory |
| `HYBRID_AI_ENV_FILE` | the env file, staged as `env/.env` | `$HYBRID_AI_APP_DIR/.env`; if absent, `HYBRID_AI_ENV_FILE_FALLBACK` (default `/etc/hybrid-ai/hybrid-ai.env`) when it exists |
| `BACKUP_GROUP_GID` | the ONE supplementary group the status container is given so it can read `BACKUP_LOG`; `install.sh` resolves the `hybrid-ai-backup` group's gid by name in system mode, and uses the container's own primary gid in user mode | mode-dependent |
| `BACKUP_CONF_DIR` | the user-mode credential directory | `~/.config/hybrid-ai-backup` |
| `HYBRID_AI_BACKUP_CRED_DIR` | the directory the scripts read credentials from (default follows the mode: `BACKUP_CONF_DIR` in user mode, `/etc/credstore/hybrid-ai-backup` in system mode) | mode-dependent |
| `RESTIC_CACHE_DIR` | the restic cache (`<repo>/snapshots/<prefix>/` and `<repo>/index/` live under it) | `~/.cache/restic`; `/var/cache/hybrid-ai-backup` in system mode |

Pre-restore safety copies (`webui_data.pre-restore-*`,
`hermes_data.pre-restore-*`) still stay beside the data, on the same filesystem.

### The backup log's mode and group contract

`backup.log` is written by this directory's scripts and read by the status
container, which is a DIFFERENT identity. Its mode therefore follows the mode:

| Backup mode | Log mode | Owner | Who can read it |
|---|---|---|---|
| `user` (default) | `0600` | the invoking account | that account only — unchanged |
| `system` | `0640` | `hybrid-ai-backup:hybrid-ai-backup` | the backup account and its group |

The log is **never** mode `0644`. In system mode the status container reads it
with exactly one supplementary group, the `hybrid-ai-backup` gid
(`BACKUP_GROUP_GID` in `docker-compose.yml`); it keeps uid 1000 and its primary
gid for the Docker socket, and stays read-only with every capability dropped.

`install.sh` STEP 7 repairs an EXISTING log as root: `chown
hybrid-ai-backup:hybrid-ai-backup` and `chmod 640`, so a host deployed before
this contract converges on the next deploy with no by-hand step. STEP 8 writes
`BACKUP_GROUP_GID` as `${BACKUP_GROUP_GID:-<resolved>}`, so an owner override
survives reinstalls, and it fails closed when the `hybrid-ai-backup` group
cannot be resolved by name.

Why this exists: with mode 0600 the status container could not open the file, so
the Backups tile reported a quiet "no log" while the writer's log held a
success. The reader was blind, not the backup.

---

## Daily use

```bash
./backup/backup.sh                    # run a backup now
./backup/backup.sh --dry-run          # show what would be uploaded
./backup/backup.sh --check            # verify integrity (slow, reads data)
./backup/restore.sh --list            # list snapshots
./backup/restore.sh --test            # rehearse a restore — DO THIS QUARTERLY
./backup/restore.sh                   # real restore, interactive
```

Schedule status:

```bash
systemctl --user list-timers 'hybrid-ai-*'
journalctl --user -u hybrid-ai-backup.service -n 50
grep '^EVENT' backup.log | tail -20
```

### Manual runs on a system-mode host

The commands above assume **user mode** (the default): they run as your login
account and resolve the user-mode paths. On a host migrated to system mode
(`HYBRID_AI_BACKUP_MODE=system`, layout at `/etc/hybrid-ai/hybrid-ai.env`), a
bare `sudo ./backup/backup.sh` (or `restore.sh`) runs as root and resolves
**user-mode** paths, so it looks for credentials in `/root/.config/hybrid-ai-backup`
and dies with `No credentials at /root/.config/hybrid-ai-backup/r2.env`.

Run the script with the layout file named explicitly instead. That is what the
units do, and it resolves the system-mode credential directory and log path:

```bash
sudo env HYBRID_AI_ENV_FILE=/etc/hybrid-ai/hybrid-ai.env ./backup/backup.sh --check
sudo env HYBRID_AI_ENV_FILE=/etc/hybrid-ai/hybrid-ai.env ./backup/restore.sh --test
```

Prefer the units for a normal run — they carry the sandbox and the credentials
themselves:

```bash
sudo systemctl start hybrid-ai-backup-capture.service    # capture, then upload
sudo systemctl start hybrid-ai-backup-check.service      # monthly integrity check
```

In system mode the log is `/var/log/hybrid-ai-backup/backup.log` (the same file
`doctor.sh` reads), so watch it with `sudo grep '^EVENT' /var/log/hybrid-ai-backup/backup.log`.

The status page reads that same file. `scripts/lib/hybrid-ai-env.sh` resolves
`BACKUP_LOG` once from the mode, `install.sh` writes the resolved value into the
stack env file, and `docker-compose.yml` mounts exactly that path read-only into
the status container. There is one resolved path, not two: the reader cannot
drift from the writer, so a real success shows as `Backup: ok`.

### Retention

Seven daily, four weekly, six monthly snapshots — about 17 restore points covering six months, with deduplication meaning they cost far less than 17× a single backup. Override with `KEEP_DAILY`, `KEEP_WEEKLY`, `KEEP_MONTHLY`.

---

## Restoring

### Onto the same Pi

```bash
./backup/restore.sh
```

Pick a snapshot. The script verifies the recovered databases **before** touching anything live, moves your current `webui_data` to a timestamped safety copy rather than deleting it, requires you to type `RESTORE`, stops the container, restores documents then databases, and clears stale WAL files.

### Onto a brand-new Pi

1. Work through **Prerequisites** in the [main README](../README.md)
2. `git clone` the repository
3. Recreate `~/.config/hybrid-ai-backup/` with your R2 credentials and the password from your password manager:

   ```bash
   mkdir -p ~/.config/hybrid-ai-backup && chmod 700 ~/.config/hybrid-ai-backup
   cat > ~/.config/hybrid-ai-backup/r2.env <<'EOF'
   RESTIC_REPOSITORY=s3:https://<ACCOUNT_ID>.r2.cloudflarestorage.com/<BUCKET>
   RESTIC_PASSWORD_FILE=/home/pi/.config/hybrid-ai-backup/repo-password
   AWS_ACCESS_KEY_ID=<KEY_ID>
   AWS_SECRET_ACCESS_KEY=<SECRET>
   AWS_DEFAULT_REGION=auto
   EOF
   chmod 600 ~/.config/hybrid-ai-backup/r2.env
   # then write the password into repo-password and chmod 600 it
   ```

4. `./backup/restore.sh --latest` — this restores `.env` too, so your RunPod settings come back automatically
5. During the restore, answer **yes** when it offers to re-pull your Ollama models — it knows which ones you had
6. `sudo tailscale up` — machine identity is not transferable, so the new Pi must re-authenticate
7. `./install.sh`

At that point the UI should show your chats, documents, knowledge bases, connections, users, and your RunPod pipe already enabled with its valve settings intact.

### Recovering a single file

```bash
set -a; source ~/.config/hybrid-ai-backup/r2.env; set +a
restic restore latest --target /tmp/recover --include '*/files/docs/thatfile.pdf'
```

---

## Verify quarterly

```bash
./backup/restore.sh --test
```

This performs a complete restore into a scratch directory and runs SQLite's integrity check on every recovered database. Nothing live is touched, so it is safe on a working system.

An untested backup is a hypothesis. Put a recurring reminder in your calendar — the monthly `--check` timer verifies the *repository*, but only `--test` proves the *data* comes back usable.

---

## Hardening further

### Ransomware resistance

The default setup has one real weakness: the credentials on your Pi can both write *and* delete. An attacker with access to the Pi could run `restic forget --prune` and destroy your history before encrypting your live data. That is the standard second stage of a targeted ransomware run.

restic's `backup` operation is inherently additive — it never modifies or removes existing objects — so it works cleanly with immutable storage. The only complication is that restic writes lock objects it later deletes, so exclude the `/locks` path from any retention lock.

To harden: enable **R2 Object Lock** on the bucket, and issue the Pi a token that cannot delete. Retention then has to move off the Pi, because a client that can prune is a client that can destroy history. Run `restic forget --prune` manually from a trusted machine instead, and drop the `--prune` step from the nightly run.

Worth doing if this data matters to you. Not necessary on day one.

### Second copy

R2 is one provider. For genuinely important data, run a second repository to a local USB disk:

```bash
RESTIC_REPOSITORY=/mnt/usb-backup RESTIC_PASSWORD_FILE=~/.config/hybrid-ai-backup/repo-password ./backup/backup.sh
```

Two providers, two failure modes, one password to remember.

---

## System mode (fresh install and migration)

System mode runs the backup as two system units under a dedicated, unprivileged
account. It exists so the nightly backup can read ALL durable state — including
the container-owned data trees — without running as root and without putting any
account in the `docker` group. The two units split the job:

| Unit | Reads durable state | Docker | Network | Credentials |
|---|---|---|---|---|
| `hybrid-ai-backup-capture.service` | yes, with `CAP_DAC_READ_SEARCH` | no | no (`PrivateNetwork=yes`) | no |
| `hybrid-ai-backup-upload.service` | no | no | yes | yes (`LoadCredential=`) |

The capture writes a consistent copy to its `StateDirectory`; the upload sends
that copy to R2 and holds the only copy of the credentials. Neither unit can do
the other's job, so a compromise of either half is contained. A single fixed,
root-owned helper (`backup-containers.sh`) bridges the only gap — pausing the
containers for a point-in-time capture — and it never starts or stops a
container.

### What card F creates (one bootstrap, on the host)

Installing the account and the credentials on a host is card F's job. It is the
ONLY manual step; everything after it runs from the units. Card F must create:

1. **The account** — a no-login system account `hybrid-ai-backup`
   (`User=`/`Group=` in the units). It is NOT added to the `docker` group.
2. **The runtime directory** — `/run/hybrid-ai-backup`, owned by that account
   (`RuntimeDirectory=hybrid-ai-backup` recreates it per run).
3. **The credential store** — `/etc/credstore/hybrid-ai-backup/` (root, mode
   `0700`), holding:
   - `/etc/credstore/hybrid-ai-backup/r2.env` (root, mode `0600`)
   - `/etc/credstore/hybrid-ai-backup/repo-password` (root, mode `0600`)

   Every phase that reads a credential file looks here, because
   `HYBRID_AI_BACKUP_CRED_DIR` resolves to this directory in system mode: the
   upload unit via `LoadCredential=` (which sets `$CREDENTIALS_DIRECTORY`), and
   any manual `backup.sh` / `restore.sh` run directly from here.
4. **The layout env file** — `/etc/hybrid-ai/hybrid-ai.env`, root-owned, mode
   `0644`, with these settings (names and paths only, never a secret):
   - `HYBRID_AI_APP_DIR=/opt/hybrid-ai`
   - `HYBRID_AI_ENV_FILE=/etc/hybrid-ai/hybrid-ai.env`
   - `HYBRID_AI_STACK_ENV_FILE=/etc/hybrid-ai/stack.env`
   - `HYBRID_AI_DATA_DIR=/var/lib/hybrid-ai`
   - `HYBRID_AI_WORK_DIR=/var/lib/hybrid-ai/work`
   - `HYBRID_AI_LOG_DIR=/var/log/hybrid-ai`
   - `OPENHANDS_WORKSPACE` (`/var/lib/hybrid-ai/agent-workspace`)
   - `AGENT_REPOS_DIR` (`/var/lib/hybrid-ai/agent-repos`)
   - `OPENHANDS_STATE_DIR` (`/var/lib/hybrid-ai/openhands`)
   - `RESTIC_CACHE_DIR=/var/cache/hybrid-ai-backup`
   - `HYBRID_AI_HERMES_HOME_DIR=/var/lib/hybrid-ai/hermes-home`
   - `HYBRID_AI_BACKUP_MODE=system`
   - `BACKUP_CONTAINER_CONTROL=external`
   - `HYBRID_AI_UID` / `HYBRID_AI_GID` (the `hybrid-ai` account's ids)

   The units carry their OWN `Environment=` values
   (`HYBRID_AI_ENV_FILE=/etc/hybrid-ai/hybrid-ai.env` **and**
   `HYBRID_AI_STACK_ENV_FILE=/etc/hybrid-ai/hybrid-ai.env`,
   `HYBRID_AI_BACKUP_MODE=system`, `BACKUP_CONTAINER_CONTROL=external`,
   `HYBRID_AI_WORK_DIR=/var/lib/hybrid-ai-backup`,
   `RESTIC_CACHE_DIR=/var/cache/hybrid-ai-backup`). A systemd `Environment=`
   value takes precedence over the env file, so a drifted layout file cannot
   change what a unit does. Only the paths a unit does NOT pin come from
   `/etc/hybrid-ai/hybrid-ai.env`.

   **Cache ownership is converged by the installer, not by hand.** The units'
   `CacheDirectory=hybrid-ai-backup` chowns only the top directory, so a nested
   directory left behind by an earlier root run stays root-owned and restic fails
   three levels down (`<repo>/snapshots/<prefix>/`). Two things prevent that:

   - `install.sh` runs `reconcile_backup_cache_ownership` on **every**
     installation, because it rides the scheduler-repair path. It walks the
     resolved cache with `find "$cache" ! -user hybrid-ai-backup -print -quit`
     and, only when a foreign-owned entry exists, runs
     `chown -R hybrid-ai-backup:hybrid-ai-backup "$cache"` and logs
     `backup_cache_ownership_repaired`. A second run repairs nothing and logs no
     repair event. It only ever touches that one path: never
     `/var/lib/hybrid-ai-backup` (staging, `StateDirectory=`) and never
     `/etc/credstore/hybrid-ai-backup`. Symlinks inside the cache are warned
     about, never followed. A missing `hybrid-ai-backup` account warns and logs
     `backup_cache_reconcile_skipped reason=no_account`; it is never fatal.
   - A root-invoked `backup.sh` -- `--init` and the first-backup prompt -- gets
     its **own** cache, `RESTIC_CACHE_DIR=/var/cache/hybrid-ai-backup-root`,
     through the `RESTIC_CACHE_DIR` override rather than `systemd-run`. So no
     entry under `/var/cache/hybrid-ai-backup` is root-owned after setup, while
     `--init` on a host with no repository yet still works.

   In system mode an unusable cache with no writable fallback is **fatal**: the
   run aborts before staging, in seconds, with `restic_cache_unusable` carrying
   the offending `path`, its `owner` (uid:gid), its `mode` and a `fix=` hint. User
   mode keeps the older behaviour: it unsets `RESTIC_CACHE_DIR` and continues.

   `BACKUP_LOG` is **not** pinned by the units. The shared helper resolves it
   from the mode: in system mode it is `/var/log/hybrid-ai-backup/backup.log`,
   the units' `LogsDirectory=` (the one directory systemd grants write access to
   under `ProtectSystem=strict`); in user mode it stays
   `$HYBRID_AI_LOG_DIR/backup.log`. `doctor.sh` and the status page read the SAME
   resolved path, so they watch the file the units actually write. The status
   service's bind source is `${BACKUP_LOG:?...}`, written into the stack env file
   by `install.sh`; an unset value refuses the compose parse. The upload and check units each
   carry `LogsDirectory=hybrid-ai-backup`; the capture unit already did.

   `HYBRID_AI_STACK_ENV_FILE` is pinned at the **0644 layout file**, not the
   0600 root-only `stack.env`, in every system-mode unit. The units run as
   `hybrid-ai-backup` with no `CAP_DAC_READ_SEARCH`, and the shared env helper
   fails closed when a file it is told to read exists but cannot be read; without
   the pin the unit would exit 1 before restic ran. The layout file holds only
   names and paths, never a secret, so the backup account needs no access to
   `stack.env`. This mirrors the forced-command deploy fix.
5. **The units** — `install.sh`, run as root, installs `backup/system/*` into
   `/etc/systemd/system/`, daemon-reloads, and enables
   `hybrid-ai-backup-capture.timer` and `hybrid-ai-backup-check.timer`.

When `HYBRID_AI_BACKUP_MODE` is unset (or `user`), none of this applies and the
per-user units behave exactly as before.

### Verify a run

```bash
systemctl list-timers 'hybrid-ai-*'                  # see the next capture
systemctl start hybrid-ai-backup-capture.service     # run one now
journalctl --system -u hybrid-ai-backup-capture.service -n 50
journalctl --system -u hybrid-ai-backup-upload.service  -n 50
systemctl show -p Result hybrid-ai-backup-capture.service
cat /var/lib/hybrid-ai-backup/.backup-staging/STATUS                 # complete | incomplete
```

A capture that finishes with `STATUS` `complete` starts the upload immediately
(`OnSuccess=`), and the uploaded snapshot is tagged `complete:true`. An
`incomplete` capture still uploads (so partial data is kept) but is tagged
`complete:false` and never retried, because the data was already missing when it
was captured.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `No credentials at ~/.config/...` | Backups never configured | Run `./install.sh` |
| `No credentials at /root/.config/hybrid-ai-backup/r2.env` on a system-mode host | The run resolved USER-mode paths because the layout file was not found; the credentials live in `/etc/credstore/hybrid-ai-backup` | Run it as `sudo env HYBRID_AI_ENV_FILE=/etc/hybrid-ai/hybrid-ai.env ./backup/backup.sh ...`, or start the unit: `sudo systemctl start hybrid-ai-backup-capture.service`. A bare `sudo ./backup/...` picks up the layout fallback (`/etc/hybrid-ai/hybrid-ai.env`) when `$HYBRID_AI_APP_DIR/.env` is absent, so it resolves system-mode paths too |
| `tee: /var/log/hybrid-ai-backup/backup.log: Read-only file system` | A system-mode unit writing its log outside its `LogsDirectory=` (an old unit file without `LogsDirectory=hybrid-ai-backup`) | Update the units: re-run `./install.sh` as root, then `sudo systemctl daemon-reload` |
| `unable to open cache: ... permission denied` | A directory under the restic cache (`<repo>`, `<repo>/snapshots/<prefix>/`, `<repo>/index/`) is owned by another uid, usually after an earlier root run. `backup.sh` probes to that depth, so it sees this | Self-healing in both modes: `backup.sh` logs `restic_cache_unwritable` and falls back to a writable cache (`restic_cache_fallback`). In SYSTEM mode the fallback is the last resort: with no writable fallback the run aborts in seconds with `restic_cache_unusable` naming the path, owner and mode. `./install.sh` as root reconciles the ownership on its next run (`backup_cache_ownership_repaired`); by hand it is `sudo chown -R hybrid-ai-backup:hybrid-ai-backup /var/cache/hybrid-ai-backup` |
| `has permissions 644; expected 600` | Permissions drifted on a `HYBRID_AI_BACKUP_CRED_DIR` file | `chmod 600 ~/.config/hybrid-ai-backup/*` |
| `has permissions ...; a systemd LoadCredential copy must be 0400 or 0440` | A `$CREDENTIALS_DIRECTORY` copy has an unexpected mode | None: systemd materialises that tmpfs copy (0400/0440) on every start. If it reports another mode, check the `LoadCredential=` source file's mode |
| `restic init failed` | Wrong account ID, bucket, or token | Verify the endpoint URL and that the token has Object Read & Write on that bucket |
| `Could not capture ... via SQLite` | The database could not be captured online (e.g. `sqlite3` missing, or a WAL database in a directory the user cannot write) | `sudo apt-get install -y sqlite3`. The script falls back to a verified cold copy; if that also cannot capture it, the run is marked INCOMPLETE (exit 3), not failed |
| `backup_incomplete` in the log, exit code 3 | The run uploaded but missed durable state (a rejected path, an unreadable entry, a partial rsync, an unverifiable database) | Check the events around it (`db_path_rejected`, `hermes_data_unreadable`, `rsync_partial`, `backup_data_unreadable`, `cold_copy_failed`). This is not retried automatically, by design |
| `backup_data_unreadable` | The backup runs as an account that cannot read `hermes_data` or `webui_data` (usually because `HYBRID_AI_UID` makes the container own the tree). The log prints both uids | Run the backup as the account that owns the data, or grant this account read access to it. Until then the run is INCOMPLETE (exit 3) and stops no container |
| `cold_copy_agent_stop_declined` | A `hermes_data` database could not be captured online and the cold copy refused to stop `hermes-agent`, because stopping it kills in-flight agent sessions | Expected unless you opt in. The database stays out of the snapshot and the run is INCOMPLETE. To allow it, set `BACKUP_ALLOW_AGENT_STOP=1` |
| `cold_copy_failed` | A database could not be captured even with its container stopped (so it failed `quick_check` cold too) | It is left out of the snapshot and the run is marked INCOMPLETE (exit 3). A retry will not fix it: investigate why that database cannot be read, then run again |
| Backup never runs overnight | Linger not enabled | `sudo loginctl enable-linger $USER` |
| `repository is already locked` | A previous run was killed | `restic unlock` after confirming nothing is running |
| Integrity check fails | Repository corruption | Do not prune. Try `restic repair index`, and treat existing snapshots as suspect |
| Backup is slow | First run uploads everything | Subsequent runs are incremental and typically finish in seconds |
| `wrong password or no key found` | Wrong repository password | There is no recovery. This is why it goes in a password manager |
