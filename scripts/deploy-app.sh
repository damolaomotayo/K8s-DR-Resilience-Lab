#!/usr/bin/env bash
# Usage: scripts/deploy-app.sh <cluster>
source "$(dirname "$0")/lib.sh"
C="${1:?usage: deploy-app.sh <primary|recovery>}"
kc "$C" apply -f "$ROOT/k8s/namespace.yaml" >/dev/null
kc "$C" apply -f "$ROOT/k8s/notes.yaml" -f "$ROOT/k8s/web.yaml" >/dev/null
kc "$C" -n drlab rollout status statefulset/notes --timeout=180s
kc "$C" -n drlab rollout status deployment/web --timeout=180s
wait_until 60 "ingress routing" notes_is_up "$C"
echo "app is serving on $C"
