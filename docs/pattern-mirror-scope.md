# Pattern and Mirror — Scoping Document

Companion to a feature request covering: mirror about a plane, mirror about
a face, rectangular pattern, circular pattern, skip instances, straight
edges to define pattern direction, the ability to reverse direction, curved
edges/curved faces/axis lines to define circular-pattern axes, patterning
bodies, patterning features, patterning inside sketches, merge options, and
UX ideas. Same convention as `docs/sketcher-overhaul-scope.md`: broken into
engineering workstreams against the *actual current implementation*
(verified by reading the code, not assumed), with proposed approach,
affected files, complexity/risk, and a suggested delivery order.

Backend: `backend/app/document/*` (FastAPI + pythonocc-core/OCCT).
Client: `client/lib/viewport3d/*` (3D Feature panels/selection),
`client/lib/sketch/*` (sketch-level tooling).

**Status: design only — nothing in this document is implemented yet.**
Confirmed via direct grep across the whole backend, client, and `docs/`:
no `Pattern`/`Mirror`/`Array` Feature type, schema, endpoint, or geometry
module exists anywhere, and no prior planning stub mentions one beyond a
single illustrative word in `docs/didsa-longterm-vision-and-model.md`'s
feature-tree diagram and a forward-looking part-metadata note in
`docs/roadmap.md`. This is genuinely greenfield scope.

---

## 1. Grounding: what already exists that Pattern/Mirror must plug into

- `Feature` (`backend/app/document/models.py:24`) is an abstract dataclass
  base. Every concrete Feature type (`SketchFeature`, `ExtrudeFeature`,
  `CreatePlaneFeature`, `FilletFeature`, `ChamferFeature`, `RevolveFeature`,
  `SweepFeature`, `ImportFeature`) follows an identical six-part checklist
  to plug into the system:
  1. A `@dataclass` subclass of `Feature` with `id`, a `type` property,
     `produces_solid_geometry: bool`, `produces: Produces` (BODY/PLANE/
     SURFACE/SKETCH/NONE).
  2. A `depends_on` branch in `build_feature_graph` (`graph.py:180`) naming
     every upstream Feature it references.
  3. A geometry-resolution module with the established
     `resolve_X_from_bodies(bodies, feature)` (the core — takes an
     already-computed `bodies` dict, never recomputes itself, to avoid
     infinite recursion from inside `compute_part_bodies`'s own loop) /
     `resolve_X(part, feature, excluded_feature_ids=frozenset())` (the
     fresh wrapper — calls `compute_part_bodies(part, excluded_feature_ids
     | {feature.id})`, self-excluding since most Features would otherwise
     double-apply against their own prior output) split.
  4. A branch inside `compute_part_bodies`'s topological loop
     (`extrude.py:664`) folding the result into `bodies`, catching and
     skipping-with-warning on a structured `HTTPException` for topology-
     drift resilience.
  5. Pydantic Create/Update/Response schemas in `schemas.py`, added to the
     `FeatureResponse` union.
  6. Router endpoints (create/update/get-or-404) following the
     validate→construct→eager-resolve-to-validate→persist (create) /
     merge→validate→mutate (update, never left half-updated on failure)
     pattern every other Feature type uses, plus a branch in
     `_feature_response`.

  Pattern and Mirror are two more entries in this same checklist, not a
  new architecture.

- **`Part.is_locked`** (`models.py:713`): only the *last* Feature in
  `part.features` may be edited/deleted; everything before it is locked
  once something is appended after it. Pre-existing, Pattern/Mirror-
  independent — a Pattern feature, once something is stacked on top of it,
  becomes just as immutable as any other historical Feature; editing "the
  seed after patterning it" only works via rollback (already-existing
  mechanics), not a new problem this feature set introduces.

- **Recompute is a full graph walk, every time** (`compute_part_bodies`,
  `topological_order`/`build_feature_graph`, `graph.py:70`/`180`): Kahn's-
  algorithm topological sort over `GraphNode.depends_on` edges, tie-broken
  by original list order. No dirty-flag incremental recompute anywhere —
  "re-derive, don't cache." This is what gives Pattern/Mirror seed-edit
  associativity for free (see §3's survey table entry on associativity).

- **Reference types to reuse verbatim — do not invent new ones except
  where noted below:**
  - `SubShapeRef{body_id, shape_type: EDGE|FACE|VERTEX, index}`
    (`models.py:191`) — resolved via `resolve_subshape_from_bodies`
    (`extrude.py:969`, 1-based `topexp.MapShapes` index), fails closed
    with structured `missing_reference` 422 if the body/index isn't valid
    against current topology (an accepted, documented limitation — "not
    guaranteed stable if the body's own face/edge topology changes
    shape," per the field's own docstring). This is exactly the "pick an
    edge/face of a Body" primitive Pattern's direction-edge and Mirror's
    mirror-face both need.
  - `PlaneRef{face_ref: SubShapeRef | fixed_plane: Plane |
    plane_feature_id: str}` (`models.py:294`) — "exactly one of three,"
    resolved via `_resolve_plane_ref`/`resolve_offset_face`
    (`create_plane.py:190`,`146`) into a `ResolvedPlane{origin, normal,
    x_axis, y_axis}`. **This is the exact type Mirror's "mirror plane"
    input should be** — it already unifies a fixed XY/XZ/YZ plane, a
    planar Body face, and an existing `CreatePlaneFeature` behind one
    resolver. "Mirror about plane" and "mirror about face" both fall out
    of this one field with zero new backend code.
  - `SketchEntityRef{sketch_id, entity_type, entity_id}`
    (`app/sketch/models.py:710`) — already used by `RevolveFeature.
    axis_ref` (restricted to `LINE`, `revolve.py:104`) and
    `SweepFeature.path_refs`. The precedent for "use a Sketch Line as a
    pattern direction/axis."
  - `resolve_normal_to_edge_through_vertex_from_bodies`'s straight-edge
    check (`create_plane.py:321-344`): `BRepAdaptor_Curve(edge).GetType()
    != GeomAbs_Line` → raise a structured `non_linear_edge` 422. Reuse
    this exact idiom for Pattern's "use a straight edge to define
    direction" validation.
  - `resolve_circular_edge_arc` (`extrude.py:1017-1075`, built for the
    sketcher's edge-dimensioning work) already extracts a circular Body
    edge's center (`circle.Location()`) and axis
    (`circle.Axis().Direction()`) from a `SubShapeRef`. Directly reusable
    (via a thin new wrapper that stops after the raw OCCT extraction,
    without the function's extra basis-projection step) for Circular
    Pattern's curved-edge axis source.
  - `RevolveFeature._resolve_axis` (`revolve.py:81-127`) is the complete
    precedent for "resolve a rotation axis from a Sketch Line, fail
    closed as `invalid_axis_ref`." Circular Pattern's Sketch-Line axis
    source should be a near-verbatim copy.

- **No OCCT rotation/mirror transform code exists yet** — only
  `gp_Trsf.SetTranslation` (`extrude.py:395`) and a hand-rolled affine
  matrix for text (`extrude.py:159`). Pattern/Mirror are the first
  features needing `gp_Trsf.SetRotation(gp_Ax1, angle)` and
  `gp_Trsf.SetMirror(gp_Ax2 | gp_Ax1)`, applied via
  `BRepBuilderAPI_Transform(shape, trsf, True).Shape()` per instance,
  optionally fused via `BRepAlgoAPI_Fuse` (the same call
  `_apply_boss_or_cut` already uses, `extrude.py:644`).

- **Body identity for N instances is a genuinely new problem.** The only
  existing "one Feature, many Bodies" precedent is `_register_solids`'s
  `#N` suffix (`extrude.py:578`) for *accidental* multi-solid splits (a
  multi-profile Boss, a severing Cut) — every instance there is
  geometrically independent, none of them is conceptually "the same Body,
  N times" the way pattern instances are. `base_feature_id`
  (`graph.py:110`) already strips *any* `#N` suffix generically, so
  reusing `f"{feature.id}#{i}"` for pattern instance N is mechanically
  free on the resolution side, but is a semantic overload worth a
  deliberate naming-scheme decision (see §6.6's Phase 2 note) — a client
  reading a Body id today has no way to distinguish "accidental split
  piece 2" from "pattern instance 2."

- **Cascade delete already generalizes for free.** `transitive_dependents`
  (`graph.py:365`) walks `depends_on` edges generically — once Pattern's
  `build_feature_graph` branch correctly declares its dependency on the
  seed Feature(s) and its direction/axis/plane reference's owning
  Feature, deleting the seed already cascade-deletes the Pattern/Mirror
  feature with zero new mechanism.

- **Client panel convention**: one dedicated small `StatefulWidget` file
  per Feature type (`fillet_panel.dart`, `chamfer_panel.dart`,
  `extrude_panel.dart`, `revolve_panel.dart`) — Confirm/Cancel session
  shape, fields fire `onChanged` immediately, `PartScreen` (the
  orchestrator) owns debouncing/PATCH/preview-refresh. Explicit
  duplicate-rather-than-share convention (Chamfer is "a full mirror of
  Fillet's already-fixed implementation"). `pattern_panel.dart`/
  `mirror_panel.dart` should be new files following this shape exactly,
  not a shared "transform panel" abstraction. Boss/Cut-style features use
  `SegmentedButton<XType>` for mode toggles — reuse for Rectangular vs.
  Circular pattern mode.

- **Live-preview decision tree** (`docs/live-preview-pattern.md`): the
  deciding question is "does live-edit let the user re-pick sub-shapes of
  the *same* Body the Feature is currently modifying?" **Pattern and
  Mirror both answer No** — they consume an already-resolved upstream
  seed Body's whole shape, they don't ask the user to re-pick edges/faces
  of the pattern's own output. This resolves cleanly to the **simple
  `isPreviewMesh` path** (Extrude's shape: the live "bodies" list *is*
  the actual current result, rendered translucent via
  `PartViewport.isPreviewMesh`) — **no dual-mesh preview-overlay
  machinery needed**, a load-bearing simplification for the client
  implementation's complexity estimate.

- **Selection gating currently has a hole for Body-only selections.**
  `contextActionsFor` (`selection_actions.dart:62`) is the single function
  deciding which operations a selection offers; today it has an explicit
  early return of nothing (`if (selection.any((s) => s.kind ==
  SelectionEntityKind.body)) return const [];`, line 74) for a Body-only
  selection. Pattern/Mirror need a new branch here: "1+ Bodies selected,
  nothing else" → offer Pattern/Mirror.

- **Multi-select is already a real accumulator.** `PartScreen.
  _selectedEntities` is a `Set<SelectionEntityRef>`, toggled by
  `_toggleSelectedEntity` — already what Fillet/Chamfer's "1+ edges" and
  Extrude/Revolve/Sweep's Cut "1+ target Bodies" both use. Directly
  reusable for "pick multiple seed bodies/features." Box-select was tried
  three separate times and explicitly abandoned
  (`docs/archive/status-2026-06-30-box-selection-report.md` — three
  different projection/hit-test bugs, "not robust enough to rely on, let's
  park it for now") — plan on tap-toggle only, not a rectangle-select
  shortcut for picking many pattern seeds at once.

- **Sketch-level tooling precedent.** Sketch tools live in one controller
  (`sketch_controller.dart`'s `SketchMode` enum: select/draw/dimension/
  trim/convert/offset), entered via `sketch_speed_dial.dart`'s FAB "Tools"
  grid. **Offset Entities is the right template** for sketch-level
  Pattern/Mirror (not Convert/Trim, which commit immediately on a single
  tap) — it accumulates picks into a selection set, has a "Finish" FAB,
  then shows a non-modal bottom `Material` bar
  (`sketch_offset_bar.dart`'s `OffsetValueBar`) with parameter fields and
  a live ghost-preview computed **client-side** (the sketch's own
  geometry code, not a backend round-trip per keystroke — different from
  the 3D-Feature preview above).

---

## 2. Design per required scope item

### 2.1 Mirror about a plane / Mirror about a face

**Backend data model.** New `MirrorFeature` dataclass in `models.py`,
modeled on `RevolveFeature`'s shape but without a Boss/Cut mode — a
mirrored Cut doesn't make sense as its own operation; a user who wants to
mirror a Cut's *effect* mirrors the Body that already reflects it:

```python
@dataclass
class MirrorFeature(Feature):
    id: str
    source_body_ids: list[str]      # bodies to mirror (v1: exactly one, see Phase 1)
    source_feature_ids: list[str]   # features to mirror, resolved to their output bodies (Phase 6)
    mirror_plane: PlaneRef          # reuse verbatim — face, fixed plane, or CreatePlaneFeature
    merge: MergeMode                # KEEP_SEPARATE | FUSE_INTO_SOURCE (Phase 5; default KEEP_SEPARATE)

    @property
    def type(self) -> str: return "mirror"
    @property
    def produces_solid_geometry(self) -> bool: return True
    @property
    def produces(self) -> Produces: return Produces.BODY
```

`mirror_plane: PlaneRef` is the single biggest reuse win in this design —
"mirror about a fixed plane," "mirror about a Body face," and "mirror
about an existing Plane feature" are all the same field, exactly matching
the requirement, with zero new reference-resolution code.

**Dependency graph.** New branch in `build_feature_graph`: depends on
`base_feature_id(bid)` for every `source_body_ids`/`source_feature_ids`
entry, plus the plane reference's owning Feature (the existing
`_plane_ref_dependency` helper, reused verbatim).

**OCCT geometry** (new `backend/app/document/mirror.py`, same
`_from_bodies`/fresh-wrapper split every other module uses):

```python
def resolve_mirror_from_bodies(bodies, part, feature, excluded_feature_ids):
    resolved_plane = _resolve_plane_ref(part, bodies, feature.mirror_plane, excluded_feature_ids)
    trsf = gp_Trsf()
    ax2 = gp_Ax2(gp_Pnt(*resolved_plane.origin), gp_Dir(*resolved_plane.normal))
    trsf.SetMirror(ax2)   # gp_Ax2 overload = mirror about a PLANE (gp_Ax1 = mirror about a LINE)
    mirrored = BRepBuilderAPI_Transform(source_solid, trsf, True).Shape()
    ...
```

New structured error: `mirror_failed` (422, matching the established
vocabulary), for the rare case the transform/fuse doesn't produce a valid
result. `missing_reference`/`non_planar_reference` are already correctly
raised by the reused `PlaneRef` resolution path — no new error needed
there.

**Client UX.** New `mirror_panel.dart` cloned from `fillet_panel.dart`'s
shell. `contextActionsFor` gains a "1+ Bodies selected" → offer "Mirror"
branch. Plane-picking reuses `CreatePlanePanel`'s existing face/fixed-
plane/Plane-feature pick UX verbatim (all three already render and
hit-test as pickable in the viewport today). Live preview: the simple
`isPreviewMesh` path, no overlay machinery.

**Open decisions**: (1) default merge mode — recommend `KEEP_SEPARATE`,
matching SolidWorks/Fusion/Onshape's own default; (2) a Body mirrored
across a plane running through its own volume can self-intersect —
`BRepAlgoAPI_Fuse`/`IsDone()` should catch this naturally via
`mirror_failed` rather than needing a dedicated pre-check.

### 2.2 Rectangular pattern

**Backend data model.**

```python
class PatternDirectionRef:
    """Exactly one of three, mirroring PlaneRef's own convention:"""
    edge_ref: SubShapeRef | None = None              # straight Body edge
    sketch_line_ref: SketchEntityRef | None = None   # straight Sketch Line
    fixed_axis: FixedAxis | None = None              # world X/Y/Z — cheap, obvious v1 addition

@dataclass
class PatternFeature(Feature):
    id: str
    source_body_ids: list[str]
    source_feature_ids: list[str]
    pattern_type: PatternType             # RECTANGULAR | CIRCULAR
    # Rectangular:
    direction_1: PatternDirectionRef | None = None
    count_1: int = 1
    spacing_1: float = 0.0
    reverse_1: bool = False
    direction_2: PatternDirectionRef | None = None   # two-direction linear pattern
    count_2: int = 1
    spacing_2: float = 0.0
    reverse_2: bool = False
    # Circular (§2.7):
    axis: PatternAxisRef | None = None
    count_angular: int = 1
    angle_total: float = 360.0
    reverse_angular: bool = False
    # Shared:
    skip_indices: list[int] = field(default_factory=list)   # §2.4
    merge: MergeMode = MergeMode.KEEP_SEPARATE               # §2.10
```

One `PatternFeature` type covers both Rectangular and Circular via a
`pattern_type` enum — mirroring `CreatePlaneFeature`'s existing "one
dataclass, many construction methods" precedent (six `PlaneType` values in
one type) rather than splitting into two Feature types. This also directly
respects `docs/didsa-longterm-vision-and-model.md` §6's explicit decision
against giving patterns their own family of semantic sub-types — one
ordinary Pattern Feature, not "Bolt Pattern" vs. "Cooling Pattern" as
distinct object types.

`PatternDirectionRef` is genuinely new — none of the existing three
reference types alone covers "an edge OR a sketch line OR a fixed world
axis." Built the same way `PlaneRef`/`PointRef` already are: frozen
dataclass, "exactly one of N fields," payload shape validated by the
router.

**OCCT geometry** (new `backend/app/document/pattern.py`):

```python
def _direction_vector(part, bodies, ref: PatternDirectionRef, excluded) -> gp_Dir:
    if ref.edge_ref is not None:
        edge = topods.Edge(resolve_subshape_from_bodies(bodies, ref.edge_ref))
        curve = BRepAdaptor_Curve(edge)
        if curve.GetType() != GeomAbs_Line:
            raise _non_linear_edge(ref.edge_ref)          # exact reuse of create_plane.py's idiom
        return curve.Line().Direction()
    if ref.sketch_line_ref is not None:
        ...  # resolve_sketch_basis + Line endpoints, same pattern as RevolveFeature._resolve_axis
    return _FIXED_AXIS_DIRECTIONS[ref.fixed_axis]

def resolve_pattern_from_bodies(bodies, part, feature, excluded_feature_ids):
    direction = _direction_vector(part, bodies, feature.direction_1, excluded_feature_ids)
    if feature.reverse_1:
        direction = direction.Reversed()
    instances = {}
    for i in range(feature.count_1):
        if i in feature.skip_indices:      # skip = never realize this transform at all
            continue
        trsf = gp_Trsf()
        trsf.SetTranslation(gp_Vec(direction) * (i * feature.spacing_1))
        instances[i] = BRepBuilderAPI_Transform(source_shape, trsf, True).Shape()
    return instances
```

For the two-direction case, compose translations
(`i * spacing_1 * dir_1 + j * spacing_2 * dir_2`), flattened to a single
linear index `index = i * count_2 + j` (row-major) — this convention
matters for both skip-instance addressing (§2.4) and the visual grid
picker.

**Merge**: after generating all realized (skip-filtered) instances, either
register each as its own Body (`f"{feature.id}#{i}"`) or fold them all
together via repeated `BRepAlgoAPI_Fuse` into one Body sharing the seed's
original id (§2.10).

### 2.3 Circular pattern

Shares `PatternFeature`'s shape and the instance-generation loop above,
using `gp_Trsf.SetRotation(gp_Ax1, angle_radians * i)` in place of
`SetTranslation`. See §2.7 for axis resolution specifics.

### 2.4 Skip instances

**Backend**: `skip_indices: list[int]` (already shown above) — a list of
0-based linear indices into the flattened instance grid, filtered *before*
any `BRepBuilderAPI_Transform` call for that index (a skipped instance
never even briefly exists as a shape, cheaper than generate-then-discard).
Validation: reject `invalid_skip_index` (422) for any index
`>= count_1 * count_2` (rectangular) or `>= count_angular` (circular) at
create/update time — the same "validate eagerly at the router, tolerate
drift at recompute" split every other Feature uses.

**Client UX**: the "clickable grid of dots" pattern from SolidWorks/
Fusion's own pattern-preview UI is the right model. New widget
`pattern_skip_grid.dart` — for rectangular, a `GridView`/`Wrap` of
`count_1 × count_2` toggleable dot/chip widgets, index `i*count_2+j` per
§2.2's convention, live-PATCHed the same debounced way every other panel
field is. For circular, a radial arrangement (a `CustomPainter` laying
`count_angular` dots around a circle) is more legible than forcing the
rectangular grid to also do radial layout — build as a second, dedicated
painter. Directly picking a previewed ghost instance in the 3D viewport to
toggle its skip state is a reasonable stretch goal, but the grid widget is
the always-available v1 fallback.

### 2.5 Straight edges to define pattern direction

Covered by `PatternDirectionRef.edge_ref` (§2.2) — reuses the exact
`GeomAbs_Line` check and `non_linear_edge` error shape
`create_plane.py`'s `resolve_normal_to_edge_through_vertex_from_bodies`
already established. Client selection: a single Body edge tap inside the
Pattern panel's "pick direction" mode resolves to a `SubShapeRefDto`
(already a first-class client concept), exactly like Fillet/Chamfer's
existing edge-picking.

### 2.6 Reverse direction

`reverse_1`/`reverse_2`/`reverse_angular: bool` fields — flip the sign of
the direction vector or angle before building the per-instance `gp_Trsf`.
Client: reuse the exact `IconButton(icon: Icon(Icons.flip), isSelected:
..., onPressed: ...)` idiom already live in `part_screen.dart` (~line
6224) for Sketch Orientation's flip control — same plain-bool,
live-PATCH-on-tap shape, one button per direction (two for a
two-direction linear pattern, one for circular).

### 2.7 Curved edges, curved faces, and axis lines for circular patterns

Three distinct axis sources, all funneling into one `gp_Ax1`:

```python
class PatternAxisRef:
    """Exactly one of three, mirroring PatternDirectionRef's own convention:"""
    circular_edge_ref: SubShapeRef | None = None    # curved Body edge
    cylindrical_face_ref: SubShapeRef | None = None # curved Body face
    sketch_line_ref: SketchEntityRef | None = None  # straight Sketch Line as an axis
```

- **Curved edge**: `resolve_circular_edge_arc` (`extrude.py:1017`) already
  extracts `circle.Location()`/`circle.Axis().Direction()` from exactly
  this `SubShapeRef` shape — reuse directly via a thin new wrapper
  (`axis_from_circular_edge`) that stops after the raw OCCT extraction,
  skipping that function's extra sketch-basis-projection step which
  Pattern doesn't need.
- **Curved (cylindrical) face**: genuinely new, but small —
  `BRepAdaptor_Surface(face).GetType() == GeomAbs_Cylinder` →
  `adaptor.Cylinder().Axis()` gives the `gp_Ax1` directly. Reject with a
  new `non_cylindrical_face` 422 (same shape as `non_planar_reference`)
  for a face whose surface isn't a cylinder — note a fillet's own rounded
  face *is* a valid pick here; a flat face is not.
- **Sketch axis line**: `RevolveFeature._resolve_axis` (`revolve.py:81`),
  copy-adapted — same fail-closed `invalid_axis_ref` behavior.

**Open decision, addressed explicitly**: does circular pattern need a new,
standalone `CreateAxisFeature` (a lightweight reference-geometry Feature
analogous to `CreatePlaneFeature` — fixed world axis, through-two-points,
normal-to-a-circular-face, etc.), or is picking a Body edge/face/Sketch-
Line ad hoc, per pattern, sufficient? **Recommendation: defer
`CreateAxisFeature`.** `PatternAxisRef` above is materially cheaper (three
resolvers, two nearly verbatim reuse) and covers the required scope
completely. A real `CreateAxisFeature` earns its cost once (a) multiple
different Features want to reference the *same named* axis, or (b) users
need an axis not reducible to an existing edge/face/line — neither is
today's requirement. Listed in §4 as a Phase 8+ candidate, not required
for Circular Pattern's core deliverable.

### 2.8 Patterning bodies vs. patterning features (geometry pattern vs. feature pattern)

The single largest architectural fork in this design — decided
explicitly, not left open:

**Option A — Geometry pattern (transform-and-copy the resolved solid).**
`source_body_ids` names already-computed Bodies; the Pattern feature reads
their `TopoDS_Shape` out of `bodies_so_far` and transforms *that shape* N
times. This is what `resolve_mirror_from_bodies`/`resolve_pattern_from_
bodies` above actually do — matches Fillet/Chamfer/Boss's existing
"operate on `bodies_so_far`" idiom exactly.

**Option B — Feature pattern (re-run the seed Feature's own operation N
times with a transformed input).** `source_feature_ids` names an upstream
Feature (an Extrude, a Fillet, a hole-cutting Cut...); the Pattern feature
re-invokes that Feature's own resolver N times with its defining
Sketch/references transformed *before* geometry construction, rather than
transforming the already-built output. This is what SolidWorks/Fusion mean
by "feature pattern," and matters when a patterned feature's effect is
location/orientation-sensitive in a way a rigid-body copy doesn't
reproduce.

**Recommendation: build Option A now; explicitly defer Option B.** Option
A is substantially simpler (no re-entrant Feature-resolution machinery, no
question of what it means to re-run a Cut whose `target_body_ids` named a
now-differently-positioned Body) and is fully correct for the common case
in this app's current feature set — patterning a Boss'd/Revolved/Swept
Body, including one with Fillets/Chamfers already baked into its shape
(the fillet is *part of the shape being copied*, which reads correctly:
six identical filleted brackets). Option B only diverges when a seed
Feature references something *external* to its own Body in a
location-sensitive way — nothing in today's Feature set (Extrude/Revolve/
Sweep/Fillet/Chamfer/Boolean) actually does this.

**This also resolves "patterning features" from the required scope**:
interpreted in v1 as *"pattern targets can be specified via their owning
Feature, for UX convenience (pick a Feature in the tree rather than each
of its output Bodies one at a time), but the operation performed is still
Option A's geometry-copy of that Feature's current resolved Body/
Bodies"* — `source_feature_ids` resolves via `{bid for bid in bodies if
base_feature_id(bid) == fid}`, a one-line lookup, not new re-entrant
Feature-graph machinery.

### 2.9 Patterning inside sketches (2D)

Sketch geometry (`app/sketch/models.py`) has no OCCT Body/Feature graph —
a flat dict of `Point`/`Line`/`Circle`/`Arc`/... solved by py-slvs. Two
real options:

**Option 1 — Real, independent, fully-constrainable Sketch entities.** A
sketch-level Pattern tool creates N actual copies of the selected
entities' Points (new ids, offset positions) plus new Line/Circle/Arc
entities, optionally with auto-generated constraints tying each copy back
to the original. Matches SolidWorks/Fusion sketch-pattern behavior, but
needs a real decision about which constraints to auto-generate, and every
copy becomes an independent, separately-draggable thing in the solver
graph — more DOF, and an open question about what dragging one instance
vs. the original should do.

**Option 2 — Lightweight, non-solved instances.** `Sketch.
pattern_instances: dict[str, SketchPatternInstance]` (source entity ids,
direction/axis, count, spacing, skip list — structurally identical to the
3D `PatternFeature`), with each instance's geometry computed by
transforming the source entities' coordinates *on read* — client-side for
live preview, and on the backend wherever sketch geometry feeds an
Extrude/Revolve/Sweep's profile detection. No new solver entities, no new
DOF, no auto-generated constraints — instances are derived, not
independent.

**Recommendation: Option 2**, restricted to closed profiles feeding
Extrude/Revolve (the load-bearing case — "sketch one bolt-hole circle,
pattern it 6× around a bolt circle, extrude-cut the whole sketch"), not
general open-geometry decoration. Concretely:
- `Sketch` gains `pattern_instances: dict[str, SketchPatternInstance]` (a
  new lightweight, non-solver dataclass reusing `SketchEntityRef` for
  "use this Sketch Line as direction" — trivially available since it's
  the same Sketch).
- The one piece of genuinely new work: `detect_profile` (or wherever the
  extrudable wire set is assembled) needs a pre-pass expanding
  `pattern_instances` into synthetic, transformed `Point`/`Line`/`Circle`
  objects held in a *separate transient dict*, never written back into
  `sketch.points`/`sketch.lines` — so instances never become
  independently draggable/selectable/deletable.
- Editing the source entity or the pattern's own parameters live-updates
  every derived instance automatically, for free — full associativity by
  construction, arguably a better default than Option 1's "did I add the
  right constraint" risk.
- Explicit v1 non-goal: an individual instance can't be independently
  edited/deleted/dimensioned — only the source or the whole pattern's
  parameters. This is the natural Option-1 upgrade path if users want
  per-instance edits later (e.g. "5 of these 6 holes match, one is
  bigger").
- Client: a new `SketchMode` entered from the Tools FAB grid alongside
  Offset, using Offset's exact interaction shape (accumulate picks →
  Finish FAB → non-modal bottom bar with count/spacing/angle fields, a
  new `sketch_pattern_bar.dart` cloned from `sketch_offset_bar.dart`'s
  `OffsetValueBar`), live client-side ghost preview, committed to the
  backend only on Finish. A sketch-level Mirror follows the same shape:
  pick entities, pick a mirror Line (existing or new construction line —
  construction-geometry support already exists in the sketcher), live
  ghost preview, confirm.

### 2.10 Merge options (fuse vs. keep separate)

`MergeMode` enum (`KEEP_SEPARATE | FUSE_INTO_ONE`) on both `PatternFeature`
and `MirrorFeature`. `KEEP_SEPARATE`: each realized instance registers as
its own Body via the existing `#N`-suffix convention. `FUSE_INTO_ONE`:
repeated `BRepAlgoAPI_Fuse` across every realized (non-skipped) instance
plus the original, registered as a single Body — survivor-id tie-break
mirroring `_apply_boss_or_cut`'s existing multi-target fuse convention.
**Default: `KEEP_SEPARATE`** for both, matching every mainstream CAD
tool's own default.

---

## 3. Other CAD-tool pattern/mirror-adjacent features — survey and scope call

| Feature (SolidWorks/Fusion/Onshape-style) | Verdict | Reasoning |
|---|---|---|
| Pattern along a curve/path | Deferred | Needs full path-parameterization + orientation-along-tangent — closer to Sweep's `path_refs` chaining than to a simple `gp_Trsf` loop; a separate scoping effort. |
| Sketch-driven / table-driven pattern | Deferred | A materially different input model (arbitrary point list vs. count+spacing) — cheap to describe as a future `PatternType` variant of the same dataclass shape, not worth building until rectangular/circular are solid. |
| Fill pattern (fill a bounded region) | Deferred | Needs collision/fit computation against a boundary — a different algorithm from "count × spacing," not a small variant. |
| Two-direction linear pattern | **In scope — folded into Phase 2 directly** | `direction_2`/`count_2`/`spacing_2`/`reverse_2` are already in `PatternFeature`'s shape; nearly free once one direction works, and expected baseline behavior for "rectangular pattern" in any real tool. |
| Varying instance spacing | Deferred | `spacing_1: float` would need to become `float \| list[float]` plus a cumulative-vs-per-step semantics decision — real but small; a natural future widening of the existing field. |
| Pattern seed = pattern (nested patterns) | **Structurally unblocked already, not specially built for** | `source_body_ids` can already name a Body produced by an earlier `PatternFeature` — the graph plumbing needs zero special-casing. Only real risk is combinatorial instance-count explosion; recommend a soft `pattern_too_large` cap (e.g. `total_instances > 500`) rather than bespoke nested-pattern code. |
| Instances-to-skip via a visual grid picker | **In scope — §2.4, Phase 3** | Explicitly required. |
| Geometry pattern vs. feature pattern | **Decided — §2.8**: build geometry-pattern now, defer feature-pattern | See §2.8's full reasoning. |
| Symmetric extend (pattern in both directions from a center) | Cheap UI convenience, fold in once base pattern exists | Purely client-side: reinterpret existing fields (shift index-0 to the geometric center) rather than a new backend concept. |
| Associativity / seed-edit propagation | **Already works by construction** | No dirty-flag caching anywhere (§1) — every `/mesh` fetch fully recomputes from scratch, so editing the seed (while still the last Feature, per `is_locked`) and re-fetching automatically re-runs Pattern/Mirror against the new shape. One accepted wrinkle: if the seed's *topology* changes shape, Pattern/Mirror's own direction/axis/plane `SubShapeRef` can go stale — the same project-wide, already-documented limitation, not a new risk. |
| A real, named `CreateAxisFeature` | **Deferred — §2.7's own recommendation** | Ad hoc `PatternAxisRef` resolution covers required scope; revisit once a second consumer needs a shared, named axis. |
| Feature-pattern chaining (pattern of a pattern's *feature*) | Deferred — depends on Option B (§2.8) shipping first | N/A until feature-pattern itself exists. |
| Equation/formula-driven instance count or spacing | Out of scope entirely | No parametric-expression system exists anywhere in this codebase (every numeric Feature field is a plain literal) — a whole-app capability, not a Pattern-specific gap. |

---

## 4. Phased implementation plan

### Phase 1 — Mirror about a fixed plane or Body face

**Status: implemented (2026-07-23) — see `docs/status.md`'s same-dated entry
for the full implementation/verification write-up.** No `pythonocc-core`/
Flutter SDK available in that implementation session, so the OCCT-free
backend graph/native-format logic was verified by real test runs; every
OCCT-touching backend module and the entire client side (no Dart/Flutter
SDK at all in that sandbox) were `ast.parse`-verified/hand-reviewed against
exact precedent only — real CI (backend) and an on-device/desktop build
(client) are still needed to confirm beyond that.

Single Body seed, always-separate output.

- **Deliverable**: select one Body, pick a mirror plane (fixed XY/XZ/YZ,
  an existing Body face, or an existing `CreatePlaneFeature`), get a
  second, independent mirrored Body.
- **Backend**: `MirrorFeature` dataclass (`source_body_ids` constrained to
  exactly one entry for now, `mirror_plane: PlaneRef`, no `merge` field
  yet — hardcode `KEEP_SEPARATE`, add the field in Phase 5 rather than
  stubbing an unused enum now). New `mirror.py` module. Graph/
  `compute_part_bodies`/schema/router plumbing per the six-step checklist.
- **Client**: `mirror_panel.dart` (clone `fillet_panel.dart`), new
  `contextActionsFor` branch ("exactly 1 Body selected" → offer "Mirror"),
  plane-pick UX reused from `CreatePlanePanel`, simple `isPreviewMesh`
  live preview.
- **Complexity/risk**: low-medium. All the hard reference-resolution work
  (`PlaneRef`) is 100% pre-existing; the only genuinely new code is the
  `gp_Trsf.SetMirror` call itself plus the now-well-worn six-file Feature
  checklist (five prior Feature types have already done it).

### Phase 2 — Rectangular pattern

Straight-edge/sketch-line/fixed-axis direction, single Body seed, reverse,
two-direction, always-separate output.

- **Deliverable**: select one Body, pick a direction (Body edge, Sketch
  Line, or fixed X/Y/Z axis), set count + spacing, get N independent
  Bodies; reverse-direction toggle; optional second direction for a 2D
  grid pattern.
- **Backend**: `PatternFeature` dataclass (rectangular fields only —
  circular/skip/merge fields left undefined until their own phases, no
  speculative unused fields). New `PatternDirectionRef` value type.
  `pattern.py` module — straight-edge check reuses `create_plane.py`'s
  exact idiom. Graph/`compute_part_bodies`/schema/router plumbing.
- **Client**: `pattern_panel.dart`, `SegmentedButton<PatternMode>`
  (Circular disabled/hidden until Phase 4), three-way direction picker
  (edge / Sketch Line / fixed-axis dropdown, mirroring `PlaneRef`'s
  three-way UI in `CreatePlanePanel`), `Icons.flip` reverse toggle per
  direction, `contextActionsFor` extended.
- **Complexity/risk**: medium. One new value type and a genuinely new
  N-instance transform loop, but every individual piece (straight-edge
  check, translation `gp_Trsf`, multi-Body registration) has a direct
  precedent elsewhere. Build both directions now rather than deferring —
  the data-model shape is identical either way, and a 1-direction-only
  "rectangular pattern" would read as incomplete.

### Phase 3 — Skip instances

Visual grid picker.

- **Deliverable**: a clickable dot-grid inside the Pattern panel to
  suppress individual instances without deleting the whole pattern.
- **Backend**: `skip_indices: list[int]`, filtered before transform
  generation, `invalid_skip_index` validation at the router.
- **Client**: new `pattern_skip_grid.dart` (linear-indexed dot grid,
  `i*count_2+j` convention), wired into `pattern_panel.dart`.
- **Complexity/risk**: low. Backend change is a one-line filter; the real
  work is the new, self-contained grid widget.

### Phase 4 — Circular pattern

Curved-edge / cylindrical-face / axis-line direction sources.

- **Deliverable**: select one Body, pick a circular axis source (curved
  Body edge, cylindrical Body face, or a Sketch Line acting as an axis),
  set instance count + total angle, get N independent Bodies rotated
  around that axis; reverse toggle; skip-instances grid (radial variant).
- **Backend**: `PatternAxisRef` value type, `axis`/`count_angular`/
  `angle_total`/`reverse_angular` fields (already declared in Phase 2's
  dataclass, unused until now), three axis resolvers (`axis_from_
  circular_edge` — thin wrapper over `resolve_circular_edge_arc`;
  `axis_from_cylindrical_face` — new `GeomAbs_Cylinder` check;
  `axis_from_sketch_line` — near-verbatim copy of `RevolveFeature.
  _resolve_axis`), `gp_Trsf.SetRotation` in the instance loop, new
  `non_cylindrical_face` error.
- **Client**: extend `pattern_panel.dart`'s `SegmentedButton` to enable
  Circular mode, three-way axis picker, radial skip-instance dot layout
  (new `CustomPainter` sibling to Phase 3's grid widget).
- **Complexity/risk**: medium. Two of three axis resolvers are near-
  verbatim reuse; cylindrical-face is the one genuinely new (small) OCCT
  path. Main risk is UX clarity around three very different-looking valid
  axis picks — worth on-device iteration.

### Phase 5 — Merge options

Fuse vs. keep separate, for both Pattern and Mirror.

- **Deliverable**: a merge toggle on both panels — "Keep Separate"
  (default, current behavior from Phases 1-4) vs. "Merge into One Body."
- **Backend**: `MergeMode` enum, `merge` field retrofitted onto both
  dataclasses (additive, default-preserving, non-breaking), fuse chain
  mirroring `_apply_boss_or_cut`'s existing multi-target logic.
- **Client**: a `SegmentedButton<MergeMode>`/switch on both panels.
- **Complexity/risk**: low-medium. Fuse logic is copy-adjacent to
  existing code; the real risk is body-identity bookkeeping (which id
  survives a merge, what happens to selection state for instances that
  just got fused away) rather than new OCCT risk.

### Phase 6 — Multi-body / multi-feature seed selection

"Patterning bodies, patterning features" at full generality.

- **Deliverable**: Pattern/Mirror accept a multi-select of Bodies and/or
  Feature-tree entries, resolving Feature selections to their current
  output Body/Bodies per §2.8.
- **Backend**: widen `source_body_ids`/`source_feature_ids` validation
  from exactly-one to 1+; `source_feature_ids` resolves via the one-line
  `base_feature_id` lookup from §2.8 — no new resolution machinery.
- **Client**: feed the existing multi-select accumulator directly into
  the panels (no new selection mechanism), plus a Feature-tree
  multi-select entry point (verify during implementation whether
  `feature_tree_panel.dart` already supports this).
- **Complexity/risk**: low-medium. Mostly widening validation bounds that
  were artificially restricted to length-1 in earlier phases; the
  Feature-tree-as-selection-source wiring is the one piece needing a
  direct on-device check before estimating further.

### Phase 7 — Sketch-level Pattern and Mirror

2D, sketch-entity-level, per §2.9.

- **Deliverable**: inside the sketcher, select one or more entities,
  pattern or mirror them within the 2D sketch (lightweight, non-
  independent instances), contributing to the sketch's extrudable
  profile.
- **Backend**: `Sketch.pattern_instances`/a mirror analog (new lightweight
  dataclasses in `app/sketch/models.py` — pure 2D math, no OCCT needed at
  all for the mirror case), the `detect_profile` expansion pre-pass
  (§2.9), new sketch-level endpoints mirroring existing sketch-entity
  endpoint shapes.
- **Client**: new `SketchMode` entry reusing Offset's exact interaction
  shape, `sketch_pattern_bar.dart` (clone `OffsetValueBar`), client-side
  live preview, Finish-commits-to-backend flow.
- **Complexity/risk**: medium-high. Architecturally simpler than it first
  looks (no solver/DOF changes — modeled after Ellipse/Arc/Spline's own
  "decompose into plain math, don't touch the solver" precedent), but
  touches `detect_profile`'s core wire-assembly logic, which needs care
  to avoid regressing existing non-patterned sketches — budget a
  dedicated on-device verification pass.

### Phase 8+ — Explicitly deferred, not scheduled

Per §3's survey: pattern-along-a-curve, sketch-driven/table-driven
pattern, fill pattern, varying instance spacing, a standalone
`CreateAxisFeature`, feature-pattern (§2.8 Option B), per-instance
independent sketch-pattern editing (§2.9's Option 1 upgrade), and
equation-driven instance parameters. Each is called out above with its
one-line "why not now" reason preserved, so a future scoping pass doesn't
have to re-derive the reasoning from scratch.

---

## 5. Critical files for implementation

- `backend/app/document/models.py` — where `MirrorFeature`,
  `PatternFeature`, `PatternDirectionRef`, `PatternAxisRef`, `MergeMode`
  get added, following `RevolveFeature`/`CreatePlaneFeature`'s exact
  dataclass conventions.
- `backend/app/document/graph.py` — `build_feature_graph`/
  `_plane_ref_dependency`/`base_feature_id`, where Pattern/Mirror's
  dependency edges get wired for correct recompute ordering and cascade
  delete.
- `backend/app/document/extrude.py` — `compute_part_bodies`'s
  topological loop (new branches), plus `resolve_subshape_from_bodies`/
  `resolve_circular_edge_arc`/`_register_solids`/`_apply_boss_or_cut`,
  all directly reused or lightly adapted.
- `backend/app/document/create_plane.py` — source of the `PlaneRef`/
  `_resolve_plane_ref` machinery Mirror reuses verbatim, and the
  `GeomAbs_Line`/`non_linear_edge` idiom Pattern's direction-edge check
  copies exactly.
- `backend/app/document/revolve.py` — `_resolve_axis`, the direct
  template for Circular Pattern's Sketch-Line-as-axis resolution.
- `client/lib/viewport3d/fillet_panel.dart` and
  `client/lib/viewport3d/selection_actions.dart` — the panel-shell and
  selection-gating templates `mirror_panel.dart`/`pattern_panel.dart` and
  their new `contextActionsFor` branches clone/extend respectively.
- `docs/live-preview-pattern.md` — confirms Pattern/Mirror both take the
  simple `isPreviewMesh` path, a load-bearing decision for the client
  implementation's complexity estimate.
