# kubernetes-cilium-kube-proxy-replacement-debug-guide

## Article and CI jobs

| Article | CI jobs |
|:---|:---|
| [Kubernetes: iptables is empty after migrating to Cilium — what to look at next](https://dev.to/shinagawa-web/kubernetes-iptables-is-empty-after-migrating-to-cilium-what-to-look-at-next-2knn) | [capture-cilium](https://github.com/shinagawa-web/kubernetes-cilium-kube-proxy-replacement-debug-guide/actions/runs/34095095725/job/101656873084) · [capture-kubeproxy](https://github.com/shinagawa-web/kubernetes-cilium-kube-proxy-replacement-debug-guide/actions/runs/34095095725/job/101656873263) · [debug-cilium](https://github.com/shinagawa-web/kubernetes-cilium-kube-proxy-replacement-debug-guide/actions/runs/34327279232/job/102387334234) |

Sample repository for the article.

Provides two kind clusters side by side:

| Cluster | CNI | Service処理 |
|---|---|---|
| `kubeproxy-debug` | kindnet (kind default) | kube-proxy (iptables) |
| `cilium-debug` | Cilium | Cilium eBPF |

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/)
- [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [helm](https://helm.sh/docs/intro/install/)
- [cilium CLI](https://docs.cilium.io/en/stable/gettingstarted/k8s-install-default/#install-the-cilium-cli)

## Setup

### Cilium kube-proxy replacement cluster

```bash
./scripts/setup-cilium.sh
```

### kube-proxy cluster (for comparison)

```bash
./scripts/setup-kubeproxy.sh
```

## Directory structure

```
lima.yaml                    # Lima VM for running the clusters on macOS
cluster/
  kind-cilium.yaml           # kind config: kube-proxy disabled, CNI disabled
  kind-kubeproxy.yaml        # kind config: kube-proxy enabled, CNI enabled (kindnet)
manifests/
  demo.yaml                  # echo server Deployment, ClusterIP Service, NodePort Service, client Pod
  broken/
    svc-wrong-selector.yaml  # Service whose selector matches no pod
    netpol-deny.yaml         # NetworkPolicy denying client -> demo
scripts/
  setup-cilium.sh            # create cilium-debug cluster
  setup-kubeproxy.sh         # create kubeproxy-debug cluster
  teardown.sh                # delete both clusters
  lib/
    docker-group.sh          # re-exec under the docker group when the login session lacks it
    use-cluster.sh           # switch kubectl context to the cluster a script targets
tests/
  capture-cilium.sh          # Cilium: service list, bpf lb list, tcpdump, hubble, conntrack
  capture-kubeproxy.sh       # kube-proxy: iptables chain trace, conntrack
  scale-cilium.sh            # eBPF LB map growth vs replicas
  scale-kubeproxy.sh         # iptables nat rule growth vs replicas
  debug-cilium.sh            # walkthrough: no endpoints / denied by NetworkPolicy
  debug-kubeproxy.sh         # walkthrough: no endpoints
```

## Teardown

```bash
./scripts/teardown.sh
```
