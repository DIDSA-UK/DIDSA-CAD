# Workstream 6 — DXF export (MOVED, no longer a Gear Design workstream)

**This workstream moved to `docs/dxf-io/`.** Retired here deliberately
rather than deleted, so the history of why stays discoverable.

Originally scoped around a "design a gear, export DXF, reimport into a 3D
Part, extrude/loft it" round-trip. That motivation is dead —
`GearFeature`/`RackFeature`/`GearChainFeature`/`PlanetaryGearFeature`/
`BevelGearFeature`/`BevelPairFeature` all already build real solids
directly, no DXF round-trip needed. DXF export survives as a general 2D
Sketcher/3D Part Design capability instead, not a gear-specific one — see
`docs/dxf-io/00-conventions.md` for the full reasoning and
`docs/dxf-io/02-dxf-export.md`/`docs/dxf-io/03-gear-chain-schematic-export.md`
for the current scope (per-gear export is now free via a generic "Export
Face" capability, no gear-specific writer code at all; the multi-gear
chain/planetary layout export is scoped there as a schematic).

The two things this file used to flag as unresolved are both resolved in
the new location, not carried forward as open questions:
- Compound-station DXF (two members at different depths) — dissolved
  under the new "Export Face" model; each member has its own face.
- Bevel flat-pattern DXF — dropped from scope entirely, not deferred; a
  bevel tooth's curved flank has no flat face to export at all.
