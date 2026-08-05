# Workstream 1 — DXF import as a positionable Sketch block

Read `00-conventions.md` first — especially "The imported block: ghost
geometry, not a new Body, not literal Pattern/Mirror reuse" and "Block
positioning" before writing any code here; this workstream implements
both.

## Backend: parse, don't place

New backend dependency: `ezdxf`. A new endpoint parses an uploaded DXF
file into a flat list of local-frame 2D primitives (points/lines/arcs/
circles/ellipses/splines, decomposing polylines into lines) plus a list of
skip warnings for unsupported entity types (`00-conventions.md`'s entity-
coverage convention) — this endpoint does **not** decide placement at all,
it just hands back parsed geometry for the client to instantiate as a
block. Mirrors `app.document.mesh_import`/`import_geometry`'s own
OCCT-free-parse-vs-construction split in spirit, though this is pure 2D
and never touches OCCT at all.

## Sketch model: `SketchImportedBlockInstance`

New dataclass in `app/sketch/models.py`, alongside (but structurally
distinct from, per `00-conventions.md`) `SketchPatternInstance`/
`SketchMirrorInstance`:

```python
@dataclass
class SketchImportedBlockInstance:
    id: str
    local_geometry: list[ImportedCurve]  # static, parsed once at import time
    anchor_point_id: str                  # real Sketch Point - translation
    handle_point_id: str                  # real Sketch Point - scale+rotation
    connecting_line_id: str               # construction Line, anchor->handle
```

`local_geometry` is the DXF's own parsed curves in their original local
frame (unchanged after import) — never mutated. Every expansion re-derives
world-space geometry from `local_geometry` transformed by the current
solved positions of `anchor_point_id`/`handle_point_id`, the same
never-materialize-into-real-entities principle
`Sketch.expand_pattern_and_mirror_instances` already established for
Pattern/Mirror — extend that function (or add a sibling) to also expand
`SketchImportedBlockInstance`s each call.

**Transform derivation**: translation = anchor point's own `(x, y)`;
scale = `distance(anchor, handle) / reference_distance` (the distance at
import time, captured once so the block starts at 1:1 scale); rotation =
`angle(handle - anchor) - reference_angle` (captured the same way).

**Creation flow**: importing a DXF creates one `SketchImportedBlockInstance`
plus its two backing `Point`s (placed at a sensible default offset from
each other, e.g. distance = the parsed geometry's own bounding-box
diagonal / 10, so the initial scale reads as 1:1) and one construction
`Line` between them — all ordinary `Sketch.points`/`Sketch.entities`
additions, nothing special about how they're created even though what
they drive is special.

## Client: rendering, selection, placement

- Render each block's expanded ghost geometry the same visual treatment
  Pattern/Mirror ghosts already get (see `sketch_canvas.dart`'s existing
  ghost-instance rendering) — plus the anchor/handle points and connecting
  construction line rendered as ordinary (if construction-styled) sketch
  geometry, since they're real entities.
- Tapping anywhere on the block's ghost geometry selects the whole
  `SketchImportedBlockInstance` as one unit (mirrors Pattern/Mirror's own
  `_patternMirrorEntityAt`/`hitTestSketchPatternMirrorInstances` precedent,
  `client/lib/viewport3d/selection_hit_test.dart`) — dragging the anchor/
  handle points individually still works normally, exactly like dragging
  any other Point drives whatever depends on it.
- A small placement panel (or just relying on the constraint toolbar
  against the anchor/handle points/connecting line directly - decide
  during implementation) is how a user actually dimensions position/scale/
  rotation against other sketch geometry, per `00-conventions.md`'s "full
  solver participation" decision.

## Open question this workstream must resolve, not inherit an assumed answer for

**Promoting one ghost curve to a real, independently-editable entity.**
`00-conventions.md` flags this explicitly: Convert Entities as it exists
today is Body-edge-to-Sketch, not Sketch-ghost-to-Sketch-real. Options to
weigh here (not a decided list):
- A new client-side "detach" action on a tapped ghost curve within a
  block, creating a real `Line`/`Arc`/`Circle`/etc. at that curve's
  current expanded world position, with no ongoing link back to the block.
- Extending Convert Entities' own backend endpoint to also accept a
  `(block_instance_id, local_geometry_index)` reference, not just a
  `(body_id, edge_index)` one - reuses the existing UI entry point/mental
  model, more backend plumbing.
- Deciding detachment isn't needed for v1 at all - the block stays a
  block, full stop, and anything requiring individual editable curves goes
  through a different construction (e.g. Extrude the block's own outer
  profile as a whole, then Sketch a new profile from scratch referencing
  the resulting Body's edges via the existing external-reference
  mechanism). Cheapest, but check this doesn't undercut the "trace a DXF
  profile then edit it" use case DXF import is partly for.

Resolve this with real reasoning before writing the client-side detach
mechanism (if any), don't default to the first option just because it's
listed first here.

## Complexity/risk

Medium-high. The DXF parsing itself is comparatively straightforward
(`ezdxf`'s reader). The real cost is `SketchImportedBlockInstance`'s own
new expand/render/hit-test machinery (genuinely new, even though it
follows Pattern/Mirror's established pattern) and the open promotion
question above, which has no existing precedent to lean on either way.
