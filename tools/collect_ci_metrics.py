#!/usr/bin/env python3
"""Collect regression metrics from a verify_ci.sh log directory."""

import argparse
import json
import re
from pathlib import Path


CI_RE = re.compile(r"CI summary: profile=(\S+) pass=(\d+) fail=(\d+) logdir=(.+)")
VERIFY_RE = re.compile(r"Summary: pass=(\d+) fail=(\d+) logdir=(.+)")
RVTRACE_RE = re.compile(
    r"RVTRACE_AUDIT: PASS tests=(?P<tests>\d+) rows=(?P<rows>\d+) retired=(?P<retired>\d+) "
    r"traps=(?P<traps>\d+) amos=(?P<amos>\d+) pte_updates=(?P<pte_updates>\d+) "
    r"priv_switches=(?P<priv_switches>\d+) uart_writes=(?P<uart_writes>\d+) "
    r"syscon_writes=(?P<syscon_writes>\d+) logdir=(?P<trace_logdir>.+)"
)
FMAX_RE = re.compile(r"Max frequency .*: ([0-9.]+) MHz \(PASS at ([0-9.]+) MHz\)")
PNR_UTIL_RE = re.compile(r"(DP16KD|TRELLIS_FF|TRELLIS_COMB):\s+(\d+)/\s*(\d+)\s+(\d+)%")


def rel(path, root):
    try:
        return str(path.relative_to(root))
    except ValueError:
        return str(path)


def parse_log(path):
    text = path.read_text(encoding="utf-8", errors="replace")
    metrics = {
        "path": str(path),
        "ci_summaries": [],
        "verify_summaries": [],
        "rvtrace_audits": [],
        "p0_linux_pass": False,
        "p0_linux_mode": None,
        "pnr": [],
    }

    for match in CI_RE.finditer(text):
        metrics["ci_summaries"].append(
            {
                "profile": match.group(1),
                "pass": int(match.group(2)),
                "fail": int(match.group(3)),
                "logdir": match.group(4),
            }
        )
    for match in VERIFY_RE.finditer(text):
        metrics["verify_summaries"].append(
            {"pass": int(match.group(1)), "fail": int(match.group(2)), "logdir": match.group(3)}
        )
    for match in RVTRACE_RE.finditer(text):
        item = {key: int(value) for key, value in match.groupdict().items() if key != "trace_logdir"}
        item["trace_logdir"] = match.group("trace_logdir")
        metrics["rvtrace_audits"].append(item)

    if "P0_LINUX_GATE: PASS" in text:
        metrics["p0_linux_pass"] = True
        mode = re.search(r"P0_LINUX_GATE: mode=(\S+)", text)
        if mode:
            metrics["p0_linux_mode"] = mode.group(1)

    fmax_matches = list(FMAX_RE.finditer(text))
    if fmax_matches:
        util = {}
        for match in PNR_UTIL_RE.finditer(text):
            util[match.group(1).lower()] = {
                "used": int(match.group(2)),
                "total": int(match.group(3)),
                "pct": int(match.group(4)),
            }
        last = fmax_matches[-1]
        metrics["pnr"].append(
            {
                "fmax_mhz": float(last.group(1)),
                "target_mhz": float(last.group(2)),
                "util": util,
                "program_finished": "Program finished normally" in text,
            }
        )

    return metrics


def load_rvtrace_coverage(logdir):
    path = logdir / "rvtrace_coverage.json"
    if not path.is_file():
        return None
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError(f"{path}: not a JSON object")
    data = dict(data)
    data["source"] = rel(path, logdir)
    return data


def load_ci_health(logdir):
    path = logdir / "ci_health.json"
    if not path.is_file():
        return None
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError(f"{path}: not a JSON object")
    data = dict(data)
    data["source"] = rel(path, logdir)
    return data


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--logdir", required=True, help="verify_ci.sh log directory")
    ap.add_argument("--json", help="output JSON path")
    ap.add_argument("--markdown", help="output Markdown path")
    args = ap.parse_args()

    logdir = Path(args.logdir)
    if not logdir.is_dir():
        raise SystemExit(f"missing logdir: {logdir}")

    logs = sorted(p for p in logdir.rglob("*.log") if p.is_file())
    summary = {
        "logdir": str(logdir),
        "logs_scanned": len(logs),
        "ci_summaries": [],
        "verify_summaries": [],
        "rvtrace_audits": [],
        "rvtrace_coverage": None,
        "ci_health": None,
        "p0_linux_passes": [],
        "pnr": [],
    }

    for path in logs:
        item = parse_log(path)
        for key in ("ci_summaries", "verify_summaries", "rvtrace_audits", "pnr"):
            for entry in item[key]:
                entry = dict(entry)
                entry["source"] = rel(path, logdir)
                summary[key].append(entry)
        if item["p0_linux_pass"]:
            summary["p0_linux_passes"].append({"source": rel(path, logdir), "mode": item["p0_linux_mode"]})

    summary["rvtrace_coverage"] = load_rvtrace_coverage(logdir)
    summary["ci_health"] = load_ci_health(logdir)

    seen_ci = set()
    summary["ci_summaries"] = [
        item
        for item in summary["ci_summaries"]
        if (item["profile"], item["pass"], item["fail"], item["logdir"]) not in seen_ci
        and not seen_ci.add((item["profile"], item["pass"], item["fail"], item["logdir"]))
    ]
    seen_verify = set()
    summary["verify_summaries"] = [
        item
        for item in summary["verify_summaries"]
        if (item["pass"], item["fail"], item["logdir"]) not in seen_verify
        and not seen_verify.add((item["pass"], item["fail"], item["logdir"]))
    ]

    summary["status"] = "pass"
    for item in summary["ci_summaries"]:
        if item["fail"] != 0:
            summary["status"] = "fail"
    for item in summary["verify_summaries"]:
        if item["fail"] != 0:
            summary["status"] = "fail"
    for item in summary["pnr"]:
        if not item["program_finished"]:
            summary["status"] = "fail"
    if summary["rvtrace_coverage"] and summary["rvtrace_coverage"].get("status") != "pass":
        summary["status"] = "fail"
    if summary["ci_health"] and summary["ci_health"].get("status") != "pass":
        summary["status"] = "fail"

    json_path = Path(args.json) if args.json else logdir / "summary.json"
    md_path = Path(args.markdown) if args.markdown else logdir / "summary.md"
    json_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    lines = [
        "# Regression Summary",
        "",
        f"- logdir: `{summary['logdir']}`",
        f"- status: `{summary['status']}`",
        f"- logs scanned: `{summary['logs_scanned']}`",
    ]
    if summary["ci_summaries"]:
        lines += ["", "## CI"]
        for item in summary["ci_summaries"]:
            lines.append(
                f"- `{item['profile']}` pass={item['pass']} fail={item['fail']} source=`{item['source']}`"
            )
    if summary["verify_summaries"]:
        lines += ["", "## Verify"]
        for item in summary["verify_summaries"]:
            lines.append(f"- pass={item['pass']} fail={item['fail']} source=`{item['source']}`")
    if summary["rvtrace_audits"]:
        lines += ["", "## RVTRACE"]
        for item in summary["rvtrace_audits"]:
            lines.append(
                "- tests={tests} retired={retired} traps={traps} amos={amos} "
                "pte_updates={pte_updates} priv_switches={priv_switches} source=`{source}`".format(**item)
            )
    if summary["rvtrace_coverage"]:
        coverage = summary["rvtrace_coverage"]
        totals = coverage.get("totals", {})
        floor_checks = coverage.get("coverage_floor_checks", [])
        floor_fail = sum(1 for item in floor_checks if item.get("status") != "pass")
        floor_pass = len(floor_checks) - floor_fail
        lines += [
            "",
            "## RVTRACE Per-Test Coverage",
            f"- source: `{coverage.get('source')}`",
            f"- status: `{coverage.get('status')}`",
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
    if summary["ci_health"]:
        health = summary["ci_health"]
        checks = health.get("checks", [])
        failed = sum(1 for item in checks if item.get("status") != "pass")
        passed = len(checks) - failed
        lines += [
            "",
            "## CI Evidence Health",
            f"- source: `{health.get('source')}`",
            f"- status: `{health.get('status')}`",
            f"- checks: pass={passed} fail={failed}",
        ]
    if summary["p0_linux_passes"]:
        lines += ["", "## P0 Linux"]
        for item in summary["p0_linux_passes"]:
            mode = item["mode"] or "unknown"
            lines.append(f"- mode={mode} source=`{item['source']}`")
    if summary["pnr"]:
        lines += ["", "## PnR"]
        for item in summary["pnr"]:
            lines.append(
                f"- fmax={item['fmax_mhz']:.2f}MHz target={item['target_mhz']:.2f}MHz "
                f"finished={int(item['program_finished'])} source=`{item['source']}`"
            )
    md_path.write_text("\n".join(lines) + "\n", encoding="utf-8")

    print(f"CI_METRICS: PASS json={json_path} markdown={md_path} status={summary['status']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
