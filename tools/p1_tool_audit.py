#!/usr/bin/env python3
"""Audit external P1 verification tools.

The default regression is self-contained. This script is intentionally stricter:
it reports whether the external tools needed for RISCOF/ACT compliance and
Spike lockstep work are actually available on this machine.
"""
import argparse
import os
import shutil
import subprocess
import sys


TOOL_GROUPS = [
    (
        "host",
        [
            ("python3", "Python driver/runtime"),
            ("git", "fetch riscv-arch-test and ISS sources"),
        ],
    ),
    (
        "riscof",
        [
            ("riscof", "RISCOF compliance runner"),
            (("riscv64-unknown-elf-gcc", "riscv64-elf-gcc"), "RISC-V bare-metal compiler"),
            (("riscv64-unknown-elf-objcopy", "riscv64-elf-objcopy"), "RISC-V objcopy"),
            (("riscv64-unknown-elf-objdump", "riscv64-elf-objdump"), "RISC-V objdump"),
        ],
    ),
    (
        "act4",
        [
            ("act", "ACT4 framework CLI"),
            ("testgen", "ACT4 test generator CLI"),
            ("covergroupgen", "ACT4 coverage generator CLI"),
        ],
    ),
    (
        "dut-sim",
        [
            (("/usr/local/opt/llvm/bin/clang", "clang"), "LLVM clang used by tests/build_run.sh"),
            (("/usr/local/opt/llvm/bin/llvm-objcopy", "llvm-objcopy"), "LLVM objcopy used by tests/build_run.sh"),
            ("iverilog", "DUT RTL simulation compile"),
            ("vvp", "DUT RTL simulation runtime"),
        ],
    ),
    (
        "difftest",
        [
            ("spike", "golden ISS for lockstep/difftest"),
        ],
    ),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--venv", help="optional venv whose bin directory should be searched first")
    ap.add_argument("--allow-missing", action="store_true", help="report missing tools but exit 0")
    args = ap.parse_args()

    path = os.environ.get("PATH", "")
    if args.venv:
        path = os.path.join(args.venv, "bin") + os.pathsep + path

    missing = []
    print("P1_TOOL_AUDIT")
    for group, tools in TOOL_GROUPS:
        print(f"[{group}]")
        for names, purpose in tools:
            if isinstance(names, str):
                names = (names,)
            display = "/".join(names)
            found_name, found = find_tool(names, path)
            if found:
                version = probe_version(found)
                detail = f"{found}"
                if version:
                    detail += f" ({version})"
                print(f"  PASS {display:<30} {found_name}: {detail}")
            else:
                missing.append((display, purpose))
                print(f"  MISS {display:<30} {purpose}")

    if missing:
        print("\nMissing tools:")
        for name, purpose in missing:
            print(f"  - {name}: {purpose}")
        if not args.allow_missing:
            return 1

    print("\nP1_TOOL_AUDIT: PASS" if not missing else "\nP1_TOOL_AUDIT: INCOMPLETE")
    return 0


def find_tool(names, path):
    for name in names:
        found = shutil.which(name, path=path)
        if found:
            return name, found
    return "", None


def probe_version(path):
    for flag in ("-V", "--version", "-version", "-v", "--help"):
        try:
            proc = subprocess.run(
                [path, flag],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                timeout=5,
            )
        except (OSError, subprocess.TimeoutExpired):
            continue
        if proc.returncode != 0:
            continue
        line = first_version_line(proc.stdout)
        if line:
            return line
    return ""


def first_version_line(text):
    for line in text.splitlines():
        line = line.strip()
        if line and "illegal option" not in line and "unrecognized option" not in line:
            return line[:120]
    return ""


if __name__ == "__main__":
    sys.exit(main())
