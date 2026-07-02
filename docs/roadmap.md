# DIDSA-CAD Roadmap — Open Work

This tracks outstanding, not-yet-resolved work only. For project history and
everything already shipped/fixed, see `docs/status.md`. For the original
project spec, see `docs/project-brief.md`.

---

## OPEN — C3 residual edge/face-highlight occlusion bug

**Symptom**: edges and highlighted/selected faces on the far side of solid
geometry render through it instead of being occluded, when they shouldn't
be — worse (more visible) the fewer occluding layers of geometry sit in
front of them. Precisely: "when the edges are behind 1 face they're
visible, behind 2 faces they're visible, behind 3 faces they're no longer
visible." Reproduced on a comb/serrated part and a disc-with-square-hole
part, viewed statically (not just mid-orbit).

**Ruled out** (see `docs/status.md`'s 2026-07-01/07-02 entries for the full
investigation):
- Render-graph/pass-structure — `flutter_scene` 0.18.1 builds exactly one
  `RenderTarget`/`SceneEncoder` per frame; traced directly in source.
- MSAA — forcing `AntiAliasingMode.none` in-app was a real, confirmed
  partial improvement (fixed the "gross" bleed-through) but did not fix the
  residual 1–2-face pattern. Android's system-level "Force 4x MSAA" toggle
  makes no difference either way.
- Edge depth-bias direction — confirmed correct (towards camera, not away
  from mesh center).
- Edge depth-bias magnitude — tested across a 40x range (0.05 to a
  deliberately extreme 2.0 diagnostic value) with **zero** change to the
  qualitative pattern. This rules out a depth-precision/z-fighting
  explanation.
- Alpha-mode/depth-write configuration on edges — `buildMeshEdgesNode`
  switched from `AlphaMode.opaque` (depth-writes) to `AlphaMode.blend`
  (depth-tests only) — a real, confirmed fix for a related-but-separate
  depth-corruption bug, but did not resolve this residual pattern either.

**Current leading theory**: a GPU hardware/driver behavior below the level
`flutter_gpu`'s public API exposes — specifically Adreno GPUs'
hierarchical/low-resolution early-Z rejection hardware ("LRZ"), which has a
documented history on Qualcomm hardware of exactly this failure signature:
a single occluding depth write failing to properly populate/be respected by
the coarse Z structure, while several occluding writes converge to the
correct (occluded) result. Test device: Samsung Galaxy S23 Ultra (SM-S918B,
Adreno 740). There is no public API in `flutter_gpu`/`flutter_scene` 0.18.1
to disable or influence this hardware path.

**Next-step options**:
- (a) Test on non-Adreno hardware (e.g. a Mali or Apple-GPU device) to
  confirm or rule out hardware-specificity — if the bug disappears on
  different silicon, that strongly confirms the LRZ theory.
- (b) File a minimal repro upstream against `flutter/flutter` or
  `bdero/flutter_scene` — this needs a live GPU to build a reduced repro
  project, not achievable in the current sandbox.
- (c) Try a cheap double-draw/extra-depth-write experiment on the off
  chance it works around the hardware behavior (e.g. drawing opaque
  geometry twice, or writing a conservative depth pre-pass) — low
  confidence, cheap to try given the mechanism is still not fully
  understood.
- (d) Accept as a known hardware/driver limitation and pursue the
  previously-deferred "hidden lines" view mode (see below) as a
  product-level workaround — dashed/differently-styled hidden-edge
  rendering sidesteps the occlusion problem rather than solving it.

Current shipped state (deliberately left as-is, not reverted): `kEdgeDepthBias = 0.05`
(`client/lib/viewport3d/mesh_geometry.dart`) and
`Scene()..antiAliasingMode = AntiAliasingMode.none`
(`client/lib/viewport3d/part_viewport.dart`'s `initState`) — both are net
improvements over earlier states even though neither fixes this residual
bug; reverting either would only reintroduce previously-fixed regressions.

---

## Other open items

- **"Hidden lines" view mode.** Mentioned by the user as a wanted future
  addition, and now also a candidate product-level workaround for the C3
  bug above (option (d)). Not implemented. Would need its own render-mode
  entry (alongside Shaded / Shaded+Edges / Wireframe) that renders
  occluded edges distinctly (e.g. dashed) rather than hiding or bleeding
  them through.
- **Chamfer, Fillet, Create Plane context actions.** Scaffolded end-to-end
  (selection composition rules, disabled buttons with per-action
  `// TODO: wire up <action>` comments) since the 3D-viewport
  selection-mode work, but never implemented. Needs actual OCCT operations
  behind each action.
- **Revolve, Sweep.** Disabled placeholders in the Feature picker sheet
  since Stage 19b. Not implemented.
- **No redo in the sketcher.** Undo (Stage 19b) is a command/inverse-action
  stack with an explicit `// TODO: redo` left in `sketch_controller.dart`.
- **Sketcher constraint options still unwired for creation beyond what
  exists today**: confirm there's no remaining gap — as of Stage 16,
  Coincident/Parallel/Perpendicular/EqualLength/Collinear are wired; check
  `sketch_controller.dart`'s `availableConstraintOptions` before assuming
  anything further is missing (this list has shrunk stage over stage; only
  verify if picking this up).
- **Kotlin Gradle Plugin / Java 8 deprecation warnings in the Android
  build.** Noted in passing during client bootstrap sessions as low-priority
  cleanup; not tracked with a specific fix plan. Worth a pass when next
  touching the Android build config, not urgent.
- **No Flutter CI job.** `.github/workflows/backend-verify.yml` only builds/
  tests the Python backend; there is still no automated `flutter analyze`/
  `flutter test` run in CI. Every client-side change in this project's
  history has been verified either manually, via a hand-bootstrapped SDK in
  a sandbox session, or by the user on a real device — never by an
  automated gate. Setting one up (pinned to a `flutter_scene`-compatible
  Flutter version) would have caught several of the regressions documented
  in `docs/status.md` earlier.
- **Pre-existing, unrelated test failures flagged but not fixed** across
  several status entries (e.g. `addCollinearConstraint`/
  `addEqualLengthConstraint`/`applyConstraintOption(collinear)` not
  clearing the selection set in one specific test scenario, and
  `dragTargetPointIdAt` offering the origin as a drag target in
  `sketch_controller_test.dart`) — flagged in Prompt B's status doc as
  newly *visible* (not newly introduced) once a missing import let that
  test file load for the first time in a sandbox. Still open as of the
  last time it was checked.
