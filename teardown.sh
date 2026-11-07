#!/usr/bin/env bash
# Removes the kind clusters and kubeconfig contexts created by setup.sh.
set -u

for name in kubeflex cluster1 cluster2; do
  kind delete cluster --name "${name}" || true
done

for ctx in cluster1 cluster2 its1 wds1; do
  kubectl config delete-context "${ctx}" || true
done

echo "Lab clusters removed."
