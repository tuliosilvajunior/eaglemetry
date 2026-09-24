"""The unit of analysis this tool is built from.

A lens answers one question about one session. It receives the snapshot and
the session, and returns rows of named facts. The runner does the selection,
the ordering and the rendering, so adding a question means adding a lens and
nothing else.

A lens must not compute a number it cannot defend. When an input is absent,
report the absence: `Finding(..., value=None)` prints `--`, which is the same
rule the app itself follows. A lens that substitutes a plausible figure for a
missing one turns this tool into a second source of invented data.
"""

from __future__ import annotations

import sqlite3
from dataclasses import dataclass, field
from typing import Callable, Iterable, Protocol

from .db import Session

REGISTRY: dict[str, "Lens"] = {}
CORPUS_REGISTRY: dict[str, "CorpusLens"] = {}


@dataclass(frozen=True)
class Finding:
    """One named fact.

    `expected` carries what the value should be when something else in the
    snapshot already implies it, so the renderer can mark a disagreement
    without every lens re-implementing the comparison.
    """

    label: str
    value: float | int | str | None
    unit: str = ""
    note: str = ""
    expected: float | None = None
    tolerance: float = 0.0

    @property
    def disagrees(self) -> bool:
        if self.expected is None or not isinstance(self.value, (int, float)):
            return False
        return abs(self.value - self.expected) > max(
            self.tolerance, abs(self.expected) * 0.0
        )


@dataclass
class Report:
    """What one lens found about one session."""

    lens: str
    findings: list[Finding] = field(default_factory=list)
    table: list[dict[str, object]] = field(default_factory=list)
    problems: list[str] = field(default_factory=list)

    def add(self, label: str, value, unit: str = "", **kw) -> None:
        self.findings.append(Finding(label=label, value=value, unit=unit, **kw))

    def problem(self, text: str) -> None:
        self.problems.append(text)


class Lens(Protocol):
    name: str
    title: str
    kinds: tuple[str, ...]

    def inspect(self, conn: sqlite3.Connection, session: Session) -> Report: ...


def register(name: str, title: str, kinds: Iterable[str]) -> Callable:
    """Declare a lens.

    Decorates a plain function so a new component needs no class and no
    registration list to edit.
    """

    def wrap(fn: Callable[[sqlite3.Connection, Session, Report], None]) -> Callable:
        class _Lens:
            pass

        lens = _Lens()
        lens.name = name
        lens.title = title
        lens.kinds = tuple(kinds)

        def inspect(conn: sqlite3.Connection, session: Session) -> Report:
            report = Report(lens=name)
            try:
                fn(conn, session, report)
            except Exception as error:  # a broken lens must not hide the others
                report.problem(f"lens failed: {type(error).__name__}: {error}")
            return report

        lens.inspect = inspect
        REGISTRY[name] = lens
        return fn

    return wrap


class CorpusLens(Protocol):
    """A lens that asks about the whole snapshot rather than one session.

    Some questions have no session to belong to: how many trips carry measured
    energy at all, how much history still has GPS, whether a proposed threshold
    is larger than the spread of the recorded drives. Those are properties of
    the corpus, and answering them per session would only invite the reader to
    add the rows up by hand.
    """

    name: str
    title: str

    def inspect(self, conn: sqlite3.Connection) -> Report: ...


def register_corpus(name: str, title: str) -> Callable:
    """Declare a corpus lens. Same rules as `register`, no session."""

    def wrap(fn: Callable[[sqlite3.Connection, Report], None]) -> Callable:
        class _CorpusLens:
            pass

        lens = _CorpusLens()
        lens.name = name
        lens.title = title

        def inspect(conn: sqlite3.Connection) -> Report:
            report = Report(lens=name)
            try:
                fn(conn, report)
            except Exception as error:  # a broken lens must not hide the others
                report.problem(f"lens failed: {type(error).__name__}: {error}")
            return report

        lens.inspect = inspect
        CORPUS_REGISTRY[name] = lens
        return fn

    return wrap


def corpus_lenses(only: Iterable[str] | None = None) -> list[CorpusLens]:
    wanted = set(only) if only else None
    picked = [
        lens
        for lens in CORPUS_REGISTRY.values()
        if wanted is None or lens.name in wanted
    ]
    return sorted(picked, key=lambda lens: lens.name)


def lenses_for(kind: str, only: Iterable[str] | None = None) -> list[Lens]:
    wanted = set(only) if only else None
    picked = [
        lens
        for lens in REGISTRY.values()
        if kind in lens.kinds and (wanted is None or lens.name in wanted)
    ]
    return sorted(picked, key=lambda lens: lens.name)
