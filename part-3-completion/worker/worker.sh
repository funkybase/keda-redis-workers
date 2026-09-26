#!/bin/bash
# Moves a job from 'jobs' to 'processing', works on it, then removes it from
# 'processing'. Fixed version of the stub; the differences:
#
# 1. Graceful shutdown. SIGTERM is trapped: the worker finishes the job it is
#    holding, then exits instead of taking another. The stub runs as PID 1
#    with no handler, so SIGTERM is ignored, it keeps taking jobs, and the
#    kubelet SIGKILLs it mid-job when the grace period runs out.
# 2. Atomic completion. Removing the job from 'processing' and counting it in
#    'done' is one Lua script, so no crash can leave one done without the other.
# 3. Redis errors are errors. With -e, an error reply (e.g. NOAUTH) exits
#    non-zero instead of being printed and treated as a job ID. Completion is
#    retried until Redis confirms it.
# 4. The password is passed via REDISCLI_AUTH instead of -a, so it is not in
#    the process list.
set -u

export REDISCLI_AUTH="$REDIS_PASSWORD"
r() { redis-cli -e -h "$REDIS_HOST" --no-auth-warning "$@"; }
log() { echo "$(date -u +%H:%M:%S) $HOSTNAME $*"; }

# KEYS: processing, jobs, done   ARGV: job
# Removes one copy of the job and counts it once. Normally the copy is in
# 'processing'. If the reaper (bonus) re-queued it while we were slow, the copy
# is back in 'jobs' (remove it so nobody runs it again) or in 'processing' under
# another worker; either way whichever completion gets there first counts it,
# and a later one finds nothing and returns 0.
COMPLETE='
local n = redis.call("LREM", KEYS[1], 1, ARGV[1])
if n == 0 then n = redis.call("LREM", KEYS[2], 1, ARGV[1]) end
if n == 0 then return 0 end
redis.call("INCR", KEYS[3])
return 1'

stopping=0
# Bash runs the trap once the current foreground command (BLMOVE, sleep,
# completion) returns, so a job in hand is always finished first.
trap 'stopping=1; log "SIGTERM: finishing current job, then exiting"' TERM

log "started"
while ((!stopping)); do
  # Short blocking timeout: an idle worker notices SIGTERM within ~2s.
  if ! job=$(r BLMOVE jobs processing LEFT RIGHT 2); then
    log "redis error on BLMOVE: $job"; sleep 1; continue
  fi
  [ -n "$job" ] || continue

  sleep $((RANDOM % 4 + 2)) # simulated work: 2-5s

  until res=$(r EVAL "$COMPLETE" 3 processing jobs done "$job"); do
    log "redis error completing $job: $res (retrying)"; sleep 1
  done
  [ "$res" = 1 ] && log "done $job" || log "done $job (already completed elsewhere, not counted)"
done
log "exiting cleanly"
