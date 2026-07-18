import 'package:shared_preferences/shared_preferences.dart';

/// Persisted, device-wide default for which base layer a newly opened
/// [SketchScreen] starts in - the same `shared_preferences`-backed,
/// load-then-read-getters pattern `mesh_viewer_preferences.dart`'s
/// [MeshViewerPreferences] already uses, for the same reason: "which
/// sketcher does this device use" is a "set once, rarely revisited" choice,
/// not something to re-tune per Sketch.
///
/// Sketcher restructure Phase 2's rollout mechanism: the 3D-embedded
/// sketcher (Orbit View's own [PartViewport] backdrop, made genuinely
/// interactive rather than look-only) coexists with the existing flat 2D
/// [SketchCanvas] rather than replacing it outright, gated by this default -
/// [SketchScreen]'s existing live Orbit-View-toggle FAB stays available
/// regardless, as an escape hatch back to 2D mid-sketch during rollout.
class SketcherPreferences {
  SketcherPreferences._();

  static const String use3DSketcherPrefKey = 'sketcher_use_3d';

  static const bool defaultUse3DSketcher = false;

  static bool _use3DSketcher = defaultUse3DSketcher;

  static bool get use3DSketcher => _use3DSketcher;

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _use3DSketcher = prefs.getBool(use3DSketcherPrefKey) ?? defaultUse3DSketcher;
  }

  static Future<void> setUse3DSketcher(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(use3DSketcherPrefKey, value);
    _use3DSketcher = value;
  }
}
