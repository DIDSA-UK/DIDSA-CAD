"""M4.1 (`docs/mates-storage-sessions-plan-2026-11-12.md`): the current value of a DISTANCE mate's two picks, measured at the stored
poses, so a client can start a new Distance where the parts already are (as SOLIDWORKS does: parallel, then the measured distance in
the value box) instead of asking for a number before it shows anything.

What is measured is what the distance mate itself holds, in mm, never negative (the side is `secondary_flip`):
- two planes: the driven plane's origin above the fixed plane, along the fixed plane's normal;
- a plane and a point (either way round): the point above the plane;
- two axes (round faces, circular or straight edges): the distance of the driven axis' origin from the fixed axis line;
- two points: the distance between them.
Anything else: None (the preview answers as it always did). Rounded to `MEASURE_DECIMALS` so the value the client shows and sends back
is exactly the one the preview solved with.
"""

from __future__ import annotations

import numpy as np

MEASURE_DECIMALS = 3  # mm: a micrometre


def measured_distance(driven, fixed) -> float | None:
    """The distance as described in the module docstring, from two WORLD geometries (`_ResolvedGeometry`, references order)."""
    def arr(x):
        return None if x is None else np.asarray(x, float)

    def unit(x):
        x = arr(x)
        n = float(np.linalg.norm(x))
        return None if n < 1e-12 else x / n

    value = None
    if driven.plane is not None and fixed.plane is not None:
        value = float((arr(driven.plane.origin) - arr(fixed.plane.origin)) @ unit(fixed.plane.normal))
    elif fixed.plane is not None and driven.point is not None and driven.plane is None:
        value = float((arr(driven.point) - arr(fixed.plane.origin)) @ unit(fixed.plane.normal))
    elif driven.plane is not None and fixed.point is not None and fixed.plane is None:
        value = float((arr(fixed.point) - arr(driven.plane.origin)) @ unit(driven.plane.normal))
    elif driven.plane is None and fixed.plane is None and driven.axis_origin is not None and fixed.axis_origin is not None and fixed.direction is not None:
        d = unit(fixed.direction)
        gap = arr(driven.axis_origin) - arr(fixed.axis_origin)
        value = float(np.linalg.norm(gap - (gap @ d) * d))
    elif driven.point is not None and fixed.point is not None and driven.plane is None and fixed.plane is None and driven.axis_origin is None and fixed.axis_origin is None:
        value = float(np.linalg.norm(arr(driven.point) - arr(fixed.point)))
    if value is None or not np.isfinite(value):
        return None
    return round(abs(value), MEASURE_DECIMALS)
