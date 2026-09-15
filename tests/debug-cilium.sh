#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/docker-group.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/use-cluster.sh"

use_cluster cilium-debug

NAMESPACE=default
CLIENT_POD=client
BROKEN_DIR="$(dirname "${BASH_SOURCE[0]}")/../manifests/broken"

cleanup() {
  kubectl delete -f "$BROKEN_DIR" --ignore-not-found >/dev/null 2>&1 || true
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

agent() {
  kubectl -n kube-system exec ds/cilium -c cilium-agent -- "$@"
}

NODE=$(kubectl get pod "$CLIENT_POD" -n "$NAMESPACE" -o jsonpath='{.spec.nodeName}')
SERVICE_IP=$(kubectl get svc demo -n "$NAMESPACE" -o jsonpath='{.spec.clusterIP}')

kubectl apply -f "$BROKEN_DIR/svc-wrong-selector.yaml" >/dev/null
sleep 3
BROKEN_IP=$(kubectl get svc demo-broken -n "$NAMESPACE" -o jsonpath='{.spec.clusterIP}')

section "case A - symptom: demo-broken never answers"
echo "demo-broken ClusterIP : ${BROKEN_IP}"
echo "curl from ${CLIENT_POD}     : HTTP $(probe "$BROKEN_IP")"

section "case A - the old habit returns nothing"
docker exec "$NODE" iptables-save -t nat | grep "$BROKEN_IP" \
  || echo "(no nat rule - Cilium does not use netfilter for Services)"

section "case A - step 1: does the Service have endpoints?"
kubectl get endpoints demo-broken -n "$NAMESPACE"

section "case A - step 2: how Cilium sees both Services (name + backend count)"
agent cilium-dbg service list -o json 2>/dev/null \
| jq -r '.[] | select(
    (.spec["frontend-address"].ip == "'"${BROKEN_IP}"'") or
    (.spec["frontend-address"].ip == "'"${SERVICE_IP}"'")
  ) | [
    (.spec.id | tostring),
    (.spec["frontend-address"].ip + ":" + (.spec["frontend-address"].port | tostring)),
    .spec.flags.type,
    (.spec.flags.namespace + "/" + .spec.flags.name),
    (.spec["backend-addresses"] | length | tostring)
  ] | @tsv' | column -t || true

section "case A - step 3: backend slots in the LB map"
echo "working Service ${SERVICE_IP}:"
agent cilium-dbg bpf lb list 2>/dev/null | grep "${SERVICE_IP}:" | sed 's/^/    /' || true
echo "broken Service ${BROKEN_IP}:"
agent cilium-dbg bpf lb list 2>/dev/null | grep "${BROKEN_IP}:" | sed 's/^/    /' \
  || echo "    (no backend slots)"

section "case A - root cause: the selector matches no pod"
echo "demo-broken selector : $(kubectl get svc demo-broken -n "$NAMESPACE" -o jsonpath='{.spec.selector}')"
kubectl get pod -n "$NAMESPACE" -l app=demo \
  -o jsonpath='{range .items[*]}    {.metadata.name}  {.metadata.labels}{"\n"}{end}'

kubectl delete -f "$BROKEN_DIR/svc-wrong-selector.yaml" >/dev/null 2>&1
kubectl apply -f "$BROKEN_DIR/netpol-deny.yaml" >/dev/null
sleep 4

section "case B - symptom: demo fails too, same HTTP 000"
echo "demo ClusterIP : ${SERVICE_IP}"
echo "curl from ${CLIENT_POD} : HTTP $(probe "$SERVICE_IP")"

section "case B - step 1: endpoints are healthy this time"
kubectl get endpoints demo -n "$NAMESPACE"

section "case B - step 2: Cilium has active backends - not a load balancing problem"
agent cilium-dbg service list -o json 2>/dev/null \
| jq -r '.[] | select(.spec["frontend-address"].ip == "'"${SERVICE_IP}"'") | [
    (.spec.id | tostring),
    (.spec["frontend-address"].ip + ":" + (.spec["frontend-address"].port | tostring)),
    .spec.flags.type,
    (.spec.flags.namespace + "/" + .spec.flags.name),
    (.spec["backend-addresses"] | length | tostring)
  ] | @tsv' | column -t || true

section "case B - step 3: hubble names the verdict"
probe "$SERVICE_IP" >/dev/null
DROPS=$(agent hubble observe --verdict DROPPED --last 20 | grep -E "client|demo" || true)
if [ -n "$DROPS" ]; then
  head -6 <<<"$DROPS"
else
  echo "(no dropped flows observed)"
fi

section "case B - root cause: a NetworkPolicy is denying the traffic"
kubectl get networkpolicy -n "$NAMESPACE"

section "old tool -> new tool"
cat <<'TABLE'
    iptables-save -t nat        ->  cilium service list / cilium bpf lb list
    conntrack -L                ->  cilium bpf ct list global (+ cilium service list)
    tcpdump on the node         ->  hubble observe / cilium monitor
    filter REJECT "no endpoints"->  backend count in cilium service list
    (no equivalent)             ->  hubble observe --verdict DROPPED
TABLE
