import 'package:shared_preferences/shared_preferences.dart';

/// AI Modelling multi-part/assembly overhaul, Phase A
/// (`docs/ai-modelling/13-multi-part-assembly-overhaul.md`): the toggle
/// between the tool's two generation modes.
///
/// - [multiBodyPart]: recognizes distinct sub-parts in the request and
///   models each as its own independent Sketch->Extrude(+Feature) chain
///   inside one ordinary Part, never merged via boolean/merge unless asked -
///   `backend/app/document/extrude.py`'s `compute_part_bodies` already
///   tracks a Part's Bodies in a dict keyed by stable id, so this needs no
///   schema/translator/storage change at all, just new prompt vocabulary
///   (`ai_scoping_prompt.dart`'s `multiBodyPartVocabularyText`). The result
///   is one ordinary Part, saved (if at all) via the existing manual Save/
///   Save As flow - this mode never writes to disk on its own.
/// - [assembly]: recognizes distinct parts, saves each as its own file, then
///   creates/reuses an assembly file that inserts and mates them - the
///   large multi-phase build (Phases D/D2/E of the same overhaul doc). Only
///   a stub in Phase A/B/C - selecting it disables Send with an explanatory
///   banner until those phases land.
enum AiGenerationMode { multiBodyPart, assembly }

/// `shared_preferences`-backed default, mirroring `AiSystemPromptPreferences`'s
/// own load()/getter/setter pattern exactly. This is only the *default* a
/// fresh conversation starts from - `AiModellingScreen` also keeps its own
/// per-conversation override (the toggle itself), so switching mode mid-chat
/// never has to touch this static state.
class AiGenerationModePreferences {
  AiGenerationModePreferences._();

  static const String modePrefKey = 'ai_generation_mode';

  static AiGenerationMode _defaultMode = AiGenerationMode.multiBodyPart;

  /// Multi-body Part is the default, not Assembly - it's the smaller, fully-
  /// built mode (Phase A); Assembly is still a stub until Phases D/D2/E
  /// land, so defaulting to it would put a fresh conversation one tap away
  /// from a "coming soon" dead end.
  static AiGenerationMode get defaultMode => _defaultMode;

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(modePrefKey);
    _defaultMode = AiGenerationMode.values.asNameMap()[stored] ?? AiGenerationMode.multiBodyPart;
  }

  static Future<void> setDefaultMode(AiGenerationMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(modePrefKey, mode.name);
    _defaultMode = mode;
  }
}
