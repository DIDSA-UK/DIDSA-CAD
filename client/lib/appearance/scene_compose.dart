/// Scene composition (`docs/scenes-scope.md` section 5): a scene plus the real placement tree give every placed instance its
/// pose, visibility and appearance while the scene is shown. A line-for-line copy of the backend's reference,
/// `backend/app/document/scene_compose.py`, checked against its golden vectors (`docs/scenes/vectors.json`,
/// `test/scene_compose_test.dart`). DIDSA-VR keeps a GDScript copy.
///
/// nodes: `[{path, local: T, hidden, bodies: [body ids]}]` - every placed instance, its occurrence path from the scene's Part
/// (`''` = the Part's own bodies, a pattern copy is its own node), its REAL local transform at its own level, its real hidden
/// flag. T is the backend's `{translation (mm), rotation_axis, rotation_angle_degrees}`. scene: `{overrides: [...]}` or null.
///
/// The rule: a node's local transform is the scene's for its path, else its real one, and world poses compose down the tree;
/// the nearest scene `hidden` on the node or an ancestor decides its visibility (else its own real flag); the scene's
/// appearance overrides are the top layer of the Appearance tool's rule.
library;

import 'dart:math' as math;

import 'appearance_rule.dart';

const Json kIdentityTransform = {
  'translation': [0.0, 0.0, 0.0],
  'rotation_axis': [0.0, 0.0, 1.0],
  'rotation_angle_degrees': 0.0,
};

/// A pose: a row-major 3x3 [basis] and an [origin] (mm).
class ScenePose {
  final List<List<double>> basis;
  final List<double> origin;

  const ScenePose(this.basis, this.origin);
}

/// Rodrigues: the rotation matrix (row-major) of an axis-angle transform.
List<List<double>> rotationMatrix(Json transform) {
  final axis = (transform['rotation_axis'] as List?) ?? const [0.0, 0.0, 1.0];
  var x = (axis[0] as num).toDouble();
  var y = (axis[1] as num).toDouble();
  var z = (axis[2] as num).toDouble();
  final length = math.sqrt(x * x + y * y + z * z);
  final angle = ((transform['rotation_angle_degrees'] as num?) ?? 0.0).toDouble() * math.pi / 180.0;
  if (length < 1e-12 || angle.abs() < 1e-12) {
    return [
      [1.0, 0.0, 0.0],
      [0.0, 1.0, 0.0],
      [0.0, 0.0, 1.0],
    ];
  }
  x /= length;
  y /= length;
  z /= length;
  final c = math.cos(angle);
  final s = math.sin(angle);
  final t = 1.0 - c;
  return [
    [t * x * x + c, t * x * y - s * z, t * x * z + s * y],
    [t * x * y + s * z, t * y * y + c, t * y * z - s * x],
    [t * x * z - s * y, t * y * z + s * x, t * z * z + c],
  ];
}

ScenePose poseOf(Json transform) {
  final tr = (transform['translation'] as List?) ?? const [0.0, 0.0, 0.0];
  return ScenePose(rotationMatrix(transform), [for (final v in tr) (v as num).toDouble()]);
}

/// [parent] then [child] (child in the parent's frame).
ScenePose composePoses(ScenePose parent, ScenePose child) {
  final pb = parent.basis;
  final cb = child.basis;
  final basis = [
    for (var r = 0; r < 3; r++)
      [
        for (var c = 0; c < 3; c++) pb[r][0] * cb[0][c] + pb[r][1] * cb[1][c] + pb[r][2] * cb[2][c],
      ],
  ];
  final origin = [
    for (var r = 0; r < 3; r++)
      parent.origin[r] + pb[r][0] * child.origin[0] + pb[r][1] * child.origin[1] + pb[r][2] * child.origin[2],
  ];
  return ScenePose(basis, origin);
}

/// The path of the node that places [path] (`''` for a top-level one), or null for the Part's own content (`''`).
String? parentPath(String path) {
  if (path.isEmpty) return null;
  final at = path.lastIndexOf('/');
  return at >= 0 ? path.substring(0, at) : '';
}

/// One node of a composed scene.
class ComposedNode {
  final ScenePose world;
  final bool hidden;
  final Json appearance;
  final Map<String, Json> bodies;

  const ComposedNode({required this.world, required this.hidden, required this.appearance, required this.bodies});
}

bool _whole(Json o) => o['body_id'] == null && o['face'] == null;

/// The scene's appearance overrides as the top layer of the Appearance tool's rule (only their target and appearance).
List<Json> sceneAppearanceLayer(Json? scene) => [
      for (final raw in ((scene?['overrides'] as List?) ?? const []))
        if ((raw as Map)['appearance'] is Map && (raw['appearance'] as Map).isNotEmpty)
          {
            for (final k in const ['path', 'body_id', 'face', 'appearance'])
              if (raw[k] != null) k: raw[k],
          },
    ];

/// The paths the scene hides or shows (whole nodes only).
Map<String, bool> sceneHiddenFlags(Json? scene) => {
      for (final raw in ((scene?['overrides'] as List?) ?? const []))
        if ((raw as Map)['hidden'] != null && _whole(Map<String, dynamic>.from(raw))) raw['path'] as String: raw['hidden'] as bool,
    };

/// The nearest scene `hidden` on [path] or an ancestor, or null when the scene decides nothing about it.
bool? sceneHiddenDecision(String path, Map<String, bool> flags) {
  String? probe = path;
  while (probe != null) {
    final d = flags[probe];
    if (d != null) return d;
    probe = parentPath(probe);
  }
  return null;
}

/// Every node's world pose (in the scene's Part's frame, mm), visibility and appearance while [scene] is shown (null = the
/// default).
Map<String, ComposedNode> composeScene(List<Json> nodes, Json model, String rootId, Json? scene) {
  final overrides = [for (final o in ((scene?['overrides'] as List?) ?? const [])) Map<String, dynamic>.from(o as Map)];
  final transforms = <String, Json>{
    for (final o in overrides)
      if (o['transform'] != null && _whole(o)) o['path'] as String: Map<String, dynamic>.from(o['transform'] as Map),
  };
  final hiddenSet = sceneHiddenFlags(scene);
  final layer = sceneAppearanceLayer(scene);
  final byPath = <String, Json>{for (final n in nodes) n['path'] as String: n};
  final world = <String, ScenePose>{};
  ScenePose worldOf(String path) {
    final known = world[path];
    if (known != null) return known;
    final node = byPath[path];
    final local = transforms[path] ?? (node != null ? Map<String, dynamic>.from(node['local'] as Map) : kIdentityTransform);
    final parent = parentPath(path);
    final pose = parent == null ? poseOf(local) : composePoses(worldOf(parent), poseOf(local));
    world[path] = pose;
    return pose;
  }

  final out = <String, ComposedNode>{};
  for (final node in nodes) {
    final path = node['path'] as String;
    final hidden = sceneHiddenDecision(path, hiddenSet) ?? (node['hidden'] as bool? ?? false);
    final segments = splitPath(path);
    out[path] = ComposedNode(
      world: worldOf(path),
      hidden: hidden,
      appearance: resolveAppearance(model, rootId, segments, sceneOverrides: layer),
      bodies: {
        for (final b in (node['bodies'] as List?) ?? const [])
          b as String: resolveAppearance(model, rootId, segments, bodyId: b, sceneOverrides: layer),
      },
    );
  }
  return out;
}
