#!/usr/bin/env python3
"""Exercise the updater's health-check/cleanup/rollback block without services."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


UPDATER = Path(__file__).parent / "outpost/bin/outpost-update"
TAIL = 'for _ in $(seq 1 60); do\n' + UPDATER.read_text().split(
    'for _ in $(seq 1 60); do\n', 1
)[1]


class ReleaseCleanupTests(unittest.TestCase):
    def run_update(self, healthy=True, previous_kind="managed", cleanup_fails=False):
        with tempfile.TemporaryDirectory(prefix="outpost update ") as tmp:
            data = Path(tmp)
            releases = data / "releases"
            releases.mkdir()
            release = releases / "new"
            release.mkdir()
            previous = releases / "old"
            if previous_kind == "outside":
                previous = data / "files"
            elif previous_kind == "active":
                previous = release
            elif previous_kind == "root":
                previous = releases
            previous.mkdir(exist_ok=True)
            platform = data / "platform"
            platform.symlink_to(release)
            env = os.environ | {
                "data": str(data), "releases": str(releases),
                "release": str(release), "previous": str(previous),
                "platform": str(platform),
            }
            if previous_kind == "none":
                env["previous"] = ""
            prelude = '''set -euo pipefail
units=(test-api test-app)
sleep() { :; }
systemctl() { :; }
'''
            prelude += f'outpost-doctor() {{ return {0 if healthy else 1}; }}\n'
            if cleanup_fails:
                prelude += 'rm() { return 1; }\n'
            result = subprocess.run(["bash", "-c", prelude + TAIL], env=env,
                                    text=True, capture_output=True)
            self.assertEqual(result.returncode, 0 if healthy else 1, result.stderr)
            self.assertTrue(release.is_dir())
            self.assertEqual(platform.resolve(), release if healthy else previous)
            should_delete = healthy and previous_kind == "managed" and not cleanup_fails
            self.assertEqual(previous.exists(), not should_delete)
            if cleanup_fails:
                self.assertIn("cleanup failed", result.stderr)

    def test_healthy_release_removes_previous(self):
        self.run_update()

    def test_unhealthy_release_preserves_previous_and_rolls_back(self):
        self.run_update(healthy=False)

    def test_cleanup_is_limited_to_previous_managed_release(self):
        for kind in ("outside", "active", "root", "none"):
            with self.subTest(kind=kind):
                self.run_update(previous_kind=kind)

    def test_cleanup_failure_does_not_fail_healthy_upgrade(self):
        self.run_update(cleanup_fails=True)


if __name__ == "__main__":
    unittest.main()
