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

- **Consecutive stage pairs**: no check at all — correctness is
  guaranteed by `gear_math`'s exact center-distance formula.
- **Every non-adjacent pair**: exact overlap test (zero tolerance — any
  overlap is a genuine problem), *plus* a small default **print-clearance
  margin** (e.g. 0.2mm — flag pairs that come within this distance
  without literally overlapping; geometrically-fine isn't the same as
  printable). Both non-blocking warnings.

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

**Two unspiked unknowns — resolve during this workstream, not
mid-implementation:**
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
convention as `GearChainFeature`. Static/positioned only — no
kinematics/rotation.

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
