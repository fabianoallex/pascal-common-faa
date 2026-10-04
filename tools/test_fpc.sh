#!/bin/sh
# Regenerates the FPCUnit mirrors from the DUnitX masters, then builds and
# runs the unit suite on FPC. Acceptance criterion: 0 errors, 0 failures and
# "0 unfreed memory blocks" (heaptrc), and no "FINALIZATION CHECK FAILED" line
# (printed by a test unit's finalization; see PascalCommon.ThreadPoolTests).
#
# The Delphi side has no command-line equivalent: Delphi Community Edition
# doesn't compile outside the IDE (dcc32 prints "This version of the product
# does not support command line compiling." and exits with code 0). Run
# tests\Unit\PascalCommon.UnitTests.dproj from the IDE.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LAZBUILD="${LAZBUILD:-lazbuild}"
command -v "$LAZBUILD" >/dev/null 2>&1 || LAZBUILD=/c/lazarus4.0/lazbuild.exe

cd "$ROOT"
python tools/gen_fpc_mirror.py
cd tests/Unit/fpc
if ! "$LAZBUILD" -B PascalCommonUnitTestsFpc.lpi > build.log 2>&1; then
  grep -E "Error|Fatal" build.log | grep -v "generics\." | head -30
  exit 1
fi
./PascalCommonUnitTestsFpc.exe --all --format=plain > run.log 2>&1 || true
grep -E "^Number of|unfreed|FINALIZATION CHECK FAILED" run.log
grep -qE "^Number of errors: +0$" run.log && grep -qE "^Number of failures: +0$" run.log && grep -qE "^0 unfreed memory blocks" run.log \
  && ! grep -q "FINALIZATION CHECK FAILED" run.log
