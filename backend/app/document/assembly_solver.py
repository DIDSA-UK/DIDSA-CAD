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
- A COINCIDENT mate between two planar references locks the *full*
  relative orientation (`addSameOrientation`, 3 DOF) rather than only the
  2 DOF a real "flush, but free to spin about the shared normal" mate
  should - a deliberate, documented v1 simplification (`addParallel`
  alone cannot disambiguate the `flipped` sign, since two parallel lines
  are equally "parallel" whether pointing the same or opposite ways).
"""

from __future__ import annotations

import math
from dataclasses import dataclass

from fastapi import HTTPException
from OCC.Core.BRepAdaptor import BRepAdaptor_Curve, BRepAdaptor_Surface
from OCC.Core.GeomAbs import GeomAbs_Circle, GeomAbs_Cylinder, GeomAbs_Line, GeomAbs_Plane
from OCC.Core.TopoDS import topods
from py_slvs import slvs

from app.document.assembly import apply_transform_to_direction, apply_transform_to_point
from app.document.create_plane import resolve_plane_ref, resolve_point_ref_position
from app.document.extrude import compute_part_bodies, resolve_subshape_from_bodies
from app.document.measure import single_shape_geometry
from app.document.models import (
    Document,
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

# `solve_occurrence`'s own residual-verified-convergence fallback (see
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
    """`solve_occurrence`'s own result - `converged` mirrors `app.sketch.
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


def _resolve_local_geometry(target_part: Part, bodies: dict, ref: MateEntityRef) -> _ResolvedGeometry:
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
    return _ResolvedGeometry(point=point, plane=plane, axis_origin=axis_origin, direction=direction, perp=perp)


def _target_part_and_transform(
    document: Document, part: Part, occurrence_id: str
) -> tuple[Part, RigidTransform | None]:
    """The Part whose local bodies `occurrence_id` places, plus that
    Occurrence's own current `transform` - `None` for the special `""`
    ("this Part's own root content") occurrence id, which needs no
    transform at all (already at the assembly's own world origin)."""
    if occurrence_id == "":
        return part, None
    for occurrence in part.occurrences:
        if occurrence.id == occurrence_id:
            if occurrence.part_id is None or occurrence.part_id not in document.parts:
                raise _unresolved_mate_occurrence(occurrence_id)
            return document.parts[occurrence.part_id], occurrence.transform
    raise _unresolved_mate_occurrence(occurrence_id)


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
    qw = max(-1.0, min(1.0, q[0]))
    angle_radians = 2.0 * math.acos(qw)
    s = math.sqrt(max(0.0, 1.0 - qw * qw))
    if s < 1e-9:
        return (0.0, 0.0, 1.0), 0.0
    return (q[1] / s, q[2] / s, q[3] / s), math.degrees(angle_radians)


def _quaternion_aligning(source: Vec3, target: Vec3) -> Quaternion:
    """A quaternion rotating unit vector `source` onto unit vector `target`
    - `solve_occurrence`'s own warm-start seed for a COINCIDENT plane-plane
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
    `solve_occurrence`'s own warm-start seed (`_quaternion_aligning`) -
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
            # `solve_occurrence`'s own warm-start seed, not a constraint.
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
            system.addAngle(0.0, False, driven_perp_line, fixed_perp_line, group=_SOLVE_GROUP)
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
        system.addAngle(mate.value, mate.flipped, driven_line, fixed_line, group=_SOLVE_GROUP)
        return

    if mate.type == MateType.DISTANCE:
        if mate.value is None:
            raise _unsupported_mate_geometry(ref_placeholder, "a value (mm)")
        distance = abs(mate.value)
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
            system.addPointPlaneDistance(distance, driven_point, fixed_workplane, group=_SOLVE_GROUP)
            system.addParallel(driven_line, fixed_line, group=_SOLVE_GROUP)
        elif driven.plane is not None:
            assert fixed.point is not None
            fixed_point = _fixed_point(system, fixed.point)
            driven_workplane_origin = builder.point(driven.plane.origin)
            driven_workplane_normal = builder.normal_from_quaternion(
                _quaternion_from_basis(driven.plane.x_axis, driven.plane.y_axis, driven.plane.normal)
            )
            driven_workplane = system.addWorkplane(driven_workplane_origin, driven_workplane_normal, group=_SOLVE_GROUP)
            system.addPointPlaneDistance(distance, fixed_point, driven_workplane, group=_SOLVE_GROUP)
        elif fixed.plane is not None:
            assert driven.point is not None
            driven_point = builder.point(driven.point)
            fixed_workplane = _fixed_workplane(system, fixed.plane)
            system.addPointPlaneDistance(distance, driven_point, fixed_workplane, group=_SOLVE_GROUP)
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
    `solve_occurrence`'s own residual-verified-convergence fallback, run only
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
    if mate.type == MateType.COINCIDENT:
        if driven_world.plane is not None and fixed.plane is not None:
            return _point_plane_distance(
                driven_world.plane.origin, fixed.plane.origin, fixed.plane.normal
            ) <= _RESIDUAL_TOLERANCE and _directions_parallel(driven_world.plane.normal, fixed.plane.normal)
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
        axis_satisfied = _directions_parallel(driven_world.direction, fixed.direction) and (
            _point_line_distance(driven_world.axis_origin, fixed.axis_origin, fixed.direction) <= _RESIDUAL_TOLERANCE
        )
        if not axis_satisfied:
            return False
        # Test report item 4: mirrors `_add_mate_constraints`' own extra
        # `allow_rotation=False` constraint - `driven_world.perp`/`fixed.perp`
        # went through the exact same `_place_in_world` rotation `direction`
        # itself did, so this residual check compares the same two lines
        # that constraint actually built.
        if not mate.allow_rotation:
            if driven_world.perp is None or fixed.perp is None:
                return False
            return _directions_parallel(driven_world.perp, fixed.perp)
        return True

    if mate.type == MateType.PARALLEL:
        if driven_world.direction is None or fixed.direction is None:
            return False
        return _directions_parallel(driven_world.direction, fixed.direction)

    if mate.type == MateType.ANGLE:
        if driven_world.direction is None or fixed.direction is None or mate.value is None:
            return False
        dot = max(-1.0, min(1.0, _dot(_normalize(driven_world.direction), _normalize(fixed.direction))))
        actual_degrees = math.degrees(math.acos(dot))
        target_degrees = abs(mate.value) % 360
        target_degrees = min(target_degrees, 360 - target_degrees)
        # `addAngle`'s own `supplement` toggle (`mate.flipped`) picks which
        # of the two branches `mateTypeHasFlip` already documents client-side
        # - either is a legitimate solved state here.
        supplement_degrees = 180 - target_degrees
        return (
            abs(actual_degrees - target_degrees) <= _RESIDUAL_ANGLE_TOLERANCE_DEGREES
            or abs(actual_degrees - supplement_degrees) <= _RESIDUAL_ANGLE_TOLERANCE_DEGREES
        )

    if mate.type == MateType.DISTANCE:
        if mate.value is None:
            return False
        target = abs(mate.value)
        if driven_world.plane is not None and fixed.plane is not None:
            actual = _point_plane_distance(driven_world.plane.origin, fixed.plane.origin, fixed.plane.normal)
            return abs(actual - target) <= _RESIDUAL_TOLERANCE and _directions_parallel(
                driven_world.plane.normal, fixed.plane.normal
            )
        if driven_world.plane is not None:
            if fixed.point is None:
                return False
            actual = _point_plane_distance(fixed.point, driven_world.plane.origin, driven_world.plane.normal)
            return abs(actual - target) <= _RESIDUAL_TOLERANCE
        if fixed.plane is not None:
            if driven_world.point is None:
                return False
            actual = _point_plane_distance(driven_world.point, fixed.plane.origin, fixed.plane.normal)
            return abs(actual - target) <= _RESIDUAL_TOLERANCE
        if (
            driven_world.axis_origin is not None
            and driven_world.direction is not None
            and fixed.axis_origin is not None
            and fixed.direction is not None
        ):
            actual = _point_line_distance(driven_world.axis_origin, fixed.axis_origin, fixed.direction)
            return abs(actual - target) <= _RESIDUAL_TOLERANCE and _directions_parallel(
                driven_world.direction, fixed.direction
            )
        if driven_world.point is None or fixed.point is None:
            return False
        actual = _magnitude(_vec_sub(driven_world.point, fixed.point))
        return abs(actual - target) <= _RESIDUAL_TOLERANCE

    return False  # pragma: no cover - every MateType is handled above


def _applicable_mates(part: Part, driven_occurrence_id: str) -> list[tuple[Mate, MateEntityRef, MateEntityRef]]:
    """Every non-suppressed Mate in `part.mates` with exactly one of its two
    `references` naming `driven_occurrence_id` - returned as `(mate,
    driven_ref, fixed_ref)` triples. A Mate with zero or two references to
    the driven Occurrence doesn't apply to *this* solve (the latter would
    be a self-mate, which nothing in this codebase can create)."""
    applicable = []
    for mate in part.mates:
        if mate.suppressed or len(mate.references) != 2:
            continue
        first, second = mate.references
        if first.occurrence_id == driven_occurrence_id and second.occurrence_id != driven_occurrence_id:
            applicable.append((mate, first, second))
        elif second.occurrence_id == driven_occurrence_id and first.occurrence_id != driven_occurrence_id:
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
    """The shared tail of `solve_occurrence`/`preview_mate_solve` (test
    report item 3, New Mate ghost preview) - given `driven_occurrence` and
    its own already-gathered `applicable` Mate list (the real ones from
    `part.mates` for `solve_occurrence`; that same list plus one
    hypothetical, not-yet-created Mate for `preview_mate_solve`'s own live
    "New Mate" ghost preview), does the actual `py_slvs` solve and returns
    the result. Never mutates `driven_occurrence` or `part.mates` itself -
    each caller decides separately whether/how to persist anything.

    No applicable Mates at all is not an error - returns the Occurrence's
    own current transform, trivially "converged" (nothing to satisfy).
    Seeds the solve's own initial guess from that same current transform,
    so a gizmo-dragged position (passed in in a live implementation, which
    always writes to `Occurrence.transform` *before* calling this - see the
    router's own `solve_for_occurrence` endpoint) snaps to the *nearest*
    mate-satisfying placement rather than jumping to some other,
    arbitrarily-different valid solution."""
    if not applicable:
        return MateSolveResult(converged=True, transform=driven_occurrence.transform, dof=6)

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
        driven_geometry = _resolve_local_geometry(driven_target_part, driven_bodies, driven_ref)
        fixed_target_part, fixed_transform = _target_part_and_transform(document, part, fixed_ref.occurrence_id)
        fixed_bodies = compute_part_bodies(fixed_target_part)
        fixed_local_geometry = _resolve_local_geometry(fixed_target_part, fixed_bodies, fixed_ref)
        fixed_geometry = (
            fixed_local_geometry if fixed_transform is None else _place_in_world(fixed_local_geometry, fixed_transform)
        )
        resolved.append((mate, driven_ref, driven_geometry, fixed_geometry))

    seed_rotation_quaternion: Quaternion | None = None
    for mate, _driven_ref, driven_geometry, fixed_geometry in resolved:
        if mate.type == MateType.COINCIDENT and driven_geometry.plane is not None and fixed_geometry.plane is not None:
            target_direction = fixed_geometry.plane.normal if mate.flipped else tuple(-c for c in fixed_geometry.plane.normal)
            seed_rotation_quaternion = _quaternion_aligning(driven_geometry.plane.normal, target_direction)
            break

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

    return MateSolveResult(converged=converged, transform=transform, dof=system.Dof)


def solve_occurrence(document: Document, part: Part, driven_occurrence_id: str) -> MateSolveResult:
    """Solves every Mate in `part.mates` that references
    `driven_occurrence_id`, against every other referenced Occurrence held
    fixed at its own current transform - the real prerequisite this
    module's own docstring describes. `driven_occurrence_id` must name a
    real, top-level entry in `part.occurrences` (never `""` - the root has
    no transform of its own to solve for). See `_solve_occurrence_against`
    for the actual solve."""
    driven_occurrence = _find_occurrence(part, driven_occurrence_id)
    applicable = _applicable_mates(part, driven_occurrence_id)
    return _solve_occurrence_against(document, part, driven_occurrence, applicable)


def preview_mate_solve(
    document: Document, part: Part, driven_occurrence_id: str, extra_mate: Mate
) -> MateSolveResult:
    """Test report item 3 (New Mate ghost preview): like `solve_occurrence`,
    but against `part.mates` *plus* one hypothetical `extra_mate` - never
    appended to `part.mates`, never persisted anywhere. Lets the client show
    a live ghost preview of where a Mate currently being authored in the UI
    (`MatePanel`, before the user ever taps Confirm) would actually place
    its driven Occurrence, recomputed on every type/value/flip/allow-
    rotation change. `extra_mate.references` must have exactly 2 entries,
    exactly one of them naming `driven_occurrence_id` (the router's own
    `preview_mate_solve_endpoint` builds it directly from the same payload
    shape `POST .../mates` validates, so this is always true in practice);
    if neither or both do, `extra_mate` is silently dropped and this behaves
    exactly like `solve_occurrence` (the real Mates already on
    `driven_occurrence_id`, if any) rather than raising - a live preview
    tolerates a still-being-edited, momentarily-nonsensical selection."""
    driven_occurrence = _find_occurrence(part, driven_occurrence_id)
    applicable = _applicable_mates(part, driven_occurrence_id)
    if len(extra_mate.references) == 2:
        first, second = extra_mate.references
        if first.occurrence_id == driven_occurrence_id and second.occurrence_id != driven_occurrence_id:
            applicable = [*applicable, (extra_mate, first, second)]
        elif second.occurrence_id == driven_occurrence_id and first.occurrence_id != driven_occurrence_id:
            applicable = [*applicable, (extra_mate, second, first)]
    return _solve_occurrence_against(document, part, driven_occurrence, applicable)
