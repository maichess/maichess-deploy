#!/usr/bin/env bash
set -euo pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
cd "$(dirname "$0")/../maichess"

helm dependency update .
helm upgrade --install maichess . \
  -n maichess --create-namespace \
  -f values.yaml \
  -f values-prod.yaml \
  -f /etc/maichess/values-secrets-prod.yaml \
  --wait --timeout 5m
