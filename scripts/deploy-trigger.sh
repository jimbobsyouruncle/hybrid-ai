#!/usr/bin/env bash
set -Eeuo pipefail
# ---------------------------------------------------------------------------
# FILE: scripts/deploy-trigger.sh
# PURPOSE (plain English):
#   The CLIENT half of the headless deploy. The GitHub deploy job runs this
#   script with the validated commit as its single argument. It connects to the
#   Pi over SSH as the dedicated `hybrid-ai-deploy` account and sends EXACTLY
#   one command string:
#
#       deploy <40-lowercase-hex>
#
#   The account's authorized_keys line pins the forced command
#   (scripts/deploy-forced-command.sh), so that is the one and only thing this
#   connection can do: start the system unit hybrid-ai-deploy@<sha>.service.
#   The unit runs scripts/deploy-instance.sh, which does the ancestor check,
#   the reset to the SHA and the HEAD assert. This script never runs git and
#   never sends a shell script, a heredoc, or an extra argument.
#
#   WHY PLAIN OpenSSH INSTEAD OF appleboy/ssh-action:
#     The action wraps the `script:` content in a shell before sending it, so
#     the remote command is not the exact string the forced command requires.
#     Plain `ssh host "deploy <sha>"` sends precisely that two-token string.
#
#   WHY THE HOST KEY IS CHECKED BEFORE CONNECTING:
#     The runner joins a shared tailnet. Without a host-key check, anything able
#     to occupy the Pi's address could impersonate it and harvest the deploy
#     key. This script fetches the Pi's ed25519 host key with ssh-keyscan,
#     computes its SHA256 fingerprint with ssh-keygen, and refuses to connect
#     unless that fingerprint equals PI_SSH_HOST_KEY. The check happens BEFORE
#     any authentication. StrictHostKeyChecking=no and accept-new are never
#     used.
#
# USAGE (the deploy job calls it with the runner-provided GITHUB_SHA):
#   PI_HOST=<pi-ip> PI_SSH_KEY=<private-key> PI_SSH_HOST_KEY=<SHA256:...> \
#     ./scripts/deploy-trigger.sh "$GITHUB_SHA"
#
# SECRET HANDLING:
#   PI_SSH_KEY holds the private key. It is written with mode 0600 to a file
#   under $RUNNER_TEMP and is never echoed, logged, or printed. Never run this
#   script under `set -x`: xtrace would print the key. The file is removed on
#   EVERY exit path (trap), and the workflow adds an `if: always()` cleanup
#   step as a second line of defence.
#
# EXIT CODES:
#   0  remote exit 0: the unit started and finished successfully
#   2  bad usage: the argument is missing or not a 40-lowercase-hex commit
#   3  a local prerequisite failed (missing env, host key not obtainable)
#   4  the Pi host-key fingerprint did not match PI_SSH_HOST_KEY
#   1  the remote command failed: exit 2 (refused), exit 3 (unit failed), or
#      any other non-zero remote code. Each prints an ::error:: line.
# ---------------------------------------------------------------------------

# --- 1. Validate the argument BEFORE anything else --------------------------
# Exactly one argument, and it must be a full 40-character lowercase hex
# commit. A malformed sha must send nothing at all.
if (( $# != 1 )); then
  echo "::error::deploy-trigger.sh requires exactly one argument: the full 40-hex commit SHA (got $#)." >&2
  exit 2
fi

SHA="$1"
if [[ ! "$SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "::error::deploy-trigger.sh: the argument is not a full 40-character lowercase hex commit SHA." >&2
  exit 2
fi

# --- 2. Required environment (values, never printed) ------------------------
: "${PI_HOST:?deploy-trigger.sh: PI_HOST must be set}"
: "${PI_SSH_KEY:?deploy-trigger.sh: PI_SSH_KEY must be set}"
: "${PI_SSH_HOST_KEY:?deploy-trigger.sh: PI_SSH_HOST_KEY must be set}"

# The account is fixed: the forced command is wired into its authorized_keys
# line. The client never chooses a different login name.
DEPLOY_USER="hybrid-ai-deploy"

# --- 3. Temporary key material, mode 0600, under $RUNNER_TEMP ---------------
RUNNER_TMP="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
KEY_FILE="${RUNNER_TMP}/hybrid-ai-deploy-key"
KNOWN_HOSTS_FILE="${RUNNER_TMP}/hybrid-ai-deploy-known_hosts"

# Remove the private key and the scanned host key on EVERY exit path.
trap 'rm -f -- "$KEY_FILE" "$KNOWN_HOSTS_FILE"' EXIT

umask 077
printf '%s\n' "$PI_SSH_KEY" > "$KEY_FILE"
chmod 0600 -- "$KEY_FILE"

# --- 4. Mandatory host-key check, BEFORE any authentication -----------------
# Fetch the Pi's ed25519 host key, compute its SHA256 fingerprint, and connect
# only on an exact match with PI_SSH_HOST_KEY. A mismatch exits non-zero and
# ssh is never invoked.
if ! ssh-keyscan -t ed25519 "$PI_HOST" > "$KNOWN_HOSTS_FILE" 2>/dev/null; then
  echo "::error::deploy-trigger.sh: ssh-keyscan could not fetch the Pi's host key." >&2
  exit 3
fi
if [[ ! -s "$KNOWN_HOSTS_FILE" ]]; then
  echo "::error::deploy-trigger.sh: ssh-keyscan returned no host key for the Pi." >&2
  exit 3
fi

SCANNED_FP="$(ssh-keygen -lf - < "$KNOWN_HOSTS_FILE" 2>/dev/null | awk 'NR==1{print $2}')"
if [[ -z "$SCANNED_FP" ]]; then
  echo "::error::deploy-trigger.sh: could not compute the Pi's host-key fingerprint." >&2
  exit 3
fi
if [[ "$SCANNED_FP" != "$PI_SSH_HOST_KEY" ]]; then
  echo "::error::deploy-trigger.sh: the Pi's host-key fingerprint does not match PI_SSH_HOST_KEY; refusing to connect." >&2
  exit 4
fi

# --- 5. Send exactly `deploy <sha>` to the forced command -------------------
# Host verification is mandatory (StrictHostKeyChecking=yes against the scanned
# key only). BatchMode and IdentitiesOnly keep this non-interactive and pinned
# to the one key. The remote output (unit:, result:, run log) flows straight to
# this job's log.
REMOTE_RC=0
ssh \
  -i "$KEY_FILE" \
  -o IdentitiesOnly=yes \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile="$KNOWN_HOSTS_FILE" \
  -o ConnectTimeout=20 \
  -o ServerAliveInterval=30 \
  "${DEPLOY_USER}@${PI_HOST}" \
  "deploy ${SHA}" || REMOTE_RC=$?

# --- 6. Map the remote exit code --------------------------------------------
case "$REMOTE_RC" in
  0)
    echo "Deploy accepted: the forced command started the unit and it finished successfully."
    ;;
  2)
    echo "::error::forced command refused the request" >&2
    exit 1
    ;;
  3)
    echo "::error::deploy unit failed" >&2
    exit 1
    ;;
  *)
    echo "::error::deploy SSH command failed (exit ${REMOTE_RC})" >&2
    exit 1
    ;;
esac

exit 0
