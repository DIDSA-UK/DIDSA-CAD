# DIDSA-CAD Roadmap — Open Work

This tracks outstanding, not-yet-resolved work only. For project history and
everything already shipped/fixed, see `docs/status.md`. For the original
project spec, see `docs/project-brief.md`.

---

## Other open items

- **"Hidden lines" view mode.** Mentioned by the user as a wanted future
  addition. Not implemented. Would need its own render-mode entry
  (alongside Shaded / Shaded+Edges / Wireframe) that renders occluded
  edges distinctly (e.g. dashed) rather than hiding them entirely. (No
  longer tied to any occlusion bug - the C3 edge/face-highlight
  occlusion bug this was once floated as a workaround for turned out to
  have a real fix; see `docs/status.md`'s "C3 residual edge/face-highlight
  occlusion bug: resolved" entry.)
- **26 pre-existing client test failures, found by the new CI workflow -
  all diagnosed and fixed, not yet re-verified by a real CI run.** (See
  `docs/status.md`'s "CI now shows the real state of this test suite" entry
  for the original discovery, and its two follow-up entries for the actual
  fixes.) None were connected to any change made in the session that stood
  up CI - almost all were the test suite itself never having been updated
  to match already-shipped product changes, plus a handful of genuine small
  app bugs found along the way:
  - 4 in `sketch_controller_test.dart`: `dragTargetPointIdAt` really could
    return the origin as a drag target for a Line/Circle whose *nearer*
    constituent Point happened to be the origin (a real app bug - fixed to
    always offer the *other* point instead); the other 3
    (`addEqualLengthConstraint`/`addCollinearConstraint`/
    `applyConstraintOption(collinear)`) were test-coordinate bugs - two taps
    landed close enough to a Line's own endpoint or midpoint to select/
    materialize a Point there instead of the Line itself.
  - 14 in `part_screen_test.dart` - all test-file staleness against B4
    rollback, Prompt A4's target-body banner, and Revolve/Sweep joining the
    long-press menu, plus one real (now fixed) bottom-sheet overflow bug in
    `feature_context_menu.dart`.
  - 3 in `orbit_camera_test.dart` - a real app bug (`_defaultDistance` was
    `80`, contradicting its own doc comment's worked math for `48`) plus a
    stale test expectation (`kDefaultFarClip` was intentionally bumped from
    1000 to 3000 in an earlier prompt, test never updated).
  - 1 each in `selection_list_drawer_test.dart` (test picked the wrong
    `Padding` - `SafeArea`'s own internal one, not the app's), `widget_test.dart`
    (tested a "Click" tool and flat speed-dial that no longer exist - the FAB
    menu is a two-level Categories/Sketch-Entities design now), and
    `part_viewport_test.dart` (test's own "spinner gone" wait was ambiguous
    with Scene-init failure in this CI sandbox's software renderer - now
    waits for the real `Listener`-bearing tree instead).
  - `sketch_canvas_ghost_editor_test.dart` used `pumpAndSettle()` against a
    widget with its own permanently-running edge-pan `Ticker` - same class
    of issue as `PartViewport`'s own spinner elsewhere in this codebase -
    switched to a bounded pump.
  - `feature_picker_sheet_test.dart` still expected Revolve/Sweep to render
    disabled - stale from before those features were fully wired up;
    replaced with tests confirming they resolve their own
    `FeaturePickerAction`.
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
