"""Pure bookkeeping tests for `app.document.loft_seam` (no OCC needed)."""

import pytest

from app.document.loft_seam import best_alignment, locate_seam, reseam_order


def test_locate_seam_inside_an_edge():
    index, t = locate_seam([10.0, 10.0, 20.0], 0.75)  # 30 of 40 along -> third edge, halfway
    assert index == 2
    assert t == pytest.approx(0.5)


def test_locate_seam_snaps_to_a_vertex():
    assert locate_seam([10.0, 10.0, 20.0], 0.25) == (1, 0.0)
    assert locate_seam([10.0, 10.0, 20.0], 0.0) == (0, 0.0)
    assert locate_seam([10.0, 10.0, 20.0], 1.0) == (0, 0.0)  # wraps


def test_locate_seam_snaps_a_near_vertex_seam():
    index, t = locate_seam([10.0, 10.0], 0.5 - 1e-12)
    assert (index, t) == (1, 0.0)


def test_locate_seam_rejects_an_empty_wire():
    with pytest.raises(ValueError):
        locate_seam([], 0.5)


def test_reseam_order_at_a_vertex_rotates_the_edges():
    assert reseam_order(4, 2, 0.0, reverse=False) == [(2, "whole"), (3, "whole"), (0, "whole"), (1, "whole")]


def test_reseam_order_mid_edge_splits_it_into_both_ends():
    assert reseam_order(3, 1, 0.4, reverse=False) == [
        (1, "second"),
        (2, "whole"),
        (0, "whole"),
        (1, "first"),
    ]


def test_reseam_order_single_edge_circle_splits_into_two_arcs():
    assert reseam_order(1, 0, 0.25, reverse=False) == [(0, "second"), (0, "first")]


def test_reseam_order_reverse_runs_the_other_way():
    forward = reseam_order(3, 1, 0.4, reverse=False)
    assert reseam_order(3, 1, 0.4, reverse=True) == list(reversed(forward))


def _ngon(n, radius, z, phase=0.0, samples=48, clockwise=False):
    """`samples` points at equal arc-length fractions of a regular n-gon (corners at `phase`)."""
    import math

    corners = [
        (radius * math.cos(phase + 2 * math.pi * k / n), radius * math.sin(phase + 2 * math.pi * k / n), z)
        for k in range(n)
    ]
    points = []
    for i in range(samples):
        position = i / samples * n
        edge = int(position)
        t = position - edge
        a, b = corners[edge % n], corners[(edge + 1) % n]
        points.append(tuple(a[axis] + t * (b[axis] - a[axis]) for axis in range(3)))
    return list(reversed(points)) if clockwise else points


def test_best_alignment_leaves_an_aligned_pair_alone():
    square = _ngon(4, 10, 0)
    assert best_alignment(square, _ngon(4, 6, 20)) == (0, False)


def test_best_alignment_undoes_a_start_vertex_shift():
    from app.document.loft_seam import best_alignment as align

    reference = _ngon(4, 10, 0)
    shifted = reference[12:] + reference[:12]  # start a quarter of the way round
    moved = [(x * 0.6, y * 0.6, 20.0) for x, y, _ in shifted]
    shift, reverse = align(reference, moved)
    assert not reverse
    assert shift == 36  # moves the start back by 12 samples (48 - 12)


def test_best_alignment_flips_a_reversed_profile():
    reference = _ngon(4, 10, 0)
    flipped = [(x * 0.6, y * 0.6, 20.0) for x, y, _ in reversed(reference)]
    shift, reverse = best_alignment(reference, flipped)
    assert reverse
    # Following the candidate backwards from `shift` reproduces the reference.
    aligned = [flipped[(shift - i) % 48] for i in range(48)]
    for (ax, ay, _), (rx, ry, _) in zip(aligned, reference):
        assert (ax / 0.6, ay / 0.6) == pytest.approx((rx, ry), abs=1e-9)


def test_best_alignment_matches_a_circle_start_to_a_square_corner():
    import math

    square = _ngon(4, 10, 0, phase=math.pi / 4)  # corners at 45, 135, ...
    circle = [
        (6 * math.cos(2 * math.pi * i / 48), 6 * math.sin(2 * math.pi * i / 48), 20.0) for i in range(48)
    ]
    shift, reverse = best_alignment(square, circle)
    assert not reverse
    assert shift == 6  # 45 degrees = 6 of 48 samples


def test_best_alignment_rejects_mismatched_samples():
    with pytest.raises(ValueError):
        best_alignment([(0, 0, 0)], [])
