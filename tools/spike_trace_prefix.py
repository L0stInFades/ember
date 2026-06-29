#!/usr/bin/env python3
"""Compare a DUT RVTRACE prefix against Spike commit logs.

This is a first external-ISS gate, not a full RVVI implementation. Spike starts
through its own boot stub, so this tool discards commits below the DUT RAM base
and then compares the DUT stream against Spike's committed instructions. Spike
does not emit a commit row for faulting instructions, so DUT TRAP rows are
handled by checking that the next Spike commit lands at the DUT trap target. When
enabled, this tool also asks Spike for execution logs and compares each
non-terminal DUT TRAP row against the corresponding Spike exception pc, cause,
tval, and instr when Spike reports the faulting instruction. Terminal-trap mode
still matches the final Spike exception when Spike stops at the trap.
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
EXEC_RE = re.compile(r"core\s+\d+:\s+0x([0-9a-fA-F]+)\s+\(0x([0-9a-fA-F]+)\)")
EXCEPTION_RE = re.compile(r"core\s+\d+:\s+exception\s+(\S+),\s+epc\s+0x([0-9a-fA-F]+)")
TVAL_RE = re.compile(r"core\s+\d+:\s+tval\s+0x([0-9a-fA-F]+)")
XREG_RE = re.compile(r"\bx([0-9]+)\s+0x([0-9a-fA-F]+)")

EXCEPTION_CAUSES = {
    "trap_instruction_address_misaligned": 0,
    "trap_instruction_access_fault": 1,
    "trap_illegal_instruction": 2,
    "trap_breakpoint": 3,
    "trap_load_address_misaligned": 4,
    "trap_load_access_fault": 5,
    "trap_store_address_misaligned": 6,
    "trap_store_access_fault": 7,
    "trap_user_ecall": 8,
    "trap_supervisor_ecall": 9,
    "trap_machine_ecall": 11,
    "trap_instruction_page_fault": 12,
    "trap_load_page_fault": 13,
    "trap_store_page_fault": 15,
}

SYSCON_BASE = 0x11100000
SYSCON_PASS_CODE = 0x5555


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


def trace_row(row, line):
    return {
        "line": line,
        "event": row["event"],
        "pc": parse_hex(row["pc"]),
        "instr": parse_hex(row["instr"]),
        "priv": parse_int(row["priv"], 10),
        "rd": parse_int(row["rd"], 10),
        "wdata": parse_hex(row["wdata"]),
        "next_pc": parse_hex(row["next_pc"]),
        "cause": parse_hex(row["cause"]),
        "tval": parse_hex(row["tval"]),
    }


def load_trace(path, max_rows, stop_before_pc, stop_after_first_trap):
    rows = []
    stopped_at = None
    stopped_row = None
    with open(path, "r", encoding="ascii", newline="") as f:
        reader = csv.DictReader(f)
        if reader.fieldnames != FIELDS:
            raise ValueError(f"bad RVTRACE header: got {reader.fieldnames}, expected {FIELDS}")
        for line, row in enumerate(reader, 2):
            if row["event"] not in ("RET", "TRAP"):
                raise ValueError(f"{path}:{line}: bad RVTRACE event {row['event']!r}")
            parsed = trace_row(row, line)
            if stop_before_pc is not None and parsed["pc"] == stop_before_pc:
                stopped_at = parsed["pc"]
                stopped_row = parsed
                break
            rows.append(parsed)
            if stop_after_first_trap and row["event"] == "TRAP":
                break
            if max_rows and len(rows) >= max_rows:
                break
    if not rows:
        raise ValueError(f"{path}: trace contains no rows")
    return rows, stopped_at, stopped_row


def run_spike(args, needed_rows):
    instructions = args.instructions
    if instructions is None:
        instructions = needed_rows + args.spike_slack
    cmd = [
        args.spike,
        f"--isa={args.isa}",
        f"--priv={args.priv}",
        f"-m{args.mem}",
    ]
    if args.expect_terminal_trap or args.check_trap_exceptions:
        cmd.append("-l")
    cmd.extend(["--log-commits", f"--instructions={instructions}", args.elf])
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


def parse_spike_exceptions(text, _base):
    exceptions = []
    last_exec = None
    pending = None

    def append_pending():
        nonlocal pending
        if pending:
            exceptions.append(pending)
        pending = None

    for line in text.splitlines():
        exec_match = EXEC_RE.search(line)
        if exec_match:
            append_pending()
            last_exec = {
                "pc": int(exec_match.group(1), 16) & 0xFFFFFFFF,
                "instr": int(exec_match.group(2), 16) & 0xFFFFFFFF,
            }
            continue

        exception_match = EXCEPTION_RE.search(line)
        if exception_match:
            append_pending()
            name = exception_match.group(1)
            pending = {
                "name": name,
                "cause": EXCEPTION_CAUSES.get(name),
                "pc": int(exception_match.group(2), 16) & 0xFFFFFFFF,
                "instr": None,
                "tval": 0,
            }
            if last_exec and last_exec["pc"] == pending["pc"]:
                pending["instr"] = last_exec["instr"]
            continue

        if pending:
            tval_match = TVAL_RE.search(line)
            if tval_match:
                pending["tval"] = int(tval_match.group(1), 16) & 0xFFFFFFFF
                append_pending()
    append_pending()
    return exceptions


def parse_spike_exception(text, base):
    exceptions = parse_spike_exceptions(text, base)
    return exceptions[0] if exceptions else None


def compare(trace_rows, spike_rows, stopped_at, max_errors, terminal_trap, trap_exceptions=None):
    errors = []
    ret_rows = sum(1 for row in trace_rows if row["event"] == "RET")
    if len(spike_rows) < ret_rows:
        errors.append(f"Spike produced only {len(spike_rows)} comparable commits for {ret_rows} RET trace rows")
        return errors

    spike_idx = 0
    trap_exception_idx = 0
    for idx, dut in enumerate(trace_rows, 1):
        if dut["event"] == "TRAP":
            if terminal_trap and idx == len(trace_rows):
                continue
            if trap_exceptions is not None:
                if trap_exception_idx >= len(trap_exceptions):
                    errors.append(
                        f"row {idx} trace line {dut['line']}: Spike logged only "
                        f"{len(trap_exceptions)} comparable exceptions"
                    )
                else:
                    spike_exception = trap_exceptions[trap_exception_idx]
                    fields = ("pc", "cause", "tval")
                    if spike_exception.get("instr") is not None:
                        fields = ("pc", "instr", "cause", "tval")
                    for field in fields:
                        if spike_exception.get(field) is None:
                            errors.append(
                                f"row {idx} trace line {dut['line']}: Spike exception did not report {field}"
                            )
                        elif dut[field] != spike_exception[field]:
                            errors.append(
                                f"row {idx} trace line {dut['line']}: trap {field} mismatch "
                                f"dut={format_value(field, dut[field])} "
                                f"spike={format_value(field, spike_exception[field])}"
                            )
                trap_exception_idx += 1
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


def compare_terminal_trap(trace_rows, spike_exception):
    if trace_rows[-1]["event"] != "TRAP":
        return ["terminal trap mode requires the compared DUT prefix to end at a TRAP row"]
    if spike_exception is None:
        return ["Spike did not log a terminal exception"]
    dut = trace_rows[-1]
    errors = []
    for field in ("pc", "instr", "cause", "tval"):
        if spike_exception.get(field) is None:
            errors.append(f"Spike terminal exception did not report {field}")
        elif dut[field] != spike_exception[field]:
            errors.append(
                f"terminal trap {field} mismatch "
                f"dut={format_value(field, dut[field])} spike={format_value(field, spike_exception[field])}"
            )
    return errors


def compare_device_complete(trace_rows, stopped_row):
    if stopped_row is None:
        return ["device-complete mode requires --stop-before-pc to capture the completion store"]
    if len(trace_rows) < 2:
        return ["device-complete mode requires at least two rows before the completion store"]
    errors = []
    pass_code = trace_rows[-2]
    syscon_addr = trace_rows[-1]
    if pass_code["event"] != "RET" or pass_code["wdata"] != SYSCON_PASS_CODE:
        errors.append(
            "device-complete pass-code row mismatch "
            f"line={pass_code['line']} wdata=0x{pass_code['wdata']:08x}"
        )
    if syscon_addr["event"] != "RET" or syscon_addr["wdata"] != SYSCON_BASE:
        errors.append(
            "device-complete syscon-address row mismatch "
            f"line={syscon_addr['line']} wdata=0x{syscon_addr['wdata']:08x}"
        )
    if stopped_row["event"] != "RET":
        errors.append(f"device-complete row must retire, got {stopped_row['event']}")
    if (stopped_row["instr"] & 0x7F) != 0x23:
        errors.append(f"device-complete row is not a store instr=0x{stopped_row['instr']:08x}")
    if stopped_row["priv"] != 3:
        errors.append(f"device-complete store must retire in M-mode, got priv={stopped_row['priv']}")
    if stopped_row["rd"] != 0 or stopped_row["wdata"] != 0:
        errors.append(
            "device-complete store should not write an integer register "
            f"rd={stopped_row['rd']} wdata=0x{stopped_row['wdata']:08x}"
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
    ap.add_argument("--stop-after-first-trap", action="store_true", help="stop after the first DUT TRAP row")
    ap.add_argument(
        "--expect-terminal-trap",
        action="store_true",
        help="expect Spike to stop at the final DUT TRAP and compare its logged exception",
    )
    ap.add_argument(
        "--check-trap-exceptions",
        action="store_true",
        help="run Spike with execution logs and compare non-terminal DUT TRAP rows against Spike exceptions",
    )
    ap.add_argument(
        "--expect-device-complete",
        action="store_true",
        help="expect --stop-before-pc to point at a clean syscon poweroff store",
    )
    ap.add_argument("--instructions", type=int, help="exact Spike instruction limit")
    ap.add_argument("--spike-slack", type=int, default=1024, help="extra Spike commits beyond DUT rows")
    ap.add_argument("--timeout", type=int, default=30, help="Spike timeout in seconds")
    ap.add_argument("--max-errors", type=int, default=20)
    args = ap.parse_args()

    try:
        base = parse_int(args.base)
        stop_before_pc = parse_int(args.stop_before_pc) if args.stop_before_pc else None
        stop_after_first_trap = args.stop_after_first_trap or args.expect_terminal_trap
        trace_rows, stopped_at, stopped_row = load_trace(args.trace, args.max_rows, stop_before_pc, stop_after_first_trap)
        needed_commits = sum(1 for row in trace_rows if row["event"] == "RET")
        spike_output = run_spike(args, needed_commits)
        spike_rows = parse_spike_commits(spike_output, base)
        trap_exceptions = parse_spike_exceptions(spike_output, base) if args.check_trap_exceptions else None
        errors = compare(
            trace_rows,
            spike_rows,
            stopped_at,
            args.max_errors,
            args.expect_terminal_trap,
            trap_exceptions,
        )
        if args.expect_terminal_trap:
            errors.extend(compare_terminal_trap(trace_rows, parse_spike_exception(spike_output, base)))
        if args.expect_device_complete:
            errors.extend(compare_device_complete(trace_rows, stopped_row))
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
    checked_traps = sum(
        1
        for idx, row in enumerate(trace_rows, 1)
        if row["event"] == "TRAP" and not (args.expect_terminal_trap and idx == len(trace_rows))
    )
    print(
        "SPIKE_TRACE_PREFIX: PASS "
        f"rows={compared} ret={compared - traps} trap={traps} spike_commits={len(spike_rows)} "
        f"first_pc=0x{trace_rows[0]['pc']:08x} last_pc=0x{trace_rows[-1]['pc']:08x}"
        + (f" stopped_before=0x{stopped_at:08x}" if stopped_at is not None else "")
        + (f" trap_exceptions={checked_traps}" if args.check_trap_exceptions else "")
        + (" terminal_trap=1" if args.expect_terminal_trap else "")
        + (" device_complete=1" if args.expect_device_complete else "")
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
