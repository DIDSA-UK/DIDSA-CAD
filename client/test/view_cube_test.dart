import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:didsa_cad_client/viewport3d/view_cube.dart';

/// Desktop input D5 (`docs/desktop-input-scope.md` section 4): the view
/// cube's geometry (which of the 26 targets a click lands on) and its popup.
ViewCubeBasis _lookingFrom(vm.Vector3 direction) {
  final (eye, up) = viewCubeEyeAndUp(direction);
  final back = eye;
  final right = up.cross(back)..normalize();
  final trueUp = back.cross(right)..normalize();
  return ViewCubeBasis(right: right, up: trueUp, back: back);
}

final _front = ViewCubeBasis(right: vm.Vector3(1, 0, 0), up: vm.Vector3(0, 1, 0), back: vm.Vector3(0, 0, 1));

List<vm.Vector3> _allTargets() => [
      for (var x = -1; x <= 1; x++)
        for (var y = -1; y <= 1; y++)
          for (var z = -1; z <= 1; z++)
            if (x != 0 || y != 0 || z != 0) vm.Vector3(x.toDouble(), y.toDouble(), z.toDouble()),
    ];

Offset _centre(List<Offset> quad) => quad.reduce((a, b) => a + b) / quad.length.toDouble();

void main() {
  normalToTests();
  group('viewCubeEyeAndUp', () {
    test('a face looks from its own side with Y up; Top and Bottom keep SOLIDWORKS ups', () {
      final (frontEye, frontUp) = viewCubeEyeAndUp(vm.Vector3(0, 0, 1));
      expect(frontEye, vm.Vector3(0, 0, 1));
      expect(frontUp, vm.Vector3(0, 1, 0));
      expect(viewCubeEyeAndUp(vm.Vector3(0, 1, 0)).$2, vm.Vector3(0, 0, -1));
      expect(viewCubeEyeAndUp(vm.Vector3(0, -1, 0)).$2, vm.Vector3(0, 0, 1));
    });

    test('an edge or corner looks along the normalised diagonal', () {
      final (eye, up) = viewCubeEyeAndUp(vm.Vector3(1, 1, 1));
      expect(eye.length, closeTo(1, 1e-6));
      expect(eye.x, closeTo(eye.y, 1e-6));
      expect(up, vm.Vector3(0, 1, 0));
    });
  });

  test('viewCubeTargetName uses SOLIDWORKS names', () {
    expect(viewCubeTargetName(vm.Vector3(0, 0, 1)), 'Front');
    expect(viewCubeTargetName(vm.Vector3(1, 1, 0)), 'Top Right');
    expect(viewCubeTargetName(vm.Vector3(-1, -1, -1)), 'Back Bottom Left');
  });

  group('ViewCubeProjection', () {
    test('seen from the front only the front face shows, and its middle is Front', () {
      final projection = ViewCubeProjection(_front, 200);
      expect([for (final n in ViewCubeProjection.faceNormals) projection.faceVisible(n)], [true, false, false, false, false, false]);
      expect(projection.targetAt(const Offset(100, 100)), vm.Vector3(0, 0, 1));
      expect(projection.targetAt(const Offset(2, 2)), isNull, reason: 'off the cube');
    });

    test('the front face is a 3 x 3 grid: an edge cell is an edge, a corner cell a corner', () {
      final projection = ViewCubeProjection(_front, 200);
      final quad = projection.faceQuad(vm.Vector3(0, 0, 1)); // (-1,-1) (1,-1) (1,1) (-1,1) in x, y
      final left = quad.first.dx;
      final right = quad[1].dx;
      final bottom = quad.first.dy; // y = -1 is lower on screen (larger dy)
      final top = quad[2].dy;
      final width = right - left;
      final height = bottom - top;
      // top right corner cell: x = +1, y = +1
      expect(projection.targetAt(Offset(right - width / 10, top + height / 10)), vm.Vector3(1, 1, 1));
      // middle of the right edge: x = +1, y = 0
      expect(projection.targetAt(Offset(right - width / 10, top + height / 2)), vm.Vector3(1, 0, 1));
      // bottom left corner: x = -1, y = -1
      expect(projection.targetAt(Offset(left + width / 10, bottom - height / 10)), vm.Vector3(-1, -1, 1));
    });

    test('every one of the 26 targets can be reached, and a cell\'s middle resolves back to it', () {
      for (final target in _allTargets()) {
        final projection = ViewCubeProjection(_lookingFrom(target), 200);
        final cell = projection.cellOf(target);
        expect(cell, isNotNull, reason: 'visible from its own side: ${viewCubeTargetName(target)}');
        expect(projection.targetAt(_centre(cell!)), target, reason: viewCubeTargetName(target));
      }
    });

    test('from a corner three faces show', () {
      final projection = ViewCubeProjection(_lookingFrom(vm.Vector3(1, 1, 1)), 200);
      expect(ViewCubeProjection.faceNormals.where(projection.faceVisible).length, 3);
    });
  });

  group('showViewCube', () {
    Future<void> open(
      WidgetTester tester, {
      required List<vm.Vector3> picks,
      VoidCallback? onNormalTo,
      Size size = const Size(800, 600),
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showViewCube(
                context,
                anchor: const Offset(300, 100),
                basis: _front,
                onPick: picks.add,
                onNormalTo: onNormalTo,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('clicking the middle of the cube picks Front and closes it', (tester) async {
      final picks = <vm.Vector3>[];
      await open(tester, picks: picks);
      await tester.tap(find.byKey(const Key('view-cube')));
      await tester.pumpAndSettle();
      expect(picks, [vm.Vector3(0, 0, 1)]);
      expect(find.byKey(const Key('view-cube')), findsNothing);
    });

    testWidgets('Normal To is disabled without a flat face or plane, and runs when there is one', (tester) async {
      await open(tester, picks: []);
      expect(tester.widget<TextButton>(find.widgetWithText(TextButton, 'Normal To')).onPressed, isNull);
      await tester.tapAt(const Offset(5, 5)); // outside: closes
      await tester.pumpAndSettle();

      var normalTo = 0;
      await open(tester, picks: [], onNormalTo: () => normalTo++);
      await tester.tap(find.text('Normal To'));
      await tester.pumpAndSettle();
      expect(normalTo, 1);
      expect(find.byKey(const Key('view-cube')), findsNothing);
    });

    testWidgets('a click outside and Esc both close it without picking', (tester) async {
      final picks = <vm.Vector3>[];
      await open(tester, picks: picks);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('view-cube')), findsNothing);

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('view-cube')), findsNothing);
      expect(picks, isEmpty);
    });

    testWidgets('stays on screen when opened near an edge of a small window', (tester) async {
      await open(tester, picks: [], size: const Size(320, 480));
      final rect = tester.getRect(find.byKey(const Key('view-cube')));
      expect(rect.right, lessThanOrEqualTo(320));
      expect(rect.bottom, lessThanOrEqualTo(480));
      expect(tester.takeException(), isNull);
    });
  });
}

void normalToTests() {
  group('Normal To up vector', () {
    test('from an isometric view, a +X face gets world +Y up', () {
      final isoUp = vm.Vector3(-1, 2, -1)..normalize();
      expect(normalToUp(vm.Vector3(1, 0, 0), isoUp), vm.Vector3(0, 1, 0));
    });

    test('a top face (+Y) gets the world axis nearest the current up instead', () {
      final up = vm.Vector3(-0.4, 0.8, -0.4)..normalize();
      final result = normalToUp(vm.Vector3(0, 1, 0), up);
      expect(result.dot(vm.Vector3(0, 1, 0)).abs(), lessThan(0.01));
    });

    test('a tilted face never gets an up along its normal', () {
      final normal = vm.Vector3(0, 1, 0.1)..normalize();
      final result = normalToUp(normal, vm.Vector3(0, 1, 0));
      expect(result.dot(normal).abs(), lessThan(0.95));
    });

    test('a -Z face with the camera upside down keeps -Y up', () {
      expect(normalToUp(vm.Vector3(0, 0, -1), vm.Vector3(0, -1, 0.1)..normalize()), vm.Vector3(0, -1, 0));
    });
  });
}
