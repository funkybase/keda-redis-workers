#!/usr/bin/env bash
# Usage: scale-down-test.sh TRACE_FILE
#
# Pushes TOTAL (100) jobs so that KEDA scales the worker down while work is
# still arriving, then waits for idle and runs check.sh.
#
#   1. Push FIRST (40) jobs. KEDA scales the worker up.
#   2. As soon as KEDA starts scaling down, keep appending BATCH (10) jobs every
#      GAP (5) seconds until TOTAL have been pushed.
#
# Pods that were scaled down are Terminating during step 2, so a worker that
# doesn't stop cleanly is still taking jobs when its grace period ends and it
# is SIGKILLed. A single 100-job burst hides this: the queue is usually empty
# by the time the SIGKILL comes, so the stub survives by luck.
#
# The replica/queue trace (scripts/watch-replicas.sh) goes to TRACE_FILE.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/lib.sh"

TRACE="${1:?usage: $0 TRACE_FILE}"
TOTAL="${TOTAL:-100}" FIRST="${FIRST:-40}" BATCH="${BATCH:-10}" GAP="${GAP:-5}"

spec() { kubectl -n "$NAMESPACE" get deploy worker -o jsonpath='{.spec.replicas}'; }

"$ROOT/scripts/watch-replicas.sh" 3 600 >"$TRACE" &
watcher=$!
trap 'kill $watcher 2>/dev/null || true' EXIT
sleep 4

"$ROOT/scripts/producer.sh" "$FIRST"
pushed=$FIRST

peak=0
while :; do
  s=$(spec); s=${s:-0}
  ((s > peak)) && peak=$s
  if ((peak > 1 && s < peak)); then
    echo "$(date -u +%H:%M:%S) KEDA scaling down: $peak -> $s replicas; appending jobs while pods terminate"
    break
  fi
  sleep 1
done

while ((pushed < TOTAL)); do
  n=$((TOTAL - pushed < BATCH ? TOTAL - pushed : BATCH))
  "$ROOT/scripts/producer.sh" "$n" --append
  pushed=$((pushed + n))
  ((pushed < TOTAL)) && sleep "$GAP"
done

wait "$watcher" || true
trap - EXIT
"$ROOT/scripts/check.sh"
