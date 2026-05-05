#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

git pull

docker compose -p maichess-prod --env-file .env.prod down
docker compose -p maichess-staging --env-file .env.staging \
  -f docker-compose.yml \
  -f docker-compose.staging.yml \
  down

docker compose -p maichess-prod --env-file .env.prod up -d --pull always
docker compose -p maichess-staging --env-file .env.staging \
  -f docker-compose.yml \
  -f docker-compose.staging.yml \
  up -d --pull always
