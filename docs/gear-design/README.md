# Gear Design Tool

A new "Gear Design" entry point (alongside "3D Part Design"/"2D Drawing"
on `ToolChooserScreen`) for parametric text-entry gear generation with a
2D preview: external, internal, rack-and-pinion, helical, herringbone,
compound, planetary, and straight bevel gears — plus DXF import/export
and a general Loft feature. Ends in solid geometry ready to 3D print.

**Status: in progress.** Workstreams 1-3 (gear math core, `GearFeature`,
`RackFeature`) and a scoped-down v1 of Workstream 8 (entry screen + 2D
preview for those two Feature types) are done - see the table below and
`docs/status.md`'s dated entries. Helical/herringbone/Loft, gear chains/
compound/planetary, DXF import/export, presets, and bevel gears are all
still unstarted.

## How to use these docs in a fresh implementation session

**Read `00-conventions.md` first, always** — it holds every fact/decision
referenced by 2+ workstreams (Feature-tree checklist, why gear teeth
aren't Sketch entities, the `plane_ref`/`PlaneRef` positioning convention
and its XY default, real-`BSplineCurve` tooth flanks, the non-blocking
validation-banner convention, field input style). Workstream files don't
repeat it.

Then read **only the one workstream file you're implementing**, plus
whatever it names as a dependency. Don't read the other workstream files
— that's the entire point of this split (a prior single-file version of
this doc grew past 1000 lines; a session implementing one workstream
never needed most of it).

## Workstreams

| # | File | Depends on | Risk |
|---|------|-----------|------|
| 1 | `01-gear-math-core.md` | — | Medium |
| 2 | `02-gear-feature.md` | 1 | Medium-high |
| 3 | `03-rack.md` | 1, 2 | Low-medium |
| 4 | `04-helical-herringbone-loft.md` | 2 | High |
| 5 | `05-gear-chain-and-planetary.md` | 1, 2, 3 | High |
| 6 | `06-dxf-export.md` | 1, 5 | Low-medium |
| 7 | `07-dxf-import-block.md` | — | Medium |
| 8 | `08-entry-screen-and-preview.md` | 1, 2 | Medium - **v1 done** (external/internal/rack only; helical/herringbone/chain/planetary/bevel UI, multi-gear preview, and `GearGroup` colour-coding deferred to their own workstreams per that file's own scoped-down note) |
| 9 | `09-presets.md` | 8 | Low |
| 10 | `10-bevel-gear.md` | 1 | Highest in project |
| 11 | `11-bevel-pair.md` | 10 | High |

Spiral/Zerol/hypoid bevel variants are the one thing still deliberately
deferred past this whole project — a further-later phase after 10/11's
straight-bevel foundation is live.

## Delivery order

1. **Workstream 1** — no dependencies, everything else needs it.
2. **Workstream 2** — first real 3D gear, proves the Feature-tree
   integration end to end.
3. **Workstream 8** in parallel with/right after 2, so there's a usable
   tool as soon as spur gears work. **Workstream 9** afterward, no
   ordering pressure.
4. **Workstream 3** — cheap extension of 2.
5. **Four parallel spikes** (find a showstopper early, before the
   surrounding UI/schema/export commits to depending on any of them):
   Workstream 4's Loft/helix-sweep feasibility; Workstream 5's bent-path +
   interference-check approach; Workstream 5's compound-station spike
   (two coaxial gears, one fuse, one structural-transition check);
   Workstream 10's bevel spike (spherical-involute construction,
   confirm/reject `BRepOffsetAPI_ThruSections` for ruled tooth flanks).
6. **Workstream 4** once its spike lands.
7. **Workstream 5** once both its spikes land — depends on 2 and 3.
8. **Workstream 10** once its spike lands — no dependency on 2-5 (shares
   no construction code with any other gear type), sequenced here so it
   benefits from the rest of the tool (preview, DXF, presets) already
   existing to slot into rather than being built in isolation.
9. **Workstream 11** once 10 is live.
10. **Workstreams 6-7** — independent of the gear-specific work; can run
    on their own track in parallel. Workstream 6's per-gear export in
    particular could ship early, since the existing "2D Drawing" tool
    wants a DXF writer regardless of gears.
11. **Spiral/Zerol/hypoid bevel** — separate phase, after the above.

## Key decisions carried through every workstream (don't re-litigate)

- Gears are procedural Features (parameters → solid), never DXF-round-
  tripped or built as constraint-solved Sketch entities.
- Multi-gear systems (`GearChainFeature`, `PlanetaryGearFeature`,
  `BevelPairFeature`) are each one live, re-derivable Feature — not
  one-shot generators that create independent Features once.
- Compound-gear geometry and straight bevel are both in v1 scope, not
  deferred, despite being the two highest-risk items in the project —
  accepted deliberately.
- DXF import gets full "block" semantics (whole-unit selection in place,
  individual-curve pickable elsewhere via Convert Entities) — turned out
  to need almost no new client mechanism, see `07-dxf-import-block.md`.
