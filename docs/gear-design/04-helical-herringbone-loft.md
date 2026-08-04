# Workstream 4 — Helical/herringbone gears + general `LoftFeature`

Read `00-conventions.md` first. Depends on Workstream 2 (`GearFeature`
profile-building) and, for the Loft path specifically, is itself a
prerequisite spike (see delivery order in `README.md`) before committing.

## 4a — Helical/herringbone teeth: two viable OCCT techniques

Decide which during implementation, based on the 4b spike below:

- **Sweep the 2D tooth profile along a helical path** — geometrically the
  *correct* way to generate a true constant-lead helical tooth surface
  (what real CAD/manufacturing tools do), more accurate than a loft
  (which only interpolates a ruled/smooth surface *between* two end
  cross-sections). Requires extending `SweepFeature`'s path concept,
  since its `path_refs` today only accepts a picked chain of existing
  Sketch Lines/Arcs/Ellipses/Splines, not a procedurally generated helix
  curve.
- **Loft between two profile copies, rotated relative to each other by
  the helix's twist angle** — simpler, an approximation (the surface
  between two lofted cross-sections isn't exactly a helicoid).

**Recommendation**: build the general Loft feature (4b) regardless — it's
independently useful — but implement helical teeth via the
sweep-along-helix technique for correctness, falling back to Loft if the
helix-sweep spike proves too costly.

**Herringbone** = two opposite-handed helical halves joined at the gear's
mid-plane (mirrored, not simply "twice as tall").

## 4b — General `LoftFeature`

A genuinely new, standalone Feature (not gear-specific — same
"useful on its own" status Sweep already has): lofts between 2+ Sketch
profiles via `BRepOffsetAPI_ThruSections`, with user-selectable start/end
reference points per profile to control twist. OCCT doesn't expose "pick
a vertex to align" directly — achieving it means reordering each
profile's own wire edge-traversal start to begin at the user-chosen point
before feeding wires to `ThruSections`, and matching winding direction
across profiles.

**Spike this early**, before committing gear teeth to depend on it — new
OCCT usage in this codebase, real correctness risk (self-intersecting
lofts/sweeps at high twist angles, wire-orientation mismatches).

## Complexity/risk

High. Both paths are genuinely new OCCT techniques for this codebase.
Budget real spike time before committing to an approach.
