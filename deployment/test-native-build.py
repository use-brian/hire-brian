"""Offline contract tests. Run: python3 deployment/test-native-build.py"""

import itertools
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


HELPER = Path(__file__).resolve().with_name("native-build.sh")
CORE = ["@use-brian/api-open", "app-web", "@use-brian/doc-sync", "@use-brian/browser-relay"]
CONNECTORS = {
    "ENABLE_DISCORD": "@use-brian/discord-connector",
    "ENABLE_WHATSAPP": "@use-brian/wa-connector",
    "ENABLE_WECHAT": "@use-brian/wechat-connector",
    "ENABLE_FEISHU": "@use-brian/feishu-connector",
}
SKIPS = {
    "PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD": "1",
    "PUPPETEER_SKIP_DOWNLOAD": "true",
    "ELECTRON_SKIP_BINARY_DOWNLOAD": "1",
}


class NativeBuildTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.release = self.root / "release with spaces"
        self.release.mkdir()
        self.log = self.root / "calls.jsonl"
        mock = self.root / "corepack"
        mock.write_text('''#!/usr/bin/env python3
import json, os, sys
keys = ["PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD", "PUPPETEER_SKIP_DOWNLOAD",
        "ELECTRON_SKIP_BINARY_DOWNLOAD", "NODE_ENV"]
with open(os.environ["CALL_LOG"], "a") as log:
    log.write(json.dumps({"args": sys.argv[1:], "cwd": os.getcwd(),
                         "env": {k: os.environ.get(k) for k in keys},
                         "node_options": os.environ.get("NODE_OPTIONS")}) + "\\n")
phase = "INSTALL" if "install" in sys.argv else "BUILD"
sys.exit(int(os.environ.get("FAIL_" + phase, "0")))
''')
        mock.chmod(0o755)

    def run_helper(self, script, extra=None):
        env = dict(os.environ)
        for key in [*CONNECTORS, *SKIPS, "INSTALL_BROWSER", "NODE_ENV", "NODE_OPTIONS", "FAIL_INSTALL", "FAIL_BUILD"]:
            env.pop(key, None)
        env.update(PATH=f"{self.root}:{env['PATH']}", CALL_LOG=str(self.log))
        env.update(extra or {})
        self.log.unlink(missing_ok=True)
        result = subprocess.run(
            ["bash", "-c", 'set -eu; source "$1"; ' + script,
             "test", str(HELPER), str(self.release)],
            env=env, text=True, capture_output=True,
        )
        calls = [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
        return result, calls

    def expected_args(self, packages):
        return [
            ["pnpm", *[f"--filter={p}..." for p in packages],
             "--filter=@use-brian/api...", "install", "--frozen-lockfile", "--prod=false"],
            ["pnpm", "turbo", "run", "build", "--concurrency=1",
             *[f"--filter={p}" for p in packages]],
        ]

    def test_all_profiles_browser_and_connector_combinations(self):
        for profile, browser, bits in itertools.product(
            ("oss", "outpost"), ("no", "yes"), itertools.product((False, True), repeat=4)
        ):
            with self.subTest(profile=profile, browser=browser, enabled=bits):
                env = {key: "yes" if bit else "no" for key, bit in zip(CONNECTORS, bits)}
                env["INSTALL_BROWSER"] = browser
                packages = CORE + (["@use-brian/auth-web"] if profile == "outpost" else [])
                packages += ["@use-brian/browser-extension"] if browser == "yes" else []
                packages += [pkg for pkg, bit in zip(CONNECTORS.values(), bits) if bit]
                result, calls = self.run_helper(
                    f'native_build_filters {profile}; build_native_release "$2"', env)
                self.assertEqual(result.returncode, 0, result.stderr)
                # Exact equality excludes unselected connectors/the extension,
                # Firefox targets, build:firefox, and browser download commands.
                self.assertEqual([c["args"] for c in calls], self.expected_args(packages))
                self.assertEqual([c["cwd"] for c in calls], [str(self.release)] * 2)
                self.assertEqual(calls[0]["env"], dict(SKIPS, NODE_ENV=None))
                self.assertEqual(calls[1]["env"], dict.fromkeys(SKIPS) | {"NODE_ENV": "production"})

    def test_defaults_and_only_literal_yes_enable_optional_targets(self):
        for profile, value in itertools.product(("oss", "outpost"), (None, "", "no", "YES", "true", "1")):
            with self.subTest(profile=profile, value=value):
                env = {} if value is None else dict.fromkeys([*CONNECTORS, "INSTALL_BROWSER"], value)
                result, calls = self.run_helper(f'native_build_filters {profile}; build_native_release "$2"', env)
                self.assertEqual(result.returncode, 0, result.stderr)
                packages = CORE + (["@use-brian/auth-web"] if profile == "outpost" else [])
                self.assertEqual([c["args"] for c in calls], self.expected_args(packages))

    def test_reselection_resets_array(self):
        result, calls = self.run_helper('''
            native_build_filters outpost
            ENABLE_DISCORD=no; ENABLE_WHATSAPP=no; ENABLE_WECHAT=no; ENABLE_FEISHU=no
            INSTALL_BROWSER=no
            native_build_filters oss
            build_native_release "$2"
        ''', dict.fromkeys([*CONNECTORS, "INSTALL_BROWSER"], "yes"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([c["args"] for c in calls], self.expected_args(CORE))

    def test_uses_existing_filters_and_preserves_caller_state(self):
        result, calls = self.run_helper('''
            build_filters=(--filter=app-web)
            before=$PWD
            build_native_release "$2"
            [[ "$PWD" = "$before" && "${build_filters[*]}" = --filter=app-web ]]
            [[ "$PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD" = original && "$NODE_ENV" = development ]]
        ''', dict.fromkeys(SKIPS, "original") | {"NODE_ENV": "development"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([c["args"] for c in calls], self.expected_args(["app-web"]))
        self.assertEqual(calls[0]["env"], dict(SKIPS, NODE_ENV="development"))
        self.assertEqual(calls[1]["env"], dict.fromkeys(SKIPS, "original") | {"NODE_ENV": "production"})

    def test_build_raises_heap_without_leaking_or_dropping_caller_options(self):
        for caller, expected in ((None, "--max-old-space-size=4096"),
                                 ("--enable-source-maps", "--enable-source-maps --max-old-space-size=4096")):
            extra = {"EXPECT_AFTER": caller or "unset"} | ({"NODE_OPTIONS": caller} if caller else {})
            result, calls = self.run_helper('''
                build_filters=(--filter=app-web)
                build_native_release "$2"
                [[ "${NODE_OPTIONS-unset}" = "$EXPECT_AFTER" ]]
            ''', extra)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(calls[0]["node_options"], caller)
            self.assertEqual(calls[1]["node_options"], expected)

    def test_failures_propagate_even_in_conditional_context(self):
        for phase, status, count in (("INSTALL", 37, 1), ("BUILD", 42, 2)):
            for invocation in ('build_native_release "$2"', 'if build_native_release "$2"; then exit 99; else exit $?; fi'):
                with self.subTest(phase=phase, invocation=invocation):
                    result, calls = self.run_helper('native_build_filters oss; ' + invocation,
                                                    {f"FAIL_{phase}": str(status)})
                    self.assertEqual(result.returncode, status, result.stderr)
                    self.assertEqual(len(calls), count)

    def mock_runuser(self):
        mock = self.root / "runuser"
        mock.write_text('''#!/usr/bin/env python3
import json, os, sys
with open(os.environ["RUNUSER_LOG"], "a") as log:
    log.write(json.dumps(sys.argv[1:]) + "\\n")
assert sys.argv[1:4] == ["-u", "test-service-user", "--"], sys.argv
os.execvp(sys.argv[4], sys.argv[4:])
''')
        mock.chmod(0o755)
        data = self.root / "data with spaces"
        data.mkdir()
        (data / "platform").symlink_to(self.release, target_is_directory=True)
        return {
            "BRIAN_USER": "test-service-user",
            "CONNECTOR_DATA": str(data),
            "ADMIN_HELPER": str(HELPER.with_name("connector-admin.sh")),
            "NATIVE_HELPER": str(HELPER),
            "RUNUSER_LOG": str(self.root / "runuser.jsonl"),
        }

    def test_build_connector_targets_only_requested_connector(self):
        env = self.mock_runuser()
        for connector, package in zip(("discord", "whatsapp", "wechat", "feishu"), CONNECTORS.values()):
            with self.subTest(connector=connector):
                result, calls = self.run_helper('''
                    source "$ADMIN_HELPER"
                    build_connector "$CONNECTOR" "$CONNECTOR_DATA" "$NATIVE_HELPER"
                ''', env | {"CONNECTOR": connector, "INSTALL_BROWSER": "yes"} | dict.fromkeys(CONNECTORS, "yes"))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual([c["args"] for c in calls], self.expected_args([package]))
                self.assertEqual([c["cwd"] for c in calls], [str(self.release)] * 2)
                self.assertEqual(calls[0]["env"], dict(SKIPS, NODE_ENV=None))
                invocation = json.loads(Path(env["RUNUSER_LOG"]).read_text().splitlines()[-1])
                self.assertEqual(invocation[:6], ["-u", "test-service-user", "--", "env",
                                                  f'HOME={env["CONNECTOR_DATA"]}', "bash"])
                self.assertEqual(invocation[-3:], [f'{env["CONNECTOR_DATA"]}/platform', str(HELPER), package])

    def test_updaters_derive_browser_selection_from_marker(self):
        env = self.mock_runuser() | dict.fromkeys(CONNECTORS, "no")
        env.update(dict.fromkeys((
            "NEXT_PUBLIC_API_URL", "NEXT_PUBLIC_DOC_SYNC_URL", "AUTH_PORTAL_URL",
            "APP_URL", "API_URL", "DOC_SYNC_PUBLIC_URL",
        ), "https://test.invalid"))
        marker = self.root / "browser marker"
        env["BROWSER_MARKER"] = str(marker)
        for profile, command, marker_path, library in (
            ("oss", "brian-update", "/etc/brian/vnc.pass", "/usr/local/lib/brian"),
            ("outpost", "outpost-update", "/etc/use-brian-outpost/browser-desktop", "/usr/local/lib/use-brian-outpost"),
        ):
            source = (HELPER.parent / profile / "bin" / command).read_text()
            # Exercise the actual build block, replacing only filesystem paths.
            block = "INSTALL_BROWSER=no\n" + source.split("INSTALL_BROWSER=no\n", 1)[1].split('\necho ">>', 1)[0]
            block = block.replace(marker_path, '"$BROWSER_MARKER"')
            block = block.replace(library + "/native-build", '"$NATIVE_HELPER"')
            for present in (False, True):
                with self.subTest(profile=profile, marker_present=present):
                    if present:
                        marker.touch()
                    else:
                        marker.unlink(missing_ok=True)
                    result, calls = self.run_helper('''
                        release=$2; data=$CONNECTOR_DATA
                        unset INSTALL_BROWSER
                    ''' + block, env)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    packages = CORE + (["@use-brian/auth-web"] if profile == "outpost" else [])
                    packages += ["@use-brian/browser-extension"] if present else []
                    self.assertEqual([c["args"] for c in calls], self.expected_args(packages))
                    invocation = json.loads(Path(env["RUNUSER_LOG"]).read_text().splitlines()[-1])
                    self.assertIn("INSTALL_BROWSER=" + ("yes" if present else "no"), invocation)

    def test_invalid_connector_does_not_runuser(self):
        env = self.mock_runuser()
        result, calls = self.run_helper('''
            source "$ADMIN_HELPER"
            build_connector invalid "$CONNECTOR_DATA" "$NATIVE_HELPER"
        ''', env)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [])
        self.assertFalse(Path(env["RUNUSER_LOG"]).exists())

    def test_enable_build_failure_prevents_configuration_mutation(self):
        env = self.mock_runuser()
        mutation_log = self.root / "mutations"
        env["MUTATION_LOG"] = str(mutation_log)
        for profile, command, data, library in (
            ("oss", "brian-connectors", "/var/lib/brian", "/usr/local/lib/brian"),
            ("outpost", "outpost-connectors", "/var/lib/use-brian-outpost", "/usr/local/lib/use-brian-outpost"),
        ):
            source = (HELPER.parent / profile / "bin" / command).read_text()
            # Execute the actual enable branch, not a hand-written ordering model.
            # Exclude the privileged setup/status/disable paths and redirect all
            # build paths to the fixture. Mutation helpers are harmless sentinels.
            branch = 'if [ "$action" = enable ]; then\n' + source.split(
                'if [ "$action" = enable ]; then\n', 1)[1].split('\nelse\n', 1)[0] + '\nfi\n'
            branch = branch.replace(library + "/native-build", '"$NATIVE_HELPER"')
            branch = branch.replace(data, '"$CONNECTOR_DATA"')
            branch = branch.replace(library + "/wait-for-api", "record_mutation")
            for phase, status, count in (("INSTALL", 37, 1), ("BUILD", 42, 2)):
                with self.subTest(profile=profile, phase=phase):
                    files = [self.root / name for name in ("api.env", "deploy.conf", "service.env")]
                    for file in files:
                        file.write_text("unchanged\n")
                    result, calls = self.run_helper('''
                        source "$ADMIN_HELPER"
                        record_mutation() { echo changed >> "$MUTATION_LOG"; }
                        new_connector_secret() { record_mutation; echo secret; }
                        upsert_env_value() { record_mutation; }
                        systemctl() { record_mutation; }
                        chown() { record_mutation; }
                        chmod() { record_mutation; }
                        action=enable; connector=discord; variable=ENABLE_DISCORD
                        URL_KEY=DISCORD_CONNECTOR_URL; SECRET_KEY=DISCORD_CONNECTOR_SECRET
                        URL=http://127.0.0.1:8090; UNIT=test; BRIAN_GROUP=test
                    ''' + branch, env | {
                        f"FAIL_{phase}": str(status), "api_env": str(files[0]),
                        "config": str(files[1]), "SERVICE_ENV": str(files[2]),
                    })
                    self.assertEqual(result.returncode, status, result.stderr)
                    self.assertEqual([c["args"] for c in calls],
                                     self.expected_args([CONNECTORS["ENABLE_DISCORD"]])[:count])
                    self.assertFalse(mutation_log.exists())
                    self.assertEqual([file.read_text() for file in files], ["unchanged\n"] * 3)

    def test_invalid_inputs_do_not_invoke_corepack(self):
        for script in (
            'native_build_filters invalid', 'native_build_filters',
            'build_native_release "$2"',
            'build_filters=(); build_native_release "$2"',
            'native_build_filters oss; build_native_release',
            'native_build_filters oss; build_native_release ""',
            'native_build_filters oss; build_native_release "$2/missing"',
        ):
            with self.subTest(script=script):
                result, calls = self.run_helper(script)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
