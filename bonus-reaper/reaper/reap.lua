-- Re-queues jobs stuck in 'processing'. Run atomically via EVAL, so it cannot
-- race a worker's claim (BLMOVE) or completion (the worker's Lua script).
--
-- KEYS[1] processing   KEYS[2] jobs   KEYS[3] reaper:seen (hash job -> ts)
-- ARGV[1] reap-after seconds
-- Returns the list of re-queued job IDs.
--
-- Workers don't record when they claim a job, so the reaper tracks it itself:
-- the first pass that sees a job in 'processing' stamps it; a later pass that
-- still sees it REAP_AFTER seconds on re-queues it. That needs no changes to
-- the worker, and it also catches a worker killed right after BLMOVE. Times
-- come from Redis (TIME) so there is one clock, whatever pod runs this.
local now = tonumber(redis.call('TIME')[1])
local reap_after = tonumber(ARGV[1])

local inflight, requeued = {}, {}
for _, job in ipairs(redis.call('LRANGE', KEYS[1], 0, -1)) do
  local first = redis.call('HGET', KEYS[3], job)
  if not first then
    redis.call('HSET', KEYS[3], job, now)
    inflight[job] = true
  elseif now - tonumber(first) >= reap_after then
    redis.call('LREM', KEYS[1], 1, job)
    redis.call('HDEL', KEYS[3], job)
    -- LPUSH: workers pop from the left, so the oldest job goes first.
    redis.call('LPUSH', KEYS[2], job)
    table.insert(requeued, job)
  else
    inflight[job] = true
  end
end

-- Forget stamps for jobs that completed since the last pass.
for _, job in ipairs(redis.call('HKEYS', KEYS[3])) do
  if not inflight[job] then redis.call('HDEL', KEYS[3], job) end
end

return requeued
