# Kubernetes Disaster Recovery and Resilience Lab

A self-contained lab on one Docker host that **breaks a Kubernetes app on purpose and measures how it recovers**.
Run-from-scratch commands are in [STEPS.md](STEPS.md). Plan and runbook: [docs/DR-PLAN.md](docs/DR-PLAN.md).

```
                       ┌───────────────────────── Docker host ─────────────────────────┐
  hourly Velero  ───►  │  primary cluster (k3d: 1 server + 2 agents)                     │
  backups              │    web      3 replicas, spread, PodDisruptionBudget (min 2)     │
                       │    notes    1 replica, SQLite on a volume, pre-backup hook      │
                       │       │ backups (Velero + file-system backup)                   │
                       │       ▼                                                         │
                       │  MinIO container  (outside both clusters, S3 API)               │
                       │       ▲ read-only                                               │
                       │  recovery cluster (k3d: 1 node)  ◄── restore after disaster     │
                       └─────────────────────────────────────────────────────────────────┘
```

## The three drills

| Drill | Hypothesis | Measured |
|---|---|---|
| `drill-pod-kill.sh` | Killing pods is harmless: web stays up, notes returns with all data | availability %, recovery seconds, rows before/after |
| `drill-node-drain.sh` | Draining a node never drops below 2 ready web pods | lowest ready count, availability % |
| `drill-dr.sh` | After losing the whole primary cluster, everything backed up is recoverable elsewhere | **RPO** (writes lost), **RTO** (seconds), written to `reports/` |

Each drill states a hypothesis, injects a failure, measures, and prints PASS/FAIL: the chaos-engineering loop applied to recovery.

## Ideas it demonstrates

- **RPO and RTO** as measured numbers, not slogans.
- **Backups that live outside the failure domain**, and a recovery side that can read but not write them.
- **Application-consistent backups** (a pre-hook flushes SQLite's write-ahead log before the volume is copied).
- **Availability engineering:** replicas, topology spread, probes, `preStop` delay, PodDisruptionBudget.
- **Honest limits of local storage:** the stateful pod is pinned to its node's volume, which is why backups matter.
- **Hardened workloads:** non-root, read-only root filesystem, dropped capabilities, seccomp, pinned image tags, all checked by tests.

## Tests

`pytest` checks the app (including restart durability and the WAL checkpoint hook), manifest policy (probes, limits, PDB, pinned images, backup annotations) and the scripts (syntax, executability, pinned tool images).

## Limits

- The cluster drills have not been run end to end yet: the tests cover the app, manifests and scripts statically. Your first run is the real proof; pinned image tags can be overridden if one has moved (see STEPS.md).
- One host: MinIO is off-cluster, not off-host.
- Single-replica database on node-local storage; see the DR plan's known gaps.
