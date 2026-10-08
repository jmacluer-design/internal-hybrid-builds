#!/usr/bin/env python3
"""Read-only research-checkpoint freshness check; never republishes catalogue data."""
from __future__ import annotations

import argparse
from datetime import date, datetime, timedelta, timezone
import json
from pathlib import Path
import re
from typing import Any

BRISBANE = timezone(timedelta(hours=10))
SCOPE = (
    "Checkpoint freshness only. This does not verify project claims, inspect "
    "ChatGPT task state, resume a task, or override a publication denial."
)


def assess(state: Any, projects: Any, today: date, max_age_days: int = 2) -> dict[str, Any]:
    """Assess the last completed full cycle, ignoring structural/partial dates."""
    if max_age_days < 0:
        raise ValueError("max_age_days must be non-negative")
    report: dict[str, Any] = {
        "schema_version": 1,
        "checked_on": today.isoformat(),
        "timezone": "Australia/Brisbane",
        "max_age_days": max_age_days,
        "scope": SCOPE,
        "status": "invalid",
        "last_completed_on": None,
        "checkpoint_head": None,
        "checkpoint_project_count": None,
        "current_project_count": None,
        "age_days": None,
        "message": "Invalid maintenance input; inspect the state and catalogue files.",
    }
    if not isinstance(state, dict) or not isinstance(projects, list):
        return report
    if not projects or any(not isinstance(project, dict) for project in projects):
        return report
    report["current_project_count"] = len(projects)
    checkpoint = state.get("last_completed_cycle")
    if checkpoint is None:
        report.update(status="missing", message="No completed research-cycle checkpoint is recorded.")
        return report
    if not isinstance(checkpoint, dict):
        return report
    value = checkpoint.get("verified_at")
    sha = checkpoint.get("head_sha")
    count = checkpoint.get("project_count")
    if not isinstance(value, str) or re.fullmatch(r"\d{4}-\d{2}-\d{2}", value) is None:
        return report
    if not isinstance(sha, str) or re.fullmatch(r"[0-9a-f]{40}", sha) is None:
        return report
    if type(count) is not int or count < 1:
        return report
    try:
        completed = date.fromisoformat(value)
    except ValueError:
        return report
    if completed > today:
        report["message"] = "Completed-cycle date is in the future; do not treat it as a fresh audit."
        return report
    age = (today - completed).days
    report.update(
        last_completed_on=completed.isoformat(),
        checkpoint_head=sha,
        checkpoint_project_count=count,
        age_days=age,
        status="stale" if age > max_age_days else "current",
        message=(
            "Completed research checkpoint is overdue. Review the scheduled task and publication failures; "
            "do not advance the checkpoint merely to clear this alert."
            if age > max_age_days else
            "Recorded completed-cycle date is within the freshness window; audit quality is not assessed here."
        ),
    )
    return report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--max-age-days", type=int, default=2)
    args = parser.parse_args(argv)
    if args.max_age_days < 0:
        parser.error("--max-age-days must be non-negative")
    today = datetime.now(BRISBANE).date()
    try:
        state = json.loads((args.root / ".github/catalogue-state.json").read_text(encoding="utf-8"))
        projects = json.loads((args.root / "data/projects.json").read_text(encoding="utf-8"))
        report = assess(state, projects, today, args.max_age_days)
    except (OSError, ValueError, RecursionError) as exc:
        report = assess(None, None, today, args.max_age_days)
        report["input_error"] = type(exc).__name__
    print(json.dumps(report, indent=2, ensure_ascii=False))
    return 0 if report["status"] == "current" else 2 if report["status"] == "invalid" else 1


if __name__ == "__main__":
    raise SystemExit(main())
