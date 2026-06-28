#!/usr/bin/env python3
"""Audit retained RVTRACE CSV logs against the local structural and ref-model checks."""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path


DEFAULT_TESTS = [
    "isa",
    "amotest",
    "mmu",
    "ctest",
    "shtest",
    "mtest",
    "utrap",
    "mprv",
    "mxr",
    "upage",
    "ifault",
    "wpfault",
    "sum",
    "badpte",
    "superpage",
    "amo_mmu",
]
TRAP_ALLOWED = {
    "mmu",
    "utrap",
    "mprv",
    "mxr",
    "upage",
    "ifault",
    "wpfault",
    "sum",
    "badpte",
    "superpage",
    "amo_mmu",
}
EXPECT_M_PRIV = {"isa", "amotest", "ctest", "shtest", "mtest"}
DEFAULT_COVERAGE_FLOORS = {
    "isa": {"retired": 600, "amos": 3},
    "amotest": {"retired": 450, "amos": 2},
    "mmu": {"retired": 5000, "traps": 3, "pte_updates": 1, "priv_switches": 2},
    "ctest": {"retired": 2000},
    "shtest": {"retired": 200},
    "mtest": {"retired": 200},
    "utrap": {"retired": 150, "traps": 1, "priv_switches": 3},
    "mprv": {"retired": 5000, "traps": 1, "pte_updates": 1},
    "mxr": {"retired": 5000, "traps": 2, "pte_updates": 1},
    "upage": {"retired": 9000, "traps": 3, "pte_updates": 2, "priv_switches": 6},
    "ifault": {"retired": 9000, "traps": 2, "priv_switches": 2},
    "wpfault": {"retired": 5000, "traps": 2, "pte_updates": 2, "priv_switches": 2},
    "sum": {"retired": 5000, "traps": 3, "pte_updates": 2, "priv_switches": 2},
    "badpte": {"retired": 5000, "traps": 3, "priv_switches": 2},
    "superpage": {"retired": 3000, "traps": 3, "priv_switches": 2},
    "amo_mmu": {"retired": 5000, "traps": 2, "amos": 1, "pte_updates": 3, "priv_switches": 2},
}
REF_RE = re.compile(
    r"RVTRACE_REF: PASS rows=(?P<rows>\d+) retired=(?P<retired>\d+) traps=(?P<traps>\d+) "
    r"priv_switches=(?P<priv_switches>\d+) writes=(?P<writes>\d+) stores=(?P<stores>\d+) "
    r"amos=(?P<amos>\d+) pte_updates=(?P<pte_updates>\d+) "
    r"uart_writes=(?P<uart_writes>\d+) syscon_writes=(?P<syscon_writes>\d+) "
    r"halted=(?P<halted>\d+) exit=(?P<exit>\S+)"
)
CHECK_RE = re.compile(
    r"RVTRACE_CHECK: PASS rows=(?P<rows>\d+) ret=(?P<ret>\d+) trap=(?P<trap>\d+) "
    r"instr_checked=(?P<instr_checked>\d+) compressed_skipped=(?P<compressed_skipped>\d+)"
)


def run(cmd):
    proc = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if proc.returncode != 0:
        raise RuntimeError("command failed: " + " ".join(cmd) + "\n" + proc.stdout)
    return proc.stdout


def parse_ref_summary(text, test):
    match = REF_RE.search(text)
    if not match:
        raise RuntimeError(f"{test}: missing RVTRACE_REF PASS summary\n{text}")
    data = {key: int(value) for key, value in match.groupdict().items() if key != "exit"}
    data["exit"] = match.group("exit")
    return data


def parse_check_summary(text, test):
    match = CHECK_RE.search(text)
    if not match:
        raise RuntimeError(f"{test}: missing RVTRACE_CHECK PASS summary\n{text}")
    return {key: int(value) for key, value in match.groupdict().items()}


def parse_floor(text):
    try:
        test, rest = text.split(":", 1)
        metric, value = rest.split("=", 1)
        value = int(value, 0)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("expected TEST:METRIC=MIN") from exc
    if not test or not metric:
        raise argparse.ArgumentTypeError("expected TEST:METRIC=MIN")
    if value < 0:
        raise argparse.ArgumentTypeError("MIN must be non-negative")
    return test, metric, value


def merge_coverage_floors(use_defaults, floor_args):
    floors = {}
    if use_defaults:
        floors = {test: dict(metrics) for test, metrics in DEFAULT_COVERAGE_FLOORS.items()}
    for test, metric, value in floor_args:
        floors.setdefault(test, {})[metric] = value
    return floors


def check_coverage_floors(report):
    tests = {item["test"]: item for item in report["tests"]}
    checks = []
    failures = []
    for test, metrics in sorted(report["coverage_floors"].items()):
        item = tests.get(test)
        for metric, minimum in sorted(metrics.items()):
            value = item.get(metric) if item else None
            passed = value is not None and value >= minimum
            checks.append(
                {
                    "test": test,
                    "metric": metric,
                    "value": value,
                    "min": minimum,
                    "status": "pass" if passed else "fail",
                }
            )
            if not passed:
                got = "missing" if value is None else str(value)
                failures.append(f"{test}:{metric}={got} below {minimum}")
    return checks, failures


def write_artifacts(json_path, md_path, report):
    if json_path:
        path = Path(json_path)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    if md_path:
        path = Path(md_path)
        path.parent.mkdir(parents=True, exist_ok=True)
        totals = report["totals"]
        lines = [
            "# RVTRACE Coverage",
            "",
            f"- status: `{report['status']}`",
            f"- logdir: `{report['logdir']}`",
            f"- tests: `{len(report['tests'])}`",
            (
                "- totals: "
                f"rows={totals['rows']} retired={totals['retired']} traps={totals['traps']} "
                f"amos={totals['amos']} pte_updates={totals['pte_updates']} "
                f"priv_switches={totals['priv_switches']}"
            ),
            "",
            "## Thresholds",
        ]
        for key, minimum in report["thresholds"].items():
            value = totals.get(key, 0)
            state = "PASS" if value >= minimum else "FAIL"
            lines.append(f"- `{key}`: {value} >= {minimum} `{state}`")
        if report["coverage_floor_checks"]:
            lines += [
                "",
                "## Per-Test Floors",
                "",
                "| Test | Metric | Value | Floor | Status |",
                "|---|---|---:|---:|---:|",
            ]
            for item in report["coverage_floor_checks"]:
                value = "missing" if item["value"] is None else item["value"]
                lines.append(
                    f"| `{item['test']}` | `{item['metric']}` | `{value}` | "
                    f"`{item['min']}` | `{item['status']}` |"
                )
        if report["tests"]:
            lines += [
                "",
                "## Per Test",
                "",
                "| Test | Rows | Retired | Trap | AMO | PTE | Priv | Stores | Writes | UART | Syscon |",
                "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
            ]
            for item in report["tests"]:
                lines.append(
                    "| `{test}` | {rows} | {retired} | {traps} | {amos} | {pte_updates} | "
                    "{priv_switches} | {stores} | {writes} | {uart_writes} | {syscon_writes} |".format(**item)
                )
        if report["failures"]:
            lines += ["", "## Failures"]
            for failure in report["failures"]:
                lines.append(f"- `{failure}`")
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--logdir", required=True, help="directory containing rvtrace_<test>.csv files")
    ap.add_argument("--tests", nargs="+", default=DEFAULT_TESTS, help="tests to audit")
    ap.add_argument("--base", default="0x80000000", help="RAM base address")
    ap.add_argument("--min-total-traps", type=int, default=25)
    ap.add_argument("--min-total-amos", type=int, default=6)
    ap.add_argument("--min-total-pte-updates", type=int, default=12)
    ap.add_argument("--min-total-priv-switches", type=int, default=25)
    ap.add_argument(
        "--no-default-coverage-floors",
        action="store_true",
        help="disable built-in per-test coverage floors",
    )
    ap.add_argument(
        "--coverage-floor",
        action="append",
        default=[],
        type=parse_floor,
        help="add or override a floor as TEST:METRIC=MIN",
    )
    ap.add_argument("--json", help="write machine-readable per-test coverage")
    ap.add_argument("--markdown", help="write human-readable per-test coverage")
    args = ap.parse_args()

    root = Path(__file__).resolve().parents[1]
    logdir = Path(args.logdir)
    thresholds = {
        "traps": args.min_total_traps,
        "amos": args.min_total_amos,
        "pte_updates": args.min_total_pte_updates,
        "priv_switches": args.min_total_priv_switches,
    }
    report = {
        "schema_version": 1,
        "status": "fail",
        "logdir": str(logdir),
        "tests": [],
        "totals": {
            "rows": 0,
            "retired": 0,
            "traps": 0,
            "amos": 0,
            "pte_updates": 0,
            "priv_switches": 0,
            "uart_writes": 0,
            "syscon_writes": 0,
        },
        "thresholds": thresholds,
        "coverage_floors": merge_coverage_floors(not args.no_default_coverage_floors, args.coverage_floor),
        "coverage_floor_checks": [],
        "failures": [],
    }
    if not logdir.is_dir():
        report["failures"].append(f"missing logdir {logdir}")
        write_artifacts(args.json, args.markdown, report)
        print(f"RVTRACE_AUDIT: FAIL missing logdir {logdir}", file=sys.stderr)
        return 1

    totals = report["totals"]
    failures = []

    for test in args.tests:
        trace = logdir / f"rvtrace_{test}.csv"
        hex_path = root / "tests" / f"{test}.hex"
        if not trace.is_file() or trace.stat().st_size == 0:
            failures.append(f"{test}: missing trace {trace}")
            continue
        if not hex_path.is_file() or hex_path.stat().st_size == 0:
            failures.append(f"{test}: missing hex {hex_path}")
            continue

        check_cmd = [
            sys.executable,
            str(root / "tools" / "check_rvtrace.py"),
            "--trace",
            str(trace),
            "--hex",
            str(hex_path),
            "--base",
            args.base,
            "--min-ret",
            "1",
        ]
        if test not in TRAP_ALLOWED:
            check_cmd.append("--no-trap")

        ref_cmd = [
            sys.executable,
            str(root / "tools" / "rvtrace_ref.py"),
            "--trace",
            str(trace),
            "--hex",
            str(hex_path),
            "--base",
            args.base,
        ]
        if test in EXPECT_M_PRIV:
            ref_cmd += ["--expect-priv", "3"]

        try:
            check_out = run(check_cmd)
            ref_out = run(ref_cmd)
            check_data = parse_check_summary(check_out, test)
            data = parse_ref_summary(ref_out, test)
        except RuntimeError as exc:
            failures.append(str(exc))
            continue

        if data["halted"] != 1 or data["exit"] != "0":
            failures.append(f"{test}: ref did not halt cleanly: halted={data['halted']} exit={data['exit']}")
        for key in totals:
            totals[key] += data[key]
        report["tests"].append(
            {
                "test": test,
                "trace": str(trace),
                "hex": str(hex_path),
                "rows": data["rows"],
                "retired": data["retired"],
                "traps": data["traps"],
                "priv_switches": data["priv_switches"],
                "writes": data["writes"],
                "stores": data["stores"],
                "amos": data["amos"],
                "pte_updates": data["pte_updates"],
                "uart_writes": data["uart_writes"],
                "syscon_writes": data["syscon_writes"],
                "halted": data["halted"],
                "exit": data["exit"],
                "check": check_data,
            }
        )
        print(f"RVTRACE_AUDIT_TEST: PASS {test} " + check_out.strip() + " " + ref_out.strip())

    if failures:
        report["failures"] = failures
        write_artifacts(args.json, args.markdown, report)
        print("RVTRACE_AUDIT: FAIL", file=sys.stderr)
        for failure in failures:
            print(f"  {failure}", file=sys.stderr)
        return 1

    for key, minimum in thresholds.items():
        if totals[key] < minimum:
            failure = f"total {key}={totals[key]} below {minimum}"
            report["failures"].append(failure)
            write_artifacts(args.json, args.markdown, report)
            print(f"RVTRACE_AUDIT: FAIL {failure}", file=sys.stderr)
            return 1

    floor_checks, floor_failures = check_coverage_floors(report)
    report["coverage_floor_checks"] = floor_checks
    if floor_failures:
        report["failures"] = floor_failures
        write_artifacts(args.json, args.markdown, report)
        print("RVTRACE_AUDIT: FAIL per-test coverage floor", file=sys.stderr)
        for failure in floor_failures:
            print(f"  {failure}", file=sys.stderr)
        return 1

    report["status"] = "pass"
    write_artifacts(args.json, args.markdown, report)
    print(
        "RVTRACE_AUDIT: PASS "
        f"tests={len(args.tests)} rows={totals['rows']} retired={totals['retired']} "
        f"traps={totals['traps']} amos={totals['amos']} "
        f"pte_updates={totals['pte_updates']} priv_switches={totals['priv_switches']} "
        f"uart_writes={totals['uart_writes']} syscon_writes={totals['syscon_writes']} "
        f"logdir={logdir}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
