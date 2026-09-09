"""Authorize identities, then delegate to the governed finance runtime.

Ported from `bobsled-agents/door/service.py`. The important property: every
governed method calls `_authorize` FIRST, so authorization is a property of this
layer rather than something each tool has to remember to do. A tool added later
cannot ship unprotected by forgetting a decorator.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Any

from .auth import DoorConfigurationError, Identity


def _email_set(raw: str) -> frozenset[str]:
    return frozenset(
        part.strip().lower() for part in (raw or "").split(",") if part.strip()
    )


@dataclass(frozen=True)
class DoorPolicy:
    allowed_emails: frozenset[str]

    @classmethod
    def from_env(cls) -> "DoorPolicy":
        allowed = _email_set(os.environ.get("PERSONAL_DOOR_ALLOWED_EMAILS", ""))
        insecure_local = os.environ.get("PERSONAL_DOOR_INSECURE_LOCAL", "") == "1"
        if not allowed and not insecure_local:
            raise DoorConfigurationError(
                "PERSONAL_DOOR_ALLOWED_EMAILS is empty. This door fronts the "
                "complete finance mirror on a public URL; the allowlist is the "
                "only perimeter, so there is no permissive default."
            )
        return cls(allowed_emails=allowed)


class DoorService:
    """Gate every request on identity, then delegate to the governed runtime."""

    def __init__(self, *, policy: DoorPolicy):
        self.policy = policy

    @classmethod
    def from_env(cls) -> "DoorService":
        return cls(policy=DoorPolicy.from_env())

    # -- identity ---------------------------------------------------------

    def whoami(self, identity: Identity) -> dict[str, Any]:
        """Deliberately UNGATED.

        An unenrolled identity gets a truthful answer with `authorized: False`
        and no data. That turns "I connected with the wrong Google account"
        into a self-diagnosing message instead of an opaque refusal on every
        other tool.
        """
        email = (identity.email or "").lower() or None
        authorized = bool(
            email
            and identity.email_verified is True
            and email in self.policy.allowed_emails
        )
        return {
            "authenticated": bool(identity.subject and email),
            "authorized": authorized,
            "subject": identity.subject,
            "email": email,
            "email_verified": identity.email_verified,
            "name": identity.name,
            "client_id": identity.client_id,
            "scopes": list(identity.scopes),
            "note": (
                None
                if authorized
                else "This Google identity is not enrolled on this door. "
                "Reconnect with the enrolled account."
            ),
        }

    # -- the gate ---------------------------------------------------------

    def _authorize(self, identity: Identity) -> dict[str, Any] | None:
        """Return a refusal dict, or None when the caller may proceed."""
        email = (identity.email or "").strip().lower()
        if not identity.subject or not email:
            return {
                "status": "unauthorized",
                "error": "This door requires a personal Google OAuth session.",
            }
        if identity.email_verified is not True:
            return {
                "status": "forbidden",
                "error": "The Google identity must have a verified email address.",
                "email": email,
            }
        if email not in self.policy.allowed_emails:
            return {
                "status": "forbidden",
                "error": "This Google identity is not enrolled on this door.",
                "email": email,
            }
        return None

    # -- governed finance reads -------------------------------------------

    def list_finance_sources(self, identity: Identity) -> dict[str, Any]:
        refusal = self._authorize(identity)
        if refusal:
            return refusal
        from . import finance_native

        return finance_native.list_finance_sources()

    def describe_finance_source(self, identity: Identity, source: str) -> dict[str, Any]:
        refusal = self._authorize(identity)
        if refusal:
            return refusal
        from . import finance_native

        return finance_native.describe_finance_source(source)

    def run_finance_query(
        self,
        identity: Identity,
        sql: str,
        max_rows: int = 100,
        dry_run: bool = False,
    ) -> dict[str, Any]:
        refusal = self._authorize(identity)
        if refusal:
            return refusal
        from . import finance_native

        return finance_native.run_finance_query(sql, max_rows=max_rows, dry_run=dry_run)

    def list_saved_queries(self, identity: Identity) -> dict[str, Any]:
        refusal = self._authorize(identity)
        if refusal:
            return refusal
        from . import saved_queries

        return saved_queries.list_saved_queries()

    def saved_query(
        self, identity: Identity, name: str, max_rows: int = 100
    ) -> dict[str, Any]:
        refusal = self._authorize(identity)
        if refusal:
            return refusal
        from . import saved_queries

        return saved_queries.saved_query(name, max_rows=max_rows)

    def feed_health(self, identity: Identity, max_rows: int = 100) -> dict[str, Any]:
        refusal = self._authorize(identity)
        if refusal:
            return refusal
        from . import saved_queries

        return saved_queries.feed_health(max_rows=max_rows)

    # -- governed finance writes -------------------------------------------
    #
    # Same property as the reads: `_authorize` FIRST, then delegate to the
    # governed write runtime (finance_write.py), stamping who is writing onto
    # every audit row.

    def _write_actor(self, identity: Identity):
        """The audit stamp for this request.

        U10 SEAM: today every authorized writer is the enrolled human on an
        OAuth session, so window_state is 'human' and the identity is the
        verified email. U10 adds machine identities, per-identity grants, and
        the schedule dial by extending THIS method (and `_authorize`) — the
        write tools themselves never look at who is calling.
        """
        from .finance_write import WriteActor

        return WriteActor(
            identity=(identity.email or "").strip().lower(),
            client_id=identity.client_id,
            window_state="human",
        )

    def record_checkin(self, identity: Identity, payload: dict) -> dict[str, Any]:
        refusal = self._authorize(identity)
        if refusal:
            return refusal
        from . import finance_write

        return finance_write.record_checkin(payload, actor=self._write_actor(identity))

    def record_checkin_failed(self, identity: Identity, reason: str) -> dict[str, Any]:
        refusal = self._authorize(identity)
        if refusal:
            return refusal
        from . import finance_write

        return finance_write.record_checkin_failed(
            reason, actor=self._write_actor(identity)
        )

    def reclassify_transaction(
        self, identity: Identity, transaction_key: str, category: str, notes: str = ""
    ) -> dict[str, Any]:
        refusal = self._authorize(identity)
        if refusal:
            return refusal
        from . import finance_write

        return finance_write.reclassify_transaction(
            transaction_key, category, notes, actor=self._write_actor(identity)
        )

    def set_vendor_override(
        self, identity: Identity, transaction_key: str, vendor_name: str, notes: str = ""
    ) -> dict[str, Any]:
        refusal = self._authorize(identity)
        if refusal:
            return refusal
        from . import finance_write

        return finance_write.set_vendor_override(
            transaction_key, vendor_name, notes, actor=self._write_actor(identity)
        )

    def set_flow_override(
        self, identity: Identity, transaction_key: str, flow_type: str, notes: str = ""
    ) -> dict[str, Any]:
        refusal = self._authorize(identity)
        if refusal:
            return refusal
        from . import finance_write

        return finance_write.set_flow_override(
            transaction_key, flow_type, notes, actor=self._write_actor(identity)
        )

    def add_vendor_mapping(
        self, identity: Identity, vendor_name: str, category_id: str, notes: str = ""
    ) -> dict[str, Any]:
        refusal = self._authorize(identity)
        if refusal:
            return refusal
        from . import finance_write

        return finance_write.add_vendor_mapping(
            vendor_name, category_id, notes, actor=self._write_actor(identity)
        )

    def add_vendor_alias(
        self,
        identity: Identity,
        alias_name: str,
        canonical_vendor_name: str,
        notes: str = "",
    ) -> dict[str, Any]:
        refusal = self._authorize(identity)
        if refusal:
            return refusal
        from . import finance_write

        return finance_write.add_vendor_alias(
            alias_name, canonical_vendor_name, notes, actor=self._write_actor(identity)
        )

    def add_classification_rule(
        self,
        identity: Identity,
        rule_id: str,
        priority: int,
        description_regex: str,
        category: str,
        subcategory: str = "",
    ) -> dict[str, Any]:
        refusal = self._authorize(identity)
        if refusal:
            return refusal
        from . import finance_write

        return finance_write.add_classification_rule(
            rule_id,
            priority,
            description_regex,
            category,
            subcategory,
            actor=self._write_actor(identity),
        )

    def add_vendor_rule(
        self,
        identity: Identity,
        rule_id: str,
        priority: int,
        description_regex: str,
        vendor_name: str,
        notes: str = "",
    ) -> dict[str, Any]:
        refusal = self._authorize(identity)
        if refusal:
            return refusal
        from . import finance_write

        return finance_write.add_vendor_rule(
            rule_id,
            priority,
            description_regex,
            vendor_name,
            notes,
            actor=self._write_actor(identity),
        )
