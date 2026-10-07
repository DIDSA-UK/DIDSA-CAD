"""Pure bookkeeping tests for `app.document.loft_seam` (no OCC needed)."""

import pytest

from app.document.loft_seam import locate_seam, reseam_order


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
