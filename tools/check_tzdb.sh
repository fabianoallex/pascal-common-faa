#!/bin/sh
# Says whether IANA has a tzdb release newer than the one embedded in
# src/PascalCommon.TimeZones.Data.pas (docs/timezones-design.md, "Update
# policy"). Always exits 0: a new IANA release is a reason to run
# tools/gen_tzdata.py and cut a patch release, not to fail a build (CI calls
# this from tools/ci-test.sh as a warning).
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EMBEDDED=$(grep "PC_TZDB_VERSION = " "$ROOT/src/PascalCommon.TimeZones.Data.pas" | head -1 | cut -d"'" -f2)
LATEST=$(curl -fsS --max-time 20 https://data.iana.org/time-zones/tzdb/version 2>/dev/null | tr -d '\r\n ')
if [ -z "$LATEST" ]; then
  echo "check_tzdb: could not reach data.iana.org (embedded: $EMBEDDED)"
elif [ "$EMBEDDED" = "$LATEST" ]; then
  echo "tzdb: the embedded $EMBEDDED is IANA's latest"
else
  echo "WARNING: the embedded tzdb is $EMBEDDED, IANA has $LATEST: python tools/gen_tzdata.py --release $LATEST"
fi
exit 0
