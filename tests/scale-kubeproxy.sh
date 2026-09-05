#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/docker-group.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/use-cluster.sh"

use_cluster kubeproxy-debug

NAMESPACE=default
DEPLOY=echo
SERVICE_NAME=echo
REPLICAS_STEPS="${REPLICAS_STEPS:-1 2 4 8 16}"
SERVICE_IP=$(kubectl get svc "$SERVICE_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.clusterIP}')
NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
ORIGINAL=$(kubectl get deploy "$DEPLOY" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}')

restore() {
  kubectl scale deploy "$DEPLOY" -n "$NAMESPACE" --replicas="$ORIGINAL" >/dev/null 2>&1 || true
}
trap restore EXIT

section() {
  echo ""
  echo "## $1"
  echo ""
}

nat_dump() {
  docker exec "$NODE" iptables-save -t nat
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

section "iptables nat rule growth vs replicas (${NAMESPACE}/${DEPLOY})"

CHAIN=$(nat_dump | grep "^-A KUBE-SERVICES -d ${SERVICE_IP}/32" \
  | grep -oE 'KUBE-SVC-[A-Z0-9]+' | head -1 || true)
if [ -z "$CHAIN" ]; then
  echo "(no KUBE-SERVICES entry for ${SERVICE_IP} - kube-proxy not present?)"
  exit 0
fi

echo "service   : ${NAMESPACE}/${SERVICE_NAME} (${SERVICE_IP})"
echo "svc chain : ${CHAIN}"
echo "steps     : ${REPLICAS_STEPS}"
echo ""
printf "%-10s %-16s %-12s %s\n" "replicas" "KUBE-SEP chains" "SVC rules" "total nat rules"

for r in $REPLICAS_STEPS; do
  scale_to "$r"
  NAT=$(nat_dump)
  printf "%-10s %-16s %-12s %s\n" \
    "$r" \
    "$(grep -c '^:KUBE-SEP-' <<<"$NAT")" \
    "$(grep -c "^-A ${CHAIN} " <<<"$NAT")" \
    "$(grep -c '^-A' <<<"$NAT")"
done

echo ""
echo "note: SVC rules = 1 (MARK-MASQ) + N (one probability rule per endpoint)"
echo "note: the last endpoint carries no --probability; it is the fallthrough"

section "KUBE-SVC chain at the largest step"
LAST=$(awk '{print $NF}' <<<"$REPLICAS_STEPS")
scale_to "$LAST"
nat_dump | grep "^-A ${CHAIN} " | sed 's/^/    /'
