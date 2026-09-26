#!/bin/bash
# Usage (inside a redis:7 container): producer-core.sh N RUN_ID [--force|--append]
#
# The actual push logic. producer.sh streams this script into a container
# (`bash -s`), either the Redis pod itself or a one-off producer pod, so both
# modes behave identically. Needs REDIS_PASSWORD; REDIS_HOST defaults to
# 127.0.0.1 (i.e. when running inside the Redis pod).
set -euo pipefail

N="$1" RUN_ID="$2" OPT="${3:-}"
export REDISCLI_AUTH="$REDIS_PASSWORD"

# stdin is this script (bash -s), so keep redis-cli from reading it.
r() { redis-cli -h "${REDIS_HOST:-127.0.0.1}" --no-auth-warning "$@" </dev/null; }

queued=$(r LLEN jobs)
inflight=$(r LLEN processing)
if [ -z "$OPT" ] && { [ "$queued" -ne 0 ] || [ "$inflight" -ne 0 ]; }; then
  echo "refusing: jobs=$queued processing=$inflight from a previous run (use --force)" >&2
  exit 1
fi

CHUNK=500 # IDs per RPUSH, keeps each command line a sane size

{
  echo "MULTI"
  if [ "$OPT" = "--append" ]; then
    # Add to the current run: 'expected' grows, 'done' keeps counting.
    echo "INCRBY expected $N"
  else
    echo "SET done 0"
    echo "SET expected $N"
    echo "SET run_id $RUN_ID"
  fi
  for ((start = 1; start <= N; start += CHUNK)); do
    end=$((start + CHUNK - 1)); ((end > N)) && end=$N
    printf 'RPUSH jobs'
    for ((i = start; i <= end; i++)); do printf ' %s-%05d' "$RUN_ID" "$i"; done
    printf '\n'
  done
  echo "EXEC"
} | redis-cli -h "${REDIS_HOST:-127.0.0.1}" --no-auth-warning >/dev/null

echo "$(date -u +%H:%M:%S) pushed $N jobs (run $RUN_ID) via ${REDIS_HOST:-127.0.0.1}; jobs=$(r LLEN jobs)"
