#!/usr/bin/env python3
"""Generate xcassets imagesets for provider logos.

Reads SVG logos from local/provider-logos and writes PNG renditions into
AudiobookPlayer/Assets.xcassets/ProviderLogos/<provider>.imageset/.

Sizes: 24pt @2x (48px) and @3x (72px). 1x is omitted because the app targets
retina screens only. Existing contents are replaced.

Usage:
  python scripts/build_provider_logo_assets.py
  python scripts/build_provider_logo_assets.py --providers openai,anthropic
"""

from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path
from typing import Iterable, List, Optional

try:
    import cairosvg
except Exception:  # noqa: BLE001
    cairosvg = None


REPO_ROOT = Path(__file__).resolve().parent.parent
SVG_DIR = REPO_ROOT / "local/provider-logos"
ASSETS_ROOT = REPO_ROOT / "AudiobookPlayer/Assets.xcassets/ProviderLogos"


def run_convert(svg: Path, png: Path, size_px: int) -> None:
    """Convert SVG to PNG at a square size. Prefer CairoSVG for robustness."""

    png.parent.mkdir(parents=True, exist_ok=True)

    if cairosvg is not None:
        cairosvg.svg2png(url=str(svg), write_to=str(png), output_width=size_px, output_height=size_px)
        return

    # Fallback to ImageMagick if cairosvg is unavailable.
    subprocess.run(
        [
            "magick",
            str(svg),
            "-background",
            "none",
            "-resize",
            f"{size_px}x{size_px}",
            str(png),
        ],
        check=True,
    )


def write_contents_json(imageset: Path) -> None:
    contents = {
        "images": [
            {"idiom": "universal", "filename": "logo@2x.png", "scale": "2x"},
            {"idiom": "universal", "filename": "logo@3x.png", "scale": "3x"},
        ],
        "info": {"version": 1, "author": "xcode"},
    }
    (imageset / "Contents.json").write_text(__import__("json").dumps(contents, indent=2) + "\n")


def provider_ids(providers_arg: Optional[str]) -> Iterable[str]:
    if providers_arg:
        yield from (p.strip() for p in providers_arg.split(",") if p.strip())
        return
    for svg in sorted(SVG_DIR.glob("*.svg")):
        yield svg.stem


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Build provider logo xcassets")
    parser.add_argument(
        "--providers",
        help="Comma-separated list of provider ids (defaults to all SVGs)",
    )
    args = parser.parse_args(argv)

    if not SVG_DIR.exists():
        parser.error(f"SVG directory missing: {SVG_DIR}")

    ASSETS_ROOT.mkdir(parents=True, exist_ok=True)
    root_contents = ASSETS_ROOT / "Contents.json"
    if not root_contents.exists():
        root_contents.write_text(json.dumps({"info": {"version": 1, "author": "xcode"}}, indent=2) + "\n")

    for provider in provider_ids(args.providers):
        svg_path = SVG_DIR / f"{provider}.svg"
        if not svg_path.exists():
            print(f"skip {provider}: missing SVG")
            continue

        imageset = ASSETS_ROOT / f"{provider}.imageset"
        imageset.mkdir(parents=True, exist_ok=True)

        run_convert(svg_path, imageset / "logo@2x.png", 48)
        run_convert(svg_path, imageset / "logo@3x.png", 72)
        write_contents_json(imageset)
        print(f"built {provider}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
