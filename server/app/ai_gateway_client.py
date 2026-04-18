from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import Any

import requests

logger = logging.getLogger("app.ai_gateway")


AI_GATEWAY_BASE_URL = "https://ai-gateway.vercel.sh/v1"
OPENROUTER_BASE_URL = "https://openrouter.ai/api/v1"
DEFAULT_MODEL = "openai/gpt-4o-mini"
DEFAULT_SYSTEM_PROMPT = "You are a helpful assistant."


@dataclass(frozen=True)
class AIGatewayResult:
    text: str
    raw: dict[str, Any]


def _do_request(
    base_url: str,
    api_key: str,
    messages: list[dict[str, Any]],
    model: str | None = None,
    system_prompt: str | None = None,
    temperature: float = 0.7,
    max_tokens: int | None = None,
    top_p: float | None = None,
    presence_penalty: float | None = None,
    frequency_penalty: float | None = None,
    stop: str | list[str] | None = None,
    seed: int | None = None,
    response_format: dict[str, Any] | None = None,
    user: str | None = None,
    extra: dict[str, Any] | None = None,
) -> AIGatewayResult:
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
    }
    final_messages = list(messages)
    if system_prompt:
        has_system = any(message.get("role") == "system" for message in final_messages)
        if not has_system:
            final_messages.insert(0, {"role": "system", "content": system_prompt})
    payload = {
        "model": model or DEFAULT_MODEL,
        "messages": final_messages or [
            {"role": "system", "content": system_prompt or DEFAULT_SYSTEM_PROMPT},
            {"role": "user", "content": ""},
        ],
        "stream": False,
    }
    if temperature is not None:
        payload["temperature"] = temperature
    if max_tokens is not None:
        payload["max_tokens"] = max_tokens
    if top_p is not None:
        payload["top_p"] = top_p
    if presence_penalty is not None:
        payload["presence_penalty"] = presence_penalty
    if frequency_penalty is not None:
        payload["frequency_penalty"] = frequency_penalty
    if stop is not None:
        payload["stop"] = stop
    if seed is not None:
        payload["seed"] = seed
    if response_format is not None:
        payload["response_format"] = response_format
    if user is not None:
        payload["user"] = user
    if extra:
        payload.update(extra)
    payload["stream"] = False

    session = requests.Session()
    session.headers.update(headers)
    # trust_env=True (default) picks up HTTP_PROXY/HTTPS_PROXY from environment
    response = session.post(f"{base_url}/chat/completions", json=payload, timeout=60)
    if response.status_code != 200:
        logger.error(
            "AI request failed: %s %s body=%s", response.status_code, response.url, response.text[:500]
        )
    response.raise_for_status()
    data = response.json()

    choices = data.get("choices") or []
    if not choices:
        raise RuntimeError("AI response missing choices")

    message = choices[0].get("message") or {}
    content = message.get("content")
    if not content:
        raise RuntimeError("AI response missing content")

    return AIGatewayResult(text=content, raw=data)


def generate_text(
    api_key: str,
    messages: list[dict[str, Any]],
    model: str | None = None,
    system_prompt: str | None = None,
    temperature: float = 0.7,
    max_tokens: int | None = None,
    top_p: float | None = None,
    presence_penalty: float | None = None,
    frequency_penalty: float | None = None,
    stop: str | list[str] | None = None,
    seed: int | None = None,
    response_format: dict[str, Any] | None = None,
    user: str | None = None,
    extra: dict[str, Any] | None = None,
) -> AIGatewayResult:
    return _do_request(
        base_url=AI_GATEWAY_BASE_URL,
        api_key=api_key,
        messages=messages,
        model=model,
        system_prompt=system_prompt,
        temperature=temperature,
        max_tokens=max_tokens,
        top_p=top_p,
        presence_penalty=presence_penalty,
        frequency_penalty=frequency_penalty,
        stop=stop,
        seed=seed,
        response_format=response_format,
        user=user,
        extra=extra,
    )


def generate_text_openrouter(
    api_key: str,
    messages: list[dict[str, Any]],
    model: str | None = None,
    system_prompt: str | None = None,
    temperature: float = 0.7,
    max_tokens: int | None = None,
    top_p: float | None = None,
    presence_penalty: float | None = None,
    frequency_penalty: float | None = None,
    stop: str | list[str] | None = None,
    seed: int | None = None,
    response_format: dict[str, Any] | None = None,
    user: str | None = None,
    extra: dict[str, Any] | None = None,
) -> AIGatewayResult:
    return _do_request(
        base_url=OPENROUTER_BASE_URL,
        api_key=api_key,
        messages=messages,
        model=model,
        system_prompt=system_prompt,
        temperature=temperature,
        max_tokens=max_tokens,
        top_p=top_p,
        presence_penalty=presence_penalty,
        frequency_penalty=frequency_penalty,
        stop=stop,
        seed=seed,
        response_format=response_format,
        user=user,
        extra=extra,
    )
