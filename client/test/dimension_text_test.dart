import 'package:didsa_cad_client/sketch/dimension_text.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('dimensionValueText', () {
    test('shows the magnitude of a negative value', () {
      expect(dimensionValueText(-12.5), '12.50');
      expect(dimensionValueText(12.5), '12.50');
    });

    test('zero, negative zero and values that round to zero have no sign', () {
      expect(dimensionValueText(0), '0.00');
      expect(dimensionValueText(-0.0), '0.00');
      expect(dimensionValueText(-0.001), '0.00');
    });

    test('rounds to the requested decimals', () {
      expect(dimensionValueText(-1.005, decimals: 1), '1.0');
      expect(dimensionValueText(-45.04, decimals: 1), '45.0');
      expect(dimensionValueText(3.14159, decimals: 3), '3.142');
    });

    test('callers can add the radius, diameter and angle decoration', () {
      expect('R${dimensionValueText(-6)}', 'R6.00');
      expect('⌀${dimensionValueText(-12)}', '⌀12.00');
      expect('${dimensionValueText(-90, decimals: 1)}°', '90.0°');
    });
  });

  group('resolveDimensionSign', () {
    test('a plain number keeps the current side', () {
      expect(resolveDimensionSign(5, 3), 5);
      expect(resolveDimensionSign(5, -3), -5);
    });

    test('a leading minus flips the side', () {
      expect(resolveDimensionSign(-5, 3), -5);
      expect(resolveDimensionSign(-5, -3), 5);
    });

    test('a zero existing value counts as positive', () {
      expect(resolveDimensionSign(5, 0), 5);
      expect(resolveDimensionSign(-5, 0), -5);
    });
  });
}
