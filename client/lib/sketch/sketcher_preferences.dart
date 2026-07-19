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

  /// On-device feedback ("when I tap a sketch in the tree, it sends me to
  /// the old 2d editor"): there is only one `SketchScreen` widget/route
  /// (the flat 2D canvas and the embedded 3D Orbit View are both internal
  /// states of it, not separate screens - see that widget's own
  /// `_loadInitialOrbitViewPreference`), so this single, device-wide,
  /// persisted default is the *only* thing deciding which one a device
  /// lands in - identically for a brand-new Sketch and for tapping an
  /// existing one in the feature tree. A fresh install, or any device that
  /// never visited Settings > Sketcher, landed in the 2D canvas every time.
  /// Flipped to `true` now that the 3D sketcher has real feature parity
  /// (P1-P51) - the 2D canvas remains reachable via the in-sketch Orbit-
  /// View-toggle FAB for whoever still wants it, per this class's own doc
  /// comment above.
  static const bool defaultUse3DSketcher = true;

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
