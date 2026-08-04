# Gear Design Tool — Shared Conventions

Read this before implementing **any** workstream. It holds facts and
resolved decisions referenced by two or more workstreams; each workstream's
own file holds only what's specific to it. Don't duplicate this content
into a workstream file — link back here.

Backend: `backend/app/document/*` (FastAPI + pythonocc-core/OCCT),
`backend/app/sketch/*` (Sketch model). Client: `client/lib/viewport3d/*`,
`client/lib/sketch/*`, `client/lib/tool_chooser_screen.dart`.

## The Feature-tree checklist

Every gear-producing Feature type is one more entry in this codebase's
existing pattern — not a new architecture. Every concrete `Feature`
subclass (`SketchFeature`, `ExtrudeFeature`, `RevolveFeature`,
`SweepFeature`, `FilletFeature`, `ChamferFeature`, `MirrorFeature`,
`PatternFeature`, `CreatePlaneFeature`, `ImportFeature` — all in
`backend/app/document/models.py`) follows the same six parts:

1. A `@dataclass` subclass of `Feature` with `id`, a `type` property,
   `produces_solid_geometry: bool`, `produces: Produces`.
2. A `depends_on` branch in `build_feature_graph` (`graph.py`).
3. A geometry module with `resolve_X_from_bodies(bodies, feature)` (core —
   takes already-computed `bodies`, never recomputes itself) /
   `resolve_X(part, feature, excluded_feature_ids=frozenset())` (wrapper —
   self-excluding, calls `compute_part_bodies` fresh).
4. A branch inside `compute_part_bodies`'s topological loop (`extrude.py`).
5. Pydantic Create/Update/Response schemas in `schemas.py`.
6. Router endpoints (create/update/get-or-404).

Recompute is a full graph walk every time (`compute_part_bodies`,
`topological_order`) — no dirty-flag incremental recompute anywhere,
"re-derive, don't cache." This is what makes `GearChainFeature`/
`PlanetaryGearFeature`/`BevelPairFeature` (multiple Bodies from one
Feature, live-editable) work for free — same mechanism `PatternFeature`/
`MirrorFeature` already use.

## Gear teeth are not Sketch entities

The Sketch model (Line, Circle, Arc, Ellipse, Polygon, Slot, Rectangle,
Spline, Text) has no involute curve type, and should not gain one. `Spline`
is solver-backed (`py-slvs`, real constraint entities per through-point,
built for live dragging) — a single gear profile needs ~10-20 sampled
points per flank × 2 flanks × N teeth, hundreds of solver entities
re-solved on every drag, for no benefit (nobody drags individual points on
a gear tooth). Precedent for avoiding this: `TextEntity` realizes glyph
outlines directly as OCCT geometry (`text_to_brep`), never as
constraint-solved Sketch entities. Every gear Feature follows the same
pattern — profile built directly from parameters, not through
`py-slvs`/the interactive Sketch model.

## OCCT-free / OCCT-dependent module split

Every gear Feature type splits its math into two files: `*_math.py`
(pure Python, zero OCCT dependency — unit-testable in this repo's dev
sandbox, which has never had `pythonocc-core` installed) and the OCCT
construction itself (only verifiable in real CI, which does have OCCT).
Mirrors `app.document.mesh_import` vs `app.document.import_geometry`, and
`app.document.sweep`'s own path-resolution-vs-construction split.

## Tooth flank curve: real `Geom_BSplineCurve`, not a polyline

Every involute/spherical-involute tooth flank is one real
`Geom_BSplineCurve` interpolated through sampled points (`GeomAPI_
Interpolate`), never a dense polyline of straight edges. This is the only
choice that keeps STEP export genuinely smooth:

- **STEP export** (`step_export.py`, writes the Body's real BRep directly)
  carries the exact flank curve.
- **STL/OBJ/glTF and the 3D viewport** all tessellate through
  `app/document/mesh.py`'s `BRepMesh_IncrementalMesh`
  (`MeshQuality.linear_deflection`/`angular_deflection`) — always faceted,
  because those formats have no curve concept (true of every solid
  modeler, not a gap here). `DEFAULT_MESH_QUALITY`'s `linear_deflection =
  0.5` (`mesh_data.py`) is tuned coarse for Pi 5 viewport performance —
  too coarse for a small-module tooth meant to actually mesh with another
  printed gear. STL/print export should request a finer `MeshQuality`
  override at export time (the mechanism already exists; this is a
  call-site decision).

A polyline flank would make even STEP export visibly faceted, since
there'd be no real curve to preserve — the small extra cost of building a
true `BSplineCurve` is what buys STEP fidelity.

## Positioning: every gear Feature owns a `plane_ref: PlaneRef`

No gear Feature routes through a `SketchFeature` (per "gear teeth are not
Sketch entities" above), so none of them get a plane for free the way
`ExtrudeFeature` does via its Sketch. Every gear-producing Feature type
(`GearFeature`, `GearChainFeature`, `PlanetaryGearFeature`,
`BevelGearFeature`, `BevelPairFeature`) owns a `plane_ref: PlaneRef`
directly — the existing reusable type (fixed XY/XZ/YZ plane, a Body face,
or an existing `CreatePlaneFeature`; no new reference kind). The profile
builds in that plane's local (x, y) via its real right-handed
`x_axis`/`y_axis` basis (`ResolvedPlane`), then extrudes/assembles along
its normal — mirrors `ExtrudeFeature`'s own `start_distance`/
`end_distance`-from-plane convention. For a bevel Feature, the plane's
origin is the cone apex and its normal is the primary shaft axis.

**Default**: the Gear Design screen's plane field is a full `PlaneRef`
picker (same component Mirror/Create Plane already use for their own
plane-reference fields), pre-filled to the fixed XY plane, always visibly
shown, never silently chosen — matches this app's existing rule that no
Sketch-anchored feature anywhere ever defaults to a plane invisibly.
Works identically whether or not a Part is already open: the fixed-plane
case needs no existing Part geometry to resolve, so arriving fresh from
`ToolChooserScreen` with no Part open needs no special-casing — a new
Part is created lazily at "Create," same as every other flow.

## Downstream Features already work on any gear Body — confirmed, zero new work

Every gear Feature registers ordinary Bodies (real OCCT topology, the same
`#N`-suffix multi-body convention `ExtrudeFeature`/`PatternFeature`
already use for multi-solid output). `target_body_ids` (Cut, Fillet,
Chamfer), `SubShapeRef` (a face for a new Sketch, an edge pick), and
Pattern/Mirror's `source_body_ids` are all already generic across *any*
Body regardless of which Feature produced it. A keyway or fixing holes on
one gear of a pair/chain/planetary set: new Sketch on a face of *that
specific gear's* `#N`-suffixed Body id (individually targetable exactly
like one Pattern instance already is), `ExtrudeFeature` with `mode=CUT`
targeting it. No gear-specific tooling needed. Standard, expected
behaviour, not a limitation: once a Cut is stacked on a gear Feature,
`Part.is_locked` applies exactly as it does to every other Feature —
editing the gear's own tooth count/module afterward needs the existing
rollback mechanic.

## Non-blocking validation banner convention

Every gear-math validation (undercut risk, interference, print-clearance
margin, face-width-vs-cone-distance bound) surfaces as a non-blocking
warning banner — same convention every other Feature in this app already
uses for a geometrically-valid-but-questionable result. **Exception**: a
result with no valid geometry at all (e.g. a non-integer/non-positive
computed planet tooth count — see `05-gear-chain-and-planetary.md`) blocks
creation outright, since there's nothing to draw, not a quality tradeoff.

## Field input style

Dropdown of standard values (module: 0.5, 0.75, 1, 1.25, 1.5, 2, 2.5, 3,
4, 5, 6, 8, 10...; pressure angle: 14.5°, 20°, 25°) with a "custom" option
revealing free text — matches this project's own already-planned Hole
tool approach ("selectable from a standard table rather than typed in as
a raw diameter"). Applies to every gear-type entry form (Workstream 8).

## `GearGroup`

Introduced in `05-gear-chain-and-planetary.md` for `GearChainFeature`
only (`PlanetaryGearFeature`/`BevelPairFeature` use flat shared fields
instead — their topologies don't have a place for a module change to
happen). Referenced here because Workstream 8's preview also consumes it
(group color-coding).
