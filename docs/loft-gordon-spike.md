# Loft on Gordon surfaces: spike results (2026-10-26)

Milestone 1 of `docs/loft-gordon-and-helix-plan.md`. The spike ran on OCCT 8.0.1 / pythonocc-core 8.0.1.2 with throwaway
scripts (not committed); what it learned is built into `backend/app/document/loft_gordon.py`, which is the production
code. Items are numbered as in the plan.

**Decision: Gordon for every Loft and Loft Surface, guided or not.** On the unguided cases Gordon is not worse than
`ThruSections` by the plan's criteria (item 9), so the fallback decision (Gordon for guided lofts only) is *not* taken.
Two things differ from what the plan assumed, both cheap to live with: unguided lofts keep a `ThruSections` safety net
(item 9), and a guide that misses is snapped by us rather than rescued by Gordon's approximate mode (item 5).

## A measurement warning

`BRepGProp::VolumeProperties(shape, props)` with its default accuracy is only about 1% accurate on a face made of a
few-knot B-spline surface. Early spike runs showed 0.2-1% "volume differences" between Gordon and `ThruSections` that were
pure integration noise (the same Gordon cone read 621.0, 621.2 and 615.75 depending on the call). Everything below uses
the adaptive form, `VolumeProperties(shape, props, 1e-6)`. `tools/occt_compare/geomdiff.py` was changed the same way (and
now also records each feature step's time), and `tests/test_loft_feature.py::_volume` too.

## 1. One face per edge: (b), a Gordon network per section edge, sewn

- **(a)** one network over the whole closed section was not pursued: it needs periodic networks and then a split into
  faces along isolines, with no gain over (b).
- **(b)** works. For every section edge *i*, profiles are edge *i* of each section and the guides are the *hidden
  guides* through vertex *i* and vertex *i+1* of all sections (a straight line for two sections, an interpolating curve
  through the vertices for more), plus any user guide that crosses inside the edge. The patches are turned into faces
  and sewn with `BRepBuilderAPI_Sewing` (1e-4), the caps added, the shell made a solid and `ShapeFix_Solid`'d.
  Rectangle to rectangle: 6 faces, 12 edges, valid, volume exact (1060.00 = `ThruSections`), and a corner edge fillets
  (`BRepFilletAPI_MakeFillet`, valid result). The same holds for circle to square, triangle to rectangle, a twisted
  square, three-section lofts and a ruled loft.
- A patch whose surface turns out planar (the straight-sided case) is rebuilt as a real `Geom_Plane` face bounded by its
  four boundary curves (`GeomLib_IsPlanarSurface`). Left as a flat B-spline surface, `_mid_section_warnings`' plane cut
  took 160-300 ms instead of 6-11 ms.
- **A single closed edge (a circle) is one periodic face.** One guide is `InvalidInput`; hidden guides at equal
  parameter fractions work (three for an unguided loft: exact cone volume, 3 faces like `ThruSections`). With user
  guides we use twelve, because the guides are interpolated through all of them: one bump on a circle made the loft 20% too big
  with three hidden guides, 12% with four, 5.6% with twelve.

## 2. Closed sections

All build. Two things Gordon needs that `ThruSections` did not:

- **Rational and non-rational profiles do not mix** (`ResultStatus_CurveCompatibilityFailed`, status 8): an arc (rational)
  against a line fails. Every profile and guide is converted to a non-rational B-spline with parameter range 0..1;
  conics are approximated by a C2 spline to 1e-7 (`GeomConvert_ApproxCurve`, measured error 2.7e-9 mm). Circle to square
  then works, volume within 0.2% of `ThruSections`.
- Edge-count harmonisation, reseam and auto-align stay as they are; they define the vertex correspondence the hidden
  guides go through. A section with a `reference_point` is now also auto-aligned (see item 9).

## 3. Hidden guides for unguided lofts

A curve through each set of corresponding vertices: `GC_MakeSegment` for two sections, `GeomAPI_Interpolate` (no end
tangents, non-periodic) for three or more. Rect-rect-rect and circle-circle-circle match `ThruSections` (volume within
0.03%). Two sections that share a vertex position have no guide between them; that raises and the loft falls back to
`ThruSections`.

## 4. Ruled lofts

One network per span between neighbouring sections with straight hidden guides: the exact frustum volumes
(`tests/test_loft_gordon.py::test_a_ruled_three_section_loft_is_straight_between_sections`, rel 1e-6). **User guides with
`ruled=True` are a 422** (`a ruled loft cannot have guide curves`): straight spans contradict a curved guide. Enforced in
the router (`_validate_loft_guide_curves`) and in the AI plan validator.

## 5. Guides that miss

On a 10 x 10 x 8 rectangle loft with a guide through the middle of an edge:

| Guide | Gordon exact mode | Gordon `AllowApproximateFallback` | Tolerance raised to the miss |
|---|---|---|---|
| exact | builds, guide on the surface to 0.0000 | same | n/a |
| 0.2 mm off | `IntersectionFailed` (status 4) | `IntersectionFailed` | builds, but the surface **leaves the profile by 0.17 mm** |
| 2 mm off | `IntersectionFailed` | `IntersectionFailed` | builds, surface leaves the profile by 1.44 mm |
| missing a section entirely | `IntersectionFailed` | `IntersectionFailed` | n/a |

So: approximate mode does **not** rescue a network that does not intersect (it covers later stages only, and
`IsApproximate()` stayed false throughout), and a tolerance large enough to accept the miss makes the surface leave the
section, so it no longer meets the end caps. The plan's stated fallback applies: **we snap the crossing and warn, and
return a 422 beyond a limit.** Each user guide is located against every section (curve-curve extrema plus the end
points, which extrema miss); if it passes within 10% of the loft's bounding-box diagonal of a section, it is rebuilt
through the exact points on the sections (the offset at each crossing blended along the span after it) and the loft
warns `Guide 1 misses section 2 by 0.30 mm; the surface was bent to meet both, so it deviates from the guide by up to that
much.` Beyond the limit, or a guide that crosses a section twice, doubles back, or reaches sections out of order:
`422 invalid_guide_curve_ref` with `index` (the guide) and `section`. `SetApproximationMode(AllowApproximateFallback)` is
still set on every network, and `IsApproximate()` is reported as a warning if it ever fires.

## 6. A guide crossing mid-edge, at a vertex, or moving between edges

- Mid-edge: becomes an interior guide of that edge's patch. One face, shaped by the guide (exact: guide to surface
  distance < 1e-4 mm for every sample; three sections too).
- At a vertex (within 1% of the edge's parameter range of it): it *replaces* that vertex's hidden guide (guide on a
  rhombus corner edge, `test_a_guide_through_a_corner_replaces_that_corners_hidden_guide`). Two guides through the same
  corner: 422.
- Moving from one edge to another between sections (or mid-edge on one section and at a corner on the next): **422**
  `crosses the sections on different edges`. The face structure would have to change between sections.

## 7. End caps

Planar caps from the first and last section wire (`BRepBuilderAPI_MakeFace(wire, OnlyPlane=True)`). For a non-planar
`edge_ref` section `ThruSections` returned an **invalid, uncapped 4-face shell** (`BRepCheck_Analyzer` false); Gordon
raises `422 loft_failed: section 1 is not planar, so the loft cannot be capped there; use a Loft Surface instead`.

Open chains (thin lofts, Loft Surface of open chains) are oriented the way `ThruSections` oriented them: a chain running
the opposite way to its neighbour is reversed, otherwise a loft between two body edges is a bow-tie (the test
`test_loft_surface_between_two_body_edges_succeeds` caught this: area 50 against 100).

## 8. Thin lofts, and the L-chain from the OCCT 8 evaluation (1c)

- Open-chain and closed-profile thin lofts go through the same `thicken_shell_to_solid` as before. The shells have the
  same faces and the same normals as `ThruSections`' (checked on five chains, including reversed and slanted ones).
- **The L-chain (10 and 6 mm legs, 8 mm apart, thickness 1) gave ~88 mm³ instead of ~136, and that was not the loft's
  fault; it is fixed on this branch.** Gordon's shell is identical to `ThruSections`' (2 planar faces, area 128 = 16 x 8).
  The wrong volume came from `thicken_shell_to_solid`: `_thicken_by_join` returns only the offset *shell* (no solid) when
  there are no closing faces, `_thicken_by_capping_free_bounds` cannot cap this shell (its free boundary is one
  non-planar loop), and the fallback `MakeThickSolidBySimple` offsets each face by itself and leaves the corner open.
  The right answers are analytic: 8 x (10 + 6 + 1) = **136** with the material on the outside of the bend (the mitre adds
  a 1 mm corner square) and 8 x (10 + 6 - 1) = **120** on the inside.
  - New path `shell_ops._thicken_by_offset_and_walls`, tried after the two existing ones and before `Simple`: the mitred
    offset shell (`MakeThickSolidByJoin`, `GeomAbs_Intersection`, no closing faces) plus a `brepfill.Face` wall between
    every free edge and its offset partner, sewn and made a solid. It gives exactly 136 and 120, a valid solid, for both
    signs; the sides of the thickness are the same ones `Simple` used. Edge ends must be read in the edge's *oriented*
    direction (`TopExp::FirstVertex(edge, True)`), not the curve's parameter direction, or the walls twist.
  - Found on the way: for a single flat wall with a negative thickness `_thicken_by_capping_free_bounds` returned a valid
    solid of volume **0.0**. Every path's result is now checked for a plausible volume (0.3-3 x area x |thickness|) and
    falls through to the next path when it is not.
  - Tests: `tests/test_shell_ops_open_walls.py` (flat, L, U, two 45-degree bends, quarter-cylinder; analytic volumes on both
    sides) and `test_thin_loft_between_two_l_shaped_open_chains` (136 and 120 through the loft).

## 9. Unguided comparison

Every body from the loft tests (`test_loft_feature`, `test_loft_seam`, `test_loft_surface_*`, `test_ruled_surface_feature`,
`test_lod_pattern_loft`, `test_edge_ref_surface_inputs`, `test_body_cache_get_features_fix`, `test_thicken_feature`; 106
tests) built both ways with `tools/occt_compare/geomdiff.py`, `main` against this branch, same machine:

- **Every loft test passes.** Some needed changes, none for a Gordon defect: two guide tests pinned the old translation
  behaviour ("slides each section along the rail", "requires an alignment point on every section"; replaced), two more
  only renamed the field (`guide_curves`), the triangle-to-circle test (it required the automatic seam within 1 mm³
  of the best of twelve explicit seams; the Gordon surface blends differently between neighbouring start vertices and the
  best seam is 0.8% above the corner-aligned one, so the tolerance is now 1% of the volume, the plan's own figure), and
  the ruled-surface equivalence test (it compared exact mesh vertices of a `ThruSections` ruled surface against a Loft
  Surface; now they are compared by bounds and area).
- **Validity:** 184 bodies compared (one more on each side that only one run produced), 185 of 185 valid on both sides.
- **Topology:** the same face/edge/vertex counts for every body but one. Face counts per section edge are unchanged,
  circles stay one face. The exception is `test_reference_point_alignment_changes_the_lofted_geometry`: a 10 x 4 rectangle
  twisted by 223 degrees through a `reference_point`. `ThruSections` joined it to the nearest corner match (290.6 mm³
  against the 320 mm³ prism, 6 faces); the section now goes through the same automatic alignment as every other closed
  section (before, `reference_point` opted out of it, because only `ThruSections` searched for a correspondence), whose
  best start lies mid-edge, so one edge splits into two: 7 faces, 311.9 mm³ (less twist). This is the one place the face
  count differs from the old result; it is a better-aligned loft with one more face.
- **Volume:** the other differences are all test cases where `ThruSections` and Gordon use a different vertex
  correspondence, and each was inspected: (i) `test_square_to_circle...` and `test_triangle_to_circle...` deliberately
  switch the automatic alignment *off* to measure a poor correspondence, and `ThruSections` then silently searched for a
  better one while Gordon honours index correspondence, so that "bad" body is worse than it was (the user-facing default,
  auto-align on, is the same shape as before, within 0.2%); (ii) `ThruSections` returned **negative-volume (inside-out)
  solids** for some poor seams (-127 mm³ against Gordon's +130); (iii) open-shell "volumes" are the signed volume of an
  open surface and not meaningful (the signs differ with the shell's orientation; the normals themselves match, item 8).
- **Speed:** summed feature-step time 20.2 s against 21.5 s over 125 steps (+6%); the slowest loft step is 1.6x (0.24 s
  against 0.38 s for the twisted rectangle, whose seam splits an edge). Before the planar-face change the slowest was 11x
  (`_mid_section_warnings` cutting a flat B-spline face). The criterion is "no case more than 3x slower": met.
- **`ThruSections` stays as the safety net for unguided lofts.** Gordon cannot build every network: sections that
  intersect each other (a loft between a vertical edge and a horizontal one that crosses it, exercised by
  `test_loft_surface_between_a_body_edge_and_an_open_sketch_chain_succeeds`) fail with an OCCT `Standard_OutOfRange`
  inside `Perform`. An unguided loft that Gordon cannot build is built by `ThruSections` as before (logged); a guided loft
  is a 422 naming the guide.

## 10. Coarse (LOD) previews

`resolve_loft_coarse_from_bodies` hands a two-section copy of the feature to the same code, guides included; a guide still
crosses the first and last section. `test_coarse_preview_keeps_the_guides`.

## Other spike findings worth keeping

- `GeomFill_Gordon` wants `TColGeom_Array1OfCurve` of B-splines; `Init(profiles, guides, tol)` then `Perform()`;
  `Status()` is an int, names in `ResultStatus_*`.
- Gordon and `GeomLib_IsPlanarSurface` do their own work in 5-30 ms per face for these sizes.
- pythonocc 8 reminders: copy getter results you keep; `Geom_TrimmedCurve.Reversed()` returns a plain `Geom_Curve`
  (use `Value(FirstParameter())`, not `StartPoint()`); `Geom_BSplineCurve::SetKnot` one at a time fails when the new
  range overlaps the old (use `SetKnots` with the whole array).
