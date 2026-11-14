"""The HTTP surface (docs/shared-storage-scope.md section 5). Thin on purpose: headers and bodies in, `Store` calls, status codes out.

Status codes: 200 / 201 success; 400 a refused path, header, cursor or body; 401 no / wrong key; 404 no such project, file, version
or kept bytes; 409 a name taken or a path that would be both file and folder, or a commit that clashed (the body lists every clash,
nothing was written); 412 a single write whose If-Match / If-None-Match did not hold (nothing written; the body says what is
current); 413 a body over the size limit; 422 a body that is not the JSON shape asked for; 428 a write with neither header.
"""

import hashlib
import os
from typing import Annotated

from fastapi import Depends, FastAPI, Header, Query, Request
from fastapi.concurrency import run_in_threadpool
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic import BaseModel

from app.auth import make_verifier
from app.store import MAX_CHUNK_BYTES, BadRequest, Expect, PreconditionRequired, Staged, Store, StoreError, TooLarge

APP_VERSION = "0.1.0"

# What this service can do, for a client that must know before it relies on it (the same idea as the backend's api_features).
API_FEATURES = ["files.if_match", "commit.all_or_nothing", "uploads", "versions.history", "changes.cursor", "parts.index", "uploads.chunked"]

_CHUNK = 1024 * 1024


class NewProject(BaseModel):
    name: str


class NewUploadSession(BaseModel):
    size: int
    sha256: str


class Commit(BaseModel):
    message: str | None = None
    changes: list[dict]


def _etag(version: int) -> str:
    return f'"{version}"'


def _parse_preconditions(if_match: str | None, if_none_match: str | None) -> Expect:
    if if_match is None and if_none_match is None:
        raise PreconditionRequired(
            "send If-Match: \"<version>\" to replace that version, or If-None-Match: * to create (a write must say what it replaces)"
        )
    if if_match is not None and if_none_match is not None:
        raise BadRequest("send If-Match or If-None-Match, not both")
    if if_none_match is not None:
        if if_none_match.strip() != "*":
            raise BadRequest("If-None-Match must be *")
        return Expect(create=True)
    value = if_match.strip()
    if value.startswith("W/") or value == "*":
        raise BadRequest('If-Match must be one version, quoted: "3"')
    value = value.strip('"')
    if not value.isdigit() or int(value) < 1:
        raise BadRequest('If-Match must be one version, quoted: "3"')
    return Expect(version=int(value))


def _device(x_device_name: str | None) -> str:
    return x_device_name or ""


async def _stream_to_tmp(request: Request, store: Store, limit: int | None = None) -> tuple[str, str, int]:
    """Stream the request body to a staging file, hashing as it goes. 413 past the limit (the partial file is removed)."""
    limit = store.max_file_bytes if limit is None else limit
    declared = request.headers.get("content-length")
    if declared and declared.isdigit() and int(declared) > limit:
        raise TooLarge(f"a request body may be at most {limit} bytes")
    path = store.new_tmp_path()
    digest = hashlib.sha256()
    size = 0
    try:
        with open(path, "wb") as out:
            async for chunk in request.stream():
                size += len(chunk)
                if size > limit:
                    raise TooLarge(f"a request body may be at most {limit} bytes")
                digest.update(chunk)
                out.write(chunk)
    except BaseException:
        try:
            os.unlink(path)
        except OSError:
            pass
        raise
    return path, digest.hexdigest(), size


def _file_response(info: dict, handle, name: str) -> StreamingResponse:
    def iterate():
        with handle:
            while chunk := handle.read(_CHUNK):
                yield chunk

    return StreamingResponse(
        iterate(),
        media_type="application/octet-stream",
        headers={
            "ETag": _etag(info["version"]),
            "X-Sha256": info["sha256"],
            "Content-Length": str(info["size"]),
            "Content-Disposition": 'attachment; filename="' + name.replace('"', "") + '"',
        },
    )


def create_app(store: Store, api_key: str) -> FastAPI:
    # Applied app-wide so every route (/health too) needs the key; see app/auth.py. /docs and /openapi.json are wired up
    # outside the dependency system and stay reachable (schema only, no data), as they do on the backend.
    app = FastAPI(dependencies=[Depends(make_verifier(api_key))], title="DIDSA project store", version=APP_VERSION)
    app.state.store = store

    @app.exception_handler(StoreError)
    async def _store_error(_request: Request, error: StoreError) -> JSONResponse:
        body = {"error": error.code, "detail": error.detail, **error.extra}
        headers = {}
        current = error.extra.get("current")
        if error.status == 412 and isinstance(current, dict) and not current.get("deleted"):
            headers["ETag"] = _etag(current["version"])
        return JSONResponse(body, status_code=error.status, headers=headers)

    @app.exception_handler(RequestValidationError)
    async def _validation(_request: Request, error: RequestValidationError) -> JSONResponse:
        return JSONResponse({"error": "invalid_body", "detail": "the request body is not the shape this endpoint takes"}, status_code=422)

    DeviceHeader = Annotated[str | None, Header(alias="X-Device-Name")]

    @app.get("/health")
    def health() -> dict:
        return {"status": "ok", "api_features": API_FEATURES, "version": APP_VERSION}

    @app.get("/projects")
    def list_projects() -> dict:
        return {"projects": store.list_projects()}

    @app.post("/projects", status_code=201)
    def create_project(body: NewProject, device: DeviceHeader = None) -> dict:
        return store.create_project(body.name, _device(device))

    @app.get("/projects/{project}/tree")
    def tree(project: str) -> dict:
        return store.tree(project)

    @app.get("/projects/{project}/changes")
    def changes(project: str, since: str | None = None, limit: Annotated[int, Query(ge=1, le=5000)] = 1000) -> dict:
        return store.changes(project, since, limit)

    @app.get("/projects/{project}/parts/{part_id}")
    def parts(project: str, part_id: str) -> dict:
        return store.parts(project, part_id)

    @app.post("/projects/{project}/commit")
    def commit(project: str, body: Commit, device: DeviceHeader = None) -> dict:
        return store.commit(project, body.changes, body.message, _device(device))

    @app.post("/projects/{project}/uploads", status_code=201)
    async def upload(project: str, request: Request) -> dict:
        await run_in_threadpool(store.tree, project)  # 404 for an unknown project before any body is read
        path, sha, size = await _stream_to_tmp(request, store)
        staged = await run_in_threadpool(store.make_staged, path, sha, size, None)
        try:
            return await run_in_threadpool(store.add_upload, project, staged)
        except BaseException:
            store.discard(staged)
            raise

    # Chunked uploads (S4): a file too big for one request (a Cloudflare tunnel refuses a body over 100 MB).
    @app.post("/projects/{project}/uploads/sessions", status_code=201)
    def start_upload_session(project: str, body: NewUploadSession) -> dict:
        return store.start_upload_session(project, body.size, body.sha256)

    @app.get("/projects/{project}/uploads/{upload_id}")
    def upload_status(project: str, upload_id: str) -> dict:
        return store.upload_status(project, upload_id)

    @app.put("/projects/{project}/uploads/{upload_id}")
    async def upload_chunk(project: str, upload_id: str, request: Request, offset: Annotated[int, Query(ge=0)]) -> dict:
        await run_in_threadpool(store.upload_status, project, upload_id)  # 404 before any body is read
        path, sha, size = await _stream_to_tmp(request, store, MAX_CHUNK_BYTES)
        staged = await run_in_threadpool(store.make_staged, path, sha, size, "chunk")
        return await run_in_threadpool(store.add_chunk, project, upload_id, offset, staged)

    @app.post("/projects/{project}/uploads/{upload_id}/complete")
    def complete_upload(project: str, upload_id: str) -> dict:
        return store.complete_upload(project, upload_id)

    @app.delete("/projects/{project}/uploads/{upload_id}")
    def cancel_upload(project: str, upload_id: str) -> dict:
        store.cancel_upload(project, upload_id)
        return {"cancelled": True}

    # The history routes are declared before the file routes; paths that could be mistaken for them are refused (app/paths.py).
    @app.get("/projects/{project}/files/{path:path}/versions/{version:int}")
    def get_version(project: str, path: str, version: int):
        info, handle = store.open_version(project, path, version)
        return _file_response({**info}, handle, os.path.basename(path))

    @app.get("/projects/{project}/files/{path:path}/versions")
    def list_versions(project: str, path: str) -> dict:
        return store.versions(project, path)

    @app.get("/projects/{project}/files/{path:path}")
    def get_file(project: str, path: str):
        info, handle = store.open_current(project, path)
        return _file_response(info, handle, os.path.basename(path))

    @app.put("/projects/{project}/files/{path:path}")
    async def put_file(
        project: str,
        path: str,
        request: Request,
        if_match: Annotated[str | None, Header()] = None,
        if_none_match: Annotated[str | None, Header()] = None,
        device: DeviceHeader = None,
    ):
        expect = _parse_preconditions(if_match, if_none_match)
        # Refuse a stale write before its body is read (the same checks are made again under the store's lock).
        await run_in_threadpool(store.check_expectation, project, path, expect)
        tmp, sha, size = await _stream_to_tmp(request, store)
        staged: Staged = await run_in_threadpool(store.make_staged, tmp, sha, size, path)
        info, created = await run_in_threadpool(store.put, project, path, staged, expect, _device(device))
        return JSONResponse(
            info, status_code=201 if created else 200, headers={"ETag": _etag(info["version"])}
        )

    @app.delete("/projects/{project}/files/{path:path}")
    def delete_file(
        project: str,
        path: str,
        if_match: Annotated[str | None, Header()] = None,
        device: DeviceHeader = None,
    ):
        expect = _parse_preconditions(if_match, None)
        if expect.create:
            raise BadRequest("a delete takes If-Match only")
        info = store.delete(project, path, expect, _device(device))
        return JSONResponse(info, headers={"ETag": _etag(info["version"])})

    return app
