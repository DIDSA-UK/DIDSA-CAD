# DIDSA-CAD Roadmap — Open Work

This tracks outstanding, not-yet-resolved work only. For project history and
everything already shipped/fixed, see `docs/status.md`. For the original
project spec, see `docs/project-brief.md`.

---

## Measure tool & MBD part-data compliance

- **Measure tool.** Not yet scoped in detail - needs its own design pass
  (what can be measured: distance, angle, radius, between which entity
  types, etc.).
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
- **Centre of gravity (CofG)** calculation for parts/assemblies.
- **Basic static stress analysis.**

## Sketcher tuning package

Notes from a scoping pass on sketcher UX. Grouped by theme; each is a
distinct, independently implementable item.

**Selection and drag interaction**
- **"Double-tap to drag" produces too many false positives** - e.g. user
  taps to select, then taps again to start dragging and move the cursor,
  and the sketcher misreads the second tap as part of a double-tap and
  keeps the entity in a drag state. Proposed fix: replace the gesture
  with an explicit FAB ("click and drag with cursor" mode), positioned
  bottom-left.
- **Dragging a point in a partially constrained sketch behaves
  undesirably during solving.** The point the user just dragged should
  stay where the user placed it if the solver can satisfy that; other,
  unconstrained entities should be the ones that move to accommodate it,
  not the dragged point itself.
- **Hit radius for points feels too large when selecting with the
  cursor**, causing too many false-positive point selections.
- **Point-on-point hit radius doesn't scale with zoom level** when
  placing a point during sketching. Hit radii should be made consistent
  throughout the app, including how (and whether) they scale with zoom.
- **Hover/highlight state disconnects from what actually gets selected**,
  seemingly specific to points - causing unintended selection of
  midpoints in particular.
- **Placing a point on an existing point should create a coincident
  constraint** between the two points automatically.

**Constraint feedback**
- **Need a visual system for over-constrained entities**: turn them red
  and disallow click-and-drag on their defining points.
- **Constrained lines/curves should turn dark green as they become fully
  constrained**, so the user can see at a glance which entities still
  need more constraining.

**3D context while sketching**
- **Existing bodies should be visible behind the sketch canvas** -
  default canvas transparency should favour opacity (~25% transparent,
  i.e. mostly opaque) rather than the current setting.
- **Orbit-view button** so the user can rotate the view to see the
  sketch plane in relation to existing bodies while sketching.
- **Return-to-default-view button** that animates back to the sketch's
  normal orientation.
- **Dimensioning from body edges/points should be allowed.** If a
  referenced edge/point is later lost (e.g. the feature it came from is
  deleted or changed), the sketch's icon in the feature tree should turn
  yellow to flag the dangling reference.
- **Sketch orientation control**: when starting a sketch, two buttons to
  flip (mirror) and rotate the sketch axes. A "sketch" label plus axis
  arrows, positioned near the bottom-left of the displayed plane, should
  indicate current orientation and move each time flip/rotate is
  pressed. When creating the sketch, a line or edge can optionally be
  selected as an aligning feature to set the sketch's Y-axis (a button
  on the sketch-canvas-definition step to manually pick a reference
  axis). A long-press on an existing sketch (in the tree or canvas)
  should allow the user to redefine its orientation retrospectively.

**Drawing tools**
- **Line tool should snap to horizontal/vertical** while profiling, and
  placing a snapped line should automatically add the corresponding
  horizontal/vertical constraint.
- **Additional shape/curve tools needed**: arc, ellipse, slot, polygon,
  spline, and text (with outline output, for both cutting and
  embossing).

**Overall feel**
- **Sketcher should feel like sketching on a canvas within the 3D
  environment**, with the sketch positioned/rendered relative to
  existing 3D geometry rather than as an isolated 2D view.

## Other open items

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
