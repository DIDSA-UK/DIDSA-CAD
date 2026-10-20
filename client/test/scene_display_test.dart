// A shown scene on the flat app's placed instances (`lib/appearance/scene_display.dart`): the golden vectors' tree laid out as
// `assembly-mesh` instances (world poses from the root), a scene composed over them, and back to a scene override.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/appearance/scene_compose.dart';
import 'package:didsa_cad_client/appearance/scene_display.dart';
import 'package:didsa_cad_client/viewport3d/mesh_geometry.dart' show composeRigidTransforms;

const String _vectorsPath = '../docs/scenes/vectors.json';

RigidTransformDto _rigid(Map world) => rigidOfPose(ScenePose(
      [for (final row in world['basis'] as List) [for (final v in row as List) (v as num).toDouble()]],
      [for (final v in world['origin'] as List) (v as num).toDouble()],
    ));

/// Where [t] puts the point [p] (mm).
List<double> _apply(RigidTransformDto t, List<double> p) {
  final pose = poseOf({'translation': t.translation, 'rotation_axis': t.rotationAxis, 'rotation_angle_degrees': t.rotationAngleDegrees});
  return [for (var r = 0; r < 3; r++) pose.origin[r] + pose.basis[r][0] * p[0] + pose.basis[r][1] * p[1] + pose.basis[r][2] * p[2]];
}

void _expectSamePose(RigidTransformDto got, RigidTransformDto want, String why) {
  for (final p in const [
    [0.0, 0.0, 0.0],
    [100.0, 0.0, 0.0],
    [0.0, 100.0, 0.0],
    [0.0, 0.0, 100.0],
  ]) {
    final a = _apply(got, p);
    final b = _apply(want, p);
    for (var i = 0; i < 3; i++) {
      expect(a[i], closeTo(b[i], 1e-3), reason: '$why at $p');
    }
  }
}

void main() {
  late Map<String, dynamic> doc;
  late List<AssemblyOccurrenceInstanceDto> instances;

  Map<String, dynamic> expectedOf(String name) =>
      ((doc['cases'] as List).firstWhere((c) => c['name'] == name) as Map)['expected'] as Map<String, dynamic>;

  setUpAll(() {
    doc = jsonDecode(File(_vectorsPath).readAsStringSync()) as Map<String, dynamic>;
    final defaults = expectedOf('default');
    instances = [
      for (final n in doc['nodes'] as List)
        if (n['path'] != 'leg')
          AssemblyOccurrenceInstanceDto(
            occurrencePath: (n['path'] as String).isEmpty ? const [] : (n['path'] as String).split('/'),
            partId: 'p',
            worldTransform: _rigid(defaults[n['path']]['world'] as Map),
            color: '#ABCDEF',
            appearance: const {'opacity': 0.5},
          ),
    ];
  });

  test('rigidOfPose turns a pose back into the transform it came from', () {
    final t = {'translation': [1.0, 2.0, 3.0], 'rotation_axis': [1.0, 1.0, 0.0], 'rotation_angle_degrees': 70.0};
    _expectSamePose(rigidOfPose(poseOf(t)), RigidTransformDto.fromJson(t), 'round trip');
    final none = rigidOfPose(poseOf({'translation': [0, 0, 0], 'rotation_axis': [0, 0, 1], 'rotation_angle_degrees': 0}));
    expect(none.rotationAngleDegrees, 0);
  });

  test('the default scene leaves every instance where it is', () {
    final shown = sceneDisplayInstances(instances, {'overrides': <dynamic>[]});
    for (var i = 0; i < instances.length; i++) {
      _expectSamePose(shown[i].worldTransform, instances[i].worldTransform, instances[i].occurrencePath.join('/'));
      expect(shown[i].hidden, instances[i].hidden);
    }
  });

  test('the exploded scene composes down the tree as the vectors say; colour and looks are kept', () {
    final scene = ((doc['cases'] as List).firstWhere((c) => c['name'] == 'exploded') as Map)['scene'] as Map<String, dynamic>;
    final expected = expectedOf('exploded');
    final shown = sceneDisplayInstances(instances, scene);
    for (final i in shown) {
      final path = i.occurrencePath.join('/');
      _expectSamePose(i.worldTransform, _rigid(expected[path]['world'] as Map), path);
      expect(i.color, '#ABCDEF');
      expect(i.appearance, const {'opacity': 0.5});
    }
  });

  test('the hidden scene: the nearest scene hidden wins, the rest as they are', () {
    final scene = ((doc['cases'] as List).firstWhere((c) => c['name'] == 'hidden') as Map)['scene'] as Map<String, dynamic>;
    final expected = expectedOf('hidden');
    for (final i in sceneDisplayInstances(instances, scene)) {
      expect(i.hidden, expected[i.occurrencePath.join('/')]['hidden'], reason: i.occurrencePath.join('/'));
    }
  });

  test('a move on screen is the instance\'s local transform in the pose its parent shows at', () {
    final scene = ((doc['cases'] as List).firstWhere((c) => c['name'] == 'exploded') as Map)['scene'] as Map<String, dynamic>;
    final shown = sceneDisplayInstances(instances, scene);
    final frame = shown.firstWhere((i) => i.occurrencePath.join('/') == 'frame');
    // barB moved to 25 mm above where the scene shows it, in the root's frame.
    final barB = shown.firstWhere((i) => i.occurrencePath.join('/') == 'frame/barB');
    final up = RigidTransformDto(translation: const [0, 0, 25], rotationAxis: const [0, 0, 1], rotationAngleDegrees: 0);
    final world = composeRigidTransforms(up, barB.worldTransform);
    final local = RigidTransformDto.fromJson(sceneLocalTransform(shown, 'frame/barB', world));
    _expectSamePose(composeRigidTransforms(frame.worldTransform, local), world, 'local in the shown frame');
    expect(local.translation[1], closeTo(800, 1e-3));
    expect(local.translation[2], closeTo(25, 1e-3), reason: 'the frame is turned about z, so up stays up');
    // And shown again with that override, barB is where it was put.
    final again = sceneDisplayInstances(instances, {
      'overrides': [...(scene['overrides'] as List), {'path': 'frame/barB', 'transform': local.toJson()}],
    });
    _expectSamePose(again.firstWhere((i) => i.occurrencePath.join('/') == 'frame/barB').worldTransform, world, 'shown again');
  });
}
