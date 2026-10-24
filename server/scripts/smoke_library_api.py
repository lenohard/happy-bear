"""Smoke test for the PolarBear library API. Run: python3 server/scripts/smoke_library_api.py"""

from __future__ import annotations

import json
import os
from pathlib import Path
import sys
import urllib.error
import urllib.request

TOKEN = os.environ.get("POLARBEAR_LIBRARY_TOKEN", "smoke-token")
BASE = os.environ.get("POLARBEAR_LIBRARY_BASE", "http://127.0.0.1:8082")


def get(path: str, token: str | None = TOKEN) -> tuple[int, object]:
    request = urllib.request.Request(f"{BASE}{path}")
    if token is not None:
        request.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            body = response.read()
            ctype = response.headers.get("Content-Type", "")
            if "json" in ctype:
                return response.status, json.loads(body)
            return response.status, {"bytes": len(body), "contentType": ctype}
    except urllib.error.HTTPError as error:
        return error.code, json.loads(error.read() or b"{}")


def check(name: str, condition: bool, detail: str = "") -> None:
    print(f"{'PASS' if condition else 'FAIL'}  {name}{f' :: {detail}' if detail else ''}")
    if not condition:
        raise SystemExit(1)


def main() -> None:
    status, body = get("/v1/library/status")
    check("status 200", status == 200, str(body)[:200])
    check("status dbReady", bool(body.get("dbReady")), str(body)[:200])
    check("status has tracks", int(body.get("tracks") or 0) > 0, str(body.get("tracks")))
    check("status has collections", int(body.get("collections") or 0) > 0, str(body.get("collections")))

    status, folders = get("/v1/library/folders")
    check("folders 200", status == 200)
    check("folders list", isinstance(folders, list), str(folders)[:200])

    status, collections = get("/v1/library/collections")
    check("collections 200", status == 200)
    check("collections non-empty", isinstance(collections, list) and len(collections) > 0, str(len(collections or [])))
    first = collections[0]
    check(
        "collection shape",
        {"id", "title", "trackCount", "progress", "cover"} <= set(first),
        ",".join(sorted(first)),
    )

    if folders:
        status, scoped = get(f"/v1/library/collections?folderId={folders[0]['id']}")
        check("collections by folder 200", status == 200, str(scoped)[:160])

    collection_id = first["id"]
    status, page = get(f"/v1/library/collections/{collection_id}/tracks?page=0&pageSize=5")
    check("tracks 200", status == 200, str(page)[:200])
    check("tracks page shape", {"tracks", "total", "page", "pageSize"} <= set(page))
    check("tracks has items", len(page.get("tracks") or []) > 0, str(page.get("total")))
    track = page["tracks"][0]
    check("track shape", {"id", "displayName", "locationType", "playable"} <= set(track), ",".join(sorted(track)))

    status, cont = get("/v1/library/tracks/continue?limit=5")
    check("continue 200", status == 200, str(cont)[:160])

    status, favs = get("/v1/library/tracks/favorites?limit=5")
    check("favorites 200", status == 200, str(favs)[:160])

    status, results = get("/v1/library/search?q=a&limit=5")
    check("search 200", status == 200, str(results)[:160])

    status, detail = get(f"/v1/library/tracks/{track['id']}")
    check("track detail 200", status == 200, str(detail)[:200])
    check("track detail shape", {"track", "collection", "playback", "listening", "transcript", "summary"} <= set(detail))

    status, transcript = get(f"/v1/library/tracks/{track['id']}/transcript?fullText=1")
    check("transcript 200", status == 200, str(transcript)[:160])

    status, text = get(f"/v1/library/tracks/{track['id']}/text")
    check("text 200", status == 200, str(text)[:160])

    status, playback = get(f"/v1/library/tracks/{track['id']}/playback")
    check("playback 200 or 404", status in (200, 404), str(playback)[:160])

    status, cover = get(f"/v1/library/covers/{collection_id}")
    check("cover 200 or 404", status in (200, 404), str(cover)[:160])

    status, body = get("/v1/library/status", token=None)
    check("missing token 401", status == 401, str(body)[:160])
    status, body = get("/v1/library/status", token="wrong")
    check("bad token 401", status == 401, str(body)[:160])

    print("\nall library API smoke checks passed")


if __name__ == "__main__":
    sys.exit(main())
