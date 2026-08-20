import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:didsa_cad_client/ai/ai_system_prompt_preferences.dart';

/// AI Modelling: [AiSystemPromptPreferences] round-trip tests, mirroring
/// `ai_provider_preferences_test.dart`'s own setUp/shape.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('load defaults to no override and no enabled add-ons on first-ever launch', () async {
    await AiSystemPromptPreferences.load();

    expect(AiSystemPromptPreferences.override, isNull);
    expect(AiSystemPromptPreferences.enabledAddOns, isEmpty);
  });

  test('setOverride persists text and load reads it back after a fresh load()', () async {
    await AiSystemPromptPreferences.load();
    await AiSystemPromptPreferences.setOverride('Be extra terse.');

    expect(AiSystemPromptPreferences.override, 'Be extra terse.');

    await AiSystemPromptPreferences.load();
    expect(AiSystemPromptPreferences.override, 'Be extra terse.');
  });

  test('setOverride with blank/whitespace-only text clears the override, same as resetToDefault', () async {
    await AiSystemPromptPreferences.load();
    await AiSystemPromptPreferences.setOverride('Custom instructions.');
    expect(AiSystemPromptPreferences.override, isNotNull);

    await AiSystemPromptPreferences.setOverride('   \n  ');
    expect(AiSystemPromptPreferences.override, isNull);

    await AiSystemPromptPreferences.load();
    expect(AiSystemPromptPreferences.override, isNull);
  });

  test('resetToDefault clears a previously-saved override', () async {
    await AiSystemPromptPreferences.load();
    await AiSystemPromptPreferences.setOverride('Custom instructions.');
    expect(AiSystemPromptPreferences.override, isNotNull);

    await AiSystemPromptPreferences.resetToDefault();
    expect(AiSystemPromptPreferences.override, isNull);

    await AiSystemPromptPreferences.load();
    expect(AiSystemPromptPreferences.override, isNull);
  });

  test('setAddOnEnabled adds/removes independently and persists across a fresh load()', () async {
    await AiSystemPromptPreferences.load();
    await AiSystemPromptPreferences.setAddOnEnabled('sheet_metal', true);
    await AiSystemPromptPreferences.setAddOnEnabled('machining', true);

    expect(AiSystemPromptPreferences.enabledAddOns, {'sheet_metal', 'machining'});

    await AiSystemPromptPreferences.setAddOnEnabled('sheet_metal', false);
    expect(AiSystemPromptPreferences.enabledAddOns, {'machining'});

    await AiSystemPromptPreferences.load();
    expect(AiSystemPromptPreferences.enabledAddOns, {'machining'});
  });
}
