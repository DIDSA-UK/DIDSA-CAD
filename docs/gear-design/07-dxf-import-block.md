# Workstream 7 — DXF import with block semantics (MOVED, no longer a Gear Design workstream)

**This workstream moved to `docs/dxf-io/`.** Retired here deliberately
rather than deleted, so the history of why stays discoverable.

Originally scoped as a Gear Design workstream even though it never
actually depended on any gear-specific Feature type — the "why" section
below is superseded, but the reuse research itself (Convert Entities,
`SelectionEntityKind.body`, the audit of this codebase's own selection
architecture) fed directly into the new design.

See `docs/dxf-io/00-conventions.md` ("The imported block") and
`docs/dxf-io/01-dxf-import-block.md` for the current scope. The mechanism
changed materially, not just the location: DXF import now lands **inside
the active Sketch** as ghost geometry positioned by two real,
constraint-participating Points and a construction Line (reusing the
*pattern* `SketchPatternInstance`/`SketchMirrorInstance` establish, not
their data model) — not as a separate wireframe reference `Body`/
`ImportFeature` selected as one opaque block the way this file originally
specified. The "select as one, individually pickable via Convert Entities"
goal survives, but Convert Entities' own applicability to this new
mechanism is now flagged as an open question in the new location, not an
already-resolved reuse.
