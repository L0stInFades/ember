#!/usr/bin/env bash
# Strict external P1 verification tool gate. This is separate from verify.sh
# until RISCOF/Spike are installed and configured in CI.
set -euo pipefail

cd "$(dirname "$0")"

if [ -d ".p1/spike/bin" ]; then
  export PATH="$PWD/.p1/spike/bin:$PATH"
fi

if [ -f ".p1/riscof-venv/bin/activate" ]; then
  # shellcheck disable=SC1091
  source ".p1/riscof-venv/bin/activate"
fi

python3 tools/p1_tool_audit.py

find_syscon_stop_pc() {
  python3 - "$1" <<'PY'
import csv
import sys

trace_path = sys.argv[1]
with open(trace_path, "r", encoding="ascii", newline="") as f:
    rows = list(csv.DictReader(f))

for prev, row in zip(rows, rows[1:]):
    try:
        instr = int(row["instr"], 16)
    except ValueError:
        continue
    if (
        prev["event"] == "RET"
        and prev["rd"] != "0"
        and prev["wdata"].lower() == "11100000"
        and row["event"] == "RET"
        and (instr & 0x7F) == 0x23
    ):
        print("0x" + row["pc"])
        break
else:
    raise SystemExit(f"{trace_path}: missing syscon report store stop point")
PY
}

if [ "${P1_SKIP_SPIKE_PREFIX:-0}" != "1" ]; then
  LOGDIR=${LOGDIR:-logs/p1-external-$(date +%Y%m%d-%H%M%S)}
  mkdir -p "$LOGDIR"

  tests=${P1_SPIKE_PREFIX_TESTS:-"isa amotest ctest shtest mtest"}
  for t in $tests; do
    echo "=== spike-prefix $t ==="
    rm -f rvtrace.log "$LOGDIR/rvtrace_${t}.csv"
    LOG="$LOGDIR/${t}_dut.log" \
      EXTRA_IVERILOG_FLAGS="-D RVTRACE" \
      bash tests/build_run.sh "$t" >"$LOGDIR/${t}_build_run.log" 2>&1
    test -s rvtrace.log
    mv rvtrace.log "$LOGDIR/rvtrace_${t}.csv"

    python3 tools/check_rvtrace.py \
      --trace "$LOGDIR/rvtrace_${t}.csv" \
      --hex "tests/${t}.hex" \
      --base 0x80000000 \
      --min-ret 1 \
      --no-trap

    python3 tools/spike_trace_prefix.py \
      --trace "$LOGDIR/rvtrace_${t}.csv" \
      --elf "tests/${t}.elf" \
      --spike spike \
      --spike-log "$LOGDIR/spike_${t}.log" \
      --base 0x80000000 \
      --stop-before-pc 0x80000048
  done

  if [ "${P1_SKIP_SPIKE_MMU_PREFIX:-0}" != "1" ]; then
    t=mmu
    echo "=== spike-prefix $t ==="
    rm -f rvtrace.log "$LOGDIR/rvtrace_${t}.csv"
    LOG="$LOGDIR/${t}_dut.log" \
      EXTRA_IVERILOG_FLAGS="-D RVTRACE" \
      bash tests/build_run.sh "$t" >"$LOGDIR/${t}_build_run.log" 2>&1
    test -s rvtrace.log
    mv rvtrace.log "$LOGDIR/rvtrace_${t}.csv"

    python3 tools/check_rvtrace.py \
      --trace "$LOGDIR/rvtrace_${t}.csv" \
      --hex "tests/${t}.hex" \
      --base 0x80000000 \
      --min-ret 1

    stop_pc=$(python3 - "$LOGDIR/rvtrace_${t}.csv" <<'PY'
import csv
import sys

with open(sys.argv[1], "r", encoding="ascii", newline="") as f:
    for row in csv.DictReader(f):
        if row["event"] == "TRAP" and row["cause"].lower() == "00000009":
            print("0x" + row["pc"])
            break
    else:
        raise SystemExit("missing S-mode ecall trap stop point")
PY
)

    python3 tools/spike_trace_prefix.py \
      --trace "$LOGDIR/rvtrace_${t}.csv" \
      --elf "tests/${t}.elf" \
      --spike spike \
      --spike-log "$LOGDIR/spike_${t}.log" \
      --base 0x80000000 \
      --mem 0x80000000:0x400000 \
      --isa RV32IMA_Svadu \
      --instructions 20000 \
      --stop-before-pc "$stop_pc"
  fi

  if [ "${P1_SKIP_SPIKE_UTRAP_PREFIX:-0}" != "1" ]; then
    t=utrap
    echo "=== spike-prefix $t ==="
    rm -f rvtrace.log "$LOGDIR/rvtrace_${t}.csv"
    LOG="$LOGDIR/${t}_dut.log" \
      EXTRA_IVERILOG_FLAGS="-D RVTRACE" \
      bash tests/build_run.sh "$t" >"$LOGDIR/${t}_build_run.log" 2>&1
    test -s rvtrace.log
    mv rvtrace.log "$LOGDIR/rvtrace_${t}.csv"

    python3 tools/check_rvtrace.py \
      --trace "$LOGDIR/rvtrace_${t}.csv" \
      --hex "tests/${t}.hex" \
      --base 0x80000000 \
      --min-ret 1

    stop_pc=$(python3 - "$LOGDIR/rvtrace_${t}.csv" <<'PY'
import csv
import sys

with open(sys.argv[1], "r", encoding="ascii", newline="") as f:
    for row in csv.DictReader(f):
        if row["event"] == "TRAP" and row["cause"].lower() == "00000008":
            print("0x" + row["pc"])
            break
    else:
        raise SystemExit("missing U-mode ecall trap stop point")
PY
)

    python3 tools/spike_trace_prefix.py \
      --trace "$LOGDIR/rvtrace_${t}.csv" \
      --elf "tests/${t}.elf" \
      --spike spike \
      --spike-log "$LOGDIR/spike_${t}.log" \
      --base 0x80000000 \
      --stop-before-pc "$stop_pc"
  fi

  if [ "${P1_SKIP_SPIKE_MISALIGN_PREFIX:-0}" != "1" ]; then
    t=misalign
    echo "=== spike-prefix $t ==="
    rm -f rvtrace.log "$LOGDIR/rvtrace_${t}.csv"
    LOG="$LOGDIR/${t}_dut.log" \
      EXTRA_IVERILOG_FLAGS="-D RVTRACE" \
      bash tests/build_run.sh "$t" >"$LOGDIR/${t}_build_run.log" 2>&1
    test -s rvtrace.log
    mv rvtrace.log "$LOGDIR/rvtrace_${t}.csv"

    python3 tools/check_rvtrace.py \
      --trace "$LOGDIR/rvtrace_${t}.csv" \
      --hex "tests/${t}.hex" \
      --base 0x80000000 \
      --min-ret 1

    python3 tools/spike_trace_prefix.py \
      --trace "$LOGDIR/rvtrace_${t}.csv" \
      --elf "tests/${t}.elf" \
      --spike spike \
      --spike-log "$LOGDIR/spike_${t}.log" \
      --base 0x80000000 \
      --expect-terminal-trap
  fi

  if [ "${P1_SKIP_SPIKE_SV32_PREFIX:-0}" != "1" ]; then
    tests=${P1_SPIKE_SV32_PREFIX_TESTS:-"mxr upage ifault wpfault sum badpte superpage amo_mmu"}
    for t in $tests; do
      echo "=== spike-prefix $t ==="
      rm -f rvtrace.log "$LOGDIR/rvtrace_${t}.csv"
      LOG="$LOGDIR/${t}_dut.log" \
        EXTRA_IVERILOG_FLAGS="-D RVTRACE" \
        bash tests/build_run.sh "$t" >"$LOGDIR/${t}_build_run.log" 2>&1
      test -s rvtrace.log
      mv rvtrace.log "$LOGDIR/rvtrace_${t}.csv"

      python3 tools/check_rvtrace.py \
        --trace "$LOGDIR/rvtrace_${t}.csv" \
        --hex "tests/${t}.hex" \
        --base 0x80000000 \
        --min-ret 1

      stop_pc=$(find_syscon_stop_pc "$LOGDIR/rvtrace_${t}.csv")

      python3 tools/spike_trace_prefix.py \
        --trace "$LOGDIR/rvtrace_${t}.csv" \
        --elf "tests/${t}.elf" \
        --spike spike \
        --spike-log "$LOGDIR/spike_${t}.log" \
        --base 0x80000000 \
        --mem 0x80000000:0x400000 \
        --isa RV32IMA_Svadu \
        --instructions 40000 \
        --stop-before-pc "$stop_pc"
    done
  fi

  echo "P1_EXTERNAL: PASS logdir=$LOGDIR"
fi
