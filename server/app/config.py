from __future__ import annotations

from dataclasses import dataclass
import os
from pathlib import Path


@dataclass(frozen=True)
class Settings:
    token: str
    storage_dir: Path
    database_url: str


def load_settings() -> Settings:
    token = os.environ.get("REMOTE_JOBS_TOKEN")
    if not token:
        raise RuntimeError("REMOTE_JOBS_TOKEN is required")

    storage_dir = Path(os.environ.get("REMOTE_JOBS_STORAGE", "./storage")).resolve()
    database_url = os.environ.get("REMOTE_JOBS_DATABASE_URL") or os.environ.get("DATABASE_URL")
    if not database_url:
        raise RuntimeError("REMOTE_JOBS_DATABASE_URL is required")

    storage_dir.mkdir(parents=True, exist_ok=True)

    return Settings(token=token, storage_dir=storage_dir, database_url=database_url)
