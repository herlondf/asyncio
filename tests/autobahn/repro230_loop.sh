#!/bin/bash
# Repeated repro loop for #230 residual failures (~2.7% rate), now against a
# server binary instrumented with [ws-debug-230] Writeln in TryDecompress
# (src/Poseidon.Net.WebSocket.pas, temporary, to be reverted after capture).
# Stops early as soon as a round contains a FAILED case, preserving that
# round's server.log (which has the debug output) and reports/ directory.
set -u
DIR="/mnt/d/IA/Projetos/Delphi/Poseidon/tests/autobahn"
ROUNDS="${1:-15}"
CAPTURED=0
for i in $(seq 1 "$ROUNDS"); do
  echo "=== round $i/$ROUNDS ==="
  bash "$DIR/run-autobahn.sh" 9011 fuzzingclient-230repro.json > /tmp/repro230_round.log 2>&1
  FAILS=$(python3 -c "
import json
d = json.load(open('/opt/autobahn/reports/clients/index.json'))
agent = list(d.keys())[0]
cases = d[agent]
failed = [c for c,v in cases.items() if v.get('behavior')=='FAILED' or v.get('behaviorClose')=='FAILED']
print(','.join(failed))
" 2>/dev/null)
  if [ -n "$FAILS" ]; then
    echo "ROUND $i FAILED cases: $FAILS"
    cp -r /opt/autobahn/reports/clients "/tmp/repro230_capture_round${i}"
    cp /opt/autobahn/server.log "/tmp/repro230_capture_round${i}_server.log"
    CAPTURED=1
    break
  else
    echo "round $i: no failures"
  fi
done
echo "=== done, captured=$CAPTURED ==="
