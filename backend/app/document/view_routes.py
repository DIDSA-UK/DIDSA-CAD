"""Live sessions: the presenter mints and revokes read-only view tokens; an observer asks what revision it should be showing
(docs/live-sessions-scope.md, section 5; `app.view_tokens`). Included by `router.py`, so these sit under `/document` with
`bind_session_id`: a mint and a revoke act on the caller's own document session (they need the API key: `app.auth.verify_access`
refuses a token on any route but the two allowlisted GETs), and `view-state` reads the session the token is bound to."""

from fastapi import APIRouter, HTTPException, Request, Response
from pydantic import BaseModel, Field

from app import view_tokens
from app.document import revision
from app.document.store import get_document
from app.session_context import get_current_session_id

router = APIRouter()


class ViewTokenRequest(BaseModel):
    root_part_id: str
    ttl_s: int | None = Field(default=None, ge=view_tokens.MIN_TTL_S, le=view_tokens.MAX_TTL_S)


class ViewTokenResponse(BaseModel):
    token: str
    root_part_id: str
    expires_at: float
    rev: int


class ViewStateResponse(BaseModel):
    rev: int
    root_part_id: str
    expires_at: float


@router.post("/view-tokens", response_model=ViewTokenResponse, status_code=201)
def mint_view_token(payload: ViewTokenRequest) -> ViewTokenResponse:
    """A token that lets an observer GET this session's `assembly-mesh.glb` (any Part in it) and `view-state`, nothing else.
    At most four live per session (a fifth revokes the oldest); 12 h at most."""
    if payload.root_part_id not in get_document().parts:
        raise HTTPException(status_code=404, detail="Part not found")
    session_id = get_current_session_id()
    record = view_tokens.mint(session_id, payload.root_part_id, payload.ttl_s)
    return ViewTokenResponse(
        token=record.token, root_part_id=record.root_part_id, expires_at=record.expires_at, rev=revision.current(session_id)
    )


@router.delete("/view-tokens/{token}", status_code=204)
def revoke_view_token(token: str) -> Response:
    """Ends a token this session minted (Host Session's End). 404 for a token that is unknown or another session's."""
    if not view_tokens.revoke(token, get_current_session_id()):
        raise HTTPException(status_code=404, detail="View token not found")
    return Response(status_code=204)


@router.get("/view-state", response_model=ViewStateResponse)
def view_state(request: Request) -> ViewStateResponse:
    """For an observer (a view token): the presenter's current document revision and the root it is showing. With the API key it
    answers for the caller's own session, which needs a token to name the root, so it is 404 there."""
    record = getattr(request.state, "view_token", None)
    if record is None:
        raise HTTPException(status_code=404, detail="view-state is for a view token")
    return ViewStateResponse(
        rev=revision.current(get_current_session_id()), root_part_id=record.root_part_id, expires_at=record.expires_at
    )
