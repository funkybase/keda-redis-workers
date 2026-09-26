#!/usr/bin/env bash
# Usage: check.sh [--wait [TIMEOUT_SECONDS]]
#
# Verifies the last producer run: once idle, done == expected and both
# 'jobs' and 'processing' are empty. Exits 0 on PASS, 1 on FAIL.
#
# With --wait it first polls until the system is idle (jobs empty and 'done'
# unchanged for IDLE_SECONDS) or until the timeout (default 600s).
set -euo pipefail
source "$(dirname "$0")/lib.sh"

IDLE_SECONDS="${IDLE_SECONDS:-15}"

snapshot() {
  # One round trip: expected, done, run_id, len(jobs), len(processing)
  printf 'GET expected\nGET done\nGET run_id\nLLEN jobs\nLLEN processing\n' | rcli
}

if [ "${1:-}" = "--wait" ]; then
  timeout="${2:-600}"
  deadline=$((SECONDS + timeout))
  last_done="" stable_since=$SECONDS
  while :; do
    mapfile -t s < <(snapshot); done_="${s[1]}" jobs="${s[3]}" processing="${s[4]}"
    echo "$(date -u +%H:%M:%S) done=${done_:-0} jobs=$jobs processing=$processing"
    if [ "$done_" != "$last_done" ] || [ "$jobs" -ne 0 ]; then
      last_done="$done_" stable_since=$SECONDS
    elif ((SECONDS - stable_since >= IDLE_SECONDS)); then
      break
    fi
    if ((SECONDS >= deadline)); then
      echo "timed out after ${timeout}s waiting for idle" >&2
      break
    fi
    sleep 5
  done
fi

mapfile -t s < <(snapshot)
expected="${s[0]}" done_="${s[1]}" run_id="${s[2]}" jobs="${s[3]}" processing="${s[4]}"
expected="${expected:-0}" done_="${done_:-0}"

echo "run=$run_id expected=$expected done=$done_ jobs=$jobs processing=$processing"

status=0
[ "$done_" -eq "$expected" ] || { echo "FAIL: done ($done_) != expected ($expected)"; status=1; }
[ "$jobs" -eq 0 ]            || { echo "FAIL: $jobs jobs still queued"; status=1; }
if [ "$processing" -ne 0 ]; then
  echo "FAIL: $processing jobs stuck in processing:"
  rcli LRANGE processing 0 -1 | sed 's/^/  /'
  status=1
fi
[ "$status" -eq 0 ] && echo "PASS"
exit "$status"
