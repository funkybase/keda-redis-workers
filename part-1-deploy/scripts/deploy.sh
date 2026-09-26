#!/usr/bin/env bash
# Usage: deploy.sh [KUSTOMIZE_DIR]
#
# Deploys Redis and the worker into the 'ingest' namespace. KUSTOMIZE_DIR
# defaults to Part 1's manifests; later parts pass their own overlay.
#
# The Redis password is generated here and stored only in the 'redis-auth'
# Secret, so it never gets committed to git. Re-running keeps the existing
# password.
set -euo pipefail

NAMESPACE="${NAMESPACE:-ingest}"
KUSTOMIZE_DIR="${1:-$(cd "$(dirname "$0")/../manifests" && pwd)}"

if kubectl -n "$NAMESPACE" get secret redis-auth >/dev/null 2>&1; then
  echo "secret/redis-auth already exists, keeping it"
else
  kubectl -n "$NAMESPACE" create secret generic redis-auth \
    --from-literal=password="$(head -c 24 /dev/urandom | base64 | tr -d '/+=')"
fi

# --load-restrictor lets a kustomization read files outside its own directory
# (e.g. ../worker/worker.sh)
kubectl kustomize --load-restrictor LoadRestrictionsNone "$KUSTOMIZE_DIR" \
  | kubectl apply -f -

kubectl -n "$NAMESPACE" rollout status deploy/redis --timeout=180s
kubectl -n "$NAMESPACE" rollout status deploy/worker --timeout=180s
kubectl -n "$NAMESPACE" get pods -o wide
