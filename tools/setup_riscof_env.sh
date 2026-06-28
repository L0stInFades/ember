#!/usr/bin/env bash
# Create a local RISCOF environment under .p1/ without changing the default
# self-contained regression.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VENV=${P1_RISCOF_VENV:-"$ROOT/.p1/riscof-venv"}
ARCH_TEST=${P1_ARCH_TEST_DIR:-"$ROOT/.p1/riscv-arch-test"}
ARCH_TEST_REF=${P1_ARCH_TEST_REF:-c6c69dc33414101c7ea94bf4fbea40885f9447ce}

mkdir -p "$ROOT/.p1"

if [ ! -x "$VENV/bin/python" ]; then
  python3 -m venv "$VENV"
fi

"$VENV/bin/python" -m pip install --upgrade pip wheel
"$VENV/bin/python" -m pip install --upgrade riscof

if [ ! -d "$ARCH_TEST/.git" ]; then
  rm -rf "$ARCH_TEST"
  git clone --no-checkout https://github.com/riscv-non-isa/riscv-arch-test "$ARCH_TEST"
fi
git -C "$ARCH_TEST" fetch --depth 1 origin "$ARCH_TEST_REF"
git -C "$ARCH_TEST" checkout --detach FETCH_HEAD

if [ -d "$ARCH_TEST/framework" ]; then
  "$VENV/bin/python" -m pip install --upgrade \
    -e "$ARCH_TEST/framework" \
    -e "$ARCH_TEST/generators/testgen" \
    -e "$ARCH_TEST/generators/coverage"
fi

PATH="$ROOT/.p1/spike/bin:$PATH" "$VENV/bin/python" "$ROOT/tools/p1_tool_audit.py" --venv "$VENV" --allow-missing
