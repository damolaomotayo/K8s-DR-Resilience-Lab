# Disaster recovery plan (what the lab models)

## Objectives

| | Target | How it is met in the lab |
|---|---|---|
| **RPO** (data we can afford to lose) | 1 hour | Velero `hourly` schedule on the primary, 7-day retention. The DR drill measures the real number. |
| **RTO** (time to be serving again) | 15 minutes | Recovery cluster is pre-built and waiting; recovery is one `velero restore`. The DR drill measures it. |

## What protects what

| Failure | Protection | Drill |
|---|---|---|
| Pod crashes | Controllers recreate it; replicas, probes; the volume outlives the pod | `drill-pod-kill.sh` |
| Planned node maintenance | PodDisruptionBudget (min 2 of 3 web pods), topology spread | `drill-node-drain.sh` |
| Whole cluster lost | Off-cluster backups (MinIO) + a second cluster that can read them | `drill-dr.sh` |
| Bad data or deleted namespace | Same backups; restore into the same or another cluster | `drill-dr.sh` (restore path) |

## Backup design

- **Where:** MinIO runs in its own container outside both clusters, so deleting a cluster cannot delete its backups (the "off-site" copy in 3-2-1; in production use S3 in another region).
- **Consistency:** a pre-backup hook flushes the SQLite write-ahead log, so the volume copy is application-consistent, not just crash-consistent.
- **Read-only recovery side:** the recovery cluster's backup location is `ReadOnly`, so a mistake there cannot damage the backups.
- **Retention:** 7 days of hourly backups.

## Runbook: the primary cluster is gone

1. Confirm the recovery cluster is healthy: `kubectl --context k3d-recovery get nodes`.
2. List backups (they sync from the bucket within a minute): `velero --kubecontext k3d-recovery backup get`.
3. Restore the newest completed one: `velero --kubecontext k3d-recovery restore create --from-backup <name> --wait`.
4. Verify: `curl -H 'Host: notes.drlab.local' http://127.0.0.1:8082/notes` returns the data; web answers on `/work`.
5. Repoint traffic (DNS or load balancer) to the recovery cluster. Record the time.
6. Rebuild the primary (`scripts/up.sh primary`), then plan the fail-back.

## Known gaps (be honest about these)

- Backups cover the `drlab` namespace only. Cluster-wide objects (CRDs, RBAC, ingress controller config) must come from your infrastructure code.
- MinIO shares the host with the clusters, so this models "off-cluster", not "off-host". A real design uses another region or account.
- The notes database is a single replica on a node-local volume: a node loss means downtime until restore. Real systems add replication.
- Backups hold Secrets unencrypted in the bucket. Encrypt the bucket and the Velero repository password in production.
- Restore is only proven by restoring. Schedule a restore test regularly (the DR drill is that test).
