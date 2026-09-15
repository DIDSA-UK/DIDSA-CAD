import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'mesh_geometry.dart' show AlwaysOnTopMaterial;
import 'section_gizmo.dart' show angleOnRotationPlane, closestPointOnLineToRay;
import 'selection_hit_test.dart' show kSelectionHitRadiusPixels, kCameraVerticalFovRadians;

/// Assembly support Phase 5 (`docs/assembly-scope.md` §3): the Move/Rotate
/// gizmo for a selected Occurrence - `section_gizmo.dart`'s sibling,
/// reusing that file's own proven ray/line/plane primitives
/// ([closestPointOnLineToRay]/[angleOnRotationPlane]) rather than
/// re-deriving equivalent math. Differs from the section gizmo in shape,
/// not technique: a *component* placement is a free rigid transform (all
/// 3 translation axes, all 3 rotation axes meaningful - unlike a section
/// plane, which is fully described by one point + one normal, so
/// `SectionGizmoHandleKind` only ever needed 1 translate + 2 rotate
/// handles), so this is the full 6-handle manipulator: 3 translate arrows
/// plus 3 rotate rings.
///
/// The gizmo's own basis is always the Occurrence's own *current* local
/// frame (derived from its live [ComponentGizmoBasis.origin]/rotation),
/// not a fixed world frame - the same "handles follow the entity's own
/// orientation" convention [sectionGizmoBasis] already established for the
/// section plane's own normal-derived frame. A translate handle therefore
/// moves the component along its own local axis, and a rotate handle spins
/// it about its own local axis - both drags then compose onto whatever
/// placement was already there (see [composeTranslation]/[composeRotation]),
/// never replacing it outright.
enum ComponentGizmoHandleKind { translateX, translateY, translateZ, rotateX, rotateY, rotateZ }

/// The Occurrence's own current local frame, in world space - [origin] is
/// its world-space translation, [xAxis]/[yAxis]/[zAxis] its own current
/// rotation's basis vectors (already unit length, mutually orthogonal).
/// Callers derive this from whichever [RigidTransformDto]/`Matrix4`
/// they're already tracking for the selected instance
/// (`mesh_geometry.dart`'s `matrix4FromRigidTransform`) - this class itself
/// has no opinion on where that comes from.
class ComponentGizmoBasis {
  final vm.Vector3 origin;
  final vm.Vector3 xAxis;
  final vm.Vector3 yAxis;
  final vm.Vector3 zAxis;

  const ComponentGizmoBasis({
    required this.origin,
    required this.xAxis,
    required this.yAxis,
    required this.zAxis,
  });

  /// Built straight from a placement [Matrix4] (e.g.
  /// `matrix4FromRigidTransform`'s own result) - the matrix's own translation
  /// column and rotation columns are exactly [origin]/[xAxis]/[yAxis]/[zAxis].
  factory ComponentGizmoBasis.fromMatrix(vm.Matrix4 matrix) {
    final translation = matrix.getTranslation();
    return ComponentGizmoBasis(
      origin: translation,
      xAxis: vm.Vector3(matrix.storage[0], matrix.storage[1], matrix.storage[2]).normalized(),
      yAxis: vm.Vector3(matrix.storage[4], matrix.storage[5], matrix.storage[6]).normalized(),
      zAxis: vm.Vector3(matrix.storage[8], matrix.storage[9], matrix.storage[10]).normalized(),
    );
  }

  vm.Vector3 axisFor(ComponentGizmoHandleKind kind) => switch (kind) {
        ComponentGizmoHandleKind.translateX || ComponentGizmoHandleKind.rotateX => xAxis,
        ComponentGizmoHandleKind.translateY || ComponentGizmoHandleKind.rotateY => yAxis,
        ComponentGizmoHandleKind.translateZ || ComponentGizmoHandleKind.rotateZ => zAxis,
      };
}

/// World-space half-length of each translation arrow's shaft, and the
/// radius of each rotation ring, used only as a fallback - same role
/// [kSectionGizmoArrowLength]/[kSectionGizmoRingRadius] play for the
/// section gizmo, see that constant's own doc comment.
const double kComponentGizmoArrowLength = 5.0;
const double kComponentGizmoRingRadius = 3.5;

/// Desired constant on-screen size (screen pixels) - see
/// [kSectionGizmoArrowLengthPixels]'s own doc comment for the technique.
const double kComponentGizmoArrowLengthPixels = 80.0;
const double kComponentGizmoRingRadiusPixels = 60.0;

/// Number of straight segments approximating each rotation ring - see
/// [kSectionGizmoRingSegments]'s own doc comment.
const int kComponentGizmoRingSegments = 48;

double _worldUnitsPerPixelAtDepth(double depth, Size viewportSize, {double fovRadiansY = kCameraVerticalFovRadians}) {
  if (viewportSize.height <= 0) return double.infinity;
  final worldHeightAtDepth = 2 * depth * math.tan(fovRadiansY / 2);
  return worldHeightAtDepth / viewportSize.height;
}

double _componentGizmoWorldScale({
  required double desiredScreenPixels,
  required double fallbackWorldUnits,
  required vm.Vector3 origin,
  vm.Vector3? cameraPosition,
  Size? viewportSize,
  double fovRadiansY = kCameraVerticalFovRadians,
}) {
  if (cameraPosition == null || viewportSize == null || viewportSize.height <= 0) {
    return fallbackWorldUnits;
  }
  final depth = (origin - cameraPosition).length;
  if (depth <= 0) return fallbackWorldUnits;
  return desiredScreenPixels * _worldUnitsPerPixelAtDepth(depth, viewportSize, fovRadiansY: fovRadiansY);
}

(double, double)? _closestRaySegmentDistance(vm.Ray ray, vm.Vector3 segStart, vm.Vector3 segEnd) {
  final d1 = ray.direction.normalized();
  final d2 = segEnd - segStart;
  final r = ray.origin - segStart;
  final b = d1.dot(d2);
  final c = d2.dot(d2);
  final d = d1.dot(r);
  final e = d2.dot(r);
  final denom = c - b * b;
  double segT;
  if (c < 1e-9) {
    segT = 0.0;
  } else if (denom.abs() < 1e-9) {
    return null;
  } else {
    segT = (e - b * d) / denom;
  }
  segT = segT.clamp(0.0, 1.0);
  final segPoint = segStart + d2 * segT;
  final rayT = d1.dot(segPoint - ray.origin);
  if (rayT <= 0) return null;
  final closestOnRay = ray.origin + d1 * rayT;
  return (rayT, (segPoint - closestOnRay).length);
}

/// One handle hit - mirrors [SectionGizmoHit]'s own role exactly.
class ComponentGizmoHit {
  final ComponentGizmoHandleKind kind;
  final double rayT;

  const ComponentGizmoHit({required this.kind, required this.rayT});
}

/// Pure ray-vs-gizmo hit-test for [basis]'s own manipulator - mirrors
/// [hitTestSectionGizmo]'s exact structure (three arrows as ray-vs-segment,
/// three rings as ray-vs-many-segments), just with a third arrow/ring pair
/// since a component gizmo has no "this axis doesn't matter" omission the
/// way a section plane's own normal-axis rotation does.
ComponentGizmoHit? hitTestComponentGizmo(
  vm.Ray ray,
  ComponentGizmoBasis basis,
  Size viewportSize, {
  double radiusPixels = kSelectionHitRadiusPixels,
  vm.Vector3? cameraPosition,
  double fovRadiansY = kCameraVerticalFovRadians,
}) {
  final arrowLength = _componentGizmoWorldScale(
    desiredScreenPixels: kComponentGizmoArrowLengthPixels,
    fallbackWorldUnits: kComponentGizmoArrowLength,
    origin: basis.origin,
    cameraPosition: cameraPosition,
    viewportSize: viewportSize,
    fovRadiansY: fovRadiansY,
  );
  final ringRadius = _componentGizmoWorldScale(
    desiredScreenPixels: kComponentGizmoRingRadiusPixels,
    fallbackWorldUnits: kComponentGizmoRingRadius,
    origin: basis.origin,
    cameraPosition: cameraPosition,
    viewportSize: viewportSize,
    fovRadiansY: fovRadiansY,
  );

  ComponentGizmoHit? best;
  double? bestPixelDistance;

  void consider(ComponentGizmoHandleKind kind, vm.Vector3 a, vm.Vector3 b) {
    final closest = _closestRaySegmentDistance(ray, a, b);
    if (closest == null) return;
    final (rayT, worldDistance) = closest;
    final pixelDistance = worldDistance / _worldUnitsPerPixelAtDepth(rayT, viewportSize, fovRadiansY: fovRadiansY);
    if (pixelDistance > radiusPixels) return;
    if (bestPixelDistance == null || pixelDistance < bestPixelDistance!) {
      bestPixelDistance = pixelDistance;
      best = ComponentGizmoHit(kind: kind, rayT: rayT);
    }
  }

  consider(ComponentGizmoHandleKind.translateX, basis.origin, basis.origin + basis.xAxis * arrowLength);
  consider(ComponentGizmoHandleKind.translateY, basis.origin, basis.origin + basis.yAxis * arrowLength);
  consider(ComponentGizmoHandleKind.translateZ, basis.origin, basis.origin + basis.zAxis * arrowLength);

  void considerRing(ComponentGizmoHandleKind kind, vm.Vector3 axisA, vm.Vector3 axisB) {
    vm.Vector3 pointAt(double t) => basis.origin + (axisA * math.cos(t) + axisB * math.sin(t)) * ringRadius;
    var previous = pointAt(0);
    for (var i = 1; i <= kComponentGizmoRingSegments; i++) {
      final t = 2 * math.pi * i / kComponentGizmoRingSegments;
      final current = pointAt(t);
      consider(kind, previous, current);
      previous = current;
    }
  }

  // Each ring sweeps the plane perpendicular to the axis it rotates about -
  // the usual CAD-gizmo convention (same as [hitTestSectionGizmo]'s own
  // rotateX/rotateY rings).
  considerRing(ComponentGizmoHandleKind.rotateX, basis.yAxis, basis.zAxis);
  considerRing(ComponentGizmoHandleKind.rotateY, basis.xAxis, basis.zAxis);
  considerRing(ComponentGizmoHandleKind.rotateZ, basis.xAxis, basis.yAxis);

  return best;
}

final vm.Vector3 _componentGizmoColorX = vm.Vector3(0xE8 / 255, 0x36 / 255, 0x4A / 255);
final vm.Vector3 _componentGizmoColorY = vm.Vector3(0x27 / 255, 0xAE / 255, 0x60 / 255);
final vm.Vector3 _componentGizmoColorZ = vm.Vector3(0x3A / 255, 0x7B / 255, 0xD5 / 255);

/// The color each handle renders/highlights with - same X=red/Y=green/
/// Z=blue axis convention [sectionGizmoHandleColor] uses; a rotate handle
/// borrows the arrow color of the axis it rotates *about* (unlike the
/// section gizmo, every one of the three arrow colors is actually used
/// here, since all three translate axes are meaningful for a component).
vm.Vector4 componentGizmoHandleColor(ComponentGizmoHandleKind kind, {bool highlighted = false}) {
  final base = switch (kind) {
    ComponentGizmoHandleKind.translateX || ComponentGizmoHandleKind.rotateX => _componentGizmoColorX,
    ComponentGizmoHandleKind.translateY || ComponentGizmoHandleKind.rotateY => _componentGizmoColorY,
    ComponentGizmoHandleKind.translateZ || ComponentGizmoHandleKind.rotateZ => _componentGizmoColorZ,
  };
  final alpha = highlighted ? 1.0 : 0.85;
  return vm.Vector4(base.x, base.y, base.z, alpha);
}

/// Builds the [Node] rendering [basis]'s own gizmo - mirrors
/// [buildSectionGizmoNode] exactly (thin [PolylineGeometry] arrows/rings,
/// [AlwaysOnTopMaterial] + `AlphaMode.blend` for the same deterministic-
/// on-top-of-everything draw-order reason that function's own doc comment
/// documents), just with a third arrow and a third ring.
Node buildComponentGizmoNode(
  ComponentGizmoBasis basis, {
  ComponentGizmoHandleKind? highlightedHandle,
  vm.Vector3? cameraPosition,
  Size? viewportSize,
  double fovRadiansY = kCameraVerticalFovRadians,
}) {
  final primitives = <MeshPrimitive>[];
  final arrowLength = _componentGizmoWorldScale(
    desiredScreenPixels: kComponentGizmoArrowLengthPixels,
    fallbackWorldUnits: kComponentGizmoArrowLength,
    origin: basis.origin,
    cameraPosition: cameraPosition,
    viewportSize: viewportSize,
    fovRadiansY: fovRadiansY,
  );
  final ringRadius = _componentGizmoWorldScale(
    desiredScreenPixels: kComponentGizmoRingRadiusPixels,
    fallbackWorldUnits: kComponentGizmoRingRadius,
    origin: basis.origin,
    cameraPosition: cameraPosition,
    viewportSize: viewportSize,
    fovRadiansY: fovRadiansY,
  );

  void addArrow(ComponentGizmoHandleKind kind, vm.Vector3 axis) {
    final tip = basis.origin + axis * arrowLength;
    final highlighted = kind == highlightedHandle;
    final material = AlwaysOnTopMaterial()
      ..alphaMode = AlphaMode.blend
      ..baseColorFactor = componentGizmoHandleColor(kind, highlighted: highlighted);
    primitives.add(MeshPrimitive(
      PolylineGeometry([basis.origin, tip], width: highlighted ? 5 : 3),
      material,
    ));
  }

  void addRing(ComponentGizmoHandleKind kind, vm.Vector3 axisA, vm.Vector3 axisB) {
    final highlighted = kind == highlightedHandle;
    final points = <vm.Vector3>[
      for (var i = 0; i <= kComponentGizmoRingSegments; i++)
        basis.origin +
            (axisA * math.cos(2 * math.pi * i / kComponentGizmoRingSegments) +
                    axisB * math.sin(2 * math.pi * i / kComponentGizmoRingSegments)) *
                ringRadius,
    ];
    final material = AlwaysOnTopMaterial()
      ..alphaMode = AlphaMode.blend
      ..baseColorFactor = componentGizmoHandleColor(kind, highlighted: highlighted);
    primitives.add(MeshPrimitive(PolylineGeometry(points, width: highlighted ? 4 : 2.5), material));
  }

  addArrow(ComponentGizmoHandleKind.translateX, basis.xAxis);
  addArrow(ComponentGizmoHandleKind.translateY, basis.yAxis);
  addArrow(ComponentGizmoHandleKind.translateZ, basis.zAxis);
  addRing(ComponentGizmoHandleKind.rotateX, basis.yAxis, basis.zAxis);
  addRing(ComponentGizmoHandleKind.rotateY, basis.xAxis, basis.zAxis);
  addRing(ComponentGizmoHandleKind.rotateZ, basis.xAxis, basis.yAxis);

  return Node(name: 'component-gizmo', mesh: Mesh.primitives(primitives: primitives));
}

/// Applies a translate-handle drag: [worldDelta] (already resolved via
/// [closestPointOnLineToRay] - the caller's own drag-start-to-drag-current
/// difference along the dragged axis) is simply added to
/// [currentTranslation] - translation has no composition subtlety the way
/// rotation does (see [composeRotation]), since two translations always
/// commute.
vm.Vector3 composeTranslation(vm.Vector3 currentTranslation, vm.Vector3 worldDelta) =>
    currentTranslation + worldDelta;

/// Applies a rotate-handle drag: composes [deltaAngleRadians] about local
/// [deltaAxis] *onto* the Occurrence's existing rotation
/// ([currentAxis]/[currentAngleDegrees]), rather than replacing it -
/// `q_current * q_delta` (the delta expressed in the object's own,
/// already-rotated local frame - the same "handles follow the entity's own
/// orientation" convention [ComponentGizmoBasis] itself is built from, so a
/// rotate-handle drag keeps spinning the object about its own current axis,
/// not a world-fixed one). Returns a new single equivalent axis-angle pair -
/// `RigidTransform` has no quaternion field of its own
/// (`matrix4FromRigidTransform`'s own doc comment), so every rotation this
/// app persists must always collapse back to one axis-angle pair no matter
/// how many drags contributed to it. A near-zero resulting angle (the two
/// rotations cancelling out) returns the canonical `([0,0,1], 0)` identity
/// representation, matching `RigidTransform.identity()`'s own backend-side
/// default.
(vm.Vector3 axis, double angleDegrees) composeRotation({
  required vm.Vector3 currentAxis,
  required double currentAngleDegrees,
  required vm.Vector3 deltaAxis,
  required double deltaAngleRadians,
}) {
  final qCurrent = currentAxis.length2 < 1e-12
      ? vm.Quaternion.identity()
      : vm.Quaternion.axisAngle(currentAxis.normalized(), currentAngleDegrees * math.pi / 180);
  final qDelta = vm.Quaternion.axisAngle(deltaAxis.normalized(), deltaAngleRadians);
  final qNew = qCurrent * qDelta;
  final axis = qNew.axis;
  if (axis.length2 < 1e-12) return (vm.Vector3(0, 0, 1), 0.0);
  return (axis.normalized(), qNew.radians * 180 / math.pi);
}

/// A translate-handle drag's own world-space delta, from [dragStartRay] to
/// [currentRay], both resolved via [closestPointOnLineToRay] against the
/// same frozen-at-drag-start [origin]/[axis] - mirrors `PartViewport`'s
/// existing section-gizmo drag fields (`_sectionDragStartPointOnAxis` etc.):
/// always computed as an *absolute* delta from the drag's own start, never
/// accumulated frame-over-frame, so floating-point drift can never build up
/// across a long drag gesture.
vm.Vector3 translateDragDelta({
  required vm.Ray dragStartRay,
  required vm.Ray currentRay,
  required vm.Vector3 origin,
  required vm.Vector3 axis,
}) {
  final startPoint = closestPointOnLineToRay(dragStartRay, origin, axis);
  final currentPoint = closestPointOnLineToRay(currentRay, origin, axis);
  return currentPoint - startPoint;
}

/// A rotate-handle drag's own angle delta (radians) - [refAxis]/[perpAxis]
/// span the plane perpendicular to [rotationAxis] (the same pair
/// [buildComponentGizmoNode]'s own ring for that handle is drawn with -
/// e.g. `rotateX`'s ring uses `yAxis`/`zAxis`). Null if either ray misses
/// the rotation plane entirely (see [angleOnRotationPlane]'s own doc
/// comment) - the caller is expected to simply not update the drag that
/// frame, the same "no well-defined position, hold the last one" fallback
/// [PartViewport]'s existing section-gizmo rotate drag already uses.
double? rotateDragDeltaRadians({
  required vm.Ray dragStartRay,
  required vm.Ray currentRay,
  required vm.Vector3 origin,
  required vm.Vector3 rotationAxis,
  required vm.Vector3 refAxis,
  required vm.Vector3 perpAxis,
}) {
  final startAngle = angleOnRotationPlane(dragStartRay, origin, rotationAxis, refAxis, perpAxis);
  final currentAngle = angleOnRotationPlane(currentRay, origin, rotationAxis, refAxis, perpAxis);
  if (startAngle == null || currentAngle == null) return null;
  return currentAngle - startAngle;
}
