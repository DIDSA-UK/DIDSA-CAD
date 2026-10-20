// The flat app's Appearance panel (`lib/appearance/appearance_panel.dart`): the brush (palette, Clear, picker, hex, the
// per-property switches and sliders, presets), the rows (hover previews, tap paints), the eyedropper and Save brush.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/appearance/appearance_model.dart';
import 'package:didsa_cad_client/appearance/appearance_panel.dart';
import 'package:didsa_cad_client/appearance/appearance_rule.dart';

class _Harness {
  Json brush = {'colour': '#E63946'};
  PaintRow? previewed;
  bool previewEnded = false;
  final List<PaintRow> painted = [];
  bool eyedropper = false;
  String? savedName;
}

Future<_Harness> _pump(WidgetTester tester, {List<PaintRow> rows = const []}) async {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final h = _Harness();
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: StatefulBuilder(
        builder: (context, setState) => AppearancePanel(
          brush: h.brush,
          onBrushChanged: (b) => setState(() => h.brush = b),
          rows: rows,
          pickLabel: rows.isEmpty ? null : 'Bar',
          onPreviewRow: (row) {
            if (row == null) {
              h.previewEnded = true;
            } else {
              h.previewed = row;
            }
          },
          onPaintRow: h.painted.add,
          eyedropper: h.eyedropper,
          onEyedropperChanged: (on) => setState(() => h.eyedropper = on),
          recentColours: const ['#123456'],
          savedAppearances: const [('Mine', {'colour': '#ABCDEF'})],
          onSaveBrush: (name) => h.savedName = name,
          onClose: () {},
        ),
      ),
    ),
  ));
  await tester.pump();
  return h;
}

void main() {
  testWidgets('a swatch sets the colour; Clear empties the brush; a recent colour sets it again', (tester) async {
    final h = await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('appearance-swatch-#3498DB')));
    await tester.pump();
    expect(h.brush, {'colour': '#3498DB'});
    await tester.tap(find.byKey(const ValueKey('appearance-clear')));
    await tester.pump();
    expect(h.brush, isEmpty);
    expect(find.text('Clear'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('appearance-recent-#123456')));
    await tester.pump();
    expect(h.brush, {'colour': '#123456'});
  });

  testWidgets('a property is painted only when switched on; moving its slider switches it on; Shine is 1 - roughness', (tester) async {
    final h = await _pump(tester);
    expect(h.brush.containsKey('opacity'), isFalse);
    await tester.tap(find.byKey(const ValueKey('appearance-switch-opacity')));
    await tester.pump();
    expect(h.brush['opacity'], 1.0);
    await tester.tap(find.byKey(const ValueKey('appearance-switch-colour')));
    await tester.pump();
    expect(h.brush.containsKey('colour'), isFalse, reason: '"opacity only" keeps the colour beneath');
    final shine = find.byKey(const ValueKey('appearance-slider-roughness'));
    await tester.tapAt(tester.getTopLeft(shine) + Offset(tester.getSize(shine).width - 4, tester.getSize(shine).height / 2));
    await tester.pump();
    expect((h.brush['roughness'] as num), lessThan(0.05), reason: 'shine all the way up is roughness near 0');
  });

  testWidgets('the hex field and the picker set the colour', (tester) async {
    final h = await _pump(tester);
    await tester.enterText(find.byKey(const ValueKey('appearance-hex')), '#00ff00');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(h.brush['colour'], '#00FF00');
    final sv = find.byKey(const ValueKey('appearance-sv'));
    await tester.tapAt(tester.getBottomLeft(sv) + const Offset(2, -2)); // no saturation, no value: black
    await tester.pump();
    final c = colourOfHex(h.brush['colour'] as String);
    expect([c.r, c.g, c.b].every((v) => v < 0.05), isTrue, reason: 'near black: ${h.brush['colour']}');
    expect(c.r, c.b, reason: 'no saturation: a grey');
  });

  testWidgets('presets and saved appearances add their fields to the brush', (tester) async {
    final h = await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('appearance-saved-Brushed metal')));
    await tester.pump();
    expect(h.brush, {'colour': '#E63946', 'metallic': 1.0, 'roughness': 0.45});
    await tester.tap(find.byKey(const ValueKey('appearance-saved-Mine')));
    await tester.pump();
    expect(h.brush['colour'], '#ABCDEF');
  });

  testWidgets('rows: hovering previews, leaving ends it, a tap paints; "set here" shows', (tester) async {
    final rows = [
      const PaintRow(id: 'body', label: 'Body', record: {'path': 'a', 'body_id': 'b'}, members: ['a']),
      const PaintRow(id: 'whole', label: 'Whole assembly', record: {'path': ''}, members: ['a'], setHere: true, swatch: {'colour': '#FFFFFF'}),
    ];
    final h = await _pump(tester, rows: rows);
    expect(find.text('Paint · Bar'), findsOneWidget);
    expect(find.textContaining('set here'), findsOneWidget);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    await gesture.moveTo(tester.getCenter(find.byKey(const ValueKey('appearance-row-whole'))));
    await tester.pump();
    expect(h.previewed?.id, 'whole');
    await gesture.moveTo(Offset.zero);
    await tester.pump();
    expect(h.previewEnded, isTrue);
    await tester.tap(find.text('Body'));
    await tester.pump();
    expect(h.painted.single.id, 'body');
    await gesture.removePointer();
  });

  testWidgets('the eyedropper toggles; Save brush asks for a name', (tester) async {
    final h = await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('appearance-eyedropper')));
    await tester.pump();
    expect(h.eyedropper, isTrue);
    expect(find.textContaining('take its appearance'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('appearance-save-brush')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('appearance-save-field')), 'Red glow');
    await tester.tap(find.byKey(const ValueKey('appearance-save-ok')));
    await tester.pumpAndSettle();
    expect(h.savedName, 'Red glow');
  });

  test('describeAppearance', () {
    expect(describeAppearance({}), 'Clear');
    expect(describeAppearance({'colour': '#FF0000', 'opacity': 0.5, 'roughness': 0.2, 'metallic': 1.0, 'emission_strength': 2.0}),
        '#FF0000 · 50% · shine 0.80 · metal 1.00 · glow 2.0');
  });
}
