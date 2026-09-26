#!/usr/bin/env bash
# Usage: producer.sh N [--force]
#
# Pushes N unique job IDs onto the 'jobs' list. IDs look like
# <run-id>-<seq>, e.g. r20260926T134501-00042, so they are unique within and
# across runs.
#
# In the same MULTI/EXEC transaction it resets the 'done' counter and records
# 'expected' = N and 'run_id', so check.sh can verify the run.
#
# Refuses to start if 'jobs' or 'processing' still hold anything from a
# previous run (that would make done == N meaningless); --force overrides.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

N="${1:-}"
FORCE="${2:-}"
if ! [[ "$N" =~ ^[1-9][0-9]*$ ]]; then
  echo "usage: $0 N [--force]" >&2
  exit 2
fi

queued=$(rcli LLEN jobs)
inflight=$(rcli LLEN processing)
if [ "$FORCE" != "--force" ] && { [ "$queued" -ne 0 ] || [ "$inflight" -ne 0 ]; }; then
  echo "refusing: jobs=$queued processing=$inflight from a previous run (use --force)" >&2
  exit 1
fi

RUN_ID="r$(date -u +%Y%m%dT%H%M%S)"
CHUNK=500 # IDs per RPUSH, keeps each command line a sane size

{
  echo "MULTI"
  echo "SET done 0"
  echo "SET expected $N"
  echo "SET run_id $RUN_ID"
  for ((start = 1; start <= N; start += CHUNK)); do
    end=$((start + CHUNK - 1)); ((end > N)) && end=$N
    printf 'RPUSH jobs'
    for ((i = start; i <= end; i++)); do printf ' %s-%05d' "$RUN_ID" "$i"; done
    printf '\n'
  done
  echo "EXEC"
} | rcli >/dev/null

echo "$(date -u +%H:%M:%S) pushed $N jobs (run $RUN_ID); jobs=$(rcli LLEN jobs)"
