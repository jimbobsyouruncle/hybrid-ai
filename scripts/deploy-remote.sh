#!/usr/bin/env bash
set -Eeuo pipefail
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

echo "==> Post-deploy verification"
docker compose --env-file .env ps

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
    docker compose --env-file .env logs --tail 50 open-webui
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
du -sh webui_data ollama_data 2>/dev/null || true

# Backups are a data-loss control; a deploy that silently disables them is
# worth flagging even though it is not a failure.
if systemctl --user is-active hybrid-ai-backup.timer >/dev/null 2>&1; then
  echo "Backup timer active. Next run:"
  systemctl --user list-timers hybrid-ai-backup.timer --no-pager 2>/dev/null | head -3 || true
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
