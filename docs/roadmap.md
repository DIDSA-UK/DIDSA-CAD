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
- **Pre-existing, unrelated test failures flagged but not fixed** across
  several status entries (e.g. `addCollinearConstraint`/
  `addEqualLengthConstraint`/`applyConstraintOption(collinear)` not
  clearing the selection set in one specific test scenario, and
  `dragTargetPointIdAt` offering the origin as a drag target in
  `sketch_controller_test.dart`) — flagged in Prompt B's status doc as
  newly *visible* (not newly introduced) once a missing import let that
  test file load for the first time in a sandbox. Still open as of the
  last time it was checked.
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
- **Larger Blender-exported `.glb` still crashes** - reported twice now
  (after the round-1 node-transform fix, and again after round 2's
  recursive-walk rewrite), with no new diagnostic information either time
  ("still crashes" with no visible in-app error). Crash-to-home-screen with
  no catchable Dart exception usually means a native-level fault (OOM kill,
  GPU/driver crash) rather than something this codebase's own error
  handling would ever see - needs an actual crash log (e.g. `adb logcat`
  output captured around the crash) to make any further progress; guessing
  again without one risks repeating the last two rounds' pattern.
- **The actual "mirrored"/orientation issue on a complex glTF - still not
  found.** Ruled out so far, with real evidence: decimation (only ever
  drops whole triangles, never touches a kept one's own data), node
  transforms (the actual file's root node has no translation/rotation/scale
  at all - confirmed from its own scene-graph JSON dump, so both rounds of
  node-transform work were correctly a no-op here), and this decoder's
  quaternion/matrix composition math (independently re-derived, matches).
  A *different*, now-confirmed-and-fixed bug (39 materials/primitives all
  rendered with material 0's texture - see `docs/status.md`'s "Real
  diagnosis: 39 materials/primitives" entry) explained "patchy and wrong"
  textures, but not the geometry orientation itself, which the user
  separately confirmed is real: "everything went down into the ground
  instead of up into the sky (although the model is actually on its
  side)". No axis-swap/handedness-conversion code exists anywhere in this
  decoder or the app's rendering pipeline - and this app's own camera
  (`orbit_camera.dart`) and documented backend convention (`sketch/
  view_transform.dart`) both already treat Y as up, matching glTF's own
  spec exactly - so a simple up-axis mismatch doesn't obviously explain it
  either. Sent the user a script to pull each POSITION accessor's own
  spec-mandated bounding box (min/max, no vertex bytes needed) to find the
  file's true "up" axis directly (smallest range) rather than guess a
  fourth time. Not yet resolved.
