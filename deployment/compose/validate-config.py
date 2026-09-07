"""Validate resolved Compose JSON on stdin. Never display environment values."""

import base64
import binascii
import json
import re
import sys
from urllib.parse import urlsplit


class InvalidConfig(Exception):
    """Only fixed, secret-safe diagnostics belong in this exception."""


def validate(config, mode, action="check"):
    def need(env, *names):
        for name in names:
            value = str(env.get(name) or "").strip()
            if not value or value.lower().startswith(("replace-", "generate-")):
                raise InvalidConfig(f"Set {name} before deployment")

    def boolean(env, name):
        if env.get(name) not in ("true", "false"):
            raise InvalidConfig(f"{name} must be literal true or false")
        return env[name] == "true"

    def url(value, schemes, name, origin=True):
        parsed = urlsplit(value)
        if (parsed.scheme not in schemes or not parsed.hostname or parsed.username
                or parsed.password or parsed.query or parsed.fragment
                or (origin and parsed.path) or not parsed.port and parsed.netloc.endswith(":")):
            raise InvalidConfig(f"Invalid {name} URL")
        return parsed

    if mode not in ("oss", "outpost") or config.get("name") != "use-brian":
        raise InvalidConfig("Invalid mode or project name")
    services = config["services"]
    api = services["api"]["environment"]
    web = services["app-web"]["environment"]
    db = services["postgres"]["environment"]
    if any(env.get("USEBRIAN_EDITION") != mode for env in (api, web)):
        raise InvalidConfig("API and app-web edition must match the requested mode")
    for service in services.values():
        for port in service.get("ports", []):
            if port.get("host_ip") != "127.0.0.1":
                raise InvalidConfig("Published ports must bind to IPv4 loopback")
    need(db, "POSTGRES_PASSWORD", "APP_DATABASE_PASSWORD")
    for name in ("POSTGRES_PASSWORD", "APP_DATABASE_PASSWORD"):
        if not re.fullmatch(r"[A-Za-z0-9_~-]{16,}", db[name]):
            raise InvalidConfig(f"{name} must be URI-safe and at least 16 characters")
    secrets = ("JWT_SECRET", "DOC_SYNC_SECRET", "CHANNEL_CREDENTIAL_KEY",
               "DISCORD_CONNECTOR_SECRET", "WA_CONNECTOR_SECRET", "BROWSER_RELAY_SECRET",
               "WECHAT_CONNECTOR_SECRET", "FEISHU_CONNECTOR_SECRET", "BROWSER_VAULT_ENCRYPTION_KEY",
               "BROWSER_CREDENTIAL_ENCRYPTION_KEY", "LLM_PROVIDER_KEY_ENCRYPTION_KEY")
    need(api, *secrets)
    for name in secrets:
        if name.endswith(("_ENCRYPTION_KEY", "_CREDENTIAL_KEY")):
            try:
                valid = len(base64.b64decode(api[name], validate=True)) == 32
            except (ValueError, binascii.Error):
                valid = False
            if not valid:
                raise InvalidConfig(f"{name} must encode 32 bytes as base64")
        elif len(api[name]) < 32:
            raise InvalidConfig(f"{name} must have at least 32 characters")
    # Shell interpolation can override .env for companion services but not the
    # API's env_file. Reject a split credential set before stopping anything.
    for service in services.values():
        env = service.get("environment", {})
        for name in secrets:
            if name in env and env[name] != api[name]:
                raise InvalidConfig("Application service secrets must match the API; clear stale overrides")
    if (api.get("POSTGRES_PASSWORD") != db["POSTGRES_PASSWORD"]
            or api.get("APP_DATABASE_PASSWORD") != db["APP_DATABASE_PASSWORD"]):
        raise InvalidConfig("Database secrets must match .env; clear stale overrides")
    images = []
    names = ["api", "app-web", "doc-sync", "browser-relay", "discord-connector",
             "wa-connector", "wechat-connector", "feishu-connector"]
    if mode == "outpost":
        names.append("auth-web")
    tags = set()
    for name in names:
        image = services[name]["image"]
        match = re.fullmatch(r"ghcr\.io/use-brian/" + name + r":([A-Za-z0-9_][A-Za-z0-9_.-]{0,127})", image)
        if not match:
            raise InvalidConfig("Expected matching published application images")
        tags.add(match[1])
        images.append(image)
    if len(tags) != 1 or services["migrate"]["image"] != services["api"]["image"]:
        raise InvalidConfig("All application images must use one tag")
    if action == "update" and tags & {"latest", "main", "develop"}:
        raise InvalidConfig("Pin BRIAN_IMAGE_TAG to a release or sha-* tag before updates/resuming")

    hosts = []
    for env, name, local_scheme in ((web, "PUBLIC_APP_URL", "http"), (web, "PUBLIC_API_URL", "http"),
                                    (web, "PUBLIC_DOC_SYNC_URL", "ws"), (api, "BROWSER_RELAY_URL", "http")):
        secure_scheme = "wss" if local_scheme == "ws" else "https"
        parsed = url(env[name], (secure_scheme,) if mode == "outpost" else (local_scheme, secure_scheme), name)
        if mode == "oss" and parsed.scheme == local_scheme and parsed.hostname not in ("localhost", "127.0.0.1", "::1"):
            raise InvalidConfig("Non-local public URLs require HTTPS/WSS and external protection")
        hosts.append(parsed.hostname)
    if api["APP_URL"] != web["PUBLIC_APP_URL"] or api["API_URL"] != web["PUBLIC_API_URL"]:
        raise InvalidConfig("API and app-web public URLs must match")
    if mode == "oss":
        if web.get("PUBLIC_PRIMARY_AUTH_URL") or api.get("AUTH_PORTAL_URL"):
            raise InvalidConfig("Clear Outpost auth URLs for OSS mode")
        return images

    auth = services["auth-web"]["environment"]
    need(auth, "AUTH_PORTAL_URL", "COOKIE_DOMAIN")
    portal = url(auth["AUTH_PORTAL_URL"], ("https",), "AUTH_PORTAL_URL")
    hosts.append(portal.hostname)
    suffix = auth["COOKIE_DOMAIN"]
    label = r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"
    if not re.fullmatch(r"\." + label + r"(?:\." + label + r")+", suffix):
        raise InvalidConfig("COOKIE_DOMAIN must be a dot-prefixed DNS domain")
    if len(set(hosts)) != 5 or any(not host.endswith(suffix) or not re.fullmatch(label, host[:-len(suffix)]) for host in hosts):
        raise InvalidConfig("Use five distinct single-level sibling hosts under COOKIE_DOMAIN")
    if (web["PUBLIC_PRIMARY_AUTH_URL"] != auth["AUTH_PORTAL_URL"]
            or auth["AUTHED_APP_URL"] != web["PUBLIC_APP_URL"]
            or any(env.get("COOKIE_DOMAIN") != suffix for env in (api, web))):
        raise InvalidConfig("API, app-web and auth-web URLs/cookie domain must match")
    for name, value in auth.items():
        if name.startswith("OUTPOST_") or name == "AUTH_PORTAL_URL":
            if api.get(name) != value:
                raise InvalidConfig("API and auth-web provider settings must match")
    email = boolean(auth, "OUTPOST_AUTH_EMAIL_ENABLED")
    oidc = boolean(auth, "OUTPOST_AUTH_OIDC_ENABLED")
    boolean(auth, "OUTPOST_OIDC_SUBJECT_IDENTITY_ENABLED")
    if not email and not oidc:
        raise InvalidConfig("Enable at least one Outpost authentication provider")
    if email:
        need(api, "SMTP_HOST", "SMTP_USER", "SMTP_PASSWORD", "EMAIL_FROM_ADDRESS")
        boolean(api, "SMTP_SECURE")
        if not str(api["SMTP_PORT"]).isdigit() or not 1 <= int(api["SMTP_PORT"]) <= 65535:
            raise InvalidConfig("SMTP_PORT must be between 1 and 65535")
    enrollment = auth["OUTPOST_OIDC_ENROLLMENT_MODE"]
    if email or enrollment == "invite_only":
        need(api, "OUTPOST_AUTH_BOOTSTRAP_EMAILS")
        if any(not re.fullmatch(r"[^\s@,]+@[^\s@,]+\.[^\s@,]+", address.strip()) for address in api["OUTPOST_AUTH_BOOTSTRAP_EMAILS"].split(",")):
            raise InvalidConfig("OUTPOST_AUTH_BOOTSTRAP_EMAILS must contain mailbox addresses")
    if oidc:
        need(auth, "OUTPOST_OIDC_ISSUER_URL", "OUTPOST_OIDC_CLIENT_ID", "OUTPOST_OIDC_CLIENT_SECRET",
             "OUTPOST_OIDC_PROVIDER_NAME", "OUTPOST_AUTH_BRIDGE_SECRET")
        url(auth["OUTPOST_OIDC_ISSUER_URL"], ("https",), "OUTPOST_OIDC_ISSUER_URL", origin=False)
        if len(auth["OUTPOST_AUTH_BRIDGE_SECRET"].strip()) < 32:
            raise InvalidConfig("OUTPOST_AUTH_BRIDGE_SECRET must have at least 32 characters")
        if auth["OUTPOST_OIDC_EMAIL_VERIFICATION"] not in ("claim", "issuer"):
            raise InvalidConfig("OUTPOST_OIDC_EMAIL_VERIFICATION must be claim or issuer")
        for origin in auth["OUTPOST_OIDC_ALLOWED_ENDPOINT_ORIGINS"].split(","):
            if origin.strip():
                url(origin.strip(), ("https",), "OUTPOST_OIDC_ALLOWED_ENDPOINT_ORIGINS")
        if enrollment not in ("invite_only", "mapped"):
            raise InvalidConfig("OUTPOST_OIDC_ENROLLMENT_MODE must be invite_only or mapped")
        if enrollment == "mapped":
            raw = auth["OUTPOST_OIDC_WORKSPACE_MAPPINGS"]
            try:
                mappings = json.loads(raw)
            except ValueError:
                raise InvalidConfig("OUTPOST_OIDC_WORKSPACE_MAPPINGS must be valid JSON") from None
            if (len(raw.encode()) > 32768 or not isinstance(mappings, dict)
                    or set(mappings) - {"version", "groupClaim", "additionalScopes", "rules"}
                    or mappings.get("version") != 1 or not isinstance(mappings.get("rules"), list)
                    or not 1 <= len(mappings["rules"]) <= 128):
                raise InvalidConfig("OUTPOST_OIDC_WORKSPACE_MAPPINGS has an invalid shape")
            for rule in mappings["rules"]:
                if (not isinstance(rule, dict) or set(rule) - {"workspaceId", "emailDomain", "group"}
                        or not re.fullmatch(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}", str(rule.get("workspaceId", "")))
                        or ("emailDomain" in rule) == ("group" in rule)
                        or not rule.get("emailDomain", rule.get("group"))
                        or ("group" in rule and not mappings.get("groupClaim"))):
                    raise InvalidConfig("OUTPOST_OIDC_WORKSPACE_MAPPINGS has an invalid rule")
    return images


if __name__ == "__main__":
    try:
        images = validate(json.load(sys.stdin), sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else "check")
    except InvalidConfig as error:
        print(f"Preflight failed: {error}. No stack changes made.", file=sys.stderr)
        sys.exit(1)
    except Exception:
        # Parser exceptions can contain credentials; never print them or a traceback.
        print("Preflight failed: invalid resolved Compose configuration. No stack changes made.", file=sys.stderr)
        sys.exit(1)
    print("\n".join(images))
