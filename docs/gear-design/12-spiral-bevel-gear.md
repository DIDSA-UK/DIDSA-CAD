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

## Bearing on BevelPairFeature

There is now a real, substantial mesh-margin/interference system, mostly
living in `bevel_math.py` (header comment: "pure-math proxy for a real
`BRepAlgoAPI_Common` overlap check"):

- `bevel_pair_mesh_margin_degrees(intruder_face_cone_angle,
  receiver_base_colatitude, shaft_angle_degrees)` = `shaft_angle_degrees -
  (degrees(intruder_face_cone_angle) + degrees(receiver_base_colatitude))`
  — uses `tredgold_base_colatitude`, not `root_cone_angle` (an on-device
  finding: doubling `dedendum_coefficient` changed measured overlap volume
  by only 0.002%, confirming `root_cone_angle` was the wrong quantity).
- `worst_bevel_pair_mesh_margin_degrees`, `minimum_intruder_profile_
  shift_for_mesh_clearance`, `maximum_receiver_profile_shift_for_mesh_
  clearance`, `bevel_pair_mesh_interference_warning` — bisection-based,
  calibrated against real on-device `BRepAlgoAPI_Common` measurements
  (`MESH_MARGIN_SAFETY_BUFFER_DEGREES = 0.5`).
- `bevel_pair.resolve_member_profile_shifts` — the real auto-balancing
  implementation: `None` = Auto, explicit float = Manual ("explicit always
  wins"), a single-sided fix on the intruder if the receiver is pinned, a
  backlash-neutral complementary fix on both if both are Auto (exploiting
  `tooth_thickness_at_pitch`'s shared `module`/`circular_pitch` to land the
  receiver's new tooth thickness exactly on the intruder's new gap), capped
  to avoid over-correcting into a reverse-direction interference (a real
  flip was found and documented at this app's default 14.5°
  pressure-angle pair).

Its bearing on spiral bevel: `bevel_pair_mesh_margin_degrees` reasons
purely about colatitude/radial extents (`face_cone_angle`,
`tredgold_base_colatitude`), and a pure `_rotate_about_z` azimuthal offset
never changes colatitude or `z`. So this radial-margin math *plausibly
survives unchanged* for a spiral-bevel pair — stated as plausible, flagged
for spike confirmation, not asserted as certain (the same "plausible by
analogy, not yet measured" caveat as the layered-offset construction
itself).

What does **not** carry over, or is genuinely new:

- **Hand-of-spiral compatibility** between mating members — a purely
  tangential/azimuthal meshing concern with no counterpart in the existing
  radial-only margin system. Real new work, not an extension of anything
  present today.
- The existing system checks radial/colatitude overlap; it was never
  designed to catch a *tangential* (along-the-tooth) meshing failure of
  the kind the Tredgold rewrite fixed. Spike A above is exactly the check
  needed to close that gap for the layered-offset construction, and
  nothing in `bevel_pair.py` does it today.

What carries over unchanged: `_tilted_basis` (apex-aligned dual-axis
positioning) and `pitch_cone_half_angles`-based auto-derivation of
`gamma_1`/`gamma_2` — both pure pitch-cone geometry, independent of
lengthwise tooth shape, and both still valid for intersecting-axis spiral
bevel (not hypoid).

One documentation-accuracy note, unrelated to spiral bevel but worth
flagging while in this code: `bevel_pair.py` still carries a stale
docstring sentence — "No interference checking at all... per
`11-bevel-pair.md`" — left over from before the mesh-margin system existed.
It refers only to `GearChainFeature`-style non-adjacent-stage interference,
not the pairwise tooth-tip interference the code plainly checks today.
Flagged as an inconsistency, not a functional gap; not proposed to fix
here.

## Proposed v1 scope

**In scope**: spiral bevel gear only (pair deferred to its own later
workstream, mirroring how `11-bevel-pair.md` depended on `10-bevel-gear.
md`'s spike landing first); the layered-constant-spiral-angle approximation
as the *only* lengthwise-curve family offered — no user choice between
circular-arc/involute/epicycloid systems, the spiral-bevel equivalent of
straight bevel's own "standard equal-addendum, no Gleason long-and-short-
addendum system" downgrade; user-configurable spiral angle and hand of
spiral; arbitrary shaft angle (inherited free from `pitch_cone_half_
angles`, no reason to restrict); Zerol bevel falls out at `β=0`, no
separate scope line; inherits the existing Tredgold crown-gear-angle cap
(`TREDGOLD_MAX_PITCH_CONE_ANGLE_DEGREES = 89.5`) and disc-like thin-hub
warning unchanged.

**Explicitly deferred**: spiral bevel pairing as its own later workstream
(depends on this one landing, and specifically on Spike A's
meshing-correctness result); true Gleason-conjugate envelope surfaces; root
fillet (already unsupported for straight bevel, not a new gap); hypoid
bevel gears (offset, non-intersecting axes — a separate, even-further-later
phase, not bundled with spiral/Zerol); hand-of-spiral pair-compatibility
validation (flagged above for the pair workstream); DXF flat-pattern/
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
hand-of-spiral compatibility surfacing) — the pair workstream itself is
deferred above, so its UI is future work for that later doc.

## Open questions

- Whether the layered-offset-on-Tredgold construction actually preserves
  conjugate action between two independently-built mating gears — Spike
  A's whole purpose, and the single biggest unknown in this doc.
- Whether Zerol bevel's `β=0` reduction is the complete story, or only
  correct at the mean point.
- Whether `N`-section `ThruSections` or a genuine sweep wins on flank
  surface quality, and whether `CheckCompatibility(False)` resolves the
  large-twist correspondence risk here the way it did for helical gears.
- Hand-of-spiral pair-compatibility validation — real new work, not
  designed here, deferred to the pair workstream.
- Whether `bevel_pair_mesh_margin_degrees`'s radial-only reasoning really
  does carry over unchanged for spiral bevel, or whether a tangential
  companion check is needed even for the *pair* workstream's own v1.
- `geometry.base_cone_angle`'s now-vestigial status is worth a cleanup
  note for whoever next touches `bevel_math.py`, independent of spiral
  bevel.
- `10-bevel-gear.md`/`11-bevel-pair.md`'s staleness relative to current
  code (Tredgold, mesh-margin system, Crown Gear, disc-like warning, none
  mentioned in either doc) is a separate follow-up candidate worth raising
  with whoever owns this doc set — not addressed in this session.
