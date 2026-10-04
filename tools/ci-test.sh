#!/bin/sh
# Everything CI runs (.github/workflows/ci.yml), also runnable locally with
# Docker: the mirror check and the unit suite on Linux FPC 3.2.2, x86_64 and
# i386. Delphi Community Edition can't build headless, so the Delphi side is
# validated in the IDE (see CLAUDE.md, "Tests").
#
# The i386 pass is the only place the 32-bit FPC path of PascalCommon.Threading
# (64-bit atomics behind a lock; docs/gotchas.md, gotcha 1) is compiled and run.
#
# FPC images: built here from Debian bookworm's fpc package (3.2.2) and tagged
# pascalcommon-fpc322 / pascalcommon-fpc322-i386, unless FPC_IMAGE (x86_64)
# or FPC_IMAGE_I386 names an existing one.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ -z "${FPC_IMAGE:-}" ]; then
  FPC_IMAGE=pascalcommon-fpc322
  docker build -q -t "$FPC_IMAGE" - <<'EOF' >/dev/null
FROM debian:bookworm
RUN apt-get update && apt-get install -y --no-install-recommends fpc && rm -rf /var/lib/apt/lists/*
EOF
fi
if [ -z "${FPC_IMAGE_I386:-}" ]; then
  FPC_IMAGE_I386=pascalcommon-fpc322-i386
  docker build -q -t "$FPC_IMAGE_I386" - <<'EOF' >/dev/null
FROM i386/debian:bookworm
RUN apt-get update && apt-get install -y --no-install-recommends fpc && rm -rf /var/lib/apt/lists/*
EOF
fi

echo "== unit suite (x86_64)"
FPC_IMAGE="$FPC_IMAGE" sh tools/test_fpc_docker.sh

echo "== unit suite (i386)"
FPC_IMAGE="$FPC_IMAGE_I386" sh tools/test_fpc_docker.sh
