#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/docker-group.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/use-cluster.sh"

use_cluster kubeproxy-debug

NAMESPACE=default
CLIENT_POD=client
SERVICE_NAME=demo
SERVICE_IP=$(kubectl get svc "$SERVICE_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.clusterIP}')
NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')

section() {
  echo ""
  echo "## $1"
  echo ""
}

section "iptables-save | grep KUBE-SERVICES (expect: rules)"
docker exec "$NODE" iptables-save \
  | grep "KUBE-SERVICES" \
  || echo "(no KUBE-SERVICES rules - kube-proxy not present?)"

section "chain trace for ${NAMESPACE}/${SERVICE_NAME} (${SERVICE_IP}, flow order)"
NAT=$(docker exec "$NODE" iptables-save -t nat)
ENTRY=$(grep "^-A KUBE-SERVICES -d ${SERVICE_IP}/32" <<<"$NAT" || true)
if [ -z "$ENTRY" ]; then
  echo "(no KUBE-SERVICES entry for ${SERVICE_IP} - kube-proxy not present?)"
else
  echo "[1] KUBE-SERVICES: match ClusterIP"
  sed 's/^/    /' <<<"$ENTRY"
  SVC_CHAIN=$(grep -oE 'KUBE-SVC-[A-Z0-9]+' <<<"$ENTRY" | head -1)
  SVC_RULES=$(grep "^-A ${SVC_CHAIN} " <<<"$NAT")
  echo "[2] ${SVC_CHAIN}: pick an endpoint"
  sed 's/^/    /' <<<"$SVC_RULES"
  for sep in $(grep -oE 'KUBE-SEP-[A-Z0-9]+' <<<"$SVC_RULES"); do
    echo "[3] ${sep}: DNAT to pod"
    grep "^-A ${sep} " <<<"$NAT" | sed 's/^/    /'
  done
fi

section "KUBE-SVC / KUBE-SEP chains (all services)"
docker exec "$NODE" iptables-save -t nat \
  | grep -E "^-A KUBE-(SVC|SEP)-" \
  || echo "(no KUBE-SVC/SEP rules)"

section "ClusterIP connectivity from client pod"
kubectl exec -n "$NAMESPACE" "$CLIENT_POD" -- \
  curl -s --max-time 5 "http://${SERVICE_IP}/" | python3 -m json.tool 2>/dev/null || true

section "tcpdump on node targeting ClusterIP (expect: packets visible before DNAT)"
echo "ClusterIP: ${SERVICE_IP}"
docker exec "$NODE" sh -c 'command -v tcpdump || (apt-get update -qq && apt-get install -y -qq tcpdump)' > /dev/null 2>&1
echo "Sending traffic from client pod while tcpdump listens on node..."
docker exec "$NODE" \
  timeout 8 tcpdump -n -i any "host ${SERVICE_IP}" 2>&1 &
TCPDUMP_PID=$!
sleep 2
kubectl exec -n "$NAMESPACE" "$CLIENT_POD" -- curl -s --max-time 5 "http://${SERVICE_IP}/" > /dev/null
echo "(request sent)"
wait $TCPDUMP_PID || true

section "conntrack -L (ClusterIP and its DNAT target in one row)"
kubectl exec -n "$NAMESPACE" "$CLIENT_POD" -- \
  curl -s --max-time 5 "http://${SERVICE_IP}/" > /dev/null
sleep 1
CT=$(docker exec "$NODE" conntrack -L 2>/dev/null | grep -w "$SERVICE_IP" || true)
if [ -n "$CT" ]; then
  head -3 <<<"$CT"
else
  echo "(no conntrack entry for ${SERVICE_IP})"
fi
