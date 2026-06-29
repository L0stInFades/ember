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

DEFAULT_P1_ACT4_SPIKE_GROUP_COUNTS = {
    "I": 39,
    "M": 8,
    "Zmmul": 4,
    "Zaamo": 9,
    "Zalrsc": 2,
    "Zca": 26,
    "Zicsr": 6,
    "Zicntr": 2,
    "Zifencei": 1,
    "Zihintpause": 1,
    "Zihintntl": 4,
    "ZihintntlZca": 4,
}

DEFAULT_P1_ACT4_SPIKE_TESTS = [
    "I/I-add-00",
    "I/I-addi-00",
    "I/I-and-00",
    "I/I-andi-00",
    "I/I-auipc-00",
    "I/I-beq-00",
    "I/I-bge-00",
    "I/I-bgeu-00",
    "I/I-blt-00",
    "I/I-bltu-00",
    "I/I-bne-00",
    "I/I-fence-00",
    "I/I-jal-00",
    "I/I-jalr-00",
    "I/I-lb-00",
    "I/I-lbu-00",
    "I/I-lh-00",
    "I/I-lhu-00",
    "I/I-lui-00",
    "I/I-lw-00",
    "I/I-nop-00",
    "I/I-or-00",
    "I/I-ori-00",
    "I/I-sb-00",
    "I/I-sh-00",
    "I/I-sll-00",
    "I/I-slli-00",
    "I/I-slt-00",
    "I/I-slti-00",
    "I/I-sltiu-00",
    "I/I-sltu-00",
    "I/I-sra-00",
    "I/I-srai-00",
    "I/I-srl-00",
    "I/I-srli-00",
    "I/I-sub-00",
    "I/I-sw-00",
    "I/I-xor-00",
    "I/I-xori-00",
    "M/M-div-00",
    "M/M-divu-00",
    "M/M-mul-00",
    "M/M-mulh-00",
    "M/M-mulhsu-00",
    "M/M-mulhu-00",
    "M/M-rem-00",
    "M/M-remu-00",
    "Zmmul/Zmmul-mul-00",
    "Zmmul/Zmmul-mulh-00",
    "Zmmul/Zmmul-mulhsu-00",
    "Zmmul/Zmmul-mulhu-00",
    "Zaamo/Zaamo-amoadd.w-00",
    "Zaamo/Zaamo-amoand.w-00",
    "Zaamo/Zaamo-amomax.w-00",
    "Zaamo/Zaamo-amomaxu.w-00",
    "Zaamo/Zaamo-amomin.w-00",
    "Zaamo/Zaamo-amominu.w-00",
    "Zaamo/Zaamo-amoor.w-00",
    "Zaamo/Zaamo-amoswap.w-00",
    "Zaamo/Zaamo-amoxor.w-00",
    "Zalrsc/Zalrsc-lr.w-00",
    "Zalrsc/Zalrsc-sc.w-00",
    "Zca/Zca-c.add-00",
    "Zca/Zca-c.addi-00",
    "Zca/Zca-c.addi16sp-00",
    "Zca/Zca-c.addi4spn-00",
    "Zca/Zca-c.and-00",
    "Zca/Zca-c.andi-00",
    "Zca/Zca-c.beqz-00",
    "Zca/Zca-c.bnez-00",
    "Zca/Zca-c.j-00",
    "Zca/Zca-c.jal-00",
    "Zca/Zca-c.jalr-00",
    "Zca/Zca-c.jr-00",
    "Zca/Zca-c.li-00",
    "Zca/Zca-c.lui-00",
    "Zca/Zca-c.lw-00",
    "Zca/Zca-c.lwsp-00",
    "Zca/Zca-c.mv-00",
    "Zca/Zca-c.nop-00",
    "Zca/Zca-c.or-00",
    "Zca/Zca-c.slli-00",
    "Zca/Zca-c.srai-00",
    "Zca/Zca-c.srli-00",
    "Zca/Zca-c.sub-00",
    "Zca/Zca-c.sw-00",
    "Zca/Zca-c.swsp-00",
    "Zca/Zca-c.xor-00",
    "Zicsr/Zicsr-csrrc-00",
    "Zicsr/Zicsr-csrrci-00",
    "Zicsr/Zicsr-csrrs-00",
    "Zicsr/Zicsr-csrrsi-00",
    "Zicsr/Zicsr-csrrw-00",
    "Zicsr/Zicsr-csrrwi-00",
    "Zicntr/Zicntr-csrrc-00",
    "Zicntr/Zicntr-csrrs-00",
    "Zifencei/Zifencei-fence.i-00",
    "Zihintpause/Zihintpause-pause-00",
    "Zihintntl/Zihintntl-ntl.all-00",
    "Zihintntl/Zihintntl-ntl.p1-00",
    "Zihintntl/Zihintntl-ntl.pall-00",
    "Zihintntl/Zihintntl-ntl.s1-00",
    "ZihintntlZca/ZihintntlZca-c.ntl.all-00",
    "ZihintntlZca/ZihintntlZca-c.ntl.p1-00",
    "ZihintntlZca/ZihintntlZca-c.ntl.pall-00",
    "ZihintntlZca/ZihintntlZca-c.ntl.s1-00",
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

DEFAULT_RVTRACE_COVERAGE_TESTS = [
    "isa",
    "amotest",
    "mmu",
    "ctest",
    "shtest",
    "mtest",
    "misalign",
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

DEFAULT_P1_EXTERNAL_TEST_FLOORS = {
    "isa": {"ret": 600},
    "amotest": {"ret": 450},
    "ctest": {"ret": 2000},
    "shtest": {"ret": 200},
    "mtest": {"ret": 200},
    "mmu": {"ret": 5000, "traps": 2, "trap_exceptions": 2},
    "utrap": {"ret": 40},
    "misalign": {"ret": 90, "traps": 1, "terminal_trap": 1},
    "mprv": {"ret": 5000, "traps": 1, "trap_exceptions": 1},
    "mxr": {"ret": 5000, "traps": 2, "trap_exceptions": 2},
    "upage": {"ret": 9000, "traps": 3, "trap_exceptions": 3},
    "ifault": {"ret": 9000, "traps": 2, "trap_exceptions": 2},
    "wpfault": {"ret": 5000, "traps": 2, "trap_exceptions": 2},
    "sum": {"ret": 5500, "traps": 3, "trap_exceptions": 3},
    "badpte": {"ret": 9000, "traps": 3, "trap_exceptions": 3},
    "superpage": {"ret": 3500, "traps": 3, "trap_exceptions": 3},
    "amo_mmu": {"ret": 5500, "traps": 2, "trap_exceptions": 2},
}

P1_EXTERNAL_TEST_FLOOR_FIELDS = {"rows", "ret", "traps", "trap_exceptions", "spike_commits", "terminal_trap"}


def format_p1_external_test_floors(floors):
    chunks = []
    for test, fields in floors.items():
        rules = ",".join(f"{field}={value}" for field, value in fields.items())
        chunks.append(f"{test}:{rules}")
    return ";".join(chunks)


def format_group_counts(counts):
    return ",".join(f"{group}={count}" for group, count in counts.items())


def parse_group_counts(text):
    counts = {}
    if not text.strip():
        return counts
    for chunk in text.split(","):
        chunk = chunk.strip()
        if not chunk:
            continue
        if "=" not in chunk:
            raise SystemExit(f"invalid group count {chunk!r}: expected group=count")
        group, value_text = chunk.split("=", 1)
        group = group.strip()
        if not group:
            raise SystemExit(f"invalid group count {chunk!r}: empty group")
        try:
            counts[group] = int(value_text.strip(), 0)
        except ValueError as exc:
            raise SystemExit(f"invalid group count value {value_text!r} for {group}") from exc
    return counts


def act4_group_count_map(items):
    counts = {}
    for item in items or []:
        group = item.get("group")
        if group:
            counts[group] = int(item.get("tests", 0))
    return counts


def parse_p1_external_test_floors(text):
    floors = {}
    if not text.strip():
        return floors
    for chunk in text.split(";"):
        chunk = chunk.strip()
        if not chunk:
            continue
        if ":" not in chunk:
            raise SystemExit(f"invalid P1 external test floor {chunk!r}: expected test:field=value,...")
        test, rules_text = chunk.split(":", 1)
        test = test.strip()
        if not test:
            raise SystemExit(f"invalid P1 external test floor {chunk!r}: empty test name")
        fields = {}
        for rule in rules_text.split(","):
            rule = rule.strip()
            if not rule:
                continue
            if "=" not in rule:
                raise SystemExit(f"invalid P1 external test floor {chunk!r}: expected field=value")
            field, value_text = rule.split("=", 1)
            field = field.strip()
            if field not in P1_EXTERNAL_TEST_FLOOR_FIELDS:
                raise SystemExit(
                    f"invalid P1 external test floor field {field!r}; "
                    f"valid fields: {','.join(sorted(P1_EXTERNAL_TEST_FLOOR_FIELDS))}"
                )
            try:
                fields[field] = int(value_text.strip(), 0)
            except ValueError as exc:
                raise SystemExit(f"invalid P1 external test floor value {value_text!r} for {test}:{field}") from exc
        if fields:
            floors[test] = fields
    return floors


def p1_external_test_field(item, field):
    if field == "terminal_trap":
        return int(bool(item.get(field)))
    return int(item.get(field, 0))


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


def find_summary_by_logdir(dashboard, logdir):
    root = dashboard.get("root")
    if not root:
        return None, None
    root_path = Path(root)
    if not root_path.is_dir():
        return None, None
    for path in root_path.rglob("summary.json"):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if isinstance(data, dict) and data.get("logdir") == logdir:
            return data, str(path)
    return None, None


def load_summary(dashboard, logdir):
    if not logdir:
        return None, None
    path = Path(logdir) / "summary.json"
    if path.is_file():
        data = load_json(path)
        if isinstance(data, dict):
            return data, str(path)
    data, source = find_summary_by_logdir(dashboard, logdir)
    if data:
        return data, source
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


def coverage_test_names(coverage):
    return [item.get("test") for item in coverage.get("tests", []) if item.get("test")]


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
    ap.add_argument(
        "--require-p1-external-test-floors",
        default=format_p1_external_test_floors(DEFAULT_P1_EXTERNAL_TEST_FLOORS),
        help="semicolon-separated per-test minimum P1 external fields, e.g. test:ret=1,trap_exceptions=1; empty disables",
    )
    ap.add_argument("--min-p1-act4-spike-tests", type=int, default=106)
    ap.add_argument(
        "--require-p1-act4-spike-test-list",
        default=",".join(DEFAULT_P1_ACT4_SPIKE_TESTS),
        help="comma-separated exact ACT/Spike test list required for the latest P1 evidence; empty disables",
    )
    ap.add_argument(
        "--require-p1-act4-spike-groups",
        default=",".join(DEFAULT_P1_ACT4_SPIKE_GROUPS),
        help="comma-separated exact ACT/Spike group list required for the latest P1 evidence; empty disables",
    )
    ap.add_argument(
        "--require-p1-act4-spike-group-counts",
        default=format_group_counts(DEFAULT_P1_ACT4_SPIKE_GROUP_COUNTS),
        help="comma-separated exact ACT/Spike group=count list required for the latest P1 evidence; empty disables",
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
    ap.add_argument(
        "--require-rvtrace-coverage-tests",
        default=",".join(DEFAULT_RVTRACE_COVERAGE_TESTS),
        help="comma-separated exact RVTRACE coverage test list required for latest coverage evidence; empty disables",
    )
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
            p1_floor_rules = parse_p1_external_test_floors(args.require_p1_external_test_floors)
            if p1_floor_rules:
                tests_by_name = {
                    item.get("test"): item
                    for item in latest_p1.get("tests", [])
                    if item.get("test")
                }
                for test, fields in p1_floor_rules.items():
                    item = tests_by_name.get(test)
                    if not item:
                        add_check(checks, f"P1 external {test} floor source", False, "missing test", p1_source)
                        continue
                    for field, minimum in fields.items():
                        check_min(
                            checks,
                            f"P1 external {test} {field}",
                            p1_external_test_field(item, field),
                            minimum,
                            evidence=p1_source,
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
            required_act4_tests = [
                test.strip()
                for test in args.require_p1_act4_spike_test_list.split(",")
                if test.strip()
            ]
            if required_act4_tests:
                actual_act4_tests = latest_act4.get("test_names") or []
                add_check(
                    checks,
                    "P1 ACT/Spike smoke test list",
                    actual_act4_tests == required_act4_tests,
                    "tests={actual} required={required}".format(
                        actual=",".join(actual_act4_tests) or "missing",
                        required=",".join(required_act4_tests),
                    ),
                    p1_source,
                )
                dashboard_act4_tests = dashboard.get("latest_act4_spike_tests") or []
                add_check(
                    checks,
                    "P1 ACT/Spike dashboard test list",
                    dashboard_act4_tests == required_act4_tests,
                    "tests={actual} required={required}".format(
                        actual=",".join(dashboard_act4_tests) or "missing",
                        required=",".join(required_act4_tests),
                    ),
                    str(dashboard_path),
                )
                history_act4 = history.get("act4_spike") if isinstance(history.get("act4_spike"), dict) else {}
                history_act4_tests = history_act4.get("latest_tests") or []
                add_check(
                    checks,
                    "P1 ACT/Spike history test list",
                    history_act4_tests == required_act4_tests,
                    "tests={actual} required={required}".format(
                        actual=",".join(history_act4_tests) or "missing",
                        required=",".join(required_act4_tests),
                    ),
                    str(history_path),
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
            required_act4_group_counts = parse_group_counts(args.require_p1_act4_spike_group_counts)
            if required_act4_group_counts:
                actual_act4_group_counts = act4_group_count_map(latest_act4.get("group_tests", []))
                add_check(
                    checks,
                    "P1 ACT/Spike smoke group counts",
                    actual_act4_group_counts == required_act4_group_counts,
                    "groups={actual} required={required}".format(
                        actual=format_group_counts(actual_act4_group_counts) or "missing",
                        required=format_group_counts(required_act4_group_counts),
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
            required_coverage_tests = [
                test.strip()
                for test in args.require_rvtrace_coverage_tests.split(",")
                if test.strip()
            ]
            if required_coverage_tests:
                actual_coverage_tests = coverage_test_names(coverage)
                add_check(
                    checks,
                    "RVTRACE coverage test list",
                    actual_coverage_tests == required_coverage_tests,
                    "tests={actual} required={required}".format(
                        actual=",".join(actual_coverage_tests) or "missing",
                        required=",".join(required_coverage_tests),
                    ),
                    coverage_source,
                )
                dashboard_coverage_tests = dashboard.get("latest_rvtrace_coverage_tests") or []
                add_check(
                    checks,
                    "RVTRACE coverage dashboard test list",
                    dashboard_coverage_tests == required_coverage_tests,
                    "tests={actual} required={required}".format(
                        actual=",".join(dashboard_coverage_tests) or "missing",
                        required=",".join(required_coverage_tests),
                    ),
                    str(dashboard_path),
                )
                history_coverage = history.get("rvtrace_coverage") if isinstance(history.get("rvtrace_coverage"), dict) else {}
                history_coverage_tests = history_coverage.get("latest_tests") or []
                add_check(
                    checks,
                    "RVTRACE coverage history test list",
                    history_coverage_tests == required_coverage_tests,
                    "tests={actual} required={required}".format(
                        actual=",".join(history_coverage_tests) or "missing",
                        required=",".join(required_coverage_tests),
                    ),
                    str(history_path),
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
