#!/bin/bash
# build_run.sh <name> : compile tests/<name>.c (+start.S) and run it on the
# rvlinux core via iverilog. Requires a host RISC-V clang and iverilog on PATH.
set -e
cd "$(dirname "$0")/.."                       # repo root
NAME=$1
CLANG=${CLANG:-/usr/local/opt/llvm/bin/clang}
OBJCOPY=${OBJCOPY:-/usr/local/opt/llvm/bin/llvm-objcopy}
[ -f oss-cad-suite/environment ] && source oss-cad-suite/environment 2>/dev/null || true
$CLANG --target=riscv32 -march=rv32ima -mabi=ilp32 -nostdlib -ffreestanding -static -O2 \
   -fno-builtin -fuse-ld=lld -T tests/bm.ld \
   -o tests/$NAME.elf tests/start.S tests/$NAME.c
$OBJCOPY -O binary tests/$NAME.elf tests/$NAME.bin
python3 tools/bin2hex.py tests/$NAME.bin tests/$NAME.hex
iverilog -g2012 -D SIM_INIT -D MEMW=1048576 -D MAXCYC=${MAXCYC:-200000} \
   -D PROG=\"tests/$NAME.hex\" -o /tmp/tb_$NAME rtl/cores/rvlinux.v sim/tb_linux.v
vvp /tmp/tb_$NAME
