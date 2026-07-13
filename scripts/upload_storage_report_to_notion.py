#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request
from datetime import date
from pathlib import Path


NOTION_API_URL = "https://api.notion.com/v1/pages"
NOTION_VERSION = os.environ.get("NOTION_VERSION", "2026-03-11")
DEFAULT_PARENT_PAGE_ID = "39c953b34421805f9b81d664f291f945"


def normalize_page_id(value: str) -> str:
    raw = value.strip()
    match = re.search(r"([0-9a-fA-F]{32})", raw.replace("-", ""))
    if not match:
        raise ValueError(f"Could not find a Notion page ID in: {value}")
    compact = match.group(1).lower()
    return (
        f"{compact[0:8]}-{compact[8:12]}-{compact[12:16]}-"
        f"{compact[16:20]}-{compact[20:32]}"
    )


def request_json(url: str, token: str, body: dict[str, object]) -> dict[str, object]:
    payload = json.dumps(body).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=payload,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "Notion-Version": NOTION_VERSION,
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Notion API returned HTTP {exc.code}: {detail}") from exc


def main() -> int:
    parser = argparse.ArgumentParser(description="Upload a generated storage_report.md to Notion.")
    parser.add_argument("report", type=Path, help="Path to storage_report.md")
    parser.add_argument(
        "--parent-page-id",
        default=os.environ.get("NOTION_PARENT_PAGE_ID", DEFAULT_PARENT_PAGE_ID),
        help="Notion parent page ID or URL. Defaults to the RCP Storage page ID.",
    )
    parser.add_argument(
        "--title",
        default=os.environ.get("NOTION_REPORT_TITLE"),
        help="Title for the created Notion child page.",
    )
    parser.add_argument("--dry-run", action="store_true", help="Validate inputs but do not call Notion.")
    args = parser.parse_args()

    token = os.environ.get("NOTION_API_KEY") or os.environ.get("NOTION_TOKEN")
    if not token and not args.dry_run:
        print("Set NOTION_API_KEY or NOTION_TOKEN in the environment.", file=sys.stderr)
        return 2

    report_path = args.report
    markdown = report_path.read_text(encoding="utf-8")
    parent_page_id = normalize_page_id(args.parent_page_id)
    title = args.title or f"RCP Storage Report {date.today().isoformat()}"

    body = {
        "parent": {"page_id": parent_page_id},
        "properties": {
            "title": [{"text": {"content": title}}],
        },
        "markdown": markdown,
    }

    if args.dry_run:
        print(json.dumps({"url": NOTION_API_URL, "notion_version": NOTION_VERSION, "body": body}, indent=2))
        return 0

    response = request_json(NOTION_API_URL, token or "", body)
    print(response.get("url", json.dumps(response)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
