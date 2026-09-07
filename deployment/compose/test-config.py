"""Offline tests: synthetic configuration and mocked Docker; never open .env."""

import base64
import copy
import json
import os
from pathlib import Path
import re
import runpy
import subprocess
import sys
import tempfile
import unittest

import yaml


HERE = Path(__file__).resolve().parent
module = runpy.run_path(str(HERE / "validate-config.py"))
validate, InvalidConfig = module["validate"], module["InvalidConfig"]


def fixture(mode="oss"):
    values = {}
    for line in (HERE / ".env.example").read_text().splitlines():
        if line and not line.startswith("#"):
            name, value = line.split("=", 1)
            if value.startswith("replace-"):
                value = base64.b64encode(b"x" * 32).decode() if name.endswith(("_ENCRYPTION_KEY", "_CREDENTIAL_KEY")) else "a" * 64
            values[name] = value
    values.update(USEBRIAN_EDITION=mode, BRIAN_IMAGE_TAG="sha-test")
    if mode == "outpost":
        for line in (HERE / "outpost.env.example").read_text().splitlines():
            if line and not line.startswith("#"):
                name, value = line.split("=", 1)
                values[name] = value
        values.update(OUTPOST_AUTH_BOOTSTRAP_EMAILS="admin@example.com", SMTP_HOST="smtp.example.com",
                      SMTP_USER="synthetic-user", SMTP_PASSWORD="synthetic-password", EMAIL_FROM_ADDRESS="admin@example.com")

    def resolve(value):
        if isinstance(value, str):
            return re.sub(r"\$\{([A-Z_]+)(?::-([^}]*))?\}", lambda m: values.get(m[1]) or m[2] or "", value)
        if isinstance(value, dict):
            return {key: resolve(item) for key, item in value.items()}
        if isinstance(value, list):
            return [resolve(item) for item in value]
        return value

    config = resolve(yaml.safe_load((HERE / "compose.yml").read_text()))
    if mode == "outpost":
        overlay = resolve(yaml.safe_load((HERE / "compose.outpost.yml").read_text()))
        config["services"]["api"]["environment"].update(overlay["services"]["api"]["environment"])
    else:
        del config["services"]["auth-web"]
    api = config["services"]["api"]
    api["environment"] = {**values, **api["environment"]}
    for service in config["services"].values():
        service["ports"] = [{"host_ip": port.split(":")[0], "published": port.split(":")[1],
                             "target": int(port.split(":")[2])} for port in service.get("ports", [])]
    return config


# fd 3 records Docker calls without contaminating captured config/image output.
MOCK = r'''
exec 3>&1
function [() {
  if [[ "$1" == -f ]]; then
    [[ "${TEST_FAIL:-}" != missing || "$2" != outpost.env ]]
    return
  fi
  builtin [ "$@"
}
docker() {
  case "$*" in
    "compose version") return 0 ;;
    *"config --format json")
      printf 'CONFIG %s\n' "$*" >&3
      printf 'EDITION %s\n' "$USEBRIAN_EDITION" >&3
      if [[ "${TEST_FAIL:-}" == config ]]; then printf 'synthetic-secret-error' >&2; return 1; fi
      printf '%s' "$TEST_CONFIG" ;;
    "ps "*) [[ "${TEST_FAIL:-}" != legacy ]] || printf 'legacy-id' ;;
    "volume ls "*) [[ "${TEST_FAIL:-}" != volumes ]] || printf 'use-brian_postgres-data' ;;
    "image inspect "*)
      printf 'IMAGE %s\n' "$*" >&3
      [[ "${TEST_FAIL:-}" != image ]] || return 1
      if [[ "${TEST_FAIL:-}" == mismatch && "$*" == *auth-web* ]]; then
        printf '%040d' 1
      else printf '%040d' 0; fi ;;
    *)
      printf 'MUTATION %s\n' "$*" >&3
      [[ "${TEST_FAIL:-}" != pull || "$*" != *" pull" ]] || return 1
      [[ "${TEST_FAIL:-}" != stop || "$*" != *" stop "* ]] || return 1
      [[ "${TEST_FAIL:-}" != migrate || "$*" != *"run --rm --no-deps migrate" ]] || return 1
      [[ "${TEST_FAIL:-}" != grants || "$*" != *"run --rm --no-deps grant-app-role" ]] || return 1
      ;;
  esac
}
export -f docker [
bash "$TEST_SCRIPT" "$TEST_MODE" ${TEST_ACTION:-}
'''


class ConfigTests(unittest.TestCase):
    def run_mock(self, mode="outpost", script="update.sh", failure="", config=None, action=""):
        # Do not inherit host application secrets or Compose settings.
        env = {"PATH": os.environ["PATH"], "TEST_MODE": mode, "TEST_SCRIPT": f"./{script}",
               "TEST_FAIL": failure, "TEST_ACTION": action,
               "TEST_CONFIG": json.dumps(config if config is not None else fixture(mode))}
        return subprocess.run(["bash", "-c", MOCK], cwd=HERE, env=env, text=True, capture_output=True)

    def test_manifest_defaults(self):
        manifest = yaml.safe_load((HERE / "compose.yml").read_text())
        self.assertEqual(manifest["name"], "use-brian")
        self.assertEqual(set(manifest["volumes"]), {"postgres-data", "brian-data", "whatsapp-data"})
        services = manifest["services"]
        self.assertEqual(services["auth-web"]["profiles"], ["outpost"])
        self.assertEqual(services["auth-web"]["ports"], ["127.0.0.1:3005:3005"])
        for service in services.values():
            self.assertNotIn("build", service)
            for port in service.get("ports", []):
                self.assertTrue(port.startswith("127.0.0.1:"))
                self.assertNotIn(port.split(":")[1], ("80", "443"))
        for name in ("postgres", "discord-connector", "wa-connector", "wechat-connector", "feishu-connector"):
            self.assertNotIn("ports", services[name])
        self.assertNotIn("caddy", services)
        self.assertNotIn("cloudflared", services)
        self.assertEqual(services["api"]["depends_on"]["grant-app-role"]["condition"], "service_completed_successfully")
        self.assertEqual(services["grant-app-role"]["depends_on"]["migrate"]["condition"], "service_completed_successfully")
        self.assertIn("./init-db.sh:/docker-entrypoint-initdb.d/10-use-brian.sh:ro", services["postgres"]["volumes"])
        self.assertIn("./grant-app-role.sql:/scripts/grant-app-role.sql:ro", services["grant-app-role"]["volumes"])

    def test_modes_and_auth_wiring(self):
        for mode, count in (("oss", 8), ("outpost", 9)):
            with self.subTest(mode=mode):
                config = fixture(mode)
                self.assertEqual(len(validate(config, mode)), count)
                web = config["services"]["app-web"]["environment"]
                self.assertEqual(web["PUBLIC_API_URL"], web["PUBLIC_DISPLAY_API_URL"])
                self.assertEqual(web["USEBRIAN_EDITION"], mode)
                if mode == "outpost":
                    auth = config["services"]["auth-web"]["environment"]
                    self.assertEqual(auth["INTERNAL_API_URL"], "http://api:4000")
                    self.assertEqual(auth["TRUST_PROXY_HEADERS"], "false")
                    for key in auth:
                        if key.startswith("OUTPOST_") or key == "AUTH_PORTAL_URL":
                            self.assertEqual(auth[key], config["services"]["api"]["environment"][key])

    def test_invalid_configuration(self):
        for service, key, value in (
            ("api", "SMTP_PASSWORD", ""), ("api", "OUTPOST_AUTH_BOOTSTRAP_EMAILS", "not-email"),
            ("api", "SMTP_SECURE", "yes"), ("api", "USEBRIAN_EDITION", "oss"),
            ("auth-web", "COOKIE_DOMAIN", ".nested.example.com"),
            ("auth-web", "AUTH_PORTAL_URL", "http://auth.example.com"),
            ("app-web", "PUBLIC_APP_URL", "https://nested.app.example.com"),
            ("api", "JWT_SECRET", "replace-secret"), ("api", "CHANNEL_CREDENTIAL_KEY", "not-base64"),
            ("postgres", "POSTGRES_PASSWORD", "not/uri/safe"),
            ("doc-sync", "JWT_SECRET", "different-secret"),
        ):
            with self.subTest(key=key):
                config = fixture("outpost")
                config["services"][service]["environment"][key] = value
                with self.assertRaises(InvalidConfig):
                    validate(config, "outpost")
        config = fixture()
        config["services"]["api"]["ports"][0]["host_ip"] = "0.0.0.0"
        with self.assertRaises(InvalidConfig):
            validate(config, "oss")

    def test_oidc_only(self):
        config = fixture("outpost")
        settings = dict(OUTPOST_AUTH_EMAIL_ENABLED="false", OUTPOST_AUTH_OIDC_ENABLED="true",
                        OUTPOST_OIDC_ISSUER_URL="https://id.example.net/tenant", OUTPOST_OIDC_CLIENT_ID="synthetic-id",
                        OUTPOST_OIDC_CLIENT_SECRET="synthetic-secret", OUTPOST_OIDC_PROVIDER_NAME="SSO",
                        OUTPOST_AUTH_BRIDGE_SECRET="b" * 32)
        for service in ("api", "auth-web"):
            config["services"][service]["environment"].update(settings)
        validate(config, "outpost")
        for key, value in (("OUTPOST_AUTH_BRIDGE_SECRET", "short"), ("OUTPOST_AUTH_OIDC_ENABLED", "TRUE"),
                           ("OUTPOST_OIDC_CLIENT_SECRET", ""), ("OUTPOST_OIDC_ENROLLMENT_MODE", "unknown")):
            broken = copy.deepcopy(config)
            for service in ("api", "auth-web"):
                broken["services"][service]["environment"][key] = value
            with self.assertRaises(InvalidConfig):
                validate(broken, "outpost")

    def test_secret_safe_cli(self):
        for payload in ("synthetic-secret-not-json", json.dumps({"services": "synthetic-secret"})):
            result = subprocess.run([sys.executable, str(HERE / "validate-config.py"), "outpost"],
                                    input=payload, text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("synthetic-", result.stdout + result.stderr)
            self.assertNotIn("Traceback", result.stderr)

    def test_shared_mode_mapping(self):
        for mode in ("oss", "outpost"):
            for script, action in (("verify-images.sh", ""), ("update.sh", ""), ("stack.sh", "check"), ("stack.sh", "up")):
                with self.subTest(mode=mode, script=script, action=action):
                    result = self.run_mock(mode, script, action=action)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn("--project-name use-brian --env-file .env", result.stdout)
                    self.assertIn(f"EDITION {mode}", result.stdout)
                    self.assertEqual("--env-file outpost.env -f compose.yml -f compose.outpost.yml --profile outpost" in result.stdout, mode == "outpost")
                    if script == "verify-images.sh":
                        self.assertEqual("ghcr.io/use-brian/auth-web:sha-test" in result.stdout, mode == "outpost")
                        self.assertNotIn("MUTATION", result.stdout)

    def test_update_order_and_failures(self):
        result = self.run_mock()
        self.assertEqual(result.returncode, 0, result.stderr)
        milestones = ("preflight passed", " pull", "IMAGE ", " stop ", "--wait postgres",
                      "run --rm --no-deps migrate", "run --rm --no-deps grant-app-role",
                      "up -d --no-deps --force-recreate --wait app-web")
        positions = [result.stdout.index(item) for item in milestones]
        self.assertEqual(positions, sorted(positions))
        for failure in ("config", "missing", "legacy", "image", "mismatch", "pull", "stop", "migrate", "grants"):
            with self.subTest(failure=failure):
                result = self.run_mock(failure=failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("--force-recreate", result.stdout)
                self.assertNotIn("synthetic-", result.stdout + result.stderr)
                if failure in ("config", "missing", "legacy"):
                    self.assertNotIn("MUTATION", result.stdout)
                if failure in ("image", "mismatch", "pull"):
                    self.assertNotIn(" stop ", result.stdout)
                if failure == "migrate":
                    self.assertNotIn("run --rm --no-deps grant-app-role", result.stdout)
        config = fixture("outpost")
        config["services"]["api"]["environment"]["SMTP_PASSWORD"] = ""
        result = self.run_mock(config=config)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("MUTATION", result.stdout)
        self.assertNotIn("IMAGE ", result.stdout)

    def test_mutable_and_mixed_images(self):
        for mode in ("oss", "outpost"):
            config = fixture(mode)
            for service in config["services"].values():
                service["image"] = service["image"].replace(":sha-test", ":latest")
            validate(config, mode, "install")
            result = self.run_mock(mode=mode, config=config)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("MUTATION", result.stdout)
            config["services"]["app-web"]["image"] = "ghcr.io/use-brian/app-web:other"
            with self.assertRaises(InvalidConfig):
                validate(config, mode)

    def test_install_stages_before_mutation_and_preserves_env(self):
        # Copy only public implementation files into an isolated synthetic target.
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory)
            for name in ("install.sh", "common.sh", "validate-config.py", ".env.example"):
                (target / name).write_text((HERE / name).read_text())
            env = {"PATH": os.environ["PATH"], "TEST_MODE": "oss", "TEST_SCRIPT": "./install.sh",
                   "TEST_CONFIG": json.dumps(fixture()), "TEST_FAIL": "config"}
            result = subprocess.run(["bash", "-c", MOCK], cwd=target, env=env, text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((target / ".env").exists())
            self.assertFalse(list(target.glob(".env.install.*")))
            self.assertNotIn("MUTATION", result.stdout)
            env["TEST_FAIL"] = "volumes"
            result = subprocess.run(["bash", "-c", MOCK], cwd=target, env=env, text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((target / ".env").exists())
            self.assertNotIn("MUTATION", result.stdout)
            env["TEST_FAIL"] = ""
            result = subprocess.run(["bash", "-c", MOCK], cwd=target, env=env, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((target / ".env").stat().st_mode & 0o777, 0o600)
            original = (target / ".env").read_bytes()
            self.assertNotIn(b"replace-", original)
            result = subprocess.run(["bash", "-c", MOCK], cwd=target, env=env, text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((target / ".env").read_bytes(), original)
            self.assertNotIn("MUTATION", result.stdout)


if __name__ == "__main__":
    unittest.main()
