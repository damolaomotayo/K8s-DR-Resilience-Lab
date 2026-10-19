#!/usr/bin/env bash
# Remove everything the lab created (clusters, MinIO, network, secrets). Reports in reports/ are kept.
source "$(dirname "$0")/lib.sh"
k3d cluster delete primary recovery 2>/dev/null || true
docker rm -f "$MINIO" >/dev/null 2>&1 || true
docker volume rm drlab-minio-data >/dev/null 2>&1 || true
docker network rm "$NET" >/dev/null 2>&1 || true
rm -rf "$SECRETS" "$RESULTS"
echo "Lab destroyed."
