import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'orbit_camera.dart' show kDefaultFarClip;
import 'render_mode.dart';

/// Single source of truth for the Stage 18/19a 3D-viewport appearance
/// preferences - background colour, body colour, body opacity, render mode -
/// the same `shared_preferences`-backed, load-then-read-getters pattern
/// [ApiConfig] (`lib/config.dart`) already uses for connection details.
class ViewPreferences {
  ViewPreferences._();

  static const String bgColourPrefKey = 'view_bg_colour';
  static const String bodyColourPrefKey = 'view_body_colour';
  static const String bodyOpacityPrefKey = 'view_body_opacity';
  static const String renderModePrefKey = 'view_render_mode';
  // A4: perspective toggle (false = orthographic default per A4 brief)
  static const String perspectivePrefKey = 'view_perspective';
  // A3: manually-overridden far clip distance (mm)
  static const String farClipPrefKey = 'view_far_clip';
  // Camera-calibration debug aid (see triad.dart's own doc comment) -
  // temporary, reachable from the CAD settings screen off the connection
  // screen.
  static const String debugShowCameraOrientationPrefKey = 'view_debug_camera_orientation';

  /// Stage 19a Item 4: was `#1E1E2E` (Studio Dark) through Stage 18 - anyone
  /// who already has that stored keeps it (see [load]); this only changes
  /// the fallback for new installs / cleared preferences.
  static const String defaultBgColourHex = '#F5F5F0';

  /// Was `#B0B8C1` ("Aluminium") through the `UnlitMaterial`-only rendering
  /// era - changed to mid-grey alongside the `PhysicallyBasedMaterial`
  /// lighting/shading upgrade (see `scene_preferences.dart`), per the user's
  /// explicit requested default for the new Scene menu. Anyone with an
  /// existing stored value keeps it (see [load]) - this only changes the
  /// fallback for new installs / cleared preferences, same non-destructive
  /// convention as [defaultBgColourHex]'s own past change.
  static const String defaultBodyColourHex = '#808080';
  static const double defaultBodyOpacity = 1.0;

  /// Stage 19a Item 5: the most common default render mode in professional
  /// CAD tools (Fusion 360, SolidWorks, Onshape) - was [ViewportRenderMode.shaded].
  static const ViewportRenderMode defaultRenderMode = ViewportRenderMode.shadedWithEdges;

  // A4: orthographic off by default.
  static const bool defaultIsPerspective = false;
  // A3: default far clip imported from orbit_camera.dart's constant.
  static double get defaultFarClip => kDefaultFarClip;
  // On while the camera-calibration round is still active - see this key's
  // own doc comment.
  static const bool defaultDebugShowCameraOrientation = true;

  static String _bgColourHex = defaultBgColourHex;
  static String _bodyColourHex = defaultBodyColourHex;
  static double _bodyOpacity = defaultBodyOpacity;
  static ViewportRenderMode _renderMode = defaultRenderMode;
  static bool _isPerspective = defaultIsPerspective;
  static double _farClip = kDefaultFarClip;
  static bool _debugShowCameraOrientation = defaultDebugShowCameraOrientation;

  static String get bgColourHex => _bgColourHex;
  static String get bodyColourHex => _bodyColourHex;
  static double get bodyOpacity => _bodyOpacity;
  static ViewportRenderMode get renderMode => _renderMode;
  static bool get isPerspective => _isPerspective;
  static double get farClip => _farClip;
  static bool get debugShowCameraOrientation => _debugShowCameraOrientation;

  /// Populates the in-memory cache from `shared_preferences`, falling back to
  /// the defaults above for any key never [save]d. [renderModePrefKey] is
  /// stored as [ViewportRenderMode.name] - an unrecognised/corrupt stored
  /// string (e.g. from a future enum value an older client doesn't know
  /// about) falls back to [defaultRenderMode] rather than throwing.
  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _bgColourHex = prefs.getString(bgColourPrefKey) ?? defaultBgColourHex;
    _bodyColourHex = prefs.getString(bodyColourPrefKey) ?? defaultBodyColourHex;
    _bodyOpacity = prefs.getDouble(bodyOpacityPrefKey) ?? defaultBodyOpacity;
    final storedRenderMode = prefs.getString(renderModePrefKey);
    _renderMode = ViewportRenderMode.values.firstWhere(
      (mode) => mode.name == storedRenderMode,
      orElse: () => defaultRenderMode,
    );
    _isPerspective = prefs.getBool(perspectivePrefKey) ?? defaultIsPerspective;
    _farClip = prefs.getDouble(farClipPrefKey) ?? kDefaultFarClip;
    _debugShowCameraOrientation =
        prefs.getBool(debugShowCameraOrientationPrefKey) ?? defaultDebugShowCameraOrientation;
  }

  static Future<void> setBgColourHex(String hex) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(bgColourPrefKey, hex);
    _bgColourHex = hex;
  }

  static Future<void> setBodyColourHex(String hex) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(bodyColourPrefKey, hex);
    _bodyColourHex = hex;
  }

  static Future<void> setBodyOpacity(double opacity) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(bodyOpacityPrefKey, opacity);
    _bodyOpacity = opacity;
  }

  static Future<void> setRenderMode(ViewportRenderMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(renderModePrefKey, mode.name);
    _renderMode = mode;
  }

  static Future<void> setIsPerspective(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(perspectivePrefKey, value);
    _isPerspective = value;
  }

  static Future<void> setFarClip(double value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(farClipPrefKey, value);
    _farClip = value;
  }

  static Future<void> setDebugShowCameraOrientation(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(debugShowCameraOrientationPrefKey, value);
    _debugShowCameraOrientation = value;
  }
}

/// Parses a `"#RRGGBB"` string (as stored by [ViewPreferences]) into a
/// Flutter [Color] - forward-only construction via [Color.new], never
/// decomposing an existing [Color]'s channels, so this stays correct
/// regardless of which Flutter version's [Color] channel-accessor API ends
/// up in the lockfile.
Color colorFromHex(String hex) {
  final value = int.parse(hex.replaceFirst('#', ''), radix: 16);
  return Color(0xFF000000 | value);
}

/// Same forward-only conversion as [colorFromHex], but into the
/// `flutter_scene` material shape (`vm.Vector4`, 0..1 per channel) that
/// `UnlitMaterial.baseColorFactor` expects, with [opacity] as the alpha
/// channel.
vm.Vector4 vector4FromHex(String hex, {double opacity = 1.0}) {
  final value = int.parse(hex.replaceFirst('#', ''), radix: 16);
  final r = (value >> 16) & 0xFF;
  final g = (value >> 8) & 0xFF;
  final b = value & 0xFF;
  return vm.Vector4(r / 255.0, g / 255.0, b / 255.0, opacity);
}
