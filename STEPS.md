# STEPS: Kubernetes Disaster Recovery and Resilience Lab

## Prerequisites (do these first)

| Need | Details |
|---|---|
| Machine | EC2 `t3.large` (2 vCPU, 8 GB) minimum, `t3.xlarge` (16 GB) recommended. **30 GB disk.** Ubuntu 22.04+ (Amazon Linux 2023 also works). |
| AWS permissions | None. The lab runs entirely inside Docker on the instance. No AWS API calls, no IAM role needed. |
| Network | Outbound internet (pulls images and tools from Docker Hub, GitHub, dl.k8s.io). No inbound ports needed; you test with `curl` on the instance. |
| Accounts / tokens | None. |
| Cost | The instance only (about $0.08 to $0.17 per hour). Stop or terminate it when finished. |

## Run it (copy and paste)

```bash
# 1. Clone and install Docker, kubectl 1.30.5, k3d 5.7.4, Velero 1.14.1, jq
git clone <YOUR_REPO_URL> drlab && cd drlab
bash scripts/setup.sh
newgrp docker            # lets your user run docker without sudo (or log out and back in)

# 2. Tests (no cluster needed)
.venv/bin/python -m pytest -q          # expect: all pass

# 3. Build the lab: backup store (MinIO), primary cluster (3 nodes), recovery cluster, Velero, the app. About 6 to 10 minutes.
bash scripts/up.sh

# 4. Look around
curl -s -H 'Host: web.drlab.local'   http://127.0.0.1:8081/work
curl -s -H 'Host: notes.drlab.local' -X POST -H 'Content-Type: application/json' -d '{"text":"hello"}' http://127.0.0.1:8081/notes
curl -s -H 'Host: notes.drlab.local' http://127.0.0.1:8081/notes
kubectl --context k3d-primary -n drlab get pods -o wide

# 5. Run the drills one at a time (each prints PASS/FAIL)
bash scripts/drill-pod-kill.sh         # kill pods, check self-healing and no data loss
bash scripts/drill-node-drain.sh       # planned node maintenance, PodDisruptionBudget keeps web up
bash scripts/drill-dr.sh               # DESTROYS the primary cluster, recovers into the recovery cluster from backup

#    ...or everything in one go, with a summary at the end:
bash scripts/run-all.sh

# 6. Read the measured RPO / RTO report
cat reports/dr-drill-*.md

# 7. Rebuild the primary after the DR drill, or clean up completely
bash scripts/up.sh primary
bash scripts/destroy.sh
```

## If something fails

- `docker: permission denied`: run `newgrp docker` or log out and back in after `setup.sh`.
- Image pull fails (tag not found): the pinned tags are overridable. Example: `K3S_IMAGE=rancher/k3s:<tag> bash scripts/up.sh`. Same for `MINIO_IMAGE`, `MC_IMAGE`, `VELERO_AWS_PLUGIN`.
- `up.sh` stops at "backup location Available": MinIO is not reachable. Check `docker ps` shows `drlab-minio`, then run `bash scripts/up.sh` again (it is safe to repeat).
- Out of memory or disk: use a `t3.xlarge`; `docker system prune -af` frees space after `destroy.sh`.
- Drill says a timeout: re-run it. Cold image pulls make the first run slower.
