# AI Gateway – OpenAI-Compatible API
Last updated October 24, 2025

## Overview
AI Gateway exposes an OpenAI-compatible API surface so existing OpenAI SDKs, tools, and workflows continue to work by swapping only the base URL and credentials. The implementation mirrors the OpenAI REST specification, including structured responses, streaming behaviors, attachments, image generation, and tool-calling semantics.

## Base URL
- `https://ai-gateway.vercel.sh/v1`

## Authentication
AI Gateway accepts the same credentials used elsewhere in the platform:
- **API key**: `Authorization: Bearer <api_key>`
- **Vercel OIDC token**: `Authorization: Bearer <oidc_token>`

Only one credential type is required per request. If both are supplied, the API key is used (even if invalid), so omit unused headers.

## Supported Endpoints
- `GET /models` — List all available models.
- `GET /models/{model}` — Retrieve metadata for a specific model identifier.
- `POST /chat/completions` — Create chat completions with streaming, attachments, tool calls, and image generation.
- `POST /embeddings` — Generate vector embeddings for supplied text or tokens.

## Notes
- Behavior tracks the public OpenAI API spec; SDKs that target OpenAI should work without code changes.
- Endpoint coverage expands along with the upstream specification; monitor release notes for additional routes.

## Key Management Inside The App
- Treat the API key as a per-user secret provided at runtime (never ship one in the binary).
- Collect the key in the AI tab’s settings form, validate it with a lightweight `GET /models` probe, then store it in the **iOS Keychain** with `kSecAttrAccessibleAfterFirstUnlock` so background tasks can reuse it after reboot.
- Expose a “Re-enter key” action and optional biometric (Face ID / Touch ID) gate for reads if we want extra protection.
- Avoid `UserDefaults` or plist storage; sandboxed but still trivially extractable.
- Rotate keys if a device is lost or jailbroken—Keychain is strong but not invincible against compromised hardware.

## AI Tab Design (WIP)
Purpose: centralize AI Gateway management in a dedicated navigation tab labeled **AI**.

### Primary Sections
1. **Connection & Credentials**
   - Text field + “Save Key” button.
   - Inline validation results (success/error from `GET /models`).
   - Key stored in Keychain and mirrored in app state via `@StateObject` gateway manager.
2. **Model Catalog**
   - Fetch `GET /models` on appear and on pull-to-refresh.
   - Display provider icon, model slug, high-level capabilities.
   - Tap to push a detail view (model metadata + provider notes + pricing if returned).
   - “Set as Default” button persists selection to user defaults (non-sensitive) + CloudKit for sync if desired.

### Provider & Model Logos (Models.dev)
- Use [Models.dev](https://models.dev) as the single source of truth for provider/model metadata and logos while we wait on a first-party gateway catalog.
- The dataset lives at `https://models.dev/api.json`; it is large, so always filter with `jq`, `rg`, or similar before printing anything to the console.
- Provider lookup example (filters to Anthropic only):

```bash
curl -s https://models.dev/api.json \
  | jq '.providers[] | select(.id=="anthropic") | {id,name,website}'
```

```json
{
  "id": "anthropic",
  "name": "Anthropic",
  "website": "https://www.anthropic.com"
}
```

- Model lookup example (filters to `gpt-4o-mini`):

```bash
curl -s https://models.dev/api.json \
  | jq '.models[] | select(.id=="gpt-4o-mini") | {id,provider,modalities,price}'
```

```json
{
  "id": "gpt-4o-mini",
  "provider": "openai",
  "modalities": [
    "text",
    "vision"
  ],
  "price": {
    "prompt": 0.00015,
    "completion": 0.0006,
    "unit": "1K tokens"
  }
}
```

- Each entry exposes a `provider`/`id` pair that we can align with the `provider_name` returned by `GET /models`. Cache the parsed response in memory (or persist to disk) so repeated pulls don’t hammer the public endpoint.
- Provider logos live at `https://models.dev/logos/{provider_id}.svg`. Example: `https://models.dev/logos/anthropic.svg`. If a logo is missing, the endpoint falls back to a default SVG automatically.
- Rendering flow for the AI tab:
  1. Fetch `/models` from AI Gateway.
  2. For each model, map `provider_name` → Models.dev `provider` ID.
  3. Construct the provider logo URL and lazy-load it into the list row (cache the SVG bytes on disk to avoid repeat downloads).
  4. Optionally add `modelLogoURL` fields by pointing to the same SVG when a provider supplies a single brand mark.
- Keep the logos optional—if the fetch fails or a provider is unknown, show the fallback initials tile so the Model Catalog never blocks on this dependency.
- **Scripts**: Run `python scripts/download_provider_logos.py` to refresh the SVG set (writes to `local/provider-logos/` by default, see `local/task-provider-logo-download.md`) and `python scripts/build_provider_logo_assets.py` to regenerate the PNG assets inside `Assets.xcassets/ProviderLogos/` for in-app usage.

3. **Model Tester**
   - Simple chat playground (prompt text field, optional image/tool inputs) calling `POST /chat/completions` with streaming UI.
   - Shows token counts, latency, and provider metadata from response.
4. **Usage & Credits**
   - Pulls `GET /credits` to show balance + total_used.
   - Link to “View detailed generation” search where the user can paste a generation ID.
5. **Generation Lookup**
   - Text field for `gen_…` IDs; submits `GET /generation?id=…` and renders cost, timestamps, token stats, provider.

### Interaction Flow
- On first visit, the tab prompts for a key; other sections stay disabled until validation passes.
- GatewayManager publishes `connectionState` (disconnected, validating, ready, error) to gate UI sections.
- Each fetch includes error banners + retry; rate-limit calls when user flips tabs rapidly.

## Usage & Billing API
Same base URL: `https://ai-gateway.vercel.sh/v1` with identical authentication headers as above.

### `GET /credits`
Check remaining credit balance and aggregate usage.

```ts
// credits.ts
const apiKey = process.env.AI_GATEWAY_API_KEY ?? process.env.VERCEL_OIDC_TOKEN;

const response = await fetch('https://ai-gateway.vercel.sh/v1/credits', {
  method: 'GET',
  headers: {
    Authorization: `Bearer ${apiKey}`,
    'Content-Type': 'application/json',
  },
});

const credits = await response.json();
console.log(credits);
```

```python
# credits.py
import os
import requests

api_key = os.getenv('AI_GATEWAY_API_KEY') or os.getenv('VERCEL_OIDC_TOKEN')
resp = requests.get(
    'https://ai-gateway.vercel.sh/v1/credits',
    headers={
        'Authorization': f'Bearer {api_key}',
        'Content-Type': 'application/json',
    },
    timeout=30,
)
resp.raise_for_status()
print(resp.json())
```

**Sample response**

```json
{
  "balance": "95.50",
  "total_used": "4.50"
}
```

- `balance`: remaining credit balance.
- `total_used`: cumulative spend.

### `GET /generation?id={generation_id}`
Look up a specific generation for deeper telemetry (usage, latency, BYOK flag, token counts).

```ts
// generation-lookup.ts
const generationId = 'gen_01ARZ3NDEKTSV4RRFFQ69G5FAV';

const response = await fetch(
  `https://ai-gateway.vercel.sh/v1/generation?id=${generationId}`,
  {
    method: 'GET',
    headers: {
      Authorization: `Bearer ${process.env.AI_GATEWAY_API_KEY}`,
      'Content-Type': 'application/json',
    },
  },
);

const generation = await response.json();
console.log(generation);
```

```python
# generation_lookup.py
import os
import requests

generation_id = 'gen_01ARZ3NDEKTSV4RRFFQ69G5FAV'
resp = requests.get(
    'https://ai-gateway.vercel.sh/v1/generation',
    params={'id': generation_id},
    headers={
        'Authorization': f"Bearer {os.getenv('AI_GATEWAY_API_KEY')}",
        'Content-Type': 'application/json',
    },
    timeout=30,
)
resp.raise_for_status()
print(resp.json())
```

**Sample response fields**

```json
{
  "data": {
    "id": "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
    "total_cost": 0.00123,
    "usage": 0.00123,
    "created_at": "2024-01-01T00:00:00.000Z",
    "model": "gpt-4",
    "is_byok": false,
    "provider_name": "openai",
    "streamed": true,
    "latency": 200,
    "generation_time": 1500,
    "tokens_prompt": 100,
    "tokens_completion": 50,
    "native_tokens_prompt": 100,
    "native_tokens_completion": 50,
    "native_tokens_reasoning": 0,
    "native_tokens_cached": 0
  }
}
```

- `id`: generation ULID (`gen_*`).
- `total_cost` / `usage`: USD cost for the run.
- `created_at`: ISO-8601 timestamp.
- `model`: model slug invoked.
- `is_byok`: true if Bring Your Own Key credentials were used.
- `provider_name`: upstream provider.
- `streamed`: whether streaming was enabled.
- `latency`: time to first token (ms).
- `generation_time`: total duration (ms).
- `tokens_prompt`, `tokens_completion`: OpenAI-style token counts.
- `native_tokens_*`: provider-native token counters, including `native_tokens_reasoning` and `native_tokens_cached`.

## Probe Scripts
- `scripts/ai_gateway_probe.py` wraps the `/models`, `/chat/completions`, `/credits`, and `/generation` endpoints for quick manual verification.
- Export `VERCEL_AI_GATEWAY_API_KEY` first, then run e.g. `python scripts/ai_gateway_probe.py models` to dump the current catalog. The script prints prettified JSON so it is easy to inspect new fields when the API evolves.
- Typical `/models` payload:

```json
{
  "data": [
    {
      "id": "gpt-4o-mini",
      "object": "model",
      "created": 1730000000,
      "owned_by": "openai",
      "metadata": {
        "provider": "openai",
        "modality": ["text", "image"],
        "input_cost": 0.0000005,
        "output_cost": 0.0000015
      }
    }
  ]
}
```

- `/chat/completions` responses mirror OpenAI’s schema, including `choices[0].message.content`, `usage.prompt_tokens`, `usage.completion_tokens`, `system_fingerprint`, and `providerMetadata` (forwarded credit + latency data). Running `python scripts/ai_gateway_probe.py chat --prompt "Ping"` captures the raw JSON for debugging or to diff behavioral changes across models.

### Latest Probe Snapshots (2025-01-06)
- **Model catalog** (`python scripts/ai_gateway_probe.py models`)
  - Returns a 200+ entry `data[]` list. Each model item now includes `context_window`, `max_tokens`, `description`, `pricing.input`, `pricing.output`, `tags`, and `type` fields. Example head entry: `{"id":"alibaba/qwen-3-14b","context_window":40960,"pricing":{"input":"0.00000006","output":"0.00000024"},...}`.
- **Chat completion** (`python scripts/ai_gateway_probe.py chat --model openai/gpt-4o-mini --prompt 'Say hello from AudiobookPlayer.'`)
  - Response echoed `choices[0].message.content = "Hello from AudiobookPlayer!..."` and surfaced `provider_metadata.gateway.routing` (with resolved provider/fallback details) plus `usage.cost = 1.245e-05` and `generationId = gen_01K9ERZ8Q7P2VG5K9BB89GSQBS`.
- **Credits** (`python scripts/ai_gateway_probe.py credits`)
  - Returned `{ "balance": "4.98429925", "total_used": "0.01570075" }`, confirming balances are sent as strings.
- **Generation lookup** (`python scripts/ai_gateway_probe.py generation --id gen_01K9ERZ8Q7P2VG5K9BB89GSQBS`)
  - Currently returns HTTP 404 `{"error":"Usage event not found"}` even immediately after a chat request. Likely eventual consistency or gating on billable generations; handle 404 with a retry/backoff UI state.

## App Integration Status (2025-01-06)
- **UI**: Added the AI tab (`AITabView`) with credential entry, model catalog, tester, credits, and generation lookup sections.
- **Data layer**: `AIGatewayViewModel`, `AIGatewayClient`, and `KeychainAIGatewayAPIKeyStore` coordinate persistence and API calls.
- **Defaults**: Preferred model stored under `ai_gateway_default_model` in `UserDefaults` and surfaced via “Use as Default” buttons.
- **Auto refresh**: When a valid key exists, the tab preloads models (if empty) and credit totals, with manual refresh + inline error states for retries.
