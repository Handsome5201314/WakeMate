import base64
import hashlib
import hmac
import secrets


def digest(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def hash_password(value: str) -> str:
    salt = secrets.token_bytes(16)
    hashed = hashlib.scrypt(value.encode(), salt=salt, n=16384, r=8, p=1)
    return (
        "scrypt$"
        + base64.b64encode(salt).decode()
        + "$"
        + base64.b64encode(hashed).decode()
    )


def verify_password(value: str, encoded: str) -> bool:
    try:
        _, salt, expected = encoded.split("$")
        actual = hashlib.scrypt(
            value.encode(), salt=base64.b64decode(salt), n=16384, r=8, p=1
        )
        return hmac.compare_digest(actual, base64.b64decode(expected))
    except (ValueError, TypeError):
        return False
