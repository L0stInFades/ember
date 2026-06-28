#!/bin/bash
# Boot rvlinux to the login prompt, then drive an interactive root shell over
# the UART RX path (fed through a FIFO) and run a few commands as proof.
ROOT=$(cd "$(dirname "$0")" && pwd)
cd "$ROOT"
pkill -f Vvtop 2>/dev/null; sleep 1
rm -f /tmp/rxin; mkfifo /tmp/rxin
sleep 100000 > /tmp/rxin &        # hold the FIFO open (never EOF)
HOLD=$!
./obj_vtop/Vvtop --maxcyc=6000000000 < /tmp/rxin > /tmp/sh8.out 2>/tmp/sh8.err &
SIM=$!
echo "SIM=$SIM HOLD=$HOLD"

send(){ printf '%s' "$1" > /tmp/rxin; }
waitfor(){ for i in $(seq 1 "$2"); do grep -qE "$1" /tmp/sh8.out && return 0; sleep 1; done; return 1; }

waitfor "buildroot login:" 1000 && echo "[orch] got login prompt @ $(date +%T)"
sleep 3; send $'root\n'
sleep 25
send $'uname -a\n'; sleep 20
send $'cat /proc/cpuinfo\n'; sleep 20
send $'ls -la /\n'; sleep 15
send $'free; echo RVCORE_SHELL_OK\n'; sleep 20
echo "[orch] done @ $(date +%T)"
