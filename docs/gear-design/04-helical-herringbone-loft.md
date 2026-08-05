# Workstream 4 — Helical/herringbone gears + general `LoftFeature`

Read `00-conventions.md` first. Depends on Workstream 2 (`GearFeature`
profile-building) and, for the Loft path specifically, is itself a
prerequisite spike (see delivery order in `README.md`) before committing.

## 4a — Helical/herringbone teeth: two viable OCCT techniques

Decide which during implementation, based on the 4b spike below:

- **Sweep the 2D tooth profile along a helical path** — geometrically the
  *correct* way to generate a true constant-lead helical tooth surface
  (what real CAD/manufacturing tools do), more accurate than a loft
  (which only interpolates a ruled/smooth surface *between* two end
  cross-sections). Requires extending `SweepFeature`'s path concept,
  since its `path_refs` today only accepts a picked chain of existing
  Sketch Lines/Arcs/Ellipses/Splines, not a procedurally generated helix
  curve.
- **Loft between two profile copies, rotated relative to each other by
  the helix's twist angle** — simpler, an approximation (the surface
  between two lofted cross-sections isn't exactly a helicoid).

**Recommendation**: build the general Loft feature (4b) regardless — it's
independently useful — but implement helical teeth via the
sweep-along-helix technique for correctness, falling back to Loft if the
helix-sweep spike proves too costly.

**Superseded by the 2026-08-04 spike below**: real prototyping overturned
this — build helical teeth via Loft-between-two-rotated-copies as the
*primary* technique, not a fallback. See "Spike findings" at the end of
this file for the evidence.

**Herringbone** = two opposite-handed helical halves joined at the gear's
mid-plane (mirrored, not simply "twice as tall").

## 4b — General `LoftFeature`

A genuinely new, standalone Feature (not gear-specific — same
"useful on its own" status Sweep already has): lofts between 2+ Sketch
profiles via `BRepOffsetAPI_ThruSections`, with user-selectable start/end
reference points per profile to control twist. OCCT doesn't expose "pick
a vertex to align" directly — achieving it means reordering each
profile's own wire edge-traversal start to begin at the user-chosen point
before feeding wires to `ThruSections`, and matching winding direction
across profiles.

**Spike this early**, before committing gear teeth to depend on it — new
OCCT usage in this codebase, real correctness risk (self-intersecting
lofts/sweeps at high twist angles, wire-orientation mismatches).

## Complexity/risk

High. Both paths are genuinely new OCCT techniques for this codebase.
Budget real spike time before committing to an approach.

## Spike findings (2026-08-04)

Investigate/prototype pass, not a build — no shipped code from this
session. Ran against a real bootstrapped `pythonocc-core` conda-forge env
(same recipe every prior session's own status.md entry used: micromamba
from `github.com/mamba-org/micromamba-releases`' GitHub Releases
download-asset URL, `micro.mamba.pm`/the GitHub API blocked but
`conda.anaconda.org` reachable — built `backend/environment.yml`'s env for
real, `pythonocc-core=7.9.3=novtk*`). All numbers below are from real OCCT
construction, not reasoning about the API.

### Result 1 — `ThruSections` vertex correspondence does NOT depend on wire
### edge-traversal order in this codebase's actual OCCT build

This directly contradicts 4b's own stated premise above. Tested three
ways, all against `BRepOffsetAPI_ThruSections(isSolid=True, ruled)` for
both `ruled=True` and `ruled=False`:

1. **Real 20-tooth module-2 gear profile** (320 points,
   `full_gear_profile_points`), bottom wire built from the raw point list,
   top wire built from the *same, unrotated* point list but cyclically
   shifted by 0/4/8/16/40/160 points before being fed to
   `BRepBuilderAPI_MakePolygon` — a pure re-index, no coordinate rotation
   at all. If correspondence followed wire order, this should read back as
   an apparent twist of up to 180°. Measured via the tooth-tip's angular
   position at a mid-height planar section
   (`BRepAlgoAPI_Section`): **identical to the decimal place in every
   case** (`-37.810°`, matching the untwisted profile) — re-indexing had
   zero effect.
2. Same null result for a small asymmetric 6-vertex "flag" polygon (used
   throughout this spike as a hand-checkable stand-in), both for a pure
   re-index and for a genuine winding-direction flip (building the wire
   from the reversed point list, and separately via `TopoDS_Wire.
   Reversed()`) — traced the loft's actual generator edge from a specific
   non-degenerate marker vertex (`(10,0)`, *not* the origin — an earlier
   pass of this same check mistakenly used a vertex sitting exactly on the
   rotation axis, which is invariant under any rotation and can't actually
   distinguish a correct correspondence from a broken one) and confirmed
   it always lands on the geometrically-correct rotated partner, CW or CCW
   winding, reindexed or not.
3. Same null result even for the **general, non-gear case**: a square
   (4 vertices) lofted to a differently-shaped, differently-sized
   irregular hexagon (6 vertices) — cycling the hexagon's own start vertex
   through all 6 positions produced byte-identical results every time.

Confirmed this isn't a broken measurement: actually rotating a profile's
real coordinates (not just re-indexing which point is listed first) does
change every one of the above measurements, every time — and
`TopExp_Explorer`'s reported "first" vertex of a wire genuinely does
change under re-indexing (checked directly), so the wire's own topology is
really different — `ThruSections` is just not using that ordering for its
correspondence. It appears to use a real geometric/parametric matching
(candidates worth a closer look if this is ever revisited: `ParType`/
`SetParType`, or the otherwise-unused `AddVertex`), not "vertex *N* of
wire A ↔ vertex *N* of wire B".

**Practical implication for helical teeth**: achieving a specific twist
between two copies of the *same* tooth profile needs nothing more than
pre-rotating the top copy's real `(x, y)` coordinates by the desired angle
before building its wire — no wire-reordering step, no winding-direction
correction. Simpler than this file originally assumed.

**Still open** (not resolved by this spike, flagged for whoever builds 4b
for real): if the general `LoftFeature`'s own "pick a reference point per
profile" UI is meant to let a user align two genuinely *different*
profiles by an arbitrary chosen point pair (not just twist a repeated
profile), Result 1's third case shows plain wire re-ordering won't drive
that either — `ThruSections` already picks its own correspondence
regardless. Getting explicit, user-controlled correspondence for
dissimilar profiles may need a different OCCT mechanism entirely (the
`AddVertex`/`ParType` candidates above), or an explicit pre-alignment
transform of one profile before lofting. Real open question, not answered
here.

### Result 2 — OCCT's own validity checks are weak signals for a twisted
### loft's self-intersection

Sanity-checked both checkers this codebase would otherwise reach for
against a deliberately, obviously self-intersecting "bowtie" quadrilateral
(`(0,0),(10,10),(10,0),(0,10)`) prism: `BRepCheck_Analyzer(shape).
IsValid()` correctly caught it (`False`). `BOPAlgo_CheckerSI` (OCCT's
dedicated self-interference checker) **did not** — `HasErrors()` returned
`False` on the same obviously-bad shape. Neither checker flagged anything
as wrong across the entire twist sweep in Result 3 below, including a
case (Result 3, "blade" profile) independently confirmed bad by a third,
more direct method. Conclusion: don't rely on `IsDone()`/`BRepCheck_
Analyzer`/`BOPAlgo_CheckerSI` alone as this feature's correctness signal —
whoever builds this needs a real geometric check (this spike used:
`BRepAlgoAPI_Section` at a representative height, reassemble the loose
section edges into one wire via `BRepBuilderAPI_MakeWire.Add` — which can
only ever produce a single connected loop — and compare its area against
the known, rotation-invariant expected value).

### Result 3 — self-intersection risk for realistic gear-tooth profiles is
### low even at extreme twist; the risk is real for other profile shapes

Same 20-tooth module-2 gear profile, looped between two rotated copies at
twist angles 5°–1080° (face width 20mm; twist 1080° is 3 full turns, past
the point where the test methodology itself becomes ambiguous — rotating
a rigid point set by 360°+k is indistinguishable from rotating it by k,
so results above ~350° aren't evidence about "more turns," only about
periodicity — noted, not a real OCCT limitation). Every single case:
`BRepCheck` valid, positive sane volume, and (Result 2's stronger check)
a clean single-wire mid-height section with the correct area. Pushed a
deliberately much deeper 6-point star (tip:root radius ratio up to 40:1 —
far more concave than any real involute gear tooth's ~1.1–1.3:1) through
the same sweep, twist up to 340°, face widths 1mm–10mm: same clean result
every time.

Self-intersection **is** a real, reproducible phenomenon for other profile
shapes — a thin, far-off-axis "blade" profile (a 2×40mm rectangle rotated
about its own centroid, like a plain fan-blade cross-section) showed
genuinely corrupted mid-sections (area up to 5.5× the expected value, one
case fully degenerate at 0 area) starting around 60°–110° twist,
especially at short face widths — proving the check methodology itself
finds real failures when they exist, not just reporting "fine" no matter
what.

**Conclusion**: for the actual gear-tooth application (loft between two
rotated copies of a real involute tooth profile), self-intersection risk
is low well beyond any twist a real helical gear would ever use (helix
angles rarely exceed ~45°, and even at a 46° helix angle/20mm pitch radius
this spike's own module-2/20-tooth reference gear only needed ~27° of
twist over a 20mm face width).

### Result 4 — sweep-along-helix: the path is easy, a *correct* (non-
### distorting) tooth cross-section is not

Building a real helix path curve in OCCT is genuinely simple and works
first-try: a `Geom2d_Line` in the `(angle, height)` parameter space of a
`Geom_CylindricalSurface`, converted to a 3D edge via
`BRepBuilderAPI_MakeEdge(line2d, cylindricalSurface, u0, u1)` +
`BRepLib.BuildCurves3d` — confirmed against known start/end coordinates.

The hard part is downstream: a real helical gear tooth's cross-section at
any height `z` must be *the same 2D involute profile as the base spur
gear, rotated by θ(z), never tilted* out of the plane perpendicular to the
gear's own axis (that's what a hobbing cutter actually produces).
`BRepOffsetAPI_MakePipeShell`'s trihedron modes don't give this for free:

- Default (`CorrectedFrenet`): a circular test profile's mid-height
  section came back visibly non-circular (bounding-box aspect ratio
  1.0999, should be 1.0) — the profile tilts to track the helix's own
  local tangent, which has a real angular component for any non-zero
  helix angle. Wrong for a gear tooth.
- Strict Frenet / fixed-binormal-along-the-gear-axis
  (`SetMode(gp_Dir(0,0,1))`): passed the circular-profile check (aspect
  1.0) — but a circle is rotationally symmetric and can't actually tell
  "correctly rotating with height" apart from "not rotating at all".
  Re-tested with the asymmetric flag profile specifically to check real
  rotation, not just absence of tilt: found a genuine ~14% cross-
  sectional-area distortion at mid/end height even in this best-so-far
  mode — not solved by picking one of `MakePipeShell`'s four built-in
  modes, would need a custom rotation law.

Compare against the loft's own known approximation error over the same
twist range: 1–7% cross-sectional area deviation from a true rotation
(Result 3's own gear/star tests, twist up to 90°) — smaller than, and
better-understood than, this spike's best unresolved sweep attempt.

### Recommendation, revised from the top of this file

**Build the general `LoftFeature` (4b) as planned — still independently
useful. For helical/herringbone teeth specifically, use loft-between-two-
rotated-profile-copies as the primary technique, not a sweep-along-helix
fallback.** Reasons, all backed by the results above: self-intersection
risk for real gear-tooth profiles is low far beyond any realistic helix
angle (Result 3); twist control turns out simpler than assumed — no wire
reordering needed at all for the rotated-copy case (Result 1); the loft's
own approximation error is small and predictable at realistic helix angles
(Result 4); and getting `MakePipeShell` to actually reproduce a true,
non-distorted helicoid needs real additional spike time this pass didn't
resolve — the exact "too costly" condition this file's original
recommendation already anticipated as the fallback trigger, now confirmed
by prototyping rather than assumed going in. Dropping/deferring the
`SweepFeature` path-model extension entirely unless a future need
specifically requires true-helicoid manufacturing accuracy.

### Implementation sketch — twist control for the rotated-copy loft

Not full code. For each of the two (or more, for a multi-section
herringbone-style loft) profile copies:

1. Resolve the profile's own points in its Sketch's local `(x, y)` exactly
   as `wire_for_profile` already does for any other Feature.
2. Apply a plain 2D rotation (about the profile's own local origin, or
   whatever point the gear's pitch axis maps to in that Sketch's local
   frame) by the desired twist angle for that copy — `0` for the first
   copy, the full helix twist for the last, and (for a future finely-
   subdivided loft rather than just 2 sections) intermediate angles for
   any sections in between.
3. Build each rotated copy's wire via the ordinary, unmodified
   `wire_for_profile`/`BRepBuilderAPI_MakePolygon` path — Result 1 above
   found no reordering step is needed for this case.
4. Feed the resulting wires to `BRepOffsetAPI_ThruSections` in height
   order, `isSolid=True`. `ruled` vs smooth made no measurable difference
   for a 2-section loft in every test this spike ran (expected — a spline
   fit through exactly 2 points degenerates to the same result as a
   straight line); only matters once 3+ sections are involved.
5. Validate with a real geometric check, not `IsDone()`/`BRepCheck_
   Analyzer` alone (Result 2) — e.g. a mid-height section compared against
   the known expected area, or (cheaper, if this ships without per-request
   validation) simply trust Result 3's finding that realistic gear-tooth
   profiles at realistic helix angles don't self-intersect, and skip
   runtime detection — a documented, evidence-backed judgment call rather
   than an unverified assumption.

For the general `LoftFeature`'s own user-facing "reference point per
profile" control (profiles that are *not* simply rotated copies of each
other): still an open question per Result 1's "Still open" note above —
needs its own follow-up spike before that specific UI is built, separate
from the gear-tooth case this pass focused on.

## 2026-08-05 addendum — Part Designer UI + thin/open-chain mode

A later, separate session (`docs/status.md`'s own 2026-08-05 "Loft
accessible in the 3D Part Designer" entry) built the general-purpose Part
Designer UI this doc's own 4b section describes but never had a client
for, and extended `LoftFeature` with a `thickness` field: when set, every
section is a single open chain (`app.sketch.profile.detect_open_chain`)
instead of a closed Profile, lofted into a shell and thickened into a
solid via `BRepOffsetAPI_MakeThickSolid.MakeThickSolidBySimple` rather than
lofted directly into a solid. See that status.md entry for the full
design and verification-status detail - not repeated here.
