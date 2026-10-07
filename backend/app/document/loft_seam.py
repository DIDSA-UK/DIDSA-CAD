"""Pure-Python seam bookkeeping for `app.document.loft` (no OCC imports, so it
can be unit-tested without pythonocc).

A closed Loft section's wire has a start vertex and a winding direction, and
`BRepOffsetAPI_ThruSections` joins section i's start to section i+1's start.
`LoftSection.seam_param` (a 0..1 fraction of the wire's arc length) says where
the start should be; `LoftSection.reverse` flips the winding. The OCC-facing
code in `loft._reseam_wire` uses `locate_seam`/`reseam_order` to decide which
edge to split and how to reorder the pieces.
"""

from __future__ import annotations

# A seam closer than this (as a fraction of an edge) to an edge end is snapped to
# that end instead of splitting off a degenerate sliver edge.
_SEAM_SNAP_TOLERANCE = 1e-9


def locate_seam(lengths: list[float], fraction: float) -> tuple[int, float]:
    """Maps `fraction` (0..1 of total wire length, wrapped) to `(edge_index,
    local_t)`: the edge containing the seam and how far along that edge it lies,
    with `local_t` in `[0, 1)`. A seam on or within tolerance of a vertex snaps
    to that vertex (`local_t == 0` on the following edge)."""
    if not lengths:
        raise ValueError("a wire needs at least one edge")
    total = sum(lengths)
    if total <= 0:
        raise ValueError("a wire needs a positive length")
    target = (fraction % 1.0) * total
    travelled = 0.0
    for index, length in enumerate(lengths):
        if target < travelled + length:
            local_t = (target - travelled) / length if length > 0 else 0.0
            if local_t < _SEAM_SNAP_TOLERANCE:
                return index, 0.0
            if local_t > 1.0 - _SEAM_SNAP_TOLERANCE:
                return (index + 1) % len(lengths), 0.0
            return index, local_t
        travelled += length
    return 0, 0.0


def reseam_order(edge_count: int, index: int, local_t: float, reverse: bool) -> list[tuple[int, str]]:
    """The edge pieces, in the new traversal order, for a wire re-seamed at
    `(index, local_t)`. Each entry is `(edge_index, part)`, where `part` is
    `"whole"`, `"second"` (the portion of the split edge after the seam) or
    `"first"` (the portion before it). With `reverse` the list is returned in
    the opposite traversal order; the caller must also flip each piece's own
    direction."""
    cyclic = [(index + offset) % edge_count for offset in range(edge_count)]
    if local_t == 0.0:
        order = [(edge, "whole") for edge in cyclic]
    else:
        order = [(index, "second")] + [(edge, "whole") for edge in cyclic[1:]] + [(index, "first")]
    return list(reversed(order)) if reverse else order


Point3 = tuple[float, float, float]


def _centred(points: list[Point3]) -> list[Point3]:
    count = len(points)
    cx = sum(p[0] for p in points) / count
    cy = sum(p[1] for p in points) / count
    cz = sum(p[2] for p in points) / count
    return [(p[0] - cx, p[1] - cy, p[2] - cz) for p in points]


def best_alignment(reference: list[Point3], candidate: list[Point3]) -> tuple[int, bool]:
    """The start offset and direction that make `candidate` follow `reference` most
    closely, so the loft joins corresponding points and does not twist.

    Both lists are the same number of points sampled at equal arc-length fractions
    around a closed profile. Each is centred on its own centroid first (the two
    profiles sit on different planes). Returns `(shift, reverse)`: the aligned
    candidate is `candidate[(shift + i) % n]` for `reverse=False`, or
    `candidate[(shift - i) % n]` for `reverse=True`, matched against `reference[i]` -
    the order `loft._reseam_wire` produces for `seam_param = shift / n`. Ties prefer
    no shift and no reversal, so an already-aligned loft is left untouched."""
    count = len(reference)
    if count == 0 or count != len(candidate):
        raise ValueError("reference and candidate need the same, non-zero number of samples")
    ref = _centred(reference)
    cand = _centred(candidate)

    def cost(shift: int, reverse: bool) -> float:
        total = 0.0
        for i in range(count):
            j = (shift - i) % count if reverse else (shift + i) % count
            total += sum((a - b) ** 2 for a, b in zip(ref[i], cand[j]))
        return total

    best = (0, False)
    best_cost = cost(0, False)
    for reverse in (False, True):
        for shift in range(count):
            candidate_cost = cost(shift, reverse)
            # A tiny relative margin keeps floating point noise from flipping an exact tie.
            if candidate_cost < best_cost * (1 - 1e-9) - 1e-12:
                best, best_cost = (shift, reverse), candidate_cost
    return best
