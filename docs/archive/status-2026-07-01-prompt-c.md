# Prompt C — Profile detection and rendering fixes — status — 2026-07-01

Branch: `claude/new-session-s8daac` (cut from `main`, which already had
Prompts A/B/D merged — C1 depends on B2's `is_construction` flag, which is
already in place).

## Items implemented

| # | Item | Status | Files changed |
|---|------|--------|----------------|
| C1 | Nested profiles (hole in a plate) | Done | `profile.py`, `extrude.py`, `models.py`, `schemas.py` (backend `sketch`), `router.py` (backend `sketch`), `test_stage2_profile.py`, `test_stage9_extrude.py` |
| C2 | Multiple disjoint closed profiles → compound extrude | Done | `profile.py`, `extrude.py`, `router.py` (backend `document`), `test_stage2_profile.py`, `test_stage9_extrude.py` |
| C3 | Edge bleed-through in the 3D render | Done | `mesh_geometry.dart`, `part_viewport.dart`, `mesh_geometry_test.dart` |

C1 and C2 share one implementation (`profile.py`'s `_classify_nesting`) and
land together rather than as two separate passes — see C1's section below
for why.

---

## C1/C2 — Nested and multi-profile detection (`backend/app/sketch/profile.py`)

### What changed

`detect_profile` previously handled two disconnected cases: a single
Line-chain closed loop, or (only when there were **no** Lines at all)
standalone Circles. Multiple Line-chain loops were already traced correctly
but always treated as an unstructured, unusable `MULTIPLE_LOOPS` error.
Circles mixed into a sketch that also had Lines were silently invisible to
profile detection at all — a documented gap in the `Circle` class'
docstring.

This is rewritten as: trace every Line-chain loop *and* every standalone
Circle (regardless of whether Lines are also present) into one flat list of
closed loops, then classify that list with a new `_classify_nesting`:

- A loop's **centroid** (vertex average for a polygon, center point for a
  Circle) is tested against every other loop's boundary (ray-casting
  point-in-polygon, or a plain distance check for a Circle) via
  `_loop_contains_point`.
- A loop is a **hole** of the *larger-area* loop that contains its
  centroid; a loop contained by no larger loop is itself an **outer**
  profile. The area tie-break (`_loop_area`) matters for the very common
  case of a hole centred on its container (e.g. a plate with a hole
  drilled through its own middle): the container's centroid then also
  falls inside the small hole, so a centroid-only test would see each
  loop contain the other. This was caught by a real assertion failure
  against a live, real-OCCT test run (see "Test/analyze results" below),
  not found by inspection — comparing area resolves it the way anyone
  would expect (the bigger loop is always the container).
- A loop contained by **two or more** others (a hole nested inside another
  hole) is rejected as a new `ProfileStatus.INVALID_NESTING`, deferred per
  the prompt's explicit scope.
- **One** outer loop (with 0+ holes attached as `Profile.inner_loops`) is
  C1's case, reported as the existing `ProfileStatus.CLOSED_LOOP` —
  `profile` is populated exactly as before, just now possibly carrying
  holes.
- **Two or more** outer loops (C2's "MultiProfile") reuses the existing
  `ProfileStatus.MULTIPLE_LOOPS` / `ProfileDetectionResult.loops` shape —
  each entry is itself a `Profile` that may carry its own `inner_loops`.
  This is a deliberate reuse rather than introducing a distinct
  `MultiProfile` type as the prompt sketches: the existing
  `loops: list[Profile]` field already has exactly the right shape, and
  every existing test/caller that checks `status == MULTIPLE_LOOPS` and
  reads `.loops` continues to work unchanged (see the existing
  `test_multiple_disjoint_loops_are_detected` /
  `test_multiple_standalone_circles_are_multiple_loops` tests, both still
  green with zero changes).

`Profile` gained one new field: `inner_loops: list[Profile] = []` (empty
default, so every existing construction site is unaffected).

**C1 and C2 land together, not staged**, despite the prompt separating
them: the prompt's own C1 spec says to *reject* "more than one outer loop
(use C2 for that case)", and C2 explicitly builds on C1's nesting logic —
implementing C1's reject-then-redo step first would just be thrown away
the moment C2 landed in the same commit anyway.

### `backend/app/document/extrude.py` (Extrude module)

- `_face_for_profile` now builds the face via
  `BRepBuilderAPI_MakeFace(outerWire)` then `.Add(innerWire)` per hole,
  exactly as the prompt specifies. `BRepBuilderAPI_MakeFace.Add` does not
  reorient wires for you — an inner wire wound the *same* way as the outer
  one produces an invalid/doubled face, not a hole — so each inner wire's
  winding is checked against the outer's via a new `_wire_normal` helper
  (build a standalone face from just that one wire, read its real surface
  normal back via `BRepAdaptor_Surface`, correcting for
  `TopAbs_REVERSED`) and reversed if it matches. This sidesteps having to
  reason analytically about `_wire_for_profile`'s winding direction (a
  Line-chain loop's is whatever order `profile.py`'s graph walk happened to
  trace it in; a Circle's is fixed by the plane's `gp_Ax2`, and — as
  confirmed empirically, see below — that fixed direction is *not* the
  same "handedness" relative to the plane normal on all three reference
  planes) by asking OCCT directly instead.
- `_solid_for_extrude_feature` now accepts both `CLOSED_LOOP` and
  `MULTIPLE_LOOPS` (previously only `CLOSED_LOOP`), builds one prism per
  sub-profile (`_prism_for_profile`, the single-profile logic factored out
  unchanged), and — when there's more than one — combines them into a
  `TopoDS_Compound` via `BRep_Builder`. Every existing caller
  (`compute_part_solid`) is unaffected: it already only cares that it gets
  back one `TopoDS_Shape`, compound or not.
- `backend/app/document/mesh.py` needed **no changes** — `tessellate_shape`
  already walks faces/edges/vertices via `TopExp_Explorer`/
  `topexp.MapShapes` directly on the input shape, both of which already
  traverse into a `TopoDS_Compound`'s constituent solids transparently.

### `backend/app/document/router.py` / `backend/app/sketch/router.py`

- `_require_closed_sketch_feature` (gates creating an `ExtrudeFeature`) now
  accepts `MULTIPLE_LOOPS` alongside `CLOSED_LOOP` — without this, C2's
  MultiProfile sketches would classify correctly but never be extrudable
  at all, since this was the one remaining place still hard-coded to
  `CLOSED_LOOP` only.
- `ProfileResponse` gained `inner_loops: list[ProfileResponse] = []`
  (self-referential, empty default) and `_profile_response` now recurses
  into it. No other client-facing schema changed.

### Client

No changes needed, per the prompt's own note to check first: the only
client consumer of `/sketches/{id}/profile`
(`ProfileDetectionDto.fromJson` in `sketch_api_client.dart`) reads only
`status` and the outer `profile.point_ids` — it does not parse
`branch_point_ids`/`loops`/`inner_loops` at all, and a Sketch becoming
extrude-eligible via `MULTIPLE_LOOPS` needs no client change either, since
`_require_closed_sketch_feature`'s HTTP-level gate (not a client-side
status check) is what actually decides extrude eligibility for creation,
and the Feature-tree extrude picker (Prompt D) already just tries the
create call and shows the server's error on failure.

### Test coverage (all new tests run against the real backend + OCCT — see below)

- `test_stage2_profile.py`: a smaller square inside a bigger one is one
  `CLOSED_LOOP` with an `inner_loops` hole (not two loops); a Circle inside
  a square is a hole; a construction-only inner loop is ignored; three
  concentric squares (hole inside a hole) is rejected as
  `INVALID_NESTING`; the nested-profile response is checked over the real
  HTTP API; two disjoint rectangles are a `MULTIPLE_LOOPS` MultiProfile;
  one MultiProfile sub-profile can carry its own hole independently of the
  other.
- `test_stage9_extrude.py`: extruding a square-with-a-square-hole produces
  exactly 10 distinct mesh faces (2 end caps with a hole + 4 outer walls +
  4 inner walls, matching the prompt's own worked example exactly);
  extruding a square-with-a-circular-hole produces 7 (2 end caps + 4 outer
  walls + 1 cylindrical inner wall); a sketch with two disjoint squares is
  accepted for extrude creation; extruding it produces a
  `TopoDS_Compound` with exactly 2 solids (checked directly via
  `TopExp_Explorer`/`TopAbs_SOLID`, per the prompt's own suggested
  verification) and a mesh with 12 faces / 24 triangles (two independent
  6-face boxes); a MultiProfile where one sub-profile has a hole produces
  16 faces total (10 + 6) — the hollow sub-profile's holed solid is
  unaffected by being unioned into a compound with a plain one.

---

## C3 — Edge bleed-through in the 3D render (`client/lib/viewport3d/mesh_geometry.dart`, `part_viewport.dart`)

### What was there before

`buildMeshEdgesNode` already rendered edges as `PolylineGeometry` segments
essentially coplanar with the face triangles beneath them, and there was
already one prior attempt at a fix in place: `nudgeSegmentsOutward` pushed
every edge point a fixed `0.02` world units directly away from the mesh's
bounding-sphere **center**. This is exactly the kind of "unacceptable
trade-off" the prompt describes: at a glancing viewing angle, "away from
mesh center" and "towards the camera" can be nearly perpendicular
directions, so the existing nudge barely increased depth-buffer separation
for precisely the edges the bug report is about — the silhouette/grazing
case.

### Approaches evaluated, in the prompt's preferred order

1. **Separate always-on-top pass, depth test/write disabled for edges.**
   Not achievable: `flutter_scene` 0.18.1's public API is `Scene.add(Node)`
   into one implicitly depth-tested pass, with no per-material
   depth-test/depth-write toggle and no way to declare a second, later
   render pass. This was already established by the *previous* fix's own
   doc comment (now removed) — written when this was confirmed against
   the real package — so it was not re-investigated from scratch.
2. **Chosen.** Push each edge vertex a small amount towards the camera,
   approximating a per-pixel NDC/clip-space depth bias in world space.
3. **Enlarge the offset only on near-face-parallel segments.** Not
   attempted: it needs a per-edge-segment "which face is this edge part
   of" lookup, and `MeshDto` has no such adjacency — `faceIds`/`edgeIds`
   are two independent dense id lists with no link between them. Adding
   one would mean extending `mesh.py`'s tessellation and the wire schema,
   which is out of C3's client-only scope.

### What changed

- `nudgeSegmentsOutward(segments, center, amount)` → renamed
  `biasSegmentsTowardCamera(segments, cameraPosition, amount)`: same
  per-point cost (one subtract/normalize/scale per vertex), but the
  direction is now *towards the camera position* rather than *away from a
  fixed mesh-center point*.
- New `kEdgeDepthBias = 0.001`, matching the prompt's suggested name/value
  but reinterpreted as a **fraction of the mesh's bounding-sphere radius**,
  not a fixed world-space distance — a literal `0.001` world units would
  be an inch-scale offset on a small bracket and invisible on a
  metre-scale frame. Scaling off the model's own size (the same pattern
  Prompt A's auto-fit far clip already uses) keeps the effect consistently
  visible across the whole range of real part sizes this tool targets.
- Since the bias direction depends on the *current* camera position,
  `_syncEdgesNode` (in `part_viewport.dart`) is no longer only re-run when
  the mesh or render mode changes — it's now also re-run whenever the
  camera itself moves, via `setState(_syncEdgesNode)` calls added to:
  `_onPointerEnd` (orbit-drag, and the selection-mode two-finger
  pinch/pan path), `_onPointerSignal` (scroll-wheel zoom), `_doRecentre`
  ("Reset view"), and `animateToPlane` (View-menu "look at plane"
  transitions), once each gesture/animation **completes** rather than on
  every intermediate pointer-move delta or animation tick. This bounds the
  added cost to "once per finished camera move" instead of a
  `PolylineGeometry`-primitive-per-edge-segment rebuild on every frame of
  an active drag, which would be a real concern on the Pi 5 target
  hardware. Per the existing project convention, none of
  `_handlePointerDown`/`_handlePointerMove`/`_handlePointerEnd`/
  `_handlePointerSignal` (the orbit handler bodies) were touched — every
  new call is in a wrapper method or in `_doRecentre`/`animateToPlane`,
  neither of which is one of the four protected bodies.

### Known trade-off (disclosed, not silently accepted)

Because the resync only happens once per *completed* gesture, the bias
direction is briefly stale for the intermediate frames of an active drag
(it still points towards where the camera *was* at the start of the drag,
not each in-between frame). This is a deliberate cost/robustness trade-off
given this fix cannot be perf-profiled or visually verified in this
sandbox (see below) — it is still a strict improvement over the previous
fix, which used a single direction that was *never* correct at any
glancing angle, static or moving.

---

## Test/analyze results

### Backend

Unlike prior prompts in this project (see e.g. Prompt B's status doc),
this session was able to get the backend's **real** conda toolchain
working rather than a stub: `pythonocc-core` and `py-slvs` have no pip
wheels, but their `.tar.bz2`/`.whl` artifacts are hosted on
`conda.anaconda.org`, which is reachable in this sandbox even though
`conda.anaconda.org`'s installer script host and the wider Anaconda API
are not — so a `micromamba` binary was fetched directly as a conda-forge
package (extracted, not run through an installer script) and used to
build the exact environment `backend/environment.yml` specifies. This
means every backend test below — including the new C1/C2 tests exercising
real OCCT geometry construction (`BRepBuilderAPI_MakeFace.Add`, wire
orientation, `TopoDS_Compound`) — actually ran and passed, not merely
compiled against a stub. This is a meaningfully stronger verification bar
than prior prompts had available, and is how the area/centroid ambiguity
in `_classify_nesting` (see C1 above) was caught: it surfaced as a real
test failure (`test_a_circle_inside_a_square_is_a_hole` initially reported
`INVALID_NESTING` instead of `CLOSED_LOOP`) before being fixed, not
something reasoned about after the fact. None of this toolchain
bootstrapping is committed.

- `pytest tests/` (whole suite): **249 passed**, 0 failed (was 236 before
  this prompt; +13 new tests, all passing for real).
- Manually verified (not a `pytest` file, run ad hoc against the real
  `TestClient`) that C1's hole-in-a-plate case produces exactly 10 mesh
  faces on **all three** reference planes (`XY`/`XZ`/`YZ`), not just `XY`
  — this specifically exercises `_wire_normal`'s per-plane robustness,
  since `plane_normal`/`sketch_point_to_world`'s three embeddings do *not*
  all share the same handedness (XZ's is the mirror image of XY/YZ's, by
  direct derivation), so a hand-rolled "signed area" orientation check
  would have needed a per-plane correction that asking OCCT for the real
  normal avoids entirely.
- Manually verified the `INVALID_NESTING` case is rejected at extrude
  creation with a 400 and a descriptive detail message, via the real HTTP
  API.

### Client

- `flutter analyze lib/viewport3d/mesh_geometry.dart
  lib/viewport3d/part_viewport.dart test/mesh_geometry_test.dart` — no
  issues.
- `flutter analyze` (whole project) — 2 issues, both pre-existing and
  unrelated (`test/selection_list_drawer_test.dart`'s `const` set of a
  non-primitive-equality type) — confirmed via `git diff` that this file
  was not touched by this prompt.
- `flutter test` (whole suite) — 148 passed, 17 failed. All 17 are the
  same pre-existing `flutter_scene 0.18.1` vs. this sandbox's stable
  3.44.4 engine (`flutter_gpu` API mismatch) failures documented in every
  prior prompt's status doc (`mesh_geometry_test.dart` among them) — not
  something this prompt introduced. `flutter test
  test/mesh_geometry_test.dart` alone fails to even load for the same
  reason (`mesh_geometry.dart` itself imports `flutter_scene`).
- Unlike prior prompts, a working Flutter SDK **was** available this
  session (`storage.googleapis.com`'s official release archive and
  `pub.dev` are both reachable here, unlike `micro.mamba.pm`/
  `api.anaconda.org`/generic `github.com`, none of which are) — so
  `flutter analyze` above is a real run against the official stable
  3.44.4 tarball, not reasoning from source alone. `flutter test` was
  still blocked by the pre-existing, documented `flutter_gpu` engine
  mismatch (this stable channel build predates the `flutter_scene`-
  compatible master-channel snapshot prior prompts bootstrapped by hand);
  this does not affect the real build/CI environment, which already
  targets a Flutter version `flutter_scene` supports. None of this SDK
  bootstrapping is committed.

---

## Known gaps / verification required

- **C3 cannot be visually verified in this sandbox** (no GPU/display, and
  `flutter test` can't even load `flutter_scene`-dependent files here —
  see above). Manual verification steps for a real device/desktop build:
  1. Load any Part with a computed mesh (e.g. a simple Boss extrude) in
     `shadedWithEdges` render mode (the default).
  2. Orbit the camera so a face is nearly edge-on to the view (a glancing
     angle) — this is the previously-reported bleed-through case.
  3. Confirm the face's edges render as solid, stable lines with no
     flickering/bleed-through, both immediately after releasing the drag
     and while holding the view still.
  4. Repeat after a scroll-wheel zoom, a "Reset view", and a View-menu
     "look at plane" transition, to exercise each of the four resync call
     sites.
  5. As a regression check, confirm edges still look reasonable *during*
     an active drag (before release) — the bias is stale for those
     in-between frames (see "Known trade-off" above), so some residual
     flicker during the drag itself, settling once released, would be the
     expected (not ideal, but disclosed) behaviour; visible bleed-through
     that *doesn't* clear up on release would indicate the fix isn't
     working.
- **C1/C2's centroid+area nesting heuristic assumes non-self-intersecting,
  non-overlapping loops** (consistent with the rest of `profile.py`, which
  already assumes well-formed sketches for e.g. its branch/open-chain
  detection). A sketch with genuinely overlapping (not nested, not
  disjoint) loops is not specifically detected and may be misclassified;
  this was not in the prompt's scope and is a pre-existing class of
  assumption, not a new one.
- **Nested holes (a hole inside a hole) are deferred**, per the prompt's
  explicit scope, and rejected as `ProfileStatus.INVALID_NESTING` with a
  descriptive 400 rather than silently picking one interpretation.
