"""Phase 6 (`docs/assembly-scope.md` §3): the mate solver. Given a Part's
own Mates + Occurrences, solves for one *driven* Occurrence's own
`RigidTransform` that satisfies every non-suppressed Mate referencing it,
treating every other referenced Occurrence - or the currently-open Part's
own root geometry, for a `MateEntityRef.occurrence_id == ""` reference (this
module's own convention, mirroring the client's identical "empty
occurrencePath means the root Part's own content" rule, `selection_hit_test.
dart`'s `hitTestComponentInstances`) - as *fixed* at its own already-known,
current transform. "v1 only drives the actively-dragged Occurrence against
fixed peers" (`docs/assembly-scope.md` §3) - no simultaneous multi-body
solving, and (mirroring Phase 5's own gizmo scope limit) only ever a
top-level Occurrence of the currently-open Part - a Mate cannot reference an
Occurrence nested inside another Occurrence in this pass.

Wraps `py_slvs.slvs.System` the same way `app.sketch.solver` does, but gets
no code reuse from that module - `_PySlvsBuilder` there only ever exercises
the 2D-sketch-workplane constraint subset (`addPointsCoincident`/
`addPointsDistance`/etc, always with an explicit `wrkpln`); a mate instead
needs `addTransform`/`addSameOrientation`/`addPointPlaneDistance`/
`addPointInPlane`/`addParallel`/`addPointOnLine`/`addAngle`, all free-3D
(`wrkpln` omitted), none of which `_PySlvsBuilder` touches.

Design notes on `SLVS_E_TRANSFORM` (confirmed against `realthunder/
solvespace`'s own `include/slvs.h`/`exposed/DOC.txt`/`src/entity.cpp` - the
fork `docs/assembly-scope.md` §1 already identified as this dependency's
real upstream):

- `addTransform(src, dx, dy, dz, qw, qx, qy, qz, asAxisAngle=False, ...)`
  with `asAxisAngle=False` (quaternion mode) produces `POINT_N_ROT_TRANS`/
  `NORMAL_N_ROT` internally, whose world-space value is the standard
  `q.Rotate(local) + (dx,dy,dz)` for a point, or `q_transform * q_local`
  for a normal/frame - exactly `RigidTransform`'s own rotate-then-translate
  convention, composed the same direction `app.document.assembly.compose`
  already applies one Occurrence level at a time.
  `asAxisAngle=True` instead produces `POINT_N_ROT_AA`, a *rotate-about-a-
  fixed-pivot* transform with no independent translation term (`p_world =
  q.Rotate(p_local - pivot) + pivot`, where the very same three params
  double as both the pivot and the post-rotation offset) - useful for
  SolveSpace's own "step-rotate a group about a point" UI feature, but
  unable to represent a translation-only placement (pivot cancels out when
  the rotation is the identity) and therefore *not* what a general
  rigid-body mate placement needs. This module always uses quaternion mode.
- Quaternion mode requires an accompanying `NORMAL_IN_3D` entity built from
  the *same* `(qw, qx, qy, qz)` param handles, in the same solve group, per
  `DOC.txt`'s own "IMPORTANT" note on `SLVS_E_TRANSFORM` - without it, the
  implicit unit-quaternion constraint `NORMAL_IN_3D` normally carries never
  gets added, and the solve is under/incorrectly constrained.
- Only a point or normal entity can be transformed directly (`DOC.txt`:
  "For other entities, ... recreate them yourself") - a line needed on the
  *driven* side is always rebuilt from two independently-transformed
  points (`addLineSegment`), and a workplane from a transformed point +
  transformed normal (`addWorkplane`) - never transformed as a whole.
- The *fixed* side of a mate never touches `py_slvs` at all - its
  Occurrence's transform is already fully known, so its geometry is placed
  into world space by plain Python (`app.document.assembly.
  apply_transform_to_point`/`apply_transform_to_direction`) before being
  fed in as literal, unsolved (`_FIXED_GROUP`) entities.

Axis-angle <-> quaternion conversion is entirely this module's own - per
`docs/assembly-scope.md` §1, `RigidTransform`'s wire format is axis-angle
specifically so the mate solver is the *only* place a quaternion appears,
at its own `py_slvs` FFI boundary, and no such converter exists anywhere
else in this backend.

Known v1 scope limits (documented here, not silently assumed):
- CONCENTRIC only supports axis-to-axis (a cylindrical Face, or a circular
  or straight Edge - Phase 13, `docs/assembly-scope.md` §6 `[15]` - on
  *both* sides) - there is no "concentric to a point" variant.

Which of a mate's valid placements ("roots") it means is data on the mate, not luck of the starting pose
(`docs/mate-solution-choice-plan.md`): `Mate.alignment` (the two directions point the same way / opposite ways) and
`Mate.secondary_flip` (the side of a DISTANCE, the spin half-turn of a locked CONCENTRIC, an ANGLE's supplement). `None`
is "Closest" and `resolve_branch` fills it in from the pose a solve starts from. The py-slvs constraints below are
sign-agnostic (`addParallel` holds for both roots), so the root is chosen by a warm-start seed that turns the occurrence
onto all of its alignment targets (`alignment_pairs` / `rotation_onto_pairs`) and, for a DISTANCE side, by the sign of the
signed `addPointPlaneDistance`; the residuals every other solver uses (`_mate_residual_vector`) are zero only on that
branch.

A COINCIDENT mate between two planar references is `addPointInPlane` plus `addParallel` (`_direction_lock`, 2 DOF): flush,
free to slide and to spin about the shared normal. (This docstring used to say `addSameOrientation`, 3 DOF - the code never
did; `addSameOrientation` cannot tell the two parallel branches apart either.)
"""

from __future__ import annotations

import math
from dataclasses import dataclass, replace

import numpy as np
from fastapi import HTTPException
from OCC.Core.BRepAdaptor import BRepAdaptor_Curve, BRepAdaptor_Surface
from OCC.Core.GeomAbs import GeomAbs_Circle, GeomAbs_Cylinder, GeomAbs_Line, GeomAbs_Plane
from OCC.Core.TopoDS import topods
from py_slvs import slvs

from app.document.assembly import (
    mate_ref_tops,
    invert_transform,
    apply_transform_to_direction,
    apply_transform_to_point,
    resolve_occurrence_target,
    top_level_occurrence_id,
)
from app.document.create_plane import midplane_of_resolved, resolve_plane_ref, resolve_point_ref_position
from app.document.extrude import compute_part_bodies, resolve_subshape_from_bodies
from app.document.measure import single_shape_geometry
from app.document.models import (
    COUPLER_TYPES,
    LIMIT_TYPES,
    Document,
    MATE_ALIGNED,
    MATE_ANTI_ALIGNED,
    Mate,
    MateEntityRef,
    MateType,
    Occurrence,
    Part,
    PlaneRef,
    ResolvedPlane,
    RigidTransform,
    SubShapeType,
)

Vec3 = tuple[float, float, float]
Quaternion = tuple[float, float, float, float]

# Mirrors `app.sketch.solver`'s own `_FIXED_GROUP`/`_SOLVE_GROUP` split -
# group 1 for literal/known geometry (both the fixed peer's world-space
# geometry, and the driven Occurrence's own *local*-frame source points/
# normals, which are constants too - only the whole-body transform is the
# unknown), group 2 for the transform's own 7 unknown params and anything
# `addTransform` derives from them.
_FIXED_GROUP = 1
_SOLVE_GROUP = 2

# `solve_occurrence_from_guess`'s own residual-verified-convergence fallback (see
# `_mate_residual_satisfied`'s own docstring) - mirrors `app.sketch.solver`'s
# identically-named, identically-scoped `_RESIDUAL_TOLERANCE` constant and
# the reasoning behind it (`py_slvs`'s own `result_code` cannot always tell
# "solved, just redundantly so" apart from a genuine conflict). Millimetre-
# scale absolute tolerance - unlike the sketch solver's own version this
# isn't scaled to the geometry's own size, since a mate's two references can
# come from Parts of wildly different scale (a tiny bolt mated to a large
# plate) where "size of the larger one" would be far too loose a floor for
# the smaller one's own real tolerance needs.
_RESIDUAL_TOLERANCE = 1e-4
_RESIDUAL_ANGLE_TOLERANCE_DEGREES = 1e-2


def _unsupported_mate_geometry(ref: MateEntityRef, needed: str) -> HTTPException:
    """Structured 422, same envelope `app.document.extrude._missing_reference`/
    `app.document.create_plane._non_planar_reference` already established -
    `ref` resolved to real geometry, but not a kind this module knows how to
    use as `needed` (e.g. a straight edge has no "axis")."""
    return HTTPException(
        status_code=422,
        detail={
            "type": "unsupported_mate_geometry",
            "occurrence_id": ref.occurrence_id,
            "needed": needed,
            "detail": f"This mate type can't use the selected geometry - it needs {needed}.",
        },
    )


def _unresolved_mate_occurrence(occurrence_id: str) -> HTTPException:
    return HTTPException(
        status_code=422,
        detail={"type": "unresolved_mate_occurrence", "occurrence_id": occurrence_id},
    )


def _driven_occurrence_not_found(occurrence_id: str) -> HTTPException:
    return HTTPException(status_code=404, detail={"type": "occurrence_not_found", "occurrence_id": occurrence_id})


@dataclass
class MateSolveResult:
    """`solve_occurrence_from_guess`'s own result - `converged` mirrors `app.sketch.
    solver.SolveResult`'s identically-named field (`system.solve`'s result
    code, `0` meaning success). `transform` is the *new* transform to store
    on `driven_occurrence_id` when `converged`; when not converged, it is
    the best-effort (likely garbage) value Newton's method stopped at -
    callers must check `converged` before using it, exactly like `app.
    sketch.solver`'s own caller always does."""

    converged: bool
    transform: RigidTransform
    dof: int


@dataclass
class _ResolvedGeometry:
    """A `MateEntityRef`'s resolved geometry, in *some* consistent frame
    (local to its own target Part, or already placed in world space - the
    caller tracks which). Fields are populated according to what kind of
    reference this was - never all four at once:
    - `point_ref`/a Vertex `subshape_ref` -> `point` only.
    - `plane_ref`/a planar Face `subshape_ref` -> `point` (the plane's own
      origin - a representative point on it, reused for the point-in-plane
      half of a mixed point/plane mate), `plane`, and `direction` (the
      plane's own normal - reused by PARALLEL/ANGLE, which only care about
      *a* direction, not which kind of reference it came from).
    - A cylindrical Face or circular Edge `subshape_ref` -> `axis_origin`
      and `direction` (the axis' own direction - same field PARALLEL/ANGLE
      already read for a planar reference, so those two mate types treat a
      face normal and an axis direction identically)."""

    point: Vec3 | None = None
    plane: ResolvedPlane | None = None
    axis_origin: Vec3 | None = None
    direction: Vec3 | None = None

    # Test report item 4: a unit vector perpendicular to `direction`,
    # populated only alongside an axis (`axis_origin`/`direction` from a
    # cylindrical Face or circular/straight Edge) - `None` for a plane/point
    # reference, and unused by every `MateType` except CONCENTRIC's own
    # `allow_rotation=False` branch (`_add_mate_constraints`/`_mate_
    # residual_satisfied`). Computed once, in `_resolve_local_geometry`, from
    # the *local*, untransformed `direction` (via `_axis_perpendicular`) -
    # `_place_in_world` then carries it through the same rotation `direction`
    # itself gets, so the constraint-building and residual-verification
    # passes always compare the *same* transformed vector, never two
    # independently-recomputed ones that could disagree once `direction`
    # itself has been rotated (see `_axis_perpendicular`'s own docstring for
    # why recomputing from a rotated vector isn't safe).
    perp: Vec3 | None = None

    # The HINGE an ANGLE between two planes swings about: `(origin, direction)` of the axis a CONCENTRIC (or edge-on-edge
    # COINCIDENT) mate between the same two occurrences holds them on, on the side of the mate's SECOND reference. Attached by
    # the group model / `mate_world_geometries` (never resolved from a reference), carried through `_place_in_world` like an
    # axis. It is what gives the sign of an ANGLE: the two roots +theta / -theta about the hinge (see `_angle_hinge`).
    hinge: tuple[Vec3, Vec3] | None = None


def _resolve_midplane_plane(
    target_part: Part, bodies: dict, ref: MateEntityRef, document: Document | None, root_part: Part | None
) -> ResolvedPlane:
    """A Width side (`MateEntityRef.midplane`): the plane midway between its two faces, in `target_part`'s local frame
    (`ref.occurrence_id`'s leaf Part). Computed fresh on every call; nothing is created or stored. Face `b` may sit in a
    different leaf Part under the same top-level Occurrence (the two bars of a frame): it is carried into `a`'s frame
    through the sub-assembly's own transforms."""
    mp = ref.midplane
    assert mp is not None
    plane_a = resolve_plane_ref(target_part, bodies, mp.a, frozenset())
    b_id = ref.occurrence_id if mp.b_occurrence_id is None else mp.b_occurrence_id
    if b_id == ref.occurrence_id:
        plane_b = resolve_plane_ref(target_part, bodies, mp.b, frozenset())
        return midplane_of_resolved(plane_a, plane_b, mp.a, mp.b)
    top = top_level_occurrence_id(ref.occurrence_id)
    if top == "" or top != top_level_occurrence_id(b_id) or document is None or root_part is None:
        # Faces under different top-level occurrences are resolved by `cross_midplane_geometry` (world space) / the group model's
        # composite sides; this local-frame resolver only serves one rigid body.
        raise HTTPException(
            status_code=422,
            detail={
                "type": "midplane_faces_on_different_occurrences",
                "message": "This solve cannot resolve a Width reference whose faces are on different top-level occurrences",
                "occurrence_id": ref.occurrence_id,
                "b_occurrence_id": b_id,
            },
        )
    top_part, _ = _target_part_and_transform(document, root_part, top)
    part_a, to_a = _target_part_and_transform(document, top_part, ref.occurrence_id[len(top) + 1 :])
    part_b, to_b = _target_part_and_transform(document, top_part, b_id[len(top) + 1 :])
    plane_b = resolve_plane_ref(part_b, compute_part_bodies(part_b), mp.b, frozenset())
    if to_b is not None:
        plane_b = _transform_plane(plane_b, to_b)
    if to_a is not None:
        plane_b = _transform_plane(plane_b, invert_transform(to_a))
    return midplane_of_resolved(plane_a, plane_b, mp.a, mp.b)


def _transform_plane(plane: ResolvedPlane, transform: RigidTransform) -> ResolvedPlane:
    return ResolvedPlane(
        origin=apply_transform_to_point(transform, plane.origin),
        normal=apply_transform_to_direction(transform, plane.normal),
        x_axis=apply_transform_to_direction(transform, plane.x_axis),
        y_axis=apply_transform_to_direction(transform, plane.y_axis),
    )


def midplane_spans_tops(ref: MateEntityRef) -> bool:
    """A Width reference whose two faces are under different top-level occurrences."""
    return ref.midplane is not None and len(mate_ref_tops(ref)) > 1


def cross_midplane_geometry(document: Document, part: Part, ref: MateEntityRef) -> _ResolvedGeometry:
    """A cross-occurrence Width reference in WORLD space at the stored poses: each face is resolved in its own part, placed by
    its occurrence's chain, and the plane midway between them is returned (strict: 422 `faces_not_parallel` unless parallel)."""
    mp = ref.midplane
    assert mp is not None and mp.b_occurrence_id is not None
    planes = []
    for occurrence_id, plane_ref in ((ref.occurrence_id, mp.a), (mp.b_occurrence_id, mp.b)):
        target, transform = _target_part_and_transform(document, part, occurrence_id)
        plane = resolve_plane_ref(target, compute_part_bodies(target), plane_ref, frozenset())
        planes.append(plane if transform is None else _transform_plane(plane, transform))
    plane = midplane_of_resolved(planes[0], planes[1], mp.a, mp.b)
    return _ResolvedGeometry(point=plane.origin, plane=plane, direction=plane.normal)


def _resolve_local_geometry(
    target_part: Part,
    bodies: dict,
    ref: MateEntityRef,
    document: Document | None = None,
    root_part: Part | None = None,
) -> _ResolvedGeometry:
    """`ref`'s own geometry, in `target_part`'s local frame (from `bodies`,
    `compute_part_bodies(target_part)`'s own result - never pre-transformed).
    Exactly one of `ref.point_ref`/`ref.plane_ref`/`ref.subshape_ref` is
    ever set (the router's own validation, mirroring `PlaneRef`/`PointRef`'s
    established "exactly one of N fields" convention)."""
    if ref.point_ref is not None:
        point = resolve_point_ref_position(target_part, bodies, ref.point_ref, frozenset())
        return _ResolvedGeometry(point=point)
    if ref.plane_ref is not None:
        plane = resolve_plane_ref(target_part, bodies, ref.plane_ref, frozenset())
        return _ResolvedGeometry(point=plane.origin, plane=plane, direction=plane.normal)
    if ref.midplane is not None:
        plane = _resolve_midplane_plane(target_part, bodies, ref, document, root_part)
        return _ResolvedGeometry(point=plane.origin, plane=plane, direction=plane.normal)

    assert ref.subshape_ref is not None
    sub = ref.subshape_ref
    shape = resolve_subshape_from_bodies(bodies, sub)

    if sub.shape_type == SubShapeType.VERTEX:
        geometry = single_shape_geometry(sub, shape)
        assert geometry.point is not None
        return _ResolvedGeometry(point=geometry.point)

    if sub.shape_type == SubShapeType.FACE:
        surface_type = BRepAdaptor_Surface(topods.Face(shape), True).GetType()
        if surface_type == GeomAbs_Plane:
            plane = resolve_plane_ref(target_part, bodies, PlaneRef(face_ref=sub), frozenset())
            return _ResolvedGeometry(point=plane.origin, plane=plane, direction=plane.normal)
        if surface_type == GeomAbs_Cylinder:
            geometry = single_shape_geometry(sub, shape)
            assert geometry.axis_origin is not None and geometry.axis_direction is not None
            return _ResolvedGeometry(
                axis_origin=geometry.axis_origin,
                direction=geometry.axis_direction,
                perp=_axis_perpendicular(geometry.axis_direction),
            )
        raise _unsupported_mate_geometry(ref, "point, plane, or axis")

    if sub.shape_type == SubShapeType.EDGE:
        curve_type = BRepAdaptor_Curve(topods.Edge(shape)).GetType()
        if curve_type in (GeomAbs_Circle, GeomAbs_Line):
            # Phase 13 (`docs/assembly-scope.md` §6 `[15]`): a straight
            # edge now resolves the same way a circular one always has -
            # `single_shape_geometry`'s own `GeomAbs_Line` branch reports
            # the identical `axis_origin`/`axis_direction` shape (a point on
            # the line + its direction) a circular edge's fitted axis
            # already does, so no new field or branch is needed here beyond
            # widening this `if` - CONCENTRIC/PARALLEL/ANGLE's own dispatch
            # (`_apply_mate_constraint`) never distinguished where an
            # `axis_origin`/`direction` pair came from in the first place.
            geometry = single_shape_geometry(sub, shape)
            assert geometry.axis_origin is not None and geometry.axis_direction is not None
            return _ResolvedGeometry(
                axis_origin=geometry.axis_origin,
                direction=geometry.axis_direction,
                perp=_axis_perpendicular(geometry.axis_direction),
            )
        raise _unsupported_mate_geometry(ref, "an axis (a circular or straight edge)")

    # SubShapeType.BODY - no meaningful point/plane/axis of its own.
    raise _unsupported_mate_geometry(ref, "point, plane, or axis")


def _place_in_world(geometry: _ResolvedGeometry, transform: RigidTransform) -> _ResolvedGeometry:
    """`geometry` (local to some fixed Occurrence's own target Part), placed
    into world space via `transform` (that Occurrence's own already-known
    current transform) - plain Python, no `py_slvs` involvement, since
    nothing here is being solved for."""
    point = apply_transform_to_point(transform, geometry.point) if geometry.point is not None else None
    axis_origin = (
        apply_transform_to_point(transform, geometry.axis_origin) if geometry.axis_origin is not None else None
    )
    direction = (
        apply_transform_to_direction(transform, geometry.direction) if geometry.direction is not None else None
    )
    # Test report item 4: `perp` rotates exactly like `direction` (it's just
    # another direction vector, in the same local frame) - never
    # recomputed from the already-transformed `direction` above, see
    # `_ResolvedGeometry.perp`'s own docstring for why that would disagree.
    perp = apply_transform_to_direction(transform, geometry.perp) if geometry.perp is not None else None
    plane = None
    if geometry.plane is not None:
        plane = ResolvedPlane(
            origin=apply_transform_to_point(transform, geometry.plane.origin),
            normal=apply_transform_to_direction(transform, geometry.plane.normal),
            x_axis=apply_transform_to_direction(transform, geometry.plane.x_axis),
            y_axis=apply_transform_to_direction(transform, geometry.plane.y_axis),
        )
    hinge = None
    if geometry.hinge is not None:
        hinge = (apply_transform_to_point(transform, geometry.hinge[0]), apply_transform_to_direction(transform, geometry.hinge[1]))
    return _ResolvedGeometry(point=point, plane=plane, axis_origin=axis_origin, direction=direction, perp=perp, hinge=hinge)


def _target_part_and_transform(
    document: Document, part: Part, occurrence_id: str
) -> tuple[Part, RigidTransform | None]:
    """The Part whose local bodies `occurrence_id` places, plus that
    Occurrence's own current `transform` - thin wrapper over
    `app.document.assembly.resolve_occurrence_target` (this module's
    original owner, now shared with the Measure tool - see that function's
    own docstring) that translates its plain `KeyError` into this module's
    own established `unresolved_mate_occurrence` 422 shape."""
    try:
        return resolve_occurrence_target(document, part, occurrence_id)
    except KeyError:
        raise _unresolved_mate_occurrence(occurrence_id) from None


# ---- Axis-angle <-> quaternion (this module's own private FFI boundary) --


def _normalize(v: Vec3) -> Vec3:
    length = math.sqrt(v[0] ** 2 + v[1] ** 2 + v[2] ** 2)
    if length < 1e-12:
        return (0.0, 0.0, 1.0)
    return (v[0] / length, v[1] / length, v[2] / length)


def _vec_sub(a: Vec3, b: Vec3) -> Vec3:
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def _dot(a: Vec3, b: Vec3) -> float:
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def _cross(a: Vec3, b: Vec3) -> Vec3:
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def _magnitude(v: Vec3) -> float:
    return math.sqrt(_dot(v, v))


def _axis_perpendicular(direction: Vec3) -> Vec3:
    """A unit vector perpendicular to `direction` - `_ResolvedGeometry.perp`'s
    own populator (test report item 4, CONCENTRIC's `allow_rotation=False`
    branch). Deterministic and a pure function of `direction` alone (the
    same "pick whichever world axis isn't nearly parallel, cross it in"
    technique `_quaternion_aligning`'s own near-180-degree branch already
    uses) - **not** meant to reconstruct any particular real-world reference
    on the part (a plain cylindrical/circular axis has no such reference to
    begin with, unlike e.g. a keyway), just to give CONCENTRIC's own extra
    angle-lock constraint two well-defined, always-available lines to pin
    together. This is why `allow_rotation=False` is documented as a
    canonical-phase lock, not a "freeze wherever it currently is" one: the
    driven side ends up at whichever of its own infinite rotational
    positions makes this canonical perpendicular line up with the fixed
    side's, not necessarily the position it happened to be dragged to."""
    axis = _normalize(direction)
    arbitrary = (1.0, 0.0, 0.0) if abs(axis[0]) < 0.9 else (0.0, 1.0, 0.0)
    return _normalize(_cross(axis, arbitrary))


def _point_plane_distance(point: Vec3, plane_origin: Vec3, plane_normal: Vec3) -> float:
    return abs(_dot(_vec_sub(point, plane_origin), _normalize(plane_normal)))


def _point_line_distance(point: Vec3, line_origin: Vec3, line_direction: Vec3) -> float:
    # |cross(offset, direction)| is exactly the perpendicular distance for a
    # *unit* direction (|offset| * sin(theta)) - the same identity
    # `_quaternion_aligning` already relies on via its own cross product.
    return _magnitude(_cross(_vec_sub(point, line_origin), _normalize(line_direction)))


def _directions_parallel(a: Vec3, b: Vec3) -> bool:
    # Cross-product magnitude of two unit vectors is `sin(theta)` - zero for
    # either same- or opposite-direction parallel vectors, matching
    # `addParallel`'s own sign-agnostic semantics (see `_direction_lock`'s
    # own docstring: *which* sign is `flipped`'s job via the warm-start seed,
    # never an extra constraint here).
    return _magnitude(_cross(_normalize(a), _normalize(b))) <= _RESIDUAL_TOLERANCE


def _quaternion_from_axis_angle(axis: Vec3, angle_degrees: float) -> Quaternion:
    ax, ay, az = _normalize(axis)
    half = math.radians(angle_degrees) / 2.0
    s = math.sin(half)
    return (math.cos(half), ax * s, ay * s, az * s)


def _axis_angle_from_quaternion(q: Quaternion) -> tuple[Vec3, float]:
    # The angle comes from the VECTOR part (`2 atan2(|v|, w)`), not from `acos(w)`: near the identity `w = cos(theta / 2)` rounds
    # to exactly 1.0 for any theta below ~1.5e-8 rad, so a Gauss-Newton rotation update that fine (a 1e-9 rad tilt of a 1.6 m
    # part is a 1.6e-6 mm shift of its far end) was silently dropped and the solve stalled just above tolerance.
    s = math.sqrt(q[1] * q[1] + q[2] * q[2] + q[3] * q[3])
    if s < 1e-15:
        return (0.0, 0.0, 1.0), 0.0
    angle_radians = 2.0 * math.atan2(s, q[0])
    return (q[1] / s, q[2] / s, q[3] / s), math.degrees(angle_radians)


def _quaternion_aligning(source: Vec3, target: Vec3) -> Quaternion:
    """A quaternion rotating unit vector `source` onto unit vector `target`
    - `solve_occurrence_from_guess`'s own warm-start seed for a COINCIDENT plane-plane
    mate's direction, used *instead of* an extra sign-picking constraint
    (see `_direction_lock`'s own docstring for why one doesn't work): once
    `addParallel` has already locked the driven direction to lie along the
    *same infinite line* as the target, seeding Newton's method already
    almost exactly on the intended branch (same-direction vs opposite)
    reliably keeps it there, the same "warm start" principle any Newton
    solver relies on for a nearby-but-not-exact initial guess. Standard
    "rotation between two vectors" construction (half-angle formula) - the
    near-180-degree case (`source`/`target` opposite) is degenerate for the
    usual `cross(source, target)` axis (near-zero magnitude), so that case
    picks an arbitrary perpendicular axis instead (a full 180-degree
    rotation, unique up to choice of axis for its own end result - and this
    seed only needs to be *close*, not exact, since the real solve refines
    it)."""
    a = _normalize(source)
    b = _normalize(target)
    dot = a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
    if dot > 1.0 - 1e-9:
        return (1.0, 0.0, 0.0, 0.0)
    if dot < -1.0 + 1e-9:
        # Any vector not parallel to `a` gives a valid perpendicular axis
        # via a second cross product.
        arbitrary = (1.0, 0.0, 0.0) if abs(a[0]) < 0.9 else (0.0, 1.0, 0.0)
        axis = _normalize(
            (
                a[1] * arbitrary[2] - a[2] * arbitrary[1],
                a[2] * arbitrary[0] - a[0] * arbitrary[2],
                a[0] * arbitrary[1] - a[1] * arbitrary[0],
            )
        )
        return (0.0, axis[0], axis[1], axis[2])
    cross = (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])
    s = math.sqrt((1.0 + dot) * 2.0)
    inv_s = 1.0 / s
    return (s * 0.5, cross[0] * inv_s, cross[1] * inv_s, cross[2] * inv_s)


def _quaternion_multiply(a: Quaternion, b: Quaternion) -> Quaternion:
    """Standard Hamilton product `a * b` - rotating a vector by `b` then by
    `a` is the same as rotating it once by `_quaternion_multiply(a, b)`."""
    aw, ax, ay, az = a
    bw, bx, by, bz = b
    return (
        aw * bw - ax * bx - ay * by - az * bz,
        aw * bx + ax * bw + ay * bz - az * by,
        aw * by - ax * bz + ay * bw + az * bx,
        aw * bz + ax * by - ay * bx + az * bw,
    )


def _rotate_vector_by_quaternion(q: Quaternion, v: Vec3) -> Vec3:
    """Rotates `v` by unit quaternion `q` (the standard `q * v * q^-1`,
    expanded via its cross-product form rather than a full quaternion
    multiply)."""
    qw, qx, qy, qz = q
    qv = (qx, qy, qz)
    t = _cross(qv, v)
    t = (t[0] * 2.0, t[1] * 2.0, t[2] * 2.0)
    cross_t = _cross(qv, t)
    return (v[0] + qw * t[0] + cross_t[0], v[1] + qw * t[1] + cross_t[1], v[2] + qw * t[2] + cross_t[2])


def _quaternion_aligning_axis_and_perp(
    driven_axis: Vec3, driven_perp: Vec3, fixed_axis: Vec3, fixed_perp: Vec3
) -> Quaternion:
    """CONCENTRIC's own warm-start seed for the `allow_rotation=False` branch
    (test report item 4, bolt-in-hole repro) - unlike COINCIDENT's
    `_quaternion_aligning` (a single alignment: only the +/- sign along one
    already-shared axis is ambiguous), the rotation-locked branch needs two:
    first bring `driven_axis` onto `fixed_axis` (`_quaternion_aligning`
    itself, same as COINCIDENT's use), then - about that now-shared axis -
    bring the perpendicular reference line along too, so the new
    `addParallel` rotation-lock constraint (see its own call site's comment
    for why it replaced `addAngle`) starts on the correct 0-degree branch
    rather than the 180-degree one. The second alignment is guaranteed to
    rotate about (a multiple of) `fixed_axis` alone, never disturbing the
    first: `driven_perp` is perpendicular to `driven_axis` by construction
    (`_axis_perpendicular`), the first rotation preserves that
    perpendicularity, and two vectors both perpendicular to the same axis can
    only be brought together by rotating about that axis."""
    axis_alignment = _quaternion_aligning(driven_axis, fixed_axis)
    perp_after_axis_alignment = _rotate_vector_by_quaternion(axis_alignment, driven_perp)
    twist_alignment = _quaternion_aligning(perp_after_axis_alignment, fixed_perp)
    return _quaternion_multiply(twist_alignment, axis_alignment)


def _quaternion_from_basis(x_axis: Vec3, y_axis: Vec3, z_axis: Vec3) -> Quaternion:
    """Standard rotation-matrix-to-quaternion conversion (Shepperd's
    method) for the right-handed orthonormal frame `[x_axis | y_axis |
    z_axis]` (as columns) - `ResolvedPlane`'s own `x_axis`/`y_axis`/`normal`
    triple already is exactly this, by construction (`app.document.
    create_plane._resolve_planar_face`'s own docstring)."""
    m00, m10, m20 = x_axis
    m01, m11, m21 = y_axis
    m02, m12, m22 = z_axis
    trace = m00 + m11 + m22
    if trace > 0:
        s = 0.5 / math.sqrt(trace + 1.0)
        return (0.25 / s, (m21 - m12) * s, (m02 - m20) * s, (m10 - m01) * s)
    if m00 > m11 and m00 > m22:
        s = 2.0 * math.sqrt(1.0 + m00 - m11 - m22)
        return ((m21 - m12) / s, 0.25 * s, (m01 + m10) / s, (m02 + m20) / s)
    if m11 > m22:
        s = 2.0 * math.sqrt(1.0 + m11 - m00 - m22)
        return ((m02 - m20) / s, (m01 + m10) / s, 0.25 * s, (m12 + m21) / s)
    s = 2.0 * math.sqrt(1.0 + m22 - m00 - m11)
    return ((m10 - m01) / s, (m02 + m20) / s, (m12 + m21) / s, 0.25 * s)


# ---- The py_slvs solve itself --------------------------------------------


@dataclass
class _TransformParams:
    """The 7 unknown params (`SLVS_E_TRANSFORM`'s own `dx,dy,dz,qw,qx,qy,qz`)
    representing the driven Occurrence's own whole-body placement, created
    once per solve and reused as `addTransform`'s own trailing arguments for
    however many points/normals that Occurrence's own Mates need
    transformed."""

    dx: int
    dy: int
    dz: int
    qw: int
    qx: int
    qy: int
    qz: int


class _DrivenGeometryBuilder:
    """Wraps `system`/`transform` to build `py_slvs` entities for the
    driven side of a mate - every local point/direction it's handed is
    first created as a literal `_FIXED_GROUP` entity (the constant, known
    local-frame value), then run through `addTransform` (quaternion mode -
    see this module's own docstring for why) into a `_SOLVE_GROUP` entity
    representing that same point/direction after the trial whole-body
    placement Newton's method is searching over."""

    def __init__(self, system: slvs.System, transform: _TransformParams):
        self._system = system
        self._transform = transform

    def point(self, local: Vec3) -> int:
        src = self._system.addPoint3dV(*local, group=_FIXED_GROUP)
        t = self._transform
        return self._system.addTransform(
            src, t.dx, t.dy, t.dz, t.qw, t.qx, t.qy, t.qz, asAxisAngle=False, group=_SOLVE_GROUP
        )

    def normal_from_quaternion(self, local_quaternion: Quaternion) -> int:
        src = self._system.addNormal3dV(*local_quaternion, group=_FIXED_GROUP)
        t = self._transform
        return self._system.addTransform(
            src, t.dx, t.dy, t.dz, t.qw, t.qx, t.qy, t.qz, asAxisAngle=False, group=_SOLVE_GROUP
        )

    def line(self, origin: Vec3, direction: Vec3) -> int:
        p0 = self.point(origin)
        p1 = self.point((origin[0] + direction[0], origin[1] + direction[1], origin[2] + direction[2]))
        return self._system.addLineSegment(p0, p1, group=_SOLVE_GROUP)


def _direction_lock(
    system: slvs.System,
    builder: _DrivenGeometryBuilder,
    driven_local_origin: Vec3,
    driven_local_direction: Vec3,
    fixed_direction: Vec3,
) -> None:
    """`MateType.COINCIDENT`'s own plane-plane branch needs the transformed
    driven direction to end up parallel to `fixed_direction` (2 DOF) -
    *which* of the two parallel branches (same-direction vs opposite) is
    `flipped`'s own job, resolved not by an extra constraint here but by
    `solve_occurrence_from_guess`'s own warm-start seed (`_quaternion_aligning`) -
    see that function's own docstring for why a *constraint* meant to pick
    the sign doesn't actually work.

    Two constraint-based attempts were tried and reverted here, both
    confirmed by an actual failing solve, not just reasoning:
    1. `addSameOrientation` - confirmed against `realthunder/solvespace`'s
       own `src/constrainteq.cpp`, `SAME_ORIENTATION`'s actual equations are
       "the two normals are *parallel*" (sign-agnostic - antiparallel
       counts as parallel too) plus one dot-product term whose own comment
       reads "allow either orientation for the coordinate system,
       depending on how it was drawn" - i.e. it structurally cannot
       distinguish `flipped` from not-flipped at all.
    2. Chaining `addTranslate` off an already-`addTransform`'d point (to
       build "driven's transformed origin, offset by a fixed target
       vector") - `EntityBase::Transform`'s own `numPoint = src->
       PointGetNum()` snapshots `src`'s value *once*, at entity-creation
       time (confirmed directly against `entity.cpp`), so a `_SOLVE_GROUP`
       `addTransform` result passed back in as a *second* transform's own
       `src` stays frozen at its seed value forever - zero solver progress.
    3. A signed `addPointPlaneDistance` of a point one unit along the
       driven direction, once `addParallel` had already locked the
       direction to +/- the target - correct in principle (unlike 1 and 2),
       but its own Jacobian w.r.t. rotation is *exactly* zero at the target
       configurations themselves (a dot-product/cosine measure is always
       stationary at its own extrema, cos(theta) near theta=0 or pi) - a
       real, reproduced convergence failure sitting precisely at the two
       configurations this mate is actually trying to reach, not a
       hypothetical concern."""
    driven_line = builder.line(driven_local_origin, driven_local_direction)
    fixed_line = _fixed_line(system, (0.0, 0.0, 0.0), fixed_direction)
    system.addParallel(driven_line, fixed_line, group=_SOLVE_GROUP)


def _fixed_point(system: slvs.System, point: Vec3) -> int:
    return system.addPoint3dV(*point, group=_FIXED_GROUP)


def _fixed_line(system: slvs.System, origin: Vec3, direction: Vec3) -> int:
    p0 = system.addPoint3dV(*origin, group=_FIXED_GROUP)
    tip = (origin[0] + direction[0], origin[1] + direction[1], origin[2] + direction[2])
    p1 = system.addPoint3dV(*tip, group=_FIXED_GROUP)
    return system.addLineSegment(p0, p1, group=_FIXED_GROUP)


def _fixed_workplane(system: slvs.System, plane: ResolvedPlane) -> int:
    origin = system.addPoint3dV(*plane.origin, group=_FIXED_GROUP)
    quaternion = _quaternion_from_basis(plane.x_axis, plane.y_axis, plane.normal)
    normal = system.addNormal3dV(*quaternion, group=_FIXED_GROUP)
    return system.addWorkplane(origin, normal, group=_FIXED_GROUP)


def _effective_mate(mate: Mate, driven: _ResolvedGeometry, fixed: _ResolvedGeometry) -> Mate:
    """A COINCIDENT between two axis references (straight or circular Edges, cylindrical Faces) means "the two lines
    coincide" - exactly CONCENTRIC's axis-to-axis lock (parallel + driven axis origin on the fixed line; spin about and
    slide along the shared line stay free). Read as such wherever a mate is built, checked or differentiated, so the
    three solver paths and the exported constraint model can never disagree about it."""
    if (
        mate.type == MateType.COINCIDENT
        and driven.plane is None
        and fixed.plane is None
        and driven.axis_origin is not None
        and driven.direction is not None
        and fixed.axis_origin is not None
        and fixed.direction is not None
    ):
        return replace(mate, type=MateType.CONCENTRIC, allow_rotation=True)
    return mate


# ---- the branch ("root") a mate stands for ---------------------------------------------------------------------
#
# `docs/mate-solution-choice-plan.md`: a mate's geometry alone has several exact placements - parallel the same way or the
# opposite way, a DISTANCE on either side of its face. `Mate.alignment` / `Mate.secondary_flip` say which; every solver
# below (py-slvs seed, group Gauss-Newton, the exported constraint model and its Dart / GDScript mirrors) uses residuals
# that are zero ONLY on the chosen branch, so a solve or drag can never land on another one.

_DISTANCE_FLOOR = 1e-3  # mm: the divisor floor of the mm-scaled squared residuals (axis-axis / point-point DISTANCE)


def _alignment_pair(mate: Mate, driven: _ResolvedGeometry, fixed: _ResolvedGeometry) -> tuple[Vec3, Vec3] | None:
    """The two directions whose relative sign `mate.alignment` fixes (driven, fixed), for an EFFECTIVE mate; `None` when
    the mate's geometry has no such pair (point/plane mixes, point-point, ANGLE)."""
    if mate.type == MateType.COINCIDENT:
        if driven.plane is not None and fixed.plane is not None:
            return driven.plane.normal, fixed.plane.normal
        return None
    if mate.type in (MateType.CONCENTRIC, MateType.PARALLEL):
        if driven.direction is not None and fixed.direction is not None:
            return driven.direction, fixed.direction
        return None
    if mate.type == MateType.DISTANCE:
        if driven.plane is not None and fixed.plane is not None:
            return driven.plane.normal, fixed.plane.normal
        if (
            driven.plane is None
            and fixed.plane is None
            and driven.axis_origin is not None
            and driven.direction is not None
            and fixed.axis_origin is not None
            and fixed.direction is not None
        ):
            return driven.direction, fixed.direction
    return None


def _signed_offset(mate: Mate, driven: _ResolvedGeometry, fixed: _ResolvedGeometry) -> float | None:
    """The signed separation a DISTANCE mate's `secondary_flip` is the side of (`signed` in `_mate_residual_vector`);
    `None` for the unsigned geometries (axis-axis, point-point) and for other mate types."""
    if mate.type != MateType.DISTANCE:
        return None
    if driven.plane is not None and fixed.plane is not None:
        return _dot(_vec_sub(driven.plane.origin, fixed.plane.origin), fixed.plane.normal)
    if driven.plane is not None and fixed.point is not None:
        return _dot(_vec_sub(fixed.point, driven.plane.origin), driven.plane.normal)
    if fixed.plane is not None and driven.point is not None:
        return _dot(_vec_sub(driven.point, fixed.plane.origin), fixed.plane.normal)
    return None


def _perp_pair(mate: Mate, driven: _ResolvedGeometry, fixed: _ResolvedGeometry) -> tuple[Vec3, Vec3] | None:
    """CONCENTRIC with rotation locked: the two perpendicular reference lines whose relative sign (the spin half-turn)
    `secondary_flip` fixes."""
    if mate.type == MateType.CONCENTRIC and not mate.allow_rotation and driven.perp is not None and fixed.perp is not None:
        return driven.perp, fixed.perp
    return None


def _angle_degrees(driven: _ResolvedGeometry, fixed: _ResolvedGeometry) -> float | None:
    if driven.direction is None or fixed.direction is None:
        return None
    dot = max(-1.0, min(1.0, _dot(_normalize(driven.direction), _normalize(fixed.direction))))
    return math.degrees(math.acos(dot))


def _angle_target_radians(mate: Mate) -> float:
    target = abs(mate.value or 0.0) % 360.0
    return math.radians(min(target, 360.0 - target))


def _angle_hinge(mate: Mate, driven: _ResolvedGeometry, fixed: _ResolvedGeometry) -> tuple[Vec3, Vec3] | None:
    """The hinge `(origin, unit direction)` an ANGLE mate's `alignment` is the swing sense about, or `None` when the mate has no
    hinge, is not an ANGLE between two directions, has no value, or its angle is 0 / 180 degrees (both roots coincide)."""
    if mate.type != MateType.ANGLE or mate.value is None or driven.direction is None or fixed.direction is None:
        return None
    hinge = driven.hinge or fixed.hinge
    if hinge is None or math.sin(_angle_target_radians(mate)) < 1e-6:
        return None
    return hinge[0], _normalize(hinge[1])


def _hinge_sine(driven: _ResolvedGeometry, fixed: _ResolvedGeometry, hinge: tuple[Vec3, Vec3]) -> float:
    """`(driven x fixed) . hinge`: the sine of the signed angle from the driven direction to the fixed one about the hinge."""
    return _dot(_cross(_normalize(driven.direction), _normalize(fixed.direction)), hinge[1])


def hinge_swing_state(mate: Mate, driven: _ResolvedGeometry, fixed: _ResolvedGeometry):
    """`(hinge, signed angle from driven to fixed about the hinge, in (-pi, pi])` for an ANGLE with an active hinge, else `None`."""
    hinge = _angle_hinge(mate, driven, fixed)
    if hinge is None:
        return None
    dot = _dot(_normalize(driven.direction), _normalize(fixed.direction))
    return hinge, math.atan2(_hinge_sine(driven, fixed, hinge), dot)


def resolve_branch(mate: Mate, driven_world: _ResolvedGeometry, fixed_world: _ResolvedGeometry) -> Mate:
    """`mate` with every branch field its geometry uses and that is still `None` ("Closest") filled in from the CURRENT
    placement (`driven_world` / `fixed_world`, both in world space): `alignment` from the sign of the two directions'
    dot product, the DISTANCE side from the sign of the signed offset, the spin half-turn from the perpendicular lines,
    an ANGLE's supplement from whichever of the angle and its supplement the pair is nearer. Fields already set are never
    changed, so a resolved mate resolves to itself. Where the sign is undecidable (perpendicular directions, zero offset)
    the default is anti-aligned for COINCIDENT plane-plane (touching solids face each other), aligned / side 0 otherwise."""
    effective = _effective_mate(mate, driven_world, fixed_world)
    alignment, flip = mate.alignment, mate.secondary_flip
    if alignment is None:
        pair = _alignment_pair(effective, driven_world, fixed_world)
        hinge = _angle_hinge(effective, driven_world, fixed_world)
        if pair is not None:
            dot = _dot(_normalize(pair[0]), _normalize(pair[1]))
            if abs(dot) > 1e-9:
                alignment = MATE_ALIGNED if dot > 0 else MATE_ANTI_ALIGNED
            else:
                alignment = MATE_ANTI_ALIGNED if effective.type == MateType.COINCIDENT else MATE_ALIGNED
        elif hinge is not None:
            # An ANGLE about a hinge: which way the lid swings, from the sign of the sine of the swing at the current placement.
            sine = _hinge_sine(driven_world, fixed_world, hinge)
            alignment = MATE_ANTI_ALIGNED if sine < -1e-9 else MATE_ALIGNED
    if flip is None:
        offset = _signed_offset(effective, driven_world, fixed_world)
        perp = _perp_pair(effective, driven_world, fixed_world)
        if offset is not None:
            flip = bool(offset < -1e-9)  # a plain bool: these are stored on the mate (a numpy bool does not serialise)
        elif perp is not None:
            flip = bool(_dot(_normalize(perp[0]), _normalize(perp[1])) < 0)
        elif effective.type == MateType.ANGLE and effective.value is not None:
            actual = _angle_degrees(driven_world, fixed_world)
            if actual is not None:
                target = abs(effective.value) % 360.0
                target = min(target, 360.0 - target)
                flip = bool(abs(actual - (180.0 - target)) < abs(actual - target) - 1e-9)
    if alignment == mate.alignment and flip == mate.secondary_flip:
        return mate
    return replace(mate, alignment=alignment, secondary_flip=flip)


def branch_fields(mate: Mate, driven_world: _ResolvedGeometry, fixed_world: _ResolvedGeometry) -> tuple[str, ...]:
    """The branch fields (`"alignment"`, `"secondary_flip"`) this mate's geometry actually uses - the ones a branch search may
    flip. `alignment` when the mate has a direction pair; `secondary_flip` for the side of a plane / point DISTANCE, the spin
    half-turn of a rotation-locked CONCENTRIC, and an ANGLE's supplement."""
    effective = _effective_mate(mate, driven_world, fixed_world)
    fields: list[str] = []
    if _alignment_pair(effective, driven_world, fixed_world) is not None or _angle_hinge(effective, driven_world, fixed_world) is not None:
        fields.append("alignment")
    if (
        _signed_offset(effective, driven_world, fixed_world) is not None
        or _perp_pair(effective, driven_world, fixed_world) is not None
        or (effective.type == MateType.ANGLE and effective.value is not None and _angle_degrees(driven_world, fixed_world) is not None)
    ):
        fields.append("secondary_flip")
    return tuple(fields)


def orient_branch(mate: Mate, driven_world: _ResolvedGeometry, fixed_world: _ResolvedGeometry, swapped: bool) -> Mate:
    """Converts a mate's stored (CANONICAL) branch to the orientation a solve uses, and back (it is its own inverse).

    A branch is stored relative to the mate's `references` order - reference 0 is the "driven" side, reference 1 the "fixed"
    one - but a solve orients the pair by which occurrence is the one moving (`swapped` = the solve's driven side is
    reference 1). `alignment` does not care. The SIDE of a DISTANCE between two planes does when their normals point the same
    way: `(a.origin - b.origin) . b.normal` is minus `(b.origin - a.origin) . a.normal` there, so grounding the other part must
    not make the stored side mean the opposite one (the part would hop across the face). Every other branch field is
    orientation-free (a point-plane distance is always `(point - plane.origin) . plane.normal`)."""
    if swapped and mate.alignment is not None and _angle_hinge(mate, driven_world, fixed_world) is not None:
        # The swing sense of an ANGLE about its hinge is the sign of `(driven x fixed) . hinge`: swapping the roles reverses it.
        return replace(mate, alignment=MATE_ALIGNED if mate.alignment == MATE_ANTI_ALIGNED else MATE_ANTI_ALIGNED)
    if not swapped or mate.secondary_flip is None or mate.alignment != MATE_ALIGNED:
        return mate
    effective = _effective_mate(mate, driven_world, fixed_world)
    if effective.type != MateType.DISTANCE or driven_world.plane is None or fixed_world.plane is None:
        return mate
    return replace(mate, secondary_flip=not mate.secondary_flip)


def resolve_oriented_branch(
    mate: Mate, driven_world: _ResolvedGeometry, fixed_world: _ResolvedGeometry, swapped: bool
) -> tuple[Mate, Mate]:
    """`(oriented, canonical)`: `mate` (its branch stored canonically, `None` = Closest) resolved for a solve that orients the
    pair `(driven_world, fixed_world)` - `swapped` when that is the reverse of the mate's `references` order. `oriented` is what
    the residuals use; `canonical` is the same mate with the resolved branch in the stored convention (what a commit writes back)."""
    # The alignment first (orientation-free), so the side can then be converted: resolve with the side blanked and keep only the
    # alignment, put the stored side back, orient it, and let the oriented geometry fill a side that is still unset.
    stored = resolve_branch(replace(mate, secondary_flip=None), driven_world, fixed_world)
    if swapped and mate.alignment is None and stored.alignment is not None and _angle_hinge(stored, driven_world, fixed_world) is not None:
        # resolved from the REVERSED pair: back to the references' order (an ANGLE's swing sense is antisymmetric)
        stored = replace(stored, alignment=MATE_ALIGNED if stored.alignment == MATE_ANTI_ALIGNED else MATE_ANTI_ALIGNED)
    stored = replace(stored, secondary_flip=mate.secondary_flip)
    oriented = resolve_branch(orient_branch(stored, driven_world, fixed_world, swapped), driven_world, fixed_world)
    return oriented, orient_branch(oriented, driven_world, fixed_world, swapped)


def sync_flipped(mate: Mate, driven_world: _ResolvedGeometry | None = None, fixed_world: _ResolvedGeometry | None = None) -> None:
    """Keeps the deprecated `Mate.flipped` in step with the branch fields (`flipped=True` <=> aligned for COINCIDENT,
    <=> the supplement for ANGLE). CONCENTRIC / PARALLEL / DISTANCE never used it and keep whatever they carry."""
    if mate.type == MateType.ANGLE and mate.secondary_flip is not None:
        mate.flipped = bool(mate.secondary_flip)
    elif mate.type == MateType.COINCIDENT and mate.alignment is not None:
        mate.flipped = mate.alignment == MATE_ALIGNED


def apply_flipped_alias(
    mate: Mate, driven_world: _ResolvedGeometry, fixed_world: _ResolvedGeometry, override: bool = False
) -> Mate:
    """The deprecated `flipped` flag read into the branch fields, for a mate whose payload carried only `flipped`: COINCIDENT
    plane-plane -> `alignment` (True = aligned), ANGLE -> `secondary_flip`. Needs the geometry because `flipped` meant
    something only for those (a COINCIDENT of two edges is a CONCENTRIC and ignored it). Fields already set are kept unless
    `override` (an edit that sets `flipped` on a mate that already names its branch)."""
    effective = _effective_mate(mate, driven_world, fixed_world)
    alignment, flip = mate.alignment, mate.secondary_flip
    if (
        effective.type == MateType.COINCIDENT
        and (alignment is None or override)
        and _alignment_pair(effective, driven_world, fixed_world) is not None
    ):
        alignment = MATE_ALIGNED if mate.flipped else MATE_ANTI_ALIGNED
    if effective.type == MateType.ANGLE and (flip is None or override):
        flip = bool(mate.flipped)
    if alignment == mate.alignment and flip == mate.secondary_flip:
        return mate
    return replace(mate, alignment=alignment, secondary_flip=flip)


def _align_sign(mate: Mate) -> float:
    """+1 for aligned, -1 for anti-aligned (an unresolved mate reads as aligned: callers resolve first)."""
    return -1.0 if mate.alignment == MATE_ANTI_ALIGNED else 1.0


def _flip_sign(mate: Mate) -> float:
    """-1 when `secondary_flip` (the other side / the half-turn), else +1."""
    return -1.0 if mate.secondary_flip else 1.0


def _direction_matches(a: Vec3, b: Vec3, sign: float) -> bool:
    """`a` points the way `sign * b` does (unit vectors compared, `_RESIDUAL_TOLERANCE`)."""
    na, nb = _normalize(a), _normalize(b)
    return _magnitude((na[0] - sign * nb[0], na[1] - sign * nb[1], na[2] - sign * nb[2])) <= _RESIDUAL_TOLERANCE


def alignment_pairs(mate: Mate, driven_world: _ResolvedGeometry, fixed_world: _ResolvedGeometry) -> list[tuple[Vec3, Vec3]]:
    """`(current driven direction, target direction)` for every direction a RESOLVED mate wants brought onto its branch: the
    alignment pair (target = `sign * fixed`) and, for a CONCENTRIC with rotation locked, the spin pair. All in world space."""
    effective = _effective_mate(mate, driven_world, fixed_world)
    pairs: list[tuple[Vec3, Vec3]] = []
    pair = _alignment_pair(effective, driven_world, fixed_world)
    if pair is not None and mate.alignment is not None:
        sign = _align_sign(mate)
        fixed = _normalize(pair[1])
        pairs.append((_normalize(pair[0]), (sign * fixed[0], sign * fixed[1], sign * fixed[2])))
    perp = _perp_pair(effective, driven_world, fixed_world)
    if perp is not None and mate.secondary_flip is not None:
        sign = _flip_sign(mate)
        fixed = _normalize(perp[1])
        pairs.append((_normalize(perp[0]), (sign * fixed[0], sign * fixed[1], sign * fixed[2])))
    return pairs


def rotation_onto_pairs(pairs: list[tuple[Vec3, Vec3]]) -> np.ndarray | None:
    """The rotation (3x3, acting on world vectors) that best takes every pair's source direction onto its target: the
    minimal rotation for one independent pair, a least-squares (Kabsch) fit for two or more - so a part held by several
    alignment mates is turned once, onto all of their branches together, instead of by one mate undoing the previous.
    Pairs whose sources are parallel to an earlier one add nothing (the spin about that axis is not theirs to decide)
    and are dropped. `None` for no pair, or nothing to rotate."""
    kept: list[tuple[np.ndarray, np.ndarray]] = []
    for source, target in pairs:
        a, b = np.array(_normalize(source)), np.array(_normalize(target))
        if any(float(np.linalg.norm(np.cross(a, k[0]))) < 1e-6 for k in kept):
            continue
        kept.append((a, b))
    if not kept:
        return None
    if len(kept) == 1:
        a, b = kept[0]
        q = _quaternion_aligning(tuple(a), tuple(b))
        w, x, y, z = q
        return np.array(
            [
                [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
            ]
        )
    h = sum(np.outer(a, b) for a, b in kept)
    u, _s, vt = np.linalg.svd(h)
    d = np.sign(np.linalg.det(vt.T @ u.T)) or 1.0
    return vt.T @ np.diag([1.0, 1.0, d]) @ u.T


def _add_mate_constraints(
    system: slvs.System,
    builder: _DrivenGeometryBuilder,
    mate: Mate,
    driven: _ResolvedGeometry,
    fixed: _ResolvedGeometry,
    driven_ref: MateEntityRef,
) -> None:
    """Adds `mate`'s own constraint(s) to `system` - `driven`/`fixed` are
    already resolved (driven still local, ready for `builder`; fixed
    already placed in world space by `_place_in_world`). Raises
    `_unsupported_mate_geometry` (named after `driven_ref` - either side of
    a mismatched pair is equally "the" problem, so naming the driven side
    consistently is simpler than picking whichever one is actually at
    fault) for a reference-kind/`MateType` mismatch this module doesn't
    support (see this module's own docstring for the documented v1 gaps)."""
    ref_placeholder = driven_ref
    mate = _effective_mate(mate, driven, fixed)

    if mate.type == MateType.COINCIDENT:
        if driven.plane is not None and fixed.plane is not None:
            # Not flipped (the default): the two faces sit flush facing
            # *each other* - physically valid touching solids have their
            # outward normals pointing in opposite directions (this is
            # SolidWorks' own Coincident-mate default). `flipped=True` is
            # the same-direction (surfaces co-facing, geometrically
            # overlapping) configuration instead - a real option some
            # assemblies genuinely need (e.g. a deliberately-open/
            # see-through pair, or disambiguating a symmetric part), not a
            # mistake. See `_direction_lock`'s own docstring for why
            # *which* of the two parallel branches is picked by
            # `solve_occurrence_from_guess`'s own warm-start seed, not a constraint.
            driven_point = builder.point(driven.plane.origin)
            fixed_workplane = _fixed_workplane(system, fixed.plane)
            system.addPointInPlane(driven_point, fixed_workplane, group=_SOLVE_GROUP)
            _direction_lock(system, builder, driven.plane.origin, driven.plane.normal, fixed.plane.normal)
        elif driven.plane is not None:
            assert fixed.point is not None
            fixed_point = _fixed_point(system, fixed.point)
            driven_workplane_origin = builder.point(driven.plane.origin)
            driven_workplane_normal = builder.normal_from_quaternion(
                _quaternion_from_basis(driven.plane.x_axis, driven.plane.y_axis, driven.plane.normal)
            )
            driven_workplane = system.addWorkplane(driven_workplane_origin, driven_workplane_normal, group=_SOLVE_GROUP)
            system.addPointInPlane(fixed_point, driven_workplane, group=_SOLVE_GROUP)
        elif fixed.plane is not None:
            assert driven.point is not None
            driven_point = builder.point(driven.point)
            fixed_workplane = _fixed_workplane(system, fixed.plane)
            system.addPointInPlane(driven_point, fixed_workplane, group=_SOLVE_GROUP)
        else:
            if driven.point is None or fixed.point is None:
                raise _unsupported_mate_geometry(ref_placeholder, "a point or plane on each side")
            driven_point = builder.point(driven.point)
            fixed_point = _fixed_point(system, fixed.point)
            system.addPointsCoincident(driven_point, fixed_point, group=_SOLVE_GROUP)
        return

    if mate.type == MateType.CONCENTRIC:
        if driven.axis_origin is None or driven.direction is None or fixed.axis_origin is None or fixed.direction is None:
            raise _unsupported_mate_geometry(ref_placeholder, "an axis (a cylindrical face or circular edge) on each side")
        driven_line = builder.line(driven.axis_origin, driven.direction)
        driven_origin_point = builder.point(driven.axis_origin)
        fixed_line = _fixed_line(system, fixed.axis_origin, fixed.direction)
        system.addParallel(driven_line, fixed_line, group=_SOLVE_GROUP)
        system.addPointOnLine(driven_origin_point, fixed_line, group=_SOLVE_GROUP)
        # Test report item 4: "Allow rotation" unchecked - on top of the
        # axis-to-axis lock above (which alone leaves both translation along,
        # and rotation about, the shared axis free), also locks rotation
        # about that axis by forcing a deterministic perpendicular reference
        # line on each side (`_ResolvedGeometry.perp`, always populated
        # alongside an axis reference) parallel to one another - an
        # `addAngle(0, ...)` between them rather than a second `addParallel`
        # so this reads as what it is (a rotation-lock constraint), even
        # though `addParallel` would be numerically equivalent (0 degrees).
        # Translation along the axis stays free either way - this only ever
        # removes the spin DOF, never combines with an implicit DISTANCE/
        # COINCIDENT lock, matching the "CONCENTRIC only supports axis-to-
        # axis" v1 scope this module's own docstring already documents.
        if not mate.allow_rotation:
            assert driven.perp is not None and fixed.perp is not None
            driven_perp_line = builder.line(driven.axis_origin, driven.perp)
            fixed_perp_line = _fixed_line(system, fixed.axis_origin, fixed.perp)
            # Bug fix (test report item 4, bolt-in-hole repro): was
            # `addAngle(0.0, ...)`, whose residual (`cos(theta) - cos(0)`) has
            # a Jacobian that is *exactly* zero at its own target (`sin(0) ==
            # 0`) - the identical degeneracy `_direction_lock`'s own docstring
            # documents and avoids for COINCIDENT's plane-lock ("rejected
            # approach 3"). `addParallel` has the same 0-degree solution but a
            # non-degenerate (cross-product) Jacobian there, so the solve can
            # actually converge onto it - see `solve_occurrence_from_guess`'s own
            # `seed_rotation_quaternion` handling for how the resulting
            # sign/branch ambiguity (parallel is satisfied at 0 *or* 180
            # degrees) is resolved via a warm start instead of a constraint,
            # the same pattern already used for COINCIDENT.
            system.addParallel(driven_perp_line, fixed_perp_line, group=_SOLVE_GROUP)
        return

    if mate.type == MateType.PARALLEL:
        if driven.direction is None or fixed.direction is None:
            raise _unsupported_mate_geometry(ref_placeholder, "a direction (a face normal or an axis) on each side")
        driven_origin = driven.axis_origin if driven.axis_origin is not None else (driven.point or (0.0, 0.0, 0.0))
        fixed_origin = fixed.axis_origin if fixed.axis_origin is not None else (fixed.point or (0.0, 0.0, 0.0))
        driven_line = builder.line(driven_origin, driven.direction)
        fixed_line = _fixed_line(system, fixed_origin, fixed.direction)
        system.addParallel(driven_line, fixed_line, group=_SOLVE_GROUP)
        return

    if mate.type == MateType.ANGLE:
        if driven.direction is None or fixed.direction is None:
            raise _unsupported_mate_geometry(ref_placeholder, "a direction (a face normal or an axis) on each side")
        if mate.value is None:
            raise _unsupported_mate_geometry(ref_placeholder, "a value (degrees)")
        driven_origin = driven.axis_origin if driven.axis_origin is not None else (driven.point or (0.0, 0.0, 0.0))
        fixed_origin = fixed.axis_origin if fixed.axis_origin is not None else (fixed.point or (0.0, 0.0, 0.0))
        driven_line = builder.line(driven_origin, driven.direction)
        fixed_line = _fixed_line(system, fixed_origin, fixed.direction)
        system.addAngle(mate.value, bool(mate.secondary_flip), driven_line, fixed_line, group=_SOLVE_GROUP)
        return

    if mate.type == MateType.DISTANCE:
        if mate.value is None:
            raise _unsupported_mate_geometry(ref_placeholder, "a value (mm)")
        distance = abs(mate.value)
        # The side (`secondary_flip`): `addPointPlaneDistance` is SIGNED, so the chosen side is simply its sign.
        signed_distance = _flip_sign(mate) * distance
        if driven.plane is not None and fixed.plane is not None:
            # Unlike COINCIDENT's plane-plane case, this keeps the two
            # planes merely parallel (`addParallel`, 2 DOF - direction
            # only), not fully orientation-locked (`addSameOrientation`,
            # 3 DOF) - a "these two flat faces are N mm apart" mate has no
            # reason to also lock spin about the shared normal, unlike a
            # flush COINCIDENT mate where this module already documents
            # that simplification as a deliberate v1 gap.
            driven_point = builder.point(driven.plane.origin)
            driven_line = builder.line(driven.plane.origin, driven.plane.normal)
            fixed_workplane = _fixed_workplane(system, fixed.plane)
            fixed_line = _fixed_line(system, fixed.plane.origin, fixed.plane.normal)
            system.addPointPlaneDistance(signed_distance, driven_point, fixed_workplane, group=_SOLVE_GROUP)
            system.addParallel(driven_line, fixed_line, group=_SOLVE_GROUP)
        elif driven.plane is not None:
            assert fixed.point is not None
            fixed_point = _fixed_point(system, fixed.point)
            driven_workplane_origin = builder.point(driven.plane.origin)
            driven_workplane_normal = builder.normal_from_quaternion(
                _quaternion_from_basis(driven.plane.x_axis, driven.plane.y_axis, driven.plane.normal)
            )
            driven_workplane = system.addWorkplane(driven_workplane_origin, driven_workplane_normal, group=_SOLVE_GROUP)
            system.addPointPlaneDistance(signed_distance, fixed_point, driven_workplane, group=_SOLVE_GROUP)
        elif fixed.plane is not None:
            assert driven.point is not None
            driven_point = builder.point(driven.point)
            fixed_workplane = _fixed_workplane(system, fixed.plane)
            system.addPointPlaneDistance(signed_distance, driven_point, fixed_workplane, group=_SOLVE_GROUP)
        elif (
            driven.axis_origin is not None
            and driven.direction is not None
            and fixed.axis_origin is not None
            and fixed.direction is not None
        ):
            # Phase 13 (`docs/assembly-scope.md` §6 `[15]`): axis-to-axis
            # DISTANCE - "these two parallel shafts/dowel-pin axes are N mm
            # apart," the "parallel-shaft center-distance" case this
            # module's own docstring used to list as unsupported. Checked
            # `py_slvs`'s own primitives first, mirroring Phase 6's own
            # "three rejected approaches" process rather than inventing new
            # math: there is no direct line-to-line distance constraint
            # (`system.addPointLineDistance` is the closest primitive), but
            # a point-to-line distance *is* exactly the true axis-to-axis
            # distance as long as the two axes are actually forced parallel
            # first (`addParallel`, the same call CONCENTRIC already makes
            # one line up) - for two non-parallel lines, point-line distance
            # varies along the line and would silently mean something
            # different depending on the fixed point py_slvs happened to
            # measure from, so `addParallel` here isn't merely a nicety, it
            # is what makes "the" distance well-defined at all.
            driven_line = builder.line(driven.axis_origin, driven.direction)
            driven_point = builder.point(driven.axis_origin)
            fixed_line = _fixed_line(system, fixed.axis_origin, fixed.direction)
            system.addParallel(driven_line, fixed_line, group=_SOLVE_GROUP)
            system.addPointLineDistance(distance, driven_point, fixed_line, group=_SOLVE_GROUP)
        else:
            if driven.point is None or fixed.point is None:
                raise _unsupported_mate_geometry(ref_placeholder, "a point, plane, or axis on each side")
            driven_point = builder.point(driven.point)
            fixed_point = _fixed_point(system, fixed.point)
            system.addPointsDistance(distance, driven_point, fixed_point, group=_SOLVE_GROUP)
        return

    raise AssertionError(f"unhandled MateType: {mate.type}")  # pragma: no cover


def _mate_residual_satisfied(mate: Mate, driven_world: _ResolvedGeometry, fixed: _ResolvedGeometry) -> bool:
    """Recomputes `mate`'s own constraint violation directly from
    `driven_world` (the driven Occurrence's geometry placed into world space
    by the just-solved transform) and `fixed` (already world-placed) -
    `solve_occurrence_from_guess`'s own residual-verified-convergence fallback, run only
    when `py_slvs`'s raw `result_code` reported failure.

    Mirrors `app.sketch.solver._residual_verified_convergence`'s exact
    reasoning (see that function's own docstring for the full story):
    `result_code` cannot tell "every constraint is actually satisfied, just
    redundantly so in a way this build's rank-deficiency handling doesn't
    cleanly certify" apart from a genuine conflict. Confirmed directly
    against the bug report this fixes - a CONCENTRIC mate (bolt shaft to
    hole axis) followed by a COINCIDENT mate (bolt-head underside plane to
    plate face): a bolt's own head-underside plane normal is, by
    construction, parallel to its own shaft axis, so `_direction_lock`'s own
    `addParallel` (COINCIDENT's plane-plane branch) ends up forcing the
    *exact same* direction CONCENTRIC's `addParallel` already forces, via a
    second, independently-built pair of line entities - mathematically
    redundant, not conflicting, but `py_slvs` reports a non-zero
    `result_code` for it regardless (same "redundant produces the identical
    ambiguous code as a real conflict" shape `app.sketch.solver`'s own
    `_REDUNDANCY_SAFE_CONSTRAINT_TYPES`/`_residual_verified_convergence`
    comments already document at length for the 2D sketch solver).

    Each branch below checks exactly the geometric relationship the
    matching branch of `_add_mate_constraints` encodes as a `py_slvs`
    constraint - a plane-plane COINCIDENT checks point-in-plane distance
    *and* direction parallelism (`_direction_lock`'s own pair), CONCENTRIC
    checks axis-direction parallelism *and* the driven axis origin lying on
    the fixed axis line, and so on. Returns `False` (never raises) for any
    geometry shape `_add_mate_constraints` itself would have rejected before
    ever reaching `system.solve` - reaching this function at all already
    means the constraints were built successfully, so a missing point/plane/
    axis here can only mean the solve genuinely left it unset, a real
    non-convergence rather than an ambiguous one."""
    mate = resolve_branch(mate, driven_world, fixed)
    mate = _effective_mate(mate, driven_world, fixed)
    align = _align_sign(mate)
    if mate.type == MateType.COINCIDENT:
        if driven_world.plane is not None and fixed.plane is not None:
            return _point_plane_distance(
                driven_world.plane.origin, fixed.plane.origin, fixed.plane.normal
            ) <= _RESIDUAL_TOLERANCE and _direction_matches(driven_world.plane.normal, fixed.plane.normal, align)
        if driven_world.plane is not None:
            if fixed.point is None:
                return False
            return _point_plane_distance(fixed.point, driven_world.plane.origin, driven_world.plane.normal) <= _RESIDUAL_TOLERANCE
        if fixed.plane is not None:
            if driven_world.point is None:
                return False
            return _point_plane_distance(driven_world.point, fixed.plane.origin, fixed.plane.normal) <= _RESIDUAL_TOLERANCE
        if driven_world.point is None or fixed.point is None:
            return False
        return _magnitude(_vec_sub(driven_world.point, fixed.point)) <= _RESIDUAL_TOLERANCE

    if mate.type == MateType.CONCENTRIC:
        if (
            driven_world.axis_origin is None
            or driven_world.direction is None
            or fixed.axis_origin is None
            or fixed.direction is None
        ):
            return False
        axis_satisfied = _direction_matches(driven_world.direction, fixed.direction, align) and (
            _point_line_distance(driven_world.axis_origin, fixed.axis_origin, fixed.direction) <= _RESIDUAL_TOLERANCE
        )
        if not axis_satisfied:
            return False
        # Test report item 4: mirrors `_add_mate_constraints`' own extra
        # `allow_rotation=False` constraint - `driven_world.perp`/`fixed.perp`
        # went through the exact same `_place_in_world` rotation `direction`
        # itself did, so this residual check compares the same two lines
        # that constraint actually built (on the spin half-turn `secondary_flip` names).
        if not mate.allow_rotation:
            if driven_world.perp is None or fixed.perp is None:
                return False
            return _direction_matches(driven_world.perp, fixed.perp, _flip_sign(mate))
        return True

    if mate.type == MateType.PARALLEL:
        if driven_world.direction is None or fixed.direction is None:
            return False
        return _direction_matches(driven_world.direction, fixed.direction, align)

    if mate.type == MateType.ANGLE:
        if driven_world.direction is None or fixed.direction is None or mate.value is None:
            return False
        dot = max(-1.0, min(1.0, _dot(_normalize(driven_world.direction), _normalize(fixed.direction))))
        actual_degrees = math.degrees(math.acos(dot))
        target_degrees = abs(mate.value) % 360
        target_degrees = min(target_degrees, 360 - target_degrees)
        # The angle or its supplement (`secondary_flip` names which one the solve targets; either is a legitimate
        # solved state for this check, as before).
        supplement_degrees = 180 - target_degrees
        if not (
            abs(actual_degrees - target_degrees) <= _RESIDUAL_ANGLE_TOLERANCE_DEGREES
            or abs(actual_degrees - supplement_degrees) <= _RESIDUAL_ANGLE_TOLERANCE_DEGREES
        ):
            return False
        hinge = _angle_hinge(mate, driven_world, fixed) if mate.alignment is not None else None
        if hinge is not None:
            # about a hinge the swing must also be the named way (+theta or -theta): sine = +-sin(target)
            expected = _align_sign(mate) * math.sin(_angle_target_radians(mate))
            return abs(_hinge_sine(driven_world, fixed, hinge) - expected) <= 2e-4
        return True

    if mate.type == MateType.DISTANCE:
        if mate.value is None:
            return False
        target = abs(mate.value)
        signed_target = _flip_sign(mate) * target
        offset = _signed_offset(mate, driven_world, fixed)
        if driven_world.plane is not None and fixed.plane is not None:
            return abs(offset - signed_target) <= _RESIDUAL_TOLERANCE and _direction_matches(
                driven_world.plane.normal, fixed.plane.normal, align
            )
        if driven_world.plane is not None:
            if fixed.point is None:
                return False
            return abs(offset - signed_target) <= _RESIDUAL_TOLERANCE
        if fixed.plane is not None:
            if driven_world.point is None:
                return False
            return abs(offset - signed_target) <= _RESIDUAL_TOLERANCE
        if (
            driven_world.axis_origin is not None
            and driven_world.direction is not None
            and fixed.axis_origin is not None
            and fixed.direction is not None
        ):
            actual = _point_line_distance(driven_world.axis_origin, fixed.axis_origin, fixed.direction)
            return abs(actual - target) <= _RESIDUAL_TOLERANCE and _direction_matches(
                driven_world.direction, fixed.direction, align
            )
        if driven_world.point is None or fixed.point is None:
            return False
        actual = _magnitude(_vec_sub(driven_world.point, fixed.point))
        return abs(actual - target) <= _RESIDUAL_TOLERANCE

    return False  # pragma: no cover - every MateType is handled above


def _mate_residual_vector(mate: Mate, driven_world: _ResolvedGeometry, fixed: _ResolvedGeometry) -> tuple[float, ...]:
    """Fix (test report item 4's own "dof" follow-up - see `MateSolveResult.
    dof`'s own docstring for why `system.Dof` itself can't be trusted): the
    continuous, everywhere-smooth counterpart of `_mate_residual_satisfied`
    above - encodes the exact same geometric relationship each
    `_add_mate_constraints` branch builds, but as a residual *vector* (never
    a boolean, and deliberately never an `abs`/`sqrt`-based magnitude or an
    `acos`-based angle) so `_independent_dof`'s own finite-difference
    Jacobian is well-defined and non-degenerate exactly at a converged
    solution, not just away from it - the identical "a magnitude/cosine
    measure's own Jacobian vanishes at its own target" lesson this module's
    CONCENTRIC `allow_rotation=False` fix already learned (see that branch's
    own comment in `_add_mate_constraints`) applies equally to *diagnosing*
    DOF, not just to *solving* for it.

    Entries are allowed to be linearly dependent on one another (e.g. a
    `cross(a, b)` residual's 3 components, only 2 of which are ever
    independent for a unit-vector pair) - deliberately not hand-reduced to
    a minimal independent set, since `_independent_dof`'s own `numpy.
    linalg.matrix_rank` (SVD-based) already finds the *true* combined rank
    across every mate's own residual stacked together, correctly
    regardless of how many redundant-looking components any one mate
    contributes - unlike `system.Dof`'s own naive per-equation tally, which
    is exactly the failure mode this fix replaces (`app/sketch/solver.py`'s
    own sibling docstring: "does not distinguish [a genuinely redundant
    equation] ... it reports 0 even while a real ... degree of freedom ...
    remains")."""
    mate = resolve_branch(mate, driven_world, fixed)
    mate = _effective_mate(mate, driven_world, fixed)
    align = _align_sign(mate)

    def direction_rows(a: Vec3, b: Vec3, sign: float) -> tuple[float, ...]:
        # `a - sign * b`: zero ONLY when `a` points the way `sign * b` does. Three rows of rank two, non-degenerate at the
        # target (unlike `cross(a, b)`, zero for both roots, or a dot product, stationary at its extremum).
        return (a[0] - sign * b[0], a[1] - sign * b[1], a[2] - sign * b[2])

    if mate.type == MateType.COINCIDENT:
        if driven_world.plane is not None and fixed.plane is not None:
            offset = _vec_sub(driven_world.plane.origin, fixed.plane.origin)
            return (_dot(offset, fixed.plane.normal), *direction_rows(driven_world.plane.normal, fixed.plane.normal, align))
        if driven_world.plane is not None:
            if fixed.point is None:
                return ()
            offset = _vec_sub(fixed.point, driven_world.plane.origin)
            return (_dot(offset, driven_world.plane.normal),)
        if fixed.plane is not None:
            if driven_world.point is None:
                return ()
            offset = _vec_sub(driven_world.point, fixed.plane.origin)
            return (_dot(offset, fixed.plane.normal),)
        if driven_world.point is None or fixed.point is None:
            return ()
        return _vec_sub(driven_world.point, fixed.point)

    if mate.type == MateType.CONCENTRIC:
        if (
            driven_world.axis_origin is None
            or driven_world.direction is None
            or fixed.axis_origin is None
            or fixed.direction is None
        ):
            return ()
        residual = (
            *direction_rows(driven_world.direction, fixed.direction, align),
            *_cross(_vec_sub(driven_world.axis_origin, fixed.axis_origin), fixed.direction),
        )
        if not mate.allow_rotation:
            if driven_world.perp is None or fixed.perp is None:
                return residual
            residual = (*residual, *direction_rows(driven_world.perp, fixed.perp, _flip_sign(mate)))
        return residual

    if mate.type == MateType.PARALLEL:
        if driven_world.direction is None or fixed.direction is None:
            return ()
        return direction_rows(driven_world.direction, fixed.direction, align)

    if mate.type == MateType.ANGLE:
        if driven_world.direction is None or fixed.direction is None or mate.value is None:
            return ()
        target_degrees = abs(mate.value) % 360
        target_degrees = min(target_degrees, 360 - target_degrees)
        dot = _dot(_normalize(driven_world.direction), _normalize(fixed.direction))
        rows = (dot - math.cos(math.radians(target_degrees)),)
        hinge = _angle_hinge(mate, driven_world, fixed) if mate.alignment is not None else None
        if hinge is not None:
            # about a hinge: the sine of the signed swing is +-sin(target) - zero only on the named way (+theta / -theta)
            rows = (*rows, _hinge_sine(driven_world, fixed, hinge) - _align_sign(mate) * math.sin(math.radians(target_degrees)))
        return rows

    if mate.type == MateType.DISTANCE:
        if mate.value is None:
            return ()
        target = abs(mate.value)
        # Linear in the signed separation, so Gauss-Newton converges in one step from either side (the squared form had
        # a zero gradient at 0 and a ~1e-3 rounding floor on large moves); the side is `secondary_flip`.
        signed_target = _flip_sign(mate) * target
        # Squared forms (no sign to carry) scaled to millimetres, `(x^2 - d^2) / (2 d)`, so one tolerance means the same
        # thing for every mate; the divisor is floored for tiny distances.
        scale = 2.0 * max(target, _DISTANCE_FLOOR)
        offset = _signed_offset(mate, driven_world, fixed)
        if driven_world.plane is not None and fixed.plane is not None:
            return (offset - signed_target, *direction_rows(driven_world.plane.normal, fixed.plane.normal, align))
        if driven_world.plane is not None:
            if fixed.point is None:
                return ()
            return (offset - signed_target,)
        if fixed.plane is not None:
            if driven_world.point is None:
                return ()
            return (offset - signed_target,)
        if (
            driven_world.axis_origin is not None
            and driven_world.direction is not None
            and fixed.axis_origin is not None
            and fixed.direction is not None
        ):
            perp = _cross(_vec_sub(driven_world.axis_origin, fixed.axis_origin), fixed.direction)
            perp_sq = _dot(perp, perp)
            return (
                (perp_sq - target * target) / scale,
                *direction_rows(driven_world.direction, fixed.direction, align),
            )
        if driven_world.point is None or fixed.point is None:
            return ()
        offset_vec = _vec_sub(driven_world.point, fixed.point)
        return ((_dot(offset_vec, offset_vec) - target * target) / scale,)

    return ()  # pragma: no cover - every MateType is handled above


# A central-difference step small enough that a converged solve's own
# residual is locally linear to well within finite-difference noise (every
# geometric quantity here is in millimetres/unitless directions - the same
# order of magnitude `_RESIDUAL_TOLERANCE` itself already assumes), large
# enough that float64 subtraction cancellation doesn't itself dominate the
# result.
_DOF_JACOBIAN_STEP = 1e-6


def _independent_dof(
    resolved: list[tuple[Mate, MateEntityRef, _ResolvedGeometry, _ResolvedGeometry]],
    solved_transform: RigidTransform,
) -> int:
    return _free_motion(resolved, solved_transform)[0]


def _free_motion(
    resolved: list[tuple[Mate, MateEntityRef, _ResolvedGeometry, _ResolvedGeometry]],
    solved_transform: RigidTransform,
) -> tuple[int, tuple[tuple[float, float, float, float, float, float], ...]]:
    """Replaces `system.Dof` (`py_slvs`'s own naive params-minus-equations
    count, confirmed unpatchable - `py-slvs==1.0.6` is a precompiled,
    pinned third-party wheel with no vendored source in this repo, its
    internals unreachable from here) with a from-scratch, numerically
    robust count: the rank of the numerical Jacobian of every applicable
    Mate's own `_mate_residual_vector`, stacked together, with respect to a
    *minimal* 6-parameter local perturbation of `solved_transform` (3
    translation + 3 rotation via a tangent-space perturbation composed onto
    the already-solved orientation - never the redundant 4-parameter unit
    quaternion itself, whose own unit-norm constraint would otherwise
    inflate the apparent rank by exactly 1 every time). `6 - rank` is the
    true count of genuinely independent remaining degrees of freedom,
    correctly collapsing redundant-but-consistent constraints to their real
    rank the same way `numpy.linalg.matrix_rank`'s SVD-based tolerance
    always does - unlike `system.Dof`, confirmed by this module's own
    sibling (`app/sketch/solver.py`) to misreport in exactly this
    "redundant equation counted as if independent" direction.

    No applicable Mates (`resolved` empty) trivially returns 6 (every rigid-
    body DOF free), matching `_solve_occurrence_against`'s own pre-existing
    early return for that case."""
    identity_basis = tuple(tuple(1.0 if i == j else 0.0 for j in range(6)) for i in range(6))
    if not resolved:
        return 6, identity_basis

    def transform_for(delta: tuple[float, float, float, float, float, float]) -> RigidTransform:
        dtx, dty, dtz, rx, ry, rz = delta
        angle = math.sqrt(rx * rx + ry * ry + rz * rz)
        delta_quaternion = (
            (1.0, 0.0, 0.0, 0.0)
            if angle < 1e-12
            else _quaternion_from_axis_angle((rx / angle, ry / angle, rz / angle), math.degrees(angle))
        )
        base_quaternion = _quaternion_from_axis_angle(solved_transform.rotation_axis, solved_transform.rotation_angle_degrees)
        axis, angle_degrees = _axis_angle_from_quaternion(_quaternion_multiply(delta_quaternion, base_quaternion))
        translation = (
            solved_transform.translation[0] + dtx,
            solved_transform.translation[1] + dty,
            solved_transform.translation[2] + dtz,
        )
        return RigidTransform(translation=translation, rotation_axis=axis, rotation_angle_degrees=angle_degrees)

    def residual_at(delta: tuple[float, float, float, float, float, float]) -> list[float]:
        transform = transform_for(delta)
        values: list[float] = []
        for mate, _driven_ref, driven_geometry, fixed_geometry in resolved:
            values.extend(_mate_residual_vector(mate, _place_in_world(driven_geometry, transform), fixed_geometry))
        return values

    baseline = residual_at((0.0, 0.0, 0.0, 0.0, 0.0, 0.0))
    if not baseline:
        return 6, identity_basis

    jacobian = np.zeros((len(baseline), 6))
    for i in range(6):
        plus_delta = [0.0] * 6
        plus_delta[i] = _DOF_JACOBIAN_STEP
        minus_delta = [0.0] * 6
        minus_delta[i] = -_DOF_JACOBIAN_STEP
        plus = residual_at(tuple(plus_delta))
        minus = residual_at(tuple(minus_delta))
        jacobian[:, i] = [(p - m) / (2 * _DOF_JACOBIAN_STEP) for p, m in zip(plus, minus)]

    rank = int(np.linalg.matrix_rank(jacobian))
    # The nullspace of the Jacobian (the trailing right-singular vectors) IS the
    # free motion: moving along any of them changes no mate's residual (to
    # first order). Same rank as the DOF count by construction.
    _u, _s, vt = np.linalg.svd(jacobian)
    free = tuple(tuple(float(x) for x in row) for row in vt[rank:])
    return max(0, 6 - rank), free


def _applicable_mates(
    part: Part, driven_occurrence_id: str, extra_mates: tuple[Mate, ...] = ()
) -> list[tuple[Mate, MateEntityRef, MateEntityRef]]:
    """Every non-suppressed Mate in `part.mates` - then `extra_mates`, the
    hypothetical mates of a dry-run preview - with exactly one of its two
    `references` naming `driven_occurrence_id` - returned as `(mate,
    driven_ref, fixed_ref)` triples. A Mate with zero or two references to
    the driven Occurrence doesn't apply to *this* solve (the latter would
    be a self-mate, which nothing in this codebase can create)."""
    applicable = []
    for mate in (*part.mates, *extra_mates):
        if mate.suppressed or len(mate.references) != 2 or mate.type in COUPLER_TYPES or mate.type in LIMIT_TYPES:
            continue  # a coupler / limit is a group-model mate only (`app.document.coupler`, `app.document.limit`); py-slvs knows nothing of it
        first, second = mate.references
        # A reference into a sub-assembly (`outer/inner`) belongs to the
        # top-level Occurrence `outer`: that is what moves when it is driven.
        # (A Width reference spanning two top-level occurrences involves both.)
        first_tops = mate_ref_tops(first)
        second_tops = mate_ref_tops(second)
        if driven_occurrence_id in first_tops and driven_occurrence_id not in second_tops:
            applicable.append((mate, first, second))
        elif driven_occurrence_id in second_tops and driven_occurrence_id not in first_tops:
            applicable.append((mate, second, first))
    return applicable


def _find_occurrence(part: Part, occurrence_id: str) -> Occurrence:
    for occurrence in part.occurrences:
        if occurrence.id == occurrence_id:
            return occurrence
    raise _driven_occurrence_not_found(occurrence_id)


def _solve_occurrence_against(
    document: Document,
    part: Part,
    driven_occurrence: Occurrence,
    applicable: list[tuple[Mate, MateEntityRef, MateEntityRef]],
) -> MateSolveResult:
    """The `py_slvs` tail of `solve_occurrence_from_guess` - given `driven_occurrence` and
    its own already-gathered `applicable` Mate list, does the actual solve and returns
    the result. Never mutates `driven_occurrence` or `part.mates` itself -
    each caller decides separately whether/how to persist anything.

    No applicable Mates at all is not an error - returns the Occurrence's
    own current transform, trivially "converged" (nothing to satisfy).
    Seeds the solve's own initial guess from the occurrence's (or the
    caller's wanted) transform, so a dragged position snaps to the *nearest*
    mate-satisfying placement rather than jumping to some other,
    arbitrarily-different valid solution."""
    if not applicable:
        return MateSolveResult(
            converged=True,
            transform=driven_occurrence.transform,
            dof=6,
        )

    if driven_occurrence.part_id is None or driven_occurrence.part_id not in document.parts:
        raise _unresolved_mate_occurrence(driven_occurrence.id)
    driven_target_part = document.parts[driven_occurrence.part_id]
    driven_bodies = compute_part_bodies(driven_target_part)

    # Resolve every applicable Mate's own geometry *before* building the
    # `py_slvs` system - both because the constraint-building pass below
    # needs it, and because a COINCIDENT plane-plane pair's own geometry
    # gives `_quaternion_aligning` what it needs for a warm-start seed
    # (see that function's own docstring for why the seed, not an extra
    # constraint, is what actually disambiguates `flipped`).
    resolved: list[tuple[Mate, MateEntityRef, _ResolvedGeometry, _ResolvedGeometry]] = []
    for mate, driven_ref, fixed_ref in applicable:
        # A driven reference may point inside a sub-assembly the driven
        # Occurrence places (`driven/inner`): resolve it against the leaf Part
        # and lift it into the driven Occurrence's own local frame.
        driven_leaf_part, driven_inner = _target_part_and_transform(
            document, driven_target_part, driven_ref.occurrence_id[len(driven_occurrence.id) + 1 :]
        )
        driven_geometry = _resolve_local_geometry(
            driven_leaf_part,
            driven_bodies if driven_leaf_part is driven_target_part else compute_part_bodies(driven_leaf_part),
            driven_ref,
            document,
            part,
        )
        if driven_inner is not None:
            driven_geometry = _place_in_world(driven_geometry, driven_inner)
        if midplane_spans_tops(fixed_ref):
            fixed_geometry = cross_midplane_geometry(document, part, fixed_ref)  # already in world space
        else:
            fixed_target_part, fixed_transform = _target_part_and_transform(document, part, fixed_ref.occurrence_id)
            fixed_bodies = compute_part_bodies(fixed_target_part)
            fixed_local_geometry = _resolve_local_geometry(fixed_target_part, fixed_bodies, fixed_ref, document, part)
            fixed_geometry = (
                fixed_local_geometry if fixed_transform is None else _place_in_world(fixed_local_geometry, fixed_transform)
            )
        # Closest -> a concrete branch, from the pose this solve starts from (a mate that already names its branch keeps it),
        # oriented the way THIS solve sees the pair (the driven side is reference 1 when `swapped`: see `orient_branch`).
        mate, _canonical = resolve_oriented_branch(
            mate,
            _place_in_world(driven_geometry, driven_occurrence.transform),
            fixed_geometry,
            swapped=driven_ref is mate.references[1],
        )
        resolved.append((mate, driven_ref, driven_geometry, fixed_geometry))

    # Warm start on the mates' branches. Every parallel-type constraint below is sign-agnostic (py-slvs' `addParallel`
    # holds for both roots), so which root Newton ends on is decided here: turn the occurrence ONCE onto all of its
    # alignment targets together (`alignment_pairs` / `rotation_onto_pairs` - the minimal rotation for a single pair, a
    # least-squares fit for several), composed onto its CURRENT rotation so the spin about the shared direction survives
    # (a face-to-face mate leaves that spin free, found in VR testing of live mate-constrained dragging). A direction that
    # is already on its branch needs no extra rotation, one pointing the wrong way is flipped by the minimal one.
    current_rotation = _quaternion_from_axis_angle(
        driven_occurrence.transform.rotation_axis, driven_occurrence.transform.rotation_angle_degrees
    )
    pairs: list[tuple[Vec3, Vec3]] = []
    for mate, _driven_ref, driven_geometry, fixed_geometry in resolved:
        pairs.extend(alignment_pairs(mate, _place_in_world(driven_geometry, driven_occurrence.transform), fixed_geometry))
    seed_rotation_quaternion: Quaternion | None = None
    seed_matrix = rotation_onto_pairs(pairs)
    if seed_matrix is not None:
        extra_rotation = _quaternion_from_basis(
            tuple(float(c) for c in seed_matrix[:, 0]),
            tuple(float(c) for c in seed_matrix[:, 1]),
            tuple(float(c) for c in seed_matrix[:, 2]),
        )
        seed_rotation_quaternion = _quaternion_multiply(extra_rotation, current_rotation)

    system = slvs.System()
    seed_translation = driven_occurrence.transform.translation
    seed_quaternion = seed_rotation_quaternion or _quaternion_from_axis_angle(
        driven_occurrence.transform.rotation_axis, driven_occurrence.transform.rotation_angle_degrees
    )
    transform_params = _TransformParams(
        dx=system.addParamV(seed_translation[0], group=_SOLVE_GROUP),
        dy=system.addParamV(seed_translation[1], group=_SOLVE_GROUP),
        dz=system.addParamV(seed_translation[2], group=_SOLVE_GROUP),
        qw=system.addParamV(seed_quaternion[0], group=_SOLVE_GROUP),
        qx=system.addParamV(seed_quaternion[1], group=_SOLVE_GROUP),
        qy=system.addParamV(seed_quaternion[2], group=_SOLVE_GROUP),
        qz=system.addParamV(seed_quaternion[3], group=_SOLVE_GROUP),
    )
    # The unit-quaternion entity `SLVS_E_TRANSFORM`'s own DOC.txt requires
    # alongside the transform's params, in the same solve group (see this
    # module's own docstring) - never otherwise referenced.
    system.addNormal3d(
        transform_params.qw, transform_params.qx, transform_params.qy, transform_params.qz, group=_SOLVE_GROUP
    )
    builder = _DrivenGeometryBuilder(system, transform_params)

    for mate, driven_ref, driven_geometry, fixed_geometry in resolved:
        _add_mate_constraints(system, builder, mate, driven_geometry, fixed_geometry, driven_ref)

    result_code = system.solve(group=_SOLVE_GROUP, reportFailed=True)
    converged = result_code == 0
    translation = (
        system.getParam(transform_params.dx).val,
        system.getParam(transform_params.dy).val,
        system.getParam(transform_params.dz).val,
    )
    quaternion = (
        system.getParam(transform_params.qw).val,
        system.getParam(transform_params.qx).val,
        system.getParam(transform_params.qy).val,
        system.getParam(transform_params.qz).val,
    )
    axis, angle = _axis_angle_from_quaternion(quaternion)
    transform = RigidTransform(translation=translation, rotation_axis=axis, rotation_angle_degrees=angle)

    # Bug fix (on-device feedback: a CONCENTRIC mate followed by a
    # COINCIDENT one on the same driven Occurrence - a bolt shaft in a hole,
    # then its head-underside plane against the plate face - reported
    # `mate_solve_did_not_converge` even though the solved position was
    # geometrically exact): `result_code` alone can't distinguish a genuine
    # conflict from a merely-redundant-but-satisfied constraint set (see
    # `_mate_residual_satisfied`'s own docstring for the full mechanism,
    # mirroring `app.sketch.solver`'s identical, already-proven fallback for
    # the 2D solver) - so a `result_code != 0` here gets one more chance:
    # recompute every applicable Mate's own residual directly from the
    # just-solved `transform`, and only keep reporting non-convergence if at
    # least one Mate's constraint is actually still violated.
    if not converged:
        converged = all(
            _mate_residual_satisfied(mate, _place_in_world(driven_geometry, transform), fixed_geometry)
            for mate, _driven_ref, driven_geometry, fixed_geometry in resolved
        )

    # Fix (test report item 4's own "dof" follow-up): `system.Dof` itself
    # (`py_slvs`'s own naive params-minus-equations count) is replaced with
    # `_independent_dof`'s rank-based recomputation - see that function's
    # own docstring for why. Computed from `transform` regardless of
    # `converged` (an unconverged solve's own `transform` is still whatever
    # Newton's method last reached, a meaningful point to report DOF
    # around, exactly like `system.Dof` itself was already read
    # unconditionally here before this fix).
    dof = _independent_dof(resolved, transform)

    return MateSolveResult(converged=converged, transform=transform, dof=dof)


def solve_occurrence_from_guess(
    document: Document,
    part: Part,
    driven_occurrence_id: str,
    guess: RigidTransform | None,
    extra_mates: tuple[Mate, ...] = (),
) -> MateSolveResult:
    """Solves every Mate of `part.mates` that references `driven_occurrence_id`, against every other referenced Occurrence held
    fixed at its own current transform, seeding the solve from `guess` (a pose the
    client WANTS - e.g. wherever a hand has dragged a part) instead of the
    occurrence's stored transform, and never stores anything: the result
    carries the nearest mate-satisfying pose and this occurrence's own dof
    against frozen peers (the group solver, `assembly_group`, uses it as a
    fallback seed). `guess=None` solves from the stored transform. `extra_mates` are hypothetical mates solved
    alongside the stored ones (a preview's mate, which is not in `part.mates`)."""
    driven_occurrence = _find_occurrence(part, driven_occurrence_id)
    if guess is not None:
        driven_occurrence = replace(driven_occurrence, transform=guess)
    applicable = _applicable_mates(part, driven_occurrence_id, extra_mates)
    return _solve_occurrence_against(document, part, driven_occurrence, applicable)
