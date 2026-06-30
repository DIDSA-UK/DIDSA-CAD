# Box selection (3D viewport) — methods tried, results, and user feedback — 2026-06-30

Branch: `claude/new-session-khsgmg`.

Box selection (drag a rectangle to select multiple vertices/edges/faces at once)
was attempted across three implementations in this branch's history. All three
were rejected on real-device testing. The feature has been **removed/parked**
(see `docs/status-2026-06-30-viewport-fixes-2.md`); single-tap-toggle selection
("multi select" via repeated taps, accumulated by `PartScreen`) is the only
selection mechanism in the viewport going forward.

## Summary

| # | Approach | Commit | On-device result |
|---|----------|--------|-------------------|
| 1 | Hand-rolled `_worldToScreen` projection (original Prompt A implementation) | `0f32a0d` | Selected the wrong corner/region of the box — projection math did not match what was drawn on screen |
| 2 | Frustum-plane test via `screenPointToRay` corner rays + cross-product plane normals | `7d0f3da` | Selected nothing at all, at any zoom level, full-screen box included |
| 3 | Direct 2D screen-projection (camera-axis dot products against the fixed 45° vertical FOV) | `0755f6c` | Selected *something*, but unreliably — missed entities inside the box and/or included entities outside it |

Net result: three independent projection/hit-test strategies, three different
failure modes, none usable. The user's decision (verbatim): *"that's still not
working great... Not robust enough to rely on. let's park it for now."*

---

## Method 1 — hand-rolled `_worldToScreen` (original implementation)

Part of the original Prompt A box-selection feature (commit `0f32a0d`,
`docs/status-2026-06-30-prompt-a.md`, item A2). `_hitTestEntitiesInBox`
projected each topology vertex/edge-midpoint/face-centroid into screen space
with a custom `_worldToScreen(vm.Vector3)` helper, using `cam.position`,
`cam.target`, and the camera's `right`/`up` vectors plus the fixed
`kCameraVerticalFovRadians = π/4` constant (matching the assumption already
used by `selection_hit_test.dart`'s single-tap hit-testing).

**On-device feedback:** screenshots from the user showed the box selecting
geometry from the *wrong corner* of the screen relative to where the drag
rectangle was actually drawn — a systematic offset/mirroring rather than
random noise, consistent with a sign or axis-convention bug in the projection.

## Method 2 — frustum-plane test via `screenPointToRay`

Attempted fix for Method 1 (commit `7d0f3da`). Replaced the direct screen
projection with a geometric approach: cast rays from each of the selection
box's four screen-space corners using the camera's existing
`screenPointToRay` helper, build four frustum side-planes from pairs of
adjacent corner rays via cross products, and test each entity's world-space
point for being inside all four planes.

**Result:** code-reviewed only (no Flutter/Dart toolchain is available in
this sandboxed environment to run or test render output), so this was not
caught before being pushed.

**On-device feedback:** *"box select is not selecting anything at all. tried
at max zoom, full screen box, nothing selected. Individual select working as
desired."* — suspected (not confirmed) cause: a Y-axis convention mismatch
between `screenPointToRay`'s internal coordinate handling and the plane
cross-product math, inverting the inside/outside test for every plane.

## Method 3 — direct 2D screen-projection

Final attempt (commit `0755f6c`). Dropped `screenPointToRay` and the
frustum-plane approach entirely in favour of projecting each entity's world
point straight to screen pixels via dot products against the camera's
forward/right/up axes and the fixed 45° vertical FOV, mirroring the same
math `selection_hit_test.dart` already uses for single-tap hit-testing:

```dart
final v = p - camPos;
final depth = v.dot(forward);
if (depth <= 0) return null; // behind camera
final ndcX = v.dot(right) / (depth * tanHalfFov * aspect);
final ndcY = v.dot(up) / (depth * tanHalfFov);
// → screen pixel coordinates
```

Window (contain-only) vs. crossing selection semantics were preserved via
the `containOnly` toggle in the toolbar's Selection submenu.

**Result:** code-reviewed only, not device-tested before push (same toolchain
limitation as Method 2).

**On-device feedback:** *"it's now making selections but it misses some or
picks up some outside the box. Not robust enough to rely on."* — an
improvement over Method 2 (it does select *something*, proving the gross
sign/axis error from Method 2 is gone), but still imprecise enough at the
box edges/corners to be unreliable for real use.

---

## Decision

No further iteration was attempted on a fourth projection method. Without a
local Flutter/Dart toolchain to render and visually verify projection math
against the live `flutter_scene`/Impeller pipeline, each fix could only be
validated by the user's on-device testing — a slow loop that produced three
different failure modes in three attempts. Box selection has been removed
from the codebase (state, gestures, hit-test, toolbar UI, tests) and the
viewport reverts to the original single-tap-toggle multi-select. Revisiting
box selection later should budget for an on-device or screenshot-based
verification loop rather than code-review-only iteration.
