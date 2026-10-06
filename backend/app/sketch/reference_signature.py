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
SOFT_TOLERANCE_REL = 0.01


@dataclass(frozen=True)
class VertexSignature:
    position: Vec3
    valence: int
    face_normals: tuple[Vec3, ...] = ()
    face_kinds: tuple[str, ...] = ()
    edge_directions: tuple[Vec3, ...] = ()
    body_diagonal: float = 0.0


@dataclass(frozen=True)
class LineageOrigin:
    """Where OCCT history says a referenced vertex came from: the first feature whose output *created* it (nothing in that feature's input maps to it),
    the vertex's index in that feature's output, and its signature there. See `app.document.reference_history`."""

    feature_id: str
    body_id: str
    index: int
    signature: VertexSignature


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


def fingerprint_matches(stored: VertexSignature, other: VertexSignature) -> bool:
    """Same valence and the same set of adjacent faces (surface kind + normal at the vertex, within `NORMAL_TOLERANCE_DEGREES`). Position is not part of it:
    a depth change or a dimension edit moves a vertex without changing what it is."""
    if stored.valence != other.valence:
        return False
    kinds_a = stored.face_kinds or ("",) * len(stored.face_normals)
    kinds_b = other.face_kinds or ("",) * len(other.face_normals)
    return _directions_match(stored.face_normals, kinds_a, other.face_normals, kinds_b)


def edge_direction_score(stored: VertexSignature, other: VertexSignature) -> int:
    """How many of `stored`'s incident edge tangents have a (unsigned) match at `other` - a tie-break only."""
    used = [False] * len(other.edge_directions)
    score = 0
    for direction in stored.edge_directions:
        for j, candidate in enumerate(other.edge_directions):
            if not used[j] and _angle_degrees(direction, candidate, unsigned=True) <= NORMAL_TOLERANCE_DEGREES:
                used[j] = True
                score += 1
                break
    return score


def decide_reference(
    stored: VertexSignature,
    index: int,
    candidates: list[VertexSignature],
) -> ReferenceDecision:
    """Where does the reference now point? `candidates[i]` is the measured signature of vertex `i` of the Body as it is now."""
    diagonal = stored.body_diagonal or (candidates[0].body_diagonal if candidates else 0.0)
    search_tolerance = SEARCH_TOLERANCE_REL * diagonal
    soft_tolerance = SOFT_TOLERANCE_REL * diagonal

    equal = [i for i, c in enumerate(candidates) if fingerprint_matches(stored, c)]
    by_distance = sorted(equal, key=lambda i: (distance(candidates[i].position, stored.position), -edge_direction_score(stored, candidates[i])))

    if 0 <= index < len(candidates) and index in equal:
        mine = distance(candidates[index].position, stored.position)
        twin_nearer = any(i != index and distance(candidates[i].position, stored.position) < mine - 1e-9 for i in equal)
        if mine <= search_tolerance or not twin_nearer:
            return ReferenceDecision(ReferenceStatus.OK, index, method="index")
        # Same fingerprint but it travelled far and an identical-looking twin is nearer to where it was: fall through to the search below.

    if len(equal) == 1:
        only = equal[0]
        if distance(candidates[only].position, stored.position) <= search_tolerance:
            return ReferenceDecision(ReferenceStatus.FOLLOWED, only, reason="unique_fingerprint", method="signature")
        # The only vertex that looks like it is far from where it was: it may be the same vertex after a big parametric move, or an identical-looking
        # twin of one that no longer exists. Bind (the Sketch keeps working) but flag it.
        return ReferenceDecision(
            ReferenceStatus.POTENTIALLY_MOVED, only, reason="unique_fingerprint_far", method="signature", candidates=(only,)
        )
    if len(equal) > 1:
        d1 = distance(candidates[by_distance[0]].position, stored.position)
        d2 = distance(candidates[by_distance[1]].position, stored.position)
        if d1 <= search_tolerance and d2 >= UNAMBIGUOUS_RATIO * d1:
            return ReferenceDecision(
                ReferenceStatus.POTENTIALLY_MOVED, by_distance[0], reason="nearest_of_identical_vertices", method="signature", candidates=tuple(by_distance)
            )
        return ReferenceDecision(ReferenceStatus.LOST, None, reason="ambiguous", method="signature", candidates=tuple(by_distance))

    near = [i for i, c in enumerate(candidates) if distance(c.position, stored.position) <= soft_tolerance]
    if len(near) == 1:
        return ReferenceDecision(ReferenceStatus.POTENTIALLY_MOVED, near[0], reason="fingerprint_changed_in_place", method="position", candidates=tuple(near))
    return ReferenceDecision(ReferenceStatus.LOST, None, reason="ambiguous" if near else "no_match", method="signature", candidates=tuple(near))


def narrow_by_signature(stored: VertexSignature, pool: list[int], candidates: list[VertexSignature]) -> list[int]:
    """Of `pool` (indices OCCT history says the vertex may have become), those whose signature still fits; the whole pool if none does."""
    fitting = [i for i in pool if fingerprint_matches(stored, candidates[i])]
    return fitting or list(pool)
