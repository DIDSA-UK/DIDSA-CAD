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
  existing tool — see Workstream 7.

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
   and planetary sets together** (not phased planar-first). ~~Bevel is
   explicitly carved out~~ — **superseded, see decisions 14-17 below**:
   straight bevel was later pulled into v1 too, leaving only spiral/
   Zerol/hypoid bevel variants genuinely deferred.
3. ~~Bevel gears: deferred to a dedicated later phase~~ — **superseded**,
   see decisions 14-17. Targeting true spherical-involute tooth surfaces
   (not the cheaper loft-of-scaled-flat-profiles approximation most
   hobbyist tools use) still holds; the *timing* decision changed.
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
   an open §6 question. Mirrors Pattern/Mirror's existing "one Feature,
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
11. **Turn-angle input: one always-visible per-stage field (default 0°),
    relative to the previous segment, sign convention inherited from
    `RevolveFeature`/circular `PatternFeature`; text-entry only for v1.**
    See Workstream 5.
12. **Interference checking is a topology split, not a tolerance value**:
    skip consecutive (intentionally meshing) stage pairs entirely, exact
    overlap test plus a small print-clearance margin for every non-adjacent
    pair, per-stage-type bounding shape. **Internal/ring stages are
    restricted to the last position in a chain.** See Workstream 5.
13. **Compound gears: full geometry pulled into v1, not deferred** —
    revised from this doc's own initial resolution (`GearGroup` schema
    now, geometry later) after an explicit walk-through of the pros/cons,
    decided against this doc's own recommendation to defer; recorded as a
    deliberate accepted risk, not a default. A `GearGroup`
    (`id`/`module`/`pressure_angle`/`display_color`) is what module/
    pressure-angle actually belong to, not the chain directly — v1 UI
    creates exactly one implicit group per chain for an ordinary chain, and
    a real second group at each compound join. The two-coaxial-gears-per-
    station geometry, cross-group mesh validation, and compound-aware
    ratio/direction rule are all in v1 scope now, alongside two genuinely
    unspiked unknowns that need resolving during Workstream 5 itself, not
    discovered mid-implementation: the structural transition between very
    different diameters at a join (no manufacturing-constraint validation
    precedent exists anywhere in this codebase), and how a compound
    station's two members — at different depths along the shaft, not the
    same 2D plane — represent as DXF cut files. v1 now carries three
    separate "genuinely new OCCT/geometry technique" spikes in total (up
    from two), not one more increment on an already-scoped item. The two
    members default to fusing into one Body (reusing Pattern/Mirror's
    existing `MergeMode`, not a new mechanism), overridable to stay
    separate. See Workstream 5's "Compound gears" note.
14. **Bevel gears: straight bevel only, pulled into v1** — spiral/Zerol/
    hypoid bevel variants remain deferred as their own further-later phase
    (a materially bigger leap, arguably harder than every other workstream
    in this doc combined). See Workstream 10.
15. **Bevel shaft angle: arbitrary, not restricted to 90°.** The pitch-cone
    formula is built general from the start (`γ1 = atan(sin(Σ) / (N2/N1 +
    cos(Σ)))`), not the simpler 90°-only special case. See Workstream 10.
16. **Bevel pairing: a full automated, live `BevelPairFeature`** — not a
    standalone `BevelGearFeature` manually positioned twice. Mirrors
    `GearChainFeature`/`PlanetaryGearFeature`'s own live, re-derivable
    pattern, scoped as a pair specifically (exactly 2 members), not a
    generalized N-stage bevel chain. See Workstream 11.
17. **`BevelPairFeature` kept fully separate from `GearChainFeature`** —
    no bevel stage kind added to the planar chain. A chain that needs to
    turn a 3D corner places a `BevelPairFeature` alongside a
    `GearChainFeature`, rather than the chain's own bent-path/interference
    machinery (built around one shared plane) being extended to a
    structurally different intersecting-axis case. See Workstream 11.

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

**Curve representation — resolved, not left open** (see §6's earlier note,
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
external/internal/rack, tooth count or rack length, face width, hand).

**Module/pressure-angle: owned by a `GearGroup`, not inlined per-chain —
resolved, folding in a compound-gear-driven refinement** (see this
workstream's own "Compound gears" note below for the full reasoning). A
`GearGroup` is a small named record (`id`, `module`, `pressure_angle`,
`display_color`), and every stage references a `group_id` rather than
carrying its own module/pressure-angle directly. Two stages can only mesh
if they share a group (still structurally eliminates mismatched-module
gears — impossible to construct, not just validated against — exactly
the original guarantee, just relocated one level). v1 UI creates exactly
**one implicit group per chain** — a normal chain still reads, to the
user, as "the chain has one module," no groups concept surfaced anywhere
— but the schema is already shaped for multiple groups (and the
color-coded preview that falls out of it) without a later breaking
migration of an already-shipped Feature type.

N=2 is an ordinary pair (including rack-and-pinion, a rack stage next to a
gear stage); N>2 is a longer gear train. Resolves in
one pass into N positioned Bodies, same `#N`-suffix convention
`ExtrudeFeature` already uses when one Feature yields several disjoint
solids. A later Feature (Fillet, Cut for a bore/keyway, Pattern, Text
engraving...) can still target one specific stage's Body individually,
exactly as it already can target one instance of a Pattern today — the
chain Feature only owns the *generative* gear parameters, not anything
downstream.

**Internal (ring) stages: last stage only, resolved.** A linear chain
naturally "continues past" an external gear (something else meshes with
its far side), but nothing meaningfully continues past a ring the same
way without turning into a branching (planetary-like) topology, which is
`PlanetaryGearFeature`'s job, not this one's. `GearChainFeature` rejects an
`internal` stage anywhere but the final position — a real, deliberate
restriction (not a v1 gap left to chance), avoiding an edge case the
linear-chain model was never meant to cover.

**Path shape — bent paths supported, not straight-line-only.** Each stage
after the first carries its own turn angle (relative to the previous
segment's direction, within the chain's own plane — reusing `PlaneRef` for
that plane, same as Mirror's mirror-plane input already does, no new
reference type needed) rather than every stage defaulting to one straight
line. **Turn-angle UX — resolved** (was open, see §6): one always-visible
numeric field per stage after the first, default 0° = continue straight
(no reveal/hide toggle — the default already gives a straight chain for
free), plus one chain-level "start direction" field for stage 1→2's own
heading. Angle is relative to the *previous segment's own direction*
(turtle-graphics style, not absolute within the plane), so inserting or
removing a stage elsewhere in the chain never changes what an untouched
stage's own angle means. Sign convention inherited rather than invented:
positive = counter-clockwise about the anchor plane's normal, exactly
matching `RevolveFeature.angle`/circular `PatternFeature`'s existing
right-hand-rule convention (both already rotate via OCCT's own `gp_Ax1`).
No bespoke angle-range validation — a sharp reversal is exactly what the
interference check below exists to catch. Text-entry only, no visual
drag/dial control, for v1. This is a materially bigger scope item than the
straight-line-only alternative would have been, for two concrete reasons:
- **Interference checking becomes mandatory, not optional — design
  resolved, not just a tolerance value picked.** The naive version of this
  check ("do two stages' addendum circles overlap?") can't actually
  distinguish a correctly meshing adjacent pair from a real collision:
  addendum radius = pitch radius + module, so a *correctly meshing* pair's
  addendum circles always overlap by design (`sum of addendum radii =
  center_distance + 2×module` — teeth interleave, that's the whole point).
  Tuning a fuzzy "how much overlap is OK" threshold can't resolve that
  ambiguity, because a correct mesh and a collision look geometrically
  identical to that test. The chain's own topology already disambiguates
  it for free, so the check splits in two instead of needing a tolerance:
  - **Consecutive stage pairs**: no check at all. Their correctness is
    guaranteed by `gear_math`'s own exact center-distance formula, not
    re-verified by a geometric collision test after the fact — the same
    trust this doc already places in that formula everywhere else.
  - **Every non-adjacent pair**: a plain, exact overlap test (zero
    tolerance — any overlap at all is a genuine problem, there is no
    legitimate reason for these to be close), *plus* a small default
    **print-clearance margin** (flagging pairs that come within e.g. 0.2mm
    without literally overlapping — "geometrically fine" isn't the same as
    "printable," and FDM/manufacturing needs real gap, not mathematical
    zero) — both non-blocking warnings, same banner convention as every
    other gear validation.

  The "occupied shape" checked also isn't the same for every stage type,
  worth being precise about rather than treating every stage as a generic
  circle: an **external** gear's addendum circle (its teeth point outward
  — the part that can hit a neighbor); an **internal** gear's *outer rim*
  circle, not its addendum circle (its teeth point inward into its own
  bore, so the addendum circle can't collide with anything external — the
  rim can); a **rack**'s oriented bounding rectangle along its length
  (addendum-to-dedendum band width), not a circle at all. No existing
  precedent for any of this to reuse anywhere in this codebase — genuinely
  new geometry-validation code.
- **The 2D preview (Workstream 8) needs to render an actual routed path**,
  not a single line — each stage's center comes from the previous stage's
  center + center-distance + the stage's own turn angle, and the preview
  should visually flag any interfering pair it detects (e.g. highlighting
  the offending gears), so a bad route is *seen*, not just rejected by a
  banner after the fact.

A fully general, drag-to-route interactive path editor (dragging gear
positions directly in the preview canvas rather than typing angles) is a
plausible later UI-only enhancement over the same underlying data shape —
not attempted in v1, deliberately, per the resolution above.

**`PlanetaryGearFeature`** — kept as its own Feature type, not folded into
`GearChainFeature`, because its topology is genuinely different: branching
(sun meshes every planet, every planet meshes the ring), not a sequence.
Sun/ring tooth counts + planet count in, validates the assembly condition
(Workstream 1) and evenly spaces planets around the sun at the correct
radius, resolving into N+2 positioned Bodies (sun, ring, N planets) in one
pass, same multi-body convention as `GearChainFeature`. Static/positioned
only — no kinematics/rotation, matching the static-print-and-design scope
of the original request. Planetary topology structurally requires one
shared module across sun/planets/ring (no `GearGroup`-style module change
makes sense within a fixed sun/planet/ring relationship the way it does
along a chain), so `GearGroup` is a `GearChainFeature`-only concept, not
shared with this Feature type.

**Compound gears — in v1 scope** (revised from an earlier draft of this
doc, which deferred the geometry to a later phase; pulled forward per an
explicit later decision, against this doc's own recommendation to defer —
recorded honestly as a deliberate risk accepted, not a default). A
compound gear (two or more gears rigidly fused coaxially on one shaft —
the incoming mesh from one station connects to one member, the outgoing
mesh to the next station originates from the other, the two members never
mesh with each other) is exactly the case `GearGroup` above exists to
support: a compound station is the point where a chain crosses from one
group to another, since its two coaxial members are free to differ in
module without needing to mesh.

Concretely, in scope now: a stage-list item type becomes a discriminated
union (single-gear stage, as already scoped, or a compound stage holding
*two* gear specs — each its own type/teeth/width/hand/`group_id` — plus an
axial stacking-offset parameter between them along the shared shaft axis);
cross-group mesh validation at a compound join (the two members' own
`group_id`s must each match their respective neighbour's, and must differ
from each other — a compound station whose two members share a group
would just be an ordinary single-gear station, structurally meaningless);
the compound-aware ratio/direction rule for Workstream 8's preview (never
reverses direction, since both members are rigidly fused and always
co-rotate, but changes the ratio by the two members' own tooth-count
difference — a distinct case from an ordinary meshing link, not a variant
of the same formula). Merge behaviour: **fuse into one Body by default**
(matches what a compound gear physically usually is when printed/machined
as one part — one hub, two diameters), overridable to keep the two members
as separate Bodies (e.g. pressed onto a common keyed shaft, also a real,
common construction) via the existing `MergeMode` field Pattern/Mirror
already expose — reused, not invented, same as `GearGroup`'s own reuse of
an existing pattern.

**Two genuinely unspiked unknowns, now real v1 blockers rather than
someday-questions — both need resolving during this workstream, not
discovered mid-implementation:**
- **Structural transition between the two diameters.** A large module
  difference between the two members leaves a step (or, worse, a thin
  unsupported overhang) at the join — printability likely needs a fillet/
  chamfer transition or a minimum-hub-thickness rule between them, neither
  of which this codebase has any existing precedent for (no manufacturing-
  constraint validation exists anywhere in this app today). Needs its own
  small design pass — most likely a minimum-thickness check (warn, same
  non-blocking-banner convention as every other gear validation) plus an
  optional fillet at the join, rather than a hard constraint.
- **DXF export for a compound station doesn't obviously reduce to one
  profile.** Per-gear cut files (Workstream 6) assume one 2D profile per
  gear; a compound station's two members sit at *different depths* along
  the shaft, not in the same 2D plane, so "the DXF for this station" is
  ambiguous by default. Likely resolution: still two separate per-member
  DXF files even when the 3D solid is fused (matching how the members are
  actually cut/printed as two profiles regardless of whether the final
  assembly is fused) — but this needs an explicit decision, not an
  assumption, before Workstream 6's export code is written against a
  compound-aware `GearChainFeature`.

**Complexity/risk:** high for `GearChainFeature` (bent paths + interference
checking are both genuinely new problems for this codebase, not reuse of
an existing pattern) **and now also high for compound-station geometry
within the same workstream** (coaxial stacking, cross-group validation,
the two genuinely unspiked unknowns above — structural transition and
DXF-per-compound-member — neither previously investigated at all) — v1
now carries *three* separate "genuinely new OCCT/geometry technique, real
correctness risk" items in total across this doc (alongside Workstream
4b's Loft/helix-sweep spike), not two; worth two real spikes here, not
one — bent-path/interference as already planned, *plus* a small standalone
compound-station spike (two coaxial gears, one fuse, one structural-
transition check) before committing the full chain UI/DXF export to depend
on it. Medium for `PlanetaryGearFeature` (no new geometry-kernel work,
mostly correct application of Workstream 1's math plus Workstream 2's
per-gear-type geometry builders, reused via the same shared-helper pattern
`ExtrudeFeature`/`RevolveFeature`/`SweepFeature` already use for their own
common Boss/Cut logic). Low for `GearGroup`'s own schema in isolation (a
small referenced record and a "same group" mesh-validation check) — it's
compound-station geometry specifically that carries the real added cost
from this decision, not the group concept itself.

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

**Block-selection design resolved** — turned out to be mostly reuse of an
existing mechanism, not the new selection-semantics concept this doc
originally flagged it as. Grounded in a direct audit of the client's
selection architecture (`client/lib/viewport3d/selection_hit_test.dart`,
`client/lib/sketch/sketch_controller.dart`): `SketchSelection`
(`{kind, id}`) is a flat list with no compound/grouped-selection container
anywhere; Rectangle/Polygon/Slot are deliberately *not* selected as a
unit (tapping one selects a single constituent Line/Point, confirmed by
`SketchRectangleView`'s own doc comment); Pattern/Mirror's `ownerInstanceId`
grouping (`_patternMirrorEntityAt`, `hitTestSketchPatternMirrorInstances`)
is the one real "many hit regions → one id" precedent, but only works
because those instances are pure ghost geometry with no independent
underlying primitives — not applicable here, since a DXF block's curves
need to be real, individually addressable entities for Convert Entities to
reach. None of these three fit directly. What does: `SelectionEntityKind.
body` (`selection_hit_test.dart`) already exists and is already "select the
whole thing as one unit" — normally a tap resolves to a specific face/
edge/vertex, but with `SelectionFilterState.body` engaged, it resolves to
the whole owning Body instead (already used for e.g. Boss/Cut target-body
picking). Convert Entities (`convert_body_edge`/`convert_body_vertex`,
`backend/app/document/router.py`) is already Body-edge-to-Sketch, one edge
per tap, and is structurally *separate* from ordinary viewport
tap-selection (`SketchMode.convert` is its own dedicated picking mode).
Both halves of the requirement already exist — they just aren't wired
to the same object yet.

**Resolved design, four pieces:**
1. DXF import stays a new `ImportSourceFormat.DXF` value on the *existing*
   `ImportFeature` (no new Feature type) — confirms this workstream's
   original plan: a lightweight, non-solid reference `Body` (a wireframe/
   compound of real OCCT edges, no volume — `ImportFeature` already
   round-trips STEP/glTF/OBJ/STL into a `Body` the same way).
2. **`ImportFeature` gains placement fields** (translation, rotation,
   uniform scale — matching `TextEntity`'s own existing "uniform-scale-
   about-center" convention, since non-uniform scale would distort a
   mechanical drawing's proportions), applied to the parsed shape before
   it registers as a Body. Genuinely new, but small and general-purpose —
   benefits STEP/mesh imports too, not just DXF, and directly fulfils
   `ImportFeature`'s own docstring, which already named "move body" as an
   anticipated-but-deferred capability ("future features will be able to
   edit existing bodies (scale, move face, delete face, move body)").
   **This is what "moved, rotated, and scaled as a block" actually cashes
   out to** — editing this Feature's own placement via a small dedicated
   panel (same convention as every other panel in this app), not dragging
   loose sketch points (which would hit the exact known "associative point
   drag snaps back on next solve" gap this doc's grounding audit already
   found elsewhere in this codebase — deliberately avoided by never
   treating a block's rendered geometry as directly draggable at all).
3. **"Selects as one" — one small, targeted rule**, not a new selection
   paradigm: a Body whose originating Feature is a DXF `ImportFeature`
   always resolves as `SelectionEntityKind.body` on an ordinary tap,
   regardless of the general `SelectionFilterState` — necessary because a
   DXF-sourced Body is wireframe-only (no faces at all to hit-test
   against), so without this override, ordinary tapping would fall
   through to individual-edge picking by default instead. Applies
   everywhere the Body is visible, not context-restricted to "while
   editing its home sketch" specifically — there's no real need for that
   narrower scoping once the rule is this simple.
4. **"Individually elsewhere, via Convert Entities" — completely
   unmodified.** Pick one edge of the DXF Body at a time, exactly like
   picking an edge from any other Body today. Zero new scope.

**Complexity/risk:** medium, downgraded from this doc's original "high...
needs its own focused design pass" — the research this round found the
hard-sounding part was mostly already-existing machinery, not a genuinely
new concept. What's left is real but bounded: the DXF parsing itself
(`ezdxf`'s reader — already known to be comparatively straightforward),
`ImportFeature`'s new placement fields (small, additive), and the one
targeted whole-body-selection override (item 3) — none of which carry the
"nothing like this exists anywhere in this codebase" risk profile
Workstream 10's bevel construction does.

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

**Group color-coding.** Each stage's outline is tinted by its `GearGroup`'s
`display_color`. A no-op visually for v1's single-implicit-group chains
(everything one color), but the mechanism costs nothing to build now and
is what makes a future multi-group/compound chain self-explanatory at a
glance later — the color change *is* the compound joint, no need to read
fields to find where a chain's module changes.

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

### Workstream 10 — Bevel gear math + `BevelGearFeature` (straight bevel)

**Pulled into v1** (revised from this doc's original "deferred phase"
treatment, per an explicit later decision — straight bevel only, not
spiral/Zerol/hypoid, which stay deferred as their own further-later phase;
see §2 decisions 14-17). This workstream is where this doc's original
"needs its own dedicated scoping pass" note (recorded when bevel was still
deferred) finally gets done, rather than staying a placeholder.

**Why this is structurally unlike every other gear type in this doc.**
Every other gear type builds a flat 2D tooth profile and turns it into a
solid via an operation this codebase already has some version of (Extrude
for external/internal/rack, Sweep/Loft for helical/herringbone). A bevel
tooth has no such flat profile at all — its flank is a genuinely 3D
curved surface on a cone, so there's no "make the 2D shape, then run an
existing operation" shortcut. The math and the OCCT construction are both
real, first-time work for this codebase.

**Math** (`app/document/bevel_math.py`, OCCT-free, mirrors `gear_math.py`'s
own split): the **spherical involute** — a curve generated by rolling a
plane on a base cone (rather than a base cylinder, as the planar involute
does), living on the surface of a sphere centred at the cone apex, not in
a flat plane. Also: pitch cone half-angles from tooth counts and shaft
angle (`γ1 = atan(sin(Σ) / (N2/N1 + cos(Σ)))`, `γ2 = Σ − γ1` — the general
form for **arbitrary shaft angle Σ**, per this round's decision; reduces
to the familiar `γ1 = atan(N1/N2)` at Σ=90°, a useful known-value check for
the test suite this needs); addendum/dedendum cone angles; and a face-width
bound relative to cone distance (a face width too large relative to the
cone distance thins the tooth toward degeneracy near the apex — needs a
real bounds check, non-blocking-banner warning, same convention as every
other gear validation in this doc, not a hard limit). Like Workstream 1,
this needs a real reference-value test suite (known standard bevel gear
dimensions), not just "it runs" — arguably more important here than
anywhere else in this doc, since there's no existing precedent anywhere in
this codebase to sanity-check the derivation against.

**OCCT construction** (`app/document/bevel.py`): sample the spherical
involute at the outer (back) cone and at the inner cone (back cone
distance − face width) — two genuine 3D space curves per tooth flank on
the generating sphere, not planar profiles — then build each flank as a
ruled/lofted surface between them. `BRepOffsetAPI_ThruSections` (already
scoped for Workstream 4b's Loft) may actually be reusable here after all —
it isn't strictly limited to planar cross-sections — but this is
genuinely unconfirmed and needs its own spike, not an assumption, since
self-intersection risk on a tight cone is real. Full gear body assembly
(N teeth around the cone, flank surfaces stitched into a closed shell,
addendum/dedendum cone surfaces capping top and bottom) is real BRep
shell/solid construction from curved surfaces directly — closer to
raw kernel work than any other Feature in this codebase, all of which
extrude/revolve/sweep/loft a profile rather than assembling a shell from
scratch.

**`BevelGearFeature`**: six-part checklist as usual. Parameters: module
(back-cone equivalent), tooth count, pressure angle, face width, backlash,
profile shift, and **pitch cone angle as a direct field** (a standalone
bevel gear doesn't know its future meshing partner, so it can't derive its
own cone angle the way Workstream 11's pairing system will — Workstream 11
computes and sets this automatically when generating a pair together,
mirroring how `GearChainFeature` computes center distance rather than
having the user enter it).

**Complexity/risk:** the highest in this entire document, worth saying
plainly rather than folding into a generic "high" alongside everything
else. Every other hard item in this doc found something existing to reuse
— `PlaneRef`, `MergeMode`, Pattern/Mirror's multi-body pattern,
`RevolveFeature`'s angle convention, `ExternalVertexReference`. Bevel
construction largely can't: there's no shell-from-curved-surfaces
precedent anywhere in this codebase to build on. Budget real, dedicated
spike time before committing the rest of Workstream 11 to depend on this
approach working.

### Workstream 11 — `BevelPairFeature`: automated live bevel pairing

**Pulled into v1**, and scoped as a **pair specifically (exactly 2
members), not a generalized N-stage chain** — deliberately narrower than
`GearChainFeature`. Bevel trains longer than two gears are a genuinely
rarer, more exotic case than planar chains, and routing a 3D path through
multiple arbitrary shaft angles would import all of `GearChainFeature`'s
bent-path/interference-check complexity into a second, geometrically
unrelated (intersecting-axis, not parallel/coplanar) case — a much bigger
scope expansion than "mirror what GearChainFeature does" was asking for.
If a longer bevel train turns out to be wanted later, it's an additive
extension of this Feature type, not a redesign.

Mirrors `GearChainFeature`/`PlanetaryGearFeature`'s own live,
re-derivable pattern (one Feature, resolved fresh into multiple Bodies on
every recompute, via the same Pattern/Mirror precedent) — editing one
gear's tooth count live-recomputes both members' pitch cone angles and
repositions/resizes automatically. Module and pressure-angle are **flat
shared fields on the Feature itself, not a `GearGroup` reference** —
deliberately simpler than `GearChainFeature`'s own group indirection,
since a pair always has exactly two members that always mesh with each
other; there's no third station for a module change to happen at, so
`GearGroup`'s whole reason to exist (module changing partway through a
chain) doesn't apply here. Shaft angle: user-specified, **arbitrary** per
this round's decision, feeding directly into Workstream 10's cone-angle
formula. Position: apex-aligned — both gears' cone apexes coincide at one
point, axes intersecting at the specified shaft angle, anchored via a
`PlaneRef` for the apex/primary-axis orientation (reusing the same
reference type Mirror/`GearChainFeature` already use, no new reference
kind invented). Interference checking: **not needed at all** — with
exactly two members that are always the intended meshing pair, there's no
"non-adjacent stage" case for `GearChainFeature`'s own interference
machinery to apply to; a genuine simplification worth stating explicitly
rather than leaving as a silent gap.

**Kept fully separate from `GearChainFeature`**, per this round's decision
— a chain that needs to turn a real 3D corner places a `BevelPairFeature`
alongside a `GearChainFeature` rather than the chain gaining a bevel stage
kind. Avoids extending the already-high-risk bent-path/interference-check
work (designed around one shared plane) to a structurally different
intersecting-axis case it was never built to handle.

**A real unresolved unknown, same shape as the compound-gear DXF
question**: a bevel gear has no flat 2D "cut profile" the way planar gears
do — its teeth are curved 3D surfaces on a cone, not extruded from an
outline. Likely resolution: represent a bevel gear's DXF export as the
back-cone tooth profile's **flat pattern/development** (a cone "unrolled"
flat — a standard bevel-gear drafting technique real technical drawings
already use), which is itself new geometry work (computing a cone's flat
development), distinct from anything else Workstream 6 needs for planar
gears. Needs resolving during this workstream, not assumed.

**Complexity/risk:** high — real new positioning/validation logic
(simpler than `GearChainFeature`'s own in some ways, per the no-
interference-check simplification above, but built on Workstream 10's
still-unproven construction approach) plus the DXF flat-pattern question
above, itself unspiked.

---

## 5. Suggested delivery order

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
5. **Four parallel spikes, all specifically *because* they're the
   highest-risk unknowns** — better to find a showstopper early than after
   committing. v1 now carries four separate "genuinely new OCCT/geometry
   technique" items in total (up from two at this doc's original draft):
   - **Workstream 4b** (Loft/helix-sweep feasibility for helical teeth).
   - **Workstream 5's `GearChainFeature` bent-path + interference-check
     approach** — a small standalone spike (a handful of stages, a couple
     of turn angles, confirm the circle-overlap interference check and the
     `PlaneRef`-anchored routing math both hold up) before committing the
     full chain UI/preview to depend on it.
   - **Workstream 5's compound-station spike** — two coaxial gears, one
     fuse, one structural-transition check between very different
     diameters — specifically to de-risk the two genuinely unspiked
     unknowns (structural transition, DXF-per-compound-member
     representation) before the chain schema/UI/export are built assuming
     an approach that turns out not to work.
   - **Workstream 10's bevel spike** — the highest-risk item in the whole
     doc (§ Workstream 10's own complexity/risk note): confirm the
     spherical-involute construction and the ruled/lofted tooth-flank
     approach (whether `BRepOffsetAPI_ThruSections` genuinely handles this,
     or something else is needed) before any of Workstream 11's pairing
     logic or Workstream 6's flat-pattern DXF question are built on top of
     an unproven foundation.
6. **Workstream 4** (helical/herringbone) once 4b's spike lands.
7. **Workstream 5** (`GearChainFeature` — covers pairs, rack-and-pinion,
   N-stage chains, and compound stations in one Feature type, plus its
   `GearGroup` schema — then `PlanetaryGearFeature`) once both of its own
   spikes land — depends on Workstream 2 (internal + external gears) and
   Workstream 3 (rack) for the per-stage geometry it positions.
8. **Workstream 10** (`BevelGearFeature`, straight bevel) once its own
   spike lands — no dependency on Workstreams 2-5, since bevel's
   construction pipeline shares no code with any other gear type (see
   Workstream 10's own "why this is structurally unlike every other gear
   type" note); could in principle run earlier in parallel with 2-7, but
   sequenced after them here since it's the doc's single highest-risk item
   and benefits most from the rest of the tool (preview, DXF, presets)
   already existing to slot into rather than being built in isolation.
9. **Workstream 11** (`BevelPairFeature`) once Workstream 10 is live —
   depends on it the same way Workstream 5 depends on Workstream 2.
10. **Workstreams 6-7** (DXF export — per-gear cut files including the
    compound-member and bevel-flat-pattern representations resolved above,
    the combined layout export, then DXF import-with-blocks) — independent
    of the gear-specific work above; can run on its own track in parallel,
    and Workstream 6's per-gear export in particular could ship early
    since the existing "2D Drawing" tool wants a DXF writer regardless of
    gears.
11. **Spiral/Zerol/hypoid bevel** — the one variant still deliberately
    deferred in this entire doc (§2 decision 14), a further-later phase
    after Workstream 10/11's straight-bevel foundation is live.

---

## 6. Open questions to resolve during detailed design (not blocking this
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
- ~~Exact turn-angle input UX...~~ **Resolved.** One always-visible numeric
  "turn angle" field per stage after the first (default 0° = continue
  straight — no toggle to reveal/hide it; leaving the default alone already
  gives a straight chain, the same shape as every other per-stage field
  this tool already has), plus one chain-level "start direction" field
  (stage 1→2's own heading, since a relative turn needs something to be
  relative *to*). Reference frame is **relative to the previous segment's
  direction** (turtle-graphics style), not absolute within the plane — the
  only choice that keeps every stage's meaning stable when a stage is
  inserted/removed elsewhere in the chain. Sign convention inherited, not
  invented: positive = counter-clockwise about the anchor plane's normal,
  matching `RevolveFeature.angle`/circular `PatternFeature`'s existing
  right-hand-rule convention (OCCT's own `gp_Ax1`-based rotation, already
  used both places). No bespoke angle-range validation — a sharp reversal
  is exactly what the interference check (below) exists to catch, not a
  separate bounds check to invent. Text-entry only for v1, no visual
  drag/dial control (a plausible later enhancement over the same data, not
  required now).
- ~~The precise interference-check tolerance...~~ **Resolved — not a
  tolerance value, a topology split.** A fuzzy "how close is too close"
  threshold can't distinguish a correctly meshing pair from a collision
  (their addendum circles overlap identically either way, by design of
  meshing teeth) — the chain's own topology already disambiguates it for
  free instead: skip consecutive stage pairs entirely (trusted to
  `gear_math`'s exact center-distance formula), exact zero-tolerance
  overlap test for every non-adjacent pair, plus a small default
  print-clearance margin (e.g. 0.2mm) beyond pure geometric overlap for
  manufacturing practicality. Per-stage-type bounding shape (addendum
  circle / outer rim circle / rack bounding rectangle), also resolved. See
  Workstream 5's own interference bullet for full reasoning.
- ~~Can an internal gear appear mid-chain?~~ **Resolved** — no, last stage
  only; see Workstream 5's "Internal (ring) stages" note.
