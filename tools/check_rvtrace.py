#!/usr/bin/env python3
"""Validate the lightweight rvlinux RVTRACE CSV stream.

This is not a golden-ISS difftest. It is a strict sanity gate for the DUT-side
trace source that a future Spike/RVVI lockstep checker will consume.
"""
import argparse
import csv
import sys


FIELDS = [
    "event",
    "cycle",
    "pc",
    "instr",
    "priv",
    "rd",
    "wdata",
    "next_pc",
    "cause",
    "tval",
]


def parse_int(text, base=0):
    try:
        return int(text, base)
    except ValueError:
        if base == 0:
            return int(text, 16)
        raise


def parse_hex(text):
    s = text.strip().lower()
    if s.startswith("0x"):
        s = s[2:]
    return int(s, 16)


def load_hex(path):
    words = []
    with open(path, "r", encoding="ascii") as f:
        for lineno, line in enumerate(f, 1):
            s = line.strip()
            if not s:
                continue
            try:
                words.append(int(s, 16) & 0xFFFFFFFF)
            except ValueError as exc:
                raise ValueError(f"{path}:{lineno}: invalid hex word {s!r}") from exc
    return words


def fetch_raw32(words, base, pc):
    if pc < base:
        return None, "pc_below_base"
    byte_off = pc - base
    word_idx = byte_off >> 2
    half = (byte_off >> 1) & 1
    if word_idx >= len(words):
        return None, "pc_past_image"
    word = words[word_idx]
    lo16 = (word >> 16) & 0xFFFF if half else word & 0xFFFF
    if (lo16 & 0x3) != 0x3:
        return None, "compressed"
    if half:
        if word_idx + 1 >= len(words):
            return None, "pc_crosses_image"
        hi16 = words[word_idx + 1] & 0xFFFF
        return ((hi16 << 16) | lo16) & 0xFFFFFFFF, None
    return word & 0xFFFFFFFF, None


def fail(errors, msg):
    errors.append(msg)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--trace", required=True, help="RVTRACE CSV file")
    ap.add_argument("--hex", required=True, help="little-endian word hex image")
    ap.add_argument("--base", default="0x80000000", help="RAM base address")
    ap.add_argument("--min-ret", type=int, default=1, help="minimum RET rows")
    ap.add_argument("--no-trap", action="store_true", help="fail if TRAP rows appear")
    args = ap.parse_args()

    base = parse_int(args.base)
    words = load_hex(args.hex)
    errors = []
    ret_count = 0
    trap_count = 0
    compared_instr = 0
    skipped_compressed = 0
    last_cycle = None
    row_count = 0

    with open(args.trace, "r", encoding="ascii", newline="") as f:
        reader = csv.DictReader(f)
        if reader.fieldnames != FIELDS:
            fail(errors, f"bad header: got {reader.fieldnames}, expected {FIELDS}")
            print_errors(errors)
            return 1

        for row_count, row in enumerate(reader, 2):
            event = row["event"]
            if event not in ("RET", "TRAP"):
                fail(errors, f"line {row_count}: bad event {event!r}")
                continue

            try:
                cycle = parse_int(row["cycle"], 10)
                pc = parse_hex(row["pc"])
                instr = parse_hex(row["instr"])
                priv = parse_int(row["priv"], 10)
                rd = parse_int(row["rd"], 10)
                wdata = parse_hex(row["wdata"])
                next_pc = parse_hex(row["next_pc"])
                cause = parse_hex(row["cause"])
                tval = parse_hex(row["tval"])
            except ValueError as exc:
                fail(errors, f"line {row_count}: bad integer field: {exc}")
                continue

            if last_cycle is not None and cycle <= last_cycle:
                fail(errors, f"line {row_count}: non-increasing cycle {cycle} after {last_cycle}")
            last_cycle = cycle

            if priv not in (0, 1, 3):
                fail(errors, f"line {row_count}: invalid priv {priv}")
            if not 0 <= rd <= 31:
                fail(errors, f"line {row_count}: invalid rd {rd}")
            if (pc & 1) != 0:
                fail(errors, f"line {row_count}: unaligned pc 0x{pc:08x}")
            if (next_pc & 1) != 0:
                fail(errors, f"line {row_count}: unaligned next_pc 0x{next_pc:08x}")
            if rd == 0 and wdata != 0:
                fail(errors, f"line {row_count}: x0 write has nonzero wdata 0x{wdata:08x}")

            raw32, skip = fetch_raw32(words, base, pc)
            if raw32 is None:
                if skip == "compressed":
                    skipped_compressed += 1
                else:
                    fail(errors, f"line {row_count}: cannot fetch instruction at pc 0x{pc:08x}: {skip}")
            elif raw32 != instr:
                fail(
                    errors,
                    f"line {row_count}: instr mismatch pc=0x{pc:08x} trace=0x{instr:08x} image=0x{raw32:08x}",
                )
            else:
                compared_instr += 1

            if event == "RET":
                ret_count += 1
                if cause != 0 or tval != 0:
                    fail(errors, f"line {row_count}: RET has nonzero cause/tval")
            else:
                trap_count += 1

            if len(errors) >= 20:
                break

    if row_count == 0:
        fail(errors, "trace contains no data rows")
    if ret_count < args.min_ret:
        fail(errors, f"only {ret_count} RET rows, expected at least {args.min_ret}")
    if args.no_trap and trap_count:
        fail(errors, f"trace contains {trap_count} TRAP rows")
    if compared_instr == 0:
        fail(errors, "no 32-bit instructions were checked against the hex image")

    if errors:
        print_errors(errors)
        return 1

    print(
        "RVTRACE_CHECK: PASS "
        f"rows={row_count - 1} ret={ret_count} trap={trap_count} "
        f"instr_checked={compared_instr} compressed_skipped={skipped_compressed}"
    )
    return 0


def print_errors(errors):
    print("RVTRACE_CHECK: FAIL", file=sys.stderr)
    for msg in errors:
        print(f"  {msg}", file=sys.stderr)


if __name__ == "__main__":
    sys.exit(main())
