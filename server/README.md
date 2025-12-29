# Remote Jobs Server (FastAPI)

## Purpose
Local/LAN FastAPI service for STT/TTS/AI background jobs.

## Requirements
- Python 3.11+
- uv (recommended)

## Setup
```bash
cd server
uv venv
source .venv/bin/activate
uv pip install -r <(uv pip compile pyproject.toml)
```

## Run
```bash
cd server
REMOTE_JOBS_TOKEN=your-token-here \
REMOTE_JOBS_STORAGE=./storage \
REMOTE_JOBS_DATABASE_URL=postgresql://user:password@127.0.0.1:5432/audiobook_jobs \
uvicorn app.main:app --host 0.0.0.0 --port 8081 --reload
```

## iOS LAN Setup
1. On the machine running the server, find its LAN IP (e.g. `192.168.1.50`).
2. In the app: Settings → Remote Jobs
   - Enable "Use Remote Server"
   - Base URL: `http://<LAN-IP>:8081`
   - Auth Token: value used for `REMOTE_JOBS_TOKEN`
   - Tap "Test Connection" and confirm status shows Connected.
3. If using HTTP on LAN, enable "Allow HTTP on LAN" and ensure ATS exceptions are configured for local IPs.

## Notes
- Token auth is required for all endpoints.
- This MVP writes uploads and results to the local filesystem.
- STT uses Soniox (requires `SONIOX_API_KEY`).
- AI uses Vercel AI Gateway (requires `VERCEL_AI_GATEWAY_API_KEY`).
- TTS currently returns a "not configured" error.
- STT accepts direct uploads or URL input with a source (server downloads with optional Baidu cookie).
- Port `8081` is recommended if `8080` is occupied by OrbStack.

## Environment Variables
- `REMOTE_JOBS_TOKEN` (required): bearer token
- `REMOTE_JOBS_STORAGE` (default `./storage`)
- `REMOTE_JOBS_DATABASE_URL` (required): PostgreSQL DSN
- `SONIOX_API_KEY` (optional): enables STT processing
- `VERCEL_AI_GATEWAY_API_KEY` (optional): enables AI processing
