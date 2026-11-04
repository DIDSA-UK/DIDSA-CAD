import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/ai/ai_provider_settings_screen.dart';
import 'package:didsa_cad_client/ai/ai_theme.dart';

void main() {
  for (final brightness in [Brightness.light, Brightness.dark]) {
    testWidgets('AI screens follow the system brightness ($brightness)', (tester) async {
      tester.platformDispatcher.platformBrightnessTestValue = brightness;
      addTearDown(tester.platformDispatcher.clearAllTestValues);

      await tester.pumpWidget(const MaterialApp(home: AiProviderSettingsScreen()));
      await tester.pumpAndSettle();

      final context = tester.element(find.byType(Scaffold));
      expect(Theme.of(context).brightness, brightness);
      // Status colours resolve per-brightness and muted text is never a fixed white/black.
      final palette = AiPalette.of(context);
      expect(palette.muted, Theme.of(context).colorScheme.onSurfaceVariant);
      expect(Theme.of(context).scaffoldBackgroundColor, Theme.of(context).colorScheme.surface);
    });
  }
}
