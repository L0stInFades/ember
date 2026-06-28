#!/bin/bash
# Build the Verilator boot harness for the Linux SoC core (rvlinux).
# Optional arg: MEMFILE path (OpenSBI+Linux payload hex). Run from anywhere.
set -e
cd "$(dirname "$0")/.."                      # repo root
if [ -f oss-cad-suite/environment ]; then
  source oss-cad-suite/environment
fi
MEMFILE=${1:-linux/fw_payload_sf.hex}
verilator --cc --exe --build -j 0 -O3 \
  -CFLAGS "-O2" \
  -Wno-WIDTH -Wno-UNUSED -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE -Wno-CASEOVERLAP \
  -Wno-MULTIDRIVEN -Wno-BLKANDNBLK -Wno-IMPLICIT -Wno-SELRANGE -Wno-WIDTHCONCAT \
  --top-module vtop \
  -DSIM_INIT -GMEMFILE="\"$MEMFILE\"" \
  -Mdir obj_vtop \
  sim/vtop.v rtl/cores/rvlinux.v sim/sim_main.cpp
echo "built obj_vtop/Vvtop  (mem=$MEMFILE)"
