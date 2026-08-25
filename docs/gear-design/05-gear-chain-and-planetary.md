# Workstream 5 — Multi-gear systems: `GearChainFeature` and `PlanetaryGearFeature`

Read `00-conventions.md` first. Depends on Workstream 2 (internal +
external `GearFeature`), Workstream 3 (rack), and Workstream 1
(`gear_math`). Two new Feature types (six-part checklist,
`00-conventions.md`), each **one Feature, live and re-derivable** —
editing one gear's tooth count repositions/resizes the rest automatically
on the next recompute, via the same "one Feature, many `#N`-suffixed
Bodies, resolved fresh every time" pattern `PatternFeature`/
`MirrorFeature` already use. Not a one-shot orchestration that creates
independent Features once.

This is the largest, highest-risk workstream in the whole project — plan
for **two separate spikes** before committing to the full build (see
`README.md`'s delivery order): one for `GearChainFeature`'s bent-path +
interference-check approach, one for the compound-station geometry below.

---

## `GearChainFeature`

An ordered list of N≥2 meshing stages (each stage: external/internal/
rack, tooth count or rack length, face width, hand). N=2 is an ordinary
pair (including rack-and-pinion — a rack stage next to a gear stage);
N>2 is a longer gear train. Resolves in one pass into N positioned
Bodies, same `#N`-suffix convention `ExtrudeFeature` already uses for
multi-solid output. A later Feature can still target one specific stage's
Body individually (see conventions).

### Module/pressure-angle: owned by a `GearGroup`, not inlined per-chain

A `GearGroup` is a small named record: `id`, `module`, `pressure_angle`,
`display_color`. Every stage references a `group_id` rather than carrying
module/pressure-angle directly. Two stages can only mesh if they share a
group — this is what makes a mismatched-module pair structurally
impossible to construct. v1 UI creates exactly **one implicit group per
chain** — a normal chain reads to the user as "the chain has one module,"
no groups concept surfaced — but the schema is shaped for multiple groups
(and the color-coded preview that falls out of it, see
`08-entry-screen-and-preview.md`) without a later breaking migration.

### Internal (ring) stages: last position only

A linear chain naturally "continues past" an external gear (something
else meshes with its far side), but nothing meaningfully continues past a
ring without turning into a branching (planetary) topology — that's
`PlanetaryGearFeature`'s job. `GearChainFeature` **rejects** an `internal`
stage anywhere but the final position — a deliberate restriction, not a
gap.

### Path shape: bent paths, not straight-line-only

Each stage after the first carries its own turn-angle field:

- One always-visible numeric field per stage after the first, **default
  0° = continue straight** (no reveal/hide toggle needed). Plus one
  chain-level "start direction" field for stage 1→2's own heading.
- Angle is **relative to the previous segment's own direction**
  (turtle-graphics style, not absolute within the plane) — the only
  choice that keeps every stage's meaning stable when a stage is
  inserted/removed elsewhere in the chain.
- Sign convention: **positive = counter-clockwise about the anchor
  plane's normal**, matching `RevolveFeature.angle`/circular
  `PatternFeature`'s existing right-hand-rule convention (both already
  rotate via OCCT's own `gp_Ax1`) — inherited, not invented.
- No bespoke angle-range validation — a sharp reversal is exactly what
  interference checking (below) exists to catch.
- Text-entry only for v1, no visual drag/dial control.

Anchored via `plane_ref: PlaneRef` (see conventions) for the chain's own
plane; the turn-angle chain lives within that plane.

### Interference checking — a topology split, not a tolerance value

The naive check ("do two stages' addendum circles overlap?") can't
distinguish a correctly meshing pair from a real collision: addendum
radius = pitch radius + module, so a *correctly meshing* pair's addendum
circles always overlap by design (`sum of addendum radii = center_distance
+ 2×module` — teeth interleave, that's the point). A fuzzy "how much
overlap is OK" threshold can't resolve that ambiguity. The chain's own
topology already disambiguates it instead:

- **Consecutive stage pairs**: no *body-envelope* check — correctness
  there is guaranteed by `gear_math`'s exact center-distance formula
  (the two solids' addendum circles are always tangent-or-overlapping by
  the design margin above, never further apart or closer). Getting the
  two solids' actual *tooth phase* right — one member's tooth landing in
  the other's gap rather than tooth-on-tooth, at the correct centre
  distance — is a separate concern this section originally left
  unaddressed entirely: every non-rack member was built with `app.
  document.gear`'s own fixed "tooth 0 at local azimuth 0" convention with
  no rotation ever applied, silently producing real tooth-on-tooth
  interference for most tooth-count combinations. Fixed by `app.document.
  gear_chain_math.meshing_phase_base`/`propagate_meshing_phase` — see
  that module's own extensive derivation notes (two real-OCCT
  counterexamples that ruled out two successively-simpler, wrong
  versions of the fix along the way) and `PlanetaryGearFeature`'s own
  parallel section below for the sun/ring/planet case. A rack member
  gets the equivalent fix (`rack_meshing_phase_base`) only when it's a
  junction's own *successor* — a real, separate, still-open bug in `app.
  document.gear_chain._rack_rotation`'s own orientation formula makes a
  RACK-as-predecessor junction (a rack as the chain's first stage, or a
  rack in the middle of a gear-rack-gear chain) mesh incorrectly
  regardless of tooth phase, documented but not fixed as part of this
  workstream.
- **Every non-adjacent pair**: exact overlap test (zero tolerance — any
  overlap is a genuine problem), *plus* a small default **print-clearance
  margin** (e.g. 0.2mm — flag pairs that come within this distance
  without literally overlapping; geometrically-fine isn't the same as
  printable). Both non-blocking warnings. This is still a pure
  *body-envelope* check, unrelated to tooth phase — it catches a bent
  chain looping back on itself, not tooth-on-tooth interference between
  meshing neighbours (which the point above now covers separately).

Bounding shape differs per stage type — be precise, don't treat every
stage as a generic circle:
- **External**: addendum circle (teeth point outward).
- **Internal**: *outer rim* circle, not addendum (teeth point inward into
  its own bore — the rim is what can collide externally).
- **Rack**: oriented bounding rectangle along its length
  (addendum-to-dedendum band width), not a circle.

No existing precedent for any of this anywhere in this codebase —
genuinely new geometry-validation code.

The 2D preview (`08-entry-screen-and-preview.md`) must render the actual
routed path (each stage's center = previous center + center-distance +
turn angle), highlighting any interfering pair directly on the offending
gears.

---

## Compound gears (in scope, not deferred)

A compound gear: two or more gears rigidly fused coaxially on one shaft —
the incoming mesh from one station connects to one member, the outgoing
mesh to the next station originates from the other; the two members never
mesh each other. This is exactly the case `GearGroup` exists for: a
compound station is where a chain crosses from one group to another,
since its two coaxial members are free to differ in module without
needing to mesh.

**Scope**:
- Stage-list item type becomes a discriminated union: a single-gear stage
  (as above) or a **compound stage** holding *two* gear specs (each its
  own type/teeth/width/hand/`group_id`) plus an axial stacking-offset
  parameter between them along the shared shaft axis.
- Cross-group mesh validation at a compound join: the two members' own
  `group_id`s must each match their respective neighbour's, and must
  differ from each other (a compound station whose two members share a
  group is just an ordinary single-gear station — structurally
  meaningless).
- Compound-aware ratio/direction rule (`08-entry-screen-and-preview.md`'s
  preview): never reverses direction (both members are rigidly fused,
  always co-rotate), but changes the ratio by the two members' own
  tooth-count difference — a distinct case from an ordinary meshing link.
- Merge behaviour: **fuse into one Body by default** (matches what a
  compound gear physically usually is when printed/machined — one hub,
  two diameters), overridable to keep the two members separate (e.g.
  pressed onto a common keyed shaft) via the existing `MergeMode` field
  Pattern/Mirror already expose.

**Two unspiked unknowns, resolved by a real spike against
`pythonocc-core` — see "Spike 2 findings" below.** Original framing, kept
for context:
- **Structural transition between the two diameters.** A large module
  difference leaves a step (or a thin unsupported overhang) at the join.
  No manufacturing-constraint validation exists anywhere in this
  codebase yet. Most likely: a minimum-thickness check (non-blocking
  warning) plus an optional fillet at the join, not a hard constraint.
- **DXF export for a compound station doesn't reduce to one profile.**
  The two members sit at *different depths* along the shaft, not the
  same 2D plane. Likely resolution: two separate per-member DXF files
  even when the 3D solid is fused (matches how the members are actually
  cut/printed as two profiles regardless of fusion) — decide explicitly
  in `06-dxf-export.md`, don't assume.

---

## `PlanetaryGearFeature`

Kept as its own Feature type, not folded into `GearChainFeature` — its
topology is genuinely different: branching (sun meshes every planet,
every planet meshes the ring), not a sequence. Resolves into N+2
positioned Bodies (sun, ring, N planets) in one pass, same multi-body
convention as `GearChainFeature`. Static/positioned only — no continuous
kinematics/rotation simulation, but each member's own one-time build
rotation *is* chosen (not left at zero) for correct tooth-mesh phase — see
below.

**Meshing-phase alignment**: originally, sun/ring/every planet all shared
`app.document.gear`'s own fixed "tooth 0 at local azimuth 0" build
convention with no per-member rotation ever applied — real, silent
tooth-on-tooth interference for essentially every tooth-count
combination, the same bug `GearChainFeature`'s own section above
describes, generalized here to the branching sun/ring/N-planets topology
instead of a sequence. Fixed the same way: the sun anchors this
assembly's own zero-reference (rotation `0.0`, arbitrary but fixed); each
planet's own rotation is then *fully* determined by its own mesh with the
sun (`app.document.gear_chain_math.meshing_phase_base`/`propagate_
meshing_phase`, sun as predecessor, the planet's own orbital azimuth as
the junction's `incoming_direction`) — a planet has exactly one
rotational degree of freedom, and the sun-mesh constraint alone consumes
all of it, so there is nothing left to independently choose to also
satisfy the ring. The ring's own rotation is instead solved for once,
from planet 0's resulting rotation (planet 0 as predecessor, the ring as
successor, at the ring's own azimuth directly opposite planet 0's,
`INTERNAL` flipping the correction's sign the same way it does for a
chain's own external-into-internal junction) — and, per the already-
enforced assembly condition (`(N_sun + N_ring) mod N_planets == 0`), that
same ring rotation was confirmed (real `BRepAlgoAPI_Common` measurement,
not assumed) to also correctly mesh every *other* planet, not just planet
0. Verified at 0.000000mm³ overlap across sun/ring/every-planet for
multiple planet counts and tooth-count ratios (all clear of the
low-tooth-count real involute tip interference `gear_chain_math`'s own
module note documents — a genuine, pre-existing, separate geometric
limitation no phase fix can itself resolve).

**Inputs, resolved** (a real gap found while walking a full user flow
end to end — none of this was specified before):
- **Sun and ring tooth counts are the free inputs.** Planet tooth count
  is **not** a separate input — it's computed as `N_planet = (N_ring −
  N_sun) / 2`, the same "derived, not entered" treatment
  `GearChainFeature`'s center distance already gets. A planet can't
  independently mesh with both sun and ring at any other tooth count.
- If `(N_ring − N_sun)` is odd or non-positive, there's no valid gear to
  draw at all — **this blocks creation outright** (see conventions'
  validation-banner exception), unlike the softer non-blocking warnings
  used elsewhere.
- Planet count validated against the assembly condition (`gear_math`,
  Workstream 1): `(N_sun + N_ring) mod N_planets == 0`.
- **One shared face-width field** across sun/ring/planets — real
  planetary sets mesh across one common axial band, so this isn't a
  per-member field the way tooth count is for `GearChainFeature`'s
  stages.
- **No turn-angle/path concept at all** — planetary's topology is fixed
  and radial (planets evenly auto-spaced around the sun at the correct
  radius), not a routed path. Simpler than `GearChainFeature` in this
  one respect.

`GearGroup` does **not** apply here — planetary topology structurally
requires one shared module across sun/planets/ring (no place for a
module change to happen the way a chain has a compound join), so module/
pressure-angle are flat shared fields directly on `PlanetaryGearFeature`.

Anchored via `plane_ref: PlaneRef` (see conventions), same as
`GearChainFeature`.

---

## Complexity/risk

High for `GearChainFeature` (bent paths + interference checking are both
genuinely new problems for this codebase) **and** for compound-station
geometry within the same workstream (coaxial stacking, cross-group
validation, the two unspiked unknowns above) — worth two real spikes, not
one, before committing the full chain UI/DXF export to depend on either.
Medium for `PlanetaryGearFeature` (no new geometry-kernel work, mostly
correct application of Workstream 1's math plus Workstream 2's per-gear-
type geometry builders). Low for `GearGroup`'s own schema in isolation (a
small referenced record and a "same group" mesh-validation check) — it's
compound-station geometry specifically that carries the real cost.

---

## Spike 1 findings (2026-08-04) — `GearChainFeature` bent-path positioning + interference checking

Investigate/prototype only, per this doc's own "plan for two separate
spikes" note above — Spike 1 covers `GearChainFeature`'s own two new
problems (below); Spike 2 (compound-station geometry) is not attempted
here. Pure-Python prototype, no `GearChainFeature` schema/router/OCCT work
— confirms both problems are cleanly implementable, with hand-verified
numbers, before committing to the full build. Prototype script (throwaway,
not committed) printed every number below directly; nothing here is "it
runs" without a hand check, matching Workstream 1's own test discipline
(`docs/status.md`'s Workstream 1 entry).

### 1. Bent-path positioning — turtle graphics, confirmed clean

**Resolution rule** (0-indexed stages `0..N-1`, segment `k` connects stage
`k` to stage `k+1`, `k = 0..N-2`):

- Segment `0`'s direction = the chain-level `start_direction` field,
  absolute.
- Segment `k` (`k >= 1`)'s direction = segment `k-1`'s direction +
  `stages[k].turn_angle` — turtle-relative, CCW-positive. Reuses
  `gear_math._rotate`'s existing CCW-positive convention directly (no new
  sign rule invented) — the same convention `RevolveFeature.angle`/OCCT's
  `gp_Ax1` rotation already use.
- `stage[k]`'s `turn_angle` field steers the segment **leaving** stage `k`
  (segment `k`), not the segment arriving at it. Centre position:
  `position[k+1] = position[k] + center_distance(k, k+1) * (cos(dir_k),
  sin(dir_k))`, anchored `position[0] = (0, 0)` in the chain's `plane_ref`
  local frame.

**Real gap found**: `stage[N-1]` (the last stage) has a `turn_angle` field
per the doc's "every stage after the first" rule above, but there is no
segment `N-1` for it to steer (max segment index is `N-2`) — the field is
geometrically inert on the last stage specifically. Not a blocker (it's
just an unused number, same as any other over-permissive field), but
Workstream 8's entry screen should either grey it out or omit it on the
last row rather than silently accepting a value that does nothing.

**Data structure sketch**:

```python
@dataclass
class ResolvedChainStage:
    index: int
    center: tuple[float, float]        # local (x, y) in plane_ref's frame
    incoming_direction: float | None   # radians; None for stage 0
    outgoing_direction: float | None   # radians; None for the last stage
    bounding_shape: BoundingCircle | BoundingRect  # see part 2

@dataclass
class ResolvedGearChain:
    stages: list[ResolvedChainStage]
    interference_findings: list[InterferenceFinding]  # see part 2


def resolve_chain_positions(
    stages: list[GearChainStageSpec],   # kind, tooth_count, turn_angle, ...
    module: float,
    start_direction_degrees: float,
) -> list[ResolvedChainStage]: ...
```

**Worked example** (module 2, 5 stages, external/external/external/
external/internal, one 90° sharp turn then a -30° turn back,
`start_direction = 0°`):

| stage | kind | teeth | turn° | segment dir° (hand: cumulative sum) | centre (hand-computed) |
|---|---|---|---|---|---|
| 0 | ext | 20 | — | 0 | (0, 0) |
| 1 | ext | 15 | 0 | 0 (0+0) | (35, 0) — `d=m(20+15)/2=35`, `+35·(cos0,sin0)` |
| 2 | ext | 10 | 90 | 90 (0+90) | (60, 0) — `d=m(15+10)/2=25`, `+25·(cos0,sin0)` |
| 3 | ext | 25 | -30 | 60 (90-30) | (60, 35) — `d=m(10+25)/2=35`, `+35·(cos90,sin90)` |
| 4 | int | 60 | (n/a — last stage) | 60 (inert field) | (77.5, 65.310889) — `d=m(60-25)/2=35`, `+35·(cos60,sin60)=+35·(0.5, 0.8660254)=(17.5, 30.310889)` |

Every centre-distance and direction above reproduced exactly by the
prototype (`math.isclose` against the hand-computed values, all `True`);
stage 4's centre matches `60+35·0.5=77.5` and `35+35·0.8660254=65.310889`
by direct calculator check.

**Open question, not this spike's job to resolve**: a rack stage's own
position needs a reference point *and* an orientation (its length axis),
not just a centre — the doc doesn't specify how a rack's length axis
derives from the connecting segment's turtle direction. Most likely
convention (untested here): the rack's length axis is perpendicular to the
connecting segment direction, its pitch line offset from the neighbouring
gear's centre by exactly that gear's pitch radius along the segment
direction. This spike's worked example deliberately used four gears
(no rack) to keep the turtle math itself unambiguous; resolving the
rack-orientation convention is real remaining work before the full build,
separate from (and smaller than) either of this spike's two headline
problems.

### 2. Interference checking — topology split, confirmed implementable with zero-tolerance/margin cleanly separated

Bounding shape per stage type, per this doc's own spec above:
`BoundingCircle(center, radius)` with `radius` = addendum radius
(external) or **outer rim radius** = `outer_diameter / 2` (internal — the
same `outer_diameter` field `GearFeature` already requires for internal
gears, *not* `dedendum_radius`, which for an internal gear points outward
toward the rim but isn't the rim itself); `BoundingRect(center, angle,
half_length, half_width)` for a rack, `half_length = rack_length / 2`,
`half_width = (addendum_height + dedendum_height) / 2`, `center` offset
from the rack's pitch-line reference point by `(addendum_height -
dedendum_height) / 2` along the rack's own perpendicular axis (asymmetric
by default: `1.0×module` addendum vs `1.25×module` dedendum).

Three shape-pair combinations, all exercised in the prototype:

```python
def circle_circle_gap(a: BoundingCircle, b: BoundingCircle) -> float: ...
def circle_rect_gap(circle: BoundingCircle, rect: BoundingRect) -> float: ...
def rect_rect_gap(a: BoundingRect, b: BoundingRect) -> float: ...

def check_chain_interference(
    bounding_shapes: list[BoundingCircle | BoundingRect],
    print_clearance_margin: float = 0.2,
) -> list[InterferenceFinding]:
    """Skips every consecutive (adjacent-index) pair outright — no check,
    per this doc's own reasoning above. Every non-adjacent pair: gap < 0 ->
    "overlap" finding (zero tolerance), 0 <= gap < margin -> "clearance"
    finding, gap >= margin -> no finding. Both finding kinds non-blocking
    per 00-conventions.md's validation-banner convention."""
```

All three gap functions return a single **signed** number (negative =
overlap depth, positive = clear gap) — this is what makes the "zero
tolerance for real overlap, small margin for near-miss" split trivial to
implement as one `gap < 0` / `gap < margin` check shared across all three
shape pairs, rather than three bespoke boolean tests:

- **circle-circle**: `center_distance - (radius_a + radius_b)`. Exact,
  no approximation.
- **circle-rect**: standard oriented-box signed-distance function (SDF) —
  transform the circle's centre into the rectangle's local frame, then
  `hypot(max(|dx|-half_length, 0), max(|dy|-half_width, 0)) +
  min(max(|dx|-half_length, |dy|-half_width), 0)`, minus the circle's
  radius. Exact (box SDF is exact both inside and outside), not an
  approximation.
- **rect-rect**: Separating Axis Theorem over the 4 unique edge-normal
  axes (2 per rectangle — sufficient for 2D OBB-OBB). **Overlap detection
  is exact** (SAT is an iff for convex polygons — if no axis separates
  them, they truly overlap). The **separation magnitude** returned when
  they don't overlap (`max` of the 4 per-axis gaps) is a conservative
  lower bound on true separation — exact for the common parallel-edge-
  facing case, an underestimate for a corner-to-corner closest-approach
  case. Conservative is the safe direction for a print-clearance margin
  check (never reports more clearance than actually exists), so this
  doesn't compromise the "zero tolerance for overlap" half of the split —
  only the near-miss magnitude for the already-fuzzy margin half, which
  tolerated approximation by design.

**Worked example, one instance of each shape pair** (module 2 throughout;
full numbers in the prototype's printed output):

- *circle-circle*, two addendum-22 circles (20-tooth, module-2 gears):
  centres 50mm apart → `gap = 50 - 44 = 6.0` (clear); 44.1mm apart →
  `gap = 0.1` (inside the 0.2mm margin → clearance finding); 40mm apart →
  `gap = -4.0` (real overlap).
- *circle-rect*, a 10-tooth module-2 rack (`half_length = 31.4159`,
  `half_width = 2.25`, rect centred at `(0, -0.25)`) against an
  addendum-22 circle: placed tangent to the rect's top edge at
  `y = 24` → `gap = 0.0` exactly; placed at `y = 100` →
  `gap = (100 - (-0.25) - 2.25) - 22 = 76.0`.
- *rect-rect*, two identical racks (`half_width = 2.25` each) both
  axis-aligned: centres 10mm apart (perpendicular) → `gap = 10 - 4.5 =
  5.5`; 4.5mm apart → `gap = 0.0` exactly (touching); 3mm apart →
  `gap = -1.5` (overlap). A 45°-rotated, overlapping placement also
  correctly returns negative.
- Running `check_chain_interference` over part 1's 5-stage worked example
  (addendum/outer radii `[22, 17, 12, 27, 70]`) finds genuine overlaps at
  non-adjacent pairs `(1,3)`, `(1,4)`, `(2,4)` and correctly skips every
  consecutive pair — expected, since that worked example was built to
  exercise a sharp turn, not to be a collision-free design; it's a useful
  side-confirmation that a naive bent path easily self-collides and that
  the checker actually catches it.

### Conclusion

Both halves prototype cleanly in pure Python with no OCCT dependency, per
`00-conventions.md`'s OCCT-free/dependent split — `gear_chain_math.py`
(mirroring `gear_math.py`'s own shape) can hold `resolve_chain_positions`
and the three gap functions + `check_chain_interference` directly, unit-
tested the same way `test_gear_math.py` already is. Two small pieces of
real design work remain before the full build (not blockers, not
attempted in this spike): the last-stage inert-`turn_angle`-field UI
handling, and the rack-orientation-within-a-bent-chain convention. Spike 2
(compound-station geometry) is still separately required before the full
Workstream 5 build, per this doc's own risk section above.

---

## Spike 2 findings (2026-08-04) — compound-station geometry, against real `pythonocc-core`

Investigate/prototype only, per this doc's own "plan for two separate
spikes" note above — Spike 1 (above) is unmodified context, not redone
here. Unlike Spike 1 (pure Python, no OCCT), this workstream's own compound-
gear unknowns are explicitly OCCT questions ("structural transition
between two diameters," "does the fused solid's own geometry support a
join fillet"), so this spike required real `pythonocc-core`, not reasoning
about the API. Bootstrapped a real conda-forge env — `micromamba` from its
GitHub Releases download-asset URL (`micro.mamba.pm` 403'd through this
sandbox's proxy, same shape as every prior session's entry above), built
`backend/environment.yml` (`pythonocc-core=7.9.3=novtk*`, `conda.anaconda.org`
reachable) — the same established recipe every prior spike in this file
used. Prototype script (throwaway, not committed) built every solid via
`app.document.gear`'s own real internals (`_gear_outline_wire`, `_gear_face`,
`_apply_root_fillet`, `spur_gear_geometry` — a simplified stand-in for
`resolve_gear_from_bodies` that hand-builds a `ResolvedPlane` offset along
world Z instead of routing through `resolve_plane_ref`/a full
`Part`/`compute_part_bodies`, which isn't needed to test the join itself),
fused the results with real `BRepAlgoAPI_Fuse`, and inspected the actual
output (`BRepCheck_Analyzer`, `TopAbs_SOLID`/`TopAbs_FACE`/`TopAbs_EDGE`
counts, real `BRepGProp` volumes) — every number below is printed output
from that run, not restated reasoning.

### 1. Structural transition: minimum-thickness alone is not sufficient — the real failure mode is silent disconnection

**External+external members never degenerate, at any tested module
ratio.** Five module/tooth-count combinations up to a 16× ratio (module
0.5 ↔ module 8, 60-tooth ↔ 8-tooth) all fused into one topologically valid
single solid — `BRepAlgoAPI_Fuse.IsDone()` and `BRepCheck_Analyzer.IsValid()`
both `True` in every case, fused volume equal to the sum of the two
members' own unfused volumes to the mm³ (e.g. the 16× case: `A=2109.668 +
B=108088.318 = 110197.986`, fused `110197.986`, zero difference). This
matches what `_gear_face` actually builds: an external `GearFeature` is a
solid disc all the way to the shaft centre (wire-alone face, no inner
loop), so two coaxial external members are always fully backed by a
continuous cross-sectional web at the join — never merely a thin shell.
**A plain minimum-thickness warning would be guarding against a failure
mode that structurally can't occur for the common external+external
case.**

**Three real, silent failure modes were found instead, none flagged by
`Fuse.IsDone()` or `BRepCheck_Analyzer` (both stayed `True` in every case
below):**

1. **Axial gap.** Module-1/20-tooth (`face_width=6`) stacked against
   module-5/10-tooth with a gap between the two members' own `z` ranges:
   `gap=0.0mm` → 1 solid (correct). `gap=0.1mm` → **2 solids** — `IsDone`
   and `BRepCheck.IsValid` both stayed `True`, only a real
   `TopAbs_SOLID` walk (`_explode_solids`) reveals the members never
   actually touch. `gap=1.0mm` → 2 solids, same silent pattern. A 0.1mm
   stacking-offset typo is well within plausible user input.
2. **Radial mismatch on an internal (ring) member.** Compound members can
   be any type ("each its own type" per this doc's own scope), and a ring
   gear's material is an annulus, not a disc. Built a ring (module 2, 40
   teeth, `outer_diameter=90` → outer rim radius 45mm, inward addendum
   reach 38mm) against three external partners at the same axial position:
   a small pinion (module 1, 8 teeth, addendum radius 5mm, well inside the
   38mm bore) → **2 solids**, a floating disconnected pinion; a bigger
   pinion (module 1, 46 teeth, addendum radius 24mm, still short of 38mm)
   → still **2 solids**; only once the pinion's own addendum radius
   (module 2, 44 teeth → 46mm) exceeds the ring's 38mm reach does it
   become **1 solid**. Confirms the mechanism is genuinely radius-
   dependent, not a fixed bug, and — as the doc's original "step/overhang"
   framing didn't anticipate at all — this is a connectivity problem
   specific to internal-member compounds, not a thickness problem.
3. **Axial overlap.** Module-1/20-tooth stacked with the second member's
   `z` start moved *earlier* than the first member's own `face_width` (a
   stacking offset smaller than it should be): `overlap=0.0mm` → 1 solid,
   volume exactly the unfused sum (36098.919mm³). `overlap=1.0mm` → still
   1 solid (`IsDone`/valid both `True`), but volume drops to
   35777.806mm³ — 321.113mm³ less than the unfused sum. `overlap=3.0mm` →
   1 solid, volume 35135.580mm³, 963.339mm³ less. Geometrically valid
   (one connected solid, no OCCT error), but the larger member's footprint
   silently swallows the smaller member's own tooth geometry in the
   overlap band — the result doesn't match either member's stated spec
   there.

**Resolution**: a minimum-thickness check does not catch any of the three
cases above (none are a thin wall; all are silent — no exception, no
invalid-shape flag). What actually catches case 1 and 2 cheaply, reusing
existing code with zero new topology work: **count connected solids after
the join** the same way `app.document.extrude._explode_solids` already
does (already called by `_register_solids` on every Boss/Cut/Pattern/
Mirror result — no new function needed, just a call-site check). When
`merge=FUSE_INTO_ONE` was requested and the result comes back as more
than one connected solid, that's `00-conventions.md`'s "no valid geometry
to draw" **blocking** exception (the user asked for one fused body and the
given parameters don't produce one) — not a soft warning, since there is
nothing sensible to register as "the" fused Body. Case 3 (axial overlap,
silently-swallowed geometry) is a good fit for the ordinary **non-blocking**
warning convention instead — the result is a single valid solid, just
surprising relative to the stated per-member spec; detecting it needs
comparing the fused volume against the two members' own unfused volumes
(both already computed for free before the fuse). A literal minimum-
thickness metric is still worth keeping, but as a separate, simpler check
on a single member's own `face_width` in isolation (a 0.3mm-thick member
is physically fragile regardless of the join) — a different question from
the join geometry this spike was scoped to test.

### 2. Optional join fillet: the edge-picking mechanism generalizes, but convergence is too narrow to be worth building now

Locating "the join" directly on the fused result (walking every edge of
the fused shape and keeping the ones whose bounding box sits flat in the
member-A/member-B transition plane, `z=width_a`) works cleanly and
generalizes the same "map original topology through the operation" idiom
`_apply_root_fillet` already uses via `BRepPrimAPI_MakePrism.Generated()` —
just via a direct query on the fused result here rather than the prism's
own build history (tracking member A's *original* top face through
`BRepAlgoAPI_Fuse.Modified()`/`IsDeleted()` turned out to be the wrong
approach: when member B's cross-section is larger than member A's, the
exposed "shoulder" at the join is a face newly carved from member B's
own bottom face, not a survival of member A's top face at all — a real
dead end this spike hit and corrected before landing on the direct-query
approach).

But actual convergence of `BRepFilletAPI_MakeFillet` around that whole
loop (a modest module diff, module 1→2, 20→15 teeth: 280 join-plane edges
found; a large diff, module 1→5, 20→10 teeth: 240 edges) is narrow and
non-monotonic with radius:
- Modest diff (module 1→2): converges (`IsDone=True`) at 0.05–0.5mm,
  fails at 0.8mm and 1.0mm.
- Large diff (module 1→5): converges at 0.05–0.8mm, fails only at 1.0mm —
  a *wider* window than the modest-diff case, confirming the relationship
  between module difference and which radii converge isn't a simple
  monotonic curve.

The usable window exists but is unpredictable as a function of module
difference, and even where it converges the radii (well under 1mm) are
too small relative to a real multi-millimetre step to meaningfully
address stress concentration — cosmetic at best, not real relief. Given
root fillet "worked correctly on the first real run, no fixes needed" per
this project's own Workstream-2 history (`docs/status.md`), a whole-loop
join fillet is a materially less reliable feature by comparison. **Not
worth building as v1 scope.** A more promising future angle (not
prototyped here, genuinely new geometry work): a chamfer/lead-in on just
the *outer envelope* at the transition radius (one large circle, not the
actual scalloped tooth-profile loop).

### 3. DXF two-files resolution: confirmed, and simpler than the original framing suggested

No DXF export code exists in this codebase yet (`06-dxf-export.md`,
Workstream 6, unstarted — confirmed by direct search, not assumed), so
this is a scoping conclusion, not a code test — correctly out of this
spike's scope to implement. `06-dxf-export.md`'s own existing scope
already writes a gear's DXF directly from its stored generative
parameters (`gear_math` profile points) — it never slices or re-derives
from the OCCT solid. Each compound member keeps its own `module`/
`tooth_count`/`pressure_angle`/`face_width` spec on the Feature regardless
of what the fused 3D solid ends up looking like (confirmed directly by
this spike's own Part A–D results above: the fuse only ever touches the
3D solid, never the members' own stored parameters), so **whether
`merge=FUSE_INTO_ONE` or `KEEP_SEPARATE` was chosen makes no difference to
DXF export** — "two separate per-member DXF files" isn't a special case
needing new logic, it's the same per-member path `06-dxf-export.md`'s
"per-gear cut files" already needs for an ordinary N-stage chain, just
contributing 2 files for a compound stage instead of 1.

Two concrete, previously-unflagged refinements for `06-dxf-export.md`'s
own future scope (not implemented here):
1. **Per-gear cut file naming needs a compound-aware case.** An ordinary
   chain stage maps 1:1 to one output file; a compound stage must map to
   2 (member A / member B) — a naming sub-index, not a structural rework.
2. **Combined layout export has an unaddressed compound case.** Both
   members of a compound stage share the exact same `(x, y)` centre
   (coaxial, unlike an ordinary chain's sequentially-offset stages) — in
   a flat top-down layout drawing they land exactly on top of each other
   by construction. Not a bug (they genuinely are coaxial), but the
   writer needs a deliberate choice here (e.g. one DXF layer per member at
   the shared location) rather than silently overlapping two profiles
   indistinguishably on one layer.

### 4. `MergeMode`: confirmed sufficient for the coaxial compound case, with one gap already covered by finding 1 above

Built a `TopoDS_Compound` of two touching-but-unfused coaxial solids and
ran it through the real `_explode_solids`/`_register_solids` functions
Pattern/Mirror's own `KEEP_SEPARATE` path already uses (not reasoning
about them — actually called them, same as every other check in this
spike):

- **`KEEP_SEPARATE`**: `_register_solids(bodies, "compound_stage_1",
  compound)` registered `['compound_stage_1#0', 'compound_stage_1#1']` —
  two independent Bodies, identical to Mirror/Pattern's own disjoint-
  copies outcome. `_explode_solids` walks `TopAbs_SOLID` topologically,
  not by spatial proximity, so two independently-built solids that merely
  touch (no shared BRep topology) are correctly split, no special-casing
  needed for "touching" vs. "spatially separate" — confirming this covers
  the coaxial case cleanly, not just Pattern/Mirror's original
  non-coaxial (spatially-disjoint-copies) use case.
- **`FUSE_INTO_ONE`, well-formed** (correct stacking offset): registered
  `['compound_stage_1']` — one Body, correct.
- **`FUSE_INTO_ONE`, 0.5mm axial gap**: `Fuse.IsDone()=True`,
  `BRepCheck.IsValid()=True`, but `_register_solids` still registered
  `['compound_stage_1#0', 'compound_stage_1#1']` — silently split into two
  Bodies despite the user asking for one fused body. This is exactly
  finding 1's own gap, confirmed directly through the real `MergeMode`
  plumbing rather than in the abstract: `MergeMode`'s existing two values
  and `_register_solids`'/`_fuse_realized_instances`' existing mechanics
  are sufficient and need no new field or enum value — what's missing is
  a `FUSE_INTO_ONE`-specific caller-side check on the resulting body count
  (finding 1's resolution), which Mirror/Pattern's own existing
  `FUSE_INTO_ONE` callers never needed since their sources/copies aren't
  positioned by a user-typed axial-offset number the way a compound
  stacking offset is.

One further, minor observation: `KEEP_SEPARATE` performs no boolean at
all, so a compound station built with `KEEP_SEPARATE` *and* a mistaken
axial overlap would register two literally interpenetrating Bodies (both
keeping their own full, unmodified geometry) rather than
`FUSE_INTO_ONE`'s "geometrically valid but volume-short" outcome (finding
1, case 3). Not a new gap this spike introduces — this app already allows
any two Bodies to overlap in general (nothing Pattern/Mirror-specific
prevents it today) — but worth carrying into the full build as the same
kind of non-blocking warning as finding 1's overlap case, checked
independently of which `MergeMode` was chosen.

### Conclusion

Both compound-gear unknowns are resolved with real evidence, not just
re-derived reasoning: a plain minimum-thickness check is **not**
sufficient (three silent disconnection/volume-loss modes reachable via
plausible input, none of them a thin wall); the fix is a connected-solid-
count check after the join (blocking when `FUSE_INTO_ONE` produces >1
solid, non-blocking for the overlap/volume-loss case), cheap to build by
reusing `_explode_solids` already-existing logic. A join fillet is
technically wireable (edge-picking generalizes) but not worth building as
v1 scope — convergence is too narrow and unpredictable to be a reliable
feature. The DXF two-files resolution is confirmed and simpler than
originally framed (gear DXF export never touches the 3D solid at all, so
fuse-vs-separate is a non-issue for it), with two concrete refinements
flagged for `06-dxf-export.md`'s own future scope. `MergeMode`'s existing
`KEEP_SEPARATE`/`FUSE_INTO_ONE` values need no new field for the coaxial
compound case — both were exercised directly against real coaxial solids
here, not just reasoned about from Pattern/Mirror's original non-coaxial
use case.

**Both of Workstream 5's spikes are now done** (Spike 1: `GearChainFeature`
bent-path positioning + interference checking, above; Spike 2: this
section). **Workstream 5 is clear to move to a full build** — the
remaining open items are small, scoped design decisions to make during
implementation (Spike 1's last-stage inert-field UI handling and rack-
orientation convention; this spike's connected-solid-count check and the
two `06-dxf-export.md` refinements), not further unresolved technical
risk requiring another spike.
