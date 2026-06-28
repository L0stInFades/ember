#!/usr/bin/env python3
"""Check that retained CI evidence is present and healthy."""

import argparse
import json
from pathlib import Path


DEFAULT_P1_ACT4_SPIKE_GROUPS = [
    "I",
    "M",
    "Zmmul",
    "Zaamo",
    "Zalrsc",
    "Zca",
    "Zicsr",
    "Zicntr",
    "Zifencei",
    "Zihintpause",
    "Zihintntl",
    "ZihintntlZca",
]

DEFAULT_P1_EXTERNAL_TESTS = [
    "isa",
    "amotest",
    "ctest",
    "shtest",
    "mtest",
    "mmu",
    "utrap",
    "misalign",
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


def load_json(path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise SystemExit(f"missing or unreadable JSON: {path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise SystemExit(f"invalid JSON: {path}: {exc}") from exc


def load_history(path):
    records = []
    errors = []
    if not path.is_file():
        return records, [f"missing history file: {path}"]
    for lineno, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
        line = line.strip()
        if not line:
            continue
        try:
            item = json.loads(line)
        except json.JSONDecodeError as exc:
            errors.append(f"{path}:{lineno}: {exc}")
            continue
        if isinstance(item, dict) and item.get("logdir"):
            records.append(item)
        else:
            errors.append(f"{path}:{lineno}: missing logdir")
    return records, errors


def recent_summary(dashboard, logdir):
    for item in dashboard.get("recent", []):
        if item.get("logdir") == logdir:
            return item
    return None


def load_summary(dashboard, logdir):
    if not logdir:
        return None, None
    path = Path(logdir) / "summary.json"
    if path.is_file():
        data = load_json(path)
        if isinstance(data, dict):
            return data, str(path)
    item = recent_summary(dashboard, logdir)
    if item:
        return item, "dashboard.recent"
    return None, str(path)


def latest_item(items):
    return items[-1] if items else None


def coverage_floor_summary(coverage):
    checks = coverage.get("coverage_floor_checks", [])
    failed = sum(1 for item in checks if item.get("status") != "pass")
    return {"pass": len(checks) - failed, "fail": failed, "total": len(checks)}


def add_check(checks, name, ok, detail, evidence=None):
    checks.append(
        {
            "name": name,
            "status": "pass" if ok else "fail",
            "detail": detail,
            "evidence": evidence,
        }
    )


def check_min(checks, name, value, minimum, unit="", evidence=None):
    suffix = f" {unit}" if unit else ""
    add_check(
        checks,
        name,
        value >= minimum,
        f"{value}{suffix} >= {minimum}{suffix}",
        evidence=evidence,
    )


def check_max(checks, name, value, maximum, unit="", evidence=None):
    suffix = f" {unit}" if unit else ""
    add_check(
        checks,
        name,
        value <= maximum,
        f"{value}{suffix} <= {maximum}{suffix}",
        evidence=evidence,
    )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dashboard", default="logs/ci-dashboard.json", help="dashboard JSON to check")
    ap.add_argument("--history-jsonl", help="history JSONL path; defaults to dashboard history path")
    ap.add_argument("--json", help="output health JSON path")
    ap.add_argument("--markdown", help="output health Markdown path")
    ap.add_argument("--min-runs", type=int, default=1)
    ap.add_argument("--min-history-runs", type=int, default=1)
    ap.add_argument("--min-pass-streak", type=int, default=1)
    ap.add_argument("--min-p0-linux-runs", type=int, default=1)
    ap.add_argument("--max-p0-linux-login-cycles", type=int, default=9_000_000_000)
    ap.add_argument("--min-p1-external-runs", type=int, default=1)
    ap.add_argument("--min-p1-external-tests", type=int, default=17)
    ap.add_argument(
        "--require-p1-external-tests",
        default=",".join(DEFAULT_P1_EXTERNAL_TESTS),
        help="comma-separated exact P1 external Spike-prefix test list required for the latest P1 evidence; empty disables",
    )
    ap.add_argument("--min-p1-act4-spike-tests", type=int, default=106)
    ap.add_argument(
        "--require-p1-act4-spike-groups",
        default=",".join(DEFAULT_P1_ACT4_SPIKE_GROUPS),
        help="comma-separated exact ACT/Spike group list required for the latest P1 evidence; empty disables",
    )
    ap.add_argument("--min-p1-external-trap-exceptions", type=int, default=23)
    ap.add_argument("--min-p1-external-terminal-traps", type=int, default=1)
    ap.add_argument("--min-rvtrace-runs", type=int, default=1)
    ap.add_argument("--min-rvtrace-coverage-runs", type=int, default=1)
    ap.add_argument("--min-pnr-runs", type=int, default=1)
    ap.add_argument("--min-pnr-fmax-mhz", type=float, default=40.0)
    ap.add_argument("--min-pnr-target-mhz", type=float, default=40.0)
    ap.add_argument("--min-rvtrace-tests", type=int, default=17)
    ap.add_argument("--min-rvtrace-retired", type=int, default=71000)
    ap.add_argument("--min-rvtrace-traps", type=int, default=27)
    ap.add_argument("--min-rvtrace-amos", type=int, default=6)
    ap.add_argument("--min-rvtrace-pte-updates", type=int, default=12)
    ap.add_argument("--min-rvtrace-priv-switches", type=int, default=25)
    ap.add_argument("--min-rvtrace-floor-checks", type=int, default=48)
    ap.add_argument("--no-require-p0-linux", action="store_true")
    ap.add_argument("--no-require-p1-external", action="store_true")
    ap.add_argument("--no-require-rvtrace", action="store_true")
    ap.add_argument("--no-require-rvtrace-coverage", action="store_true")
    ap.add_argument("--no-require-pnr", action="store_true")
    args = ap.parse_args()

    dashboard_path = Path(args.dashboard)
    dashboard = load_json(dashboard_path)
    if not isinstance(dashboard, dict):
        raise SystemExit(f"{dashboard_path}: expected JSON object")

    history_path = Path(args.history_jsonl or dashboard.get("history", {}).get("path") or "logs/ci-history.jsonl")
    history_records, history_errors = load_history(history_path)
    history = dashboard.get("history", {}) if isinstance(dashboard.get("history"), dict) else {}
    checks = []

    errors = dashboard.get("errors", [])
    add_check(checks, "dashboard parse warnings", not errors, f"errors={len(errors)}", str(dashboard_path))
    add_check(
        checks,
        "history parse warnings",
        not history_errors,
        f"errors={len(history_errors)}",
        str(history_path),
    )
    check_min(checks, "dashboard runs", int(dashboard.get("runs", 0)), args.min_runs, evidence=str(dashboard_path))
    check_min(
        checks,
        "history records",
        len(history_records),
        args.min_history_runs,
        evidence=str(history_path),
    )
    if "runs" in history:
        add_check(
            checks,
            "history run count matches file",
            int(history.get("runs", 0)) == len(history_records),
            f"dashboard={history.get('runs', 0)} file={len(history_records)}",
            str(history_path),
        )
    check_min(
        checks,
        "current pass streak",
        int(history.get("current_pass_streak", 0)),
        args.min_pass_streak,
        evidence=str(history_path),
    )

    if not args.no_require_p0_linux:
        check_min(
            checks,
            "P0 Linux evidence runs",
            int(history.get("p0_linux_runs", 0)),
            args.min_p0_linux_runs,
            evidence=str(history_path),
        )
        if "p0_linux_login_runs" in history:
            check_min(
                checks,
                "P0 Linux login evidence runs",
                int(history.get("p0_linux_login_runs", 0)),
                args.min_p0_linux_runs,
                evidence=str(history_path),
            )
        p0_logdir = dashboard.get("latest_p0_linux")
        add_check(checks, "latest P0 Linux evidence exists", bool(p0_logdir), f"logdir={p0_logdir or 'none'}")
        p0_summary, p0_source = load_summary(dashboard, p0_logdir)
        add_check(
            checks,
            "latest P0 Linux summary",
            bool(p0_summary and p0_summary.get("p0_linux_passes")),
            f"source={p0_source or 'none'}",
            p0_source,
        )
        if p0_summary:
            add_check(
                checks,
                "latest P0 Linux run passed",
                p0_summary.get("status") == "pass",
                f"status={p0_summary.get('status', 'unknown')}",
                p0_source,
            )
            latest_p0_login = next(
                (
                    item
                    for item in reversed(p0_summary.get("p0_linux_passes", []))
                    if item.get("mode") == "login"
                ),
                None,
            )
            add_check(
                checks,
                "latest P0 Linux login evidence",
                bool(latest_p0_login),
                f"mode={latest_p0_login.get('mode') if latest_p0_login else 'missing'}",
                p0_source,
            )
            if latest_p0_login:
                cycles = latest_p0_login.get("cycles")
                add_check(
                    checks,
                    "P0 Linux login cycles recorded",
                    isinstance(cycles, int),
                    f"cycles={cycles if cycles is not None else 'missing'}",
                    p0_source,
                )
                if isinstance(cycles, int):
                    check_max(
                        checks,
                        "P0 Linux login cycles",
                        cycles,
                        args.max_p0_linux_login_cycles,
                        "cycles",
                        evidence=p0_source,
                    )

    if not args.no_require_p1_external:
        check_min(
            checks,
            "P1 external evidence runs",
            int(history.get("p1_external_runs", 0)),
            args.min_p1_external_runs,
            evidence=str(history_path),
        )
        p1_logdir = dashboard.get("latest_p1_external")
        add_check(checks, "latest P1 external evidence exists", bool(p1_logdir), f"logdir={p1_logdir or 'none'}")
        p1_summary, p1_source = load_summary(dashboard, p1_logdir)
        latest_p1 = latest_item(p1_summary.get("p1_external", [])) if p1_summary else None
        latest_act4 = latest_item(p1_summary.get("act4_spike", [])) if p1_summary else None
        add_check(checks, "latest P1 external summary", bool(latest_p1), f"source={p1_source or 'none'}", p1_source)
        if latest_p1:
            add_check(
                checks,
                "latest P1 external run passed",
                latest_p1.get("status") == "pass",
                f"status={latest_p1.get('status', 'unknown')}",
                p1_source,
            )
            check_min(
                checks,
                "P1 external tests",
                int(latest_p1.get("test_count", 0)),
                args.min_p1_external_tests,
                evidence=p1_source,
            )
            required_p1_tests = [
                test.strip()
                for test in args.require_p1_external_tests.split(",")
                if test.strip()
            ]
            if required_p1_tests:
                actual_p1_tests = [item.get("test") for item in latest_p1.get("tests", []) if item.get("test")]
                add_check(
                    checks,
                    "P1 external test list",
                    actual_p1_tests == required_p1_tests,
                    "tests={actual} required={required}".format(
                        actual=",".join(actual_p1_tests) or "missing",
                        required=",".join(required_p1_tests),
                    ),
                    p1_source,
                )
                dashboard_p1_tests = dashboard.get("latest_p1_external_tests") or []
                add_check(
                    checks,
                    "P1 external dashboard test list",
                    dashboard_p1_tests == required_p1_tests,
                    "tests={actual} required={required}".format(
                        actual=",".join(dashboard_p1_tests) or "missing",
                        required=",".join(required_p1_tests),
                    ),
                    str(dashboard_path),
                )
                history_p1 = history.get("p1_external") if isinstance(history.get("p1_external"), dict) else {}
                history_p1_tests = history_p1.get("latest_tests") or []
                add_check(
                    checks,
                    "P1 external history test list",
                    history_p1_tests == required_p1_tests,
                    "tests={actual} required={required}".format(
                        actual=",".join(history_p1_tests) or "missing",
                        required=",".join(required_p1_tests),
                    ),
                    str(history_path),
                )
            check_min(
                checks,
                "P1 external trap exceptions",
                int(latest_p1.get("trap_exceptions", 0)),
                args.min_p1_external_trap_exceptions,
                evidence=p1_source,
            )
            check_min(
                checks,
                "P1 external terminal traps",
                int(latest_p1.get("terminal_traps", 0)),
                args.min_p1_external_terminal_traps,
                evidence=p1_source,
            )
        add_check(
            checks,
            "latest P1 ACT/Spike summary",
            bool(latest_act4),
            f"source={p1_source or 'none'}",
            p1_source,
        )
        if latest_act4:
            add_check(
                checks,
                "latest P1 ACT/Spike smoke passed",
                latest_act4.get("status") == "pass" and int(latest_act4.get("failed", 0)) == 0,
                f"status={latest_act4.get('status', 'unknown')} failed={latest_act4.get('failed', 0)}",
                p1_source,
            )
            check_min(
                checks,
                "P1 ACT/Spike smoke tests",
                int(latest_act4.get("tests", 0)),
                args.min_p1_act4_spike_tests,
                evidence=p1_source,
            )
            add_check(
                checks,
                "P1 ACT/Spike smoke all tests passed",
                int(latest_act4.get("passed", 0)) == int(latest_act4.get("tests", 0)),
                f"passed={latest_act4.get('passed', 0)} tests={latest_act4.get('tests', 0)}",
                p1_source,
            )
            required_act4_groups = [
                group.strip()
                for group in args.require_p1_act4_spike_groups.split(",")
                if group.strip()
            ]
            if required_act4_groups:
                actual_act4_groups = latest_act4.get("groups") or []
                add_check(
                    checks,
                    "P1 ACT/Spike smoke groups",
                    actual_act4_groups == required_act4_groups,
                    "groups={actual} required={required}".format(
                        actual=",".join(actual_act4_groups) or "missing",
                        required=",".join(required_act4_groups),
                    ),
                    p1_source,
                )

    if not args.no_require_pnr:
        pnr = dashboard.get("best_pnr") or {}
        pnr_history = history.get("pnr") or {}
        check_min(
            checks,
            "PnR evidence runs",
            int(pnr_history.get("runs", 0)),
            args.min_pnr_runs,
            evidence=str(history_path),
        )
        add_check(checks, "best PnR evidence exists", bool(pnr), f"logdir={pnr.get('logdir', 'none')}")
        if pnr:
            check_min(
                checks,
                "best PnR Fmax",
                float(pnr.get("fmax_mhz") or 0.0),
                args.min_pnr_fmax_mhz,
                "MHz",
                evidence=pnr.get("logdir"),
            )
            check_min(
                checks,
                "best PnR target",
                float(pnr.get("target_mhz") or 0.0),
                args.min_pnr_target_mhz,
                "MHz",
                evidence=pnr.get("logdir"),
            )
            pnr_summary, pnr_source = load_summary(dashboard, pnr.get("logdir"))
            latest_pnr = latest_item(pnr_summary.get("pnr", [])) if pnr_summary else None
            add_check(
                checks,
                "best PnR summary",
                bool(latest_pnr),
                f"source={pnr_source or 'none'}",
                pnr_source,
            )
            if latest_pnr:
                add_check(
                    checks,
                    "best PnR completed",
                    bool(latest_pnr.get("program_finished")),
                    f"program_finished={bool(latest_pnr.get('program_finished'))}",
                    pnr_source,
                )

    trace_summary = None
    trace_source = None
    if not args.no_require_rvtrace:
        check_min(
            checks,
            "RVTRACE audit runs",
            int(history.get("rvtrace_runs", 0)),
            args.min_rvtrace_runs,
            evidence=str(history_path),
        )
        trace_logdir = dashboard.get("latest_rvtrace")
        add_check(checks, "latest RVTRACE audit exists", bool(trace_logdir), f"logdir={trace_logdir or 'none'}")
        trace_summary, trace_source = load_summary(dashboard, trace_logdir)
        latest_trace = latest_item(trace_summary.get("rvtrace_audits", [])) if trace_summary else None
        add_check(checks, "latest RVTRACE summary", bool(latest_trace), f"source={trace_source or 'none'}", trace_source)
        if latest_trace:
            check_min(checks, "RVTRACE tests", int(latest_trace.get("tests", 0)), args.min_rvtrace_tests, evidence=trace_source)
            check_min(
                checks,
                "RVTRACE retired",
                int(latest_trace.get("retired", 0)),
                args.min_rvtrace_retired,
                evidence=trace_source,
            )
            check_min(checks, "RVTRACE traps", int(latest_trace.get("traps", 0)), args.min_rvtrace_traps, evidence=trace_source)
            check_min(checks, "RVTRACE AMOs", int(latest_trace.get("amos", 0)), args.min_rvtrace_amos, evidence=trace_source)
            check_min(
                checks,
                "RVTRACE PTE updates",
                int(latest_trace.get("pte_updates", 0)),
                args.min_rvtrace_pte_updates,
                evidence=trace_source,
            )
            check_min(
                checks,
                "RVTRACE privilege switches",
                int(latest_trace.get("priv_switches", 0)),
                args.min_rvtrace_priv_switches,
                evidence=trace_source,
            )

    if not args.no_require_rvtrace_coverage:
        check_min(
            checks,
            "RVTRACE coverage runs",
            int(history.get("rvtrace_coverage_runs", 0)),
            args.min_rvtrace_coverage_runs,
            evidence=str(history_path),
        )
        coverage_logdir = dashboard.get("latest_rvtrace_coverage")
        add_check(
            checks,
            "latest RVTRACE coverage exists",
            bool(coverage_logdir),
            f"logdir={coverage_logdir or 'none'}",
        )
        coverage_summary, coverage_source = load_summary(dashboard, coverage_logdir)
        coverage = coverage_summary.get("rvtrace_coverage") if coverage_summary else None
        add_check(
            checks,
            "latest RVTRACE coverage summary",
            bool(coverage),
            f"source={coverage_source or 'none'}",
            coverage_source,
        )
        if coverage:
            add_check(
                checks,
                "RVTRACE coverage passed",
                coverage.get("status") == "pass",
                f"status={coverage.get('status', 'unknown')}",
                coverage_source,
            )
            floors = coverage_floor_summary(coverage)
            add_check(
                checks,
                "RVTRACE coverage floors passed",
                floors["fail"] == 0,
                f"pass={floors['pass']} fail={floors['fail']}",
                coverage_source,
            )
            check_min(
                checks,
                "RVTRACE coverage floor checks",
                floors["total"],
                args.min_rvtrace_floor_checks,
                evidence=coverage_source,
            )
            totals = coverage.get("totals", {})
            check_min(
                checks,
                "RVTRACE coverage retired",
                int(totals.get("retired", 0)),
                args.min_rvtrace_retired,
                evidence=coverage_source,
            )
            check_min(
                checks,
                "RVTRACE coverage traps",
                int(totals.get("traps", 0)),
                args.min_rvtrace_traps,
                evidence=coverage_source,
            )
            check_min(
                checks,
                "RVTRACE coverage AMOs",
                int(totals.get("amos", 0)),
                args.min_rvtrace_amos,
                evidence=coverage_source,
            )
            check_min(
                checks,
                "RVTRACE coverage PTE updates",
                int(totals.get("pte_updates", 0)),
                args.min_rvtrace_pte_updates,
                evidence=coverage_source,
            )
            check_min(
                checks,
                "RVTRACE coverage privilege switches",
                int(totals.get("priv_switches", 0)),
                args.min_rvtrace_priv_switches,
                evidence=coverage_source,
            )

    failures = [item for item in checks if item["status"] != "pass"]
    result = {
        "schema_version": 1,
        "status": "pass" if not failures else "fail",
        "dashboard": str(dashboard_path),
        "history_jsonl": str(history_path),
        "checks": checks,
        "summary": {
            "runs": int(dashboard.get("runs", 0)),
            "history_runs": len(history_records),
            "pass_streak": int(history.get("current_pass_streak", 0)),
            "latest_p0_linux": dashboard.get("latest_p0_linux"),
            "latest_p1_external": dashboard.get("latest_p1_external"),
            "latest_act4_spike": dashboard.get("latest_act4_spike"),
            "latest_rvtrace": dashboard.get("latest_rvtrace"),
            "latest_rvtrace_coverage": dashboard.get("latest_rvtrace_coverage"),
            "best_pnr": dashboard.get("best_pnr"),
        },
    }

    if args.json:
        json_path = Path(args.json)
        json_path.parent.mkdir(parents=True, exist_ok=True)
        json_path.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    if args.markdown:
        md_path = Path(args.markdown)
        md_path.parent.mkdir(parents=True, exist_ok=True)
        lines = [
            "# CI Evidence Health",
            "",
            f"- status: `{result['status']}`",
            f"- dashboard: `{dashboard_path}`",
            f"- history: `{history_path}`",
            f"- checks: pass={len(checks) - len(failures)} fail={len(failures)}",
            "",
            "| Check | Status | Detail | Evidence |",
            "|---|---:|---|---|",
        ]
        for item in checks:
            lines.append(
                f"| {item['name']} | `{item['status']}` | {item['detail']} | `{item.get('evidence') or '-'}` |"
            )
        md_path.write_text("\n".join(lines) + "\n", encoding="utf-8")

    status = result["status"].upper()
    print(
        f"CI_HEALTH: {status} checks={len(checks)} failures={len(failures)} "
        f"dashboard={dashboard_path} history={history_path} runs={result['summary']['runs']} "
        f"history_runs={result['summary']['history_runs']} pass_streak={result['summary']['pass_streak']}"
    )
    for item in failures:
        print(f"CI_HEALTH_FAIL: {item['name']}: {item['detail']} evidence={item.get('evidence') or '-'}")
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
