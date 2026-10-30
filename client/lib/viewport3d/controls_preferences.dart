import 'package:shared_preferences/shared_preferences.dart';

import '../layout/layout_mode.dart';

/// Desktop input D5 (`docs/desktop-input-scope.md` section 4): which CAD
/// package's mouse bindings the view drags follow - see
/// `mouse_navigation.dart`'s `mouseNavActionFor` for the tables.
enum NavigationPreset {
  solidworks('SOLIDWORKS', 'Middle drag orbits, Ctrl+middle pans, Shift+middle zooms, right drag pans.'),
  fusion360('Fusion 360', 'Shift+middle drag orbits, middle drag pans, right drag pans.'),
  onshape('Onshape', 'Right drag orbits, middle drag pans, Ctrl+right drag pans.');

  const NavigationPreset(this.label, this.description);

  final String label;
  final String description;
}

/// Desktop input D5: the mouse and keyboard "Controls" settings - the
/// navigation preset, inverted wheel zoom and the mouse orbit speed. The
/// same `shared_preferences`-backed, load-then-read-getters pattern
/// [ScenePreferences] and [ViewPreferences] use, so the 3D viewport, the 2D
/// sketch canvas and the mesh viewer all read the same stored values.
class ControlsPreferences {
  ControlsPreferences._();

  static const String presetPrefKey = 'controls_navigation_preset';
  static const String invertWheelPrefKey = 'controls_invert_wheel_zoom';
  static const String orbitSpeedPrefKey = 'controls_orbit_speed';
  static const String layoutPrefKey = 'controls_layout_preference';
  static const String quickColumnOpensPrefKey = 'controls_quick_column_opens';

  static const NavigationPreset defaultPreset = NavigationPreset.solidworks;
  static const bool defaultInvertWheel = false;

  /// A multiplier on the orbit speed of a mouse drag (1 = the speed it has
  /// always had).
  static const double defaultOrbitSpeed = 1.0;
  static const double minOrbitSpeed = 0.25;
  static const double maxOrbitSpeed = 3.0;

  static NavigationPreset _preset = defaultPreset;
  static bool _invertWheel = defaultInvertWheel;
  static double _orbitSpeed = defaultOrbitSpeed;
  static LayoutPreference _layoutPreference = LayoutPreference.automatic;
  static int _quickColumnOpens = 0;

  /// The Start button's swipe hint goes after the quick column has been opened this many times.
  static const int quickColumnHintLimit = 3;

  static NavigationPreset get preset => _preset;
  static bool get invertWheel => _invertWheel;
  static double get orbitSpeed => _orbitSpeed;
  static LayoutPreference get layoutPreference => _layoutPreference;

  /// Whether the Start button still draws its swipe-up hint (a once-per-install hint: never reset by [reset]).
  static bool get showQuickColumnHint => _quickColumnOpens < quickColumnHintLimit;

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final storedPreset = prefs.getString(presetPrefKey);
    _preset = NavigationPreset.values.where((p) => p.name == storedPreset).firstOrNull ?? defaultPreset;
    _invertWheel = prefs.getBool(invertWheelPrefKey) ?? defaultInvertWheel;
    final storedLayout = prefs.getString(layoutPrefKey);
    _layoutPreference =
        LayoutPreference.values.where((p) => p.name == storedLayout).firstOrNull ?? LayoutPreference.automatic;
    _orbitSpeed = (prefs.getDouble(orbitSpeedPrefKey) ?? defaultOrbitSpeed).clamp(minOrbitSpeed, maxOrbitSpeed);
    _quickColumnOpens = prefs.getInt(quickColumnOpensPrefKey) ?? 0;
  }

  /// Counts one more user-opened quick column, towards dropping the swipe hint.
  static Future<void> noteQuickColumnOpened() async {
    if (!showQuickColumnHint) return;
    _quickColumnOpens++;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(quickColumnOpensPrefKey, _quickColumnOpens);
  }

  static Future<void> setPreset(NavigationPreset value) async {
    _preset = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(presetPrefKey, value.name);
  }

  static Future<void> setInvertWheel(bool value) async {
    _invertWheel = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(invertWheelPrefKey, value);
  }

  static Future<void> setOrbitSpeed(double value) async {
    _orbitSpeed = value.clamp(minOrbitSpeed, maxOrbitSpeed);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(orbitSpeedPrefKey, _orbitSpeed);
  }

  static Future<void> setLayoutPreference(LayoutPreference value) async {
    _layoutPreference = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(layoutPrefKey, value.name);
  }

  /// Puts every control back to its default.
  static Future<void> reset() async {
    await setPreset(defaultPreset);
    await setInvertWheel(defaultInvertWheel);
    await setOrbitSpeed(defaultOrbitSpeed);
    await setLayoutPreference(LayoutPreference.automatic);
  }
}
