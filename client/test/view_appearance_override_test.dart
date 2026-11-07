import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:didsa_cad_client/viewport3d/mesh_geometry.dart' show kSelectOtherDimOpacity, kNonPrimaryAssemblyOpacity;
import 'package:didsa_cad_client/viewport3d/view_appearance_override.dart';
import 'package:didsa_cad_client/viewport3d/view_preferences.dart';

void main() {
  const over = ViewAppearanceOverride(colourHex: '#112233', opacity: 0.4);

  group('resolveInstanceLook (placed sub-parts and sub-assemblies)', () {
    for (final overridden in [false, true]) {
      for (final painted in [false, true]) {
        for (final tinted in [false, true]) {
          for (final focused in [true, false]) {
            for (final dim in [false, true]) {
              final name = 'override=$overridden painted=$painted tinted=$tinted focused=$focused dim=$dim';
              test(name, () {
                final fade = focused ? 1.0 : kNonPrimaryAssemblyOpacity;
                final r = resolveInstanceLook(
                  override: overridden ? over : null,
                  hasLook: painted,
                  tintHex: tinted ? '#AA0000' : null,
                  fade: fade,
                  dim: dim,
                );
                // The override beats the look and the colour disc; without it nothing changes.
                expect(r.useLook, !overridden && painted);
                expect(r.colourHex, overridden ? '#112233' : (tinted ? '#AA0000' : null));
                final base = overridden ? 0.4 * fade : fade;
                expect(r.opacity, dim ? (base < kSelectOtherDimOpacity ? base : kSelectOtherDimOpacity) : base);
              });
            }
          }
        }
      }
    }
  });

  group('resolvePrimaryLook (the root Part\'s or the focused Part\'s bodies)', () {
    for (final overridden in [false, true]) {
      for (final painted in [false, true]) {
        for (final focusColour in [false, true]) {
          for (final dim in [false, true]) {
            test('override=$overridden painted=$painted focusColour=$focusColour dim=$dim', () {
              final r = resolvePrimaryLook(
                override: overridden ? over : null,
                hasLook: painted,
                focusColourHex: focusColour ? '#AA0000' : null,
                baseColourHex: '#B0B8C1',
                baseOpacity: 0.9,
                dim: dim,
              );
              expect(r.useLook, !overridden && painted);
              expect(r.colourHex, overridden ? '#112233' : (focusColour ? '#AA0000' : '#B0B8C1'));
              final base = overridden ? 0.4 : 0.9;
              expect(r.opacity, dim ? (base < kSelectOtherDimOpacity ? base : kSelectOtherDimOpacity) : base);
            });
          }
        }
      }
    }
  });

  test('ViewAppearanceOverride compares by value (the viewport rebuilds on a change only)', () {
    expect(const ViewAppearanceOverride(colourHex: '#112233', opacity: 0.4), over);
    expect(over == const ViewAppearanceOverride(colourHex: '#112233', opacity: 0.5), isFalse);
  });

  group('ViewPreferences override keys', () {
    test('default from the old body colour / opacity keys, and the old keys are not rewritten', () async {
      SharedPreferences.setMockInitialValues({'view_body_colour': '#6C8EAD', 'view_body_opacity': 0.7});
      await ViewPreferences.load();
      expect(ViewPreferences.overrideColourHex, '#6C8EAD');
      expect(ViewPreferences.overrideOpacity, 0.7);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('view_override_colour'), isFalse);
      expect(prefs.getString('view_body_colour'), '#6C8EAD');
    });

    test('an explicit new value wins and leaves the old key alone', () async {
      SharedPreferences.setMockInitialValues({
        'view_body_colour': '#6C8EAD',
        'view_body_opacity': 0.7,
        'view_override_colour': '#E8834A',
        'view_override_opacity': 0.25,
      });
      await ViewPreferences.load();
      expect(ViewPreferences.overrideColourHex, '#E8834A');
      expect(ViewPreferences.overrideOpacity, 0.25);
      await ViewPreferences.setOverrideColourHex('#4A9B8E');
      await ViewPreferences.setOverrideOpacity(0.5);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('view_override_colour'), '#4A9B8E');
      expect(prefs.getDouble('view_override_opacity'), 0.5);
      expect(prefs.getString('view_body_colour'), '#6C8EAD');
      expect(prefs.getDouble('view_body_opacity'), 0.7);
    });

    test('nothing stored: the defaults', () async {
      SharedPreferences.setMockInitialValues({});
      await ViewPreferences.load();
      expect(ViewPreferences.overrideColourHex, ViewPreferences.defaultBodyColourHex);
      expect(ViewPreferences.overrideOpacity, ViewPreferences.defaultBodyOpacity);
    });
  });
}
