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
- **A structural UX rethink is under consideration, not yet scoped or
  decided.** On-device use still finds the drag/move experience too slow
  and unpredictable for how central it is to sketching - see
  `docs/sketcher-architecture-ux-scoping.md` (2026-07-15), a standalone
  reference covering the full entity/constraint/solver architecture,
  every tool's exact client/backend round-trip cost, the drag system in
  full, and a menu of concrete options (client-side solving vs. backend-
  authoritative, scoped/partial re-solves, giving Slot a real backend
  entity, low-risk round-trip reductions) for a dedicated scoping
  session. Nothing in it has been decided or started yet.

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

## Other open items

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
