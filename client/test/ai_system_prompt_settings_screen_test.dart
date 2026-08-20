import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:didsa_cad_client/ai/ai_scoping_prompt.dart';
import 'package:didsa_cad_client/ai/ai_system_prompt_preferences.dart';
import 'package:didsa_cad_client/ai/ai_system_prompt_settings_screen.dart';

/// AI Modelling: widget-level coverage for [AiSystemPromptSettingsScreen] -
/// editing/saving/resetting the assistant-instructions override, and
/// toggling add-ons, each round-tripped through [AiSystemPromptPreferences].
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('pre-fills the instructions field with the default text on first launch', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: AiSystemPromptSettingsScreen()));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byKey(const Key('aiSystemPromptInstructions')));
    expect(field.controller?.text, defaultAssistantInstructions);
  });

  testWidgets('editing and saving persists a real override', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: AiSystemPromptSettingsScreen()));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('aiSystemPromptInstructions')), 'Only ever speak in haiku.');
    // The default instructions text is long enough that Save sits beyond
    // ListView's built extent at the default text size - scrollUntilVisible
    // (not ensureVisible, which requires the target to already be mounted)
    // scrolls incrementally until it is. `scrollable` must be given
    // explicitly: the default `find.byType(Scrollable)` matches both the
    // outer ListView's own Scrollable and the multi-line TextField's
    // internal one (EditableText wraps its own Scrollable for text
    // overflow), and scrollUntilVisible needs exactly one - `.first` is the
    // outer ListView's, found first in the depth-first Element walk.
    await tester.scrollUntilVisible(
      find.byKey(const Key('aiSystemPromptSave')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('aiSystemPromptSave')));
    await tester.pumpAndSettle();

    expect(AiSystemPromptPreferences.override, 'Only ever speak in haiku.');
  });

  testWidgets('Reset to default clears a saved override and restores the default text', (tester) async {
    SharedPreferences.setMockInitialValues({'ai_system_prompt_override': 'Custom instructions.'});
    await tester.pumpWidget(const MaterialApp(home: AiSystemPromptSettingsScreen()));
    await tester.pumpAndSettle();

    final fieldBefore = tester.widget<TextField>(find.byKey(const Key('aiSystemPromptInstructions')));
    expect(fieldBefore.controller?.text, 'Custom instructions.');

    await tester.tap(find.byKey(const Key('aiSystemPromptReset')));
    await tester.pumpAndSettle();

    expect(AiSystemPromptPreferences.override, isNull);
    final fieldAfter = tester.widget<TextField>(find.byKey(const Key('aiSystemPromptInstructions')));
    expect(fieldAfter.controller?.text, defaultAssistantInstructions);
  });

  testWidgets('toggling an add-on persists it as enabled', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: AiSystemPromptSettingsScreen()));
    await tester.pumpAndSettle();

    // Same reasoning as the Save-button fix above: the default instructions
    // text pushes the add-on switches beyond ListView's built extent, and
    // `scrollable` must be given explicitly for the same reason.
    await tester.scrollUntilVisible(
      find.byKey(const Key('aiPromptAddOn_sheet_metal')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('aiPromptAddOn_sheet_metal')));
    await tester.pumpAndSettle();

    expect(AiSystemPromptPreferences.enabledAddOns, contains('sheet_metal'));
  });
}
