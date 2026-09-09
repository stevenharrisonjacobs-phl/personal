"""Shared write-path fakes for the door tests (test_door_write, test_door_grants)."""

from __future__ import annotations

from door import finance_write as fw


class FakeExecute:
    """Stands in for fw._execute: records every job, replays scripted results."""

    def __init__(self, script=()):
        self.calls = []
        self.script = list(script)

    def __call__(self, sql, params, tool):
        self.calls.append({"sql": sql, "params": list(params), "tool": tool})
        return self.script.pop(0) if self.script else []


def fake(monkeypatch, script=()):
    fx = FakeExecute(script)
    monkeypatch.setattr(fw, "_execute", fx)
    return fx


def pval(call, name):
    for n, _t, v in call["params"]:
        if n == name:
            return v
    raise KeyError(f"{name} not in {[n for n, _, _ in call['params']]}")


def write_calls(fx):
    return [c for c in fx.calls if "BEGIN TRANSACTION" in c["sql"]]
