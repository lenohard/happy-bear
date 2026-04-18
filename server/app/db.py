from __future__ import annotations

from datetime import datetime, timezone
from typing import Any

import psycopg
from psycopg.rows import dict_row

from .config import load_settings


def _connect() -> psycopg.Connection[dict]:
    settings = load_settings()
    return psycopg.connect(settings.database_url, row_factory=dict_row)


def init_db() -> None:
    conn = _connect()
    try:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS jobs (
                id TEXT PRIMARY KEY,
                type TEXT NOT NULL,
                status TEXT NOT NULL,
                progress DOUBLE PRECISION NOT NULL,
                phase TEXT,
                phase_started_at TEXT,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                error_code TEXT,
                error_message TEXT,
                input_kind TEXT,
                input_mime TEXT,
                input_size BIGINT,
                input_text TEXT,
                input_url TEXT,
                input_source TEXT,
                input_cookie TEXT,
                input_path TEXT,
                dedup_key TEXT,
                params_json TEXT,
                output_kind TEXT,
                output_mime TEXT,
                output_size BIGINT,
                output_text TEXT,
                result_path TEXT
            )
            """
        )
        _ensure_column(conn, "jobs", "input_path", "TEXT")
        _ensure_column(conn, "jobs", "dedup_key", "TEXT")
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_jobs_dedup_key ON jobs (dedup_key)"
        )
        _ensure_column(conn, "jobs", "params_json", "TEXT")
        _ensure_column(conn, "jobs", "output_text", "TEXT")
        _ensure_column(conn, "jobs", "input_url", "TEXT")
        _ensure_column(conn, "jobs", "input_source", "TEXT")
        _ensure_column(conn, "jobs", "input_cookie", "TEXT")
        _ensure_column(conn, "jobs", "phase", "TEXT")
        _ensure_column(conn, "jobs", "phase_started_at", "TEXT")
        conn.commit()
    finally:
        conn.close()


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _ensure_column(conn: psycopg.Connection[dict], table: str, column: str, column_type: str) -> None:
    conn.execute(f"ALTER TABLE {table} ADD COLUMN IF NOT EXISTS {column} {column_type}")


def insert_job(job: dict[str, Any]) -> None:
    conn = _connect()
    try:
        conn.execute(
            """
            INSERT INTO jobs (
                id, type, status, progress, phase, phase_started_at, created_at, updated_at,
                error_code, error_message, input_kind, input_mime,
                input_size, input_text, input_url, input_source, input_cookie, input_path, dedup_key, params_json,
                output_kind, output_mime, output_size, output_text,
                result_path
            ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
            """,
            (
                job["id"],
                job["type"],
                job["status"],
                job["progress"],
                job.get("phase"),
                job.get("phase_started_at"),
                job["created_at"],
                job["updated_at"],
                job.get("error_code"),
                job.get("error_message"),
                job.get("input_kind"),
                job.get("input_mime"),
                job.get("input_size"),
                job.get("input_text"),
                job.get("input_url"),
                job.get("input_source"),
                job.get("input_cookie"),
                job.get("input_path"),
                job.get("dedup_key"),
                job.get("params_json"),
                job.get("output_kind"),
                job.get("output_mime"),
                job.get("output_size"),
                job.get("output_text"),
                job.get("result_path"),
            ),
        )
        conn.commit()
    finally:
        conn.close()


def update_job(job_id: str, **fields: Any) -> None:
    if not fields:
        return
    fields["updated_at"] = _utc_now()
    columns = ", ".join(f"{key} = %s" for key in fields)
    values = list(fields.values())
    values.append(job_id)

    conn = _connect()
    try:
        conn.execute(
            f"UPDATE jobs SET {columns} WHERE id = %s",
            values,
        )
        conn.commit()
    finally:
        conn.close()


def get_job(job_id: str) -> dict[str, Any] | None:
    conn = _connect()
    try:
        row = conn.execute("SELECT * FROM jobs WHERE id = %s", (job_id,)).fetchone()
        if not row:
            return None
        return dict(row)
    finally:
        conn.close()


def find_cached_input(dedup_key: str, job_type: str) -> str | None:
    """Find a prior job's input_path for the same dedup_key & type.

    Returns the on-disk path if found and the file still exists, else None.
    """
    if not dedup_key:
        return None
    conn = _connect()
    try:
        row = conn.execute(
            """
            SELECT input_path FROM jobs
            WHERE dedup_key = %s AND type = %s AND input_path IS NOT NULL
            ORDER BY created_at DESC
            LIMIT 1
            """,
            (dedup_key, job_type),
        ).fetchone()
        if not row:
            return None
        return row.get("input_path")
    finally:
        conn.close()


def delete_job(job_id: str) -> None:
    conn = _connect()
    try:
        conn.execute("DELETE FROM jobs WHERE id = %s", (job_id,))
        conn.commit()
    finally:
        conn.close()


def list_jobs(filters: dict[str, Any], limit: int, cursor: str | None) -> tuple[list[dict[str, Any]], str | None]:
    conn = _connect()
    try:
        clauses = []
        values: list[Any] = []

        if "status" in filters:
            clauses.append("status = %s")
            values.append(filters["status"])
        if "type" in filters:
            clauses.append("type = %s")
            values.append(filters["type"])

        if cursor:
            clauses.append("created_at < %s")
            values.append(cursor)

        where_clause = " AND ".join(clauses)
        if where_clause:
            where_clause = "WHERE " + where_clause

        rows = conn.execute(
            f"SELECT * FROM jobs {where_clause} ORDER BY created_at DESC LIMIT %s",
            (*values, limit + 1),
        ).fetchall()

        jobs = [dict(row) for row in rows[:limit]]
        next_cursor = None
        if len(rows) > limit:
            next_cursor = jobs[-1]["created_at"]

        return jobs, next_cursor
    finally:
        conn.close()
