import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:didsa_cad_client/viewport3d/component_gizmo.dart';
import 'package:didsa_cad_client/viewport3d/selection_hit_test.dart' show kCameraVerticalFovRadians;

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

  group('S8 cues: locked / partial handles, re-pivoted ring, in-plane handle', () {
    final basis = ComponentGizmoBasis.fromMatrix(vm.Matrix4.identity());
    const free = ComponentHandleCue(1.0);
    const partial = ComponentHandleCue(0.4);
    const locked = ComponentHandleCue(0.0);

    test('a locked handle cannot be grabbed; free and partly free ones can', () {
      final ray = vm.Ray.originDirection(vm.Vector3(0, 5, 4.2), vm.Vector3(0, -1, 0)); // clear of every ring
      expect(hitTestComponentGizmo(ray, basis, viewportSize)?.kind, ComponentGizmoHandleKind.translateZ);
      for (final cue in [free, partial]) {
        final cues = ComponentGizmoCues(handles: {ComponentGizmoHandleKind.translateZ: cue});
        expect(hitTestComponentGizmo(ray, basis, viewportSize, cues: cues)?.kind, ComponentGizmoHandleKind.translateZ);
      }
      final lockedCues = ComponentGizmoCues(handles: {ComponentGizmoHandleKind.translateZ: locked});
      expect(hitTestComponentGizmo(ray, basis, viewportSize, cues: lockedCues), isNull);
    });

    test('a locked arrow is drawn short: the hit-test no longer reaches where the full arrow was', () {
      // Free: hit at z = 4 on the arrow. Locked arrows are also un-grabbable, so check via the partial/free length only.
      final far = vm.Ray.originDirection(vm.Vector3(0, 5, 4.0), vm.Vector3(0, -1, 0));
      expect(hitTestComponentGizmo(far, basis, viewportSize)?.kind, ComponentGizmoHandleKind.translateZ);
      expect(kComponentLockedLengthFactor, lessThan(1.0));
    });

    test('cue colours: free = axis colour, partial = dimmed, locked = grey and faint', () {
      final f = componentGizmoCueColor(ComponentGizmoHandleKind.translateX, free);
      final p = componentGizmoCueColor(ComponentGizmoHandleKind.translateX, partial);
      final l = componentGizmoCueColor(ComponentGizmoHandleKind.translateX, locked);
      expect(f, componentGizmoHandleColor(ComponentGizmoHandleKind.translateX));
      expect(p.w, lessThan(f.w));
      expect(p.x, f.x);
      expect(l.x, l.y);
      expect(l.y, l.z);
      expect(l.w, lessThan(f.w));
      expect(componentGizmoCueColor(ComponentGizmoHandleKind.translateX, null), f);
    });

    test('a re-pivoted ring is hit on the screw axis, not at the origin', () {
      final cues = ComponentGizmoCues(handles: {
        ComponentGizmoHandleKind.rotateZ: ComponentHandleCue(1.0, pivot: vm.Vector3(0, 0, 10), pivotAxis: vm.Vector3(0, 0, 1)),
      });
      final atPivot = vm.Ray.originDirection(vm.Vector3(kComponentGizmoRingRadius, -5, 10), vm.Vector3(0, 1, 0));
      expect(hitTestComponentGizmo(atPivot, basis, viewportSize, cues: cues)?.kind, ComponentGizmoHandleKind.rotateZ);
      expect(hitTestComponentGizmo(atPivot, basis, viewportSize), isNull, reason: 'without the cue there is no ring there');
      final atOrigin = vm.Ray.originDirection(vm.Vector3(kComponentGizmoRingRadius * 0.7071, kComponentGizmoRingRadius * 0.7071, -5), vm.Vector3(0, 0, 1));
      // the moved ring lies at z = 10, the ray along z still crosses it; the ring at the origin plane is gone
      final atOriginPlane = vm.Ray.originDirection(vm.Vector3(kComponentGizmoRingRadius, -5, 0), vm.Vector3(0, 1, 0));
      expect(hitTestComponentGizmo(atOriginPlane, basis, viewportSize, cues: cues)?.kind, isNot(ComponentGizmoHandleKind.rotateZ));
      expect(hitTestComponentGizmo(atOrigin, basis, viewportSize, cues: cues), isNotNull);
    });

    test('in-plane handle: hit inside its square when no arrow/ring is nearer, absent without a plane normal', () {
      final cues = ComponentGizmoCues(planeNormal: vm.Vector3(0, 0, 1));
      final ray = vm.Ray.originDirection(vm.Vector3(2, 2, 5), vm.Vector3(0, 0, -1));
      expect(hitTestComponentGizmo(ray, basis, viewportSize, cues: cues)?.kind, ComponentGizmoHandleKind.translatePlane);
      expect(hitTestComponentGizmo(ray, basis, viewportSize), isNull);
      final outside = vm.Ray.originDirection(vm.Vector3(0.3, 0.3, 5), vm.Vector3(0, 0, -1));
      expect(hitTestComponentGizmo(outside, basis, viewportSize, cues: cues)?.kind, isNot(ComponentGizmoHandleKind.translatePlane),
          reason: 'inside the near corner gap');
    });

    test('plane frame is orthonormal, in the plane, and follows the gizmo x axis', () {
      final (u, v) = componentGizmoPlaneFrame(basis, vm.Vector3(0, 0, 1));
      expect(u.dot(vm.Vector3(0, 0, 1)), closeTo(0, 1e-9));
      expect(u.dot(v), closeTo(0, 1e-9));
      expect(u, vm.Vector3(1, 0, 0));
      expect(v, vm.Vector3(0, 1, 0));
    });

    test('rotatePointAboutPivot turns a point about an axis that does not pass through the origin', () {
      final moved = rotatePointAboutPivot(vm.Vector3(0, 0, 0), vm.Vector3(0, 5, 0), vm.Vector3(0, 0, 1), 3.141592653589793 / 2);
      expect(moved.x, closeTo(5, 1e-9));
      expect(moved.y, closeTo(5, 1e-9));
      expect(moved.z, closeTo(0, 1e-9));
      expect(rotatePointAboutPivot(vm.Vector3(1, 2, 3), vm.Vector3(1, 2, 9), vm.Vector3(0, 0, 1), 1.0), vm.Vector3(1, 2, 3));
    });

    test('perpendicularPair is orthonormal for any axis', () {
      for (final n in [vm.Vector3(0, 0, 1), vm.Vector3(1, 0, 0), vm.Vector3(1, 2, 3)]) {
        final (a, b) = perpendicularPair(n);
        expect(a.length, closeTo(1, 1e-6)); // vector_math is float32
        expect(b.length, closeTo(1, 1e-6));
        expect(a.dot(b), closeTo(0, 1e-6));
        expect(a.dot(n.normalized()), closeTo(0, 1e-6));
      }
    });
  });

  group('grab radius', () {
    final basis = ComponentGizmoBasis.fromMatrix(vm.Matrix4.identity());

    test('the gizmo grab radius is wider than a plain selection pick', () {
      expect(kComponentGizmoHitRadiusPixels, greaterThan(2 * 12.5 - 1));
    });

    test('a ray ~20 px beside the translateZ arrow (a miss at the old 12.5 px radius) still grabs it', () {
      // Ray along -y at x offset d from the z arrow, z = 4.2 (clear of every ring), camera-free: world units per pixel at
      // the ray's depth come from the default fov and the 600 px viewport height.
      const depth = 5.0;
      final unitsPerPixel = 2 * depth * math.tan(kCameraVerticalFovRadians / 2) / viewportSize.height;
      final ray = vm.Ray.originDirection(vm.Vector3(20 * unitsPerPixel, 5, 4.2), vm.Vector3(0, -1, 0));
      expect(hitTestComponentGizmo(ray, basis, viewportSize)?.kind, ComponentGizmoHandleKind.translateZ);
      expect(hitTestComponentGizmo(ray, basis, viewportSize, radiusPixels: 12.5), isNull);
    });
  });
}

