# DIDSA-CAD Status Summary — 2026-06-23 (Stage 10a)

## What this covers

Follow-on session to the same day's Stage 9 Extrude work, on
`claude/project-background-next-actions-larhyt`:

1. **Signed Extrude distances** — `start_distance`/`end_distance` are now
   both signed offsets from the Sketch plane along its normal, with the
   solid spanning literally from one to the other (previously
   `start_distance` was only ever used as a magnitude in the wrong
   direction). Validated server-side: `end_distance` must be greater than
   `start_distance`, on both create and update.
2. **Client-side Hide/Show now affects the body mesh.** `GET
   /document/parts/{id}/mesh` accepts a repeated `hidden_feature_ids` query
   param; the accumulated solid skips any `ExtrudeFeature` whose id is in
   that set (hiding a Boss drops its volume, hiding a Cut un-subtracts it).
   This state is purely client-side and is never persisted on the backend —
   the client re-sends it on every mesh fetch.
3. **`OrbitCamera` zoom bounds now scale to the actual mesh.** `minDistance`/
   `maxDistance` were fixed constants; `setZoomBoundsForRadius(radius)`
   derives them from the mesh's bounding-sphere radius (×2 / ×20) instead,
   called whenever the Part's mesh changes. Falls back to the old fixed
   defaults for a non-positive radius (no body yet, or an empty one).

## Backend

- `backend/app/document/extrude.py`: `_solid_for_extrude_feature` now
  translates the face to `start_distance` first, then prisms by
  `end_distance - start_distance`, instead of treating `start_distance` as
  a magnitude subtracted in the wrong direction. `compute_part_solid` takes
  a new `hidden_feature_ids: frozenset[str]` parameter and skips any
  matching `ExtrudeFeature` entirely, as if it weren't in the Part's
  history.
- `backend/app/document/router.py`: new `_validate_extrude_distances`
  helper (400 "end_distance must be greater than start_distance"), wired
  into both `create_extrude_feature` and `update_extrude_feature`.
  `get_part_mesh` gained `hidden_feature_ids: list[str] = Query(default=[])`
  and forwards it to `compute_part_solid`.
- `backend/app/document/models.py`: `ExtrudeFeature` docstring updated to
  describe the new signed-offset semantics.
- New tests in `backend/tests/test_stage9_extrude.py`: non-zero and
  negative `start_distance` spanning correctly, the new 400 validation on
  both create and update (and that a rejected PATCH doesn't mutate the
  stored feature), and `hidden_feature_ids` excluding a Boss / un-subtracting
  a Cut from the computed mesh.
- **166/166 backend tests pass** (verified via the micromamba `cadtest`
  env — `pythonocc-core` is not importable in a bare `pip`/venv in this
  sandbox).

## Client

- `client/lib/viewport3d/mesh_geometry.dart`: `centroidOfMesh` replaced
  with `boundsOfMesh`, returning a `MeshBounds` (`center` = bounding-box
  centre, `boundingSphereRadius` = half the box diagonal) or `null` for an
  empty mesh.
- `client/lib/viewport3d/orbit_camera.dart`: `minDistance`/`maxDistance`
  are now mutable instance fields (`defaultMinDistance`/`defaultMaxDistance`
  as the fixed fallback); new `setZoomBoundsForRadius(radius)` derives them
  from a body's bounding-sphere radius and re-clamps `distance` immediately.
  `reset()` now clamps its default distance into the current bounds rather
  than assigning it outright, so a body smaller than the old fixed default
  distance doesn't let Reset escape the new bounds.
- `client/lib/viewport3d/part_viewport.dart`: `_syncMeshNode` now calls
  `boundsOfMesh`, feeding `.center` to `OrbitCamera.setTarget` and
  `.boundingSphereRadius` to the new `setZoomBoundsForRadius`.
- `client/lib/api/document_api_client.dart`: `getPartMesh` takes an
  optional `hiddenFeatureIds` and forwards it as a repeated
  `hidden_feature_ids` query param.
- `client/lib/viewport3d/part_screen.dart`: new `_refreshMesh()` helper
  (re-fetches the mesh with the current `_hiddenFeatureIds`), used by
  `_loadPart`, `_ensureExtrudeFeatureExists`, `_cancelExtrude`, the
  (now-async) `_toggleFeatureVisibility`, and `_cascadeDeleteFeature` — so
  hiding/showing or cascade-deleting a Feature always refreshes the
  rendered body, not just the feature tree.
- `client/lib/viewport3d/extrude_panel.dart`: now shows a live "Depth: N" /
  "End distance must be greater than start distance" hint below the
  distance fields, mirroring the backend's own validation so the user sees
  why a Confirm would be rejected before trying it.
- Updated `client/test/mesh_geometry_test.dart` and
  `client/test/orbit_camera_test.dart` for the `boundsOfMesh` rename and the
  new `setZoomBoundsForRadius`/`reset`-clamping behaviour.

## Known limitation this session

**No Flutter/Dart SDK is available in this sandbox** (`flutter`/`dart` are
both absent, no SDK directory exists anywhere on the filesystem), so none
of the Dart changes above could be run through `flutter analyze` or
`flutter test` this session. They were made as carefully as possible
(reading each full file before editing, cross-checking call sites by
grep), but are **unverified by any test run** and should be confirmed with
a real `flutter analyze`/`flutter test` pass before relying on them.

One specific risk flagged for human follow-up: `OrbitCamera.orbitByScreenDelta`
was deliberately **left unchanged** this session. A from-scratch Python
quaternion simulation (written because no Dart toolchain or `numpy` was
available to verify against the real implementation) suggested its
existing "upside-down" horizontal-drag-direction flip may not satisfy its
own test (`orbit_camera_test.dart`'s `'horizontal orbit direction stays
visually consistent once the camera is upside-down'`) — but since this
couldn't be checked against the real `vector_math` library, the safer
choice was to leave the on-device-confirmed behaviour alone rather than
risk a regression on unverified hand-rolled math. Worth a real `flutter
test` run plus an on-device check next session.

## Branch / merge state

All Stage 10a work is committed on `claude/project-background-next-actions-larhyt`
and pushed to origin. No PR opened, no merge to `main` performed.

## What's next

- Run `flutter analyze` / `flutter test` in an environment that has the
  Flutter SDK, to verify all the Dart changes above (none of this was
  possible in this sandbox).
- Resolve the `orbitByScreenDelta` upside-down-drag question above with a
  real test run and/or on-device check.
- On-device smoke test of Hide/Show now affecting the rendered body, and
  of zoom bounds tracking the actual mesh size as features are added.
