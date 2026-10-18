"""Check the deployed public routes without displaying credentials or user data."""

import argparse
import json
import urllib.error
import urllib.request
from pathlib import Path


def request(url, *, body=None, headers=None):
    data = None if body is None else json.dumps(body).encode()
    merged = {"Content-Type": "application/json", **(headers or {})}
    query = urllib.request.Request(url, data=data, headers=merged)
    try:
        response = urllib.request.urlopen(query, timeout=25)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        return response.status, response.headers, response.read(), response.url


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default="https://wakemate.tongyimoheai.top")
    parser.add_argument("--env-file", type=Path)
    args = parser.parse_args()
    base = args.base_url.rstrip("/")
    report = {}
    for path in ("/health/ready", "/admin", "/assets/styles.css", "/assets/app.js", "/assets/vendor/lucide.min.js"):
        status, headers, body, _ = request(base + path)
        assert status == 200 and body, f"Public route failed: {path} ({status})"
        if path == "/admin":
            assert headers.get("Strict-Transport-Security"), "HSTS missing"
            assert b"login-form" in body, "Admin HTML missing"
        report[path] = status

    status, _, _, _ = request(base + "/api/admin/overview")
    assert status == 401, f"Unauthenticated admin access: {status}"
    report["unauthenticated_admin"] = status
    for ip in ("203.0.113.90", "203.0.113.91"):
        status, _, _, _ = request(
            base + "/api/auth/password",
            body={"username": "wakemate-public-proxy-check", "password": "invalid-check-password"},
            headers={"X-Forwarded-For": ip, "Forwarded": f"for={ip};proto=http"},
        )
        assert status == 401, f"Unexpected invalid login result: {status}"
    report["invalid_password"] = 401

    env_path = args.env_file or Path(__file__).resolve().parents[3] / ".env"
    settings = {}
    for line in env_path.read_text(encoding="utf-8-sig").splitlines():
        if line.startswith("WAKEMATE_ADMIN_PASSWORD="):
            settings["password"] = line.partition("=")[2].strip().strip("\"'")
    if not settings.get("password"):
        raise RuntimeError("WakeMate administrator password is unavailable")
    status, _, body, _ = request(
        base + "/api/auth/password", body={"username": "admin", "password": settings["password"]}
    )
    assert status == 200, f"Administrator login failed: {status}"
    session = json.loads(body)
    assert session["role"] == "admin"
    status, _, _, _ = request(
        base + "/api/admin/overview", headers={"Authorization": "Bearer " + session["access_token"]}
    )
    assert status == 200, f"Authenticated overview failed: {status}"
    report["authenticated_admin"] = status
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
