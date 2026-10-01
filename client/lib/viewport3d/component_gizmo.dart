import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'mesh_geometry.dart' show AlwaysOnTopMaterial;
import 'section_gizmo.dart' show angleOnRotationPlane, closestPointOnLineToRay;
import 'selection_hit_test.dart' show kCameraVerticalFovRadians;

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
enum ComponentGizmoHandleKind { translateX, translateY, translateZ, rotateX, rotateY, rotateZ, translatePlane }

/// Plan S8: what the mates allow for one handle (from `lib/motion/gizmo_freedom.dart`, mapped to world space).
/// [fraction] is the free fraction 0..1; a rotate handle may carry a [pivot] point and unit [pivotAxis] (world) - the
/// screw axis the part really turns about, onto which the ring is re-pivoted.
class ComponentHandleCue {
  final double fraction;
  final vm.Vector3? pivot;
  final vm.Vector3? pivotAxis;

  const ComponentHandleCue(this.fraction, {this.pivot, this.pivotAxis});

  bool get locked => fraction < kComponentHandleLockedBelow;
  bool get free => fraction >= kComponentHandleFreeAtLeast;
}

/// Free fraction below which a handle is drawn grey/short and cannot be grabbed, and from which it is full strength.
/// (Same numbers as `kHandleLockedBelow` / `kHandleFreeAtLeast` in `lib/motion/gizmo_freedom.dart`.)
const double kComponentHandleLockedBelow = 0.05;
const double kComponentHandleFreeAtLeast = 0.95;

/// Grab radius of the Move/Rotate gizmo's handles, in pixels: wider than a plain selection pick
/// (`kSelectionHitRadiusPixels`, 12.5) because the thin arrows and rings are hard to hit, most of all on touch.
const double kComponentGizmoHitRadiusPixels = 26.0;

/// A locked handle's arrow is drawn this fraction of its normal length.
const double kComponentLockedLengthFactor = 0.35;

/// The mates' view of the whole gizmo: per-handle cues (absent = no information = drawn as usual) and, when exactly two
/// pure translations are free, the world unit [planeNormal] of the in-plane handle.
class ComponentGizmoCues {
  final Map<ComponentGizmoHandleKind, ComponentHandleCue> handles;
  final vm.Vector3? planeNormal;

  const ComponentGizmoCues({this.handles = const {}, this.planeNormal});

  ComponentHandleCue? operator [](ComponentGizmoHandleKind k) => handles[k];

  bool isLocked(ComponentGizmoHandleKind k) => handles[k]?.locked ?? false;
}

/// Two unit vectors perpendicular to [n] and to each other.
(vm.Vector3, vm.Vector3) perpendicularPair(vm.Vector3 n) {
  final axis = n.normalized();
  final helper = axis.x.abs() < 0.9 ? vm.Vector3(1, 0, 0) : vm.Vector3(0, 1, 0);
  final a = axis.cross(helper).normalized();
  final b = axis.cross(a).normalized();
  return (a, b);
}

/// [point] turned by [angle] radians about the axis through [pivot] along [axis]: `pivot + R·(point − pivot)`. What a
/// re-pivoted rotate ring does to the occurrence origin (the rotation itself composes via [composeRotation]).
vm.Vector3 rotatePointAboutPivot(vm.Vector3 point, vm.Vector3 pivot, vm.Vector3 axis, double angle) =>
    vm.Quaternion.axisAngle(axis.normalized(), angle).asRotationMatrix().transformed(point - pivot) + pivot;

/// In-plane handle frame: `u` = the gizmo's x axis projected into the plane (y if x is ~normal), `v = n × u`.
(vm.Vector3, vm.Vector3) componentGizmoPlaneFrame(ComponentGizmoBasis basis, vm.Vector3 normal) {
  final n = normal.normalized();
  var u = basis.xAxis - n * basis.xAxis.dot(n);
  if (u.length2 < 1e-6) u = basis.yAxis - n * basis.yAxis.dot(n);
  u = u.normalized();
  return (u, n.cross(u).normalized());
}

/// The in-plane handle's square, in (u, v) coordinates as fractions of the arrow length.
const double kComponentPlaneHandleNear = 0.2;
const double kComponentPlaneHandleFar = 0.6;

/// Where the ray meets the plane through [origin] with [normal] (ray parameter, point), or null when parallel/behind.
(double, vm.Vector3)? rayPlaneHit(vm.Ray ray, vm.Vector3 origin, vm.Vector3 normal) {
  final d = ray.direction.normalized();
  final denom = d.dot(normal);
  if (denom.abs() < 1e-9) return null;
  final t = (origin - ray.origin).dot(normal) / denom;
  if (t <= 0) return null;
  return (t, ray.origin + d * t);
}

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
        // The in-plane handle has no single axis; its normal comes from [ComponentGizmoCues.planeNormal].
        ComponentGizmoHandleKind.translatePlane => zAxis,
      };
}

/// World-space half-length of each translation arrow's shaft, and the
/// radius of each rotation ring, used only as a fallback - when no
/// [ComponentGizmoHit]/[buildComponentGizmoNode] caller can supply the
/// target's own bounding-sphere radius at all (e.g. an empty/placeholder
/// mesh - see [_componentGizmoArrowLength]'s own doc comment for the normal,
/// size-based case).
const double kComponentGizmoArrowLength = 5.0;
const double kComponentGizmoRingRadius = 3.5;

/// On-device feedback ("the gizmo is the wrong size"): a rotation ring
/// reads as a fraction of its own translate arrow's length - kept as a
/// ratio (not a second independent constant/fraction) so the two stay in
/// proportion however the gizmo's overall size is actually derived.
const double kComponentGizmoRingToArrowRatio = kComponentGizmoRingRadius / kComponentGizmoArrowLength;

/// Number of straight segments approximating each rotation ring - see
/// [kSectionGizmoRingSegments]'s own doc comment.
const int kComponentGizmoRingSegments = 48;

double _worldUnitsPerPixelAtDepth(double depth, Size viewportSize, {double fovRadiansY = kCameraVerticalFovRadians}) {
  if (viewportSize.height <= 0) return double.infinity;
  final worldHeightAtDepth = 2 * depth * math.tan(fovRadiansY / 2);
  return worldHeightAtDepth / viewportSize.height;
}

/// On-device feedback ("the gizmo is the wrong size"): this used to hold a
/// constant *on-screen pixel* size regardless of the target's own scale
/// (`_componentGizmoWorldScale`, a `desiredScreenPixels`-driven helper this
/// replaces) - a whole sub-assembly and a single small bolt got an
/// identically-sized manipulator, which read as wrong next to whichever one
/// it actually was sized for. The gizmo's overall size now instead tracks
/// [targetBoundingRadius] - the selected Occurrence's (and, for a
/// sub-assembly, its own descendants') real world-space bounding-sphere
/// radius (`PartScreen._gizmoTargetBoundingRadius`) - at roughly this
/// fraction of it, so a big part gets a big gizmo and a small part a small
/// one, the same "the gizmo is roughly part-sized" convention most CAD
/// tools use. Falls back to the fixed [kComponentGizmoArrowLength] world-
/// unit constant only when no bounding radius is available at all (`null`
/// or non-positive - an empty/placeholder mesh).
const double kComponentGizmoSizeFraction = 2 / 3;

double _componentGizmoArrowLength(double? targetBoundingRadius) =>
    (targetBoundingRadius != null && targetBoundingRadius > 0)
        ? targetBoundingRadius * kComponentGizmoSizeFraction
        : kComponentGizmoArrowLength;

double _componentGizmoRingRadius(double? targetBoundingRadius) =>
    _componentGizmoArrowLength(targetBoundingRadius) * kComponentGizmoRingToArrowRatio;

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
  double radiusPixels = kComponentGizmoHitRadiusPixels,
  double fovRadiansY = kCameraVerticalFovRadians,
  double? targetBoundingRadius,
  ComponentGizmoCues? cues,
}) {
  final arrowLength = _componentGizmoArrowLength(targetBoundingRadius);
  final ringRadius = _componentGizmoRingRadius(targetBoundingRadius);

  ComponentGizmoHit? best;
  double? bestPixelDistance;

  void consider(ComponentGizmoHandleKind kind, vm.Vector3 a, vm.Vector3 b) {
    if (cues != null && cues.isLocked(kind)) return; // a blocked handle cannot be grabbed
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

  double armLength(ComponentGizmoHandleKind kind) =>
      arrowLength * ((cues?.isLocked(kind) ?? false) ? kComponentLockedLengthFactor : 1.0);

  consider(ComponentGizmoHandleKind.translateX, basis.origin,
      basis.origin + basis.xAxis * armLength(ComponentGizmoHandleKind.translateX));
  consider(ComponentGizmoHandleKind.translateY, basis.origin,
      basis.origin + basis.yAxis * armLength(ComponentGizmoHandleKind.translateY));
  consider(ComponentGizmoHandleKind.translateZ, basis.origin,
      basis.origin + basis.zAxis * armLength(ComponentGizmoHandleKind.translateZ));

  void considerRing(ComponentGizmoHandleKind kind, vm.Vector3 axisA, vm.Vector3 axisB) {
    var center = basis.origin;
    final pivot = cues?[kind]?.pivot;
    final pivotAxis = cues?[kind]?.pivotAxis;
    if (pivot != null && pivotAxis != null) {
      center = pivot;
      (axisA, axisB) = perpendicularPair(pivotAxis);
    }
    vm.Vector3 pointAt(double t) => center + (axisA * math.cos(t) + axisB * math.sin(t)) * ringRadius;
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

  // The in-plane handle only wins when no arrow/ring is under the pointer.
  final normal = cues?.planeNormal;
  if (best == null && normal != null) {
    final hit = rayPlaneHit(ray, basis.origin, normal);
    if (hit != null) {
      final (u, v) = componentGizmoPlaneFrame(basis, normal);
      final rel = hit.$2 - basis.origin;
      final a = rel.dot(u) / arrowLength, b = rel.dot(v) / arrowLength;
      // A little slack around the drawn square (same spirit as the arrows' pixel radius).
      const lo = kComponentPlaneHandleNear - 0.06, hi = kComponentPlaneHandleFar + 0.06;
      if (a >= lo && a <= hi && b >= lo && b <= hi) {
        best = ComponentGizmoHit(kind: ComponentGizmoHandleKind.translatePlane, rayT: hit.$1);
      }
    }
  }

  return best;
}

final vm.Vector3 _componentGizmoColorX = vm.Vector3(0xE8 / 255, 0x36 / 255, 0x4A / 255);
final vm.Vector3 _componentGizmoColorY = vm.Vector3(0x27 / 255, 0xAE / 255, 0x60 / 255);
final vm.Vector3 _componentGizmoColorZ = vm.Vector3(0x3A / 255, 0x7B / 255, 0xD5 / 255);
final vm.Vector3 _componentGizmoColorPlane = vm.Vector3(0xF1 / 255, 0xC4 / 255, 0x0F / 255);
final vm.Vector3 _componentGizmoColorLocked = vm.Vector3(0.55, 0.55, 0.55);

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
    ComponentGizmoHandleKind.translatePlane => _componentGizmoColorPlane,
  };
  final alpha = highlighted ? 1.0 : 0.85;
  return vm.Vector4(base.x, base.y, base.z, alpha);
}

/// [componentGizmoHandleColor] with the mates' cue applied: locked = grey and faint, partly free = dimmed.
vm.Vector4 componentGizmoCueColor(ComponentGizmoHandleKind kind, ComponentHandleCue? cue, {bool highlighted = false}) {
  if (cue == null || cue.free) return componentGizmoHandleColor(kind, highlighted: highlighted);
  if (cue.locked) {
    return vm.Vector4(_componentGizmoColorLocked.x, _componentGizmoColorLocked.y, _componentGizmoColorLocked.z, 0.5);
  }
  final base = componentGizmoHandleColor(kind, highlighted: highlighted);
  return vm.Vector4(base.x, base.y, base.z, highlighted ? 0.75 : 0.45);
}

/// Builds the [Node] rendering [basis]'s own gizmo - mirrors
/// [buildSectionGizmoNode] exactly (thin [PolylineGeometry] arrows/rings,
/// [AlwaysOnTopMaterial] + `AlphaMode.blend` for the same deterministic-
/// on-top-of-everything draw-order reason that function's own doc comment
/// documents), just with a third arrow and a third ring.
Node buildComponentGizmoNode(
  ComponentGizmoBasis basis, {
  ComponentGizmoHandleKind? highlightedHandle,
  double? targetBoundingRadius,
  ComponentGizmoCues? cues,
}) {
  final primitives = <MeshPrimitive>[];
  final arrowLength = _componentGizmoArrowLength(targetBoundingRadius);
  final ringRadius = _componentGizmoRingRadius(targetBoundingRadius);

  void addArrow(ComponentGizmoHandleKind kind, vm.Vector3 axis) {
    final cue = cues?[kind];
    final length = arrowLength * ((cue?.locked ?? false) ? kComponentLockedLengthFactor : 1.0);
    final tip = basis.origin + axis * length;
    final highlighted = kind == highlightedHandle;
    final material = AlwaysOnTopMaterial()
      ..alphaMode = AlphaMode.blend
      ..baseColorFactor = componentGizmoCueColor(kind, cue, highlighted: highlighted);
    primitives.add(MeshPrimitive(
      PolylineGeometry([basis.origin, tip], width: highlighted ? 5 : 3),
      material,
    ));
  }

  void addRing(ComponentGizmoHandleKind kind, vm.Vector3 axisA, vm.Vector3 axisB) {
    final cue = cues?[kind];
    final highlighted = kind == highlightedHandle;
    var center = basis.origin;
    if (cue?.pivot != null && cue?.pivotAxis != null) {
      // Re-pivoted onto the screw axis the part really turns about.
      center = cue!.pivot!;
      (axisA, axisB) = perpendicularPair(cue.pivotAxis!);
    }
    final radius = ringRadius * ((cue?.locked ?? false) ? kComponentLockedLengthFactor : 1.0);
    final points = <vm.Vector3>[
      for (var i = 0; i <= kComponentGizmoRingSegments; i++)
        center +
            (axisA * math.cos(2 * math.pi * i / kComponentGizmoRingSegments) +
                    axisB * math.sin(2 * math.pi * i / kComponentGizmoRingSegments)) *
                radius,
    ];
    final material = AlwaysOnTopMaterial()
      ..alphaMode = AlphaMode.blend
      ..baseColorFactor = componentGizmoCueColor(kind, cue, highlighted: highlighted);
    primitives.add(MeshPrimitive(PolylineGeometry(points, width: highlighted ? 4 : 2.5), material));
  }

  addArrow(ComponentGizmoHandleKind.translateX, basis.xAxis);
  addArrow(ComponentGizmoHandleKind.translateY, basis.yAxis);
  addArrow(ComponentGizmoHandleKind.translateZ, basis.zAxis);
  addRing(ComponentGizmoHandleKind.rotateX, basis.yAxis, basis.zAxis);
  addRing(ComponentGizmoHandleKind.rotateY, basis.xAxis, basis.zAxis);
  addRing(ComponentGizmoHandleKind.rotateZ, basis.xAxis, basis.yAxis);

  final normal = cues?.planeNormal;
  if (normal != null) {
    final (u, v) = componentGizmoPlaneFrame(basis, normal);
    const lo = kComponentPlaneHandleNear, hi = kComponentPlaneHandleFar;
    vm.Vector3 corner(double a, double b) => basis.origin + u * (a * arrowLength) + v * (b * arrowLength);
    final highlighted = highlightedHandle == ComponentGizmoHandleKind.translatePlane;
    final material = AlwaysOnTopMaterial()
      ..alphaMode = AlphaMode.blend
      ..baseColorFactor = componentGizmoHandleColor(ComponentGizmoHandleKind.translatePlane, highlighted: highlighted);
    primitives.add(MeshPrimitive(
      PolylineGeometry([corner(lo, lo), corner(hi, lo), corner(hi, hi), corner(lo, hi), corner(lo, lo)],
          width: highlighted ? 5 : 3),
      material,
    ));
  }

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

/// Applies a rotate-handle drag: composes [deltaAngleRadians] about
/// [deltaAxis] *onto* the Occurrence's existing rotation
/// ([currentAxis]/[currentAngleDegrees]), rather than replacing it -
/// `q_delta * q_current` (the delta is a *world-space* axis - the object's
/// current, already-rotated local axis, the same "handles follow the
/// entity's own orientation" convention [ComponentGizmoBasis] itself is
/// built from - composed as the rotation applied *after* the existing one,
/// so a rotate-handle drag keeps spinning the object about its own current
/// axis, not a world-fixed one; see this function's own inline doc comment
/// on `qNew` for why the operand order matters here and both orders happen
/// to agree whenever a caller only ever composes rotations about a single
/// shared axis). Returns a new single equivalent axis-angle pair -
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
  // Bug fix ("rotate about one axis, then another - the second rotation
  // turns about an unexpected axis"): [deltaAxis] is always expressed in
  // WORLD-space coordinates - it's [ComponentGizmoBasis.xAxis]/[yAxis]/
  // [zAxis] (or `PartViewport`'s own `basis.xAxis` etc. for a rotate-handle
  // drag), the object's *current*, already-rotated local axis read straight
  // off its placement matrix's own column vectors, not the object's
  // canonical (pre-rotation) body-frame axis. Composing a world-space-axis
  // rotation "on top of" an existing orientation is `qDelta * qCurrent`
  // (apply [qCurrent] first, then [qDelta] - standard extrinsic
  // composition: `(q1*q2)*v*(q1*q2)⁻¹` applies `q2` first, `q1` second, so
  // the *later* rotation is the left-hand operand), not `qCurrent * qDelta`
  // - swapping the operands doesn't merely reorder an already-symmetric
  // case: quaternion multiplication only commutes when both rotations
  // share the same axis (or either is the identity), which every existing
  // `composeRotation` unit test happens to do - a *single* rotation from
  // identity, two rotations about the *same* axis, or a rotation composed
  // with its own exact inverse - so the wrong order passed unnoticed until
  // two genuinely different axes were composed back-to-back (a rotate
  // handle drag starting from a non-identity `currentAxis`/
  // `currentAngleDegrees`, i.e. the *second* rotation in a session, not the
  // first).
  final qNew = qDelta * qCurrent;
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
