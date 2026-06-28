#!/bin/bash
# build_run.sh <name>  : compile tests/<name>.c (+start.S) and run on rvlinux via iverilog
set -euo pipefail
cd "$(dirname "$0")/.."
NAME=$1

find_first_exe() {
  local candidate
  for candidate in "$@"; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

find_path_tool() {
  command -v "$1" 2>/dev/null || true
}

export PATH=/usr/local/bin:/opt/homebrew/bin:$PATH
if [ -z "${CLANG:-}" ]; then
  CLANG=$(find_first_exe /usr/local/opt/llvm/bin/clang /opt/homebrew/opt/llvm/bin/clang || find_path_tool clang)
fi
if [ -z "${OBJCOPY:-}" ]; then
  OBJCOPY=$(find_first_exe /usr/local/opt/llvm/bin/llvm-objcopy /opt/homebrew/opt/llvm/bin/llvm-objcopy || find_path_tool llvm-objcopy)
fi
if [ -z "${LD:-}" ]; then
  LD=$(find_first_exe \
    /usr/local/opt/lld/bin/ld.lld \
    /opt/homebrew/opt/lld/bin/ld.lld \
    /usr/local/bin/ld.lld \
    /opt/homebrew/bin/ld.lld \
    /usr/local/opt/llvm/bin/ld.lld \
    /opt/homebrew/opt/llvm/bin/ld.lld \
    || find_path_tool ld.lld)
fi
if [ -z "${CLANG:-}" ] || [ -z "${OBJCOPY:-}" ] || [ -z "${LD:-}" ]; then
  echo "[build_run] missing clang, llvm-objcopy, or ld.lld" >&2
  exit 1
fi

"$CLANG" --target=riscv32 -march=rv32ima -mabi=ilp32 -nostdlib -ffreestanding -O2 \
   -fno-builtin -fno-pic -c tests/start.S -o /tmp/${NAME}_start.o
"$CLANG" --target=riscv32 -march=rv32ima -mabi=ilp32 -nostdlib -ffreestanding -O2 \
   -fno-builtin -fno-pic -c tests/$NAME.c -o /tmp/${NAME}.o
"$LD" -m elf32lriscv -T tests/bm.ld /tmp/${NAME}_start.o /tmp/${NAME}.o -o tests/$NAME.elf
"$OBJCOPY" -O binary tests/$NAME.elf tests/$NAME.bin
python3 bin2hex.py tests/$NAME.bin tests/$NAME.hex
if [ -f oss-cad-suite/environment ]; then
  source oss-cad-suite/environment
fi
iverilog -g2012 -D SIM_INIT -D MEMW=1048576 -D MAXCYC=${MAXCYC:-200000} \
   ${EXTRA_IVERILOG_FLAGS:-} \
   -D PROG=\"tests/$NAME.hex\" -o /tmp/tb_$NAME rvlinux.v tb_linux.v
LOG=${LOG:-/tmp/tb_$NAME.log}
vvp /tmp/tb_$NAME | tee "$LOG"
if ! grep -q "\\[SOC\\] halt exit=0" "$LOG"; then
  echo "[build_run] FAIL: missing clean halt exit=0 for $NAME" >&2
  exit 1
fi
if grep -q "RESULT: FAIL" "$LOG"; then
  echo "[build_run] FAIL: RESULT failure reported by $NAME" >&2
  exit 1
fi
