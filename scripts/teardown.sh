#!/usr/bin/env bash
set -euo pipefail

kind delete cluster --name cilium-debug
kind delete cluster --name kubeproxy-debug
