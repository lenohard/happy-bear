from __future__ import annotations

from typing import Any, Literal, Optional
from pydantic import BaseModel, Field


JobType = Literal["stt", "tts", "ai"]
JobStatus = Literal["queued", "running", "succeeded", "failed", "canceled"]
InputKind = Literal["upload", "text", "url"]
InputSource = Literal["baidu", "rss", "external"]


class ErrorPayload(BaseModel):
    code: str
    message: str
    details: Optional[dict[str, Any]] = None


class InputPayload(BaseModel):
    kind: InputKind
    text: Optional[str] = None
    mime: Optional[str] = None
    url: Optional[str] = None
    source: Optional[InputSource] = None
    cookie: Optional[str] = Field(default=None, exclude=True)


class JobParams(BaseModel):
    language: Optional[str] = None
    language_hints: Optional[list[str]] = None
    model: Optional[str] = None
    voice: Optional[str] = None
    format: Optional[str] = None
    context: Optional[str] = None
    system_prompt: Optional[str] = None
    temperature: Optional[float] = None
    messages: Optional[list[dict[str, Any]]] = None
    max_tokens: Optional[int] = None
    top_p: Optional[float] = None
    presence_penalty: Optional[float] = None
    frequency_penalty: Optional[float] = None
    stop: Optional[str | list[str]] = None
    seed: Optional[int] = None
    response_format: Optional[dict[str, Any]] = None
    user: Optional[str] = None
    extra: Optional[dict[str, Any]] = None


class CreateJobRequest(BaseModel):
    type: JobType
    input: InputPayload
    params: Optional[JobParams] = None


class JobOutput(BaseModel):
    kind: Optional[str] = None
    mime: Optional[str] = None
    size: Optional[int] = None


class JobResponse(BaseModel):
    id: str
    type: JobType
    status: JobStatus
    progress: float
    phase: Optional[str] = None
    created_at: str
    updated_at: str
    error: Optional[ErrorPayload] = None
    input: Optional[InputPayload] = None
    output: Optional[JobOutput] = None


class CreateJobResponse(BaseModel):
    job: JobResponse
    upload: Optional[dict[str, str]] = None


class JobResultResponse(BaseModel):
    result: dict[str, Any]
