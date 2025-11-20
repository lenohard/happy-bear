# Provider Logo Assets
- **Generated**: 2025-11-18
- `scripts/build_provider_logo_assets.py` converts `local/provider-logos/*.svg` into PNGs + xcassets entries.
- Regenerate after fetching a new Models.dev provider list by running:
  ```bash
  python scripts/download_provider_logos.py
  python scripts/build_provider_logo_assets.py
  ```
- Assets live in `AudiobookPlayer/Assets.xcassets/ProviderLogos/` and match provider ids exactly (lowercase kebab case).
