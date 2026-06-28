#!/bin/bash
# build_run.sh <name>  : compile tests/<name>.c (+start.S) and run on rvlinux via iverilog
set -euo pipefail
cd "$(dirname "$0")/.."
NAME=$1
if [ -z "${CLANG:-}" ]; then
  if [ -x /usr/local/opt/llvm/bin/clang ]; then
    CLANG=/usr/local/opt/llvm/bin/clang
  elif [ -x /opt/homebrew/opt/llvm/bin/clang ]; then
    CLANG=/opt/homebrew/opt/llvm/bin/clang
  else
    CLANG=$(command -v clang)
  fi
fi
if [ -z "${OBJCOPY:-}" ]; then
  if [ -x /usr/local/opt/llvm/bin/llvm-objcopy ]; then
    OBJCOPY=/usr/local/opt/llvm/bin/llvm-objcopy
  elif [ -x /opt/homebrew/opt/llvm/bin/llvm-objcopy ]; then
    OBJCOPY=/opt/homebrew/opt/llvm/bin/llvm-objcopy
  else
    OBJCOPY=$(command -v llvm-objcopy)
  fi
fi
export PATH=/usr/local/bin:/opt/homebrew/bin:$PATH
$CLANG --target=riscv32 -march=rv32ima -mabi=ilp32 -nostdlib -ffreestanding -static -O2 \
   -fno-builtin -fuse-ld=lld -T tests/bm.ld \
   -o tests/$NAME.elf tests/start.S tests/$NAME.c
$OBJCOPY -O binary tests/$NAME.elf tests/$NAME.bin
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
