import uuid

from fastapi import APIRouter, HTTPException

from app.sketch.models import Line
from app.sketch.schemas import LineCreate, LineResponse, LineUpdate

router = APIRouter(prefix="/sketch/lines", tags=["sketch"])

# Temporary in-memory store, Stage 1 only. Per the project brief (Section 6)
# the server is meant to be stateless long-term - the client will hold the
# authoritative model. This dict exists only so a line can be created and
# then read/updated within a session (e.g. a curl/test session), and will
# be superseded by the Stage 2 dependency graph.
_lines: dict[str, Line] = {}


def _to_response(line: Line) -> LineResponse:
    return LineResponse(
        id=line.id,
        start={"x": line.start[0], "y": line.start[1]},
        end={"x": line.end[0], "y": line.end[1]},
        length=line.length,
    )


def _get_or_404(line_id: str) -> Line:
    line = _lines.get(line_id)
    if line is None:
        raise HTTPException(status_code=404, detail="Line not found")
    return line


@router.post("", response_model=LineResponse, status_code=201)
def create_line(payload: LineCreate) -> LineResponse:
    line_id = str(uuid.uuid4())
    start = (payload.start.x, payload.start.y)
    if payload.end is not None:
        line = Line(id=line_id, start=start, end=(payload.end.x, payload.end.y))
    else:
        line = Line.from_length_angle(line_id, start, payload.length, payload.angle)
    _lines[line_id] = line
    return _to_response(line)


@router.get("/{line_id}", response_model=LineResponse)
def get_line(line_id: str) -> LineResponse:
    return _to_response(_get_or_404(line_id))


@router.patch("/{line_id}", response_model=LineResponse)
def update_line(line_id: str, payload: LineUpdate) -> LineResponse:
    line = _get_or_404(line_id)
    if payload.length is not None:
        try:
            line.set_length(payload.length)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
    else:
        line.set_endpoints((payload.start.x, payload.start.y), (payload.end.x, payload.end.y))
    return _to_response(line)
