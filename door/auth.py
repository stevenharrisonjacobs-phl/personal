"""Google OAuth and per-request identity for the personal door.

A close port of `bobsled-agents/door/auth.py`, with the evaluation-mode
machinery dropped (there is one user here) and Redis swapped for Firestore —
same encrypted `key-value-aio` client storage, but serverless and free at this
scale. See `docs/personal-door-spec.md` §4.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import secrets
from dataclasses import dataclass
from typing import Mapping
from urllib.parse import urlparse


class DoorConfigurationError(RuntimeError):
    """Raised when the door would start with unsafe or incomplete auth."""


@dataclass(frozen=True)
class Identity:
    """The identity carried by one authenticated MCP request.

    Either a human (Google OAuth: subject/email/etc.) or a machine
    (`machine` set to the identity name, email None, subject
    'machine|<name>'). Everything downstream branches on `machine`.
    """

    subject: str | None
    email: str | None
    email_verified: bool | None = None
    name: str | None = None
    client_id: str | None = None
    scopes: tuple[str, ...] = ()
    machine: str | None = None


# ── machine-token identities (U10) ───────────────────────────────────────────
#
# Non-interactive callers (the cloud check-in routine, its watchdog, the deploy
# smoke) cannot do Google OAuth. They present a static bearer token instead.
# The door NEVER stores those tokens — only their SHA-256 digests, so a leaked
# door environment cannot be replayed as a caller.

MACHINE_CLAIM = "personal_door_machine"
MACHINE_TOKEN_DIGESTS_ENV = "PERSONAL_DOOR_MACHINE_TOKEN_DIGESTS"

_SHA256_HEX_RE = re.compile(r"^[0-9a-f]{64}$")

# The scopes GoogleProvider requires. Shared with the machine verifier because
# FastMCP's RequireAuthMiddleware checks the auth provider's required_scopes
# against every verified token's scopes — see _build_machine_verifier.
GOOGLE_REQUIRED_SCOPES = [
    "openid",
    "profile",
    "https://www.googleapis.com/auth/userinfo.email",
]


def machine_token_digests() -> dict[str, str]:
    """Parse the digests env var, failing closed on anything malformed.

    Returns {} when unset — the pre-U10 door. A malformed value raises at
    startup rather than silently disabling machine auth: a door that boots
    with tokens half-configured would refuse every scheduled run at 06:10
    with nothing in the logs pointing at the actual typo.
    """
    raw = os.environ.get(MACHINE_TOKEN_DIGESTS_ENV, "").strip()
    if not raw:
        return {}
    try:
        parsed = json.loads(raw)
    except ValueError as exc:
        raise DoorConfigurationError(
            f"{MACHINE_TOKEN_DIGESTS_ENV} is not valid JSON: {exc}"
        ) from exc
    if not isinstance(parsed, dict) or not parsed:
        raise DoorConfigurationError(
            f"{MACHINE_TOKEN_DIGESTS_ENV} must be a non-empty JSON object of "
            "identity name -> sha256 hex digest."
        )
    digests: dict[str, str] = {}
    for name, digest in parsed.items():
        if not isinstance(name, str) or not name.strip():
            raise DoorConfigurationError(
                f"{MACHINE_TOKEN_DIGESTS_ENV} has an empty identity name."
            )
        if not isinstance(digest, str) or not _SHA256_HEX_RE.match(digest):
            raise DoorConfigurationError(
                f"{MACHINE_TOKEN_DIGESTS_ENV} entry {name!r} is not a 64-char "
                "lowercase sha256 hex digest."
            )
        digests[name.strip()] = digest
    return digests


def _match_machine_token(token: str, digests: Mapping[str, str]) -> str | None:
    """Name the machine identity whose digest matches this token, else None.

    Constant-time by construction: the presented token is hashed once, every
    configured digest is checked with secrets.compare_digest, and the loop
    never exits early — timing reveals neither which entry matched nor how
    close a near-miss came.
    """
    if not token or not digests:
        return None
    presented = hashlib.sha256(token.encode("utf-8")).hexdigest()
    matched: str | None = None
    for name in sorted(digests):
        if secrets.compare_digest(presented, digests[name]):
            matched = name
    return matched


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
    """Compose the door's transport auth: Google OAuth plus machine tokens.

    When machine-token digests are configured, the two verification paths are
    composed with FastMCP's `MultiAuth` (fastmcp.server.auth) — the sanctioned
    seam for exactly this shape: the Google provider keeps ALL routes and OAuth
    metadata and is tried first on every bearer; the machine verifier only adds
    token verification, tried second. Without digests this returns exactly the
    pre-U10 provider.
    """

    def _google_provider():
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
            "required_scopes": list(GOOGLE_REQUIRED_SCOPES),
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
            from key_value.aio.stores.firestore import (
                FirestoreStore,
                FirestoreV1CollectionSanitizationStrategy,
                FirestoreV1KeySanitizationStrategy,
            )
            from key_value.aio.wrappers.encryption import FernetEncryptionWrapper

            # The sanitization strategies are NOT optional here, despite defaulting
            # to None. claude.ai registers itself with a client_id that is a URL —
            # `https://claude.ai/oauth/mcp-oauth-client-metadata` — and Firestore
            # document IDs cannot contain "/". Without these, the very first OAuth
            # callback dies with `Document name ... lacks a collection id`, which
            # surfaces to the user as a bare "Internal Server Error" with nothing
            # linking it back to key encoding.
            kwargs["jwt_signing_key"] = signing_key
            kwargs["client_storage"] = FernetEncryptionWrapper(
                key_value=FirestoreStore(
                    project=firestore_project,
                    database=os.environ.get("FIRESTORE_DATABASE") or None,
                    default_collection=os.environ.get(
                        "FIRESTORE_COLLECTION", "personal_door_oauth"
                    ),
                    key_sanitization_strategy=FirestoreV1KeySanitizationStrategy(),
                    collection_sanitization_strategy=FirestoreV1CollectionSanitizationStrategy(),
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

    digests = machine_token_digests()
    google = _google_provider()
    if not digests:
        return google

    from fastmcp.server.auth import MultiAuth

    # The verifier carries the Google provider's EFFECTIVE required scopes,
    # read back from the built provider rather than from our request list:
    # GoogleProvider normalizes short scope names (e.g. 'profile' becomes
    # 'https://www.googleapis.com/auth/userinfo.profile'), and the middleware
    # compares tokens against the NORMALIZED list — a token carrying the
    # request-form scopes would 403 on every machine call.
    transport_scopes = list(google.required_scopes or []) if google else []
    verifier = _build_machine_verifier(digests, transport_scopes)
    if google is None:
        # Loopback-insecure dev with digests deliberately set: machine tokens
        # are testable locally, and every request now needs a bearer.
        return MultiAuth(verifiers=[verifier])
    return MultiAuth(server=google, verifiers=[verifier])


def _build_machine_verifier(digests: Mapping[str, str], transport_scopes: list[str] | None = None):
    """A TokenVerifier that accepts only configured machine tokens.

    Defined inside a factory so importing door.auth never imports fastmcp —
    the offline test suite runs without it, same as the rest of this module.
    """
    from fastmcp.server.auth import AccessToken, TokenVerifier

    scopes = list(transport_scopes or [])

    class MachineTokenVerifier(TokenVerifier):
        async def verify_token(self, token: str) -> AccessToken | None:
            name = _match_machine_token(token, digests)
            if name is None:
                return None
            return AccessToken(
                token=token,
                client_id=f"machine|{name}",
                subject=f"machine|{name}",
                # Transport artifact, not a claim about the caller: FastMCP's
                # RequireAuthMiddleware checks the composed provider's
                # required_scopes (Google's) against every verified token, so
                # a machine token must carry them to reach the service layer.
                # current_identity() strips them — the machine Identity has no
                # scopes, and authorization is entirely the grants map.
                scopes=scopes,
                claims={MACHINE_CLAIM: name},
            )

    return MachineTokenVerifier()


def current_identity() -> Identity:
    """Return the identity FastMCP validated for the current request."""
    from fastmcp.server.dependencies import get_access_token

    token = get_access_token()
    if token is None:
        return Identity(subject=None, email=None)
    return _identity_from_access_token(token)


def _identity_from_access_token(token) -> Identity:
    """Map a verified transport token onto an Identity (pure; offline-testable).

    A token carrying the machine claim becomes a machine Identity with NO email
    and NO scopes — the transport scopes on a machine token exist only to pass
    RequireAuthMiddleware and say nothing about the caller.
    """
    claims = getattr(token, "claims", None) or {}
    machine = str(claims.get(MACHINE_CLAIM) or "").strip() or None
    if machine:
        return Identity(
            subject=f"machine|{machine}",
            email=None,
            machine=machine,
            client_id=str(getattr(token, "client_id", "") or "").strip() or None,
        )
    email = str(claims.get("email") or "").strip().lower() or None
    return Identity(
        subject=str(claims.get("sub") or token.subject or "").strip() or None,
        email=email,
        email_verified=_email_verified_claim(claims.get("email_verified")),
        name=str(claims.get("name") or "").strip() or None,
        client_id=str(token.client_id or "").strip() or None,
        scopes=tuple(sorted(str(scope) for scope in (token.scopes or ()))),
    )
