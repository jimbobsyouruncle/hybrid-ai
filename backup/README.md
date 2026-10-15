# `backup/` — Encrypted Offsite Backups

| File | Purpose |
|---|---|
| `backup.sh` | Snapshots your data consistently and uploads it, encrypted, to Cloudflare R2 |
| `restore.sh` | Brings it all back — including a rehearsal mode that touches nothing live |
| `hybrid-ai-backup.{service,timer}` | Nightly schedule at 03:15 |
| `hybrid-ai-check.{service,timer}` | Monthly integrity verification |

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
- it exits with code **3**, which both backup units list in `RestartPreventExitStatus=` so there is no 15-minute retry loop.

`backup_failed` (exit 1) stays reserved for a run that aborted. An incomplete run is a distinct, non-retryable outcome. `doctor.sh` counts both `backup_failed` and `backup_incomplete` **since the last `backup_success`**, so a clean run resets the counters.

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

Both scripts **refuse to run** if either file is not mode 0600. They also
**refuse to run** when `BACKUP_CONF_DIR` is, or is inside, `HYBRID_AI_APP_DIR`,
`HYBRID_AI_DATA_DIR` or `HYBRID_AI_WORK_DIR`: a credential directory inside one
of those trees would be swept up by a git operation or by the very data a
restore writes.

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
| `HYBRID_AI_LOG_DIR` | `backup.log` | the repo directory |
| `HYBRID_AI_WORK_DIR` | `.backup-staging`, `.restore-work`, `.restore-test-*` | the repo directory |
| `HYBRID_AI_ENV_FILE` | the env file, staged as `env/.env` | `$HYBRID_AI_APP_DIR/.env` |
| `BACKUP_CONF_DIR` | the credentials above | `~/.config/hybrid-ai-backup` |
| `RESTIC_CACHE_DIR` | the restic cache | `~/.cache/restic` |

Pre-restore safety copies (`webui_data.pre-restore-*`,
`hermes_data.pre-restore-*`) still stay beside the data, on the same filesystem.

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

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `No credentials at ~/.config/...` | Backups never configured | Run `./install.sh` |
| `has permissions 644; expected 600` | Permissions drifted | `chmod 600 ~/.config/hybrid-ai-backup/*` |
| `restic init failed` | Wrong account ID, bucket, or token | Verify the endpoint URL and that the token has Object Read & Write on that bucket |
| `Could not capture ... via SQLite` | The database could not be captured online (e.g. `sqlite3` missing, or a WAL database in a directory the user cannot write) | `sudo apt-get install -y sqlite3`. The script falls back to a verified cold copy, then fails the run if that also fails |
| `backup_incomplete` in the log, exit code 3 | The run uploaded but missed durable state (a rejected path, an unreadable entry, a partial rsync, an unverifiable database) | Check the events around it (`db_path_rejected`, `hermes_data_unreadable`, `rsync_partial`). This is not retried automatically, by design |
| Backup never runs overnight | Linger not enabled | `sudo loginctl enable-linger $USER` |
| `repository is already locked` | A previous run was killed | `restic unlock` after confirming nothing is running |
| Integrity check fails | Repository corruption | Do not prune. Try `restic repair index`, and treat existing snapshots as suspect |
| Backup is slow | First run uploads everything | Subsequent runs are incremental and typically finish in seconds |
| `wrong password or no key found` | Wrong repository password | There is no recovery. This is why it goes in a password manager |
