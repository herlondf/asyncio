#!/bin/bash
# Build + run the full Poseidon server closure under Free Pascal / Linux (#5).
#
# Three gates (server_smoke/server_run mirror build-server-fpc.ps1 on Windows;
# server_signal_run is Linux-only, added for #219 item 4):
#   server_smoke      — `uses Poseidon` forces the whole server graph (facade,
#     HttpServer, epoll/io_uring backends, Connection, SSL, HTTP2, WebSocket,
#     pools) to build+link, and proves init/finalization runs clean.
#   server_run        — boots a real TPoseidonServer in a thread and issues
#     real HTTP GETs, proving the native server actually SERVES on Linux.
#   server_signal_run — boots the server, then a REAL external `kill -TERM`
#     (sent by this script, not a self-signal) must reach
#     InstallSignalHandler/CheckShutdownSignal (Poseidon.GracefulReload) and
#     trigger App.Stop — proves the poll-based signal flag actually works at
#     runtime under FPC, not just compiles.
#
# Requires FPC 3.3.1 (trunk) — `reference to` / attribute RTTI need it. Build it
# from source (bootstrap with the 3.2.2 apt package). Override the install dir
# with:  FPCDIR=/path/to/fpc-trunk  ./build-linux-fpc.sh
set -u
FPCDIR="${FPCDIR:-$HOME/fpc-trunk}"
PPC="$FPCDIR/lib/fpc/3.3.1/ppcx64"
U="$FPCDIR/lib/fpc/3.3.1/units/x86_64-linux"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../../src"
COMPAT="$SRC/compat"
OUT=/tmp/poseidon-fpc-linux
mkdir -p "$OUT"

if [ ! -x "$PPC" ]; then
  echo "ppcx64 not found at $PPC. Build FPC 3.3.1 trunk or set FPCDIR." >&2
  exit 2
fi

build_run() {
  local prog="$1"
  echo "=== $prog ==="
  "$PPC" -Tlinux \
    -MDELPHIUNICODE -Mfunctionreferences -Manonymousfunctions -Mprefixedattributes \
    -Fu"$U/rtl" -Fu"$U/*" -Fu"$SRC" -Fu"$COMPAT" \
    -FU"$OUT" -FE"$OUT" -vw \
    "$HERE/$prog.pas" 2>&1 | grep -E 'Error|Fatal|Linking' | tail -8
  "$OUT/$prog"
  local rc=$?
  echo "--- $prog exit: $rc ---"
  [ "$rc" -eq 0 ] || { echo "$prog FAILED"; exit 1; }
}

build_only() {
  local prog="$1"
  "$PPC" -Tlinux \
    -MDELPHIUNICODE -Mfunctionreferences -Manonymousfunctions -Mprefixedattributes \
    -Fu"$U/rtl" -Fu"$U/*" -Fu"$SRC" -Fu"$COMPAT" \
    -FU"$OUT" -FE"$OUT" -vw \
    "$HERE/$prog.pas" 2>&1 | grep -E 'Error|Fatal|Linking' | tail -8
  [ -x "$OUT/$prog" ] || { echo "$prog BUILD FAILED"; exit 1; }
}

run_signal_gate() {
  echo "=== server_signal_run ==="
  build_only server_signal_run
  "$OUT/server_signal_run" > "$OUT/signal_run.log" 2>&1 &
  local pid=$!
  local ready=0
  for i in $(seq 1 40); do
    grep -q READY "$OUT/signal_run.log" 2>/dev/null && { ready=1; break; }
    sleep 0.25
  done
  if [ "$ready" != 1 ]; then
    echo "SERVER_NOT_READY"; cat "$OUT/signal_run.log"; kill -9 "$pid" 2>/dev/null; exit 3
  fi
  kill -TERM "$pid"
  wait "$pid"
  local rc=$?
  cat "$OUT/signal_run.log"
  echo "--- server_signal_run exit: $rc ---"
  [ "$rc" -eq 0 ] || { echo "server_signal_run FAILED"; exit 1; }
}

echo "FPC: $("$PPC" -iV)  (target x86_64-linux)"
build_run server_smoke
build_run server_run
build_run server_async_run
run_signal_gate
echo "FPC LINUX SERVER GATE: PASSED (compile+link+init, runtime serve, async worker-pool dispatch, AND real SIGTERM delivery)"
