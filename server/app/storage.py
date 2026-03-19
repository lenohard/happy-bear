from __future__ import annotations

import shutil
from pathlib import Path

from .config import load_settings


def job_dir(job_id: str) -> Path:
    settings = load_settings()
    path = settings.storage_dir / job_id
    path.mkdir(parents=True, exist_ok=True)
    return path


def input_path(job_id: str, filename: str) -> Path:
    return job_dir(job_id) / f"input_{filename}"


def result_path(job_id: str, filename: str) -> Path:
    return job_dir(job_id) / f"result_{filename}"


def delete_job_files(job_id: str) -> None:
    settings = load_settings()
    path = settings.storage_dir / job_id
    if path.exists():
        shutil.rmtree(path)
