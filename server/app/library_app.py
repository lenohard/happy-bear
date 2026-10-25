"""PolarBear library API — read-only HTTP access to the iOS library.

Runs standalone (no PostgreSQL required) so a Mac mini can serve the library
and the web client:

    uvicorn app.library_app:app --host 127.0.0.1 --port 8082

There is no token check: the service is meant to stay on the tailnet
(`tailscale serve`, tailnet-only). Bind it to 127.0.0.1 and expose it
through Tailscale Serve — never on 0.0.0.0.
"""

from __future__ import annotations

import logging
from pathlib import Path
from typing import Any

from fastapi import APIRouter, FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles

from .library import LibraryStore

logger = logging.getLogger(__name__)

WEB_DIR = Path(__file__).parent.parent / "web"
WEB_DIR.mkdir(parents=True, exist_ok=True)
store = LibraryStore()

router = APIRouter(prefix="/v1/library")


@router.get("/status")
def read_status() -> dict[str, Any]:
    return store.status().to_dict()


@router.post("/refresh")
def refresh_snapshot() -> dict[str, Any]:
    return store.refresh(force=True).to_dict()


@router.get("/folders")
def read_folders() -> list[dict[str, Any]]:
    return store.folders()


@router.get("/collections")
def read_collections(folder_id: str | None = None, includeArchived: bool = False) -> list[dict[str, Any]]:
    return store.collections(folder_id, includeArchived)


@router.get("/collections/{collection_id}/tracks")
def read_collection_tracks(
    collection_id: str, page: int = 0, pageSize: int = 200, includeArchived: bool = False
) -> dict[str, Any]:
    return store.tracks(collection_id, page, pageSize, includeArchived)


@router.get("/tracks/continue")
def read_continue(limit: int = 20) -> list[dict[str, Any]]:
    return store.continue_listening(limit)


@router.get("/tracks/favorites")
def read_favorites(limit: int = 500) -> list[dict[str, Any]]:
    return store.favorites(limit)


@router.get("/search")
def read_search(q: str, limit: int = 50) -> list[dict[str, Any]]:
    return store.search(q, limit)


@router.get("/tracks/{track_id}")
def read_track(track_id: str) -> dict[str, Any]:
    detail = store.track_detail(track_id)
    if detail is None:
        raise HTTPException(status_code=404, detail={"code": "NOT_FOUND", "message": "Track not found"})
    return detail


@router.get("/tracks/{track_id}/transcript")
def read_transcript(track_id: str, fullText: bool = False) -> dict[str, Any] | None:
    return store.transcript(track_id, fullText)


@router.get("/tracks/{track_id}/text")
def read_text(track_id: str) -> dict[str, Any]:
    return {"content": store.text_content(track_id)}


@router.get("/tracks/{track_id}/playback")
def read_playback(track_id: str) -> dict[str, str]:
    source = store.playback(track_id)
    if source is None:
        raise HTTPException(status_code=404, detail={"code": "NOT_FOUND", "message": "No playable source"})
    return source


@router.get("/covers/{collection_id}")
def read_cover(collection_id: str) -> FileResponse:
    path = store.cover_path(collection_id)
    if path is None:
        raise HTTPException(status_code=404, detail={"code": "NOT_FOUND", "message": "Cover not found"})
    return FileResponse(path)


@router.get("/cover")
def read_cover_by_path(path: str) -> FileResponse:
    resolved = store.cover_by_path(path)
    if resolved is None:
        raise HTTPException(status_code=404, detail={"code": "NOT_FOUND", "message": "Cover not found"})
    return FileResponse(resolved)


app = FastAPI(title="PolarBear Library API", version="0.1.0")
app.include_router(router)


@app.exception_handler(HTTPException)
def handle_http_exception(_: Request, exc: HTTPException) -> JSONResponse:
    detail = exc.detail
    if isinstance(detail, dict) and "code" in detail:
        payload = detail
    else:
        payload = {"code": "REQUEST_FAILED", "message": str(detail)}
    return JSONResponse(status_code=exc.status_code, content={"error": payload})


@app.on_event("startup")
def on_startup() -> None:
    store.initialize()
    logger.info("library snapshot ready: %s", store.status().to_dict())


app.mount("/", StaticFiles(directory=WEB_DIR, html=True), name="web")
