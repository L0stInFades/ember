#!/usr/bin/env bash
# Build and run the RVLINUX_SYNTH_SHELL Linux payload matched to the minimal
# no-Ethernet SoC. The pass condition is seeing the Buildroot login prompt.
set -euo pipefail

cd "$(dirname "$0")"

usage() {
  cat >&2 <<'EOF'
usage: ./run_synth_shell_nonet.sh [options]

Options:
  --prepare-payload   Rebuild the no-net soft-float payload in Docker first.
  --no-build          Reuse OBJ_DIR/Vvtop instead of rebuilding Verilator.
  --build-only        Build Vvtop and stop before running the simulation.
  --maxcyc=N          Override MAXCYC for the Verilator run.
  -h, --help          Show this help.

Environment overrides:
  TIMEBASE_HZ         DTB timebase-frequency to patch in (default: 400000000).
  TIMEBASE_TAG        Name tag used in output paths (default: tb400m).
  NONET_BIN           Base no-net OpenSBI payload .bin.
  PAYLOAD_STEM        Timebase-patched payload stem.
  PAYLOAD_HEX         Timebase-patched payload .hex.
  OBJ_DIR             Verilator output directory.
  MAXCYC              Verilator cycle cap (default: 10000000000).
  LOGDIR              Log directory (default: logs).
  LOG_PREFIX          Full log prefix, without .out/.err suffixes.
  EXPECT_UART         UART substring required for pass (default: buildroot login:).
  MEMWORDS            Backing RAM words (default: 33554432).
  MEMFILE_WORDS       Payload words; defaults to line count of PAYLOAD_HEX.
  MTIME_TICK_CYCLES   CLINT tick divider passed to vtop (default: 1).
EOF
}

PREPARE_PAYLOAD=${PREPARE_PAYLOAD:-0}
REBUILD_VTOP=${REBUILD_VTOP:-1}
RUN_SIM=${RUN_SIM:-1}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --prepare-payload)
      PREPARE_PAYLOAD=1
      ;;
    --no-build)
      REBUILD_VTOP=0
      ;;
    --build-only)
      RUN_SIM=0
      ;;
    --maxcyc=*)
      MAXCYC=${1#--maxcyc=}
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage
      exit 2
      ;;
  esac
  shift
done

TIMEBASE_HZ=${TIMEBASE_HZ:-400000000}
TIMEBASE_TAG=${TIMEBASE_TAG:-tb400m}
NONET_BIN=${NONET_BIN:-linux-build/fw_payload_sf_nonet.bin}
PAYLOAD_STEM=${PAYLOAD_STEM:-linux-build/fw_payload_sf_${TIMEBASE_TAG}_nonet}
PAYLOAD_HEX=${PAYLOAD_HEX:-${PAYLOAD_STEM}.hex}
OBJ_DIR=${OBJ_DIR:-obj_vtop_synth_linux_sf_${TIMEBASE_TAG}_nonet}
MAXCYC=${MAXCYC:-10000000000}
LOGDIR=${LOGDIR:-logs}
EXPECT_UART=${EXPECT_UART:-buildroot login:}
MEMWORDS=${MEMWORDS:-33554432}
MTIME_TICK_CYCLES=${MTIME_TICK_CYCLES:-1}
EBREAK_HALTS=${EBREAK_HALTS:-0}

case "$TIMEBASE_HZ" in
  ''|*[!0-9]*)
    echo "TIMEBASE_HZ must be a positive decimal integer" >&2
    exit 2
    ;;
esac
case "$MAXCYC" in
  ''|*[!0-9]*)
    echo "MAXCYC must be a positive decimal integer" >&2
    exit 2
    ;;
esac

if [ "$PREPARE_PAYLOAD" != "0" ]; then
  command -v docker >/dev/null || { echo "missing docker for --prepare-payload" >&2; exit 1; }
  docker run --rm -v "$PWD/linux-build:/out" rvl-sf-img bash /out/repackage_sf_nonet.sh
fi

if [ ! -f "$NONET_BIN" ]; then
  cat >&2 <<EOF
missing $NONET_BIN
Run with --prepare-payload, or first run:
  docker run --rm -v "\$PWD/linux-build:/out" rvl-sf-img bash /out/repackage_sf_nonet.sh
EOF
  exit 1
fi

if [ ! -f "$PAYLOAD_HEX" ] || [ "$NONET_BIN" -nt "$PAYLOAD_HEX" ]; then
  SRC_BIN="$NONET_BIN" linux-build/make_timebase_payload.sh "$TIMEBASE_HZ" "$PAYLOAD_STEM"
fi

[ -f "$PAYLOAD_HEX" ] || { echo "missing $PAYLOAD_HEX" >&2; exit 1; }
MEMFILE_WORDS=${MEMFILE_WORDS:-$(wc -l < "$PAYLOAD_HEX" | tr -d ' ')}

if [ "$REBUILD_VTOP" != "0" ] || [ ! -x "$OBJ_DIR/Vvtop" ]; then
  SYNTH_SHELL=1 \
  EBREAK_HALTS="$EBREAK_HALTS" \
  MEMWORDS="$MEMWORDS" \
  MEMFILE_WORDS="$MEMFILE_WORDS" \
  MTIME_TICK_CYCLES="$MTIME_TICK_CYCLES" \
  OBJ_DIR="$OBJ_DIR" \
    bash build_vtop.sh "$PAYLOAD_HEX"
else
  echo "reusing $OBJ_DIR/Vvtop"
fi

if [ "$RUN_SIM" = "0" ]; then
  echo "build-only complete: $OBJ_DIR/Vvtop"
  exit 0
fi

mkdir -p "$LOGDIR"
LOG_PREFIX=${LOG_PREFIX:-$LOGDIR/run-vtop-synth-linux-sf-${TIMEBASE_TAG}-nonet-$(date +%Y%m%d-%H%M%S)}
OUT_LOG=${OUT_LOG:-${LOG_PREFIX}.out}
ERR_LOG=${ERR_LOG:-${LOG_PREFIX}.err}

echo "payload=$PAYLOAD_HEX words=$MEMFILE_WORDS"
echo "obj=$OBJ_DIR/Vvtop maxcyc=$MAXCYC expect=$EXPECT_UART"
echo "stdout=$OUT_LOG"
echo "stderr=$ERR_LOG"

EXPECT_UART="$EXPECT_UART" "./$OBJ_DIR/Vvtop" "--maxcyc=$MAXCYC" >"$OUT_LOG" 2>"$ERR_LOG"

if grep -qF "[VSIM] expect matched \"$EXPECT_UART\"" "$ERR_LOG"; then
  echo "SYNTH_SHELL_NONET_EXPECT_RESULT: PASS"
  grep -F "[VSIM] expect matched \"$EXPECT_UART\"" "$ERR_LOG" | tail -1
else
  echo "SYNTH_SHELL_NONET_EXPECT_RESULT: FAIL" >&2
  tail -n 40 "$OUT_LOG" >&2 || true
  tail -n 40 "$ERR_LOG" >&2 || true
  exit 1
fi
