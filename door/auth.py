"""Google OAuth and per-request identity for the personal door.

A close port of `bobsled-agents/door/auth.py`, with the evaluation-mode
machinery dropped (there is one user here) and Redis swapped for Firestore —
same encrypted `key-value-aio` client storage, but serverless and free at this
scale. See `docs/personal-door-spec.md` §4.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from urllib.parse import urlparse


class DoorConfigurationError(RuntimeError):
    """Raised when the door would start with unsafe or incomplete auth."""


@dataclass(frozen=True)
class Identity:
    """The human identity carried by one authenticated MCP request."""

    subject: str | None
    email: str | None
    email_verified: bool | None = None
    name: str | None = None
    client_id: str | None = None
    scopes: tuple[str, ...] = ()


def _is_loopback(url: str) -> bool:
    hostname = (urlparse(url).hostname or "").lower()
    return hostname in {"localhost", "127.0.0.1", "::1"}


def _email_verified_claim(value: object) -> bool | None:
    """Normalize Google's boolean or token-info string verification claim.

    Google's tokeninfo endpoint returns the STRING "true", not a bool, so a
    truthiness test here would also accept the string "false".
    """
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        normalized = value.strip().lower()
        if normalized == "true":
            return True
        if normalized == "false":
            return False
    return None


def build_auth():
    """Build FastMCP's Google OAuth proxy, failing closed outside local dev."""
    from fastmcp.server.auth.providers.google import GoogleProvider

    client_id = os.environ.get("GOOGLE_OAUTH_CLIENT_ID", "").strip()
    client_secret = os.environ.get("GOOGLE_OAUTH_CLIENT_SECRET", "").strip()
    base_url = os.environ.get("BASE_URL", "http://localhost:8080").rstrip("/")
    insecure_local = os.environ.get("PERSONAL_DOOR_INSECURE_LOCAL", "") == "1"

    if not client_id or not client_secret:
        if insecure_local and _is_loopback(base_url):
            return None
        raise DoorConfigurationError(
            "GOOGLE_OAUTH_CLIENT_ID and GOOGLE_OAUTH_CLIENT_SECRET are required. "
            "No-auth mode is allowed only on a loopback BASE_URL with "
            "PERSONAL_DOOR_INSECURE_LOCAL=1."
        )

    kwargs: dict[str, object] = {
        "client_id": client_id,
        "client_secret": client_secret,
        "base_url": base_url,
        "required_scopes": [
            "openid",
            "profile",
            "https://www.googleapis.com/auth/userinfo.email",
        ],
    }

    signing_key = os.environ.get("JWT_SIGNING_KEY", "").strip()
    storage_key = os.environ.get("STORAGE_ENCRYPTION_KEY", "").strip()
    firestore_project = os.environ.get("FIRESTORE_PROJECT", "").strip()

    if firestore_project or storage_key:
        if not (firestore_project and storage_key and signing_key):
            raise DoorConfigurationError(
                "Persistent OAuth storage requires FIRESTORE_PROJECT, "
                "STORAGE_ENCRYPTION_KEY, and JWT_SIGNING_KEY together."
            )
        from cryptography.fernet import Fernet
        from key_value.aio.stores.firestore import FirestoreStore
        from key_value.aio.wrappers.encryption import FernetEncryptionWrapper

        kwargs["jwt_signing_key"] = signing_key
        kwargs["client_storage"] = FernetEncryptionWrapper(
            key_value=FirestoreStore(
                project=firestore_project,
                database=os.environ.get("FIRESTORE_DATABASE") or None,
                default_collection=os.environ.get(
                    "FIRESTORE_COLLECTION", "personal_door_oauth"
                ),
            ),
            fernet=Fernet(storage_key.encode()),
        )
    elif not _is_loopback(base_url):
        if os.environ.get("PERSONAL_DOOR_ALLOW_EPHEMERAL_OAUTH", "") != "1":
            raise DoorConfigurationError(
                "Production OAuth needs encrypted persistent client storage. "
                "Configure FIRESTORE_PROJECT, STORAGE_ENCRYPTION_KEY, and "
                "JWT_SIGNING_KEY. PERSONAL_DOOR_ALLOW_EPHEMERAL_OAUTH=1 is a "
                "single-instance escape hatch and will force a reconnect after "
                "every restart."
            )
        if signing_key:
            kwargs["jwt_signing_key"] = signing_key

    return GoogleProvider(**kwargs)


def current_identity() -> Identity:
    """Return the Google identity FastMCP validated for the current request."""
    from fastmcp.server.dependencies import get_access_token

    token = get_access_token()
    if token is None:
        return Identity(subject=None, email=None)
    claims = token.claims or {}
    email = str(claims.get("email") or "").strip().lower() or None
    return Identity(
        subject=str(claims.get("sub") or token.subject or "").strip() or None,
        email=email,
        email_verified=_email_verified_claim(claims.get("email_verified")),
        name=str(claims.get("name") or "").strip() or None,
        client_id=str(token.client_id or "").strip() or None,
        scopes=tuple(sorted(str(scope) for scope in (token.scopes or ()))),
    )
