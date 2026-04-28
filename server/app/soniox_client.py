from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any

from soniox import SonioxClient
from soniox.types import CreateTranscriptionConfig, StructuredContext

DEFAULT_MODEL = "stt-async-preview"
DEFAULT_LANGUAGE_HINTS = ["zh", "en"]


@dataclass(frozen=True)
class SonioxResult:
    transcript_text: str
    srt_text: str


def _format_srt_time(ms: int) -> str:
    seconds = ms / 1000.0
    hours = int(seconds // 3600)
    minutes = int((seconds % 3600) // 60)
    secs = int(seconds % 60)
    millisecs = int(ms % 1000)
    return f"{hours:02d}:{minutes:02d}:{secs:02d},{millisecs:03d}"


def tokens_to_srt(tokens: list[Any], chunk_duration_ms: int = 5000) -> str:
    """Convert Token list to SRT subtitle format."""
    if not tokens:
        return ""

    srt_parts: list[str] = []
    chunk_index = 1
    chunk_tokens: list[str] = []
    chunk_start_ms: int | None = None
    chunk_end_ms: int | None = None

    for token in tokens:
        text = token.text
        start_ms = token.start_ms or 0
        end_ms = token.end_ms if token.end_ms is not None else start_ms

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


def transcribe_file(
    api_key: str,
    audio_path: Path,
    model: str | None = None,
    language_hints: list[str] | None = None,
    context: str | None = None,
    poll_interval: float = 1.0,
    max_wait_seconds: int = 600,
) -> SonioxResult:
    """
    Transcribe an audio file using Soniox SDK.

    Uses async transcription: upload -> create job -> poll -> get result -> cleanup.
    The SDK handles all HTTP requests with proper timeouts.
    """
    # Soniox SDK's internal httpx client reads proxy env vars.
    # Clear them to avoid proxy-related failures (e.g. missing socksio).
    import os
    for key in ("http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY", "all_proxy", "ALL_PROXY", "no_proxy", "NO_PROXY"):
        os.environ.pop(key, None)

    client = SonioxClient(api_key=api_key)

    # Soniox SDK requires context to be a dict or StructuredContext, not a raw string.
    structured_context = None
    if context:
        structured_context = StructuredContext(text=context)

    config = CreateTranscriptionConfig(
        model=model or DEFAULT_MODEL,
        language_hints=language_hints or DEFAULT_LANGUAGE_HINTS,
        enable_speaker_diarization=True,
        enable_language_identification=True,
        context=structured_context,
    )

    # Use SDK's transcribe_and_wait_with_tokens which handles:
    # - File upload
    # - Transcription creation
    # - Polling until completion
    # - Fetching tokens
    # - Cleanup (delete_after=True)
    with audio_path.open("rb") as handle:
        result = client.stt.transcribe_and_wait_with_tokens(
            file=handle,
            filename=audio_path.name,
            config=config,
            delete_after=True,
            wait_interval_sec=poll_interval,
            wait_timeout_sec=max_wait_seconds,
        )

    srt_text = tokens_to_srt(result.tokens)

    return SonioxResult(
        transcript_text=result.text,
        srt_text=srt_text,
    )
