#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/docker-group.sh"

kind create cluster \
  --name kubeproxy-debug \
  --config cluster/kind-kubeproxy.yaml

kubectl wait --for=create serviceaccount/default --timeout=60s
kubectl apply -f manifests/
