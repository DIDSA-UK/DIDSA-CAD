# Workstream 2 — DXF export: Sketch and Face

Read `00-conventions.md` first — especially "Export capabilities" and
"Units"/"Export: raw geometry only".

## One writer, two callers

New backend dependency: `ezdxf`. One writer module taking a flat list of
2D primitives (points/lines/arcs/circles/ellipses/splines/text, all in one
common local frame) and producing DXF bytes with an explicit `$INSUNITS`
header (mm). Both entry points below produce that same flat primitive list
from different sources, then hand off to the one writer — don't write two
writers.

### Export Sketch

Straightforward: walk a `Sketch`'s own `points`/`entities` (Lines, Arcs,
Circles, Ellipses, Splines, Text — the same entity set `00-conventions.md`
already scopes for import) and emit the corresponding DXF entity for each
(LWPOLYLINE for sampled curves or SPLINE directly if `ezdxf`'s spline
entity is preferred over polyline sampling — decide during
implementation, either is acceptable per this doc's own "raw geometry"
scope). A `SketchImportedBlockInstance`'s own *expanded* ghost geometry
(`01-dxf-import-block.md`) should export too, at its current world
position — a re-exported block is just more geometry, no special-casing
needed at the writer level.

### Export Face

New: any Body's own planar face, flattened to DXF via that face's real
local 2D frame. `plane_geometry.world_point_to_basis(basis: ResolvedPlane,
point) -> (x, y)` already exists and already does exactly the projection
needed (used today by `create_plane.py`/Convert Entities' own
`convert_body_edge`/`convert_body_vertex` for the identical "materialize a
Body's own 3D geometry into a 2D-ish representation" problem) — resolve
the target face's own plane as a `ResolvedPlane` (reuse whatever this
codebase already does to get a `ResolvedPlane` for an arbitrary picked
planar face, not just the three fixed reference planes), walk its
boundary wire's edges, sample each into local `(x, y)` via
`world_point_to_basis`, hand the result to the same writer Export Sketch
uses. Works for any planar face regardless of orientation — not just
Sketch-originated ones — since it goes through a real local-basis
resolution rather than a naive 3D-to-2D projection that could distort a
non-axis-aligned face.

**A face with holes** (an internal gear's own annulus face, or any Cut-
created hole) needs its inner wire loops emitted too, not just the outer
boundary — the DXF equivalent of what `face_for_profile`/`_gear_face`
already do when *building* such a face from a profile, just the reverse
direction.

## Client entry points

- **`SketchScreen`** (one shared component per `00-conventions.md` — both
  contexts get this for free from one implementation): an "Export DXF"
  action alongside the existing local file Save/Open.
- **`PartScreen`**: an "Export Face" action reachable from face selection
  (the same `SelectionEntityKind.face` picking Boss/Cut target-body
  selection already establishes as a UI pattern) — pick a face, export it.

## Complexity/risk

Low-medium. `ezdxf` writing is mature and well-documented; the real work
is Export Face's own boundary-wire-walk-plus-hole-handling, which has
strong existing precedent to lean on (`world_point_to_basis`, Convert
Entities' own edge materialization, `face_for_profile`'s inner-loop
handling in the opposite direction) rather than being genuinely new
technique the way `docs/gear-design/`'s highest-risk workstreams were.
