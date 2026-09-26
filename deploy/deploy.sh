#!/usr/bin/env bash
# One command for the finished assignment: kind cluster + KEDA, then the
# redis-auth Secret and deploy/all-in-one.yaml. Safe to re-run.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/setup.sh"
"$ROOT/part-1-deploy/scripts/deploy.sh" "$ROOT/deploy/all-in-one.yaml"
