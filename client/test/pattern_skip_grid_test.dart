import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/viewport3d/pattern_skip_grid.dart';

/// Pattern/Mirror scoping's Phase 3 (`docs/pattern-mirror-scope.md`
/// §2.4/§4): unit-level coverage for [PatternSkipGrid]'s dot rendering
/// and toggle behavior, for both the rectangular and radial layouts. No
/// `flutter_scene` dependency anywhere in `pattern_skip_grid.dart`'s
/// import chain, so this is a real, runnable widget test in this
/// sandbox.
void main() {
  Widget harness({
    PatternSkipGridLayout layout = PatternSkipGridLayout.rectangular,
    required int totalCount,
    int columns = 1,
    double angleTotal = 360.0,
    Set<int> skipIndices = const {},
    void Function(int index)? onToggle,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: PatternSkipGrid(
          layout: layout,
          totalCount: totalCount,
          columns: columns,
          angleTotal: angleTotal,
          skipIndices: skipIndices,
          onToggle: onToggle ?? (_) {},
        ),
      ),
    );
  }

  Color? dotColor(WidgetTester tester, int index) {
    final finder = find.byKey(ValueKey('pattern-skip-dot-$index'));
    final container = tester.widget<Container>(find.descendant(of: finder, matching: find.byType(Container)));
    final decoration = container.decoration as BoxDecoration;
    return decoration.color;
  }

  group('PatternSkipGrid rendering', () {
    testWidgets('renders nothing when totalCount is 1 or fewer', (tester) async {
      await tester.pumpWidget(harness(totalCount: 1));
      expect(find.byKey(const ValueKey('pattern-skip-dot-0')), findsNothing);
    });

    testWidgets('renders one dot per index for a rectangular grid', (tester) async {
      await tester.pumpWidget(harness(totalCount: 4, columns: 2));
      for (var i = 0; i < 4; i++) {
        expect(find.byKey(ValueKey('pattern-skip-dot-$i')), findsOneWidget);
      }
    });

    testWidgets('renders one dot per index for a radial layout', (tester) async {
      await tester.pumpWidget(harness(layout: PatternSkipGridLayout.radial, totalCount: 6));
      for (var i = 0; i < 6; i++) {
        expect(find.byKey(ValueKey('pattern-skip-dot-$i')), findsOneWidget);
      }
    });

    testWidgets('the seed dot (index 0) is filled and every other active dot is filled too', (tester) async {
      await tester.pumpWidget(harness(totalCount: 3));
      final primary = Theme.of(tester.element(find.byType(PatternSkipGrid))).colorScheme.primary;
      expect(dotColor(tester, 0), primary);
      expect(dotColor(tester, 1), primary);
      expect(dotColor(tester, 2), primary);
    });

    testWidgets('a skipped dot renders hollow (transparent), others stay filled', (tester) async {
      await tester.pumpWidget(harness(totalCount: 3, skipIndices: {1}));
      final primary = Theme.of(tester.element(find.byType(PatternSkipGrid))).colorScheme.primary;
      expect(dotColor(tester, 0), primary);
      expect(dotColor(tester, 1), Colors.transparent);
      expect(dotColor(tester, 2), primary);
    });
  });

  group('PatternSkipGrid interaction', () {
    testWidgets('tapping a non-seed dot fires onToggle with its own index', (tester) async {
      int? toggled;
      await tester.pumpWidget(harness(totalCount: 4, columns: 2, onToggle: (i) => toggled = i));
      await tester.tap(find.byKey(const ValueKey('pattern-skip-dot-2')));
      expect(toggled, 2);
    });

    testWidgets('tapping the seed dot (index 0) never fires onToggle', (tester) async {
      var toggled = false;
      await tester.pumpWidget(harness(totalCount: 3, onToggle: (_) => toggled = true));
      await tester.tap(find.byKey(const ValueKey('pattern-skip-dot-0')));
      expect(toggled, isFalse);
    });

    testWidgets('tapping a dot in the radial layout fires onToggle with its own index', (tester) async {
      int? toggled;
      await tester.pumpWidget(
        harness(layout: PatternSkipGridLayout.radial, totalCount: 4, onToggle: (i) => toggled = i),
      );
      await tester.tap(find.byKey(const ValueKey('pattern-skip-dot-3')));
      expect(toggled, 3);
    });
  });
}
