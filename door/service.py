"""Authorize identities, then delegate to the governed finance runtime.

Ported from `bobsled-agents/door/service.py`. The important property: every
governed method calls `_authorize` FIRST, so authorization is a property of this
layer rather than something each tool has to remember to do. A tool added later
cannot ship unprotected by forgetting a decorator.
"""

from __future__ import annotations

import datetime as dt
import json
import os
import re
from dataclasses import dataclass, field
from typing import Any, Callable, Mapping
from zoneinfo import ZoneInfo

from .auth import DoorConfigurationError, Identity, machine_token_digests


def _email_set(raw: str) -> frozenset[str]:
    return frozenset(
        part.strip().lower() for part in (raw or "").split(",") if part.strip()
    )


# ── the governed tool catalog, by family (U10) ───────────────────────────────
#
# Grants name tools from these sets and nothing else — a typo in a grant is a
# startup error, not a silent lifetime denial. The split inside the writes
# matters: check-in writes (the routine's own ledger) are never window-gated,
# classification writes (which change how every dollar is categorized) are.

READ_TOOLS = frozenset(
    {
        "list_finance_sources",
        "describe_finance_source",
        "run_finance_query",
        "list_saved_queries",
        "saved_query",
        "feed_health",
    }
)
CHECKIN_WRITE_TOOLS = frozenset({"record_checkin", "record_checkin_failed"})
CLASSIFICATION_WRITE_TOOLS = frozenset(
    {
        "reclassify_transaction",
        "set_vendor_override",
        "set_flow_override",
        "add_vendor_mapping",
        "add_vendor_alias",
        "add_classification_rule",
        "add_vendor_rule",
    }
)
WRITE_TOOLS = CHECKIN_WRITE_TOOLS | CLASSIFICATION_WRITE_TOOLS

_EASTERN = ZoneInfo("America/New_York")
_WINDOW_RE = re.compile(r"^([01]\d|2[0-3]):([0-5]\d)-([01]\d|2[0-3]):([0-5]\d)$")
_GRANT_KEYS = {"write_tools", "read_tools", "window"}


@dataclass(frozen=True)
class MachineGrant:
    """What one machine identity may do, and when."""

    write_tools: frozenset[str]
    read_tools: frozenset[str]
    read_all: bool
    window: tuple[int, int] | None  # inclusive minutes-of-day in ET; None = always
    window_raw: str


def _parse_window(raw: object, name: str) -> tuple[tuple[int, int] | None, str]:
    if raw is None:
        return None, "always"
    if not isinstance(raw, str):
        raise DoorConfigurationError(f"grant {name!r}: window must be a string.")
    if raw == "always":
        return None, raw
    match = _WINDOW_RE.match(raw)
    if not match:
        raise DoorConfigurationError(
            f"grant {name!r}: window must be 'always' or 'HH:MM-HH:MM' "
            f"(America/New_York, inclusive at both ends), got {raw!r}."
        )
    start = int(match.group(1)) * 60 + int(match.group(2))
    end = int(match.group(3)) * 60 + int(match.group(4))
    if end <= start:
        raise DoorConfigurationError(
            f"grant {name!r}: window {raw!r} must end after it starts "
            "(wrap-around windows are not supported)."
        )
    return (start, end), raw


def _parse_tool_list(raw: object, universe: frozenset[str], name: str, kind: str) -> frozenset[str]:
    if not isinstance(raw, list) or not all(isinstance(t, str) for t in raw):
        raise DoorConfigurationError(
            f"grant {name!r}: {kind} must be a list of tool names."
        )
    unknown = sorted(set(raw) - universe)
    if unknown:
        raise DoorConfigurationError(
            f"grant {name!r}: unknown {kind} {unknown} — valid names: "
            f"{sorted(universe)}."
        )
    return frozenset(raw)


def _parse_grants(raw: str) -> dict[str, MachineGrant]:
    """Parse PERSONAL_DOOR_GRANTS, refusing anything it cannot fully vouch for."""
    try:
        parsed = json.loads(raw)
    except ValueError as exc:
        raise DoorConfigurationError(
            f"PERSONAL_DOOR_GRANTS is not valid JSON: {exc}"
        ) from exc
    if not isinstance(parsed, dict):
        raise DoorConfigurationError(
            "PERSONAL_DOOR_GRANTS must be a JSON object: identity name -> grant."
        )
    grants: dict[str, MachineGrant] = {}
    for name, spec in parsed.items():
        if not isinstance(name, str) or not name.strip():
            raise DoorConfigurationError("PERSONAL_DOOR_GRANTS has an empty identity name.")
        if not isinstance(spec, dict):
            raise DoorConfigurationError(f"grant {name!r} must be a JSON object.")
        unknown = sorted(set(spec) - _GRANT_KEYS)
        if unknown:
            raise DoorConfigurationError(
                f"grant {name!r}: unknown keys {unknown} — valid keys: "
                f"{sorted(_GRANT_KEYS)}."
            )
        write_tools = _parse_tool_list(
            spec.get("write_tools", []), WRITE_TOOLS, name, "write_tools"
        )
        raw_reads = spec.get("read_tools", [])
        if raw_reads == "all":
            read_all, read_tools = True, frozenset()
        else:
            read_all = False
            read_tools = _parse_tool_list(raw_reads, READ_TOOLS, name, "read_tools")
        window, window_raw = _parse_window(spec.get("window"), name)
        grants[name.strip()] = MachineGrant(
            write_tools=write_tools,
            read_tools=read_tools,
            read_all=read_all,
            window=window,
            window_raw=window_raw,
        )
    return grants


@dataclass(frozen=True)
class DoorPolicy:
    allowed_emails: frozenset[str]
    grants: Mapping[str, MachineGrant] = field(default_factory=dict)

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
        # Fail closed at STARTUP, like the allowlist above: machine tokens
        # configured with missing/malformed grants would otherwise boot a door
        # that refuses every scheduled call at runtime with nothing in the
        # deploy output naming the actual mistake. machine_token_digests()
        # itself raises on a malformed digests env.
        digests = machine_token_digests()
        raw_grants = os.environ.get("PERSONAL_DOOR_GRANTS", "").strip()
        if digests and not raw_grants:
            raise DoorConfigurationError(
                "PERSONAL_DOOR_MACHINE_TOKEN_DIGESTS is set but "
                "PERSONAL_DOOR_GRANTS is missing. Machine identities are "
                "default-deny, so a door in this state would authenticate "
                "callers only to refuse every call — configure the grants or "
                "remove the digests."
            )
        grants = _parse_grants(raw_grants) if raw_grants else {}
        return cls(allowed_emails=allowed, grants=grants)


def _utc_now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


class DoorService:
    """Gate every request on identity, then delegate to the governed runtime."""

    def __init__(
        self,
        *,
        policy: DoorPolicy,
        now: Callable[[], dt.datetime] | None = None,
    ):
        self.policy = policy
        # The clock seam for the window dial. Injected in tests; the default
        # is timezone-aware UTC, converted to America/New_York per call, so
        # the container's TZ setting is irrelevant.
        self._now = now or _utc_now

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
        if identity.machine:
            granted = identity.machine in self.policy.grants
            return {
                "authenticated": True,
                "authorized": granted,
                "subject": identity.subject,
                "machine": identity.machine,
                "email": None,
                "client_id": identity.client_id,
                "note": (
                    None
                    if granted
                    else "This machine identity has no grants on this door. "
                    "Machine identities are default-deny; enrollment is a "
                    "PERSONAL_DOOR_GRANTS entry, not a retry."
                ),
            }
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

    def _authorize(self, identity: Identity, tool: str | None = None) -> dict[str, Any] | None:
        """Return a refusal dict, or None when the caller may proceed.

        Humans (OAuth) keep the pre-U10 behavior: the allowlist admits them to
        the whole catalog, every hour. Machines are gated per tool by the
        grants map, so every governed method names the tool it fronts; a
        method that forgets stays fail-closed (tool=None refuses machines).
        """
        if identity.machine:
            return self._authorize_machine(identity, tool)
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

    def _authorize_machine(
        self, identity: Identity, tool: str | None
    ) -> dict[str, Any] | None:
        """The machine gate: default-deny, per-tool grants, ET window dial."""
        name = identity.machine or ""
        subject = f"machine|{name}"
        grant = self.policy.grants.get(name)
        if grant is None:
            return {
                "status": "forbidden",
                "error": (
                    f"Machine identity {name!r} has no grants on this door. "
                    "Machine identities are default-deny: absence from "
                    "PERSONAL_DOOR_GRANTS refuses every governed call."
                ),
                "identity": subject,
            }
        if tool is None or tool not in (WRITE_TOOLS | READ_TOOLS):
            return {
                "status": "forbidden",
                "error": (
                    f"{tool!r} is not a governed tool this door can grant to "
                    f"machine identity {name!r}."
                ),
                "identity": subject,
            }
        if tool in WRITE_TOOLS:
            if tool not in grant.write_tools:
                return {
                    "status": "forbidden",
                    "error": f"Write tool '{tool}' is not granted to machine identity {name!r}.",
                    "identity": subject,
                }
            if tool in CLASSIFICATION_WRITE_TOOLS and not self._window_open(grant):
                now_et = self._now().astimezone(_EASTERN)
                return {
                    "status": "forbidden",
                    "error": (
                        f"Classification tool '{tool}' is granted to {name!r} "
                        f"only inside its {grant.window_raw} America/New_York "
                        f"window; it is now {now_et.strftime('%H:%M')} "
                        "America/New_York. Do not retry — the schedule dial "
                        "refused this on purpose."
                    ),
                    "identity": subject,
                    "window": grant.window_raw,
                }
            return None
        if grant.read_all or tool in grant.read_tools:
            return None
        return {
            "status": "forbidden",
            "error": f"Read tool '{tool}' is not granted to machine identity {name!r}.",
            "identity": subject,
        }

    def _window_open(self, grant: MachineGrant) -> bool:
        """Is the grant's ET window open right now? Inclusive at both ends."""
        if grant.window is None:
            return True
        start, end = grant.window
        now_et = self._now().astimezone(_EASTERN)
        minutes = now_et.hour * 60 + now_et.minute
        return start <= minutes <= end

    # -- governed finance reads -------------------------------------------

    def list_finance_sources(self, identity: Identity) -> dict[str, Any]:
        refusal = self._authorize(identity, "list_finance_sources")
        if refusal:
            return refusal
        from . import finance_native

        return finance_native.list_finance_sources()

    def describe_finance_source(self, identity: Identity, source: str) -> dict[str, Any]:
        refusal = self._authorize(identity, "describe_finance_source")
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
        refusal = self._authorize(identity, "run_finance_query")
        if refusal:
            return refusal
        from . import finance_native

        return finance_native.run_finance_query(sql, max_rows=max_rows, dry_run=dry_run)

    def list_saved_queries(self, identity: Identity) -> dict[str, Any]:
        refusal = self._authorize(identity, "list_saved_queries")
        if refusal:
            return refusal
        from . import saved_queries

        return saved_queries.list_saved_queries()

    def saved_query(
        self, identity: Identity, name: str, max_rows: int = 100
    ) -> dict[str, Any]:
        refusal = self._authorize(identity, "saved_query")
        if refusal:
            return refusal
        from . import saved_queries

        return saved_queries.saved_query(name, max_rows=max_rows)

    def feed_health(self, identity: Identity, max_rows: int = 100) -> dict[str, Any]:
        refusal = self._authorize(identity, "feed_health")
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

        Humans on OAuth are always window_state='human'. A machine identity is
        'human' only while inside its bounded America/New_York window (the
        hours a human plausibly sees the results land) and 'autonomous'
        otherwise — including identities whose window is 'always', which have
        no human-hours claim to make. The write tools themselves never look at
        who is calling; this method and `_authorize` are the whole story.
        """
        from .finance_write import WriteActor

        if identity.machine:
            grant = self.policy.grants.get(identity.machine)
            inside = bool(
                grant is not None
                and grant.window is not None
                and self._window_open(grant)
            )
            return WriteActor(
                identity=identity.subject or f"machine|{identity.machine}",
                client_id=identity.client_id,
                window_state="human" if inside else "autonomous",
            )
        return WriteActor(
            identity=(identity.email or "").strip().lower(),
            client_id=identity.client_id,
            window_state="human",
        )

    def record_checkin(self, identity: Identity, payload: dict) -> dict[str, Any]:
        refusal = self._authorize(identity, "record_checkin")
        if refusal:
            return refusal
        from . import finance_write

        return finance_write.record_checkin(payload, actor=self._write_actor(identity))

    def record_checkin_failed(self, identity: Identity, reason: str) -> dict[str, Any]:
        refusal = self._authorize(identity, "record_checkin_failed")
        if refusal:
            return refusal
        from . import finance_write

        return finance_write.record_checkin_failed(
            reason, actor=self._write_actor(identity)
        )

    def reclassify_transaction(
        self, identity: Identity, transaction_key: str, category: str, notes: str = ""
    ) -> dict[str, Any]:
        refusal = self._authorize(identity, "reclassify_transaction")
        if refusal:
            return refusal
        from . import finance_write

        return finance_write.reclassify_transaction(
            transaction_key, category, notes, actor=self._write_actor(identity)
        )

    def set_vendor_override(
        self, identity: Identity, transaction_key: str, vendor_name: str, notes: str = ""
    ) -> dict[str, Any]:
        refusal = self._authorize(identity, "set_vendor_override")
        if refusal:
            return refusal
        from . import finance_write

        return finance_write.set_vendor_override(
            transaction_key, vendor_name, notes, actor=self._write_actor(identity)
        )

    def set_flow_override(
        self, identity: Identity, transaction_key: str, flow_type: str, notes: str = ""
    ) -> dict[str, Any]:
        refusal = self._authorize(identity, "set_flow_override")
        if refusal:
            return refusal
        from . import finance_write

        return finance_write.set_flow_override(
            transaction_key, flow_type, notes, actor=self._write_actor(identity)
        )

    def add_vendor_mapping(
        self, identity: Identity, vendor_name: str, category_id: str, notes: str = ""
    ) -> dict[str, Any]:
        refusal = self._authorize(identity, "add_vendor_mapping")
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
        refusal = self._authorize(identity, "add_vendor_alias")
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
        refusal = self._authorize(identity, "add_classification_rule")
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
        refusal = self._authorize(identity, "add_vendor_rule")
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
