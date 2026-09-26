#!/usr/bin/env bash
# Creates the kind cluster, installs KEDA from its official Helm chart and
# creates the 'ingest' namespace. Idempotent: safe to re-run.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-keda-redis}"
KEDA_VERSION="${KEDA_VERSION:-2.21.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  echo "kind cluster '$CLUSTER_NAME' already exists"
else
  kind create cluster --config "$ROOT/kind/cluster.yaml" --name "$CLUSTER_NAME" --wait 120s
fi
kubectl config use-context "kind-$CLUSTER_NAME" >/dev/null

# kubectl only supports +/-1 minor version of skew against the API server.
server_minor=$(kubectl version -o json 2>/dev/null | sed -n '/serverVersion/,/}/s/.*"minor": "\([0-9]*\).*/\1/p')
client_minor=$(kubectl version --client -o json | sed -n 's/.*"minor": "\([0-9]*\).*/\1/p' | head -1)
if [ -n "$server_minor" ] && [ $((server_minor - client_minor)) -gt 1 ]; then
  echo "WARNING: kubectl 1.$client_minor is too old for server 1.$server_minor; install a newer kubectl" >&2
fi

helm repo add kedacore https://kedacore.github.io/charts >/dev/null 2>&1 || true
helm repo update kedacore >/dev/null
helm upgrade --install keda kedacore/keda \
  --version "$KEDA_VERSION" \
  --namespace keda --create-namespace \
  --wait --timeout 5m

kubectl create namespace ingest --dry-run=client -o yaml | kubectl apply -f -

kubectl get nodes -o wide
kubectl -n keda get pods
