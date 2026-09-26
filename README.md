# keda-redis-workers

A Redis-backed job worker on Kubernetes that KEDA scales from zero while jobs
are queued, and that doesn't lose jobs when it scales back down.

## Layout

```
kind/cluster.yaml     kind cluster: 1 control-plane + 2 workers
scripts/setup.sh      create cluster, install KEDA (Helm), create 'ingest' namespace
scripts/teardown.sh   delete the cluster
scripts/producer.sh   push N unique job IDs onto 'jobs'
scripts/check.sh      verify a run: done == N, 'jobs' and 'processing' empty
scripts/lib.sh        shared redis-cli-over-kubectl-exec helper
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
```

Override `CLUSTER_NAME` or `KEDA_VERSION` via env vars. The script is idempotent.

## Run

```bash
./scripts/producer.sh 200          # push 200 jobs
./scripts/check.sh --wait          # wait until idle, then PASS/FAIL
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

Both scripts run `redis-cli` inside the Redis pod via `kubectl exec`. That means
no port-forward, and the password never appears on a command line: the Redis
container gets it from the Secret as `$REDIS_PASSWORD` and `redis-cli` reads it
from `$REDISCLI_AUTH`.

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