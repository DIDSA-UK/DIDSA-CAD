# Workstream 12 — Spiral bevel gear feasibility/scoping (pre-spike)

Read `00-conventions.md` first. This is a feasibility/scoping doc, not an
implementation doc — one step *before* `10-bevel-gear.md`'s own "budget
real, dedicated spike time" stage. It proposes what to spike and why, not a
finished, buildable approach. No code changes accompany this doc.

**A note on sourcing, since it matters for trusting anything below**:
`10-bevel-gear.md` and `11-bevel-pair.md` are stale relative to the current
`backend/app/document/bevel_math.py`/`bevel.py`/`bevel_pair.py`. Both still
narrate true spherical-involute tooth-flank construction as current fact
and don't mention Tredgold's approximation, the mesh-interference-margin
system, Crown Gear, or the disc-like pitch-cone-angle warning — all of
which exist in code today. Every claim in this doc is checked directly
against current source, not against that prose.

## Why the straight-tooth assumption is still there, just moved

Straight bevel's tooth-flank construction changed since `10-bevel-gear.md`
was written. `bevel_math.tredgold_bevel_point`'s own docstring explains why,
plainly:

> "on-device testing found two real, differently-sized mating bevel gears
> built via the true spherical involute independently on their own base
> cones do *not* reliably mesh without interference (confirmed via direct
> `BRepAlgoAPI_Common` overlap measurement on a real `BevelPairFeature`,
> comparable in size to a full tooth height) - the true-spherical
> construction has no guaranteed conjugate-action relationship between two
> *different* gears' independently-generated flanks the way Tredgold's
> shared-back-cone-projection method does by construction (any two gears
> of the same module/pressure angle, built this way, are conjugate - the
> same guarantee ordinary planar involute spur gears already rely on, now
> inherited via the flat/virtual-gear step below)."

So today's tooth flanks are built by `tredgold_bevel_point`: take a point
on the ordinary *planar* involute-of-a-circle (`gear_math.involute_point`,
2D, no cone involved) in the gear's own "back cone unrolled flat" domain,
then map it onto the real pitch sphere — `real_azimuth = flat_azimuth /
cos(gamma)` (arc-length-preserving unroll), `radial = r_v*cos(gamma)`,
`axial = cone_distance/cos(gamma) - r_v*sin(gamma)` in the real meridian
plane, read `colatitude = atan2(radial, axial)`, then re-project onto the
sphere of radius `cone_distance`. Full derivation, with an exact-at-the-
pitch-point algebraic check, is in that function's own docstring.
`sample_tredgold_flank` calls this once per `sphere_radius` (outer, then
inner), deriving `pitch_radius_v = sphere_radius * tan(gamma)` and
`base_radius_v = pitch_radius_v * cos(pressure_angle)` fresh each time.
True spherical-involute code (`spherical_involute_point` and friends) is
still in `bevel_math.py`, still correct, still unit-tested — just no longer
called by `bevel_tooth_flank_pair`.

The straight-line-tooth assumption this doc is about survives the rewrite,
unchanged in shape, in three places:

- **`bevel_math.bevel_tooth_flank_pair`**: computes exactly one `offset =
  _tredgold_flank_start_offset_angle(geometry)` and applies it identically
  to *both* the outer (`geometry.cone_distance`) and inner
  (`geometry.inner_cone_distance`) flank curves via `_rotate_about_z`. No
  azimuthal variation with `sphere_radius` exists anywhere in this
  function. It's the same "one offset for the whole tooth" pattern the
  pre-Tredgold code had — just applied to a real-azimuth value computed
  after the back-cone unroll, rather than directly to a spherical-involute
  point.
- **`bevel._cone_arc_wire`**: tip-land/root-land faces are a plain circular
  arc at fixed colatitude, exact only because (its own docstring) "a
  straight-bevel tooth is ruled by lines through the apex, so corresponding
  outer/inner arc points lie on the same ray." Nothing about the Tredgold
  rewrite touches this — it's still true today, and still false for a
  curved lengthwise trace.
- **`bevel._thru_sections_face`**: flank, tip-land, and root-land faces all
  use exactly two cross-section wires with `BRepOffsetAPI_ThruSections(...,
  ruled=True)`, exact only for a ruled (straight-generator) surface. Also
  untouched by the rewrite.

## What's reusable

**Survives unchanged**: `pitch_cone_half_angles` (`γ1 = atan(sin(Σ) /
(N2/N1 + cos(Σ)))`, general shaft angle Σ — pure pitch-cone rolling
geometry, independent of tooth-trace shape); `cone_distance = pitch_radius
/ sin(pitch_cone_angle)` and `inner_cone_distance = cone_distance -
face_width`; addendum/dedendum angle formulas; the disc-like/crown-like
thin-hub warning (`thin_hub_warning`, fires ≥75° pitch cone angle — a
structural bore-clearance concern, unrelated to lengthwise tooth shape);
`_assemble_gear_solid`'s overall assembly skeleton (sew → `ShapeFix_Shell`
→ `MakeSolid` → `OrientClosedSolid`, independent volume/self-intersection
cross-checks in place of `BRepCheck_Analyzer`); basis/positioning math for
intersecting-axis gears (`_basis_point3_to_world`, `_sphere_axis`) — valid for
spiral bevel, explicitly not for hypoid (offset axes, no shared apex);
`_inner_cap_flattening_tool`'s explicit-shared-X-direction fix, which
matters even more once a basis is genuinely tilted (any `BevelPairFeature`
member 2).

**Formula survives, role changed**: `base_cone_half_angle` (`sin(gamma_b) =
sin(gamma)*cos(alpha)`, Napier's-rule derivation) is still computed on
every `BevelGearGeometry` — but it is **not** what flank/root-land
construction actually uses any more. `tredgold_base_colatitude` replaced it
for that purpose; its own docstring explains why: reusing `base_cone_angle`
"is a *different* number under Tredgold and left the root-land face's own
boundary circle not passing through the flank curve's actual start point (a
real `BRepBuilderAPI_MakeEdge` failure caught on-device switching this
module over)." `geometry.base_cone_angle` is now largely vestigial for
construction purposes — worth flagging plainly so a future reader doesn't
assume it's still load-bearing.

**Reusable as pattern, not code**: `gear.py`'s helical-gear construction
(`_twisted_basis`, `helical_twist_angle`, `_twisted_tooth_loft`) is the
closest real precedent in this codebase for "rotate a per-cross-section
profile by a position-dependent angle, then loft." It does *not* do a
normal/transverse module conversion — it twists the same flat 2D tooth
outline used for a spur gear by `twist = face_width * tan(helix_angle) /
pitch_radius` (linear in axial position, exact for a cylinder since
`pitch_radius` doesn't vary along the face width), lofting between twisted
copies with `ruled=False`. Its own docstring documents a real bug worth
carrying forward as a named risk (not an unknown-unknown): at large helix
angles, `ThruSections`' default vertex-correspondence search can snap a
tooth's tip vertex to a *different* tooth's root vertex — still
`IsDone()`-valid, silently wrong — fixed via `CheckCompatibility(False)`
since the two wires' correspondence is already known-correct by
construction (same code path, same point order, only a rotation differs).

**Vestigial**: the true spherical-involute functions are present, correct,
and tested, but not proposed for reuse below — see "Candidate approaches"
for why.

**`bevel_pair.py`'s mesh-margin/interference system**: substantial, and
directly relevant — covered in its own section below.

## Candidate approaches

**Rejected: an independent, per-gear azimuthal spiral-offset applied
directly to the (currently-unused) true spherical-involute construction.**
This is the "obvious" naive generalization, and it's named here explicitly
so nobody re-discovers its failure the hard way: it has exactly the defect
the Tredgold rewrite exists to fix — two independently-built gears with no
guaranteed conjugate-action relationship between their flanks. Whatever
spiral-bevel approach is chosen has to inherit conjugate action the same
way straight-bevel Tredgold does, not reintroduce the problem one level up.

**Rejected: true Gleason-conjugate envelope/cutter-simulation generation.**
Deriving the tooth surface as the envelope of a cutter-blade family
(Litvin-style theory of gearing) needs either symbolic envelope-surface
derivation — a differential-geometry exercise with no precedent anywhere in
this codebase — or literal material-removal simulation (many sequential
`BRepAlgoAPI_Cut` operations of a cutter solid against a blank). OCCT
booleans are already the least reliable primitive this codebase leans on
(see `10-bevel-gear.md`'s own end-cap findings); this would need dozens per
tooth, producing faceted results at odds with `00-conventions.md`'s "real
`Geom_BSplineCurve`" convention. It also targets manufacturing-grade
conjugate-contact accuracy that this project doesn't need —
`docs/gear-design/README.md` states the tool's job is solid geometry "ready
to 3D print," not hobbing/grinding tool paths.

**Proposed: layer a position-dependent azimuthal offset on top of the
existing per-cross-section Tredgold construction — the conic analogue of
`gear.py`'s own linear-twist helical technique.**

`gear.py`'s cylindrical helical twist is *linear in axial height*
specifically because a cylinder's circumference doesn't change along the
face width — constant angle-to-generator (helix angle) is equivalent to
linear twist-vs-height only for a cylinder. On a cone, circumference at
cone-distance `R` is proportional to `R` itself, so the same "constant
angle to the generator line" definition of spiral angle `β` requires a
different relationship. Deriving it: unrolling (developing) the cone onto a
flat plane maps true azimuth `θ` at cone-distance `R` to a flattened polar
angle `θ' = θ·sin(γ)` (one full revolution around the cone axis spans
`2π·sin(γ)` once flattened — the same compression `tredgold_bevel_point`
already uses in the other direction). A curve holding constant angle `β` to
the radius vector in that flattened *polar* view satisfies `tan(β) = r /
(dr/dθ')`; solving for constant `β` gives a logarithmic (equiangular)
spiral, `r = r0 · exp(θ'/tan(β))`, i.e. `θ'(R) = θ'_mean +
tan(β)·ln(R/R_mean)`. Undoing the development compression:

```
offset(R) = offset_mean + [tan(β) / sin(γ)] · ln(R / R_mean)
```

where `offset_mean` is exactly today's `_tredgold_flank_start_offset_angle`
value, now evaluated at the mean cone distance instead of applied
uniformly. Concrete integration point: in `bevel_tooth_flank_pair`, replace
the single `offset` applied identically to both `flank(geometry.
cone_distance, ...)` and `flank(geometry.inner_cone_distance, ...)` calls
with `offset(R)` evaluated at each call's own `sphere_radius` — same
function signature, same call sites, minimal in shape. Likely needs more
than the current two `sphere_radius` samples once the offset varies
continuously (not just outer/inner) to keep a loft close to the true curve
— the same reason a herringbone tooth already needs a mid-plane split
rather than two flat end sections.

Sanity check, matching this codebase's own validation culture (the Σ=90°
reduction check in `10-bevel-gear.md`, the rolling-simulation cross-check
in `bevel_math.py`'s history): at `β=0`, `offset(R) = offset_mean` for all
`R`, reducing exactly to today's Tredgold construction. Zerol bevel (`β=0`
at the mean point, curved trace, zero net spiral) falls out of this same
family for free and needs no separate mechanism — flagged as an open
question below whether that reduction is the *complete* story for Zerol or
just the mean-point behavior.

**Open question, stated as such and not asserted**: does this layered
construction actually preserve conjugate action between two mating gears,
the way two ordinary meshing helical gears (matching normal module/
pressure angle, opposite-but-equal helix angle) are proven conjugate? It's
plausible by analogy — the offset is a pure azimuthal rotation of an
already-conjugate-by-construction Tredgold flank, and two mating members
would use matching `β` magnitude with opposite hand — but it is *not yet
verified for the conic case specifically*. This codebase's own history is
a direct warning against trusting a plausible-sounding construction without
a real measurement: that's exactly how the spherical-involute defect was
found. This should be the first thing any spike checks (see
Complexity/risk), ahead of surface-quality questions.

## OCCT construction — open questions

- **Flank faces**: the 2-wire loft stops being sufficient once `offset(R)`
  varies continuously; needs `N>2` sections with `ruled=False` (mirroring
  `_twisted_tooth_loft`'s existing choice) or a genuine sweep along the
  spiral guide curve. Budget for the documented `ThruSections`
  large-twist correspondence bug re-appearing here — likely at *smaller*
  angles than it was found at in `gear.py`, since bevel gears typically
  have fewer, larger teeth than the fine-pitch cylindrical gears that bug
  was found on. Try `CheckCompatibility(False)` first, since the wires'
  correspondence is similarly known-correct by construction here.
- **Tip-land/root-land**: `_cone_arc_wire`'s closed-form arc no longer
  applies. The same `offset(R)` family serves both flank sampling (fix
  `R`, sweep roll angle) and tip/root-land sampling (fix colatitude, sweep
  `R`) — one 2-parameter family, not a new curve type.
- **End-cap faces**: conceptually unchanged (still bounded by points on a
  fixed-radius sphere), but the per-tooth boundary-walk needs updating for
  curved edges — mechanical, not conceptually new.
- **Fold-risk detection** (`_flank_fold_warning`): thresholds were tuned
  for straight/Tredgold-straight teeth. Needs re-validation, not
  carry-forward — a curved multi-section loft is a strictly higher
  self-intersection risk than the 2-section ruled case that already needed
  dedicated spike attention to get right.

## Complexity/risk

Multi-week spike, not days — if anything a harder case than a naive read
would suggest, precisely because this codebase's own history shows the
"obvious" naive approach (independent per-gear curved flanks) silently
fails a real interference test rather than an OCCT-buildability test.
Straight bevel's own construction — with a closed-form exact shortcut
available (ray-coincidence) and a *simpler* problem (no lengthwise
curvature at all) — still took two dedicated spike sessions before real
implementation and was named "the single highest-risk workstream in the
whole project." Spiral bevel loses that shortcut and stacks a real,
previously-triggered failure mode (conjugate action) on top of an unproven
surface-construction technique.

**Riskiest unknown to spike first**: not OCCT surface quality — whether the
layered-offset-on-Tredgold construction actually meshes without
interference between two independently-built members, checked the same
concrete way the original Tredgold decision was validated.

- **Spike A (mesh correctness, minimal OCCT)**: build the smallest possible
  two-member spiral-bevel candidate via the layered-offset approach and
  directly measure interference/backlash via `BRepAlgoAPI_Common`,
  mirroring the exact test that drove the Tredgold rewrite. This gates
  everything else — if it fails, the whole layered-offset approach needs
  rethinking before further investment.
- **Spike B (surface quality)**: once Spike A confirms meshing, attempt the
  multi-section flank loft/sweep at several spiral angles and face widths,
  watching specifically for the `ThruSections` large-twist correspondence
  failure and confirming whether `CheckCompatibility(False)` (or another
  fix) resolves it here too.

Estimate: at least 1–2 weeks of dedicated spike time before a go/no-go call
on the construction approach — comparable to or larger than the original
bevel spike.

## Bearing on BevelPairFeature — see Workstream 13

Spiral bevel *pairing* is no longer just a deferred footnote here — it's
scoped in its own doc, `13-spiral-bevel-pair.md`, which folds in the real
lessons `11-bevel-pair.md`'s own build-and-ship history surfaced (a real
mesh-margin/profile-shift-auto-balancing system exists today, and it
shipped a real regression before it shipped a real fix — worth reading in
detail before assuming pairing is simple wiring once this doc's own
single-gear spike lands). Depends on this doc's own Spike A landing
first, same as everything else pair-shaped in this project has depended
on its own single-gear workstream landing first.

## Proposed v1 scope

**In scope**: spiral bevel gear only (pair scoped separately in `13-
spiral-bevel-pair.md`, which depends on this workstream's own spike
landing first, mirroring how `11-bevel-pair.md` depended on `10-bevel-
gear.md`'s spike landing first); the layered-constant-spiral-angle approximation
as the *only* lengthwise-curve family offered — no user choice between
circular-arc/involute/epicycloid systems, the spiral-bevel equivalent of
straight bevel's own "standard equal-addendum, no Gleason long-and-short-
addendum system" downgrade; user-configurable spiral angle and hand of
spiral; arbitrary shaft angle (inherited free from `pitch_cone_half_
angles`, no reason to restrict); Zerol bevel falls out at `β=0`, no
separate scope line; inherits the existing Tredgold crown-gear-angle cap
(`TREDGOLD_MAX_PITCH_CONE_ANGLE_DEGREES = 89.5`) and disc-like thin-hub
warning unchanged.

**Explicitly deferred**: spiral bevel pairing to `13-spiral-bevel-pair.md`
(depends on this workstream landing, and specifically on Spike A's
meshing-correctness result); true Gleason-conjugate envelope surfaces; root
fillet (already unsupported for straight bevel, not a new gap); hypoid
bevel gears (offset, non-intersecting axes — a separate, even-further-later
phase, not bundled with spiral/Zerol); hand-of-spiral pair-compatibility
validation (scoped in `13-spiral-bevel-pair.md`); DXF flat-pattern/
flank-development export (already deferred even for straight bevel per
`11-bevel-pair.md`; a spiral trace compounds the "unroll a cone flat"
problem further).

## Entry-screen / UX proposal

Grounded in a direct read of `client/lib/gear/bevel_design_screen.dart`
(the live `BevelDesignScreen`).

**Crown Gear's own precedent is the template to follow.** The screen's own
doc comment: "a crown gear is exactly a `BevelGearFeature` with
`pitch_cone_angle_degrees` fixed at 90... it only changes the Pitch cone
angle field (fixed, hidden) and a few display strings." Crown Gear is not
a separate Feature type or a separate screen — it's a UI-level variant of
the existing single-gear mode (`BevelMultiKind.gear`) that fixes one field
and relabels. Propose the same shape for spiral bevel: not a new
`BevelMultiKind` entry, not a new screen — a "Spiral" toggle on the
existing single-gear form (next to Pitch cone angle) revealing two new
fields when on:

- `spiral_angle_degrees` — plain numeric field. Unlike module/pressure
  angle, there's no small fixed set of textbook spiral angles worth a
  standard-values chip row (`_standardModules`/`_standardPressureAngles`'s
  own pattern).
- hand of spiral — a two-way Left/Right toggle, the same UI shape as the
  existing `herringbone` boolean toggle on `GearDesignScreen`'s helical
  fields, per `08-entry-screen-and-preview.md`'s established "new
  gear-type fields land on the existing form, not a new screen"
  convention already used for helical/herringbone.

**No new points-per-flank-style slider for face-width sections.** The
existing `_pointsPerFlank` field controls sampling density *within* one
flank curve; the layered-offset approach additionally needs more than two
cross-sections *along the face width* once the offset varies continuously.
Proposal: derive that section count internally from `spiral_angle_degrees`/
`face_width` rather than exposing another user-facing control — keeps the
parameter surface from growing past what a user can reason about,
consistent with "one approximation family, not a menu" above.

**Preview stays unchanged in v1 — a deliberate scope-down, not an
oversight.** `BevelPreviewCanvas`'s own doc comment: the 2D preview is "the
standard bevel-drafting axial cross-section envelope... not a tooth
outline" — it already doesn't show individual straight-bevel teeth today,
only the cone envelope. Spiral curvature is inherently an azimuthal
(out-of-the-axial-plane) property, so this envelope view can't show it for
either tooth type — it needs no changes for spiral bevel. Where a user
would actually *see* spiral curvature is the full 3D solid, already
viewable via the existing `PartScreen`/viewport3d Orbit View once a
`BevelGearFeature` is created — propose relying on that unchanged rather
than building new preview machinery this v1 scope doesn't need.

**Out of scope for this UX proposal**: any `BevelPairFeature`/
`BevelDesignScreen` pair-mode UI (Auto/Manual profile-shift equivalents,
hand-of-spiral compatibility surfacing) — scoped in `13-spiral-bevel-
pair.md` instead, which depends on this workstream landing first.

## Open questions

- Whether the layered-offset-on-Tredgold construction actually preserves
  conjugate action between two independently-built mating gears — Spike
  A's whole purpose, and the single biggest unknown in this doc.
- Whether Zerol bevel's `β=0` reduction is the complete story, or only
  correct at the mean point.
- Whether `N`-section `ThruSections` or a genuine sweep wins on flank
  surface quality, and whether `CheckCompatibility(False)` resolves the
  large-twist correspondence risk here the way it did for helical gears.
- `geometry.base_cone_angle`'s now-vestigial status is worth a cleanup
  note for whoever next touches `bevel_math.py`, independent of spiral
  bevel.

Pairing-specific open questions (hand-of-spiral validation, whether
`bevel_pair_mesh_margin_degrees`'s radial-only reasoning carries over
unchanged) have moved to `13-spiral-bevel-pair.md`, along with the
lessons `11-bevel-pair.md`'s own real build-and-ship history surfaced for
applying here. `10-bevel-gear.md`/`11-bevel-pair.md`'s own staleness
relative to current code, flagged as an open item when this doc was
first written, has since been addressed directly in both docs.

## Spike findings (2026-08-21) — Spike A: does the layered-offset construction preserve conjugate action?

Real investigate/prototype pass answering this doc's own single biggest
open question, per this doc's own "Riskiest unknown to spike first"
framing. Bootstrapped a real conda-forge `pythonocc-core` 7.9.3 env
(micromamba from GitHub Releases, `backend/environment.yml` - this
project's own established recipe). Scratch-only harness (not committed,
per this project's own spike convention), built by reusing `app.document.
bevel`'s real, already-validated internals directly (`_bspline_wire`,
`_tip_land_face`, `_root_land_face`, `_spherical_cap_face`,
`_flank_fold_warning`, `_flatten_end_caps`, the sewing/`ShapeFix_Shell`/
`MakeSolid`/`OrientClosedSolid` sequence) and `app.document.bevel_pair`'s
real `_tilted_basis`/`_rotated_about_axis` positioning unchanged - only
the flank curve/surface generation itself (the thing actually under test)
is new spike code. Interference measured via real `BRepAlgoAPI_Common` on
the assembled two-member pair, exactly as this doc's own "Spike A" item
and `13-spiral-bevel-pair.md`'s "Verification plan" specify. Small tooth
counts (mostly 10T/10T, module 4, face_width 8, 90° shaft) throughout to
keep per-case build time manageable across a real parameter sweep -
absolute overlap numbers below are from that one representative geometry,
not universal constants, but the *qualitative* findings (which
constructions produce a real spiral trace, which parameter regions break
down, the direction every sweep moves) were checked across the sweep
described below and are the load-bearing result.

### 1. A real dead end in this doc's own formula, worth naming so nobody re-implements it: the literal "Concrete integration point" does not produce a spiral trace at all

This doc's own "Candidate approaches" section says to "replace the single
`offset` applied identically to both `flank(geometry.cone_distance, ...)`
and `flank(geometry.inner_cone_distance, ...)` calls with `offset(R)`
evaluated at each call's own `sphere_radius`" - i.e. plug `offset(R)`
directly into `bevel_tooth_flank_pair`'s existing `angle = offset if
mirror else -offset` structure, unchanged in shape. Implementing exactly
that (spike script `spiral_spike.py`, "v1" below) and measuring it
directly found this is a real, previously-unnoticed bug in this doc's own
derivation, not an implementation slip - proven two ways:

- **Algebraically**: `bevel_tooth_flank_pair`'s right/left flanks are
  built from a single raw curve, mirrored (`sign = -1 if mirror else 1`)
  and rotated by `angle = offset if mirror else -offset`. For any `R`, the
  tooth's own centerline (the midpoint between a matched right/left point
  pair) is `[(raw(t) - offset(R)) + (-raw(t) + offset(R))] / 2 = 0`
  identically, **for every value `offset(R)` takes** - the ± mirror
  structure algebraically cancels the R-dependent term at the centerline
  no matter what function of R it is. Only the tooth's own angular
  *width* (`2 * offset(R)`) becomes R-dependent this way, not its trace.
- **On-device, directly**: sampling `_layered_flank_sections` at 5 radii
  (10T/10T, module 4, β=20°) and reading the actual azimuth of a matched
  right/left point pair at each radius:

  | section (outer→inner) | right az (deg) | left az (deg) | centerline (deg) | width (deg) |
  |---|---|---|---|---|
  | 0 (outer) | -7.747 | 7.747 | **0.000** | 15.495 |
  | 1 | -5.584 | 5.584 | **0.000** | 11.169 |
  | 2 (mean) | -3.250 | 3.250 | **0.000** | 6.501 |
  | 3 | -0.716 | 0.716 | **0.000** | 1.431 |
  | 4 (inner) | 2.058 | -2.058 | **0.000** | -4.115 |

  The centerline is exactly 0.000° at every radius - not approximately,
  exactly, matching the algebra above bit-for-bit. The tooth's own width
  shrinks from 15.5° at the outer end through zero and past it to a
  *negative* 4.1° at the inner end for this β - the flanks literally cross
  over and swap sides before reaching the inner cone distance. This is not
  a spiral tooth by any definition; it's a tooth that pinches shut and
  reopens backwards along its own face width, while its centerline stays
  the same straight ray from the apex a straight-bevel tooth already has.

This fully explains why measuring this construction (v1) gives wild,
non-monotonic interference as β varies (opposite-hand, same 10T/10T pair,
`BRepAlgoAPI_Common` overlap in mm³ against a ~930 mm³ per-tooth reference
volume - full assembled 10-tooth gear volume 9301 mm³ / 10):

| β | 5° | 10° | 15° | 20° | 25° | 30° | 35° |
|---|---|---|---|---|---|---|---|
| overlap (mm³) | 84.7 | 83.0 | **6011.4** | **5473.6** | 274.5 | 14.8 | 2.9 |

No trend - it rises and falls chaotically, because what's being measured
isn't a spiral-meshing question at all, it's an artifact of exactly how
much a malformed, self-crossing tooth happens to clash with its
(equally-malformed) mate at each specific β. Same-hand cases at β=20°/30°
made `BRepAlgoAPI_Common.IsDone()` fail outright (`overlap=None`) rather
than returning a large-but-finite number - the geometry is bad enough that
the boolean can't even complete. **Named dead end**: never plug `offset(R)`
into the existing ±offset/mirror structure directly - the mirror symmetry
that made a *constant* offset correct for straight-bevel Tredgold actively
defeats an R-varying one.

### 2. The corrected construction - and it does reduce to Tredgold at β=0

What this doc's own prose actually intends ("the conic analogue of
`gear.py`'s own linear-twist helical technique") is `_twisted_basis`'s
real behaviour: rotate the *whole* tooth profile rigidly per cross-section,
not offset one flank relative to the other. Fix: keep the existing,
R-independent `offset_mean` (`_tredgold_flank_start_offset_angle`) as the
± term that sets tooth *width* exactly as today, and add a **new** term,
`curve(R) = [tan(β)/sin(γ)] · ln(R/R_mean)`, with the **same sign** to
both flanks (`angle = ±offset_mean + curve(R)`) - a rigid per-radius
rotation on top of the existing width term, not a replacement for it.
Confirmed this actually curves the centerline while holding width
constant (same 10T/10T, β=20° case, spike script `spiral_spike_v2.py`):

| section (outer→inner) | right az (deg) | left az (deg) | centerline (deg) | width (deg) |
|---|---|---|---|---|
| 0 (outer) | 1.246 | 7.747 | 4.497 | 6.501 |
| 1 | -0.916 | 5.584 | 2.334 | 6.501 |
| 2 (mean) | -3.250 | 3.250 | **0.000** | 6.501 |
| 3 | -5.785 | 0.716 | -2.535 | 6.501 |
| 4 (inner) | -8.558 | -2.058 | -5.308 | 6.501 |

Width is exactly constant (6.501° at every section, to full float
precision); the centerline genuinely sweeps through azimuth, curving away
from 0 on both sides of the mean radius - a real spiral trace. At β=0°
this construction's assembled pair reproduces the existing Tredgold
straight-bevel pair's own near-zero overlap exactly (1.7×10⁻⁷ mm³,
matching a real unmodified `bevel._assemble_gear_solid` pair bit-for-bit) -
the sanity check this doc's own §"Sanity check" text calls for, confirmed
on-device, not just algebraically.

### 3. Real measurement on the corrected construction: close to conjugate, but not exact - a real, phase-uncorrectable residual remains

All results below use the corrected (§2) construction. Same 10T/10T,
module 4, face_width 8, pressure_angle 20°, shaft 90° baseline unless
noted; per-tooth reference volume ~930 mm³ (9301 mm³ full gear / 10 teeth).

**Spiral angle sweep, opposite hand** (the doc's own primary "does it
mesh" question):

| β | 5° | 10° | 15° | 20° | 25° | 30° | 35° |
|---|---|---|---|---|---|---|---|
| overlap (mm³) | 84.3 | 82.4 | 79.7 | 77.9 | 75.0 | 71.9 | **4790.4** |
| % of per-tooth volume | 9.1% | 8.9% | 8.6% | 8.4% | 8.1% | 7.7% | **515%** |

5°-30° stays flat, even *slightly decreasing*, in the 72-95 mm³/8-9%
range - a real, small, non-zero residual, not growing with β the way a
naive "more curvature = more mismatch" guess would predict. At 35° it
jumps 60× to over 5× a full tooth's own volume - a distinct, sharp
breakdown, not a continuation of the same trend. This lands squarely in
the "Fold-risk detection... a curved multi-section loft is a strictly
higher self-intersection risk" open question this doc's own "OCCT
construction — open questions" section already named - **not root-caused
this session** (this spike's own scope was Spike A/mesh-correctness, not
Spike B/surface quality); flagged here as a concrete, characterized
threshold (β≥35° breaks down for this specific geometry) for whoever runs
Spike B next, with a working grid-injectivity fold detector
(`bevel._flank_fold_warning`) already available to point at it directly.

**Is the ~72-95 mm³ residual just a bad meshing-phase choice?** Swept the
existing `_rotated_about_axis` phase offset (calibrated for straight
bevel, where a *fixed* rotation is exact for every R since a straight
tooth's centerline never moves) in fine steps around its default value,
same β=20° case:

| phase Δ | -6° | -3° | -1° | -0.5° | -0.2° | 0° (default) | +0.2° | +0.5° |
|---|---|---|---|---|---|---|---|---|
| overlap (mm³) | 88.1 | 74.9 | 66.0 | 64.4 | **63.4** | 77.9 | **7785.6** | 7777.5 |

A small negative correction helps modestly (77.9→63.4 mm³, ~19%), then
overlap rises again moving further negative (88 mm³ at -6°, 265.7 mm³ at
-18° - checked the full half-pitch range), confirming −0.2° to −1° is a
genuine local minimum, not an unbounded improvement. Crossing *past* zero
in the positive direction jumps 100× (7770+ mm³) - a real tooth-into-tooth
collision boundary, not a fine-tuning region. **Conclusion: phase
adjustment recovers at most ~20% of the residual and cannot zero it out -
the ~63 mm³ floor is a real property of the flank geometry itself, not a
positioning artifact.** Unlike straight-bevel Tredgold (whose β=0 residual
*is* exactly zero, to the 1.7×10⁻⁷ mm³ noise floor), this construction is
close to conjugate but not exact.

**Same hand vs. opposite hand** (validates the hand-of-spiral
compatibility requirement `13-spiral-bevel-pair.md` names as an open
question):

| β | 10° | 20° | 30° |
|---|---|---|---|
| opposite-hand overlap (mm³) | 82.4 | 77.9 | 71.9 |
| same-hand overlap (mm³) | 105.8 | 137.3 | 168.1 |

Same-hand is worse at every β tested, and the gap widens with β (23 mm³ at
10° → 96 mm³ at 30°) - real, physical confirmation that opposite-hand
pairing is genuinely required for this construction, not just a labeling
convention, and that the penalty for getting it wrong grows with spiral
angle rather than being a fixed cost.

**Pressure angle sweep** (tests this doc's own "plausibly survives
unchanged" claim about the radial mesh-margin math - see §4 below for the
full answer):

| pressure angle | 14.5° | 20° | 25° |
|---|---|---|---|
| overlap (mm³) | 128.3 | 77.9 | 28.3 |

Same direction real straight-bevel pairs show (`bevel_math.
MESH_MARGIN_SAFETY_BUFFER_DEGREES`'s own calibration docstring: overlap
"largest [at low pressure angle]... shrinking... as pressure angle
rises") - consistent with the radial component of this residual behaving
exactly like the existing, already-calibrated straight-bevel radial
margin.

**Tooth-count ratio sweep** (β=20°, opposite hand):

| pair | 10T/10T | 10T/20T | 8T/16T | 6T/24T |
|---|---|---|---|---|
| overlap (mm³) | 77.9 | 42.3 | **25270.5** | **78199.2** |

10T/10T and 10T/20T stay in the same well-behaved range as the main
sweep; 8T/16T and 6T/24T break down catastrophically - both are cases
where `pitch_cone_half_angles` produces a steep split (6T/24T: γ≈14°/76°,
the larger member already past this codebase's own `CROWN_LIKE_PITCH_
CONE_ANGLE_DEGREES=75°` thin-hub threshold). Consistent with, and likely
the same underlying mechanism as, the β=35° breakdown above - a steep
pitch cone combined with the curved multi-section loft, not a new,
separate failure mode. Not root-caused this session; same Spike B
follow-up applies.

**Shaft angle sweep** (β=20°, opposite hand) - mild, no dramatic effect:

| shaft angle | 60° | 90° | 120° |
|---|---|---|---|
| overlap (mm³) | 82.1 | 77.9 | 65.6 |

**Section-count convergence** (β=20°, opposite hand) - answers this doc's
own "OCCT construction — open questions" flag that 2-section `ThruSections`
"stops being sufficient once the offset varies continuously":

| sections | 2 | 3 | 5 | 9 | 15 |
|---|---|---|---|---|---|
| overlap (mm³) | 94.2 | 77.9 | 77.9 | 77.9 | 77.9 |

Confirmed: the legacy 2-section loft measurably under-counts the real
mismatch (94.2 vs. the converged 77.9 mm³, ~17% off) - this doc's own
flagged concern is real, not theoretical. Good news: convergence is fast,
not expensive - 3 sections already matches 15 sections to full float
precision for this case. `ruled=False` + `CheckCompatibility(False)`
(gear.py's own helical-twist fix) both carried over without needing
further tuning.

### 4. Does the existing radial mesh-margin math survive unchanged? Yes - by construction, not just "plausibly"

`offset(R)`/`curve(R)` are pure rotations about the gear axis
(`_rotate_about_z`) - they change a point's azimuth and *nothing else*.
`bevel_pair_mesh_margin_degrees` and `tredgold_base_colatitude` (the two
functions the existing straight-bevel mesh-margin system is built from)
read only colatitude/cone-distance quantities, never azimuth. So the
spiral extension provably cannot change what they compute - not an
empirical finding, a direct consequence of which coordinate the new math
touches. The pressure-angle sweep in §3 (128.3→77.9→28.3 mm³, same
direction and rough shape as existing straight-bevel calibration) is the
on-device confirmation that this holds in practice too, not just on
paper. **This doc's own "plausibly survives unchanged" hedge is
confirmed - upgrade to "survives unchanged," full stop.**

That said, the *residual* this session measured (§3's ~72-95 mm³/8-9%
baseline, phase-uncorrectable) is not radial - it's the exact tangential
effect `13-spiral-bevel-pair.md`'s own "What's new" section named as the
alternative to "inherits the guarantee for free." See that doc's own
matching spike-findings entry for what this means for pairing.

### 5. Go/no-go

**NO-GO on "conjugate by construction"** - the property this doc's own
"Open question" text asked Spike A to check, and the property Tredgold
gives straight bevel for free. Two separate results support this call:

- The literal construction this doc's own "Concrete integration point"
  text specifies (§1) is not just imperfect, it's a **named dead end** -
  provably not a spiral trace at all, and empirically chaotic/large
  interference as a direct consequence. Do not implement it as written.
- The corrected construction (§2, the one this doc's prose actually
  intended) is much closer - β=0° reduces exactly to Tredgold, moderate β
  gives a small, bounded, mostly-flat residual (~7-9% of a tooth's own
  volume for this test geometry) - but that residual is real,
  **not phase-correctable to zero** (§3's phase sweep), and there is a
  sharp, uncharacterized breakdown regime at high β (≥~35° here) and at
  extreme tooth-count ratios (§3). This is the "approximate,
  parameter-dependent" outcome `13-spiral-bevel-pair.md`'s own "What's
  new" section flagged as the pessimistic branch, not the "inherits the
  guarantee for free" optimistic one.

**What a revised approach needs**, for whoever picks this up next:

1. Use the corrected (§2) rigid-per-radius-rotation construction, never
   the literal formula-into-existing-mirror-structure reading (§1) - this
   is now a settled, proven point, not an open question.
2. Build a real, calibrated tangential margin proxy for the residual in
   §3 - the same treatment `MESH_MARGIN_SAFETY_BUFFER_DEGREES` got for
   straight bevel (calibrate against real `BRepAlgoAPI_Common` sweeps,
   size a safety buffer off the actual observed gap), not a new
   closed-form guess. `13-spiral-bevel-pair.md`'s own "Proposed
   auto-resolution" section's second candidate (a new field, not reusing
   `profile_shift` unchanged) is the right shape.
3. Run a dedicated Spike B (fold-risk/surface-quality, already scoped in
   this doc's own "Complexity/risk" section) before allowing spiral angles
   past roughly 30° or steep tooth-count-ratio splits (γ approaching
   `CROWN_LIKE_PITCH_CONE_ANGLE_DEGREES`) - both break down sharply, and
   this session did not root-cause either. `bevel._flank_fold_warning`'s
   existing grid-injectivity detector is the right starting tool, per
   this doc's own "OCCT construction — open questions" section.
4. The meshing-phase-alignment convention (`_rotated_about_axis`'s fixed
   `±π/2` rotation, calibrated for a straight tooth whose centerline never
   moves) should be re-derived for a genuinely curved centerline rather
   than reused as-is - §3's phase sweep found it's already close to the
   real local optimum (within ~20%) but not exactly at it.

## Spike findings (2026-08-21) — Spike B: root-causing the two breakdown regimes

Real investigate/prototype pass answering this doc's own "What a revised
approach needs" item 3 above (Spike A's own high-β and extreme-tooth-
ratio breakdowns, explicitly not root-caused there). Same real
conda-forge `pythonocc-core` 7.9.3 env (micromamba from GitHub Releases,
`backend/environment.yml`), same scratch-only-harness convention (nothing
below is committed), reusing `app.document.bevel`/`app.document.bevel_pair`'s
real internals unchanged - `_bspline_wire`, `_tip_land_face`,
`_root_land_face`, `_spherical_cap_face`, `_flank_fold_warning`, `_tilted_
basis`, `_rotated_about_axis`, `resolve_member_profile_shifts`, the sewing/
`ShapeFix_Shell`/`MakeSolid`/`OrientClosedSolid` sequence - and, new for
this session, a full N-section spiral member-solid assembler
(`assemble_spiral_gear_solid`, mirroring `bevel._assemble_gear_solid`'s
exact face inventory/sewing order but sampling flank/tip-land/root-land
points from the corrected §2 construction instead of the 2-section
straight one) so real full-gear pairs, not just isolated flanks, could be
measured directly via `BRepAlgoAPI_Common` the same way Spike A's own
numbers were produced.

**Headline result, ahead of the detail below**: neither breakdown is a
flank self-fold. The grid-injectivity/normal-flip detector Spike A's own
task explicitly pointed at (`_flank_fold_warning`) never fires, on either
breakdown, at any β or tooth-count ratio tested - including well past
where the breakdown actually happens. Both breakdowns are real, but
**different from each other and from what Spike A's own doc hypothesized**:
the high-β one is a meshing-*phase* artifact (fixable by re-deriving phase,
item 4 above - not a hard geometric limit), and the tooth-ratio one is a
**pre-existing, non-spiral defect** in the existing straight-bevel
profile-shift/solid-assembly pipeline that this session's own extreme-ratio
testing happened to surface, not "the same underlying mechanism" as the
high-β case the way this doc's own §3 speculated.

### 1. High-β breakdown: not a fold - a meshing-phase artifact, proven by direct recovery

Built the corrected (§2) construction as real N-section (`n_sections=5`,
past §3's own convergence point) flank/tip-land/root-land faces, assembled
into full 10-tooth solids via the new `assemble_spiral_gear_solid`, and ran
`_flank_fold_warning`'s exact grid-injectivity/normal-flip logic (25x25
grid, both signals) against tooth 0's own right flank at the task's own
requested β = 25/28/30/32/35, on the same 10T/10T module-4 baseline Spike A
used - **no fold at any of them**, and pushing further (40 through 65°, in
1° steps near the actual breakdown) still finds none. Also checked, and
also clean throughout: same-tooth (right vs. left flank of tooth 0) minimum
distance, and same-gear cross-tooth (tooth 0 vs. tooth 1) minimum distance
- both stay in the multi-mm range with no sudden drop anywhere in
25-65°. The flank surfaces themselves are geometrically well-formed
(`BRepCheck_Analyzer`-valid, smoothly-growing area, no coincident points,
no normal flips) across the entire range where Spike A's own doc reported
a "distinct, sharp breakdown."

**What actually breaks, and where**: building real full-pair solids (member
2 opposite-hand, both members' geometry given the *same* auto-resolved
`profile_shift` a real `BevelPairFeature` would compute via
`resolve_member_profile_shifts` - `ps1=0.0`, `ps2=-0.6355` for this
10T/10T/module-4/face-width-8/pressure-20°/shaft-90° baseline, so this
isolates the spiral-specific residual from the already-solved radial
dimension exactly as `13-spiral-bevel-pair.md`'s own §4 argues it should)
and measuring `BRepAlgoAPI_Common` overlap directly:

| β | 0° | 20° | 30° | 35° | 40° | 45° | 50° | 51° | **52°** | 55° | 60° | 65° |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| overlap (mm³) | 50.6 | 48.3 | 44.8 | 42.2 | 38.5 | 33.6 | 20.0 | 18.9 | **9119.2** | 9073.3 | 8968.9 | 8821.9 |
| % of per-tooth vol | 5.4% | 5.2% | 4.8% | 4.6% | 4.2% | 3.7% | 2.2% | 2.1% | **999.6%** | 999.2% | 998.5% | 999.5% |

Smoothly *decreasing* residual from β=0 through 51° (the opposite of "more
curvature = more mismatch," same qualitative direction Spike A's own §3
found at lower β), then a sharp jump to a ~999%-of-one-tooth plateau
starting exactly at 52° - not a growing trend, a step. This precise
threshold (51°→52° for this specific geometry) is new; Spike A's own doc
only bounded it as "somewhere between 30° and 35°" for a differently-built
(not profile-shift-corrected) baseline - see the honest discrepancy noted
in §5 below.

**Direct proof it's a phase artifact, not a fold**: swept
`_rotated_about_axis`'s own phase angle (member 2's `-π/2 + π/tooth_count_2`
convention, `phase_delta` added on top) at the broken β=55° case:

| phase Δ | -10° | -8° | -6° | -5° | -4° | -3° | -2° | -1° | 0° (default) | +1° | +2° | +3° | +8° | +10° | +15° |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| overlap (mm³) | 8864 | 106.8 | 34.2 | 37.1 | 25.6 | 22.2 | 9063 | 9069 | **9073.3** | 9074 | 14.3 | 11.6 | 72.0 | 108.5 | 9057 |

A ±2-3° phase correction (an order of magnitude smaller than the ~52°
spiral angle itself) drops overlap from 9073 mm³ back to the same 10-40 mm³
range the low-β residual already lives in - **the flank geometry at β=55°
is not fundamentally different from β=35°'s; the fixed `±π/2` convention
(calibrated for a straight tooth whose centerline never moves, per this
doc's own §"What a revised approach needs" item 4) has simply drifted into
picking the wrong relative alignment between the two members' teeth.** The
same test at the *earlier*, un-profile-shift-corrected 10T/10T sweep's own
break point (β=15°, `phase Δ=0` gives 9094 mm³) confirms the identical
mechanism at a much lower β: `Δ=-1°` gives 67.0 mm³, `Δ=+1°` gives
80.5 mm³ - both back in the normal residual range. **Both breakdowns -
Spike A's own reported one and this session's more-precisely-located
one - are the same phenomenon**, just triggered at a different β because
how close the fixed default phase sits to a "bad" alignment is itself
geometry/baseline-dependent (see §3).

### 2. Tooth-count-ratio breakdown: refuted as "the same mechanism" - a real, but pre-existing and non-spiral, defect

Rebuilt Spike A's own 8T/16T and 6T/24T cases with the corrected
construction, real auto-resolved profile shifts, and a real β sweep
(0/5/10/15/20°, opposite hand) - the direct test the task asked for
("does the fold detector fire on these cases even at moderate β,
independent of the high-β threshold").

**8T/16T does not reproduce at all.** `overlap = 0.0 mm³` at every β from
0° through 20°, no fold on either member's flank. This flatly contradicts
Spike A's own reported 25270.5 mm³ at β=20° for this ratio - see §5's
honest-discrepancy note.

**6T/24T does reproduce a real breakdown, but it is not spiral-related.**
`resolve_member_profile_shifts` gives this pair `ps1=+0.9215`,
`ps2=-0.9215` (both members needing a large, nearly-a-full-module
correction - the steep γ≈14°/76° split leaves little margin for the
existing radial-balancing system to work with). Overlap: 147.9 mm³ (43.9%
of a tooth) already at **β=0°** - i.e. before any spiral is applied at
all - then 70117 mm³ (5543%) at β=5°, 70118 mm³ (2493%) at β=10°, settling
back to 180.1/151.3 mm³ (6.5%/5.5%) at β=15°/20°. No fold detected on
either member's flank at any of these β. Directly checked whether this is
even *about* the spiral construction: built member 1 (the 6-tooth,
`profile_shift=+0.9215` member) via the **real, unmodified**
`app.document.bevel._assemble_gear_solid` - the exact shipped straight-bevel
code, zero spike code, `β` not a parameter at all - and got the same class
of failure: analytic volume 18348 mm³ vs. an independent mesh-based volume
of 4638 mm³ (a ~4x disagreement), which that module's own existing
`_assembly_sanity_warnings` correctly flags ("analytic volume disagrees
with an independent mesh-based volume check by more than 2%"). Rebuilding
the same member with `profile_shift=0` instead gives analytic/mesh
agreement to <0.5% - **the defect tracks the large profile-shift value,
not the spiral offset**: `resolve_member_profile_shifts`' existing
"receiver gets the exact complementary +X" balancing logic
(`13-spiral-bevel-pair.md`'s own lesson 1, `bevel_pair.
maximum_receiver_profile_shift_for_mesh_clearance`) caps the receiver's
shift against *re-introducing interference*, but nothing caps it against
producing a **geometrically malformed solid** once the correction
approaches a full module - a real, latent bug in the existing, shipped
`BevelPairFeature`/straight-bevel pipeline for extreme tooth-count-ratio
pairs, surfaced by this session's own extreme-ratio testing, not caused or
fixed by anything spiral-specific.

This directly **refutes** this doc's own §3 hypothesis ("consistent with,
and likely the same underlying mechanism as, the β=35° breakdown ...
a steep pitch cone combined with the curved multi-section loft"): it is
neither the same mechanism (§1's is a phase-positioning artifact; this one
reproduces at β=0 with zero spike code involved) nor caused by the curved
loft (it reproduces identically with the real 2-section `ruled=True`
straight-bevel construction). Fixing it is a straight-bevel/`13-spiral-
bevel-pair.md` pairing-system concern (capping `resolve_member_profile_
shifts`' own receiver correction against solid-malformation, not just
against re-introduced interference), out of this workstream's own scope.

### 3. The real safe boundary: no clean formula found - and that itself is the actionable finding

Derived a closed-form candidate threshold from the construction's own
`curve(R) = [tan(β)/sin(γ)] · ln(R/R_mean)` formula directly: the
per-tooth azimuthal excursion from outer to inner cone distance is `span =
[tan(β)/sin(γ)] · ln(cone_distance/inner_cone_distance)`; hypothesized the
break happens once `span` reaches a full angular tooth pitch (`2π /
tooth_count`). Algebraically, `(2π/N)·sin(γ) = π·module/cone_distance`
(since `cone_distance·sin(γ) = pitch_radius = module·N/2`) - i.e. the
predicted threshold **does not depend on tooth count at all**, only on
`module`/`cone_distance`/the face-width-driven `ln` ratio. For the 10T/10T
baseline this predicts `β_max ≈ 53.2°`, close to the measured 51°→52°
break - a good fit.

**It does not generalize.** Built a second case (20T/20T, module 4,
face_width 16 - face_width/cone_distance ratio held identical to the
10T/10T baseline deliberately, so the formula predicts the *same* `β_max ≈
33.75°`). Measured: smooth, small, still-*decreasing* overlap through
56° (0.10-1.32% of a tooth, no jump at all near the predicted 33.75°), then
a genuinely irregular pattern from 65-75° - clean at 65° (0.22%), a sharp
jump at 68-69° (~1910%), clean again at 70-71° (1.2%/0.78%), broken again
at 72° and 75° (3799%/2609%). The first real break is roughly **double**
the naive formula's prediction, and the pattern past it is not a simple
"stays broken past threshold" step the way 10T/10T's own 52-65° range
was (continuously broken in every β tested there) - it is geometry-
dependent whether the fixed phase convention finds occasional "lucky"
alignments on the other side of an early notch. The naive span-vs-pitch
hypothesis is a real, named dead end for predicting *when*, even though
it correctly identifies *what kind of thing* is happening (an azimuthal
alignment/aliasing effect between the two members' fixed-phase-positioned
teeth) - matching this project's own established convention
(`10-bevel-gear.md`'s own §1 wrong-signed-curve story, §7's honest
discrepancy) of naming a plausible-but-wrong hypothesis explicitly so
nobody re-derives it and trusts it further than this session did.

**The actionable conclusion**: don't look for a safe-β rule of thumb for
the *existing fixed-phase* construction - none was found, and the search
above suggests one may not exist in a form simple enough to be worth
documenting (the failure is a positioning coincidence, not a monotonic
geometric limit). The real fix is item 4 below: re-derive/search the
meshing phase per build rather than trust a single calibrated-at-β=0
constant, and gate real construction on a direct check (a small local
`BRepAlgoAPI_Common`/overlap probe at build time, alongside the existing
per-flank fold check) rather than a static β or tooth-ratio ceiling in
documentation or client-side validation.

### 4. Secondary: optimal phase vs. β - stable at low/moderate β, not smoothly defined once the notch regime starts

Swept `phase_delta` at fine (0.1°) resolution to locate the true local
optimum, same profile-shift-corrected 10T/10T baseline, at β where the
default phase is still in the well-behaved region:

| β | 10° | 20° | 30° | 40° | 45° |
|---|---|---|---|---|---|
| optimal phase Δ | -3.1° | -3.2° | -3.5° | -2.9° | -3.6° |
| min overlap (mm³) | 36.0 | 32.3 | 10.6 | 1.5 | 12.6 |

Stable (-2.9° to -3.6°, no trend toward either the default 0° or toward
the sign-flipped post-notch value) across the *entire* well-behaved range,
right up to 45° - only 7° short of this baseline's own 52° notch. The
optimum doesn't drift toward the notch as β approaches it; the whole
low/moderate regime shares essentially one correction. A real, non-zero,
near-constant correction in the low/moderate regime (this
session's own baseline differs from Spike A's own β=20° finding of a
"~-0.2 to -1°" optimum - see §5 below for why the two aren't directly
comparable - but both agree the optimum is small, negative, and non-zero
here). **Past the notch regime (§1/§3), "the optimal phase as a function
of β" stops being a well-posed question in the smooth-function sense**:
§1's own β=55° sweep found the optimum jumps to a *positive* ~+2-3°
(sign-flipped from the low-β ~-3°), separated from the default by a narrow
"bad" band on one side and a wider "good" band on the other, not a
continuous drift from the low-β value. A revised phase-alignment
convention (item 4, `12-spiral-bevel-gear.md`'s own "What a revised
approach needs") should therefore be built as a small local search/probe
at construction time for any β past the well-behaved low/moderate range,
not a closed-form `phase(β)` correction - the same conclusion §3 reaches
for the β-threshold question, for the same underlying reason.

### 5. Honest discrepancy with Spike A's own reported numbers

Flagged plainly, per this project's own established convention
(`10-bevel-gear.md`'s own §7): this session's numbers do **not** match
Spike A's own reported ones, even qualitatively in one place. Spike A's
own β-sweep table (5°→30°: 84.3→71.9 mm³, then 4790.4 mm³ at 35°) is
closer in *magnitude* to this session's own **zero-profile-shift**
reproduction (β=0-10°: 74-76 mm³) than to the profile-shift-corrected one
used for §1-§4 above (β=0-30°: 44-51 mm³) - suggesting Spike A's own
harness did not apply `resolve_member_profile_shifts`, consistent with
`13-spiral-bevel-pair.md`'s own §4 treating the radial dimension as
already-solved and out of scope for that measurement. But reproducing
that same zero-profile-shift setup here finds the break at **β=10°→15°**
(74.8 → 9094.4 mm³), not 30°→35° - a full session's own attempt at faithful
reproduction (same real internals, same phase convention read directly
from `bevel_pair.py`'s own source rather than from memory, same basis/
positioning) still lands roughly **20° earlier** than Spike A's own
number. The zero-profile-shift break is the *same phase-artifact
mechanism* (directly confirmed via the same phase-recovery test, §1) just
triggered earlier because the un-corrected radial baseline leaves less
margin before a modest spiral shift crosses into a bad alignment - so the
mechanism finding is not in doubt, but the precise number in Spike A's own
doc could not be reconciled this session, the same honest-disagreement
situation `10-bevel-gear.md`'s own §7 already established a precedent for
handling: name it, don't silently override it or silently agree with it.
Given this session's own harness is built directly against this project's
committed, real internals (not a re-description of them) and both the
mechanism (phase artifact, confirmed by direct recovery) and the general
shape (break exists, is sharp, moves earlier with a worse baseline) are
independently well-supported, this session's own numbers - not Spike A's -
should be treated as the more load-bearing reference going forward, with
Spike A's own absolute figures kept in its doc entry as historical record
rather than corrected in place.

### 6. Go/no-go, updated

Both of Spike A's own uncharacterized breakdowns are now root-caused:

- **High-β breakdown (§1)**: a meshing-phase-alignment artifact, not a
  fold or a construction defect. Directly fixable (proven by direct
  recovery, not just hypothesized) via a corrected/searched phase offset -
  this is now `12-spiral-bevel-gear.md`'s own "What a revised approach
  needs" item 4, promoted from "worth re-deriving" to "the actual fix for
  a real, otherwise-catastrophic failure," not a polish item.
- **Tooth-count-ratio breakdown (§2)**: refuted as sharing item 1's
  mechanism. A real, pre-existing, non-spiral defect in the shipped
  straight-bevel profile-shift/solid-assembly pipeline for extreme ratios
  - a `13-spiral-bevel-pair.md`/straight-bevel-pairing concern, not a
  spiral-construction one, and not blocking on Spike B/fold-risk work at
  all.
- **No genuine flank self-fold was found anywhere in this session's own
  testing** (25° through 75° spiral angle; 10T/10T, 20T/20T, 8T/16T, and
  6T/24T tooth-count ratios; opposite-hand throughout, matching Spike A's
  own primary sweep - same-hand wasn't re-tested here, already covered by
  Spike A's own §3) - the "Spike B (fold-risk/surface-quality)" framing
  in this doc's own "Complexity/risk" section and `13-spiral-bevel-pair.md`'s
  own §5 go/no-go turns out to have been aimed at the wrong mechanism;
  `_flank_fold_warning` is confirmed clean across every case this session
  tried, not merely "not yet checked."

**Still NO-GO on shipping the current fixed-phase construction as-is** -
the β≈52° (this geometry) catastrophic notch is real and would produce a
badly broken part with no warning today - but the path to GO is now
concrete and scoped, not open-ended: (1) replace the fixed `±π/2`/`-π/2 +
π/N` phase convention with a small local search/probe at build time
(§3-§4 above); (2) build the tangential margin proxy `13-spiral-bevel-
pair.md`'s own §3 already calls for, now informed by real phase-corrected
residual numbers (§1's 4-5% baseline, not Spike A's own possibly-
uncorrected 8-9%); (3) separately, flag the profile-shift/solid-
malformation defect (§2) to whoever next touches `resolve_member_profile_
shifts` - real, but independent of this workstream's own go/no-go.

## Spike findings (2026-08-21) — Spike C: per-build meshing-phase search

Real investigate/prototype pass answering Spike B's own item (1) above -
designing and validating the "small local search/probe at build time"
Spike B named as the concrete fix for the high-β phase-alignment notch,
not yet designed or validated there. Explicitly investigation/validation,
not a `BevelGearFeature`/`BevelPairFeature` implementation pass, per this
session's own task scope. Same real conda-forge `pythonocc-core` 7.9.3 env
(micromamba from GitHub Releases, `backend/environment.yml`), same
scratch-only-harness convention (nothing below is committed). Spike B's
own uncommitted `assemble_spiral_gear_solid` no longer exists (scratch, by
that spike's own convention), so this session re-derived an equivalent
N-section spiral member-solid assembler from this doc's own §2 formula and
`app.document.bevel`'s real, unchanged internals (`_bspline_wire`,
`_cone_arc_wire`, `_spherical_cap_face`, `_flank_fold_warning`,
`_flatten_end_caps`, `_assembly_sanity_warnings`, the `ThruSections`/
sewing/`ShapeFix_Shell`/`MakeSolid`/`OrientClosedSolid` sequence) -
verified byte-for-byte against Spike A's own reported per-radius
azimuth table (§2, β=20°, 10T/10T: right/left azimuth and centerline at
all 5 sections reproduced to 3 decimal places) before trusting it further.

**A real construction mistake caught early, worth naming so nobody
repeats it**: an early version of this session's own re-derived assembler
skipped `bevel._flatten_end_caps` (an optional, already-non-fatal step
per that function's own docstring) to save build cost. This was wrong,
not just a missed optimization - an un-flattened spherical end-cap is a
full dome/dish that isn't confined to its own member's own tooth region
the way a flattened one is, so two members' un-flattened caps can overlap
each other by thousands of mm³ *independent of meshing phase*, completely
swamping the real tangential signal this spike exists to measure
(confirmed on-device: the same 10T/10T/module-4/β=0 configuration gave an
~8267 mm³ near-phase-independent background overlap without flattening,
vs. 43.8 mm³ - reasonably close to this doc's own Spike B §1 reference of
50.6 mm³ for the same configuration - with it). Fixed by calling
`_flatten_end_caps` unchanged (purely colatitude/geometry-based, no
dependency on straight vs. curved tooth trace, so it needed no
modification at all) with the same fallback-to-unflattened-plus-warning
behaviour `_assemble_gear_solid` already uses.

### 1. Search algorithm: coarse grid pre-scan + local golden-section refine, not a single global search

A plain single golden-section (or ternary) search over a wide window,
assuming the whole window is unimodal, is **not sound** here - this doc's
own Spike B §4 already found the full phase-vs-overlap landscape is not
globally unimodal past the notch (a narrow bad spike sitting inside a
wide good band, not a single valley), and this session's own wide-window
sweeps (§3 below) directly reproduce that shape. A search that assumes
global unimodality can converge to - or bracket around - the wrong
feature entirely once one of these spikes is inside its starting window.
What *is* true, and load-bearing for the fix: Spike B's own §4 low-β
stable-optimum finding (-2.9° to -3.6°, smoothly present across β=10-45°)
shows the landscape *is* smooth/unimodal **within** one such band. The
algorithm this session designed and validated exploits exactly that
split:

1. **Coarse grid scan** across a window centred on the existing fixed
   convention (`_rotated_about_axis`'s own `±π/2`/`-π/2 + π/N` default),
   evaluating real `BRepAlgoAPI_Common` overlap at each grid point. This
   is the step that makes the search robust to the non-unimodal case - it
   can't be fooled by a single bad spike the way a naive wide-window
   golden-section could, since it samples broadly rather than trusting
   derivative-free bracketing logic across the whole window.
2. **Local golden-section refine** within `±`one grid step of the best
   grid point found. Sound specifically because the *interval* being
   refined over is narrow enough to sit inside one smooth band, not
   because the *whole search* is unimodal.

This two-stage shape - not a single technique - is the answer to this
item's own "state why, don't just pick one arbitrarily" instruction:
grid alone would need a very fine resolution to match golden-section's
own precision (wasteful); golden-section alone is provably unsound given
Spike B's own non-unimodality finding; the combination gets both
properties cheaply, because (per §4 below) each trial is a rotate + a
boolean against two already-built solids, not a geometry rebuild - the
coarse scan's own cost is not the bottleneck the precision-vs-cost
tradeoff would otherwise create.

**A real robustness bug this session's own first implementation had, caught
and fixed before trusting any result below**: `BRepAlgoAPI_Common`'s own
`GProp_GProps.Mass()` can come back **negative** - not a near-zero
numerical-noise negative, but large-magnitude negative (confirmed
on-device: -9.5 to -149.8 mm³ across several cases) - and this is not a
valid "even better than zero overlap" reading, it's numerical garbage
from a geometrically marginal input solid (every negative value this
session measured traced directly to a member whose own `_flatten_end_caps`
had already failed, i.e. `_assemble_gear_solid`/this session's own spiral
assembler had already raised its own non-blocking warning for that
solid). A naive minimizer that let a negative number "win" would
systematically walk the search toward whichever trial happens to be
*most* geometrically broken, exactly backwards - this fooled this
session's own first search run into reporting a "phase correction" that
was actually pure garbage for two of the four cases nearest the
fold-risk-adjacent β range. Fixed by treating both `None` (boolean itself
fails) and negative results identically as "no usable signal, worse than
any real reading" - never a candidate to select as best. **Whoever
implements this for real must carry this guard forward explicitly** - it
is exactly the kind of `IsDone()`-but-wrong gotcha this project's own
history (`10-bevel-gear.md`'s own `BRepCheck_Analyzer` findings) already
warns about, just for `GProp_GProps.Mass()` instead.

### 2. Validation: reliably recovers a good alignment across both tooth-count ratios, both hands, and well past this session's own notch

Swept β, tooth-count ratio, and hand, on the same real, phase-corrected
profile-shift baseline `resolve_member_profile_shifts` produces (matching
Spike B's own §1 methodology, not Spike A's own possibly-uncorrected
one), n_sections=3 (Spike A's own §3 convergence finding: matches
n_sections=15 to full float precision), points_per_flank=12 (the
production default in `app.document.bevel._POINTS_PER_FLANK` -
see the flattening finding above for why this matters, not just cost).

| pair | β (deg) | hand | default-phase overlap (mm³) | search result (mm³, at Δ deg) | evals | warnings |
|---|---|---|---|---|---|---|
| 10T/10T | 10 | opposite | 43.7 | 43.68 (Δ=-2.65) | 51 | none |
| 10T/10T | 20 | opposite | 43.2 | 43.21 (Δ=-1.15) | 51 | none |
| 10T/10T | 30 | opposite | 42.3 | 42.30 (Δ=-1.80) | 51 | none |
| 10T/10T | 45 | opposite | 39.3 | 39.29 (Δ=-0.90) | 51 | none |
| 10T/10T | 65 | opposite | 32.2 | 32.00 (Δ=+2.70) | 51 | none |
| 10T/10T | 70 | opposite | 20.6 | **0.82 (Δ=-4.57)** | 32 | end-cap flattening failed (both members) |
| 10T/10T | 20 | same | 57.9 | 57.44 (Δ=-1.04) | 51 | none |
| 10T/10T | 65 | same | 90.3 | 85.44 (Δ=-9.11) | 51 | none |
| 20T/20T | 20 | opposite | 18.5 | 18.54 (Δ=-0.33) | 46 | none |
| 20T/20T | 40 | opposite | 10.7 | 10.47 (Δ=-0.57) | 46 | none |
| 20T/20T | 60 | opposite | 12.4 | 9.80 (Δ=-0.58) | 46 | none |
| 20T/20T | 68 | opposite | 5.6 | 5.57 (Δ=0.00) | 31 | end-cap flattening failed (both members) |
| 20T/20T | 70 | opposite | 5.8 | 5.77 (Δ=-0.17) | 31 | end-cap flattening failed (both members) |
| 20T/20T | 72 | opposite | 5.6 | 3.09 (Δ=-0.90) | 31 | end-cap flattening failed (both members) |

In the smooth low/moderate-β regime the search finds essentially the same
result the default already gave (a few tenths to a couple mm³ better) -
consistent with Spike B's own §4 finding that the default convention is
already close to the true optimum there. At 10T/10T β=70 - the one case
in this session's own sweep that lands in a genuinely bad default
alignment (see §3's honest discrepancy below for why this is a different
β from Spike B's own reported 52° notch) - the search recovers a **96%
reduction** (20.6 → 0.82 mm³), the direct, on-device confirmation this
item's own task asked for: the search recovers a good alignment, not just
in the smooth regime it was easy to validate in.

**Same-hand still shows a real, uncorrectable-by-phase floor** (10T/10T,
β=20°: 57.9 → 57.44; β=65°: 90.3 → 85.44) - matching Spike A's own §3
finding that same-hand pairing is worse in *degree*, not something a
phase search can fix, reinforcing (not revising) `13-spiral-bevel-pair.md`'s
own conclusion that hand-of-spiral needs its own separate check, not
coverage by whatever auto-resolution phase search provides.

### 3. Search window: half the angular tooth pitch, not a fixed narrow band - and an honest discrepancy on where this session's own notch sits

This item's own task asked whether Spike B's own low-β "~1° band"
optimum window stays sufficient once past a notch, or whether the "wide
good band" Spike B found there needs a wider window. Direct on-device
answer: **wider, and it should scale with the tooth's own angular pitch,
not stay a fixed degree count.** A full wide-window scan at 10T/10T,
β=70° (the notch-adjacent case in this session's own harness) found the
true optimum at Δ≈-4.6° but a genuinely catastrophic wall (8000-18000 mm³,
essentially a full tooth's own volume) at Δ≈-12° to -16° - **within** a
±18° (half the 36° angular tooth pitch for N=10) window, comfortably
outside a ±1-3° one. The search's own coarse-grid stage correctly found
the good region and never walked toward that wall (the wall's own grid
points were sampled, scored badly, and discarded, exactly the coarse
scan's own job) - direct, positive confirmation the two-stage algorithm
is robust to a bad spike sitting inside its own search window, not merely
untested against one. `half_pitch_degrees = 180 / tooth_count` is this
session's own recommended window size: principled (guarantees covering
one full period of whatever aliasing structure produces these walls,
rather than a guessed absolute degree count) and confirmed sufficient in
every case this session tested, including the two ratios (10T/10T,
20T/20T) this doc's own Spike A/B already found don't share a simple
formula for *where* the notch sits.

**Honest discrepancy, named per this project's own established
convention** (`10-bevel-gear.md`'s own §7, Spike B's own §5): this
session's own re-derived harness, despite matching Spike A's own §2
azimuth table bit-for-bit, does **not** reproduce Spike B's own reported
β≈52° notch for 10T/10T - this session's own default-phase overlap stays
smooth and well-behaved (default ≈ search result, both in the
20-44 mm³ range) all the way through β=65°, with the first genuinely bad
default alignment appearing at β=70° instead, and 20T/20T shows no
comparably sharp default-phase failure anywhere in the 20-72° range
tested (only a modest rise from ~10 to ~18 mm³, nothing like Spike B's
own reported ~1000%-of-a-tooth jump at 68-69°). Both harnesses agree on
every *qualitative* finding that matters (a real notch/wall exists, it is
a meshing-phase-alignment artifact fixable by direct recovery, it is not
a flank fold, no clean formula predicts exactly where it sits) - only the
specific β this session's own construction happens to land a bad default
alignment at differs, most likely from implementation-detail sensitivity
this doc's own Spike B §3 already flagged as a real property of this
construction (an azimuthal-aliasing coincidence, not a smooth geometric
limit) - candidates include `n_sections` (3 here vs. Spike B's own likely
5) and `points_per_flank` (12 here, matching production, vs. Spike B's
own likely 8), either of which plausibly shifts exactly where a
discrete tooth-vs-tooth alignment coincidence falls without changing the
underlying mechanism at all. Not reconciled this session, flagged rather
than silently resolved either way, per this project's own precedent.
**Practical upshot, independent of the exact β**: a search window sized
off the angular tooth pitch is the robust choice precisely *because* the
notch location is this sensitive - a fixed absolute window tuned to one
harness's own measured notch would not have been trustworthy for another.

### 4. Cost: cheap in the smooth regime, a real and significant unbudgeted cost risk near/past the notch

Each phase trial is a rigid rotation (`_rotated_about_axis`, already the
production technique) plus one `BRepAlgoAPI_Common` against two solids
built once per case, never rebuilt per trial - the search's own
incremental cost is real but small next to a full N-section build:

- **Smooth regime** (every case in §2's own table without a warning):
  each build (both members' full N-tooth spiral solids) took 3-22s
  (10T/10T: 3-5s; 20T/20T: 6-10s - the larger, more expensive case, as
  expected). Each phase-trial eval took roughly 1-3s. This session's own
  diagnostic-grade 46-51-point exhaustive grid (used throughout §2's table
  to characterize the *whole* landscape, not what a production
  implementation should run) took 50-160s; a production-appropriate
  leaner grid (this session also validated a coarser ~30-point grid for
  the rerun cases below) would cost meaningfully less - call it 20-40
  evals, perhaps 30-90s total for a 10-20 tooth pair, on top of the
  builds. Genuinely cheap relative to `11-bevel-pair.md`'s own documented
  multi-minute-scale full-pair build cost.
- **Near/past the notch** (every warned row in §2's own table - exactly
  where `_flatten_end_caps` starts failing and the search is *most*
  needed): eval cost rose sharply, up to **~16s per trial** (20T/20T,
  β=68-72°: 365-505s for 31 evals), because `BRepAlgoAPI_Common` on a
  marginal/unflattened-dome input solid is itself a much more expensive,
  poorly-conditioned boolean, independent of the search algorithm around
  it. Combined with builds also growing more expensive in this regime
  (20T/20T, β=72°: 22s to build), a single pair's phase search alone can
  cost several **minutes**, not tens of seconds.

**This is a real, unbudgeted risk for the eventual implementation, not
something to silently absorb**: the search's own worst-case cost is
concentrated exactly in the parameter region (high β, tooth-count ratios
approaching the crown-like threshold) where it is doing the most load-
bearing work, on top of `11-bevel-pair.md`'s own already-documented
concern that a full bevel pair build is already this codebase's single
most expensive construction. A real implementation should budget for
this explicitly (e.g. a generous request timeout specifically for the
phase-search step, matching this doc's own precedent of `10-bevel-gear.md`'s
raised 180s client timeout for bevel builds generally) rather than assume
the search stays as cheap as its own smooth-regime numbers above suggest.
Whoever implements this should also gate the search itself on the
underlying per-member solid's own validity (`_assembly_sanity_warnings`-
equivalent) *before* trusting a search result at all, not just guard
against the negative-value symptom (§1) - a marginal solid's own boolean
readings are not trustworthy regardless of sign.

### 5. Go/no-go

**GO on a per-build coarse-grid-plus-golden-section-refine phase search**,
window sized to half the angular tooth pitch of the member being
searched over (`180 / tooth_count`), gated by a negative/`None`-overlap
validity guard (§1) and ideally also by the underlying solid's own
`_assembly_sanity_warnings`-equivalent validity (§4). Validated across
both tooth-count ratios this doc's own Spike A/B already found don't
share a simple notch-location formula, both hands, and a β range spanning
smooth through this session's own notch-adjacent regime - reliably
recovers a good alignment everywhere tested, including a 96% overlap
reduction at the one genuinely bad-default case found. **Real, flagged
cost risk**: cheap in the well-behaved regime, materially more expensive
- potentially minutes, not seconds - near/past the notch, exactly where
it matters most; budget for this explicitly in the real implementation,
per §4. This item's own remaining open item for a real implementation:
decide the production grid resolution/window precisely (this session's
own diagnostic grids were intentionally over-sampled for characterization,
not tuned for minimum cost) - a short follow-up tuning pass, not a new
spike.
