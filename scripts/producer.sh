#!/usr/bin/env bash
# Usage: producer.sh N [--force|--append] [--mode exec|pod]
#
# Pushes N unique job IDs onto the 'jobs' list. IDs look like
# <run-id>-<seq>, e.g. r20260926T134501123-00042 (UTC, ms), so they are unique within and
# across runs.
#
# In the same MULTI/EXEC transaction it resets the 'done' counter and records
# 'expected' = N and 'run_id', so check.sh can verify the run.
#
# Refuses to start if 'jobs' or 'processing' still hold anything from a
# previous run (that would make done == N meaningless); --force overrides.
# --append adds N jobs to the current run instead of starting a new one
# ('expected' += N, 'done' is not reset), e.g. to keep work arriving mid-run.
#
# --mode (or PRODUCER_MODE) picks where the push runs:
#   exec  (default) inside the Redis pod via `kubectl exec`, talking to localhost
#   pod   in a throwaway pod that connects through the 'redis' Service, with
#         REDIS_HOST from the worker-config ConfigMap and the password from the
#         redis-auth Secret, i.e. the same path the workers use
# Both modes run scripts/producer-core.sh, so they behave identically.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

usage() { echo "usage: $0 N [--force|--append] [--mode exec|pod]" >&2; exit 2; }

N="" OPT="" MODE="${PRODUCER_MODE:-exec}"
while [ $# -gt 0 ]; do
  case "$1" in
    --force | --append) OPT="$1" ;;
    --mode) MODE="${2:-}"; shift ;;
    --mode=*) MODE="${1#--mode=}" ;;
    *) [ -z "$N" ] || usage; N="$1" ;;
  esac
  shift
done
[[ "$N" =~ ^[1-9][0-9]*$ ]] || usage

CORE="$(dirname "$0")/producer-core.sh"
RUN_ID="r$(date -u +%Y%m%dT%H%M%S%3N)"

case "$MODE" in
  exec)
    kubectl -n "$NAMESPACE" exec -i "$REDIS_TARGET" -c redis -- \
      bash -s -- "$N" "$RUN_ID" "$OPT" <"$CORE"
    ;;
  pod)
    # kubectl run replaces the whole container list with --overrides, so the
    # container is spelled out in full (stdin for the script, env, resources).
    overrides=$(cat <<EOF
{"spec":{"containers":[{
  "name":"producer","image":"redis:7",
  "command":["bash","-s","--","$N","$RUN_ID","$OPT"],
  "stdin":true,"stdinOnce":true,
  "env":[
    {"name":"REDIS_HOST","valueFrom":{"configMapKeyRef":{"name":"worker-config","key":"REDIS_HOST"}}},
    {"name":"REDIS_PASSWORD","valueFrom":{"secretKeyRef":{"name":"redis-auth","key":"password"}}}
  ],
  "resources":{"requests":{"cpu":"10m","memory":"16Mi"},"limits":{"cpu":"200m","memory":"64Mi"}}
}]}}
EOF
)
    kubectl -n "$NAMESPACE" run "producer-$(date +%s)" --quiet -i --rm \
      --restart=Never --image=redis:7 --overrides="$overrides" <"$CORE"
    ;;
  *) usage ;;
esac
