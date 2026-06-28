#!/usr/bin/env bash
# Build a small upstream ACT4 RV32 smoke set, use Spike to generate expected
# signatures, then run the self-checking ELFs on the Ember RTL testbench.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

LOGDIR=${LOGDIR:-logs/p1-act4-spike-$(date +%Y%m%d-%H%M%S)}
ARCH_TEST=${P1_ARCH_TEST_DIR:-"$ROOT/.p1/riscv-arch-test"}
CONFIG_DIR=${P1_ACT4_CONFIG_DIR:-"$ROOT/p1/act4/ember-rv32i"}
TESTS=${P1_ACT4_TESTS:-}
ACT_GROUPS=${P1_ACT4_GROUPS:-"I M Zaamo Zalrsc Zca Zicsr Zifencei"}
ZICSR_MARCH=${P1_ACT4_ZICSR_MARCH:-rv32i_zicsr_zifencei_zca}
MAXCYC=${P1_ACT4_MAXCYC:-1500000}
SPIKE_INSNS=${P1_ACT4_SPIKE_INSNS:-2000000}

mkdir -p "$LOGDIR"
LOGDIR=$(cd "$LOGDIR" && pwd)

if [ -d "$ROOT/.p1/spike/bin" ]; then
  export PATH="$ROOT/.p1/spike/bin:$PATH"
fi

find_first_exe() {
  local candidate
  for candidate in "$@"; do
    if [ -x "$candidate" ] || command -v "$candidate" >/dev/null 2>&1; then
      command -v "$candidate" 2>/dev/null || printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

GCC=${RISCV_GCC:-$(find_first_exe riscv64-unknown-elf-gcc riscv64-elf-gcc)}
OBJCOPY=${RISCV_OBJCOPY:-$(find_first_exe riscv64-unknown-elf-objcopy riscv64-elf-objcopy)}
SPIKE=${SPIKE:-$(find_first_exe spike)}

[ -d "$ARCH_TEST/tests/env" ] || { echo "missing ACT tests env: $ARCH_TEST/tests/env" >&2; exit 1; }
[ -d "$ARCH_TEST/tests/rv32i" ] || { echo "missing ACT RV32 tests: $ARCH_TEST/tests/rv32i" >&2; exit 1; }
[ -f "$CONFIG_DIR/link.ld" ] || { echo "missing ACT link script: $CONFIG_DIR/link.ld" >&2; exit 1; }
[ -f "$CONFIG_DIR/rvmodel_macros.h" ] || { echo "missing rvmodel macros: $CONFIG_DIR/rvmodel_macros.h" >&2; exit 1; }
[ -f "$CONFIG_DIR/rvtest_config.h" ] || { echo "missing rvtest config: $CONFIG_DIR/rvtest_config.h" >&2; exit 1; }

if [ -z "$TESTS" ]; then
  TESTS=$(
    for group in $ACT_GROUPS; do
      test_dir="$ARCH_TEST/tests/rv32i/$group"
      [ -d "$test_dir" ] || { echo "missing ACT RV32 test group: $test_dir" >&2; exit 1; }
      for path in "$test_dir"/${group}-*.S; do
        [ -f "$path" ] || continue
        name=${path##*/}
        printf '%s/%s\n' "$group" "${name%.S}"
      done | sort
    done | tr '\n' ' '
  )
fi
[ -n "$TESTS" ] || { echo "no ACT RV32 tests selected" >&2; exit 1; }

find_test_src() {
  local test=$1
  local group name
  if [[ "$test" == */* ]]; then
    group=${test%%/*}
    name=${test#*/}
  else
    group=${test%%-*}
    name=$test
  fi
  printf '%s\n' "$ARCH_TEST/tests/rv32i/$group/${name}.S"
}

test_march() {
  awk '/^# MARCH:/{print $3; exit}' "$1"
}

effective_march() {
  local test=$1
  local march=$2
  local group
  group=${test%%/*}
  if [ -n "${P1_ACT4_MARCH:-}" ]; then
    printf '%s\n' "$P1_ACT4_MARCH"
  elif [ "$group" = "Zicsr" ]; then
    printf '%s\n' "$ZICSR_MARCH"
  else
    printf '%s\n' "$march"
  fi
}

process_signature() {
  PYTHONPATH="$ARCH_TEST/framework/src${PYTHONPATH:+:$PYTHONPATH}" \
    python3 - "$1" <<'PY'
from pathlib import Path
import sys

from act.sig_modify import process_signature_file

process_signature_file(Path(sys.argv[1]), 32)
PY
}

compile_common=(
  "$GCC"
  "-I$CONFIG_DIR"
  "-I$ARCH_TEST/tests/env"
  "-T$CONFIG_DIR/link.ld"
  -O0
  -g
  -mcmodel=medany
  -nostdlib
  -Wl,--no-warn-rwx-segments
  -mabi=ilp32
  -DTEST_FLEN=32
)

run_one() {
  local test=$1
  local src
  src=$(find_test_src "$test")
  local name=${test##*/}
  local tdir="$LOGDIR/$test"
  local sig_elf="$tdir/${name}.sig.elf"
  local sig_file="$tdir/${name}.sig"
  local results="$tdir/${name}.results"
  local elf="$tdir/${name}.elf"
  local bin="$tdir/${name}.bin"
  local hex="$tdir/${name}.hex"
  local sim="$tdir/tb_${name}"
  local dut_log="$tdir/${name}.dut.log"
  local march

  [ -f "$src" ] || { echo "missing ACT source: $src" >&2; return 1; }
  march=$(test_march "$src")
  [ -n "$march" ] || { echo "missing MARCH metadata: $src" >&2; return 1; }
  march=$(effective_march "$test" "$march")
  mkdir -p "$tdir"

  if ! "${compile_common[@]}" -march="$march" -DSIGNATURE "$src" -o "$sig_elf" >"$tdir/compile_sig.log" 2>&1; then
    echo "[act4-smoke] compile signature failed: $test" >&2
    return 1
  fi

  if ! "$SPIKE" --isa="$march" --instructions="$SPIKE_INSNS" \
      "+signature=$sig_file" +signature-granularity=4 "$sig_elf" \
      >"$tdir/spike.log" 2>&1; then
    echo "[act4-smoke] spike signature failed: $test" >&2
    return 1
  fi
  [ -s "$sig_file" ] || { echo "[act4-smoke] empty signature: $test" >&2; return 1; }

  if ! process_signature "$sig_file" >"$tdir/process_signature.log" 2>&1; then
    echo "[act4-smoke] signature processing failed: $test" >&2
    return 1
  fi
  [ -s "$results" ] || { echo "[act4-smoke] missing results: $test" >&2; return 1; }

  if ! "${compile_common[@]}" -march="$march" -DRVTEST_SELFCHECK -DXLEN=32 \
      "-DSIGNATURE_FILE=\"$results\"" "$src" -o "$elf" \
      >"$tdir/compile_selfcheck.log" 2>&1; then
    echo "[act4-smoke] compile selfcheck failed: $test" >&2
    return 1
  fi

  if ! "$OBJCOPY" -O binary "$elf" "$bin" >"$tdir/objcopy.log" 2>&1; then
    echo "[act4-smoke] objcopy failed: $test" >&2
    return 1
  fi
  if ! python3 bin2hex.py "$bin" "$hex" >"$tdir/bin2hex.log" 2>&1; then
    echo "[act4-smoke] bin2hex failed: $test" >&2
    return 1
  fi

  if ! iverilog -g2012 -D SIM_INIT -D MEMW=1048576 -D MAXCYC="$MAXCYC" \
      -D PROG="\"$hex\"" -o "$sim" rvlinux.v tb_linux.v \
      >"$tdir/iverilog.log" 2>&1; then
    echo "[act4-smoke] iverilog failed: $test" >&2
    return 1
  fi
  if ! vvp "$sim" >"$dut_log" 2>&1; then
    echo "[act4-smoke] vvp failed: $test" >&2
    return 1
  fi
  if ! grep -q 'RVCP-SUMMARY: TEST PASSED' "$dut_log"; then
    echo "[act4-smoke] missing RVCP pass summary: $test" >&2
    return 1
  fi
  if ! grep -q '\[SOC\] halt exit=0' "$dut_log"; then
    echo "[act4-smoke] missing clean syscon halt: $test" >&2
    return 1
  fi

  echo "ACT4_SPIKE_TEST: PASS test=$test logdir=$tdir"
}

passed=0
failed=0
total=0
for test in $TESTS; do
  total=$((total + 1))
  echo "=== act4-spike $test ==="
  if run_one "$test"; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
  fi
done

if [ "$failed" -ne 0 ]; then
  echo "P1_ACT4_SPIKE: FAIL tests=$total passed=$passed failed=$failed logdir=$LOGDIR" >&2
  exit 1
fi

echo "P1_ACT4_SPIKE: PASS tests=$total passed=$passed failed=$failed logdir=$LOGDIR"
