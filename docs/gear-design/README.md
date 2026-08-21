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

**Status: complete, backend and client**, for straight bevel and every
other v1-scoped gear type. Workstreams 1, 2, 3, 4, 5, 10, 11 (gear math
core, `GearFeature`, `RackFeature`, helical/herringbone teeth + general
`LoftFeature`, `GearChainFeature`/`PlanetaryGearFeature`/`GearGroup`,
`BevelGearFeature`, `BevelPairFeature`) are all done. Workstream 8's entry
screen + 2D preview covers external/internal/rack (v1), helical/herringbone
teeth (`GearFeature` fields on the existing External/Internal form),
chain/planetary (`GearChainDesignScreen` - stage-list editor, multi-gear
preview with interference highlighting and `GearGroup` colour-coding,
ratio/rotation-direction display), and bevel/bevel-pair (`BevelDesignScreen`
- the axial-cross-section schematic preview a bevel tooth's lack of a flat
2D profile calls for, dual-axis for a pair). Workstream 9 (presets) is done
too - `GearPresetStore` (client-local, `shared_preferences`-backed) plus a
shared `GearPresetControls` widget ("Save as preset"/"Load preset") on all
three Gear Design screens. See `docs/status.md`'s dated entries for the
full rollout history.

**Spiral bevel (Workstream 12/13) is a separate, later phase, single-gear
half now also done**: `BevelGearFeature`'s own spiral variant
(`spiral_angle_degrees`/`spiral_hand`, `BevelDesignScreen`'s "Spiral"
toggle) is real, shipped code, built directly against three real spikes'
own findings - see `12-spiral-bevel-gear.md`'s own status note.
`BevelPairFeature`'s spiral variant (Workstream 13) has not started.

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
| 12 | `12-spiral-bevel-gear.md` | 10 | Highest in project (harder than 10) - **single-gear variant done, incl. client UI**. Three spikes ran first (2026-08-21, Spike A then B then C - see the doc's own "Spike findings" entries for the full mesh-correctness/fold-risk/meshing-phase investigation), then real implementation landed on top of their findings: `BevelGearFeature.spiral_angle_degrees`/`spiral_hand` (`app.document.bevel_math.bevel_tooth_flank_sections` - N-section, default 3, layered-offset construction; `app.document.bevel._assemble_gear_solid` extended with a real N-section OCCT path, `0.0` a verified literal no-op reproducing the exact straight-bevel construction); `BevelDesignScreen`'s "Spiral" toggle (mirrors `crown`'s own UI-variant precedent). The meshing-phase search Spike C designed is deliberately NOT part of this workstream - it's pairing-only, no counterpart for a standalone gear. `BevelPairFeature`'s own spiral variant remains the next, not-yet-started workstream - see Workstream 13's own entry |
| 13 | `13-spiral-bevel-pair.md` | 12 | High - **Spike A/B/C's results applied, real GO**: hand-of-spiral compatibility confirmed physically necessary (a simple field-compatibility warning, not a margin computation); radial mesh-margin math confirmed to survive unchanged (provably); the tangential margin proxy Spike A/B thought was *required* was revised by Spike C's own broader tooth-count-ratio testing to **not needed at all** - the residual both prior spikes measured turned out to be mostly a pre-existing, non-spiral limitation of equal-tooth-count pairs (real, already accurately warned-of in shipped `BevelPairFeature` today, flagged for a future fix but out of this workstream's own scope), not a genuine spiral effect; once tested on a resolvable tooth-count ratio, real measured overlap is exactly zero at every spiral angle tested. Spike B's own separate, silent solid-malformation defect (a different, steep-tooth-ratio case) has been fixed - see the doc's own three 2026-08-21 "Spike findings" entries |

Spiral/Zerol bevel gear/pair are scoped in `12-spiral-bevel-gear.md`/
`13-spiral-bevel-pair.md`. The single-gear half is now real, shipped code -
`BevelGearFeature.spiral_angle_degrees`/`spiral_hand`, built directly on
top of three real spikes (2026-08-21, Spike A then B then C): Spike A's
own "corrected construction" (a rigid per-radius azimuthal rotation layered
on the existing straight-bevel Tredgold flank, same sign on both flanks);
Spike B's finding that neither of Spike A's two uncharacterized breakdowns
is a flank fold (both are pairing-only concerns - a fixed meshing-phase
artifact and an unrelated, since-fixed straight-bevel profile-shift
defect); Spike C's per-build phase-search design (also pairing-only, so
deliberately not built here) and its "3 sections is sufficient" convergence
finding (re-validated for the real implementation, not just assumed). The
pairing half (`BevelPairFeature`'s own spiral variant, needing Spike C's
meshing-phase search) has not started. Hypoid bevel remains unscoped, a
separate, even-further-later phase (offset, non-intersecting axes — a
bigger leap again than spiral/Zerol).

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
11. **Workstream 12 (spiral/Zerol bevel gear) — single-gear variant done.**
    Scoped in `12-spiral-bevel-gear.md`. Three spikes ran first
    (2026-08-21, Spike A then Spike B then Spike C): Spike A found NO-GO on
    "conjugate by construction" for the originally-proposed formula, but a
    corrected construction close-but-not-exact; Spike B root-caused Spike
    A's own two uncharacterized breakdowns - neither is a flank fold; the
    high-spiral-angle one is a fixed meshing-phase-convention artifact
    (pairing-only), the tooth-ratio one an unrelated, pre-existing,
    non-spiral `resolve_member_profile_shifts` defect (since fixed); Spike
    C designed and validated a real per-build phase search fixing the
    phase artifact (pairing-only, GO with a flagged cost risk near the
    notch), and found the tangential margin proxy Spike A/B thought was
    required isn't. Real implementation then landed on top: `bevel_math.
    bevel_tooth_flank_sections` (N-section layered-offset construction,
    default 3 sections, bit-for-bit reduces to the straight-bevel case at
    `spiral_angle_degrees=0.0`), `bevel._assemble_gear_solid`'s own real
    N-section OCCT path, `BevelGearFeature.spiral_angle_degrees`/
    `spiral_hand` end to end, `BevelDesignScreen`'s "Spiral" toggle. The
    meshing-phase search (Spike C) is deliberately NOT part of this
    workstream - pairing-only, no counterpart for a standalone gear.
12. **Workstream 13 (spiral/Zerol bevel pair)** now that 12's single-gear
    variant has landed — scoped in `13-spiral-bevel-pair.md`, mirrors how
    Workstream 11 depended on Workstream 10's own real implementation, not
    just its spike. Its own share of Spike A (hand-of-spiral, radial-margin
    carryover) and Spike C (tangential margin proxy - resolved as "not
    needed"; the meshing-phase search itself - real, designed, validated,
    but not yet wired into a real `BevelPairFeature` build) are already
    done at the spike level; not yet started as real implementation.
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
