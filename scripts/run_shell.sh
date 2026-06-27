#!/bin/bash
# Boot Ember's Linux SoC core to the BusyBox login prompt, then drive an
# interactive root shell over the emulated UART (RX fed through a FIFO) and run
# a few commands as proof. Needs a built obj_vtop/Vvtop (see scripts/build_vtop.sh)
# and a Linux payload hex (see linux/). Output transcript: /tmp/ember_shell.out
set -e
cd "$(dirname "$0")/.."                      # repo root
[ -x ./obj_vtop/Vvtop ] || bash scripts/build_vtop.sh "${1:-linux/fw_payload_sf.hex}"

pkill -f Vvtop 2>/dev/null; sleep 1
rm -f /tmp/ember_rx; mkfifo /tmp/ember_rx
sleep 100000 > /tmp/ember_rx &               # hold the FIFO open (never EOF)
HOLD=$!
./obj_vtop/Vvtop --maxcyc=6000000000 < /tmp/ember_rx > /tmp/ember_shell.out 2>/tmp/ember_shell.err &
SIM=$!
echo "SIM=$SIM HOLD=$HOLD   (transcript: /tmp/ember_shell.out)"

send(){ printf '%s' "$1" > /tmp/ember_rx; }
waitfor(){ for i in $(seq 1 "$2"); do grep -q "$1" /tmp/ember_shell.out 2>/dev/null && return 0; sleep 1; done; return 1; }

waitfor "buildroot login:" 1200 && echo "[orch] login prompt reached"
sleep 3;  send $'root\n'
sleep 25; send $'uname -a\n'
sleep 20; send $'cat /proc/cpuinfo\n'
sleep 20; send $'ls -la /\n'
sleep 15; send $'free; echo EMBER_SHELL_OK\n'
sleep 20
echo "[orch] done; see /tmp/ember_shell.out"
kill "$HOLD" "$SIM" 2>/dev/null || true
