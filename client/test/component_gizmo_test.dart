import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:didsa_cad_client/viewport3d/component_gizmo.dart';

void main() {
  const viewportSize = Size(800, 600);

  group('ComponentGizmoBasis.fromMatrix', () {
    test('an identity matrix gives the origin and the standard X/Y/Z axes', () {
      final basis = ComponentGizmoBasis.fromMatrix(vm.Matrix4.identity());
      expect(basis.origin, vm.Vector3(0, 0, 0));
      expect(basis.xAxis, vm.Vector3(1, 0, 0));
      expect(basis.yAxis, vm.Vector3(0, 1, 0));
      expect(basis.zAxis, vm.Vector3(0, 0, 1));
    });

    test('a pure translation moves the origin without touching the axes', () {
      final matrix = vm.Matrix4.identity()..setTranslation(vm.Vector3(5, -2, 10));
      final basis = ComponentGizmoBasis.fromMatrix(matrix);
      expect(basis.origin, vm.Vector3(5, -2, 10));
      expect(basis.xAxis, vm.Vector3(1, 0, 0));
      expect(basis.yAxis, vm.Vector3(0, 1, 0));
      expect(basis.zAxis, vm.Vector3(0, 0, 1));
    });

    test('a 90-degree rotation about Z rotates the X/Y axes but leaves Z alone', () {
      final matrix = vm.Matrix4.compose(vm.Vector3.zero(), vm.Quaternion.axisAngle(vm.Vector3(0, 0, 1), 1.5707963), vm.Vector3(1, 1, 1));
      final basis = ComponentGizmoBasis.fromMatrix(matrix);
      expect(basis.xAxis.x, closeTo(0, 1e-5));
      expect(basis.xAxis.y, closeTo(1, 1e-5));
      expect(basis.zAxis.z, closeTo(1, 1e-5));
    });

    test('axisFor picks the right axis for each handle kind', () {
      final basis = ComponentGizmoBasis.fromMatrix(vm.Matrix4.identity());
      expect(basis.axisFor(ComponentGizmoHandleKind.translateX), basis.xAxis);
      expect(basis.axisFor(ComponentGizmoHandleKind.rotateX), basis.xAxis);
      expect(basis.axisFor(ComponentGizmoHandleKind.translateY), basis.yAxis);
      expect(basis.axisFor(ComponentGizmoHandleKind.rotateY), basis.yAxis);
      expect(basis.axisFor(ComponentGizmoHandleKind.translateZ), basis.zAxis);
      expect(basis.axisFor(ComponentGizmoHandleKind.rotateZ), basis.zAxis);
    });
  });

  group('hitTestComponentGizmo', () {
    final basis = ComponentGizmoBasis.fromMatrix(vm.Matrix4.identity());

    test('a ray crossing the translateZ arrow\'s midpoint hits translateZ', () {
      // Every arrow shares the origin as its own start point, so a ray
      // through the origin itself would be an ambiguous tie between all
      // three - aimed instead at the arrow's own midpoint, well clear of
      // the other two arrows/every ring.
      final ray = vm.Ray.originDirection(vm.Vector3(0, 5, 2.5), vm.Vector3(0, -1, 0));
      final hit = hitTestComponentGizmo(ray, basis, viewportSize);
      expect(hit?.kind, ComponentGizmoHandleKind.translateZ);
    });

    test('a ray crossing the translateX arrow\'s midpoint hits translateX', () {
      final ray = vm.Ray.originDirection(vm.Vector3(2.5, 5, 0), vm.Vector3(0, -1, 0));
      final hit = hitTestComponentGizmo(ray, basis, viewportSize);
      expect(hit?.kind, ComponentGizmoHandleKind.translateX);
    });

    test('a ray through the rotateZ ring (off both other rings\' own planes) hits rotateZ', () {
      // The gizmo's fallback world-scale (no camera/viewport-based sizing
      // supplied) puts the ring at kComponentGizmoRingRadius world units.
      // A point on the ring at 45 degrees has both x!=0 and y!=0, so a
      // ray travelling straight along Z through it never crosses the
      // rotateX ring's own x=0 plane or the rotateY ring's own y=0 plane.
      final r = kComponentGizmoRingRadius * 0.70710678; // r*cos(45)==r*sin(45)
      final ray = vm.Ray.originDirection(vm.Vector3(r, r, -5), vm.Vector3(0, 0, 1));
      final hit = hitTestComponentGizmo(ray, basis, viewportSize);
      expect(hit?.kind, ComponentGizmoHandleKind.rotateZ);
    });

    test('a ray missing every handle entirely returns null', () {
      final ray = vm.Ray.originDirection(vm.Vector3(100, 100, -5), vm.Vector3(0, 0, 1));
      final hit = hitTestComponentGizmo(ray, basis, viewportSize);
      expect(hit, isNull);
    });
  });

  group('composeTranslation', () {
    test('adds the world-space delta to the current translation', () {
      final result = composeTranslation(vm.Vector3(1, 2, 3), vm.Vector3(10, -5, 0));
      expect(result, vm.Vector3(11, -3, 3));
    });
  });

  group('composeRotation', () {
    test('composing a 90-degree delta onto an identity current rotation gives back exactly that 90-degree rotation', () {
      final (axis, angleDegrees) = composeRotation(
        currentAxis: vm.Vector3(0, 0, 0),
        currentAngleDegrees: 0,
        deltaAxis: vm.Vector3(0, 0, 1),
        deltaAngleRadians: 1.5707963267948966, // 90 degrees
      );
      expect(axis.z, closeTo(1, 1e-6));
      expect(angleDegrees, closeTo(90, 1e-3));
    });

    test('composing two 90-degree deltas about the same axis gives 180 degrees total', () {
      final (axis1, angle1) = composeRotation(
        currentAxis: vm.Vector3(0, 0, 0),
        currentAngleDegrees: 0,
        deltaAxis: vm.Vector3(0, 0, 1),
        deltaAngleRadians: 1.5707963267948966,
      );
      final (axis2, angle2) = composeRotation(
        currentAxis: axis1,
        currentAngleDegrees: angle1,
        deltaAxis: vm.Vector3(0, 0, 1),
        deltaAngleRadians: 1.5707963267948966,
      );
      expect(axis2.z.abs(), closeTo(1, 1e-6));
      expect(angle2, closeTo(180, 1e-2));
    });

    test('composing a rotation with its own exact inverse cancels back to the identity representation', () {
      final (axis, angleDegrees) = composeRotation(
        currentAxis: vm.Vector3(0, 0, 1),
        currentAngleDegrees: 90,
        deltaAxis: vm.Vector3(0, 0, 1),
        deltaAngleRadians: -1.5707963267948966, // -90 degrees
      );
      expect(axis, vm.Vector3(0, 0, 1));
      expect(angleDegrees, 0.0);
    });
  });

  group('translateDragDelta', () {
    test('dragging along the X axis from one ray to another gives the world-space distance moved', () {
      final startRay = vm.Ray.originDirection(vm.Vector3(2, 0, -5), vm.Vector3(0, 0, 1));
      final currentRay = vm.Ray.originDirection(vm.Vector3(7, 0, -5), vm.Vector3(0, 0, 1));
      final delta = translateDragDelta(
        dragStartRay: startRay,
        currentRay: currentRay,
        origin: vm.Vector3(0, 0, 0),
        axis: vm.Vector3(1, 0, 0),
      );
      expect(delta.x, closeTo(5, 1e-6));
      expect(delta.y, closeTo(0, 1e-6));
      expect(delta.z, closeTo(0, 1e-6));
    });

    test('no movement between the two rays gives a zero delta', () {
      final ray = vm.Ray.originDirection(vm.Vector3(2, 0, -5), vm.Vector3(0, 0, 1));
      final delta = translateDragDelta(
        dragStartRay: ray,
        currentRay: ray,
        origin: vm.Vector3(0, 0, 0),
        axis: vm.Vector3(1, 0, 0),
      );
      expect(delta.length, closeTo(0, 1e-9));
    });
  });

  group('rotateDragDeltaRadians', () {
    test('dragging a quarter-turn around the rotation plane gives a delta of about pi/2', () {
      final origin = vm.Vector3(0, 0, 0);
      final startRay = vm.Ray.originDirection(vm.Vector3(5, 0, -10), vm.Vector3(0, 0, 1));
      final currentRay = vm.Ray.originDirection(vm.Vector3(0, 5, -10), vm.Vector3(0, 0, 1));
      final delta = rotateDragDeltaRadians(
        dragStartRay: startRay,
        currentRay: currentRay,
        origin: origin,
        rotationAxis: vm.Vector3(0, 0, 1),
        refAxis: vm.Vector3(1, 0, 0),
        perpAxis: vm.Vector3(0, 1, 0),
      );
      expect(delta, isNotNull);
      expect(delta!, closeTo(1.5707963267948966, 1e-3));
    });

    test('a ray parallel to the rotation plane (never hits it) returns null', () {
      final origin = vm.Vector3(0, 0, 0);
      // A ray travelling within the rotation plane itself (perpendicular to
      // the plane's own normal) never intersects it.
      final parallelRay = vm.Ray.originDirection(vm.Vector3(0, 0, 5), vm.Vector3(1, 0, 0));
      final delta = rotateDragDeltaRadians(
        dragStartRay: parallelRay,
        currentRay: parallelRay,
        origin: origin,
        rotationAxis: vm.Vector3(0, 0, 1),
        refAxis: vm.Vector3(1, 0, 0),
        perpAxis: vm.Vector3(0, 1, 0),
      );
      expect(delta, isNull);
    });
  });
}
