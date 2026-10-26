# Helices on `HelixBRep_BuilderHelix`: spike results (2026-10-26)

Milestone 3 of `docs/loft-gordon-and-helix-plan.md`. Run on OCCT 8.0.1 / pythonocc-core 8.0.1.2; the construction is
`app.document.curve._resolve_helix_from_bodies`.

## The builder

`HelixBRep_BuilderHelix.SetParameters(axis: gp_Ax3, diameters, pitches, turns)` with `TColStd_Array1OfReal` arguments
(`diameters` has one entry more than `pitches` and `turns`: the diameter at the start of every segment and at the end of
the last), then `Perform()`, `ErrorStatus()` (0 is fine), `Shape()` (a wire), `ToleranceReached()`.

| Case | Result |
|---|---|
| radius 10, pitch 5, 4 turns, axis Z, x axis X | wire of 4 edges; starts at (10, 0, 0), ends at (10, 0, 20); tangent at the start points to +Y and up (counterclockwise, rising); length 252.1219 against the analytic 4 x sqrt((2 pi 10)^2 + 5^2) = 252.1219 |
| `ToleranceReached()` | 1.6e-5 mm constant, 2-3e-5 mm tapered: the builder approximates, like `breplib.BuildCurves3d` did for the old construction |
| tapered, diameters 20 -> 40 over one segment | ends at radius 20 at height 20; radius is linear in height |
| three segments (pitch 2 x 2 turns, 6 x 3, 2 x 2) | wire of 7 edges, ends at height 26 = 4 + 18 + 4 |
| three segments with diameters 20, 20, 30, 30 | the taper sits in the middle segment only; ends at radius 15 |
| **negative pitch** | **`ErrorStatus() == 12`, no shape.** The builder only advances along the axis |
| left-handed | no option; the builder only winds counterclockwise |

## Hand and direction: mirrors of the base helix

`right_handed` is the winding direction and the pitch's sign the direction along the axis (as in the construction this
replaces, where `right_handed=False` negated the angular component only). Both missing cases are mirrors, with the start
point unchanged:

- `right_handed=False`: mirror across the plane through the axis and the x axis (normal = axis x x axis);
- negative pitch: mirror across the plane through the axis origin normal to the axis;
- both: both mirrors.

Tested in `tests/test_curve_features.py`: the left-handed curve starts at the same point, has `y < 0` just after the
start and ends at the same height; the negative-pitch one ends at z = -6 and still winds counterclockwise.

## Taper by height

The builder takes a diameter at each segment boundary, so a taper that is linear in *height* over the whole helix is the
radius at each boundary: `r0 + (r1 - r0) x cumulative height / total height`. The checks run the radius against that
formula at several arc-length fractions of a two-segment helix (`test_taper_runs_through_all_segments_by_height`).
A taper angle is converted at the API: `end_radius = radius + |height| x tan(angle)`; the response returns both.

## Consumers

All unchanged and tested against a tapered, variable-pitch helix:

- **Sweep along a helix** (`curve_feature_id` path): a 0.5 mm circle along a 4-segment spring widening from 10 to 14 mm is
  a valid solid with volume `pi r^2 L` within 2% (Pappus).
- **Create Plane normal to a curve** (`point_and_tangent_at_fraction`): at 0.5 of the arc length of a tapered helix the
  point is on the cone at that height, and the normal is a unit vector. (Half the *length* is a little past half the
  *height*, since the wide end is longer per turn.)
- **Fill Surface** uses the same wire; no change.

## Left open

The builder's approximation (1.6-3e-5 mm) means a length computed from the wire differs from the analytic length by about
4e-5 relative (221.8775 against 221.8694 for the spring in the tests).
