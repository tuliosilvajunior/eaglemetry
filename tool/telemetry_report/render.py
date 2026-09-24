"""Turning reports into something you can read at a glance."""

from __future__ import annotations

RESET = "\033[0m"
BOLD = "\033[1m"
DIM = "\033[2m"
RED = "\033[31m"
YELLOW = "\033[33m"


class Style:
    def __init__(self, colour: bool) -> None:
        self.colour = colour

    def __call__(self, text: str, code: str) -> str:
        return f"{code}{text}{RESET}" if self.colour else text


def number(value) -> str:
    if value is None:
        return "--"
    if isinstance(value, bool):
        return "yes" if value else "no"
    if isinstance(value, float):
        if value == 0:
            return "0"
        magnitude = abs(value)
        if magnitude >= 1000:
            return f"{value:,.0f}"
        if magnitude >= 10:
            return f"{value:.1f}"
        if magnitude >= 1:
            return f"{value:.2f}"
        return f"{value:.3f}"
    return str(value)


def render_report(report, style: Style, width: int = 34) -> list[str]:
    lines: list[str] = []
    for finding in report.findings:
        value = number(finding.value)
        if finding.unit and finding.value is not None:
            value = f"{value} {finding.unit}"
        mark = ""
        if finding.disagrees:
            mark = style(f"  != {number(finding.expected)}", YELLOW)
        note = style(f"   {finding.note}", DIM) if finding.note else ""
        lines.append(f"  {finding.label:<{width}} {value:>14}{mark}{note}")
    if report.table:
        lines.extend("  " + line for line in render_table(report.table))
    for problem in report.problems:
        lines.append("  " + style(f"! {problem}", RED))
    return lines


def render_table(table: list[dict]) -> list[str]:
    headers = list(table[0].keys())
    cells = [[number(row.get(h)) for h in headers] for row in table]
    widths = [
        max(len(h), *(len(row[i]) for row in cells)) for i, h in enumerate(headers)
    ]
    out = ["  ".join(h.rjust(w) for h, w in zip(headers, widths))]
    out.append("  ".join("-" * w for w in widths))
    out.extend("  ".join(c.rjust(w) for c, w in zip(row, widths)) for row in cells)
    return out


def wrap(text: str, width: int = 96, indent: str = "  ") -> list[str]:
    words = text.split()
    lines: list[str] = []
    current = indent
    for word in words:
        if len(current) + len(word) + 1 > width and current.strip():
            lines.append(current.rstrip())
            current = indent
        current += word + " "
    if current.strip():
        lines.append(current.rstrip())
    return lines
