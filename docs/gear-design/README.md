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

**Status: complete, backend and client.** Workstreams 1, 2, 3, 4, 5, 10, 11
(gear math core, `GearFeature`, `RackFeature`, helical/herringbone teeth +
general `LoftFeature`, `GearChainFeature`/`PlanetaryGearFeature`/
`GearGroup`, `BevelGearFeature`, `BevelPairFeature`) are all done.
Workstream 8's entry screen + 2D preview covers external/internal/rack
(v1), helical/herringbone teeth (`GearFeature` fields on the existing
External/Internal form), chain/planetary (`GearChainDesignScreen` -
stage-list editor, multi-gear preview with interference highlighting and
`GearGroup` colour-coding, ratio/rotation-direction display), and
bevel/bevel-pair (`BevelDesignScreen` - the axial-cross-section schematic
preview a bevel tooth's lack of a flat 2D profile calls for, dual-axis for
a pair). Workstream 9 (presets) is done too - `GearPresetStore`
(client-local, `shared_preferences`-backed) plus a shared `GearPresetControls`
widget ("Save as preset"/"Load preset") on all three Gear Design screens.
See `docs/status.md`'s dated entries for the full rollout history.

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
| 8 | `08-entry-screen-and-preview.md` | 1, 2 | Medium - **fully done** (external/internal/rack v1, `helix_angle_degrees`/`herringbone` fields on the same form, `GearChainDesignScreen`'s multi-gear preview with interference highlighting/ratio-direction display/`GearGroup` colour-coding, and `BevelDesignScreen`'s dual-axis axial-cross-section schematic preview - `/gear/preview` now covers all seven `gear_kind` values) |
| 9 | `09-presets.md` | 8 | Low - **done** (`GearPresetStore`, client-local `shared_preferences`-backed named presets; `GearPresetControls` "Save as preset"/"Load preset" on all three Gear Design screens - no backend involvement, per this doc's own scope) |
| 10 | `10-bevel-gear.md` | 1 | Highest in project - **done, incl. client UI** (`BevelGearFeature` - straight bevel, arbitrary shaft angle via a direct `pitch_cone_angle_degrees` field; `BevelDesignScreen`'s "Bevel Gear" mode covers entry + the axial-cross-section schematic preview) |
| 11 | `11-bevel-pair.md` | 10 | High - **done, incl. client UI** (`BevelPairFeature` - apex-aligned dual-axis positioning, arbitrary shaft angle, auto-derived pitch cone angles; `BevelDesignScreen`'s "Bevel Pair" mode covers entry + dual-axis preview; DXF flat-pattern export still deferred to Workstream 6) |
| 12 | `12-spiral-bevel-gear.md` | 10 | Highest in project (harder than 10) - **Spike A + Spike B both run, still NO-GO but the path to GO is now concrete**. Spike A: NO-GO on "conjugate by construction" (the doc's own originally-proposed formula is a named dead end - a *corrected* construction reduces exactly to Tredgold at β=0 but leaves a real, phase-uncorrectable tangential residual). Spike B (2026-08-21) root-caused both of Spike A's own uncharacterized breakdowns: **neither is a flank self-fold** (`_flank_fold_warning` never fires in either case, at any angle tested) - the high-spiral-angle breakdown is a fixed meshing-*phase*-convention artifact (proven fixable by a small phase correction, not a hard geometric limit), and the extreme-tooth-ratio breakdown is a **pre-existing, non-spiral defect** in the existing straight-bevel profile-shift/solid-assembly pipeline, unrelated to spiral bevel at all. Needs a phase-search/probe at build time (replacing the fixed `±π/2` convention) plus a calibrated tangential margin proxy before real implementation - see the doc's own 2026-08-21 "Spike findings" entries (both dated the same day, Spike A then Spike B) |
| 13 | `13-spiral-bevel-pair.md` | 12 | High - **Spike A's result applied**: hand-of-spiral compatibility confirmed physically necessary, radial mesh-margin math confirmed to survive unchanged (now provably, not just plausibly), a new tangential margin proxy confirmed *required* (not speculative); Spike B (12's own 2026-08-21 entry) additionally found a real, pre-existing profile-shift/solid-assembly defect for extreme tooth-count-ratio pairs - a straight-bevel pairing-system bug this workstream surfaced but doesn't own fixing - see the doc's own 2026-08-21 "Spike findings" |

Spiral/Zerol bevel (gear and pair both) is scoped in `12-spiral-bevel-
gear.md`/`13-spiral-bevel-pair.md`. Both of that doc's own spikes have now
run (2026-08-21, Spike A then Spike B) - real implementation hasn't
started, and still can't: still NO-GO on the current fixed-phase
construction as-is (a real, catastrophic-overlap notch exists at a
geometry-dependent spiral angle with no warning today), but Spike B
root-caused both of Spike A's own previously-uncharacterized breakdowns
and found neither is a flank fold - the "Spike B (fold-risk)" framing
`12-spiral-bevel-gear.md` itself set up turned out to be aimed at the
wrong mechanism. What's left is concrete: replace the fixed meshing-phase
convention with a per-build search/probe, and build the calibrated
tangential margin proxy - not open-ended surface-quality risk anymore.
Hypoid bevel remains unscoped, a separate, even-further-later phase
(offset, non-intersecting axes — a bigger leap again than spiral/Zerol).

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
11. **Workstream 12 (spiral/Zerol bevel gear)** — separate phase, after the
    above; scoped in `12-spiral-bevel-gear.md`. Spike A run (2026-08-21,
    NO-GO on "conjugate by construction" for the originally-proposed
    formula; a corrected construction exists but needs a calibrated
    tangential margin proxy) - a still-unrun Spike B (fold-risk at high
    spiral angle/extreme tooth-count ratios) is next, before real
    implementation.
12. **Workstream 13 (spiral/Zerol bevel pair)** once 12's own remaining
    spike work lands — scoped in `13-spiral-bevel-pair.md`, mirrors how
    Workstream 11 depended on Workstream 10; its own share of Spike A
    (hand-of-spiral, radial-margin carryover) is already done.
13. **Hypoid bevel** — still unscoped, later again than Workstream 13.

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
