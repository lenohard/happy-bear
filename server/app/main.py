from __future__ import annotations

from datetime import datetime, timezone
import json
from pathlib import Path
import uuid

from fastapi import BackgroundTasks, FastAPI, File, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse, JSONResponse
from fastapi.exceptions import RequestValidationError

from .auth import AuthDep
from . import db
from .models import CreateJobRequest, JobResponse
from .storage import input_path, delete_job_files
from .workers import run_job

app = FastAPI(title="Audiobook Remote Jobs", version="0.1.0")


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _job_to_response(job: dict) -> JobResponse:
    error = None
    if job.get("error_code") or job.get("error_message"):
        error = {"code": job.get("error_code"), "message": job.get("error_message")}

    input_payload = None
    if job.get("input_kind"):
        input_payload = {
            "kind": job.get("input_kind"),
            "text": job.get("input_text"),
            "mime": job.get("input_mime"),
            "url": job.get("input_url"),
            "source": job.get("input_source"),
        }

    output_payload = None
    if job.get("output_kind"):
        output_payload = {
            "kind": job.get("output_kind"),
            "mime": job.get("output_mime"),
            "size": job.get("output_size"),
        }

    return JobResponse(
        id=job["id"],
        type=job["type"],
        status=job["status"],
        progress=job["progress"],
        phase=job.get("phase"),
        created_at=job["created_at"],
        updated_at=job["updated_at"],
        error=error,
        input=input_payload,
        output=output_payload,
    )


@app.exception_handler(HTTPException)
def handle_http_exception(_: Request, exc: HTTPException) -> JSONResponse:
    detail = exc.detail
    if isinstance(detail, dict) and "code" in detail:
        payload = detail
    else:
        payload = {"code": "REQUEST_FAILED", "message": str(detail)}
    return JSONResponse(status_code=exc.status_code, content={"error": payload})


@app.exception_handler(RequestValidationError)
def handle_validation_error(_: Request, exc: RequestValidationError) -> JSONResponse:
    return JSONResponse(
        status_code=422,
        content={"error": {"code": "VALIDATION_ERROR", "message": "Invalid request", "details": exc.errors()}},
    )


@app.on_event("startup")
def on_startup() -> None:
    db.init_db()


@app.post("/v1/jobs")
async def create_job(
    request: CreateJobRequest,
    background_tasks: BackgroundTasks,
    _: AuthDep,
) -> dict:
    if request.input.kind == "upload" and request.input.text:
        raise HTTPException(
            status_code=400,
            detail={"code": "JOB_INVALID_STATE", "message": "Upload input cannot include text"},
        )

    if request.input.kind == "text" and not request.input.text and not (request.params and request.params.messages):
        raise HTTPException(
            status_code=400,
            detail={"code": "JOB_INVALID_STATE", "message": "Text input requires text content"},
        )

    if request.input.kind in {"upload", "text"} and (request.input.url or request.input.cookie or request.input.source):
        raise HTTPException(
            status_code=400,
            detail={"code": "JOB_INVALID_STATE", "message": "URL/source/cookie only allowed for url input"},
        )

    if request.input.kind == "url":
        if not request.input.url or not request.input.source:
            raise HTTPException(
                status_code=400,
                detail={"code": "JOB_INVALID_STATE", "message": "URL input requires url and source"},
            )
        if request.input.text:
            raise HTTPException(
                status_code=400,
                detail={"code": "JOB_INVALID_STATE", "message": "URL input cannot include text"},
            )
        if request.input.cookie and request.input.source != "baidu":
            raise HTTPException(
                status_code=400,
                detail={"code": "JOB_INVALID_STATE", "message": "Cookie only allowed for baidu source"},
            )

    if request.type == "stt" and request.input.kind not in {"upload", "url"}:
        raise HTTPException(
            status_code=400,
            detail={"code": "JOB_INVALID_STATE", "message": "STT requires upload or url input"},
        )

    if request.type in {"tts", "ai"} and request.input.kind != "text":
        raise HTTPException(
            status_code=400,
            detail={"code": "JOB_INVALID_STATE", "message": "TTS/AI require text input"},
        )

    job_id = f"job_{uuid.uuid4().hex}"
    now = _utc_now()
    params_json = json.dumps(request.params.model_dump(exclude_none=True)) if request.params else None

    job = {
        "id": job_id,
        "type": request.type,
        "status": "queued",
        "progress": 0.0,
        "phase": "queued",
        "phase_started_at": now,
        "created_at": now,
        "updated_at": now,
        "input_kind": request.input.kind,
        "input_mime": request.input.mime,
        "input_size": None,
        "input_text": request.input.text,
        "input_url": request.input.url,
        "input_source": request.input.source,
        "input_cookie": request.input.cookie,
        "input_path": None,
        "params_json": params_json,
        "output_kind": None,
        "output_mime": None,
        "output_size": None,
        "output_text": None,
        "result_path": None,
    }

    db.insert_job(job)

    upload = None
    if request.input.kind == "upload":
        upload = {"url": f"/v1/jobs/{job_id}/upload", "method": "POST"}
    else:
        background_tasks.add_task(run_job, job_id)

    return {"data": {"job": _job_to_response(job), "upload": upload}}


@app.post("/v1/jobs/{job_id}/upload")
async def upload_job_input(
    job_id: str,
    background_tasks: BackgroundTasks,
    _: AuthDep,
    file: UploadFile = File(...),
) -> dict:
    job = db.get_job(job_id)
    if not job:
        raise HTTPException(status_code=404, detail={"code": "JOB_NOT_FOUND", "message": "Job not found"})

    if job["status"] != "queued":
        raise HTTPException(
            status_code=409,
            detail={"code": "JOB_INVALID_STATE", "message": "Job not awaiting upload"},
        )
    if job.get("input_kind") != "upload":
        raise HTTPException(
            status_code=409,
            detail={"code": "JOB_INVALID_STATE", "message": "Job does not accept uploads"},
        )

    filename = file.filename or "upload"
    target_path = input_path(job_id, Path(filename).name)
    with target_path.open("wb") as handle:
        while True:
            chunk = await file.read(1024 * 1024)
            if not chunk:
                break
            handle.write(chunk)

    db.update_job(
        job_id,
        input_mime=file.content_type or job.get("input_mime") or "application/octet-stream",
        input_size=target_path.stat().st_size,
        input_path=str(target_path),
    )

    background_tasks.add_task(run_job, job_id)
    updated = db.get_job(job_id)
    return {"data": {"job": _job_to_response(updated)}}


@app.get("/v1/jobs/{job_id}")
async def get_job(job_id: str, _: AuthDep) -> dict:
    job = db.get_job(job_id)
    if not job:
        raise HTTPException(status_code=404, detail={"code": "JOB_NOT_FOUND", "message": "Job not found"})
    return {"data": {"job": _job_to_response(job)}}


@app.get("/v1/jobs")
async def list_jobs(
    _: AuthDep,
    status: str | None = None,
    type: str | None = None,
    limit: int = 50,
    cursor: str | None = None,
) -> dict:
    filters = {}
    if status:
        filters["status"] = status
    if type:
        filters["type"] = type

    jobs, next_cursor = db.list_jobs(filters, limit, cursor)
    return {
        "data": {
            "jobs": [_job_to_response(job) for job in jobs],
            "next_cursor": next_cursor,
        }
    }


@app.post("/v1/jobs/{job_id}/cancel")
async def cancel_job(job_id: str, _: AuthDep) -> dict:
    job = db.get_job(job_id)
    if not job:
        raise HTTPException(status_code=404, detail={"code": "JOB_NOT_FOUND", "message": "Job not found"})

    if job["status"] not in {"queued", "running"}:
        raise HTTPException(
            status_code=409,
            detail={"code": "JOB_INVALID_STATE", "message": "Job cannot be canceled"},
        )

    db.update_job(job_id, status="canceled", progress=1.0, phase="canceled")
    job = db.get_job(job_id)
    return {"data": {"job": _job_to_response(job)}}


@app.delete("/v1/jobs/{job_id}")
async def delete_job(job_id: str, _: AuthDep) -> dict:
    job = db.get_job(job_id)
    if not job:
        raise HTTPException(status_code=404, detail={"code": "JOB_NOT_FOUND", "message": "Job not found"})

    if job["status"] in {"queued", "running"}:
        raise HTTPException(
            status_code=409,
            detail={"code": "JOB_INVALID_STATE", "message": "Cannot delete a running job. Cancel it first."},
        )

    delete_job_files(job_id)
    db.delete_job(job_id)
    return {"data": {"deleted": True}}


@app.get("/v1/jobs/{job_id}/result")
async def get_result(job_id: str, _: AuthDep) -> dict:
    job = db.get_job(job_id)
    if not job:
        raise HTTPException(status_code=404, detail={"code": "JOB_NOT_FOUND", "message": "Job not found"})

    if job["status"] != "succeeded":
        raise HTTPException(
            status_code=409,
            detail={"code": "JOB_INVALID_STATE", "message": "Job not completed"},
        )

    result_path = job.get("result_path")
    if not result_path:
        raise HTTPException(
            status_code=500,
            detail={"code": "PROCESSING_FAILED", "message": "Missing result artifact"},
        )

    path = Path(result_path)
    if not path.exists():
        raise HTTPException(
            status_code=500,
            detail={"code": "PROCESSING_FAILED", "message": "Result file not found"},
        )

    if job["type"] == "stt":
        srt_text = path.read_text(encoding="utf-8")
        transcript_text = job.get("output_text") or ""
        result = {"format": "srt", "srt": srt_text, "transcript": transcript_text}
        return {"data": {"result": result}}

    if job["type"] == "tts":
        result = {"audio_url": f"/v1/jobs/{job_id}/result/file", "format": "mp3"}
        return {"data": {"result": result}}

    if job["type"] == "ai":
        raw_payload = None
        try:
            raw_payload = json.loads(path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            raw_payload = None
        result = {"text": job.get("output_text") or "", "raw": raw_payload}
        return {"data": {"result": result}}

    raise HTTPException(
        status_code=500,
        detail={"code": "PROCESSING_FAILED", "message": "Unknown job type"},
    )


@app.get("/v1/jobs/{job_id}/result/file")
async def get_result_file(job_id: str, _: AuthDep) -> FileResponse:
    job = db.get_job(job_id)
    if not job:
        raise HTTPException(status_code=404, detail={"code": "JOB_NOT_FOUND", "message": "Job not found"})

    if job["status"] != "succeeded":
        raise HTTPException(
            status_code=409,
            detail={"code": "JOB_INVALID_STATE", "message": "Job not completed"},
        )

    result_path = job.get("result_path")
    if not result_path:
        raise HTTPException(
            status_code=500,
            detail={"code": "PROCESSING_FAILED", "message": "Missing result artifact"},
        )

    path = Path(result_path)
    if not path.exists():
        raise HTTPException(
            status_code=500,
            detail={"code": "PROCESSING_FAILED", "message": "Result file not found"},
        )

    media_type = job.get("output_mime") or "application/octet-stream"
    return FileResponse(path, media_type=media_type, filename=path.name)
