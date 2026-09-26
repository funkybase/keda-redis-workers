#!/usr/bin/env bash
# Usage: watch-replicas.sh [INTERVAL_SECONDS] [MAX_SECONDS]
#
# Prints one line per interval with the worker replica counts and the queue
# state, until the worker is back at 0 replicas with nothing queued (after
# having scaled up), or MAX_SECONDS pass (default 600).
#
#   spec    replicas the Deployment is asked for (set by KEDA / its HPA)
#   ready   worker pods that are Running and Ready
#   pods    worker pods that exist, including Terminating ones
set -euo pipefail
source "$(dirname "$0")/lib.sh"

INTERVAL="${1:-3}"
MAX="${2:-600}"
start=$SECONDS seen_up=0

printf '%-8s %5s %5s %5s %5s %5s %10s %5s\n' time t+s spec ready pods jobs processing done
while ((SECONDS - start <= MAX)); do
  spec=$(kubectl -n "$NAMESPACE" get deploy worker -o jsonpath='{.spec.replicas}')
  ready=$(kubectl -n "$NAMESPACE" get deploy worker -o jsonpath='{.status.readyReplicas}')
  pods=$(kubectl -n "$NAMESPACE" get pods -l app=worker --no-headers 2>/dev/null | wc -l)
  mapfile -t q < <(printf 'LLEN jobs\nLLEN processing\nGET done\n' | rcli)
  printf '%-8s %5s %5s %5s %5s %5s %10s %5s\n' "$(date -u +%H:%M:%S)" $((SECONDS - start)) \
    "${spec:-0}" "${ready:-0}" "$pods" "${q[0]}" "${q[1]}" "${q[2]:-0}"
  ((${spec:-0} > 0)) && seen_up=1
  if ((seen_up && ${spec:-0} == 0 && pods == 0 && q[0] == 0)); then break; fi
  sleep "$INTERVAL"
done
