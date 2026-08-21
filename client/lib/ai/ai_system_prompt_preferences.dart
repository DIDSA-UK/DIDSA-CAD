import 'package:shared_preferences/shared_preferences.dart';

import 'ai_prompt_addons.dart';

/// AI Modelling: the user-editable part of the scoping conversation's system
/// prompt (`ai_scoping_prompt.dart`) plus which manufacturing-process
/// add-ons (`ai_prompt_addons.dart`) are enabled - mirrors
/// `AiProviderPreferences`'s own `shared_preferences`-backed,
/// load-then-read-getters pattern exactly.
class AiSystemPromptPreferences {
  AiSystemPromptPreferences._();

  static const String overridePrefKey = 'ai_system_prompt_override';
  static const String enabledAddOnsPrefKey = 'ai_system_prompt_enabled_addons';

  static String? _override;
  static Set<String> _enabledAddOns = const {};

  /// Null means "use the default assistant instructions" - never an empty
  /// string on disk (see [setOverride]), so a caller never has to
  /// distinguish "unset" from "explicitly cleared".
  static String? get override => _override;

  /// Only ids present in [aiPromptAddOns] are meaningful - a stale id from a
  /// since-removed add-on is harmlessly ignored by
  /// `buildAiScopingSystemPrompt`, never surfaced as an error here.
  static Set<String> get enabledAddOns => _enabledAddOns;

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _override = prefs.getString(overridePrefKey);
    _enabledAddOns = (prefs.getStringList(enabledAddOnsPrefKey) ?? const []).toSet();
  }

  /// A blank/whitespace-only [text] is treated the same as "Reset to
  /// default" - stores nothing rather than an override that reads as blank.
  static Future<void> setOverride(String? text) async {
    final prefs = await SharedPreferences.getInstance();
    final trimmed = text?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      await prefs.remove(overridePrefKey);
      _override = null;
    } else {
      await prefs.setString(overridePrefKey, trimmed);
      _override = trimmed;
    }
  }

  static Future<void> resetToDefault() => setOverride(null);

  static Future<void> setAddOnEnabled(String id, bool enabled) async {
    final next = Set<String>.from(_enabledAddOns);
    if (enabled) {
      next.add(id);
    } else {
      next.remove(id);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(enabledAddOnsPrefKey, next.toList());
    _enabledAddOns = next;
  }
}
