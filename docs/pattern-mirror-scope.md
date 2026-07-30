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
    source_body_ids: list[str]      # bodies to mirror (v1: 1+, widened from exactly-one - see Phase 1's 2026-07-24 revision)
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

**Revision (2026-07-29)**: on-device follow-up narrowed this section's own
"defer Option B" verdict rather than overturning it — see §2.11. Mirroring
an asymmetric hole/cut pattern into the *same* Body (not a second,
independent mirrored Body) turned out to be a real, common use case
`MergeMode.FUSE_INTO_ONE` (§2.10) cannot actually serve. Option B's
Extrude/Revolve/Sweep-into-shared-target subset (both Feature types
already expose a standalone pre-boolean tool shape — see §2.11) is now
scoped as Phase 8; the genuinely harder Fillet/Chamfer remainder (no
standalone tool shape to transform) stays deferred, per §2.11's own
scope-boundary note.

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

### 2.11 Feature pattern and feature mirror (Cut/Boss subset of Option B)

**Trigger**: on-device follow-up to §2.8's own "defer Option B" call —
Mirror's own version of the same underlying problem surfaced directly.
Mirroring an asymmetric hole/cut pattern about a plane, *into the same
Body* (not producing a second independent mirrored Body), is a real,
common CAD workflow with no correct path today. `MergeMode.
FUSE_INTO_ONE` (§2.10) looks like it should cover this but doesn't —
`BRepAlgoAPI_Fuse` is a union; unioning two differently-holed copies of
the same envelope doesn't subtract material, so both holes get filled
back in rather than combined. Mirror needs a real boolean **Cut using the
mirrored tool shape**, not a fuse of two already-cut Bodies. This
generalizes cleanly to Pattern too (repeating a hole/boss N times into
one shared target, rather than N independent Body copies) — the two
share essentially all of the same new machinery, so this section (and
the phase it produces, §4 Phase 8) covers both.

**Why this is a narrower, more tractable slice of Option B than §2.8's
own "re-run any Feature's resolver" framing.** §2.8 originally described
Option B in its most general form — re-invoke *any* seed Feature's own
resolver with its defining references transformed. That's genuinely hard
for Fillet/Chamfer: they operate directly on `SubShapeRef`-indexed edges
of an *already-existing* target Body's own topology (`BRepFilletAPI`),
with no standalone shape of their own to transform — there is no "the
edge this fillet would round if the pattern's second instance existed
yet," since that edge doesn't exist until the pattern actually runs.
Extrude/Revolve/Sweep are different: `_apply_boss_or_cut`
(`extrude.py:608`) already receives a **standalone tool solid** — the
raw extruded/revolved/swept shape — *before* it gets fused into or cut
from `target_body_ids`. That pre-boolean tool shape is exactly the kind
of rigid, transformable `TopoDS_Shape` Option A's own `gp_Trsf` loop
already knows how to copy N times or mirror once. So this phase is
scoped to **Extrude/Revolve/Sweep Features in Cut mode, or Boss mode
with a non-empty `target_body_ids`** (a targetless Boss has no "shared
target" problem at all — Option A already copies it correctly as an
independent Body) — Fillet/Chamfer feature-pattern remains genuinely
deferred, a separate future scoping effort, not folded into this phase.

**New field, not a new mode enum.** Mirrors this codebase's own
established "which optional field is set selects the behavior"
convention (`PlaneRef`'s `face_ref`/`fixed_plane`/`plane_feature_id`,
`PatternDirectionRef`'s three fields): a new `tool_feature_id: str |
None = None` on both `MirrorFeature` and `PatternFeature`, mutually
exclusive with `source_body_ids`/`source_feature_ids` (validated by the
router, same "exactly one of N" shape every other multi-option field in
this codebase already uses). Its presence *is* the mode switch — no
separate `seed_kind` enum needed.

**New backend capability — genuinely new, not a copy-adjacent reuse.**
`compute_part_bodies`'s own `ExtrudeFeature`/`RevolveFeature`/
`SweepFeature` branches currently compute a tool shape and immediately
hand it to `_apply_boss_or_cut` inline — there is no standalone function
today that resolves *just* the tool shape for an arbitrary upstream
Feature id, callable from outside that loop. New `resolve_feature_tool_
shape(part, bodies, feature_id, excluded_feature_ids) -> (TopoDS_Shape,
list[str] target_body_ids, bool is_cut)` (`extrude.py`, next to
`_apply_boss_or_cut`) factors that computation out so both `compute_
part_bodies`'s own existing branches *and* Pattern/Mirror's new
`tool_feature_id` path can call it — the one piece of this phase that
touches already-shipped, well-tested code, so it's the primary
complexity/risk driver, not the Pattern/Mirror-side logic itself (see
this section's own complexity note below).

**Resolution — Pattern (`tool_feature_id` set):**
- Resolve the tool shape and its own `(target_body_ids, is_cut)` once via
  `resolve_feature_tool_shape`.
- v1 scope: exactly one target (`target_body_ids[0]`) — `tool_feature_
  id`'s own Feature may in principle name several targets (Extrude/
  Revolve/Sweep already support multi-target fuse/cut), but multi-target
  feature-pattern is real added complexity deferred the same way
  Pattern's own multi-*body* seeding was staged behind Mirror's (§4
  Phase 6) — not needed for the common case.
- Index `0` is **already baked into the target** — the seed Cut/Boss
  Feature already ran once, earlier in feature order (Pattern can only
  reference an upstream Feature), so by the time Pattern's own branch
  runs, the target Body already reflects instance 0. Pattern only
  computes the *other* `count-1` transformed tool copies (same `gp_Trsf`
  loop §2.2/§2.3 already build, skip-filtered the same way — §2.4's
  `skip_indices` applies unchanged), unions them into one combined tool,
  and applies **one** `BRepAlgoAPI_Cut`/`BRepAlgoAPI_Fuse` (per `is_cut`)
  against the target's current shape in `bodies` — not `count-1`
  separate booleans, for the same reason `_fuse_realized_instances`
  (§2.10) unions before a single fuse rather than fusing one-by-one into
  the target repeatedly.
- `merge` (§2.10) is meaningless in this mode — there is exactly one
  target by construction, "keep separate" has no referent. The router
  rejects `merge=KEEP_SEPARATE` when `tool_feature_id` is set, so a
  client sending it gets a clear error rather than silent ignoring.

**Resolution — Mirror (`tool_feature_id` set):**
- Same tool-shape resolution; `mirror_plane` resolved exactly as today
  (§2.1, `resolve_plane_ref` reused verbatim).
- Mirror the tool shape once via the existing `gp_Trsf.SetMirror` path,
  then one `BRepAlgoAPI_Cut`/`BRepAlgoAPI_Fuse` against the target — this
  is the actual fix for "mirror an asymmetric hole pattern into the same
  part": the target ends up with both the original hole(s) and their
  mirror image, correctly subtracted, not unioned-and-refilled.
- Same v1 single-target scope, same `merge` inapplicability as Pattern's
  own feature-mode above.

**New structured error**: `invalid_tool_feature_ref` (422) —
`tool_feature_id` doesn't resolve to a qualifying Feature (wrong type, or
a Cut/Boss with the disqualifying shape above).

**New dependency-graph edge**: `_tool_feature_dependency` (`graph.py`,
mirrors `_plane_ref_dependency`'s own shape) — a Pattern/Mirror with
`tool_feature_id` set depends on that Feature's own `base_feature_id`, so
cascade-delete and topological ordering both work for free, same as
every other reference type in this codebase.

**Client**: both panels gain a third seed-picking path — pick an
eligible Cut/Boss Feature from the Feature tree (reuses whatever
`feature_tree_panel.dart` selection-source wiring Phase 6 ends up
building, restricted to Features that would pass `invalid_tool_feature_
ref` validation) rather than picking a Body/edge/plane in the viewport.
Exact UI shape (a mode toggle on the existing panels vs. a distinct
entry point) needs an on-device pass before committing — deliberately
not fully speculated here.

**Complexity/risk**: medium-high. The single real risk is `resolve_
feature_tool_shape`'s own extraction from `compute_part_bodies`'s
existing inline branches — refactoring already-shipped, heavily-tested
geometry code without regressing it needs care and a dedicated
verification pass (every existing Extrude/Revolve/Sweep test must keep
passing unchanged). Everything downstream of that extraction (the
Pattern/Mirror-side Cut/Fuse-into-target logic) is comparatively
low-risk, closely mirroring `_fuse_realized_instances`'s own
already-shipped shape (§2.10).

**Explicitly out of scope**: Fillet/Chamfer feature-pattern/mirror (no
standalone tool shape — see this section's own scope-boundary note
above); multi-target feature-pattern/mirror (v1 is single-target only);
any interaction between feature-mode and `PatternType.CIRCULAR`'s own
axis/angle addressing beyond the already-covered index conventions
(should just work unchanged, but not separately verified in this design
pass).

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
| Geometry pattern vs. feature pattern | **Decided — §2.8/§2.11**: Option A (geometry pattern) is the default/primary path for both Feature types; Option B's Extrude/Revolve/Sweep-into-shared-target subset is now scoped as Phase 8 (§2.11); the Fillet/Chamfer remainder stays deferred | See §2.8/§2.11's full reasoning. |
| Symmetric extend (pattern in both directions from a center) | Cheap UI convenience, fold in once base pattern exists | Purely client-side: reinterpret existing fields (shift index-0 to the geometric center) rather than a new backend concept. |
| Associativity / seed-edit propagation | **Already works by construction** | No dirty-flag caching anywhere (§1) — every `/mesh` fetch fully recomputes from scratch, so editing the seed (while still the last Feature, per `is_locked`) and re-fetching automatically re-runs Pattern/Mirror against the new shape. One accepted wrinkle: if the seed's *topology* changes shape, Pattern/Mirror's own direction/axis/plane `SubShapeRef` can go stale — the same project-wide, already-documented limitation, not a new risk. |
| A real, named `CreateAxisFeature` | **Deferred — §2.7's own recommendation** | Ad hoc `PatternAxisRef` resolution covers required scope; revisit once a second consumer needs a shared, named axis. |
| Feature-pattern chaining (pattern of a pattern's *feature*) | Deferred — depends on Phase 8 (§2.11) shipping first | N/A until feature-pattern itself exists. |
| Equation/formula-driven instance count or spacing | Out of scope entirely | No parametric-expression system exists anywhere in this codebase (every numeric Feature field is a plain literal) — a whole-app capability, not a Pattern-specific gap. |

---

## 4. Phased implementation plan

### Phase 1 — Mirror about a fixed plane or Body face

**Status: implemented (2026-07-23), revised (2026-07-24) — see
`docs/status.md`'s matching dated entries for the full implementation/
verification write-up.** No `pythonocc-core`/Flutter SDK available in the
initial implementation session, so the OCCT-free backend graph/native-
format logic was verified by real test runs there; every OCCT-touching
backend module and the entire client side were `ast.parse`-verified/hand-
reviewed against exact precedent only in that session. The 2026-07-24
revision (below) verified everything for real instead: a local
`pythonocc-core` env (micromamba) for the full backend `pytest` suite
(988 tests) and a local Flutter SDK (master channel) for `flutter analyze`
+ the full client `flutter test` suite (937 tests) — both green — plus
real GitHub Actions CI on the pushed branch.

Always-separate output (merge options remain Phase 5).

- **Deliverable**: select one or more Bodies, pick a mirror plane (fixed
  XY/XZ/YZ, an existing Body face, or an existing `CreatePlaneFeature`),
  get one independent mirrored Body per source. Reached either via the
  ambient `SelectionContextPanel` ("Mirror" button on a Body-only
  selection) or via a new guided "Add" FAB entry (`New > Mirror`): pick
  Body/Bodies → confirm → pick a mirror plane (reference planes
  temporarily forced visible for this step) → live preview → confirm.
- **Backend**: `MirrorFeature` dataclass (`source_body_ids: list[str]`,
  `mirror_plane: PlaneRef`, no `merge` field yet — hardcode
  `KEEP_SEPARATE`, add the field in Phase 5 rather than stubbing an unused
  enum now). New `mirror.py` module. Graph/`compute_part_bodies`/schema/
  router plumbing per the six-step checklist. **Revision (2026-07-24):**
  on-device UX feedback on the guided "New > Mirror" flow ("multiple
  bodies should be supported") pulled multi-body seeding forward from its
  original Phase 6 scoping directly into this phase — `source_body_ids`
  now accepts any positive count, not just exactly one; `resolve_mirror_
  from_bodies` mirrors every entry across the same resolved plane and
  registers one Body per source (`feature.id` alone for a single source,
  `#N`-suffixed per source for 2+, mirroring `_register_solids`'s own
  single-vs-multiple convention). `source_feature_ids` (multi-*feature*
  seeding) remains Phase 6 — unaffected by this widening.
- **Client**: `mirror_panel.dart` (clone `fillet_panel.dart`), a
  `contextActionsFor` branch (1+ Bodies, nothing else, selected → offer
  "Mirror"), plane-pick UX reused from `CreatePlanePanel`, simple
  `isPreviewMesh` live preview. **Revision (2026-07-24):** a new guided
  "Add" FAB entry (`FeaturePickerAction.mirror`) drives a genuine two-step
  wizard (`_MirrorStep.pickingBodies` → `pickingPlane`) — Body-picking and
  plane-picking use mutually exclusive `SelectionFilterState`s
  (`hitTestBodies` treats `filter.body`/`filter.face` as mutually
  exclusive at the whole-hit-test level), so, unlike Revolve's axis pick
  (a `sketchLine`, hit-tested via a completely separate code path from its
  own Body picks), Mirror cannot let the user pick Bodies and a plane
  simultaneously through one filter and genuinely needs the two-step
  shape. Each step gets its own top banner (`Select Body to Mirror` /
  `Select Mirror Plane or Face`) mirroring Fillet/Chamfer's guided-entry
  banner convention, with a checkmark FAB (mirroring the profile/path
  pickers' own) confirming the body-pick step. `contextActionsFor`'s
  Mirror branch also widened to 1+ Bodies (still nothing else selected) to
  match; its ambient entry skips straight to `pickingPlane` since its
  Bodies are already selected going in.
- **Complexity/risk**: low-medium. All the hard reference-resolution work
  (`PlaneRef`) is 100% pre-existing; the only genuinely new code is the
  `gp_Trsf.SetMirror` call itself plus the now-well-worn six-file Feature
  checklist (five prior Feature types have already done it). The
  multi-body widening and guided two-step wizard added real, but bounded,
  scope on top.

### Phase 2 — Rectangular pattern

**Status: implemented (2026-07-24), revised (2026-07-28) — see
`docs/status.md`'s matching dated entries for the full implementation/
verification write-up.** Verified for real: the full backend `pytest`
suite (1014 tests, including 26 new Pattern-specific ones) against genuine
`pythonocc-core`, and the full client `flutter test` suite (955 tests,
including 18 new `PatternPanel` ones) plus a clean `flutter analyze`,
using the same local toolchains bootstrapped for Phase 1's own
verification pass. **The 2026-07-28 revision (below)** exposed the
Sketch-Line direction the original session had deliberately deferred.

Straight-edge/Sketch-Line/fixed-axis direction, single Body seed, reverse,
two-direction, always-separate output, guided "New > Pattern" flow.

- **Deliverable**: select one Body, pick a direction (a Body edge or a
  Sketch Line, both tapped live in the viewport, or a fixed X/Y/Z axis),
  set count + spacing, get N independent Bodies (N is the total
  including the untouched seed, matching mainstream CAD convention — see
  the next bullet); reverse-direction toggle; optional second direction for
  a 2D grid pattern. Reached either via the ambient `SelectionContextPanel`
  ("Pattern" button on a lone-Body selection, alongside "Mirror") or via a
  new guided "Add" FAB entry (`New > Pattern`): pick a Body (single
  required pick — immediately advances, no separate confirm step the way
  Mirror's own multi-select `pickingBodies` step needs) → pick a direction
  (edge tap or an X/Y/Z button) → live preview → confirm.
- **Backend**: `PatternFeature` dataclass (`source_body_ids: list[str]`
  constrained to exactly one entry — unlike Mirror, Pattern's own
  multi-body seeding is *not* pulled forward, remaining Phase 6 scope, per
  this doc's own original Phase 6 revision note; `direction_1`/`count_1`/
  `spacing_1`/`reverse_1` required, `direction_2`/`count_2`/`spacing_2`/
  `reverse_2` optional — circular/skip/merge fields left undefined until
  their own phases, no speculative unused fields). New `PatternDirectionRef`
  value type (`edge_ref`/`sketch_line_ref`/`fixed_axis`, "exactly one of
  three" — mirrors `PlaneRef`'s own convention). New `pattern.py` module —
  straight-edge check reuses `create_plane.py`'s exact idiom, Sketch-Line
  direction resolution mirrors `revolve.py`'s own `_resolve_axis` (minus the
  axis origin — a translation direction needs no pivot point).
  Index 0 of the flattened `i*count_2+j` instance grid is always the seed
  Body itself (never re-created — the real design decision this phase had
  to make, since the scope doc's own original pseudocode was ambiguous
  about it): `count_1 * count_2` is the *total* instance count including
  the seed, matching mainstream CAD tools' own "count includes the
  original" convention, rather than producing a redundant zero-offset
  duplicate on top of it. `direction_2`/`spacing_2`/`reverse_2` are only
  ever read when `count_2 > 1` — a stale/unset `direction_2` is otherwise
  functionally inert, which sidesteps needing a separate "omitted vs.
  explicitly cleared" PATCH convention for it. Graph/`compute_part_bodies`/
  schema/router plumbing follows the six-part checklist exactly, mirroring
  `MirrorFeature`'s own Phase 1 shape throughout.
- **Client**: `pattern_panel.dart` — two near-identical "direction"
  sections (Direction 1 required, Direction 2 optional), each with X/Y/Z
  fixed-axis buttons, count/spacing fields, and an `Icons.flip` reverse
  toggle (the idiom this doc originally proposed). A new `_PatternStep`
  wizard (`pickingBody` → `configuring`) drives the guided entry, structured
  like Mirror's own two-step flow but simplified for Pattern's exactly-one-
  Body scope: a Body tap immediately advances (no confirm step needed).
  Because Direction 1 and Direction 2 can each independently come from an
  edge/Sketch-Line tap, an "active direction slot" toggle (a
  `SegmentedButton`, shown only once a second direction is enabled)
  disambiguates which one the next tap fills. **Revision (2026-07-28):**
  a Sketch Line is now also a reachable direction source — the original
  session's own v1 scope cut deferred it precisely because a Sketch Line
  usable as a pattern direction isn't guaranteed to already be visible in
  the viewport the way a Body edge always is (unlike Revolve's own axis
  pick, which solves this with a dedicated Sketch-picker flow); this
  revision instead just reuses the exact same live-viewport-tap mechanism
  Revolve's own axis pick already uses (`hitTestBodies`'s `sketchLine`
  filter flag), leaving visibility entirely up to the user's existing
  Sketch-visibility toggle rather than building a dedicated picker -
  `_setPatternDirectionFromEdge` was generalized into
  `_setPatternDirectionFromEntity`, accepting either kind and building
  `PatternDirectionRef.sketch_line_ref` for a Sketch-Line pick.
  `contextActionsFor` extended: a lone Body now offers both
  "Mirror" and "Pattern"; 2+ Bodies still offer only "Mirror", with
  "Pattern" shown disabled and a reason (Prompt D's own "explain, don't
  silently omit" convention) rather than omitted outright.
- **Complexity/risk**: medium, as scoped. One new value type and a
  genuinely new N-instance transform loop, but every individual piece
  (straight-edge check, translation `gp_Trsf`, multi-Body registration) has
  a direct precedent elsewhere. Both directions were built from the start
  rather than deferred — the data-model shape is identical either way, and
  a 1-direction-only "rectangular pattern" would read as incomplete. The
  client's own two-independent-direction-slots picking UX was the one
  genuinely new interaction-design problem in this phase, not present in
  Mirror's own single-plane-pick shape.

### Phase 3 — Skip instances

**Status: implemented (2026-07-28), UI redesigned same-day — see
`docs/status.md`'s same-dated entries for the full implementation/
verification write-up.** Implemented *after* Phase 4 (Circular pattern)
rather than before it, per this doc's own original phased-plan ordering
being superseded by actual delivery order - this section's original
design already anticipated both variants (a rectangular grid and a radial
ring for Circular), so no redesign was needed, only implementation against
the now-real `PatternFeature`/`PatternPanel`. Verified for real: the full
backend `pytest` suite (1073 tests, including 14 new skip-instance-
specific ones) against genuine `pythonocc-core`, and the full client
`flutter test` suite (985 tests, including a new `pattern_skip_grid_test.
dart` plus widened `pattern_panel_test.dart` coverage) plus a clean
`flutter analyze`, using the same local toolchains bootstrapped for every
prior Phase's own verification pass.

Direct user feedback the same day ("the area in the UI where instances are
toggled is too big") replaced the panel-embedded dot grid described below
with a viewport-native interaction instead - see the "revised same-day"
note right after the Deliverable/Backend/Client bullets for the new
shape; the bullets themselves are left as-written for the historical
record of what was originally built and verified.

Visual grid picker, for both Rectangular and Circular.

- **Deliverable**: a clickable dot-grid inside the Pattern panel (both
  modes) to suppress individual instances without deleting the whole
  pattern - a rectangular grid (row-major, matching Rectangular's own
  `i * count_2 + j` index) or a radial ring spanning `angle_total` degrees
  (matching Circular's own angular-step index), live-PATCHed the same
  debounced way every other panel field is. Index `0` (the untouched seed)
  is always shown filled and non-interactive - it was never going to be
  (re)created in the first place, so there is nothing there to suppress.
- **Backend**: `skip_indices: list[int]` added to `PatternFeature`
  (defaulted to `[]` for round-trip compatibility with every Pattern
  persisted before this field existed), filtered out in
  `_rectangular_instances`/`_circular_instances` before a
  `BRepBuilderAPI_Transform` is ever built for that index (a skipped
  instance never even briefly exists as a shape - cheaper than
  generate-then-discard). New `app.document.router.
  _validate_pattern_skip_indices`, called from the same single
  `_validate_pattern_payload` entry point both endpoints already share -
  rejects `0` (the seed - never created, so nothing to suppress) and
  anything `>= total_count` (Rectangular's own `count_1 * count_2`,
  Circular's own `count_angular`) rather than silently ignoring either.
  `PatternFeatureUpdate.skip_indices` gets its own `None`-vs-`[]`
  distinction (omitted leaves the current skip set untouched; `[]`
  explicitly un-skips everything), the same convention
  `ExtrudeFeatureUpdate.target_body_ids` already established - genuinely
  needed here, unlike `direction_2`'s own inert-when-unset shortcut,
  since there is no equivalent "count drops to a value that makes this
  meaningless" escape hatch for a skip set.
- **Client**: new `pattern_skip_grid.dart` (`PatternSkipGrid`) - plain
  `Positioned`/`Container` dot widgets for both layouts (not a
  `CustomPainter` for the radial case, despite this section's own original
  note suggesting one - discrete widgets give the identical visual result
  with free hit-testing, no custom pointer-math needed), wired into
  `pattern_panel.dart`'s own `_rectangularFields()`/`_circularFields()`
  via a small shared `_skipInstancesSection` helper (hidden entirely when
  the pattern's own total instance count is `<= 1`, matching the backend's
  own no-op guard). `part_screen.dart` gained `_patternSkipIndices`/
  `_onPatternSkipToggled`, wired into `_ensurePatternFeatureExists`,
  `_openPatternPanelForEdit` (both modes), and the confirm/cancel resets -
  clamped to the pattern's own *current* total instance count right before
  every send, so shrinking `count_1`/`count_2`/`count_angular` after some
  indices were already skipped can never accidentally send a now-out-of-
  range index alongside the smaller count in the same request.
- **Complexity/risk**: low, as scoped. The backend change really was close
  to a one-line filter per instance loop; the real work was the new,
  self-contained grid widget and its wiring - no design surprises, since
  Phase 4's own prior existence had already been accounted for here.

**Revised same-day: viewport-native toggling, replacing the panel grid.**
`pattern_skip_grid.dart`/`PatternSkipGrid` and its wiring into
`pattern_panel.dart` were removed entirely; `PatternPanel` now shows only a
one-line hint ("Tap an instance in the viewport to skip or keep it") once
the pattern's own total count is `> 1`. The backend's own `skip_indices`
field/validation/filtering is completely unchanged - only the client's own
sequencing of *when* it sends the real selection changed:
- While a Pattern is being configured, every debounced create/update call
  (`_ensurePatternFeatureExists`) now always sends `skip_indices: []`
  regardless of the user's current selection, so every instance stays
  present (and tappable) in the live mesh throughout editing - toggling an
  instance is a purely local `_patternSkipIndices` set mutation with no
  network round-trip. The real selection is sent exactly once, in a final
  PATCH `_confirmPattern` issues right before its own state teardown.
  `_openPatternPanelForEdit` force-reveals every instance the same way the
  moment an existing skip-carrying Pattern is opened for editing.
- Tapping a Body belonging to the pattern's own instances (recovered from
  its body id via the same `feature.id`/`feature.id#index` naming
  `compute_part_bodies` already uses - see `extrude.py`'s own doc comment
  there, reversed client-side with zero backend changes) toggles that
  instance's skip state directly, via a new special case in
  `_toggleSelectedEntity`. Index `0` (the seed) is excluded, matching the
  backend's own validation.
- `PartViewport` gained `skippedPreviewBodyIds` - a Body whose id is a
  member gets a distinct, more-transparent pale-grey tint in `_syncMeshNode`
  instead of the ordinary translucent preview orange, so kept vs. skipped
  instances read apart at a glance.
- The originally-planned "cubic node at the centre of each instance" marker
  (a secondary, always-reachable toggle target for small/thin instances
  where a direct Body tap is fiddly) was **not** built in this pass - the
  primary Body-tap interaction covers the requested behaviour end to end
  and was prioritized as the lower-risk, fully-precedented piece (reuses
  the existing ray-based `hitTestFaces`/body-kind-selection pipeline
  unchanged); the marker would need a genuinely new screen-space hit-test
  (a Body's own centroid is occluded from every existing ray-based
  hit-test by the Body's own surface - see `facesOccludeOtherHits`) and is
  left as a follow-up, not scheduled.
- New/changed tests: `pattern_skip_grid_test.dart` deleted outright;
  `pattern_panel_test.dart`'s skip-grid test group replaced with a smaller
  hint-visibility group; two new `part_screen_test.dart` integration tests
  cover the reveal-all-while-editing/restore-on-confirm sequencing and the
  viewport-tap-to-toggle interaction end to end (via a Pattern-aware fake
  `/mesh` endpoint synthesizing real per-instance body ids).

### Phase 4 — Circular pattern

**Status: implemented (2026-07-28), revised same-day — see
`docs/status.md`'s matching dated entries for the full implementation/
verification write-up.** Verified for real: the full backend `pytest`
suite (1041 tests after the same-day revision below, up from 1040 at
initial implementation) against genuine `pythonocc-core`, and the full
client `flutter test` suite (970 tests, including 15 new `PatternPanel`
circular-mode ones) plus a clean `flutter analyze`, using the same local
toolchains bootstrapped for Phase 1/2's own verification passes. **The
same-day revision (below)** made a straight Body edge a valid axis source
too (not just circular), and exposed the Sketch Line axis the initial
session had deliberately deferred.

Circular/straight-edge / cylindrical-face / Sketch-Line axis sources, a
Rectangular/Circular mode toggle inside the same guided "New > Pattern"
flow (not a separate feature entry), single Body seed, always-separate
output. Skip-instances (radial variant) remains its own Phase 3 scope, not
pulled forward here.

- **Deliverable**: the existing "New > Pattern" flow now offers a
  Rectangular/Circular `SegmentedButton` (shown only for a brand-new
  PatternFeature — see the Client bullet below on why it's hidden while
  editing). Circular mode: pick one Body, pick a circular axis (a circular
  or straight Body edge, a cylindrical Body face, or a Sketch Line, all
  tapped live in the viewport), set instance count + total angle, get N
  independent Bodies rotated around that axis (N is the total including
  the untouched seed, matching Phase 2's own `count_1 * count_2`
  convention); reverse toggle. Patterned Features (both modes) appear in
  the Build Tree exactly like any other Feature (`feature_tree_panel.dart`
  keys purely on the generic `feature.type == 'pattern'`, unaware of
  `pattern_type` — needed no changes) and tapping one reopens the edit
  panel in the correct mode with its stored fields reconstructed.
- **Backend**: `PatternType` enum (`RECTANGULAR`/`CIRCULAR`, defaulting to
  `RECTANGULAR` for round-trip compatibility with Phase-2-era persisted
  Features) added to `PatternFeature` alongside a new `PatternAxisRef`
  value type (`edge_ref`/`face_ref`/`sketch_line_ref`, "exactly one of
  three" — mirrors `PatternDirectionRef`'s own convention, generalized to
  faces too) and `axis`/`count_angular`/`angle_total`/`reverse_angular`
  fields; `direction_1`/`count_1`/`spacing_1` widened from required to
  optional, since a Circular Feature never sets them (which fields are
  actually required is validated by the router's own
  `_validate_pattern_payload`, dispatching on `pattern_type`, not by the
  dataclass itself — same split `_validate_plane_payload` already
  established for `CreatePlaneFeature`). New `_axis_from_ref` resolver in
  `pattern.py`: a circular Body edge via `BRepAdaptor_Curve`/
  `GeomAbs_Circle`; a cylindrical Body face via `BRepAdaptor_Surface`/
  `GeomAbs_Cylinder` (new `non_cylindrical_face` error, the one genuinely
  new OCCT path this phase needed); a Sketch Line mirrors
  `RevolveFeature._resolve_axis`'s own machinery, just returning a full
  `gp_Ax1` (origin + direction) instead of a bare direction. **Revision
  (same day):** a straight Body edge is now *also* a valid axis (via its
  own `gp_Lin.Location()`/`Direction()` — the same idea as a real axle
  running along that edge), not just a circular one — the original
  session's own `non_circular_edge` error was renamed to
  `unsupported_axis_edge` (an edge that's neither circular nor straight,
  e.g. elliptical/Bezier/BSpline, is still rejected). This surfaced a
  latent test-helper bug: every OCCT circular extrusion has a straight
  seam edge connecting its top/bottom circular caps, so brute-force edge
  probes that only checked "did this succeed" (not "is this genuinely the
  Body's own centre axis") started silently picking the off-axis seam
  edge instead of the true circular one once straight edges became valid
  too — fixed by verifying the resulting rotated instance is still
  centred near the world origin, not success alone. Circular
  instances use `gp_Trsf.SetRotation(axis, angle_total/count_angular * i)`
  in place of Phase 2's `SetTranslation`, sharing the exact same
  index-0-is-the-untouched-seed convention. `pattern_type` is immutable via
  PATCH (switching Rectangular ↔ Circular is delete+recreate, mirroring
  `CreatePlaneFeatureUpdate.plane_type`'s own immutability). The axis
  reference is allowed to point at a *different* Body than the one being
  patterned (confirmed by a dedicated cascade-delete test) — the
  dependency-graph edge (`_pattern_axis_dependency` in `graph.py`) tracks
  it correctly either way.
- **Client**: `pattern_panel.dart` gained a `PatternMode` enum and a
  Rectangular/Circular `SegmentedButton` (mirroring `RevolveMode`'s own
  Boss/Cut toggle), hidden/disabled while editing an existing Feature
  (`canChangeMode`) since `pattern_type` is immutable server-side. Circular
  mode's own fields: an axis status line, Count/Angle(degrees) text fields,
  and a reverse toggle — deliberately **no** fixed-world-axis button
  alternative the way Direction 1/2 have X/Y/Z buttons, since a circular
  pattern needs a real pivot point a bare direction can't supply; the axis
  is picked exclusively via a viewport tap on an edge, a face, or (as of
  the same-day revision below) a Sketch Line. `part_screen.dart` gained a
  parallel `PatternMode`/axis-picking state section alongside Phase 2's
  own direction-picking one: a new `_patternAxisSelectionFilter` (edge,
  face, **and** Sketch Line all enabled together — confirmed during this
  phase that `filter.edge`/`filter.face` coexist fine in `hitTestBodies`,
  unlike `filter.body`/`filter.face`'s mutual exclusivity, and that
  `filter.sketchLine` hit-testing is a fully independent pass so it
  coexists just as freely with both), `_setPatternMode` (swaps the pushed
  selection filter and clears the mode being left), and
  `_openPatternPanelForEdit` now branches on the edited Feature's own
  `pattern_type` to reconstruct either Direction 1/2 state or axis state,
  pushing the matching filter. **Revision (same day):** exposed the
  Sketch-Line direction/axis both this phase and Phase 2 had deliberately
  deferred, reusing the exact same live-viewport-tap mechanism Revolve's
  own axis pick already uses rather than a dedicated Sketch-picker flow —
  `_setPatternDirectionFromEdge`/`_setPatternAxisFromEntity` were widened
  (the former renamed to `_setPatternDirectionFromEntity`) to also accept
  a `sketchLine`-kind entity and build a `sketch_line_ref`, and
  `_patternEdgeEntityFor`/`_patternAxisEntityFor` widened symmetrically to
  reconstruct a Sketch-Line entity's own viewport highlight when
  re-opening an existing Feature for editing.
- **Complexity/risk**: medium, as scoped. Two of the three axis sources
  (circular edge, cylindrical face) needed genuinely new OCCT checks;
  Sketch-Line axis reused Revolve's own machinery near-verbatim. The
  trickiest part was verifying rotation geometry without assuming OCCT's
  CW/CCW convention for a given `gp_Ax1` direction — solved with a
  direction-agnostic, set-based bounding-box-quadrant test rather than
  asserting a specific instance index lands at a specific position.

### Phase 5 — Merge options

**Status: implemented (2026-07-29) — see `docs/status.md`'s matching
dated entry for the full implementation/verification write-up.** Verified
for real: the full backend `pytest` suite (1091 tests, including 16 new
`test_stage_m_merge.py` ones plus 2 new native-format round-trip tests)
against genuine `pythonocc-core`, and the full client `flutter test` suite
(992 tests, including 7 new `MirrorPanel`/`PatternPanel` merge-toggle
ones) plus a clean `flutter analyze`, using freshly-bootstrapped local
toolchains (micromamba + conda-forge for the backend, a `master`-channel
Flutter SDK clone for the client — see `.github/workflows/client-
verify.yml`'s own comment on why `master`, not `stable`, is required here).

Fuse vs. keep separate, for both Mirror and Pattern (Rectangular and
Circular alike).

- **Deliverable**: a merge toggle on both panels — "Keep Separate"
  (default, unchanged Phase 1-4 behavior) vs. "Merge into One Body."
- **Backend**: `MergeMode` enum (`KEEP_SEPARATE`/`FUSE_INTO_ONE`),
  `merge` field retrofitted onto both `MirrorFeature` and `PatternFeature`
  (additive, default-preserving — `native_format.py`'s loader defaults a
  missing `merge` key to `KEEP_SEPARATE` for any pre-Phase-5 save). New
  shared `app.document.extrude._fuse_realized_instances` helper (placed
  next to `_apply_boss_or_cut`, since that's where the existing
  `MirrorFeature`/`PatternFeature` `compute_part_bodies` branches already
  live inline) — fuses every realized (already-transformed) instance
  together with every named source Body via repeated `BRepAlgoAPI_Fuse`,
  then registers the result under whichever source's own Feature index
  sorts lowest (`_apply_boss_or_cut`'s own survivor-tie-break convention,
  reused verbatim) rather than minting a brand-new id — mirrors a Boss
  fused into an existing target. A skipped Pattern instance (Phase 3)
  never even briefly exists as a shape, so it's never part of a
  `FUSE_INTO_ONE` merge either, for free. `schemas.py`/`router.py` thread
  `merge` through Create/Update/Response for both Feature types exactly
  like every other field.
- **Client**: a `SegmentedButton<MergeMode>` on both `mirror_panel.dart`
  and `pattern_panel.dart` (new shared `MergeMode` enum in
  `document_api_client.dart`, since — unlike `RevolveMode`/`PatternMode`,
  which each pick between disjoint field groups — this is a simple
  two-way toggle both Feature types share verbatim, not something worth
  duplicating per panel). `part_screen.dart` gained `_mirrorMerge`/
  `_patternMerge` state (reset to `KEEP_SEPARATE` at the start of every
  fresh session, reconstructed from the edited Feature's own stored value
  when re-opening an existing one for editing, included in both Features'
  own B4 edit-snapshot record types so Cancel restores it correctly) and
  `_setMirrorMerge`/`_setPatternMerge` setters wired into the live-preview
  debounce, mirroring every other toggle field's exact shape.
- **Complexity/risk**: low-medium, as scoped. Fuse logic was genuinely
  copy-adjacent to `_apply_boss_or_cut`'s existing multi-target logic, not
  a new OCCT risk; the real design decision was the survivor-id
  tie-break (the fused Body inherits an existing source's id rather than
  the Feature's own), which fell out directly from mirroring that
  existing convention rather than needing a new one.

### Phase 6 — Multi-feature seed selection (+ Pattern's own multi-body)

**Status: implemented (2026-07-29) — see `docs/status.md`'s matching
dated entry for the full implementation/verification write-up.** Verified
for real: the full backend `pytest` suite (1115 tests, including 20 new
`test_stage_n_multi_source.py` ones plus native-format round-trip
coverage) against genuine `pythonocc-core`, and the full client
`flutter test` suite (1016 tests, including new `FeatureTreePanel`/
`MirrorPanel`/`PatternPanel`/`PartScreen` Phase 6 coverage) plus a clean
`flutter analyze`, using freshly-bootstrapped local toolchains (micromamba
+ conda-forge for the backend, a `master`-channel Flutter SDK clone for
the client).

"Patterning bodies, patterning features" at full generality.

**Revision (2026-07-24)**: Mirror's own multi-*body* seeding (`source_
body_ids` widened from exactly-one to 1+) was pulled forward into Phase 1
directly, on guided-flow UX feedback — see that phase's own updated entry.
What remained here was: (a) Pattern's own multi-body widening, and (b)
multi-*feature* seeding (`source_feature_ids`) for both Mirror and
Pattern.

- **Deliverable**: Pattern accepts a multi-select of Bodies (matching
  Mirror's own Phase-1-shipped behavior); both Pattern and Mirror accept
  Feature-tree entries as sources, resolved to their current output
  Body/Bodies per §2.8.
- **Backend**: `PatternFeature.source_body_ids` validation widened from
  exactly-one to 1+ (`app.document.router._validate_pattern_source_
  body_ids`), mirroring `MirrorFeature`'s own Phase 1 revision exactly.
  `source_feature_ids` (new list field, both Feature types) resolves via
  the one-line `base_feature_id` lookup from §2.8 — no new resolution
  machinery; the lookup itself lives in `app.document.graph.
  body_ids_for_feature_id` (order-preserving, unlike the scope doc's own
  set-comprehension pseudocode, since Pattern/Mirror both need
  deterministic per-source Body registration). Each of `mirror.py`/
  `pattern.py` gains a small `effective_mirror_source_body_ids`/
  `effective_pattern_source_body_ids` wrapper: combines `source_body_ids`
  with every Body each `source_feature_ids` entry currently resolves to,
  deduplicated preserving order (naming the same Body both directly and
  via its own owning Feature mirrors/patterns it once, not twice), raising
  a structured `missing_reference` (keyed by `feature_id` instead of
  `body_id`) for a `source_feature_ids` entry that currently resolves to
  no Body at all. **Real design decision made along the way**: the
  accepted-producer-type set for both `source_body_ids` and
  `source_feature_ids` was widened to also include `MirrorFeature`/
  `PatternFeature` themselves (previously only `ExtrudeFeature`/
  `RevolveFeature`/`SweepFeature`/`ImportFeature`) — Phase 1's own
  docstring had explicitly deferred chaining a Mirror/Pattern off another
  Mirror/Pattern's own output to "Phase 6 scope"; this phase is where that
  promise is actually delivered, completing §3's survey table's own
  "Pattern seed = pattern (nested patterns) — structurally unblocked
  already" entry for real rather than leaving it aspirational.
  `compute_part_bodies`'s `MirrorFeature`/`PatternFeature` branches
  (`extrude.py`) pass the *effective* (expanded) source-id list to
  `_fuse_realized_instances` for `MergeMode.FUSE_INTO_ONE`, not the raw
  field — a Feature-tree-picked source's own real Body must be absorbed
  into the fuse too. Pattern's own multi-source instance naming: a single
  effective source keeps the exact pre-Phase-6 scheme (`feature.id` /
  `feature.id#{index}`) unchanged; 2+ sources use a new
  `feature.id#{source_index}_{index}` scheme (every source shares the
  identical instance-transform grid — same direction/axis/count/spacing/
  skip_indices — so only the linear instance index, not a per-source one,
  needs to vary). New `backend/tests/test_stage_n_multi_source.py` (20
  tests): `source_feature_ids` alone, combined with `source_body_ids`,
  dedup when a Body is named both ways, unknown/wrong-type
  `source_feature_ids` rejection (400), a `MirrorFeature` accepted as a
  nested `source_feature_ids` producer, PATCH updating
  `source_feature_ids`, Pattern's 2+-`source_body_ids` widening producing
  bodies for both sources (translated independently, verified via bbox),
  multi-source `skip_indices` applying uniformly to every source,
  multi-source `FUSE_INTO_ONE` absorbing every source and instance into
  one survivor, and cascade delete via a `source_feature_ids`-only source
  — plus `test_stage_native_format.py` round-trip/backward-compatibility
  coverage for `PatternFeature.source_feature_ids`.
- **Client**: on-device/real check (per this phase's own noted
  uncertainty) confirmed `feature_tree_panel.dart` had **no** existing
  multi-select mechanism at all — every prior mode there (the Extrude/
  Revolve/Sweep Sketch pickers) is single-pick, commits immediately. New
  `FeatureTreePanel.isFeaturePickerMode` (`pickableFeaturePickerIds`/
  `selectedFeaturePickerIds`/`onFeaturePickerToggle`): a row tap toggles
  membership instead of committing, dimmed-and-inert for a non-pickable
  row (no SnackBar the way the sketch picker's own ineligible-tap
  feedback works — dimming alone is enough here), a checkmark trailing
  icon for a selected row, and a top banner naming the running selection
  count — confirmed via a checkmark FAB `PartScreen` itself owns (`_start
  SourceFeaturePicker`/`_confirmSourceFeaturePicker`/`_cancelSourceFeature
  Picker`, new shared `_SourceFeaturePickerTarget { mirror, pattern }`
  state), not a button embedded in the tree panel. `pickableFeaturePicker
  Ids` mirrors the backend's own widened accepted-type set (`extrude`/
  `revolve`/`sweep`/`import`/`mirror`/`pattern`), excluding whichever
  Mirror/Pattern is currently being configured itself.
  `mirror_panel.dart`/`pattern_panel.dart` both gained a `sourceFeatureIds`
  summary line ("N Feature(s) added from the Build Tree") and an "Add from
  Tree" button opening the picker.

  Pattern's own multi-body widening: `_PatternStep.pickingBody` (singular,
  immediately-advances-on-one-tap) became `pickingBodies` (plural),
  restructured to mirror `_MirrorStep.pickingBodies`'s own multi-select-
  then-confirm shape exactly (`_confirmPatternBodySelection` now a no-arg
  checkmark-FAB confirm, not a per-tap single-Body handler) —
  `_patternSourceBodyId: String?` became `_patternSourceBodyIds:
  List<String>?` throughout `part_screen.dart`, including widening
  `_patternInstanceIndexForBodyId`/`_patternSkippedBodyIds` (the Phase 3
  viewport-tap-to-skip machinery) to parse both the pre-Phase-6 single-
  source body-naming scheme and the new multi-source
  `feature.id#{sourceIndex}_{index}` one. `selection_actions.dart`'s
  ambient `contextActionsFor` Pattern branch widened from "exactly one
  Body" to "1+ Bodies" to match, now identical to Mirror's own branch.
- **Complexity/risk**: medium, as scoped — the backend half tracked the
  original low-medium estimate closely (Pattern's multi-body widening
  really was a direct copy of Mirror's Phase 1 revision; `source_
  feature_ids` resolution really was the one-line lookup plus a thin
  dedup wrapper). The client half ran higher than "low-medium": the
  Feature-tree multi-select mechanism didn't exist and had to be built
  from scratch (confirmed, not assumed, exactly per this phase's own
  flagged uncertainty), and Pattern's `pickingBody` → `pickingBodies`
  restructuring touched a wide surface of `part_screen.dart` (every state
  field, picker/reset/edit/confirm/cancel function, and the skip-instance
  body-naming parser) rather than being a narrow, local change.

### Phase 7 — Sketch-level Pattern and Mirror

2D, sketch-entity-level, per §2.9.

**Status: implemented (2026-07-30), plus a same-day on-device-feedback
follow-up round — see `docs/status.md`'s two matching dated entries (the
original implementation, and the follow-up) for the full write-up.**
Verified for real: the full backend `pytest` suite (1163 tests as of the
follow-up round: 1152 original + 11 new two-direction ones) against genuine
`pythonocc-core`, and the full client `flutter test` suite (1058 tests as of
the follow-up round) plus a clean `flutter analyze`, using freshly-
bootstrapped local toolchains (micromamba + conda-forge for the backend, a
`master`-channel Flutter SDK clone for the client, per every prior phase's
own bootstrap).

**Follow-up round (on-device feedback)**: fixed a Pattern/Mirror-toggle
state-loss bug (switching operations mid-configuration silently dropped the
in-progress preview); reworked the sketch-level ribbon onto the shared
`ResizableToolPanel` (the same pull-to-resize/scrollable shell the 3D
`PatternPanel` and every other Feature panel already use, rather than a
fixed-height clone of Offset's much simpler bar); added two-direction
pattern support (`direction_2`/`count_2`/`spacing_2`/`reverse_2`, row-major
grid expansion, matching `PatternFeature`'s own convention); fixed the
2D sketcher's green closed-profile fill and the embedded-in-3D-viewport
equivalent to resolve a Profile loop's synthetic Pattern/Mirror ids (both
now fall back to `SketchController.committedPatternMirrorExpansion` instead
of only real `points`/`arcs`); made a patterned/mirrored entity actually
render in the Part's 3D viewport when its Sketch isn't being actively
edited (`expandPatternMirrorDtos`, the DTO-based sibling of the same
expansion module, merged into `part_screen.dart`'s own geometry-refresh
pipeline); and made a patterned/mirrored entity selectable (as its whole
owning instance, never an individual derived copy) inside the sketch
editor, with "Edit Pattern"/"Delete Pattern" ribbon actions once selected.

**Design revisions found while implementing, not anticipated by §2.9's
original v1 write-up:**

- **A same-sketch direction/mirror-line reference doesn't need the full
  `SketchEntityRef`.** §2.9's own text suggested reusing `SketchEntityRef`
  ("trivially available since it's the same Sketch") for "use this Sketch
  Line as direction." In practice this is strictly simpler: a Pattern
  direction or Mirror's own mirror line always lives in the *same* Sketch
  as its source entities, so carrying a separate `sketch_id` alongside it
  (as the general, cross-Sketch `SketchEntityRef` does - the type
  `RevolveFeature.axis_ref`/`SweepFeature.path_refs` need, since *those*
  reference a Sketch from *outside* it via the Document layer) only
  invites a cross-Sketch-id mismatch class of bug with no benefit. Shipped
  instead as a bare `line_id: str` field (`SketchPatternDirection`/
  `SketchMirrorInstance.mirror_line_id`, `app/sketch/models.py`) - resolved
  by a direct dict lookup against `self.entities`, the same "no OCCT
  topology re-derivation" simplicity `SketchEntityRef`'s own docstring
  already describes, just without the redundant id.
- **The real, load-bearing find: a transformed Point that lands back on
  its own source Point's exact position must reuse that Point's own id,
  not mint a synthetic one.** This is always true for a Mirror instance's
  own axis-crossing Points (the fixed points of a reflection), never true
  for a Pattern instance's own pure translation (which has no fixed
  points). Discovered directly via testing, not anticipated up front: the
  single most common real-world reason to mirror a sketch at all - draw
  half a symmetric profile up to a centerline, mirror it across that
  centerline, get one closed loop - silently failed without this fix. The
  real half and its own derived mirror image shared no Point ids at all
  (each a separate, independently-computed synthetic Point per the
  original design), so even though the two open ends visually coincided,
  `detect_profile`'s id-based connectivity walk saw two disjoint open
  chains, never one closed loop. Fixed in `Sketch._place_transformed_
  entity`'s own `transformed_point` helper (`app/sketch/models.py`) - see
  that method's own doc comment for the full reasoning, and
  `test_detect_profile_closes_a_loop_mirrored_from_a_half_profile`
  (`test_stage_o_sketch_pattern_mirror.py`) for the regression test this
  fix is verified against. This changes nothing about Pattern's own
  output.
- **`detect_profile`'s own expansion is a local reassignment, not a
  mutation - every downstream caller that goes on to build OCCT wires from
  its result needs the identical re-expansion, explicitly.** `detect_
  profile(sketch)` reassigns its own `sketch` parameter to `sketch.
  expand_pattern_and_mirror_instances()` as its first line (a Sketch with
  no instances gets back the exact same object, so this is a no-op for
  every pre-Phase-7 sketch, confirmed by the full existing suite passing
  unchanged) - but that reassignment is local to `detect_profile`'s own
  call frame. `app.document.extrude`/`revolve`/`sweep` each call `detect_
  profile(sketch)` and then separately pass the *same* `sketch` variable to
  `wire_for_profile`/`face_for_profile`/`_prism_for_profile`, which index
  `sketch.points`/`sketch.entities` directly - those three call sites each
  needed their own explicit `sketch = sketch.expand_pattern_and_mirror_
  instances()` line (deterministic synthetic ids, per that method's own
  doc comment, make calling it twice safe and cheap) so a `Profile`'s
  synthetic point/entity ids actually resolve when the wire gets built.
  `app.document.router`'s two `detect_profile` call sites
  (`_require_closed_sketch_feature`/`_validate_profile_refs`) needed no
  such change - neither ever builds a wire from the result, and `profile_
  refs` can only ever name a *real* entity (`resolve_sketch_entity` looks
  up the live store, which never contains synthetic ids), so a pattern/
  mirror instance's own derived copies are correctly never independently
  selectable as a profile anchor either.
- **v1 scope narrowed from the fully general "any direction/axis" shape
  the 3D `PatternFeature`/`PatternDirectionRef` eventually grew to** -
  deliberately, given this phase's own "medium-high, `detect_profile` is
  the real risk" complexity note: linear (one direction) Pattern only, no
  circular/two-direction-grid/skip-instances variants, and Pattern's own
  direction (like Mirror's own mirror line) is either a fixed local X/Y
  axis or an existing Sketch Line's own direction - there is no 2D
  equivalent of `PatternDirectionRef.edge_ref` (a Sketch has no OCCT edges
  of its own; every straight thing in it already is a Line). Client v1
  reuses Offset's exact flat pick-then-configure shape with zero extra
  wizard steps: while the value bar is open (non-modal, same as Offset's
  own), a canvas tap on a Line sets the direction/mirror line directly (no
  separate "pick direction" step the 3D panels need) - one `SketchMode`
  entry with an internal Pattern/Mirror `SegmentedButton` toggle covers
  both operations, per this section's own original design. Each of these
  is a natural, cheap future widening behind the identical field/endpoint
  shapes already shipped (a circular sketch pattern would add a
  `pattern_type`/axis-point field exactly like `PatternFeature`'s own
  Phase 2 → Phase 4 progression did), not a redesign.
- **A committed instance's own derived geometry is never persisted as a
  mesh/cache - recomputed fresh from current source geometry on every
  read, client and server alike.** This was already §2.9's own design
  intent ("full associativity by construction"), confirmed working
  end-to-end: `Sketch.expand_pattern_and_mirror_instances` (backend) and
  `SketchController.patternMirrorGhosts` (client, a second, independent
  implementation of the identical 2D math - the same accepted-duplication
  call `offsetPreviewGhosts`'s own doc comment already made for this
  codebase's live-preview code) both recompute from scratch every call, so
  dragging a Point that defines a patterned/mirrored source entity moves
  every derived copy automatically, with no explicit invalidation/refresh
  step anywhere.

- **Deliverable**: inside the sketcher, select one or more Line/Circle/Arc
  entities, pattern (translate along a fixed X/Y axis or an existing
  Line's own direction, with count/spacing/reverse) or mirror (reflect
  across an existing Line, real or construction) them within the 2D
  sketch - lightweight, non-independent instances, contributing to the
  sketch's extrudable profile via `detect_profile`'s own expanded view,
  never appearing as independently selectable/draggable/deletable Points/
  entities in the Sketch itself.
- **Backend**: `SketchPatternInstance`/`SketchMirrorInstance` (new
  lightweight dataclasses in `app/sketch/models.py`, plus `Sketch.
  pattern_instances`/`mirror_instances` dicts) - pure 2D math (translate/
  reflect), no OCCT/py-slvs solver involvement at all, modeled after
  Ellipse/Arc/Spline's own "decompose into plain Points/Lines, don't touch
  the solver" precedent for not needing a new dedicated py-slvs primitive
  (though, unlike those, a pattern/mirror instance's own derived Points/
  entities are never added to `self.points`/`self.entities` at all - see
  `expand_pattern_and_mirror_instances`). `detect_profile`'s own expansion
  pre-pass (§2.9, revised above); new CRUD endpoints (`POST`/`GET`/`PATCH`/
  `DELETE .../pattern-instances[/{id}]` and `.../mirror-instances[/{id}]`)
  mirroring every other sketch-entity endpoint's own validate→construct/
  mutate→respond shape and 404/400 error-translation convention exactly.
  `native_format.py` round-trip support, defaulting a missing key to `[]`
  for backward compatibility with every pre-Phase-7 save, same convention
  every other additive Sketch field already uses.
- **Client**: new `SketchMode.pattern` entry reusing Offset's exact
  interaction shape (`enterPatternMode`/`_handlePatternTap`/
  `finishPatternPick`, mirroring `enterOffsetMode`/`_handleOffsetTap`/
  `finishOffsetChain`), `sketch_pattern_bar.dart` (`PatternPickBar` cloned
  from `OffsetPickBar`, `PatternValueBar` cloned from `OffsetValueBar` and
  widened with the Pattern/Mirror toggle plus count/spacing/direction/
  reverse fields), client-side live preview (`SketchController.
  patternMirrorGhosts`, wired into both `sketch_canvas.dart`'s 2D painter
  and `sketch_screen.dart`'s embedded-3D-view ghost rendering, reusing the
  existing `LineGhost`/`CircleGhost`/`ArcGhost` pipeline unchanged),
  Finish-commits-to-backend flow (`confirmPatternMirrorPreview`, with a
  single-step undo deleting the created instance, mirroring `offsetLine`'s
  own undo shape). A committed instance's own id/config is recorded
  locally (`patternInstances`/`mirrorInstances` maps, fetched on
  `adoptSketch` alongside every other entity collection) so its derived
  ghosts keep rendering - and stay associative - after the session that
  created it ends, not just during live preview.
- **Explicit v1 non-goals, matching §2.9's own**: an individual *derived
  copy* can't be independently edited/deleted/dimensioned - only its whole
  owning Pattern/Mirror instance can (select any one of its copies in the
  sketch editor, then "Edit Pattern"/"Delete Pattern" - added in the same-
  day on-device-feedback follow-up round, along with two-direction pattern
  support; both were originally deferred here, see that round's own
  write-up above and in `docs/status.md`). Still deferred: circular sketch
  patterns, skip-instances, and a Body-edge (from a sibling 3D Body) as a
  direction/mirror-line source, per the scope-narrowing note above.
- **Complexity/risk**: medium-high, as scoped - architecturally simpler
  than it first looked (no solver/DOF changes), but `detect_profile`'s own
  core wire-assembly logic genuinely needed real care: the full pre-
  existing backend suite (1115 tests before this phase) passing completely
  unchanged confirms the no-op-for-non-patterned-sketches guarantee holds,
  and the Point-welding fix above was a real correctness gap the original
  design didn't anticipate, found only by writing the "close a loop by
  mirroring a half-profile" test the deliverable's own load-bearing use
  case implies.

### Phase 8 — Feature pattern and feature mirror (Cut/Boss into a shared target)

**Status: scoped (2026-07-29), not started.** Per §2.11 — the
Extrude/Revolve/Sweep-into-shared-target subset of Option B (§2.8),
covering both Pattern and Mirror. Direct trigger: on-device follow-up
noting that mirroring an asymmetric hole pattern into the *same* Body
(rather than producing a second, independent mirrored Body) is a real,
common use case with no correct path today — see §2.11's own "why
`FUSE_INTO_ONE` doesn't cover this" reasoning.

- **Deliverable**: pick an eligible upstream Cut/Boss-into-target
  Feature (not a Body) as the seed; Pattern repeats its own cut/boss
  effect N times into the same shared target; Mirror reflects it once
  into the same shared target — e.g. a plate with one off-center hole,
  mirrored, ends up with two holes (its own mirror image), not two
  separate plates.
- **Backend**: `tool_feature_id: str | None` on both `MirrorFeature`/
  `PatternFeature` (mutually exclusive with `source_body_ids`/
  `source_feature_ids`); new `resolve_feature_tool_shape` (`extrude.py`)
  factoring the tool-shape computation out of `compute_part_bodies`'s
  existing inline `ExtrudeFeature`/`RevolveFeature`/`SweepFeature`
  branches so both that loop and Pattern/Mirror's new path can share it;
  one combined `BRepAlgoAPI_Cut`/`BRepAlgoAPI_Fuse` per Pattern/Mirror
  resolution (per §2.11's own "union then one boolean" shape, not N
  separate booleans); new `_tool_feature_dependency` graph edge; new
  `invalid_tool_feature_ref` validation.
- **Client**: a third seed-picking path on both panels (Feature-tree
  selection of an eligible Cut/Boss, rather than a Body/edge/plane pick)
  — exact UI shape needs an on-device pass, not fully speculated in
  §2.11.
- **Complexity/risk**: medium-high, as scoped in §2.11 — the real risk
  is safely factoring `resolve_feature_tool_shape` out of already-shipped
  `compute_part_bodies` logic without regressing it (every existing
  Extrude/Revolve/Sweep test must keep passing unchanged); the
  Pattern/Mirror-side logic itself closely mirrors Phase 5's
  already-shipped `_fuse_realized_instances` shape.

### Phase 9+ — Explicitly deferred, not scheduled

Per §3's survey: pattern-along-a-curve, sketch-driven/table-driven
pattern, fill pattern, varying instance spacing, a standalone
`CreateAxisFeature`, **Fillet/Chamfer feature-pattern/mirror** (the
genuinely-hard remainder of Option B — see §2.11's own scope-boundary
note; the Extrude/Revolve/Sweep subset is Phase 8, not deferred),
per-instance independent sketch-pattern editing (§2.9's Option 1
upgrade), and equation-driven instance parameters. Each is called out
above with its one-line "why not now" reason preserved, so a future
scoping pass doesn't have to re-derive the reasoning from scratch.

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
- **Phase 8 (§2.11) only**: `backend/app/document/extrude.py`'s
  `_apply_boss_or_cut` (`extrude.py:608`) and `compute_part_bodies`'s own
  `ExtrudeFeature`/`RevolveFeature`/`SweepFeature` branches — the source
  of the pre-boolean tool-shape computation `resolve_feature_tool_shape`
  extracts into a standalone, reusable function. This is the one file
  where Phase 8 touches already-shipped logic rather than adding
  alongside it, so it's the phase's own primary risk surface.

## 6. Carried-over notes (2026-07-30), not yet actioned

Surfaced during the on-device feedback rounds that produced Phase 6 and
its two follow-up fix rounds (see `docs/status.md`'s matching 2026-07-30
entries). None of these block Phase 7/8 — recorded here so a future
session doesn't have to rediscover them.

- **Fillet/Chamfer share Mirror/Pattern's own "doesn't show up after
  creation" bug.** `_confirmMirror`/`_confirmPattern` (`part_screen.dart`)
  were fixed to explicitly call `_refreshFeatures()` on confirm, since
  `_endRollback()` alone is a no-op for a brand-new creation flow (only
  engaged when editing an *existing* Feature row). `_confirmFillet`/
  `_confirmChamfer` have the exact same shape and the exact same latent
  bug — not yet reported on-device, but real: a freshly-created Fillet or
  Chamfer won't show up in the Build Tree until an unrelated later action
  happens to refresh it. Extrude/Revolve/Sweep already call
  `_refreshFeatures()` explicitly on confirm and don't have this problem.
- **No on-device verification yet for any Phase 6 work or its two fix
  rounds.** Everything has been verified via `flutter analyze`/`flutter
  test` only — no phone has touched the sandbox sessions that did this
  work. The `PickerRibbon` two-row/`Wrap` restructure (2026-07-30) is a
  solid bet given the regression test now pinning it at a 320px surface
  width, but it's exactly the kind of layout fix that already needed a
  second pass once real on-device feedback came in — worth a real-device
  glance before trusting it fully.
- **Fake test backend (`client/test/part_screen_test.dart`'s
  `_FakeDocumentBackend`) still has no `POST .../mirror-features`/
  `.../pattern-features` handler**, only `PATCH` against an
  already-seeded Feature (plus a `/mesh` fallback for a Feature-only-
  seeded Pattern, added 2026-07-30, that returns the generic single-
  placeholder mesh rather than resolving `source_feature_ids` for real).
  This hasn't bitten correctness yet, but it means no `part_screen_test.dart`
  test can exercise a brand-new Mirror/Pattern's *create* network call
  end-to-end, only edits to a pre-seeded one. Phase 8's new
  `tool_feature_id` creation path is exactly the kind of thing a real
  create-flow test would catch that PATCH-only testing can't — worth
  extending this fake if Phase 8 work runs into it.
