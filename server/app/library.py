"""Read-only library access for the PolarBear server.

Ports the desktop query layer (desktop/src/main/library.ts) to Python and
serves a consistent snapshot of the iOS `library.sqlite` file. The source
database is never written to: it is copied (db + wal + shm) into a snapshot
directory and opened read-only.
"""

from __future__ import annotations

from dataclasses import dataclass
import json
import logging
import os
from pathlib import Path
import shutil
import sqlite3
import threading
import time
from typing import Any

logger = logging.getLogger(__name__)

DEFAULT_SOURCE = (
    Path.home()
    / "Library/Mobile Documents/iCloud~com~senaca~audiobookplayer/Documents/library.sqlite"
)
SIDECARS = ("", "-wal", "-shm")


def source_path() -> Path:
    return Path(os.environ.get("POLARBEAR_LIBRARY_DB") or DEFAULT_SOURCE)


def snapshot_dir() -> Path:
    return Path(os.environ.get("POLARBEAR_LIBRARY_SNAPSHOT_DIR") or (Path(__file__).parent.parent / "data" / "library"))


def _json_object(value: Any) -> dict[str, Any] | None:
    if not isinstance(value, str):
        return None
    try:
        parsed = json.loads(value)
    except json.JSONDecodeError:
        return None
    return parsed if isinstance(parsed, dict) else None


def _cover(kind: Any, data: Any, dominant_color: Any) -> dict[str, Any]:
    return {
        "kind": kind if isinstance(kind, str) else None,
        "data": _json_object(data),
        "dominantColor": dominant_color if isinstance(dominant_color, str) else None,
    }


def _playback(row: dict[str, Any]) -> dict[str, Any] | None:
    if row.get("playback_position") is None:
        return None
    return {
        "position": float(row.get("playback_position") or 0),
        "duration": None if row.get("playback_duration") is None else float(row["playback_duration"]),
        "updatedAt": row.get("playback_updated_at"),
    }


def _track(row: dict[str, Any]) -> dict[str, Any]:
    location_type = str(row.get("location_type") or "")
    return {
        "id": str(row["id"]),
        "collectionId": str(row.get("collection_id") or ""),
        "displayName": str(row.get("display_name") or row.get("filename") or "未命名"),
        "filename": str(row.get("filename") or ""),
        "locationType": location_type,
        "duration": None if row.get("duration") is None else float(row["duration"]),
        "trackNumber": int(row.get("track_number") or 0),
        "chapter": row.get("chapter"),
        "mediaKind": str(row.get("media_kind") or "audio"),
        "isFavorite": int(row.get("is_favorite") or 0) == 1,
        "isArchived": int(row.get("is_archived") or 0) == 1,
        "playback": _playback(row),
        "playable": location_type in {"baidu", "external", "text"},
    }


def _collection(row: dict[str, Any]) -> dict[str, Any]:
    count = int(row.get("track_count") or 0)
    listened = int(row.get("listened_count") or 0)
    return {
        "id": str(row["id"]),
        "title": str(row.get("title") or "未命名合集"),
        "author": row.get("author"),
        "description": row.get("description"),
        "folderId": row.get("folder_id"),
        "sourceType": str(row.get("source_type") or ""),
        "trackCount": count,
        "listenedCount": listened,
        "progress": (listened / count) if count else 0,
        "lastPlayed": row.get("last_played"),
        "isArchived": int(row.get("is_archived") or 0) == 1,
        "cover": _cover(row.get("cover_kind"), row.get("cover_data"), row.get("cover_dominant_color")),
    }


TRACK_COLUMNS = """
  t.*, ps.position AS playback_position, ps.duration AS playback_duration, ps.updated_at AS playback_updated_at
"""

COLLECTION_COLUMNS = """
  c.*, COUNT(t.id) AS track_count,
  SUM(CASE WHEN ps.track_id IS NOT NULL AND ps.position > 0 THEN 1 ELSE 0 END) AS listened_count,
  MAX(ps.updated_at) AS last_played
"""


@dataclass
class LibraryStatus:
    db_ready: bool
    snapshot_time: int | None
    source_mtime: int | None
    tracks: int
    collections: int
    error: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "dbReady": self.db_ready,
            "snapshotTime": self.snapshot_time,
            "sourceMtime": self.source_mtime,
            "tracks": self.tracks,
            "collections": self.collections,
            **({"error": self.error} if self.error else {}),
        }


class LibraryStore:
    """Snapshot-backed, read-only view of the iOS library database."""

    def __init__(self, source: Path | None = None, snapshot: Path | None = None) -> None:
        self.source = source or source_path()
        self.snapshot = snapshot or (snapshot_dir() / "library-snapshot.sqlite")
        self._lock = threading.RLock()
        self._conn: sqlite3.Connection | None = None
        self._fingerprint: str | None = None
        self._snapshot_time: int | None = None
        self._source_mtime: int | None = None
        self._tracks = 0
        self._collections = 0
        self._error: str | None = None

    # --- snapshot lifecycle -------------------------------------------------

    def _source_fingerprint(self) -> str:
        parts = []
        for suffix in SIDECARS:
            path = Path(f"{self.source}{suffix}")
            try:
                stat = path.stat()
                parts.append(f"{suffix}:{stat.st_mtime_ns}:{stat.st_size}")
            except OSError:
                parts.append(f"{suffix}:missing")
        return "|".join(parts)

    def initialize(self) -> None:
        self.refresh(force=False)

    def refresh(self, force: bool = True) -> LibraryStatus:
        with self._lock:
            fingerprint = self._source_fingerprint()
            if not force and self._conn is not None and self._fingerprint == fingerprint:
                return self.status()
            try:
                self._copy_snapshot()
            except Exception as exc:  # noqa: BLE001 - surfaced to the client
                logger.exception("library snapshot failed")
                self._error = f"数据库快照失败：{exc}"
                return self.status()
            self._fingerprint = fingerprint
            self._snapshot_time = int(time.time() * 1000)
            try:
                self._source_mtime = int(self.source.stat().st_mtime * 1000)
            except OSError:
                self._source_mtime = None
            self._error = None
            self._reopen()
            return self.status()

    def _copy_snapshot(self) -> None:
        if not self.source.exists():
            raise FileNotFoundError(f"未找到 iCloud 数据库：{self.source}")
        self.snapshot.parent.mkdir(parents=True, exist_ok=True)
        staging = self.snapshot.with_suffix(".sqlite.part")
        if staging.exists():
            staging.unlink()
        for suffix in SIDECARS:
            src = Path(f"{self.source}{suffix}")
            dst = Path(f"{staging}{suffix}")
            if src.exists():
                shutil.copyfile(src, dst)
            elif dst.exists():
                dst.unlink()
        probe = sqlite3.connect(f"{staging.resolve().as_uri()}?mode=ro", uri=True)
        try:
            probe.execute("SELECT count(*) FROM collections").fetchone()
        finally:
            probe.close()
        staging.replace(self.snapshot)
        for suffix in ("-wal", "-shm"):
            stale = Path(f"{self.snapshot}{suffix}")
            if stale.exists():
                stale.unlink()
            staged = Path(f"{staging}{suffix}")
            if staged.exists():
                staged.replace(stale)

    def _reopen(self) -> None:
        if self._conn is not None:
            self._conn.close()
        self._conn = sqlite3.connect(
            f"{self.snapshot.resolve().as_uri()}?mode=ro", uri=True, check_same_thread=False
        )
        self._conn.row_factory = sqlite3.Row
        self._conn.execute("PRAGMA query_only = 1")
        self._update_counts()

    def _update_counts(self) -> None:
        conn = self._conn
        if conn is None:
            return
        try:
            self._tracks = int(conn.execute("SELECT count(*) FROM tracks").fetchone()[0])
            self._collections = int(conn.execute("SELECT count(*) FROM collections").fetchone()[0])
        except sqlite3.Error:
            pass

    def status(self) -> LibraryStatus:
        with self._lock:
            return LibraryStatus(
                db_ready=self._conn is not None,
                snapshot_time=self._snapshot_time,
                source_mtime=self._source_mtime,
                tracks=self._tracks,
                collections=self._collections,
                error=self._error,
            )

    # --- queries ------------------------------------------------------------

    def _query(self, sql: str, params: tuple[Any, ...] = ()) -> list[dict[str, Any]]:
        with self._lock:
            if self._conn is None:
                raise RuntimeError("数据库尚未就绪")
            rows = self._conn.execute(sql, params).fetchall()
        return [dict(row) for row in rows]

    def _query_one(self, sql: str, params: tuple[Any, ...] = ()) -> dict[str, Any] | None:
        rows = self._query(sql, params)
        return rows[0] if rows else None

    def folders(self) -> list[dict[str, Any]]:
        rows = self._query("SELECT * FROM collection_folders ORDER BY name COLLATE NOCASE")
        return [
            {
                "id": str(row["id"]),
                "name": str(row["name"]),
                "cover": _cover(row.get("cover_kind"), row.get("cover_data"), row.get("cover_dominant_color")),
            }
            for row in rows
        ]

    def collections(self, folder_id: str | None = None, include_archived: bool = False) -> list[dict[str, Any]]:
        condition = "c.folder_id = ?" if folder_id else "1=1"
        archive = "" if include_archived else "AND c.is_archived = 0"
        track_archive = "" if include_archived else " AND COALESCE(t.is_archived,0)=0"
        params = (folder_id,) if folder_id else ()
        rows = self._query(
            f"SELECT {COLLECTION_COLUMNS} FROM collections c "
            f"LEFT JOIN tracks t ON t.collection_id=c.id{track_archive} "
            f"LEFT JOIN playback_states ps ON ps.collection_id=c.id "
            f"WHERE {condition} {archive} GROUP BY c.id ORDER BY c.title COLLATE NOCASE",
            params,
        )
        return [_collection(row) for row in rows]

    def tracks(
        self, collection_id: str, page: int = 0, page_size: int = 200, include_archived: bool = False
    ) -> dict[str, Any]:
        page_size = max(1, min(page_size, 500))
        page = max(0, page)
        archive = "" if include_archived else " AND COALESCE(t.is_archived,0)=0"
        base = f"FROM tracks t LEFT JOIN playback_states ps ON ps.track_id=t.id WHERE t.collection_id = ?{archive}"
        total_row = self._query_one(f"SELECT COUNT(*) AS n {base}", (collection_id,))
        total = int(total_row["n"]) if total_row else 0
        rows = self._query(
            f"SELECT {TRACK_COLUMNS} {base} "
            "ORDER BY CASE WHEN t.track_number IS NULL THEN 1 ELSE 0 END, t.track_number, t.display_name COLLATE NOCASE "
            "LIMIT ? OFFSET ?",
            (collection_id, page_size, page * page_size),
        )
        return {"tracks": [_track(row) for row in rows], "total": total, "page": page, "pageSize": page_size}

    def continue_listening(self, limit: int = 20) -> list[dict[str, Any]]:
        rows = self._query(
            """
            WITH ranked AS (
              SELECT t.*, c.title AS collection_title, c.author AS collection_author,
                     ps.position AS playback_position, ps.duration AS playback_duration,
                     ps.updated_at AS playback_updated_at,
                     ROW_NUMBER() OVER(PARTITION BY t.collection_id ORDER BY ps.updated_at DESC) AS rn
              FROM playback_states ps
              JOIN tracks t ON t.id=ps.track_id
              JOIN collections c ON c.id=t.collection_id
              WHERE ps.position > 0 AND COALESCE(t.is_archived,0)=0 AND COALESCE(c.is_archived,0)=0
            )
            SELECT * FROM ranked WHERE rn = 1 ORDER BY playback_updated_at DESC LIMIT ?
            """,
            (max(1, min(limit, 100)),),
        )
        items = []
        for row in rows:
            item = _track(row)
            item["collectionTitle"] = str(row.get("collection_title") or "")
            item["collectionAuthor"] = row.get("collection_author")
            items.append(item)
        return items

    def favorites(self, limit: int = 500) -> list[dict[str, Any]]:
        rows = self._query(
            f"SELECT {TRACK_COLUMNS} FROM tracks t LEFT JOIN playback_states ps ON ps.track_id=t.id "
            "WHERE t.is_favorite=1 AND COALESCE(t.is_archived,0)=0 ORDER BY t.display_name COLLATE NOCASE LIMIT ?",
            (max(1, min(limit, 500)),),
        )
        return [_track(row) for row in rows]

    def search(self, query: str, limit: int = 50) -> list[dict[str, Any]]:
        trimmed = query.strip()
        if not trimmed:
            return []
        pattern = f"%{trimmed}%"
        track_limit = max(1, min(limit, 200))
        collection_limit = max(1, min(max(limit // 4, 5), 50))
        track_rows = self._query(
            f"SELECT {TRACK_COLUMNS} FROM tracks t JOIN collections c ON c.id=t.collection_id "
            "LEFT JOIN playback_states ps ON ps.track_id=t.id "
            "WHERE COALESCE(t.is_archived,0)=0 AND COALESCE(c.is_archived,0)=0 "
            "AND (t.display_name LIKE ? OR t.filename LIKE ? OR c.title LIKE ? OR c.author LIKE ?) "
            "ORDER BY c.title COLLATE NOCASE, t.track_number LIMIT ?",
            (pattern, pattern, pattern, pattern, track_limit),
        )
        collection_rows = self._query(
            f"SELECT {COLLECTION_COLUMNS} FROM collections c "
            "LEFT JOIN tracks t ON t.collection_id=c.id "
            "LEFT JOIN playback_states ps ON ps.collection_id=c.id "
            "WHERE COALESCE(c.is_archived,0)=0 AND (c.title LIKE ? OR c.author LIKE ? OR c.description LIKE ?) "
            "GROUP BY c.id ORDER BY c.title COLLATE NOCASE LIMIT ?",
            (pattern, pattern, pattern, collection_limit),
        )
        results: list[dict[str, Any]] = [
            {"type": "collection", "data": _collection(row)} for row in collection_rows
        ]
        results.extend({"type": "track", "data": _track(row)} for row in track_rows)
        return results

    def _summary(self, track_id: str) -> dict[str, Any] | None:
        row = self._query_one(
            "SELECT id, summary_title, summary_body, keywords_json FROM track_summaries "
            "WHERE track_id = ? AND status = 'complete' ORDER BY updated_at DESC LIMIT 1",
            (track_id,),
        )
        if not row:
            return None
        keywords: list[str] = []
        parsed = _json_object(row.get("keywords_json"))
        candidate = parsed.get("keywords") if parsed else None
        if candidate is None:
            candidate = parsed
        if isinstance(candidate, list):
            keywords = [item for item in candidate if isinstance(item, str)]
        sections = self._query(
            "SELECT title, summary, start_time_ms FROM track_summary_sections WHERE track_summary_id = ? ORDER BY order_index",
            (str(row["id"]),),
        )
        return {
            "title": row.get("summary_title"),
            "body": row.get("summary_body"),
            "keywords": keywords,
            "sections": [
                {
                    "title": section.get("title"),
                    "summary": str(section.get("summary") or ""),
                    "startMs": int(section.get("start_time_ms") or 0),
                }
                for section in sections
            ],
        }

    def track_detail(self, track_id: str) -> dict[str, Any] | None:
        row = self._query_one(
            """
            SELECT t.*, c.id AS c_id, c.title AS c_title, c.author AS c_author, c.description AS c_description,
                   c.cover_kind AS c_cover_kind, c.cover_data AS c_cover_data,
                   c.cover_dominant_color AS c_cover_dominant_color, c.folder_id AS c_folder_id,
                   c.source_type AS c_source_type, c.is_archived AS c_is_archived,
                   (SELECT COUNT(*) FROM tracks t2 WHERE t2.collection_id = c.id AND COALESCE(t2.is_archived,0)=0) AS c_track_count,
                   ps.position AS playback_position, ps.duration AS playback_duration, ps.updated_at AS playback_updated_at
            FROM tracks t JOIN collections c ON c.id = t.collection_id
            LEFT JOIN playback_states ps ON ps.track_id = t.id
            WHERE t.id = ?
            """,
            (track_id,),
        )
        if not row:
            return None
        track = _track(row)
        metadata = _json_object(row.get("metadata_json"))
        description = None
        if isinstance(row.get("description"), str) and row["description"]:
            description = row["description"]
        elif metadata:
            for key in ("description", "summary", "subtitle", "note", "abstract"):
                value = metadata.get(key)
                if isinstance(value, str) and value.strip():
                    description = value
                    break
        collection = None
        if row.get("c_id"):
            collection = {
                "id": str(row["c_id"]),
                "title": str(row.get("c_title") or "未命名合集"),
                "author": row.get("c_author"),
                "description": row.get("c_description"),
                "cover": _cover(row.get("c_cover_kind"), row.get("c_cover_data"), row.get("c_cover_dominant_color")),
                "folderId": row.get("c_folder_id"),
                "trackCount": int(row.get("c_track_count") or 0),
            }
        listening_row = self._query_one(
            "SELECT COUNT(*) AS sessions, MAX(end_time) AS last_listened FROM listening_statistics WHERE track_id = ?",
            (track_id,),
        )
        transcript_row = self._query_one(
            "SELECT tr.language, (SELECT COUNT(*) FROM transcript_segments s WHERE s.transcript_id = tr.id) AS cnt "
            "FROM transcripts tr WHERE tr.track_id = ? AND tr.job_status = 'complete' ORDER BY tr.updated_at DESC LIMIT 1",
            (track_id,),
        )
        transcript = None
        if transcript_row and int(transcript_row["cnt"]) > 0:
            transcript = {"segmentsCount": int(transcript_row["cnt"]), "language": str(transcript_row["language"] or "")}
        return {
            "track": {
                **track,
                "fileSize": None if row.get("file_size") is None else int(row["file_size"]),
                "characterCount": None if row.get("character_count") is None else int(row["character_count"]),
                "checksum": row.get("checksum") if isinstance(row.get("checksum"), str) else None,
                "description": description,
                "metadata": metadata,
            },
            "collection": collection,
            "playback": _playback(row),
            "listening": {
                "sessions": int(listening_row["sessions"]) if listening_row else 0,
                "totalSec": 0,
                "lastListenedAt": listening_row["last_listened"] if listening_row else None,
            },
            "transcript": transcript,
            "summary": self._summary(track_id),
        }

    def transcript(self, track_id: str, include_full_text: bool = False) -> dict[str, Any] | None:
        row = self._query_one(
            "SELECT id, language, full_text FROM transcripts WHERE track_id = ? AND job_status = 'complete' "
            "ORDER BY updated_at DESC LIMIT 1",
            (track_id,),
        )
        if not row:
            return None
        segments = self._query(
            "SELECT text, start_time_ms, end_time_ms, speaker FROM transcript_segments WHERE transcript_id = ? ORDER BY start_time_ms",
            (str(row["id"]),),
        )
        return {
            "language": str(row["language"] or ""),
            "segments": [
                {
                    "startMs": int(segment.get("start_time_ms") or 0),
                    "endMs": int(segment.get("end_time_ms") or 0),
                    "text": str(segment.get("text") or ""),
                    "speaker": segment.get("speaker"),
                }
                for segment in segments
            ],
            "fullText": (row.get("full_text") if isinstance(row.get("full_text"), str) else "") if include_full_text else None,
        }

    def text_content(self, track_id: str) -> str | None:
        row = self._query_one("SELECT location_type, location_payload FROM tracks WHERE id=?", (track_id,))
        if not row or row["location_type"] not in {"text", "cachedText"}:
            return None
        payload = _json_object(row.get("location_payload"))
        content = payload.get("content") if payload else None
        return content if isinstance(content, str) else None

    def playback(self, track_id: str) -> dict[str, str] | None:
        row = self._query_one("SELECT location_type, location_payload FROM tracks WHERE id=?", (track_id,))
        if not row:
            return None
        payload = _json_object(row.get("location_payload"))
        if row["location_type"] == "baidu" and payload and isinstance(payload.get("path"), str):
            return {"kind": "baidu", "value": payload["path"]}
        if row["location_type"] == "external" and payload and isinstance(payload.get("url"), str):
            return {"kind": "external", "value": payload["url"]}
        return None

    def cover_path(self, collection_id: str) -> Path | None:
        row = self._query_one(
            "SELECT cover_kind, cover_data FROM collections WHERE id=?", (collection_id,)
        )
        if not row or row.get("cover_kind") != "image":
            return None
        payload = _json_object(row.get("cover_data"))
        if not payload:
            return None
        relative = payload.get("relativePath")
        if not isinstance(relative, str) or not relative:
            return None
        return self._resolve_cover(relative)

    def cover_by_path(self, relative_path: str) -> Path | None:
        if not relative_path:
            return None
        return self._resolve_cover(relative_path)

    def _resolve_cover(self, relative_path: str) -> Path | None:
        root = self.source.parent.resolve()
        candidate = (root / relative_path).resolve()
        if candidate != root and not candidate.is_relative_to(root):
            return None
        return candidate if candidate.exists() else None
