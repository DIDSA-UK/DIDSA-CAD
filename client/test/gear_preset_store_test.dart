import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:didsa_cad_client/gear/gear_preset_store.dart';

/// `docs/gear-design/09-presets.md`: [GearPresetStore] round-trip tests -
/// `shared_preferences` mocked the same way `part_screen_test.dart`'s own
/// setUp does (a real platform channel doesn't exist under `flutter test`).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('load starts empty with no stored presets', () async {
    await GearPresetStore.load();
    expect(GearPresetStore.all, isEmpty);
  });

  test('save persists a preset and load reads it back after a fresh load()', () async {
    await GearPresetStore.load();
    final saved = await GearPresetStore.save('My module-2 gear', 'gear_design', {
      'kind': 'external',
      'module': 2.0,
      'toothCount': '20',
    });

    expect(GearPresetStore.all, hasLength(1));
    expect(saved.name, 'My module-2 gear');

    // Simulate a fresh app session by resetting the in-memory cache via a
    // fresh load() - shared_preferences itself (the mock) still holds the
    // persisted value.
    await GearPresetStore.load();
    expect(GearPresetStore.all, hasLength(1));
    expect(GearPresetStore.all.single.fields['toothCount'], '20');
  });

  test('forKind only returns presets saved under that kind', () async {
    await GearPresetStore.load();
    await GearPresetStore.save('Gear preset', 'gear_design', {'module': 2.0});
    await GearPresetStore.save('Chain preset', 'gear_chain_design', {'module': 3.0});

    expect(GearPresetStore.forKind('gear_design'), hasLength(1));
    expect(GearPresetStore.forKind('gear_design').single.name, 'Gear preset');
    expect(GearPresetStore.forKind('bevel_design'), isEmpty);
  });

  test('delete removes the preset and persists the removal', () async {
    await GearPresetStore.load();
    final preset = await GearPresetStore.save('Temp', 'gear_design', {});
    expect(GearPresetStore.all, hasLength(1));

    await GearPresetStore.delete(preset.id);
    expect(GearPresetStore.all, isEmpty);

    await GearPresetStore.load();
    expect(GearPresetStore.all, isEmpty);
  });
}
