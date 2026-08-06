"""AI Modelling workstream 5: `POST /document/parts/{part_id}/ai-plan/
validate`'s implementation - see docs/ai-modelling/05-backend-plan-
validation.md for the endpoint's own spec/rationale.

Builds a **scratch copy** of the Part's Feature list and walks the plan's
steps in order, calling the *existing* `resolve_X`/`resolve_X_from_bodies`
functions (`app.document.fillet`/`chamfer`/`revolve`/`sweep`/`mirror`/
`pattern`/`create_plane`, plus `app.document.extrude`'s own lower-level
`resolve_feature_tool_shape` for Extrude, which has no standalone
`resolve_extrude` wrapper) against that scratch copy - the exact same
functions every real create-Feature router endpoint already validates
against, so a step that dry-run-passes here behaves identically once
workstream 4's translator executes it for real. **Never** calls
`replace_document`, `part.add_feature` on the *real* Part, or anything
else that mutates real stored state.

Each step is validated in the order given, short-circuiting on the first
structural failure a later step's own reference would need (see `_lookup`/
`_lookup_body` below) - mirrors how the real translator also stops at the
first real failure, so dry-run and real execution behave the same way
given the same plan.

Reference *kind*-checking (03's own locked schema rule, closing the gap a
throwaway spike script's validator missed - see 03's "Spike findings" and
05's own "Real finding from spike 1"): every lookup below names the exact
set of step `kind`s a given field may reference, not just "some earlier
local_id" - an `extrude.sketch_feature_id` must resolve to a `sketch` step
(never a `sketch_point`/etc.), an `extrude.profile_refs` entry must
resolve to a Line/Circle/Arc/Ellipse entity step (never a bare `sketch`
step, never a `sketch_rectangle`/`sketch_polygon`/`sketch_slot` step
directly - the real `select_profiles` only accepts an anchor entity of
that narrower set), a `fillet.edges.of`/`target_body_ids`/
`source_body_ids` entry must resolve to a Body-producing step kind (never
a `sketch`, `create_plane`, `fillet`, or `chamfer` step).
"""

import math
import uuid
from dataclasses import dataclass

from fastapi import HTTPException

from app.document.ai_plan_edges import resolve_edge_selector
from app.document.ai_plan_schemas import (
    ChamferStep,
    CreatePlaneStep,
    ExtrudeStep,
    FilletStep,
    GearRequestStep,
    MirrorPlaneStep,
    MirrorStep,
    PatternAxisStep,
    PatternDirectionStep,
    PatternStep,
    PlanStep,
    RevolveStep,
    SketchArcStep,
    SketchCircleStep,
    SketchEllipseStep,
    SketchLineStep,
    SketchPointStep,
    SketchPolygonStep,
    SketchRectangleStep,
    SketchSlotStep,
    SketchStep,
    StepResult,
    SweepStep,
)
from app.document.schemas import SubShapeRefSchema
from app.document.chamfer import resolve_chamfer
from app.document.create_plane import resolve_create_plane
from app.document.extrude import compute_part_bodies, resolve_feature_tool_shape
from app.document.fillet import resolve_fillet
from app.document.mirror import resolve_mirror
from app.document.models import (
    ChamferFeature,
    CreatePlaneFeature,
    ExtrudeFeature,
    ExtrudeType,
    FilletFeature,
    MirrorFeature,
    Part,
    PatternAxisRef,
    PatternDirectionRef,
    PatternFeature,
    PlaneRef,
    PlaneType,
    PointRef,
    RevolveFeature,
    RevolveMode,
    SketchFeature,
    SweepFeature,
    SweepMode,
)
from app.document.pattern import resolve_pattern
from app.document.revolve import resolve_revolve
from app.document.sweep import resolve_sweep
from app.sketch.models import SketchEntityRef, SketchEntityType
from app.sketch.store import create_sketch, delete_sketch, get_sketch_or_404
from OCC.Core.TopoDS import TopoDS_Shape

# Every step kind whose Feature actually produces a Body - the only kinds
# a `target_body_ids`/`source_body_ids`/`edges.of`/`tool_feature_id`
# reference may resolve to. `gear_request` is included (a routed gear
# request does produce a real Body once the translator runs it for real)
# but is never itself dry-run-resolvable here - see `_lookup_body`.
_BODY_PRODUCING_KINDS = frozenset({"extrude", "revolve", "sweep", "pattern", "mirror", "gear_request"})

# The entity kinds `select_profiles`/Sweep's own `path_refs` gate accept -
# mirrors `app.document.extrude.select_profiles`'s own accepted
# SketchEntityType set and `app.document.router._SWEEP_PATH_ENTITY_TYPES`
# respectively, both minus Spline/Text (out of v1 generation scope per
# 00-conventions.md).
_PROFILE_ELIGIBLE_KINDS = frozenset({"sketch_line", "sketch_circle", "sketch_arc", "sketch_ellipse"})
_PATH_ELIGIBLE_KINDS = frozenset({"sketch_line", "sketch_arc", "sketch_ellipse"})

_ENTITY_TYPE_FOR_KIND: dict[str, SketchEntityType] = {
    "sketch_line": SketchEntityType.LINE,
    "sketch_circle": SketchEntityType.CIRCLE,
    "sketch_arc": SketchEntityType.ARC,
    "sketch_ellipse": SketchEntityType.ELLIPSE,
    "sketch_polygon": SketchEntityType.POLYGON,
    "sketch_slot": SketchEntityType.SLOT,
    "sketch_rectangle": SketchEntityType.RECTANGLE,
}


class _StepError(Exception):
    """Raised by this module's own hand-rolled checks (unknown/wrong-kind
    local_id references, the depends-on-failed-step short-circuit,
    payload-shape checks with no real-backend equivalent to reuse) -
    caught by `_run_step` the same way a real `HTTPException` from a
    `resolve_X` call is, so both end up as one uniform `StepResult`."""

    def __init__(self, detail: dict):
        super().__init__(detail)
        self.detail = detail


@dataclass
class _Resolved:
    kind: str
    feature_id: str | None = None  # real Feature id (sketch/extrude/revolve/sweep/fillet/chamfer/pattern/mirror/create_plane)
    sketch_id: str | None = None  # real Sketch id (sketch steps only)
    point_id: str | None = None  # real Point id (sketch_point steps only)
    entity_id: str | None = None  # real entity id (other sketch-entity steps)
    owning_sketch_id: str | None = None  # the real Sketch id a point/entity belongs to
    # fillet/chamfer steps only - see `StepResult.resolved_edges`'s own doc
    # comment for why `body_id` here is a local_id, not this scratch pass's
    # own Feature id.
    resolved_edges: list[SubShapeRefSchema] | None = None


class _PlanValidator:
    def __init__(self, part: Part):
        self.part = Part(id=part.id, name=part.name, features=list(part.features))
        self.resolved: dict[str, _Resolved] = {}
        self.failed: set[str] = set()
        self._scratch_sketch_ids: list[str] = []

    def run(self, steps: list[PlanStep]) -> list[StepResult]:
        try:
            return [self._run_step(step) for step in steps]
        finally:
            for sketch_id in self._scratch_sketch_ids:
                delete_sketch(sketch_id)

    def _run_step(self, step: PlanStep) -> StepResult:
        try:
            _HANDLERS[step.kind](self, step)
        except (HTTPException, _StepError) as exc:
            self.failed.add(step.local_id)
            detail = exc.detail
            if not isinstance(detail, dict):
                detail = {"type": "error", "message": str(detail)}
            return StepResult(local_id=step.local_id, ok=False, error=detail)
        resolved = self.resolved.get(step.local_id)
        resolved_edges = resolved.resolved_edges if resolved is not None else None
        return StepResult(local_id=step.local_id, ok=True, resolved_edges=resolved_edges)

    def _lookup(self, local_id: str, expected_kinds: frozenset[str], field: str) -> _Resolved:
        if local_id in self.failed:
            raise _StepError({"type": "depends_on_failed_step", "field": field, "local_id": local_id})
        resolved = self.resolved.get(local_id)
        if resolved is None:
            raise _StepError({"type": "unknown_local_id", "field": field, "local_id": local_id})
        if resolved.kind not in expected_kinds:
            raise _StepError(
                {
                    "type": "wrong_kind_reference",
                    "field": field,
                    "local_id": local_id,
                    "expected_kinds": sorted(expected_kinds),
                    "actual_kind": resolved.kind,
                }
            )
        return resolved

    def _lookup_body(self, local_id: str, field: str) -> _Resolved:
        resolved = self._lookup(local_id, _BODY_PRODUCING_KINDS, field)
        if resolved.kind == "gear_request":
            raise _StepError({"type": "gear_body_not_validatable", "field": field, "local_id": local_id})
        return resolved

    def _entity_ref(self, resolved: _Resolved, entity_type: SketchEntityType) -> SketchEntityRef:
        return SketchEntityRef(sketch_id=resolved.owning_sketch_id, entity_type=entity_type, entity_id=resolved.entity_id)

    def _resolve_body_shape(self, bodies: dict[str, TopoDS_Shape], base_id: str) -> tuple[str, TopoDS_Shape]:
        if base_id in bodies:
            return base_id, bodies[base_id]
        matches = sorted(k for k in bodies if k.startswith(f"{base_id}#"))
        if len(matches) == 1:
            return matches[0], bodies[matches[0]]
        if not matches:
            raise _StepError({"type": "missing_body", "body_id": base_id})
        raise _StepError({"type": "ambiguous_body", "body_id": base_id, "candidates": matches})


def validate_ai_plan(part: Part, steps: list[PlanStep]) -> list[StepResult]:
    return _PlanValidator(part).run(steps)


# --- Sketch anchoring ------------------------------------------------------


def _handle_sketch(v: _PlanValidator, step: SketchStep) -> None:
    if (step.plane is None) == (step.plane_feature_id is None):
        raise _StepError({"type": "invalid_step_payload", "message": "exactly one of plane or plane_feature_id is required"})
    plane_feature_id = None
    if step.plane_feature_id is not None:
        plane_feature_id = v._lookup(step.plane_feature_id, frozenset({"create_plane"}), "plane_feature_id").feature_id
    sketch = create_sketch(plane=step.plane)
    v._scratch_sketch_ids.append(sketch.id)
    feature = SketchFeature(id=str(uuid.uuid4()), sketch_id=sketch.id, plane_feature_id=plane_feature_id)
    v.part.add_feature(feature)
    v.resolved[step.local_id] = _Resolved(kind="sketch", feature_id=feature.id, sketch_id=sketch.id)


# --- Sketch entities ---------------------------------------------------


def _handle_sketch_point(v: _PlanValidator, step: SketchPointStep) -> None:
    sk = v._lookup(step.sketch_feature_id, frozenset({"sketch"}), "sketch_feature_id")
    sketch = get_sketch_or_404(sk.sketch_id)
    point = sketch.add_point(step.x, step.y)
    v.resolved[step.local_id] = _Resolved(kind="sketch_point", point_id=point.id, owning_sketch_id=sk.sketch_id)


def _handle_sketch_line(v: _PlanValidator, step: SketchLineStep) -> None:
    sk = v._lookup(step.sketch_feature_id, frozenset({"sketch"}), "sketch_feature_id")
    sketch = get_sketch_or_404(sk.sketch_id)
    start = v._lookup(step.start_point_id, frozenset({"sketch_point"}), "start_point_id")
    end_point_id = None
    if step.end_point_id is not None:
        end_point_id = v._lookup(step.end_point_id, frozenset({"sketch_point"}), "end_point_id").point_id
    angle_radians = None if step.angle is None else math.radians(step.angle)
    try:
        line = sketch.add_line(start.point_id, end_point_id, length=step.length, angle=angle_radians, construction=step.construction)
    except (KeyError, ValueError, TypeError) as exc:
        raise _StepError({"type": "invalid_geometry", "message": str(exc)}) from exc
    v.resolved[step.local_id] = _Resolved(
        kind="sketch_line", entity_id=line.id, owning_sketch_id=sk.sketch_id
    )


def _handle_sketch_circle(v: _PlanValidator, step: SketchCircleStep) -> None:
    sk = v._lookup(step.sketch_feature_id, frozenset({"sketch"}), "sketch_feature_id")
    sketch = get_sketch_or_404(sk.sketch_id)
    center = v._lookup(step.center_point_id, frozenset({"sketch_point"}), "center_point_id")
    radius_point_id = None
    if step.radius_point_id is not None:
        radius_point_id = v._lookup(step.radius_point_id, frozenset({"sketch_point"}), "radius_point_id").point_id
    angle_radians = None if step.angle is None else math.radians(step.angle)
    try:
        circle = sketch.add_circle(
            center.point_id, radius_point_id, radius=step.radius, angle=angle_radians, construction=step.construction
        )
    except (KeyError, ValueError, TypeError) as exc:
        raise _StepError({"type": "invalid_geometry", "message": str(exc)}) from exc
    v.resolved[step.local_id] = _Resolved(kind="sketch_circle", entity_id=circle.id, owning_sketch_id=sk.sketch_id)


def _handle_sketch_arc(v: _PlanValidator, step: SketchArcStep) -> None:
    sk = v._lookup(step.sketch_feature_id, frozenset({"sketch"}), "sketch_feature_id")
    sketch = get_sketch_or_404(sk.sketch_id)
    center = v._lookup(step.center_point_id, frozenset({"sketch_point"}), "center_point_id")
    start = v._lookup(step.start_point_id, frozenset({"sketch_point"}), "start_point_id")
    end_point_id = None
    if step.end_point_id is not None:
        end_point_id = v._lookup(step.end_point_id, frozenset({"sketch_point"}), "end_point_id").point_id
    end_angle_radians = None if step.end_angle is None else math.radians(step.end_angle)
    try:
        arc = sketch.add_arc(
            center.point_id, start.point_id, end_point_id, end_angle=end_angle_radians, construction=step.construction
        )
    except (KeyError, ValueError, TypeError) as exc:
        raise _StepError({"type": "invalid_geometry", "message": str(exc)}) from exc
    v.resolved[step.local_id] = _Resolved(kind="sketch_arc", entity_id=arc.id, owning_sketch_id=sk.sketch_id)


def _handle_sketch_ellipse(v: _PlanValidator, step: SketchEllipseStep) -> None:
    sk = v._lookup(step.sketch_feature_id, frozenset({"sketch"}), "sketch_feature_id")
    sketch = get_sketch_or_404(sk.sketch_id)
    center = v._lookup(step.center_point_id, frozenset({"sketch_point"}), "center_point_id")
    major_point_id = None
    if step.major_point_id is not None:
        major_point_id = v._lookup(step.major_point_id, frozenset({"sketch_point"}), "major_point_id").point_id
    angle_radians = None if step.angle is None else math.radians(step.angle)
    try:
        ellipse = sketch.add_ellipse(
            center.point_id,
            major_point_id,
            major_radius=step.major_radius,
            angle=angle_radians,
            minor_radius=step.minor_radius,
            construction=step.construction,
        )
    except (KeyError, ValueError, TypeError) as exc:
        raise _StepError({"type": "invalid_geometry", "message": str(exc)}) from exc
    v.resolved[step.local_id] = _Resolved(kind="sketch_ellipse", entity_id=ellipse.id, owning_sketch_id=sk.sketch_id)


def _handle_sketch_polygon(v: _PlanValidator, step: SketchPolygonStep) -> None:
    sk = v._lookup(step.sketch_feature_id, frozenset({"sketch"}), "sketch_feature_id")
    sketch = get_sketch_or_404(sk.sketch_id)
    center = v._lookup(step.center_point_id, frozenset({"sketch_point"}), "center_point_id")
    first_vertex = v._lookup(step.first_vertex_point_id, frozenset({"sketch_point"}), "first_vertex_point_id")
    try:
        polygon = sketch.add_polygon(
            center.point_id,
            first_vertex.point_id,
            step.sides,
            construction=step.construction,
            reference_circles=step.reference_circles,
        )
    except (KeyError, ValueError, TypeError) as exc:
        raise _StepError({"type": "invalid_geometry", "message": str(exc)}) from exc
    v.resolved[step.local_id] = _Resolved(kind="sketch_polygon", entity_id=polygon.id, owning_sketch_id=sk.sketch_id)


def _handle_sketch_slot(v: _PlanValidator, step: SketchSlotStep) -> None:
    sk = v._lookup(step.sketch_feature_id, frozenset({"sketch"}), "sketch_feature_id")
    sketch = get_sketch_or_404(sk.sketch_id)
    center1 = v._lookup(step.center1_point_id, frozenset({"sketch_point"}), "center1_point_id")
    center2 = v._lookup(step.center2_point_id, frozenset({"sketch_point"}), "center2_point_id")
    try:
        slot = sketch.add_slot(center1.point_id, center2.point_id, step.radius, construction=step.construction)
    except (KeyError, ValueError, TypeError) as exc:
        raise _StepError({"type": "invalid_geometry", "message": str(exc)}) from exc
    v.resolved[step.local_id] = _Resolved(kind="sketch_slot", entity_id=slot.id, owning_sketch_id=sk.sketch_id)


def _handle_sketch_rectangle(v: _PlanValidator, step: SketchRectangleStep) -> None:
    sk = v._lookup(step.sketch_feature_id, frozenset({"sketch"}), "sketch_feature_id")
    sketch = get_sketch_or_404(sk.sketch_id)
    if len(step.corner_point_ids) != 4:
        raise _StepError({"type": "invalid_step_payload", "message": "corner_point_ids must have exactly 4 entries"})
    corner_ids = [
        v._lookup(local_id, frozenset({"sketch_point"}), "corner_point_ids").point_id
        for local_id in step.corner_point_ids
    ]
    try:
        rectangle = sketch.add_rectangle(corner_ids, axis_aligned=step.axis_aligned, construction=step.construction)
    except (KeyError, ValueError, TypeError) as exc:
        raise _StepError({"type": "invalid_geometry", "message": str(exc)}) from exc
    v.resolved[step.local_id] = _Resolved(kind="sketch_rectangle", entity_id=rectangle.id, owning_sketch_id=sk.sketch_id)


# --- Body-producing Features --------------------------------------------


def _profile_refs(v: _PlanValidator, sketch_id: str, local_ids: list[str], field: str) -> list[SketchEntityRef]:
    refs = []
    for local_id in local_ids:
        resolved = v._lookup(local_id, _PROFILE_ELIGIBLE_KINDS, field)
        if resolved.owning_sketch_id != sketch_id:
            raise _StepError({"type": "profile_ref_wrong_sketch", "field": field, "local_id": local_id})
        refs.append(v._entity_ref(resolved, _ENTITY_TYPE_FOR_KIND[resolved.kind]))
    return refs


def _handle_extrude(v: _PlanValidator, step: ExtrudeStep) -> None:
    sk = v._lookup(step.sketch_feature_id, frozenset({"sketch"}), "sketch_feature_id")
    if step.end_distance <= step.start_distance:
        raise _StepError({"type": "invalid_distances", "message": "end_distance must be greater than start_distance"})
    target_body_ids = [v._lookup_body(t, "target_body_ids").feature_id for t in step.target_body_ids]
    if step.extrude_type == ExtrudeType.CUT and not target_body_ids:
        raise _StepError({"type": "invalid_step_payload", "message": "cut requires at least one target_body_ids entry"})
    profile_refs = _profile_refs(v, sk.sketch_id, step.profile_refs, "profile_refs")

    feature = ExtrudeFeature(
        id=str(uuid.uuid4()),
        sketch_feature_id=sk.feature_id,
        extrude_type=step.extrude_type,
        start_distance=step.start_distance,
        end_distance=step.end_distance,
        target_body_ids=target_body_ids,
        profile_refs=profile_refs,
    )
    v.part.add_feature(feature)
    bodies_so_far = compute_part_bodies(v.part, frozenset({feature.id}))
    try:
        result = resolve_feature_tool_shape(v.part, bodies_so_far, feature.id, frozenset())
    except HTTPException:
        v.part.delete_feature(feature.id)
        raise
    if result is None:
        v.part.delete_feature(feature.id)
        raise _StepError({"type": "no_extrudable_profile", "sketch_feature_id": step.sketch_feature_id})
    v.resolved[step.local_id] = _Resolved(kind="extrude", feature_id=feature.id)


def _handle_revolve(v: _PlanValidator, step: RevolveStep) -> None:
    sk = v._lookup(step.sketch_feature_id, frozenset({"sketch"}), "sketch_feature_id")
    axis = v._lookup(step.axis_ref, frozenset({"sketch_line"}), "axis_ref")
    target_body_ids = [v._lookup_body(t, "target_body_ids").feature_id for t in step.target_body_ids]
    if step.mode == RevolveMode.CUT and not target_body_ids:
        raise _StepError({"type": "invalid_step_payload", "message": "cut requires at least one target_body_ids entry"})
    profile_refs = _profile_refs(v, sk.sketch_id, step.profile_refs, "profile_refs")

    feature = RevolveFeature(
        id=str(uuid.uuid4()),
        sketch_feature_id=sk.feature_id,
        axis_ref=v._entity_ref(axis, SketchEntityType.LINE),
        angle=step.angle,
        mode=step.mode,
        target_body_ids=target_body_ids,
        profile_refs=profile_refs,
    )
    result = resolve_revolve(v.part, feature)
    if result is None:
        raise _StepError({"type": "no_revolvable_profile", "sketch_feature_id": step.sketch_feature_id})
    v.part.add_feature(feature)
    v.resolved[step.local_id] = _Resolved(kind="revolve", feature_id=feature.id)


def _handle_sweep(v: _PlanValidator, step: SweepStep) -> None:
    sk = v._lookup(step.sketch_feature_id, frozenset({"sketch"}), "sketch_feature_id")
    if not step.path_refs:
        raise _StepError({"type": "invalid_step_payload", "message": "sweep requires at least one path_refs entry"})
    path_refs = []
    for p in step.path_refs:
        resolved = v._lookup(p, _PATH_ELIGIBLE_KINDS, "path_refs")
        path_refs.append(v._entity_ref(resolved, _ENTITY_TYPE_FOR_KIND[resolved.kind]))
    target_body_ids = [v._lookup_body(t, "target_body_ids").feature_id for t in step.target_body_ids]
    if step.mode == SweepMode.CUT and not target_body_ids:
        raise _StepError({"type": "invalid_step_payload", "message": "cut requires at least one target_body_ids entry"})
    profile_refs = _profile_refs(v, sk.sketch_id, step.profile_refs, "profile_refs")

    feature = SweepFeature(
        id=str(uuid.uuid4()),
        sketch_feature_id=sk.feature_id,
        path_refs=path_refs,
        mode=step.mode,
        target_body_ids=target_body_ids,
        profile_refs=profile_refs,
    )
    result = resolve_sweep(v.part, feature)
    if result is None:
        raise _StepError({"type": "no_sweepable_profile", "sketch_feature_id": step.sketch_feature_id})
    v.part.add_feature(feature)
    v.resolved[step.local_id] = _Resolved(kind="sweep", feature_id=feature.id)


# --- Fillet / Chamfer ----------------------------------------------------


def _resolve_edges(v: _PlanValidator, edges) -> tuple[list, list[SubShapeRefSchema]]:
    """Returns both the real `SubShapeRef`s (for this scratch pass's own
    `resolve_fillet`/`resolve_chamfer` structural check) and their
    `StepResult.resolved_edges` wire counterpart, with `body_id` rewritten
    from this pass's own scratch Feature id back to `edges.of`'s plan
    local_id (plus any `#N` multi-solid suffix `_resolve_body_shape`
    added) - see that field's own doc comment."""
    target = v._lookup_body(edges.of, "edges.of")
    bodies = compute_part_bodies(v.part, frozenset())
    body_id, body_shape = v._resolve_body_shape(bodies, target.feature_id)
    edge_refs = resolve_edge_selector(body_shape, body_id, edges.selector, edges.direction)
    suffix = body_id[len(target.feature_id) :]
    resolved_edges = [
        SubShapeRefSchema(body_id=f"{edges.of}{suffix}", shape_type=ref.shape_type, index=ref.index)
        for ref in edge_refs
    ]
    return edge_refs, resolved_edges


def _handle_fillet(v: _PlanValidator, step: FilletStep) -> None:
    if step.radius <= 0:
        raise _StepError({"type": "invalid_step_payload", "message": "radius must be greater than 0"})
    edge_refs, resolved_edges = _resolve_edges(v, step.edges)
    feature = FilletFeature(id=str(uuid.uuid4()), edge_refs=edge_refs, radius=step.radius)
    resolve_fillet(v.part, feature)
    v.part.add_feature(feature)
    v.resolved[step.local_id] = _Resolved(kind="fillet", feature_id=feature.id, resolved_edges=resolved_edges)


def _handle_chamfer(v: _PlanValidator, step: ChamferStep) -> None:
    if step.distance <= 0:
        raise _StepError({"type": "invalid_step_payload", "message": "distance must be greater than 0"})
    edge_refs, resolved_edges = _resolve_edges(v, step.edges)
    feature = ChamferFeature(id=str(uuid.uuid4()), edge_refs=edge_refs, distance=step.distance)
    resolve_chamfer(v.part, feature)
    v.part.add_feature(feature)
    v.resolved[step.local_id] = _Resolved(kind="chamfer", feature_id=feature.id, resolved_edges=resolved_edges)


# --- Pattern / Mirror / Create Plane -------------------------------------


def _direction_ref(v: _PlanValidator, step: PatternDirectionStep | None, field: str) -> PatternDirectionRef | None:
    if step is None:
        return None
    if (step.fixed_axis is None) == (step.sketch_line_ref is None):
        raise _StepError({"type": "invalid_step_payload", "message": f"{field} requires exactly one of fixed_axis or sketch_line_ref"})
    if step.fixed_axis is not None:
        return PatternDirectionRef(fixed_axis=step.fixed_axis)
    line = v._lookup(step.sketch_line_ref, frozenset({"sketch_line"}), field)
    return PatternDirectionRef(sketch_line_ref=v._entity_ref(line, SketchEntityType.LINE))


def _axis_ref(v: _PlanValidator, step: PatternAxisStep | None, field: str) -> PatternAxisRef | None:
    if step is None:
        return None
    line = v._lookup(step.sketch_line_ref, frozenset({"sketch_line"}), field)
    return PatternAxisRef(sketch_line_ref=v._entity_ref(line, SketchEntityType.LINE))


def _handle_pattern(v: _PlanValidator, step: PatternStep) -> None:
    source_body_ids = [v._lookup_body(s, "source_body_ids").feature_id for s in step.source_body_ids]
    tool_feature_id = v._lookup_body(step.tool_feature_id, "tool_feature_id").feature_id if step.tool_feature_id else None
    feature = PatternFeature(
        id=str(uuid.uuid4()),
        source_body_ids=source_body_ids,
        pattern_type=step.pattern_type,
        direction_1=_direction_ref(v, step.direction_1, "direction_1"),
        count_1=step.count_1,
        spacing_1=step.spacing_1,
        reverse_1=step.reverse_1,
        direction_2=_direction_ref(v, step.direction_2, "direction_2"),
        count_2=step.count_2,
        spacing_2=step.spacing_2,
        reverse_2=step.reverse_2,
        axis=_axis_ref(v, step.axis, "axis"),
        count_angular=step.count_angular,
        angle_total=step.angle_total,
        reverse_angular=step.reverse_angular,
        skip_indices=list(step.skip_indices),
        merge=step.merge,
        tool_feature_id=tool_feature_id,
    )
    resolve_pattern(v.part, feature)
    v.part.add_feature(feature)
    v.resolved[step.local_id] = _Resolved(kind="pattern", feature_id=feature.id)


def _handle_mirror(v: _PlanValidator, step: MirrorStep) -> None:
    source_body_ids = [v._lookup_body(s, "source_body_ids").feature_id for s in step.source_body_ids]
    tool_feature_id = v._lookup_body(step.tool_feature_id, "tool_feature_id").feature_id if step.tool_feature_id else None
    mirror_plane = _plane_ref(v, step.mirror_plane, "mirror_plane")
    feature = MirrorFeature(
        id=str(uuid.uuid4()),
        source_body_ids=source_body_ids,
        mirror_plane=mirror_plane,
        merge=step.merge,
        tool_feature_id=tool_feature_id,
    )
    resolve_mirror(v.part, feature)
    v.part.add_feature(feature)
    v.resolved[step.local_id] = _Resolved(kind="mirror", feature_id=feature.id)


def _plane_ref(v: _PlanValidator, step: MirrorPlaneStep, field: str) -> PlaneRef:
    if (step.fixed_plane is None) == (step.plane_feature_id is None):
        raise _StepError({"type": "invalid_step_payload", "message": f"{field} requires exactly one of fixed_plane or plane_feature_id"})
    if step.fixed_plane is not None:
        return PlaneRef(fixed_plane=step.fixed_plane)
    plane_feature = v._lookup(step.plane_feature_id, frozenset({"create_plane"}), field)
    return PlaneRef(plane_feature_id=plane_feature.feature_id)


def _handle_create_plane(v: _PlanValidator, step: CreatePlaneStep) -> None:
    line_ref = None
    point_ref = None
    point_refs: list[PointRef] = []
    if step.plane_type == PlaneType.NORMAL_TO_LINE_AT_POINT:
        if step.line_ref is None or step.point_ref is None:
            raise _StepError({"type": "invalid_step_payload", "message": "normal_to_line_at_point requires line_ref and point_ref"})
        line = v._lookup(step.line_ref, frozenset({"sketch_line"}), "line_ref")
        point = v._lookup(step.point_ref, frozenset({"sketch_point"}), "point_ref")
        line_ref = v._entity_ref(line, SketchEntityType.LINE)
        point_ref = SketchEntityRef(sketch_id=point.owning_sketch_id, entity_type=SketchEntityType.POINT, entity_id=point.point_id)
    else:
        if len(step.point_refs) != 3:
            raise _StepError({"type": "invalid_step_payload", "message": "three_points requires exactly 3 point_refs"})
        for local_id in step.point_refs:
            point = v._lookup(local_id, frozenset({"sketch_point"}), "point_refs")
            point_refs.append(
                PointRef(sketch_point_ref=SketchEntityRef(sketch_id=point.owning_sketch_id, entity_type=SketchEntityType.POINT, entity_id=point.point_id))
            )

    feature = CreatePlaneFeature(
        id=str(uuid.uuid4()),
        plane_type=step.plane_type,
        line_ref=line_ref,
        point_ref=point_ref,
        point_refs=point_refs,
    )
    resolve_create_plane(v.part, feature)
    v.part.add_feature(feature)
    v.resolved[step.local_id] = _Resolved(kind="create_plane", feature_id=feature.id)


def _handle_gear_request(v: _PlanValidator, step: GearRequestStep) -> None:
    v.resolved[step.local_id] = _Resolved(kind="gear_request", feature_id=step.local_id)


_HANDLERS = {
    "sketch": _handle_sketch,
    "sketch_point": _handle_sketch_point,
    "sketch_line": _handle_sketch_line,
    "sketch_circle": _handle_sketch_circle,
    "sketch_arc": _handle_sketch_arc,
    "sketch_ellipse": _handle_sketch_ellipse,
    "sketch_polygon": _handle_sketch_polygon,
    "sketch_slot": _handle_sketch_slot,
    "sketch_rectangle": _handle_sketch_rectangle,
    "extrude": _handle_extrude,
    "revolve": _handle_revolve,
    "sweep": _handle_sweep,
    "fillet": _handle_fillet,
    "chamfer": _handle_chamfer,
    "pattern": _handle_pattern,
    "mirror": _handle_mirror,
    "create_plane": _handle_create_plane,
    "gear_request": _handle_gear_request,
}
