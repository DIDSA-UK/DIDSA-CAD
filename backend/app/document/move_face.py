"""OCCT geometry construction for MoveFaceFeature (Direct Editing family,
fifth/last entry - see `docs/direct-editing-scope.md`) - moves a single
planar face along its own normal, an explicit delta, or a picked edge's
direction, and heals the adjacent faces by construction.

Technique: extrude the target face's own profile along the movement vector
into a solid prism (`BRepPrimAPI_MakePrism` - the same primitive `app.
document.split` already uses for its own oversized-block cutting tools),
then fuse it into the Body (if the vector points outward, adding material)
or cut it out of the Body (if it points inward, removing material) via
`BRepAlgoAPI_Fuse`/`BRepAlgoAPI_Cut` - both already heavily used elsewhere
in this codebase. This is NOT a "true" synchronous-modeling face-offset
solver (OCCT/pythonocc-core has none, per this package's own scope doc) -
it works because, for a *single planar face* being pushed in *any* direction
with a nonzero component along its own outward normal, "the material swept
between the face's old and new position" is exactly this prism, and fusing/
cutting it in is geometrically identical to what a real face-offset solver
would produce for this specific, narrow case. Confirmed via a real
pythonocc-core spike: pushing one face of a box outward/inward (both purely
along its normal and with an arbitrary sheared/tangential delta) produces
the exact expected volume and a valid result each time.

The movement vector's sign relative to the face's own *outward* normal
(accounting for `TopoDS_Face.Orientation()` - a `REVERSED` face's own
`BRepAdaptor_Surface` plane normal points the wrong way and must be
flipped) decides Fuse (material added) vs. Cut (material removed) - a
vector with (near-)zero component along that normal is rejected as
degenerate (nothing for this technique to meaningfully do - see `_move_
face_failed`).

v1 scope (planar faces, single face - see `MoveFaceFeature`'s own
docstring): this module makes no attempt to detect "this offset is large
enough to consume a neighbouring face" ahead of time - `BRepAlgoAPI_Fuse`/
`BRepAlgoAPI_Cut` either produce a valid result or don't
(`BRepCheck_Analyzer`/an empty-or-negative-volume result both fail closed),
so an offset that goes wrong surfaces as the same structured 422 a
geometrically-impossible Fillet radius already does, not a distinct
predictive check.

This module needs `compute_part_bodies`/`resolve_subshape_from_bodies` from
extrude.py at module level, so (mirroring app.document.chamfer/fillet's own
identical circular-import workaround) extrude.py imports this module back
via a function-local import inside `_apply_feature_to_bodies` instead.
"""

from fastapi import HTTPException
from OCC.Core.BRepAdaptor import BRepAdaptor_Surface
from OCC.Core.BRepAlgoAPI import BRepAlgoAPI_Cut, BRepAlgoAPI_Fuse
from OCC.Core.BRepCheck import BRepCheck_Analyzer
from OCC.Core.BRepGProp import brepgprop
from OCC.Core.BRepPrimAPI import BRepPrimAPI_MakePrism
from OCC.Core.GeomAbs import GeomAbs_Plane
from OCC.Core.gp import gp_Vec
from OCC.Core.GProp import GProp_GProps
from OCC.Core.TopAbs import TopAbs_FACE, TopAbs_REVERSED
from OCC.Core.TopExp import TopExp_Explorer
from OCC.Core.TopoDS import TopoDS_Shape, topods

from app.document.extrude import compute_part_bodies, resolve_subshape_from_bodies
from app.document.models import MoveFaceFeature, Part, SubShapeType
from app.document.pattern import direction_vector

# Below this fraction of the movement vector's own magnitude, its component
# along the face's outward normal is treated as "no meaningful perpendicular
# movement" - see `_movement_vector`'s own doc comment.
_MIN_NORMAL_COMPONENT_RATIO = 1e-6


def _move_face_not_found(body_id: str) -> HTTPException:
    return HTTPException(status_code=422, detail={"type": "missing_reference", "body_id": body_id})


def _move_face_non_planar(body_id: str) -> HTTPException:
    return HTTPException(
        status_code=422, detail={"type": "non_planar_reference", "body_id": body_id}
    )


def _move_face_failed(body_id: str) -> HTTPException:
    """The movement vector had no meaningful component along the face's
    own outward normal, or the resulting Fuse/Cut didn't complete/produced
    a degenerate result - see this module's own top-level docstring. 422,
    matching every other structured geometry-failure error in this
    codebase."""
    return HTTPException(status_code=422, detail={"type": "move_face_failed", "body_id": body_id})


def _face_count(shape: TopoDS_Shape) -> int:
    count = 0
    exp = TopExp_Explorer(shape, TopAbs_FACE)
    while exp.More():
        count += 1
        exp.Next()
    return count


def _volume(shape: TopoDS_Shape) -> float:
    props = GProp_GProps()
    brepgprop.VolumeProperties(shape, props)
    return props.Mass()


def _outward_normal(face) -> gp_Vec:
    """`face`'s own plane normal, corrected for `Orientation()` - a
    `REVERSED` face's raw `BRepAdaptor_Surface` normal points *into* the
    solid, not out of it (confirmed via the real pythonocc-core spike this
    module's own docstring references)."""
    plane = BRepAdaptor_Surface(face, True).Plane()
    direction = plane.Axis().Direction()
    normal = gp_Vec(direction.X(), direction.Y(), direction.Z())
    if face.Orientation() == TopAbs_REVERSED:
        normal = normal.Reversed()
    return normal


def _movement_vector(
    part: Part,
    bodies: dict[str, TopoDS_Shape],
    feature: MoveFaceFeature,
    excluded_feature_ids: frozenset[str],
    outward_normal: gp_Vec,
) -> gp_Vec:
    """The world-space vector `feature` moves its face by, for exactly one
    of its three mutually-exclusive modes (payload shape already validated
    by the router's own `_validate_move_face_payload`)."""
    if feature.offset_distance is not None:
        return outward_normal.Scaled(feature.offset_distance)
    if feature.delta is not None:
        dx, dy, dz = feature.delta
        return gp_Vec(dx, dy, dz)
    if feature.direction_ref is not None and feature.direction_distance is not None:
        direction = direction_vector(part, bodies, feature.direction_ref, excluded_feature_ids)
        return gp_Vec(direction.X(), direction.Y(), direction.Z()).Scaled(feature.direction_distance)
    # Unreachable once the router's own payload-shape validation runs first
    # (mirrors every other "exactly one of N fields" ref type in this
    # codebase - SplitToolRef, PatternAxisRef - which likewise never check
    # this branch defensively beyond that validation).
    raise _move_face_failed(feature.face_ref.body_id)


def resolve_move_face_from_bodies(
    part: Part,
    bodies: dict[str, TopoDS_Shape],
    feature: MoveFaceFeature,
    excluded_feature_ids: frozenset[str],
) -> tuple[str, TopoDS_Shape]:
    """The Body id `feature` modifies and its post-move shape, resolved
    against `bodies` - an already-in-progress `app.document.extrude.
    compute_part_bodies` accumulator, never a fresh recompute (same reason
    `resolve_fillet_from_bodies`'s own doc comment gives). Needs `part`/
    `excluded_feature_ids` (unlike Fillet/Chamfer/Scale Body's simpler
    two-argument shape) only because `direction_ref` resolution
    (`direction_vector`) needs them, mirroring `resolve_move_body_from_
    bodies`'s identical four-argument shape for the same reason."""
    body_id = feature.face_ref.body_id
    source = bodies.get(body_id)
    if source is None:
        raise _move_face_not_found(body_id)
    if feature.face_ref.shape_type != SubShapeType.FACE:
        raise _move_face_not_found(body_id)

    face = topods.Face(resolve_subshape_from_bodies(bodies, feature.face_ref))
    if BRepAdaptor_Surface(face, True).GetType() != GeomAbs_Plane:
        raise _move_face_non_planar(body_id)

    outward_normal = _outward_normal(face)
    vec = _movement_vector(part, bodies, feature, excluded_feature_ids, outward_normal)

    magnitude = vec.Magnitude()
    if magnitude < 1e-9:
        raise _move_face_failed(body_id)
    normal_component = vec.Dot(outward_normal)
    if abs(normal_component) < magnitude * _MIN_NORMAL_COMPONENT_RATIO:
        raise _move_face_failed(body_id)

    prism = BRepPrimAPI_MakePrism(face, vec).Shape()
    boolean_op = BRepAlgoAPI_Fuse if normal_component > 0 else BRepAlgoAPI_Cut
    result = boolean_op(source, prism).Shape()

    if not BRepCheck_Analyzer(result).IsValid():
        raise _move_face_failed(body_id)
    if _face_count(result) == 0 or _volume(result) <= 0.0:
        raise _move_face_failed(body_id)

    return body_id, result


def resolve_move_face(
    part: Part, feature: MoveFaceFeature, excluded_feature_ids: frozenset[str] = frozenset()
) -> tuple[str, TopoDS_Shape]:
    """Fresh entry point for the router's create/update validation - mirrors
    `resolve_fillet`'s own self-exclusion shape exactly (Move Face modifies
    a Body in place, so re-resolving against its own prior output would
    double-apply it)."""
    bodies = compute_part_bodies(part, excluded_feature_ids | {feature.id})
    return resolve_move_face_from_bodies(part, bodies, feature, excluded_feature_ids | {feature.id})
