import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:didsa_cad_client/ai/ai_generation_mode.dart';

/// Multi-part/assembly overhaul, Phase A
/// (`docs/ai-modelling/13-multi-part-assembly-overhaul.md`):
/// [AiGenerationModePreferences] round-trip tests, mirroring
/// `ai_system_prompt_preferences_test.dart`'s own setUp/shape.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('load defaults to multiBodyPart on first-ever launch (the smaller, fully-built mode)', () async {
    await AiGenerationModePreferences.load();
    expect(AiGenerationModePreferences.defaultMode, AiGenerationMode.multiBodyPart);
  });

  test('setDefaultMode persists and load reads it back after a fresh load()', () async {
    await AiGenerationModePreferences.load();
    await AiGenerationModePreferences.setDefaultMode(AiGenerationMode.assembly);
    expect(AiGenerationModePreferences.defaultMode, AiGenerationMode.assembly);

    await AiGenerationModePreferences.load();
    expect(AiGenerationModePreferences.defaultMode, AiGenerationMode.assembly);
  });

  test('a stored value naming an unknown mode (e.g. from a future removed variant) falls back to multiBodyPart',
      () async {
    SharedPreferences.setMockInitialValues({'ai_generation_mode': 'not_a_real_mode'});
    await AiGenerationModePreferences.load();
    expect(AiGenerationModePreferences.defaultMode, AiGenerationMode.multiBodyPart);
  });
}
