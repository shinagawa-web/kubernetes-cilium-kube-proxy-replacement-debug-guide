#!/usr/bin/env bash

use_cluster() {
  local name=$1
  local ctx="kind-${name}"
  if ! kubectl config get-contexts -o name | grep -qx "$ctx"; then
    echo "error: no kubectl context '$ctx'; create the cluster first" >&2
    exit 1
  fi
  kubectl config use-context "$ctx" >/dev/null
}
