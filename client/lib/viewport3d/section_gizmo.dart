import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../api/document_api_client.dart' show MeshDto;
import 'mesh_geometry.dart' show AlwaysOnTopMaterial;
import 'reference_planes.dart' show closedLoopBorderPoints, doubleSidedQuadBuffers;
import 'section_plane.dart';
import 'selection_hit_test.dart' show kSelectionHitRadiusPixels, kCameraVerticalFovRadians;

/// Sectioning Tool - brand-new interactive-gizmo subsystem (see this app's
/// section-tool brief: "nothing like it exists yet... there is no existing
/// gizmo code to extend, only rendering/hit-testing/camera-projection
/// primitives to build on top of"). This file is that subsystem: geometry,
/// screen-space hit-testing, and drag math for a translate+rotate 3D
/// manipulator anchored on the active [SectionPlane]'s own origin/normal.
///
/// World-space half-length of each translation arrow's shaft, and the
/// radius of each rotation ring, used only as a fallback when a caller has
/// no camera position/viewport size to compute [_sectionGizmoWorldScale]'s
/// constant-on-screen-size value from (see that function's own doc
/// comment for the primary sizing rule) - sized to be comfortably tappable
/// at [OrbitCamera]'s default distance without dwarfing a typical Body, the
/// same "large enough to be visible/tappable, not dominating" reasoning
/// `reference_planes.dart`'s own `referencePlaneSize` doc comment gives.
const double kSectionGizmoArrowLength = 6.0;
const double kSectionGizmoRingRadius = 4.5;

/// Desired constant on-screen size (in screen pixels) for the translate-
/// arrow half-length and rotation-ring radius respectively - see
/// [_sectionGizmoWorldScale]'s own doc comment.
const double kSectionGizmoArrowLengthPixels = 90.0;
const double kSectionGizmoRingRadiusPixels = 70.0;

/// Number of straight segments approximating each rotation ring, both for
/// rendering (a closed [PolylineGeometry] loop) and for hit-testing (see
/// [hitTestSectionGizmo]'s own doc comment on why a true ray-vs-torus test
/// isn't used) - high enough that the polygonal approximation is visually
/// indistinguishable from a circle at this gizmo's on-screen size.
const int kSectionGizmoRingSegments = 48;

/// Which part of the gizmo a drag or hit-test targets. Rotation about the
/// plane's own normal (local Z) is deliberately omitted - see this file's
/// own module doc comment below for why - so there is no `rotateZ` alongside
/// [rotateX]/[rotateY]. Lateral [translateX]/[translateY] handles were
/// removed (on-device feedback: "the section plane can be translated in
/// directions other than its normal, this is unnecessary as the section is
/// infinite in width and height, it should only move along its normal and
/// rotate about 2 axes") - the plane's own infinite extent means an in-
/// plane translation is a visual no-op (it never changes which geometry the
/// section cuts through), so only [translateZ] (along the normal) remains.
enum SectionGizmoHandleKind { translateZ, rotateX, rotateY }

/// The plane's own local orthonormal frame the gizmo is drawn/dragged
/// against: [zAxis] is always the plane's real normal (the translate-Z arrow
/// and the actual cutting direction coincide), [xAxis]/[yAxis] are the same
/// deterministic in-plane basis [arbitraryPerpendicularBasis] gives the
/// backend's own resolved custom planes, so the gizmo's in-plane orientation
/// never spins unpredictably between rebuilds of the same normal.
class SectionGizmoBasis {
  final vm.Vector3 xAxis;
  final vm.Vector3 yAxis;
  final vm.Vector3 zAxis;

  const SectionGizmoBasis({required this.xAxis, required this.yAxis, required this.zAxis});
}

SectionGizmoBasis sectionGizmoBasis(vm.Vector3 normal) {
  final n = normal.normalized();
  final (x, y) = arbitraryPerpendicularBasis(n);
  return SectionGizmoBasis(xAxis: x, yAxis: y, zAxis: n);
}

/// Design decision (documented per the brief's own "your call, document the
/// decision either way"): rotation about the plane's own normal has **no**
/// effect on the actual cut - an infinite plane is fully described by a
/// point plus a normal, and spinning around that normal leaves both
/// unchanged - so a `rotateZ` ring would only ever spin the *cosmetic*
/// quad/gizmo orientation, never the geometry sent to the backend. Per the
/// brief's own "optional/skippable... your call", this omits it entirely
/// rather than building a handle that visibly does something (the quad
/// rotates) but is a no-op on the one thing this tool actually exists to
/// control - a purely cosmetic control here would be more likely to
/// confuse a user ("why doesn't this look like it did anything to the cut")
/// than to help.
const bool kSectionGizmoOmitsRotateZByDesign = true;

/// Analytic closest-point-of-approach between an infinite ray and an
/// infinite line - the [rayT]/[lineT] pair minimizing the distance between
/// `ray.origin + rayT * ray.direction` and `lineOrigin + lineT * lineDir`.
/// Null when the two are (numerically) parallel, the one case with no
/// unique closest pair.
///
/// Standard skew-line closest-point derivation (`ray.direction`/[lineDir]
/// both taken as unit vectors here, so the `a`/`c` coefficients below are
/// both exactly 1): let `r = ray.origin - lineOrigin`, `b = d1.dot(d2)`,
/// `d = d1.dot(r)`, `e = d2.dot(r)`; `lineT = (e - b*d) / (1 - b*b)`,
/// `rayT = (b*e - d) / (1 - b*b)`.
(double rayT, double lineT)? _closestApproach(vm.Ray ray, vm.Vector3 lineOrigin, vm.Vector3 lineDir) {
  final d1 = ray.direction.normalized();
  final d2 = lineDir.normalized();
  final r = ray.origin - lineOrigin;
  final b = d1.dot(d2);
  final denom = 1 - b * b;
  if (denom.abs() < 1e-9) return null; // Parallel - no unique closest pair.
  final d = d1.dot(r);
  final e = d2.dot(r);
  final lineT = (e - b * d) / denom;
  final rayT = (b * e - d) / denom;
  return (rayT, lineT);
}

/// The point on the infinite line through [lineOrigin] along [lineDir]
/// closest to [ray] - the translate-handle drag math's own core primitive:
/// projecting the cursor's screen ray onto the world-space axis the handle
/// is constrained to. Falls back to [lineOrigin] itself (no movement) for a
/// ray parallel to the line (looking straight down the axis being dragged -
/// genuinely no well-defined drag position exists at that exact angle).
vm.Vector3 closestPointOnLineToRay(vm.Ray ray, vm.Vector3 lineOrigin, vm.Vector3 lineDir) {
  final approach = _closestApproach(ray, lineOrigin, lineDir);
  if (approach == null) return lineOrigin;
  return lineOrigin + lineDir.normalized() * approach.$2;
}

/// The angle (radians, `atan2` convention) of [ray]'s intersection with the
/// plane through [planeOrigin] normal to [planeNormal], measured from
/// [refAxis] (angle 0) towards [perpAxis] (angle +90 degrees) - both
/// expected perpendicular to [planeNormal] and to each other. Null if the
/// ray misses the plane (near-parallel, or would hit behind the camera) or
/// lands exactly on [planeOrigin] (an undefined angle). This is the
/// rotate-handle drag math's own core primitive - mirrors
/// `hitTestReferencePlanes`'/`hitTestCreatePlanes`' own ray-vs-plane
/// algebra, just also reporting the in-plane angle instead of only the hit
/// point.
double? angleOnRotationPlane(
  vm.Ray ray,
  vm.Vector3 planeOrigin,
  vm.Vector3 planeNormal,
  vm.Vector3 refAxis,
  vm.Vector3 perpAxis,
) {
  final denom = ray.direction.dot(planeNormal);
  if (denom.abs() < 1e-9) return null;
  final t = (planeOrigin - ray.origin).dot(planeNormal) / denom;
  if (t < 0) return null;
  final local = ray.at(t) - planeOrigin;
  final x = local.dot(refAxis);
  final y = local.dot(perpAxis);
  if (x.abs() < 1e-9 && y.abs() < 1e-9) return null;
  return math.atan2(y, x);
}

/// [selection_hit_test.dart]'s own private `_worldUnitsPerPixelAtDepth` -
/// duplicated rather than shared (that helper isn't exported, and this
/// codebase's own documented convention - see `docs/live-preview-pattern.md`
/// on `_filletPreviewMesh`/`_chamferPreviewMesh` - is to duplicate small
/// per-consumer helpers like this rather than thread a new shared export
/// through an already-large file for one extra caller).
double _worldUnitsPerPixelAtDepth(double depth, Size viewportSize) {
  if (viewportSize.height <= 0) return double.infinity;
  final worldHeightAtDepth = 2 * depth * math.tan(kCameraVerticalFovRadians / 2);
  return worldHeightAtDepth / viewportSize.height;
}

/// On-device feedback ("the cutting plane is too small... should be sized
/// relative to the geometry on screen" / "the triad should remain centred
/// on screen so the user can always access it"): the gizmo/plane-quad used
/// to be sized by a single flat world-space constant
/// ([kSectionGizmoArrowLength] etc.) - correctly tappable at the default
/// zoom, but shrinking to an unusable sliver once the user zoomed out (or
/// dwarfing the model once zoomed in very close), since its *world-space*
/// size never adapted to the camera's current distance from the plane.
///
/// This computes the world-space size that reads as a constant
/// [desiredScreenPixels] on screen at [planeOrigin]'s own depth from
/// [cameraPosition] - the standard "constant apparent size" technique
/// every CAD manipulator uses, built from [_worldUnitsPerPixelAtDepth] (the
/// same primitive [hitTestSectionGizmo] already uses for its own tap
/// tolerance). The gizmo's *position* still tracks [planeOrigin] through
/// pan/orbit exactly as before (this only scales its size, never
/// repositions it) - dragging still resolves against real world-space
/// geometry, unlike the orientation-only 2D `triad.dart` compass overlay,
/// which this deliberately does not imitate (see this file's own module
/// doc comment on why a draggable 3D manipulator needs a different
/// technique).
///
/// Falls back to [fallbackWorldUnits] whenever [cameraPosition]/
/// [viewportSize] aren't available (kept optional so existing callers -
/// and tests - that only care about the gizmo's shape, not its on-screen
/// size, don't need to supply a camera) or the plane sits exactly at the
/// camera (a zero/negative depth has no meaningful on-screen size to solve
/// for).
double _sectionGizmoWorldScale({
  required double desiredScreenPixels,
  required double fallbackWorldUnits,
  required vm.Vector3 planeOrigin,
  vm.Vector3? cameraPosition,
  Size? viewportSize,
}) {
  if (cameraPosition == null || viewportSize == null || viewportSize.height <= 0) {
    return fallbackWorldUnits;
  }
  final depth = (planeOrigin - cameraPosition).length;
  if (depth <= 0) return fallbackWorldUnits;
  return desiredScreenPixels * _worldUnitsPerPixelAtDepth(depth, viewportSize);
}

/// [selection_hit_test.dart]'s own private `_closestRaySegmentDistance`,
/// duplicated for the same reason as [_worldUnitsPerPixelAtDepth] above -
/// returns `(rayT, worldDistance)` for the closest approach between [ray]
/// and the segment [segStart]->[segEnd], or null for a segment behind the
/// ray or (near-)parallel to it (no meaningful single closest point).
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

/// Rotates [v] by [angleRadians] around unit [axis], via Rodrigues' rotation
/// formula - `v*cos(a) + (axis x v)*sin(a) + axis*(axis.v)*(1 - cos(a))` -
/// rather than `vector_math`'s own `Quaternion`: this package's exact
/// `Quaternion` construction/rotation API isn't exercised anywhere else in
/// this codebase to confirm its axis/angle sign convention against, and this
/// closed-form formula is both a well-known, independently-verifiable
/// primitive and just as cheap per call. Used by the rotate-handle drag math
/// to tilt a [SectionPlane]'s normal by the drag's own accumulated angle
/// delta around a fixed (frozen-at-drag-start) rotation axis.
vm.Vector3 rotateAroundAxis(vm.Vector3 v, vm.Vector3 axis, double angleRadians) {
  final a = axis.normalized();
  final cosA = math.cos(angleRadians);
  final sinA = math.sin(angleRadians);
  final term1 = v * cosA;
  final term2 = a.cross(v) * sinA;
  final term3 = a * (a.dot(v) * (1 - cosA));
  return term1 + term2 + term3;
}

/// One handle hit: which [SectionGizmoHandleKind], and how far along the ray
/// ([rayT]) - lets [hitTestSectionGizmo]'s caller depth-compare this against
/// an ordinary face/edge hit the same way [ReferencePlaneHit.rayT] already
/// does for reference planes.
class SectionGizmoHit {
  final SectionGizmoHandleKind kind;
  final double rayT;

  const SectionGizmoHit({required this.kind, required this.rayT});
}

/// Pure ray-vs-gizmo hit-test for [plane]'s own gizmo (see
/// [sectionGizmoBasis]) - the three translation arrows as ray-vs-segment
/// (a straight shaft has no meaningful "cylinder radius" concept beyond the
/// same screen-space pixel tolerance every other thin-geometry hit-test in
/// this app already uses - `hitTestEdges`' own ray-vs-segment test is the
/// direct precedent, not a simplification unique to this gizmo), and the two
/// rotation rings as ray-vs-many-segments (the brief's own "a reasonable
/// line-segment-ring approximation" alternative to a true ray-vs-torus test
/// - a full torus intersection is exact but only matters at a scale far
/// below this hit radius's own screen-space tolerance). Returns the closest
/// (smallest screen-space pixel distance, ties broken by nearest [rayT]) hit
/// within [radiusPixels], or null.
SectionGizmoHit? hitTestSectionGizmo(
  vm.Ray ray,
  SectionPlane plane,
  Size viewportSize, {
  double radiusPixels = kSelectionHitRadiusPixels,
  vm.Vector3? cameraPosition,
}) {
  final basis = sectionGizmoBasis(plane.normal);
  // Must match whatever [buildSectionGizmoNode] actually rendered for this
  // same [plane]/[cameraPosition]/[viewportSize] - see
  // [_sectionGizmoWorldScale]'s own doc comment; otherwise the tappable
  // area and the drawn gizmo drift apart as the camera moves.
  final arrowLength = _sectionGizmoWorldScale(
    desiredScreenPixels: kSectionGizmoArrowLengthPixels,
    fallbackWorldUnits: kSectionGizmoArrowLength,
    planeOrigin: plane.origin,
    cameraPosition: cameraPosition,
    viewportSize: viewportSize,
  );
  final ringRadius = _sectionGizmoWorldScale(
    desiredScreenPixels: kSectionGizmoRingRadiusPixels,
    fallbackWorldUnits: kSectionGizmoRingRadius,
    planeOrigin: plane.origin,
    cameraPosition: cameraPosition,
    viewportSize: viewportSize,
  );
  SectionGizmoHit? best;
  double? bestPixelDistance;

  void consider(SectionGizmoHandleKind kind, vm.Vector3 a, vm.Vector3 b) {
    final closest = _closestRaySegmentDistance(ray, a, b);
    if (closest == null) return;
    final (rayT, worldDistance) = closest;
    final pixelDistance = worldDistance / _worldUnitsPerPixelAtDepth(rayT, viewportSize);
    if (pixelDistance > radiusPixels) return;
    if (bestPixelDistance == null || pixelDistance < bestPixelDistance!) {
      bestPixelDistance = pixelDistance;
      best = SectionGizmoHit(kind: kind, rayT: rayT);
    }
  }

  consider(SectionGizmoHandleKind.translateZ, plane.origin, plane.origin + basis.zAxis * arrowLength);

  void considerRing(SectionGizmoHandleKind kind, vm.Vector3 axisA, vm.Vector3 axisB) {
    vm.Vector3 pointAt(double t) =>
        plane.origin + (axisA * math.cos(t) + axisB * math.sin(t)) * ringRadius;
    var previous = pointAt(0);
    for (var i = 1; i <= kSectionGizmoRingSegments; i++) {
      final t = 2 * math.pi * i / kSectionGizmoRingSegments;
      final current = pointAt(t);
      consider(kind, previous, current);
      previous = current;
    }
  }

  // rotateX tilts the plane about the local X axis, so its ring sweeps the
  // Y/Z plane; rotateY sweeps X/Z - each ring always omits the axis it
  // rotates about, the usual CAD-gizmo convention.
  considerRing(SectionGizmoHandleKind.rotateX, basis.yAxis, basis.zAxis);
  considerRing(SectionGizmoHandleKind.rotateY, basis.xAxis, basis.zAxis);

  return best;
}

/// The same X=red/Y=green/Z=blue axis-color RGB triples `triad.dart`'s own
/// `triadColorX`/`Y`/`Z` use, as [vm.Vector3] (0..1 channels) directly -
/// deliberately not derived from `triad.dart`'s `Color` constants:
/// `view_preferences.dart`'s own `colorFromHex`/`vector4FromHex` doc
/// comments flag that decomposing an existing [Color]'s channels (`.r`/
/// `.g`/`.b` vs. `.red`/`.green`/`.blue`) is unsafe across Flutter SDK
/// versions in this codebase's lockfile - so, like those two functions,
/// this only ever *constructs* a color/vector from a literal, never reads
/// channels back off a [Color] instance.
final vm.Vector3 _sectionGizmoColorX = vm.Vector3(0xE8 / 255, 0x36 / 255, 0x4A / 255);
final vm.Vector3 _sectionGizmoColorY = vm.Vector3(0x27 / 255, 0xAE / 255, 0x60 / 255);
final vm.Vector3 _sectionGizmoColorZ = vm.Vector3(0x3A / 255, 0x7B / 255, 0xD5 / 255);

/// The color each handle renders/highlights with - arrows follow this app's
/// existing X=red/Y=green/Z=blue axis convention (`triad.dart`); a rotation
/// ring has no single "axis" color of its own the way an arrow does, so
/// [rotateX]/[rotateY] instead borrow the arrow color of the axis they
/// rotate *about* (X/Y respectively) - keeps the ring's own color
/// meaningfully tied to "which axis this tilts around" rather than an
/// arbitrary third color.
vm.Vector4 sectionGizmoHandleColor(SectionGizmoHandleKind kind, {bool highlighted = false}) {
  final base = switch (kind) {
    SectionGizmoHandleKind.rotateX => _sectionGizmoColorX,
    SectionGizmoHandleKind.rotateY => _sectionGizmoColorY,
    SectionGizmoHandleKind.translateZ => _sectionGizmoColorZ,
  };
  final alpha = highlighted ? 1.0 : 0.85;
  return vm.Vector4(base.x, base.y, base.z, alpha);
}

/// Builds the [Node] rendering [plane]'s gizmo - three translate arrows plus
/// two rotate rings, all as [PolylineGeometry] (this app's existing
/// thin-line-overlay primitive - `reference_planes.dart`'s own border
/// outline is the same technique) rather than true 3D cylinder/torus solids.
/// Deliberate simplification: a real arrowhead cone/torus mesh would need
/// its own triangulation code with no reuse in this codebase, for a purely
/// cosmetic improvement over a thicker-width colored line - the *tappable*
/// area is governed by [hitTestSectionGizmo]'s own generous screen-space
/// tolerance regardless of how the handle is drawn, so this keeps the
/// gizmo's node-building cheap (rebuilt every frame while dragging) without
/// losing any interactivity. [highlightedHandle] (the handle currently
/// hovered/dragged, if any) renders with a thicker line and full opacity -
/// see [sectionGizmoHandleColor].
Node buildSectionGizmoNode(
  SectionPlane plane, {
  SectionGizmoHandleKind? highlightedHandle,
  vm.Vector3? cameraPosition,
  Size? viewportSize,
}) {
  final basis = sectionGizmoBasis(plane.normal);
  final primitives = <MeshPrimitive>[];
  // See [_sectionGizmoWorldScale]'s own doc comment - keeps this in sync
  // with [hitTestSectionGizmo]'s identical computation for the same
  // [plane]/[cameraPosition]/[viewportSize].
  final arrowLength = _sectionGizmoWorldScale(
    desiredScreenPixels: kSectionGizmoArrowLengthPixels,
    fallbackWorldUnits: kSectionGizmoArrowLength,
    planeOrigin: plane.origin,
    cameraPosition: cameraPosition,
    viewportSize: viewportSize,
  );
  final ringRadius = _sectionGizmoWorldScale(
    desiredScreenPixels: kSectionGizmoRingRadiusPixels,
    fallbackWorldUnits: kSectionGizmoRingRadius,
    planeOrigin: plane.origin,
    cameraPosition: cameraPosition,
    viewportSize: viewportSize,
  );

  void addArrow(SectionGizmoHandleKind kind, vm.Vector3 axis) {
    final tip = plane.origin + axis * arrowLength;
    final highlighted = kind == highlightedHandle;
    // On-device feedback ("can't see the [triad]"): AlwaysOnTopMaterial
    // instead of the normal depth-tested UnlitMaterial - this manipulator
    // must never be occluded by a Body, unlike an ordinary highlight (see
    // that class's own doc comment, `mesh_geometry.dart`).
    final material = AlwaysOnTopMaterial()
      ..alphaMode = AlphaMode.opaque
      ..baseColorFactor = sectionGizmoHandleColor(kind, highlighted: highlighted);
    primitives.add(MeshPrimitive(
      PolylineGeometry([plane.origin, tip], width: highlighted ? 5 : 3),
      material,
    ));
  }

  void addRing(SectionGizmoHandleKind kind, vm.Vector3 axisA, vm.Vector3 axisB) {
    final highlighted = kind == highlightedHandle;
    final points = <vm.Vector3>[
      for (var i = 0; i <= kSectionGizmoRingSegments; i++)
        plane.origin +
            (axisA * math.cos(2 * math.pi * i / kSectionGizmoRingSegments) +
                    axisB * math.sin(2 * math.pi * i / kSectionGizmoRingSegments)) *
                ringRadius,
    ];
    final material = AlwaysOnTopMaterial()
      ..alphaMode = AlphaMode.opaque
      ..baseColorFactor = sectionGizmoHandleColor(kind, highlighted: highlighted);
    primitives.add(MeshPrimitive(PolylineGeometry(points, width: highlighted ? 4 : 2.5), material));
  }

  addArrow(SectionGizmoHandleKind.translateZ, basis.zAxis);
  addRing(SectionGizmoHandleKind.rotateX, basis.yAxis, basis.zAxis);
  addRing(SectionGizmoHandleKind.rotateY, basis.xAxis, basis.zAxis);

  return Node(name: 'section-gizmo-${plane.id}', mesh: Mesh.primitives(primitives: primitives));
}

const double _sectionPlaneQuadHalfSize = 12.0;
const double _sectionPlaneAlpha = 0.22;
const double _sectionPlaneActiveAlpha = 0.4;
final vm.Vector3 _sectionPlaneBaseColor = vm.Vector3(0xB8 / 255, 0x3A / 255, 0xD5 / 255);

/// Desired constant on-screen half-size (screen pixels) for the plane
/// quad - see [_sectionGizmoWorldScale]'s own doc comment; [buildSectionPlaneQuadNode]
/// otherwise falls back to [_sectionPlaneQuadHalfSize] unchanged.
const double kSectionPlaneQuadHalfSizePixels = 150.0;

/// Builds the [Node] rendering [plane]'s own bounded quad - a double-sided
/// translucent fill plus an opaque border, the exact same two-primitive
/// technique `reference_planes.dart`'s `buildReferencePlaneNode` uses (see
/// that function's own doc comment for why the fill needs the double-sided
/// vertex duplication trick at all). Sized via [_sectionGizmoWorldScale] to
/// read as a constant [kSectionPlaneQuadHalfSizePixels] on screen regardless
/// of zoom (on-device feedback: "the cutting plane is too small... should
/// be sized relative to the geometry on screen") when [cameraPosition]/
/// [viewportSize] are supplied, falling back to the flat
/// [_sectionPlaneQuadHalfSize] otherwise. This is still not the target
/// Body's real bounding box - this app's [BodyMeshDto] doesn't carry a
/// precomputed AABB today, and deriving one here would mean walking every
/// triangle of every enabled Body on every gizmo-drag frame - a real
/// per-Body AABB (already computed for the "recentre" camera fit - see
/// `PartViewport._doRecentre`) would be the natural follow-up if a
/// constant-screen-size quad still proves too small/large against a
/// particular Body in practice.
Node buildSectionPlaneQuadNode(
  SectionPlane plane, {
  bool active = false,
  vm.Vector3? cameraPosition,
  Size? viewportSize,
}) {
  final basis = sectionGizmoBasis(plane.normal);
  final alpha = active ? _sectionPlaneActiveAlpha : _sectionPlaneAlpha;
  final halfSize = _sectionGizmoWorldScale(
    desiredScreenPixels: kSectionPlaneQuadHalfSizePixels,
    fallbackWorldUnits: _sectionPlaneQuadHalfSize,
    planeOrigin: plane.origin,
    cameraPosition: cameraPosition,
    viewportSize: viewportSize,
  );

  // AlwaysOnTopMaterial for both primitives - same "must never be occluded
  // by a Body" reasoning as [buildSectionGizmoNode]'s own arrows/rings.
  final fillMaterial = AlwaysOnTopMaterial()
    ..alphaMode = AlphaMode.blend
    ..baseColorFactor = vm.Vector4(_sectionPlaneBaseColor.x, _sectionPlaneBaseColor.y, _sectionPlaneBaseColor.z, alpha);
  final fillBuffers = doubleSidedQuadBuffers(halfSize);
  final fillGeometry = MeshGeometry.fromArrays(
    positions: fillBuffers.positions,
    normals: fillBuffers.normals,
    indices: fillBuffers.indices,
  );

  final borderMaterial = AlwaysOnTopMaterial()
    ..alphaMode = AlphaMode.opaque
    ..baseColorFactor = vm.Vector4(_sectionPlaneBaseColor.x, _sectionPlaneBaseColor.y, _sectionPlaneBaseColor.z, 1.0);
  final borderGeometry = PolylineGeometry(closedLoopBorderPoints(halfSize), width: 2.0);

  // doubleSidedQuadBuffers/closedLoopBorderPoints are built flat in local
  // XZ, facing +Y - reuse [createPlaneTransform]'s exact same column-matrix
  // construction (xAxis -> local X, normal -> local Y, yAxis -> local Z) so
  // this quad orients identically to how a resolved custom Plane already
  // does, rather than re-deriving an equivalent transform.
  final transform = vm.Matrix4.columns(
    vm.Vector4(basis.xAxis.x, basis.xAxis.y, basis.xAxis.z, 0),
    vm.Vector4(basis.zAxis.x, basis.zAxis.y, basis.zAxis.z, 0),
    vm.Vector4(basis.yAxis.x, basis.yAxis.y, basis.yAxis.z, 0),
    vm.Vector4(plane.origin.x, plane.origin.y, plane.origin.z, 1),
  );

  return Node(
    name: 'section-plane-${plane.id}',
    localTransform: transform,
    mesh: Mesh.primitives(primitives: [
      MeshPrimitive(fillGeometry, fillMaterial),
      MeshPrimitive(borderGeometry, borderMaterial),
    ]),
  );
}

/// Whether world point [p] sits on the *kept* (not clipped away) side of
/// one enabled [SectionPlane] - `dot(p - origin, normal) >= 0`, inverted by
/// [SectionPlane.flipped], matching this tool's own backend contract
/// (`POST .../section-preview`'s `flipped` field "inverts which side of
/// that one plane is kept").
bool _isKeptBySinglePlane(vm.Vector3 p, SectionPlane plane) {
  final side = (p - plane.origin).dot(plane.normal);
  return plane.flipped ? side <= 0 : side >= 0;
}

/// The fast, momentary "cheap approximate clip" this app's section-tool
/// brief calls for during an active gizmo drag: discards every triangle of
/// [mesh] whose centroid falls on the clipped-away side of *any* enabled
/// plane in [planes] (multiple planes combine by intersection - a triangle
/// survives only if it's kept by every one of them, matching the accurate
/// backend endpoint's own AND-combination contract), producing an open/
/// uncapped cross-section - acceptable per the brief ("an open/uncapped
/// look during the drag is fine, it's momentary"), since the accurate,
/// properly-capped backend result swaps back in the moment the drag ends
/// (see `PartScreen._refreshSectionPreview`/`docs/live-preview-pattern.md`'s
/// debounce shape).
///
/// Deliberately a per-triangle centroid test, not a real triangle-plane
/// clip (which would need to *cut* triangles straddling a plane and
/// generate new vertices along the seam) - a discard-only test is
/// dramatically cheaper (no new geometry, just a filter over the existing
/// triangle list) and, for a mesh with any reasonable tessellation density,
/// visually indistinguishable from a true clip at the boundary during a
/// drag the user is actively watching move, not stopping to inspect the cut
/// edge itself. [mesh.vertices]/[normals] are left untouched (every backend
/// [MeshDto] triangle owns its own 3 unique vertices - see
/// `mesh_geometry.dart`'s own `meshBuffersFromMesh` doc comment - so
/// dropping triangles never needs to renumber or compact the vertex arrays,
/// just filter which triangles/faceIds/edges are kept); [edges] (the
/// wireframe overlay) is left entirely unfiltered - clipping it too would
/// double this function's own per-frame cost for a wireframe that is hidden
/// in every render mode except Shaded+Edges, a smaller, deliberately-accepted
/// visual rough edge during the same momentary window.
MeshDto approximateClipMesh(MeshDto mesh, List<SectionPlane> planes) {
  final enabled = planes.where((p) => p.enabled).toList();
  if (enabled.isEmpty) return mesh;

  final keptTriangles = <List<int>>[];
  final keptFaceIds = <int>[];
  final hasFaceIds = mesh.faceIds.length == mesh.triangleIndices.length;

  for (var i = 0; i < mesh.triangleIndices.length; i++) {
    final tri = mesh.triangleIndices[i];
    final a = mesh.vertices[tri[0]];
    final b = mesh.vertices[tri[1]];
    final c = mesh.vertices[tri[2]];
    final centroid = vm.Vector3(
      (a[0] + b[0] + c[0]) / 3,
      (a[1] + b[1] + c[1]) / 3,
      (a[2] + b[2] + c[2]) / 3,
    );
    final kept = enabled.every((plane) => _isKeptBySinglePlane(centroid, plane));
    if (!kept) continue;
    keptTriangles.add(tri);
    if (hasFaceIds) keptFaceIds.add(mesh.faceIds[i]);
  }

  return MeshDto(
    vertices: mesh.vertices,
    normals: mesh.normals,
    triangleIndices: keptTriangles,
    edges: mesh.edges,
    faceIds: hasFaceIds ? keptFaceIds : mesh.faceIds,
    edgeIds: mesh.edgeIds,
    topologyVertices: mesh.topologyVertices,
    topologyVertexIds: mesh.topologyVertexIds,
    faceEdgeIds: mesh.faceEdgeIds,
    faceIsPlanar: mesh.faceIsPlanar,
  );
}

/// Splits [mesh]'s triangles into (everything else, only the cut-cap faces)
/// by [SectionPreviewResultDto.cutFaceIds] membership - the accurate
/// backend section result's own rendering needs two differently-colored
/// [MeshPrimitive]s sharing one [Node] (standard CAD section-view
/// convention: the cut faces get a visually distinct flat color from the
/// rest of the body), and `flutter_scene`'s [MeshPrimitive] only ever takes
/// one [Material] each - a single mixed-color mesh isn't expressible as one
/// primitive. [mesh.vertices]/[normals] are shared, untouched, by both
/// halves (same "no vertex renumbering needed" reasoning as
/// [approximateClipMesh]'s own doc comment) - only which triangles/faceIds
/// each keeps differs.
(MeshDto body, MeshDto cutCaps) splitMeshByCutFaces(MeshDto mesh, Set<int> cutFaceIds) {
  if (cutFaceIds.isEmpty || mesh.faceIds.length != mesh.triangleIndices.length) {
    return (
      mesh,
      MeshDto(vertices: mesh.vertices, normals: mesh.normals, triangleIndices: const []),
    );
  }

  final bodyTriangles = <List<int>>[];
  final bodyFaceIds = <int>[];
  final capTriangles = <List<int>>[];
  final capFaceIds = <int>[];

  for (var i = 0; i < mesh.triangleIndices.length; i++) {
    final faceId = mesh.faceIds[i];
    if (cutFaceIds.contains(faceId)) {
      capTriangles.add(mesh.triangleIndices[i]);
      capFaceIds.add(faceId);
    } else {
      bodyTriangles.add(mesh.triangleIndices[i]);
      bodyFaceIds.add(faceId);
    }
  }

  MeshDto rebuild(List<List<int>> triangles, List<int> faceIds) => MeshDto(
        vertices: mesh.vertices,
        normals: mesh.normals,
        triangleIndices: triangles,
        edges: mesh.edges,
        faceIds: faceIds,
        edgeIds: mesh.edgeIds,
        topologyVertices: mesh.topologyVertices,
        topologyVertexIds: mesh.topologyVertexIds,
        faceEdgeIds: mesh.faceEdgeIds,
        faceIsPlanar: mesh.faceIsPlanar,
      );

  return (rebuild(bodyTriangles, bodyFaceIds), rebuild(capTriangles, capFaceIds));
}
