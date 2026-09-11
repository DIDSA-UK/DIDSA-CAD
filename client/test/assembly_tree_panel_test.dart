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
}
