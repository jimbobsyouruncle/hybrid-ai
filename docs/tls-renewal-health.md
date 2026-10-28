# TLS renewal health, audit and alerting

This page covers the observability layer around TLS. It answers three questions:

1. Is the certificate the host serves healthy right now?
2. Was a certificate issued or renewed, and when?
3. Is anyone told when it goes wrong?

Caddy owns issuance and renewal. Nothing here issues or renews a certificate.

## Fixed thresholds and exit codes

`scripts/tls-check.sh` uses one table. The values are fixed; only the two
thresholds are flags.

`days = floor((notAfter - now) / 86400)`

| Situation                                  | Severity   | Exit |
|--------------------------------------------|------------|------|
| TLS disabled                               | SKIPPED    | 3    |
| connect fails / no certificate             | missing    | 3    |
| chain does not verify                      | missing    | 3    |
| SAN does not contain the hostname          | missing    | 3    |
| staging issuer while `ACME_CA=production`   | missing    | 3    |
| `days <= 0` (expired)                      | critical   | 2    |
| `days < 7`                                 | critical   | 2    |
| `days < 14`                                | warn       | 1    |
| anything else                              | ok         | 0    |

- `--warn-days` defaults to 14, `--crit-days` defaults to 7. Both are printed
  on every per-host line so a log explains itself.
- The exit code is the WORST severity across every host checked.
- Exit 3 for "TLS disabled" is a deliberate skip, not an error. Do not treat it
  as a failure in a wrapper.
- The script never reads a private key. It reads the leaf certificate the
  endpoint serves.
- When a certificate is present but the chain does not verify, the script still
  reports the SAN and the days left. A staging certificate therefore stays
  diagnosable instead of being reported as unreachable.
- The staging-issuer row is a distinct case. When `ACME_CA` resolves to
  production but the served certificate issuer is a Let's Encrypt staging CA
  (issuer `CN`/`O` carrying `(STAGING)` or `Fake LE`), the script exits 3 with
  `staging issuer while ACME_CA is production`. That means the re-render never
  took effect or a stale certificate is deployed. When `ACME_CA` is staging, or
  not set at all, this case never fires: there is no new failure for a staging
  install. Expiry is still tested first, so an expired staging certificate
  reports `expired` (exit 2).

## Why there is no second renewer

Do not add certbot, lego, or any timer that issues or renews a certificate.

- Caddy renews inside a window of about 30 days before expiry.
- On renewal Caddy swaps the new certificate into memory. There is no reload
  and no restart.
- Caddy runs with `restart: unless-stopped`, so it comes back after a reboot
  with the same managed storage.

A second issuer would compete with Caddy for the same names, trip ACME rate
limits, and leave two sources of truth. The watchdog in this repository proves
health; it never changes a certificate.

## The watchdog timer

`deploy/hybrid-ai-tls-check.service` runs two commands, in this order:

```
scripts/tls-audit.sh
scripts/tls-check.sh --quiet --audit --alert
```

The audit runs FIRST because it is the only record that a certificate was
issued or renewed. The health check runs second. Both run once, with a
5-minute start timeout and no `Restart=`. A failing check must not loop. The
service runs with `NoNewPrivileges=true`, `PrivateTmp=true`,
`ProtectSystem=strict`, `ProtectHome=read-only`, and `ReadWritePaths` limited to
the log directory. That is the only writable path it needs.

`deploy/hybrid-ai-tls-check.timer` runs it daily at 06:10 with
`Persistent=true` and `RandomizedDelaySec=5min`. `Persistent=true` plus an
enabled timer is what makes the check run after a reboot: systemd remembers the
last run and fires a missed one when the host is back.

`install.sh` installs both units and enables the timer ONLY when `TLS_ENABLED`
is true in the resolved stack env file. With TLS off it prints
`(skipped: TLS disabled)` and changes nothing, so a TLS-off install is
behaviourally identical to before.

Verify after a reboot:

```
systemctl --user list-timers hybrid-ai-tls-check.timer
systemctl --user is-enabled hybrid-ai-tls-check.timer
journalctl --user -u hybrid-ai-tls-check.service --since today
```

## Audit log: proof of renewal without Docker logs

Caddy renews in memory, so there is no container restart to look for. The audit
script compares certificate serials instead. A NEW SERIAL IS PROOF OF A RENEWAL.

`scripts/tls-audit.sh` walks Caddy's managed storage:

```
<data>/caddy/caddy/certificates/<acme-ca-dir>/<host>/<host>.crt
```

That root is derived in ONE place, `scripts/lib/hybrid-ai-env.sh`, as
`HYBRID_AI_CADDY_CERT_ROOT="${HYBRID_AI_CADDY_DATA_DIR}/caddy/certificates"`.
`tls-audit.sh` and `tls-dry-run-renewal.sh` both default their certificate root
to that exported value (`--cert-root` still wins). If Caddy's `/data` mount ever
moves, the helper constant is the only line to edit; no script hardcodes the
literal path.

For each host it reads the leaf with openssl (never the `.key`) and compares the
serial with the last recorded serial in the state file. One line is appended to
the audit log only when something changed:

```
ts=<ISO8601> host=<h> event=issue|renew|renew-overdue|missing outcome=success|pending|failure serial=<S> not_after=<ISO> issuer="<CN>" acme_ca=<ca-dir>
```

| Situation                                                    | Event           | Outcome |
|--------------------------------------------------------------|-----------------|---------|
| first serial ever seen for a host                            | `issue`         | success |
| serial changed                                               | `renew`         | success |
| serial unchanged and `days <= 30`                             | `renew-overdue` | pending |
| certificate recorded earlier, now absent                      | `missing`       | failure |

Exit codes: 0 nothing wrong or nothing changed, 1 missing or unreadable
certificate storage, 3 the certificate root does not exist yet.

The log is append-only. The script never truncates and never rewrites history.

`scripts/tls-check.sh --audit` also appends one message-level line per host per
run to `tls-check.log`:

```
ts=2026-10-28T06:10:02Z host=daemonhub.dev issuer="CN=R11" not_after=2027-01-20T00:00:00Z days=84 severity=ok exit=0 serial=AB12
```

Both logs are created 0600 in a directory created 0700.

Both scripts resolve the log directory the same way, whether they run from the
timer or by hand: an exported variable wins, otherwise `HYBRID_AI_LOG_DIR` is
read from the deployment env file, otherwise they fall back to `<repo>/logs`.
The certificate root resolves the same way from `HYBRID_AI_DATA_DIR`. So on a
real deployment the logs land in the deployment log directory next to the
backups, not in the repository.

The unit runs under `ProtectSystem=strict`, which makes `/var/log` read-only, so
it permits writes to exactly two directories: `__REPO_DIR__/logs` and
`/var/log/hybrid-ai`. Any OTHER `HYBRID_AI_LOG_DIR` value needs its own
`ReadWritePaths=` entry in the unit, or the appends are blocked. A blocked
append does not change the health verdict: the check's exit code is independent
of whether the audit line was written, so the alert still fires.

Rotation is config, not code. logrotate does NOT expand shell variables, so the
shipped file carries a `__HYBRID_AI_LOG_DIR__` placeholder that must be
substituted with the RESOLVED log directory (`HYBRID_AI_LOG_DIR` from `.env`,
else `<repo>/logs`):

```
LOGDIR=/opt/hybrid-ai/logs        # or the HYBRID_AI_LOG_DIR value from .env
sudo sed "s#__HYBRID_AI_LOG_DIR__#$LOGDIR#g" deploy/logrotate/hybrid-ai-tls \
  | sudo tee /etc/logrotate.d/hybrid-ai-tls >/dev/null
sudo logrotate --debug /etc/logrotate.d/hybrid-ai-tls
```

An unsubstituted placeholder parses but matches no file and rotates nothing, so
always check the debug output names both paths. The config rotates weekly, keeps
12, compresses, and uses `copytruncate` so no process needs a signal.

## Alert transports

This repository has no mail relay and no alert webhook by default. The existing
monitoring path is systemd user timers, journald and `doctor.sh` exit codes.
`scripts/tls-alert.sh` uses exactly that path.

- Transport A, always: one structured line on stderr, which journald captures.

  ```
  ts=<ISO8601> source=tls severity=<warn|critical|missing|test> subject="..." body="..."
  ```

  Read it with `journalctl --user -u hybrid-ai-tls-check.service`.

- Transport B, only when `HYBRID_AI_ALERT_WEBHOOK_URL` is set: POST the same
  JSON body with curl. `https://` only. A URL carrying userinfo is refused. The
  URL never appears in argv, in output, or in a log: it is handed to curl
  through a 0600 `--config` file in a private `mktemp` directory. Timeout is
  10s. A non-2xx answer is a transport failure.

- `--sink-dir DIR` is the offline transport. It appends the same line to
  `DIR/tls-alert-test.log` and skips the network entirely.

Exit codes: 0 delivered on every configured transport, 1 not delivered,
2 usage error.

Run the synthetic self-test after any change to the alerting path:

```
./scripts/tls-alert.sh --test
```

It fires severity `test` with subject `hybrid-ai TLS alert self-test`, prints
which transports were attempted and their result, and exits 0 only when every
configured transport delivered. It never prints the URL.

## Staging-only dry run

`scripts/tls-dry-run-renewal.sh` proves the chain end to end without touching
production rate limits.

Preconditions:

- `ACME_CA` in the resolved env file names a STAGING directory (its path
  contains `acme-staging`).
- `docker` is on PATH and the compose file exists.
- The Caddy certificate root is readable.
- The proxy service name is known (default `proxy`).

The script refuses to run when `ACME_CA` is unset or points at
`acme-v02.api.letsencrypt.org`. There is no `--force` override, by design.
Staging issuance is untrusted and repeatable; that is why it is safe to test.

Preflight only, changes nothing:

```
./scripts/tls-dry-run-renewal.sh --check-only
```

A full staging run needs `--yes`:

```
./scripts/tls-dry-run-renewal.sh --yes
```

It records the current serial, moves the host's certificate directory to
`<cert-root>/staging-hold/<host>.<epoch>`, restarts the proxy so Caddy sees no
managed certificate, waits up to 180s for a certificate with a different serial,
runs `tls-audit.sh` to record the renewal, then runs `tls-check.sh` to confirm
the served certificate is healthy. On any failure it restores the held
directory and exits 1. It prints the serial before and after, then PASS or FAIL.

This is the only place in the repository that restarts the proxy, and only
against staging.

## Not automated here

- Caddy issues and renews certificates. This change does not.
- There is no certbot, lego, or certificate-issuing timer. Do not add one.
- The `/status/tls` HTTP endpoint is NOT part of this change. Showing certificate
  health on the status page needs a follow-up card.

## Residual risk

- A staging CA makes `chain_valid=false` by design, so `tls-check.sh` reports
  exit 3 for those hosts. That is correct behaviour, not a bug: an untrusted
  chain is untrusted. The days and SAN are still printed so the certificate
  remains diagnosable. A staging issuer served while `ACME_CA=production` is
  reported as its own named case, so the operator can tell a forgotten staging
  certificate from an ordinary trust failure.
- The webhook transport proves delivery to that URL, not that a human read the
  alert. Pair it with the journald line and with `doctor.sh` exit codes.
- A host that is off when the timer would fire catches up on boot
  (`Persistent=true`). A host whose user timer is disabled by missing linger
  will not. `install.sh` warns about linger when it is off.
