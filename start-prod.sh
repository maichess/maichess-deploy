#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

docker compose -p maichess-prod --env-file .env.prod up -d --pull always
