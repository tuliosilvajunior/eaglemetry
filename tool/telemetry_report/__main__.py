"""Command line for the telemetry report.

    python3 -m tool.telemetry_report pull snapshot.db
    python3 -m tool.telemetry_report report snapshot.db --trips 5
    python3 -m tool.telemetry_report report snapshot.db --lens efficiency --json
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import asdict

from . import lenses  # noqa: F401  registers every lens
from .db import PullError, open_snapshot, pull, recent_charges, recent_trips
from .lens import corpus_lenses, lenses_for
from .render import BOLD, DIM, Style, render_report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="telemetry_report")
    sub = parser.add_subparsers(dest="command", required=True)

    p_pull = sub.add_parser("pull", help="copy the database off the car")
    p_pull.add_argument("snapshot", help="where to write the snapshot")
    p_pull.add_argument("--serial", help="adb device serial")

    p_report = sub.add_parser("report", help="analyse a snapshot")
    p_report.add_argument("snapshot")
    p_report.add_argument("--trips", type=int, default=5)
    p_report.add_argument("--charges", type=int, default=3)
    p_report.add_argument(
        "--session", action="append", help="one session id; repeatable"
    )
    p_report.add_argument(
        "--lens", action="append", help="restrict to these lenses; repeatable"
    )
    p_report.add_argument("--json", action="store_true")
    p_report.add_argument("--problems", action="store_true",
                          help="print only the sessions that have problems")
    p_report.add_argument("--no-colour", action="store_true")

    p_corpus = sub.add_parser(
        "corpus", help="analyse the whole snapshot rather than single sessions"
    )
    p_corpus.add_argument("snapshot")
    p_corpus.add_argument(
        "--lens", action="append", help="restrict to these lenses; repeatable"
    )
    p_corpus.add_argument("--json", action="store_true")
    p_corpus.add_argument("--no-colour", action="store_true")

    p_list = sub.add_parser("lenses", help="list the available lenses")

    args = parser.parse_args(argv)

    if args.command == "pull":
        try:
            written = pull(args.snapshot, args.serial)
        except PullError as error:
            print(f"pull failed: {error}", file=sys.stderr)
            return 1
        print(f"snapshot written to {written}")
        return 0

    if args.command == "lenses":
        from .lens import CORPUS_REGISTRY, REGISTRY

        for name, lens in sorted(REGISTRY.items()):
            print(f"{name:<14} {'/'.join(lens.kinds):<14} {lens.title}")
        for name, lens in sorted(CORPUS_REGISTRY.items()):
            print(f"{name:<14} {'corpus':<14} {lens.title}")
        return 0

    if args.command == "corpus":
        return _corpus(args)

    return _report(args)


def _corpus(args) -> int:
    conn = open_snapshot(args.snapshot)
    reports = [lens.inspect(conn) for lens in corpus_lenses(args.lens)]
    if not reports:
        print("no corpus lens matched", file=sys.stderr)
        return 1

    if args.json:
        print(json.dumps(
            [
                {
                    "lens": r.lens,
                    "findings": [asdict(f) for f in r.findings],
                    "table": r.table,
                    "problems": r.problems,
                }
                for r in reports
            ],
            indent=2,
            default=str,
        ))
        return 0

    style = Style(colour=sys.stdout.isatty() and not args.no_colour)
    head = f"CORPUS  {args.snapshot}"
    print()
    print(style(head, BOLD))
    print(style("=" * len(head), DIM))
    for report in reports:
        if not (report.findings or report.table or report.problems):
            continue
        print(style(f"[{report.lens}]", BOLD))
        for line in render_report(report, style):
            print(line)
    return 0


def _report(args) -> int:
    conn = open_snapshot(args.snapshot)
    sessions = recent_trips(conn, args.trips) + recent_charges(conn, args.charges)
    if args.session:
        wanted = set(args.session)
        sessions = [s for s in sessions if s.id in wanted]
        if not sessions:
            print("no session matched", file=sys.stderr)
            return 1
    sessions.sort(key=lambda s: s.started_utc_millis, reverse=True)

    style = Style(colour=sys.stdout.isatty() and not args.no_colour)
    payload = []

    for session in sessions:
        reports = [
            lens.inspect(conn, session) for lens in lenses_for(session.kind, args.lens)
        ]
        problems = sum(len(r.problems) for r in reports)
        if args.problems and problems == 0:
            continue

        if args.json:
            payload.append({
                "kind": session.kind,
                "id": session.id,
                "startedAtUtcMillis": session.started_utc_millis,
                "reports": [
                    {
                        "lens": r.lens,
                        "findings": [asdict(f) for f in r.findings],
                        "table": r.table,
                        "problems": r.problems,
                    }
                    for r in reports
                ],
            })
            continue

        head = f"{session.kind.upper()}  {session.id}"
        print()
        print(style(head, BOLD))
        print(style("=" * len(head), DIM))
        for report in reports:
            if not (report.findings or report.table or report.problems):
                continue
            print(style(f"[{report.lens}]", BOLD))
            for line in render_report(report, style):
                print(line)
        if problems == 0:
            print(style("  no problems found", DIM))

    if args.json:
        print(json.dumps(payload, indent=2, default=str))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
