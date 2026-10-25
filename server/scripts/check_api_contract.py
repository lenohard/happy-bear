"""Verifies the library API JSON matches the desktop LibraryProvider contract.

Run: server/.venv/bin/python server/scripts/check_api_contract.py
"""

from __future__ import annotations

import json
import os
import urllib.request

BASE = os.environ.get("POLARBEAR_LIBRARY_BASE", "http://127.0.0.1:8082")

COVER = {"kind", "data", "dominantColor"}
FOLDER = {"id", "name", "cover"}
COLLECTION = {
    "id", "title", "author", "description", "folderId", "sourceType",
    "trackCount", "listenedCount", "progress", "lastPlayed", "isArchived", "cover",
}
PLAYBACK = {"position", "duration", "updatedAt"}
TRACK = {
    "id", "collectionId", "displayName", "filename", "locationType", "duration",
    "trackNumber", "chapter", "mediaKind", "isFavorite", "isArchived", "playback", "playable",
}
SUMMARY = {"title", "body", "keywords", "sections"}
STATUS = {"dbReady", "snapshotTime", "sourceMtime", "tracks", "collections"}


def get(path: str):
    request = urllib.request.Request(f"{BASE}{path}")
    with urllib.request.urlopen(request, timeout=20) as response:
        return json.loads(response.read())


def check(name: str, payload: dict, expected: set[str], optional: set[str] | None = None) -> None:
    optional = optional or set()
    missing = expected - set(payload)
    extra = set(payload) - expected - optional
    status = "PASS" if not missing and not extra else "FAIL"
    print(f"{status}  {name} missing={sorted(missing)} extra={sorted(extra)}")
    if missing or extra:
        raise SystemExit(1)


def main() -> None:
    status = get("/v1/library/status")
    check("status", status, STATUS, {"error"})

    folders = get("/v1/library/folders")
    check("folder[0]", folders[0], FOLDER)

    collections = get("/v1/library/collections")
    check("collection[0]", collections[0], COLLECTION)
    check("collection[0].cover", collections[0]["cover"], COVER)

    tracks = get(f"/v1/library/collections/{collections[0]['id']}/tracks?page=0&pageSize=3")
    check("trackPage", tracks, {"tracks", "total", "page", "pageSize"})
    track = tracks["tracks"][0]
    check("track[0]", track, TRACK)
    if track["playback"] is not None:
        check("track[0].playback", track["playback"], PLAYBACK)

    cont = get("/v1/library/tracks/continue?limit=3")
    check("continue[0]", cont[0], TRACK | {"collectionTitle", "collectionAuthor"})

    favs = get("/v1/library/tracks/favorites?limit=3")
    check("favorite[0]", favs[0], TRACK)

    results = get("/v1/library/search?q=a&limit=3")
    check("search[0]", results[0], {"type", "data"})

    detail = get(f"/v1/library/tracks/{track['id']}")
    check("trackDetail", detail, {"track", "collection", "playback", "listening", "transcript", "summary"})
    check(
        "trackDetail.track",
        detail["track"],
        TRACK | {"fileSize", "characterCount", "checksum", "description", "metadata"},
    )
    if detail["collection"] is not None:
        check(
            "trackDetail.collection",
            detail["collection"],
            {"id", "title", "author", "description", "cover", "folderId", "trackCount"},
        )
    check("trackDetail.listening", detail["listening"], {"sessions", "totalSec", "lastListenedAt"})
    if detail["summary"] is not None:
        check("trackDetail.summary", detail["summary"], SUMMARY)

    transcript = get(f"/v1/library/tracks/{track['id']}/transcript?fullText=1")
    if transcript is not None:
        check("transcript", transcript, {"language", "segments", "fullText"})

    playback = get(f"/v1/library/tracks/{track['id']}/playback")
    check("playback", playback, {"kind", "value"})

    print("\nAPI contract matches the desktop LibraryProvider types")


if __name__ == "__main__":
    main()
