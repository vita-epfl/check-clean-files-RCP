#!/usr/bin/env python3

from __future__ import annotations

import argparse
import csv
import json
import re
from dataclasses import dataclass
from datetime import date
from pathlib import Path
from typing import Iterable


SCOPES = {
    "datasets": {
        "title": "Datasets",
        "csv": "files_datasets.csv",
        "summary": "files_datasets.summary.txt",
    },
    "staff": {
        "title": "Vita Staff",
        "csv": "files_staff.csv",
        "summary": "files_staff.summary.txt",
    },
    "students": {
        "title": "Vita Students",
        "csv": "files_students.csv",
        "summary": "files_students.summary.txt",
    },
}

REQUIRED_COLUMNS = ["Directory", "Size", "Modified", "Accessed"]
OPTIONAL_COLUMNS = ["Owner"]
SIZE_RE = re.compile(r"^\s*([0-9.]+)\s*([KMGTPE]?i?B?|B)?\s*$", re.IGNORECASE)
SIZE_UNITS = {
    "": 1,
    "B": 1,
    "K": 1024,
    "KB": 1024,
    "KIB": 1024,
    "M": 1024**2,
    "MB": 1024**2,
    "MIB": 1024**2,
    "G": 1024**3,
    "GB": 1024**3,
    "GIB": 1024**3,
    "T": 1024**4,
    "TB": 1024**4,
    "TIB": 1024**4,
    "P": 1024**5,
    "PB": 1024**5,
    "PIB": 1024**5,
    "E": 1024**6,
    "EB": 1024**6,
    "EIB": 1024**6,
}


@dataclass
class ScopeReport:
    key: str
    title: str
    csv_path: Path
    summary_path: Path
    rows: list[dict[str, str]]

    @property
    def too_large_count(self) -> int:
        return sum(1 for row in self.rows if row.get("Size") == "TOO_LARGE")

    @property
    def known_bytes(self) -> int:
        total = 0
        for row in self.rows:
            parsed = parse_size(row.get("Size", ""))
            if parsed is not None:
                total += parsed
        return total

    @property
    def has_owner_data(self) -> bool:
        return any(row.get("Owner") for row in self.rows)

    @property
    def owner_counts(self) -> dict[str, int]:
        counts: dict[str, int] = {}
        for row in self.rows:
            owner = row.get("Owner")
            if not owner:
                continue
            counts[owner] = counts.get(owner, 0) + 1
        return counts


def parse_size(value: str) -> int | None:
    if not value or value == "TOO_LARGE":
        return None
    match = SIZE_RE.match(value)
    if not match:
        return None
    number = float(match.group(1))
    unit = (match.group(2) or "").upper()
    return int(number * SIZE_UNITS.get(unit, 1))


def human_size(num_bytes: int) -> str:
    value = float(num_bytes)
    for unit in ("B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB"):
        if value < 1024 or unit == "EiB":
            if unit == "B":
                return f"{int(value)} B"
            return f"{value:.1f} {unit}"
        value /= 1024
    return f"{num_bytes} B"


def markdown_escape(value: object) -> str:
    text = str(value)
    return text.replace("|", "\\|").replace("\n", " ")


def load_scope(run_dir: Path, key: str, spec: dict[str, str]) -> ScopeReport:
    csv_path = run_dir / spec["csv"]
    summary_path = run_dir / spec["summary"]
    if not csv_path.exists():
        raise FileNotFoundError(f"Missing CSV for {key}: {csv_path}")

    with csv_path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        fieldnames = reader.fieldnames or []
        missing_columns = [column for column in REQUIRED_COLUMNS if column not in fieldnames]
        unexpected_columns = [
            column for column in fieldnames if column not in REQUIRED_COLUMNS + OPTIONAL_COLUMNS
        ]
        if missing_columns or unexpected_columns:
            raise ValueError(
                f"{csv_path} has columns {fieldnames}; missing {missing_columns}, "
                f"unexpected {unexpected_columns}"
            )
        rows = list(reader)

    return ScopeReport(
        key=key,
        title=spec["title"],
        csv_path=csv_path,
        summary_path=summary_path,
        rows=rows,
    )


def sorted_rows(rows: Iterable[dict[str, str]]) -> list[dict[str, str]]:
    return sorted(
        rows,
        key=lambda row: (
            parse_size(row.get("Size", "")) is None,
            -(parse_size(row.get("Size", "")) or 0),
            row.get("Directory", ""),
        ),
    )


def render_table(headers: list[str], rows: list[list[object]]) -> list[str]:
    lines = [
        "| " + " | ".join(headers) + " |",
        "| " + " | ".join("---" for _ in headers) + " |",
    ]
    for row in rows:
        lines.append("| " + " | ".join(markdown_escape(cell) for cell in row) + " |")
    return lines


def render_scope(scope: ScopeReport, limit: int) -> list[str]:
    lines = [
        f"## {scope.title}",
        "",
        f"- CSV: `{scope.csv_path.name}`",
        f"- Summary: `{scope.summary_path.name}`" if scope.summary_path.exists() else "- Summary: missing",
        f"- Entries: {len(scope.rows)}",
        f"- TOO_LARGE entries: {scope.too_large_count}",
        f"- Total known size: {human_size(scope.known_bytes)}",
        "",
    ]

    owner_rows = sorted(scope.owner_counts.items(), key=lambda item: (-item[1], item[0]))[:limit]
    if owner_rows:
        lines.extend(render_table(["Owner", "Entries"], [[owner, count] for owner, count in owner_rows]))
        lines.append("")

    top_rows = sorted_rows(scope.rows)[:limit]
    if top_rows:
        headers = ["Directory", "Size", "Modified", "Accessed"]
        rows = [
            [
                row.get("Directory", ""),
                row.get("Size", ""),
                row.get("Modified", ""),
                row.get("Accessed", ""),
            ]
            for row in top_rows
        ]
        if scope.has_owner_data:
            headers.insert(2, "Owner")
            for table_row, source_row in zip(rows, top_rows):
                table_row.insert(2, source_row.get("Owner", ""))
        lines.extend(render_table(headers, rows))
    else:
        lines.append("No matching directories were recorded.")

    lines.append("")
    return lines


def write_json_summary(run_dir: Path, scopes: list[ScopeReport]) -> None:
    payload = {
        "run_dir": str(run_dir),
        "generated_on": date.today().isoformat(),
        "scopes": [
            {
                "key": scope.key,
                "title": scope.title,
                "csv": scope.csv_path.name,
                "summary": scope.summary_path.name,
                "entries": len(scope.rows),
                "too_large_entries": scope.too_large_count,
                "total_known_bytes": scope.known_bytes,
                "owner_counts": scope.owner_counts,
            }
            for scope in scopes
        ],
    }
    (run_dir / "storage_report.json").write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate a consolidated RCP storage scan report.")
    parser.add_argument("run_dir", type=Path, help="Run output directory containing the three CSV files.")
    parser.add_argument("--output", type=Path, default=None, help="Markdown report path.")
    parser.add_argument("--limit", type=int, default=20, help="Rows to show per table.")
    args = parser.parse_args()

    run_dir = args.run_dir
    output_path = args.output or run_dir / "storage_report.md"
    scopes = [load_scope(run_dir, key, spec) for key, spec in SCOPES.items()]

    lines = [
        "# RCP Scratch Storage Report",
        "",
        f"- Run directory: `{run_dir}`",
        f"- Generated on: {date.today().isoformat()}",
        "",
    ]

    overview_rows = [
        [
            scope.title,
            len(scope.rows),
            scope.too_large_count,
            human_size(scope.known_bytes),
            scope.csv_path.name,
        ]
        for scope in scopes
    ]
    lines.extend(render_table(["Scope", "Entries", "TOO_LARGE", "Known Size", "CSV"], overview_rows))
    lines.append("")

    for scope in scopes:
        lines.extend(render_scope(scope, args.limit))

    output_path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
    write_json_summary(run_dir, scopes)
    print(f"Wrote {output_path}")
    print(f"Wrote {run_dir / 'storage_report.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
