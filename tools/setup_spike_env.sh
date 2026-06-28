#!/usr/bin/env bash
# Build a local Spike under .p1/ for the external P1 prefix gate.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SPIKE_REPO=${P1_SPIKE_REPO:-https://github.com/riscv-software-src/riscv-isa-sim.git}
SPIKE_REF=${P1_SPIKE_REF:-}
SPIKE_SRC=${P1_SPIKE_SRC:-"$ROOT/.p1/riscv-isa-sim"}
SPIKE_BUILD=${P1_SPIKE_BUILD:-"$ROOT/.p1/riscv-isa-sim-build"}
SPIKE_PREFIX=${P1_SPIKE_PREFIX:-"$ROOT/.p1/spike"}
SPIKE_JOBS=${P1_SPIKE_JOBS:-}

mkdir -p "$ROOT/.p1"

if [ ! -d "$SPIKE_SRC/.git" ]; then
  rm -rf "$SPIKE_SRC"
  git clone "$SPIKE_REPO" "$SPIKE_SRC"
fi

if [ -n "$SPIKE_REF" ]; then
  git -C "$SPIKE_SRC" fetch --tags origin
  git -C "$SPIKE_SRC" checkout "$SPIKE_REF"
fi

if [ -z "$SPIKE_JOBS" ]; then
  if command -v nproc >/dev/null 2>&1; then
    SPIKE_JOBS=$(nproc)
  elif command -v sysctl >/dev/null 2>&1; then
    SPIKE_JOBS=$(sysctl -n hw.ncpu)
  else
    SPIKE_JOBS=2
  fi
fi

mkdir -p "$SPIKE_BUILD" "$SPIKE_PREFIX"

(
  cd "$SPIKE_BUILD"
  "$SPIKE_SRC/configure" --prefix="$SPIKE_PREFIX"
  make -j"$SPIKE_JOBS"
  make install
)

AUDIT_VENV=${P1_RISCOF_VENV:-"$ROOT/.p1/riscof-venv"}
AUDIT_PYTHON="$AUDIT_VENV/bin/python"
AUDIT_PATH="$SPIKE_PREFIX/bin:$PATH"
if [ ! -x "$AUDIT_PYTHON" ]; then
  AUDIT_PYTHON=python3
else
  AUDIT_PATH="$AUDIT_VENV/bin:$AUDIT_PATH"
fi

PATH="$AUDIT_PATH" "$AUDIT_PYTHON" "$ROOT/tools/p1_tool_audit.py" --allow-missing
