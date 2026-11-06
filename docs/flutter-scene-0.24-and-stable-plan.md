# flutter_scene 0.18.1 to 0.24.3, and Flutter stable: plan

Source: the owner asked for the `flutter_scene` upgrade after the Android toolchain upgrade (PR #334, `docs/android-toolchain-upgrade-plan.md`).
This doc is for the implementation session. Researched on 2026-11-06 against `main` at `612c2fb`.
Line numbers drift, so search for the named symbol if a line is off. Paths are under `client/` unless they say otherwise.

## What this gets us

- **Off Flutter's master channel.** `flutter_scene` 0.24.3 requires Flutter >= 3.47.0 and says 3.47.0 is "the first stable carrying the Flutter GPU support this package needs". Master is why CI has to be pinned to a commit, why new deprecations land without warning (the 237 `material.dart` imports), and why local set-up is fragile. Stable 3.47.9 (2026-10-29, Dart 3.13.7) is the target.
- **Faster 3D on phones.** 0.24.0: "Opaque materials no longer `discard`, so mobile GPUs keep early depth testing and hidden-surface removal on for every opaque draw (frames 2.5 to 6x faster on a Mali-G57)". This is automatic; nothing in the app has to opt in. The gain is largest on Mali GPUs (most Samsung A-series and many mid-range phones) and smaller elsewhere.
- Six versions of fixes (GPU pacing so a GPU-bound scene does not block the UI thread, a GLES depth-test fix, NaN and bloom fixes) and features we can use later (see "Later").

## What was checked before writing this (2026-11-06)

All in a scratch copy, never in the repo. Flutter 3.47.9 stable was installed from the official archive (SHA-256 checked).

| Check | Result |
|---|---|
| `main` as is (`flutter_scene` 0.18.1) on 3.47.9: `flutter analyze` | No issues found |
| Same, full `flutter test` from a full repo copy | All pass (the GPU tests skip, as on CI) |
| `flutter_scene` 0.24.3 on 3.47.9: `flutter pub upgrade flutter_scene` | Resolves; adds `scene` 0.4.1 and `yaml_edit` 2.2.4 |
| 0.24.3: `flutter analyze` | **12 errors**, every one listed in Phase 2 step 2. After those fixes: no issues |
| 0.24.3: full `flutter test` | 4 failures, all one cause (Phase 2 step 4). With a minimal fix for it (log the error): 3581 passed, 47 skipped, the same counts as `main` today. That run had steps 2 and 4 only, not steps 3, 5 and 6 (which change expected values on purpose) |
| Stable 3.47.9's Gradle plugin against our Android set-up (read in its source) | Gradle 9.5.0 + AGP 9.3.1 are above its newest known versions and "treated as valid"; no "soon dropped" warning (its warn floors are 9.1.0 / 9.0.1 / 2.3.20); built-in Kotlin is supported. **Not built**: no Android SDK in that session. CI is the check |

Not checked anywhere: anything rendered. Tests here have no GPU (`Flutter GPU requires the Impeller rendering backend`), so every rendering change below is reasoned from `flutter_scene`'s source and changelog and must be checked on a device.

## Earlier decisions this upgrade must not undo

Checked against 0.24.3's source on 2026-11-06.

- **The mirror fix (2026-07-22 in `docs/status.md`).** `flutter_scene`'s private `_matrix4LookAt` builds `right = up.cross(forward)`, a mirror. It is **unchanged in 0.24.3**. The app renders only through its own `FixedPerspectiveCamera` and `OrthographicCamera` (`orthographic_camera.dart`, both on `correctedLookAt`). 0.24's `ViewportBoundCamera` wrapper and `rasterViewTransformOf` call the app's `getViewMatrix()`, and `_matrix4Perspective` is identical for unjittered, non-reversed use, so the fix still holds. **Never** use flutter_scene's `PerspectiveCamera`, `OrthographicCamera`, `OrbitCameraController`, `FollowCameraController`, `FlyCameraController` or `Node.lookAt` for anything the app renders or hit-tests: they all go through the mirrored `_matrix4LookAt`. (`test/triad_test.dart` and `test/screen_projection_test.dart` construct `PerspectiveCamera` for maths checks only; leave them.)
- **The orthographic clipping fix** (`orthographicCameraFor`: near may go negative). The fitted near plane only applies when the projection is exactly `PerspectiveProjection` (`Scene._depthRasterFor`), so the app's orthographic projection is never refitted, in Phase 3 too.
- **`AlwaysOnTopMaterial` / `NormalDepth*Material`.** 0.24 skips `bind` when the same material instance is bound again, but always re-binds when the material changes, so the depth-compare reset still runs after an always-on-top draw. The translucent pass still runs after the opaque one with depth write off. Keep both classes.
- **Double-copy winding for translucent geometry** (`doubleSidedWinding`). 0.24's `renderCullMode` has the same rule (double-sided honoured only for opaque), so it is still needed.
- **32-bit indices** for large meshes: still needed (`IndexType` is now exported, but leave the imports as they are).
- **Anti-aliasing off** in `PartViewport` (`AntiAliasingMode.none`, a diagnostic for edges showing through bodies). Keep it. Note for later: 0.24.0 fixed "Switching `Scene.antiAliasingMode` from `msaa` to another mode on the OpenGL ES backend no longer renders without a depth test (far surfaces drew over near ones)", the same symptom.
- **Translucent sort order (changed).** 0.18 sorted translucent draws by the distance from the camera to the node's origin (`_depthOf`), and the sketch-plane surface and grid were separated by moving their node origins (`_sketchPlaneNodeTransform`, `sketch_geometry_3d.dart`). 0.24 sorts by the centre of the geometry's bounds projected on the view direction (`sceneSortDepth`), after `Node.renderOrder`. The layering should survive (the offset is along the plane normal), but it is a real change: Phase 2's device check includes it. If the grid ends up behind the surface, set `renderOrder` on the grid node above the surface node's (higher draws later) and record it; do not move origins again.

## Rules for the implementing session

- Branch: the one you were given. One commit per step marked **(commit)**. Push after each phase and wait for the `Client - build and test` workflow. Do not start the next phase until CI is green **and** the owner has done that phase's device check (ask them, and wait).
- Change only what a step lists. This is a like-for-like port: the 3D view must look and behave exactly as before. No refactors, no other dependency bumps (`flutter pub upgrade <name>` for the named package only).
- Never skip, delete or weaken a test to get green. Updating an expected value that this plan says changes (vertex layout, index order) is allowed; say which in the commit message.
- Stop and report instead of improvising if something fails in a way this plan does not cover. Include the error text.
- Fill in the Progress table at the bottom as you go. At the end, add a dated entry to `docs/status.md` (format: its recent entries), including what was not verified.
- Final report for the owner, who is not a software developer, in plain words.

---

## Phase 1: Flutter stable 3.47.9, `flutter_scene` unchanged

Moving the channel on its own first means a problem in Phase 2 can only be `flutter_scene`.

1. **(commit)** `.github/workflows/client-verify.yml`, step "Set up Flutter":
   ```yaml
   with:
     channel: stable
     flutter-version: 3.47.9
     cache: true
   ```
   Rewrite the comment block above it: the project is on stable since `flutter_scene` needs Flutter >= 3.47.0 and 3.47.0 is the first stable with the GPU support it needs; the version is pinned so CI is reproducible; move it deliberately (3.50 when it is stable: its Android floors are Gradle 9.3.1, AGP 9.1.1, Kotlin 2.4.10, which we already meet).
   In the same commit:
   - `.claude/hooks/session-start.sh`: clone `-b 3.47.9` instead of `-b master`, and if `$FLUTTER_DIR` exists but `git -C "$FLUTTER_DIR" describe --tags --exact-match` is not `3.47.9`, delete it and clone again (a session image may already hold a master SDK). Update its comments (they say master is required).
   - `pubspec.lock`: run `flutter pub get` on 3.47.9 and commit the result (in the check above it changed two entries, for example `listen` was dropped).
2. **(commit, DIDSA-VR repo, same branch name)** `tools/setup_test_env.sh`: `get_flutter` clones `-b 3.47.9` instead of master; same "wrong version present, re-clone" check; update the comment on line 4 and the one in `get_flutter`. Push to the DIDSA-VR branch. Do not touch DIDSA-VR's older dated plan docs.
3. Local check on 3.47.9: `flutter analyze` (expect no issues), `flutter test` (expect all pass, GPU tests skipped).

Gate: CI green, including "Build debug APK". If the APK build fails with an error from Flutter's Gradle plugin about built-in Kotlin (flutter/flutter#192167 was reported on 3.47.2), set `android.builtInKotlin=false` in `android/gradle.properties`, put `id "kotlin-android"` back into the `plugins` block of `android/app/build.gradle` (after `com.android.application`), push, and record it. Any other Android failure: stop and report.

Owner device check (whole app, the Flutter engine changed): install the branch's debug APK; connect; open a part and orbit, pan, zoom; select faces and edges; edit a sketch; open the mesh viewer with an STL; the AI screen microphone; Share.
Owner's own computer: switch to stable, `flutter channel stable` then `flutter upgrade` (3.47.9 or a newer 3.47.x is fine). The master SDK they have now will no longer match CI.

## Phase 2: `flutter_scene` 0.24.3, like-for-like

### Step 1 (commit 2a starts): the package

`pubspec.yaml`: `flutter_scene: ^0.24.3`. Run `flutter pub upgrade flutter_scene` only.

### Step 2: the 12 compile errors (all verified on 3.47.9)

| File | Error | Fix |
|---|---|---|
| `lib/viewport3d/mesh_geometry.dart` `AlwaysOnTopMaterial.bind`, `NormalDepthUnlitMaterial.bind`, `NormalDepthPhysicallyBasedMaterial.bind` (6 errors) | `bind` now takes a `TransientWriter`, not `gpu.HostBuffer` (0.19) | Change the parameter type to `TransientWriter` (exported by `package:flutter_scene/scene.dart`). Bodies unchanged. Update the doc comment at the top of the file that names `HostBuffer` |
| `lib/viewport3d/orthographic_camera.dart` and `lib/viewport3d/b1_tap_test_screen.dart` `OrthographicProjection.getProjectionMatrix` (2) | The base method gained `{Vector2? jitter}` (0.23, for temporal anti-aliasing) | `vm.Matrix4 getProjectionMatrix(double aspectRatio, {vm.Vector2? jitter})`. Ignore `jitter` (TAA is off) and say so in a one-line comment |
| `lib/viewport3d/orbit_camera.dart`, `lib/viewport3d/part_viewport.dart` (3) | 0.24 exports its own `OrthographicCamera` and `OrthographicProjection`, which clash with the app's classes of the same names | Import with `hide OrthographicCamera, OrthographicProjection` in those two files, and add the same `hide` in `orthographic_camera.dart` and `b1_tap_test_screen.dart` for clarity (they declare the classes, so they compile either way). Do not switch to flutter_scene's classes in this phase |
| `lib/mesh_viewer/mesh_viewer_render.dart:218` `material.baseColorTexture = texture` (1) | Texture slots hold a `TextureSource` (0.19) | `material.baseColorTexture = GpuTextureSource(texture);` and change the file's `import 'package:flutter_gpu/gpu.dart' as gpu;` to `// ignore: implementation_imports` + `import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;` (the same shim `mesh_geometry.dart` already uses; `flutter_gpu`'s `Texture` is a different type from the shim's) |

After this, `flutter analyze` must report no issues (verified).

### Step 3: vertex layout, 48 to 72 bytes (run-time error otherwise)

`UnskinnedGeometry.uploadVertexData` now **throws** unless each vertex is 72 bytes: 18 float32s in this order: position 3, normal 3, UV0 2, **UV1 2**, colour 4, **tangent 4**. The app packs 12 floats (position, normal, UV0, colour) in three places:

- `meshBuffersFromMesh` (`lib/viewport3d/mesh_geometry.dart`): every Body and assembly instance.
- `triangleHighlightBuffers` (same file): face highlights.
- `_buildMeshViewerBatches` (`lib/mesh_viewer/mesh_viewer_render.dart`): the mesh viewer.

Add one shared helper in `mesh_geometry.dart`, for example `const int kVertexFloats = 18;` and `void writeUnskinnedVertex(Float32List out, int vertex, {required double px, py, pz, nx, ny, nz, double u = 0, double v = 0})`. It writes UV1 = 0, 0, colour = 1, 1, 1, 1 and tangent = 0, 0, 0, 0 (the values `flutter_scene`'s own `MeshGeometry.fromArrays` uses when they are absent, in `interleaved_layout.dart`). Use it in all three. `MeshGeometry.fromArrays` call sites need no change (its signature only gained optional parameters).

Tests: `test/mesh_geometry_test.dart` asserts the 12-float layout ("packs position/normal/uv/color into 12 floats per vertex" and the offsets in the tests after it). Update the expected layout to 18 floats and the new offsets; add one test that `vertexData.lengthInBytes == vertexCount * 72` for each of the two `mesh_geometry.dart` builders. Add a small test for the mesh viewer batch layout if the function can be reached from a test; if not, say so.

### Step 4: start-up error handling

0.24: `Scene.initializeStaticResources()` "completes with its error instead of normally". The app calls it without handling errors in three places:

- `lib/viewport3d/part_viewport.dart` (`Scene.initializeStaticResources().then(...)` in `initState`'s set-up)
- `lib/mesh_viewer/mesh_viewer_render.dart` `ensureSceneResourcesLoaded`
- `lib/viewport3d/b1_tap_test_screen.dart`

Without a GPU (every `flutter test` run) the error now escapes, the error screen replaces the viewport's loading spinner, and the "skip without a GPU" helpers think the GPU is ready. That caused the 4 failures seen (`touch_pivot_test`, `component_gizmo_touch_test`, `section_gizmo_touch_test`, `part_viewport_mouse_navigation_test`). Adding `.catchError(...)` that only logs made all four pass again (verified).

Do this properly:
- At each site, catch the error, `debugPrint` it, and set a state flag. The viewport then shows a short message in place of the spinner ("3D view unavailable on this device: <error>"), keyed `ValueKey('viewport-gpu-unavailable')`. On a phone this replaces an endless spinner with a reason (see the `EnableFlutterGPU` note in `AndroidManifest.xml`).
- Update every test helper that waits for the spinner to go away, so the unavailable message also counts as "not ready, skip": `gpuReady` in `test/touch_pivot_test.dart`, `_pumpUntilGpuReady` in `test/component_gizmo_touch_test.dart`, `test/section_gizmo_touch_test.dart`, `test/part_viewport_mouse_navigation_test.dart`, and any other test that finds `CircularProgressIndicator` for this purpose (grep `test/` for it and for `initializeStaticResources`).
- Add a widget test: with no GPU, the viewport shows the unavailable message and nothing throws.

### Step 5: keep two new defaults from changing behaviour

At every `Scene()` the app creates (`part_viewport.dart`, `mesh_viewer_screen.dart`, `b1_tap_test_screen.dart`), set:

- `..reversedDepth = false`: 0.24 stores depth reversed on Metal (iOS, macOS) and some browsers. The app's `NormalDepth*Material` classes hard-code `CompareFunction.lessEqual`, which is wrong under reversed depth (far surfaces would win). Android, Windows and Linux are not affected, but the app must behave the same everywhere.
- `..fitNearPlane = false`: 0.24 fits the near plane to visible content every frame. That is an improvement, but it changes which of two nearly coplanar surfaces wins, which the app's edge and sketch-overlay offsets were tuned against. Keep the old behaviour here; Phase 3 turns it on with its own device check.
- `..debugCheckCoplanarOverlaps = false`: 0.24 debug builds scan for coplanar surfaces and print them, costing a few ms a frame. A CAD scene is full of intended coplanar surfaces (sketches on faces, reference planes), so it is noise.

Each line gets a one-line comment saying why. Then **(commit 2a)**: steps 1 to 5.

### Step 6 (commit 2b, on its own so it can be reverted alone): triangle winding

0.23: "model-space front faces wind Counter-Clockwise (CCW) now ... hand-authored index buffers and custom `Geometry` subclasses wind the other way and need their triangles swapped." Read in the source: 0.18's `Material.bind` set `WindingOrder.counterClockwise` on the Y-down rasteriser (so model-space clockwise was the front); 0.24's sets `WindingOrder.clockwise` "accepting model-space CCW front faces".

What that means for this app: every triangle the app builds is either drawn double-sided or exists twice with opposite windings and opposite normals (for see-through surfaces, which are always back-face culled). So nothing disappears, but **after the flip the other copy is drawn**, and its normal points away from the viewer. Translucent Bodies (Appearance opacity below 100%) would be lit from behind (darker, wrong highlights). Unlit geometry (planes, sketch fills, highlights) would look the same either way.

Fix, so the drawn triangles and normals are exactly what 0.18 drew: **swap the 2nd and 3rd index of every triangle the app builds** (or the 2nd and 3rd vertex where triangles are written vertex by vertex), and **leave every normal value as it is**. Sites:

| Where | Change |
|---|---|
| `meshBuffersFromMesh` (`mesh_geometry.dart`) | First loop writes `t[0], t[2], t[1]`; the reversed copy writes `t[0], t[1], t[2]` (normals unchanged: the second copy keeps its flipped normals) |
| `triangleHighlightBuffers` (same file) | Its two `writeTriangle` calls swap `b` and `c`, but the normal written must stay the one computed for the original order: compute the normal from the old order first, then write the corners in the new order |
| `_buildMeshViewerBatches` (`mesh_viewer_render.dart`) | Write each triangle's 2nd and 3rd vertex in swapped order (normals and UVs travel with their vertex) |
| `doubleSidedQuadBuffers` (`lib/viewport3d/reference_planes.dart`, `indices: const [0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7]`) | `[0, 1, 2, 0, 2, 3, 4, 6, 5, 4, 7, 6]` |
| `doubleSidedSketchPlaneQuadBuffers` (`lib/viewport3d/sketch_geometry_3d.dart`, the same constant) | the same |
| the loop near `indices.addAll([a, b, c]); indices.addAll([c + n, b + n, a + n]);` (`sketch_geometry_3d.dart`) | `[a, c, b]` and `[c + n, a + n, b + n]` |

Then grep `lib/` once more for any other place that builds an index list or writes triangles for `flutter_scene` (`indices`, `Uint16List(`, `Uint32List(`, `writeTriangle`) and apply the same rule. `PolylineGeometry` and flutter_scene's own primitives need nothing (the package handles them).

Tests: update the expected index orders in `test/mesh_geometry_test.dart` (and any test pinning the quad constants), and add a comment there pointing at this section. Commit message says the order changed on purpose.

Gate for Phase 2: `flutter analyze` no issues; `flutter test` all pass with the same skips as before; CI green including the APK.

Owner device check, comparing against the Phase 1 APK if possible (two phones, or a screenshot of each):

1. A plain Body: shading, edges, orbit; it should look the same.
2. A see-through Body (Appearance, opacity about 50%): lit on the side facing you, not darker than before. **If it looks lit from behind, revert commit 2b** and report: that would mean the reasoning above is wrong for this case.
3. Select a face (highlight), select edges and vertices.
4. Edit a sketch on a face: sketch lines and points stay on top; the "Select Other" long-press preview does not show internal faces through a near face (the bug `NormalDepth*Material` was written for).
5. Reference planes and a sketch plane, from both sides. While sketching on a plane: the grid shows on top of the plane's tinted surface, from both sides and in orthographic view (0.24 changed how see-through surfaces are ordered).
5a. Mirror check (the 2026-07-22 fix): a Boss extruded in +Z on the XY plane builds on the +Z side, the triad agrees, and an asymmetric labelled STEP part matches SolidWorks (not mirrored), in both perspective and orthographic views.
6. Orthographic view, section view (section gizmo), an assembly with several instances, a mate preview.
7. Mesh viewer: an STL, and a GLB with a texture.
8. Feel: is orbiting a heavy model smoother? (The 2.5 to 6x figure is for Mali GPUs; say which phone.)

## Phase 3: fitted near plane (`fitNearPlane = true`), optional but recommended

One line per `Scene()`: remove the `fitNearPlane = false` from Phase 2 step 5. 0.24 then fits the near plane to what is on screen each frame, so surfaces close together (a sketch on a face, edges over faces, a far-zoomed model) stop flickering. Picking and the app's own projection maths are not affected ("projections and picking keep the authored planes").

**(commit)**. Gate: CI green. Owner device check: zoom far out on a large assembly and in close on a small feature; look for flicker between faces and edges, and between a sketch and the face it is on. Better or the same: keep. Worse: revert this commit.

---

## Later (each needs its own look; not in this plan)

- `Material.depthLayer` (0.24): "a higher layer draws over a lower one at any distance". It could replace the `AlwaysOnTopMaterial` / `NormalDepth*Material` depth-compare workarounds and the edge offset tricks. Those were written for on-device bugs, so swapping them needs its own investigation and device checks.
- `reversedDepth` on iOS/macOS: needs the `NormalDepth*` materials to use the scene's depth compare instead of `lessEqual`.
- Not flutter_scene's own `OrthographicCamera` (or any of its cameras): see "Earlier decisions" above, it would bring the mirror back.
- Anti-aliasing: the Part viewport sets `AntiAliasingMode.none` as an old diagnostic. 0.24 fixed a GLES bug with the same symptom, and has SMAA and TAA; worth a trial for edge quality, with an on-device check for edges showing through bodies.
- `Node.renderOrder` (0.24) could replace the node-origin offsets used to order translucent overlays.
- Flutter 3.50 stable when it is released (CI pin, the hook, DIDSA-VR's script).

## Progress

| Phase / step | Commit | CI run | What landed / what failed | Not verified |
|---|---|---|---|---|
| 1 | | | | |
| 1 (DIDSA-VR) | | | | |
| 2a | | | | |
| 2b | | | | |
| 3 | | | | |
