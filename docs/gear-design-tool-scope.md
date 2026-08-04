# Gear Design Tool — Scoping Document

Companion to a feature request covering: a new "Gear Design" entry point
alongside "3D Part Design" / "2D Drawing", parametric text-entry gear
generation with a 2D preview, DXF export (including multi-file export for
pairs/sets), DXF import into the 3D sketcher as a selectable "block", and
support for external, internal, rack-and-pinion, helical, herringbone,
planetary, and bevel gears, ending in solid geometry ready to 3D print.
Same convention as `docs/pattern-mirror-scope.md`/`docs/text-tool-3d-viewport-scope.md`:
broken into engineering workstreams against the *actual current
implementation* (verified by reading the code, not assumed), with proposed
approach, affected files, complexity/risk, and a suggested delivery order.

**Status: design only — nothing in this document is implemented yet.**
Confirmed via direct grep across the whole backend, client, and `docs/`: no
gear/involute code, no DXF import or export in either direction, and no
Loft feature exist anywhere in this codebase. This is genuinely greenfield
scope, landing on top of a Feature-tree/Sketch system that is otherwise
quite mature.

Backend: `backend/app/document/*` (FastAPI + pythonocc-core/OCCT),
`backend/app/sketch/*` (Sketch/Point/entity/constraint model).
Client: `client/lib/viewport3d/*` (3D Feature panels/selection),
`client/lib/sketch/*` (sketch-level tooling), `client/lib/tool_chooser_screen.dart`
(the existing "splash" entry point).

---

## 1. Grounding: what already exists that this must plug into

- **The Feature-tree checklist.** Every concrete `Feature` subclass
  (`SketchFeature`, `ExtrudeFeature`, `RevolveFeature`, `SweepFeature`,
  `FilletFeature`, `ChamferFeature`, `MirrorFeature`, `PatternFeature`,
  `CreatePlaneFeature`, `ImportFeature` — all in `backend/app/document/models.py`)
  follows the same six-part pattern: a `@dataclass` with `id`/`type`/
  `produces_solid_geometry`/`produces`; a `depends_on` branch in
  `build_feature_graph` (`graph.py`); a `resolve_X_from_bodies`/`resolve_X`
  geometry module; a branch in `compute_part_bodies`'s topological recompute
  loop (`extrude.py`); pydantic Create/Update/Response schemas
  (`schemas.py`); router endpoints. A new `GearFeature` is one more entry in
  this same checklist, not a new architecture — this is the single biggest
  reason to prefer "gear as a Feature" over inventing a parallel system.

- **Sketch entities and why gear teeth should *not* be one.** The Sketch
  model has Line, Circle, Arc, Ellipse, Polygon, Slot, Rectangle, Spline,
  and Text. `Spline` is the closest existing thing to "an arbitrary curve
  through points" — but it is genuinely solver-backed: every through-point
  gets a real `py-slvs` cubic-Bezier entity plus a `SplineTangentConstraint`
  at every interior join, so it can be dragged live and stay tangent-
  continuous. A single involute gear profile easily needs on the order of
  10-20 sampled points *per flank*, times 2 flanks, times N teeth — for a
  20-tooth gear that's several hundred solver entities, re-solved on every
  drag. That's a real performance risk if gear teeth were represented as
  interactive Spline entities, for no actual benefit (nobody drags
  individual points on a gear tooth).

  The existing precedent for *avoiding* this is **`TextEntity`**: glyph
  outlines are realized directly as OCCT geometry (`text_to_brep`) and
  rendered as closed contours, without ever becoming constraint-solved
  Sketch entities. Gear teeth should follow the same pattern — procedurally
  generated curves realized directly in OCCT, not routed through
  `py-slvs`/the interactive Sketch model at all. This directly answers "check
  involute curves are supported in the 3D part sketcher": they aren't, and
  per the decision below (§2, Q1) they don't need to be — a `GearFeature`
  builds its profile straight from parameters, the same way `ExtrudeFeature`
  builds a prism straight from a Profile without needing "extrusion" to be a
  Sketch primitive.

- **Convert Entities / `ExternalVertexReference`** (`app/sketch/models.py`)
  is the existing mechanism that already does almost exactly what the DXF
  "block" behaviour needs: it lets a Sketch reference a *Body's* edges/
  vertices individually, tracked associatively, from inside another Sketch.
  A DXF import that lands as a lightweight reference Body (wireframe, no
  volume) would make individual-curve selection "for free" via this
  existing tool — see Workstream 6.

- **Confirmed absent, all genuinely greenfield:**
  - **DXF, in either direction.** `docs/roadmap.md`'s "2D Drawing tool
    follow-ups" section already flags DXF export as wanted-but-unstarted
    for the separate standalone 2D Drawing tool, and confirms no `ezdxf`
    dependency and no prior DXF import exists to mirror. This gear tool
    and that roadmap item should share one DXF subsystem (§ Workstream 5/6),
    not build two.
  - **Loft.** Only Extrude (prism), Revolve (rotate), and Sweep (single
    profile along a *picked Sketch Line chain*, `BRepOffsetAPI_MakePipe`)
    exist. `BRepOffsetAPI_ThruSections` (OCCT's loft primitive) is used
    nowhere. Needed for helical/herringbone teeth (§ Workstream 4).
  - **Any multi-part assembly concept.** A `Part` holds multiple `Body`
    instances (Pattern/Mirror/split solids already produce several Bodies
    from one Part), but there is no independent-parts-positioned-relative-
    to-each-other concept, and no kinematics/simulation of any kind. Fine
    for this request, since the ask is static printable/design geometry,
    not simulated meshing — but it means "planetary set" and "rack and
    pinion pair" are built as multiple `GearFeature`s (and a rack/pinion
    variant) correctly *positioned* within one Part, not a true assembly.

- **The existing "splash" screen is `ToolChooserScreen`**
  (`client/lib/tool_chooser_screen.dart`), shown right after Connect,
  currently offering "3D Part Design" (`PartScreen`) and "2D Drawing"
  (`SketchScreen(standalone: true)`). A third `_ToolTile` for "Gear Design"
  slots in directly.

---

## 2. Decisions already made (from brainstorming)

1. **Core mechanism: procedural `GearFeature`.** A gear is a Feature-tree
   node — parameters in, solid Body out — not a DXF-round-trip and not a
   constraint-solved Sketch. DXF export/import remain required, but as
   secondary outputs/inputs, not the mechanism that produces the 3D shape.
2. **V1 scope: external, internal, rack-and-pinion, helical, herringbone,
   and planetary sets together** (not phased planar-first). Bevel is
   explicitly carved out.
3. **Bevel gears: deferred to a dedicated later phase, targeting true
   spherical-involute tooth surfaces** (not the cheaper loft-of-scaled-
   flat-profiles approximation most hobbyist tools use). Flagged as
   realistically the single largest chunk of effort in this whole area —
   see §5.
4. **DXF import: full "block" semantics.** A DXF import lands as one
   selectable/movable/rotatable/scalable unit in its own home sketch, while
   individual curves become pickable elsewhere via the existing Convert
   Entities tool — reusing the `ExternalVertexReference` mechanism rather
   than inventing a new one.
5. **Tooth flank curve: a real `Geom_BSplineCurve`, not a straight-line
   approximation** — the only choice that keeps STEP export genuinely
   smooth rather than faceted. Full reasoning moved into Workstream 2 (it's
   an engineering detail of that workstream, not a product-level scoping
   decision on its own).
6. **Numeric fields: dropdown of standard values (module, pressure angle)
   with a "custom" override, not free text everywhere** — matches this
   project's own already-planned approach for the (separate, still
   unbuilt) Hole tool: "selectable from a standard table rather than typed
   in as a raw diameter" (`docs/roadmap.md`'s MBD section).
7. **Gear parameter presets/templates: yes, wanted** — but kept
   **client-local**, not a new server-side store. `project-brief.md` §3's
   stated architecture principle ("the server is stateless between
   sessions... does not persist any model data") has held for every Feature
   built so far; a preset store is the first thing in this whole app that
   needs to persist independent of one session's Part, so it's worth being
   deliberate rather than accidentally becoming the first exception to it.
   `SketcherPreferences`/`MeshViewerPreferences` (on-device, local-only
   settings, no backend involved) are the direct existing precedent — see
   Workstream 9. If cross-device preset sync is ever wanted, that's a
   genuine, separate architectural decision to revisit explicitly, not an
   incidental side effect of building presets at all.
8. **Multi-gear systems (pairs, chains, planetary) are one live,
   re-derivable Feature each — `GearChainFeature`/`PlanetaryGearFeature` —
   not a one-shot orchestration that creates independent Features once.**
   Reverses this doc's original Workstream 5 draft; resolves what had been
   an open §7 question. Mirrors Pattern/Mirror's existing "one Feature,
   many realized Bodies, recomputed fresh every time" pattern, so editing
   one gear's tooth count live-repositions/resizes the rest, for free, from
   the existing dependency graph — no new live-linking mechanism needed.
   See Workstream 5.
9. **Gear chains support bent (multi-directional) paths in v1, not
   straight-line-only.** Real added scope, specifically interference
   checking between non-adjacent stages (a genuinely new problem for this
   codebase — nothing currently checks for unintended geometric overlap
   between unrelated shapes) — see Workstream 5's own risk callout.
10. **DXF export for a multi-gear system produces both per-gear cut files
    and a combined layout file** (every gear at its real relative
    position, for reference/assembly drawings) — see Workstream 6.

---

## 3. Architecture overview

```
Gear Design entry (ToolChooserScreen tile)
        |
        v
Parameter form + 2D preview  (client-side quick preview math,
  mirroring gear_math.py so preview matches the real solve)
        |
        v
"Create" -> creates/opens a Part, adds one or more GearFeature
  (+ CreatePlaneFeature for positioning, for pairs/sets/planetary)
        |
        v
Normal Part Design flow from here on: 3D viewport, Fillet/Chamfer/
  Pattern/etc. all already work against any Body, gears included.

Separately (not on the critical path to a 3D gear):
  GearFeature's own profile params -> DXF export (single or multi-file)
  DXF file -> DXF import -> reference Body (block) in the 3D sketcher
    -> Convert Entities pulls individual curves into a real Sketch
```

Two independent tracks: **gear generation** (Workstreams 1-4, 7-8) needs no
DXF at all to produce a printable 3D gear. **DXF import/export**
(Workstreams 5-6) is shared infrastructure that also benefits the existing
"2D Drawing" tool and general interchange, and is buildable/deliverable in
parallel.

---

## 4. Workstreams

### Workstream 1 — Gear math core (`app/document/gear_math.py`, OCCT-free)

Pure-Python involute/gear geometry: base circle, addendum/dedendum circles,
involute curve sampling (parametric `x = r_b(cos t + t sin t)`, `y =
r_b(sin t - t cos t)`), tooth spacing from module + tooth count, root
fillet, pressure angle, profile shift/correction (needed at low tooth
counts to avoid undercut), backlash allowance, and rack tooth generation
(trapezoidal, straight-sided — genuinely different math from involute
sampling, not a variant of it). Also: pair/mesh validation (center distance
`= module * (N1 + N2) / 2` for external pairs, `= module * (N_ring - N_sun)
/ 2` for a sun/ring pair) and planetary assembly-condition validation
(`(N_sun + N_ring) mod N_planets == 0`, plus a minimum-planet-count/
interference check) — fail closed with a clear structured error rather than
silently producing a non-meshing or self-colliding model.

Deliberately kept OCCT-free, mirroring the existing split already used
elsewhere in this codebase (`app.document.mesh_import` vs
`app.document.import_geometry`; `app.document.sweep`'s own pure-Python
path-resolution helpers vs its OCCT construction) — this repo's dev sandbox
has never had `pythonocc-core` installed, so keeping the actual involute
math OCCT-free means it's directly unit-testable here, with only the final
curve/solid construction needing real CI (which does have OCCT) to verify.

**Complexity/risk:** medium. The math itself is well-documented (standard
gear-design formulas, AGMA/ISO 21771), but precision matters — wrong
formulas produce gears that don't mesh, not just cosmetically wrong ones.
Needs a real test suite checking known reference values (e.g. a standard
module-2/20-tooth/20°-pressure-angle gear's known base circle diameter),
not just "it runs."

### Workstream 2 — `GearFeature`: external + internal spur gears

New `Feature` subclass, following the six-part checklist above. Parameters:
module (mm), tooth count, pressure angle, face width (extrude depth),
profile shift, backlash, root fillet radius, and (internal only) rim/outer
diameter. `app/document/gear.py` (OCCT-dependent half) turns `gear_math`'s
sampled profile points into OCCT edges/wire.

**Curve representation — resolved, not left open** (see §7's earlier note,
now settled): each tooth flank is built as one real `Geom_BSplineCurve`
interpolated through `gear_math`'s sampled involute points (`GeomAPI_
Interpolate`), not a polyline of short straight edges. This matters beyond
looks — the resulting `Body` is a true analytic BRep solid, identical in
kind to every other Feature's output in this codebase (Extrude/Revolve/
Sweep all already produce exact curves/surfaces, never polygons, at the
model level). Concretely:
- **STEP export** (`step_export.py`, writes the Body's real BRep directly)
  carries the exact involute flank curve, not a faceted approximation —
  correct for reimport into another CAD tool or for a shop that machines
  from STEP.
- **STL/OBJ/glTF export and the 3D viewport** all go through one shared
  tessellation step (`app/document/mesh.py`'s `BRepMesh_IncrementalMesh`,
  controlled by `MeshQuality.linear_deflection`/`angular_deflection`) —
  these are always faceted, because STL/OBJ/glTF have no curve concept at
  all; this is true of every solid modeler's STL export, not a DIDSA-CAD
  limitation. The one real action item: `DEFAULT_MESH_QUALITY`'s existing
  `linear_deflection = 0.5` (`mesh_data.py`) is deliberately coarse, tuned
  for real-time viewport performance on the Pi 5 target hardware — almost
  certainly too coarse for a small-module tooth flank meant to actually
  mesh with another printed gear. STL/print export should request a
  measurably finer deflection than the viewport's live default (an
  explicit `MeshQuality` override at export time — the mechanism already
  exists, this is a call-site decision, not new plumbing), rather than
  inheriting the viewport's performance-tuned default unchanged.

Had the tooth flank instead been built as a dense polyline of straight
edges, none of the above would hold — even the "exact" STEP output would
carry visibly faceted flanks, since there'd be no real curve there to
preserve. Building the true `BSplineCurve` costs a little more up front in
`gear.py` and is worth it precisely because it's the only choice that keeps
STEP export genuinely smooth.

Internal gears: an annulus profile (outer rim boundary + inward-facing
involute tooth boundary) built as one Boss, not a separate Cut step.

**Complexity/risk:** medium-high for the OCCT curve/profile assembly
(getting wire winding direction and start/end continuity right around a
full gear — 20+ repeated tooth profiles stitched into one closed wire — is
fiddly, matching this codebase's own noted experience with e.g. Slot/Polygon
closed-form geometry); low for Boss/Cut integration, which is copy-paste
from `ExtrudeFeature`'s existing pattern.

### Workstream 3 — Rack tooth-profile generator

A standalone rack: same `GearFeature`-family Feature but a linear
trapezoidal-tooth profile (from `gear_math`'s rack generator, genuinely
different math from involute sampling — straight-sided, not curved) over a
specified length instead of a full disc, for a user who wants just a rack
on its own. Pairing a rack with a pinion at the correct position is **not**
built here — see Workstream 5, which now owns all multi-gear positioning
(pairs, chains, rack-and-pinion, planetary) as one unified concept.

**Complexity/risk:** low-medium, mostly reuses Workstream 2's machinery.

### Workstream 4 — Helical and herringbone gears (needs Loft or
sweep-along-helix)

Two viable OCCT techniques, worth deciding during implementation rather
than locking in now:
- **Sweep the 2D tooth profile along a helical path.** Geometrically the
  *correct* way to generate a true constant-lead helical tooth surface
  (what real CAD/manufacturing tools do) — more accurate than a loft, which
  only interpolates a ruled/smooth surface *between* two end cross-sections.
  Requires extending `SweepFeature`'s path concept, since its `path_refs`
  today only accepts a picked chain of existing Sketch Lines/Arcs/Ellipses/
  Splines, not a procedurally generated helix curve.
- **Loft between two profile copies, rotated relative to each other by the
  helix's twist angle.** Simpler to implement, an approximation (the swept
  surface between two lofted involute cross-sections isn't exactly a
  helicoid), and this is the mechanism the original request specifically
  asked for as a general capability (see Workstream 4b) — genuinely useful
  as a standalone new CAD primitive beyond gears too.

Recommendation: build the general Loft feature regardless (real,
independently requested capability), but implement helical gear teeth via
the sweep-along-helix technique for correctness, using Loft as a fallback/
simpler-approximation path if the helix-sweep spike proves too costly.
Herringbone = two opposite-handed helical halves joined at the gear's
mid-plane (mirrored, not simply "twice as tall").

#### Workstream 4b — General `LoftFeature`

A genuinely new, standalone Feature (not gear-specific — same "useful on
its own" status as Sweep already has): lofts between 2+ Sketch profiles via
`BRepOffsetAPI_ThruSections`, with user-selectable start/end reference
points per profile to control twist — OCCT doesn't expose "pick a vertex to
align" directly; achieving it means reordering each profile's own wire
edge-traversal start to begin at the user-chosen point before feeding wires
to `ThruSections`, and matching winding direction across profiles. This is
new OCCT usage in this codebase and should be spiked early (small standalone
script/test, ahead of committing to gear teeth depending on it) rather than
assumed to work first try.

**Complexity/risk:** high. Both the helix-sweep path and the twist-controlled
Loft path are genuinely new OCCT techniques for this codebase, with real
correctness risk (self-intersecting lofts/sweeps at high twist angles,
wire-orientation mismatches). Budget real spike time before committing to
an approach.

### Workstream 5 — Multi-gear systems: `GearChainFeature` and `PlanetaryGearFeature`

**Revised from an earlier draft of this doc**, which treated pairs/sets as
one-shot client-side orchestration (generate N independent `GearFeature`s
once, no ongoing relationship). Superseded per a later brainstorming
round: a multi-gear system should be **one Feature, live and re-derivable**
— editing one gear's tooth count should reposition/resize the rest
automatically, the same live parametric behaviour every other edit in this
app already gets. The existing precedent that makes this both possible and
cheap is **Pattern/Mirror**: one Feature specification resolved fresh into
several `#N`-suffixed Bodies on *every* recompute (this app's dependency
graph never caches — "re-derive, don't cache," per the project brief), not
a one-time expansion into independent sibling Features. Two new Feature
types, following the six-part checklist §1 describes, mirroring how this
codebase already gives Extrude/Revolve/Sweep each their own enum rather
than one shared polymorphic type:

**`GearChainFeature`** — an ordered list of N≥2 meshing stages (each stage:
external/internal/rack, tooth count or rack length, face width, hand), one
shared module + pressure angle for the whole chain (structurally
eliminates mismatched-module gears — impossible to construct, not just
validated against). N=2 is an ordinary pair (including rack-and-pinion, a
rack stage next to a gear stage); N>2 is a longer gear train. Resolves in
one pass into N positioned Bodies, same `#N`-suffix convention
`ExtrudeFeature` already uses when one Feature yields several disjoint
solids. A later Feature (Fillet, Cut for a bore/keyway, Pattern, Text
engraving...) can still target one specific stage's Body individually,
exactly as it already can target one instance of a Pattern today — the
chain Feature only owns the *generative* gear parameters, not anything
downstream.

**Path shape — bent paths supported, not straight-line-only.** Each stage
after the first carries its own turn angle (relative to the previous
segment's direction, within the chain's own plane — reusing `PlaneRef` for
that plane, same as Mirror's mirror-plane input already does, no new
reference type needed) rather than every stage defaulting to one straight
line. This is a materially bigger scope item than the straight-line-only
alternative would have been, for two concrete reasons:
- **Interference checking becomes mandatory, not optional.** In a straight
  chain, only consecutive stages can ever be geometrically close, so
  correctness reduces to "consecutive pairs are the correct center
  distance apart" (already required regardless). Once a chain can bend —
  potentially back toward itself — **non-adjacent** stages can now
  physically overlap even though they were never meant to mesh. This needs
  a real new check (pairwise circle-overlap test — addendum circle vs.
  addendum circle — across every *non-adjacent* stage pair, not just
  consecutive ones) with no existing precedent to reuse anywhere in this
  codebase; flag interference as a warning (same non-blocking-banner
  convention as every other gear validation) rather than silently letting
  two solids collide.
- **The 2D preview (Workstream 8) needs to render an actual routed path**,
  not a single line — each stage's center comes from the previous stage's
  center + center-distance + the stage's own turn angle, and the preview
  should visually flag any interfering pair it detects (e.g. highlighting
  the offending gears), so a bad route is *seen*, not just rejected by a
  banner after the fact.

A fully general, drag-to-route interactive path editor is real UI scope on
top of the numeric turn-angle-per-stage approach above — recommend text-
entry turn angles for v1 (consistent with this tool's stated text-entry-
first interaction model), with interactive routing as a plausible later
UI-only enhancement over the same underlying data shape, not a backend
change.

**`PlanetaryGearFeature`** — kept as its own Feature type, not folded into
`GearChainFeature`, because its topology is genuinely different: branching
(sun meshes every planet, every planet meshes the ring), not a sequence.
Sun/ring tooth counts + planet count in, validates the assembly condition
(Workstream 1) and evenly spaces planets around the sun at the correct
radius, resolving into N+2 positioned Bodies (sun, ring, N planets) in one
pass, same multi-body convention as `GearChainFeature`. Static/positioned
only — no kinematics/rotation, matching the static-print-and-design scope
of the original request.

**Complexity/risk:** high for `GearChainFeature` specifically (bent paths +
interference checking are both genuinely new problems for this codebase,
not reuse of an existing pattern — worth a real spike alongside Workstream
4b's Loft/helix-sweep spike, for the same "find out early if there's a
showstopper" reason); medium for `PlanetaryGearFeature` (no new geometry-
kernel work, mostly correct application of Workstream 1's math plus
Workstream 2's per-gear-type geometry builders, reused via the same shared-
helper pattern `ExtrudeFeature`/`RevolveFeature`/`SweepFeature` already use
for their own common Boss/Cut logic).

### Workstream 6 — DXF export (shared with the existing "2D Drawing"
roadmap item)

`ezdxf`-based writer (new backend dependency), consuming either a gear's
own profile points (Workstream 1, bypassing the Sketch model entirely —
the profile never needs to become interactive Sketch geometry to be
exported) or a general Sketch's Points/Lines/Arcs/Circles/Ellipses/Splines/
Text (satisfying the pre-existing, separately-roadmapped "2D Drawing DXF
export" ask with the same writer). Two export shapes for a
`GearChainFeature`/`PlanetaryGearFeature`, both wanted:
- **Per-gear cut files** — one DXF per gear, since that matches how a gear
  is actually cut/printed/used downstream (each part on its own sheet/
  plate), returned as a zip or as multiple endpoint calls.
- **Combined layout export** — every gear in the system in one DXF, each
  at its real relative position/rotation (the same positions
  `GearChainFeature`/`PlanetaryGearFeature` itself computes), for a
  reference/assembly drawing rather than for cutting. Cheap to add given
  the per-gear profile geometry and positions already both exist from the
  Feature's own resolve step — this is placement, not new geometry.

DWG is explicitly out of scope (proprietary format, no viable open-source
writer) — this was already the conclusion reached for the separate 2D
Drawing tool's own roadmap entry.

**Complexity/risk:** low-medium. `ezdxf` is a mature, well-documented
library; the main work is a clean mapping from this app's entity model to
DXF entities (LWPOLYLINE for sampled involute curves, SPLINE if `ezdxf`'s
spline entity is preferred over polyline sampling, ARC/LINE/CIRCLE
directly), plus units (DXF `$INSUNITS` header — this app's geometry is
implicitly mm throughout; needs to be stated explicitly in the export
rather than assumed by the importing tool).

### Workstream 7 — DXF import with block semantics

The larger design lift of the two DXF workstreams, because of the block
requirement (§2, decision 4). Proposed approach: an imported DXF becomes a
lightweight, non-solid reference `Body` (a wireframe/compound of edges, no
volume) — `ImportFeature` already round-trips STEP/glTF/OBJ/STL into a
`Body`; a DXF import is a new `ImportSourceFormat` entry feeding the same
pattern, just producing wire/edge geometry instead of a solid. Once it's a
real `Body`:
- In the sketch it's imported into, the whole thing is one selectable/
  movable/rotatable/scalable unit (new selection-hit-testing case treating
  the reference Body as one grouped hit target — needs a real client-side
  design pass, not yet detailed here).
- From the 3D viewport or another sketch, **Convert Entities already lets
  individual Body edges be pulled in as independent, associative Sketch
  entities** (`ExternalVertexReference`) — this is the existing mechanism
  that gives "select individually elsewhere" for free, assuming the
  reference Body's edges are real, well-formed OCCT edges (they will be,
  since DXF entities become real OCCT curves on import, same as any other
  imported geometry).

**Complexity/risk:** high. The "one unit in its home sketch, individual
elsewhere" requirement is a genuinely new selection-semantics concept for
this codebase (nothing currently groups a set of entities as one
hit-target while also allowing them to be referenced individually from
elsewhere) — needs its own focused design pass on the client selection/
hit-testing model before implementation starts, separate from the DXF
parsing itself (which is comparatively straightforward via `ezdxf`'s
reader).

### Workstream 8 — Gear Design entry screen (client) and its 2D preview

New `ToolChooserScreen` tile → a dedicated screen (closer in shape to
`SketchScreen` than to a compact `ResizableToolPanel`, since it needs a 2D
canvas alongside a form, not just a few fields): a gear-type selector
(external/internal/rack/helical/herringbone/planetary/pair) and a form of
fields per type (§ below), next to a live 2D preview canvas.

**Preview mechanism — resolved, refining Workstream 1's own earlier open
question ("Dart port vs. backend round-trip").** Neither, exactly: since
`gear_math` (Workstream 1) is deliberately kept OCCT-free, add a cheap
`GET/POST /gear/preview` endpoint that runs *only* `gear_math` and returns
raw 2D point arrays (tooth outline, plus pitch/base/addendum/dedendum
circle radii for the reference overlay below) — no OCCT solid construction,
no tessellation. That's cheap enough to call on every debounced keystroke,
the same rhythm every other panel's live-PATCH already uses, without
duplicating the math client-side (avoiding the exact "three duplicate
implementations" drift already flagged as a known cost in
`docs/roadmap.md`'s Pattern/Mirror entry) and without paying for a full
OCCT extrude+mesh cycle on every field edit. The **expensive** path — a
real `GearFeature`, real OCCT solid (with the true `BSplineCurve` flank
from Workstream 2) — only runs on debounce-settle or explicit "Create",
mirroring the create-eagerly-on-open convention every other Feature panel
already uses, just deferred one step later than usual given how much more
expensive a full gear solid is than e.g. an Extrude.

**Reference circle overlay: on by default, toggleable.** Pitch/base/
addendum/dedendum circles drawn alongside the tooth outline from the same
`/gear/preview` response, since they directly explain what each parameter
is doing — genuinely useful while learning the tool, not just decoration.
A pair/rack-pinion preview shows both members together (mesh visibly
correct or not, before committing); a planetary preview shows the full
ring/sun/planet layout, so an invalid assembly condition (Workstream 1) is
*seen*, with the validation error as backup, not the first signal.

**Chain preview: renders the actual routed path, not a straight line.**
`/gear/preview` extended to accept a `GearChainFeature`/`PlanetaryGearFeature`-
shaped payload (list of stages + turn angles, or sun/ring/planet-count),
returning every stage's outline + computed center + reference circles, so
a bent chain's real layout is visible while still editing turn angles.
Any interfering non-adjacent pair (Workstream 5) is highlighted directly on
the two offending gears — seen at the point of cause, not just reported as
a banner elsewhere. Also surfaces two cheap, genuinely useful numbers per
`gear_math`, even with no kinematics/simulation involved: **overall ratio**
(input:output tooth ratio through the chain) and **rotation direction**
per stage (external-external reverses, external-internal doesn't, rack
direction depends on orientation) — standard in every real gear-design
tool, and essentially free once the stage list and its meshing
relationships already exist for layout purposes.

**Field input style: dropdown of standard values (module, pressure angle)
with a "custom" override**, matching this project's own already-planned
approach for the Hole tool. Standard module list (a conventional metric
series: 0.5, 0.75, 1, 1.25, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10...) and standard
pressure angles (14.5°, 20°, 25°) as the picklist, "custom" revealing a
free-text field for anything outside that set — never a hard restriction,
just a sane default path.

"Create" adds a Part (or opens the current one) with the resulting
`GearFeature`(s), handing off to the normal `PartScreen` 3D-viewport flow —
editing afterward is then just the ordinary Feature-tree edit flow
(reopen while it's still the last Feature, or roll back to it via the
existing `Part.is_locked` mechanic if something's been built on top of it
since), nothing gear-specific to add there.

**Complexity/risk:** medium. Mostly UI work following this codebase's
existing tool-panel/value-bar conventions (`ExtrudePanel`, `FilletPanel`,
etc.) rather than new concepts; the one new backend piece is the cheap
`/gear/preview` endpoint, which is a thin wrapper around Workstream 1 and
should ship alongside it.

### Workstream 9 — Gear parameter presets/templates (client-local)

A named-preset store for gear parameters (module, teeth, pressure angle,
type, etc.), reusable across Parts/sessions. Kept deliberately **client-
local** (on-device storage — the same mechanism `SketcherPreferences`/
`MeshViewerPreferences` already use, no new backend persistence), per §2
decision 7: this app's server has held a genuine "stateless, persists no
model data" principle through every Feature built so far, and a preset
store is the first thing that needs to outlive a single session's Part —
worth keeping that boundary intact by default rather than crossing it
incidentally. UI: a "Save as preset" action on the Gear Design screen
(Workstream 8) capturing the current form state under a user-given name,
and a picklist/gallery to load one back into the form. Presets are a
convenience for *re-populating the form*, not a live/associative link —
loading one and then creating a gear produces an ordinary, independent
`GearFeature`, with no ongoing relationship to the preset it came from.

**Complexity/risk:** low. Pure client-side, no new backend surface, no
interaction with the Feature-tree/dependency-graph model at all — this is
UI convenience state, not part of any Part's document. Only real design
question left: exact storage mechanism (Flutter's usual local-prefs/
file-based options — a small, ordinary choice, not one that needs
resolving in this scope doc).

---

## 5. Bevel gears (deferred phase, targeting true spherical-involute geometry)

Explicitly out of the initial delivery per §2 decision 3, recorded here so
the reasoning isn't lost: a true involute bevel tooth flank is a
**spherical involute**, generated by rolling a plane on a base cone rather
than a base cylinder — the tooth profile genuinely changes shape along the
face width (it does not scale uniformly the way a simple "shrink toward
the apex" loft would suggest), and real bevel gear manufacture (Gleason/
Klingelnberg-style) uses additional corrections (lengthwise crowning, tooth
taper) beyond the base spherical-involute form that this scope deliberately
leaves for a later decision. Building this properly is realistically the
single largest chunk of geometry-kernel work in the whole gear tool —
expect it to need its own dedicated scoping pass (own math derivation, own
OCCT construction strategy — most likely sampling the spherical involute
directly as 3D points rather than any 2D-profile-plus-extrude/loft
technique the other gear types use) once Workstreams 1-9 are live and there's
a working gear tool to extend rather than build bevel support into
speculatively now.

---

## 6. Suggested delivery order

1. **Workstream 1** (gear math core) — no dependencies, fully unit-testable
   in this dev sandbox today, and everything else depends on it.
2. **Workstream 2** (external/internal `GearFeature`) — first real 3D gear,
   proves the Feature-tree integration end-to-end.
3. **Workstream 8** (entry screen + `/gear/preview` + reference overlay) in
   parallel with/right after Workstream 2, so there's a usable tool as soon
   as spur gears work rather than waiting for every gear type. **Workstream
   9** (client-local presets) is a small, independent add-on once
   Workstream 8's form exists — no dependency ordering pressure either way.
4. **Workstream 3** (rack/rack-and-pinion) — cheap extension of Workstream 2.
5. **Two parallel spikes, both specifically *because* they're the highest-
   risk unknowns** — better to find a showstopper early than after
   committing:
   - **Workstream 4b** (Loft/helix-sweep feasibility for helical teeth).
   - **Workstream 5's `GearChainFeature` bent-path + interference-check
     approach** — a small standalone spike (a handful of stages, a couple
     of turn angles, confirm the circle-overlap interference check and the
     `PlaneRef`-anchored routing math both hold up) before committing the
     full chain UI/preview to depend on it.
6. **Workstream 4** (helical/herringbone) once 4b's spike lands.
7. **Workstream 5** (`GearChainFeature` — covers pairs, rack-and-pinion,
   and N-stage chains in one Feature type — then `PlanetaryGearFeature`)
   once its own spike lands — depends on Workstream 2 (internal + external
   gears) and Workstream 3 (rack) for the per-stage geometry it positions.
8. **Workstreams 6-7** (DXF export — per-gear cut files, then the combined
   layout export, then DXF import-with-blocks) — independent of the
   gear-specific work above; can run on its own track in parallel, and
   Workstream 6's per-gear export in particular could ship early since the
   existing "2D Drawing" tool wants a DXF writer regardless of gears.
9. **Bevel** (§5) — separate phase, after the above is live.

---

## 7. Open questions to resolve during detailed design (not blocking this
scope doc, but not yet answered)

- ~~Client-side preview: Dart port of `gear_math`, or live backend
  round-trip per field edit?~~ **Resolved** — neither: a cheap, OCCT-free
  `/gear/preview` endpoint calling the real `gear_math` directly, cheap
  enough for every debounced keystroke. See Workstream 8.
- ~~Involute profile realized as a true `Geom_BSplineCurve` through sampled
  points, or dense straight-line segments?~~ **Resolved** — real
  `BSplineCurve`, per the mesh-smoothness discussion now in Workstream 2:
  it's the only choice that keeps STEP export genuinely smooth rather than
  faceted, and print/STL export quality is a separate, already-existing
  `MeshQuality` override at export time, not a reason to avoid a real curve.
- Exact parameter set per gear type for v1 (e.g. is profile shift a v1
  requirement or a later refinement once undercut at low tooth counts is
  confirmed to actually be a problem worth surfacing to the user?).
- ~~Whether "gear pairs/sets" need a saved, re-editable relationship...~~
  **Resolved** — yes, live and re-derivable, via `GearChainFeature`/
  `PlanetaryGearFeature` as single Features. See §2 decision 8 / Workstream 5.
- New from the bent-path decision: exact turn-angle input UX (a numeric
  field per stage vs. some lighter-weight way to specify "continue
  straight" as the common case without a redundant 0° entry every time),
  and the precise interference-check tolerance (how close is "touching but
  not meshing" allowed to be before it's flagged, given two *intentionally*
  meshing adjacent gears are supposed to be nearly touching by design —
  the check needs to somehow exclude each stage's own intended meshing
  neighbour while still catching everything else).
