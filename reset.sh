#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

echo "WARNING: This will stop all environments, remove all containers, volumes, and the shared Traefik network."
read -r -p "Type 'yes' to continue: " confirm
[[ "$confirm" == "yes" ]] || { echo "Aborted."; exit 1; }

docker compose -p maichess-prod --env-file .env.prod \
  down -v --remove-orphans || true

docker compose -p maichess-staging --env-file .env.staging \
  -f docker-compose.yml \
  -f docker-compose.staging.yml \
  down -v --remove-orphans || true

docker compose -f docker-compose.traefik.yml --env-file .env.prod \
  down -v --remove-orphans || true

docker network rm traefik 2>/dev/null || true

echo "Reset complete."
