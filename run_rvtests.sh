#!/bin/bash
# 跑官方 riscv-tests (rv32ui + rv32um) 在自建核上
cd "$(dirname "$0")"

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
  echo "[run_rvtests] missing clang, llvm-objcopy, or ld.lld" >&2
  exit 1
fi

ensure_soc_rt() {
  local rebuild=0
  if [ ! -x ./soc_rt ]; then
    rebuild=1
  elif [ rvcore.v -nt ./soc_rt ] || [ soc_tb.v -nt ./soc_rt ] || [ run_rvtests.sh -nt ./soc_rt ]; then
    rebuild=1
  fi
  if [ "$rebuild" -eq 0 ]; then
    return
  fi
  if [ -f oss-cad-suite/environment ]; then
    source oss-cad-suite/environment
  fi
  if ! command -v iverilog >/dev/null 2>&1; then
    echo "[run_rvtests] missing iverilog to build ./soc_rt" >&2
    exit 1
  fi
  iverilog -g2012 -D SIM_INIT -D PROG=\"rvtest.hex\" -o soc_rt rvcore.v soc_tb.v
}

ensure_soc_rt

UI="add addi and andi auipc beq bge bgeu blt bltu bne fence_i jal jalr lb lbu lh lhu lui lw or ori sb sh sll slli slt slti sltiu sltu sra srai srl srli sub sw xor xori"
UM="mul mulh mulhsu mulhu div divu rem remu"
pass=0; fail=0; err=0; faillist=""
run_one() {
  local set=$1 name=$2
  if ! "$CLANG" --target=riscv32 -march=rv32im -mabi=ilp32 -nostdlib -ffreestanding -fno-pic \
        -Irvtests -c rvtests/$set/$name.S -o /tmp/rt.o 2>/tmp/rt.err; then
    printf "  %-10s ASM-ERR\n" "$name"; err=$((err+1)); faillist="$faillist $set/$name(asm)"; return; fi
  if ! "$LD" -m elf32lriscv -T link.ld /tmp/rt.o -o /tmp/rt.elf 2>/tmp/rt.lderr; then
    printf "  %-10s LD-ERR\n" "$name"; err=$((err+1)); faillist="$faillist $set/$name(ld)"; return; fi
  "$OBJCOPY" -O binary /tmp/rt.elf /tmp/rt.bin
  python3 bin2hex.py /tmp/rt.bin rvtest.hex
  local out code
  out=$(./soc_rt 2>/dev/null | grep -oE "退出码 = [0-9]+" | grep -oE "[0-9]+")
  if [ "$out" = "0" ]; then pass=$((pass+1));
  else printf "  %-10s FAIL (退出码=%s)\n" "$name" "${out:-超时}"; fail=$((fail+1)); faillist="$faillist $set/$name"; fi
}
echo "================ rv32ui (基础整数) ================"
for t in $UI; do run_one rv32ui $t; done
echo "================ rv32um (乘除) ================"
for t in $UM; do run_one rv32um $t; done
echo "=================================================="
echo "通过=$pass  失败=$fail  错误=$err"
[ -n "$faillist" ] && echo "未过:$faillist"
echo "总计 = $((pass+fail+err)) 个测试"
if [ "$fail" -ne 0 ] || [ "$err" -ne 0 ]; then
  exit 1
fi
