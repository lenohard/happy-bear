# Local Overrides (not in git)

## Remote Jobs Server (local service)

- **FastAPI server**: running on `http://0.0.0.0:8081` (uvicorn from `server/.venv`)
- **Auth token**: `sb4OemhmR2os` (env var `REMOTE_JOBS_TOKEN`)
- **Tailscale HTTPS URL**: `https://mathemac-mini.tailb0587a.ts.net/` (tailnet only, proxies to port 8081)
- **Tailscale Serve config**: `tailscale serve --bg --https=443 http://127.0.0.1:8081`
  - To verify: `tailscale serve status`
  - To reset & reconfigure: `tailscale serve reset && tailscale serve --bg --https=443 http://127.0.0.1:8081`
- **Server logs**: `server/logs/remote-jobs.log` and `server/logs/remote-jobs-error.log`

### Launch Management (launchd)
The service runs as a user LaunchAgent — **do not start it manually**, launchd auto-starts at login and auto-respawns on crash.

- **Label**: `com.happybear.remote-jobs`
- **Plist**: `~/Library/LaunchAgents/com.happybear.remote-jobs.plist`
- **Config**: `RunAtLoad=true`, `KeepAlive.SuccessfulExit=false` (respawns on non-zero exit)
- **Working dir**: `/Users/mathe/projects/happy-bear/server`
- **Env vars set in plist**: `REMOTE_JOBS_TOKEN`, `REMOTE_JOBS_STORAGE`, `REMOTE_JOBS_DATABASE_URL` (`postgresql://audiobook:audiobook@127.0.0.1:5432/audiobook_jobs`), `SONIOX_API_KEY`, `VERCEL_AI_GATEWAY_API_KEY`

Common operations:
```bash
# Status / PID
launchctl list | grep com.happybear.remote-jobs

# Restart (clean kill + relaunch)
launchctl kickstart -k gui/$(id -u)/com.happybear.remote-jobs

# Stop (will auto-respawn unless unloaded)
launchctl kill TERM gui/$(id -u)/com.happybear.remote-jobs

# Disable / enable (survives reboot)
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.happybear.remote-jobs.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.happybear.remote-jobs.plist

# Reload after editing the plist
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.happybear.remote-jobs.plist && \
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.happybear.remote-jobs.plist
```

### Manual Start (only if launchd is unloaded, e.g. for debugging with `--reload`)
```bash
cd /Users/mathe/projects/happy-bear/server
REMOTE_JOBS_TOKEN=sb4OemhmR2os REMOTE_JOBS_STORAGE=./storage REMOTE_JOBS_DATABASE_URL=postgresql://... \
  uvicorn app.main:app --host 0.0.0.0 --port 8081 --reload
```

- **Quick health check**: `curl -s http://localhost:8081/v1/jobs?limit=1 -H "Authorization: Bearer sb4OemhmR2os"`

## iOS App Config (Settings → Remote Jobs)
- Base URL: `https://mathemac-mini.tailb0587a.ts.net`
- Auth Token: `sb4OemhmR2os`
