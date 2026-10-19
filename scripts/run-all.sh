#!/usr/bin/env bash
# Build the lab (if needed) and run all three drills in order. Exit code is non-zero if anything failed.
source "$(dirname "$0")/lib.sh"
rm -f "$RESULTS"
"$ROOT/scripts/up.sh" all
"$ROOT/scripts/drill-pod-kill.sh"
"$ROOT/scripts/drill-node-drain.sh"
"$ROOT/scripts/drill-dr.sh"
echo
echo "================ SUMMARY ================"
cat "$RESULTS"
! grep -q '^FAIL' "$RESULTS"
