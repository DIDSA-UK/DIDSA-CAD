import 'package:flutter/material.dart' show Offset;
import 'package:flutter/rendering.dart' show Size;
import 'package:flutter_scene/scene.dart' show Camera;
import 'package:vector_math/vector_math.dart' as vm;

/// The inverse of [Camera.screenPointToRay]: maps a world-space point to
/// the screen-space [Offset] it renders at for [camera]/[viewSize] - same
/// view-projection transform, same NDC<->screen mapping, just run forward
/// (world -> clip -> NDC -> screen) instead of backward. Returns null when
/// [worldPoint] is behind the camera (`w <= 0` after the transform) - a
/// caller anchoring an overlay to a point that could leave the visible
/// frustum (e.g. during the new-sketch orientation confirm step's up/down
/// arrows) must treat that as "don't draw this", not project it to a
/// nonsense on-screen position.
///
/// Typed to the base [Camera] (not [PerspectiveCamera] specifically) so it
/// keeps working once a call site's camera is an [OrthographicCamera] -
/// `getViewTransform` is implemented once on `Camera` itself in terms of
/// `getViewMatrix()`/`projection`, identically for either kind.
Offset? worldToScreen(
    Camera camera, Size viewSize, vm.Vector3 worldPoint) {
  final viewProjection = camera.getViewTransform(viewSize);
  final clip = viewProjection *
      vm.Vector4(worldPoint.x, worldPoint.y, worldPoint.z, 1) as vm.Vector4;
  if (clip.w <= 0) return null;
  final ndcX = clip.x / clip.w;
  final ndcY = clip.y / clip.w;
  return Offset(
      (ndcX + 1) / 2 * viewSize.width, (1 - ndcY) / 2 * viewSize.height);
}

/// Assembly-audit gap `[28]` (`docs/assembly-scope.md`): [worldToScreen]'s
/// own sibling for a Sketch's *local-frame* geometry - composes
/// [focusTransform] (a focused sub-Part's own real world transform, `null`/
/// identity while unfocused or focused exactly at the document root, the
/// same `PartViewport.focusWorldTransformMatrix` convention every other
/// focus-transform consumer in this codebase already uses) onto
/// [localPoint] before projecting, the exact "compose the forward
/// transform onto a local-frame point before it's used" step every one of
/// this codebase's other `focusWorldTransformMatrix` read sites already
/// does inline (`part_viewport.dart`'s own `focusTransform.transformed3
/// (point)` pattern, e.g. `_syncMeshNode`) - factored out here once,
/// rather than repeated at each of `sketch_constraint_overlay.dart`'s four
/// projection call sites, `sketch_orientation_indicator.dart`'s two, and
/// `part_viewport.dart`'s own `_localPixelsPerSketchUnit`. This is the fix
/// for Phase 20's own disclosed "known gap, deliberately not fixed this
/// phase" (`docs/assembly-scope.md` §2v): those call sites project a
/// Sketch's local-frame geometry straight to screen space with no
/// focus-transform composition at all, so a dimension/constraint label or
/// the orientation indicator renders at the wrong screen position while
/// sketching on a focused sub-Part.
Offset? worldToScreenFocused(
    Camera camera, Size viewSize, vm.Matrix4? focusTransform, vm.Vector3 localPoint) {
  final worldPoint = focusTransform == null ? localPoint : focusTransform.transformed3(localPoint);
  return worldToScreen(camera, viewSize, worldPoint);
}
