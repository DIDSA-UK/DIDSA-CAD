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
