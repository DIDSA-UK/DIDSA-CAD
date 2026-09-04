import 'package:shared_preferences/shared_preferences.dart';

import 'ai_prompt_addons.dart';
import 'ai_tool_groups.dart';

/// AI Modelling: the user-editable part of the scoping conversation's system
/// prompt (`ai_scoping_prompt.dart`) plus which manufacturing-process
/// add-ons (`ai_prompt_addons.dart`) are enabled - mirrors
/// `AiProviderPreferences`'s own `shared_preferences`-backed,
/// load-then-read-getters pattern exactly.
class AiSystemPromptPreferences {
  AiSystemPromptPreferences._();

  static const String overridePrefKey = 'ai_system_prompt_override';
  static const String enabledAddOnsPrefKey = 'ai_system_prompt_enabled_addons';
  static const String disabledToolGroupsPrefKey = 'ai_system_prompt_disabled_tool_groups';

  static String? _override;
  static Set<String> _enabledAddOns = const {};
  static Set<String> _disabledToolGroups = const {};

  /// Null means "use the default assistant instructions" - never an empty
  /// string on disk (see [setOverride]), so a caller never has to
  /// distinguish "unset" from "explicitly cleared".
  static String? get override => _override;

  /// Only ids present in [aiPromptAddOns] are meaningful - a stale id from a
  /// since-removed add-on is harmlessly ignored by
  /// `buildAiScopingSystemPrompt`, never surfaced as an error here.
  static Set<String> get enabledAddOns => _enabledAddOns;

  /// AI Settings -> Tools: `aiToolGroups` (`ai_tool_groups.dart`) ids
  /// currently turned off. Persists what's *off*, not what's on (inverted
  /// from [enabledAddOns]) so an empty/missing pref - the state of every
  /// install before this feature shipped - means "everything on," i.e. zero
  /// migration and identical behavior to before this preference existed. A
  /// stale id from a since-removed group is harmlessly ignored, same as
  /// [enabledAddOns].
  static Set<String> get disabledToolGroups => _disabledToolGroups;

  /// [disabledToolGroups] flattened into the raw plan-step `kind` strings
  /// they cover - what `PlanTranslator.execute`/`DocumentApiClient.
  /// validateAiPlan`'s own `disabledKinds` parameter actually needs; the
  /// backend only ever reasons about `kind`s, never "groups" (a client/UI-
  /// only concept).
  static Set<String> get disabledKinds => {
        for (final id in _disabledToolGroups) ...?aiToolGroups[id]?.kinds,
      };

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _override = prefs.getString(overridePrefKey);
    _enabledAddOns = (prefs.getStringList(enabledAddOnsPrefKey) ?? const []).toSet();
    _disabledToolGroups = (prefs.getStringList(disabledToolGroupsPrefKey) ?? const []).toSet();
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

  /// [enabled] true removes [id] from the disabled set (turns the tool
  /// group back on); false adds it (turns the tool group off).
  static Future<void> setToolGroupEnabled(String id, bool enabled) async {
    final next = Set<String>.from(_disabledToolGroups);
    if (enabled) {
      next.remove(id);
    } else {
      next.add(id);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(disabledToolGroupsPrefKey, next.toList());
    _disabledToolGroups = next;
  }
}
