# keda-redis-workers

A Redis-backed job worker on Kubernetes that KEDA scales from zero while jobs
are queued, and that doesn't lose jobs when it scales back down.

**Quick start** (the finished assignment, about 2.5 minutes from nothing):

```bash
./deploy/deploy.sh                 # kind cluster + KEDA + everything from Parts 1-3 + reaper
./scripts/producer.sh 100          # push 100 jobs
./scripts/check.sh --wait          # PASS once done == 100 and nothing is left in processing
./scripts/teardown.sh              # delete the cluster
```

## Layout

Shared tooling lives at the top level. Each part of the assignment has its own
directory. Part 1 is the base; later parts only contain overrides on top of it.

```
kind/cluster.yaml                  kind cluster: 1 control-plane + 2 workers
scripts/setup.sh                   create cluster, install KEDA (Helm), create 'ingest' namespace
scripts/teardown.sh                delete the cluster
scripts/producer.sh                push N unique job IDs onto 'jobs' (--mode exec|pod, --append)
scripts/producer-core.sh           the push logic, run inside a container by producer.sh
scripts/check.sh                   verify a run: done == N, 'jobs' and 'processing' empty
scripts/lib.sh                     shared redis-cli-over-kubectl-exec helper
scripts/watch-replicas.sh          record worker replicas + queue state over time
evidence/                          captured output from the runs below

part-1-deploy/
  manifests/kustomization.yaml     ties the manifests together, generates the worker-script ConfigMap
  manifests/redis.yaml             Redis 7 Deployment (password, readiness probe) + Service
  manifests/worker.yaml            worker-config ConfigMap (REDIS_HOST) + worker Deployment
  worker/worker.sh                 the worker loop (mounted into the stock redis:7 image)
  scripts/deploy.sh                create the redis-auth Secret, apply a kustomization (default: Part 1)

part-2-autoscale/manifests/        overrides on Part 1
  kustomization.yaml               Part 1 + the files below; drops the worker's fixed replicas
  triggerauthentication.yaml       KEDA gets the Redis password from the redis-auth Secret
  scaledobject.yaml                redis list trigger on 'jobs', 0-10 replicas

part-3-completion/                 overrides on Part 2
  manifests/kustomization.yaml     swaps in the fixed worker script, explicit 30s grace period
  worker/worker.sh                 worker with graceful shutdown + atomic completion
  scripts/scale-down-test.sh       100 jobs, with work still arriving while KEDA scales down

bonus-reaper/                      overrides on Part 3
  manifests/kustomization.yaml     Part 3 + reaper CronJob + generated reaper-script ConfigMap
  manifests/reaper.yaml            CronJob: every minute, re-queue jobs stuck in 'processing'
  reaper/reap.lua                  the atomic re-queue logic
  scripts/crash-test.sh            SIGKILL a worker mid-job, watch the reaper recover it

deploy/                            the finished assignment in one step
  all-in-one.yaml                  rendered from bonus-reaper/manifests (Parts 1-3 + reaper)
  render.sh                        regenerate all-in-one.yaml after changing any part
  deploy.sh                        setup.sh + Secret + apply all-in-one.yaml
```

To deploy one part on its own, run
`./part-1-deploy/scripts/deploy.sh <part>/manifests`. Each overlay includes
the parts before it.

## Prerequisites

- A container runtime that kind supports: Docker, Podman or nerdctl. See
  [kind's quick start](https://kind.sigs.k8s.io/docs/user/quick-start/) for
  using a runtime other than Docker.
- [kind](https://kind.sigs.k8s.io/) v0.33+ (creates Kubernetes v1.37 nodes)
- [Helm](https://helm.sh/) v3
- kubectl within one minor version of the cluster (v1.36 to v1.38). `setup.sh`
  warns if it's too old.
- bash

## Set up

```bash
./scripts/setup.sh        # kind cluster 'keda-redis' + KEDA 2.21.0 in ns 'keda' + ns 'ingest'
./part-1-deploy/scripts/deploy.sh   # redis-auth Secret + Redis + worker in ns 'ingest'
```

Or, for the finished assignment in one step: `./deploy/deploy.sh`.

Override `CLUSTER_NAME` or `KEDA_VERSION` via env vars. Both scripts are
idempotent.

## Run

```bash
./scripts/producer.sh 200              # push 200 jobs (via kubectl exec into Redis)
./scripts/producer.sh 200 --mode pod   # same, from a throwaway pod through the Service
./scripts/check.sh --wait              # wait until idle, then PASS/FAIL
```

**Producer:** job IDs are `<run-id>-<seq>` (e.g. `r20260926T054905-00042`),
unique within and across runs. One `MULTI`/`EXEC` pushes the jobs and also resets
`done=0`, sets `expected=N` and sets `run_id`, so the checker always compares
against the latest run. The producer refuses to start if `jobs` or
`processing` still hold entries from an earlier run, because leftovers would
make `done == N` meaningless. `--force` overrides this. `--append` adds jobs to
the current run instead (`expected += N`, `done` is not reset). Part 3 uses it
to keep work arriving mid-run.

**Check:** passes when `done == expected`, `jobs` is empty and `processing` is
empty. On failure it lists the job IDs stuck in `processing`. `--wait [secs]`
first polls until `jobs` is empty and `done` has stopped changing for
`IDLE_SECONDS` (default 15). Exit code is 0 on PASS and 1 on FAIL.

**Producer modes.** `--mode` (or `PRODUCER_MODE=exec|pod`) picks where the push
runs. Both modes stream the same [scripts/producer-core.sh](scripts/producer-core.sh)
into a `redis:7` container, so they behave identically. Neither needs
`redis-cli` on the host or exposes Redis outside the cluster.

| Mode | Runs in | Connects to | Pros | Cons |
|------|---------|-------------|------|------|
| `exec` (default) | the Redis pod (`kubectl exec`) | `127.0.0.1` | instant, nothing created | bypasses the Service; needs `pods/exec` RBAC |
| `pod` | a throwaway pod (`kubectl run --rm`) | the `redis` Service, using `worker-config` + `redis-auth` like the workers | proves the network path the workers use | ~2s pod start per run |

`check.sh` always uses `kubectl exec`. It only reads counters, so the Service
path isn't what it tests.

In both modes the password stays inside the cluster. Containers get it from the
`redis-auth` Secret as `$REDIS_PASSWORD`, and `redis-cli` reads it from
`$REDISCLI_AUTH`. It never appears on a command line or on the host.

## Part 1: Deploy

Everything is in namespace `ingest`, applied by `part-1-deploy/scripts/deploy.sh`.

**1. Redis with a password, behind a Service.** [part-1-deploy/manifests/redis.yaml](part-1-deploy/manifests/redis.yaml)
runs `redis:7` as a single-replica Deployment with a ClusterIP Service `redis`
on port 6379. The password is generated by `part-1-deploy/scripts/deploy.sh` (24 random bytes) and
stored only in the `redis-auth` Secret, so it is never committed to git.
Re-running `deploy.sh` keeps the existing Secret. The container writes the
password into a mode-600 config file and `exec`s `redis-server` with it:
- The password is not in the process list.
- `redis-server` is PID 1, so it receives SIGTERM directly and shuts down
  cleanly.

Persistence (RDB/AOF) is off, so a Redis restart empties the queue. That is
acceptable for this exercise, but listed under limitations.

**2. Worker reads host from a ConfigMap and password from a Secret.**
[part-1-deploy/manifests/worker.yaml](part-1-deploy/manifests/worker.yaml) defines:
- The `worker-config` ConfigMap, holding
  `REDIS_HOST=redis.ingest.svc.cluster.local`.
- The worker Deployment, which gets `REDIS_HOST` via `configMapKeyRef` and
  `REDIS_PASSWORD` via `secretKeyRef`.

The worker script itself ([part-1-deploy/worker/worker.sh](part-1-deploy/worker/worker.sh)) is mounted from
a ConfigMap that kustomize generates from the file. That means no image build,
and the ConfigMap's hash-suffixed name makes any script edit roll the workers.
For Parts 1 and 2 the script is the stub as given. It changes in Part 3.

**3. Resource requests/limits and readiness probe.**

| Container | requests (cpu / mem) | limits (cpu / mem) |
|-----------|----------------------|--------------------|
| redis     | 50m / 64Mi           | 500m / 256Mi       |
| worker    | 10m / 16Mi           | 100m / 64Mi        |

Redis has a readiness probe that runs an authenticated `redis-cli ping` and
expects `PONG`. That proves Redis is actually accepting commands with the
password, not just that the port is open. There is also a TCP liveness probe.
The Service only routes to Redis once the readiness probe passes.

**4. Push 20 jobs and confirm they drain.** The two worker replicas drained
20 jobs in about 40s ([evidence/part1-drain-20.txt](evidence/part1-drain-20.txt)):

```
$ ./scripts/producer.sh 20
06:15:34 pushed 20 jobs (run r20260926T061534); jobs=19
$ ./scripts/check.sh --wait
06:15:34 done=0 jobs=19 processing=1
06:15:39 done=2 jobs=16 processing=2
06:15:49 done=6 jobs=12 processing=2
06:16:00 done=13 jobs=5 processing=2
06:16:10 done=18 jobs=0 processing=2
06:16:15 done=20 jobs=0 processing=0
...
run=r20260926T061534 expected=20 done=20 jobs=0 processing=0
PASS
```

`processing` never goes above 2: one in-flight job per worker.

## Part 2: Autoscale with KEDA

```bash
./part-1-deploy/scripts/deploy.sh part-2-autoscale/manifests
./scripts/watch-replicas.sh &      # record replicas + queue every 3s
./scripts/producer.sh 200
```

**1. ScaledObject + TriggerAuthentication.** [part-2-autoscale/manifests/](part-2-autoscale/manifests/)
only holds overrides on Part 1:
- [scaledobject.yaml](part-2-autoscale/manifests/scaledobject.yaml): a `redis`
  trigger on list `jobs` for the `worker` Deployment, 0 to 10 replicas, with a
  target of `listLength: 5` queued jobs per replica.
  - The Redis host comes from the worker container's `REDIS_HOST` (via
    `hostFromEnv`), so it stays defined only in the `worker-config` ConfigMap.
- [triggerauthentication.yaml](part-2-autoscale/manifests/triggerauthentication.yaml):
  maps the scaler's `password` parameter to the existing `redis-auth` Secret.
  No credentials are in the ScaledObject.
- The kustomization removes `replicas: 2` from the worker Deployment. Once KEDA
  owns the replica count, a fixed value would be reapplied on every
  `kubectl apply`.

Timings are shortened from KEDA's defaults so scaling shows up within a short
run:

| Setting | Here | KEDA default |
|---------|------|--------------|
| `pollingInterval` | 5s | 30s |
| `cooldownPeriod` | 30s | 300s |
| HPA scale-down stabilization window | 15s | 300s |

**2. Replica count while 200 jobs drain** ([evidence/part2-replicas-200.txt](evidence/part2-replicas-200.txt)).
`spec` is the replica count KEDA/the HPA asked for, `ready` is Ready pods,
`pods` includes Terminating ones. Some rows are omitted:

```
time       t+s  spec ready  pods  jobs processing  done
06:59:40     4     0     0     0     0          0    30   <- idle at 0 replicas ('done' is from an earlier run)
06:59:43     7     0     0     0   200          0     0   <- producer pushes 200
06:59:50    14     1     1     1   199          1     0   <- KEDA operator: 0 -> 1
06:59:54    18     5     3     5   194          5     1   <- HPA: 1 -> 5
07:00:11    35    10    10    10   164         10    26   <- HPA: 5 -> 10 (max)
07:00:52    76    10    10    10    42         10   148
07:00:55    79     8     8    10    30         10   160   <- HPA scales down; queue shrinking
07:01:09    93     1     1    10     0          2   198   <- queue empty, 9 pods still Terminating
07:01:12    96     1     1    10     0          0   200
07:01:26   110     1     1     8     0          0   200
07:01:36   120     0     0     8     0          0   200   <- KEDA operator: 1 -> 0 after 30s cooldown
07:02:07   151     0     0     0     0          0   200
run=r20260926T065943 expected=200 done=200 jobs=0 processing=0
PASS
```

In total: 0 → 1 → 5 → 10 → 8 → 1 → 0. The 200 jobs finished about 90s after
being pushed, and the check passes.

### How does the worker get from 0 to 1 replica, and from 1 to N?

KEDA splits the job between two components, because a Kubernetes HPA cannot
scale a workload to or from zero. Its `minReplicas` is at least 1.

**0 → 1: the KEDA operator.**
1. Every `pollingInterval` (5s here), `keda-operator` runs the Redis scaler,
   authenticating with the TriggerAuthentication. The scaler runs `LLEN jobs`.
2. If the length is above `activationListLength` (0), the ScaledObject becomes
   Active.
3. If the Deployment is at 0, the operator itself patches it to 1 replica
   (`minReplicaCount` is 0, so 1 is the next step up).

In the run above the operator went from 0 to 1 about 7s after the push: up to
one polling interval, plus pod scheduling and startup.

**1 → N: the HPA that KEDA manages.**
1. When the ScaledObject is created, KEDA creates an HPA, `keda-hpa-worker`
   (`kubectl -n ingest get hpa`). Its target is an External metric,
   `s0-redis-jobs`, with an average value of 5 per pod.
2. The metric is served by `keda-operator-metrics-apiserver`, which KEDA
   registers as the cluster's `external.metrics.k8s.io` API. That server asks the
   operator, and the operator runs the scaler (`LLEN jobs`).
3. Every 15s, the kube-controller-manager's HPA controller reads the metric and
   computes `desired = ceil(LLEN(jobs) / 5)`, clamped to 1 to 10. With 200
   queued, that's ceil(40) → 10.
4. It rises in steps rather than jumping straight there, because of the HPA's
   default scale-up policy: at most +100% or +4 pods, whichever is larger, per
   15s. That gives the observed 1 → 5 → 10.

**N → 1 → 0.**
- Down to 1: the HPA lowers the replica count as the queue shrinks, after the
  15s stabilization window.
- To 0: once the list has been empty for `cooldownPeriod` (30s), the operator
  sets the Deployment to 0. In the run, the queue was empty at about t=93s and
  the worker was at 0 by t=120s.

**What the metric doesn't count.** The trigger only sees `jobs`, not
`processing`. The last jobs are still being worked on when the HPA sees an
almost empty queue, so it scales down while jobs are in flight. In this run the
HPA dropped to 8 and then 1 replica while `processing` was still 10.

Those pods then stayed Terminating (`pods` column) for about 30s. The stub runs
as `bash` PID 1, which ignores SIGTERM, so they kept looping until the kubelet
SIGKILLed them at the end of the 30s grace period. Here the queue had already
drained before the kills, so nothing was lost. Part 3 shows what happens when it
hasn't.

## Part 3: Don't lose jobs

```bash
./part-1-deploy/scripts/deploy.sh part-2-autoscale/manifests    # stub worker
./part-3-completion/scripts/scale-down-test.sh evidence/trace.txt   # FAIL
./part-1-deploy/scripts/deploy.sh part-3-completion/manifests   # fixed worker
./part-3-completion/scripts/scale-down-test.sh evidence/trace.txt   # PASS
```

### 1. What happens with the stub as given?

**What the stub does on scale-down.** The stub runs as `bash` PID 1 in its
container and doesn't install a signal handler. The kernel doesn't deliver
signals with the default action to PID 1, so **it ignores the SIGTERM** the
kubelet sends when KEDA/the HPA scales the Deployment down. The pod shows as
Terminating, but the loop keeps taking new jobs with `BLMOVE`. After
`terminationGracePeriodSeconds` (30s) the kubelet SIGKILLs it. If it holds a job
at that moment, the job is already in `processing` and is never removed or
counted. Nothing ever looks at `processing` again, so it is lost for good.

**A single burst of 100 jobs hid this.** With 100 jobs pushed at once, KEDA
scaled 10 → 6 → 1 → 0 mid-run, and the check still passed
([evidence/part3-before-replicas-100.txt](evidence/part3-before-replicas-100.txt)).
The Terminating pods kept working, the queue was empty before their 30s ran
out, and every pod was idle when it was SIGKILLed. So the stub is only safe by
accident: the kill happens to land after the work runs out.

**Reproducing the loss.**
[scale-down-test.sh](part-3-completion/scripts/scale-down-test.sh) keeps the
total at 100 jobs but models bursty traffic:
1. Push 40 jobs.
2. The moment KEDA starts scaling down, append 10 jobs every 5s (`producer.sh --append`).

With the stub
([trace](evidence/part3-before-trace.txt), [check](evidence/part3-before-check.txt)),
a scaled-down pod was still taking jobs when its grace period ended:

```
time       t+s  spec ready  pods  jobs processing  done
07:32:06    20     5     5     5    22          5    13
07:32:10    24     4     4     5    27          5    18   <- scale-down: 1 pod Terminating, still working
07:32:40    54     6     6     6    25          7    68   <- ~30s later: SIGKILL (pods 7 -> 6) mid-job
07:33:04    78     1     1     6     0          1    99
07:33:56   130     0     0     0     0          1    99   <- scaled to zero; the job never comes back
run=r20260926T073150067 expected=100 done=99 jobs=0 processing=1
FAIL: done (99) != expected (100)
FAIL: 1 jobs stuck in processing:
  r20260926T073219475-00006
```

**Two more problems in the stub:**
- **`redis-cli` prints server errors to stdout with exit code 0.** If Redis
  answers `NOAUTH Authentication required.`, that text becomes `$job`. The
  stub then "processes" it and increments `done` for a job that never existed.
- **`LREM` and `INCR` are two separate commands.** A kill between them leaves
  a removed job that is never counted.

### 2. The fix

[part-3-completion/worker/worker.sh](part-3-completion/worker/worker.sh):

1. **Graceful shutdown.** `trap ... TERM` sets a flag.
   - Bash runs the trap when the current foreground command returns. So a job
     in hand is always finished and completed first, and then the loop exits
     instead of taking another job.
   - `BLMOVE` now blocks for only 2s, so an idle worker notices SIGTERM quickly.
   - Worst-case shutdown time is about 2s + 5s + the completion call, well within
     the grace period. The overlay sets it to 30s explicitly
     ([kustomization.yaml](part-3-completion/manifests/kustomization.yaml)),
     with a comment that it must stay above the longest job.
2. **Atomic completion.** Removing the job from `processing` and `INCR done` are
   now a single Lua `EVAL`, so a kill can't split them.
   - If the job isn't in `processing`, because the bonus reaper already
     re-queued it, the script removes it from `jobs` instead.
   - It counts the job only if a copy was found. So a job run twice is still
     counted once.
3. **Errors are errors.** `redis-cli -e` makes error replies exit non-zero:
   - A failed `BLMOVE` is retried instead of being treated as a job.
   - A failed completion is retried until Redis confirms it.
4. The password is passed via `REDISCLI_AUTH` instead of `-a`, so it's not in
   the process list.

**After the fix**, with the identical test
([trace](evidence/part3-after-trace.txt), [check](evidence/part3-after-check.txt)).
Scaled-down pods now leave within one sample, about 3s, instead of 30s:

```
time       t+s  spec ready  pods  jobs processing  done
07:34:36    24     5     5     5    19          5    16
07:34:40    28     4     4     5    24          5    21   <- scale-down: 1 pod Terminating
07:34:43    31     4     4     4    19          4    27   <- ...finished its job and exited
07:35:24    72     2     2     6     6          5    89
07:35:28    76     2     2     2     4          2    94   <- 4 pods drained and gone within ~3s
07:36:09   117     0     0     0     0          0   100
run=r20260926T073416642 expected=100 done=100 jobs=0 processing=0
PASS
```

What a scaled-down worker logs ([evidence/part3-after-shutdown-logs.txt](evidence/part3-after-shutdown-logs.txt)):

```
07:36:52 worker-96b596f77-625bl done r20260926T073626656-00019
07:36:57 worker-96b596f77-625bl SIGTERM: finishing current job, then exiting
07:36:57 worker-96b596f77-625bl done r20260926T073626656-00023
07:36:57 worker-96b596f77-625bl exiting cleanly
```

The `SIGTERM` line is printed when the trap runs, which is once the job's
`sleep` returns. That's why it has the same timestamp as the last `done`.

### What failure cases does the fix not cover?

The fix only handles **graceful** termination: SIGTERM followed by enough
time to finish. A job still ends up stranded in `processing` if the worker
dies without that:

| Failure | Why the fix doesn't help | Covered by the reaper? |
|---------|--------------------------|------------------------|
| **OOM kill, or any SIGKILL** | No SIGTERM, so the trap never runs. `kubectl delete --force --grace-period=0` does *not* cause this: the kubelet still sends SIGTERM and waits for the grace period. | yes |
| **Node failure / kernel panic / VM loss** | The process just stops. | yes |
| **Job outlives the grace period** (a real job taking more than 30s, or Redis unreachable while completing) | The kubelet SIGKILLs mid-job or mid-retry. | yes |
| **Container crash** (bug, `set -u` violation, etc.) | Same as SIGKILL. | yes |
| **Redis itself restarts** | Persistence is off, so `jobs`, `processing` and `done` all vanish. | **no**, needs AOF + a PVC, or a durable queue |
| **Redis failover** (if replicated) | Async replication can drop the last writes. | **no** |
| **Duplicate execution** | After a re-queue (or a network error after a successful `BLMOVE`), a job can run twice. This is at-least-once delivery: `done` stays correct, but job side effects must be idempotent. | n/a, this is inherent |
| **Poison jobs** | A job that always crashes its worker is re-queued forever. There's no attempt count or dead-letter list. | **no** |
| **Jobs lost before `BLMOVE`** | The producer's `MULTI`/`EXEC` is all-or-nothing, but a producer crash before `EXEC` loses that batch. | **no**, the producer should retry |

## Bonus: reaper CronJob

**Choice: the reaper, not a ScaledJob.** Part 3 asks what the fix doesn't
cover. The honest answer is "any death without a graceful shutdown", which is
the most common way workers die in production: OOM kills, node loss, evictions
past the grace period. The reaper closes that gap. It is the recovery half of
the reliable-queue pattern the stub half-implements with `BLMOVE` to
`processing`. Without a reaper, `processing` is a record of what was lost, not
a way to get it back.

A ScaledJob is a valid design, but it's a *different* way to avoid scale-down
kills: every job gets its own pod, which KEDA never terminates. It doesn't help
with OOM or node loss either, and a Job pod that dies after `BLMOVE` strands its
job in `processing` just the same. It trades the problem rather than solving
it, and adds a pod start (~2s) to every 2-5s job.

The reaper design also forces the questions that show whether the system is
really correct:
- **Clock skew.** Whose clock decides a job is stuck? The reaper uses Redis
  `TIME`, so there's a single clock.
- **Deaths between steps.** What if a worker dies between `BLMOVE` and
  recording a claim time? The workers record nothing; the reaper stamps a job
  the first time *it* sees it in `processing`.
- **Races.** What if the reaper re-queues a job just as a slow worker finishes
  it? The reap is one atomic Lua script. The worker's completion script
  removes the other copy and counts the job only once.
- **Choosing the timeout.** It must be above the longest job, or live jobs get
  duplicated.

**How it works** ([bonus-reaper/reaper/reap.lua](bonus-reaper/reaper/reap.lua),
[reaper.yaml](bonus-reaper/manifests/reaper.yaml)):
- The CronJob runs every minute with `concurrencyPolicy: Forbid`, using the
  same ConfigMap/Secret as the worker.
- Each run is one atomic `EVAL`:
  1. Stamp every job in `processing` that isn't yet in the `reaper:seen` hash
     with the current Redis time.
  2. Re-queue with `LPUSH` (so it's next to be taken) any job stamped at least
     `REAP_AFTER_SECONDS` (45s) ago.
  3. Remove stamps for jobs that have since completed.
- With a 1-minute schedule, a stranded job is re-queued 1-2 minutes after its
  worker died. KEDA then sees `jobs` > 0 and scales a worker up if it was at 0.
- The workers need no changes for this.

**Evidence** ([evidence/bonus-reaper-crash-test.txt](evidence/bonus-reaper-crash-test.txt),
produced by [crash-test.sh](bonus-reaper/scripts/crash-test.sh)). A worker's
process is SIGKILLed from its kind node mid-job, which is exactly what an OOM
kill does:

```
07:40:57 pushed 20 jobs (run r20260926T074057430) via 127.0.0.1; jobs=19
07:40:57 in processing: r20260926T074057430-00001
07:40:57 SIGKILL worker process of worker-96b596f77-pxkf5 on node keda-redis-worker (like an OOM kill)
--- after the queue drains, before the reaper:
run=r20260926T074057430 expected=20 done=19 jobs=0 processing=1
FAIL: done (19) != expected (20)
FAIL: 1 jobs stuck in processing:
  r20260926T074057430-00001
--- waiting for the reaper (runs every minute, re-queues after REAP_AFTER_SECONDS=45):
[pod/reaper-29840142-x28jk/reaper] 07:42:00 re-queued:
[pod/reaper-29840142-x28jk/reaper] r20260926T074057430-00001
run=r20260926T074057430 expected=20 done=20 jobs=0 processing=0
PASS
```

The 07:41 pass stamped the job, and the 07:42 pass re-queued it. KEDA started
a worker, which finished it.

My first version of this test used `kubectl delete pod --force
--grace-period=0`, and **no job was lost**. That only removes the API object;
the kubelet still sends SIGTERM and honours the grace period, which the Part 3
worker handles. A test that doesn't actually produce the failure would have
"proved" the reaper by accident, so the test now kills the process on the node.

## What I'd do with more time

- **Durability:** turn on Redis AOF (`appendfsync everysec`) with a PVC, or
  move to Redis Streams. Streams have consumer groups with a per-message
  pending list, delivery counts and `XAUTOCLAIM`, which are a built-in reaper.
  Alternatively, use a queue built for this (SQS, RabbitMQ with manual acks).
- **Poison jobs:** keep an attempt counter per job in the reaper. After N
  re-queues, move the job to a `dead` list and alert.
- **Heartbeats instead of a fixed timeout:** have workers refresh a per-job
  lease (`SET lease:<job> <worker> EX 15`). The reaper then re-queues when the
  lease expires, which suits long jobs without a large global timeout. It also
  means the reaper could run as a small always-on loop instead of a 1-minute
  CronJob.
- **Scale on `jobs + processing`:** the trigger ignores in-flight work, which is
  why KEDA scales down while every worker is busy. A second trigger on
  `processing` (or on the sum) would keep capacity until work actually finishes.
- **ScaledJob comparison:** implement it and run the same tests. It would be
  useful for long, uneven jobs, where one pod per job is worth the start-up
  cost.
- **Metrics and alerts:** queue depth, oldest job age, the rate of re-queued and
  duplicate jobs, and worker restarts, exported for Prometheus.
- **Hardening:** a real worker image with a proper client (retries, timeouts)
  instead of bash + `redis-cli`; `securityContext` (non-root, read-only root
  filesystem); a NetworkPolicy so only the workers, the reaper and KEDA can
  reach Redis; TLS to Redis; a PodDisruptionBudget for Redis.
- **CI:** run `deploy/deploy.sh`, `scale-down-test.sh` and `crash-test.sh` in a
  kind-based pipeline, so the evidence is regenerated on every change.

## Tear down

```bash
./scripts/teardown.sh
```

## Test Setup
Tested with kind v0.33.0 (Kubernetes v1.37.0 nodes), Helm v3.18, kubectl
v1.37.0 and Podman 6.0.2, on WSL2 Ubuntu.

- **Podman on WSL2:** kind runs `podman` as a binary, so a shell alias isn't
  enough. With the Windows Podman machine as the engine:
  ```bash
  podman.exe machine start                        # from Windows or via /mnt/c/...
  # copy the machine's SSH key into WSL (the Windows copy has the wrong permissions)
  cp /mnt/c/Users/<you>/.local/share/containers/podman/machine/machine ~/.ssh/podman-machine
  chmod 600 ~/.ssh/podman-machine
  # 'podman-remote' is the remote client; here it is podman-remote-static-linux_amd64
  podman-remote system connection add --default podman-machine-root \
    --identity ~/.ssh/podman-machine \
    ssh://root@127.0.0.1:<port>/run/podman/podman.sock   # port from `podman.exe system connection list`
  export KIND_EXPERIMENTAL_PROVIDER=podman
  ```
  kind looks for a binary named `podman` on PATH, so a two-line wrapper at
  `~/bin/podman` forwards to the remote client:
  ```bash
  #!/bin/sh
  exec podman-remote-static-linux_amd64 "$@"
  ```
  kind needs the **rootful** connection. Docker works too; just unset
  `KIND_EXPERIMENTAL_PROVIDER`.