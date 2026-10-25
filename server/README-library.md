# PolarBear Library Server

Read-only HTTP access to the iOS `library.sqlite` plus a responsive web client.
Runs standalone — no PostgreSQL, no remote-jobs service required.

## Run

```bash
cd server
POLARBEAR_LIBRARY_DB="$HOME/Library/Mobile Documents/iCloud~com~senaca~audiobookplayer/Documents/library.sqlite" \
.venv/bin/python -m uvicorn app.library_app:app --host 127.0.0.1 --port 8082
```

- **No token.** The API is unauthenticated, so it must stay reachable only from
  your own devices: bind it to `127.0.0.1` and expose it through
  `tailscale serve` (tailnet-only). Never bind it to `0.0.0.0`.
- `POLARBEAR_LIBRARY_DB` (default): path to the iOS database. The server never
  writes to it — it copies the database (plus `-wal`/`-shm`) into a snapshot and
  opens that snapshot read-only.
- `POLARBEAR_LIBRARY_SNAPSHOT_DIR` (default `server/data/library`): snapshot location.

The web client is served from the same process at `/` (files in `server/web`).

## Endpoints

All under `/v1/library`:

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

Errors are JSON: `{"error":{"code":"…","message":"…"}}`.

## Web client

`server/web` is a dependency-free, responsive client (phone + desktop). It talks
to the API on the same origin — no token, no login screen.

## Smoke test

```bash
cd server
.venv/bin/python -m uvicorn app.library_app:app --port 8082 &
.venv/bin/python scripts/smoke_library_api.py
.venv/bin/python scripts/check_api_contract.py
```

## Desktop client in server mode

The Electron app reads the same API when configured; otherwise it keeps using
the local iCloud snapshot. Configuration file `userData/server.json`:

```json
{ "enabled": true, "baseUrl": "http://mac-mini.local:8082" }
```

Environment override: `POLARBEAR_SERVER_URL`.

## Deployment (WonderTree)

```bash
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.happybear.library-server.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.happybear.library-server.plist
tailscale serve --bg --https=8444 http://127.0.0.1:8082
```

## Limits

- Read-only: the server never writes to the iOS database. Playback progress and
  AI summaries are still written by the desktop app to the local iCloud library.
- Baidu playback needs a Baidu session; the API only exposes the netdisk path,
  so Baidu streaming remains a desktop-only feature.
