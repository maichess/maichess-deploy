#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

# Create the shared Traefik network if it doesn't already exist
docker network inspect traefik >/dev/null 2>&1 \
  || docker network create traefik

docker compose -f docker-compose.traefik.yml --env-file .env.prod up -d --pull always
