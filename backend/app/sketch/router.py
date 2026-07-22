import math
import uuid

from fastapi import APIRouter, HTTPException

from app.sketch.constraints import (
    AngleConstraint,
    AtMidpointConstraint,
    CoincidentConstraint,
    CollinearConstraint,
    Constraint,
    DistanceConstraint,
    EqualLengthConstraint,
    EqualRadiusConstraint,
    HorizontalConstraint,
    LineDistanceConstraint,
    ParallelConstraint,
    PerpendicularConstraint,
    PointLineDistanceConstraint,
    SplineTangentConstraint,
    TangentConstraint,
    VerticalConstraint,
)
from app.sketch.models import (
    Arc,
    Circle,
    Ellipse,
    Line,
    NoIntersectionFoundError,
    Point,
    Polygon,
    Rectangle,
    Sketch,
    Slot,
    Spline,
    TextEntity,
)
from app.sketch.profile import Profile, detect_profile
from app.sketch.schemas import (
    AngleConstraintCreate,
    AngleConstraintResponse,
    ArcCreate,
    ArcResponse,
    ArcTrimRequest,
    ArcTrimResponse,
    ArcUpdate,
    AtMidpointConstraintCreate,
    AtMidpointConstraintResponse,
    CircleCreate,
    CircleResponse,
    CircleTrimRequest,
    CircleTrimResponse,
    CircleUpdate,
    CoincidentConstraintCreate,
    CoincidentConstraintResponse,
    CollinearConstraintCreate,
    CollinearConstraintResponse,
    ConstraintCreate,
    ConstraintResponse,
    ConstraintValueUpdate,
    DeleteEntityResponse,
    DistanceConstraintCreate,
    DistanceConstraintResponse,
    EllipseCreate,
    EllipseResponse,
    EllipseUpdate,
    EqualLengthConstraintCreate,
    EqualLengthConstraintResponse,
    EqualRadiusConstraintCreate,
    EqualRadiusConstraintResponse,
    EqualRadiusPointsConstraintCreate,
    HorizontalConstraintCreate,
    HorizontalConstraintResponse,
    LineCreate,
    LineDistanceConstraintCreate,
    LineDistanceConstraintResponse,
    LineResponse,
    LineSplitTrimRequest,
    LineSplitTrimResponse,
    LineTrimRequest,
    LineTrimResponse,
    LineUpdate,
    OffsetArcResponse,
    OffsetChainRequest,
    OffsetChainResponse,
    OffsetCircleResponse,
    OffsetLineResponse,
    OffsetRequest,
    ParallelConstraintCreate,
    ParallelConstraintResponse,
    PerpendicularConstraintCreate,
    PerpendicularConstraintResponse,
    PointCreate,
    PointLineDistanceConstraintCreate,
    PointLineDistanceConstraintResponse,
    PointResponse,
    PointUpdate,
    PolygonCreate,
    PolygonResponse,
    PolygonUpdate,
    ProfileDetectionResponse,
    ProfileResponse,
    RectangleCreate,
    RectangleResponse,
    RectangleUpdate,
    SketchCreate,
    SketchOrientationUpdate,
    SketchResponse,
    SketchStateResponse,
    SlotCreate,
    SlotResponse,
    SlotUpdate,
    SolveRequest,
    SolveResultResponse,
    SplineCreate,
    SplineResponse,
    SplineTangentConstraintResponse,
    SplineUpdate,
    TangentConstraintCreate,
    TangentConstraintResponse,
    TextContourResponse,
    TextCreate,
    TextPreviewResponse,
    TextResponse,
    TextUpdate,
    VerticalConstraintCreate,
    VerticalConstraintResponse,
)
from app.sketch.solver import SolveResult, solve_sketch
from app.sketch.store import add_sketch as _add_sketch
from app.sketch.store import create_sketch as _create_sketch
from app.sketch.store import get_sketch_or_404 as _get_sketch_or_404
from app.sketch.text_geometry import place_local_point, text_to_polygons

router = APIRouter(prefix="/sketch", tags=["sketch"])


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


def _get_arc_or_404(sketch: Sketch, arc_id: str) -> Arc:
    entity = sketch.entities.get(arc_id)
    if not isinstance(entity, Arc):
        raise HTTPException(status_code=404, detail="Arc not found")
    return entity


def _get_ellipse_or_404(sketch: Sketch, ellipse_id: str) -> Ellipse:
    entity = sketch.entities.get(ellipse_id)
    if not isinstance(entity, Ellipse):
        raise HTTPException(status_code=404, detail="Ellipse not found")
    return entity


def _get_polygon_or_404(sketch: Sketch, polygon_id: str) -> Polygon:
    entity = sketch.entities.get(polygon_id)
    if not isinstance(entity, Polygon):
        raise HTTPException(status_code=404, detail="Polygon not found")
    return entity


def _get_slot_or_404(sketch: Sketch, slot_id: str) -> Slot:
    entity = sketch.entities.get(slot_id)
    if not isinstance(entity, Slot):
        raise HTTPException(status_code=404, detail="Slot not found")
    return entity


def _get_rectangle_or_404(sketch: Sketch, rectangle_id: str) -> Rectangle:
    entity = sketch.entities.get(rectangle_id)
    if not isinstance(entity, Rectangle):
        raise HTTPException(status_code=404, detail="Rectangle not found")
    return entity


def _get_spline_or_404(sketch: Sketch, spline_id: str) -> Spline:
    entity = sketch.entities.get(spline_id)
    if not isinstance(entity, Spline):
        raise HTTPException(status_code=404, detail="Spline not found")
    return entity


def _get_text_or_404(sketch: Sketch, text_id: str) -> TextEntity:
    entity = sketch.entities.get(text_id)
    if not isinstance(entity, TextEntity):
        raise HTTPException(status_code=404, detail="Text not found")
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
        cardinal_point_ids=circle.cardinal_point_ids,
    )


def _arc_response(sketch: Sketch, arc: Arc) -> ArcResponse:
    return ArcResponse(
        id=arc.id,
        center_point_id=arc.center_point_id,
        start_point_id=arc.start_point_id,
        end_point_id=arc.end_point_id,
        radius=arc.radius(sketch.points),
        construction=arc.construction,
    )


def _ellipse_response(sketch: Sketch, ellipse: Ellipse) -> EllipseResponse:
    return EllipseResponse(
        id=ellipse.id,
        center_point_id=ellipse.center_point_id,
        major_point_id=ellipse.major_point_id,
        major_point_neg_id=ellipse.major_point_neg_id,
        minor_point_id=ellipse.minor_point_id,
        minor_point_neg_id=ellipse.minor_point_neg_id,
        major_axis_line_id=ellipse.major_axis_line_id,
        minor_axis_line_id=ellipse.minor_axis_line_id,
        major_radius=ellipse.major_radius(sketch.points),
        minor_radius=ellipse.minor_radius(sketch.points),
        rotation=ellipse.rotation(sketch.points),
        construction=ellipse.construction,
    )


def _polygon_response(sketch: Sketch, polygon: Polygon) -> PolygonResponse:
    return PolygonResponse(
        id=polygon.id,
        center_point_id=polygon.center_point_id,
        vertex_point_ids=polygon.vertex_point_ids,
        line_ids=polygon.line_ids,
        radius=polygon.radius(sketch.points),
        sides=polygon.sides,
        construction=polygon.construction,
    )


def _slot_response(sketch: Sketch, slot: Slot) -> SlotResponse:
    return SlotResponse(
        id=slot.id,
        center1_point_id=slot.center1_point_id,
        center2_point_id=slot.center2_point_id,
        centerline_id=slot.centerline_id,
        arc1_id=slot.arc1_id,
        arc2_id=slot.arc2_id,
        line1_id=slot.line1_id,
        line2_id=slot.line2_id,
        a_point_id=slot.a_point_id,
        b_point_id=slot.b_point_id,
        c_point_id=slot.c_point_id,
        d_point_id=slot.d_point_id,
        radius=slot.radius(sketch.points),
        construction=slot.construction,
    )


def _rectangle_response(rectangle: Rectangle) -> RectangleResponse:
    return RectangleResponse(
        id=rectangle.id,
        corner_point_ids=rectangle.corner_point_ids,
        line_ids=rectangle.line_ids,
        axis_aligned=rectangle.axis_aligned,
        center_point_id=rectangle.center_point_id,
        diagonal_line_id=rectangle.diagonal_line_id,
        diagonal2_line_id=rectangle.diagonal2_line_id,
        construction=rectangle.construction,
    )


def _spline_response(spline: Spline) -> SplineResponse:
    return SplineResponse(
        id=spline.id,
        through_point_ids=spline.through_point_ids,
        control_point_ids=spline.control_point_ids,
        construction=spline.construction,
    )


def _text_response(text: TextEntity) -> TextResponse:
    return TextResponse(
        id=text.id,
        content=text.content,
        font=text.font,
        size=text.size,
        anchor_point_id=text.anchor_point_id,
        rotation_degrees=text.rotation_degrees,
        construction=text.construction,
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
            provisional=constraint.provisional,
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
    if isinstance(constraint, SplineTangentConstraint):
        return SplineTangentConstraintResponse(
            id=constraint.id,
            spline_id=constraint.spline_id,
            segment_a_p0=constraint.segment_a_p0,
            segment_a_p1=constraint.segment_a_p1,
            segment_a_p2=constraint.segment_a_p2,
            segment_a_p3=constraint.segment_a_p3,
            segment_b_p0=constraint.segment_b_p0,
            segment_b_p1=constraint.segment_b_p1,
            segment_b_p2=constraint.segment_b_p2,
            segment_b_p3=constraint.segment_b_p3,
        )
    if isinstance(constraint, TangentConstraint):
        return TangentConstraintResponse(
            id=constraint.id,
            center_point_id=constraint.center_point_id,
            radius_point_id=constraint.radius_point_id,
            line_id=constraint.line_id,
        )
    if isinstance(constraint, EqualRadiusConstraint):
        return EqualRadiusConstraintResponse(
            id=constraint.id,
            center1_point_id=constraint.center1_point_id,
            radius1_point_id=constraint.radius1_point_id,
            center2_point_id=constraint.center2_point_id,
            radius2_point_id=constraint.radius2_point_id,
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


def _sketch_response(sketch: Sketch) -> SketchResponse:
    return SketchResponse(
        id=sketch.id,
        plane=sketch.plane,
        origin_point_id=sketch.origin_point().id,
        flip=sketch.flip,
        rotation_quarter_turns=sketch.rotation_quarter_turns,
    )


@router.post("/sketches", response_model=SketchResponse, status_code=201)
def create_sketch(payload: SketchCreate) -> SketchResponse:
    sketch = _create_sketch(payload.plane, flip=payload.flip, rotation_quarter_turns=payload.rotation_quarter_turns)
    return _sketch_response(sketch)


@router.get("/sketches/{sketch_id}", response_model=SketchResponse)
def get_sketch(sketch_id: str) -> SketchResponse:
    sketch = _get_sketch_or_404(sketch_id)
    return _sketch_response(sketch)


@router.get("/sketches/{sketch_id}/export")
def export_sketch(sketch_id: str) -> dict:
    """Standalone "2D Drawing" tool save: a bare Sketch's own full state as
    a plain JSON dict, for the client to write straight to a local file -
    mirrors `app.document.router.export_native_document`'s identical
    "hand back a dict, client owns the actual file" shape, just scoped to
    one Sketch instead of a whole Document (a bare Sketch, reached via this
    standalone `/sketch` API rather than the Document/Part/Feature layer,
    has no Part to export *with* - see `app.document.native_format.
    sketch_to_dict`'s own doc comment for why this reuses that exact
    serialization rather than inventing a second one).

    Function-local import (not module-level): `app.document.native_format`
    imports from `app.sketch.models`/`constraints`, so a module-level
    import back the other way would be a real circular dependency between
    the `app.sketch` and `app.document` packages - the same avoidance
    `app.document.sweep`'s own docstring documents for its own
    `app.document.extrude` import."""
    from app.document.native_format import sketch_to_dict

    sketch = _get_sketch_or_404(sketch_id)
    return sketch_to_dict(sketch)


@router.post("/sketches/import", response_model=SketchResponse, status_code=201)
def import_sketch(payload: dict) -> SketchResponse:
    """Standalone "2D Drawing" tool open: the inverse of [export_sketch] -
    creates a brand-new Sketch in the store from a previously-exported
    dict, *not* a full-store replace the way `app.document.router.
    import_native_document` is (that one owns the entire process's state;
    this is one Sketch among however many already exist). Always assigns a
    fresh id (never the id the export happened to carry) so re-opening the
    same save file twice, or opening it alongside the Sketch it was
    originally exported from, never collides with an existing entry.

    Fails closed with a 422 for anything malformed, same convention
    `import_native_document` uses for the Document-level format."""
    from app.document.native_format import NativeFormatError, sketch_from_dict

    try:
        sketch = sketch_from_dict(payload)
    except NativeFormatError as exc:
        raise HTTPException(status_code=422, detail=f"Invalid sketch file: {exc}")
    sketch.id = str(uuid.uuid4())
    _add_sketch(sketch)
    return _sketch_response(sketch)


@router.patch("/sketches/{sketch_id}/orientation", response_model=SketchResponse)
def update_sketch_orientation(sketch_id: str, payload: SketchOrientationUpdate) -> SketchResponse:
    """Sketcher-roadmap Phase 5: the retrospective-redefine entry point -
    just flips two fields (see `Sketch.set_orientation`'s own doc comment
    for why this needs no re-projection of any existing Point). Works
    identically for a `plane is None` Sketch (one anchored to a custom
    `CreatePlaneFeature` rather than a fixed `Plane`) - `app.document.
    create_plane._basis_for_sketch` applies these fields via
    `apply_orientation` for that case too (bug fix: it used to silently
    ignore them for a custom-plane Sketch), matching this project's
    general "store what's given, resolve meaning at read time" pattern."""
    sketch = _get_sketch_or_404(sketch_id)
    sketch.set_orientation(flip=payload.flip, rotation_quarter_turns=payload.rotation_quarter_turns)
    return _sketch_response(sketch)


@router.post("/sketches/{sketch_id}/points", response_model=PointResponse, status_code=201)
def create_point(sketch_id: str, payload: PointCreate) -> PointResponse:
    sketch = _get_sketch_or_404(sketch_id)
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
    point = _get_point_or_404(sketch, point_id)
    if point_id == sketch.origin_point_id:
        raise HTTPException(status_code=400, detail="Cannot move the sketch's origin point")
    point.x = payload.x
    point.y = payload.y
    return _point_response(point)


@router.delete("/sketches/{sketch_id}/points/{point_id}", status_code=204)
def delete_point(sketch_id: str, point_id: str) -> None:
    sketch = _get_sketch_or_404(sketch_id)
    _get_point_or_404(sketch, point_id)
    try:
        sketch.delete_point(point_id)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@router.post("/sketches/{sketch_id}/lines", response_model=LineResponse, status_code=201)
def create_line(sketch_id: str, payload: LineCreate) -> LineResponse:
    sketch = _get_sketch_or_404(sketch_id)
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


@router.delete("/sketches/{sketch_id}/lines/{line_id}", response_model=DeleteEntityResponse)
def delete_line(sketch_id: str, line_id: str) -> DeleteEntityResponse:
    sketch = _get_sketch_or_404(sketch_id)
    _get_line_or_404(sketch, line_id)
    pruned_point_ids = sketch.delete_line(line_id)
    return DeleteEntityResponse(pruned_point_ids=pruned_point_ids)


@router.patch("/sketches/{sketch_id}/lines/{line_id}", response_model=LineResponse)
def update_line(sketch_id: str, line_id: str, payload: LineUpdate) -> LineResponse:
    sketch = _get_sketch_or_404(sketch_id)
    line = _get_line_or_404(sketch, line_id)
    if payload.length is not None:
        try:
            line.set_length(sketch.points, payload.length)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
    if payload.construction is not None:
        line.construction = payload.construction
    return _line_response(sketch, line)


@router.post("/sketches/{sketch_id}/lines/{line_id}/trim", response_model=LineTrimResponse)
def trim_line(sketch_id: str, line_id: str, payload: LineTrimRequest) -> LineTrimResponse:
    """Sketcher-roadmap Phase 11: trims/extends [line_id] - see
    `Sketch.trim_or_extend_line`'s own doc comment for the full behaviour.
    404 for a missing Point/Line (a real lookup failure); 422 specifically
    for `NoIntersectionFoundError` (a real, expected "nothing to trim/
    extend to" outcome, not a client error); every other `ValueError`
    (invalid endpoint, Polygon-owned edge) stays the usual 400."""
    sketch = _get_sketch_or_404(sketch_id)
    _get_line_or_404(sketch, line_id)
    _get_point_or_404(sketch, payload.moved_point_id)
    try:
        line, moved_point, created_new_point = sketch.trim_or_extend_line(line_id, payload.moved_point_id)
    except NoIntersectionFoundError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    except (KeyError, ValueError) as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return LineTrimResponse(
        line=_line_response(sketch, line),
        moved_point=_point_response(moved_point),
        created_new_point=created_new_point,
    )


@router.post("/sketches/{sketch_id}/lines/{line_id}/split-trim", response_model=LineSplitTrimResponse)
def split_trim_line(sketch_id: str, line_id: str, payload: LineSplitTrimRequest) -> LineSplitTrimResponse:
    """On-device feedback follow-up ("trim/extend should prioritize the
    part of the line clicked, it maybe the middle, eg. a line completely
    crossing through a circle"): see `Sketch.split_trim_line`'s own doc
    comment for the full behaviour and why this is a separate endpoint
    from `POST .../trim` rather than a rewrite of it.

    404 for a missing Line; 422 specifically for `NoIntersectionFoundError`
    - a real, expected "the click isn't bracketed by two interior
    crossings" outcome, not a client error, and the specific signal the
    client uses to fall back to `POST .../trim` instead (see that
    endpoint's own `moved_point_id` contract); every other `ValueError`
    (Polygon-owned edge, zero-length Line) stays the usual 400."""
    sketch = _get_sketch_or_404(sketch_id)
    _get_line_or_404(sketch, line_id)
    try:
        line1, line2 = sketch.split_trim_line(line_id, payload.click_x, payload.click_y)
    except NoIntersectionFoundError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    except (KeyError, ValueError) as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return LineSplitTrimResponse(line1=_line_response(sketch, line1), line2=_line_response(sketch, line2))


@router.post("/sketches/{sketch_id}/lines/{line_id}/offset", response_model=OffsetLineResponse, status_code=201)
def offset_line(sketch_id: str, line_id: str, payload: OffsetRequest) -> OffsetLineResponse:
    """Sketcher-roadmap Phase 9 v1 (Offset Entities): a new, real Line
    parallel to [line_id] - see `Sketch.offset_line`'s own doc comment for
    the sign convention and v1's single-entity (no corner-join) scope.
    404 for a missing Line; every `ValueError` (zero-length Line, zero
    distance) is a 400."""
    sketch = _get_sketch_or_404(sketch_id)
    _get_line_or_404(sketch, line_id)
    try:
        line = sketch.offset_line(line_id, payload.distance, construction=payload.construction)
    except (KeyError, ValueError) as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return OffsetLineResponse(
        line=_line_response(sketch, line),
        start_point=_point_response(sketch.points[line.start_point_id]),
        end_point=_point_response(sketch.points[line.end_point_id]),
    )


@router.post("/sketches/{sketch_id}/offset-chain", response_model=OffsetChainResponse, status_code=201)
def offset_chain(sketch_id: str, payload: OffsetChainRequest) -> OffsetChainResponse:
    """Offset Entities v2 (on-device feedback: "offset should allow the
    selection of multiple entities... if the origin lines are connected,
    the offset lines should be connected") - see `Sketch.offset_chain`'s
    own doc comment for the corner-joining algorithm and its v1 limits.
    404 for any entity id in the payload that doesn't exist; 400 for a
    non-Line/Arc entity id, a zero-length Line, a collapsing Arc radius,
    zero distance, or a join that collapsed an entity to a single Point."""
    sketch = _get_sketch_or_404(sketch_id)
    try:
        results = sketch.offset_chain(payload.entity_ids, payload.distance, construction=payload.construction)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=f"Entity not found: {exc}") from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    lines: list[LineResponse] = []
    arcs: list[ArcResponse] = []
    seen_point_ids: set[str] = set()
    points: list[PointResponse] = []
    for entity in results:
        point_ids: tuple[str, str]
        if isinstance(entity, Line):
            lines.append(_line_response(sketch, entity))
            point_ids = (entity.start_point_id, entity.end_point_id)
        else:
            arcs.append(_arc_response(sketch, entity))
            point_ids = (entity.start_point_id, entity.end_point_id)
        for point_id in point_ids:
            if point_id in seen_point_ids:
                continue
            seen_point_ids.add(point_id)
            points.append(_point_response(sketch.points[point_id]))
    return OffsetChainResponse(lines=lines, arcs=arcs, points=points)


@router.post("/sketches/{sketch_id}/circles", response_model=CircleResponse, status_code=201)
def create_circle(sketch_id: str, payload: CircleCreate) -> CircleResponse:
    sketch = _get_sketch_or_404(sketch_id)
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
    circle = _get_circle_or_404(sketch, circle_id)
    if payload.construction is not None:
        circle.construction = payload.construction
    return _circle_response(sketch, circle)


@router.delete("/sketches/{sketch_id}/circles/{circle_id}", response_model=DeleteEntityResponse)
def delete_circle(sketch_id: str, circle_id: str) -> DeleteEntityResponse:
    sketch = _get_sketch_or_404(sketch_id)
    _get_circle_or_404(sketch, circle_id)
    pruned_point_ids = sketch.delete_circle(circle_id)
    return DeleteEntityResponse(pruned_point_ids=pruned_point_ids)


@router.post("/sketches/{sketch_id}/circles/{circle_id}/trim", response_model=CircleTrimResponse)
def trim_circle(sketch_id: str, circle_id: str, payload: CircleTrimRequest) -> CircleTrimResponse:
    """On-device feedback ("trim/extend should work on circles curves and
    splines"): see `Sketch.trim_circle`'s own doc comment - converts
    [circle_id] into an Arc excluding whichever segment was clicked. 404
    for a missing Circle; 422 specifically for `NoIntersectionFoundError`
    (fewer than 2 real crossings found - nothing to trim against, a real
    expected outcome, not a client error)."""
    sketch = _get_sketch_or_404(sketch_id)
    _get_circle_or_404(sketch, circle_id)
    try:
        arc, pruned_point_ids = sketch.trim_circle(circle_id, payload.click_x, payload.click_y)
    except NoIntersectionFoundError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    except (KeyError, ValueError) as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return CircleTrimResponse(arc=_arc_response(sketch, arc), pruned_point_ids=pruned_point_ids)


@router.post(
    "/sketches/{sketch_id}/circles/{circle_id}/offset", response_model=OffsetCircleResponse, status_code=201
)
def offset_circle(sketch_id: str, circle_id: str, payload: OffsetRequest) -> OffsetCircleResponse:
    """Offset Entities' Circle-shaped sibling to `offset_line` - see
    `Sketch.offset_circle`'s own doc comment. 404 for a missing Circle;
    every `ValueError` (zero distance, resulting radius <= 0) is a 400."""
    sketch = _get_sketch_or_404(sketch_id)
    _get_circle_or_404(sketch, circle_id)
    try:
        circle = sketch.offset_circle(circle_id, payload.distance, construction=payload.construction)
    except (KeyError, ValueError) as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return OffsetCircleResponse(
        circle=_circle_response(sketch, circle),
        radius_point=_point_response(sketch.points[circle.radius_point_id]),
    )


@router.post("/sketches/{sketch_id}/arcs", response_model=ArcResponse, status_code=201)
def create_arc(sketch_id: str, payload: ArcCreate) -> ArcResponse:
    sketch = _get_sketch_or_404(sketch_id)
    try:
        arc = sketch.add_arc(
            payload.center_point_id,
            payload.start_point_id,
            payload.end_point_id,
            end_angle=payload.end_angle,
            construction=payload.construction,
        )
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=f"Point not found: {exc}") from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return _arc_response(sketch, arc)


@router.get("/sketches/{sketch_id}/arcs", response_model=list[ArcResponse])
def list_arcs(sketch_id: str) -> list[ArcResponse]:
    sketch = _get_sketch_or_404(sketch_id)
    return [_arc_response(sketch, arc) for arc in sketch.arcs()]


@router.get("/sketches/{sketch_id}/arcs/{arc_id}", response_model=ArcResponse)
def get_arc(sketch_id: str, arc_id: str) -> ArcResponse:
    sketch = _get_sketch_or_404(sketch_id)
    return _arc_response(sketch, _get_arc_or_404(sketch, arc_id))


@router.patch("/sketches/{sketch_id}/arcs/{arc_id}", response_model=ArcResponse)
def update_arc(sketch_id: str, arc_id: str, payload: ArcUpdate) -> ArcResponse:
    sketch = _get_sketch_or_404(sketch_id)
    arc = _get_arc_or_404(sketch, arc_id)
    if payload.construction is not None:
        arc.construction = payload.construction
    return _arc_response(sketch, arc)


@router.delete("/sketches/{sketch_id}/arcs/{arc_id}", response_model=DeleteEntityResponse)
def delete_arc(sketch_id: str, arc_id: str) -> DeleteEntityResponse:
    sketch = _get_sketch_or_404(sketch_id)
    _get_arc_or_404(sketch, arc_id)
    pruned_point_ids = sketch.delete_arc(arc_id)
    return DeleteEntityResponse(pruned_point_ids=pruned_point_ids)


@router.post("/sketches/{sketch_id}/arcs/{arc_id}/trim", response_model=ArcTrimResponse)
def trim_arc(sketch_id: str, arc_id: str, payload: ArcTrimRequest) -> ArcTrimResponse:
    """On-device feedback ("trim/extend should work on circles curves and
    splines"): see `Sketch.trim_or_extend_arc`'s own doc comment - mirrors
    `POST .../lines/{line_id}/trim` exactly, just for an Arc's own start/
    end Point. 404 for a missing Point/Arc; 422 specifically for
    `NoIntersectionFoundError`; every other `ValueError` (invalid endpoint,
    degenerate arc) stays the usual 400."""
    sketch = _get_sketch_or_404(sketch_id)
    _get_arc_or_404(sketch, arc_id)
    _get_point_or_404(sketch, payload.moved_point_id)
    try:
        arc, moved_point, created_new_point = sketch.trim_or_extend_arc(arc_id, payload.moved_point_id)
    except NoIntersectionFoundError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    except (KeyError, ValueError) as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return ArcTrimResponse(
        arc=_arc_response(sketch, arc),
        moved_point=_point_response(moved_point),
        created_new_point=created_new_point,
    )


@router.post("/sketches/{sketch_id}/arcs/{arc_id}/offset", response_model=OffsetArcResponse, status_code=201)
def offset_arc(sketch_id: str, arc_id: str, payload: OffsetRequest) -> OffsetArcResponse:
    """Offset Entities' Arc-shaped sibling to `offset_circle` - see
    `Sketch.offset_arc`'s own doc comment. 404 for a missing Arc; every
    `ValueError` (zero distance, resulting radius <= 0) is a 400."""
    sketch = _get_sketch_or_404(sketch_id)
    _get_arc_or_404(sketch, arc_id)
    try:
        arc = sketch.offset_arc(arc_id, payload.distance, construction=payload.construction)
    except (KeyError, ValueError) as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return OffsetArcResponse(
        arc=_arc_response(sketch, arc),
        start_point=_point_response(sketch.points[arc.start_point_id]),
        end_point=_point_response(sketch.points[arc.end_point_id]),
    )


@router.post("/sketches/{sketch_id}/ellipses", response_model=EllipseResponse, status_code=201)
def create_ellipse(sketch_id: str, payload: EllipseCreate) -> EllipseResponse:
    sketch = _get_sketch_or_404(sketch_id)
    try:
        ellipse = sketch.add_ellipse(
            payload.center_point_id,
            payload.major_point_id,
            major_radius=payload.major_radius,
            angle=payload.angle,
            minor_radius=payload.minor_radius,
            construction=payload.construction,
        )
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=f"Point not found: {exc}") from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return _ellipse_response(sketch, ellipse)


@router.get("/sketches/{sketch_id}/ellipses", response_model=list[EllipseResponse])
def list_ellipses(sketch_id: str) -> list[EllipseResponse]:
    sketch = _get_sketch_or_404(sketch_id)
    return [_ellipse_response(sketch, ellipse) for ellipse in sketch.ellipses()]


@router.get("/sketches/{sketch_id}/ellipses/{ellipse_id}", response_model=EllipseResponse)
def get_ellipse(sketch_id: str, ellipse_id: str) -> EllipseResponse:
    sketch = _get_sketch_or_404(sketch_id)
    return _ellipse_response(sketch, _get_ellipse_or_404(sketch, ellipse_id))


@router.patch("/sketches/{sketch_id}/ellipses/{ellipse_id}", response_model=EllipseResponse)
def update_ellipse(sketch_id: str, ellipse_id: str, payload: EllipseUpdate) -> EllipseResponse:
    sketch = _get_sketch_or_404(sketch_id)
    ellipse = _get_ellipse_or_404(sketch, ellipse_id)
    if payload.construction is not None:
        ellipse.construction = payload.construction
    return _ellipse_response(sketch, ellipse)


@router.delete("/sketches/{sketch_id}/ellipses/{ellipse_id}", response_model=DeleteEntityResponse)
def delete_ellipse(sketch_id: str, ellipse_id: str) -> DeleteEntityResponse:
    sketch = _get_sketch_or_404(sketch_id)
    _get_ellipse_or_404(sketch, ellipse_id)
    pruned_point_ids = sketch.delete_ellipse(ellipse_id)
    return DeleteEntityResponse(pruned_point_ids=pruned_point_ids)


@router.post("/sketches/{sketch_id}/polygons", response_model=PolygonResponse, status_code=201)
def create_polygon(sketch_id: str, payload: PolygonCreate) -> PolygonResponse:
    sketch = _get_sketch_or_404(sketch_id)
    try:
        polygon = sketch.add_polygon(
            payload.center_point_id,
            payload.first_vertex_point_id,
            payload.sides,
            construction=payload.construction,
        )
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=f"Point not found: {exc}") from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return _polygon_response(sketch, polygon)


@router.get("/sketches/{sketch_id}/polygons", response_model=list[PolygonResponse])
def list_polygons(sketch_id: str) -> list[PolygonResponse]:
    sketch = _get_sketch_or_404(sketch_id)
    return [_polygon_response(sketch, polygon) for polygon in sketch.polygons()]


@router.get("/sketches/{sketch_id}/polygons/{polygon_id}", response_model=PolygonResponse)
def get_polygon(sketch_id: str, polygon_id: str) -> PolygonResponse:
    sketch = _get_sketch_or_404(sketch_id)
    return _polygon_response(sketch, _get_polygon_or_404(sketch, polygon_id))


@router.patch("/sketches/{sketch_id}/polygons/{polygon_id}", response_model=PolygonResponse)
def update_polygon(sketch_id: str, polygon_id: str, payload: PolygonUpdate) -> PolygonResponse:
    sketch = _get_sketch_or_404(sketch_id)
    polygon = _get_polygon_or_404(sketch, polygon_id)
    if payload.construction is not None:
        polygon.construction = payload.construction
    return _polygon_response(sketch, polygon)


@router.delete("/sketches/{sketch_id}/polygons/{polygon_id}", response_model=DeleteEntityResponse)
def delete_polygon(sketch_id: str, polygon_id: str) -> DeleteEntityResponse:
    sketch = _get_sketch_or_404(sketch_id)
    _get_polygon_or_404(sketch, polygon_id)
    pruned_point_ids = sketch.delete_polygon(polygon_id)
    return DeleteEntityResponse(pruned_point_ids=pruned_point_ids)


@router.post("/sketches/{sketch_id}/slots", response_model=SlotResponse, status_code=201)
def create_slot(sketch_id: str, payload: SlotCreate) -> SlotResponse:
    sketch = _get_sketch_or_404(sketch_id)
    try:
        slot = sketch.add_slot(
            payload.center1_point_id,
            payload.center2_point_id,
            payload.radius,
            construction=payload.construction,
        )
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=f"Point not found: {exc}") from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return _slot_response(sketch, slot)


@router.get("/sketches/{sketch_id}/slots", response_model=list[SlotResponse])
def list_slots(sketch_id: str) -> list[SlotResponse]:
    sketch = _get_sketch_or_404(sketch_id)
    return [_slot_response(sketch, slot) for slot in sketch.slots()]


@router.get("/sketches/{sketch_id}/slots/{slot_id}", response_model=SlotResponse)
def get_slot(sketch_id: str, slot_id: str) -> SlotResponse:
    sketch = _get_sketch_or_404(sketch_id)
    return _slot_response(sketch, _get_slot_or_404(sketch, slot_id))


@router.patch("/sketches/{sketch_id}/slots/{slot_id}", response_model=SlotResponse)
def update_slot(sketch_id: str, slot_id: str, payload: SlotUpdate) -> SlotResponse:
    sketch = _get_sketch_or_404(sketch_id)
    slot = _get_slot_or_404(sketch, slot_id)
    if payload.construction is not None:
        slot.construction = payload.construction
    return _slot_response(sketch, slot)


@router.delete("/sketches/{sketch_id}/slots/{slot_id}", response_model=DeleteEntityResponse)
def delete_slot(sketch_id: str, slot_id: str) -> DeleteEntityResponse:
    sketch = _get_sketch_or_404(sketch_id)
    _get_slot_or_404(sketch, slot_id)
    pruned_point_ids = sketch.delete_slot(slot_id)
    return DeleteEntityResponse(pruned_point_ids=pruned_point_ids)


@router.post("/sketches/{sketch_id}/rectangles", response_model=RectangleResponse, status_code=201)
def create_rectangle(sketch_id: str, payload: RectangleCreate) -> RectangleResponse:
    sketch = _get_sketch_or_404(sketch_id)
    try:
        rectangle = sketch.add_rectangle(
            payload.corner_point_ids,
            axis_aligned=payload.axis_aligned,
            construction=payload.construction,
        )
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=f"Point not found: {exc}") from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return _rectangle_response(rectangle)


@router.get("/sketches/{sketch_id}/rectangles", response_model=list[RectangleResponse])
def list_rectangles(sketch_id: str) -> list[RectangleResponse]:
    sketch = _get_sketch_or_404(sketch_id)
    return [_rectangle_response(rectangle) for rectangle in sketch.rectangles()]


@router.get("/sketches/{sketch_id}/rectangles/{rectangle_id}", response_model=RectangleResponse)
def get_rectangle(sketch_id: str, rectangle_id: str) -> RectangleResponse:
    sketch = _get_sketch_or_404(sketch_id)
    return _rectangle_response(_get_rectangle_or_404(sketch, rectangle_id))


@router.patch("/sketches/{sketch_id}/rectangles/{rectangle_id}", response_model=RectangleResponse)
def update_rectangle(sketch_id: str, rectangle_id: str, payload: RectangleUpdate) -> RectangleResponse:
    sketch = _get_sketch_or_404(sketch_id)
    rectangle = _get_rectangle_or_404(sketch, rectangle_id)
    if payload.construction is not None:
        rectangle.construction = payload.construction
    return _rectangle_response(rectangle)


@router.delete("/sketches/{sketch_id}/rectangles/{rectangle_id}", response_model=DeleteEntityResponse)
def delete_rectangle(sketch_id: str, rectangle_id: str) -> DeleteEntityResponse:
    sketch = _get_sketch_or_404(sketch_id)
    _get_rectangle_or_404(sketch, rectangle_id)
    pruned_point_ids = sketch.delete_rectangle(rectangle_id)
    return DeleteEntityResponse(pruned_point_ids=pruned_point_ids)


@router.post("/sketches/{sketch_id}/splines", response_model=SplineResponse, status_code=201)
def create_spline(sketch_id: str, payload: SplineCreate) -> SplineResponse:
    sketch = _get_sketch_or_404(sketch_id)
    try:
        spline = sketch.add_spline(payload.through_point_ids, construction=payload.construction)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=f"Point not found: {exc}") from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return _spline_response(spline)


@router.get("/sketches/{sketch_id}/splines", response_model=list[SplineResponse])
def list_splines(sketch_id: str) -> list[SplineResponse]:
    sketch = _get_sketch_or_404(sketch_id)
    return [_spline_response(spline) for spline in sketch.splines()]


@router.get("/sketches/{sketch_id}/splines/{spline_id}", response_model=SplineResponse)
def get_spline(sketch_id: str, spline_id: str) -> SplineResponse:
    sketch = _get_sketch_or_404(sketch_id)
    return _spline_response(_get_spline_or_404(sketch, spline_id))


@router.patch("/sketches/{sketch_id}/splines/{spline_id}", response_model=SplineResponse)
def update_spline(sketch_id: str, spline_id: str, payload: SplineUpdate) -> SplineResponse:
    sketch = _get_sketch_or_404(sketch_id)
    spline = _get_spline_or_404(sketch, spline_id)
    if payload.construction is not None:
        spline.construction = payload.construction
    return _spline_response(spline)


@router.delete("/sketches/{sketch_id}/splines/{spline_id}", response_model=DeleteEntityResponse)
def delete_spline(sketch_id: str, spline_id: str) -> DeleteEntityResponse:
    sketch = _get_sketch_or_404(sketch_id)
    _get_spline_or_404(sketch, spline_id)
    pruned_point_ids = sketch.delete_spline(spline_id)
    return DeleteEntityResponse(pruned_point_ids=pruned_point_ids)


@router.post("/sketches/{sketch_id}/texts", response_model=TextResponse, status_code=201)
def create_text(sketch_id: str, payload: TextCreate) -> TextResponse:
    sketch = _get_sketch_or_404(sketch_id)
    try:
        text = sketch.add_text(
            payload.content,
            payload.font,
            payload.size,
            payload.anchor_point_id,
            rotation_degrees=payload.rotation_degrees,
            construction=payload.construction,
        )
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=f"Point not found: {exc}") from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return _text_response(text)


@router.get("/sketches/{sketch_id}/texts", response_model=list[TextResponse])
def list_texts(sketch_id: str) -> list[TextResponse]:
    sketch = _get_sketch_or_404(sketch_id)
    return [_text_response(text) for text in sketch.texts()]


@router.get("/sketches/{sketch_id}/texts/{text_id}", response_model=TextResponse)
def get_text(sketch_id: str, text_id: str) -> TextResponse:
    sketch = _get_sketch_or_404(sketch_id)
    return _text_response(_get_text_or_404(sketch, text_id))


@router.patch("/sketches/{sketch_id}/texts/{text_id}", response_model=TextResponse)
def update_text(sketch_id: str, text_id: str, payload: TextUpdate) -> TextResponse:
    sketch = _get_sketch_or_404(sketch_id)
    text = _get_text_or_404(sketch, text_id)
    if payload.content is not None:
        text.content = payload.content
    if payload.font is not None:
        text.font = payload.font
    if payload.size is not None:
        text.size = payload.size
    if payload.rotation_degrees is not None:
        text.rotation_degrees = payload.rotation_degrees
    if payload.construction is not None:
        text.construction = payload.construction
    return _text_response(text)


@router.delete("/sketches/{sketch_id}/texts/{text_id}", response_model=DeleteEntityResponse)
def delete_text(sketch_id: str, text_id: str) -> DeleteEntityResponse:
    sketch = _get_sketch_or_404(sketch_id)
    _get_text_or_404(sketch, text_id)
    pruned_point_ids = sketch.delete_text(text_id)
    return DeleteEntityResponse(pruned_point_ids=pruned_point_ids)


@router.get("/sketches/{sketch_id}/texts/{text_id}/preview", response_model=TextPreviewResponse)
def get_text_preview(sketch_id: str, text_id: str) -> TextPreviewResponse:
    """Every contour of `text_id`'s own current outline, already positioned
    per its anchor Point/rotation, in sketch-local `(x, y)` - see the Text
    tool's own scoping notes: no font-outline renderer belongs in the
    client, so it fetches/caches/draws this real server-tessellated
    outline instead of approximating one itself. Regenerated fresh on
    every call (see `app.sketch.text_geometry`'s own docstring) - the
    client is expected to call this once per content/font/size/rotation
    change and cache the result locally, not poll it."""
    sketch = _get_sketch_or_404(sketch_id)
    text = _get_text_or_404(sketch, text_id)
    anchor = sketch.points[text.anchor_point_id]

    def placed(local: tuple[float, float]) -> tuple[float, float]:
        return place_local_point(anchor.x, anchor.y, text.rotation_degrees, local[0], local[1])

    try:
        contours = text_to_polygons(text.content, text.font, text.size)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return TextPreviewResponse(
        contours=[
            TextContourResponse(
                outer=[placed(p) for p in outer],
                holes=[[placed(p) for p in hole] for hole in holes],
            )
            for outer, holes in contours
        ]
    )


def _profile_detection_response(sketch: Sketch) -> ProfileDetectionResponse:
    result = detect_profile(sketch)
    return ProfileDetectionResponse(
        status=result.status,
        detail=result.detail,
        profile=_profile_response(result.profile) if result.profile else None,
        branch_point_ids=result.branch_point_ids,
        loops=[_profile_response(loop) for loop in result.loops],
    )


@router.get("/sketches/{sketch_id}/profile", response_model=ProfileDetectionResponse)
def get_profile(sketch_id: str) -> ProfileDetectionResponse:
    sketch = _get_sketch_or_404(sketch_id)
    return _profile_detection_response(sketch)


@router.post("/sketches/{sketch_id}/constraints", response_model=ConstraintResponse, status_code=201)
def create_constraint(sketch_id: str, payload: ConstraintCreate) -> ConstraintResponse:
    sketch = _get_sketch_or_404(sketch_id)
    try:
        if isinstance(payload, DistanceConstraintCreate):
            constraint = sketch.add_distance_constraint(
                payload.point_a_id,
                payload.point_b_id,
                payload.distance,
                payload.orientation,
                provisional=payload.provisional,
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
        elif isinstance(payload, TangentConstraintCreate):
            constraint = sketch.add_tangent_constraint(payload.circle_or_arc_id, payload.line_id)
        elif isinstance(payload, EqualRadiusConstraintCreate):
            constraint = sketch.add_equal_radius_constraint(
                payload.entity1_id, payload.entity2_id, radius2_point_id=payload.radius2_point_id
            )
        elif isinstance(payload, EqualRadiusPointsConstraintCreate):
            constraint = sketch.add_equal_radius_constraint_from_points(
                payload.center1_point_id,
                payload.radius1_point_id,
                payload.center2_point_id,
                payload.radius2_point_id,
            )
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
    _get_constraint_or_404(sketch, constraint_id)
    del sketch.constraints[constraint_id]


def _reseed_distance_constraint_free_point(
    sketch: Sketch, constraint: DistanceConstraint, new_distance: float
) -> None:
    """On-device feedback: py-slvs's `addPointsDistance` is a squared-distance
    equation with two mirror-symmetric roots either side of `point_a` -
    `update_constraint_value`'s solve seeds each Point from its *current*
    stored x/y (see `_PySlvsBuilder.point2d`) with neither point anchored, so
    it normally converges back to the same side the two Points already sit
    on - but whenever their current separation (on the constrained axis, for
    "horizontal"/"vertical"; on both, for "linear") is small enough that
    floating-point noise dominates the direction, the solve can converge to
    the *other* mirror root instead, flipping which side of `point_a`
    `point_b` ends up on. Reported on-device as a dimension's value
    "changing polarity" on confirm, "only some of the time" - exactly the
    near-degenerate-seed signature.

    Fixes this by re-seeding `point_b`'s stored position, before the solve
    ever runs, to sit at exactly `new_distance` along the *current* direction
    from `point_a` to `point_b` - the solve then starts already on the
    correct side (a much better initial guess than the old, possibly
    near-zero, separation), so Newton's method converges back there instead
    of the arbitrary opposite one. A no-op when the current separation is
    exactly zero - genuinely no "side" to preserve in that case, not a
    regression, since no seed choice can resolve that either.
    """
    point_a = sketch.points.get(constraint.point_a_id)
    point_b = sketch.points.get(constraint.point_b_id)
    if point_a is None or point_b is None:
        return
    if constraint.orientation == "horizontal":
        dx = point_b.x - point_a.x
        if dx == 0:
            return
        point_b.x = point_a.x + math.copysign(new_distance, dx)
    elif constraint.orientation == "vertical":
        dy = point_b.y - point_a.y
        if dy == 0:
            return
        point_b.y = point_a.y + math.copysign(new_distance, dy)
    else:
        dx = point_b.x - point_a.x
        dy = point_b.y - point_a.y
        current_distance = math.hypot(dx, dy)
        if current_distance == 0:
            return
        scale = new_distance / current_distance
        point_b.x = point_a.x + dx * scale
        point_b.y = point_a.y + dy * scale


@router.patch("/sketches/{sketch_id}/constraints/{constraint_id}", response_model=SolveResultResponse)
def update_constraint_value(
    sketch_id: str, constraint_id: str, payload: ConstraintValueUpdate
) -> SolveResultResponse:
    sketch = _get_sketch_or_404(sketch_id)
    constraint = _get_constraint_or_404(sketch, constraint_id)
    if isinstance(constraint, DistanceConstraint):
        _reseed_distance_constraint_free_point(sketch, constraint, payload.value)
        constraint.distance = payload.value
        # Any explicit value PATCH is the user confirming a size (this is
        # the same endpoint the ghost-confirm flow already calls) - clears
        # `provisional` without needing a separate confirm flag/endpoint.
        constraint.provisional = False
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
def solve(sketch_id: str, payload: SolveRequest | None = None) -> SolveResultResponse:
    """`payload` is optional (defaults to no anchors) so every caller from
    before drag-solve semantics existed - which POSTs no body at all -
    keeps working unchanged; see SolveRequest's own doc comment."""
    sketch = _get_sketch_or_404(sketch_id)
    anchor_point_ids = frozenset(payload.anchor_point_ids) if payload else frozenset()
    result = solve_sketch(sketch, anchor_point_ids=anchor_point_ids)
    return _solve_result_response(result)


@router.post("/sketches/{sketch_id}/solve-and-refresh", response_model=SketchStateResponse)
def solve_and_refresh(sketch_id: str, payload: SolveRequest | None = None) -> SketchStateResponse:
    """Phase 0 round-trip reduction: bundles [solve]'s own result with what
    every caller of it immediately fetches afterward anyway (`listPoints`,
    `listConstraints`, `getProfile`) into one response, for the common
    "just finished a mutation" case - same solve semantics as [solve]
    (including `anchor_point_ids`), no new solver behaviour."""
    sketch = _get_sketch_or_404(sketch_id)
    anchor_point_ids = frozenset(payload.anchor_point_ids) if payload else frozenset()
    result = solve_sketch(sketch, anchor_point_ids=anchor_point_ids)
    return SketchStateResponse(
        solve=_solve_result_response(result),
        points=[_point_response(point) for point in sketch.points.values()],
        constraints=[_constraint_response(constraint) for constraint in sketch.constraints.values()],
        profile=_profile_detection_response(sketch),
    )
