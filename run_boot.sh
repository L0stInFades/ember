#!/bin/bash
# Convert fw_payload.bin -> hex, build the Verilator SoC, and boot it.
set -e
cd "$(dirname "$0")"
BIN=linux-build/fw_payload.bin
[ -f "$BIN" ] || { echo "missing $BIN (build not finished?)"; exit 1; }
echo "payload size: $(wc -c < $BIN) bytes"
python3 bin2hex.py "$BIN" linux-build/fw_payload.hex
echo "hex words: $(wc -l < linux-build/fw_payload.hex)"
bash build_vtop.sh linux-build/fw_payload.hex >/dev/null 2>&1 || bash build_vtop.sh linux-build/fw_payload.hex
echo "=== BOOT ==="
exec ./obj_vtop/Vvtop "$@"
