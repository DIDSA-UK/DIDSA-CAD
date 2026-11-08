import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/ai/ai_theme.dart' show AiPalette;
import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/viewport3d/assembly_tree_panel.dart';
import 'package:didsa_cad_client/viewport3d/pattern_context_menu.dart';

RigidTransformDto _identity() =>
    RigidTransformDto(translation: const [0, 0, 0], rotationAxis: const [0, 0, 1], rotationAngleDegrees: 0);

OccurrenceDto _occurrence(
  String id, {
  String? externalRef,
  String? resolvedPartId,
  String? nameOverride,
  bool hidden = false,
  bool suppressed = false,
  bool fixed = false,
  String? color,
}) =>
    OccurrenceDto(
      id: id,
      externalRef: externalRef,
      resolvedPartId: resolvedPartId,
      nameOverride: nameOverride,
      transform: _identity(),
      hidden: hidden,
      suppressed: suppressed,
      fixed: fixed,
      color: color,
    );

MateDto _mate(String id, {String type = 'coincident', bool suppressed = false}) => MateDto(
      id: id,
      type: type,
      references: const [],
      suppressed: suppressed,
    );

ComponentPatternDto _pattern(
  String id, {
  String patternType = 'linear',
  int count = 3,
  double angleTotal = 360.0,
  int countAngular = 1,
  bool suppressed = false,
}) =>
    ComponentPatternDto(
      id: id,
      sourceOccurrenceIds: const ['o1'],
      patternType: patternType,
      direction: const [1.0, 0.0, 0.0],
      count: count,
      angleTotal: angleTotal,
      countAngular: countAngular,
      suppressed: suppressed,
    );

Widget _wrap(AssemblyTreePanel panel) => MaterialApp(home: Scaffold(body: panel));

void main() {
  group('occurrenceDisplayName', () {
    test('prefers nameOverride when set', () {
      final occurrences = [_occurrence('o1', externalRef: 'parts/bolt.didsa', nameOverride: 'My Bolt')];
      expect(occurrenceDisplayName(occurrences, 0), 'My Bolt');
    });

    test('falls back to the externalRef file basename without extension', () {
      final occurrences = [_occurrence('o1', externalRef: 'parts/sub/bracket.didsa')];
      expect(occurrenceDisplayName(occurrences, 0), 'bracket');
    });

    test('a generated file name (UUID / hex id) is not a name: "Component N" instead, counted by position', () {
      final occurrences = [
        _occurrence('o1', externalRef: 'parts/bracket.didsa'),
        _occurrence('o2', externalRef: 'parts/a441a4ab-e3b7-4c63-8784-aec0d5159295.didsa'),
        _occurrence('o3', externalRef: 'parts/part-3f2a9c41d07e5b8a1c2d.didsa'),
        _occurrence('o4', externalRef: 'parts/Bolt M8.didsa'),
      ];
      expect([for (var i = 0; i < 4; i++) occurrenceDisplayName(occurrences, i)], ['bracket', 'Component 2', 'Component 3', 'Bolt M8']);
      expect(occurrenceDisplayNames(occurrences), {'o1': 'bracket', 'o2': 'Component 2', 'o3': 'Component 3', 'o4': 'Bolt M8'});
    });

    test('looksGeneratedName: uuids and long hex ids yes, ordinary names no', () {
      for (final g in ['a441a4ab-e3b7-4c63-8784-aec0d5159295', 'a441a4abe3b74c638784aec0d5159295', 'occ_3f2a9c41d07e5b8a1c2d', '']) {
        expect(looksGeneratedName(g), isTrue, reason: g);
      }
      for (final n in ['bolt', 'Plate 2', 'cafe', 'deadbeef', 'M8x30', 'Bracket-A']) {
        expect(looksGeneratedName(n), isFalse, reason: n);
      }
    });

    test('B4: a part placed more than once is numbered <base>:<n>; overrides are verbatim; a lone part is plain', () {
      final occurrences = [
        _occurrence('o1', externalRef: 'parts/LONG_RAIL_001.didsa', resolvedPartId: 'rail'),
        _occurrence('o2', externalRef: 'parts/LONG_RAIL_001.didsa', resolvedPartId: 'rail'),
        _occurrence('o3', externalRef: 'parts/LONG_RAIL_001.didsa', resolvedPartId: 'rail', nameOverride: 'Rail Left'),
        _occurrence('o4', externalRef: 'parts/GUSSET_001.didsa', resolvedPartId: 'gusset'),
      ];
      expect([for (var i = 0; i < 4; i++) occurrenceDisplayName(occurrences, i)],
          ['LONG_RAIL_001:1', 'LONG_RAIL_001:2', 'Rail Left', 'GUSSET_001']);
    });

    test('B4: pattern copies read "Source [Linear 1 #2]" and nested paths show their last segment', () {
      final occurrences = [_occurrence('o1', externalRef: 'parts/bolt.didsa', nameOverride: 'Short Rail BOT_RIGHT')];
      final patterns = [_pattern('p1')];
      expect(occurrencePathDisplayName('o1#pattern:p1:1', occurrences, patterns: patterns), 'Short Rail BOT_RIGHT [Linear 1 #2]');
      expect(occurrencePathDisplayName('x/o1', occurrences, patterns: patterns), 'Short Rail BOT_RIGHT');
      final names = occurrenceDisplayNames(occurrences, patterns: patterns, extraPaths: const ['o1#pattern:p1:1', 'o1']);
      expect(names['o1#pattern:p1:1'], 'Short Rail BOT_RIGHT [Linear 1 #2]');
      expect(names['o1'], 'Short Rail BOT_RIGHT');
    });

    test('falls back to an ordinal "Component N" when neither is available', () {
      final occurrences = [_occurrence('o1'), _occurrence('o2')];
      expect(occurrenceDisplayName(occurrences, 0), 'Component 1');
      expect(occurrenceDisplayName(occurrences, 1), 'Component 2');
    });
  });

  group('mateDisplayName', () {
    test('labels by type with a per-type ordinal', () {
      final mates = [_mate('m1', type: 'coincident'), _mate('m2', type: 'concentric'), _mate('m3', type: 'coincident')];
      expect(mateDisplayName(mates, 0), 'Coincident 1');
      expect(mateDisplayName(mates, 1), 'Concentric 1');
      expect(mateDisplayName(mates, 2), 'Coincident 2');
    });
  });

  group('componentPatternDisplayName', () {
    test('labels by type with a per-type ordinal', () {
      final patterns = [
        _pattern('p1', patternType: 'linear'),
        _pattern('p2', patternType: 'circular'),
        _pattern('p3', patternType: 'linear'),
      ];
      expect(componentPatternDisplayName(patterns, 0), 'Linear 1');
      expect(componentPatternDisplayName(patterns, 1), 'Circular 1');
      expect(componentPatternDisplayName(patterns, 2), 'Linear 2');
    });
  });

  group('componentPatternSummary', () {
    test('a linear pattern shows its instance count', () {
      expect(componentPatternSummary(_pattern('p1', patternType: 'linear', count: 4)), '×4');
    });

    test('a full-circle circular pattern omits the redundant angle', () {
      expect(
        componentPatternSummary(_pattern('p1', patternType: 'circular', countAngular: 6, angleTotal: 360.0)),
        '×6',
      );
    });

    test('a partial-sweep circular pattern shows its angle', () {
      expect(
        componentPatternSummary(_pattern('p1', patternType: 'circular', countAngular: 3, angleTotal: 270.0)),
        '×3 (270°)',
      );
    });
  });

  testWidgets('"Assembly Tree" is the panel title', (tester) async {
    await tester.pumpWidget(
      _wrap(
        AssemblyTreePanel(
          visible: true,
          occurrences: const [],
          mates: const [],
          selectedOccurrenceId: null,
          onOccurrenceTap: (_) {},
          onOccurrenceLongPress: (_) {},
          onClose: () {},
        ),
      ),
    );

    expect(find.text('Assembly Tree'), findsOneWidget);
  });

  testWidgets('Phase 3b: the header is tinted with the theme\'s tertiaryContainer accent', (tester) async {
    final colorScheme = ColorScheme.fromSeed(seedColor: Colors.blue);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(colorScheme: colorScheme),
        home: Scaffold(
          body: AssemblyTreePanel(
            visible: true,
            occurrences: const [],
            mates: const [],
            selectedOccurrenceId: null,
            onOccurrenceTap: (_) {},
            onOccurrenceLongPress: (_) {},
            onClose: () {},
          ),
        ),
      ),
    );

    final header = tester.widget<Container>(
      find.ancestor(of: find.text('Assembly Tree'), matching: find.byType(Container)).first,
    );
    expect(header.color, colorScheme.tertiaryContainer);
    final title = tester.widget<Text>(find.text('Assembly Tree'));
    expect(title.style?.color, colorScheme.onTertiaryContainer);
  });

  testWidgets('shows an empty-state message when there are no occurrences or mates', (tester) async {
    await tester.pumpWidget(
      _wrap(
        AssemblyTreePanel(
          visible: true,
          occurrences: const [],
          mates: const [],
          selectedOccurrenceId: null,
          onOccurrenceTap: (_) {},
          onOccurrenceLongPress: (_) {},
          onClose: () {},
        ),
      ),
    );

    expect(find.text('No components yet'), findsOneWidget);
    expect(find.text('Components'), findsNothing);
  });

  testWidgets('Components section lists occurrences; Mates section is hidden when there are none', (tester) async {
    await tester.pumpWidget(
      _wrap(
        AssemblyTreePanel(
          visible: true,
          occurrences: [_occurrence('o1', externalRef: 'parts/bolt.didsa')],
          mates: const [],
          selectedOccurrenceId: null,
          onOccurrenceTap: (_) {},
          onOccurrenceLongPress: (_) {},
          onClose: () {},
        ),
      ),
    );

    expect(find.text('Components'), findsOneWidget);
    expect(find.text('Mates'), findsNothing);
    expect(find.text('bolt'), findsOneWidget);
  });

  testWidgets('a hidden occurrence shows the visibility-off trailing icon', (tester) async {
    await tester.pumpWidget(
      _wrap(
        AssemblyTreePanel(
          visible: true,
          occurrences: [_occurrence('o1', externalRef: 'parts/bolt.didsa', hidden: true)],
          mates: const [],
          selectedOccurrenceId: null,
          onOccurrenceTap: (_) {},
          onOccurrenceLongPress: (_) {},
          onClose: () {},
        ),
      ),
    );

    // Bug report (assembly testing): the row's own visibility icon is now
    // an always-visible interactive toggle (see the "inline visibility
    // toggle" test group below), not the old plain-Icon read-only trailing
    // marker - `Icons.visibility_off_outlined` mirrors
    // `component_context_menu.dart`'s own Hide/Show icon pair exactly.
    expect(find.byIcon(Icons.visibility_off_outlined), findsOneWidget);
  });

  // --- Bug report (assembly testing): the inline visibility toggle/colour
  // disc ("add two toggles in line with the part names") -----------------

  testWidgets('a visible occurrence shows the visibility-on trailing icon', (tester) async {
    await tester.pumpWidget(
      _wrap(
        AssemblyTreePanel(
          visible: true,
          occurrences: [_occurrence('o1', externalRef: 'parts/bolt.didsa')],
          mates: const [],
          selectedOccurrenceId: null,
          onOccurrenceTap: (_) {},
          onOccurrenceLongPress: (_) {},
          onClose: () {},
        ),
      ),
    );

    expect(find.byIcon(Icons.visibility_outlined), findsOneWidget);
    expect(find.byIcon(Icons.visibility_off_outlined), findsNothing);
  });

  testWidgets('tapping the visibility toggle calls onOccurrenceVisibilityToggle with that occurrence',
      (tester) async {
    final occurrence = _occurrence('o1', externalRef: 'parts/bolt.didsa');
    OccurrenceDto? toggled;
    await tester.pumpWidget(
      _wrap(
        AssemblyTreePanel(
          visible: true,
          occurrences: [occurrence],
          mates: const [],
          selectedOccurrenceId: null,
          onOccurrenceTap: (_) {},
          onOccurrenceLongPress: (_) {},
          onOccurrenceVisibilityToggle: (o) => toggled = o,
          onClose: () {},
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.visibility_outlined));
    expect(toggled, same(occurrence));
  });

  testWidgets('tapping the visibility toggle does not also trigger onOccurrenceTap', (tester) async {
    bool rowTapped = false;
    OccurrenceDto? toggled;
    await tester.pumpWidget(
      _wrap(
        AssemblyTreePanel(
          visible: true,
          occurrences: [_occurrence('o1', externalRef: 'parts/bolt.didsa')],
          mates: const [],
          selectedOccurrenceId: null,
          onOccurrenceTap: (_) => rowTapped = true,
          onOccurrenceLongPress: (_) {},
          onOccurrenceVisibilityToggle: (o) => toggled = o,
          onClose: () {},
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.visibility_outlined));
    expect(toggled, isNotNull);
    expect(rowTapped, isFalse);
  });

  testWidgets('the colour disc calls onOccurrenceColorTap with that occurrence when tapped', (tester) async {
    final occurrence = _occurrence('o1', externalRef: 'parts/bolt.didsa', color: '#FF8800');
    OccurrenceDto? tapped;
    await tester.pumpWidget(
      _wrap(
        AssemblyTreePanel(
          visible: true,
          occurrences: [occurrence],
          mates: const [],
          selectedOccurrenceId: null,
          onOccurrenceTap: (_) {},
          onOccurrenceLongPress: (_) {},
          onOccurrenceColorTap: (o) => tapped = o,
          onClose: () {},
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('occurrence-color-disc-o1')));
    expect(tapped, same(occurrence));
  });

  testWidgets('an occurrence with no colour override does not crash rendering the disc', (tester) async {
    await tester.pumpWidget(
      _wrap(
        AssemblyTreePanel(
          visible: true,
          occurrences: [_occurrence('o1', externalRef: 'parts/bolt.didsa')],
          mates: const [],
          selectedOccurrenceId: null,
          onOccurrenceTap: (_) {},
          onOccurrenceLongPress: (_) {},
          onClose: () {},
        ),
      ),
    );

    expect(find.text('bolt'), findsOneWidget);
  });

  // Bug report (assembly testing): "Long pressing a part in the assembly
  // tree should offer the option to fix/float" - the tree row itself shows
  // a pin icon so a fixed component is visible without opening the menu.
  testWidgets('a fixed occurrence shows the push-pin trailing icon', (tester) async {
    await tester.pumpWidget(
      _wrap(
        AssemblyTreePanel(
          visible: true,
          occurrences: [_occurrence('o1', externalRef: 'parts/bolt.didsa', fixed: true)],
          mates: const [],
          selectedOccurrenceId: null,
          onOccurrenceTap: (_) {},
          onOccurrenceLongPress: (_) {},
          onClose: () {},
        ),
      ),
    );

    expect(find.byIcon(Icons.push_pin), findsOneWidget);
  });

  testWidgets('an unresolved occurrence (no resolvedPartId) shows "Missing file"', (tester) async {
    await tester.pumpWidget(
      _wrap(
        AssemblyTreePanel(
          visible: true,
          occurrences: [_occurrence('o1', externalRef: 'parts/bolt.didsa', resolvedPartId: null)],
          mates: const [],
          selectedOccurrenceId: null,
          onOccurrenceTap: (_) {},
          onOccurrenceLongPress: (_) {},
          onClose: () {},
        ),
      ),
    );

    expect(find.text('Missing file'), findsOneWidget);
    expect(find.byIcon(Icons.link_off), findsOneWidget);
  });

  testWidgets('tapping an occurrence row calls onOccurrenceTap with that occurrence', (tester) async {
    final occurrence = _occurrence('o1', externalRef: 'parts/bolt.didsa', resolvedPartId: 'part-x');
    OccurrenceDto? tapped;
    await tester.pumpWidget(
      _wrap(
        AssemblyTreePanel(
          visible: true,
          occurrences: [occurrence],
          mates: const [],
          selectedOccurrenceId: null,
          onOccurrenceTap: (o) => tapped = o,
          onOccurrenceLongPress: (_) {},
          onClose: () {},
        ),
      ),
    );

    await tester.tap(find.text('bolt'));
    await tester.pumpAndSettle();

    expect(tapped, same(occurrence));
  });

  testWidgets('long-pressing an occurrence row calls onOccurrenceLongPress', (tester) async {
    final occurrence = _occurrence('o1', externalRef: 'parts/bolt.didsa', resolvedPartId: 'part-x');
    OccurrenceDto? longPressed;
    await tester.pumpWidget(
      _wrap(
        AssemblyTreePanel(
          visible: true,
          occurrences: [occurrence],
          mates: const [],
          selectedOccurrenceId: null,
          onOccurrenceTap: (_) {},
          onOccurrenceLongPress: (o) => longPressed = o,
          onClose: () {},
        ),
      ),
    );

    await tester.longPress(find.text('bolt'));
    await tester.pumpAndSettle();

    expect(longPressed, same(occurrence));
  });

  testWidgets('Mates section lists mates by display name and responds to tap/long-press', (tester) async {
    final mate = _mate('m1', type: 'coincident');
    MateDto? tapped;
    MateDto? longPressed;
    await tester.pumpWidget(
      _wrap(
        AssemblyTreePanel(
          visible: true,
          occurrences: const [],
          mates: [mate],
          selectedOccurrenceId: null,
          onOccurrenceTap: (_) {},
          onOccurrenceLongPress: (_) {},
          onClose: () {},
          onMateTap: (m) => tapped = m,
          onMateLongPress: (m) => longPressed = m,
        ),
      ),
    );

    expect(find.text('Mates'), findsOneWidget);
    expect(find.text('Coincident 1'), findsOneWidget);

    await tester.tap(find.text('Coincident 1'));
    await tester.pumpAndSettle();
    expect(tapped, same(mate));

    await tester.longPress(find.text('Coincident 1'));
    await tester.pumpAndSettle();
    expect(longPressed, same(mate));
  });

  testWidgets('a suppressed mate is dimmed and shows the visibility-off trailing icon', (tester) async {
    await tester.pumpWidget(
      _wrap(
        AssemblyTreePanel(
          visible: true,
          occurrences: const [],
          mates: [_mate('m1', suppressed: true)],
          selectedOccurrenceId: null,
          onOccurrenceTap: (_) {},
          onOccurrenceLongPress: (_) {},
          onClose: () {},
        ),
      ),
    );

    expect(find.byIcon(Icons.visibility_off), findsOneWidget);
  });

  testWidgets('the close button calls onClose', (tester) async {
    bool closed = false;
    await tester.pumpWidget(
      _wrap(
        AssemblyTreePanel(
          visible: true,
          occurrences: const [],
          mates: const [],
          selectedOccurrenceId: null,
          onOccurrenceTap: (_) {},
          onOccurrenceLongPress: (_) {},
          onClose: () => closed = true,
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.close));
    expect(closed, isTrue);
  });

  testWidgets('Patterns section lists patterns by display name, hidden by default when empty', (tester) async {
    await tester.pumpWidget(
      _wrap(
        AssemblyTreePanel(
          visible: true,
          occurrences: const [],
          mates: const [],
          selectedOccurrenceId: null,
          onOccurrenceTap: (_) {},
          onOccurrenceLongPress: (_) {},
          onClose: () {},
        ),
      ),
    );

    expect(find.text('Patterns'), findsNothing);
  });

  testWidgets('Patterns section shows a row with a summary subtitle', (tester) async {
    await tester.pumpWidget(
      _wrap(
        AssemblyTreePanel(
          visible: true,
          occurrences: const [],
          mates: const [],
          patterns: [_pattern('p1', patternType: 'linear', count: 5)],
          selectedOccurrenceId: null,
          onOccurrenceTap: (_) {},
          onOccurrenceLongPress: (_) {},
          onClose: () {},
        ),
      ),
    );

    expect(find.text('Patterns'), findsOneWidget);
    expect(find.text('Linear 1'), findsOneWidget);
    expect(find.text('×5'), findsOneWidget);
  });

  testWidgets('a suppressed pattern is dimmed and shows the visibility-off trailing icon', (tester) async {
    await tester.pumpWidget(
      _wrap(
        AssemblyTreePanel(
          visible: true,
          occurrences: const [],
          mates: const [],
          patterns: [_pattern('p1', suppressed: true)],
          selectedOccurrenceId: null,
          onOccurrenceTap: (_) {},
          onOccurrenceLongPress: (_) {},
          onClose: () {},
        ),
      ),
    );

    expect(find.byIcon(Icons.visibility_off), findsOneWidget);
  });

  // --- Phase 11 (`docs/assembly-scope.md` §6 `[8]`) -------------------------

  testWidgets('tapping a pattern row calls onPatternTap when wired', (tester) async {
    final pattern = _pattern('p1', patternType: 'linear', count: 5);
    ComponentPatternDto? tapped;
    await tester.pumpWidget(
      _wrap(
        AssemblyTreePanel(
          visible: true,
          occurrences: const [],
          mates: const [],
          patterns: [pattern],
          selectedOccurrenceId: null,
          onOccurrenceTap: (_) {},
          onOccurrenceLongPress: (_) {},
          onClose: () {},
          onPatternTap: (p) => tapped = p,
        ),
      ),
    );

    await tester.tap(find.text('Linear 1'));
    await tester.pumpAndSettle();
    expect(tapped, same(pattern));
  });

  testWidgets('long-pressing a pattern row calls onPatternLongPress when wired', (tester) async {
    final pattern = _pattern('p1', patternType: 'circular', count: 1, countAngular: 4);
    ComponentPatternDto? longPressed;
    await tester.pumpWidget(
      _wrap(
        AssemblyTreePanel(
          visible: true,
          occurrences: const [],
          mates: const [],
          patterns: [pattern],
          selectedOccurrenceId: null,
          onOccurrenceTap: (_) {},
          onOccurrenceLongPress: (_) {},
          onClose: () {},
          onPatternLongPress: (p) => longPressed = p,
        ),
      ),
    );

    await tester.longPress(find.text('Circular 1'));
    await tester.pumpAndSettle();
    expect(longPressed, same(pattern));
  });

  // --- Bug fix: focus breadcrumb ---------------------------------------
  // A focused Part with no Occurrences of its own previously rendered the
  // plain "No components yet" empty state with nothing at all to
  // long-press "Exit Focus" on - no way back out via the tree. The
  // breadcrumb row (shown whenever `focusedLabel` is set) fixes that.

  testWidgets('no breadcrumb row when focusedLabel is null', (tester) async {
    await tester.pumpWidget(
      _wrap(
        AssemblyTreePanel(
          visible: true,
          occurrences: const [],
          mates: const [],
          selectedOccurrenceId: null,
          onOccurrenceTap: (_) {},
          onOccurrenceLongPress: (_) {},
          onClose: () {},
        ),
      ),
    );

    expect(find.byIcon(Icons.arrow_back), findsNothing);
    expect(find.text('No components yet'), findsOneWidget);
  });

  testWidgets('a focused Part with no Occurrences shows the breadcrumb, not just an empty state', (tester) async {
    await tester.pumpWidget(
      _wrap(
        AssemblyTreePanel(
          visible: true,
          occurrences: const [],
          mates: const [],
          selectedOccurrenceId: null,
          onOccurrenceTap: (_) {},
          onOccurrenceLongPress: (_) {},
          onClose: () {},
          focusedLabel: 'Bracket',
        ),
      ),
    );

    expect(find.byIcon(Icons.arrow_back), findsOneWidget);
    expect(find.text('Bracket'), findsOneWidget);
    expect(find.text('This component has no sub-components of its own'), findsOneWidget);
    expect(find.text('No components yet'), findsNothing);
  });

  testWidgets('tapping the breadcrumb calls onExitFocus', (tester) async {
    bool exited = false;
    await tester.pumpWidget(
      _wrap(
        AssemblyTreePanel(
          visible: true,
          occurrences: const [],
          mates: const [],
          selectedOccurrenceId: null,
          onOccurrenceTap: (_) {},
          onOccurrenceLongPress: (_) {},
          onClose: () {},
          focusedLabel: 'Bracket',
          onExitFocus: () => exited = true,
        ),
      ),
    );

    await tester.tap(find.text('Bracket'));
    expect(exited, isTrue);
  });

  testWidgets('the breadcrumb still shows above a non-empty tree while focused', (tester) async {
    await tester.pumpWidget(
      _wrap(
        AssemblyTreePanel(
          visible: true,
          occurrences: [_occurrence('o1', externalRef: 'parts/bolt.didsa')],
          mates: const [],
          selectedOccurrenceId: null,
          onOccurrenceTap: (_) {},
          onOccurrenceLongPress: (_) {},
          onClose: () {},
          focusedLabel: 'Bracket',
        ),
      ),
    );

    expect(find.byIcon(Icons.arrow_back), findsOneWidget);
    expect(find.text('bolt'), findsOneWidget);
  });

  testWidgets('a pattern row is inert (no tap/long-press callback invoked) when neither is wired', (tester) async {
    await tester.pumpWidget(
      _wrap(
        AssemblyTreePanel(
          visible: true,
          occurrences: const [],
          mates: const [],
          patterns: [_pattern('p1')],
          selectedOccurrenceId: null,
          onOccurrenceTap: (_) {},
          onOccurrenceLongPress: (_) {},
          onClose: () {},
        ),
      ),
    );

    final tile = tester.widget<ListTile>(find.byType(ListTile).last);
    expect(tile.onTap, isNull);
    expect(tile.onLongPress, isNull);
  });

  // Bug report 2026-10-14, item 4: the multi-select bar used to sit in a bottom
  // sheet stacked over the tree, covering its lowest rows so they could not be
  // tapped. It now replaces the panel's title row.
  group('multiSelectHeader (item 4)', () {
    testWidgets('replaces the title row (title and Close), in the panel itself', (tester) async {
      await tester.pumpWidget(
        _wrap(
          AssemblyTreePanel(
            visible: true,
            occurrences: [_occurrence('o1')],
            mates: const [],
            selectedOccurrenceId: null,
            onOccurrenceTap: (_) {},
            onOccurrenceLongPress: (_) {},
            onClose: () {},
            isMultiSelectMode: true,
            selectedMultiSelectIds: const {'o1'},
            onMultiSelectToggle: (_) {},
            multiSelectHeader: const Text('bar-marker'),
          ),
        ),
      );

      expect(find.text('bar-marker'), findsOneWidget);
      expect(find.text('Assembly Tree'), findsNothing);
      expect(find.byTooltip('Close'), findsNothing);
    });

    testWidgets('with a tree taller than the screen, the last visible row can still be tapped to toggle', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(800, 600);
      addTearDown(tester.view.reset);
      final toggled = <String>[];
      final occurrences = [for (var i = 1; i <= 40; i++) _occurrence('o$i', nameOverride: 'Part $i')];
      await tester.pumpWidget(
        _wrap(
          AssemblyTreePanel(
            visible: true,
            occurrences: occurrences,
            mates: const [],
            selectedOccurrenceId: null,
            onOccurrenceTap: (_) {},
            onOccurrenceLongPress: (_) {},
            onClose: () {},
            isMultiSelectMode: true,
            selectedMultiSelectIds: const {'o1'},
            onMultiSelectToggle: toggled.add,
            multiSelectHeader: const SizedBox(height: 48, child: Text('bar-marker')),
          ),
        ),
      );

      // Scroll the list to its end, then tap the bottom-most row on screen:
      // nothing is stacked over it any more.
      await tester.drag(find.byType(ListView).first, const Offset(0, -5000));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Part 40'));
      await tester.pump();

      expect(toggled, ['o40']);
    });
  });

  // Bug report 2026-10-14, item 7: one status-icon slot per row.
  group('constraint badge (item 7)', () {
    Widget panelWith(List<OccurrenceDto> occurrences, Map<String, ConstraintStatusDto> status) => _wrap(
      AssemblyTreePanel(
        visible: true,
        occurrences: occurrences,
        mates: const [],
        selectedOccurrenceId: null,
        onOccurrenceTap: (_) {},
        onOccurrenceLongPress: (_) {},
        onClose: () {},
        constraintStatusByOccurrenceId: status,
      ),
    );

    testWidgets('fully constrained shows a lock, under-constrained an open lock naming the dof, over a warning', (
      tester,
    ) async {
      await tester.pumpWidget(
        panelWith(
          [_occurrence('a', nameOverride: 'A'), _occurrence('b', nameOverride: 'B'), _occurrence('c', nameOverride: 'C')],
          const {
            'a': ConstraintStatusDto(state: ConstraintState.fullyConstrained, dof: 0),
            'b': ConstraintStatusDto(state: ConstraintState.underConstrained, dof: 3),
            'c': ConstraintStatusDto(state: ConstraintState.overConstrained, dof: 0),
          },
        ),
      );

      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
      expect(find.byIcon(Icons.lock_open), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
      expect(find.byTooltip('Fully constrained'), findsOneWidget);
      expect(find.byTooltip('Under-constrained - 3 degrees of freedom'), findsOneWidget);
      expect(find.byTooltip('Over-constrained - mates conflict'), findsOneWidget);
    });

    testWidgets('a fixed occurrence keeps the push-pin, whether or not a status was fetched', (tester) async {
      await tester.pumpWidget(
        panelWith([_occurrence('a', nameOverride: 'A', fixed: true), _occurrence('b', nameOverride: 'B', fixed: true)], const {
          'a': ConstraintStatusDto(state: ConstraintState.fixed, dof: 0),
        }),
      );
      expect(find.byIcon(Icons.push_pin), findsNWidgets(2));
    });

    testWidgets('with no status at all, a free occurrence shows no badge', (tester) async {
      await tester.pumpWidget(panelWith([_occurrence('a', nameOverride: 'A')], const {}));
      expect(find.byIcon(Icons.lock_outline), findsNothing);
      expect(find.byIcon(Icons.lock_open), findsNothing);
      expect(find.byIcon(Icons.push_pin), findsNothing);
    });

    testWidgets('on a portrait phone the badge, colour disc and visibility toggle fit without overflow', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(360, 640);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        panelWith([_occurrence('a', nameOverride: 'A Fairly Long Component Name')], const {
          'a': ConstraintStatusDto(state: ConstraintState.underConstrained, dof: 6),
        }),
      );
      expect(tester.takeException(), isNull);
      expect(find.byIcon(Icons.lock_open), findsOneWidget);
    });
  });

  group('broken mates (pattern followers, F1)', () {
    MateDto brokenMate(String id) => MateDto(id: id, type: 'coincident', references: const [], status: 'broken');

    Widget panel({required List<MateDto> mates, Set<String> flash = const {}, int token = 0}) => _wrap(
          AssemblyTreePanel(
            visible: true,
            occurrences: const [],
            mates: mates,
            selectedOccurrenceId: null,
            onOccurrenceTap: (_) {},
            onOccurrenceLongPress: (_) {},
            onClose: () {},
            flashMateIds: flash,
            flashToken: token,
          ),
        );

    testWidgets('a broken mate row uses the error colour, a warning icon and says why; an ok one is plain', (tester) async {
      await tester.pumpWidget(panel(mates: [brokenMate('bad'), _mate('good')]));
      final error = Theme.of(tester.element(find.text('Mates'))).colorScheme.error;
      final bad = tester.widget<ListTile>(find.widgetWithText(ListTile, 'Coincident 1'));
      final good = tester.widget<ListTile>(find.widgetWithText(ListTile, 'Coincident 2'));
      expect((bad.leading as Icon).icon, Icons.warning_amber_rounded);
      expect((bad.leading as Icon).color, error);
      expect((bad.title as Text).style?.color, error);
      expect(find.text(kBrokenMateText), findsOneWidget);
      expect((good.leading as Icon).icon, Icons.link);
      expect((good.title as Text).style?.color, isNull);
    });

    testWidgets('a suppressed mate is never drawn as broken', (tester) async {
      final suppressed = MateDto(id: 's', type: 'coincident', references: const [], status: 'broken', suppressed: true);
      await tester.pumpWidget(panel(mates: [suppressed]));
      expect(find.text(kBrokenMateText), findsNothing);
    });

    testWidgets('a new flash token pulses the named rows (about three times over two seconds) and reopens a collapsed Mates section',
        (tester) async {
      final mates = [brokenMate('bad'), _mate('good')];
      await tester.pumpWidget(panel(mates: mates));
      await tester.tap(find.text('Mates')); // collapse it
      await tester.pumpAndSettle();
      expect(find.text(kBrokenMateText), findsNothing);

      await tester.pumpWidget(panel(mates: mates, flash: {'bad'}, token: 1));
      await tester.pump(); // post-frame: opens the section and starts the pulse
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text(kBrokenMateText), findsOneWidget, reason: 'the Mates section was opened so the flash is visible');

      var peaks = 0;
      var wasPulsing = false;
      var pulseSamples = 0;
      Color? tileColour() => tester.widget<ListTile>(find.widgetWithText(ListTile, 'Coincident 1')).tileColor;
      var previous = 0.0;
      var rising = false;
      for (var ms = 0; ms < 2000; ms += 50) {
        await tester.pump(const Duration(milliseconds: 50));
        final alpha = tileColour()?.a ?? 0.0;
        if (alpha > 0) {
          wasPulsing = true;
          pulseSamples++;
        }
        if (alpha < previous && rising) peaks++;
        rising = alpha > previous;
        previous = alpha;
      }
      expect(wasPulsing, isTrue);
      expect(pulseSamples, greaterThan(5));
      expect(peaks, inInclusiveRange(2, 3), reason: 'three pulses');
      await tester.pump(const Duration(milliseconds: 500));
      expect(tileColour(), isNull, reason: 'the flash ends');
      // the unnamed row never flashed
      expect(tester.widget<ListTile>(find.widgetWithText(ListTile, 'Coincident 2')).tileColor, isNull);
    });
  });

  group('pattern context menu (F2)', () {
    Future<PatternContextMenuAction?> open(WidgetTester tester, {required bool suppressed, required String tap}) async {
      PatternContextMenuAction? result;
      var done = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showPatternContextMenu(context, suppressed: suppressed);
                done = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Edit'), findsOneWidget);
      expect(find.text('Dissolve'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
      await tester.tap(find.text(tap));
      await tester.pumpAndSettle();
      return done ? result : null;
    }

    testWidgets('lists Edit, Dissolve and Delete and resolves to the tapped action', (tester) async {
      expect(await open(tester, suppressed: false, tap: 'Dissolve'), PatternContextMenuAction.dissolve);
    });

    testWidgets('Dissolve is disabled for a suppressed pattern: tapping it picks nothing', (tester) async {
      expect(await open(tester, suppressed: true, tap: 'Dissolve'), isNull);
      expect(find.text('Dissolve'), findsOneWidget, reason: 'the sheet stays open');
    });
  });

  group('near mates (B1: within tolerance, amber)', () {
    MateDto nearMate(String id, {double mm = 0.006, double deg = 0.0002, List<String> occurrences = const []}) => MateDto(
          id: id,
          type: 'distance',
          references: [for (final o in occurrences) MateEntityRefDto(occurrenceId: o)],
          status: 'near',
          statusResidualMm: mm,
          statusResidualDeg: deg,
        );

    Widget panel({List<MateDto> mates = const [], List<OccurrenceDto> occurrences = const [], Map<String, ConstraintStatusDto> status = const {}}) =>
        _wrap(
          AssemblyTreePanel(
            visible: true,
            occurrences: occurrences,
            mates: mates,
            selectedOccurrenceId: null,
            onOccurrenceTap: (_) {},
            onOccurrenceLongPress: (_) {},
            onClose: () {},
            constraintStatusByOccurrenceId: status,
          ),
        );

    test('MateDto reads status near and the residuals; an older backend gives ok', () {
      final json = {
        'id': 'm',
        'type': 'distance',
        'references': [
          {'occurrence_id': 'a'},
          {'occurrence_id': 'b'},
        ],
      };
      expect(MateDto.fromJson(json).isNear, isFalse);
      final near = MateDto.fromJson({...json, 'status': 'near', 'status_residual_mm': 0.006, 'status_residual_deg': 0.0002});
      expect(near.isNear, isTrue);
      expect(near.isBroken, isFalse);
      expect(near.statusResidualMm, 0.006);
      expect(near.statusResidualDeg, 0.0002);
    });

    test('the subtitle text is "Within tolerance: 0.006 mm / 0.0002°" with trailing zeros dropped', () {
      expect(nearMateText(nearMate('m')), 'Within tolerance: 0.006 mm / 0.0002°');
      expect(nearMateText(nearMate('m', mm: 0.01, deg: 0.1)), 'Within tolerance: 0.01 mm / 0.1°');
      expect(nearMateText(nearMate('m', mm: 0.00385, deg: 0.000123)), 'Within tolerance: 0.004 mm / 0.0001°');
    });

    testWidgets('a near mate row is amber (the warning token, not the error red), says how far, and explains itself in a tooltip', (tester) async {
      await tester.pumpWidget(panel(mates: [nearMate('n'), _mate('good')]));
      final amber = AiPalette.of(tester.element(find.text('Mates'))).warning;
      final error = Theme.of(tester.element(find.text('Mates'))).colorScheme.error;
      expect(amber, isNot(error));
      final tile = tester.widget<ListTile>(find.widgetWithText(ListTile, 'Distance 1'));
      final icon = tester.widget<Icon>(find.descendant(of: find.byWidget(tile.leading!), matching: find.byType(Icon)));
      expect(icon.icon, Icons.warning_amber_rounded);
      expect(icon.color, amber);
      expect((tile.title as Text).style?.color, amber);
      expect(find.text('Within tolerance: 0.006 mm / 0.0002°'), findsOneWidget);
      expect(find.byTooltip(kNearMateTooltip), findsOneWidget);
      expect(find.text(kBrokenMateText), findsNothing);
      final good = tester.widget<ListTile>(find.widgetWithText(ListTile, 'Coincident 1'));
      expect((good.leading as Icon).icon, Icons.link);
    });

    testWidgets('a suppressed near mate is drawn plain', (tester) async {
      final suppressed = MateDto(id: 's', type: 'distance', references: const [], status: 'near', suppressed: true);
      await tester.pumpWidget(panel(mates: [suppressed]));
      expect(find.textContaining('Within tolerance'), findsNothing);
    });

    test('occurrenceConflictsAreAllNear: needs a near mate, and any broken one on the part makes it a real conflict', () {
      final near = nearMate('n', occurrences: ['a', 'b']);
      final broken = MateDto(id: 'x', type: 'distance', references: [MateEntityRefDto(occurrenceId: 'a/inner')], status: 'broken');
      expect(occurrenceConflictsAreAllNear([near], 'a'), isTrue);
      expect(occurrenceConflictsAreAllNear([near, broken], 'a'), isFalse, reason: 'a/inner is inside the top-level a');
      expect(occurrenceConflictsAreAllNear([near, broken], 'b'), isTrue, reason: 'the broken mate does not touch b');
      expect(occurrenceConflictsAreAllNear([_mate('ok')], 'a'), isFalse);
      expect(occurrenceConflictsAreAllNear([near], 'c'), isFalse);
    });

    testWidgets('an over-constrained part whose mates are all near shows the amber badge, not the red one', (tester) async {
      final status = {'a': const ConstraintStatusDto(state: ConstraintState.overConstrained, dof: 0)};
      await tester.pumpWidget(panel(occurrences: [_occurrence('a')], mates: [nearMate('n', occurrences: ['a', ''])], status: status));
      final amber = AiPalette.of(tester.element(find.text('Mates'))).warning;
      final badge = tester.widget<Icon>(find.byIcon(Icons.warning_amber_rounded).first);
      expect(badge.color, amber);
      expect(find.byTooltip('Over-constrained - the mates agree to within tolerance'), findsOneWidget);
    });

    testWidgets('an over-constrained part with a broken mate keeps the red badge', (tester) async {
      final status = {'a': const ConstraintStatusDto(state: ConstraintState.overConstrained, dof: 0)};
      final broken = MateDto(id: 'x', type: 'distance', references: [MateEntityRefDto(occurrenceId: 'a')], status: 'broken');
      await tester.pumpWidget(panel(occurrences: [_occurrence('a')], mates: [broken], status: status));
      expect(find.byTooltip('Over-constrained - mates conflict'), findsOneWidget);
    });
  });

  group('Edit Alone row (C1)', () {
    Widget panel({String? label, VoidCallback? onDone, bool visible = true}) => _wrap(
          AssemblyTreePanel(
            visible: visible,
            occurrences: [_occurrence('a')],
            mates: const [],
            selectedOccurrenceId: null,
            onOccurrenceTap: (_) {},
            onOccurrenceLongPress: (_) {},
            onClose: () {},
            rootLabel: 'Frame',
            editAloneLabel: label,
            onEditAloneDone: onDone,
          ),
        );

    testWidgets('sits directly under the parent row, names the component and Done calls back', (tester) async {
      var done = 0;
      await tester.pumpWidget(panel(label: 'Bracket', onDone: () => done++));
      final row = find.byKey(const ValueKey('edit-alone-pill'));
      expect(row, findsOneWidget);
      expect(find.descendant(of: row, matching: find.textContaining('Editing', findRichText: true)), findsOneWidget);
      expect(tester.getTopLeft(row).dy, greaterThan(tester.getTopLeft(find.text('Frame')).dy));
      expect(tester.getTopLeft(row).dy, lessThan(tester.getTopLeft(find.text('Components')).dy));
      await tester.tap(find.byKey(const ValueKey('edit-alone-done')));
      expect(done, 1);
    });

    testWidgets('is not there without a label, or while the floating panel is closed', (tester) async {
      await tester.pumpWidget(panel());
      expect(find.byKey(const ValueKey('edit-alone-pill')), findsNothing);
      await tester.pumpWidget(panel(label: 'Bracket', onDone: () {}, visible: false));
      expect(find.byKey(const ValueKey('edit-alone-pill')), findsNothing);
    });
  });
}
