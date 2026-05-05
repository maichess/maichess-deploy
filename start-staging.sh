#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

docker compose -p maichess-staging --env-file .env.staging \
  -f docker-compose.yml \
  -f docker-compose.staging.yml \
  up -d --pull always
