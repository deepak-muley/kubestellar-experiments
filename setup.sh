#!/usr/bin/env bash
# Local KubeStellar lab, pinned to v0.30.1.
# Follows the upstream step-by-step, then applies examples/ so both WECs
# run the nginx Deployment. Not a production topology.
# Docs: docs/knowledge-base.md
set -euo pipefail

KUBESTELLAR_VERSION="${KUBESTELLAR_VERSION:-0.30.1}"
HOST_CLUSTER="${HOST_CLUSTER:-kubeflex}"
HOST_CONTEXT="kind-${HOST_CLUSTER}"
ITS_NAME="${ITS_NAME:-its1}"
WDS_NAME="${WDS_NAME:-wds1}"
WEC_NAMES=(cluster1 cluster2)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "KubeStellar lab ${KUBESTELLAR_VERSION}"
echo "Checking prerequisites with the upstream script..."
bash <(curl -fsSL "https://raw.githubusercontent.com/kubestellar/kubestellar/v${KUBESTELLAR_VERSION}/scripts/check_pre_req.sh") \
  kflex ocm helm kubectl docker kind

existing="$(kind get clusters 2>/dev/null || true)"
for name in "${HOST_CLUSTER}" "${WEC_NAMES[@]}"; do
  if grep -qx "${name}" <<<"${existing}"; then
    echo "kind cluster '${name}' already exists. Run ./teardown.sh first." >&2
    exit 1
  fi
done

echo "Creating the KubeFlex hosting cluster (ingress with SSL passthrough on port 9443)..."
bash <(curl -fsSL "https://raw.githubusercontent.com/kubestellar/kubestellar/v${KUBESTELLAR_VERSION}/scripts/create-kind-cluster-with-SSL-passthrough.sh") \
  --name "${HOST_CLUSTER}" --port 9443

echo "Installing ks-core chart ${KUBESTELLAR_VERSION} (ITS=${ITS_NAME}, WDS=${WDS_NAME})..."
helm upgrade --install ks-core oci://ghcr.io/kubestellar/kubestellar/core-chart \
  --version "${KUBESTELLAR_VERSION}" \
  --set-json "ITSes=[{\"name\":\"${ITS_NAME}\"}]" \
  --set-json "WDSes=[{\"name\":\"${WDS_NAME}\"}]"

kubectl config use-context "${HOST_CONTEXT}"
kflex ctx --set-current-for-hosting
kflex ctx --overwrite-existing-context "${WDS_NAME}"
kflex ctx --overwrite-existing-context "${ITS_NAME}"

echo "Waiting for the ITS to finish OCM hub init and the status add-on..."
kubectl --context "${HOST_CONTEXT}" wait \
  "controlplane.tenancy.kflex.kubestellar.org/${ITS_NAME}" \
  --for 'jsonpath={.status.postCreateHooks.its-hub-init}=true' --timeout 180s
kubectl --context "${HOST_CONTEXT}" wait -n "${ITS_NAME}-system" \
  job.batch/its-hub-init --for condition=Complete --timeout 300s
kubectl --context "${HOST_CONTEXT}" wait \
  "controlplane.tenancy.kflex.kubestellar.org/${ITS_NAME}" \
  --for 'jsonpath={.status.postCreateHooks.install-status-addon}=true' --timeout 180s
kubectl --context "${HOST_CONTEXT}" wait -n "${ITS_NAME}-system" \
  job.batch/install-status-addon --for condition=Complete --timeout 300s

# All three clusters share one machine. The join must use an endpoint
# the WEC can reach inside kind, which is what this flag asks clusteradm for.
flags="--force-internal-endpoint-lookup"

echo "Creating and joining workload clusters: ${WEC_NAMES[*]}"
for cluster in "${WEC_NAMES[@]}"; do
  kind create cluster --name "${cluster}"
  kubectl config rename-context "kind-${cluster}" "${cluster}"
  clusteradm --context "${ITS_NAME}" get token \
    | grep '^clusteradm join' \
    | sed "s/<cluster_name>/${cluster}/" \
    | awk '{print $0 " --context '"${cluster}"' --singleton '"${flags}"'"}' \
    | sh
done

echo "Waiting for join CSRs..."
for _ in $(seq 1 30); do
  pending="$(kubectl --context "${ITS_NAME}" get csr --no-headers 2>/dev/null | grep -c Pending || true)"
  if [[ "${pending}" -ge ${#WEC_NAMES[@]} ]]; then
    break
  fi
  sleep 10
done
pending="$(kubectl --context "${ITS_NAME}" get csr --no-headers 2>/dev/null | grep -c Pending || true)"
if [[ "${pending}" -lt ${#WEC_NAMES[@]} ]]; then
  echo "Timed out waiting for ${#WEC_NAMES[@]} Pending CSRs. Current CSRs:" >&2
  kubectl --context "${ITS_NAME}" get csr >&2 || true
  exit 1
fi

for cluster in "${WEC_NAMES[@]}"; do
  clusteradm --context "${ITS_NAME}" accept --clusters "${cluster}"
  kubectl --context "${ITS_NAME}" label managedcluster "${cluster}" \
    location-group=edge "name=${cluster}" --overwrite
done

echo "Inventory:"
kubectl --context "${ITS_NAME}" get managedclusters --show-labels

echo "Applying the nginx BindingPolicy and workload to ${WDS_NAME}..."
kubectl --context "${WDS_NAME}" apply -f "${ROOT}/examples/nginx-binding-policy.yaml"
kubectl --context "${WDS_NAME}" apply -f "${ROOT}/examples/nginx-workload.yaml"

echo "Waiting for nginx-deployment on each workload cluster..."
for cluster in "${WEC_NAMES[@]}"; do
  kubectl --context "${cluster}" -n nginx rollout status deployment/nginx-deployment --timeout=180s
done

cat <<EOF

Lab is up. Contexts:
  hosting   ${HOST_CONTEXT}
  inventory ${ITS_NAME}
  workload  ${WDS_NAME}
  clusters  ${WEC_NAMES[*]}

Inspect:
  kubectl --context ${WDS_NAME} get bindingpolicies,bindings
  kubectl --context ${ITS_NAME} get managedclusters --show-labels
  kubectl --context cluster1 get deploy -n nginx
  kubectl --context cluster2 get deploy -n nginx

Tear down with ./teardown.sh
EOF
