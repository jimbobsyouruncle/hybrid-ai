#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
[[ -f .env ]] || { echo "Missing .env; run ./install.sh first." >&2; exit 1; }
COMPOSE=(docker compose -f docker-compose.yml -f openhands/docker-compose.openhands.yml --env-file .env)
case "${1:-status}" in
  start)   "${COMPOSE[@]}" up -d openhands ;;
  stop)    "${COMPOSE[@]}" stop openhands ;;
  restart) "${COMPOSE[@]}" restart openhands ;;
  logs)    "${COMPOSE[@]}" logs -f --tail 200 openhands ;;
  status)  "${COMPOSE[@]}" ps openhands ;;
  update)  "${COMPOSE[@]}" pull openhands && "${COMPOSE[@]}" up -d openhands ;;
  *) echo "Usage: $0 {start|stop|restart|logs|status|update}" >&2; exit 2 ;;
esac
