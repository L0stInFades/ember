#!/bin/bash
# Convert an OpenSBI+Linux payload .bin -> hex, build the Verilator SoC, and boot it.
set -e
cd "$(dirname "$0")/.."                      # repo root
BIN=${1:-linux/fw_payload_sf.bin}
[ -f "$BIN" ] || { echo "missing $BIN (build the Linux payload first; see linux/README path)"; exit 1; }
HEX="${BIN%.bin}.hex"
echo "payload size: $(wc -c < "$BIN") bytes"
python3 tools/bin2hex.py "$BIN" "$HEX"
echo "hex words: $(wc -l < "$HEX")"
bash scripts/build_vtop.sh "$HEX" >/dev/null 2>&1 || bash scripts/build_vtop.sh "$HEX"
echo "=== BOOT ==="
shift || true
exec ./obj_vtop/Vvtop "$@"
