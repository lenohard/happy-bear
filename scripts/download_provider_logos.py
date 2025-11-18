#!/usr/bin/env python3
"""Download provider SVG logos from Models.dev.

This pulls the provider catalog from https://models.dev/api.json and downloads
each provider's logo from https://models.dev/logos/{provider_id}.svg.

Usage examples:
  python scripts/download_provider_logos.py
  python scripts/download_provider_logos.py --output-dir local/provider-logos
  python scripts/download_provider_logos.py --providers openai,anthropic,google
  python scripts/download_provider_logos.py --force --max-workers 16

Notes:
- Skips providers whose SVG already exists unless --force is passed.
- Writes files as {provider_id}.svg in the chosen output directory.
- Parallelized with ThreadPoolExecutor; defaults to 8 workers.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import sys
from pathlib import Path
from typing import Iterable, List, Optional

import requests


API_URL = "https://models.dev/api.json"
LOGO_URL_TEMPLATE = "https://models.dev/logos/{provider_id}.svg"


def fetch_catalog(timeout: int) -> dict:
    resp = requests.get(API_URL, timeout=timeout)
    resp.raise_for_status()
    return resp.json()


def download_logo(provider_id: str, output_dir: Path, *, force: bool, timeout: int) -> tuple[str, str]:
    """Download a single provider logo.

    Returns a tuple of (provider_id, status) where status is one of
    "downloaded", "skipped", or an error message.
    """

    output_path = output_dir / f"{provider_id}.svg"

    if output_path.exists() and not force:
        return provider_id, "skipped"

    url = LOGO_URL_TEMPLATE.format(provider_id=provider_id)
    try:
        resp = requests.get(url, timeout=timeout)
        resp.raise_for_status()
    except Exception as exc:  # noqa: BLE001
        return provider_id, f"error: {exc}"  # short error string for summary

    try:
        output_path.write_bytes(resp.content)
    except Exception as exc:  # noqa: BLE001
        return provider_id, f"error: write failed: {exc}"

    return provider_id, "downloaded"


def parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Download provider logos from Models.dev")
    parser.add_argument(
        "--output-dir",
        default="local/provider-logos",
        help="Directory to save SVG files (default: local/provider-logos)",
    )
    parser.add_argument(
        "--providers",
        help="Comma-separated list of provider ids to download (default: all providers in the catalog)",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Re-download logos even if the file already exists",
    )
    parser.add_argument(
        "--max-workers",
        type=int,
        default=8,
        help="Maximum concurrent downloads (default: 8)",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=30,
        help="Request timeout in seconds for catalog + logo fetches (default: 30)",
    )
    return parser.parse_args(argv)


def _provider_ids_from_catalog(catalog: dict) -> Iterable[str]:
    """Extract provider IDs from the catalog payload.

    Handles both historical formats (providers as list of dicts) and the
    current format (top-level object keyed by provider id)."""

    providers = catalog.get("providers")
    if isinstance(providers, list):
        for entry in providers:
            provider_id = entry.get("id") if isinstance(entry, dict) else None
            if provider_id:
                yield provider_id
        return

    # Models.dev now returns a dict keyed by provider slug. Fall back to that.
    if isinstance(catalog, dict):
        for provider_id, entry in catalog.items():
            if isinstance(entry, dict) and entry.get("id", provider_id):
                yield entry.get("id", provider_id)
        return

    raise ValueError("Catalog missing providers list or map")


def main(argv: Optional[List[str]] = None) -> int:
    args = parse_args(argv)

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    try:
        catalog = fetch_catalog(timeout=args.timeout)
    except Exception as exc:  # noqa: BLE001
        print(f"Failed to fetch catalog: {exc}", file=sys.stderr)
        return 1

    seen: set[str] = set()
    provider_ids: list[str] = []
    for provider_id in _provider_ids_from_catalog(catalog):
        if provider_id and provider_id not in seen:
            seen.add(provider_id)
            provider_ids.append(provider_id)
    if args.providers:
        requested = {p.strip() for p in args.providers.split(",") if p.strip()}
        provider_ids = [p for p in provider_ids if p in requested]

    if not provider_ids:
        print("No providers to download (empty list after filtering).", file=sys.stderr)
        return 1

    print(f"Providers to fetch: {len(provider_ids)}")
    statuses: dict[str, str] = {}

    with concurrent.futures.ThreadPoolExecutor(max_workers=args.max_workers) as pool:
        futures = [
            pool.submit(download_logo, provider_id, output_dir, force=args.force, timeout=args.timeout)
            for provider_id in provider_ids
        ]
        for future in concurrent.futures.as_completed(futures):
            provider_id, status = future.result()
            statuses[provider_id] = status
            if status == "downloaded":
                print(f"✔ {provider_id} downloaded")
            elif status == "skipped":
                print(f"↷ {provider_id} skipped (exists)")
            else:
                print(f"✖ {provider_id} {status}")

    downloaded = sum(1 for s in statuses.values() if s == "downloaded")
    skipped = sum(1 for s in statuses.values() if s == "skipped")
    failed = len(statuses) - downloaded - skipped

    print("--- Summary ---")
    print(f"Downloaded: {downloaded}")
    print(f"Skipped:    {skipped}")
    print(f"Failed:     {failed}")

    return 0 if failed == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
