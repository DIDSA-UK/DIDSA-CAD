# Gear Design Tool

A new "Gear Design" entry point (alongside "3D Part Design"/"2D Drawing"
on `ToolChooserScreen`) for parametric text-entry gear generation with a
2D preview: external, internal, rack-and-pinion, helical, herringbone,
compound, planetary, and straight bevel gears — plus a general Loft
feature. Ends in solid geometry ready to 3D print.

DXF import/export is **no longer part of this doc set** — it moved to
`docs/dxf-io/` as a general 2D Sketcher/3D Part Design capability, not a
gear-specific one (the "design a gear, export DXF, reimport, extrude"
workflow that originally motivated it is dead now that gears build real
solids directly). See `docs/dxf-io/00-conventions.md` for the full
reasoning, and `06-dxf-export.md`/`07-dxf-import-block.md` in this
directory for pointers to the new location.

**Status: backend/API complete, client rollout in progress.** Workstreams
1, 2, 3, 4, 5, 10, 11 (gear math core, `GearFeature`, `RackFeature`,
helical/herringbone teeth + general `LoftFeature`, `GearChainFeature`/
`PlanetaryGearFeature`/`GearGroup`, `BevelGearFeature`, `BevelPairFeature`)
are all done. Workstream 8's entry screen + 2D preview now covers
external/internal/rack (v1), helical/herringbone teeth (`GearFeature`
fields on the existing External/Internal form), and chain/planetary
(`GearChainDesignScreen` - stage-list editor, multi-gear preview with
interference highlighting and `GearGroup` colour-coding, ratio/rotation-
direction display) - see `docs/status.md`'s dated entries. Still unstarted:
bevel/bevel-pair UI (Workstream 8's own extension) and Workstream 9
(presets) - Workstreams 10/11 remain backend/API only until their own
client UI lands, per their "build before UI" scope.

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
| 4 | `04-helical-herringbone-loft.md` | 2 | High - **done** (general `LoftFeature` + `GearFeature.helix_angle_degrees`/`herringbone`) |
| 5 | `05-gear-chain-and-planetary.md` | 1, 2, 3 | High - **done, incl. client UI** (`GearGroup`, `GearChainFeature` incl. compound stations, `PlanetaryGearFeature` all backend/API; `GearChainDesignScreen` covers chain/planetary preview + Create - v1 UI scope is single-gear/rack stages only, no compound-station UI yet, per that doc's own "v1 UI creates exactly one implicit group per chain" note) |
| 6 | `06-dxf-export.md` | — | — **moved to `docs/dxf-io/`**, no longer gear-specific |
| 7 | `07-dxf-import-block.md` | — | — **moved to `docs/dxf-io/`**, no longer gear-specific |
| 8 | `08-entry-screen-and-preview.md` | 1, 2 | Medium - **v1 + helical/herringbone + chain/planetary done** (external/internal/rack, `helix_angle_degrees`/`herringbone` fields on the same form, and `GearChainDesignScreen`'s own multi-gear preview - `/gear/preview` extended with `chain`/`planetary` nested payloads, interference highlighting, ratio/rotation-direction display, `GearGroup` colour-coding; bevel/bevel-pair UI still deferred to its own follow-on pass) |
| 9 | `09-presets.md` | 8 | Low |
| 10 | `10-bevel-gear.md` | 1 | Highest in project - **done** (`BevelGearFeature` - straight bevel, arbitrary shaft angle via a direct `pitch_cone_angle_degrees` field - backend/API only, bevel UI deferred to Workstream 8's own future extension) |
| 11 | `11-bevel-pair.md` | 10 | High - **done** (`BevelPairFeature` - apex-aligned dual-axis positioning, arbitrary shaft angle, auto-derived pitch cone angles - backend/API only, bevel pair UI deferred to Workstream 8's own future extension; DXF flat-pattern export deferred to Workstream 6) |

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
10. **Workstream 9 (presets)** — the one piece left in this doc set,
    no ordering pressure, can happen any time.
11. **Spiral/Zerol/hypoid bevel** — separate phase, after the above.

DXF import/export (formerly Workstreams 6-7 here) now has its own
delivery order in `docs/dxf-io/README.md`, independent of this doc set
entirely.

## Key decisions carried through every workstream (don't re-litigate)

- Gears are procedural Features (parameters → solid), never DXF-round-
  tripped or built as constraint-solved Sketch entities.
- Multi-gear systems (`GearChainFeature`, `PlanetaryGearFeature`,
  `BevelPairFeature`) are each one live, re-derivable Feature — not
  one-shot generators that create independent Features once.
- Compound-gear geometry and straight bevel are both in v1 scope, not
  deferred, despite being the two highest-risk items in the project —
  accepted deliberately.
- DXF import/export is not part of this doc set — see `docs/dxf-io/`.
