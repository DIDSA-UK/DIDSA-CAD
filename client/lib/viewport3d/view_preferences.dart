import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vector_math/vector_math.dart' as vm;

/// Single source of truth for the Stage 18 3D-viewport appearance
/// preferences - background colour, body colour, body opacity - the same
/// `shared_preferences`-backed, load-then-read-getters pattern [ApiConfig]
/// (`lib/config.dart`) already uses for connection details.
class ViewPreferences {
  ViewPreferences._();

  static const String bgColourPrefKey = 'view_bg_colour';
  static const String bodyColourPrefKey = 'view_body_colour';
  static const String bodyOpacityPrefKey = 'view_body_opacity';

  static const String defaultBgColourHex = '#1E1E2E';
  static const String defaultBodyColourHex = '#B0B8C1';
  static const double defaultBodyOpacity = 1.0;

  static String _bgColourHex = defaultBgColourHex;
  static String _bodyColourHex = defaultBodyColourHex;
  static double _bodyOpacity = defaultBodyOpacity;

  static String get bgColourHex => _bgColourHex;
  static String get bodyColourHex => _bodyColourHex;
  static double get bodyOpacity => _bodyOpacity;

  /// Populates the in-memory cache from `shared_preferences`, falling back to
  /// the defaults above for any key never [save]d.
  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _bgColourHex = prefs.getString(bgColourPrefKey) ?? defaultBgColourHex;
    _bodyColourHex = prefs.getString(bodyColourPrefKey) ?? defaultBodyColourHex;
    _bodyOpacity = prefs.getDouble(bodyOpacityPrefKey) ?? defaultBodyOpacity;
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
