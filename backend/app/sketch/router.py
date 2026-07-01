from fastapi import APIRouter, HTTPException

from app.sketch.constraints import (
    AngleConstraint,
    AtMidpointConstraint,
    CoincidentConstraint,
    CollinearConstraint,
    Constraint,
    DistanceConstraint,
    EqualLengthConstraint,
    HorizontalConstraint,
    LineDistanceConstraint,
    ParallelConstraint,
    PerpendicularConstraint,
    PointLineDistanceConstraint,
    VerticalConstraint,
)
from app.sketch.models import Circle, Line, Point, Sketch
from app.sketch.profile import Profile, detect_profile
from app.sketch.schemas import (
    AngleConstraintCreate,
    AngleConstraintResponse,
    AtMidpointConstraintCreate,
    AtMidpointConstraintResponse,
    CircleCreate,
    CircleResponse,
    CircleUpdate,
    CoincidentConstraintCreate,
    CoincidentConstraintResponse,
    CollinearConstraintCreate,
    CollinearConstraintResponse,
    ConstraintCreate,
    ConstraintResponse,
    ConstraintValueUpdate,
    DistanceConstraintCreate,
    DistanceConstraintResponse,
    EqualLengthConstraintCreate,
    EqualLengthConstraintResponse,
    HorizontalConstraintCreate,
    HorizontalConstraintResponse,
    LineCreate,
    LineDistanceConstraintCreate,
    LineDistanceConstraintResponse,
    LineResponse,
    LineUpdate,
    ParallelConstraintCreate,
    ParallelConstraintResponse,
    PerpendicularConstraintCreate,
    PerpendicularConstraintResponse,
    PointCreate,
    PointLineDistanceConstraintCreate,
    PointLineDistanceConstraintResponse,
    PointResponse,
    PointUpdate,
    ProfileDetectionResponse,
    ProfileResponse,
    SketchCreate,
    SketchResponse,
    SolveResultResponse,
    VerticalConstraintCreate,
    VerticalConstraintResponse,
)
from app.sketch.solver import SolveResult, solve_sketch
from app.sketch.store import create_sketch as _create_sketch
from app.sketch.store import get_sketch_or_404 as _get_sketch_or_404

router = APIRouter(prefix="/sketch", tags=["sketch"])


def _ensure_sketch_editable(sketch_id: str) -> None:
    """Stage 7's Feature-locking rule, enforced here rather than only in
    client UI: a Sketch wrapped by a SketchFeature can only be mutated while
    that Feature is the last one in its Part. Sketches not (yet) wrapped by
    any Feature - e.g. created directly via this router rather than through
    the document API - are unrestricted. Imported lazily inside the function
    (not at module level) to avoid a hard import-time dependency from this
    lower-level module onto app.document, which itself depends on this
    module's store - see app/document/store.py's is_sketch_locked.
    """
    from app.document.store import is_sketch_locked

    if is_sketch_locked(sketch_id):
        raise HTTPException(
            status_code=400,
            detail="This sketch belongs to a locked Feature - only the most recent "
            "Feature in a Part can be edited. Add a new Feature instead of editing this one.",
        )


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


def _get_circle_or_404(sketch: Sketch, circle_id: str) -> Circle:
    entity = sketch.entities.get(circle_id)
    if not isinstance(entity, Circle):
        raise HTTPException(status_code=404, detail="Circle not found")
    return entity


def _get_constraint_or_404(sketch: Sketch, constraint_id: str) -> Constraint:
    constraint = sketch.constraints.get(constraint_id)
    if constraint is None:
        raise HTTPException(status_code=404, detail="Constraint not found")
    return constraint


def _point_response(point: Point) -> PointResponse:
    return PointResponse(id=point.id, x=point.x, y=point.y)


def _line_response(sketch: Sketch, line: Line) -> LineResponse:
    return LineResponse(
        id=line.id,
        start_point_id=line.start_point_id,
        end_point_id=line.end_point_id,
        length=line.length(sketch.points),
        construction=line.construction,
    )


def _circle_response(sketch: Sketch, circle: Circle) -> CircleResponse:
    return CircleResponse(
        id=circle.id,
        center_point_id=circle.center_point_id,
        radius_point_id=circle.radius_point_id,
        radius=circle.radius(sketch.points),
        construction=circle.construction,
    )


def _profile_response(profile: Profile) -> ProfileResponse:
    return ProfileResponse(
        point_ids=profile.point_ids,
        line_ids=profile.line_ids,
        inner_loops=[_profile_response(inner) for inner in profile.inner_loops],
    )


def _constraint_response(constraint: Constraint) -> ConstraintResponse:
    if isinstance(constraint, DistanceConstraint):
        return DistanceConstraintResponse(
            id=constraint.id,
            point_a_id=constraint.point_a_id,
            point_b_id=constraint.point_b_id,
            distance=constraint.distance,
            orientation=constraint.orientation,
        )
    if isinstance(constraint, VerticalConstraint):
        return VerticalConstraintResponse(
            id=constraint.id,
            line_id=constraint.line_id,
            point_a_id=constraint.point_a_id,
            point_b_id=constraint.point_b_id,
        )
    if isinstance(constraint, HorizontalConstraint):
        return HorizontalConstraintResponse(
            id=constraint.id,
            line_id=constraint.line_id,
            point_a_id=constraint.point_a_id,
            point_b_id=constraint.point_b_id,
        )
    if isinstance(constraint, AngleConstraint):
        return AngleConstraintResponse(
            id=constraint.id,
            line1_id=constraint.line1_id,
            line2_id=constraint.line2_id,
            angle_degrees=constraint.angle_degrees,
        )
    if isinstance(constraint, CoincidentConstraint):
        return CoincidentConstraintResponse(
            id=constraint.id,
            point_a_id=constraint.point_a_id,
            point_b_id=constraint.point_b_id,
        )
    if isinstance(constraint, ParallelConstraint):
        return ParallelConstraintResponse(
            id=constraint.id,
            line1_id=constraint.line1_id,
            line2_id=constraint.line2_id,
        )
    if isinstance(constraint, PerpendicularConstraint):
        return PerpendicularConstraintResponse(
            id=constraint.id,
            line1_id=constraint.line1_id,
            line2_id=constraint.line2_id,
        )
    if isinstance(constraint, EqualLengthConstraint):
        return EqualLengthConstraintResponse(
            id=constraint.id,
            line1_id=constraint.line1_id,
            line2_id=constraint.line2_id,
        )
    if isinstance(constraint, CollinearConstraint):
        return CollinearConstraintResponse(
            id=constraint.id,
            line1_id=constraint.line1_id,
            line2_id=constraint.line2_id,
        )
    if isinstance(constraint, LineDistanceConstraint):
        return LineDistanceConstraintResponse(
            id=constraint.id,
            line1_id=constraint.line1_id,
            line2_id=constraint.line2_id,
            distance=constraint.distance,
        )
    if isinstance(constraint, PointLineDistanceConstraint):
        return PointLineDistanceConstraintResponse(
            id=constraint.id,
            point_id=constraint.point_id,
            line_id=constraint.line_id,
            distance=constraint.distance,
        )
    if isinstance(constraint, AtMidpointConstraint):
        return AtMidpointConstraintResponse(
            id=constraint.id,
            point_id=constraint.point_id,
            line_id=constraint.line_id,
        )
    raise NotImplementedError(f"No response mapping for constraint type: {constraint.type}")


def _solve_result_response(result: SolveResult) -> SolveResultResponse:
    return SolveResultResponse(
        converged=result.converged,
        dof=result.dof,
        result_code=result.result_code,
        blamed_constraint_ids=result.blamed_constraint_ids,
        solver_reported_failed_constraint_ids=result.solver_reported_failed_constraint_ids,
        detail=result.detail,
    )


@router.post("/sketches", response_model=SketchResponse, status_code=201)
def create_sketch(payload: SketchCreate) -> SketchResponse:
    sketch = _create_sketch(payload.plane)
    return SketchResponse(id=sketch.id, plane=sketch.plane, origin_point_id=sketch.origin_point().id)


@router.get("/sketches/{sketch_id}", response_model=SketchResponse)
def get_sketch(sketch_id: str) -> SketchResponse:
    sketch = _get_sketch_or_404(sketch_id)
    return SketchResponse(id=sketch.id, plane=sketch.plane, origin_point_id=sketch.origin_point().id)


@router.post("/sketches/{sketch_id}/points", response_model=PointResponse, status_code=201)
def create_point(sketch_id: str, payload: PointCreate) -> PointResponse:
    sketch = _get_sketch_or_404(sketch_id)
    _ensure_sketch_editable(sketch_id)
    point = sketch.add_point(payload.x, payload.y)
    return _point_response(point)


@router.get("/sketches/{sketch_id}/points", response_model=list[PointResponse])
def list_points(sketch_id: str) -> list[PointResponse]:
    """Every Point currently in this Sketch - the only way a client can
    learn what a Sketch contains without already knowing specific ids (e.g.
    re-entering a Sketch it didn't just create), mirroring list_constraints."""
    sketch = _get_sketch_or_404(sketch_id)
    return [_point_response(point) for point in sketch.points.values()]


@router.get("/sketches/{sketch_id}/points/{point_id}", response_model=PointResponse)
def get_point(sketch_id: str, point_id: str) -> PointResponse:
    sketch = _get_sketch_or_404(sketch_id)
    return _point_response(_get_point_or_404(sketch, point_id))


@router.patch("/sketches/{sketch_id}/points/{point_id}", response_model=PointResponse)
def update_point(sketch_id: str, point_id: str, payload: PointUpdate) -> PointResponse:
    sketch = _get_sketch_or_404(sketch_id)
    _ensure_sketch_editable(sketch_id)
    point = _get_point_or_404(sketch, point_id)
    if point_id == sketch.origin_point_id:
        raise HTTPException(status_code=400, detail="Cannot move the sketch's origin point")
    point.x = payload.x
    point.y = payload.y
    return _point_response(point)


@router.delete("/sketches/{sketch_id}/points/{point_id}", status_code=204)
def delete_point(sketch_id: str, point_id: str) -> None:
    sketch = _get_sketch_or_404(sketch_id)
    _ensure_sketch_editable(sketch_id)
    _get_point_or_404(sketch, point_id)
    try:
        sketch.delete_point(point_id)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@router.post("/sketches/{sketch_id}/lines", response_model=LineResponse, status_code=201)
def create_line(sketch_id: str, payload: LineCreate) -> LineResponse:
    sketch = _get_sketch_or_404(sketch_id)
    _ensure_sketch_editable(sketch_id)
    try:
        line = sketch.add_line(
            payload.start_point_id,
            payload.end_point_id,
            length=payload.length,
            angle=payload.angle,
            construction=payload.construction,
        )
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=f"Point not found: {exc}") from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return _line_response(sketch, line)


@router.get("/sketches/{sketch_id}/lines", response_model=list[LineResponse])
def list_lines(sketch_id: str) -> list[LineResponse]:
    sketch = _get_sketch_or_404(sketch_id)
    return [_line_response(sketch, line) for line in sketch.lines()]


@router.get("/sketches/{sketch_id}/lines/{line_id}", response_model=LineResponse)
def get_line(sketch_id: str, line_id: str) -> LineResponse:
    sketch = _get_sketch_or_404(sketch_id)
    return _line_response(sketch, _get_line_or_404(sketch, line_id))


@router.delete("/sketches/{sketch_id}/lines/{line_id}", status_code=204)
def delete_line(sketch_id: str, line_id: str) -> None:
    sketch = _get_sketch_or_404(sketch_id)
    _ensure_sketch_editable(sketch_id)
    _get_line_or_404(sketch, line_id)
    sketch.delete_line(line_id)


@router.patch("/sketches/{sketch_id}/lines/{line_id}", response_model=LineResponse)
def update_line(sketch_id: str, line_id: str, payload: LineUpdate) -> LineResponse:
    sketch = _get_sketch_or_404(sketch_id)
    _ensure_sketch_editable(sketch_id)
    line = _get_line_or_404(sketch, line_id)
    if payload.length is not None:
        try:
            line.set_length(sketch.points, payload.length)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
    if payload.construction is not None:
        line.construction = payload.construction
    return _line_response(sketch, line)


@router.post("/sketches/{sketch_id}/circles", response_model=CircleResponse, status_code=201)
def create_circle(sketch_id: str, payload: CircleCreate) -> CircleResponse:
    sketch = _get_sketch_or_404(sketch_id)
    _ensure_sketch_editable(sketch_id)
    try:
        circle = sketch.add_circle(
            payload.center_point_id,
            payload.radius_point_id,
            radius=payload.radius,
            angle=payload.angle,
            construction=payload.construction,
        )
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=f"Point not found: {exc}") from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return _circle_response(sketch, circle)


@router.get("/sketches/{sketch_id}/circles", response_model=list[CircleResponse])
def list_circles(sketch_id: str) -> list[CircleResponse]:
    sketch = _get_sketch_or_404(sketch_id)
    return [_circle_response(sketch, circle) for circle in sketch.circles()]


@router.get("/sketches/{sketch_id}/circles/{circle_id}", response_model=CircleResponse)
def get_circle(sketch_id: str, circle_id: str) -> CircleResponse:
    sketch = _get_sketch_or_404(sketch_id)
    return _circle_response(sketch, _get_circle_or_404(sketch, circle_id))


@router.patch("/sketches/{sketch_id}/circles/{circle_id}", response_model=CircleResponse)
def update_circle(sketch_id: str, circle_id: str, payload: CircleUpdate) -> CircleResponse:
    sketch = _get_sketch_or_404(sketch_id)
    _ensure_sketch_editable(sketch_id)
    circle = _get_circle_or_404(sketch, circle_id)
    if payload.construction is not None:
        circle.construction = payload.construction
    return _circle_response(sketch, circle)


@router.delete("/sketches/{sketch_id}/circles/{circle_id}", status_code=204)
def delete_circle(sketch_id: str, circle_id: str) -> None:
    sketch = _get_sketch_or_404(sketch_id)
    _ensure_sketch_editable(sketch_id)
    _get_circle_or_404(sketch, circle_id)
    sketch.delete_circle(circle_id)


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


@router.post("/sketches/{sketch_id}/constraints", response_model=ConstraintResponse, status_code=201)
def create_constraint(sketch_id: str, payload: ConstraintCreate) -> ConstraintResponse:
    sketch = _get_sketch_or_404(sketch_id)
    _ensure_sketch_editable(sketch_id)
    try:
        if isinstance(payload, DistanceConstraintCreate):
            constraint = sketch.add_distance_constraint(
                payload.point_a_id, payload.point_b_id, payload.distance, payload.orientation
            )
        elif isinstance(payload, VerticalConstraintCreate):
            constraint = sketch.add_vertical_constraint(payload.line_id)
        elif isinstance(payload, HorizontalConstraintCreate):
            constraint = sketch.add_horizontal_constraint(payload.line_id)
        elif isinstance(payload, AngleConstraintCreate):
            constraint = sketch.add_angle_constraint(
                payload.line1_id, payload.line2_id, payload.angle_degrees
            )
        elif isinstance(payload, CoincidentConstraintCreate):
            constraint = sketch.add_coincident_constraint(payload.point_a_id, payload.point_b_id)
        elif isinstance(payload, ParallelConstraintCreate):
            constraint = sketch.add_parallel_constraint(payload.line1_id, payload.line2_id)
        elif isinstance(payload, PerpendicularConstraintCreate):
            constraint = sketch.add_perpendicular_constraint(payload.line1_id, payload.line2_id)
        elif isinstance(payload, EqualLengthConstraintCreate):
            constraint = sketch.add_equal_length_constraint(payload.line1_id, payload.line2_id)
        elif isinstance(payload, CollinearConstraintCreate):
            constraint = sketch.add_collinear_constraint(payload.line1_id, payload.line2_id)
        elif isinstance(payload, LineDistanceConstraintCreate):
            constraint = sketch.add_line_distance_constraint(
                payload.line1_id, payload.line2_id, payload.distance
            )
        elif isinstance(payload, PointLineDistanceConstraintCreate):
            constraint = sketch.add_point_line_distance_constraint(
                payload.point_id, payload.line_id, payload.distance
            )
        elif isinstance(payload, AtMidpointConstraintCreate):
            constraint = sketch.add_at_midpoint_constraint(payload.point_id, payload.line_id)
        else:
            raise NotImplementedError(f"No constraint creation mapping for payload: {payload}")
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=f"Referenced id not found: {exc}") from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return _constraint_response(constraint)


@router.get("/sketches/{sketch_id}/constraints", response_model=list[ConstraintResponse])
def list_constraints(sketch_id: str) -> list[ConstraintResponse]:
    sketch = _get_sketch_or_404(sketch_id)
    return [_constraint_response(constraint) for constraint in sketch.constraints.values()]


@router.delete("/sketches/{sketch_id}/constraints/{constraint_id}", status_code=204)
def delete_constraint(sketch_id: str, constraint_id: str) -> None:
    sketch = _get_sketch_or_404(sketch_id)
    _ensure_sketch_editable(sketch_id)
    _get_constraint_or_404(sketch, constraint_id)
    del sketch.constraints[constraint_id]


@router.patch("/sketches/{sketch_id}/constraints/{constraint_id}", response_model=SolveResultResponse)
def update_constraint_value(
    sketch_id: str, constraint_id: str, payload: ConstraintValueUpdate
) -> SolveResultResponse:
    sketch = _get_sketch_or_404(sketch_id)
    _ensure_sketch_editable(sketch_id)
    constraint = _get_constraint_or_404(sketch, constraint_id)
    if isinstance(constraint, DistanceConstraint):
        constraint.distance = payload.value
    elif isinstance(constraint, LineDistanceConstraint):
        constraint.distance = payload.value
    elif isinstance(constraint, AngleConstraint):
        constraint.angle_degrees = payload.value
    else:
        raise HTTPException(
            status_code=422,
            detail=f"{constraint.type} constraints have no numeric value to update",
        )
    result = solve_sketch(sketch)
    return _solve_result_response(result)


@router.post("/sketches/{sketch_id}/solve", response_model=SolveResultResponse)
def solve(sketch_id: str) -> SolveResultResponse:
    sketch = _get_sketch_or_404(sketch_id)
    result = solve_sketch(sketch)
    return _solve_result_response(result)
