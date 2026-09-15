import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/assembly/assembly_lens.dart';
import 'package:didsa_cad_client/assembly/assembly_lens_theme.dart';

void main() {
  final lightScheme = ColorScheme.fromSeed(seedColor: Colors.blue);
  final darkScheme = ColorScheme.fromSeed(seedColor: Colors.blue, brightness: Brightness.dark);

  group('assemblyLensAccentColor', () {
    test('Part lens resolves to the scheme\'s primary color (light)', () {
      expect(assemblyLensAccentColor(lightScheme, AssemblyLens.part), lightScheme.primary);
    });

    test('Assembly lens resolves to the scheme\'s tertiary color (light)', () {
      expect(assemblyLensAccentColor(lightScheme, AssemblyLens.assembly), lightScheme.tertiary);
    });

    test('Part lens resolves to the scheme\'s primary color (dark)', () {
      expect(assemblyLensAccentColor(darkScheme, AssemblyLens.part), darkScheme.primary);
    });

    test('Assembly lens resolves to the scheme\'s tertiary color (dark)', () {
      expect(assemblyLensAccentColor(darkScheme, AssemblyLens.assembly), darkScheme.tertiary);
    });

    test('Part and Assembly resolve to different colors for a real seeded scheme', () {
      expect(
        assemblyLensAccentColor(lightScheme, AssemblyLens.part),
        isNot(assemblyLensAccentColor(lightScheme, AssemblyLens.assembly)),
      );
    });
  });

  group('assemblyLensContainerColors', () {
    test('Part lens resolves to a neutral surface/onSurface pair', () {
      final (background, onBackground) = assemblyLensContainerColors(lightScheme, AssemblyLens.part);
      expect(background, lightScheme.surface);
      expect(onBackground, lightScheme.onSurface);
    });

    test('Assembly lens resolves to the tertiaryContainer/onTertiaryContainer pair', () {
      final (background, onBackground) =
          assemblyLensContainerColors(lightScheme, AssemblyLens.assembly);
      expect(background, lightScheme.tertiaryContainer);
      expect(onBackground, lightScheme.onTertiaryContainer);
    });

    test('Part and Assembly resolve to different background colors', () {
      final (partBackground, _) = assemblyLensContainerColors(lightScheme, AssemblyLens.part);
      final (assemblyBackground, _) = assemblyLensContainerColors(lightScheme, AssemblyLens.assembly);
      expect(partBackground, isNot(assemblyBackground));
    });
  });
}
