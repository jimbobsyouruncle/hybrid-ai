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

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

[[ -f .env ]] || { echo "Missing .env. Run ./install.sh first." >&2; exit 1; }

COMPOSE=(docker compose
         -f docker-compose.yml
         -f openhands/docker-compose.openhands.yml
         --env-file .env)

# Read the configured workspace for display. Parsed line by line, never
# sourced -- sourcing executes the file as shell code.
workspace() {
  local line v
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^OPENHANDS_WORKSPACE=(.*)$ ]]; then
      v="${BASH_REMATCH[1]}"; v="${v%\"}"; v="${v#\"}"
      printf '%s' "$v"; return
    fi
  done < .env
  printf '(unset)'
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
