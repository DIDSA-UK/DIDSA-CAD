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
   see Workstream 8.
4. **DXF import: full "block" semantics.** A DXF import lands as one
   selectable/movable/rotatable/scalable unit in its own home sketch, while
   individual curves become pickable elsewhere via the existing Convert
   Entities tool — reusing the `ExternalVertexReference` mechanism rather
   than inventing a new one.

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
sampled profile points into OCCT edges/wire (likely a `BSplineCurve`
through the sampled involute points, or straight edges if enough points are
sampled — a design choice to make during implementation, trading file/mesh
size against curve fidelity) and extrudes via the same `BRepPrimAPI_MakePrism`
path `ExtrudeFeature` already uses. Internal gears: an annulus profile
(outer rim boundary + inward-facing involute tooth boundary) built as one
Boss, not a separate Cut step.

**Complexity/risk:** medium-high for the OCCT curve/profile assembly
(getting wire winding direction and start/end continuity right around a
full gear — 20+ repeated tooth profiles stitched into one closed wire — is
fiddly, matching this codebase's own noted experience with e.g. Slot/Polygon
closed-form geometry); low for Boss/Cut integration, which is copy-paste
from `ExtrudeFeature`'s existing pattern.

### Workstream 3 — Rack, and rack-and-pinion pairs

Rack: same `GearFeature`-family Feature but a linear trapezoidal-tooth
profile (from `gear_math`'s rack generator) over a specified length instead
of a full disc. Rack-and-pinion "pair": client/orchestration-level, not a
new backend Feature type — creates one rack `GearFeature` and one external
`GearFeature`, plus a `CreatePlaneFeature` positioning the pinion's pitch
circle tangent to the rack's pitch line at the correct center distance.

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

### Workstream 5 — Planetary gear sets (orchestration, not new gear math)

Client (or a thin backend orchestration endpoint) that, given a module,
sun/ring tooth counts, and planet count, validates the assembly condition
(Workstream 1), computes each planet's `GearFeature` + position (via
`CreatePlaneFeature`, evenly spaced around the sun at the correct radius),
and creates: one external `GearFeature` (sun), one internal `GearFeature`
(ring), N external `GearFeature`s (planets), each correctly positioned.
Static/positioned only — no kinematics, no rotation/motion, matching the
static-print-and-design scope of the original request.

**Complexity/risk:** medium — mostly correct application of Workstream 1's
math plus repeated use of Workstream 2's `GearFeature`, no new geometry
kernel work. The one real design question: whether the app currently has a
clean way to programmatically add several Features to a Part in one
client-driven batch, or whether this needs a small new "batch create"
convenience — worth checking against `document_api_client.dart`'s existing
call shape during implementation.

### Workstream 6 — DXF export (shared with the existing "2D Drawing"
roadmap item)

`ezdxf`-based writer (new backend dependency), consuming either a gear's
own profile points (Workstream 1, bypassing the Sketch model entirely —
the profile never needs to become interactive Sketch geometry to be
exported) or a general Sketch's Points/Lines/Arcs/Circles/Ellipses/Splines/
Text (satisfying the pre-existing, separately-roadmapped "2D Drawing DXF
export" ask with the same writer). Multi-file export for pairs/sets/
planetary/rack-pinion: one DXF per gear, since that matches how a gear is
actually cut/printed/used downstream (each part on its own sheet/plate),
returned as a zip or as multiple endpoint calls — a UX decision for the
export dialog, not a backend architecture one.

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

### Workstream 8 — Gear Design entry screen (client)

New `ToolChooserScreen` tile → a parameter-entry screen with text fields
per gear type (module/teeth/pressure angle/etc., matching Workstream 1's
parameter set) and a live 2D preview canvas. The preview should run the
*same* `gear_math` formulas the backend uses (ported to Dart, or requested
from the backend on every field change like the existing sketch solve
round-trip does) rather than a separately-hand-rolled approximation, so
what the user previews is what they get — worth an explicit implementation
decision (client-side Dart port vs. backend round-trip) during detailed
design, trading offline/latency-free preview against a second copy of the
math to keep in sync (this codebase has an existing, explicitly-accepted
precedent for live-preview math duplication — see `docs/roadmap.md`'s
Pattern/Mirror "three duplicate translate/reflect implementations" entry —
so duplication itself isn't a blocker, just a known, named tradeoff).
"Create" adds a Part (or opens the current one) with the resulting
`GearFeature`(s), handing off to the normal `PartScreen` 3D-viewport flow.

**Complexity/risk:** medium. Mostly UI work following this codebase's
existing tool-panel/value-bar conventions (`ExtrudePanel`, `FilletPanel`,
etc.) rather than new concepts, plus the preview-duplication decision above.

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
technique the other gear types use) once Workstreams 1-8 are live and there's
a working gear tool to extend rather than build bevel support into
speculatively now.

---

## 6. Suggested delivery order

1. **Workstream 1** (gear math core) — no dependencies, fully unit-testable
   in this dev sandbox today, and everything else depends on it.
2. **Workstream 2** (external/internal `GearFeature`) — first real 3D gear,
   proves the Feature-tree integration end-to-end.
3. **Workstream 8** (entry screen + preview) in parallel with/right after
   Workstream 2, so there's a usable tool as soon as spur gears work rather
   than waiting for every gear type.
4. **Workstream 3** (rack/rack-and-pinion) — cheap extension of Workstream 2.
5. **Workstream 4b spike** (Loft/helix-sweep feasibility) early, in parallel
   with 2-4, specifically *because* it's the highest-risk unknown — better
   to find out if the twist-controlled Loft or helix-sweep approach has a
   showstopper before Workstream 4 is fully committed to depending on it.
6. **Workstream 4** (helical/herringbone) once 4b's spike lands.
7. **Workstream 5** (planetary) — depends on Workstream 2 (internal +
   external gears) and benefits from Workstream 4b's `CreatePlaneFeature`-
   positioning patterns if any were built along the way.
8. **Workstreams 6-7** (DXF export, then import-with-blocks) — independent
   of the gear-specific work above; can run on its own track in parallel,
   and Workstream 6 in particular could ship early since the existing "2D
   Drawing" tool wants it regardless of gears.
9. **Bevel** (§5) — separate phase, after the above is live.

---

## 7. Open questions to resolve during detailed design (not blocking this
scope doc, but not yet answered)

- Client-side preview: Dart port of `gear_math`, or live backend round-trip
  per field edit (Workstream 8)?
- Involute profile realized as a true `Geom_BSplineCurve` through sampled
  points, or dense straight-line segments? Affects file size, DXF fidelity,
  and mesh triangle count — worth a quick real-file comparison once
  Workstream 1/2 exist.
- Exact parameter set per gear type for v1 (e.g. is profile shift a v1
  requirement or a later refinement once undercut at low tooth counts is
  confirmed to actually be a problem worth surfacing to the user?).
- Whether "gear pairs/sets" need a saved, re-editable relationship (e.g.
  changing the sun's tooth count later re-derives the whole planetary set)
  or are a one-shot generator whose output Features are then independent,
  ordinary Part Features from that point on (simpler, matches this
  codebase's "re-derive the whole graph" recompute model less directly
  since there's no single upstream Feature the whole set depends on today).
