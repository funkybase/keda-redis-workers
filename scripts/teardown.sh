#!/usr/bin/env bash
# Deletes the kind cluster (and with it KEDA, Redis and all workloads).
set -euo pipefail
kind delete cluster --name "${CLUSTER_NAME:-keda-redis}"
