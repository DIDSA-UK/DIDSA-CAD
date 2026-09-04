"""OCCT geometry construction for MoveFaceFeature (Direct Editing family,
fifth/last entry - see `docs/direct-editing-scope.md`) - moves every face
named in `face_refs` (1+, all sharing one Body) by one of three mutually-
exclusive modes, and heals the adjacent faces by construction. **Three
different OCCT techniques** (not one shared technique generalized, because
the underlying movement models are genuinely different operations,
confirmed via real-pythonocc-core spikes each time - see `docs/direct-
editing-scope.md`'s "Spike findings (2026-09-03)" section and its V3/V4
follow-ups for the full numbers) - `offset_distance` mode always uses the
first; `delta`/`direction_ref` dispatch between the second and third based
on whether the picked group contains a planar face:

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

  **Still deliberately narrower than `offset_distance` mode in one real
  way, confirmed via spike, not an oversight:** every face in the group
  must be planar, cylindrical, or conical (same set `offset_distance`
  mode accepts) - `BRepPrimAPI_MakePrism` genuinely produces a degenerate
  (invalid, ~zero-volume) prism when swept along a vector with a
  *tangential* (sideways, non-normal) component relative to a curved
  face's own local generatrix - confirmed directly: sweeping a lone
  cylindrical hole wall sideways, even by as little as 0.01 units, reports
  `BRepCheck_Analyzer` invalid. This is why this technique only works when
  the curved members are moving *together with* a driving flat face to a
  new position (their own individual sweep is well-behaved because the
  group's shared vector has a normal-dominant component relative to
  *them*, not because curved faces are unrestricted) - a group with **no**
  planar face dispatches to the third technique below instead, rather than
  being rejected outright.
- **`delta`/`direction_ref`, coaxial-reposition sub-case (V4)**: used
  instead of the sweep technique above when the picked group contains no
  planar face - by construction, every face in it is already confirmed
  cylindrical/conical. This is the fix for the gap the sweep technique's
  own restriction above leaves open: repositioning a hole/boss (translate
  its whole cylindrical/conical wall, and any coaxial tip/counterbore
  faces, to a new position) - on-device feedback, "when the cylindrical
  face of a hole is selected, translate should move the position of the
  hole." Reconstructs the feature's own canonical solid-of-revolution
  directly from the picked face(s)' analytic geometry
  (`BRepAdaptor_Surface.Cylinder()`/`.Cone()`) - once at the original
  position, once at the target - then `BRepAlgoAPI_Fuse`/`Cut`s it in and
  out of the Body, rather than sweeping the picked faces' own literal
  trimmed profile (which is exactly what's degenerate for a lone curved
  face, per the restriction above). Two structured checks, both confirmed
  necessary via spike, gate this technique:
  1. **Axis coincidence**: every face's own fitted axis (`_face_axis`)
     must coincide with the group's own shared reference axis (parallel
     direction and near-zero perpendicular line distance -
     `_axes_coincide`) - otherwise `_move_face_group_axis_mismatch`
     (most likely two different holes/bosses picked together by
     mistake).
  2. **Coaxial-chain completeness** (`_coaxial_group_is_complete`): every
     coaxial cylindrical/conical neighbour of a picked face, found by
     walking the Body's own edge-to-face adjacency (NOT by point-
     classification - confirmed via spike a point probed just past a
     group's own axial extent cannot distinguish a through-hole's own
     legitimately open end from a hidden void because a real neighbour,
     e.g. a blind hole's own conical tip, was left out of `face_refs` -
     both report `TopAbs_OUT`), must already be in the group - otherwise
     `_move_face_group_incomplete_coaxial_chain`. A planar or non-coaxial
     neighbour (a flat end cap, an unrelated wall, a fillet blend at a
     boss/hole's own base) is a legitimate natural boundary and does not
     force inclusion.

  Fuse-vs-Cut order is **not** the sign-relative-to-one-normal decision
  the sweep technique above uses (there is no single reference face's own
  normal here) - confirmed via spike that a *fixed* Fuse-then-Cut order is
  actively wrong for a boss (Fusing an already-solid boss's own
  reconstructed primitive back onto itself is a geometric no-op, so a
  fixed order would leave the original boss in place *and* cut a spurious
  hole at the target, rather than relocating it). Instead, a point at the
  group's own axial-extent midpoint is classified against the *original*
  Body via `BRepClass3d_SolidClassifier` - `TopAbs_IN` (boss: Cut original,
  then Fuse target) vs. `TopAbs_OUT` (hole: Fuse original, then Cut
  target). This is a different, more robust technique than the sweep
  technique's own per-face-normal-voting sign mechanism above (already
  found unreliable for curved faces) - it sidesteps that finding rather
  than reopening it, by classifying against real solid material instead of
  a face's own local normal.

  A cone's `BRepAdaptor_Surface` `V` parameter is a slant distance along
  the generatrix, **not** an axial coordinate the way a cylinder's is
  (confirmed via spike by direct point evaluation against a hand-built
  cone) - conflating the two, or reusing the *different*, unrelated
  `1/cos(theta)` relationship `offset_distance` mode's own cone-growth
  nuance uses, gave a confirmed-wrong ~7% volume error in this module's
  own spike. True axial offset at `V` is `V * cos(theta)`, true radius at
  `V` is `ref_radius + V * sin(theta)` (`_face_axial_range`/
  `_face_primitive`).

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

Fail-closed contract, `delta`/`direction_ref`'s coaxial-reposition
sub-case (V4): the two structured pre-checks above (axis coincidence,
coaxial-chain completeness) run before any geometry is built at all - the
coaxial-chain check specifically exists because the *late* checks below
would not have caught its failure mode on their own (confirmed via spike:
reconstructing from an incomplete coaxial group, e.g. a blind hole's own
wall without its conical tip, produces a `BRepCheck_Analyzer`-valid
result with a genuine internal cavity where the tip used to be - a
silently *wrong*, not merely invalid, result). Beyond those two, every
intermediate shape (`fill`, `target`, the first boolean's own result) is
checked with the same `is None`/`IsNull()`/`BRepCheck_Analyzer` battery
the sweep technique's own final result already used, not just the
technique's own final result - mirrors this module's own hard-won "check
before you build on it, not just at the end" discipline throughout.

This module needs `compute_part_bodies`/`resolve_subshape_from_bodies` from
extrude.py at module level, so (mirroring app.document.chamfer/fillet's own
identical circular-import workaround) extrude.py imports this module back
via a function-local import inside `_apply_feature_to_bodies` instead.
"""

import math

from fastapi import HTTPException
from OCC.Core.BRep import BRep_Builder
from OCC.Core.BRepAdaptor import BRepAdaptor_Surface
from OCC.Core.BRepAlgoAPI import BRepAlgoAPI_Cut, BRepAlgoAPI_Fuse
from OCC.Core.BRepBuilderAPI import BRepBuilderAPI_Transform
from OCC.Core.BRepCheck import BRepCheck_Analyzer
from OCC.Core.BRepClass3d import BRepClass3d_SolidClassifier
from OCC.Core.BRepGProp import brepgprop
from OCC.Core.BRepOffset import BRepOffset_MakeOffset, BRepOffset_Skin
from OCC.Core.BRepPrimAPI import BRepPrimAPI_MakeCone, BRepPrimAPI_MakeCylinder, BRepPrimAPI_MakePrism
from OCC.Core.GeomAbs import GeomAbs_Cone, GeomAbs_Cylinder, GeomAbs_Intersection, GeomAbs_Plane
from OCC.Core.gp import gp_Ax1, gp_Ax2, gp_Pnt, gp_Trsf, gp_Vec
from OCC.Core.GProp import GProp_GProps
from OCC.Core.TopAbs import TopAbs_EDGE, TopAbs_FACE, TopAbs_IN, TopAbs_REVERSED
from OCC.Core.TopExp import TopExp_Explorer, topexp
from OCC.Core.TopoDS import TopoDS_Compound, TopoDS_Face, TopoDS_Shape, topods
from OCC.Core.TopTools import TopTools_IndexedDataMapOfShapeListOfShape

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

# V4: two independently-fit `gp_Cylinder`/`gp_Cone` axes are treated as "the
# same axis" when their directions are parallel within this angle (radians)
# AND the perpendicular distance between the two lines is below
# `_AXIS_LINEAR_TOLERANCE` - confirmed via spike that a real wall+tip pair
# (the same hole, two different faces) agrees to *exactly* 0.0 on both
# measures (no floating-point noise at all in this kernel), and that a
# genuinely different, deliberately-nearby hole disagrees by many orders of
# magnitude more than this - fails closed (rejects) on anything in between,
# matching this module's own house style throughout. `delta`/`direction_ref`
# coaxial-reposition sub-case only.
_AXIS_ANGULAR_TOLERANCE = 1e-4
_AXIS_LINEAR_TOLERANCE = 1e-4


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


def _move_face_group_axis_mismatch(body_id: str) -> HTTPException:
    """V4: `delta`/`direction_ref`'s coaxial-reposition sub-case only - the
    group named in `face_refs` contains 2+ cylindrical/conical faces whose
    own fitted axes don't coincide (see `_AXIS_ANGULAR_TOLERANCE`/
    `_AXIS_LINEAR_TOLERANCE`'s own doc comment) - most likely two different
    holes/bosses picked together by mistake, rather than one feature's own
    wall+tip/stepped-diameter faces. Distinct from `_move_face_group_
    requires_planar_reference` (a *complete* single-axis group with no
    planar anchor) - the fix here is "pick one feature's faces only", not
    "add a face"."""
    return HTTPException(
        status_code=422, detail={"type": "move_face_group_axis_mismatch", "body_id": body_id}
    )


def _move_face_group_incomplete_coaxial_chain(body_id: str) -> HTTPException:
    """V4: `delta`/`direction_ref`'s coaxial-reposition sub-case only - a
    coaxial cylindrical/conical neighbour of a picked face (found by
    walking the Body's own edge-to-face adjacency, not by point-probing -
    see `_resolve_move_face_coaxial_reposition`'s own doc comment for why
    point-probing was tried and rejected) isn't itself in `face_refs`. The
    concrete case this catches: a blind hole with a conical drill-point tip,
    where only the cylindrical wall was picked - reconstructing from the
    wall alone would silently leave the tip's own void unfilled (confirmed
    via spike: a real internal cavity, passing every existing fail-closed
    check). The fix is "add the missing coaxial face(s) to `face_refs`",
    distinct from `_move_face_group_axis_mismatch`'s own "pick fewer
    faces" fix."""
    return HTTPException(
        status_code=422,
        detail={"type": "move_face_group_incomplete_coaxial_chain", "body_id": body_id},
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
    body_id: str,
) -> gp_Vec:
    """The world-space vector `feature` moves its whole face group by, for
    `delta`/`direction_ref` mode (the only two modes that still call this
    - `offset_distance` mode's own signed scalar goes straight to
    `SetOffsetOnFace`, no vector construction needed). V4: also used by the
    coaxial-reposition sub-case, which has no single reference face's own
    normal to relate this vector to (see `_resolve_move_face_coaxial_
    reposition`'s own hole-vs-boss classifier instead)."""
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


# --- V4: reposition a lone coaxial cylindrical/conical face group ----------
# (`delta`/`direction_ref`'s "no planar reference" sub-case - see this
# module's own top docstring for the framing and `docs/direct-editing-
# scope.md`'s "Move Face V4" section for the full spike narrative). Rather
# than sweeping the picked faces' own literal profile (the technique above,
# which cannot handle a lone curved face moving sideways - confirmed
# degenerate via spike), this reconstructs the feature's own canonical
# solid-of-revolution directly from its analytic geometry, once at the
# original position and once at the target, then Fuse/Cut it in and out of
# the Body - the same "auxiliary swept volume, then a boolean op" category
# every technique in this module already uses, just built differently.


def _face_axis(face: TopoDS_Face) -> gp_Ax1:
    """`face`'s own fitted cylinder/cone axis - caller must already have
    confirmed `face`'s surface type is one of the two (this module's own
    `_SUPPORTED_SURFACE_TYPES` loop always runs first)."""
    surf = BRepAdaptor_Surface(face, True)
    if surf.GetType() == GeomAbs_Cylinder:
        return surf.Cylinder().Axis()
    return surf.Cone().Axis()


def _axes_coincide(a: gp_Ax1, b: gp_Ax1) -> bool:
    """Whether `a`/`b` are the same infinite line (parallel directions -
    same or opposite pointing, both confirmed via spike to occur between a
    real hole's own wall/tip - AND a near-zero perpendicular distance
    between them) - see `_AXIS_ANGULAR_TOLERANCE`/`_AXIS_LINEAR_TOLERANCE`'s
    own doc comment for the confirmed-via-spike tolerance reasoning."""
    da, db = a.Direction(), b.Direction()
    cross = gp_Vec(da.X(), da.Y(), da.Z()).Crossed(gp_Vec(db.X(), db.Y(), db.Z()))
    if cross.Magnitude() > _AXIS_ANGULAR_TOLERANCE:
        return False
    la, lb = a.Location(), b.Location()
    delta = gp_Vec(lb.X() - la.X(), lb.Y() - la.Y(), lb.Z() - la.Z())
    perpendicular = delta.Crossed(gp_Vec(da.X(), da.Y(), da.Z()))
    return perpendicular.Magnitude() < _AXIS_LINEAR_TOLERANCE


def _axial_offset(reference_axis: gp_Ax1, point: gp_Pnt) -> float:
    """Signed distance from `reference_axis`'s own location to `point`,
    projected onto `reference_axis`'s own direction - converts a coaxial
    face's own independently-fitted axis location into the group's shared
    canonical coordinate (confirmed via spike this is required: two faces
    of the same real hole fit axes at *different* location points along
    the identical line, not the same point)."""
    loc = reference_axis.Location()
    direction = reference_axis.Direction()
    delta = gp_Vec(point.X() - loc.X(), point.Y() - loc.Y(), point.Z() - loc.Z())
    return delta.Dot(gp_Vec(direction.X(), direction.Y(), direction.Z()))


def _point_along(reference_axis: gp_Ax1, axial: float) -> gp_Pnt:
    loc = reference_axis.Location()
    direction = reference_axis.Direction()
    return gp_Pnt(
        loc.X() + direction.X() * axial,
        loc.Y() + direction.Y() * axial,
        loc.Z() + direction.Z() * axial,
    )


def _face_axial_sign_and_offset(face: TopoDS_Face, reference_axis: gp_Ax1) -> tuple[float, float]:
    """`(sign, offset)` converting `face`'s own V-parameter into
    `reference_axis`'s own shared coordinate frame: `reference_axis`'s
    own axial coordinate = `offset + sign * V`. A face's own fitted axis
    direction can, in principle, point either the same or the opposite way
    along the shared line relative to `reference_axis` (both confirmed via
    spike to occur harmlessly between a real hole's own wall/tip in
    practice, but not guaranteed by OCCT in general) - `sign` corrects for
    that so the reported axial range is never accidentally inverted."""
    face_axis = _face_axis(face)
    sign = 1.0 if gp_Vec(*reference_axis.Direction().Coord()).Dot(
        gp_Vec(*face_axis.Direction().Coord())
    ) >= 0.0 else -1.0
    offset = _axial_offset(reference_axis, face_axis.Location())
    return sign, offset


def _face_axial_range(face: TopoDS_Face, reference_axis: gp_Ax1) -> tuple[float, float]:
    """`(axial_at_vmin, axial_at_vmax)` of `face`'s own real
    (already-trimmed) parametric extent, converted into `reference_axis`'s
    own shared frame - NOT sorted (deliberately: `_face_primitive` pairs
    each value with the matching radius before sorting itself; callers
    that only need the overall span, like `_group_axial_midpoint`, can use
    `min`/`max` directly). GeomAbs_Cone's own `V` is a slant distance along
    the generatrix, NOT an axial coordinate the way a cylinder's is
    (confirmed via spike by direct point evaluation against a hand-built
    cone - conflating the two, or reusing the *different*, unrelated
    `1/cos(theta)` relationship `offset_distance` mode's own cone-growth
    nuance uses, gave a confirmed-wrong ~7% volume error in this module's
    own spike): true axial offset at `V` is `V * cos(theta)`."""
    surf = BRepAdaptor_Surface(face, True)
    sign, offset = _face_axial_sign_and_offset(face, reference_axis)
    vmin, vmax = surf.FirstVParameter(), surf.LastVParameter()
    if surf.GetType() == GeomAbs_Cylinder:
        return offset + sign * vmin, offset + sign * vmax
    theta = surf.Cone().SemiAngle()
    return offset + sign * vmin * math.cos(theta), offset + sign * vmax * math.cos(theta)


def _face_primitive(face: TopoDS_Face, reference_axis: gp_Ax1) -> TopoDS_Shape:
    """Reconstructs the one `BRepPrimAPI_MakeCylinder`/`MakeCone` matching
    `face`'s own radius/semi-angle and real axial extent (`_face_axial_
    range`), expressed in `reference_axis`'s own shared coordinate frame -
    built at the ORIGINAL position only; the caller translates a copy for
    the target position via `BRepBuilderAPI_Transform` rather than
    rebuilding (mirrors the confirmed-via-spike approach, cheaper than
    re-deriving per-face geometry twice)."""
    surf = BRepAdaptor_Surface(face, True)
    axial_at_vmin, axial_at_vmax = _face_axial_range(face, reference_axis)

    if surf.GetType() == GeomAbs_Cylinder:
        radius = surf.Cylinder().Radius()
        axial_min, axial_max = sorted((axial_at_vmin, axial_at_vmax))
        origin = _point_along(reference_axis, axial_min)
        return BRepPrimAPI_MakeCylinder(
            gp_Ax2(origin, reference_axis.Direction()), radius, axial_max - axial_min
        ).Shape()

    # See `ref_radius + V * sin(theta)`'s own doc comment (`_face_axial_
    # range`) for why this is not the `offset_distance`-mode cone formula.
    cone = surf.Cone()
    ref_radius = cone.RefRadius()
    theta = cone.SemiAngle()
    vmin, vmax = surf.FirstVParameter(), surf.LastVParameter()
    radius_at_vmin = ref_radius + vmin * math.sin(theta)
    radius_at_vmax = ref_radius + vmax * math.sin(theta)
    if axial_at_vmin <= axial_at_vmax:
        axial_min, axial_max = axial_at_vmin, axial_at_vmax
        radius_min, radius_max = radius_at_vmin, radius_at_vmax
    else:
        axial_min, axial_max = axial_at_vmax, axial_at_vmin
        radius_min, radius_max = radius_at_vmax, radius_at_vmin
    origin = _point_along(reference_axis, axial_min)
    return BRepPrimAPI_MakeCone(
        gp_Ax2(origin, reference_axis.Direction()), radius_min, radius_max, axial_max - axial_min
    ).Shape()


def _group_fill_solid(faces: list[TopoDS_Face], reference_axis: gp_Ax1) -> TopoDS_Shape:
    """One `_face_primitive` per face in `faces`, `BRepAlgoAPI_Fuse`d into
    one solid - the trivial one-element case for a lone wall, and the
    wall+tip/stepped-diameter-counterbore case identically (confirmed via
    spike to generalize past exactly two faces with no new issues)."""
    combined = _face_primitive(faces[0], reference_axis)
    for face in faces[1:]:
        combined = BRepAlgoAPI_Fuse(combined, _face_primitive(face, reference_axis)).Shape()
        if not BRepCheck_Analyzer(combined).IsValid():
            raise ValueError("degenerate coaxial group fill solid")
    return combined


def _coaxial_group_is_complete(source: TopoDS_Shape, faces: list[TopoDS_Face]) -> bool:
    """Whether every coaxial cylindrical/conical neighbour of `faces` (on
    the whole Body, not just within the group) is itself already in
    `faces` - confirmed via spike this must be a topological adjacency
    check, not a point-classification probe: probing just past a group's
    own axial extent cannot distinguish a through-hole's own legitimately
    open end (also reports `TopAbs_OUT`) from a hidden void because a
    coaxial neighbour (e.g. a blind hole's own conical tip) was left out of
    `face_refs` (confirmed via spike to also report `TopAbs_OUT` - the two
    cases are indistinguishable by point-probing alone). A planar or
    non-coaxial neighbour (a flat end cap, an unrelated wall, a fillet
    blend at a boss/hole's own base) is a legitimate natural boundary and
    does not force inclusion - confirmed via spike this correctly leaves
    ordinary single-face repositioning unaffected even when such faces are
    present."""
    edge_face_map = TopTools_IndexedDataMapOfShapeListOfShape()
    topexp.MapShapesAndAncestors(source, TopAbs_EDGE, TopAbs_FACE, edge_face_map)
    reference_axis = _face_axis(faces[0])

    for face in faces:
        exp = TopExp_Explorer(face, TopAbs_EDGE)
        while exp.More():
            edge = exp.Current()
            if edge_face_map.Contains(edge):
                for ancestor in edge_face_map.FindFromKey(edge):
                    ancestor_face = topods.Face(ancestor)
                    if any(ancestor_face.IsSame(member) for member in faces):
                        continue
                    ancestor_type = BRepAdaptor_Surface(ancestor_face, True).GetType()
                    if ancestor_type not in (GeomAbs_Cylinder, GeomAbs_Cone):
                        continue  # planar or unsupported - a legitimate boundary
                    if _axes_coincide(reference_axis, _face_axis(ancestor_face)):
                        return False  # coaxial neighbour missing from the group
            exp.Next()
    return True


def _group_axial_midpoint(faces: list[TopoDS_Face], reference_axis: gp_Ax1) -> gp_Pnt:
    """A point on `reference_axis`, at the midpoint of the group's own
    combined axial extent - used only to classify hole-vs-boss against the
    original solid (`_resolve_move_face_coaxial_reposition`'s own doc
    comment), never as reconstruction geometry itself."""
    axial_values = [v for face in faces for v in _face_axial_range(face, reference_axis)]
    midpoint_axial = (min(axial_values) + max(axial_values)) / 2.0
    return _point_along(reference_axis, midpoint_axial)


def _resolve_move_face_coaxial_reposition(
    body_id: str,
    part: Part,
    bodies: dict[str, TopoDS_Shape],
    feature: MoveFaceFeature,
    excluded_feature_ids: frozenset[str],
    source: TopoDS_Shape,
    faces: list[TopoDS_Face],
) -> TopoDS_Shape:
    """`delta`/`direction_ref`'s coaxial-reposition sub-case - every face in
    `faces` is already confirmed cylindrical/conical with no planar member
    (the caller's own preceding loop). Reconstructs the feature's own
    solid-of-revolution at the original position and Fuse/Cut's it out and
    back in at the target - see this module's own top docstring and
    `docs/direct-editing-scope.md`'s "Move Face V4" section for the full
    reasoning."""
    reference_axis = _face_axis(faces[0])
    for face in faces[1:]:
        if not _axes_coincide(reference_axis, _face_axis(face)):
            raise _move_face_group_axis_mismatch(body_id)

    if not _coaxial_group_is_complete(source, faces):
        raise _move_face_group_incomplete_coaxial_chain(body_id)

    vec = _movement_vector(part, bodies, feature, excluded_feature_ids, body_id)
    magnitude = vec.Magnitude()
    if magnitude < 1e-9:
        raise _move_face_failed(body_id)

    try:
        fill = _group_fill_solid(faces, reference_axis)
    except ValueError:
        raise _move_face_failed(body_id) from None
    if not BRepCheck_Analyzer(fill).IsValid():
        raise _move_face_failed(body_id)

    trsf = gp_Trsf()
    trsf.SetTranslation(vec)
    target = BRepBuilderAPI_Transform(fill, trsf, True).Shape()
    if target is None or target.IsNull() or not BRepCheck_Analyzer(target).IsValid():
        raise _move_face_failed(body_id)

    # Hole vs. boss: a fixed Fuse-then-Cut order is only correct for a void
    # (hole) - confirmed via spike a fixed order is WRONG for a boss (fusing
    # an already-solid boss's own reconstructed primitive back onto itself
    # is a geometric no-op, so a fixed order would leave the original boss
    # in place *and* cut a spurious hole at the target instead of relocating
    # it). Classifying a point at the group's own axial midpoint against the
    # ORIGINAL solid (not the fill/target volumes) is the confirmed-correct,
    # more robust alternative to V3's own per-face-normal-voting sign
    # mechanism (already found unreliable for curved faces) - this sidesteps
    # that finding rather than reopening it, by classifying against real
    # solid material instead of a face's own local normal.
    midpoint = _group_axial_midpoint(faces, reference_axis)
    classifier = BRepClass3d_SolidClassifier(source, midpoint, _OFFSET_TOLERANCE)
    is_boss = classifier.State() == TopAbs_IN

    if is_boss:
        step1 = BRepAlgoAPI_Cut(source, fill).Shape()
        step1_op_is_valid = step1 is not None and not step1.IsNull() and BRepCheck_Analyzer(step1).IsValid()
        if not step1_op_is_valid:
            raise _move_face_failed(body_id)
        result = BRepAlgoAPI_Fuse(step1, target).Shape()
    else:
        step1 = BRepAlgoAPI_Fuse(source, fill).Shape()
        step1_op_is_valid = step1 is not None and not step1.IsNull() and BRepCheck_Analyzer(step1).IsValid()
        if not step1_op_is_valid:
            raise _move_face_failed(body_id)
        result = BRepAlgoAPI_Cut(step1, target).Shape()

    if result is None or result.IsNull():
        raise _move_face_failed(body_id)
    if not BRepCheck_Analyzer(result).IsValid():
        raise _move_face_failed(body_id)
    if _face_count(result) == 0 or _volume(result) <= 0.0:
        raise _move_face_failed(body_id)

    return result


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
    # surface types this family's own techniques are confirmed to handle.
    reference_face: TopoDS_Face | None = None
    for face in faces:
        surface_type = BRepAdaptor_Surface(face, True).GetType()
        if surface_type not in _SUPPORTED_SURFACE_TYPES:
            raise _move_face_unsupported_surface_type(body_id)
        if surface_type == GeomAbs_Plane and reference_face is None:
            reference_face = face
    if reference_face is None:
        # V4: no planar face in the group - by construction every face is
        # already confirmed cylindrical/conical (the loop above would have
        # raised on anything else). This is exactly the "lone hole/boss"
        # case the sweep technique below can't handle (no single face's own
        # outward normal to anchor the sign decision on) - see this
        # module's own top docstring for the different, coaxial-
        # reconstruction technique used instead.
        result = _resolve_move_face_coaxial_reposition(
            body_id, part, bodies, feature, excluded_feature_ids, source, faces
        )
        return body_id, result

    outward_normal = _outward_normal(reference_face)
    vec = _movement_vector(part, bodies, feature, excluded_feature_ids, body_id)

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
