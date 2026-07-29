#!/bin/bash
# #230: capture loopback traffic on port 9011 while running the repro loop,
# so a captured failure's debug byte-dump (timestamped) can be cross-checked
# against the actual wire bytes via tshark.
set -u
DIR="/mnt/d/IA/Projetos/Delphi/Poseidon/tests/autobahn"
PCAP=/tmp/poseidon-fpc-linux/ws230.pcap
mkdir -p /tmp/poseidon-fpc-linux
sudo -n pkill -9 tcpdump 2>/dev/null
sleep 1
sudo -n tcpdump -i lo -s 0 -w "$PCAP" "tcp port 9011" > /tmp/poseidon-fpc-linux/tcpdump.log 2>&1 &
TCPDUMPPID=$!
sleep 1
echo "tcpdump started (pid $TCPDUMPPID) -> $PCAP"

bash "$DIR/repro230_loop.sh" "${1:-30}"

sudo -n kill -TERM "$TCPDUMPPID" 2>/dev/null
sleep 1
ls -la "$PCAP"
echo "PCAP_DONE"
