# DIDSA-CAD Roadmap — Open Work

This tracks outstanding, not-yet-resolved work only. For project history and
everything already shipped/fixed, see `docs/status.md`. For the original
project spec, see `docs/project-brief.md`.

---

## Analysis tools

- **Measure tool.** Not yet scoped in detail - needs its own design pass
  (what can be measured: distance, angle, radius, between which entity
  types, etc.).
- **Sectioning tool.** Not yet scoped in detail - needs its own design
  pass (single vs. multiple section planes, planar vs. offset/stepped
  sections, a live/interactive cutaway vs. a static section view, and
  whether it also supports measuring/dimensioning the cut face).
- **Centre of gravity (CofG)** calculation for parts/assemblies.
- **Basic static stress analysis.**

## MBD part-data compliance

- **Part data to support MBD (model-based definition) and comply with the
  project's STEP MBD policy.** Fields needed on a part: material, part
  number, description, supplier, supplier part number, mass (with a
  checkbox to override the calculated-from-volume value when the user
  wants to enter a known mass instead), volume (calculated), surface area
  (calculated), and pattern features/bodies (so patterned instances carry
  the same part data as their source).
- **Hole tool** covering common standards and sizes: screw clearance
  holes, tap drills, and common drill sizes - selectable from a standard
  table rather than typed in as a raw diameter.
- **Material database** so a part's material can be populated easily from
  a picklist, with dependent metrics cascading automatically from the
  chosen material: density, stress data, colour, texture, etc.

## Sketcher tuning package

Notes from an original scoping pass on sketcher UX (selection/drag
interaction, constraint feedback, 3D context while sketching, drawing
tools, overall feel) - engineering breakdown in
`docs/sketcher-overhaul-scope.md` Phases 1-6, narrative history in
`docs/status.md`. Essentially all of it has shipped, including the
package's last deferred item (Polygon vertex-drag reinterpreted as a
circumradius-dimension edit, the on-device-feedback fixes that
followed it, a further round removing the broken 3D backdrop, adding
New Sketch on Face, and reworking the sketch-start camera sequence,
and Phase 11's trim/extend tool - see `docs/status.md`'s 2026-07-14
entries) - with one real gap confirmed by a direct code audit:

- **Phase 5's reference-axis alignment was never built.** Picking a
  line/edge as an aligning feature to set a new sketch's Y-axis (the
  "when creating the sketch, a line or edge can optionally be selected
  as an aligning feature" ask) has no implementation anywhere - only
  the discrete flip/90°-rotate half of Phase 5 ever shipped. Not
  scoped in detail yet.
- **The structural UX rethink was decided and is mostly shipped** -
  `docs/sketcher-restructure-plan.md` (2026-07-16) adopted an in-process
  FFI SolveSpace solver (`client/lib/sketch/local_solver/`) over the
  client-side-reimplementation idea `docs/sketcher-architecture-ux-scoping.md`
  (2026-07-15) had considered and rejected. `updatePointDrag`'s mid-drag
  reflow already tries it before falling back to the network path;
  `updateLineDrag` got the same treatment in `docs/status.md`'s 2026-07-21
  session. **Open sub-item found along the way**: a Horizontal/Vertical
  Constraint between two simultaneously-anchored Points, combined with any
  other Constraint reaching from one of them to a free Point, can make the
  native solver silently move an "anchored" Point - worked around with a
  drift-detection fallback (see that entry), but not yet root-caused at the
  FFI/SLVS level. **Correction to an earlier version of this entry**: Phase 2
  (plane-embedded 3D sketching/Orbit View) is *not* still unstarted - direct
  verification found it already shipped and essentially complete (nearly
  every draw tool, Dimensions, Trim/Extend, and drag mode all already work
  embedded in the 3D viewport; only the Text tool is deliberately excluded) -
  see `docs/status.md`'s 2026-07-17 P1-P10+ entries, which an earlier
  research pass in this same session missed. Phase 3 (Slot's real backend
  entity) shipped in the 2026-07-22 session below - Phase 4 (scoped/partial
  re-solve) is still genuinely not started.
- **Drag/solve rebuilt on closed-form geometry for Polygon/Slot** (2026-07-22
  session, see `docs/status.md`) - the redundant-constraint-chain approach
  above (Phase 1's FFI solver) is no longer how these two shapes drag at
  all; a formula has exactly one answer, so it eliminates the wrong-root
  class of bug for them entirely rather than reactively guarding against
  it. Real follow-ups from that pass, not silently dropped:
  - **Bisection/sub-step retry** for the *general* solver path (arbitrary
    hand-built constraint combinations, and a Polygon/Slot's own remnants
    once trimmed) - when a direct local solve fails a guard, retry via
    halving sub-steps between the last known-good position and the target
    instead of falling straight through to the throttled network path.
  - **Port `solver.py`'s `_fix_circle_cardinal_point_signs`** (detect a
    discrete mirror-flip root, correct it with a direct reflection through
    the known-good axis instead of rejecting outright) to the client's
    local solver, where it's confirmed not yet present - and extend the
    same detect-then-reflect shape to the general path's own Arc chord-side
    branch-flip guard, so a caught flip self-heals instead of just
    stalling.
  - **Ghost-preview drag** (decouple live rendering from the authoritative
    solve - a cheap kinematic preview every frame, one real solve at drop)
    for the general path specifically. No longer needed for Polygon/Slot
    (the closed-form path already removes the "wrong root flashing
    mid-drag" risk for those), so this is now polish, not a live-bug fix.
  - **Slot's own delete-cascade-with-undo** (multi-select delete cleanly
    removing a whole intact Slot, not leaving a dangling backend entity if
    only its Lines/Arcs happened to be in the selection) - `Polygon` needed
    this exact same follow-up fix after its own entity first landed
    ("select all > delete doesn't work on polygons, says constraint not
    found" - see `docs/status.md`); Slot hasn't gotten the equivalent pass
    yet.
  - **A Slot's arc-apex construction Points (2026-07-22 follow-up, see
    `docs/status.md`) don't auto-update on drag/resize** - deliberately
    unconstrained (no existing solver primitive expresses "stays
    diametrically opposite this Arc's own chord"), so once materialized
    they go stale if the Slot is later dragged/resized, unlike the
    centreline midpoint (which stays live via a real `AtMidpointConstraint`).
    Acceptable for v1 (a reference point the user places when needed, not
    something dragged independently), but worth a real fix - most likely by
    teaching the closed-form drag rebuild's own `_closedFormSlotGeometry` to
    also re-sync any materialized apex Points it finds, the same way it
    already re-syncs a/b/c/d.
  - **Residual-based redundancy verification** (`_residual_verified_
    convergence`/`_residualVerifiedConvergence`, 2026-07-22) only covers
    Distance/EqualLength/EqualRadius/Angle/Tangent/LineDistanceConstraint -
    a closed allowlist, deliberately (falls through to ordinary failure
    reporting rather than guess for any other type present). If a future
    on-device report surfaces the same "doubly-redundant but consistent"
    symptom involving a Parallel/Perpendicular/Coincident/Collinear/
    PointLineDistance/SplineTangent Constraint, that's the function to
    extend, following the exact same per-type residual-formula pattern.
- **Sketch dimension rendering/hit-testing has two independent
  implementations** (`sketch_canvas.dart` for the flat 2D canvas,
  `sketch_constraint_overlay.dart` for the 3D-embedded sketcher) that can
  drift out of sync - confirmed happened once already (the 2026-07-21
  dimension-overhaul session only fixed the 2D canvas; the 3D-embedded one,
  which is what `SketcherPreferences.defaultUse3DSketcher = true` actually
  shows by default, had the same bugs independently, plus one of its own -
  ported in the same day's follow-up session, see `docs/status.md`). Worth
  a future pass to unify the two into one shared implementation rather than
  two hand-kept-in-sync copies, if a third such divergence shows up.

## Standalone "2D Drawing" tool follow-ups

Thin v1 shipped 2026-07-21 (see `docs/status.md`): a bare, Part-free
`SketchScreen` reachable from a new `ToolChooserScreen` (between Connect and
the app's actual tools), with local file Save/Open via two new backend
endpoints (`GET`/`POST /sketch/sketches/{id}/export`, `.../import`, reusing
the Part-level native format's own `sketch_to_dict`/`sketch_from_dict`).
Deliberately deferred, not yet scoped in detail:

- **DXF export.** Genuinely greenfield - no `ezdxf` dependency yet, no
  existing DXF import to mirror either (contrary to what
  `docs/sketcher-overhaul-scope.md` Phase 8 implied was already scoped -
  confirmed zero implementation exists). Realistic path: a Python `ezdxf`
  writer directly against the Sketch model's own Points/Lines/Arcs/Circles/
  Ellipses/Splines/Text. DWG is a dead end (proprietary format, no viable
  open-source parser) - DXF-only.
- **A "my drawings" list/browse feature.** No multi-document concept exists
  anywhere in the backend today (not even for Parts) - the current
  file-based Save/Open sidesteps needing one entirely. Would need either a
  real multi-document backend store or a client-side recent-files list at
  minimum.
- **Drafting fundamentals**: no units/scale, no layers, no sheets/paper
  size, no annotation beyond the existing Text entity - all absent, all
  real scope for a genuine floor-plan/drafting tool, not yet designed.

## Convert Entities / Offset Entities follow-ups

Both tools shipped (Convert Entities v1→v2, Offset Entities v1→v2 with
chain-aware corner-joining, curved-edge-to-Arc conversion - full history in
`docs/status.md`'s 2026-07-18 through 2026-07-21 entries). Known gaps left
deliberately unbuilt along the way, not yet scoped further:

- **A full circular Body edge (a real closed loop - both topological
  endpoints the same Body vertex) still 422s as `degenerate_edge`** before
  ever reaching curve-type detection, for both Convert Entities and Offset's
  body-edge picking. Real Circle extraction (as opposed to the now-shipped
  open-Arc case) is a separate, not-yet-built follow-up.
- **A converted circular edge's Arc centre Point is non-associative**
  (a plain `add_point`, not an external vertex reference) - unlike its
  start/end Points, it won't itself track a later change to the Body's
  shape. No existing mechanism pins a circular edge's own centre the way a
  vertex reference pins a corner; would need new backend design, not
  attempted.
- **Dragging a Convert-Entities-created (associative) Point visually works
  but snaps back on the next solve** - `dragTargetPointIdAt` has no
  exclusion for external-reference Points, the same inherited limitation
  every other pinned reference already has. Not fixed, not newly introduced.

## Reference drift / "potentially broken reference" health flag

User brainstorm (2026-07-31, prompted by the same day's three related bug
fixes - see `docs/status.md`'s "Bug fix: face-anchored Plane and Sketch
external references drifting..." and "Bug fix: Pattern/Mirror
`tool_feature_id` mode re-deriving an upstream Cut's tool shape..."
entries): those bugs were a *fixable* implementation defect (resolving a
`SubShapeRef` against the wrong point in the Part's own history), but the
underlying vulnerability they exposed is not fully closed by that fix - a
raw OCCT face/edge/vertex index (`topexp.MapShapes`'s own enumeration
order over one specific shape - see `SubShapeRef`'s own docstring) is
*never* a guaranteed-stable identity across a genuinely restructured Body
(a later fillet merging two faces, a cut consuming one entirely). This is
the industry-wide, still-not-fully-solved "Topological Naming Problem"
every history-based CAD kernel (Parasolid, ACIS, OCCT here) has some
version of - not unique brittleness in this project. Today, that
remaining case is handled by failing closed (a structured
`missing_reference` 422, or `has_lost_reference` for Sketch external
references) when resolution genuinely can't find a match at all. The gap:
nothing catches the case where resolution *succeeds* but against a
different face/edge than intended - exactly what happened here (a Plane's
`face_ref` silently landing on a side face instead of the top face it was
created against).

**The idea, not yet designed in detail**: alongside a `SubShapeRef` (or
`PatternDirectionRef`/`PatternAxisRef`/a Mirror's `mirror_plane`), store a
lightweight geometric signature captured when the reference was created
(or last confirmed healthy) - a face's centroid + normal, an edge's
midpoint + direction, a vertex's position. On every later resolution,
compare the newly-resolved shape's own signature against the stored one.
Small drift (the body legitimately grew/shrank a bit, the referenced
face moved slightly) is expected and fine; a normal that flipped
90°+, or a centroid that jumped to a different corner of the body
entirely, is exactly the "resolved successfully but wrong" failure this
session hit twice. Past some threshold, don't silently trust the new
value the way `refresh_external_references` currently does (it persists
whatever it resolves to, on every read) - flag the feature instead
("potentially broken reference"), the same way `has_lost_reference`
already flags a Sketch whose external reference can't resolve at all, but
generalized to every reference kind that can silently drift rather than
only the one that currently fails closed. Critically (the user's own
framing): don't auto-correct the feature's behavior based on the drifted
value - surface the flag and let the user decide, rather than the system
silently accepting a value that might be wrong.

The user's own rough starting language for thresholds - "normal changed by
more than ___", "sketch vertical changed by more than ___" - is a
reasonable first cut at the two most obviously-affected reference kinds
(a face-anchored Plane's own normal; a Sketch's in-plane orientation via
its anchor Plane's x/y axes) and is roughly the design direction to start
from, not yet worked out as real numbers/formulas.

**Precedent** (general industry concepts, not verified against any
specific vendor's documented internals - worth a real research pass before
or during implementation if matching prior art precisely matters, per the
user's own "align with NX or something" ask): the general "diff the
before/after state and require confirmation on a large change" pattern is
well-established outside CAD too (`terraform plan` refusing to silently
apply a change that would destroy more resources than expected; migration
tools that abort rather than silently touch an unexpectedly large row
count). Within CAD specifically, mature kernels/wrappers are understood to
mitigate the Topological Naming Problem partly via geometry-based
re-identification ("shape matching" / "sticky IDs") layered on top of raw
topological indices, rather than trusting a bare enumeration index alone -
OCCT itself exposes `BRepAlgoAPI_BooleanOperation::Modified()`/
`Generated()`/`IsDeleted()` for a boolean operation to report what became
of a given input face/edge directly, which this codebase does not
currently use anywhere (every resolver here re-derives identity purely by
re-enumerating a shape after the fact). A geometric-signature health check
is a heuristic safety net *on top of* the current approach, not a
replacement for wiring in that boolean-native tracking, which would be the
more thorough (and more involved) fix for the same underlying class of
problem.

**Open questions, not yet resolved:**
- Threshold values, and whether they should be absolute (a fixed angle/
  distance) or relative (e.g. a percentage of the Body's own bounding-box
  diagonal, so the same check behaves sensibly on a 10mm bracket and a
  10m assembly).
- Which reference kinds get this first - `CreatePlaneFeature.face_refs`
  and `PatternDirectionRef.edge_ref`/`PatternAxisRef` are the two directly
  implicated by this session's own bugs; `Sketch.external_references`
  already has a (weaker, resolve-or-fail-only) version of this via
  `has_lost_reference`, so may just need widening rather than a new
  mechanism; `tool_feature_id` itself is a Feature-id reference, not a
  raw topology index, so may not need a signature scheme at all.
- Whether a flagged feature still renders its best-effort (possibly wrong)
  resolved geometry, or freezes at its last known-good state until the
  flag is addressed.
- Whether/how a flag is dismissed once reviewed - does the user
  acknowledge "yes, this drift is intentional, stop flagging it" (updating
  the stored signature to the new value), or does it just clear itself
  once the signature re-stabilizes?
- Where the comparison logic would live - most likely a new sibling to
  `resolve_subshape_from_bodies` (`app.document.extrude`), called from the
  same handful of `_feature_response` branches `excluded_feature_ids_after`
  already touches, plus `pattern.py`/`mirror.py`'s own tool_feature_id
  resolvers.

Not scoped enough to estimate effort or start implementation - written up
here to capture the idea and the concrete bug reports that motivated it
before they're forgotten, per the user's own explicit "let's scope the
roadmap entry" ask.

## Other open items

- **A sketch's origin point reportedly doesn't line up with the correct 3D
  viewport origin.** User report (2026-07-21), investigated the same day -
  every basis-resolution path audited (backend `basis_for_sketch`, client
  `SketchPlaneBasis`, "New Sketch on Face") reads internally consistent, no
  bug found via static reading. The design question this was paired with
  has an answer: the origin is already a real, pinned backend Point, not a
  good candidate for the Convert-Entities-style external-reference
  mechanism (the world origin isn't a Body vertex to reference against).
  Needs an on-device repro to make further progress - does it happen on a
  fixed-plane Sketch, a custom-plane one, or specifically "New Sketch on
  Face"? Immediately on entry, or only after orbiting the camera?
- **Cast option for the main CAD viewport and the 3D mesh viewer.** User
  ask (2026-07-18): a proper in-app Cast button (matching YouTube/Netflix-
  style casting), not just Android's built-in screen-mirror toggle - lets
  a Chromecast/Cast-enabled TV show the 3D view directly. This needs
  Google's Cast Application Framework: a Custom Receiver (an HTML/JS page
  using the CAF Receiver SDK - effectively a second WebGL renderer for the
  mesh, since a live interactive 3D view can't just be a video stream)
  registered under a Google Cast SDK Developer Console account (one-time
  $5 fee), hosted at a public HTTPS URL, plus a sender-side integration in
  the Flutter app (no official Flutter plugin - would need a platform
  channel wrapping Android's native Cast SDK). Real scope, not a small
  addition. Not started - open questions before any implementation: does
  the user want to set up (or already have) a Google Cast developer
  account, and where would the receiver page be hosted (their own Pi, or
  a static host like GitHub Pages)? A sensible v1/v2 split once scoped:
  v1 a simpler static/turntable render or periodic snapshot pushed to the
  receiver, v2 a fully live orbit-synced remote render.
- **"Hidden lines" view mode.** Mentioned by the user as a wanted future
  addition. Not implemented. Would need its own render-mode entry
  (alongside Shaded / Shaded+Edges / Wireframe) that renders occluded
  edges distinctly (e.g. dashed) rather than hiding them entirely. (No
  longer tied to any occlusion bug - the C3 edge/face-highlight
  occlusion bug this was once floated as a workaround for turned out to
  have a real fix; see `docs/status.md`'s "C3 residual edge/face-highlight
  occlusion bug: resolved" entry.)
- **CI is green: 534/535 client tests passing, confirmed by real CI runs
  (not assumed).** All 26 pre-existing failures the new CI workflow first
  surfaced (see `docs/status.md`'s "CI now shows the real state of this
  test suite" entry and its many follow-up entries) are resolved - almost
  all were the test suite itself never having been updated to match
  already-shipped product changes, plus a handful of genuine small app bugs
  (`OrbitCamera._defaultDistance` contradicting its own doc comment's math;
  `dragTargetPointIdAt` able to return the sketch origin as a drag target;
  a `feature_context_menu.dart` bottom-sheet overflow) found and fixed along
  the way. Getting to green took nine CI round-trips, several of which
  caught mistakes in this session's *own* fixes (an unscoped `Listener`
  finder, a `find.byTooltip` position mismatch, a Hero-flight duplicate FAB)
  rather than declaring victory on the first apparent fix - see
  `docs/status.md`'s dated entries for the full history.
  - **One remaining failure, confirmed as CI-sandbox environment flakiness,
    not a code bug**: `part_viewport_test.dart`'s "Fix 4: tapping the
    viewport in selection mode over empty space" test intermittently hits
    this CI runner's lack of real Impeller/GPU support (`Flutter GPU
    requires the Impeller rendering backend, but Impeller is not enabled`)
    for that specific widget configuration - reproduced identically across
    multiple runs, with a sibling test in the same file only passing
    reliably because its own assertions happen to hold whether Scene setup
    succeeds or not. Not fixable from test-file changes; flagged rather
    than chased further.
  - Everything learned along the way about writing/fixing Flutter widget
    tests correctly (not just this project's specific bugs) is written up
    as a standalone reference in `docs/flutter-widget-test-lessons.md`.
- **Draco-compressed glTF/GLB support (`KHR_draco_mesh_compression`) - not
  implemented.** A real ODM/OpenDroneMap `.glb` export uses it; the mesh
  viewer currently detects it up front and fails with a clear, specific
  error rather than crashing (see `docs/status.md`'s "Same ODM file, real
  root cause found: Draco mesh compression" entry) - it does not actually
  decode the compressed geometry. Real Draco decoding needs an
  entropy/range decoder plus edgebreaker-style connectivity
  reconstruction - a genuine binary-codec implementation, not a small
  addition - and there's no ready-made pure-Dart package to lean on; a
  native/FFI Draco library would be a materially bigger dependency change
  (platform-specific binaries). Whether to pursue this, versus relying on
  re-exporting without mesh compression (available in most pipelines that
  use it, including ODM's), is an open question for the user - not decided.
- **glTF node transforms: full scene-graph walk now implemented, but
  `matrix`-based nodes are still rejected rather than decomposed.** The
  original fix only inspected root scene nodes, which turned out to be
  wrong for a real Blender export (the transform-bearing ancestor is often
  several levels above the actual mesh node) - now fixed via a full
  recursive walk composing every ancestor's transform (see
  `docs/status.md`'s "glTF node transforms, round 2" entry). The remaining
  gap: a node anywhere in the hierarchy using a raw `matrix` instead of
  separate translation/rotation/scale fields is rejected with a clear
  error rather than decomposed (correctly handling non-uniform
  scale/reflection when decomposing an arbitrary matrix is real
  complexity, not attempted here). Not decided whether it's worth building
  without a real file that needs it.
- **Larger Blender-exported `.glb` crash - root cause confirmed and fixed,
  not yet re-tested on-device.** A real `adb logcat` capture (see
  `docs/status.md`'s "The real, confirmed cause of the crash" entry) showed
  a genuine `java.lang.OutOfMemoryError` inside `file_picker`'s own
  `MethodChannel` encoding of the picked file's bytes (`withData: true`
  reads the whole file into a Java byte array and re-encodes it through a
  `StandardMessageCodec` envelope, needing roughly double the file's size on
  Android's small default Java heap) - not a texture or decode issue at
  all, and not a native/GPU fault either. Fixed by reading the file via its
  own path (`dart:io`) instead of requesting `PlatformFile.bytes`, so the
  platform channel never carries the file's actual content. Needs the user
  to confirm the same larger file now loads without crashing.
- **Mesh viewer Up-axis toggle only handles a Y/Z mismatch, not an
  arbitrary one.** Resolved for the real case that motivated it - a
  Blender export that skipped its "+Y Up" conversion, leaving the file's
  real "up" in Z instead of the glTF-spec-mandated Y (see `docs/status.md`'s
  "Root cause found: the file's own data isn't Y-up" entry) - via a new
  manual `MeshUpAxis` (`y`/`z`) View-menu toggle, since there's no reliable
  way to auto-detect this from the file alone. Not handled: a file with a
  totally different/arbitrary axis convention (e.g. X-up, or a non-90-degree
  misalignment) would need a more general fix than a simple Y/Z choice -
  not attempted, since no real file needing it has come up yet.
- **Mesh viewer decimation triangle-budget and default Up-axis settings are
  global, not per-device-profile.** `MeshViewerPreferences` (new this
  session) is a single flat set of values, not a saved list of profiles a
  user could switch between (e.g. "this phone" vs "that tablet") - fine for
  a single device, would need real design work to extend to multiple.
  Not requested, not attempted.
- **Silent re-save on Android.** On-device feedback: after PR #110's Save
  fix (`_canPersistFilePathForReuse` - see `part_screen.dart`), Android
  still prompts for a location/filename on every save, even a re-save of
  an already-saved Part - by design, not a bug: `file_picker`'s Android
  `saveFile()` only ever hands back a fabricated `Downloads`-guessed path,
  never a real, `dart:io`-writable one, so there is currently no way to
  silently reuse a prior save location there (desktop already does, since
  its path *is* real). Closing this gap for real would need a native
  Android Storage Access Framework integration - persisting a writable
  `ACTION_CREATE_DOCUMENT` URI's permission grant across app sessions (via
  `ContentResolver.takePersistableUriPermission`) and writing through that
  URI on subsequent saves via a platform channel - not something
  `file_picker`'s existing Flutter API exposes. Real scope (new platform
  channel/native Kotlin code, not a `file_picker` config tweak), not yet
  designed or attempted.
- **Investigate unifying sketch-level Pattern/Mirror's three duplicate
  translate/reflect implementations.** Phase 7 (`docs/pattern-mirror-scope.md`)
  and its on-device-feedback follow-up rounds (see `docs/status.md`'s
  2026-07-30 entries) ended up with the identical 2D pattern/mirror
  expansion math implemented three separate times: the backend
  (`Sketch.expand_pattern_and_mirror_instances`, `app/sketch/models.py`),
  the 2D sketch canvas's own client-side mirror
  (`pattern_mirror_expansion.dart`'s `expandPatternAndMirrorInstances`,
  consumed by `SketchController`), and - added for the embedded-3D (Orbit
  View) sketch editor's own hit-testing - a third,
  `hitTestSketchPatternMirrorInstances`/`_embeddedPatternMirrorGhostSegments`
  path in `selection_hit_test.dart`/`sketch_screen.dart`. Each was a
  deliberate, individually-justified instance of this codebase's existing
  "accepted duplication" convention for live-preview math (matching how
  `offsetPreviewGhosts` already duplicates real Offset logic client-side) -
  not an oversight, but three copies of the same translate/reflect/welding
  rules is more than that convention originally anticipated, and nothing
  enforces they stay in sync if the math changes again. Worth a dedicated
  investigation later (not attempted now): whether the two *client-side*
  copies (2D canvas + embedded-3D) could share one Dart implementation
  behind a thin per-consumer adapter, and whether that's worth the
  refactor risk against a working, well-tested feature - the backend copy
  almost certainly stays separate regardless (different language, and the
  one authoritative source of truth `detect_profile`/wire-building must
  use).
