"""On-device feedback: a Slot's own semicircular end-cap Arcs came out
concave instead of convex, and a Trim/Extend-closed Arc+Line loop extruded
the wrong (excluded) side - both on a Sketch whose own fixed-plane
orientation had been flipped. Confirmed via the backend's own request logs:
a wire's real vertex world coordinates showed `x_axis` behaving as
`(+1, 0, 0)` for a Sketch on the XZ plane, where `app.document.
plane_geometry._PLANE_BASIS[Plane.XZ]` already documents `x_axis=(-1, 0,
0)` as the correct, already-fixed value for that plane's *unflipped* case
- root-caused to `apply_orientation`'s own `flip` support, which negates
`x_axis` alone and so leaves a flipped Sketch's own `(x_axis, y_axis,
normal)` triple left-handed.

First fix attempt: derive a "canonicalized" right-handed X reference
direction for `app.document.extrude._arc_axis`, ignoring the real
(possibly left-handed) `x_axis`. Wrong - disproven by direct numeric
simulation (transforming an entire local arc, point by point, through the
real embedding, and comparing against what each candidate fix actually
built): a mirror transform genuinely is supposed to reverse apparent
CCW/CW for anything embedded through it, and `_arc_axis` passing the real
`x_axis` straight through was never the bug. The canonicalized-axis
"fix" reproduced the exact same wrong (270-degree, long-way) arc the
original bug did.

Real fix: `app.document.extrude.wire_for_profile`'s own Arc branch swaps
which Point is passed as P1 vs P2 to `BRepBuilderAPI_MakeEdge(gp_Circ, P1,
P2)` whenever the basis is mirrored (`is_mirrored_basis`, below) - `_arc_
axis` itself is unchanged from the original code. `is_mirrored_basis` is
the one piece of this fix that's genuinely OCC-free pure math, so it's
tested directly here; the actual OCCT wire construction that consumes it
can't be exercised in this environment at all (no pythonocc-core
available), so on-device confirmation remains the real gate for the fix
as a whole.
"""

import math

from app.document.plane_geometry import _PLANE_BASIS, apply_orientation, is_mirrored_basis


def test_is_mirrored_basis_is_false_for_every_fixed_plane_unflipped():
    for plane, basis in _PLANE_BASIS.items():
        assert not is_mirrored_basis(basis), f"{plane}: an unflipped fixed plane must never read as mirrored"


def test_is_mirrored_basis_is_true_exactly_when_flipped_regardless_of_rotation():
    for plane, basis in _PLANE_BASIS.items():
        for turns in range(4):
            unflipped = apply_orientation(basis, flip=False, rotation_quarter_turns=turns)
            flipped = apply_orientation(basis, flip=True, rotation_quarter_turns=turns)
            assert not is_mirrored_basis(unflipped), f"{plane} turns={turns}: rotation alone must not mirror"
            assert is_mirrored_basis(flipped), f"{plane} turns={turns}: flip must always mirror"


def _cross(a, b):
    ax, ay, az = a
    bx, by, bz = b
    return (ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx)


def _dot(a, b):
    return sum(x * y for x, y in zip(a, b))


def _local_to_world(basis, lx, ly):
    xx, xy, xz = basis.x_axis
    yx, yy, yz = basis.y_axis
    return (lx * xx + ly * yx, lx * xy + ly * yy, lx * xz + ly * yz)


def _ground_truth_arc_points(basis, radius=5.0, n=13):
    """Every point of a fixed local arc (center at the sketch origin, CCW
    from local angle 0deg to 90deg), individually transformed into world
    space via `basis` - the one unambiguous "correct" answer any embedding
    strategy must reproduce, since it's just "transform the whole curve",
    not an OCCT-specific shortcut."""
    points = []
    for t in range(n):
        theta = math.radians(90 * t / (n - 1))
        points.append(_local_to_world(basis, radius * math.cos(theta), radius * math.sin(theta)))
    return points


def _simulated_occt_sweep(basis, p1_world, p2_world, radius=5.0, n=13):
    """A pure-Python stand-in for what `BRepBuilderAPI_MakeEdge(gp_Circ(gp_
    Ax2(center, normal, basis.x_axis), radius), P1, P2)` actually builds -
    CCW trim from P1 to P2 using the real `basis.x_axis` as the axis's own
    reference direction and `normal cross x_axis` as its own freshly
    computed Y direction, mirroring gp_Ax2's own internal construction
    exactly (never `basis.y_axis` directly - see _arc_axis's own doc
    comment for why passing the real x_axis, not a "corrected" one, is
    correct)."""
    x_axis = basis.x_axis
    y_computed = _cross(basis.normal, x_axis)

    def local_angle(p):
        return math.degrees(math.atan2(_dot(p, y_computed), _dot(p, x_axis))) % 360

    a1, a2 = local_angle(p1_world), local_angle(p2_world)
    sweep = (a2 - a1) % 360
    points = []
    for t in range(n):
        theta = math.radians(a1 + sweep * t / (n - 1))
        lx, ly = radius * math.cos(theta), radius * math.sin(theta)
        points.append(
            (lx * x_axis[0] + ly * y_computed[0], lx * x_axis[1] + ly * y_computed[1], lx * x_axis[2] + ly * y_computed[2])
        )
    return points


def _points_close(a, b, tol=1e-6):
    return len(a) == len(b) and all(
        all(math.isclose(x, y, abs_tol=tol) for x, y in zip(pa, pb)) for pa, pb in zip(a, b)
    )


def test_swapping_p1_p2_on_a_mirrored_basis_reproduces_the_true_transformed_arc():
    """The actual property the fix depends on: for every fixed plane, with
    every flip/rotation combination this codebase supports, building the
    Arc edge with P1/P2 swapped whenever `is_mirrored_basis` is true (and
    unswapped otherwise) must exactly reproduce transforming the entire
    local arc curve through the real basis, point by point - not merely
    "look plausible" for one hand-picked case."""
    for plane, base_basis in _PLANE_BASIS.items():
        for flip in (False, True):
            for turns in range(4):
                basis = apply_orientation(base_basis, flip=flip, rotation_quarter_turns=turns)
                ground_truth = _ground_truth_arc_points(basis)
                start_world = _local_to_world(basis, 5.0, 0.0)
                end_world = _local_to_world(basis, 0.0, 5.0)

                if is_mirrored_basis(basis):
                    p1, p2 = end_world, start_world
                else:
                    p1, p2 = start_world, end_world
                swept = _simulated_occt_sweep(basis, p1, p2)
                # A swapped sweep runs end->start, so its own point order
                # is the reverse of the (start->end) ground truth.
                comparable = list(reversed(swept)) if is_mirrored_basis(basis) else swept

                assert _points_close(ground_truth, comparable), (
                    f"{plane} flip={flip} turns={turns}: swap-based Arc embedding must match the "
                    "true point-by-point transform of the local arc"
                )
