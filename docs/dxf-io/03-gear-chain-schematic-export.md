# Workstream 3 — Gear-chain/planetary schematic DXF export

Read `00-conventions.md` first — especially "Gear-chain schematic export".
Also read `docs/gear-design/05-gear-chain-and-planetary.md`'s own Spike 1
findings section (`gear_chain_math.resolve_chain_positions`'s exact output
shape) before starting — this workstream consumes that directly, doesn't
re-derive chain positioning.

## Scope

A combined-layout DXF for a `GearChainFeature`/`PlanetaryGearFeature`:
every member at its real relative 2D position, real tooth geometry (not a
block-diagram abstraction) for whichever members are genuinely
representable, using Workstream 2's own Export Face logic per member.

**`PlanetaryGearFeature` is always fully in-plane** — sun, ring, and every
planet mesh across one shared axial band by construction (no per-member
axial offset concept exists on this Feature type at all). Nothing is ever
omitted for a planetary export; every member gets real geometry.

**`GearChainFeature` needs the omission rule** — an ordinary chain stage
(external/internal/rack) is inherently in-plane, since
`resolve_chain_positions`'s own turtle-graphics positioning happens
entirely within `plane_ref`'s own 2D frame. The one case with genuine
depth is a **compound stage's second member** — stacked axially along the
shared shaft axis (`plane_ref`'s own normal), confirmed by
`docs/gear-design/05-gear-chain-and-planetary.md`'s own compound spike as
sitting at a different depth than the first member, not the same 2D plane.

**Open sub-question this workstream must resolve**: for a compound stage,
does the schematic show the first (reference-position) member's own face
and simply omit the second, axially-offset member — or omit the whole
compound stage from the drawing? `00-conventions.md`'s own "real geometry
for in-plane stages, omit the rest" decision doesn't fully pin this down
at the single-stage granularity. Lean toward showing the first member
(there's real, correct 2D geometry for it — no reason to withhold it) and
omitting only the second, but confirm this reads sensibly against a real
multi-stage test case with a compound station before committing to it.

## Mechanism

For each `ResolvedChainStage` (or planetary member) that's being drawn:
resolve its own already-built Body's flat end face (the same face Export
Face would pick if a user picked it manually), run it through Workstream
2's own face-to-local-2D-points logic, then place those points at the
stage's own already-resolved `center`/orientation in the combined
drawing's frame — a placement step on top of Workstream 2's own per-face
export, not new geometry-extraction code.

## Out of scope, confirmed not applicable

`BevelGearFeature`/`BevelPairFeature` — standalone or paired — have no
flat face at all (`00-conventions.md`'s "Bevel flat-pattern DXF" note) and
don't participate in `GearChainFeature` (`docs/gear-design/11-bevel-pair.md`'s
own "kept fully separate" decision). Bevel gears are simply not DXF-
exportable under this whole doc set's model, standalone or in a chain —
a known, accepted gap, not something this workstream needs to solve.

## Complexity/risk

Low. No new geometry-extraction technique — this is placement of
Workstream 2's own per-face output at positions `GearChainFeature`/
`PlanetaryGearFeature` already compute and expose. The only real decision
is the compound-stage omission granularity above.
