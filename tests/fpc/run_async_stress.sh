#!/bin/bash
# Concurrent-load stress for #219 item 1 (async worker-pool under FPC).
set -u
mkdir -p /tmp/poseidon-fpc-linux
OUT=/tmp/poseidon-fpc-linux
PORT=19784
"$OUT/server_async_soak" > "$OUT/async_stress.log" 2>&1 &
SRVPID=$!
ready=0
for i in $(seq 1 50); do
  grep -q READY "$OUT/async_stress.log" 2>/dev/null && { ready=1; break; }
  sleep 0.2
done
if [ "$ready" != 1 ]; then
  echo "SERVER_NOT_READY"; cat "$OUT/async_stress.log"; kill -9 "$SRVPID" 2>/dev/null; exit 3
fi
echo "server up (pid $SRVPID)"

wrk -t4 -c100 -d30s "http://127.0.0.1:$PORT/ping" 2>&1 | tee "$OUT/async_stress_wrk.log"

kill -TERM "$SRVPID"
wait "$SRVPID"
RC=$?
echo "--- server_async_soak exit: $RC ---"
tail -10 "$OUT/async_stress.log"
[ "$RC" -eq 0 ] || { echo "STRESS FAILED (non-zero exit)"; exit 1; }
echo "ALL_OK"
