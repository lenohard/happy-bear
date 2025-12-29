from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import time
from typing import Any

import requests


SONIOX_API_BASE_URL = "https://api.soniox.com"
DEFAULT_MODEL = "stt-async-preview"
DEFAULT_LANGUAGE_HINTS = ["zh", "en"]


@dataclass(frozen=True)
class SonioxResult:
    transcript_text: str
    srt_text: str


def _token_time_bounds(token: dict[str, Any]) -> tuple[int, int]:
    start_ms = token.get("start_ms") or 0
    end_ms = token.get("end_ms")
    if end_ms is None:
        duration_ms = token.get("duration_ms")
        if duration_ms is not None:
            end_ms = start_ms + duration_ms
        else:
            end_ms = start_ms
    return start_ms, end_ms


def _format_srt_time(ms: int) -> str:
    seconds = ms / 1000.0
    hours = int(seconds // 3600)
    minutes = int((seconds % 3600) // 60)
    secs = int(seconds % 60)
    millisecs = int(ms % 1000)
    return f"{hours:02d}:{minutes:02d}:{secs:02d},{millisecs:03d}"


def tokens_to_srt(tokens: list[dict[str, Any]], chunk_duration_ms: int = 5000) -> str:
    if not tokens:
        return ""

    srt_parts: list[str] = []
    chunk_index = 1
    chunk_tokens: list[str] = []
    chunk_start_ms: int | None = None
    chunk_end_ms: int | None = None

    for token in tokens:
        text = token.get("text", "")
        start_ms, end_ms = _token_time_bounds(token)

        if chunk_start_ms is None:
            chunk_start_ms = start_ms
            chunk_tokens = [text]
            chunk_end_ms = end_ms
        elif (end_ms - chunk_start_ms) <= chunk_duration_ms:
            chunk_tokens.append(text)
            chunk_end_ms = end_ms
        else:
            srt_parts.append(f"{chunk_index}\n")
            srt_parts.append(f"{_format_srt_time(chunk_start_ms)} --> {_format_srt_time(chunk_end_ms)}\n")
            srt_parts.append(f"{''.join(chunk_tokens).strip()}\n\n")

            chunk_index += 1
            chunk_start_ms = start_ms
            chunk_tokens = [text]
            chunk_end_ms = end_ms

    if chunk_tokens and chunk_start_ms is not None and chunk_end_ms is not None:
        srt_parts.append(f"{chunk_index}\n")
        srt_parts.append(f"{_format_srt_time(chunk_start_ms)} --> {_format_srt_time(chunk_end_ms)}\n")
        srt_parts.append(f"{''.join(chunk_tokens).strip()}\n")

    return "".join(srt_parts)


def tokens_to_text(tokens: list[dict[str, Any]]) -> str:
    return "".join(token.get("text", "") for token in tokens)


def transcribe_file(
    api_key: str,
    audio_path: Path,
    model: str | None = None,
    language_hints: list[str] | None = None,
    context: str | None = None,
    poll_interval: float = 1.0,
    max_wait_seconds: int = 600,
) -> SonioxResult:
    headers = {"Authorization": f"Bearer {api_key}"}
    timeout = 60

    session = requests.Session()
    session.headers.update(headers)
    session.trust_env = False

    with audio_path.open("rb") as handle:
        files = {"file": handle}
        upload_response = session.post(f"{SONIOX_API_BASE_URL}/v1/files", files=files, timeout=timeout)
    upload_response.raise_for_status()
    file_payload = upload_response.json()
    file_id = file_payload.get("id")
    if not file_id:
        raise RuntimeError("Soniox file upload missing id")

    config: dict[str, Any] = {
        "file_id": file_id,
        "model": model or DEFAULT_MODEL,
        "language_hints": language_hints or DEFAULT_LANGUAGE_HINTS,
        "enable_speaker_diarization": True,
        "enable_language_identification": True,
    }
    if context:
        config["context"] = context

    transcription_response = session.post(
        f"{SONIOX_API_BASE_URL}/v1/transcriptions", json=config, timeout=timeout
    )
    transcription_response.raise_for_status()
    transcription_payload = transcription_response.json()
    transcription_id = transcription_payload.get("id")
    if not transcription_id:
        raise RuntimeError("Soniox transcription missing id")

    start_time = time.time()
    status = None
    error_message = None
    while True:
        status_response = session.get(
            f"{SONIOX_API_BASE_URL}/v1/transcriptions/{transcription_id}", timeout=timeout
        )
        status_response.raise_for_status()
        status_payload = status_response.json()
        status = status_payload.get("status")
        if status == "completed":
            break
        if status == "error":
            error_message = status_payload.get("error_message") or "Unknown Soniox error"
            break

        if time.time() - start_time > max_wait_seconds:
            error_message = "Soniox transcription timed out"
            break

        time.sleep(poll_interval)

    if status != "completed":
        raise RuntimeError(error_message or "Soniox transcription failed")

    transcript_response = session.get(
        f"{SONIOX_API_BASE_URL}/v1/transcriptions/{transcription_id}/transcript", timeout=timeout
    )
    transcript_response.raise_for_status()
    transcript_payload = transcript_response.json()
    tokens = transcript_payload.get("tokens") or []
    srt_text = tokens_to_srt(tokens)
    transcript_text = tokens_to_text(tokens)

    session.delete(f"{SONIOX_API_BASE_URL}/v1/transcriptions/{transcription_id}", timeout=timeout)
    session.delete(f"{SONIOX_API_BASE_URL}/v1/files/{file_id}", timeout=timeout)

    return SonioxResult(transcript_text=transcript_text, srt_text=srt_text)
