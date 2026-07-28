"""OCCT geometry construction for PatternFeature (Pattern/Mirror scoping's
Phase 2/4 - see `docs/pattern-mirror-scope.md` §2.2/§2.3/§4):

- **Rectangular** (`pattern_type=RECTANGULAR`, Phase 2): repeats one Body
  along one or two directions via OCCT `gp_Trsf.SetTranslation`.
- **Circular** (`pattern_type=CIRCULAR`, Phase 4): repeats one Body around
  an axis via OCCT `gp_Trsf.SetRotation`.

Both share the identical "index 0 is the untouched seed Body itself, never
re-created" convention (see `PatternFeature`'s own docstring). Kept in its
own module and imported from `app.document.extrude`'s own
`compute_part_bodies` via a function-local import (see that function's own
doc comment) to avoid a circular import - same convention `app.document.
mirror`/`fillet`/`chamfer` already establish, since this module needs
`compute_part_bodies` at module level.
"""

import logging
import math

from fastapi import HTTPException
from OCC.Core.BRepAdaptor import BRepAdaptor_Curve, BRepAdaptor_Surface
from OCC.Core.BRepBuilderAPI import BRepBuilderAPI_Transform
from OCC.Core.GeomAbs import GeomAbs_Circle, GeomAbs_Cylinder, GeomAbs_Line
from OCC.Core.gp import gp_Ax1, gp_Dir, gp_Trsf, gp_Vec
from OCC.Core.TopoDS import TopoDS_Shape, topods

from app.document.create_plane import resolve_sketch_basis
from app.document.extrude import basis_point_to_world, compute_part_bodies, resolve_subshape_from_bodies
from app.document.graph import sketch_feature_id_for_sketch
from app.document.models import (
    FixedAxis,
    Part,
    PatternAxisRef,
    PatternDirectionRef,
    PatternFeature,
    PatternType,
    SketchFeature,
    SubShapeRef,
)
from app.sketch.models import Line, SketchEntityType
from app.sketch.store import get_sketch_or_404, resolve_sketch_entity

logger = logging.getLogger(__name__)

_FIXED_AXIS_DIRECTIONS: dict[FixedAxis, gp_Dir] = {
    FixedAxis.X: gp_Dir(1.0, 0.0, 0.0),
    FixedAxis.Y: gp_Dir(0.0, 1.0, 0.0),
    FixedAxis.Z: gp_Dir(0.0, 0.0, 1.0),
}


def _pattern_source_not_found(body_id: str) -> HTTPException:
    """`source_body_ids`' single entry doesn't currently resolve to a Body
    in the accumulator - same structured 422 envelope as every other
    `missing_reference` in this codebase (`app.document.mirror.
    _mirror_source_not_found`, `app.document.extrude._missing_reference`)."""
    return HTTPException(status_code=422, detail={"type": "missing_reference", "body_id": body_id})


def _non_linear_edge(ref: SubShapeRef) -> HTTPException:
    """A `direction_1`/`direction_2` `edge_ref` that resolves to a real edge
    but not a straight one - a curved edge has no single well-defined
    direction to translate along. Same structured envelope and `type` string
    as `app.document.create_plane._non_linear_edge` (a different module's
    own instance of the identical check - `create_plane.py`'s own edge-
    direction validation is for `NORMAL_TO_EDGE_THROUGH_VERTEX`, not
    reusable directly since it's bound to that module's own error-detail
    shape, but the underlying condition and `type` string are the same
    concept and kept identical for a client that pattern-matches on it)."""
    return HTTPException(
        status_code=422,
        detail={"type": "non_linear_edge", "body_id": ref.body_id, "index": ref.index},
    )


def _invalid_direction_ref() -> HTTPException:
    """A `direction_1`/`direction_2` `sketch_line_ref` that cannot be used
    as a pattern direction - the entity doesn't exist, isn't a Line, is
    degenerate (zero-length), or its owning SketchFeature can't be found.
    Mirrors `app.document.revolve._invalid_axis_ref`'s identical reasoning
    for `RevolveFeature.axis_ref`, generalized to a direction rather than a
    full axis - deliberately its own structured error rather than the
    generic `missing_reference` an unresolvable bare `SketchEntityRef`
    raises, so a client can tell "this ref doesn't resolve to anything at
    all" apart from "this ref resolves, just not to something usable as a
    pattern direction"."""
    return HTTPException(status_code=422, detail={"type": "invalid_direction_ref"})


def _pattern_failed(body_id: str) -> HTTPException:
    """`BRepBuilderAPI_Transform` produced an invalid result for the seed
    Body named by `body_id` - rare for a rigid translation (unlike a
    boolean, a pattern instance essentially never fails geometrically the
    way a fillet/chamfer/fuse can), but kept for the same "never let a raw
    OCCT failure surface as an uncaught 500" reason every other structured
    geometry error in this codebase exists for."""
    return HTTPException(status_code=422, detail={"type": "pattern_failed", "body_id": body_id})


def _non_circular_edge(ref: SubShapeRef) -> HTTPException:
    """Pattern/Mirror Phase 4: an `axis` `edge_ref` that resolves to a real
    edge but not a circular one - a straight/Bezier/BSpline edge has no
    centre or axis to rotate around. Same structured envelope shape as
    `_non_linear_edge`, its own inverse-shaped sibling."""
    return HTTPException(
        status_code=422,
        detail={"type": "non_circular_edge", "body_id": ref.body_id, "index": ref.index},
    )


def _non_cylindrical_face(ref: SubShapeRef) -> HTTPException:
    """Pattern/Mirror Phase 4: an `axis` `face_ref` that resolves to a real
    face but not a cylindrical one - a planar/spherical/conical face has no
    single well-defined rotation axis the way a cylinder's own does."""
    return HTTPException(
        status_code=422,
        detail={"type": "non_cylindrical_face", "body_id": ref.body_id, "index": ref.index},
    )


def _invalid_axis_ref() -> HTTPException:
    """Pattern/Mirror Phase 4: an `axis` `sketch_line_ref` that cannot be
    used as a Circular Pattern axis - mirrors `_invalid_direction_ref`'s
    identical reasoning, generalized to a full axis (origin + direction)
    rather than a bare direction."""
    return HTTPException(status_code=422, detail={"type": "invalid_axis_ref"})


def _axis_from_ref(
    part: Part,
    bodies: dict[str, TopoDS_Shape],
    ref: PatternAxisRef,
    excluded_feature_ids: frozenset[str],
) -> gp_Ax1:
    """The world-space `gp_Ax1` `ref` resolves to - exactly one of
    `edge_ref`/`face_ref`/`sketch_line_ref` is set (enforced by
    `app.document.router._validate_pattern_axis_ref` before this is ever
    called).

    `edge_ref` must be a circular edge (`BRepAdaptor_Curve.GetType() ==
    GeomAbs_Circle`) - its own OCCT `gp_Circ` already carries a centre
    (`Location()`) and axis (`Axis().Direction()`), the same raw
    extraction `app.document.extrude.resolve_circular_edge_arc` performs
    for the sketcher's own edge-dimensioning work, but without that
    function's extra basis-projection step (a Circular Pattern axis needs
    no 2D sketch-plane coordinates at all, unlike that function's own
    Arc-materialization use case - see `docs/pattern-mirror-scope.md`
    §2.7's own note on why this is a thin new wrapper rather than a
    reuse). `face_ref` must be a cylindrical face
    (`BRepAdaptor_Surface.GetType() == GeomAbs_Cylinder`) - its own OCCT
    `gp_Cylinder.Axis()` gives the identical `gp_Ax1` shape directly.
    `sketch_line_ref` mirrors `app.document.revolve._resolve_axis`'s own
    Sketch-Line-to-`gp_Ax1` resolution exactly (restricted to
    `SketchEntityType.LINE`, same "not required to belong to the same
    Sketch as the Profile" independence)."""
    if ref.edge_ref is not None:
        shape = resolve_subshape_from_bodies(bodies, ref.edge_ref)
        edge = topods.Edge(shape)
        curve = BRepAdaptor_Curve(edge)
        if curve.GetType() != GeomAbs_Circle:
            raise _non_circular_edge(ref.edge_ref)
        circle = curve.Circle()
        return gp_Ax1(circle.Location(), circle.Axis().Direction())

    if ref.face_ref is not None:
        shape = resolve_subshape_from_bodies(bodies, ref.face_ref)
        face = topods.Face(shape)
        surface = BRepAdaptor_Surface(face, True)
        if surface.GetType() != GeomAbs_Cylinder:
            raise _non_cylindrical_face(ref.face_ref)
        return surface.Cylinder().Axis()

    if ref.sketch_line_ref is not None:
        line_ref = ref.sketch_line_ref
        if line_ref.entity_type != SketchEntityType.LINE:
            raise _invalid_axis_ref()
        try:
            entity = resolve_sketch_entity(line_ref)
        except HTTPException:
            raise _invalid_axis_ref() from None
        if not isinstance(entity, Line):
            raise _invalid_axis_ref()

        sketch_feature_id = sketch_feature_id_for_sketch(part, line_ref.sketch_id)
        sketch_feature = part.get_feature(sketch_feature_id) if sketch_feature_id else None
        if not isinstance(sketch_feature, SketchFeature):
            raise _invalid_axis_ref()

        sketch = get_sketch_or_404(line_ref.sketch_id)
        basis = resolve_sketch_basis(part, sketch_feature, bodies, excluded_feature_ids)
        start = sketch.points[entity.start_point_id]
        end = sketch.points[entity.end_point_id]
        origin = basis_point_to_world(basis, start.x, start.y)
        end_world = basis_point_to_world(basis, end.x, end.y)
        direction = gp_Vec(origin, end_world)
        if direction.Magnitude() < 1e-9:
            raise _invalid_axis_ref()
        return gp_Ax1(origin, gp_Dir(direction))

    raise _invalid_axis_ref()


def _direction_vector(
    part: Part,
    bodies: dict[str, TopoDS_Shape],
    ref: PatternDirectionRef,
    excluded_feature_ids: frozenset[str],
) -> gp_Dir:
    """The world-space unit direction `ref` resolves to - exactly one of
    `edge_ref`/`sketch_line_ref`/`fixed_axis` is set (enforced by
    `app.document.router._validate_pattern_direction_ref` before this is
    ever called).

    `edge_ref` reuses `app.document.create_plane`'s exact straight-edge-check
    idiom (`BRepAdaptor_Curve(edge).GetType() == GeomAbs_Line`) - a curved
    edge has no single direction. `sketch_line_ref` mirrors
    `app.document.revolve._resolve_axis`'s own Sketch-Line resolution
    (independently-resolved owning Sketch/basis, endpoints mapped through
    that basis), just returning a bare direction instead of a full `gp_Ax1`
    - a Rectangular Pattern only ever translates, it never needs the axis's
    own origin point. `fixed_axis` is a plain lookup table - one of the
    three world axes always exists, no resolution needed at all."""
    if ref.edge_ref is not None:
        shape = resolve_subshape_from_bodies(bodies, ref.edge_ref)
        edge = topods.Edge(shape)
        curve = BRepAdaptor_Curve(edge)
        if curve.GetType() != GeomAbs_Line:
            raise _non_linear_edge(ref.edge_ref)
        return curve.Line().Direction()

    if ref.sketch_line_ref is not None:
        line_ref = ref.sketch_line_ref
        if line_ref.entity_type != SketchEntityType.LINE:
            raise _invalid_direction_ref()
        try:
            entity = resolve_sketch_entity(line_ref)
        except HTTPException:
            raise _invalid_direction_ref() from None
        if not isinstance(entity, Line):
            raise _invalid_direction_ref()

        sketch_feature_id = sketch_feature_id_for_sketch(part, line_ref.sketch_id)
        sketch_feature = part.get_feature(sketch_feature_id) if sketch_feature_id else None
        if not isinstance(sketch_feature, SketchFeature):
            raise _invalid_direction_ref()

        sketch = get_sketch_or_404(line_ref.sketch_id)
        basis = resolve_sketch_basis(part, sketch_feature, bodies, excluded_feature_ids)
        start = sketch.points[entity.start_point_id]
        end = sketch.points[entity.end_point_id]
        origin = basis_point_to_world(basis, start.x, start.y)
        end_world = basis_point_to_world(basis, end.x, end.y)
        direction = gp_Vec(origin, end_world)
        if direction.Magnitude() < 1e-9:
            raise _invalid_direction_ref()
        return gp_Dir(direction)

    if ref.fixed_axis is not None:
        return _FIXED_AXIS_DIRECTIONS[ref.fixed_axis]

    raise _invalid_direction_ref()


def _rectangular_instances(
    part: Part,
    bodies: dict[str, TopoDS_Shape],
    feature: PatternFeature,
    source: TopoDS_Shape,
    source_id: str,
    excluded_feature_ids: frozenset[str],
) -> dict[int, TopoDS_Shape]:
    """The Rectangular Pattern (Phase 2) instance loop - `direction_1` is
    always resolved and used; `direction_2` is only resolved when
    `count_2 > 1` (see `PatternFeature`'s own docstring - a stale/unset
    `direction_2` is otherwise functionally inert anyway, since `j` never
    exceeds 0 when `count_2 == 1`, but skipping its resolution entirely
    also means a stale `direction_2` reference can never break a pattern
    it doesn't actually affect). `reverse_1`/`reverse_2` flip each
    direction before any instance is generated. Index 0 (`i=0, j=0`) is
    never a key in the returned dict - see `resolve_pattern_from_bodies`'s
    own doc comment."""
    dir_1 = _direction_vector(part, bodies, feature.direction_1, excluded_feature_ids)
    if feature.reverse_1:
        dir_1 = dir_1.Reversed()
    dir_2 = None
    if feature.count_2 > 1 and feature.direction_2 is not None:
        dir_2 = _direction_vector(part, bodies, feature.direction_2, excluded_feature_ids)
        if feature.reverse_2:
            dir_2 = dir_2.Reversed()

    instances: dict[int, TopoDS_Shape] = {}
    for i in range(feature.count_1):
        for j in range(feature.count_2):
            index = i * feature.count_2 + j
            if index == 0:
                continue
            offset = gp_Vec(dir_1) * (i * feature.spacing_1)
            if dir_2 is not None:
                offset = offset + gp_Vec(dir_2) * (j * feature.spacing_2)
            trsf = gp_Trsf()
            trsf.SetTranslation(offset)
            transform = BRepBuilderAPI_Transform(source, trsf, True)
            if not transform.IsDone():
                raise _pattern_failed(source_id)
            instances[index] = transform.Shape()
    return instances


def _circular_instances(
    part: Part,
    bodies: dict[str, TopoDS_Shape],
    feature: PatternFeature,
    source: TopoDS_Shape,
    source_id: str,
    excluded_feature_ids: frozenset[str],
) -> dict[int, TopoDS_Shape]:
    """The Circular Pattern (Phase 4) instance loop - `count_angular`
    instances spaced evenly across `angle_total` degrees (the per-instance
    angular step is `angle_total / count_angular`, so a full-360 pattern
    distributes evenly around the circle with no overlapping duplicate at
    both 0° and 360° - see `PatternFeature`'s own docstring).
    `reverse_angular` flips the rotation direction. Index 0 (angle 0) is
    never a key in the returned dict, same convention as the Rectangular
    case - it is always the untouched seed Body."""
    axis = _axis_from_ref(part, bodies, feature.axis, excluded_feature_ids)
    step_radians = math.radians(feature.angle_total / feature.count_angular)
    if feature.reverse_angular:
        step_radians = -step_radians

    instances: dict[int, TopoDS_Shape] = {}
    for i in range(feature.count_angular):
        if i == 0:
            continue
        trsf = gp_Trsf()
        trsf.SetRotation(axis, step_radians * i)
        transform = BRepBuilderAPI_Transform(source, trsf, True)
        if not transform.IsDone():
            raise _pattern_failed(source_id)
        instances[i] = transform.Shape()
    return instances


def resolve_pattern_from_bodies(
    part: Part,
    bodies: dict[str, TopoDS_Shape],
    feature: PatternFeature,
    excluded_feature_ids: frozenset[str],
) -> dict[int, TopoDS_Shape]:
    """Every non-origin instance `feature` produces, keyed by its own linear
    index (Rectangular: the flattened `i * count_2 + j`, row-major;
    Circular: simply the angular-step index `i` - see `PatternFeature`'s
    own docstring for both) - resolved against `bodies`, an already-in-
    progress `app.document.extrude.compute_part_bodies` accumulator, never
    a fresh recompute (same recursion-avoidance reasoning `app.document.
    mirror.resolve_mirror_from_bodies`'s own doc comment gives, since
    resolving a `sketch_line_ref` direction/axis may itself recurse into a
    referenced `CreatePlaneFeature` via `resolve_sketch_basis`).

    Index 0 is never a key in the returned dict for either `pattern_type` -
    it is always the seed Body itself, already registered under its own id
    and left completely untouched (this Feature never modifies its
    source, same Boss-with-no-target semantics `MirrorFeature` uses).
    Dispatches to `_rectangular_instances`/`_circular_instances` per
    `feature.pattern_type` - the two instance-generation loops share no
    code beyond this common source-lookup/dispatch, since a translation
    loop and a rotation loop have genuinely different per-instance
    parameters (a direction pair vs. a single axis+angle)."""
    source_id = feature.source_body_ids[0]
    source = bodies.get(source_id)
    if source is None:
        raise _pattern_source_not_found(source_id)

    if feature.pattern_type == PatternType.CIRCULAR:
        return _circular_instances(part, bodies, feature, source, source_id, excluded_feature_ids)
    return _rectangular_instances(part, bodies, feature, source, source_id, excluded_feature_ids)


def resolve_pattern(
    part: Part, feature: PatternFeature, excluded_feature_ids: frozenset[str] = frozenset()
) -> dict[int, TopoDS_Shape]:
    """Fresh entry point for the router's create/update validation -
    computes `bodies` *as if `feature` weren't in `part.features` yet*
    (excludes its own id in addition to whatever the caller already
    excludes), matching every other resolver's self-exclusion convention
    in this codebase (`app.document.mirror.resolve_mirror`, `app.document.
    revolve.resolve_revolve`, ...)."""
    all_excluded = excluded_feature_ids | {feature.id}
    bodies = compute_part_bodies(part, all_excluded)
    return resolve_pattern_from_bodies(part, bodies, feature, all_excluded)
