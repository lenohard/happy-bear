from __future__ import annotations

import json
import logging
import os
from pathlib import Path
import time
from datetime import datetime, timezone
from typing import Any
from urllib.parse import urlparse

import requests

from . import db
from .ai_gateway_client import DEFAULT_MODEL as DEFAULT_AI_MODEL
from .ai_gateway_client import generate_text, generate_text_openrouter
from .soniox_client import DEFAULT_MODEL as DEFAULT_STT_MODEL
from .soniox_client import transcribe_file
from .storage import input_path, result_path


logger = logging.getLogger(__name__)


def _try_generate_text(
    messages: list[dict[str, Any]],
    **kwargs: Any,
) -> AIGatewayResult:
    """Try Vercel AI Gateway first, fall back to OpenRouter on failure."""
    api_key = os.environ.get("VERCEL_AI_GATEWAY_API_KEY")
    if api_key:
        try:
            return generate_text(api_key=api_key, messages=messages, **kwargs)
        except Exception as exc:
            logger.error("Vercel AI Gateway failed: %s, falling back to OpenRouter", exc)

    openrouter_api_key = os.environ.get("OPENROUTER_API_KEY")
    if openrouter_api_key:
        logger.info("Using OpenRouter as fallback for AI generation")
        return generate_text_openrouter(api_key=openrouter_api_key, messages=messages, **kwargs)

    raise RuntimeError("No AI API keys available")


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _duration_ms(start_at: str, end_at: str) -> int:
    start = datetime.fromisoformat(start_at)
    end = datetime.fromisoformat(end_at)
    return int((end - start).total_seconds() * 1000)


def _set_phase(job_id: str, phase: str, **fields: Any) -> None:
    now = _utc_now()
    job = db.get_job(job_id)
    if job:
        previous_phase = job.get("phase")
        previous_started_at = job.get("phase_started_at")
        if previous_phase and previous_started_at and previous_phase != phase:
            duration_ms = _duration_ms(previous_started_at, now)
            logger.info("job=%s phase=%s duration_ms=%s", job_id, previous_phase, duration_ms)

    db.update_job(job_id, phase=phase, phase_started_at=now, **fields)
    logger.info("job=%s phase=%s status=%s progress=%s", job_id, phase, fields.get("status"), fields.get("progress"))


def _download_url_input(job_id: str, job: dict[str, Any]) -> Path:
    input_url = job.get("input_url")
    input_source = job.get("input_source")
    input_cookie = job.get("input_cookie")
    if not input_url or not input_source:
        raise RuntimeError("Missing input url or source")

    parsed = urlparse(input_url)
    filename = Path(parsed.path).name or "download"
    target_path = input_path(job_id, filename)

    session = requests.Session()
    session.trust_env = False
    headers = {
        "User-Agent": "AudiobookPlayer/1.0",
        "Accept": "*/*",
    }
    if input_source == "baidu" and input_cookie:
        headers["Cookie"] = input_cookie
    with session.get(input_url, headers=headers, stream=True, timeout=120) as response:
        if response.status_code != 200:
            raise RuntimeError(f"Download failed: {response.status_code}")
        with target_path.open("wb") as handle:
            for chunk in response.iter_content(chunk_size=1024 * 1024):
                if chunk:
                    handle.write(chunk)

        content_type = response.headers.get("Content-Type")
        content_length = response.headers.get("Content-Length")

    db.update_job(
        job_id,
        input_path=str(target_path),
        input_size=int(content_length) if content_length and content_length.isdigit() else target_path.stat().st_size,
        input_mime=content_type,
        input_cookie=None,
    )

    return target_path


def run_job(job_id: str) -> None:
    job = db.get_job(job_id)
    if not job:
        return

    if job["status"] in {"canceled", "failed", "succeeded"}:
        return

    _set_phase(job_id, "starting", status="running", progress=0.1)
    time.sleep(0.2)

    job_type = job["type"]
    params = {}
    if job.get("params_json"):
        try:
            params = json.loads(job["params_json"])
        except json.JSONDecodeError:
            params = {}

    if job_type == "stt":
        api_key = os.environ.get("SONIOX_API_KEY")
        if not api_key:
            _set_phase(
                job_id,
                "failed",
                status="failed",
                progress=1.0,
                error_code="PROCESSING_FAILED",
                error_message="SONIOX_API_KEY not set",
            )
            return

        input_kind = job.get("input_kind")
        input_path_value = job.get("input_path")
        if input_kind == "url" and not input_path_value:
            try:
                _set_phase(job_id, "downloading", progress=0.2)
                input_path_value = str(_download_url_input(job_id, job))
            except Exception as exc:
                _set_phase(
                    job_id,
                    "failed",
                    status="failed",
                    progress=1.0,
                    error_code="PROCESSING_FAILED",
                    error_message=str(exc),
                )
                return

        if not input_path_value:
            _set_phase(
                job_id,
                "failed",
                status="failed",
                progress=1.0,
                error_code="PROCESSING_FAILED",
                error_message="Missing input file",
            )
            return

        try:
            _set_phase(job_id, "transcribing", progress=0.4)
            result = transcribe_file(
                api_key=api_key,
                audio_path=Path(input_path_value),
                model=params.get("model") or DEFAULT_STT_MODEL,
                language_hints=params.get("language_hints"),
                context=params.get("context"),
            )
            _set_phase(job_id, "saving", progress=0.8)
            output_file = result_path(job_id, "transcript.srt")
            output_file.write_text(result.srt_text, encoding="utf-8")
            _set_phase(
                job_id,
                "succeeded",
                status="succeeded",
                progress=1.0,
                output_kind="transcript",
                output_mime="application/x-subrip",
                output_size=output_file.stat().st_size,
                output_text=result.transcript_text,
                result_path=str(output_file),
            )
            db.update_job(job_id, input_text=None)
        except Exception as exc:
            logger.error("STT job failed: %s", exc)
            _set_phase(
                job_id,
                "failed",
                status="failed",
                progress=1.0,
                error_code="PROCESSING_FAILED",
                error_message=str(exc),
            )
        return

    if job_type == "tts":
        _set_phase(
            job_id,
            "failed",
            status="failed",
            progress=1.0,
            error_code="PROCESSING_FAILED",
            error_message="TTS provider not configured",
        )
        return

    if job_type == "ai":
        api_key = os.environ.get("VERCEL_AI_GATEWAY_API_KEY")
        openrouter_api_key = os.environ.get("OPENROUTER_API_KEY")
        if not api_key and not openrouter_api_key:
            _set_phase(
                job_id,
                "failed",
                status="failed",
                progress=1.0,
                error_code="PROCESSING_FAILED",
                error_message="No AI API keys configured",
            )
            return

        prompt = job.get("input_text") or ""
        messages = list(params.get("messages") or [])
        if not messages:
            if not prompt.strip():
                _set_phase(
                    job_id,
                    "failed",
                    status="failed",
                    progress=1.0,
                    error_code="PROCESSING_FAILED",
                    error_message="Missing input text",
                )
                return
            messages = [{"role": "user", "content": prompt}]
        elif prompt.strip():
            messages.append({"role": "user", "content": prompt})

        if not messages:
            _set_phase(
                job_id,
                "failed",
                status="failed",
                progress=1.0,
                error_code="PROCESSING_FAILED",
                error_message="Missing messages",
            )
            return

        try:
            _set_phase(job_id, "generating", progress=0.4)
            result = _try_generate_text(
                messages=messages,
                model=params.get("model") or DEFAULT_AI_MODEL,
                system_prompt=params.get("system_prompt"),
                temperature=params.get("temperature", 0.7),
                max_tokens=params.get("max_tokens"),
                top_p=params.get("top_p"),
                presence_penalty=params.get("presence_penalty"),
                frequency_penalty=params.get("frequency_penalty"),
                stop=params.get("stop"),
                seed=params.get("seed"),
                response_format=params.get("response_format"),
                user=params.get("user"),
                extra=params.get("extra"),
            )
            _set_phase(job_id, "saving", progress=0.8)
            output_file = result_path(job_id, "output.json")
            output_file.write_text(json.dumps(result.raw, ensure_ascii=False), encoding="utf-8")
            _set_phase(
                job_id,
                "succeeded",
                status="succeeded",
                progress=1.0,
                output_kind="text",
                output_mime="application/json",
                output_size=output_file.stat().st_size,
                output_text=result.text,
                result_path=str(output_file),
            )
        except Exception as exc:
            logger.error("AI job failed: %s", exc)
            _set_phase(
                job_id,
                "failed",
                status="failed",
                progress=1.0,
                error_code="PROCESSING_FAILED",
                error_message=str(exc),
            )
        return

    _set_phase(
        job_id,
        "failed",
        status="failed",
        progress=1.0,
        error_code="PROCESSING_FAILED",
        error_message="Unknown job type",
    )
