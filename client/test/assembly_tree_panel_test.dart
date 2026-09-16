import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/viewport3d/assembly_tree_panel.dart';

RigidTransformDto _identity() =>
    RigidTransformDto(translation: const [0, 0, 0], rotationAxis: const [0, 0, 1], rotationAngleDegrees: 0);

OccurrenceDto _occurrence(
  String id, {
  String? externalRef,
  String? resolvedPartId,
  String? nameOverride,
  bool hidden = false,
  bool suppressed = false,
}) =>
    OccurrenceDto(
      id: id,
      externalRef: externalRef,
      resolvedPartId: resolvedPartId,
      nameOverride: nameOverride,
      transform: _identity(),
      hidden: hidden,
      suppressed: suppressed,
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

    expect(find.byIcon(Icons.visibility_off), findsOneWidget);
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
}
