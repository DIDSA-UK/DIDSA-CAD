import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/viewport3d/keyboard_shortcuts.dart';

/// Desktop input D3 (`docs/desktop-input-scope.md` R3): the shortcut scope,
/// the text-field rules and the tool panels' Enter / Esc registry.
void main() {
  Future<List<CadShortcut>> pumpScope(
    WidgetTester tester, {
    Map<CadShortcut, VoidCallback?>? bindings,
    Widget? body,
  }) async {
    final fired = <CadShortcut>[];
    final map = bindings ??
        {
          for (final shortcut in [
            CadShortcut.cancel,
            CadShortcut.confirm,
            CadShortcut.delete,
            CadShortcut.undo,
            CadShortcut.save,
            CadShortcut.zoomToFit,
            CadShortcut.viewFront,
            CadShortcut.zoomIn,
            CadShortcut.zoomOut,
            CadShortcut.rotateLeft,
            CadShortcut.rotate90Left,
            CadShortcut.panLeft,
            CadShortcut.sketchLine,
          ])
            shortcut: () => fired.add(shortcut),
        };
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: CadShortcutScope(bindings: () => map, child: body ?? const SizedBox.expand())),
    ));
    await tester.pump();
    return fired;
  }

  testWidgets('each key fires its own shortcut, modifiers kept apart', (tester) async {
    final fired = await pumpScope(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

    expect(fired, [
      CadShortcut.cancel,
      CadShortcut.confirm,
      CadShortcut.delete,
      CadShortcut.zoomToFit,
      CadShortcut.sketchLine,
      CadShortcut.zoomOut,
      CadShortcut.rotateLeft,
      CadShortcut.zoomIn,
      CadShortcut.rotate90Left,
      CadShortcut.undo,
      CadShortcut.save,
      CadShortcut.viewFront,
      CadShortcut.panLeft,
    ]);
  });

  testWidgets('a null binding leaves the key alone', (tester) async {
    var cancels = 0;
    await pumpScope(tester, bindings: {CadShortcut.cancel: () => cancels++, CadShortcut.confirm: null});
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(cancels, 1);
  });

  testWidgets('in a text field letters, Enter and Delete go to the field; Ctrl+S still saves; Esc leaves the field',
      (tester) async {
    final text = TextEditingController();
    final fired = await pumpScope(tester, body: TextField(controller: text, autofocus: true));
    await tester.pump();
    expect(textInputHasFocus(), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    expect(fired, isEmpty);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(fired, [CadShortcut.save]);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(fired, [CadShortcut.save], reason: 'Esc in a field leaves the field, it does not cancel');
    expect(textInputHasFocus(), isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    expect(fired.last, CadShortcut.zoomToFit, reason: 'out of the field, keys reach the scope again');
  });

  testWidgets('a dialog on top of the screen keeps its keys from the screen', (tester) async {
    var fits = 0;
    await tester.pumpWidget(MaterialApp(
      home: CadShortcutScope(
        bindings: () => {CadShortcut.zoomToFit: () => fits++},
        child: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(context: context, builder: (_) => const AlertDialog(content: Text('on top'))),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    expect(fits, 1);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    expect(fits, 1, reason: 'the dialog is on top');
  });

  testWidgets('withShortcut adds the keys to a tooltip', (tester) async {
    expect(withShortcut('Undo', CadShortcut.undo), 'Undo (Ctrl+Z)');
    expect(withShortcut('Zoom to fit', CadShortcut.zoomToFit), 'Zoom to fit (F)');
  });

  testWidgets('the shortcut sheet lists what the screen binds, grouped', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => showCadShortcutSheet(context, [CadShortcut.save, CadShortcut.zoomToFit, CadShortcut.rotateLeft, CadShortcut.rotateRight]),
          child: const Text('show'),
        ),
      ),
    ));
    await tester.tap(find.text('show'));
    await tester.pumpAndSettle();
    expect(find.text('Keyboard shortcuts'), findsOneWidget);
    expect(find.text('Ctrl+S'), findsOneWidget);
    expect(find.text('F'), findsOneWidget);
    expect(find.text('Arrow keys'), findsOneWidget);
    expect(find.text('→'), findsNothing, reason: 'the arrow family shares one row');
    expect(find.text('Ctrl+O'), findsNothing, reason: 'not bound by this screen');
  });

  group('ToolPanelKeys', () {
    testWidgets('the most recently opened panel owns Enter / Esc; closing it hands back', (tester) async {
      final registry = ToolPanelKeyRegistry();
      final log = <String>[];
      Widget build({required bool second, bool firstCanConfirm = true}) => MaterialApp(
            home: ToolPanelKeyScope(
              registry: registry,
              child: Column(children: [
                ToolPanelKeys(onConfirm: firstCanConfirm ? () => log.add('confirm 1') : null, onCancel: () => log.add('cancel 1')),
                if (second) ToolPanelKeys(onConfirm: () => log.add('confirm 2'), onCancel: () => log.add('cancel 2')),
              ]),
            ),
          );

      expect(registry.hasPanel, isFalse);
      await tester.pumpWidget(build(second: true));
      registry.confirm!();
      registry.cancel!();
      await tester.pumpWidget(build(second: false));
      registry.cancel!();
      await tester.pumpWidget(build(second: false, firstCanConfirm: false));
      expect(registry.confirm, isNull, reason: "a disabled Confirm button means Enter does nothing");
      expect(log, ['confirm 2', 'cancel 2', 'cancel 1']);

      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      expect(registry.hasPanel, isFalse);
    });
  });
}
