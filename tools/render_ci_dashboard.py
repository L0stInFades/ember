#!/usr/bin/env python3
"""Render a cross-run dashboard from verify_ci summary.json artifacts."""

import argparse
import json
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path


def iso_utc(timestamp):
    return datetime.fromtimestamp(timestamp, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load_summary(path):
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return None, f"{path}: {exc}"
    if not isinstance(data, dict) or "logdir" not in data:
        return None, f"{path}: not a CI summary"
    data = dict(data)
    data["_summary_path"] = str(path)
    data["_mtime"] = path.stat().st_mtime
    return data, None


def load_history(path):
    records = []
    errors = []
    if not path or not path.is_file():
        return records, errors
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


def profiles(summary):
    names = []
    for item in summary.get("ci_summaries", []):
        name = item.get("profile")
        if name and name not in names:
            names.append(name)
    return names


def latest_with(summaries, key):
    for item in summaries:
        if item.get(key):
            return item
    return None


def latest_with_p0_mode(summaries, mode):
    for summary in summaries:
        for item in summary.get("p0_linux_passes", []):
            if item.get("mode") == mode:
                return summary
    return None


def best_fmax(summaries):
    best = None
    for summary in summaries:
        for pnr in summary.get("pnr", []):
            if best is None or pnr.get("fmax_mhz", 0) > best["pnr"].get("fmax_mhz", 0):
                best = {"summary": summary, "pnr": pnr}
    return best


def latest_profile_map(summaries):
    latest = {}
    for summary in summaries:
        for profile in profiles(summary):
            latest.setdefault(profile, summary)
    return latest


def latest_item(summary, key):
    items = summary.get(key, [])
    return items[-1] if items else None


def total_field(items, key):
    return sum(int(item.get(key, 0)) for item in items)


def history_record(summary):
    pnr = latest_item(summary, "pnr")
    p1_external = latest_item(summary, "p1_external")
    act4_spike = latest_item(summary, "act4_spike")
    rvtrace = latest_item(summary, "rvtrace_audits")
    coverage = rvtrace_coverage_record(summary.get("rvtrace_coverage"))
    health = ci_health_record(summary.get("ci_health"))
    p0_passes = summary.get("p0_linux_passes", [])
    ci_summaries = summary.get("ci_summaries", [])
    verify_summaries = summary.get("verify_summaries", [])

    record = {
        "schema_version": 1,
        "timestamp": iso_utc(summary.get("_mtime", 0)),
        "logdir": summary.get("logdir"),
        "summary_path": summary.get("_summary_path"),
        "profiles": profiles(summary),
        "status": summary.get("status", "unknown"),
        "ci_pass": total_field(ci_summaries, "pass"),
        "ci_fail": total_field(ci_summaries, "fail"),
        "verify_pass": total_field(verify_summaries, "pass"),
        "verify_fail": total_field(verify_summaries, "fail"),
        "p0_linux": bool(p0_passes),
        "p0_linux_modes": [item.get("mode") or "unknown" for item in p0_passes],
        "p0_linux_boots": [p0_linux_record(item) for item in p0_passes],
        "p1_external": p1_external_record(p1_external),
        "act4_spike": act4_spike_record(act4_spike),
        "pnr": None,
        "rvtrace": None,
        "rvtrace_coverage": coverage,
        "ci_health": health,
    }
    if pnr:
        record["pnr"] = {
            "fmax_mhz": pnr.get("fmax_mhz"),
            "target_mhz": pnr.get("target_mhz"),
            "program_finished": bool(pnr.get("program_finished")),
            "source": pnr.get("source"),
            "util": pnr.get("util", {}),
        }
    if rvtrace:
        record["rvtrace"] = {
            "tests": rvtrace.get("tests"),
            "retired": rvtrace.get("retired"),
            "traps": rvtrace.get("traps"),
            "amos": rvtrace.get("amos"),
            "pte_updates": rvtrace.get("pte_updates"),
            "priv_switches": rvtrace.get("priv_switches"),
            "source": rvtrace.get("source"),
            "trace_logdir": rvtrace.get("trace_logdir"),
        }
    return record


def p0_linux_record(item):
    return {
        "mode": item.get("mode") or "unknown",
        "cycles": item.get("cycles"),
        "maxcyc": item.get("maxcyc"),
        "log_prefix": item.get("log_prefix"),
        "expect": item.get("expect"),
        "source": item.get("source"),
    }


def p1_external_record(item):
    if not item:
        return None
    tests = []
    for test in item.get("tests", []):
        tests.append(
            {
                "test": test.get("test"),
                "rows": test.get("rows"),
                "ret": test.get("ret"),
                "traps": test.get("traps"),
                "trap_exceptions": test.get("trap_exceptions", 0),
                "spike_commits": test.get("spike_commits"),
                "terminal_trap": bool(test.get("terminal_trap")),
            }
        )
    return {
        "status": item.get("status"),
        "logdir": item.get("logdir"),
        "source": item.get("source"),
        "test_count": item.get("test_count"),
        "ret": item.get("ret"),
        "traps": item.get("traps"),
        "trap_exceptions": item.get("trap_exceptions", 0),
        "spike_commits": item.get("spike_commits"),
        "terminal_traps": item.get("terminal_traps"),
        "tests": tests,
    }


def p1_external_test_names(item):
    if not item:
        return []
    return [test.get("test") for test in item.get("tests", []) if test.get("test")]


def act4_spike_test_names(item):
    if not item:
        return []
    return [test for test in item.get("test_names", []) if test]


def rvtrace_coverage_test_names(coverage):
    if not coverage:
        return []
    return [test.get("test") for test in coverage.get("tests", []) if test.get("test")]


def act4_spike_record(item):
    if not item:
        return None
    return {
        "status": item.get("status"),
        "tests": item.get("tests"),
        "passed": item.get("passed"),
        "failed": item.get("failed"),
        "test_names": item.get("test_names", []),
        "group_count": item.get("group_count"),
        "groups": item.get("groups", []),
        "group_tests": item.get("group_tests", []),
        "logdir": item.get("logdir"),
        "source": item.get("source"),
    }


def rvtrace_coverage_record(coverage):
    if not coverage:
        return None
    tests = []
    for item in coverage.get("tests", []):
        tests.append(
            {
                "test": item.get("test"),
                "retired": item.get("retired"),
                "traps": item.get("traps"),
                "amos": item.get("amos"),
                "pte_updates": item.get("pte_updates"),
                "priv_switches": item.get("priv_switches"),
                "stores": item.get("stores"),
                "writes": item.get("writes"),
            }
        )
    return {
        "status": coverage.get("status"),
        "source": coverage.get("source"),
        "totals": coverage.get("totals", {}),
        "thresholds": coverage.get("thresholds", {}),
        "floor_checks": floor_check_summary(coverage.get("coverage_floor_checks", [])),
        "tests": tests,
    }


def ci_health_record(health):
    if not health:
        return None
    checks = health.get("checks", [])
    failed = sum(1 for item in checks if item.get("status") != "pass")
    return {
        "status": health.get("status"),
        "source": health.get("source"),
        "checks": {"pass": len(checks) - failed, "fail": failed},
        "dashboard": health.get("dashboard"),
        "history_jsonl": health.get("history_jsonl"),
        "summary": health.get("summary", {}),
    }


def floor_check_summary(checks):
    failed = sum(1 for item in checks if item.get("status") != "pass")
    return {"pass": len(checks) - failed, "fail": failed}


def merge_history(existing_records, summaries):
    by_logdir = {}
    for record in existing_records:
        logdir = record.get("logdir")
        if logdir:
            by_logdir[logdir] = record
    for summary in summaries:
        record = history_record(summary)
        if record.get("logdir"):
            by_logdir[record["logdir"]] = record
    records = list(by_logdir.values())
    records.sort(key=lambda item: (item.get("timestamp", ""), item.get("logdir", "")))
    return records


def write_history(path, records):
    path.parent.mkdir(parents=True, exist_ok=True)
    text = "".join(json.dumps(item, sort_keys=True) + "\n" for item in records)
    path.write_text(text, encoding="utf-8")


def trend_summary(records):
    newest = list(reversed(records))
    profile_counts = Counter()
    for record in records:
        for profile in record.get("profiles", []):
            profile_counts[profile] += 1

    pass_streak = 0
    for record in newest:
        if record.get("status") == "pass":
            pass_streak += 1
        else:
            break

    pnr_records = [record for record in records if record.get("pnr") and record["pnr"].get("fmax_mhz") is not None]
    pnr_values = [record["pnr"].get("fmax_mhz", 0) for record in pnr_records]
    p1_external_records = [record for record in records if record.get("p1_external")]
    act4_spike_records = [record for record in records if record.get("act4_spike")]
    rvtrace_coverage_records = [record for record in records if record.get("rvtrace_coverage")]
    latest_failure = next((record for record in newest if record.get("status") != "pass"), None)
    latest_pnr = next((record for record in newest if record.get("pnr")), None)
    latest_p1_external = next((record for record in newest if record.get("p1_external")), None)
    latest_act4_spike = next((record for record in newest if record.get("act4_spike")), None)
    latest_rvtrace_coverage = next((record for record in newest if record.get("rvtrace_coverage")), None)
    p0_linux_login_records = [
        record
        for record in records
        if "login" in record.get("p0_linux_modes", [])
    ]
    p0_login_boots = [
        {"record": record, "boot": boot}
        for record in records
        for boot in record.get("p0_linux_boots", [])
        if boot.get("mode") == "login" and boot.get("cycles") is not None
    ]
    best_pnr_record = max(
        pnr_records,
        key=lambda record: (record["pnr"].get("fmax_mhz", 0), record.get("timestamp", "")),
        default=None,
    )

    pnr = None
    if pnr_records:
        pnr = {
            "runs": len(pnr_records),
            "latest_logdir": latest_pnr.get("logdir") if latest_pnr else None,
            "latest_fmax_mhz": latest_pnr["pnr"].get("fmax_mhz") if latest_pnr else None,
            "best_logdir": best_pnr_record.get("logdir") if best_pnr_record else None,
            "best_fmax_mhz": max(pnr_values),
            "min_fmax_mhz": min(pnr_values),
        }

    p0_linux_login_cycles = None
    if p0_login_boots:
        latest = p0_login_boots[-1]
        cycles = [item["boot"]["cycles"] for item in p0_login_boots]
        best = min(p0_login_boots, key=lambda item: item["boot"]["cycles"])
        p0_linux_login_cycles = {
            "latest_logdir": latest["record"].get("logdir"),
            "latest_cycles": latest["boot"].get("cycles"),
            "best_logdir": best["record"].get("logdir"),
            "best_cycles": best["boot"].get("cycles"),
            "max_cycles": max(cycles),
        }

    p1_external = None
    if latest_p1_external:
        latest_p1 = latest_p1_external.get("p1_external") or {}
        p1_external = {
            "runs": len(p1_external_records),
            "latest_logdir": latest_p1_external.get("logdir"),
            "latest_test_count": latest_p1.get("test_count"),
            "latest_tests": p1_external_test_names(latest_p1),
        }

    act4_spike = None
    if latest_act4_spike:
        latest_act4 = latest_act4_spike.get("act4_spike") or {}
        act4_spike = {
            "runs": len(act4_spike_records),
            "latest_logdir": latest_act4_spike.get("logdir"),
            "latest_test_count": latest_act4.get("tests"),
            "latest_tests": act4_spike_test_names(latest_act4),
        }

    rvtrace_coverage = None
    if latest_rvtrace_coverage:
        latest_coverage = latest_rvtrace_coverage.get("rvtrace_coverage") or {}
        rvtrace_coverage = {
            "runs": len(rvtrace_coverage_records),
            "latest_logdir": latest_rvtrace_coverage.get("logdir"),
            "latest_tests": rvtrace_coverage_test_names(latest_coverage),
        }

    return {
        "runs": len(records),
        "profile_counts": dict(sorted(profile_counts.items())),
        "current_pass_streak": pass_streak,
        "latest_failure": {
            "logdir": latest_failure.get("logdir"),
            "status": latest_failure.get("status"),
            "timestamp": latest_failure.get("timestamp"),
        }
        if latest_failure
        else None,
        "p0_linux_runs": sum(1 for record in records if record.get("p0_linux")),
        "p0_linux_login_runs": len(p0_linux_login_records),
        "p0_linux_login_cycles": p0_linux_login_cycles,
        "p1_external_runs": len(p1_external_records),
        "p1_external": p1_external,
        "act4_spike_runs": len(act4_spike_records),
        "act4_spike": act4_spike,
        "rvtrace_runs": sum(1 for record in records if record.get("rvtrace")),
        "rvtrace_coverage_runs": len(rvtrace_coverage_records),
        "rvtrace_coverage": rvtrace_coverage,
        "ci_health_runs": sum(1 for record in records if record.get("ci_health")),
        "pnr": pnr,
    }


def trend_lines(trend, history_path):
    profile_counts = trend.get("profile_counts", {})
    profile_text = ", ".join(f"{name}={count}" for name, count in profile_counts.items()) or "none"
    lines = [
        "## Trend Snapshot",
        "",
        f"- history file: `{history_path}`",
        f"- retained runs: `{trend['runs']}`",
        f"- current pass streak: `{trend['current_pass_streak']}`",
        f"- profile counts: `{profile_text}`",
        f"- P0 Linux evidence runs: `{trend['p0_linux_runs']}`",
        f"- P0 Linux login evidence runs: `{trend.get('p0_linux_login_runs', 0)}`",
        f"- P1 external evidence runs: `{trend.get('p1_external_runs', 0)}`",
        f"- ACT/Spike smoke runs: `{trend.get('act4_spike_runs', 0)}`",
        f"- RVTRACE audit runs: `{trend['rvtrace_runs']}`",
        f"- RVTRACE coverage artifact runs: `{trend['rvtrace_coverage_runs']}`",
        f"- CI evidence health runs: `{trend.get('ci_health_runs', 0)}`",
    ]
    if trend["pnr"]:
        pnr = trend["pnr"]
        lines.append(
            f"- PnR Fmax range: `{pnr['min_fmax_mhz']:.2f}..{pnr['best_fmax_mhz']:.2f} MHz`, "
            f"latest `{pnr['latest_fmax_mhz']:.2f} MHz` from `{pnr['latest_logdir']}`"
        )
    else:
        lines.append("- PnR Fmax range: `none`")
    if trend.get("p0_linux_login_cycles"):
        p0 = trend["p0_linux_login_cycles"]
        lines.append(
            f"- P0 Linux login cycles: latest `{p0['latest_cycles']}` from `{p0['latest_logdir']}`, "
            f"best `{p0['best_cycles']}` from `{p0['best_logdir']}`, max `{p0['max_cycles']}`"
        )
    else:
        lines.append("- P0 Linux login cycles: `none`")
    p1 = trend.get("p1_external")
    if p1 and p1.get("latest_tests"):
        lines.append(
            f"- P1 external latest tests: `{','.join(p1['latest_tests'])}` from `{p1['latest_logdir']}`"
        )
    else:
        lines.append("- P1 external latest tests: `none`")
    rvtrace_coverage = trend.get("rvtrace_coverage")
    if rvtrace_coverage and rvtrace_coverage.get("latest_tests"):
        lines.append(
            "- RVTRACE coverage latest tests: "
            f"`{','.join(rvtrace_coverage['latest_tests'])}` from `{rvtrace_coverage['latest_logdir']}`"
        )
    else:
        lines.append("- RVTRACE coverage latest tests: `none`")
    if trend["latest_failure"]:
        failure = trend["latest_failure"]
        lines.append(
            f"- latest failure: `{failure['logdir']}` status=`{failure['status']}` at `{failure['timestamp']}`"
        )
    else:
        lines.append("- latest failure: `none retained`")
    return lines


def rel(path, root):
    try:
        return str(Path(path).relative_to(root))
    except ValueError:
        return str(path)


def row(summary):
    profile = ",".join(profiles(summary)) or "-"
    status = summary.get("status", "unknown")
    p0 = "-"
    if summary.get("p0_linux_passes"):
        latest_p0 = summary["p0_linux_passes"][-1]
        mode = latest_p0.get("mode") or "unknown"
        cycles = latest_p0.get("cycles")
        p0 = f"{mode} {cycles / 1_000_000_000:.3f}Gcyc" if cycles is not None else mode
    p1_external = "-"
    if summary.get("p1_external"):
        latest_p1 = summary["p1_external"][-1]
        test_names = p1_external_test_names(latest_p1)
        names_suffix = f", names={','.join(test_names)}" if test_names else ""
        p1_external = (
            f"{latest_p1.get('test_count', 0)} tests, "
            f"{latest_p1.get('ret', 0)} ret, "
            f"{latest_p1.get('trap_exceptions', 0)} trap-exc, "
            f"{latest_p1.get('terminal_traps', 0)} term"
            f"{names_suffix}"
        )
    act4_spike = "-"
    if summary.get("act4_spike"):
        latest_act4 = summary["act4_spike"][-1]
        group_count = latest_act4.get("group_count")
        group_suffix = f", {group_count} groups" if group_count is not None else ""
        group_tests = latest_act4.get("group_tests", [])
        group_tests_text = ",".join(
            f"{item.get('group')}={item.get('tests')}"
            for item in group_tests
            if item.get("group")
        )
        group_tests_suffix = f", counts={group_tests_text}" if group_tests_text else ""
        act4_spike = (
            f"{latest_act4.get('passed', 0)}/{latest_act4.get('tests', 0)} "
            f"{latest_act4.get('status', 'unknown')}{group_suffix}{group_tests_suffix}"
        )
    pnr = "-"
    if summary.get("pnr"):
        latest_pnr = summary["pnr"][-1]
        pnr = f"{latest_pnr.get('fmax_mhz', 0):.2f}/{latest_pnr.get('target_mhz', 0):.0f}"
    rvtrace = "-"
    if summary.get("rvtrace_audits"):
        latest_trace = summary["rvtrace_audits"][-1]
        rvtrace = (
            f"{latest_trace.get('retired', 0)} ret, "
            f"{latest_trace.get('traps', 0)} trap, "
            f"{latest_trace.get('amos', 0)} amo"
        )
    return profile, status, p0, p1_external, act4_spike, pnr, rvtrace, summary.get("logdir", "-")


def rvtrace_coverage_lines(summary):
    coverage = summary.get("rvtrace_coverage") or {}
    totals = coverage.get("totals", {})
    floor_checks = coverage.get("coverage_floor_checks", [])
    floor_fail = sum(1 for item in floor_checks if item.get("status") != "pass")
    floor_pass = len(floor_checks) - floor_fail
    lines = [
        "## Latest RVTRACE Coverage",
        "",
        f"- logdir: `{summary.get('logdir')}`",
        f"- source: `{coverage.get('source', '-')}`",
        f"- status: `{coverage.get('status', 'unknown')}`",
        f"- floor checks: pass={floor_pass} fail={floor_fail}",
        (
            "- totals: "
            f"retired={totals.get('retired', 0)} traps={totals.get('traps', 0)} "
            f"amos={totals.get('amos', 0)} pte_updates={totals.get('pte_updates', 0)} "
            f"priv_switches={totals.get('priv_switches', 0)}"
        ),
        "",
        "| Test | Retired | Trap | AMO | PTE | Priv | Stores | Writes |",
        "|---|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for item in coverage.get("tests", []):
        lines.append(
            "| `{test}` | {retired} | {traps} | {amos} | {pte_updates} | "
            "{priv_switches} | {stores} | {writes} |".format(**item)
        )
    return lines


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default="logs", help="root directory to scan for summary.json files")
    ap.add_argument("--limit", type=int, default=20, help="recent runs to include in the markdown table")
    ap.add_argument("--json", default="logs/ci-dashboard.json", help="output dashboard JSON")
    ap.add_argument("--markdown", default="logs/ci-dashboard.md", help="output dashboard markdown")
    ap.add_argument("--history-jsonl", default="logs/ci-history.jsonl", help="retained trend history JSONL")
    ap.add_argument("--trend-markdown", default="logs/ci-trend.md", help="output trend markdown")
    args = ap.parse_args()

    root = Path(args.root)
    summaries = []
    errors = []
    if root.is_dir():
        for path in root.rglob("summary.json"):
            data, error = load_summary(path)
            if error:
                errors.append(error)
            elif data:
                summaries.append(data)
    summaries.sort(key=lambda item: item["_mtime"], reverse=True)

    latest_profiles = latest_profile_map(summaries)
    latest_p0 = latest_with_p0_mode(summaries, "login") or latest_with(summaries, "p0_linux_passes")
    latest_p1_external = latest_with(summaries, "p1_external")
    latest_act4_spike = latest_with(summaries, "act4_spike")
    latest_trace = latest_with(summaries, "rvtrace_audits")
    latest_coverage = latest_with(summaries, "rvtrace_coverage")
    latest_health = latest_with(summaries, "ci_health")
    best = best_fmax(summaries)
    history_path = Path(args.history_jsonl)
    existing_history, history_errors = load_history(history_path)
    history = merge_history(existing_history, summaries)
    trend = trend_summary(history)
    errors.extend(history_errors)

    dashboard = {
        "root": str(root),
        "runs": len(summaries),
        "errors": errors,
        "latest_by_profile": {profile: summary.get("logdir") for profile, summary in sorted(latest_profiles.items())},
        "latest_p0_linux": latest_p0.get("logdir") if latest_p0 else None,
        "latest_p1_external": latest_p1_external.get("logdir") if latest_p1_external else None,
        "latest_p1_external_tests": p1_external_test_names(latest_item(latest_p1_external, "p1_external")) if latest_p1_external else [],
        "latest_act4_spike": latest_act4_spike.get("logdir") if latest_act4_spike else None,
        "latest_act4_spike_tests": act4_spike_test_names(latest_item(latest_act4_spike, "act4_spike")) if latest_act4_spike else [],
        "latest_rvtrace": latest_trace.get("logdir") if latest_trace else None,
        "latest_rvtrace_coverage": latest_coverage.get("logdir") if latest_coverage else None,
        "latest_rvtrace_coverage_tests": rvtrace_coverage_test_names(latest_coverage.get("rvtrace_coverage")) if latest_coverage else [],
        "latest_ci_health": latest_health.get("logdir") if latest_health else None,
        "best_pnr": None,
        "history": {
            "path": str(history_path),
            **trend,
        },
        "recent": [
            {
                "logdir": summary.get("logdir"),
                "profiles": profiles(summary),
                "status": summary.get("status"),
                "p0_linux_passes": summary.get("p0_linux_passes", []),
                "p1_external": summary.get("p1_external", []),
                "act4_spike": summary.get("act4_spike", []),
                "pnr": summary.get("pnr", []),
                "rvtrace_audits": summary.get("rvtrace_audits", []),
                "rvtrace_coverage": summary.get("rvtrace_coverage"),
                "ci_health": summary.get("ci_health"),
                "summary_path": summary.get("_summary_path"),
            }
            for summary in summaries[: args.limit]
        ],
    }
    if best:
        dashboard["best_pnr"] = {
            "logdir": best["summary"].get("logdir"),
            "fmax_mhz": best["pnr"].get("fmax_mhz"),
            "target_mhz": best["pnr"].get("target_mhz"),
            "util": best["pnr"].get("util", {}),
        }

    json_path = Path(args.json)
    md_path = Path(args.markdown)
    trend_md_path = Path(args.trend_markdown)
    write_history(history_path, history)
    json_path.parent.mkdir(parents=True, exist_ok=True)
    md_path.parent.mkdir(parents=True, exist_ok=True)
    trend_md_path.parent.mkdir(parents=True, exist_ok=True)
    json_path.write_text(json.dumps(dashboard, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    lines = [
        "# CI Metrics Dashboard",
        "",
        f"- summaries scanned: `{len(summaries)}`",
        f"- retained history runs: `{trend['runs']}`",
        f"- latest P0 Linux evidence: `{dashboard['latest_p0_linux'] or 'none'}`",
        f"- latest P1 external evidence: `{dashboard['latest_p1_external'] or 'none'}`",
        f"- latest P1 external tests: `{','.join(dashboard['latest_p1_external_tests']) or 'none'}`",
        f"- latest ACT/Spike smoke: `{dashboard['latest_act4_spike'] or 'none'}`",
        f"- latest ACT/Spike tests: `{','.join(dashboard['latest_act4_spike_tests']) or 'none'}`",
        f"- latest RVTRACE audit: `{dashboard['latest_rvtrace'] or 'none'}`",
        f"- latest RVTRACE coverage: `{dashboard['latest_rvtrace_coverage'] or 'none'}`",
        f"- latest RVTRACE coverage tests: `{','.join(dashboard['latest_rvtrace_coverage_tests']) or 'none'}`",
        f"- latest CI evidence health: `{dashboard['latest_ci_health'] or 'none'}`",
    ]
    if dashboard["best_pnr"]:
        best_pnr = dashboard["best_pnr"]
        lines.append(
            f"- best PnR Fmax: `{best_pnr['fmax_mhz']:.2f} MHz` "
            f"at `{best_pnr['target_mhz']:.2f} MHz` target from `{best_pnr['logdir']}`"
        )
    else:
        lines.append("- best PnR Fmax: `none`")
    lines += [""] + trend_lines(trend, history_path)
    if latest_coverage:
        lines += [""] + rvtrace_coverage_lines(latest_coverage)
    if latest_profiles:
        lines += ["", "## Latest By Profile"]
        for profile, summary in sorted(latest_profiles.items()):
            lines.append(f"- `{profile}`: `{summary.get('logdir')}` status=`{summary.get('status')}`")

    lines += [
        "",
        "## Recent Runs",
        "",
        "| Profile | Status | P0 Linux | P1 External | ACT/Spike | PnR Fmax/Target MHz | RVTRACE | Logdir |",
        "|---|---:|---:|---|---|---:|---|---|",
    ]
    for summary in summaries[: args.limit]:
        profile, status, p0, p1_external, act4_spike, pnr, rvtrace, logdir = row(summary)
        lines.append(
            f"| `{profile}` | `{status}` | `{p0}` | {p1_external} | {act4_spike} | `{pnr}` | {rvtrace} | `{logdir}` |"
        )
    if errors:
        lines += ["", "## Parse Warnings"]
        for error in errors[:20]:
            lines.append(f"- `{error}`")
    md_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    trend_md_path.write_text(
        "# CI Trend History\n\n" + "\n".join(trend_lines(trend, history_path)) + "\n", encoding="utf-8"
    )

    print(
        "CI_DASHBOARD: PASS "
        f"json={json_path} markdown={md_path} history={history_path} trend={trend_md_path} "
        f"runs={len(summaries)} history_runs={len(history)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
