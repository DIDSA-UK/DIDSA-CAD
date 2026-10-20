/// The Appearance tool's remembered colours and saved appearances (D4: "a short list of saved appearances (presets plus
/// your own) in their settings"), kept in `shared_preferences` like `ViewPreferences`.
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'appearance_rule.dart';

class AppearancePreferences {
  static const String recentPrefKey = 'appearance_recent_colours';
  static const String savedPrefKey = 'appearance_saved';
  static const int recentMax = 8;

  static Future<List<String>> recent() async {
    final prefs = await SharedPreferences.getInstance();
    return [for (final c in prefs.getStringList(recentPrefKey) ?? const <String>[]) if (isHexColour(c)) c];
  }

  /// Puts [hex] first in the recent colours (once), keeping [recentMax]. Returns the new list.
  static Future<List<String>> remember(String hex) async {
    if (!isHexColour(hex)) return recent();
    final list = [hex.toUpperCase(), ...(await recent()).where((c) => c.toUpperCase() != hex.toUpperCase())];
    final kept = list.take(recentMax).toList();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(recentPrefKey, kept);
    return kept;
  }

  /// The user's own saved appearances, `[(name, appearance)]` (the presets are `kAppearancePresets`).
  static Future<List<(String, Json)>> saved() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(savedPrefKey);
    if (raw == null) return const [];
    try {
      return [
        for (final e in jsonDecode(raw) as List)
          if (e is Map && e['name'] is String && e['appearance'] is Map && appearanceErrors(e['appearance']).isEmpty)
            (e['name'] as String, Map<String, dynamic>.from(e['appearance'] as Map)),
      ];
    } on FormatException {
      return const [];
    }
  }

  static Future<List<(String, Json)>> save(String name, Json appearance) async {
    final list = [...await saved(), (name, appearance)];
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(savedPrefKey, jsonEncode([for (final (n, a) in list) {'name': n, 'appearance': a}]));
    return list;
  }
}
