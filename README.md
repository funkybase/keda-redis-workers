# keda-redis-workers

A Redis-backed job worker on Kubernetes that KEDA scales from zero while jobs
are queued, and that doesn't lose jobs when it scales back down.

## Layout

Shared tooling lives at the top level. Each part of the assignment has its own
directory. Part 1 is the base; later parts only contain overrides on top of it.

```
kind/cluster.yaml                  kind cluster: 1 control-plane + 2 workers
scripts/setup.sh                   create cluster, install KEDA (Helm), create 'ingest' namespace
scripts/teardown.sh                delete the cluster
scripts/producer.sh                push N unique job IDs onto 'jobs' (--mode exec|pod)
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
```

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
make `done == N` meaningless. `--force` overrides this.

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