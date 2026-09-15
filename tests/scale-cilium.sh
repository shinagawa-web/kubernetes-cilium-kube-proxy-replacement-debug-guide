#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/docker-group.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/use-cluster.sh"

use_cluster cilium-debug

NAMESPACE=default
DEPLOY=demo
SERVICE_NAME=demo
REPLICAS_STEPS="${REPLICAS_STEPS:-1 2 4 8 16}"
SERVICE_IP=$(kubectl get svc "$SERVICE_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.clusterIP}')
SERVICE_PORT=$(kubectl get svc "$SERVICE_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.ports[0].port}')
NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
ORIGINAL=$(kubectl get deploy "$DEPLOY" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}')
VIP="${SERVICE_IP}:${SERVICE_PORT}/TCP"

restore() {
  kubectl scale deploy "$DEPLOY" -n "$NAMESPACE" --replicas="$ORIGINAL" >/dev/null 2>&1 || true
}
trap restore EXIT

section() {
  echo ""
  echo "## $1"
  echo ""
}

lb_dump() {
  kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
    cilium-dbg bpf lb list 2>/dev/null
}

ready_endpoints() {
  kubectl get endpoints "$SERVICE_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.subsets[*].addresses[*].ip}' | wc -w
}

scale_to() {
  local want=$1 i=0
  kubectl scale deploy "$DEPLOY" -n "$NAMESPACE" --replicas="$want" >/dev/null
  while [ "$(ready_endpoints)" != "$want" ]; do
    i=$((i + 1))
    [ "$i" -gt 90 ] && { echo "timed out waiting for $want ready endpoints" >&2; return 1; }
    sleep 2
  done
  sleep 2
}

section "eBPF LB map growth vs replicas (${NAMESPACE}/${DEPLOY})"

if ! lb_dump | grep -q "^${VIP} "; then
  echo "(no LB map entry for ${VIP} - cilium kube-proxy replacement not active?)"
  exit 0
fi

echo "service : ${NAMESPACE}/${SERVICE_NAME} (${VIP})"
echo "steps   : ${REPLICAS_STEPS}"
echo ""
printf "%-10s %-14s %-16s %s\n" \
  "replicas" "backend slots" "total lb entries" "iptables KUBE-SVC rules"

for r in $REPLICAS_STEPS; do
  scale_to "$r"
  LB=$(lb_dump)
  NAT=$(docker exec "$NODE" iptables-save -t nat)
  printf "%-10s %-14s %-16s %s\n" \
    "$r" \
    "$(grep -c "^${VIP} (\([1-9][0-9]*\))" <<<"$LB" || true)" \
    "$(grep -cE '^[0-9]' <<<"$LB" || true)" \
    "$(grep -c '^-A KUBE-SVC-' <<<"$NAT" || true)"
done

echo ""
echo "note: slot (0) is the service master entry; slots (1..N) are the backends"
echo "note: backend selection is an index into the slots, not a sequential scan"
echo "note: iptables stays at 0 rules regardless of replica count"

section "LB map entries for ${VIP} at the largest step"
LAST=$(awk '{print $NF}' <<<"$REPLICAS_STEPS")
scale_to "$LAST"
lb_dump | grep "^${VIP} " | sort | sed 's/^/    /'
