#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../maichess"

helm dependency update .
helm upgrade --install maichess-staging . \
  -n maichess-staging --create-namespace \
  -f values.yaml \
  -f values-staging.yaml \
  -f /etc/maichess/values-secrets-staging.yaml \
  --wait --timeout 5m
