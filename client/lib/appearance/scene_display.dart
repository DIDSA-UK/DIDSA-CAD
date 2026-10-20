/// A shown scene on the flat app's placed instances (`docs/scenes-scope.md` S3): the composition (`scene_compose.dart`, the
/// reference's copy) run over `GET /parts/{id}/assembly-mesh`'s instances, so the viewport draws the scene's poses and
/// visibility without the model changing. And back: what a scene override for an instance moved on screen is.
library;

import 'dart:math' as math;

import 'package:vector_math/vector_math.dart' as vm;

import '../api/document_api_client.dart';
import '../viewport3d/mesh_geometry.dart' show localRigidTransformRelativeTo;
import 'appearance_rule.dart';
import 'scene_compose.dart';

/// A pose (row-major basis, origin) as the backend's rigid transform.
RigidTransformDto rigidOfPose(ScenePose pose) {
  final b = pose.basis;
  // vector_math's Matrix3 is column-major: (row r, column c) goes to index c * 3 + r.
  final m = vm.Matrix3(b[0][0], b[1][0], b[2][0], b[0][1], b[1][1], b[2][1], b[0][2], b[1][2], b[2][2]);
  final q = vm.Quaternion.fromRotation(m)..normalize();
  var angle = 2 * math.acos(q.w.clamp(-1.0, 1.0));
  var axis = vm.Vector3(q.x, q.y, q.z);
  if (axis.length < 1e-9 || angle.abs() < 1e-12) {
    axis = vm.Vector3(0, 0, 1);
    angle = 0;
  } else {
    axis.normalize();
  }
  return RigidTransformDto(
    translation: [pose.origin[0], pose.origin[1], pose.origin[2]],
    rotationAxis: [axis.x, axis.y, axis.z],
    rotationAngleDegrees: angle * 180 / math.pi,
  );
}

Json _jsonOf(RigidTransformDto t) => {
      'translation': t.translation,
      'rotation_axis': t.rotationAxis,
      'rotation_angle_degrees': t.rotationAngleDegrees,
    };

/// The nearest ancestor of [path] that is a placed instance in [byPath] (null: the root's own content).
String? presentAncestor(String path, Map<String, AssemblyOccurrenceInstanceDto> byPath) {
  var probe = parentPath(path);
  while (probe != null && !byPath.containsKey(probe)) {
    probe = parentPath(probe);
  }
  return probe;
}

/// [instances] (the real ones, world poses from the root) as [scene] shows them: poses composed from the scene's transform
/// overrides down the tree, visibility from its nearest `hidden` (else the instance's own). Everything else is kept.
List<AssemblyOccurrenceInstanceDto> sceneDisplayInstances(List<AssemblyOccurrenceInstanceDto> instances, Json scene) {
  final byPath = {for (final i in instances) i.occurrencePath.join('/'): i};
  final nodes = <Json>[
    for (final entry in byPath.entries)
      () {
        final anc = presentAncestor(entry.key, byPath);
        final local = anc == null
            ? entry.value.worldTransform
            : localRigidTransformRelativeTo(byPath[anc]!.worldTransform, entry.value.worldTransform);
        return <String, dynamic>{'path': entry.key, 'local': _jsonOf(local), 'hidden': entry.value.hidden, 'bodies': const <String>[]};
      }(),
  ];
  final composed = composeScene(nodes, const {'parts': <String, dynamic>{}}, '', scene);
  return [
    for (final i in instances)
      () {
        final c = composed[i.occurrencePath.join('/')]!;
        return i.copyWith(worldTransform: rigidOfPose(c.world), hidden: c.hidden);
      }(),
  ];
}

/// The scene override transform for the instance [path] shown at [world] (its pose in the root's frame): its local
/// transform in the pose its parent shows at in [shown] (the scene's instances).
Json sceneLocalTransform(List<AssemblyOccurrenceInstanceDto> shown, String path, RigidTransformDto world) {
  final byPath = {for (final i in shown) i.occurrencePath.join('/'): i};
  final anc = presentAncestor(path, byPath);
  final parent = anc == null ? null : byPath[anc];
  return _jsonOf(parent == null ? world : localRigidTransformRelativeTo(parent.worldTransform, world));
}
