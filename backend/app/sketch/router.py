import uuid

from fastapi import APIRouter, HTTPException

from app.sketch.models import Line, Point, Sketch
from app.sketch.profile import Profile, detect_profile
from app.sketch.schemas import (
    LineCreate,
    LineResponse,
    LineUpdate,
    PointCreate,
    PointResponse,
    PointUpdate,
    ProfileDetectionResponse,
    ProfileResponse,
    SketchCreate,
    SketchResponse,
)

router = APIRouter(prefix="/sketch", tags=["sketch"])

# Temporary in-memory store, Stage 2 only. Per the project brief (Section 6)
# the server is meant to be stateless long-term - the client will hold the
# authoritative model. This dict exists only so sketches can be created and
# then read/updated within a session (e.g. a curl/test session), and will
# be superseded by the dependency graph.
_sketches: dict[str, Sketch] = {}


def _get_sketch_or_404(sketch_id: str) -> Sketch:
    sketch = _sketches.get(sketch_id)
    if sketch is None:
        raise HTTPException(status_code=404, detail="Sketch not found")
    return sketch


def _get_point_or_404(sketch: Sketch, point_id: str) -> Point:
    point = sketch.points.get(point_id)
    if point is None:
        raise HTTPException(status_code=404, detail="Point not found")
    return point


def _get_line_or_404(sketch: Sketch, line_id: str) -> Line:
    entity = sketch.entities.get(line_id)
    if not isinstance(entity, Line):
        raise HTTPException(status_code=404, detail="Line not found")
    return entity


def _point_response(point: Point) -> PointResponse:
    return PointResponse(id=point.id, x=point.x, y=point.y)


def _line_response(sketch: Sketch, line: Line) -> LineResponse:
    return LineResponse(
        id=line.id,
        start_point_id=line.start_point_id,
        end_point_id=line.end_point_id,
        length=line.length(sketch.points),
    )


def _profile_response(profile: Profile) -> ProfileResponse:
    return ProfileResponse(point_ids=profile.point_ids, line_ids=profile.line_ids)


@router.post("/sketches", response_model=SketchResponse, status_code=201)
def create_sketch(payload: SketchCreate) -> SketchResponse:
    sketch = Sketch(id=str(uuid.uuid4()), plane=payload.plane)
    _sketches[sketch.id] = sketch
    return SketchResponse(id=sketch.id, plane=sketch.plane)


@router.get("/sketches/{sketch_id}", response_model=SketchResponse)
def get_sketch(sketch_id: str) -> SketchResponse:
    sketch = _get_sketch_or_404(sketch_id)
    return SketchResponse(id=sketch.id, plane=sketch.plane)


@router.post("/sketches/{sketch_id}/points", response_model=PointResponse, status_code=201)
def create_point(sketch_id: str, payload: PointCreate) -> PointResponse:
    sketch = _get_sketch_or_404(sketch_id)
    point = sketch.add_point(payload.x, payload.y)
    return _point_response(point)


@router.get("/sketches/{sketch_id}/points/{point_id}", response_model=PointResponse)
def get_point(sketch_id: str, point_id: str) -> PointResponse:
    sketch = _get_sketch_or_404(sketch_id)
    return _point_response(_get_point_or_404(sketch, point_id))


@router.patch("/sketches/{sketch_id}/points/{point_id}", response_model=PointResponse)
def update_point(sketch_id: str, point_id: str, payload: PointUpdate) -> PointResponse:
    sketch = _get_sketch_or_404(sketch_id)
    point = _get_point_or_404(sketch, point_id)
    point.x = payload.x
    point.y = payload.y
    return _point_response(point)


@router.post("/sketches/{sketch_id}/lines", response_model=LineResponse, status_code=201)
def create_line(sketch_id: str, payload: LineCreate) -> LineResponse:
    sketch = _get_sketch_or_404(sketch_id)
    try:
        line = sketch.add_line(
            payload.start_point_id,
            payload.end_point_id,
            length=payload.length,
            angle=payload.angle,
        )
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=f"Point not found: {exc}") from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return _line_response(sketch, line)


@router.get("/sketches/{sketch_id}/lines/{line_id}", response_model=LineResponse)
def get_line(sketch_id: str, line_id: str) -> LineResponse:
    sketch = _get_sketch_or_404(sketch_id)
    return _line_response(sketch, _get_line_or_404(sketch, line_id))


@router.patch("/sketches/{sketch_id}/lines/{line_id}", response_model=LineResponse)
def update_line(sketch_id: str, line_id: str, payload: LineUpdate) -> LineResponse:
    sketch = _get_sketch_or_404(sketch_id)
    line = _get_line_or_404(sketch, line_id)
    try:
        line.set_length(sketch.points, payload.length)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return _line_response(sketch, line)


@router.get("/sketches/{sketch_id}/profile", response_model=ProfileDetectionResponse)
def get_profile(sketch_id: str) -> ProfileDetectionResponse:
    sketch = _get_sketch_or_404(sketch_id)
    result = detect_profile(sketch)
    return ProfileDetectionResponse(
        status=result.status,
        detail=result.detail,
        profile=_profile_response(result.profile) if result.profile else None,
        branch_point_ids=result.branch_point_ids,
        loops=[_profile_response(loop) for loop in result.loops],
    )
