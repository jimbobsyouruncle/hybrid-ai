#!/usr/bin/env bash
set -Eeuo pipefail

# Every host path comes from the ONE shared helper. With no settings, the
# resolved paths are exactly today's.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/hybrid-ai-env.sh
source "${SCRIPT_DIR}/lib/hybrid-ai-env.sh"
APP_DIR="$HYBRID_AI_APP_DIR"
ENV_FILE="$HYBRID_AI_STACK_ENV_FILE"
COMPOSE=(docker compose -p hybrid-ai --env-file "$ENV_FILE" --project-directory "$APP_DIR"
         -f "$APP_DIR/docker-compose.yml"
         -f "$APP_DIR/openhands/docker-compose.openhands.yml"
         -f "$APP_DIR/hermes/docker-compose.hermes.yml")

# ---------------------------------------------------------------------------
# FILE: scripts/deploy-remote.sh
# PURPOSE (plain English):
#   The remote half of the automated deploy. The GitHub workflow verifies and
#   resets the Pi to the commit CI validated, then runs this script with that
#   commit SHA as its single argument. The script re-asserts the revision as
#   its first action so the deployed tree can never drift from the validated
#   one, then reprovisions and gates on doctor.sh.
#
#   It is separated from the inline workflow script because the builder token
#   has no permission to edit .github/workflows/. The workflow only calls it.
#
# WHY THE REVISION ARGUMENT EXISTS:
#   CI validates one commit (github.sha). If the deploy reset to origin/main
#   instead, and main moved after validation, the Pi would run an unvalidated
#   revision. Resetting to the exact SHA and asserting HEAD re-closes that gap.
#
# WHY doctor.sh IS A GATE:
#   doctor.sh exits 0 healthy, 1 warnings only, 2 one or more failures. The old
#   inline script ran it with `|| true`, so a failing host still reported a
#   green deploy. Here, exit 2 (or any unexpected code) turns the deploy red.
#
# USAGE:
#   ./scripts/deploy-remote.sh <full-40-hex-commit-sha>
#
# EXIT CODES:
#   0  deploy healthy (doctor.sh reported OK, or warnings only)
#   non-zero  bad argument, revision mismatch, health failure, or doctor.sh
#             reported failures
# ---------------------------------------------------------------------------

if [[ $# -ne 1 ]]; then
  echo "::error::deploy-remote.sh requires exactly one argument: the expected full commit SHA (got $#)."
  exit 2
fi

EXPECTED_SHA="$1"
if [[ ! "$EXPECTED_SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "::error::deploy-remote.sh: '$EXPECTED_SHA' is not a full 40-character lowercase hex commit SHA."
  exit 2
fi

# --- Revision assert: the first real action ---------------------------------
# Fail before anything mutates the host if the tree is not the validated one.
CURRENT_SHA="$(git rev-parse HEAD)"
if [[ "$CURRENT_SHA" != "$EXPECTED_SHA" ]]; then
  echo "::error::deploy-remote.sh: HEAD is $CURRENT_SHA but the validated revision is $EXPECTED_SHA. Refusing to deploy an unvalidated revision."
  exit 3
fi
echo "==> Deploying validated revision $EXPECTED_SHA"

# --- Reprovision ------------------------------------------------------------
# install.sh chmods the rest itself, but it cannot run if it is not executable.
chmod +x install.sh

echo "==> Reprovisioning (non-interactive; existing .env preserved)"
./install.sh --non-interactive

# Give the containers a grace period to settle before the health poll starts.
sleep 20

echo "==> Post-deploy verification"
"${COMPOSE[@]}" ps

# Poll the health endpoint for up to two minutes. If it never comes back, dump
# the last 50 log lines so the failure is diagnosable from the Actions output.
for i in $(seq 1 12); do
  if curl -fsS http://localhost:3000/health >/dev/null 2>&1; then
    echo "Open WebUI healthy."
    break
  fi
  echo "waiting for Open WebUI... ($i/12)"
  sleep 10
  if [ "$i" -eq 12 ]; then
    echo "::error::Open WebUI failed its health check."
    "${COMPOSE[@]}" logs --tail 50 open-webui
    exit 1
  fi
done

# --- Doctor gate ------------------------------------------------------------
# Run doctor.sh WITHOUT masking its exit code. `set +e` around the call keeps
# `set -e` from aborting before we have read the code.
echo "==> Health report"
doctor_rc=0
if [[ -x ./doctor.sh ]]; then
  set +e
  ./doctor.sh --no-cloud
  doctor_rc=$?
  set -e
else
  echo "::error::doctor.sh is missing or not executable; the post-deploy health gate cannot run."
  doctor_rc=2
fi

# --- Informational steps (always run, even when doctor.sh failed) -----------
echo "==> Persistent data intact:"
du -sh "$HYBRID_AI_WEBUI_DATA_DIR" "$HYBRID_AI_OLLAMA_DATA_DIR" 2>/dev/null || true

# Backups are a data-loss control; a deploy that silently disables them is
# worth flagging even though it is not a failure. The shared helper resolves
# which units and which systemctl scope apply for the configured mode.
BACKUP_TIMER_UNIT="$HYBRID_AI_BACKUP_TIMER_UNIT"
BACKUP_SYSTEMCTL_SCOPE="$HYBRID_AI_BACKUP_SYSTEMCTL_SCOPE"
if systemctl "$BACKUP_SYSTEMCTL_SCOPE" is-active "$BACKUP_TIMER_UNIT" >/dev/null 2>&1; then
  echo "Backup timer active. Next run:"
  systemctl "$BACKUP_SYSTEMCTL_SCOPE" list-timers "$BACKUP_TIMER_UNIT" --no-pager 2>/dev/null | head -3 || true
else
  echo "::warning::Backup timer is not active on this host."
fi

# Reclaim SD card space from superseded images.
docker image prune -f >/dev/null 2>&1 || true

# --- Doctor verdict last, after the report and informational steps ----------
case "$doctor_rc" in
  0)
    echo "doctor.sh: healthy."
    ;;
  1)
    echo "::warning::doctor.sh reported warnings"
    ;;
  *)
    echo "::error::doctor.sh reported failures"
    exit 4
    ;;
esac

# HERMES_POST_DEPLOY_VERIFY: this script runs inside the deploy workflow, so
# detach a waiter that verifies only after the workflow run completes.
if [ -x /usr/local/sbin/run-post-deploy-verify.sh ]; then
  setsid nohup /usr/local/sbin/run-post-deploy-verify.sh --wait-for "$EXPECTED_SHA" \
    >/var/log/hybrid-ai-post-deploy-verify.log 2>&1 </dev/null &
fi
