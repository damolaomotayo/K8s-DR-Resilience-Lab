#!/usr/bin/env bash
# Drill 2: drain a node (planned maintenance). Hypothesis: the PodDisruptionBudget keeps >= 2 web pods ready the whole time.
source "$(dirname "$0")/lib.sh"
C=primary
echo "== Drill 2: node drain on $C"

wait_until 120 "web at 3 ready" web_is_full "$C"
NOTES_NODE=$(kc "$C" -n drlab get pod notes-0 -o jsonpath='{.spec.nodeName}')
# Drain a node that hosts web pods but not the notes pod (local-path volumes are pinned to their node).
NODE=$(kc "$C" -n drlab get pods -l app=web -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | grep -vx "$NOTES_NODE" | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
[ -n "$NODE" ] || { echo "no suitable node found"; record FAIL "node-drain: could not choose a node"; exit 0; }
echo "draining $NODE (notes-0 lives on $NOTES_NODE and is left alone)"

PROBE_FILE="$(mktemp)"; MIN_FILE="$(mktemp)"
probe_start "$C" "$PROBE_FILE"
( while true; do kc "$C" -n drlab get deploy web -o jsonpath='{.status.readyReplicas}' 2>/dev/null | sed 's/^$/0/' >> "$MIN_FILE"; echo >> "$MIN_FILE"; sleep 1; done ) &
SAMPLER=$!
trap 'probe_stop; kill $SAMPLER 2>/dev/null || true; kc "$C" uncordon "$NODE" >/dev/null 2>&1 || true' EXIT
sleep 3

START=$SECONDS
DRAIN_OK=1
kc "$C" drain "$NODE" --ignore-daemonsets --delete-emptydir-data --timeout=150s >/dev/null 2>&1 || DRAIN_OK=0
wait_until 90 "web back to 3 ready" web_is_full "$C" || true
SECS=$((SECONDS - START))

probe_stop; kill "$SAMPLER" 2>/dev/null || true
PCT=$(probe_percent "$PROBE_FILE")
MIN_READY=$(grep -E '^[0-9]+$' "$MIN_FILE" | sort -n | head -1)
ON_NODE=$(kc "$C" -n drlab get pods -l app=web --field-selector "spec.nodeName=${NODE}" --no-headers 2>/dev/null | wc -l | tr -d ' ')
kc "$C" uncordon "$NODE" >/dev/null 2>&1 || true

echo "drain took ${SECS}s; lowest ready web pods seen: ${MIN_READY:-?}; web availability ${PCT}% (${PROBE_FAILED} failed of ${PROBE_TOTAL})"
check "node-drain: drain completed" [ "$DRAIN_OK" = 1 ]
check "node-drain: never fewer than 2 web pods ready (min ${MIN_READY:-?})" [ "${MIN_READY:-0}" -ge 2 ]
check "node-drain: web availability >= 97% (was ${PCT}%)" python3 -c "import sys; sys.exit(0 if float('${PCT}') >= 97.0 else 1)"
check "node-drain: no web pods left on drained node" [ "$ON_NODE" = 0 ]
check "node-drain: web back to 3/3" web_is_full "$C"
