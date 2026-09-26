#!/usr/bin/env bash
# Usage: crash-test.sh
#
# Shows the reaper recovering a job that graceful shutdown cannot save:
#   1. push 20 jobs
#   2. once a worker is holding a job, SIGKILL its process from the kind node,
#      which is exactly what the kernel OOM killer does. No SIGTERM, no grace
#      period, so its job is stranded. (`kubectl delete --force
#      --grace-period=0` would NOT do this: it only removes the API object,
#      and the kubelet still sends SIGTERM and honours the pod's grace period,
#      which the fixed worker handles cleanly.)
#   3. wait for the queue to drain; check.sh FAILs with the stranded job
#   4. wait for the reaper CronJob to re-queue it and a worker to finish it;
#      check.sh PASSes
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/lib.sh"

# kind nodes are containers; reach them with the same runtime kind uses.
if [ "${KIND_EXPERIMENTAL_PROVIDER:-}" = podman ]; then RUNTIME=podman
elif [ "${KIND_EXPERIMENTAL_PROVIDER:-}" = nerdctl ]; then RUNTIME=nerdctl
else RUNTIME=docker; fi

"$ROOT/scripts/producer.sh" 20

while [ "$(rcli LLEN processing)" -eq 0 ]; do sleep 1; done
read -r victim node < <(kubectl -n "$NAMESPACE" get pods -l app=worker \
  --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name} {.items[0].spec.nodeName}{"\n"}')
echo "$(date -u +%H:%M:%S) in processing: $(rcli LRANGE processing 0 -1 | tr '\n' ' ')"
echo "$(date -u +%H:%M:%S) SIGKILL worker process of $victim on node $node (like an OOM kill)"
"$RUNTIME" exec "$node" sh -c '
  cid=$(crictl ps -q --name worker --label io.kubernetes.pod.name='"$victim"')
  kill -9 "$(crictl inspect --output go-template --template "{{.info.pid}}" "$cid")"'

echo "--- after the queue drains, before the reaper:"
until [ "$(rcli LLEN jobs)" -eq 0 ]; do sleep 2; done
sleep 8 # let the surviving workers finish their last jobs
"$ROOT/scripts/check.sh" || true

echo "--- waiting for the reaper (runs every minute, re-queues after REAP_AFTER_SECONDS=45):"
until [ "$(rcli LLEN processing)" -eq 0 ] && [ "$(rcli LLEN jobs)" -eq 0 ]; do sleep 5; done
kubectl -n "$NAMESPACE" logs -l app=reaper --tail=-1 --prefix --max-log-requests 10 2>/dev/null \
  | grep -A3 're-queued' | grep -v '^--$' || true
IDLE_SECONDS=10 "$ROOT/scripts/check.sh" --wait 300 | tail -2
