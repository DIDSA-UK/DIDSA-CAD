"""Geometric signatures for a Sketch's external (Body vertex) references, and the pure decision logic that re-finds a reference by signature.

See `docs/reference-identity-design.md` for the whole design. This module is deliberately OCCT-free (the sketch layer never imports the
document layer, and everything here is plain tuples and floats) so the matching rules can be unit-tested without a kernel;
`app.document.reference_signature` is the OCCT-bound half that *measures* a Body's vertices into `VertexSignature`s.

A `VertexSignature` is captured when a reference is created and refreshed every time the reference is confirmed healthy. It is made of
  * `position`: the vertex in the Body's frame (the Part-local frame every Body shape lives in; an assembly placement is applied outside);
  * a topological fingerprint: `valence` (distinct incident edges), and the unit normal + surface kind of every adjacent face at the vertex;
  * `edge_directions`: the unsigned unit tangents of the incident edges at the vertex (an edge reference is two vertex references, so this is
    where an edge's direction lives; it is only a tie-break, never required to match);
  * `body_diagonal`: the Body's bounding-box diagonal when it was captured, so every tolerance is relative (the same rule behaves on a
    10 mm bracket and a 10 m frame).

`decide_reference` is the (b) + (d) of the design: index still right -> keep it; else the unique vertex with the same fingerprint; else the nearest of
several with the same fingerprint if clearly nearest and close; else a lone vertex sitting where the old one was (flagged "potentially moved");
else lost. It never returns a rebinding it is not sure about.

Faces (N1a): a cylinder / sphere / torus face also carries its radius and a cone its half-angle (`FaceSignature`), not as fingerprint but as the tie-break
among coaxial faces, which the position rules cannot separate (`size_error` and the constants beside `RADIUS_TOLERANCE_REL`). A signature without them (every
one saved before N1a) decides exactly as before.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from enum import Enum

Vec3 = tuple[float, float, float]

# Angle within which two face normals / edge tangents count as the same direction.
NORMAL_TOLERANCE_DEGREES = 8.0
# A fingerprint-equal vertex at this fraction of the Body's diagonal (or nearer) from the old position is "close enough" to be chosen as the nearest
# of several; also bounds how far an index-matched vertex may have travelled before a nearer fingerprint-equal twin makes it suspect.
SEARCH_TOLERANCE_REL = 0.05
# The nearest candidate must be this many times nearer than the runner-up to be considered unambiguous.
UNAMBIGUOUS_RATIO = 3.0
# A vertex whose fingerprint changed but which still sits within this fraction of the diagonal of the old position is a "potentially moved" binding.
# Also the band within which two fingerprint-equal faces count as "at the same distance" for the size tie-break below (coaxial faces are at ~0 both).
SOFT_TOLERANCE_REL = 0.01

# The size tie-break among coaxial faces (N1a; plan decision N-4 (a)). A cylinder / cone face is measured by its distance from the stored AXIS
# (`shape_distance`), so every cylinder on one axis (a bore and the boss around it, the steps of a shaft, a gear's bore and rim) is equally near and the
# fingerprint (kind + axis) cannot tell them apart. `FaceSignature.radius` / `major_radius` / `half_angle` can. They are NOT fingerprint (a dimension edit
# changes them); they only decide between candidates the position rules leave level. One candidate's size is "clearly nearer" the stored size than
# another's when BOTH hold:
#   * the other is clearly a different size: its error exceeds the tolerance below. Distinct coaxial faces of a real part differ by a wall, a step or a
#     tooth depth, which is a few per cent of the radius or more (the gear-train bevel: bore 4 / rim 28 mm; a 1 mm wall on a 50 mm tube is 2 %), while
#     OCCT measures an analytic radius to ~1e-9 relative; 1 % separates the two with room either side. Two radii closer than that stay ambiguous.
#   * the nearer one is at least `SIZE_UNAMBIGUOUS_RATIO` times nearer: the same factor the position rule asks of the runner-up (`UNAMBIGUOUS_RATIO`), so a
#     radius edit that moved a face most of the way to its coaxial twin's radius is ambiguous, not a guess (bore 4 -> 5 beside an outer 10: errors 1 and 6,
#     clear; bore 4 -> 7: errors 3 and 6, ambiguous).
RADIUS_TOLERANCE_REL = 0.01  # of the stored radius (for a torus, of the larger of its two stored radii)
# The cone's half-angle tolerance, in degrees. Coaxial cones of one part differ by whole degrees (a bevel gear's face, pitch and root cones differ by its
# addendum / dedendum angles, typically 1 to 4 degrees; countersinks come in 82 / 90 / 100 / 120); OCCT measures the angle exactly. 0.5 degrees sits between.
HALF_ANGLE_TOLERANCE_DEGREES = 0.5
SIZE_UNAMBIGUOUS_RATIO = 3.0


@dataclass(frozen=True)
class VertexSignature:
    position: Vec3
    valence: int
    face_normals: tuple[Vec3, ...] = ()
    face_kinds: tuple[str, ...] = ()
    edge_directions: tuple[Vec3, ...] = ()
    body_diagonal: float = 0.0


@dataclass(frozen=True)
class EdgeSignature:
    """An edge, for references that name an edge (a Fillet's `edge_refs`, a Pattern direction, a converted circular edge's centre): `position` is the
    midpoint, `curve_kind` is "line" / "circle" / "other", `direction` the unsigned unit tangent at the midpoint for a line and the unsigned unit axis for a
    circle (zero for "other"), `length` the edge length, `radius` / `centre` a circle's own (zero otherwise), and `face_normals` / `face_kinds` the adjacent
    faces' outward normal at the midpoint and surface kind. Length, radius and centre are NOT part of the fingerprint (a dimension edit changes them without
    changing what the edge is); they ride along so a circle's centre and radius can be re-derived from the re-found edge."""

    position: tuple[float, float, float]
    curve_kind: str
    direction: tuple[float, float, float] = (0.0, 0.0, 0.0)
    length: float = 0.0
    radius: float = 0.0
    centre: tuple[float, float, float] = (0.0, 0.0, 0.0)
    face_normals: tuple[tuple[float, float, float], ...] = ()
    face_kinds: tuple[str, ...] = ()
    body_diagonal: float = 0.0


@dataclass(frozen=True)
class FaceSignature:
    """A face: `position` is its centroid, `surface_kind` "plane" / "cylinder" / ..., `direction` the OUTWARD unit normal for a plane (signed: the top and the
    bottom of a box are different faces) and the unsigned unit axis for a cylinder / cone / sphere / torus (the unsigned normal at the middle of the
    parameter range for anything else), `area` its area (not part of the fingerprint).

    The size (N1a), also NOT fingerprint, only a tie-break among coaxial candidates (`size_error`): `radius` for a cylinder and a sphere, the MINOR (tube)
    radius for a torus (a fillet's own radius) with its MAJOR radius (axis to tube centre) in `major_radius`; `half_angle` for a cone, in degrees, unsigned
    (OCCT's semi-angle carries the sign of the axis direction, and the axis here is unsigned). None when not measured: every signature saved before N1a,
    and every other surface kind."""

    position: tuple[float, float, float]
    surface_kind: str
    direction: tuple[float, float, float] = (0.0, 0.0, 0.0)
    area: float = 0.0
    body_diagonal: float = 0.0
    radius: float | None = None
    major_radius: float | None = None
    half_angle: float | None = None


ShapeSignature = VertexSignature | EdgeSignature | FaceSignature


@dataclass(frozen=True)
class LineageOrigin:
    """Where OCCT history says a referenced vertex came from: the first feature whose output *created* it (nothing in that feature's input maps to it),
    the vertex's index in that feature's output, and its signature there. See `app.document.reference_history`."""

    feature_id: str
    body_id: str
    index: int
    signature: ShapeSignature
    kind: str = "vertex"  # "vertex" | "edge" | "face": which sub-shape `index` indexes


class ReferenceStatus(str, Enum):
    OK = "ok"  # the stored index still names the same vertex
    FOLLOWED = "followed"  # the index changed; the vertex was re-found unambiguously (signature and / or OCCT history)
    POTENTIALLY_MOVED = "potentially_moved"  # bound, but on weaker evidence: the user should look
    LOST = "lost"  # not found (deleted / consumed), or found but ambiguous: not rebound


@dataclass(frozen=True)
class ReferenceDecision:
    status: ReferenceStatus
    index: int | None = None
    reason: str = ""
    method: str = ""  # "index" | "signature" | "history" | "position"
    candidates: tuple[int, ...] = field(default=())
    lineage: LineageOrigin | None = None  # set when OCCT history (re)established where the vertex came from


def _dot(a: Vec3, b: Vec3) -> float:
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def distance(a: Vec3, b: Vec3) -> float:
    return math.dist(a, b)


def _angle_degrees(a: Vec3, b: Vec3, unsigned: bool = False) -> float:
    cosine = max(-1.0, min(1.0, _dot(a, b)))
    if unsigned:
        cosine = abs(cosine)
    return math.degrees(math.acos(cosine))


def _directions_match(stored: tuple[Vec3, ...], kinds_stored: tuple[str, ...], other: tuple[Vec3, ...], kinds_other: tuple[str, ...]) -> bool:
    if len(stored) != len(other):
        return False
    used = [False] * len(other)
    for i, direction in enumerate(stored):
        for j, candidate in enumerate(other):
            if used[j] or kinds_stored[i] != kinds_other[j]:
                continue
            if _angle_degrees(direction, candidate) <= NORMAL_TOLERANCE_DEGREES:
                used[j] = True
                break
        else:
            return False
    return True


def _zero(vec: tuple[float, float, float]) -> bool:
    return abs(vec[0]) + abs(vec[1]) + abs(vec[2]) < 1e-9


def fingerprint_matches(stored: ShapeSignature, other: ShapeSignature) -> bool:
    """Whether `other` looks like the same sub-shape as `stored` (both must be the same kind). Position is never part of it: a depth change or a dimension
    edit moves a sub-shape without changing what it is.
    * vertex: same valence and the same set of adjacent faces (surface kind + normal at the vertex, within `NORMAL_TOLERANCE_DEGREES`);
    * edge: same curve kind, same (unsigned) direction / axis, same set of adjacent faces at the midpoint;
    * face: same surface kind and the same normal (planes: signed outward normal) or axis."""
    if isinstance(stored, VertexSignature):
        if not isinstance(other, VertexSignature) or stored.valence != other.valence:
            return False
        kinds_a = stored.face_kinds or ("",) * len(stored.face_normals)
        kinds_b = other.face_kinds or ("",) * len(other.face_normals)
        return _directions_match(stored.face_normals, kinds_a, other.face_normals, kinds_b)
    if isinstance(stored, EdgeSignature):
        if not isinstance(other, EdgeSignature) or stored.curve_kind != other.curve_kind:
            return False
        if not (_zero(stored.direction) or _zero(other.direction)) and _angle_degrees(stored.direction, other.direction, unsigned=True) > NORMAL_TOLERANCE_DEGREES:
            return False
        kinds_a = stored.face_kinds or ("",) * len(stored.face_normals)
        kinds_b = other.face_kinds or ("",) * len(other.face_normals)
        return _directions_match(stored.face_normals, kinds_a, other.face_normals, kinds_b)
    if not isinstance(other, FaceSignature) or stored.surface_kind != other.surface_kind:
        return False
    if _zero(stored.direction) or _zero(other.direction):
        return True
    return _angle_degrees(stored.direction, other.direction, unsigned=stored.surface_kind != "plane") <= NORMAL_TOLERANCE_DEGREES


def edge_direction_score(stored: ShapeSignature, other: ShapeSignature) -> int:
    """A tie-break among fingerprint-equal candidates: for vertices, how many of `stored`'s incident edge tangents have a (unsigned) match at `other`; for
    edges and faces, 1 when the length / area is within 20 % (a dimension edit may change it, but an identical twin rarely differs by much), else 0."""
    if isinstance(stored, VertexSignature) and isinstance(other, VertexSignature):
        used = [False] * len(other.edge_directions)
        score = 0
        for direction in stored.edge_directions:
            for j, candidate in enumerate(other.edge_directions):
                if not used[j] and _angle_degrees(direction, candidate, unsigned=True) <= NORMAL_TOLERANCE_DEGREES:
                    used[j] = True
                    score += 1
                    break
        return score
    if isinstance(stored, EdgeSignature) and isinstance(other, EdgeSignature):
        a, b = stored.length, other.length
    elif isinstance(stored, FaceSignature) and isinstance(other, FaceSignature):
        a, b = stored.area, other.area
    else:
        return 0
    return 1 if a > 0 and abs(a - b) <= 0.2 * a else 0


def _perpendicular_to_line(point: Vec3, origin: Vec3, direction: Vec3) -> float:
    d = (point[0] - origin[0], point[1] - origin[1], point[2] - origin[2])
    along = _dot(d, direction)
    return math.sqrt(max(0.0, _dot(d, d) - along * along))


def shape_distance(stored: ShapeSignature, other: ShapeSignature) -> float:
    """How far `other` is from where `stored` was, measured so that trimming does not read as moving: a vertex by its position; a straight edge by its distance
    from the stored edge's LINE (a neighbouring fillet shortens an edge and shifts its midpoint along that line without moving the edge); a circular edge by
    its centre; a planar face by its offset along the stored normal (a neighbouring cut shifts its centroid within the plane); a cylinder / cone face by its
    distance from the stored axis; anything else by position."""
    if isinstance(stored, EdgeSignature) and isinstance(other, EdgeSignature):
        if stored.curve_kind == "circle" and other.curve_kind == "circle":
            return distance(stored.centre, other.centre)
        if stored.curve_kind == "line" and other.curve_kind == "line" and not _zero(stored.direction):
            return _perpendicular_to_line(other.position, stored.position, stored.direction)
    if isinstance(stored, FaceSignature) and isinstance(other, FaceSignature) and not _zero(stored.direction):
        if stored.surface_kind == "plane" and other.surface_kind == "plane":
            return abs(_dot((other.position[0] - stored.position[0], other.position[1] - stored.position[1], other.position[2] - stored.position[2]), stored.direction))
        if stored.surface_kind in ("cylinder", "cone") and other.surface_kind == stored.surface_kind:
            return _perpendicular_to_line(other.position, stored.position, stored.direction)
    return distance(stored.position, other.position)


def size_error(stored: ShapeSignature, other: ShapeSignature) -> tuple[float, float] | None:
    """How far `other`'s size is from `stored`'s, and the tolerance within which that counts as the same size, for two faces that both carry one: the
    half-angle difference (degrees) for cones, the radius difference (plus the major-radius difference for tori) for the rest. None when either has no size
    (a signature saved before N1a, a plane, a free-form face): then no size rule applies and every decision is exactly what it was before N1a."""
    if not isinstance(stored, FaceSignature) or not isinstance(other, FaceSignature):
        return None
    if stored.half_angle is not None and other.half_angle is not None:
        return abs(stored.half_angle - other.half_angle), HALF_ANGLE_TOLERANCE_DEGREES
    if stored.radius is not None and other.radius is not None:
        error = abs(stored.radius - other.radius)
        scale = stored.radius
        if stored.major_radius is not None and other.major_radius is not None:
            error += abs(stored.major_radius - other.major_radius)
            scale = max(scale, stored.major_radius)
        return error, RADIUS_TOLERANCE_REL * scale
    return None


def size_unchanged(stored: ShapeSignature, other: ShapeSignature) -> bool:
    """Whether `other` has `stored`'s size to within the tolerance, or either has no size. The fast path's extra condition: a face that kept its size cannot have a
    coaxial twin clearly nearer in size, so only a face whose size changed needs the whole Body measured."""
    measured = size_error(stored, other)
    return measured is None or measured[0] <= measured[1]


def _size_clearly_nearer(nearer: tuple[float, float], farther: tuple[float, float]) -> bool:
    """`nearer` (error, tolerance) is clearly nearer the stored size than `farther` (see the constants above)."""
    return farther[0] > farther[1] and farther[0] >= SIZE_UNAMBIGUOUS_RATIO * nearer[0]


def _size_winner(stored: ShapeSignature, pool: list[int], candidates: list[ShapeSignature]) -> int | None:
    """Of `pool` (two or more candidates the position rules leave level), the one whose size is clearly nearer the stored size than every other's; None when
    any of them has no size or no one is clearly nearest."""
    errors = {i: size_error(stored, candidates[i]) for i in pool}
    if any(e is None for e in errors.values()):
        return None
    ranked = sorted(pool, key=lambda i: errors[i][0])
    best, runner_up = ranked[0], ranked[1]
    return best if _size_clearly_nearer(errors[best], errors[runner_up]) else None


def decide_reference(
    stored: ShapeSignature,
    index: int,
    candidates: list[ShapeSignature],
) -> ReferenceDecision:
    """Where does the reference now point? `candidates[i]` is the measured signature of sub-shape `i` (vertex, edge or face, the same kind as `stored`) of the
    Body as it is now."""
    diagonal = stored.body_diagonal or (candidates[0].body_diagonal if candidates else 0.0)
    search_tolerance = SEARCH_TOLERANCE_REL * diagonal
    soft_tolerance = SOFT_TOLERANCE_REL * diagonal

    equal = [i for i, c in enumerate(candidates) if fingerprint_matches(stored, c)]
    by_distance = sorted(equal, key=lambda i: (shape_distance(stored, candidates[i]), -edge_direction_score(stored, candidates[i])))

    if 0 <= index < len(candidates) and index in equal:
        mine = shape_distance(stored, candidates[index])
        twin_nearer = any(i != index and shape_distance(stored, candidates[i]) < mine - 1e-9 for i in equal)
        # N1a: a twin level with it (a coaxial face, at the same distance from the stored axis) whose size is clearly nearer the stored size: the index now
        # names the wrong one of several coaxial faces (a bore's index landing on the boss around it). Never `ok` on it.
        my_size = size_error(stored, candidates[index])
        twin_nearer_in_size = my_size is not None and any(
            i != index
            and abs(shape_distance(stored, candidates[i]) - mine) <= soft_tolerance
            and (twin_size := size_error(stored, candidates[i])) is not None
            and _size_clearly_nearer(twin_size, my_size)
            for i in equal
        )
        if (mine <= search_tolerance or not twin_nearer) and not twin_nearer_in_size:
            return ReferenceDecision(ReferenceStatus.OK, index, method="index")
        # Same fingerprint but it travelled far and an identical-looking twin is nearer to where it was, or a coaxial twin is clearly nearer in size: fall
        # through to the search below.

    if len(equal) == 1:
        only = equal[0]
        if shape_distance(stored, candidates[only]) <= search_tolerance:
            return ReferenceDecision(ReferenceStatus.FOLLOWED, only, reason="unique_fingerprint", method="signature")
        # The only vertex that looks like it is far from where it was: it may be the same vertex after a big parametric move, or an identical-looking
        # twin of one that no longer exists. Bind (the Sketch keeps working) but flag it.
        return ReferenceDecision(
            ReferenceStatus.POTENTIALLY_MOVED, only, reason="unique_fingerprint_far", method="signature", candidates=(only,)
        )
    if len(equal) > 1:
        d1 = shape_distance(stored, candidates[by_distance[0]])
        # N1a: several level at the nearest distance (coaxial faces): their size decides, provided every candidate outside that level set is clearly farther
        # by the usual position rule. The winner is `followed`: the same kind, the same axis, and a size the others clearly do not have.
        level = [i for i in by_distance if shape_distance(stored, candidates[i]) <= d1 + soft_tolerance]
        if d1 <= search_tolerance and len(level) > 1:
            outside = [shape_distance(stored, candidates[i]) for i in by_distance if i not in level]
            if all(d >= UNAMBIGUOUS_RATIO * d1 and d > d1 + 1e-9 for d in outside):
                winner = _size_winner(stored, level, candidates)
                if winner is not None:
                    reason = "nearest_half_angle" if getattr(stored, "half_angle", None) is not None else "nearest_radius"
                    return ReferenceDecision(ReferenceStatus.FOLLOWED, winner, reason=reason, method="signature", candidates=tuple(level))
        d2 = shape_distance(stored, candidates[by_distance[1]])
        if d1 <= search_tolerance and d2 >= UNAMBIGUOUS_RATIO * d1 and d2 > d1 + 1e-9:
            return ReferenceDecision(
                ReferenceStatus.POTENTIALLY_MOVED, by_distance[0], reason="nearest_of_identical_vertices", method="signature", candidates=tuple(by_distance)
            )
        return ReferenceDecision(ReferenceStatus.LOST, None, reason="ambiguous", method="signature", candidates=tuple(by_distance))

    near = [i for i, c in enumerate(candidates) if shape_distance(stored, c) <= soft_tolerance]
    if len(near) == 1:
        return ReferenceDecision(ReferenceStatus.POTENTIALLY_MOVED, near[0], reason="fingerprint_changed_in_place", method="position", candidates=tuple(near))
    return ReferenceDecision(ReferenceStatus.LOST, None, reason="ambiguous" if near else "no_match", method="signature", candidates=tuple(near))


def narrow_by_signature(stored: ShapeSignature, pool: list[int], candidates: list[ShapeSignature]) -> list[int]:
    """Of `pool` (indices OCCT history says the vertex may have become), those whose signature still fits; the whole pool if none does."""
    fitting = [i for i in pool if fingerprint_matches(stored, candidates[i])]
    return fitting or list(pool)
