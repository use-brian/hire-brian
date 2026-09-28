#!/usr/bin/env python3
"""Run doctor against isolated release directories and mocked health checks."""
from pathlib import Path
import subprocess
import tempfile
import unittest

DOCTOR = Path(__file__).parent / "outpost/bin/outpost-doctor"


class DoctorCleanupTests(unittest.TestCase):
    def run_doctor(self, args=(), healthy=True, locked=False, valid_active=True):
        with tempfile.TemporaryDirectory(prefix="doctor test ") as tmp:
            root = Path(tmp)
            releases = root / "releases"
            releases.mkdir()
            active = releases / "new"
            old = releases / "old"
            outside = root / "files"
            for directory in (active, old, outside):
                directory.mkdir()
                (directory / "source").write_text("keep")
            (releases / "external-link").symlink_to(outside)
            (root / "platform").symlink_to(active if valid_active else outside)
            config = root / "deploy.conf"
            config.write_text("\n".join(f"ENABLE_{name}=no" for name in
                                       ("DISCORD", "WHATSAPP", "WECHAT", "FEISHU")))
            source = DOCTOR.read_text().replace(
                "/etc/use-brian-outpost/deploy.conf", str(config)
            ).replace("/var/lib/use-brian-outpost", str(root)).replace(
                "/run/lock/use-brian-outpost-update.lock", str(root / "lock")
            )
            # Quote substituted fixture paths (which deliberately contain spaces).
            for path in (str(config), str(root / "releases"),
                         str(root / "platform"), str(root / "lock")):
                source = source.replace(path, '"' + path + '"')
            prelude = f'''
id() {{ echo 0; }}
flock() {{ return {1 if locked else 0}; }}
systemctl() {{ return {0 if healthy else 1}; }}
curl() {{ return {0 if healthy else 1}; }}
'''
            result = subprocess.run(["bash", "-c", prelude + source, "doctor", *args],
                                    capture_output=True, text=True)
            removed = bool(args) and healthy and not locked and valid_active
            self.assertEqual(old.exists(), not removed, result.stderr)
            self.assertTrue((active / "source").exists())
            self.assertTrue((outside / "source").exists())
            self.assertTrue((releases / "external-link").is_symlink())
            return result

    def test_default_does_not_delete(self):
        self.assertEqual(self.run_doctor().returncode, 0)

    def test_flag_deletes_inactive_releases(self):
        self.assertEqual(self.run_doctor(("--cleanup-old-releases",)).returncode, 0)

    def test_unsafe_cleanup_is_refused(self):
        for options in ({"healthy": False}, {"locked": True}, {"valid_active": False}):
            with self.subTest(options=options):
                self.assertNotEqual(self.run_doctor(("--cleanup-old-releases",), **options).returncode, 0)


if __name__ == "__main__":
    unittest.main()
