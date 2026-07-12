import 'package:flutter/material.dart' show Offset;
import 'package:flutter/rendering.dart' show Size;
import 'package:flutter_scene/scene.dart' show PerspectiveCamera;
import 'package:vector_math/vector_math.dart' as vm;

/// The inverse of [PerspectiveCamera.screenPointToRay]: maps a world-space
/// point to the screen-space [Offset] it renders at for [camera]/[viewSize] -
/// same view-projection transform, same NDC<->screen mapping, just run
/// forward (world -> clip -> NDC -> screen) instead of backward. Returns
/// null when [worldPoint] is behind the camera (`w <= 0` after the
/// transform) - a caller anchoring an overlay to a point that could leave
/// the visible frustum (e.g. during the new-sketch orientation confirm
/// step's up/down arrows) must treat that as "don't draw this", not project
/// it to a nonsense on-screen position.
Offset? worldToScreen(PerspectiveCamera camera, Size viewSize, vm.Vector3 worldPoint) {
  final viewProjection = camera.getViewTransform(viewSize);
  final clip = viewProjection * vm.Vector4(worldPoint.x, worldPoint.y, worldPoint.z, 1) as vm.Vector4;
  if (clip.w <= 0) return null;
  final ndcX = clip.x / clip.w;
  final ndcY = clip.y / clip.w;
  return Offset((ndcX + 1) / 2 * viewSize.width, (1 - ndcY) / 2 * viewSize.height);
}
