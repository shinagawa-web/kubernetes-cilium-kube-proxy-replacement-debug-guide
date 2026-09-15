#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/docker-group.sh"

kind create cluster \
  --name cilium-debug \
  --config cluster/kind-cilium.yaml

API_SERVER_IP=$(docker inspect \
  --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \
  cilium-debug-control-plane)
API_SERVER_PORT=$(kubectl get endpoints kubernetes \
  -o jsonpath='{.subsets[0].ports[0].port}')

NODE_COUNT=$(kubectl get nodes --no-headers | wc -l)
if [ "$NODE_COUNT" -gt 1 ]; then
  OPERATOR_REPLICAS=2
else
  OPERATOR_REPLICAS=1
fi

helm repo add cilium https://helm.cilium.io/ --force-update

helm install cilium cilium/cilium \
  --version 1.17.3 \
  --namespace kube-system \
  --set kubeProxyReplacement=true \
  --set operator.replicas="$OPERATOR_REPLICAS" \
  --set k8sServiceHost="$API_SERVER_IP" \
  --set k8sServicePort="$API_SERVER_PORT" \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true

echo "Waiting for Cilium to be ready..."
cilium status --wait

kubectl wait --for=create serviceaccount/default --timeout=60s
kubectl apply -f manifests/
