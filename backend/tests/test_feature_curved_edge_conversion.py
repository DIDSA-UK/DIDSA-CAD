"""On-device feedback ("when I offset a curved edge it creates a straight
line"): the pure-geometry pieces `app.document.plane_geometry` gained so a
circular Body edge can convert (via Convert Entities/Offset's shared
`convert_body_edge`) as a real Arc/Circle instead of always flattening to
its own chord - see `resolve_planar_circle`/`resolve_ccw_arc_endpoints`'s
own doc comments for the full reasoning.

Entirely OCCT-free pure math (`app.document.plane_geometry` deliberately
has no pythonocc-core import anywhere, per its own module doc comment) -
every test here runs for real in this sandbox, unlike the OCCT-bound
extraction wrapper (`Sketch.py`/`app.document.router`) that actually reads
a Body edge's real OCCT curve and calls into these.
"""

import math

import pytest

from app.document.models import ResolvedPlane
from app.document.plane_geometry import (
    resolve_ccw_arc_endpoints,
    resolve_planar_circle,
    signed_distance_to_plane,
)

# Plain XY plane at the origin - the simplest possible ResolvedPlane.
_XY_PLANE = ResolvedPlane(origin=(0.0, 0.0, 0.0), normal=(0.0, 0.0, 1.0), x_axis=(1.0, 0.0, 0.0), y_axis=(0.0, 1.0, 0.0))


def test_signed_distance_to_plane_is_zero_for_a_point_on_the_plane():
    assert signed_distance_to_plane(_XY_PLANE, (3.0, 4.0, 0.0)) == pytest.approx(0.0)


def test_signed_distance_to_plane_matches_offset_along_the_normal():
    assert signed_distance_to_plane(_XY_PLANE, (3.0, 4.0, 2.5)) == pytest.approx(2.5)
    assert signed_distance_to_plane(_XY_PLANE, (3.0, 4.0, -2.5)) == pytest.approx(-2.5)


def test_resolve_planar_circle_projects_a_coplanar_circle():
    result = resolve_planar_circle(
        _XY_PLANE, circle_center=(3.0, 4.0, 0.0), circle_axis=(0.0, 0.0, 1.0), circle_radius=5.0
    )
    assert result == pytest.approx((3.0, 4.0, 5.0))


def test_resolve_planar_circle_accepts_an_anti_parallel_axis():
    # A circle's own axis has no inherent "up" - a circle coplanar with the
    # plane but wound the opposite way around still lies flat against it.
    result = resolve_planar_circle(
        _XY_PLANE, circle_center=(3.0, 4.0, 0.0), circle_axis=(0.0, 0.0, -1.0), circle_radius=5.0
    )
    assert result == pytest.approx((3.0, 4.0, 5.0))


def test_resolve_planar_circle_rejects_a_non_parallel_axis():
    # The circle's own plane is tilted relative to the Sketch plane - not
    # flat, no valid 2D Arc/Circle to create.
    result = resolve_planar_circle(
        _XY_PLANE, circle_center=(3.0, 4.0, 0.0), circle_axis=(1.0, 0.0, 0.0), circle_radius=5.0
    )
    assert result is None


def test_resolve_planar_circle_rejects_a_parallel_but_offset_circle():
    # Axis matches, but the circle itself sits in a different, parallel
    # plane a real distance away - still not embeddable as flat 2D
    # geometry on *this* plane.
    result = resolve_planar_circle(
        _XY_PLANE, circle_center=(3.0, 4.0, 10.0), circle_axis=(0.0, 0.0, 1.0), circle_radius=5.0
    )
    assert result is None


def test_resolve_planar_circle_tolerates_small_floating_point_noise():
    result = resolve_planar_circle(
        _XY_PLANE, circle_center=(3.0, 4.0, 1e-6), circle_axis=(0.0, 0.0, 1.0 + 1e-8), circle_radius=5.0
    )
    assert result == pytest.approx((3.0, 4.0, 5.0))


def test_resolve_ccw_arc_endpoints_keeps_order_when_mid_is_already_on_the_ccw_sweep():
    center = (0.0, 0.0)
    start = (1.0, 0.0)  # 0 degrees
    end = (0.0, 1.0)  # 90 degrees
    mid = (math.cos(math.radians(45)), math.sin(math.radians(45)))  # 45 degrees - the short CCW way

    resolved_start, resolved_end = resolve_ccw_arc_endpoints(center, start, mid, end)

    assert resolved_start == pytest.approx(start)
    assert resolved_end == pytest.approx(end)


def test_resolve_ccw_arc_endpoints_swaps_when_mid_is_on_the_clockwise_side():
    center = (0.0, 0.0)
    start = (1.0, 0.0)  # 0 degrees
    end = (0.0, 1.0)  # 90 degrees
    mid = (0.0, -1.0)  # 270 degrees - the real edge actually sweeps the *other* way around

    resolved_start, resolved_end = resolve_ccw_arc_endpoints(center, start, mid, end)

    assert resolved_start == pytest.approx(end)
    assert resolved_end == pytest.approx(start)


def test_resolve_ccw_arc_endpoints_handles_a_sweep_that_wraps_through_zero():
    center = (0.0, 0.0)
    start = (0.0, -1.0)  # 270 degrees
    end = (0.0, 1.0)  # 90 degrees
    # The short CCW way from 270 to 90 wraps through 0/360 degrees.
    mid = (1.0, 0.0)  # 0 degrees - on that wrapped CCW sweep

    resolved_start, resolved_end = resolve_ccw_arc_endpoints(center, start, mid, end)

    assert resolved_start == pytest.approx(start)
    assert resolved_end == pytest.approx(end)
