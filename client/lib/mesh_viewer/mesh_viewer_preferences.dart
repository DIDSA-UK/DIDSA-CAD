import 'package:shared_preferences/shared_preferences.dart';

import 'mesh_data.dart' show MeshUpAxis;

/// Persisted, device/pipeline-specific defaults for the "View Complex Mesh"
/// viewer - the same `shared_preferences`-backed, load-then-read-getters
/// pattern [ViewPreferences]/[ScenePreferences] already use. Reachable from
/// a settings screen off the connection screen (not the mesh viewer's own
/// View menu, which holds live/per-session controls instead - see
/// `scene_preferences.dart`'s own split) since both of these are "set once
/// for how this device/export-pipeline behaves" choices, not something to
/// re-tune per file.
class MeshViewerPreferences {
  MeshViewerPreferences._();

  static const String maxTrianglesPrefKey = 'mesh_viewer_max_triangles';
  static const String upAxisPrefKey = 'mesh_viewer_up_axis';
  static const String mirrorPrefKey = 'mesh_viewer_mirror';
  // Camera-calibration debug aid (see triad.dart's own doc comment) -
  // temporary, this viewer's own copy of `ViewPreferences`'s identical key,
  // since the mesh viewer has its own separate camera/viewport unrelated to
  // `PartViewport`.
  static const String debugShowCameraOrientationPrefKey = 'mesh_viewer_debug_camera_orientation';

  /// Matches `mesh_viewer_render.dart`'s own former hardcoded constant -
  /// tuned for a high-end 2023-class Android flagship (Snapdragon 8 Gen 2 /
  /// Adreno 740), not a lower/generic mobile floor. A starting point for
  /// real-device tuning, which is exactly why this is now a user-adjustable
  /// setting rather than a fixed constant - a lower-end device may need to
  /// go well below this, and a newer/higher-end one could likely afford more.
  static const int defaultMaxTriangles = 3000000;
  static const int minMaxTriangles = 250000;
  static const int maxMaxTriangles = 10000000;

  static const MeshUpAxis defaultUpAxis = MeshUpAxis.y;

  /// Default for the "Mirror" toggle - see `mesh_data.dart`'s own doc
  /// comment on [applyMirror] for the real file (a Blender-exported drone
  /// photogrammetry scan) that motivated this: confirmed, by rendering both
  /// the as-decoded and a left-right-flipped version for direct comparison
  /// against the real property, to be a genuine mirror image baked into the
  /// file's own raw vertex data. Off by default for the same reason
  /// [defaultUpAxis] is `y`: most files need no correction at all.
  static const bool defaultMirror = false;

  // On while the camera-calibration round is still active - see this key's
  // own doc comment.
  static const bool defaultDebugShowCameraOrientation = true;

  static int _maxTriangles = defaultMaxTriangles;
  static MeshUpAxis _upAxis = defaultUpAxis;
  static bool _mirror = defaultMirror;
  static bool _debugShowCameraOrientation = defaultDebugShowCameraOrientation;

  static int get maxTriangles => _maxTriangles;
  static MeshUpAxis get upAxis => _upAxis;
  static bool get mirror => _mirror;
  static bool get debugShowCameraOrientation => _debugShowCameraOrientation;

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _maxTriangles = prefs.getInt(maxTrianglesPrefKey) ?? defaultMaxTriangles;
    final storedUpAxis = prefs.getString(upAxisPrefKey);
    _upAxis = MeshUpAxis.values.firstWhere(
      (axis) => axis.name == storedUpAxis,
      orElse: () => defaultUpAxis,
    );
    _mirror = prefs.getBool(mirrorPrefKey) ?? defaultMirror;
    _debugShowCameraOrientation =
        prefs.getBool(debugShowCameraOrientationPrefKey) ?? defaultDebugShowCameraOrientation;
  }

  static Future<void> setMaxTriangles(int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(maxTrianglesPrefKey, value);
    _maxTriangles = value;
  }

  static Future<void> setUpAxis(MeshUpAxis axis) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(upAxisPrefKey, axis.name);
    _upAxis = axis;
  }

  static Future<void> setMirror(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(mirrorPrefKey, value);
    _mirror = value;
  }

  static Future<void> setDebugShowCameraOrientation(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(debugShowCameraOrientationPrefKey, value);
    _debugShowCameraOrientation = value;
  }
}
