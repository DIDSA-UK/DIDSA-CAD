# Workstream 11 — `BevelPairFeature`: automated live bevel pairing

Read `00-conventions.md` first. Depends on `10-bevel-gear.md` — do not
start until that workstream's spike has confirmed the construction
approach.

## Scope

Scoped as a **pair specifically (exactly 2 members), not a generalized
N-stage bevel chain** — deliberately narrower than `GearChainFeature`.
Bevel trains longer than two gears are a rarer, more exotic case than
planar chains, and routing a 3D path through multiple arbitrary shaft
angles would import all of `GearChainFeature`'s bent-path/interference-
check complexity into a second, geometrically unrelated (intersecting-
axis, not parallel/coplanar) case. If a longer bevel train is wanted
later, it's an additive extension of this Feature type, not a redesign.

Mirrors `GearChainFeature`/`PlanetaryGearFeature`'s own live, re-
derivable pattern (one Feature, resolved fresh into multiple Bodies on
every recompute) — editing one gear's tooth count live-recomputes both
members' pitch cone angles and repositions/resizes automatically.

**Shared pair-level fields** (both gears physically share one axial
band/mesh, so these can't legitimately differ between the two members):
module, pressure angle, shaft angle, backlash, face width. **Flat fields
on the Feature itself, not a `GearGroup` reference** — deliberately
simpler than `GearChainFeature`'s group indirection, since a pair always
has exactly two members that always mesh each other; there's no third
station for a module change to happen at.

**Per-member fields**: tooth count, profile shift (legitimately differs
per member — used to balance strength between a small pinion and a large
gear).

**Shaft angle**: user-specified, arbitrary (not restricted to 90°),
feeding directly into `10-bevel-gear.md`'s cone-angle formula. **Default
90°**, pre-filled and editable — same "sensible default, always visible,
overridable" pattern used for the plane-anchor default
(`00-conventions.md`); 90° covers the overwhelming majority of real
bevel-gear use (right-angle drives, miter gears).

**Position**: apex-aligned — both gears' cone apexes coincide at one
point, axes intersecting at the specified shaft angle, anchored via
`plane_ref: PlaneRef` for the apex/primary-axis orientation (see
`00-conventions.md`).

**Interference checking: not needed at all.** With exactly two members
that are always the intended meshing pair, there's no "non-adjacent
stage" case for `GearChainFeature`'s own interference machinery to apply
to — a genuine simplification, not a silent gap.

**Kept fully separate from `GearChainFeature`** — no bevel stage kind
added to the planar chain. A chain that needs to turn a 3D corner places
a `BevelPairFeature` alongside a `GearChainFeature`, rather than the
chain's bent-path/interference machinery (built around one shared plane)
being extended to a structurally different intersecting-axis case.

**Unresolved, decide here**: a bevel gear has no flat 2D "cut profile"
the way planar gears do. Likely resolution: represent DXF export as the
back-cone tooth profile's flat pattern/development (a cone "unrolled"
flat — a standard bevel-drafting technique) — itself new geometry work,
distinct from anything else `06-dxf-export.md` needs for planar gears.

## Entry-screen note

The Gear Design screen (`08-entry-screen-and-preview.md`) exposes both
"Bevel Gear" (single, standalone, `10-bevel-gear.md`) and "Bevel Pair"
(this workstream) as separate type-selector options — mirrors how planar
gears expose both single External/Internal types and the Pair/Chain/
Planetary system options.

## Complexity/risk

High — real new positioning/validation logic (simpler than
`GearChainFeature`'s own in some ways, per the no-interference-check
simplification above, but built on `10-bevel-gear.md`'s still-unproven
construction approach) plus the DXF flat-pattern question above, itself
unspiked.
