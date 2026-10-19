#!/usr/bin/env bash
# Shared helpers. Source this; do not run it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
K3S_IMAGE="${K3S_IMAGE:-rancher/k3s:v1.30.5-k3s1}"
MINIO_IMAGE="${MINIO_IMAGE:-minio/minio:RELEASE.2024-10-02T17-50-41Z}"
MC_IMAGE="${MC_IMAGE:-minio/mc:RELEASE.2024-10-02T08-27-28Z}"
VELERO_AWS_PLUGIN="${VELERO_AWS_PLUGIN:-velero/velero-plugin-for-aws:v1.10.1}"
NET=drlab-net
MINIO=drlab-minio
BUCKET=velero
APP_IMAGE=drlab-app:1
SECRETS="${ROOT}/.secrets"
RESULTS="${ROOT}/.results"

kc() { local c="$1"; shift; kubectl --context "k3d-${c}" "$@"; }
vl() { local c="$1"; shift; velero --kubecontext "k3d-${c}" "$@"; }
port_of() { case "$1" in primary) echo 8081 ;; recovery) echo 8082 ;; *) echo "unknown cluster $1" >&2; return 1 ;; esac; }

# http <cluster> <host-prefix> <path> [curl args...]   e.g. http primary notes /notes
http() {
  local c="$1" host="$2" path="$3"; shift 3
  curl -s -m 3 -H "Host: ${host}.drlab.local" "$@" "http://127.0.0.1:$(port_of "$c")${path}"
}

note_count() { http "$1" notes /notes | python3 -c 'import sys,json; print(json.load(sys.stdin)["count"])' 2>/dev/null || echo -1; }
add_note()   { http "$1" notes /notes -X POST -H 'Content-Type: application/json' -d "{\"text\": \"$2\"}" >/dev/null; }

# wait_until <timeout-seconds> <description> <command...>: polls every 2s; returns 1 on timeout
wait_until() {
  local timeout="$1" what="$2"; shift 2
  local end=$((SECONDS + timeout))
  until "$@" >/dev/null 2>&1; do
    if [ "$SECONDS" -ge "$end" ]; then echo "  timed out after ${timeout}s waiting for: ${what}" >&2; return 1; fi
    sleep 2
  done
}

web_ready_count() {  # ready, non-terminating web pods
  kc "$1" -n drlab get pods -l app=web -o json | python3 -c '
import sys, json
pods = json.load(sys.stdin)["items"]
ok = [p for p in pods if not p["metadata"].get("deletionTimestamp")
      and any(c["type"] == "Ready" and c["status"] == "True" for c in p["status"].get("conditions", []))]
print(len(ok))'
}
web_is_full() { [ "$(web_ready_count "$1")" -ge 3 ]; }
notes_is_up() { [ "$(note_count "$1")" -ge 0 ]; }

# Background availability probe: one line per request, 1 = success, 0 = failure.
PROBE_PID=""
probe_start() {  # <cluster> <file>
  : > "$2"
  (
    while true; do
      if http "$1" web /work -f >/dev/null; then echo 1; else echo 0; fi >> "$2"
      sleep 0.1
    done
  ) &
  PROBE_PID=$!
}
probe_stop() { [ -n "$PROBE_PID" ] && kill "$PROBE_PID" 2>/dev/null || true; wait "$PROBE_PID" 2>/dev/null || true; PROBE_PID=""; }
probe_percent() {  # <file> -> availability percent with one decimal, plus counts in $PROBE_TOTAL/$PROBE_FAILED
  PROBE_TOTAL=$(wc -l < "$1" | tr -d ' ')
  PROBE_FAILED=$(grep -c '^0$' "$1" || true)
  python3 -c "t=$PROBE_TOTAL; f=$PROBE_FAILED; print(f'{100.0*(t-f)/t:.1f}' if t else '0.0')"
}

# Results ledger used by run-all.sh
record() {  # PASS|FAIL <label>
  echo "$1  $2" | tee -a "${RESULTS}"
}
check() {  # <label> <command...>
  local label="$1"; shift
  if "$@"; then record PASS "$label"; else record FAIL "$label"; return 0; fi
}
