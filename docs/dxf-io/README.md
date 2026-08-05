# DXF Import/Export

A general capability of the 2D Sketcher and 3D Part Design tools — import
an externally-drawn DXF as a positionable, constrainable "block" inside a
Sketch; export any Sketch or any Body's planar face to DXF. Not gear-
specific — see `00-conventions.md` for why this moved out of
`docs/gear-design/` (it was Workstreams 6/7 there; that motivation is now
dead) and what it kept from the old design.

**Status: not started.** Scoped only — this README, `00-conventions.md`,
and the three workstream files below are the product of a scoping
conversation, no implementation exists yet.

## How to use these docs in a fresh implementation session

**Read `00-conventions.md` first, always** — it holds every fact/decision
referenced by 2+ workstreams (why this isn't gear-specific, DXF-only/no
DWG, units, entity coverage, the block mechanism and its positioning, the
export split). Workstream files don't repeat it.

Then read **only the one workstream file you're implementing**, plus
whatever it names as a dependency.

## Workstreams

| # | File | Depends on | Risk |
|---|------|-----------|------|
| 1 | `01-dxf-import-block.md` | — | Medium-high |
| 2 | `02-dxf-export.md` | — | Low-medium |
| 3 | `03-gear-chain-schematic-export.md` | 2, `docs/gear-design/05-gear-chain-and-planetary.md` | Low |

## Delivery order

1. **Workstream 2 (export) first** — lower risk, no new Sketch-model
   mechanism, and Workstream 1's own "promote one ghost curve to a real
   entity" open question benefits from Export Face already existing as a
   worked example of resolving a real face/local-frame to 2D geometry.
2. **Workstream 1 (import block)** — the larger piece; owns the one
   genuinely new Sketch-model mechanism (`SketchImportedBlockInstance`)
   plus the open promotion-mechanism question `00-conventions.md` flags.
3. **Workstream 3 (gear-chain schematic export)** once 2 is live — thin,
   depends on Export Face's own per-face logic plus
   `GearChainFeature`/`PlanetaryGearFeature`'s already-resolved stage
   positions (both real, already built).

## Key decisions carried through every workstream (don't re-litigate)

- DXF only — DWG is out of scope (no viable open-source writer/reader).
- Units: mm assumed on import, no unit picker — correction happens via the
  block's own handle-point distance constraint.
- Export is raw geometry only — no dimensions/annotations (this app has no
  drafting/annotation system at all yet).
- The imported block is ghost geometry inside a Sketch (not a separate
  wireframe Body/`ImportFeature` the way the original Workstream 7 design
  had it), positioned via two real, solver-participating Points (anchor +
  handle) and a construction Line between them — not a plain numeric
  transform.
- One shared `ezdxf` writer for both Export Sketch and Export Face — no
  gear-specific export code anywhere. Per-gear/per-chain-member export is
  just Export Face on that member's own flat face.
- Bevel flat-pattern DXF export is out of scope, not deferred — no flat
  face exists for a bevel tooth's curved flank under this model.
