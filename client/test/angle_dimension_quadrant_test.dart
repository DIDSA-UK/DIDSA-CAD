import 'dart:math' as math;

import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/sketch/angle_rays.dart';
import 'package:didsa_cad_client/sketch/label_drag_resolver.dart';
import 'package:didsa_cad_client/sketch/sketch_controller.dart';
import 'package:didsa_cad_client/viewport3d/orthographic_camera.dart';
import 'package:didsa_cad_client/viewport3d/sketch_constraint_overlay.dart';
import 'package:didsa_cad_client/viewport3d/sketch_geometry_3d.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show Offset, Size;
import 'package:vector_math/vector_math.dart' as vm;

/// Bug report 2026-11-17 item 4: the flange profile's 23.59 deg dimension was drawn as its 156.41 deg supplement, with the label on the
/// chord near the vertex. One ray rule now serves every view (`angle_rays.dart`), a saved quadrant picks the sector, and the label sits on
/// the arc.
void main() {
  const theta = 23.59;
  final t = theta * math.pi / 180;
  // The flange case: line 1 runs straight up from the vertex; line 2 also runs up and to the left (start to end), but its segment lies on
  // the other side of the vertex, so the two OUTWARD rays are 180 - 23.59 apart.
  const line1Start = (0.0, 0.0), line1End = (0.0, 10.0);
  final up = (-math.sin(t), math.cos(t));
  final line2Start = (-15 * up.$1, -15 * up.$2), line2End = (-5 * up.$1, -5 * up.$2);

  double between(({(double, double) vertex, (double, double) ray1, (double, double) ray2}) r) => angleBetweenRaysDegrees(r.ray1, r.ray2);

  group('angleRays', () {
    test('the outward rays of the flange lines are the supplement', () {
      final r = angleOutwardRays(line1Start: line1Start, line1End: line1End, line2Start: line2Start, line2End: line2End)!;
      expect(angleBetweenRaysDegrees(r.ray1, r.ray2), closeTo(180 - theta, 1e-9));
    });

    test('with no saved quadrant the value picks the side: the flange constraint draws 23.59 deg', () {
      final r = angleRays(
        line1Start: line1Start,
        line1End: line1End,
        line2Start: line2Start,
        line2End: line2End,
        valueDegrees: theta,
      )!;
      expect(between(r), closeTo(theta, 1e-9));
      expect(r.vertex.$1, closeTo(0, 1e-9));
      expect(r.vertex.$2, closeTo(0, 1e-9));
    });

    test('each quadrant flips its rays, and draws its own angle', () {
      final expected = {0: 180 - theta, 1: theta, 2: theta, 3: 180 - theta};
      expected.forEach((q, angle) {
        final r = angleRays(line1Start: line1Start, line1End: line1End, line2Start: line2Start, line2End: line2End, quadrant: q)!;
        expect(between(r), closeTo(angle, 1e-9), reason: 'quadrant $q');
      });
      // 1 and 2 are opposite sectors: the same angle, rays pointing the other way.
      final q1 = angleRays(line1Start: line1Start, line1End: line1End, line2Start: line2Start, line2End: line2End, quadrant: 1)!;
      final q2 = angleRays(line1Start: line1Start, line1End: line1End, line2Start: line2Start, line2End: line2End, quadrant: 2)!;
      expect(q1.ray1.$2, closeTo(-1, 1e-9));
      expect(q2.ray1.$2, closeTo(1, 1e-9));
    });

    test('a saved quadrant wins over the value', () {
      final r = angleRays(
        line1Start: line1Start,
        line1End: line1End,
        line2Start: line2Start,
        line2End: line2End,
        valueDegrees: theta,
        quadrant: 0,
      )!;
      expect(between(r), closeTo(180 - theta, 1e-9));
    });

    test('angleQuadrantAt names the sector a point is in, and it is the sector angleRays draws', () {
      final outward = angleOutwardRays(line1Start: line1Start, line1End: line1End, line2Start: line2Start, line2End: line2End)!;
      for (var q = 0; q < 4; q++) {
        final r = angleRays(line1Start: line1Start, line1End: line1End, line2Start: line2Start, line2End: line2End, quadrant: q)!;
        final inside = (r.ray1.$1 + r.ray2.$1, r.ray1.$2 + r.ray2.$2); // the middle of that sector
        expect(
          angleQuadrantAt(vertex: outward.vertex, outwardRay1: outward.ray1, outwardRay2: outward.ray2, p: inside),
          q,
          reason: 'quadrant $q',
        );
      }
      expect(angleQuadrantAt(vertex: outward.vertex, outwardRay1: outward.ray1, outwardRay2: outward.ray2, p: outward.vertex), isNull);
    });

    test('parallel lines have no rays', () {
      expect(angleRays(line1Start: (0.0, 0.0), line1End: (5.0, 0.0), line2Start: (0.0, 1.0), line2End: (5.0, 1.0)), isNull);
    });
  });

  group('the label sits on the arc', () {
    final basis = SketchPlaneBasis(
      origin: vm.Vector3.zero(),
      xAxis: vm.Vector3(1, 0, 0),
      yAxis: vm.Vector3(0, 1, 0),
      normal: vm.Vector3(0, 0, 1),
    );
    const viewportSize = Size(800, 600);
    final camera = OrthographicCamera(position: vm.Vector3(0, 0, 10), target: vm.Vector3.zero(), up: vm.Vector3(0, 1, 0), halfHeight: 20);

    // The screen position of a sketch point, read through a two-anchor label item whose midpoint is that point.
    Offset screenOf((double, double) p) => constraintOverlayItemLabelCenter(
          camera,
          viewportSize,
          basis,
          ConstraintLabelItem(
            constraintId: 'probe',
            selected: false,
            anchorA: (p.$1 - 1, p.$2),
            anchorB: (p.$1 + 1, p.$2),
            text: '',
            labelOffset: Offset.zero,
            plainBlackText: false,
          ),
        )!;

    ConstraintAngleDimensionItem flangeItem({int? quadrant, double? radius, double? along}) => ConstraintAngleDimensionItem(
          constraintId: 'flange',
          selected: false,
          line1Start: line1Start,
          line1End: line1End,
          line2Start: line2Start,
          line2End: line2End,
          text: '23.6°',
          labelOffset: Offset.zero,
          valueDegrees: theta,
          quadrant: quadrant,
          sketchLocalArcRadius: radius,
          sketchLocalAlongOffset: along,
        );

    test('the flange constraint draws 23.59 deg with its default label on the arc, at the same radius as a wide angle\'s', () {
      final vertex = screenOf((0.0, 0.0));
      final rays = angleDimensionVertexAndRays(flangeItem())!;
      expect(angleBetweenRaysDegrees(rays.$2, rays.$3), closeTo(theta, 1e-9));
      final narrow = constraintOverlayItemLabelCenter(camera, viewportSize, basis, flangeItem())!;
      final wide = constraintOverlayItemLabelCenter(camera, viewportSize, basis, flangeItem(quadrant: 0))!;
      // On the arc both labels are one arc radius from the vertex; on the chord the 156 deg one would be about 0.2 of it.
      expect((narrow - vertex).distance, closeTo((wide - vertex).distance, 1e-6));
      // And on the bisector of the narrow angle (between straight up and up-left), above the vertex.
      final direction = (narrow - vertex) / (narrow - vertex).distance;
      final expected = Offset(-math.sin(t / 2), -math.cos(t / 2)); // screen y is down
      expect(direction.dx, closeTo(expected.dx, 1e-6));
      expect(direction.dy, closeTo(expected.dy, 1e-6));
    });

    test('a placed label is where the resolver put it, on the arc of the placed radius', () {
      const p = (-1.0, 4.0);
      final placement = LabelDragResolver.angle(
        line1Start: line1Start,
        line1End: line1End,
        line2Start: line2Start,
        line2End: line2End,
        p: p,
        valueDegrees: theta,
      )!;
      expect(placement.radius, closeTo(math.sqrt(17), 1e-9));
      final label = constraintOverlayItemLabelCenter(
        camera,
        viewportSize,
        basis,
        flangeItem(radius: placement.radius, along: placement.along),
      )!;
      final want = screenOf(p);
      expect(label.dx, closeTo(want.dx, 1e-6));
      expect(label.dy, closeTo(want.dy, 1e-6));
    });
  });

  group('quadrant round trip through the wire', () {
    test('a saved quadrant reaches the drawn item; an older constraint has none', () {
      for (final q in [0, 1, 2, 3]) {
        final dto = ConstraintDto.fromJson({
          'id': 'c',
          'type': 'angle',
          'line1_id': 'a',
          'line2_id': 'b',
          'angle_degrees': theta,
          'quadrant': q,
        }) as AngleConstraintDto;
        expect(dto.quadrant, q);
        final r = angleRays(
          line1Start: line1Start,
          line1End: line1End,
          line2Start: line2Start,
          line2End: line2End,
          valueDegrees: dto.angleDegrees,
          quadrant: dto.quadrant,
        )!;
        expect(between(r), closeTo(q == 1 || q == 2 ? theta : 180 - theta, 1e-9));
      }
      final old = ConstraintDto.fromJson({'id': 'c', 'type': 'angle', 'line1_id': 'a', 'line2_id': 'b', 'angle_degrees': theta})
          as AngleConstraintDto;
      expect(old.quadrant, isNull);
    });
  });

  group('angleExtensionLineStart (bug report 2026-11-18)', () {
    test('no extension line when the arc lands on the drawn segment', () {
      expect(angleExtensionLineStart(2, 10, 5), isNull);
      expect(angleExtensionLineStart(10, 2, 2), isNull);
    });
    test('beyond the segment it starts at the farther end, short of it at the nearer end', () {
      expect(angleExtensionLineStart(2, 10, 15), 1);
      expect(angleExtensionLineStart(10, 2, 15), 0);
      expect(angleExtensionLineStart(4, 10, 1), 0);
      expect(angleExtensionLineStart(10, 4, 1), 1);
    });
    test('a flipped ray (segment behind the vertex) starts at the end nearer the vertex', () {
      expect(angleExtensionLineStart(-10, -2, 3), 1);
    });
  });
}
