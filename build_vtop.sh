#!/bin/bash
# Build the Verilator boot harness. Optional arg: MEMFILE path (default linux-build/fw_payload.hex).
# Set SYNTH_SHELL=1 to build rvlinux.v through the multicycle synthesizable shell.
set -euo pipefail
cd "$(dirname "$0")"
if [ -f oss-cad-suite/environment ]; then
  source oss-cad-suite/environment
fi
MEMFILE=${1:-linux-build/fw_payload.hex}
MEMWORDS=${MEMWORDS:-33554432}
MEMFILE_WORDS=${MEMFILE_WORDS:-0}
RAMBASE=${RAMBASE:-2147483648}
EBREAK_HALTS=${EBREAK_HALTS:-1}
MTIME_TICK_CYCLES=${MTIME_TICK_CYCLES:-1}
OBJ_DIR=${OBJ_DIR:-obj_vtop}
MODE=behavioral
SIM_MAIN=sim_main.cpp
if [ ! -f "$SIM_MAIN" ]; then
  SIM_MAIN=sim/sim_main.cpp
fi
[ -f "$SIM_MAIN" ] || { echo "missing Verilator harness: $SIM_MAIN" >&2; exit 1; }

defines=(-DSIM_INIT)
sources=(vtop.v rvlinux.v "$SIM_MAIN")

if [ "${SYNTH_SHELL:-0}" != "0" ]; then
  MODE=synth-shell
  defines+=(-DRVLINUX_SYNTH_SHELL)
  sources=(
    vtop.v
    cache.v
    cache_client_arbiter2.v
    mem_arbiter2.v
    slowmem.v
    l1_mem_system.v
    sv32_ptw.v
    rvlinux_mem_boundary.v
    rvlinux_fetch_stage.v
    rvlinux_lsu_stage.v
    rvlinux_amo_stage.v
    rvlinux_stage_cluster.v
    rvlinux_decode_stage.v
    rvlinux_csr_trap_stage.v
    rvlinux_muldiv_stage.v
    rvlinux_mmio_stage.v
    rvlinux_min_core_fsm.v
    rvlinux.v
    "$SIM_MAIN"
  )
fi

verilator --cc --exe --build -j 0 -O3 \
  -CFLAGS "-O2" \
  -Wno-WIDTH -Wno-UNUSED -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE -Wno-CASEOVERLAP \
  -Wno-MULTIDRIVEN -Wno-BLKANDNBLK -Wno-IMPLICIT -Wno-SELRANGE -Wno-WIDTHCONCAT \
  --top-module vtop \
  "${defines[@]}" \
  -GMEMFILE="\"$MEMFILE\"" \
  -GMEMWORDS="$MEMWORDS" \
  -GMEMFILE_WORDS="$MEMFILE_WORDS" \
  -GRAMBASE="$RAMBASE" \
  -GEBREAK_HALTS="$EBREAK_HALTS" \
  -GMTIME_TICK_CYCLES="$MTIME_TICK_CYCLES" \
  -Mdir "$OBJ_DIR" \
  "${sources[@]}"
echo "built $OBJ_DIR/Vvtop  mode=$MODE mem=$MEMFILE memwords=$MEMWORDS memfile_words=$MEMFILE_WORDS rambase=$RAMBASE ebreak_halts=$EBREAK_HALTS mtime_tick_cycles=$MTIME_TICK_CYCLES"
