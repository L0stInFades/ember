#!/usr/bin/env python3
"""Import GitHub Actions run artifacts into retained local CI evidence."""

import argparse
import json
import os
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


def run(cmd, cwd):
    proc = subprocess.run(cmd, cwd=cwd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if proc.returncode != 0:
        raise RuntimeError("command failed: " + " ".join(cmd) + "\n" + proc.stdout)
    return proc.stdout


def origin_repo(root):
    env_repo = os.environ.get("GITHUB_REPOSITORY")
    if env_repo:
        return env_repo
    try:
        remote = run(["git", "remote", "get-url", "origin"], root).strip()
    except RuntimeError:
        return None
    if remote.startswith("git@github.com:"):
        repo = remote.split(":", 1)[1]
    elif "github.com/" in remote:
        repo = remote.split("github.com/", 1)[1]
    else:
        return None
    if repo.endswith(".git"):
        repo = repo[:-4]
    return repo or None


def load_run_metadata(run_id, repo, root):
    fields = "conclusion,createdAt,databaseId,displayTitle,event,headBranch,headSha,name,status,updatedAt,url,workflowName"
    try:
        text = run(["gh", "run", "view", str(run_id), "--repo", repo, "--json", fields], root)
        return json.loads(text)
    except (RuntimeError, json.JSONDecodeError) as exc:
        return {"warning": str(exc)}


def artifact_dirs(dest):
    return sorted(path for path in dest.iterdir() if path.is_dir())


def count_summaries(dest):
    return sum(1 for _ in dest.rglob("summary.json"))


def write_manifest(dest, repo, run_id, metadata):
    manifest = {
        "schema_version": 1,
        "repo": repo,
        "run_id": int(run_id),
        "imported_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "artifacts": [path.name for path in artifact_dirs(dest)],
        "summary_json_count": count_summaries(dest),
        "run": metadata,
    }
    path = dest / "github_run_import.json"
    path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return manifest


def refresh_dashboard(root, logs_root):
    return run(
        [
            sys.executable,
            "tools/render_ci_dashboard.py",
            "--root",
            str(logs_root),
            "--json",
            str(logs_root / "ci-dashboard.json"),
            "--markdown",
            str(logs_root / "ci-dashboard.md"),
            "--history-jsonl",
            str(logs_root / "ci-history.jsonl"),
            "--trend-markdown",
            str(logs_root / "ci-trend.md"),
        ],
        root,
    )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run_id", help="GitHub Actions run id to import")
    ap.add_argument("--repo", help="GitHub repository in OWNER/REPO form; defaults to origin")
    ap.add_argument("--logs-root", default="logs", help="retained evidence root")
    ap.add_argument("--force", action="store_true", help="replace an existing logs/github-run-<run-id> directory")
    ap.add_argument("--no-dashboard", action="store_true", help="skip dashboard/history refresh after download")
    args = ap.parse_args()

    root = Path(__file__).resolve().parents[1]
    logs_root = Path(args.logs_root)
    if not logs_root.is_absolute():
        logs_root = root / logs_root
    repo = args.repo or origin_repo(root)
    if not repo:
        raise SystemExit("missing --repo and could not infer GitHub owner/repo from origin")

    dest = logs_root / f"github-run-{args.run_id}"
    if dest.exists():
        if not args.force:
            raise SystemExit(f"{dest} already exists; use --force to replace it")
        shutil.rmtree(dest)
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.mkdir()

    metadata = load_run_metadata(args.run_id, repo, root)
    try:
        run(["gh", "run", "download", str(args.run_id), "--repo", repo, "--dir", str(dest)], root)
    except RuntimeError:
        shutil.rmtree(dest, ignore_errors=True)
        raise

    summaries = count_summaries(dest)
    if summaries == 0:
        raise SystemExit(f"downloaded artifacts into {dest}, but found no summary.json files")
    manifest = write_manifest(dest, repo, args.run_id, metadata)

    dashboard_refreshed = False
    dashboard_output = ""
    if not args.no_dashboard:
        dashboard_output = refresh_dashboard(root, logs_root)
        dashboard_refreshed = True

    print(
        "GITHUB_RUN_IMPORT: PASS "
        f"repo={repo} run_id={args.run_id} dest={dest} "
        f"artifacts={len(manifest['artifacts'])} summaries={summaries} "
        f"dashboard_refreshed={int(dashboard_refreshed)}"
    )
    if dashboard_output:
        print(dashboard_output, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
