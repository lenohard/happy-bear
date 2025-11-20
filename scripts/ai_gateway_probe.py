#!/usr/bin/env python3
"""Utility helpers for exploring the AI Gateway OpenAI-compatible + billing APIs.

Usage examples:
  VERCEL_AI_GATEWAY_API_KEY=sk-... python scripts/ai_gateway_probe.py models
  python scripts/ai_gateway_probe.py chat --model gpt-4o-mini --prompt "Hello"
  python scripts/ai_gateway_probe.py generation --id gen_01AR...
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any, Dict

import requests


BASE_URL = "https://ai-gateway.vercel.sh/v1"


def _require_api_key() -> str:
    key = os.getenv("VERCEL_AI_GATEWAY_API_KEY")
    if not key:
        raise SystemExit(
            "Set VERCEL_AI_GATEWAY_API_KEY before calling the AI Gateway probes."
        )
    return key


def _request(
    method: str,
    path: str,
    *,
    params: Dict[str, Any] | None = None,
    json_body: Dict[str, Any] | None = None,
) -> Dict[str, Any]:
    key = _require_api_key()
    url = f"{BASE_URL}{path}"
    resp = requests.request(
        method,
        url,
        params=params,
        json=json_body,
        headers={
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
        },
        timeout=60,
    )
    try:
        resp.raise_for_status()
    except requests.HTTPError as exc:
        detail = resp.text.strip()
        raise SystemExit(f"HTTP {resp.status_code} for {url}: {detail}") from exc
    return resp.json()


def cmd_models(_: argparse.Namespace) -> None:
    payload = _request("GET", "/models")
    print(json.dumps(payload, indent=2, sort_keys=True))


def cmd_model(args: argparse.Namespace) -> None:
    payload = _request("GET", f"/models/{args.model}")
    print(json.dumps(payload, indent=2, sort_keys=True))


def cmd_chat(args: argparse.Namespace) -> None:
    body = {
        "model": args.model,
        "messages": [
            {"role": "system", "content": args.system_prompt},
            {"role": "user", "content": args.prompt},
        ],
        "max_tokens": args.max_tokens,
        "temperature": args.temperature,
        "stream": False,
    }
    payload = _request("POST", "/chat/completions", json_body=body)
    print(json.dumps(payload, indent=2, sort_keys=True))


def cmd_credits(_: argparse.Namespace) -> None:
    payload = _request("GET", "/credits")
    print(json.dumps(payload, indent=2, sort_keys=True))


def cmd_generation(args: argparse.Namespace) -> None:
    payload = _request("GET", "/generation", params={"id": args.id})
    print(json.dumps(payload, indent=2, sort_keys=True))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="AI Gateway probe helpers")
    sub = parser.add_subparsers(dest="command", required=True)

    sub_models = sub.add_parser("models", help="List available models")
    sub_models.set_defaults(func=cmd_models)

    sub_model = sub.add_parser("model", help="Fetch details for a single model")
    sub_model.add_argument("model", help="Model identifier (e.g. gpt-4o-mini)")
    sub_model.set_defaults(func=cmd_model)

    sub_chat = sub.add_parser("chat", help="Send a prompt to /chat/completions")
    sub_chat.add_argument("--model", default="gpt-4o-mini", help="Model name")
    sub_chat.add_argument("--prompt", required=True, help="User message content")
    sub_chat.add_argument(
        "--system-prompt",
        default="You are AudiobookPlayer's AI assistant.",
        help="System prompt text",
    )
    sub_chat.add_argument("--max-tokens", type=int, default=256)
    sub_chat.add_argument("--temperature", type=float, default=0.2)
    sub_chat.set_defaults(func=cmd_chat)

    sub_credits = sub.add_parser("credits", help="Inspect credit balance")
    sub_credits.set_defaults(func=cmd_credits)

    sub_generation = sub.add_parser(
        "generation", help="Lookup usage details for a generation id"
    )
    sub_generation.add_argument("--id", required=True, help="gen_* identifier")
    sub_generation.set_defaults(func=cmd_generation)

    return parser


def main(argv: list[str] | None = None) -> None:
    parser = build_parser()
    args = parser.parse_args(argv)
    args.func(args)


if __name__ == "__main__":
    main(sys.argv[1:])
