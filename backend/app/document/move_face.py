"""OCCT geometry construction for MoveFaceFeature (Direct Editing family,
fifth/last entry - see `docs/direct-editing-scope.md`) - moves every face
named in `face_refs` (1+, all sharing one Body) by one of three mutually-
exclusive modes, and heals the adjacent faces by construction. **Two
different OCCT techniques, one per mode group** - not one shared technique
generalized, because the two groups' own movement models are genuinely
different operations, confirmed via two separate real-pythonocc-core
spikes (see `docs/direct-editing-scope.md`'s "Spike findings (2026-09-03)"
section and its follow-up addenda for the full numbers):

- **`offset_distance` mode**: OCCT's own per-face variable-offset engine,
  `BRepOffset_MakeOffset` (`Initialize` with a global offset of `0.0` so
  every untouched face of the Body stays put, then one `SetOffsetOnFace`
  call per face in `face_refs` - all with the identical, shared
  `offset_distance` value, per this family's own "list of refs, one
  shared param" convention - then one `MakeOffsetShape()` call). This is
  a genuine, general-purpose face-offset solver (unlike the technique
  below) - confirmed working for non-planar (cylindrical/conical) faces,
  2+ faces moved simultaneously in one call, and offsets large enough to
  fully consume a neighbouring feature while still healing correctly -
  all v1 never attempted. Requires the target Body's own coincident/
  coplanar faces (most commonly, wherever a Boss lands flush on an
  existing face) to already be merged via `ShapeUpgrade_UnifySameDomain`
  - confirmed reliably failing (a silent null `Shape()`, no exception, no
  reported error - see the fail-closed contract below) on that exact
  topology otherwise, even for a trivially small offset nowhere near
  large enough to be a genuine "neighbour-consuming" case. This is why
  `app.document.extrude._apply_feature_to_bodies`'s own `unify` step
  exists and defaults on for the real (non-coarse) body-computation path
  - `Initialize`'s own join type must be `GeomAbs_Intersection`, not the
  default `GeomAbs_Arc` (confirmed failing outright on a plain box in the
  same spike).
- **`delta`/`direction_ref`+`direction_distance` modes**: v1's own
  original technique, generalized in V3 from a single face to a *rigid
  group* of 1+ connected faces - sweep the whole group (a `TopoDS_
  Compound` of every face in `face_refs`) along the movement vector into
  a solid prism (`BRepPrimAPI_MakePrism` - the same primitive `app.
  document.split` already uses for its own oversized-block cutting
  tools, and general enough to sweep a multi-face compound, not just one
  face - confirmed via spike), then fuse it into the Body (vector points
  outward, adding material) or cut it out (points inward, removing
  material) via `BRepAlgoAPI_Fuse`/`BRepAlgoAPI_Cut`. This is NOT a
  "true" synchronous-modeling face-offset solver - it works because, for
  a *connected group of faces sharing one rigid movement* being pushed
  to a genuinely new, non-overlapping position, "the material swept
  between the group's old and new position" is exactly this prism -
  confirmed via spike for a planar cap plus its own cylindrical blend
  fillets (V3's own motivating case: on-device feedback, "translate of
  multiple faces and non-planar faces e.g. flat face and its fillets to
  make a filleted part taller" - imported/non-sketch geometry has no
  Sketch to fall back to editing, so Direct Editing is its only path to
  this).

  **Still deliberately narrower than `offset_distance` mode in two real
  ways, confirmed via spike, not oversights:**
  1. Every face in the group must be planar, cylindrical, or conical
     (same set `offset_distance` mode accepts) - `BRepPrimAPI_MakePrism`
     genuinely produces a degenerate (invalid, ~zero-volume) prism when
     swept along a vector with a *tangential* (sideways, non-normal)
     component relative to a curved face's own local generatrix -
     confirmed directly: sweeping a lone cylindrical hole wall sideways,
     even by as little as 0.01 units, reports `BRepCheck_Analyzer`
     invalid. This is why the group technique above only works when the
     curved members are moving *together with* a driving flat face to a
     new position (their own individual sweep is well-behaved because
     the group's shared vector has a normal-dominant component relative
     to *them*, not because curved faces are unrestricted) - repositioning
     a lone curved face by an arbitrary vector (e.g. relocating a hole's
     own X/Y position) remains out of scope; see `_resolve_move_face_
     group`'s own doc comment for the concrete fail-closed check this
     produces.
  2. The group must contain at least one planar face - it anchors the
     Fuse-vs-Cut sign decision (see below). Voting per-face across the
     group's own curved members was tried and confirmed unreliable via
     spike (a fillet face's own local outward normal, sampled at its own
     centroid, disagrees with the group's actual overall movement
     direction more often than not - a curved face's "outward" is only
     ever locally, not globally, defined) - one designated planar
     reference face is the only sign source confirmed correct.

The movement vector's sign relative to the group's own planar reference
face's *outward* normal (accounting for `TopoDS_Face.Orientation()` - a
`REVERSED` face's own `BRepAdaptor_Surface` plane normal points the wrong
way and must be flipped) decides Fuse (material added) vs. Cut (material
removed) for the `delta`/`direction_ref` technique - a vector with (near-)
zero component along that normal is rejected as degenerate (nothing for
this technique to meaningfully do - see `_move_face_failed`).
`offset_distance` mode's own sign convention is `BRepOffset_MakeOffset`'s
own, already outward-normal-relative by construction - confirmed matching
the exact same sign convention via spike, so `MoveFaceFeature.
offset_distance`'s documented positive-is-outward meaning needs no
per-mode special-casing.

Fail-closed contract, `offset_distance` mode: `BRepOffset_MakeOffset`'s
own `IsDone()`/lack of a reported `Error()` are confirmed (via spike) NOT
sufficient success signals on their own - an offset large enough to fully
consume *and overshoot past* a neighbouring feature reports `IsDone=True,
Error=BRepOffset_NoError` yet returns a null `Shape()`. This module checks
`Shape() is not None and not Shape().IsNull()` in addition to `IsDone()`,
mirroring `delete_face.py`'s own "don't trust the obvious success signal
alone" discipline for a different underlying reason.

Fail-closed contract, `delta`/`direction_ref` modes: unchanged from v1 for
the actual Fuse/Cut step - this module makes no attempt to detect "this
offset is large enough to consume a neighbouring face" ahead of time for
this technique - `BRepAlgoAPI_Fuse`/`BRepAlgoAPI_Cut` either produce a
valid result or don't (`BRepCheck_Analyzer`/an empty-or-negative-volume
result both fail closed), so an offset that goes wrong surfaces as the
same structured 422 a geometrically-impossible Fillet radius already
does, not a distinct predictive check - `offset_distance` mode's own
neighbour-consuming support is a real capability difference between the
two techniques, not just an unimplemented check on this side. V3 adds one
new check *before* that step, confirmed necessary via spike: the prism
itself (`BRepPrimAPI_MakePrism`'s own result, ahead of the boolean) is
now checked with `BRepCheck_Analyzer` too - `BRepAlgoAPI_Cut` against a
degenerate (invalid, ~zero-volume) prism was confirmed to silently
succeed as a **no-op** (a "valid" result identical to the untouched
input, passing every existing post-boolean check) rather than erroring,
which the post-boolean-only checks alone would never have caught.

This module needs `compute_part_bodies`/`resolve_subshape_from_bodies` from
extrude.py at module level, so (mirroring app.document.chamfer/fillet's own
identical circular-import workaround) extrude.py imports this module back
via a function-local import inside `_apply_feature_to_bodies` instead.
"""

from fastapi import HTTPException
from OCC.Core.BRep import BRep_Builder
from OCC.Core.BRepAdaptor import BRepAdaptor_Surface
from OCC.Core.BRepAlgoAPI import BRepAlgoAPI_Cut, BRepAlgoAPI_Fuse
from OCC.Core.BRepCheck import BRepCheck_Analyzer
from OCC.Core.BRepGProp import brepgprop
from OCC.Core.BRepOffset import BRepOffset_MakeOffset, BRepOffset_Skin
from OCC.Core.BRepPrimAPI import BRepPrimAPI_MakePrism
from OCC.Core.GeomAbs import GeomAbs_Cone, GeomAbs_Cylinder, GeomAbs_Intersection, GeomAbs_Plane
from OCC.Core.gp import gp_Vec
from OCC.Core.GProp import GProp_GProps
from OCC.Core.TopAbs import TopAbs_FACE, TopAbs_REVERSED
from OCC.Core.TopExp import TopExp_Explorer
from OCC.Core.TopoDS import TopoDS_Compound, TopoDS_Face, TopoDS_Shape, topods

from app.document.extrude import compute_part_bodies, resolve_subshape_from_bodies
from app.document.models import MoveFaceFeature, Part, SubShapeType
from app.document.pattern import direction_vector

# Below this fraction of the movement vector's own magnitude, its component
# along the face's outward normal is treated as "no meaningful perpendicular
# movement" - see `_movement_vector`'s own doc comment. `delta`/
# `direction_ref` modes only.
_MIN_NORMAL_COMPONENT_RATIO = 1e-6

# `BRepOffset_MakeOffset.Initialize`'s own coincidence tolerance - the exact
# value confirmed working across every case in both V2 spikes (planar,
# cylindrical, conical, multi-face, neighbour-consuming). `offset_distance`
# mode only.
_OFFSET_TOLERANCE = 1e-6

# V3: shared by every mode now - `offset_distance` (via `BRepOffset_
# MakeOffset`) and `delta`/`direction_ref` (via `BRepPrimAPI_MakePrism` on
# the group, see this module's own top docstring) were confirmed via spike
# to tolerate the identical surface-type set.
_SUPPORTED_SURFACE_TYPES = (GeomAbs_Plane, GeomAbs_Cylinder, GeomAbs_Cone)


def _move_face_not_found(body_id: str) -> HTTPException:
    return HTTPException(status_code=422, detail={"type": "missing_reference", "body_id": body_id})


def _move_face_mixed_body_selection(body_ids: set[str]) -> HTTPException:
    """V2: every entry in `face_refs` must resolve to the same Body -
    mirrors `app.document.fillet._mixed_body_selection`'s identical
    constraint on `edge_refs`, same reasoning (this module's own
    techniques, like `BRepFilletAPI_MakeFillet`, each operate on one solid
    at a time)."""
    return HTTPException(
        status_code=422,
        detail={"type": "mixed_body_selection", "body_ids": sorted(body_ids)},
    )


def _move_face_unsupported_surface_type(body_id: str) -> HTTPException:
    """V3: shared by every mode now - `_SUPPORTED_SURFACE_TYPES` (planar,
    cylindrical, conical, confirmed via spike) applies identically to
    `offset_distance`'s own per-face technique and `delta`/`direction_
    ref`'s own group-sweep technique alike; anything else (spherical,
    toroidal, free-form/B-spline, ...) is rejected here for either."""
    return HTTPException(
        status_code=422, detail={"type": "unsupported_surface_type", "body_id": body_id}
    )


def _move_face_group_requires_planar_reference(body_id: str) -> HTTPException:
    """`delta`/`direction_ref` modes only - the group named in `face_refs`
    has no planar face to anchor the Fuse-vs-Cut sign decision (see this
    module's own top docstring for why per-face voting across the group's
    curved members was tried and rejected - confirmed unreliable via
    spike). A group of curved faces alone (e.g. picking just a fillet's
    own blend faces, without the flat face they blend into) has no other
    well-defined single "outward" direction for this technique to anchor
    on."""
    return HTTPException(
        status_code=422,
        detail={"type": "move_face_group_requires_planar_reference", "body_id": body_id},
    )


def _move_face_failed(body_id: str) -> HTTPException:
    """The movement vector had no meaningful component along the face's
    own outward normal (`delta`/`direction_ref` modes), or the resulting
    geometry didn't complete/produced a degenerate result (either
    technique) - see this module's own top-level docstring. 422, matching
    every other structured geometry-failure error in this codebase."""
    return HTTPException(status_code=422, detail={"type": "move_face_failed", "body_id": body_id})


def _move_face_null_result(body_id: str) -> HTTPException:
    """`offset_distance` mode only - `BRepOffset_MakeOffset` reported
    `IsDone()` with no error, yet `Shape()` was null (confirmed via spike:
    the signature of an offset large enough to fully consume *and
    overshoot past* a neighbouring feature). Distinct from `move_face_
    failed` since `IsDone()`/`BRepCheck_Analyzer` genuinely don't apply
    here - there is no shape to check."""
    return HTTPException(status_code=422, detail={"type": "move_face_null_result", "body_id": body_id})


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


def _compound_of(faces: list[TopoDS_Face]) -> TopoDS_Compound:
    """V3: bundles `faces` into one `TopoDS_Compound` - `BRepPrimAPI_
    MakePrism` accepts any `TopoDS_Shape` (confirmed via spike: sweeping a
    compound of several connected faces produces the same kind of prism
    solid sweeping one face already did for v1, not something restricted
    to a lone Face), so this is the only change needed to generalize
    `delta`/`direction_ref`'s own technique from one face to a rigid
    group of 1+."""
    compound = TopoDS_Compound()
    builder = BRep_Builder()
    builder.MakeCompound(compound)
    for face in faces:
        builder.Add(compound, face)
    return compound


def _outward_normal(face: TopoDS_Face) -> gp_Vec:
    """`face`'s own plane normal, corrected for `Orientation()` - a
    `REVERSED` face's raw `BRepAdaptor_Surface` normal points *into* the
    solid, not out of it (confirmed via the real pythonocc-core spike this
    module's own docstring references). `delta`/`direction_ref` modes
    only - `offset_distance` mode's own `BRepOffset_MakeOffset` handles
    its per-face outward-normal convention internally."""
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
    body_id: str,
) -> gp_Vec:
    """The world-space vector `feature` moves its whole face group by, for
    `delta`/`direction_ref` mode (the only two modes that still call this
    - `offset_distance` mode's own signed scalar goes straight to
    `SetOffsetOnFace`, no vector construction needed)."""
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
    raise _move_face_failed(body_id)


def _resolve_move_face_offset(
    body_id: str,
    source: TopoDS_Shape,
    faces: list[TopoDS_Face],
    offset_distance: float,
) -> TopoDS_Shape:
    """`offset_distance` mode's own technique - see this module's top
    docstring. `offset_distance` is applied identically to every face in
    `faces` (this family's own "list of refs, one shared param"
    convention, matching `FilletFeature.radius`)."""
    for face in faces:
        if BRepAdaptor_Surface(face, True).GetType() not in _SUPPORTED_SURFACE_TYPES:
            raise _move_face_unsupported_surface_type(body_id)

    offset_maker = BRepOffset_MakeOffset()
    offset_maker.Initialize(
        source,
        0.0,
        _OFFSET_TOLERANCE,
        BRepOffset_Skin,
        False,
        False,
        GeomAbs_Intersection,
        False,
        False,
    )
    for face in faces:
        offset_maker.SetOffsetOnFace(face, offset_distance)
    offset_maker.MakeOffsetShape()
    result = offset_maker.Shape()

    if not offset_maker.IsDone() or result is None or result.IsNull():
        raise _move_face_null_result(body_id)
    if not BRepCheck_Analyzer(result).IsValid():
        raise _move_face_failed(body_id)
    if _face_count(result) == 0 or _volume(result) <= 0.0:
        raise _move_face_failed(body_id)

    return result


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
    body_ids = {ref.body_id for ref in feature.face_refs}
    if len(body_ids) != 1:
        raise _move_face_mixed_body_selection(body_ids)
    body_id = next(iter(body_ids))
    source = bodies.get(body_id)
    if source is None:
        raise _move_face_not_found(body_id)

    faces: list[TopoDS_Face] = []
    for ref in feature.face_refs:
        if ref.shape_type != SubShapeType.FACE:
            raise _move_face_not_found(body_id)
        faces.append(topods.Face(resolve_subshape_from_bodies(bodies, ref)))

    if feature.offset_distance is not None:
        result = _resolve_move_face_offset(body_id, source, faces, feature.offset_distance)
        return body_id, result

    # delta / direction_ref modes - V3: a rigid group of 1+ connected
    # faces, generalized from v1's single-face-only technique (see this
    # module's own top docstring for the full reasoning and the two real
    # restrictions this still carries). Every face must be one of the
    # surface types this family's own techniques are confirmed to handle;
    # the group must contain at least one planar face to anchor the sign
    # decision below.
    reference_face: TopoDS_Face | None = None
    for face in faces:
        surface_type = BRepAdaptor_Surface(face, True).GetType()
        if surface_type not in _SUPPORTED_SURFACE_TYPES:
            raise _move_face_unsupported_surface_type(body_id)
        if surface_type == GeomAbs_Plane and reference_face is None:
            reference_face = face
    if reference_face is None:
        raise _move_face_group_requires_planar_reference(body_id)

    outward_normal = _outward_normal(reference_face)
    vec = _movement_vector(part, bodies, feature, excluded_feature_ids, outward_normal, body_id)

    magnitude = vec.Magnitude()
    if magnitude < 1e-9:
        raise _move_face_failed(body_id)
    normal_component = vec.Dot(outward_normal)
    if abs(normal_component) < magnitude * _MIN_NORMAL_COMPONENT_RATIO:
        raise _move_face_failed(body_id)

    group = _compound_of(faces)
    prism = BRepPrimAPI_MakePrism(group, vec).Shape()
    # V3: confirmed via spike - a degenerate sweep (any curved face moving
    # with a tangential/sideways component relative to its own local
    # generatrix) can otherwise slip through undetected: `BRepAlgoAPI_Cut`
    # against an invalid, ~zero-volume prism silently succeeds as a no-op,
    # which the post-boolean checks below would never catch on their own
    # (a "valid" result identical to the untouched input passes every one
    # of them). Checking the prism itself first closes that gap.
    if not BRepCheck_Analyzer(prism).IsValid():
        raise _move_face_failed(body_id)

    boolean_op = BRepAlgoAPI_Fuse if normal_component > 0 else BRepAlgoAPI_Cut
    result = boolean_op(source, prism).Shape()

    # Same silent-null gotcha `_resolve_move_face_offset` already guards
    # against (see this module's own top docstring) - a boolean op can
    # report success with a null `Shape()`, which `BRepCheck_Analyzer`
    # itself cannot even be constructed against.
    if result is None or result.IsNull():
        raise _move_face_failed(body_id)
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
