# Task: Provider Logo Download Script
- **Created**: 2025-11-18
- **Owner**: Codex (GPT-5)

## Request
Create a reusable script that pulls the provider catalog referenced in `local/ai-gateway-openai-compatible.md` and downloads the SVG logos for every provider so the AI tab can show real icons instead of fallback initials.

## Requirements & Notes
- Use the Models.dev dataset (`https://models.dev/api.json`) mentioned in the gateway doc as the source of provider metadata.
- For each provider entry, fetch the SVG at `https://models.dev/logos/{provider_id}.svg`.
- Save files under a deterministic directory in the repo (default suggestion: `local/provider-logos` since these assets are large and regenerated).
- Skip downloads when the file already exists unless `--force` is passed.
- Provide CLI arguments for `--output-dir`, optional `--providers` filter, and `--max-workers` for parallel fetches.
- Emit a short summary at the end (downloaded, skipped, failed counts).

## Plan
1. Inspect existing scripts under `scripts/` for conventions (argparse, requests usage) and decide on script structure + destination.
2. Implement `scripts/download_provider_logos.py` using `requests` with streaming writes, concurrency via `ThreadPoolExecutor`, and logging to stdout.
3. Test against the live API (dry-run + real download), document usage in the script docstring, and update project docs/PROD entry.

## Progress Log
- **2025-11-18**: Captured requirements & initial plan.
- **2025-11-18**: Implemented `scripts/download_provider_logos.py`, added `--output-dir`, `--providers`, `--force`, `--max-workers`, and `--timeout` flags. Verified a partial run with two providers to confirm happy-path networking + file writing.
