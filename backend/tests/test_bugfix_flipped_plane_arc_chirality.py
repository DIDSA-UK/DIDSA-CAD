"""On-device feedback: a Slot's own semicircular end-cap Arcs came out
concave instead of convex, and a Trim/Extend-closed Arc+Line loop extruded
the wrong (excluded) side - both on a Sketch whose own fixed-plane
orientation had been flipped. Confirmed via the backend's own request logs:
a wire's real vertex world coordinates showed `x_axis` behaving as
`(+1, 0, 0)` for a Sketch on the XZ plane, where `app.document.
plane_geometry._PLANE_BASIS[Plane.XZ]` already documents `x_axis=(-1, 0,
0)` as the one and only correct, already-fixed value for that plane.

Root cause: `apply_orientation`'s own `flip` support negates `x_axis`
alone (correct for mirroring Point/Line *positions*) but leaves
`y_axis`/`normal` untouched, so a flipped Sketch's own `(x_axis, y_axis,
normal)` triple is left-handed. `app.document.extrude._arc_axis`/
`_ellipse_axis` used to feed that same (possibly left-handed) `x_axis`
straight to OCCT as a circle's own angle-zero reference direction, which
`BRepBuilderAPI_MakeEdge(gp_Circ, P1, P2)` uses to decide which of the two
possible arcs between P1/P2 to build - silently swapping in the wrong one
whenever the basis had been flipped.

Fixed by `right_handed_x_axis`, which derives the reference direction from
`y_axis`/`normal` alone (both untouched by flip) instead of trusting
`x_axis`. This is the one piece of that fix that's genuinely OCC-free pure
math, so it's tested directly here - the actual OCCT wire construction that
consumes it (`app.document.extrude`) can't be exercised in this environment
at all (no pythonocc-core available), so on-device confirmation remains the
real gate for the fix as a whole.
"""

import math

from app.document.models import ResolvedPlane
from app.document.plane_geometry import _PLANE_BASIS, apply_orientation, right_handed_x_axis
from app.sketch.models import Plane


def _cross(a, b):
    ax, ay, az = a
    bx, by, bz = b
    return (ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx)


def _close(a, b, tol=1e-9):
    return all(math.isclose(x, y, abs_tol=tol) for x, y in zip(a, b))


def test_right_handed_x_axis_matches_the_documented_correct_value_for_every_fixed_plane():
    for plane, basis in _PLANE_BASIS.items():
        assert _close(right_handed_x_axis(basis), basis.x_axis), (
            f"{plane}: right_handed_x_axis should reproduce _PLANE_BASIS's own already-correct "
            "x_axis when nothing has been flipped"
        )


def test_right_handed_x_axis_stays_correct_after_a_flip_that_corrupts_x_axis_alone():
    for plane, basis in _PLANE_BASIS.items():
        flipped = apply_orientation(basis, flip=True, rotation_quarter_turns=0)
        # The flip really did negate x_axis (sanity-checking the premise,
        # not the fix itself) and left y_axis/normal untouched.
        assert _close(flipped.x_axis, tuple(-c for c in basis.x_axis))
        assert flipped.y_axis == basis.y_axis
        assert flipped.normal == basis.normal

        # The bug: naively using flipped.x_axis directly would now be
        # wrong. The fix: right_handed_x_axis ignores it and re-derives
        # the *original*, correct direction from y_axis/normal alone.
        assert _close(right_handed_x_axis(flipped), basis.x_axis), (
            f"{plane}: right_handed_x_axis must stay correct even once x_axis has been "
            "flip-corrupted, since y_axis/normal (what it's actually derived from) never change"
        )


def test_right_handed_x_axis_is_always_genuinely_right_handed_even_for_a_flipped_basis():
    """The property that actually matters for OCCT's own gp_Ax2/gp_Circ
    parametrization: (X, y_axis, normal) must satisfy X cross y_axis ==
    normal - not just "happen to equal the unflipped x_axis" (the other
    two tests above), which only holds for these particular fixed planes
    because their own x_axis/y_axis/normal are axis-aligned. This is the
    general property any future non-axis-aligned custom plane also needs."""
    for basis in _PLANE_BASIS.values():
        for flip in (False, True):
            for turns in range(4):
                oriented = apply_orientation(basis, flip=flip, rotation_quarter_turns=turns)
                x_ref = right_handed_x_axis(oriented)
                assert _close(_cross(x_ref, oriented.y_axis), oriented.normal), (
                    f"flip={flip} turns={turns}: (right_handed_x_axis, y_axis, normal) must be "
                    "a genuinely right-handed triple"
                )


def test_right_handed_x_axis_for_a_custom_non_axis_aligned_plane():
    """Not just the three fixed planes - a made-up right-handed basis
    (mirroring what a real CreatePlaneFeature could resolve to) must also
    round-trip correctly, confirming this isn't coincidentally only working
    because every fixed plane's own vectors happen to be axis-aligned."""
    # An arbitrary but genuinely orthonormal, right-handed triple.
    normal = (0.0, 0.0, 1.0)
    y_axis = (0.0, 1.0, 0.0)
    x_axis = (1.0, 0.0, 0.0)
    basis = ResolvedPlane(origin=(1.0, 2.0, 3.0), normal=normal, x_axis=x_axis, y_axis=y_axis)

    assert _close(right_handed_x_axis(basis), x_axis)

    flipped = apply_orientation(basis, flip=True, rotation_quarter_turns=0)
    assert _close(right_handed_x_axis(flipped), x_axis)
