from __future__ import annotations

from typing import Annotated

from fastapi import Depends, HTTPException, Request, status

from .config import load_settings


def require_auth(request: Request) -> None:
    settings = load_settings()
    auth_header = request.headers.get("Authorization", "")
    if not auth_header.startswith("Bearer "):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail={"code": "AUTH_INVALID", "message": "Missing bearer token"},
        )

    token = auth_header.removeprefix("Bearer ").strip()
    if token != settings.token:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail={"code": "AUTH_INVALID", "message": "Invalid token"},
        )


AuthDep = Annotated[None, Depends(require_auth)]
