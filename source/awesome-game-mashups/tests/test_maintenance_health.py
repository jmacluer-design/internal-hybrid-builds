"""The freshness alarm must not turn a build or partial audit into a full audit."""
from contextlib import redirect_stdout
from copy import deepcopy
from datetime import date, datetime
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location(
    "maintenance_health", Path(__file__).resolve().parents[1] / "scripts/maintenance_health.py"
)
health = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(health)


class MaintenanceHealthTests(unittest.TestCase):
    def setUp(self):
        self.today = date(2026, 10, 6)
        self.projects = [{"id": "example"}]
        self.state = {"last_completed_cycle": {
            "verified_at": "2026-10-03", "head_sha": "a" * 40, "project_count": 1,
        }}

    def test_old_full_checkpoint_is_stale(self):
        self.assertEqual(health.assess(self.state, self.projects, self.today)["status"], "stale")

    def test_recent_partial_and_structural_work_cannot_clear_alert(self):
        self.state["structural_upgrade"] = {"date": "2026-10-06"}
        self.state["last_partial_cycle"] = {"verified_at": "2026-10-06"}
        self.assertEqual(health.assess(self.state, self.projects, self.today)["status"], "stale")

    def test_boundary_and_current_counts(self):
        self.state["last_completed_cycle"]["verified_at"] = "2026-10-04"
        report = health.assess(self.state, self.projects * 2, self.today)
        self.assertEqual((report["status"], report["age_days"]), ("current", 2))
        self.assertEqual((report["checkpoint_project_count"], report["current_project_count"]), (1, 2))

    def test_missing_checkpoint(self):
        self.assertEqual(health.assess({}, self.projects, self.today)["status"], "missing")

    def test_future_date_is_invalid(self):
        self.state["last_completed_cycle"]["verified_at"] = "2026-10-07"
        self.assertEqual(health.assess(self.state, self.projects, self.today)["status"], "invalid")

    def test_malformed_fields_are_invalid(self):
        for key, value in [("verified_at", "today"), ("verified_at", "2026-02-30"),
                           ("head_sha", "main"), ("project_count", True), ("project_count", 0)]:
            with self.subTest(key=key, value=value):
                state = deepcopy(self.state)
                state["last_completed_cycle"][key] = value
                self.assertEqual(health.assess(state, self.projects, self.today)["status"], "invalid")

    def test_invalid_input_shapes(self):
        for state, projects in [(None, self.projects), ([], self.projects), (self.state, {}),
                                (self.state, []), (self.state, ["invalid"]),
                                ({"last_completed_cycle": []}, self.projects)]:
            self.assertEqual(health.assess(state, projects, self.today)["status"], "invalid")

    def test_assess_never_mutates_inputs(self):
        original = deepcopy((self.state, self.projects))
        health.assess(self.state, self.projects, self.today)
        self.assertEqual((self.state, self.projects), original)

    def test_cli_reads_but_never_modifies_source_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / ".github").mkdir()
            (root / "data").mkdir()
            self.state["last_completed_cycle"]["verified_at"] = datetime.now(health.BRISBANE).date().isoformat()
            paths = {root / ".github/catalogue-state.json": json.dumps(self.state),
                     root / "data/projects.json": json.dumps(self.projects)}
            for path, content in paths.items():
                path.write_text(content, encoding="utf-8")
            output = io.StringIO()
            with redirect_stdout(output):
                result = health.main(["--root", str(root)])
            self.assertEqual(result, 0)
            self.assertEqual(json.loads(output.getvalue())["status"], "current")
            self.assertEqual({path: path.read_text(encoding="utf-8") for path in paths}, paths)
            self.assertEqual({p for p in root.rglob("*") if p.is_file()}, set(paths))

    def test_cli_missing_files_exits_invalid(self):
        with tempfile.TemporaryDirectory() as root, redirect_stdout(io.StringIO()):
            self.assertEqual(health.main(["--root", root]), 2)

    def test_negative_window_is_invalid(self):
        with self.assertRaises(ValueError):
            health.assess(self.state, self.projects, self.today, -1)


if __name__ == "__main__":
    unittest.main()
