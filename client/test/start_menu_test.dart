import 'package:didsa_cad_client/assembly/assembly_lens.dart';
import 'package:didsa_cad_client/viewport3d/desktop_chrome.dart';
import 'package:didsa_cad_client/viewport3d/feature_picker_sheet.dart';
import 'package:didsa_cad_client/viewport3d/start_menu_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Start menu sheet on its own, over hand-made tabs (the PartScreen wiring is covered in part_screen_test.dart).
void main() {
  late AssemblyLens lens;
  late List<String> ran;
  late Map<AssemblyLens, String> remembered;
  late RibbonCommand? shown;

  List<RibbonTabData> tabs() {
    RibbonCommand command(String label, {bool enabled = true, bool selected = false, String? tooltip}) => RibbonCommand(
          label: label,
          icon: Icons.circle,
          tooltip: tooltip,
          selected: selected,
          onPressed: enabled ? () => ran.add(label) : null,
        );
    if (lens == AssemblyLens.part) {
      return [
        RibbonTabData(id: 'features', label: 'Features', groups: [
          RibbonGroup([command('New Sketch')]),
          RibbonGroup([command('Extrude'), command('Fillet', enabled: false, tooltip: 'Needs an edge')], title: 'Modify'),
        ]),
        RibbonTabData(id: 'evaluate', label: 'Evaluate', groups: [
          RibbonGroup([command('Measure', selected: true), command('Section')]),
        ]),
      ];
    }
    return [
      RibbonTabData(id: 'assembly', label: 'Assembly', groups: [
        RibbonGroup([command('Add Component'), command('Mate')]),
      ]),
      RibbonTabData(id: 'evaluate', label: 'Evaluate', groups: [
        RibbonGroup([command('Scenes')]),
      ]),
    ];
  }

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  shown = await showStartMenuSheet(
                    context,
                    tabs: tabs,
                    lens: () => lens,
                    onLensSwitch: () => lens = lens == AssemblyLens.part ? AssemblyLens.assembly : AssemblyLens.part,
                    initialTabId: (l) => remembered[l],
                    onTabChanged: (l, id) => remembered[l] = id,
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  setUp(() {
    lens = AssemblyLens.part;
    ran = [];
    remembered = {};
    shown = null;
  });

  testWidgets('shows the Part lens tabs, with the first tab selected and its groups and titles', (tester) async {
    await open(tester);
    expect(find.byKey(const ValueKey('start-menu')), findsOneWidget);
    expect(find.byKey(const ValueKey('ribbon-tab-features')), findsOneWidget);
    expect(find.byKey(const ValueKey('ribbon-tab-evaluate')), findsOneWidget);
    expect(find.byKey(const ValueKey('ribbon-tab-assembly')), findsNothing);
    expect(find.text('Modify'), findsOneWidget);
    expect(find.byKey(const ValueKey('start-tile-Extrude')), findsOneWidget);
    expect(find.byKey(const ValueKey('start-tile-Measure')), findsNothing, reason: 'only the selected tab is drawn');
  });

  testWidgets('switching tab shows that tab and remembers it for the lens', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('ribbon-tab-evaluate')));
    await tester.pump();
    expect(find.byKey(const ValueKey('start-tile-Measure')), findsOneWidget);
    expect(find.byKey(const ValueKey('start-tile-Extrude')), findsNothing);
    expect(remembered[AssemblyLens.part], 'evaluate');
  });

  testWidgets('opens on the remembered tab', (tester) async {
    remembered[AssemblyLens.part] = 'evaluate';
    await open(tester);
    expect(find.byKey(const ValueKey('start-tile-Measure')), findsOneWidget);
  });

  testWidgets('the lens switch swaps the tab set in place without closing the sheet', (tester) async {
    await open(tester);
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('start-lens')), matching: find.text('Assembly')));
    await tester.pump();
    expect(lens, AssemblyLens.assembly);
    expect(find.byKey(const ValueKey('start-menu')), findsOneWidget);
    expect(find.byKey(const ValueKey('ribbon-tab-assembly')), findsOneWidget);
    expect(find.byKey(const ValueKey('ribbon-tab-features')), findsNothing);
    expect(find.byKey(const ValueKey('start-tile-Mate')), findsOneWidget);

    await tester.tap(find.descendant(of: find.byKey(const ValueKey('start-lens')), matching: find.text('Part')));
    await tester.pump();
    expect(find.byKey(const ValueKey('start-tile-Extrude')), findsOneWidget);
  });

  testWidgets('tapping a tile closes the sheet and hands the command back unrun, for the caller to run', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('start-tile-Extrude')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('start-menu')), findsNothing);
    expect(shown?.label, 'Extrude');
    expect(ran, isEmpty, reason: 'the caller runs it once the sheet is gone');
    shown!.onPressed!();
    expect(ran, ['Extrude']);
  });

  testWidgets('a disabled tile does nothing but shows its tooltip on long press', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('start-tile-Fillet')));
    await tester.pump();
    expect(find.byKey(const ValueKey('start-menu')), findsOneWidget);
    expect(shown, isNull);
    await tester.longPress(find.byKey(const ValueKey('start-tile-Fillet')));
    await tester.pump();
    expect(find.text('Needs an edge'), findsOneWidget);
  });

  testWidgets('the close button dismisses it with no command', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('start-menu-close')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('start-menu')), findsNothing);
    expect(shown, isNull);
  });

  test('the shared feature table has every picker action exactly once', () {
    final actions = [for (final group in kFeatureGroups) for (final entry in group.entries) entry.action];
    expect(actions.toSet().length, actions.length, reason: 'no action listed twice');
    expect(actions.toSet(), FeaturePickerAction.values.toSet(), reason: 'no action missing from the table');
  });
}
