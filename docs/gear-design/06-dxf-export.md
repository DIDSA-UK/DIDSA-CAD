# Workstream 6 — DXF export

Read `00-conventions.md` first. Depends on Workstream 1 (gear profile
points) and, for multi-gear exports, Workstream 5. Shared with the
existing, separately-roadmapped "2D Drawing" tool's own unstarted DXF
export ask (`docs/roadmap.md`) — build one `ezdxf`-based writer, not two.

## Scope

New backend dependency: `ezdxf`. New writer consuming either a gear's own
profile points (Workstream 1, bypassing the Sketch model entirely — the
profile never needs to become interactive Sketch geometry to be exported)
or a general Sketch's Points/Lines/Arcs/Circles/Ellipses/Splines/Text
(satisfies the "2D Drawing" tool's own DXF export ask with the same
writer).

Two export shapes for a `GearChainFeature`/`PlanetaryGearFeature`:

- **Per-gear cut files** — one DXF per gear (matches how a gear is
  actually cut/printed/used downstream), returned as a zip or multiple
  endpoint calls.
- **Combined layout export** — every gear in the system in one DXF, each
  at its real relative position/rotation (the positions
  `GearChainFeature`/`PlanetaryGearFeature` already compute), for a
  reference/assembly drawing rather than cutting. Cheap — placement, not
  new geometry.

**Unresolved, decide here, don't assume** (flagged in
`05-gear-chain-and-planetary.md`): a compound station's two members sit
at different depths along the shaft, not the same 2D plane — likely two
separate per-member DXF files even when the 3D solid is fused. Also
unresolved: a bevel gear (`10-bevel-gear.md`) has no flat 2D profile at
all — likely a flat-pattern/development of the back-cone tooth profile
(a standard bevel-drafting technique), itself new geometry work.

DWG is out of scope (proprietary format, no viable open-source writer) —
already the conclusion for the separate 2D Drawing tool's own roadmap
entry.

## Complexity/risk

Low-medium. `ezdxf` is mature and well-documented; the main work is a
clean mapping from this app's entity model to DXF entities (LWPOLYLINE
for sampled involute curves, or SPLINE if `ezdxf`'s spline entity is
preferred over polyline sampling; ARC/LINE/CIRCLE directly), plus units
(`$INSUNITS` header — this app's geometry is implicitly mm throughout,
state it explicitly rather than assume the importing tool knows).
