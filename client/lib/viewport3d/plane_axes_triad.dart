import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

/// Matches `triad.dart`'s `triadColorX`/`triadColorY` exactly (same hex
/// values) - duplicated here rather than converted from a `Color` because
/// this module is GPU/`vm.Vector4`-typed throughout (mirrors
/// `reference_planes.dart`'s own `_baseColor` doing the identical
/// hex-to-`vm.Vector3` duplication for the same reason).
final vm.Vector4 axesTriadColorX = vm.Vector4(0xE8 / 255, 0x36 / 255, 0x4A / 255, 1.0);
final vm.Vector4 axesTriadColorY = vm.Vector4(0x27 / 255, 0xAE / 255, 0x60 / 255, 1.0);

/// World-space length of each arm - short enough not to dominate a
/// [referencePlaneSize]/`createPlaneSize`-scale plane rectangle, long
/// enough to read as a clear direction (not just a dot) at the default
/// camera distance.
const double axesTriadArmLength = 6.0;
const double axesTriadWidth = 2.5;

/// World-space X/Y axes indicator, one per rendered reference/created plane -
/// the geometric counterpart to `triad.dart`'s screen-space, orientation-only
/// world compass. Where that compass always shows the *world*'s own X/Y/Z,
/// this shows one specific plane's *own* embedded local X/Y axes, drawn at
/// that plane's real position/orientation in the same scene - so the two can
/// be compared directly, by eye, in a single view: does this plane's red
/// arrow point the same way the world compass's red arrow does (it should,
/// for any plane whose local X truly is world-aligned in the way its own
/// code assumes)?
///
/// This is exactly the kind of check `docs/status.md`'s 2026-07-08 entry
/// describes doing by hand, off-app, to track down a left-handed XZ-plane
/// basis (`x_axis` was `(1,0,0)` where a right-handed basis required
/// `(-1,0,0)`, given that plane's own `y_axis`/`normal`) - a bug that read
/// as "the whole 3D model is mirrored" and took several dead-end
/// investigation rounds (glTF up-axis, node transforms, a genuinely
/// mirrored source file) before being isolated. Having this indicator
/// on-screen by default turns that class of bug into something visible at
/// a glance, for every plane (fixed or created) at once, rather than
/// something that has to be independently re-derived from scratch the next
/// time it's suspected.
///
/// Deliberately no Z arm: a Sketch's own local coordinates are always 2D
/// `(x, y)` (see `sketch_geometry_3d.dart`'s `SketchPlaneBasis`) - there is
/// no "local Z" belonging to a plane to calibrate here, only whether X and
/// Y (and so, implicitly, their handedness relative to the plane's normal)
/// are right.
///
/// [xAxis]/[yAxis] are assumed already unit-length and orthonormal
/// (guaranteed by every `ResolvedPlane`/`SketchPlaneBasis` this app
/// produces, fixed or custom alike), so no normalization happens here.
///
/// GPU-bound (`PolylineGeometry`'s own updatable `MeshGeometry`), so - like
/// `buildReferencePlaneNode`/`buildCreatePlaneNode`/`buildSketchGeometryNode`
/// - this cannot be exercised in a headless `flutter test` run.
Node buildAxesTriadNode(
  String name,
  vm.Vector3 origin,
  vm.Vector3 xAxis,
  vm.Vector3 yAxis, {
  double armLength = axesTriadArmLength,
}) {
  final xMaterial = UnlitMaterial()
    ..alphaMode = AlphaMode.opaque
    ..baseColorFactor = axesTriadColorX;
  final yMaterial = UnlitMaterial()
    ..alphaMode = AlphaMode.opaque
    ..baseColorFactor = axesTriadColorY;

  return Node(
    name: 'axes-triad-$name',
    mesh: Mesh.primitives(primitives: [
      MeshPrimitive(
        PolylineGeometry(
          [origin, origin + xAxis * armLength],
          width: axesTriadWidth,
          cap: PolylineCap.round,
        ),
        xMaterial,
      ),
      MeshPrimitive(
        PolylineGeometry(
          [origin, origin + yAxis * armLength],
          width: axesTriadWidth,
          cap: PolylineCap.round,
        ),
        yMaterial,
      ),
    ]),
  );
}
