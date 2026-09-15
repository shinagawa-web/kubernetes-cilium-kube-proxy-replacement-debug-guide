#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/docker-group.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/use-cluster.sh"

use_cluster kubeproxy-debug

NAMESPACE=default
CLIENT_POD=client
BROKEN_SVC="$(dirname "${BASH_SOURCE[0]}")/../manifests/broken/svc-wrong-selector.yaml"

cleanup() {
  kubectl delete -f "$BROKEN_SVC" --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

section() {
  echo ""
  echo "## $1"
  echo ""
}

probe() {
  local code
  code=$(kubectl exec -n "$NAMESPACE" "$CLIENT_POD" -- \
    curl -s --max-time 5 -o /dev/null -w '%{http_code} (%{time_total}s)' "http://$1/" 2>/dev/null) || true
  echo "${code:-000}"
}

NODE=$(kubectl get pod "$CLIENT_POD" -n "$NAMESPACE" -o jsonpath='{.spec.nodeName}')
SERVICE_IP=$(kubectl get svc demo -n "$NAMESPACE" -o jsonpath='{.spec.clusterIP}')

kubectl apply -f "$BROKEN_SVC" >/dev/null
sleep 3
BROKEN_IP=$(kubectl get svc demo-broken -n "$NAMESPACE" -o jsonpath='{.spec.clusterIP}')

section "symptom: demo-broken never answers"
echo "demo-broken ClusterIP : ${BROKEN_IP}"
echo "curl from ${CLIENT_POD}     : HTTP $(probe "$BROKEN_IP")"
echo "demo (working) ${SERVICE_IP} : HTTP $(probe "$SERVICE_IP")"

section "step 1: does the Service have endpoints?"
kubectl get endpoints demo-broken -n "$NAMESPACE"

section "step 2: nat table - where a working Service appears"
echo "working Service ${SERVICE_IP}:"
docker exec "$NODE" iptables-save -t nat \
  | grep "^-A KUBE-SERVICES -d ${SERVICE_IP}/32" | sed 's/^/    /' || true
echo "broken Service ${BROKEN_IP}:"
docker exec "$NODE" iptables-save -t nat | grep "$BROKEN_IP" | sed 's/^/    /' \
  || echo "    (no nat rule - there is no endpoint to DNAT to)"

section "step 3: filter table - kube-proxy states the reason here"
docker exec "$NODE" iptables-save -t filter | grep "$BROKEN_IP" | sed 's/^/    /' \
  || echo "    (no filter rule for ${BROKEN_IP})"

section "root cause: the selector matches no pod"
echo "demo-broken selector : $(kubectl get svc demo-broken -n "$NAMESPACE" -o jsonpath='{.spec.selector}')"
echo "labels on demo pods  :"
kubectl get pod -n "$NAMESPACE" -l app=demo \
  -o jsonpath='{range .items[*]}    {.metadata.name}  {.metadata.labels}{"\n"}{end}'
