#!/bin/sh
# Sends a real SIGTERM to a program built on PascalCommon.StopSignal, on Linux
# FPC 3.2.2 in a Docker container (tests/Signals/PascalCommonStopSignalProbe.lpr,
# shaped like a server: a watcher thread, PcBlockStopSignals on the thread
# that blocks). Acceptance: the watcher sees the stop, the blocked main
# thread is not interrupted, exit code 0, and 0 unfreed blocks (heaptrc).
# Then the same without the block, reported but not asserted: which thread
# receives an unblocked signal is the kernel's choice.
#
# The unit tests can't do this: on Windows a console event reaches every
# process on the console, and the stop flag can't be lowered once raised.
#
# FPC_IMAGE: any image with FPC 3.2.2 on the PATH (default: fpc322-bookworm;
# tools/ci-test.sh builds one).
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${FPC_IMAGE:-fpc322-bookworm}"
MOUNT="$ROOT"
command -v cygpath >/dev/null 2>&1 && MOUNT="$(cygpath -w "$ROOT")"

MSYS_NO_PATHCONV=1 docker run --rm -v "$MOUNT:/src:ro" "$IMAGE" sh -c '
  set -e
  mkdir -p /t/u && cp -r /src/src /src/tests /t/
  cd /t/tests/Signals
  fpc -v0 -Mdelphi -Fu/t/src -Fi/t/src -FU/t/u -gh -gl -o/t/probe PascalCommonStopSignalProbe.lpr > /t/build.log 2>&1 \
    || { grep -iE "error|fatal" /t/build.log | head -30; exit 1; }
  run() {
    MODE="$1"; OUT="/t/out$MODE.txt"; HEAP="/t/heap$MODE.txt"
    HEAPTRC="log=$HEAP" timeout 30 /t/probe $MODE > "$OUT" 2>&1 &
    I=0
    until grep -q "^ready " "$OUT"; do
      I=$((I + 1)); [ $I -le 100 ] || { echo "probe $MODE never got ready"; cat "$OUT"; return 1; }
      sleep 0.1
    done
    kill -TERM "$(sed -n "s/^ready //p" "$OUT")"
    RC=0; wait $! || RC=$?
    echo "-- probe ${MODE:-(block)}: exit $RC"
    grep -v "^ready " "$OUT"
    grep "unfreed" "$HEAP"
    LAST_RC=$RC
  }
  run ""
  [ "$LAST_RC" -eq 0 ] && grep -q "^watcher saw the stop: yes" /t/out.txt \
    && grep -q "^main interrupted: no" /t/out.txt && grep -qE "^0 unfreed memory blocks" /t/heap.txt \
    || { echo "FAILED: SIGTERM with the block"; exit 1; }
  run --no-block
  grep -q "^watcher saw the stop: yes" /t/out--no-block.txt && grep -qE "^0 unfreed memory blocks" /t/heap--no-block.txt \
    || { echo "FAILED: SIGTERM without the block"; exit 1; }
  echo "stop signal: OK"'
