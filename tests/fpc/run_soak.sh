#!/bin/bash
# Endurance soak of the FPC/Linux build (#219 item 5). Builds server_soak.pas,
# runs it under sustained wrk load for DURATION_SEC, sampling RSS memory every
# SAMPLE_SEC, then sends a real SIGTERM and confirms clean shutdown.
#
# Usage: DURATION_SEC=7200 SAMPLE_SEC=30 FPCDIR=$HOME/fpc-trunk ./run_soak.sh
set -u
FPCDIR="${FPCDIR:-$HOME/fpc-trunk}"
PPC="$FPCDIR/lib/fpc/3.3.1/ppcx64"
U="$FPCDIR/lib/fpc/3.3.1/units/x86_64-linux"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../../src"
COMPAT="$SRC/compat"
OUT=/tmp/poseidon-fpc-linux
DURATION_SEC="${DURATION_SEC:-7200}"
SAMPLE_SEC="${SAMPLE_SEC:-30}"
PORT=19782
CSV="$OUT/soak_mem.csv"

mkdir -p "$OUT"

if [ ! -x "$PPC" ]; then
  echo "ppcx64 not found at $PPC. Build FPC 3.3.1 trunk or set FPCDIR." >&2
  exit 2
fi

echo "=== building server_soak ==="
"$PPC" -Tlinux \
  -MDELPHIUNICODE -Mfunctionreferences -Manonymousfunctions -Mprefixedattributes \
  -Fu"$U/rtl" -Fu"$U/*" -Fu"$SRC" -Fu"$COMPAT" \
  -FU"$OUT" -FE"$OUT" -vw \
  "$HERE/server_soak.pas" 2>&1 | grep -E 'Error|Fatal|Linking'
[ -x "$OUT/server_soak" ] || { echo "server_soak BUILD FAILED"; exit 1; }

"$OUT/server_soak" > "$OUT/soak_run.log" 2>&1 &
SRVPID=$!

ready=0
for i in $(seq 1 50); do
  grep -q READY "$OUT/soak_run.log" 2>/dev/null && { ready=1; break; }
  sleep 0.2
done
if [ "$ready" != 1 ]; then
  echo "SERVER_NOT_READY"; cat "$OUT/soak_run.log"; kill -9 "$SRVPID" 2>/dev/null; exit 3
fi
echo "server up (pid $SRVPID) porta $PORT"

echo "t_sec,rss_kb" > "$CSV"
START=$(date +%s)
END=$((START + DURATION_SEC))

# Background memory sampler.
(
  while kill -0 "$SRVPID" 2>/dev/null; do
    NOW=$(date +%s)
    [ "$NOW" -gt "$END" ] && break
    RSS=$(awk '/VmRSS/{print $2}' "/proc/$SRVPID/status" 2>/dev/null)
    [ -n "$RSS" ] && echo "$((NOW - START)),$RSS" >> "$CSV"
    sleep "$SAMPLE_SEC"
  done
) &
SAMPLERPID=$!

echo "=== soak: $DURATION_SEC s de carga sustentada (wrk -t4 -c100), amostrando RSS a cada ${SAMPLE_SEC}s ==="
ERRLOG="$OUT/soak_wrk_errors.log"
> "$ERRLOG"
while [ "$(date +%s)" -lt "$END" ]; do
  REMAIN=$(( END - $(date +%s) ))
  [ "$REMAIN" -le 0 ] && break
  CHUNK=$(( REMAIN < 300 ? REMAIN : 300 ))
  wrk -t4 -c100 -d"${CHUNK}s" "http://127.0.0.1:$PORT/ping" 2>&1 | tee -a "$ERRLOG" | grep -E 'Requests/sec|Socket errors|Non-2xx'
done

wait "$SAMPLERPID" 2>/dev/null

kill -TERM "$SRVPID"
wait "$SRVPID"
RC=$?
echo "--- server_soak exit: $RC ---"
tail -5 "$OUT/soak_run.log"
echo "=== memory curve (t_sec,rss_kb) em $CSV ==="
cat "$CSV"
[ "$RC" -eq 0 ] || { echo "SOAK FAILED (non-zero exit)"; exit 1; }
