// M3: the glide preview's model (pure): a previewed occurrence moves from its stored pose to the solved one, a new preview glides from where it is, Cancel goes
// home, Confirm keeps the solved pose, and the outline stays at the stored pose. Feel (the 0.25 s, the ease) is the owner's to judge on a device.
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/viewport3d/assembly_instance_render.dart';
import 'package:didsa_cad_client/viewport3d/controls_preferences.dart';
import 'package:didsa_cad_client/viewport3d/mate_preview_glide.dart';
import 'package:shared_preferences/shared_preferences.dart';

RigidTransformDto _at(double x) => RigidTransformDto(translation: [x, 0, 0], rotationAxis: const [0, 0, 1], rotationAngleDegrees: 0);

MatePreviewMember _move(String id, double from, double to) => MatePreviewMember(occurrenceId: id, previous: _at(from), next: _at(to));

double _x(MatePreviewGlide g, String id, double now) => g.posesAt(now)[id]!.translation[0];

void main() {
  test('a preview glides from the stored pose to the solved one and ends exactly on it', () {
    final g = MatePreviewGlide(seconds: 1.0);
    g.retarget([_move('b', 5, 25)], 10.0);
    expect(_x(g, 'b', 10.0), closeTo(5, 1e-9), reason: 'it starts where it was stored');
    final mid = _x(g, 'b', 10.5);
    expect(mid, closeTo(15, 1e-9), reason: 'ease in-out: half way at half time');
    expect(_x(g, 'b', 10.25), lessThan(10), reason: 'slow at the start (ease in)');
    expect(_x(g, 'b', 11.0), 25);
    expect(_x(g, 'b', 99.0), 25);
    expect(g.isAnimating(10.5), isTrue);
    expect(g.isAnimating(11.0), isFalse);
  });

  test('a new preview glides from where the part is now (not from its stored pose) and keeps the stored pose', () {
    final g = MatePreviewGlide(seconds: 1.0);
    g.retarget([_move('b', 5, 25)], 0);
    g.retarget([_move('b', 5, -7)], 0.5); // half way (x = 15) when the new answer comes
    expect(_x(g, 'b', 0.5), closeTo(15, 1e-9));
    expect(_x(g, 'b', 1.5), -7);
    expect(g.outline().single.previous.translation[0], 5, reason: 'the outline stays at the stored pose');
    expect(g.outline().single.next.translation[0], 5);
  });

  test('Cancel glides back to the stored pose and the occurrence is dropped once it is home', () {
    final g = MatePreviewGlide(seconds: 1.0);
    g.retarget([_move('b', 5, 25)], 0);
    g.cancel(2.0);
    expect(g.outline(), isEmpty, reason: 'the outline goes as soon as it is cancelled');
    expect(_x(g, 'b', 2.0), 25);
    expect(_x(g, 'b', 3.0), 5);
    expect(g.settle(2.5), isFalse);
    expect(g.isActive, isTrue);
    expect(g.settle(3.0), isTrue);
    expect(g.isActive, isFalse);
    expect(g.posesAt(3.0), isEmpty);
  });

  test('a part that is no longer moved by the new answer glides home while the new one glides out', () {
    final g = MatePreviewGlide(seconds: 1.0);
    g.retarget([_move('b', 5, 25)], 0);
    g.retarget([_move('a', 0, 3)], 2.0);
    expect(_x(g, 'b', 3.0), 5);
    expect(_x(g, 'a', 3.0), 3);
    expect(g.outline().map((m) => m.occurrenceId), ['a']);
    g.settle(3.0);
    expect(g.ids.toSet(), {'a'});
  });

  test('Confirm keeps the solved pose: the glide jumps to the end and draws it until it is cleared', () {
    final g = MatePreviewGlide(seconds: 1.0);
    g.retarget([_move('b', 5, 25)], 0);
    g.commit();
    expect(_x(g, 'b', 0.1), 25, reason: 'nothing moves back, nothing is left to animate');
    expect(g.isAnimating(0.1), isFalse);
    expect(g.settle(5.0), isFalse);
    expect(_x(g, 'b', 5.0), 25);
    g.clear();
    expect(g.isActive, isFalse);
  });

  test('a rotation glides too: the end is exactly the solved rotation', () {
    final g = MatePreviewGlide(seconds: 1.0);
    g.retarget([
      MatePreviewMember(
        occurrenceId: 'b',
        previous: _at(0),
        next: RigidTransformDto(translation: const [0, 0, 0], rotationAxis: const [0, 0, 1], rotationAngleDegrees: 90),
      ),
    ], 0);
    expect(g.posesAt(0.5)['b']!.rotationAngleDegrees, closeTo(45, 1e-6));
    expect(g.posesAt(1.0)['b']!.rotationAngleDegrees, closeTo(90, 1e-9));
  });

  test('the Controls setting defaults to the glide, is stored and is reset', () async {
    SharedPreferences.setMockInitialValues({});
    await ControlsPreferences.reset();
    await ControlsPreferences.load();
    expect(ControlsPreferences.matePreviewGlide, isTrue);
    await ControlsPreferences.setMatePreviewGlide(false);
    SharedPreferences.setMockInitialValues({ControlsPreferences.matePreviewGlidePrefKey: false});
    await ControlsPreferences.load();
    expect(ControlsPreferences.matePreviewGlide, isFalse);
    await ControlsPreferences.reset();
    expect(ControlsPreferences.matePreviewGlide, isTrue);
  });
}
