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

# docker build quietly, but print the whole build log if it fails: a bare
# "exit code: 100" from apt says nothing about the cause.
build_image() {
  log="$(mktemp)"
  if ! docker build --progress=plain -t "$1" - >"$log" 2>&1; then
    cat "$log"
    rm -f "$log"
    exit 1
  fi
  rm -f "$log"
}

if [ -z "${FPC_IMAGE:-}" ]; then
  FPC_IMAGE=pascalcommon-fpc322
  build_image "$FPC_IMAGE" <<'EOF'
FROM debian:bookworm
RUN apt-get update && apt-get install -y --no-install-recommends fpc && rm -rf /var/lib/apt/lists/*
EOF
fi
# i386 containers run with seccomp=unconfined. On the ubuntu-26.04 runners
# (Docker 29.4, kernel 7.0) the default seccomp profile makes socket calls
# from 32-bit code fail with ENOSYS: the glibc resolver can't look up any
# name, so apt stops with "Unable to locate package fpc", and the FPC tests'
# listen fails with "error 38: Function not implemented". --dns or
# --network=host don't help. docker build has no seccomp option, so the image
# is made with docker run + commit. Measured 2026-11-10.
I386_DOCKER_OPTS="--security-opt seccomp=unconfined"
if [ -z "${FPC_IMAGE_I386:-}" ]; then
  FPC_IMAGE_I386=pascalcommon-fpc322-i386
  box=pascalcommon-fpc322-i386-build
  log="$(mktemp)"
  docker rm -f "$box" >/dev/null 2>&1 || true
  # shellcheck disable=SC2086
  if ! docker run --name "$box" $I386_DOCKER_OPTS i386/debian:bookworm \
      sh -c 'apt-get update && apt-get install -y --no-install-recommends fpc && rm -rf /var/lib/apt/lists/*' \
      >"$log" 2>&1; then
    cat "$log"
    rm -f "$log"
    docker rm -f "$box" >/dev/null 2>&1 || true
    exit 1
  fi
  rm -f "$log"
  docker commit "$box" "$FPC_IMAGE_I386" >/dev/null
  docker rm "$box" >/dev/null
fi

echo "== unit suite (x86_64)"
FPC_IMAGE="$FPC_IMAGE" sh tools/test_fpc_docker.sh

echo "== unit suite (i386)"
FPC_IMAGE="$FPC_IMAGE_I386" FPC_DOCKER_OPTS="$I386_DOCKER_OPTS" sh tools/test_fpc_docker.sh

echo "== stop signal (SIGTERM, x86_64)"
FPC_IMAGE="$FPC_IMAGE" sh tools/test_stop_signal_docker.sh

echo "== embedded tzdb"
sh tools/check_tzdb.sh
