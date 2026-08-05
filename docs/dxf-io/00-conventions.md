# DXF Import/Export — Shared Conventions

Read this before implementing **any** workstream. It holds facts and
resolved decisions referenced by two or more workstreams; each workstream's
own file holds only what's specific to it. Don't duplicate this content
into a workstream file — link back here.

## Why this exists, and why it isn't a Gear Design workstream anymore

This was originally scoped as Workstreams 6/7 inside `docs/gear-design/`
(`06-dxf-export.md`/`07-dxf-import-block.md`), motivated by a "design a
gear, export DXF, reimport into a 3D Part, extrude/loft it" round-trip.
That motivation is dead — `GearFeature`/`RackFeature`/`GearChainFeature`/
`PlanetaryGearFeature`/`BevelGearFeature`/`BevelPairFeature` all already
build real solids directly, no DXF round-trip needed or wanted (see
`docs/gear-design/00-conventions.md`'s own "gear teeth are not Sketch
entities" decision, which this doesn't reopen).

DXF import/export survives as a **general** capability of the 2D Sketcher
and 3D Part Design tools — general mechanical drawing exchange, cutting
files for flat parts (laser/waterjet/plasma), and importing externally-
drawn 2D profiles (shafts, housings, brackets) to build on. Gear Design
becomes one thin *consumer* of this general capability (see
`03-gear-chain-schematic-export.md`), not the reason it exists.

Backend: `backend/app/document/*`, `backend/app/sketch/*`. Client:
`client/lib/sketch/sketch_screen.dart` — confirmed to be **one shared
component** reached both standalone (`ToolChooserScreen`'s "2D Drawing"
tile, `standalone: true`) and from `PartScreen`'s own "New Sketch" flow.
Import/export UI built once here serves both entry points automatically —
don't build two integration points.

## DXF only — DWG is out of scope

`ezdxf` (the planned library, mature and well-documented) does not read or
write DWG. A real DWG writer/reader needs either a proprietary SDK (Open
Design Alliance) or a paid converter dependency — not worth it. Confirmed
decision, not still open: DXF only, in both directions.

## Units: mm assumed, correction is the solver's job, not a picker

This app is implicitly all-mm throughout, and a DXF file's own `$INSUNITS`
header is unreliable (frequently missing entirely on hand-exported files).
Import assumes mm — no separate "what unit was this drawn in" prompt.
Correcting a mis-scaled import is the handle-point's own distance-from-
anchor value (see "Block positioning" below) — the user dimensions the
block against known real-world geometry, which fixes scale regardless of
what the file claimed. Export writes an explicit `$INSUNITS` header stating
mm, rather than assuming the importing tool guesses correctly.

## Import entity coverage: skip unsupported types with a warning, don't fail

Only entity types this app's Sketch model already has: Lines, Arcs,
Circles, Ellipses, Polylines (decomposed to Lines), Splines. Anything else
`ezdxf`'s reader hands back (TEXT beyond this app's own `TextEntity` shape,
HATCH, DIMENSION, nested `INSERT` blocks, layer/color metadata this app
has no concept of) is skipped with a non-blocking warning banner — matches
`docs/gear-design/00-conventions.md`'s own non-blocking-validation-banner
convention — never a hard failure of the whole import.

## Export: raw geometry only, no annotations

This app has no drafting/annotation system anywhere yet (`docs/roadmap.md`'s
own "2D Drawing tool follow-ups" section: "no units/scale, no layers, no
sheets/paper size, no annotation beyond the existing Text entity - all
absent"). DXF export writes geometry entities only (LWPOLYLINE for sampled
curves or SPLINE directly, ARC/LINE/CIRCLE, TEXT for this app's own
`TextEntity`) — not a fully-annotated technical drawing. That's the
expected ceiling for this scope, not an oversight to fix here.

## The imported "block": ghost geometry, not a new Body, not literal Pattern/Mirror reuse

A DXF import lands **inside the active Sketch** as a positionable "block" —
not as a separate wireframe reference `Body`/`ImportFeature` the way the
original Workstream 7 design had it (that design is superseded).

**Mechanism, precisely** — this is *not* a straight reuse of
`SketchPatternInstance`/`SketchMirrorInstance` (`app/sketch/models.py`).
Both of those require `source_entity_ids` pointing at a real,
already-existing Sketch entity as their generator, expanded transiently by
`Sketch.expand_pattern_and_mirror_instances` and never materialized into
`Sketch.points`/`Sketch.entities`. A DXF import has no such generator —
every imported curve comes from an external file; none of them is "the
original" the way Pattern's own source entity is. What's actually reused is
the *pattern* those two establish (ghost/derived geometry grouped under one
owner id, expanded transiently, never entering the solver as real points) —
not their data model. This needs a new instance type (sketched in
`01-dxf-import-block.md` as `SketchImportedBlockInstance`) holding its own
static local-frame geometry, parsed once at import time from the DXF file
and stored directly, transformed by the two control points below on every
expansion.

## Block positioning: full solver participation via two real Points + a construction Line

Not a plain numeric transform. Two real, ordinary Sketch `Point`s back the
block's placement:

- **Anchor point** — the block's translation. A real, independently
  constrainable `Point` (`DistanceConstraint`/`CoincidentConstraint`/etc.
  against other sketch geometry all apply normally).
- **Handle point** — a second real `Point`. Its distance from the anchor
  sets the block's uniform scale; its angle from the anchor sets rotation.
  Both are constrainable the same way (`DistanceConstraint` for scale,
  `AngleConstraint` for rotation).
- **Construction `Line`** connecting them — an ordinary `Line` with
  `construction=True` (already a first-class, fully-constrainable entity;
  no new mechanism needed for the line itself). The line itself is also a
  valid constraint target (`LineDistanceConstraint`/`ParallelConstraint`/
  `PerpendicularConstraint`/`EqualLengthConstraint`, etc. — see
  `native_format.py`'s `_CONSTRAINT_CLASSES` for the full existing set).

Only these two points (and the construction line between them) are real
solver entities. Every other vertex in the imported DXF stays ghost
geometry, rigidly transformed off the anchor/handle pair on every
expansion — this is what avoids reintroducing this app's known
"associative point drag snaps back on next solve" gap while still letting
position/rotation/scale genuinely participate in constraints.

**Open question, not resolved here — see `01-dxf-import-block.md`**: how
one individual ghost curve inside a block gets promoted to a real,
independently-editable Sketch entity. Convert Entities as it exists today
(`convert_body_edge`/`convert_body_vertex`) is Body-edge-to-Sketch
specifically — a document-layer mechanism, structurally separate from a
Sketch-internal ghost instance. There is no existing "promote one Pattern/
Mirror ghost instance to a real entity" mechanism to point at either. This
needs its own small design decision during implementation, not an assumed
answer.

## Cross-sketch reuse: the existing external-reference mechanism, no new case

"Bring in entities from an earlier DXF-derived sketch to start a shaft/
housing" reuses the **already-built** `ExternalVertexReference`/
`ExternalEdgeReference` mechanism (Sketcher-roadmap Phase 4.3) — no new
Sketch-to-Sketch reference case. The natural flow: the first Sketch (DXF
block, traced/positioned) is consumed by an ordinary Extrude/Revolve into a
real Body; a later Sketch (for the shaft/housing) references *that Body's*
vertices/edges via the existing mechanism, exactly like referencing any
other Body's geometry today. No synthetic/thin placeholder Body needed —
the first sketch producing a real Body is the common case, not a workaround.

## Export capabilities: one writer, two entry points, zero gear-specific code

- **Export Sketch** — any Sketch's own entities to DXF. Reachable from
  `SketchScreen` in both its contexts (standalone 2D Drawing, or Part
  Design's own sketch-editing).
- **Export Face** — any Body's own planar face, flattened to DXF via that
  face's real local 2D frame (reuses the same `ResolvedPlane`/local-basis
  machinery `plane_ref`-anchored Features already use elsewhere in this
  codebase — not a naive 3D-to-2D projection that could distort a non-
  axis-aligned face).

Both share **one** `ezdxf`-based writer (per the original doc's own "build
one writer, not two" instruction — even more clearly correct now that
gear-specific writing isn't a separate need at all).

**Direct consequence for Gear Design**: per-gear/per-chain-member DXF
export needs **zero gear-specific code**. Every gear-family solid
(external/internal/rack/helical/chain-member/planetary-member/bevel-pair-
member) already has a flat end face that *is* the cutting profile, because
they're all built by extruding a flat profile. Export Face already covers
it. The old design (reading `gear_math`'s own stored profile points
directly, bypassing the Sketch model) is dropped entirely — it's now
strictly worse than just picking a face.

Two things this also resolves, not just defers:

- **Compound-station DXF** (`docs/gear-design/05-gear-chain-and-planetary.md`'s
  own flagged unknown — two members at different depths along the shaft):
  dissolved. Each member already has its own face; export whichever one is
  picked. No special-casing needed.
- **Bevel flat-pattern DXF** (`docs/gear-design/11-bevel-pair.md`'s own
  flagged unknown): dropped from scope entirely, not deferred. A bevel
  tooth's flank is a curved 3D spherical-involute surface — there is no
  flat face to select at all under this model. Cone flat-pattern
  development (an "unroll the cone" transform) would be a wholly separate,
  unrelated feature if ever wanted later, sharing nothing with Export Face.

## Gear-chain schematic export: the one place this still needs gear-design awareness

`GearChainFeature`/`PlanetaryGearFeature`'s own combined-layout export
(every member in one DXF at real relative positions) is the one export
shape that can't be "just Export Face" — it needs the chain's own resolved
stage positions. Scoped as a **schematic**: real 2D tooth geometry (via the
same per-member face logic Export Face uses) for whichever stages are
genuinely coplanar/in-plane; any compound-station member or anything that
would require out-of-plane depth to represent correctly is **omitted from
the drawing entirely**, not drawn wrong and not placeholder'd. See
`03-gear-chain-schematic-export.md`.
