#!/usr/bin/env bash
#
# Why no trip carries a route, and why the sample series is thirty seconds long.
#
# Measured on the car on 2026-08-20, after the app was fixed and restarted:
#
#   * `sample` is written. Sixteen signals land about once a second — SOC,
#     odometer, speed, pack voltage, the two temperatures and the rest;
#   * **not one of them is a position.** LATITUDE, LONGITUDE, ALTITUDE and
#     GPS_ACCURACY have never produced a row, and `session.startLatitude` is
#     null on all 25 sessions. Both come from the signal store, so the location
#     does not reach it. `trip_segments` does carry coordinates on all 172 rows,
#     and it is fed by the Roadcast path — so the receiver works and the fix is
#     good. What is missing is the bridge from the location provider into the
#     store;
#   * the sample table holds about **thirty seconds**, while `telemetry_events`
#     and `interval` go back to 2025-05. A short horizon for the series is the
#     plan (rule 2.7, two horizons on separate clocks). Thirty seconds is not a
#     horizon. Something deletes as fast as the collector writes.
#
# An earlier reading of the same car said the table had never held a row. That
# was a torn copy: the .db, the -wal and the -shm were pulled one after another
# from a live app. This script copies all three together and prints the window,
# so the same mistake is not available twice.
#
# What one run of this gives:
#
#   * whether a recorded drive produces position samples;
#   * whether the sample window grows with the drive or stays a few seconds;
#   * the retention settings the car is actually running with;
#   * the log across the drive, for anything that refuses or drops a write.
#
# Usage:
#
#   scripts/collect_sample_evidence.sh                 # car over Wi-Fi, default
#   CAR=10.10.10.116:5555 scripts/collect_sample_evidence.sh
#
# Drive for a few minutes when it asks, then press Enter. Nothing is installed
# and nothing on the car is changed: it reads files and the log.

set -euo pipefail

CAR="${CAR:-10.10.10.116:5555}"
PACKAGE="com.timhss.capy"
DB_DIR="/data/data/$PACKAGE/databases"
DB_NAME="geely_telemetry.db"
STAMP="$(date +%Y-%m-%d_%H%M%S)"
OUT="dbpull/sample_probe_$STAMP"

say() { printf '\n=== %s\n' "$1"; }

adb connect "$CAR" >/dev/null 2>&1 || true
if ! adb -s "$CAR" get-state >/dev/null 2>&1; then
  echo "The car did not answer at $CAR." >&2
  echo "Check that the head unit is on and on the same network." >&2
  exit 1
fi

mkdir -p "$OUT/before" "$OUT/after"
echo "Writing to $OUT"

# The whole database, and that means three files.
#
# `telemetry_report pull` copies the .db alone, and on a live app almost
# everything is still in the write-ahead log — the 2026-08-20 snapshot opened
# with 38 tables and no rows for that reason. A copy without the -wal is a
# database that reads as empty, which is the worst possible way to be wrong.
snapshot() {
  local into="$1"
  for suffix in "" "-wal" "-shm"; do
    adb -s "$CAR" exec-out "cat $DB_DIR/$DB_NAME$suffix" > "$into/$DB_NAME$suffix" 2>/dev/null || true
  done
}

counts() {
  python3 - "$1" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
c = db.cursor()
out = {}
for table in ('session', 'interval', 'sample', 'telemetry_events', 'trip_segments'):
    try:
        out[table] = c.execute("select count(*) from '%s'" % table).fetchone()[0]
    except sqlite3.Error:
        out[table] = -1
seq = dict(c.execute("select name, seq from sqlite_sequence"))
out['sample_ever_inserted'] = 1 if 'sample' in seq else 0
print(' '.join('%s=%s' % kv for kv in out.items()))
# How wide the stored series actually is. On 2026-08-20 the sample table held
# thirty seconds while events and intervals went back fifteen months, which is
# not a retention horizon — it is something deleting as fast as it writes.
row = c.execute("select min(tUtcMillis), max(tUtcMillis) from sample").fetchone()
if row and row[0]:
    print('sample window seconds=%d' % ((row[1] - row[0]) / 1000))
print('position samples=%d' % c.execute(
    "select count(*) from sample where key in "
    "('LATITUDE','LONGITUDE','ALTITUDE','GPS_ACCURACY')").fetchone()[0])
print('sessions with startLatitude=%d of %d' % (
    c.execute('select count(*) from session where startLatitude is not null').fetchone()[0],
    c.execute('select count(*) from session').fetchone()[0]))
PY
}

say "Settings the car is running with"
adb -s "$CAR" shell "cat /data/data/$PACKAGE/shared_prefs/telemetry_settings.xml" \
  | tee "$OUT/telemetry_settings.xml" | grep -iE "retention|gps|days" || true

say "Snapshot before"
snapshot "$OUT/before"
BEFORE="$(counts "$OUT/before/$DB_NAME")"
echo "$BEFORE"

say "Clearing the log and starting the capture"
adb -s "$CAR" logcat -c || true
adb -s "$CAR" logcat -v time > "$OUT/logcat.txt" 2>/dev/null &
LOGCAT_PID=$!
# Stop the capture whatever happens next, including a Ctrl-C.
trap 'kill "$LOGCAT_PID" 2>/dev/null || true' EXIT

cat <<'PROMPT'

Now drive. Three to five minutes is enough — it only has to be a trip the car
records, so the vehicle has to actually move.

Keep this terminal open. Press Enter when you are parked again.
PROMPT
read -r _

say "Snapshot after"
snapshot "$OUT/after"
AFTER="$(counts "$OUT/after/$DB_NAME")"
echo "$AFTER"

kill "$LOGCAT_PID" 2>/dev/null || true
wait "$LOGCAT_PID" 2>/dev/null || true

say "What the log said about persistence"
grep -iE "FrameRepository|telemetry sample|persistence queue|insert_sample|SQLite|Room" "$OUT/logcat.txt" \
  | tail -40 | tee "$OUT/persistence_lines.txt" || echo "(nothing matched)"

say "Crashes and refusals"
grep -iE "FATAL|AndroidRuntime|IllegalState|IllegalArgument" "$OUT/logcat.txt" | tail -20 || echo "(none)"

say "Reading"
python3 - "$OUT/before/$DB_NAME" "$OUT/after/$DB_NAME" <<'PY'
import sqlite3, sys

def counts(path):
    db = sqlite3.connect(path)
    c = db.cursor()
    out = {}
    for table in ('session', 'interval', 'sample', 'telemetry_events'):
        try:
            out[table] = c.execute("select count(*) from '%s'" % table).fetchone()[0]
        except sqlite3.Error:
            out[table] = -1
    out['sample_seq'] = dict(c.execute("select name, seq from sqlite_sequence")).get('sample')
    return out

before, after = counts(sys.argv[1]), counts(sys.argv[2])
grew = {k: after[k] - before[k] for k in ('session', 'interval', 'sample', 'telemetry_events')}
print('grew:', ', '.join('%s +%d' % (k, v) for k, v in grew.items()))

if grew['interval'] == 0 and grew['telemetry_events'] == 0:
    print('\nNothing was recorded at all. This drive did not reach the')
    print('collector, so it says nothing about the sample path. Check that the')
    print('trip was detected — a session should have appeared — and run again.')
else:
    print('\nThe car recorded this drive. Read the two lines above:')
    print('  * `position samples` still 0 means the location never reached the')
    print('    signal store during a whole drive, which rules out a fix, a')
    print('    permission and the setting — all three were in place here;')
    print('  * a `sample window seconds` far shorter than the drive means the')
    print('    series is being deleted as fast as it is written. Compare it')
    print('    against the retention settings printed at the top.')
PY

say "Done"
echo "Send $OUT — the two snapshots, the log, and the lines above."
