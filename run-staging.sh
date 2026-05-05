#!/usr/bin/env bash
set -euo pipefail

# Staging environment runner
# Uses project name "maichess-staging" to isolate all volumes and networks from production.
# On every `up`, volumes are destroyed first to ensure no data persists between runs.

COMPOSE="docker compose -f docker-compose.yml -f docker-compose.staging.yml -p maichess-staging"

usage() {
  echo "Usage: $0 [up|down|logs|pull|<any docker compose subcommand>]"
  echo ""
  echo "  up    — tear down existing staging stack (including volumes), then start fresh (default)"
  echo "  down  — stop and remove staging stack including all volumes"
  echo "  logs  — follow logs (pass service names as extra args to filter)"
  echo "  pull  — pull latest images without restarting"
  echo "  *     — any other args are passed directly to docker compose"
}

case "${1:-up}" in
  up)
    echo "==> Tearing down existing staging stack and volumes..."
    $COMPOSE down --volumes --remove-orphans 2>/dev/null || true
    echo "==> Starting staging stack..."
    $COMPOSE up -d --pull always
    echo ""
    echo "Staging environment is up. Public endpoints:"
    echo "  https://staging.maichess.berger-software.com"
    echo "  https://staging.auth.maichess.berger-software.com"
    echo "  https://staging.users.maichess.berger-software.com"
    echo "  https://staging.sockets.maichess.berger-software.com"
    echo "  https://staging.matchmaker.maichess.berger-software.com"
    echo "  https://staging.matchmanager.maichess.berger-software.com"
    echo "  https://staging.analysis.maichess.berger-software.com"
    echo "  https://staging.grafana.maichess.berger-software.com"
    echo "  https://staging.topology.maichess.berger-software.com"
    echo "  https://staging.api.topology.maichess.berger-software.com"
    ;;
  down)
    echo "==> Stopping staging stack and removing volumes..."
    $COMPOSE down --volumes --remove-orphans
    ;;
  logs)
    shift
    $COMPOSE logs -f "$@"
    ;;
  pull)
    $COMPOSE pull
    ;;
  help|--help|-h)
    usage
    ;;
  *)
    $COMPOSE "$@"
    ;;
esac
