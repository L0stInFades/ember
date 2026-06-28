#!/usr/bin/env python3
"""Compare a DUT RVTRACE prefix against Spike commit logs.

This is a first external-ISS gate, not a full RVVI implementation. Spike starts
through its own boot stub, so this tool discards commits below the DUT RAM base
and then compares the DUT stream against Spike's committed instructions. Spike
does not emit a commit row for faulting instructions, so DUT TRAP rows are
handled by checking that the next Spike commit lands at the DUT trap target.
"""
import argparse
import csv
import re
import subprocess
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

COMMIT_RE = re.compile(
    r"core\s+\d+:\s+(\d+)\s+0x([0-9a-fA-F]+)\s+\(0x([0-9a-fA-F]+)\)(.*)"
)
XREG_RE = re.compile(r"\bx([0-9]+)\s+0x([0-9a-fA-F]+)")


def parse_int(text, base=0):
    try:
        return int(text, base)
    except ValueError:
        if base == 0:
            return int(text, 16)
        raise


def parse_hex(text):
    text = text.strip().lower()
    if text.startswith("0x"):
        text = text[2:]
    return int(text, 16)


def load_trace(path, max_rows, stop_before_pc):
    rows = []
    stopped_at = None
    with open(path, "r", encoding="ascii", newline="") as f:
        reader = csv.DictReader(f)
        if reader.fieldnames != FIELDS:
            raise ValueError(f"bad RVTRACE header: got {reader.fieldnames}, expected {FIELDS}")
        for line, row in enumerate(reader, 2):
            if row["event"] not in ("RET", "TRAP"):
                raise ValueError(f"{path}:{line}: bad RVTRACE event {row['event']!r}")
            pc = parse_hex(row["pc"])
            if stop_before_pc is not None and pc == stop_before_pc:
                stopped_at = pc
                break
            rows.append(
                {
                    "line": line,
                    "event": row["event"],
                    "pc": pc,
                    "instr": parse_hex(row["instr"]),
                    "priv": parse_int(row["priv"], 10),
                    "rd": parse_int(row["rd"], 10),
                    "wdata": parse_hex(row["wdata"]),
                    "next_pc": parse_hex(row["next_pc"]),
                    "cause": parse_hex(row["cause"]),
                    "tval": parse_hex(row["tval"]),
                }
            )
            if max_rows and len(rows) >= max_rows:
                break
    if not rows:
        raise ValueError(f"{path}: trace contains no rows")
    return rows, stopped_at


def run_spike(args, needed_rows):
    instructions = args.instructions
    if instructions is None:
        instructions = needed_rows + args.spike_slack
    cmd = [
        args.spike,
        f"--isa={args.isa}",
        f"--priv={args.priv}",
        f"-m{args.mem}",
        "--log-commits",
        f"--instructions={instructions}",
        args.elf,
    ]
    proc = subprocess.run(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=args.timeout,
    )
    if args.spike_log:
        with open(args.spike_log, "w", encoding="utf-8") as f:
            f.write(proc.stdout)
    if proc.returncode != 0:
        raise RuntimeError(
            f"Spike exited with {proc.returncode}; tail:\n" + "\n".join(proc.stdout.splitlines()[-20:])
        )
    return proc.stdout


def parse_spike_commits(text, base):
    commits = []
    for line in text.splitlines():
        match = COMMIT_RE.search(line)
        if not match:
            continue
        priv = int(match.group(1), 10)
        pc = int(match.group(2), 16) & 0xFFFFFFFF
        instr = int(match.group(3), 16) & 0xFFFFFFFF
        rest = match.group(4)
        if pc < base:
            continue
        rd = 0
        wdata = 0
        xmatch = XREG_RE.search(rest)
        if xmatch:
            rd = int(xmatch.group(1), 10)
            wdata = int(xmatch.group(2), 16) & 0xFFFFFFFF
            if rd == 0:
                wdata = 0
        commits.append({"pc": pc, "instr": instr, "priv": priv, "rd": rd, "wdata": wdata})
    return commits


def compare(trace_rows, spike_rows, stopped_at, max_errors):
    errors = []
    ret_rows = sum(1 for row in trace_rows if row["event"] == "RET")
    if len(spike_rows) < ret_rows:
        errors.append(f"Spike produced only {len(spike_rows)} comparable commits for {ret_rows} RET trace rows")
        return errors

    spike_idx = 0
    for idx, dut in enumerate(trace_rows, 1):
        if dut["event"] == "TRAP":
            if spike_idx >= len(spike_rows):
                errors.append(
                    f"row {idx} trace line {dut['line']}: no Spike commit at trap target "
                    f"0x{dut['next_pc']:08x} after DUT trap pc=0x{dut['pc']:08x}"
                )
            elif dut["next_pc"] != spike_rows[spike_idx]["pc"]:
                errors.append(
                    f"row {idx} trace line {dut['line']}: trap target mismatch "
                    f"dut_next=0x{dut['next_pc']:08x} spike_next=0x{spike_rows[spike_idx]['pc']:08x} "
                    f"cause=0x{dut['cause']:08x} tval=0x{dut['tval']:08x}"
                )
            if len(errors) >= max_errors:
                break
            continue

        spike = spike_rows[spike_idx]
        for field in ("pc", "instr", "priv", "rd", "wdata"):
            if dut[field] != spike[field]:
                errors.append(
                    f"row {idx} trace line {dut['line']}: {field} mismatch "
                    f"dut={format_value(field, dut[field])} spike={format_value(field, spike[field])}"
                )

        next_trace = trace_rows[idx] if idx < len(trace_rows) else None
        if next_trace is not None:
            if dut["next_pc"] != next_trace["pc"]:
                errors.append(
                    f"row {idx} trace line {dut['line']}: trace next_pc mismatch "
                    f"dut=0x{dut['next_pc']:08x} next_trace_pc=0x{next_trace['pc']:08x}"
                )
            if next_trace["event"] == "RET" and spike_idx + 1 < len(spike_rows):
                spike_next_pc = spike_rows[spike_idx + 1]["pc"]
                if dut["next_pc"] != spike_next_pc:
                    errors.append(
                        f"row {idx} trace line {dut['line']}: next_pc mismatch "
                        f"dut=0x{dut['next_pc']:08x} spike_next=0x{spike_next_pc:08x}"
                    )

        spike_idx += 1
        if len(errors) >= max_errors:
            break
    if stopped_at is not None and trace_rows[-1]["next_pc"] != stopped_at:
        errors.append(
            f"last compared row trace line {trace_rows[-1]['line']}: next_pc mismatch "
            f"dut=0x{trace_rows[-1]['next_pc']:08x} stopped_before=0x{stopped_at:08x}"
        )
    return errors


def format_value(field, value):
    if field in ("priv", "rd"):
        return str(value)
    return f"0x{value:08x}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--trace", required=True, help="DUT RVTRACE CSV")
    ap.add_argument("--elf", required=True, help="ELF image to run under Spike")
    ap.add_argument("--spike", default="spike", help="Spike executable")
    ap.add_argument("--spike-log", help="optional path to save raw Spike output")
    ap.add_argument("--base", default="0x80000000", help="DUT RAM base; Spike commits below this are ignored")
    ap.add_argument("--mem", default="0x80000000:0x200000", help="Spike memory map")
    ap.add_argument("--isa", default="RV32IMA", help="Spike --isa value")
    ap.add_argument("--priv", default="msu", help="Spike --priv value")
    ap.add_argument("--max-rows", type=int, default=0, help="compare only this many DUT rows; 0 means all rows")
    ap.add_argument("--stop-before-pc", help="stop comparing when this DUT PC is reached")
    ap.add_argument("--instructions", type=int, help="exact Spike instruction limit")
    ap.add_argument("--spike-slack", type=int, default=1024, help="extra Spike commits beyond DUT rows")
    ap.add_argument("--timeout", type=int, default=30, help="Spike timeout in seconds")
    ap.add_argument("--max-errors", type=int, default=20)
    args = ap.parse_args()

    try:
        base = parse_int(args.base)
        stop_before_pc = parse_int(args.stop_before_pc) if args.stop_before_pc else None
        trace_rows, stopped_at = load_trace(args.trace, args.max_rows, stop_before_pc)
        needed_commits = sum(1 for row in trace_rows if row["event"] == "RET")
        spike_output = run_spike(args, needed_commits)
        spike_rows = parse_spike_commits(spike_output, base)
        errors = compare(trace_rows, spike_rows, stopped_at, args.max_errors)
    except (OSError, RuntimeError, subprocess.TimeoutExpired, ValueError) as exc:
        print(f"SPIKE_TRACE_PREFIX: FAIL {exc}", file=sys.stderr)
        return 1

    if errors:
        print("SPIKE_TRACE_PREFIX: FAIL", file=sys.stderr)
        for error in errors:
            print(f"  {error}", file=sys.stderr)
        return 1

    compared = len(trace_rows)
    traps = sum(1 for row in trace_rows if row["event"] == "TRAP")
    print(
        "SPIKE_TRACE_PREFIX: PASS "
        f"rows={compared} ret={compared - traps} trap={traps} spike_commits={len(spike_rows)} "
        f"first_pc=0x{trace_rows[0]['pc']:08x} last_pc=0x{trace_rows[-1]['pc']:08x}"
        + (f" stopped_before=0x{stopped_at:08x}" if stopped_at is not None else "")
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
