#!/usr/bin/env bash
# Build the lab. Usage: scripts/up.sh [all|primary|recovery]   (default all; 'primary' rebuilds it after a DR drill)
source "$(dirname "$0")/lib.sh"
WHAT="${1:-all}"
cd "$ROOT"

mkdir -p "$SECRETS"
if [ ! -f "$SECRETS/minio.env" ]; then
  printf 'MINIO_USER=drlab\nMINIO_PASS=%s\n' "$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)" > "$SECRETS/minio.env"
fi
source "$SECRETS/minio.env"
cat > "$SECRETS/velero-credentials" <<CRED
[default]
aws_access_key_id=${MINIO_USER}
aws_secret_access_key=${MINIO_PASS}
CRED

echo "== network + backup target (MinIO, outside both clusters)"
docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null
if ! docker ps -a --format '{{.Names}}' | grep -qx "$MINIO"; then
  docker run -d --name "$MINIO" --network "$NET" --restart unless-stopped \
    -e MINIO_ROOT_USER="$MINIO_USER" -e MINIO_ROOT_PASSWORD="$MINIO_PASS" -v drlab-minio-data:/data \
    "$MINIO_IMAGE" server /data >/dev/null
fi
docker start "$MINIO" >/dev/null 2>&1 || true
mc() { docker run --rm --network "$NET" --entrypoint sh "$MC_IMAGE" -c "mc alias set m http://${MINIO}:9000 '${MINIO_USER}' '${MINIO_PASS}' >/dev/null && $*"; }
wait_until 60 "MinIO" mc "mc ls m"
mc "mc mb --ignore-existing m/${BUCKET}" >/dev/null
echo "backup bucket '${BUCKET}' ready"

echo "== app image"
docker build -q -t "$APP_IMAGE" "$ROOT/app" >/dev/null

create_cluster() {
  local name="$1" agents="$2" port="$3"
  if k3d cluster list -o json | python3 -c "import sys,json; sys.exit(0 if any(c['name']=='$name' for c in json.load(sys.stdin)) else 1)"; then
    echo "cluster $name already exists"; return
  fi
  echo "== cluster $name"
  k3d cluster create "$name" --image "$K3S_IMAGE" --network "$NET" --servers 1 --agents "$agents" \
    -p "${port}:80@loadbalancer" --wait --timeout 180s
  k3d image import "$APP_IMAGE" -c "$name" >/dev/null
  echo "installing Velero in $name"
  velero install --kubecontext "k3d-${name}" --provider aws --plugins "$VELERO_AWS_PLUGIN" --bucket "$BUCKET" \
    --secret-file "$SECRETS/velero-credentials" --use-volume-snapshots=false --use-node-agent \
    --backup-location-config "region=minio,s3ForcePathStyle=true,s3Url=http://${MINIO}:9000" --wait >/dev/null
  wait_until 120 "backup location Available" bash -c "[ \"\$(kubectl --context k3d-${name} -n velero get backupstoragelocation default -o jsonpath='{.status.phase}')\" = Available ]"
}

if [ "$WHAT" = all ] || [ "$WHAT" = primary ]; then
  create_cluster primary 2 8081
  echo "== deploy app to primary"
  "$ROOT/scripts/deploy-app.sh" primary
  kc primary -n velero get schedule hourly >/dev/null 2>&1 || \
    vl primary schedule create hourly --schedule "0 * * * *" --include-namespaces drlab --ttl 168h >/dev/null
fi
if [ "$WHAT" = all ] || [ "$WHAT" = recovery ]; then
  create_cluster recovery 0 8082
  # The recovery cluster may read backups but never write or delete them.
  kc recovery -n velero patch backupstoragelocation default --type merge -p '{"spec":{"accessMode":"ReadOnly"}}' >/dev/null
fi
echo
echo "Lab is up. primary: http://127.0.0.1:8081   recovery: http://127.0.0.1:8082   (send a Host header, see README)"
