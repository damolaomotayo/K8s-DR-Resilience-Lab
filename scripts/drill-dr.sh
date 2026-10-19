#!/usr/bin/env bash
# Drill 3: lose the whole primary cluster, restore into the recovery cluster from the off-cluster backup.
# Measures RPO (what was lost) and RTO (how long recovery took) and writes a report to reports/.
source "$(dirname "$0")/lib.sh"
P=primary; R=recovery
echo "== Drill 3: disaster recovery ($P -> $R)"
mkdir -p "$ROOT/reports"
STAMP=$(date -u +%Y%m%d-%H%M%S)
BACKUP="drlab-dr-${STAMP}"

wait_until 120 "primary notes up" notes_is_up "$P"
echo "writing 5 notes that SHOULD survive"
for i in 1 2 3 4 5; do add_note "$P" "before-backup-$i"; done
SAFE=$(note_count "$P")

echo "backup $BACKUP (pre-hook flushes SQLite, then file-system backup of the volume)"
vl "$P" backup create "$BACKUP" --include-namespaces drlab --wait >/dev/null
BACKUP_PHASE=$(kc "$P" -n velero get backup "$BACKUP" -o jsonpath='{.status.phase}')
BACKUP_DONE=$(date +%s)
echo "backup phase: $BACKUP_PHASE"

echo "writing 3 notes AFTER the backup (these will be lost: that is the RPO)"
for i in 1 2 3; do add_note "$P" "after-backup-$i"; done
TOTAL_BEFORE=$(note_count "$P")
sleep 2

echo "DISASTER: deleting the primary cluster"
T0=$(date +%s)
k3d cluster delete "$P" >/dev/null 2>&1
AGE=$(( $(date +%s) - BACKUP_DONE ))

echo "recovering in $R"
RESTORE_OK=1
wait_until 240 "backup visible in recovery cluster" kc "$R" -n velero get backup "$BACKUP" || RESTORE_OK=0
RESTORE="restore-${STAMP}"
if [ "$RESTORE_OK" = 1 ]; then
  vl "$R" restore create "$RESTORE" --from-backup "$BACKUP" --wait >/dev/null || RESTORE_OK=0
  [ "$(kc "$R" -n velero get restore "$RESTORE" -o jsonpath='{.status.phase}')" = Completed ] || RESTORE_OK=0
fi
APP_OK=1; wait_until 240 "restored notes API answering" notes_is_up "$R" || APP_OK=0
T1=$(date +%s)
RTO=$((T1 - T0))

RECOVERED=$(note_count "$R")
TEXTS=$(http "$R" notes /notes | python3 -c 'import sys,json; print(" ".join(n["text"] for n in json.load(sys.stdin)["notes"]))' 2>/dev/null || true)
LOST=$((TOTAL_BEFORE - RECOVERED))
echo "recovered ${RECOVERED} notes; lost ${LOST}; RTO ${RTO}s; data age at disaster ${AGE}s"

check "dr: backup completed cleanly (${BACKUP_PHASE})" [ "$BACKUP_PHASE" = Completed ]
check "dr: restore completed" [ "$RESTORE_OK" = 1 ]
check "dr: app serving in recovery cluster" [ "$APP_OK" = 1 ]
check "dr: all ${SAFE} notes written before the backup survived" [ "$RECOVERED" = "$SAFE" ]
check "dr: post-backup writes are absent (RPO is real: lost ${LOST})" bash -c "! echo '$TEXTS' | grep -q after-backup"
check "dr: web is serving too" bash -c "$(declare -f http port_of); [ \"\$(http $R web /work -o /dev/null -w '%{http_code}')\" = 200 ]"

REPORT="$ROOT/reports/dr-drill-${STAMP}.md"
cat > "$REPORT" <<MD
# DR drill ${STAMP}

| Measure | Result |
|---|---|
| Scenario | primary cluster deleted; restored into a separate recovery cluster from off-cluster backup storage |
| Backup | ${BACKUP} (${BACKUP_PHASE}) |
| **RPO** (data lost) | ${LOST} writes made after the last backup, ${AGE}s of data |
| **RTO** (time to recover) | ${RTO}s from disaster to the restored API answering |
| Notes before disaster | ${TOTAL_BEFORE} |
| Notes recovered | ${RECOVERED} |
| Restore | ${RESTORE} (ok=${RESTORE_OK}) |

What this tells you: with a manual, on-demand backup the RPO equals the time since that backup. The hourly Velero schedule
bounds RPO at about one hour; shorten the schedule if that is too much data to lose.
MD
echo "report written: ${REPORT}"
echo "Primary no longer exists. Rebuild it with: scripts/up.sh primary"
