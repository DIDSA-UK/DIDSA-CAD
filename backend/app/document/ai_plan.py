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

Existing-Part editing (docs/ai-modelling/09-existing-part-editing.md): any
field above that resolves a plan-local `local_id` may *also* hold a string
of the form `existing:<real_id>`, naming a real Feature already in `part`
instead of a step earlier in this same plan - resolved by `_lookup_existing`
below rather than `self.resolved`. No schema/field-shape change anywhere -
every such field was already a plain `str`/`str | None`, so only this
module's own resolution logic changes. Scope is deliberately narrower than
a plan-local reference: only a Body-producing Feature, a Plane-producing
one, or a whole Sketch (as a `sketch_feature_id` anchor for brand-new
sketch-entity steps) may be named this way - an existing Sketch's own
individual Points/Lines/Circles/etc. are never directly referenceable (see
`_lookup_existing`'s own doc comment for the full rule). A step's own
`local_id` may never itself start with `existing:` - that prefix is
reserved (`reserved_local_id_prefix`, checked in `_run_step`).
"""

import math
import uuid
from dataclasses import dataclass

from fastapi import HTTPException

from app.document.ai_plan_edges import resolve_edge_selector
from app.document.ai_plan_schemas import (
    BooleanStep,
    ChamferStep,
    CreatePlaneStep,
    DeleteBodyStep,
    EdgeSelectorKind,
    ExtrudeStep,
    FilletStep,
    GearRequestStep,
    LoftSectionStep,
    LoftStep,
    MergeStep,
    MirrorPlaneStep,
    MirrorStep,
    MoveBodyStep,
    PatternAxisStep,
    PatternDirectionStep,
    PatternStep,
    PlanStep,
    RevolveStep,
    ScaleBodyStep,
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
from app.document.extrude import EXTRUDABLE_STATUSES, compute_part_bodies, resolve_feature_tool_shape, select_profiles
from app.document.fillet import resolve_fillet
from app.document.loft import resolve_loft
from app.document.mirror import resolve_mirror
from app.document.models import (
    BooleanFeature,
    ChamferFeature,
    CreatePlaneFeature,
    DeleteBodyFeature,
    ExtrudeFeature,
    ExtrudeType,
    Feature,
    FilletFeature,
    LoftFeature,
    LoftMode,
    LoftSection,
    MergeFeature,
    MirrorFeature,
    MoveBodyFeature,
    Part,
    PatternAxisRef,
    PatternDirectionRef,
    PatternFeature,
    PlaneRef,
    PlaneType,
    PointRef,
    Produces,
    RevolveFeature,
    RevolveMode,
    ScaleBodyFeature,
    SketchFeature,
    SweepFeature,
    SweepMode,
)
from app.document.move_body import resolve_move_body
from app.document.native_format import sketch_from_dict, sketch_to_dict
from app.document.pattern import resolve_pattern
from app.document.revolve import resolve_revolve
from app.document.scale_body import resolve_scale_body
from app.document.sweep import resolve_sweep
from app.sketch.models import SketchEntityRef, SketchEntityType
from app.sketch.profile import ProfileStatus, detect_profile
from app.sketch.router import create_constraint as _create_sketch_constraint
from app.sketch.router import update_constraint_value as _update_sketch_constraint_value
from app.sketch.schemas import ConstraintValueUpdate, DistanceConstraintCreate
from app.sketch.store import add_sketch, create_sketch, delete_sketch, get_sketch_or_404
from OCC.Core.TopoDS import TopoDS_Shape

# Existing-Part editing (docs/ai-modelling/09-existing-part-editing.md): the
# reserved local_id prefix a plan step's own field may use *instead of* a
# plan-local id, to name a real Feature already in the Part being edited -
# see `_PlanValidator._lookup_existing` below for the full resolution rule.
_EXISTING_ID_PREFIX = "existing:"

# Every step kind whose Feature actually produces a Body - the only kinds
# a `target_body_ids`/`source_body_ids`/`edges.of`/`tool_feature_id`
# reference may resolve to. `gear_request` is included (a routed gear
# request does produce a real Body once the translator runs it for real)
# but is never itself dry-run-resolvable here - see `_lookup_body`.
# `delete_body` is deliberately excluded - `DeleteBodyFeature.produces ==
# Produces.NONE`, it removes geometry rather than contributing any.
_BODY_PRODUCING_KINDS = frozenset(
    {
        "extrude",
        "revolve",
        "sweep",
        "pattern",
        "mirror",
        "gear_request",
        "loft",
        "merge",
        "boolean",
        "scale_body",
        "move_body",
    }
)

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
    # extrude/revolve/sweep steps only - see `StepResult.hole_count`'s own
    # doc comment.
    hole_count: int | None = None


class _PlanValidator:
    def __init__(self, part: Part, disabled_kinds: frozenset[str] = frozenset()):
        self.part = Part(id=part.id, name=part.name, features=list(part.features))
        self.resolved: dict[str, _Resolved] = {}
        self.failed: set[str] = set()
        # AI Settings -> Tools toggle enforcement: every `kind` the client
        # has currently turned off. Checked once in `_run_step`, before any
        # `_HANDLERS` dispatch - see `PlanValidateRequest.disabled_kinds`'s
        # own doc comment for why this exists (a prompt-only toggle is not
        # enforcement; this is the one place both the standalone Validate
        # call and `PlanTranslator.execute`'s own internal pre-flight
        # validate share).
        self.disabled_kinds = disabled_kinds
        self._scratch_sketch_ids: list[str] = []
        # Existing-Part editing: every real Feature already in the Part
        # being edited, by id - built once here rather than re-scanning
        # `self.part.features` on every `existing:` lookup. `part.features`
        # (not `self.part.features`) is used deliberately - same objects
        # either way (the scratch Part above is a shallow copy), but this
        # makes the intent ("the Part's real, pre-existing Features") clear
        # regardless of which list a future edit reads from.
        self._existing_by_id: dict[str, Feature] = {f.id: f for f in part.features}
        # A pristine snapshot of every existing SketchFeature's real Sketch,
        # captured *before* any dry-run step can touch it - restored in
        # `run`'s own `finally` below. Needed because a new sketch_point/
        # sketch_line/etc. step anchored to an existing Sketch (via
        # `existing:<sketch_feature_id>` as its own `sketch_feature_id`)
        # runs through the ordinary, unmodified `_handle_sketch_point`/etc.
        # path - which calls `get_sketch_or_404` and mutates whatever real
        # Sketch object that resolves to, for real, exactly like it would
        # for a brand-new scratch Sketch. A brand-new scratch Sketch is safe
        # to mutate freely (deleted whole at the end, `_scratch_sketch_ids`
        # above) - an *existing* Sketch is real, persisted state this
        # module's own docstring promises never to touch, so its pristine
        # content is snapshotted here and restored afterward instead, via
        # the exact same `sketch_to_dict`/`sketch_from_dict` round-trip
        # native-file save/load already uses (never a hand-rolled
        # snapshot/restore of Sketch internals to keep in sync by hand).
        self._existing_sketch_snapshots: dict[str, dict] = {
            f.sketch_id: sketch_to_dict(get_sketch_or_404(f.sketch_id))
            for f in part.features
            if f.produces == Produces.SKETCH
        }

    def run(self, steps: list[PlanStep]) -> list[StepResult]:
        try:
            return [self._run_step(step) for step in steps]
        finally:
            for sketch_id in self._scratch_sketch_ids:
                delete_sketch(sketch_id)
            for sketch_id, snapshot in self._existing_sketch_snapshots.items():
                add_sketch(sketch_from_dict(snapshot))

    def _run_step(self, step: PlanStep) -> StepResult:
        try:
            if step.local_id.startswith(_EXISTING_ID_PREFIX):
                # The prefix is reserved for referencing the Part's real,
                # pre-existing Features (`_lookup_existing` below) - a plan
                # step can never invent a brand-new local_id that collides
                # with it.
                raise _StepError({"type": "reserved_local_id_prefix", "local_id": step.local_id})
            if step.kind in self.disabled_kinds:
                raise _StepError({"type": "kind_disabled", "kind": step.kind})
            _HANDLERS[step.kind](self, step)
        except (HTTPException, _StepError) as exc:
            self.failed.add(step.local_id)
            detail = exc.detail
            if not isinstance(detail, dict):
                detail = {"type": "error", "message": str(detail)}
            return StepResult(local_id=step.local_id, ok=False, error=detail)
        resolved = self.resolved.get(step.local_id)
        resolved_edges = resolved.resolved_edges if resolved is not None else None
        hole_count = resolved.hole_count if resolved is not None else None
        return StepResult(local_id=step.local_id, ok=True, resolved_edges=resolved_edges, hole_count=hole_count)

    def _lookup(self, local_id: str, expected_kinds: frozenset[str], field: str) -> _Resolved:
        if local_id.startswith(_EXISTING_ID_PREFIX):
            return self._lookup_existing(local_id, expected_kinds, field)
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

    def _lookup_existing(self, local_id: str, expected_kinds: frozenset[str], field: str) -> _Resolved:
        """Existing-Part editing (docs/ai-modelling/09-existing-part-
        editing.md): resolves `local_id` (already confirmed to start with
        `existing:`) against `self._existing_by_id` instead of this run's
        own `self.resolved` - a real Feature the Part already had before
        this plan started, rather than something an earlier step in *this*
        plan just created.

        Deliberately narrower than a plan-local reference: only a Body-
        producing Feature (`target_body_ids`/`source_body_ids`/
        `tool_feature_id`/`edges.of` fields, i.e. `expected_kinds ==
        _BODY_PRODUCING_KINDS`), a Plane-producing one (`plane_feature_id`
        fields, `expected_kinds == {"create_plane"}`), or a whole Sketch
        (`sketch_feature_id` fields, `expected_kinds == {"sketch"}`) may be
        named this way - never an individual existing Point/Line/Circle/etc.
        (every other `expected_kinds` value used elsewhere in this module),
        matching the scope `client/lib/ai/ai_existing_part_summary.dart`'s
        own prompt-facing summary already advertises to the LLM. Uses the
        real Feature's own `.produces` (`app.document.models.Produces`,
        the same tag the client's `FeatureDto.produces` mirrors) to decide
        which of those three buckets a given existing Feature falls into,
        rather than re-deriving it from the Feature's own Python type.
        """
        feature = self._existing_by_id.get(local_id[len(_EXISTING_ID_PREFIX) :])
        if feature is None:
            raise _StepError({"type": "unknown_existing_id", "field": field, "local_id": local_id})
        if expected_kinds == frozenset({"sketch"}) and feature.produces == Produces.SKETCH:
            return _Resolved(kind="sketch", feature_id=feature.id, sketch_id=feature.sketch_id)
        if expected_kinds == frozenset({"create_plane"}) and feature.produces == Produces.PLANE:
            return _Resolved(kind="create_plane", feature_id=feature.id)
        if expected_kinds == _BODY_PRODUCING_KINDS and feature.produces == Produces.BODY:
            # Sentinel kind, not a claim this existing Feature is literally
            # an Extrude - only used so `_lookup_body`'s own `kind ==
            # "gear_request"` check (the *plan-local* "not yet resolvable"
            # case) never fires for an existing Feature, which always has
            # real, already-computed geometry regardless of its own type
            # (including an existing Fillet/Chamfer/GearFeature - each a
            # real Body once built, even though a *plan-local* fillet/
            # chamfer step is deliberately excluded from
            # `_BODY_PRODUCING_KINDS` for schema-ordering reasons that don't
            # apply here - see `03-structured-plan-schema.md`'s own
            # reference kind-checking rules).
            return _Resolved(kind="extrude", feature_id=feature.id)
        raise _StepError(
            {
                "type": "existing_id_not_allowed_here",
                "field": field,
                "local_id": local_id,
                "expected_kinds": sorted(expected_kinds),
                "actual_produces": feature.produces.value,
            }
        )

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


def validate_ai_plan(part: Part, steps: list[PlanStep], disabled_kinds: frozenset[str] = frozenset()) -> list[StepResult]:
    return _PlanValidator(part, disabled_kinds).run(steps)


# --- Dimension-driven sketches (docs/ai-modelling/08-dimension-driven-
# sketches.md) --------------------------------------------------------------
#
# Every Circle/Arc/Ellipse/Polygon/Slot shape call below already auto-
# creates its own size-defining DistanceConstraint(s) *provisional*
# (`Sketch.add_circle`/`add_arc`/`add_ellipse`/`add_polygon`/`add_slot`'s own
# doc comments) - skipped entirely by the solver until a real value is
# confirmed (`DistanceConstraint.provisional`'s own doc comment), exactly
# like a human's freshly-drawn, not-yet-dimensioned shape. `_confirm_radius`
# below reuses the exact router endpoint a human's own dimension-bar PATCH
# already calls (`app.sketch.router.update_constraint_value`) to flip that
# same flag - the dry-run's own mirror of what the real client-side
# translator does via `SketchApiClient.updateConstraintValue` right after
# creating the entity. Always called with the entity's own just-computed
# radius (never a hand-derived value) so this works uniformly whether the
# plan step named an explicit numeric field (`SketchCircleStep.radius`,
# `SketchSlotStep.radius`, ...) or an explicit second Point instead (e.g.
# `radius_point_id`) - either way the plan's own literal Point coordinates
# already fully determine a real number, and confirming it turns "no real
# dimension at all" into "a real, editable one at the AI's own intended
# size", the dimension-driven-sketches workstream's whole point. Line/
# Rectangle have no such auto-created constraint at all (`_create_distance`
# below makes a brand-new, already-non-provisional one instead).
def _confirm_radius(sketch_id: str, constraint_id: str, value: float) -> None:
    _update_sketch_constraint_value(sketch_id, constraint_id, ConstraintValueUpdate(value=value))


def _create_distance(
    sketch_id: str, point_a_id: str, point_b_id: str, value: float, orientation: str = "linear"
) -> None:
    _create_sketch_constraint(
        sketch_id,
        DistanceConstraintCreate(point_a_id=point_a_id, point_b_id=point_b_id, distance=value, orientation=orientation),
    )


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
    # Unlike Circle/Arc/Ellipse/Polygon/Slot, a Line has no automatic
    # size-defining constraint at all - only create one when the plan
    # itself named a literal length (08's own "Line length" section: an
    # explicit `end_point_id` with no `length` stays exactly as unconstrained
    # as it already was, matching a human drawing two-point line with no
    # dimension added).
    if step.length is not None:
        _create_distance(sk.sketch_id, line.start_point_id, line.end_point_id, step.length, orientation="linear")
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
    _confirm_radius(sk.sketch_id, circle.radius_constraint_id, circle.radius(sketch.points))
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
    _confirm_radius(sk.sketch_id, arc.radius_constraint_id, arc.radius(sketch.points))
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
    _confirm_radius(sk.sketch_id, ellipse.major_constraint_id, ellipse.major_radius(sketch.points))
    _confirm_radius(sk.sketch_id, ellipse.minor_constraint_id, ellipse.minor_radius(sketch.points))
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
    _confirm_radius(sk.sketch_id, polygon.radius_constraint_id, polygon.radius(sketch.points))
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
    _confirm_radius(sk.sketch_id, slot.radius_constraint_id, slot.radius(sketch.points))
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
    # `width`/`height` (08's own "Rectangle width/height" section): corner0
    # -> corner1 is `width`, corner1 -> corner2 is `height` - the same two
    # edges `axis_aligned` already pins Horizontal/Vertical respectively
    # (`Sketch.add_rectangle`'s own doc comment), so a "horizontal"/
    # "vertical"-orientation DistanceConstraint here only adds a length to
    # an edge whose *direction* is already fixed - an orthogonal DOF, never
    # a redundant/conflicting constraint with those direction constraints.
    # For a non-axis-aligned (rotated) rectangle there is no global
    # horizontal/vertical to pin, so a plain "linear" distance between the
    # same two corner pairs is used instead - still exactly that edge's own
    # real length, whatever direction it happens to run in.
    orientation_width = "horizontal" if step.axis_aligned else "linear"
    orientation_height = "vertical" if step.axis_aligned else "linear"
    if step.width is not None:
        _create_distance(sk.sketch_id, corner_ids[0], corner_ids[1], step.width, orientation=orientation_width)
    if step.height is not None:
        _create_distance(sk.sketch_id, corner_ids[1], corner_ids[2], step.height, orientation=orientation_height)
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


def _hole_count(sketch_id: str, profile_refs: list[SketchEntityRef]) -> int:
    """`StepResult.hole_count`'s real value for an Extrude/Revolve/Sweep
    step: reuses `detect_profile`/`select_profiles` directly - the exact
    same nested-loop detection `extrude._solid_for_extrude_feature`/
    `revolve.resolve_revolve`/`sweep.resolve_sweep` already run internally
    to build the real shape - rather than reimplementing nested-loop
    detection here or client-side (real drift risk, see `02-scoping-
    conversation.md`'s own "Real end-to-end exercise" finding). Called
    only after the step's own `resolve_X` call has already succeeded, so
    `result.status` is guaranteed to be one of `EXTRUDABLE_STATUSES`."""
    sketch = get_sketch_or_404(sketch_id).expand_pattern_and_mirror_instances()
    result = detect_profile(sketch)
    if result.status not in EXTRUDABLE_STATUSES:
        return 0
    candidates = [result.profile] if result.status == ProfileStatus.CLOSED_LOOP else result.loops
    profiles = select_profiles(candidates, profile_refs)
    return sum(len(p.inner_loops) for p in profiles)


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
    hole_count = _hole_count(sk.sketch_id, profile_refs)
    v.resolved[step.local_id] = _Resolved(kind="extrude", feature_id=feature.id, hole_count=hole_count)


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
    hole_count = _hole_count(sk.sketch_id, profile_refs)
    v.resolved[step.local_id] = _Resolved(kind="revolve", feature_id=feature.id, hole_count=hole_count)


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
    hole_count = _hole_count(sk.sketch_id, profile_refs)
    v.resolved[step.local_id] = _Resolved(kind="sweep", feature_id=feature.id, hole_count=hole_count)


def _loft_section_point_ref(
    v: _PlanValidator, sk: _Resolved, local_id: str | None, field: str
) -> SketchEntityRef | None:
    if local_id is None:
        return None
    point = v._lookup(local_id, frozenset({"sketch_point"}), field)
    if point.owning_sketch_id != sk.sketch_id:
        raise _StepError({"type": "profile_ref_wrong_sketch", "field": field, "local_id": local_id})
    return SketchEntityRef(sketch_id=point.owning_sketch_id, entity_type=SketchEntityType.POINT, entity_id=point.point_id)


def _resolve_loft_section(v: _PlanValidator, section: LoftSectionStep, index: int) -> LoftSection:
    sk = v._lookup(section.sketch_feature_id, frozenset({"sketch"}), f"sections[{index}].sketch_feature_id")
    profile_refs = _profile_refs(v, sk.sketch_id, section.profile_refs, f"sections[{index}].profile_refs")
    reference_point = _loft_section_point_ref(v, sk, section.reference_point, f"sections[{index}].reference_point")
    alignment_point = _loft_section_point_ref(v, sk, section.alignment_point, f"sections[{index}].alignment_point")
    return LoftSection(
        sketch_feature_id=sk.feature_id,
        profile_refs=profile_refs,
        reference_point=reference_point,
        alignment_point=alignment_point,
    )


def _handle_loft(v: _PlanValidator, step: LoftStep) -> None:
    if len(step.sections) < 2:
        raise _StepError({"type": "invalid_step_payload", "message": "loft requires at least 2 sections"})
    sections = [_resolve_loft_section(v, s, i) for i, s in enumerate(step.sections)]
    target_body_ids = [v._lookup_body(t, "target_body_ids").feature_id for t in step.target_body_ids]
    if step.mode == LoftMode.CUT and not target_body_ids:
        raise _StepError({"type": "invalid_step_payload", "message": "cut requires at least one target_body_ids entry"})
    if step.thickness == 0:
        raise _StepError({"type": "invalid_step_payload", "message": "thickness must not be 0"})
    guide_curve_refs = [
        v._entity_ref(resolved, _ENTITY_TYPE_FOR_KIND[resolved.kind])
        for resolved in (v._lookup(local_id, _PATH_ELIGIBLE_KINDS, "guide_curve_refs") for local_id in step.guide_curve_refs)
    ]

    feature = LoftFeature(
        id=str(uuid.uuid4()),
        sections=sections,
        mode=step.mode,
        ruled=step.ruled,
        target_body_ids=target_body_ids,
        thickness=step.thickness,
        guide_curve_refs=guide_curve_refs,
    )
    resolve_loft(v.part, feature)  # raises a structured HTTPException on failure; result (solid+warnings) unused here
    v.part.add_feature(feature)
    v.resolved[step.local_id] = _Resolved(kind="loft", feature_id=feature.id)


# --- Direct Editing / Boolean ---------------------------------------------


def _handle_merge(v: _PlanValidator, step: MergeStep) -> None:
    from app.document.router import _validate_merge_body_ids

    body_ids = [v._lookup_body(b, "body_ids").feature_id for b in step.body_ids]
    _validate_merge_body_ids(v.part, body_ids)
    feature = MergeFeature(id=str(uuid.uuid4()), body_ids=body_ids)
    v.part.add_feature(feature)
    v.resolved[step.local_id] = _Resolved(kind="merge", feature_id=feature.id)


def _handle_boolean(v: _PlanValidator, step: BooleanStep) -> None:
    from app.document.router import _validate_boolean_body_ids

    target_body_ids = [v._lookup_body(t, "target_body_ids").feature_id for t in step.target_body_ids]
    tool_body_ids = [v._lookup_body(t, "tool_body_ids").feature_id for t in step.tool_body_ids]
    _validate_boolean_body_ids(v.part, target_body_ids, tool_body_ids)
    feature = BooleanFeature(
        id=str(uuid.uuid4()),
        operation=step.operation,
        target_body_ids=target_body_ids,
        tool_body_ids=tool_body_ids,
        consume_tool_bodies=step.consume_tool_bodies,
    )
    v.part.add_feature(feature)
    v.resolved[step.local_id] = _Resolved(kind="boolean", feature_id=feature.id)


def _handle_delete_body(v: _PlanValidator, step: DeleteBodyStep) -> None:
    from app.document.router import _validate_delete_body_ids

    body_ids = [v._lookup_body(b, "body_ids").feature_id for b in step.body_ids]
    _validate_delete_body_ids(v.part, body_ids)
    feature = DeleteBodyFeature(id=str(uuid.uuid4()), body_ids=body_ids)
    v.part.add_feature(feature)
    v.resolved[step.local_id] = _Resolved(kind="delete_body", feature_id=feature.id)


def _handle_scale_body(v: _PlanValidator, step: ScaleBodyStep) -> None:
    from app.document.router import _validate_scale_body_factor

    body_id = v._lookup_body(step.body_id, "body_id").feature_id
    _validate_scale_body_factor(v.part, body_id, step.factor)
    feature = ScaleBodyFeature(id=str(uuid.uuid4()), body_id=body_id, factor=step.factor)
    resolve_scale_body(v.part, feature)  # raises on an unresolvable/degenerate scale
    v.part.add_feature(feature)
    v.resolved[step.local_id] = _Resolved(kind="scale_body", feature_id=feature.id)


def _handle_move_body(v: _PlanValidator, step: MoveBodyStep) -> None:
    from app.document.router import _validate_move_body_payload

    body_id = v._lookup_body(step.body_id, "body_id").feature_id
    rotation_axis = _axis_ref(v, step.rotation_axis, "rotation_axis")
    _validate_move_body_payload(v.part, body_id, rotation_axis)
    feature = MoveBodyFeature(
        id=str(uuid.uuid4()),
        body_id=body_id,
        delta=step.delta,
        rotation_axis=rotation_axis,
        rotation_angle_degrees=step.rotation_angle_degrees,
        make_copy=step.make_copy,
    )
    resolve_move_body(v.part, feature)  # raises on an unresolvable/degenerate move
    v.part.add_feature(feature)
    v.resolved[step.local_id] = _Resolved(kind="move_body", feature_id=feature.id)


# --- Fillet / Chamfer ----------------------------------------------------


def _resolve_edges(v: _PlanValidator, edges) -> tuple[list, list[SubShapeRefSchema]]:
    """Returns both the real `SubShapeRef`s (for this scratch pass's own
    `resolve_fillet`/`resolve_chamfer` structural check) and their
    `StepResult.resolved_edges` wire counterpart, with `body_id` rewritten
    from this pass's own scratch Feature id back to `edges.of`'s plan
    local_id (plus any `#N` multi-solid suffix `_resolve_body_shape`
    added) - see that field's own doc comment.

    Workstream 12 (docs/ai-modelling/12-provenance-edge-selectors.md):
    `EDGE_FROM_SKETCH_POINT`/`EDGE_FROM_SKETCH_LINE` additionally need
    `edges.sketch_point_ref`/`sketch_line_ref` resolved from a plan-local
    `local_id` to the real sketch entity id `app.document.extrude`'s
    provenance cache is actually keyed by - exactly the same "resolve
    local_id to real id, let the caller pass real ids onward" split every
    other field in this module already follows (see `_entity_ref`). Can
    never be `existing:<id>` (`_lookup`'s own `_lookup_existing` fallback
    has no `sketch_point`/`sketch_line` case - an existing Sketch's
    individual entities are never directly referenceable, per this
    module's own docstring)."""
    target = v._lookup_body(edges.of, "edges.of")
    sketch_point_id = None
    sketch_line_id = None
    if edges.selector == EdgeSelectorKind.EDGE_FROM_SKETCH_POINT:
        if edges.sketch_point_ref is None:
            raise _StepError({"type": "invalid_step_payload", "message": "edge_from_sketch_point requires sketch_point_ref"})
        sketch_point_id = v._lookup(edges.sketch_point_ref, frozenset({"sketch_point"}), "edges.sketch_point_ref").point_id
    elif edges.selector == EdgeSelectorKind.EDGE_FROM_SKETCH_LINE:
        if edges.sketch_line_ref is None:
            raise _StepError({"type": "invalid_step_payload", "message": "edge_from_sketch_line requires sketch_line_ref"})
        sketch_line_id = v._lookup(edges.sketch_line_ref, frozenset({"sketch_line"}), "edges.sketch_line_ref").entity_id

    bodies = compute_part_bodies(v.part, frozenset())
    body_id, body_shape = v._resolve_body_shape(bodies, target.feature_id)
    edge_refs = resolve_edge_selector(
        body_shape,
        body_id,
        edges.selector,
        edges.direction,
        part=v.part,
        feature_id=target.feature_id,
        sketch_point_id=sketch_point_id,
        sketch_line_id=sketch_line_id,
        far=edges.far,
    )
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
    "loft": _handle_loft,
    "merge": _handle_merge,
    "boolean": _handle_boolean,
    "delete_body": _handle_delete_body,
    "scale_body": _handle_scale_body,
    "move_body": _handle_move_body,
}
