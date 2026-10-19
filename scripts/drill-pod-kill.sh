#!/usr/bin/env bash
# Drill 1: kill pods. Hypothesis: web stays available (3 replicas); notes comes back with all its data (PVC).
source "$(dirname "$0")/lib.sh"
C=primary
echo "== Drill 1: pod kill on $C"

wait_until 120 "web at 3 ready" web_is_full "$C"
wait_until 60 "notes up" notes_is_up "$C"
BEFORE=$(note_count "$C"); [ "$BEFORE" -ge 0 ] || BEFORE=0
add_note "$C" "pod-kill-drill"; BEFORE=$((BEFORE + 1))
echo "steady state: web 3/3 ready, notes has ${BEFORE} rows"

PROBE_FILE="$(mktemp)"
probe_start "$C" "$PROBE_FILE"
trap probe_stop EXIT
sleep 3

VICTIM=$(kc "$C" -n drlab get pods -l app=web -o jsonpath='{.items[0].metadata.name}')
echo "injecting: delete $VICTIM"
START=$SECONDS
kc "$C" -n drlab delete pod "$VICTIM" --wait=false >/dev/null
sleep 2
WEB_OK=1; wait_until 90 "web back to 3 ready" web_is_full "$C" || WEB_OK=0
WEB_SECS=$((SECONDS - START))

echo "injecting: delete notes-0 (stateful)"
START=$SECONDS
kc "$C" -n drlab delete pod notes-0 --wait=false >/dev/null
sleep 2
NOTES_OK=1; wait_until 120 "notes back" notes_is_up "$C" || NOTES_OK=0
NOTES_SECS=$((SECONDS - START))
AFTER=$(note_count "$C")

probe_stop
PCT=$(probe_percent "$PROBE_FILE")
echo "web availability during drill: ${PCT}% (${PROBE_FAILED} failed of ${PROBE_TOTAL} requests)"
echo "web recovery: ${WEB_SECS}s   notes recovery: ${NOTES_SECS}s   notes rows ${BEFORE} -> ${AFTER}"

check "pod-kill: web returned to 3/3 ready within 90s" [ "$WEB_OK" = 1 ]
check "pod-kill: web availability >= 97% (was ${PCT}%)" python3 -c "import sys; sys.exit(0 if float('${PCT}') >= 97.0 else 1)"
check "pod-kill: notes came back within 120s (${NOTES_SECS}s)" [ "$NOTES_OK" = 1 ]
check "pod-kill: no notes lost (${BEFORE} -> ${AFTER})" [ "$AFTER" = "$BEFORE" ]
