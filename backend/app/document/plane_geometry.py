"""Pure-Python plane-geometry math for CreatePlaneFeature's NORMAL_TO_LINE_
AT_POINT case (C2) plus the fixed-plane basis table every Sketch embedding
(fixed or, since C3, anchored to a custom plane) is built from - deliberately
has no OCCT/pythonocc-core import anywhere in this file (only app.sketch.
models/store, themselves OCCT-free), so the point-on-line/off-line validation
this prompt's own testing instructions call out can run for real in this
sandbox, unlike almost every other backend prompt's geometry construction.
See app.document.create_plane for the OFFSET_FACE/MIDPLANE cases, which do
need OCCT (a planarity/parallelism check has no OCCT-free equivalent).
"""

import math

from fastapi import HTTPException

from app.document.models import ResolvedPlane
from app.sketch.models import Line, Plane, Point, SketchEntityRef
from app.sketch.store import get_sketch_or_404, resolve_sketch_entity

Vector3 = tuple[float, float, float]


# C3: the exact fixed-plane origin/basis every Sketch on a fixed `Plane`
# embeds through - matches `_sketch_point_to_world` below (and the client's
# own `sketchPointToWorld`, client/lib/viewport3d/sketch_geometry_3d.dart)
# exactly: `origin + x * x_axis + y * y_axis` must reproduce the same
# world point `_sketch_point_to_world(plane, x, y)` already returns for
# every (x, y). Deliberately hand-written per plane rather than derived from
# a `normal`-only formula (e.g. a generic cross-product) - hand-verification
# shows no single such formula reproduces all three fixed planes' existing,
# already-shipped conventions at once (XZ's own (x_axis, y_axis, normal)
# triple is left-handed: `normal != x_axis cross y_axis` there, only for XZ -
# an accident of history now baked into every already-created XZ Sketch, not
# something to "fix" retroactively), so an explicit lookup table is the only
# option that is both correct and unsurprising here.
_PLANE_BASIS: dict[Plane, ResolvedPlane] = {
    Plane.XY: ResolvedPlane(
        origin=(0.0, 0.0, 0.0), normal=(0.0, 0.0, 1.0), x_axis=(1.0, 0.0, 0.0), y_axis=(0.0, 1.0, 0.0)
    ),
    Plane.XZ: ResolvedPlane(
        origin=(0.0, 0.0, 0.0), normal=(0.0, 1.0, 0.0), x_axis=(1.0, 0.0, 0.0), y_axis=(0.0, 0.0, 1.0)
    ),
    Plane.YZ: ResolvedPlane(
        origin=(0.0, 0.0, 0.0), normal=(1.0, 0.0, 0.0), x_axis=(0.0, 1.0, 0.0), y_axis=(0.0, 0.0, 1.0)
    ),
}


def sketch_basis_for_plane(plane: Plane) -> ResolvedPlane:
    """C3: the full basis (see `ResolvedPlane`) for one of the three fixed
    reference planes - the "anchor plane" every Sketch resolved to before
    C3 implicitly used, now made explicit so `app.document.extrude` and
    `app.document.create_plane` can treat a fixed-plane Sketch and a
    custom-plane-anchored one (C3) identically once each has its own
    `ResolvedPlane`."""
    return _PLANE_BASIS[plane]


def _cross(a: Vector3, b: Vector3) -> Vector3:
    ax, ay, az = a
    bx, by, bz = b
    return (ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx)


def _normalized(v: Vector3) -> Vector3:
    length = math.sqrt(sum(c * c for c in v))
    return tuple(c / length for c in v)


def arbitrary_perpendicular_basis(normal: Vector3) -> tuple[Vector3, Vector3]:
    """C3: an arbitrary (but deterministic) orthonormal (x_axis, y_axis) pair
    perpendicular to `normal`, for the plane types that have no natural
    in-plane reference direction of their own (`NORMAL_TO_LINE_AT_POINT`,
    `MIDPLANE`, and - C4 - `NORMAL_TO_EDGE_THROUGH_VERTEX`) - unlike
    `_PLANE_BASIS` above, there is no pre-existing convention such a plane
    needs to match, so any valid right-handed (x_axis, y_axis, normal)
    triple is equally correct; this just needs to be deterministic (the
    same `normal` always yields the same basis) so a live-recomputed plane
    doesn't visually "spin" between requests.

    Picks whichever of world +Z or +Y is *less* parallel to `normal` as a
    reference vector (avoiding the degenerate near-parallel case that would
    otherwise blow up the cross product's normalization), then derives
    `x_axis = normalize(reference x normal)` and `y_axis = normal x x_axis`
    (already unit length, since `normal`/`x_axis` are orthonormal).

    C4: public (no leading underscore) since `app.document.create_plane`'s
    `resolve_normal_to_edge_through_vertex_from_bodies` now also needs it,
    for exactly the same "no natural in-plane reference" reason."""
    _, _, nz = normal
    reference: Vector3 = (0.0, 0.0, 1.0) if abs(nz) < 0.9 else (0.0, 1.0, 0.0)
    x_axis = _normalized(_cross(reference, normal))
    y_axis = _cross(normal, x_axis)
    return x_axis, y_axis


def basis_point(basis: ResolvedPlane, x: float, y: float) -> Vector3:
    """`basis`'s own local (x, y) -> world-space point mapping:
    `origin + x * x_axis + y * y_axis`.

    C4: public (no leading underscore) since `app.document.create_plane`'s
    `_resolve_point_ref_position` now also needs it, to map a `THREE_POINTS`
    Sketch-Point `PointRef`'s local coordinates into world space through its
    own Sketch's resolved basis."""
    ox, oy, oz = basis.origin
    xx, xy, xz = basis.x_axis
    yx, yy, yz = basis.y_axis
    return (ox + x * xx + y * yx, oy + x * xy + y * yy, oz + x * xz + y * yz)


def _basis_vector(basis: ResolvedPlane, dx: float, dy: float) -> Vector3:
    """The world-space *direction* (not position - no `origin` offset) for a
    local-space delta `(dx, dy)` in `basis` - correct because `basis_point`
    is linear in (x, y) (an origin-preserving affine map once the origin
    offset is set aside), so mapping a delta gives exactly the same result
    as mapping the two endpoints and subtracting."""
    xx, xy, xz = basis.x_axis
    yx, yy, yz = basis.y_axis
    return (dx * xx + dy * yx, dx * xy + dy * yy, dx * xz + dy * yz)


def _sub(a: Vector3, b: Vector3) -> Vector3:
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def _collinear_points() -> HTTPException:
    """C4: structured 422, same envelope every other Create Plane validation
    error uses, for a `THREE_POINTS` CreatePlaneFeature whose three points
    are collinear (or coincident) - there is no single well-defined plane
    through a straight line (or a single point) alone."""
    return HTTPException(status_code=422, detail={"type": "collinear_points"})


def resolve_three_points(p0: Vector3, p1: Vector3, p2: Vector3) -> ResolvedPlane:
    """C4: resolves a THREE_POINTS CreatePlaneFeature from three already-
    resolved world-space positions (see `app.document.create_plane.
    resolve_three_points_from_bodies`, which resolves each `PointRef` - a
    Body vertex or a Sketch Point - into the `Vector3` this function actually
    consumes, keeping this function itself OCCT-free).

    `origin` is `p0` (it necessarily lies in the plane by construction);
    `x_axis` is the normalized `p0 -> p1` direction (a natural, deterministic
    in-plane reference - the plane doesn't "spin" between requests as long as
    which point is `p0`/`p1`/`p2` stays stable, which it does: `PointRef`
    order is preserved end to end from the client's selection through to
    here); `normal` is the normalized cross product of `p0 -> p1` and
    `p0 -> p2`; `y_axis = normal x x_axis` completes a right-handed
    orthonormal basis. Fails closed with `collinear_points` (see
    `_collinear_points`) when the three points don't actually span a plane -
    an exact zero-length-cross-product check, not a tolerance-based "nearly
    collinear" one, consistent with this project's no-implicit-inference
    principle."""
    v1 = _sub(p1, p0)
    v2 = _sub(p2, p0)
    raw_normal = _cross(v1, v2)
    raw_normal_length = math.sqrt(sum(c * c for c in raw_normal))
    if raw_normal_length == 0.0:
        raise _collinear_points()

    normal = tuple(c / raw_normal_length for c in raw_normal)
    v1_length = math.sqrt(sum(c * c for c in v1))
    x_axis = tuple(c / v1_length for c in v1)
    y_axis = _cross(normal, x_axis)
    return ResolvedPlane(origin=p0, normal=normal, x_axis=x_axis, y_axis=y_axis)


# Deliberately duplicates (does not import) app.document.extrude's own
# sketch_point_to_world - that version returns an OCCT gp_Pnt, and importing
# it would force this whole module to require OCCT at load time, defeating
# the point of keeping NORMAL_TO_LINE_AT_POINT OCCT-free. Both must stay in
# sync with each other and with the client's own sketchPointToWorld
# (client/lib/viewport3d/sketch_geometry_3d.dart) - the same fixed XY/XZ/YZ
# embedding used everywhere else in this project.
def _sketch_point_to_world(plane: Plane, x: float, y: float) -> Vector3:
    return {
        Plane.XY: (x, y, 0.0),
        Plane.XZ: (x, 0.0, y),
        Plane.YZ: (0.0, x, y),
    }[plane]


def _point_not_on_line(line_ref: SketchEntityRef, point_ref: SketchEntityRef) -> HTTPException:
    """C2: the structured `point_not_on_line` validation error - a plain
    HTTPException with a structured `detail` dict, same 422 envelope B1/C1
    already established for `missing_reference`. Raised when `point_ref`'s
    `entity_id` is not literally the resolved Line's own `start_point_id`
    or `end_point_id` - an id comparison, not a distance/tolerance check,
    consistent with this project's no-auto-merge/no-implicit-coincidence
    principle (see this prompt's own scope doc)."""
    return HTTPException(
        status_code=422,
        detail={
            "type": "point_not_on_line",
            "sketch_id": line_ref.sketch_id,
            "line_id": line_ref.entity_id,
            "point_id": point_ref.entity_id,
        },
    )


def resolve_normal_to_line_at_point(
    line_ref: SketchEntityRef, point_ref: SketchEntityRef, basis: ResolvedPlane
) -> ResolvedPlane:
    """C2/C3: resolves a NORMAL_TO_LINE_AT_POINT CreatePlaneFeature - a plane
    normal to `line_ref`'s direction, passing through `point_ref`'s
    position. Fully determined by the two references alone, no numeric
    input (per this prompt's own scope). Resolves both refs via C1's
    `resolve_sketch_entity` (fails closed with `missing_reference` for an
    unknown sketch/entity id, same as every other consumer of that
    resolver), then validates `point_ref` is literally one of the resolved
    Line's own endpoints - fails closed with `point_not_on_line` otherwise
    (see `_point_not_on_line`).

    C3: `basis` is the referenced Line's own Sketch's resolved anchor plane
    (see `app.document.create_plane.resolve_sketch_basis`) - a fixed plane's
    `sketch_basis_for_plane(sketch.plane)`, or (new in C3) a custom plane's
    own already-resolved `ResolvedPlane` when the Sketch is anchored to one
    via `SketchFeature.plane_feature_id`. Threaded in explicitly rather than
    derived from `sketch.plane` internally (C2's original approach) so this
    function has no OCCT dependency of its own even now that a Sketch can
    live on an OCCT-derived custom plane - resolving *that* basis is the
    caller's job, this function only ever consumes the result.

    The line's direction vector maps into world space via `_basis_vector`
    applied to the (dx, dy) delta directly, not just to positions - see that
    helper's own docstring for why a delta and a position/position
    subtraction agree."""
    line = resolve_sketch_entity(line_ref)
    assert isinstance(line, Line)  # entity_type already validated LINE by resolve_sketch_entity
    point = resolve_sketch_entity(point_ref)
    assert isinstance(point, Point)  # entity_type already validated POINT by resolve_sketch_entity

    if point_ref.entity_id not in (line.start_point_id, line.end_point_id):
        raise _point_not_on_line(line_ref, point_ref)

    sketch = get_sketch_or_404(line_ref.sketch_id)
    start = sketch.points[line.start_point_id]
    end = sketch.points[line.end_point_id]

    dx, dy = end.x - start.x, end.y - start.y
    direction = _basis_vector(basis, dx, dy)
    length = math.sqrt(sum(c * c for c in direction))
    normal = tuple(c / length for c in direction)

    origin = basis_point(basis, point.x, point.y)
    x_axis, y_axis = arbitrary_perpendicular_basis(normal)
    return ResolvedPlane(origin=origin, normal=normal, x_axis=x_axis, y_axis=y_axis)
