#!/usr/bin/env bash
# Explicit P0 Linux boot gate for the synthesizable rvlinux path.
# This is intentionally separate from verify.sh because the default login run is
# a multi-billion-cycle Verilator job.
set -euo pipefail

cd "$(dirname "$0")"

usage() {
  cat >&2 <<'EOF'
usage: ./verify_p0_linux.sh [options]

Modes:
  default            Run the full synth-shell no-net boot-to-login gate.
  --smoke           Fast harness/payload smoke; expects "OpenSBI".

Options:
  --reuse           Reuse an existing OBJ_DIR/Vvtop instead of rebuilding.
  --prepare-payload Rebuild the no-net soft-float payload in Docker first.
  --maxcyc=N        Override the Verilator cycle cap.
  --logdir=DIR      Store wrapper logs under DIR.
  --check-logs=PFX  Check existing PFX.out/PFX.err logs instead of running.
  -h, --help        Show this help.

Environment:
  LOGDIR            Default log directory (logs/p0-linux-<timestamp>).
  P0_LINUX_REUSE    Set to 1 to reuse an existing Verilator binary.
  P0_LINUX_SMOKE    Set to 1 for the OpenSBI smoke mode.
EOF
}

SMOKE=${P0_LINUX_SMOKE:-0}
REUSE=${P0_LINUX_REUSE:-0}
PREPARE_PAYLOAD=0
CHECK_LOG_PREFIX=
LOGDIR=${LOGDIR:-logs/p0-linux-$(date +%Y%m%d-%H%M%S)}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --smoke)
      SMOKE=1
      ;;
    --reuse)
      REUSE=1
      ;;
    --prepare-payload)
      PREPARE_PAYLOAD=1
      ;;
    --maxcyc=*)
      MAXCYC=${1#--maxcyc=}
      ;;
    --logdir=*)
      LOGDIR=${1#--logdir=}
      ;;
    --check-logs=*)
      CHECK_LOG_PREFIX=${1#--check-logs=}
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

mkdir -p "$LOGDIR"

runner_args=()
if [ "$REUSE" != "0" ]; then
  runner_args+=(--no-build)
fi
if [ "$PREPARE_PAYLOAD" != "0" ]; then
  runner_args+=(--prepare-payload)
fi

if [ "$SMOKE" != "0" ]; then
  export EXPECT_UART=${EXPECT_UART:-OpenSBI}
  export MAXCYC=${MAXCYC:-50000000}
  export LOG_PREFIX=${LOG_PREFIX:-$LOGDIR/synth-shell-nonet-smoke}
else
  export EXPECT_UART=${EXPECT_UART:-buildroot login:}
  export MAXCYC=${MAXCYC:-10000000000}
  export LOG_PREFIX=${LOG_PREFIX:-$LOGDIR/synth-shell-nonet-login}
fi

if [ -n "$CHECK_LOG_PREFIX" ]; then
  export LOG_PREFIX=$CHECK_LOG_PREFIX
fi
export LOGDIR

echo "P0_LINUX_GATE: mode=$([ "$SMOKE" != "0" ] && echo smoke || echo login) reuse=$REUSE prepare_payload=$PREPARE_PAYLOAD"
echo "P0_LINUX_GATE: expect=$EXPECT_UART maxcyc=$MAXCYC log_prefix=$LOG_PREFIX"

if [ -n "$CHECK_LOG_PREFIX" ]; then
  echo "P0_LINUX_GATE: checking existing logs prefix=$LOG_PREFIX"
else
  ./run_synth_shell_nonet.sh "${runner_args[@]}"
fi

out_log="${LOG_PREFIX}.out"
err_log="${LOG_PREFIX}.err"

[ -s "$out_log" ] || { echo "P0_LINUX_GATE: FAIL missing $out_log" >&2; exit 1; }
[ -s "$err_log" ] || { echo "P0_LINUX_GATE: FAIL missing $err_log" >&2; exit 1; }
grep -qF "[VSIM] expect matched \"$EXPECT_UART\"" "$err_log"
if [ "$SMOKE" = "0" ]; then
  grep -qF "Starting network: OK" "$out_log"
  grep -qF "Welcome to Buildroot" "$out_log"
  grep -qF "buildroot login:" "$out_log"
  if grep -Eq 'Waiting for interface eth0|/dev/null|panic|Oops|BUG' "$out_log" "$err_log"; then
    echo "P0_LINUX_GATE: FAIL unexpected boot error signature" >&2
    exit 1
  fi
fi

echo "P0_LINUX_GATE: PASS logdir=$LOGDIR"
