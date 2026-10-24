# PolarBear Library Server

Read-only HTTP access to the iOS `library.sqlite` plus a responsive web client.
Runs standalone — no PostgreSQL, no remote-jobs service required.

## Run

```bash
cd server
POLARBEAR_LIBRARY_TOKEN=your-token \
POLARBEAR_LIBRARY_DB="$HOME/Library/Mobile Documents/iCloud~com~senaca~audiobookplayer/Documents/library.sqlite" \
.venv/bin/python -m uvicorn app.library_app:app --host 0.0.0.0 --port 8082
```

- `POLARBEAR_LIBRARY_TOKEN` (required): bearer token for every `/v1/library/*` call.
  Falls back to `REMOTE_JOBS_TOKEN` when unset.
- `POLARBEAR_LIBRARY_DB` (default): path to the iOS database. The server never
  writes to it — it copies the database (plus `-wal`/`-shm`) into a snapshot and
  opens that snapshot read-only.
- `POLARBEAR_LIBRARY_SNAPSHOT_DIR` (default `server/data/library`): snapshot location.

The web client is served from the same process at `/` (files in `server/web`).

## Endpoints

All under `/v1/library`, all require `Authorization: Bearer <token>`:

| Endpoint | Purpose |
|---|---|
| `GET /status` | snapshot state, track/collection counts |
| `GET /folders` | collection folders |
| `GET /collections?folderId=&includeArchived=` | collections |
| `GET /collections/{id}/tracks?page=&pageSize=&includeArchived=` | tracks of a collection |
| `GET /tracks/continue?limit=` | continue listening |
| `GET /tracks/favorites?limit=` | favorites |
| `GET /search?q=&limit=` | collections + tracks |
| `GET /tracks/{id}` | track detail (metadata, summary, transcript info) |
| `GET /tracks/{id}/transcript?fullText=1` | transcript segments |
| `GET /tracks/{id}/text` | text track content |
| `GET /tracks/{id}/playback` | playable source (`baidu` path or `external` URL) |
| `GET /covers/{collectionId}` | cover image bytes |
| `GET /cover?path=CollectionCovers/…` | cover image bytes by relative path |

Errors are JSON: `{"error":{"code":"…","message":"…"}}`; `401` for a missing or
wrong token.

## Web client

`server/web` is a dependency-free, responsive client (phone + desktop). It asks
for the bearer token on first load and keeps it in `localStorage` under
`polarbear-token`.

## Smoke test

```bash
cd server
POLARBEAR_LIBRARY_TOKEN=smoke-token .venv/bin/python -m uvicorn app.library_app:app --port 8082 &
.venv/bin/python scripts/smoke_library_api.py
```

## Desktop client in server mode

The Electron app reads the same API when configured; otherwise it keeps using
the local iCloud snapshot. Configuration file `userData/server.json`:

```json
{ "enabled": true, "baseUrl": "http://mac-mini.local:8082", "token": "your-token" }
```

Environment overrides: `POLARBEAR_SERVER_URL`, `POLARBEAR_SERVER_TOKEN`.

## Limits

- Read-only: the server never writes to the iOS database. Playback progress and
  AI summaries are still written by the desktop app to the local iCloud library.
- Baidu playback needs a Baidu session; the API only exposes the netdisk path,
  so Baidu streaming remains a desktop-only feature.
