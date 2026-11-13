import 'package:vector_math/vector_math.dart' as vm;

import '../api/document_api_client.dart';
import 'mesh_geometry.dart' show matrix4FromRigidTransform;

/// M4 (`docs/mates-storage-sessions-plan-2026-11-12.md`): where a mate pick landed - the hit point local to the picked occurrence
/// (mm, the frame the backend's `pick_points` are in; `null` when it could not be worked out) and the view direction at the pick
/// (world, the picking ray's direction). Sent with the preview and the create; the backend accepts them and does not use them yet
/// (no pick-point tie-break passed the M4 bench).
class MatePickPoint {
  final List<double>? local;
  final List<double> viewDirection;

  const MatePickPoint({required this.local, required this.viewDirection});
}

/// [world] (a hit point in the viewport's world frame) in the frame of the occurrence instance whose joined path is [occurrenceKey]
/// (its part's own frame), or `null` when no instance has that path or its world transform cannot be inverted.
List<double>? occurrenceLocalPoint(vm.Vector3 world, List<AssemblyOccurrenceInstanceDto> instances, String occurrenceKey) {
  for (final instance in instances) {
    if (instance.occurrencePath.join('/') != occurrenceKey) continue;
    final matrix = matrix4FromRigidTransform(instance.worldTransform);
    if (matrix.determinant().abs() < 1e-12) return null;
    final local = vm.Matrix4.inverted(matrix).transform3(world.clone());
    return [local.x, local.y, local.z];
  }
  return null;
}

/// The `pick_points` of a two-pick mate, in [order] (the references' order): each entity's local point, `null` for one without.
/// `null` overall when no entity has one (nothing to send).
List<List<double>?>? matePickPointsFor<K>(Iterable<K> order, Map<K, MatePickPoint> picks) {
  final points = [for (final key in order) picks[key]?.local];
  return points.every((p) => p == null) ? null : points;
}

/// The view direction to send: the last pick's (the one that completed the pair), or `null`.
List<double>? mateViewDirectionFor<K>(Iterable<K> order, Map<K, MatePickPoint> picks) {
  List<double>? last;
  for (final key in order) {
    last = picks[key]?.viewDirection ?? last;
  }
  return last;
}
