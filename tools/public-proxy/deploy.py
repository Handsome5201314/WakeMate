"""Add one Caddy site, preserving and checking every existing host route."""

import base64
import hashlib
import json
import os
import subprocess
import sys
import urllib.request
from datetime import datetime, timezone
from pathlib import Path


def run(*args):
    result = subprocess.run(args, capture_output=True, text=True, check=False)
    if result.returncode:
        raise RuntimeError(f"{args[0]} {args[1]} failed with exit {result.returncode}")
    return result.stdout


def adapted(path):
    return json.loads(run("caddy", "adapt", "--config", str(path), "--adapter", "caddyfile"))


def active():
    with urllib.request.urlopen("http://127.0.0.1:2019/config/", timeout=10) as response:
        return json.load(response)


def canonical_route(route, config_path):
    # Caddy renumbers route groups and automatically hides its config file.
    groups = {}

    def normalize(value):
        if isinstance(value, list):
            return [normalize(item) for item in value]
        if not isinstance(value, dict):
            return value
        result = {}
        for key, item in value.items():
            if key == "group":
                result[key] = groups.setdefault(item, f"group-{len(groups)}")
            elif key == "hide":
                result[key] = [
                    "/etc/caddy/Caddyfile" if path == str(config_path) else path
                    for path in item
                ]
            else:
                result[key] = normalize(item)
        return result

    return normalize(route)


def host_routes(config, config_path=Path("/etc/caddy/Caddyfile")):
    routes = {}
    for server in config["apps"]["http"]["servers"].values():
        for route in server.get("routes", []):
            for matcher in route.get("match", []):
                for host in matcher.get("host", []):
                    routes[host] = canonical_route(route, config_path)
    return routes


def write_private(path, content):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as output:
        output.write(content)


def main():
    domain = "wakemate.tongyimoheai.top"
    main_path = Path("/etc/caddy/Caddyfile")
    site_path = Path("/etc/caddy/wakemate.caddy")
    site_content = base64.b64decode(sys.argv[1], validate=True)
    if not site_content.startswith((domain + " {").encode()):
        raise RuntimeError("Unexpected WakeMate site configuration")
    with urllib.request.urlopen("http://127.0.0.1:18090/health/ready", timeout=15) as response:
        if json.load(response).get("status") != "ready":
            raise RuntimeError("WakeMate upstream is not ready")

    original = main_path.read_bytes()
    before_disk = host_routes(adapted(main_path))
    before_active = host_routes(active())
    for host, route in before_disk.items():
        if before_active.get(host) != route:
            raise RuntimeError("Existing Caddy disk and active routes differ")
    if site_path.exists() and site_path.read_bytes() != site_content:
        raise RuntimeError("Existing WakeMate site file differs; refusing overwrite")
    directive = b"import /etc/caddy/wakemate.caddy"
    lines = [line.strip() for line in original.splitlines()]
    candidate = original if directive in lines else original + b"\n" + directive + b"\n"
    if domain in before_disk and directive not in lines:
        raise RuntimeError("WakeMate host already configured elsewhere")

    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    staging = main_path.with_name("Caddyfile.wakemate-candidate-" + stamp)
    backup = main_path.with_name("Caddyfile.before-wakemate-" + stamp)
    site_created = not site_path.exists()
    installed = False
    try:
        if site_created:
            write_private(site_path, site_content)
            os.chmod(site_path, 0o644)
        write_private(staging, candidate)
        os.chmod(staging, 0o644)
        candidate_routes = host_routes(adapted(staging), staging)
        for host, route in before_disk.items():
            if candidate_routes.get(host) != route:
                raise RuntimeError("Candidate changes an existing host route")
        if domain not in candidate_routes:
            raise RuntimeError("WakeMate route was not created")
        run("caddy", "validate", "--config", str(staging), "--adapter", "caddyfile")
        if main_path.read_bytes() != original:
            raise RuntimeError("Caddyfile changed during deployment")
        if candidate != original:
            write_private(backup, original)
            os.replace(staging, main_path)
            installed = True
        run("caddy", "reload", "--config", str(main_path), "--adapter", "caddyfile")
        after_active = host_routes(active())
        for host, route in before_active.items():
            if after_active.get(host) != route:
                raise RuntimeError("Active configuration changed an existing host route")
        if domain not in after_active:
            raise RuntimeError("WakeMate route missing from active configuration")
        print(json.dumps({
            "domain": domain,
            "upstream": "127.0.0.1:18090",
            "existing_hosts_unchanged": sorted(before_active),
            "original_config_sha256": hashlib.sha256(original).hexdigest(),
            "original_bytes_preserved": candidate.startswith(original),
            "backup": str(backup) if installed else None,
            "reload": "ok",
        }, indent=2))
    except Exception:
        if installed:
            rollback = main_path.with_name("Caddyfile.wakemate-rollback-" + stamp)
            write_private(rollback, original)
            os.chmod(rollback, 0o644)
            os.replace(rollback, main_path)
            run("caddy", "reload", "--config", str(main_path), "--adapter", "caddyfile")
        if site_created:
            site_path.unlink(missing_ok=True)
        raise
    finally:
        staging.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
