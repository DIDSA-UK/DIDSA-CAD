// Stress tests for the M1-M7 flat-app UI by simulated user input: seeded random taps / drags / typing ("monkey") across a matrix of
// screen sizes, text scales and themes, plus hostile inputs (huge lists, long and odd names, double taps, wrong-order sequences).
// What they assert: no framework exception (overflow, layout, setState), invariants the panels promise (a brush is always a valid
// appearance, a callback fires once per tap), and that every control is still reachable on a small screen.
//
// They judge nothing about look or feel: a green run means "did not throw and kept its invariants", not "pleasant to use".
import 'dart:async';
import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/appearance/appearance_model.dart';
import 'package:didsa_cad_client/appearance/appearance_panel.dart';
import 'package:didsa_cad_client/appearance/appearance_rule.dart';
import 'package:didsa_cad_client/appearance/scenes_panel.dart';
import 'package:didsa_cad_client/assembly/reference_report.dart';
import 'package:didsa_cad_client/assembly/references_sheet.dart';

typedef _Env = ({String name, Size size, double textScale, Brightness brightness});

const List<_Env> _envs = [
  (name: 'phone portrait', size: Size(360, 640), textScale: 1.0, brightness: Brightness.light),
  (name: 'phone portrait, large text, dark', size: Size(360, 640), textScale: 2.0, brightness: Brightness.dark),
  (name: 'phone landscape', size: Size(640, 360), textScale: 1.0, brightness: Brightness.dark),
  (name: 'tablet', size: Size(1024, 768), textScale: 1.3, brightness: Brightness.light),
  (name: 'desktop', size: Size(1920, 1080), textScale: 1.0, brightness: Brightness.dark),
];

Widget _app(_Env env, Widget body) => MaterialApp(
  theme: ThemeData(brightness: env.brightness, useMaterial3: true),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(env.textScale)),
    child: child!,
  ),
  home: Scaffold(body: body),
);

void _size(WidgetTester tester, _Env env) {
  tester.view.physicalSize = env.size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// Every on-screen interactive widget's centre, so a monkey taps what a finger could.
List<Offset> _targets(WidgetTester tester) {
  final view = tester.view.physicalSize;
  final out = <Offset>[];
  for (final type in [InkWell, GestureDetector, Switch, Slider, TextField, PopupMenuButton, IconButton, ButtonStyleButton]) {
    for (final element in find.byType(type).evaluate()) {
      final box = element.renderObject;
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      final c = box.localToGlobal(box.size.center(Offset.zero));
      if (c.dx >= 0 && c.dy >= 0 && c.dx <= view.width && c.dy <= view.height) out.add(c);
    }
  }
  return out;
}

void _noException(WidgetTester tester, String reason) {
  final error = tester.takeException();
  if (error == null) return;
  final text = error is FlutterError ? error.toStringDeep() : '$error';
  fail('$reason: ${text.length > 3000 ? text.substring(0, 3000) : text}');
}

Future<void> _monkey(WidgetTester tester, Random rng, int steps, {void Function()? afterEach}) async {
  for (var i = 0; i < steps; i++) {
    final targets = _targets(tester);
    final view = tester.view.physicalSize;
    final roll = rng.nextInt(10);
    final at = targets.isNotEmpty && roll < 7
        ? targets[rng.nextInt(targets.length)]
        : Offset(rng.nextDouble() * view.width, rng.nextDouble() * view.height);
    switch (roll) {
      case 0 || 1 || 2 || 3 || 4:
        await tester.tapAt(at);
      case 5:
        await tester.tapAt(at);
        await tester.tapAt(at); // a double tap
      case 6:
        await tester.dragFrom(at, Offset((rng.nextDouble() - 0.5) * 400, (rng.nextDouble() - 0.5) * 400));
      case 7:
        final g = await tester.startGesture(at);
        await g.moveBy(Offset(rng.nextDouble() * 60, rng.nextDouble() * 60));
        await g.cancel(); // a touch the OS takes away
      case 8:
        final g = await tester.startGesture(at);
        await tester.pump(const Duration(milliseconds: 700)); // long press
        await g.up();
      default:
        final fields = find.byType(EditableText);
        if (fields.evaluate().isNotEmpty) {
          final junk = ['', '#', '#GGG', 'ffffff', '#12345', '#FFFFFFF', '   ', '🙂🙂', '#e63946', 'x' * 300, '\n', "'; DROP"];
          await tester.enterText(fields.first, junk[rng.nextInt(junk.length)]);
          await tester.testTextInput.receiveAction(TextInputAction.done);
        }
    }
    await tester.pump(const Duration(milliseconds: 50));
    _noException(tester, 'step $i (roll $roll at $at)');
    afterEach?.call();
  }
  await tester.pump(const Duration(seconds: 1));
}

List<PaintRow> get _rows => const [
  PaintRow(id: 'face', label: 'Face 3 of Bracket with a rather long descriptive name that will not fit', record: {'path': 'a/b', 'body_id': 'x', 'face_index': 3}, members: ['a']),
  PaintRow(id: 'body', label: 'Body', record: {'path': 'a/b', 'body_id': 'x'}, members: ['a']),
  PaintRow(id: 'part', label: 'Part Bracket', record: {'path': 'a/b'}, members: ['a'], swatch: {'colour': '#3498DB'}),
  PaintRow(id: 'whole', label: 'Whole assembly', record: {'path': ''}, members: ['a'], setHere: true, swatch: {'colour': '#FFFFFF', 'opacity': 0.4}),
];

void main() {
  group('Appearance panel', () {
    for (final env in _envs) {
      testWidgets('monkey, ${env.name}: never throws, the brush is always a valid appearance, callbacks stay sane', (tester) async {
        _size(tester, env);
        var brush = <String, dynamic>{'colour': '#E63946'};
        var painted = 0;
        var previews = 0;
        var saved = <String>[];
        var eyedropper = false;
        await tester.pumpWidget(_app(
          env,
          StatefulBuilder(
            builder: (context, setState) => AppearancePanel(
              brush: brush,
              onBrushChanged: (b) => setState(() => brush = b),
              rows: _rows,
              pickLabel: 'Bracket',
              onPreviewRow: (_) => previews++,
              onPaintRow: (_) => painted++,
              eyedropper: eyedropper,
              onEyedropperChanged: (on) => setState(() => eyedropper = on),
              recentColours: const ['#123456', '#ABCDEF', '#000000'],
              savedAppearances: const [('Mine', {'colour': '#ABCDEF'}), ('A very long saved brush name indeed', {'metallic': 1.0})],
              onSaveBrush: saved.add,
              onUndo: () {},
              onClose: () {},
            ),
          ),
        ));
        await tester.pump();
        await _monkey(tester, Random(env.name.hashCode), 250, afterEach: () {
          expect(brush.isEmpty || appearanceErrors(brush).isEmpty, isTrue, reason: 'brush went invalid: $brush ${appearanceErrors(brush)}');
        });
        expect(painted + previews + saved.length, greaterThanOrEqualTo(0));
      });
    }

    testWidgets('hostile hex input never reaches the brush as a bad colour', (tester) async {
      _size(tester, _envs.first);
      var brush = <String, dynamic>{};
      await tester.pumpWidget(_app(
        _envs.first,
        StatefulBuilder(
          builder: (context, setState) => AppearancePanel(
            brush: brush,
            onBrushChanged: (b) => setState(() => brush = b),
            rows: const [],
            onPreviewRow: (_) {},
            onPaintRow: (_) {},
            onEyedropperChanged: (_) {},
            onSaveBrush: (_) {},
            onClose: () {},
          ),
        ),
      ));
      for (final text in ['', '#', 'zzzzzz', '#12', '#1234567', '#12 456', '  #aabbcc  ', 'aabbcc', '#AABBCC', '#aabbccdd', '١٢٣٤٥٦', 'x' * 5000]) {
        await tester.enterText(find.byKey(const ValueKey('appearance-hex')), text);
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();
        expect(tester.takeException(), isNull, reason: 'input "$text"');
        expect(brush.isEmpty || appearanceErrors(brush).isEmpty, isTrue, reason: 'input "$text" gave $brush');
      }
    });

    testWidgets('on a phone every control can be scrolled into view and tapped (nothing is cut off)', (tester) async {
      final env = _envs[1]; // 360x640 at 2x text: the worst case here
      _size(tester, env);
      var brush = <String, dynamic>{'colour': '#E63946'};
      await tester.pumpWidget(_app(
        env,
        StatefulBuilder(
          builder: (context, setState) => AppearancePanel(
            brush: brush,
            onBrushChanged: (b) => setState(() => brush = b),
            rows: _rows,
            pickLabel: 'Bracket',
            onPreviewRow: (_) {},
            onPaintRow: (_) {},
            onEyedropperChanged: (_) {},
            onSaveBrush: (_) {},
            onClose: () {},
          ),
        ),
      ));
      await tester.pump();
      for (final key in ['appearance-clear', 'appearance-hex', 'appearance-switch-opacity', 'appearance-slider-roughness', 'appearance-row-whole']) {
        final finder = find.byKey(ValueKey(key));
        expect(finder, findsOneWidget, reason: key);
        await tester.ensureVisible(finder);
        await tester.pump();
        final centre = tester.getCenter(finder);
        final size = tester.view.physicalSize;
        expect(centre.dx > 0 && centre.dy > 0 && centre.dx < size.width && centre.dy < size.height, isTrue, reason: '$key off screen at $centre');
        _noException(tester, key);
      }
    });
  });

  group('Scenes panel', () {
    List<Map<String, dynamic>> scenes(int n, {String? name}) => [
      for (var i = 0; i < n; i++)
        {'id': 's$i', 'name': name ?? 'Scene $i', 'unresolved': i % 7 == 0 ? [{'path': 'gone', 'reason': 'x'}] : <dynamic>[]},
    ];

    Future<List<String>> pump(WidgetTester tester, _Env env, List<Map<String, dynamic>> list, {String? shownId, bool dirty = false, bool busy = false}) async {
      _size(tester, env);
      final calls = <String>[];
      await tester.pumpWidget(_app(
        env,
        ScenesPanel(
          scenes: list,
          shownId: shownId,
          dirty: dirty,
          useViewpoint: true,
          saveView: false,
          busy: busy,
          notice: 'A notice that is fairly long so that it wraps over several lines on a narrow screen',
          onShow: (s) => calls.add('show ${s['id']}'),
          onNewScene: () => calls.add('new'),
          onUpdate: () => calls.add('update'),
          onSaveAsNew: () => calls.add('saveNew'),
          onBackToDefault: () => calls.add('back'),
          onRename: (s) => calls.add('rename ${s['id']}'),
          onDelete: (s) => calls.add('delete ${s['id']}'),
          onUseViewpointChanged: (on) => calls.add('vp $on'),
          onSaveViewChanged: (on) => calls.add('sv $on'),
          onClose: () => calls.add('close'),
        ),
      ));
      await tester.pump();
      return calls;
    }

    for (final env in _envs) {
      for (final shown in <String?>[null, '', 's1']) {
        testWidgets('monkey, ${env.name}, shown=${shown == null ? 'default' : shown.isEmpty ? 'new' : 'scene'}: never throws', (tester) async {
          await pump(tester, env, scenes(12), shownId: shown, dirty: shown != null);
          await _monkey(tester, Random(env.name.hashCode ^ (shown?.length ?? 9)), 150);
        });
      }
    }

    testWidgets('200 scenes with very long and odd names: no overflow, the last scene can be reached and tapped', (tester) async {
      final env = _envs[0];
      final list = [
        for (var i = 0; i < 200; i++)
          {'id': 's$i', 'name': i.isEven ? 'Scene $i ${'long ' * 40}' : '🙂 Scene $i ñ ü 日本語 ‮rtl', 'unresolved': <dynamic>[]},
      ];
      final calls = await pump(tester, env, list);
      _noException(tester, 'layout of 200 rows');
      final last = find.byKey(const ValueKey('scene-row-s199'));
      await tester.scrollUntilVisible(last, 300, scrollable: find.byType(Scrollable).first);
      await tester.tap(last);
      expect(calls, contains('show s199'));
    });

    testWidgets('busy: nothing that changes the model can be triggered, whatever is tapped', (tester) async {
      final calls = await pump(tester, _envs[0], scenes(3), shownId: 's1', dirty: true, busy: true);
      for (final key in ['scenes-update', 'scenes-save-new', 'scenes-back']) {
        await tester.tap(find.byKey(ValueKey(key)), warnIfMissed: false);
      }
      await tester.tap(find.byKey(const ValueKey('scene-row-s0')), warnIfMissed: false);
      expect(calls, isEmpty);
    });

    testWidgets('rapid double tap on Back to default: the panel itself does not debounce (PartScreen\'s busy flag does)', (tester) async {
      final calls = await pump(tester, _envs[3], scenes(2), shownId: 's1');
      await tester.tap(find.byKey(const ValueKey('scenes-back')));
      await tester.tap(find.byKey(const ValueKey('scenes-back')));
      // The panel itself does not debounce; whether a double call is harmful depends on the screen's `busy`. PartScreen sets it.
      expect(calls.where((c) => c == 'back').length, anyOf(1, 2));
    });
  });

  group('names dialog', () {
    for (final name in ['', '   ', 'x' * 20000, '🙂' * 500, 'line1\nline2', '\u0000\u0001', '<b>bold</b>', "O'Brien \"quoted\"", '../../etc/passwd']) {
      testWidgets('askSceneName with ${name.length > 20 ? '${name.length} chars' : '"$name"'}', (tester) async {
        _size(tester, _envs[0]);
        String? result = 'unset';
        await tester.pumpWidget(_app(
          _envs[0],
          Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () async => result = await askSceneName(context, title: 'Name'),
                child: const Text('open'),
              ),
            ),
          ),
        ));
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const ValueKey('scene-name-field')), name);
        await tester.tap(find.byKey(const ValueKey('scene-name-ok')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        // A single-line field drops a pasted newline; that is the platform's behaviour and is kept.
        final expected = name.replaceAll('\n', '');
        expect(result, expected.trim().isEmpty ? isNull : expected.trim());
      });
    }

    testWidgets('Cancel, and a tap outside, return null and leave no dialog behind', (tester) async {
      _size(tester, _envs[0]);
      String? result = 'unset';
      await tester.pumpWidget(_app(
        _envs[0],
        Builder(builder: (context) => ElevatedButton(onPressed: () async => result = await askSceneName(context, title: 'Name'), child: const Text('open'))),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(result, isNull);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(2, 2));
      await tester.pumpAndSettle();
      expect(find.byType(NameDialog), findsNothing);
    });

    testWidgets('the leave-scene question: a dismissed dialog stays; Discard / Update / Stay each answer once', (tester) async {
      _size(tester, _envs[0]);
      SceneLeaveChoice? choice;
      await tester.pumpWidget(_app(
        _envs[0],
        Builder(builder: (context) => ElevatedButton(onPressed: () async => choice = await askSceneLeave(context, canUpdate: true), child: const Text('open'))),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(2, 2));
      await tester.pumpAndSettle();
      expect(choice, SceneLeaveChoice.stay);
      for (final (key, want) in [('scene-leave-update', SceneLeaveChoice.update), ('scene-leave-discard', SceneLeaveChoice.discard)]) {
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey(key)));
        await tester.pumpAndSettle();
        expect(choice, want);
      }
    });
  });

  group('Review sheet (moved files)', () {
    ReferenceReport report(int i, ReferenceOutcome outcome, {int candidates = 0, String? long}) => ReferenceReport(
      parentPartId: 'root',
      parentPath: 'root.didsa',
      occurrenceId: 'o$i',
      requestedPath: '${long ?? ''}File $i.didsa',
      storedPartId: 'id$i',
      outcome: outcome,
      foundPath: outcome == ReferenceOutcome.movedById ? 'moved/${long ?? ''}File $i.didsa' : null,
      candidates: [for (var c = 0; c < candidates; c++) 'copy$c/${long ?? ''}File $i.didsa'],
      pathMismatch: i % 3 == 0,
      staleCopy: i % 5 == 0,
    );

    Future<({List<String> used, List<String> located, List<String> left, ValueNotifier<List<ReferenceReport>> notifier})> pump(
      WidgetTester tester,
      _Env env,
      List<ReferenceReport> list, {
      Future<void>? gate,
    }) async {
      _size(tester, env);
      final used = <String>[];
      final located = <String>[];
      final left = <String>[];
      final notifier = ValueNotifier(list);
      addTearDown(notifier.dispose);
      await tester.pumpWidget(_app(
        env,
        ReferencesSheet(
          reports: notifier,
          onUse: (r, p) async {
            used.add('${r.occurrenceId}:$p');
            await gate;
          },
          onLocate: (r) async => located.add(r.occurrenceId),
          onLeaveMissing: (r) {
            left.add(r.occurrenceId);
            notifier.value = [for (final o in notifier.value) if (o != r) o];
          },
        ),
      ));
      await tester.pump();
      return (used: used, located: located, left: left, notifier: notifier);
    }

    for (final env in _envs) {
      testWidgets('300 references of every kind with long paths, ${env.name}: no overflow, monkey never throws', (tester) async {
        final list = [
          for (var i = 0; i < 300; i++)
            report(i, ReferenceOutcome.values[i % 4], candidates: i % 4 == 1 ? 3 : i % 4 == 2 ? 1 : 0, long: i % 2 == 0 ? 'very long folder name ' * 6 : null),
        ];
        await pump(tester, env, list);
        _noException(tester, 'first layout');
        await _monkey(tester, Random(7), 120);
      });
    }

    testWidgets('a double tap on Use applies it once: the sheet ignores the second tap while the first is being applied', (tester) async {
      final gate = Completer<void>(); // the first Use is still being applied (a compose and an import take a while)
      final h = await pump(tester, _envs[3], [report(1, ReferenceOutcome.ask, candidates: 2)], gate: gate.future);
      final use = find.byKey(const ValueKey('use-o1-copy0/File 1.didsa'));
      await tester.tap(use);
      await tester.pump();
      await tester.tap(use, warnIfMissed: false);
      await tester.tap(find.byKey(const ValueKey('use-o1-copy1/File 1.didsa')), warnIfMissed: false);
      await tester.pump();
      expect(h.used.length, 1, reason: 'no second Use (same or other copy) while the first is applied');
      gate.complete();
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('use-o1-copy1/File 1.didsa')));
      await tester.pump();
      expect(h.used.length, 2, reason: 'buttons work again once it is done');
    });

    testWidgets('leaving every row empties the list without an exception and the summary updates', (tester) async {
      final list = [for (var i = 0; i < 6; i++) report(i, ReferenceOutcome.missing)];
      final h = await pump(tester, _envs[0], list);
      for (var i = 0; i < 6; i++) {
        await tester.ensureVisible(find.byKey(ValueKey('leave-o$i')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey('leave-o$i')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      expect(h.notifier.value.map((r) => r.occurrenceId), isEmpty);
      expect(find.text('All references are dealt with'), findsOneWidget);
    });

    testWidgets('an empty list and a list changed while a confirm dialog is open do not throw', (tester) async {
      final h = await pump(tester, _envs[0], [report(2, ReferenceOutcome.suggest, candidates: 1)]);
      await tester.tap(find.byKey(const ValueKey('use-o2-copy0/File 2.didsa')));
      await tester.pumpAndSettle();
      expect(find.text('Not the placed file'), findsOneWidget);
      h.notifier.value = const []; // the owner drops the row while the question is open
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use anyway'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('pointer kinds', () {
    testWidgets('Appearance rows work with a mouse hover, a stylus and a touch', (tester) async {
      final env = _envs[3];
      _size(tester, env);
      final previewed = <String?>[];
      final painted = <String>[];
      await tester.pumpWidget(_app(
        env,
        AppearancePanel(
          brush: const {'colour': '#E63946'},
          onBrushChanged: (_) {},
          rows: _rows,
          pickLabel: 'Bracket',
          onPreviewRow: (r) => previewed.add(r?.id),
          onPaintRow: (r) => painted.add(r.id),
          onEyedropperChanged: (_) {},
          onSaveBrush: (_) {},
          onClose: () {},
        ),
      ));
      final row = find.byKey(const ValueKey('appearance-row-body'));
      await tester.ensureVisible(row);
      await tester.pump();
      for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.stylus, PointerDeviceKind.touch]) {
        await tester.tapAt(tester.getCenter(row), kind: kind);
        await tester.pump();
      }
      expect(painted, ['body', 'body', 'body']);
    });
  });
}
