#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: openhands/scripts/openhands-control.sh
# PURPOSE (plain English):
#   Start, stop, and inspect the OpenHands maintenance agent.
#
# WHY USE THIS INSTEAD OF docker compose DIRECTLY:
#   OpenHands lives in an overlay file. A compose command that omits the
#   overlay does not see the service -- and "up -d --remove-orphans" without it
#   will DELETE the container, because compose considers it an orphan.
#
#   install.sh uses --remove-orphans on every run. The short form works fine
#   for "logs" and "ps", which is exactly what makes the exception dangerous:
#   the habit forms, and then one command behaves differently.
#
#   This wrapper always passes both files. Use it.
# ---------------------------------------------------------------------------
set -Eeuo pipefail

# Every host path comes from the ONE shared helper. With no settings, the
# resolved paths are exactly today's.
HYBRID_AI_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../scripts/lib" && pwd)"
# shellcheck source=scripts/lib/hybrid-ai-env.sh
source "${HYBRID_AI_LIB_DIR}/hybrid-ai-env.sh"
ROOT="$HYBRID_AI_APP_DIR"
ENV_FILE="$HYBRID_AI_STACK_ENV_FILE"
cd "$ROOT"

[[ -f "$ENV_FILE" ]] || { echo "Missing env file ($ENV_FILE). Run ./install.sh first." >&2; exit 1; }

COMPOSE=(docker compose
         --env-file "$ENV_FILE"
         --project-directory "$ROOT"
         -f "$ROOT/docker-compose.yml"
         -f "$ROOT/openhands/docker-compose.openhands.yml"
         -f "$ROOT/hermes/docker-compose.hermes.yml")

# The configured workspace is resolved by the shared helper (parsed from the env
# file line by line, never sourced). Print the resolved path for display.
workspace() {
  printf '%s' "${OPENHANDS_WORKSPACE:-(unset)}"
}

case "${1:-status}" in
  start)
    "${COMPOSE[@]}" up -d openhands
    printf '\nOpenHands starting.\n'
    printf '  Workspace : %s\n' "$(workspace)"
    printf '  Access    : ssh -L 3001:127.0.0.1:3001 <user>@<pi>\n'
    printf '              then open http://127.0.0.1:3001\n'
    ;;
  stop)    "${COMPOSE[@]}" stop openhands ;;
  restart) "${COMPOSE[@]}" restart openhands ;;
  logs)    "${COMPOSE[@]}" logs -f --tail 200 openhands ;;
  status)
    "${COMPOSE[@]}" ps openhands
    printf '\nWorkspace: %s\n' "$(workspace)"
    ;;
  update)
    "${COMPOSE[@]}" pull openhands
    "${COMPOSE[@]}" up -d openhands
    ;;
  workspace)
    "${ROOT}/scripts/setup-agent-workspace.sh"
    ;;
  *)
    echo "Usage: $0 {start|stop|restart|logs|status|update|workspace}" >&2
    exit 2
    ;;
esac
