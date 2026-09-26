#!/bin/bash
# Moves a job from 'jobs' to 'processing', works on it, then removes it from 'processing'.
while true; do
  job=$(redis-cli -h "$REDIS_HOST" -a "$REDIS_PASSWORD" --no-auth-warning \
    BLMOVE jobs processing LEFT RIGHT 5)
  [ -n "$job" ] || continue
  sleep $((RANDOM % 4 + 2)) # simulated work: 2-5s
  redis-cli -h "$REDIS_HOST" -a "$REDIS_PASSWORD" --no-auth-warning LREM processing 1 "$job"
  redis-cli -h "$REDIS_HOST" -a "$REDIS_PASSWORD" --no-auth-warning INCR done
done
