#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/docker-group.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/use-cluster.sh"

use_cluster cilium-debug

NAMESPACE=default
CLIENT_POD=client
SERVICE_NAME=echo
SERVICE_IP=$(kubectl get svc "$SERVICE_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.clusterIP}')
NODE=$(kubectl get pod "$CLIENT_POD" -o jsonpath='{.spec.nodeName}')

section() {
  echo ""
  echo "## $1"
  echo ""
}

section "cilium status"
cilium status

section "kubeProxyReplacement confirmation"
kubectl -n kube-system exec ds/cilium -- \
  cilium-dbg status --verbose | grep -A5 "KubeProxyReplacement"

section "iptables-save | grep KUBE-SERVICES (expect: empty)"
docker exec "$NODE" iptables-save 2>/dev/null | grep "KUBE-SERVICES" || echo "(no KUBE-SERVICES rules)"

section "kubectl get svc echo"
kubectl get svc "$SERVICE_NAME" -n "$NAMESPACE"

section "cilium service list"
kubectl -n kube-system exec ds/cilium -- cilium-dbg service list

section "cilium bpf lb list"
kubectl -n kube-system exec ds/cilium -- cilium-dbg bpf lb list

section "ClusterIP connectivity from client pod"
kubectl exec -n "$NAMESPACE" "$CLIENT_POD" -- \
  curl -s --max-time 5 "http://${SERVICE_IP}/" | python3 -m json.tool 2>/dev/null || true

section "tcpdump on node targeting ClusterIP (expect: no packets)"
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

section "NodePort on the wire (expect: packets, unlike ClusterIP)"
NODEPORT=$(kubectl get svc echo-nodeport -n "$NAMESPACE" -o jsonpath='{.spec.ports[0].nodePort}')
NODE_IP=$(kubectl get node "$NODE" -o jsonpath='{.status.addresses[0].address}')
echo "NodePort: ${NODE_IP}:${NODEPORT}"
docker exec "$NODE" \
  timeout 8 tcpdump -n -i any "port ${NODEPORT}" 2>&1 &
TCPDUMP_PID=$!
sleep 2
curl -s --max-time 5 -o /dev/null "http://${NODE_IP}:${NODEPORT}/" || true
echo "(request sent from outside the cluster)"
wait $TCPDUMP_PID || true

section "eBPF attach layer (NodePort path is not socket LB)"
kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
  cilium-dbg status --verbose | grep -E "Attach Mode|Device Mode|XDP Acceleration|Socket LB"

section "NodePort entries in the LB map"
kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
  cilium-dbg bpf lb list | grep "${NODEPORT}" || echo "(no NodePort entries)"

section "hubble observe (ClusterIP translation visible)"
kubectl exec -n "$NAMESPACE" "$CLIENT_POD" -- curl -s --max-time 5 "http://${SERVICE_IP}/" > /dev/null
kubectl -n kube-system exec ds/cilium -- hubble observe --last 30 2>&1 | grep -E "client|echo"

section "cilium monitor (drop events while sending traffic)"
kubectl -n kube-system exec ds/cilium -- cilium-dbg monitor --type drop &
MONITOR_PID=$!
sleep 2
kubectl exec -n "$NAMESPACE" "$CLIENT_POD" -- curl -s --max-time 5 "http://${SERVICE_IP}/" > /dev/null
sleep 2
kill $MONITOR_PID 2>/dev/null || true
wait $MONITOR_PID 2>/dev/null || true

section "cilium monitor (all events, 5s)"
timeout 5 kubectl -n kube-system exec ds/cilium -- \
  cilium-dbg monitor 2>&1 &
MONITOR_PID=$!
sleep 1
kubectl exec -n "$NAMESPACE" "$CLIENT_POD" -- curl -s --max-time 5 "http://${SERVICE_IP}/" > /dev/null
wait $MONITOR_PID 2>/dev/null || true

section "conntrack -L (expect: nothing - Cilium does not use netfilter conntrack)"
kubectl exec -n "$NAMESPACE" "$CLIENT_POD" -- \
  curl -s --max-time 5 "http://${SERVICE_IP}/" > /dev/null
sleep 1
CT=$(docker exec "$NODE" conntrack -L 2>/dev/null | grep -w "$SERVICE_IP" || true)
if [ -n "$CT" ]; then
  head -3 <<<"$CT"
else
  echo "(no conntrack entry for ${SERVICE_IP})"
fi

section "cilium bpf ct list (the replacement - addresses are already translated)"
CLIENT_IP=$(kubectl get pod "$CLIENT_POD" -n "$NAMESPACE" -o jsonpath='{.status.podIP}')
echo "client pod IP: ${CLIENT_IP}"
BPF_CT=$(kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
  cilium-dbg bpf ct list global 2>/dev/null | grep -w "$CLIENT_IP" || true)
if [ -n "$BPF_CT" ]; then
  head -3 <<<"$BPF_CT"
else
  echo "(no CT entry for ${CLIENT_IP})"
fi

section "cilium service list (where the ClusterIP -> backend mapping lives)"
kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
  cilium-dbg service list 2>/dev/null | grep -E "^ID|${SERVICE_IP}" || true
