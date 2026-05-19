#!/usr/bin/env bash
set -euo pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo "This will delete the entire staging namespace and all its resources."
read -r -p "Type 'yes' to continue: " confirm
[[ "$confirm" == "yes" ]] || { echo "Aborted."; exit 1; }

helm uninstall maichess-staging -n maichess-staging
kubectl delete namespace maichess-staging
echo "Staging teardown complete."
