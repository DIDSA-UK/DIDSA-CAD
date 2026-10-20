// The flat app's Scenes panel (`lib/appearance/scenes_panel.dart`): what it offers in the default, in a new scene and in a
// shown one; the list; and the Update / Discard / Stay question.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/appearance/appearance_rule.dart';
import 'package:didsa_cad_client/appearance/scenes_panel.dart';

final List<Json> _scenes = [
  {'id': 's1', 'name': 'Exploded', 'unresolved': <dynamic>[]},
  {
    'id': 's2',
    'name': 'Old',
    'unresolved': [
      {'path': 'gone', 'reason': 'occurrence_not_found'},
    ],
  },
];

Future<List<String>> _pump(WidgetTester tester, {String? shownId, bool dirty = false}) async {
  tester.view.physicalSize = const Size(1200, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final calls = <String>[];
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: ScenesPanel(
        scenes: _scenes,
        shownId: shownId,
        dirty: dirty,
        useViewpoint: true,
        saveView: false,
        onShow: (s) => calls.add('show ${s['id']}'),
        onNewScene: () => calls.add('new'),
        onUpdate: () => calls.add('update'),
        onSaveAsNew: () => calls.add('save new'),
        onBackToDefault: () => calls.add('back'),
        onRename: (s) => calls.add('rename ${s['id']}'),
        onDelete: (s) => calls.add('delete ${s['id']}'),
        onUseViewpointChanged: (on) => calls.add('viewpoint $on'),
        onSaveViewChanged: (on) => calls.add('save view $on'),
        onClose: () => calls.add('close'),
      ),
    ),
  ));
  await tester.pump();
  return calls;
}

void main() {
  testWidgets('in the default: New scene and the list; a row shows its scene; a scene that no longer matches says so', (tester) async {
    final calls = await _pump(tester);
    expect(find.textContaining('Showing the default'), findsOneWidget);
    expect(find.byKey(const ValueKey('scenes-new')), findsOneWidget);
    expect(find.byKey(const ValueKey('scenes-update')), findsNothing);
    expect(find.byKey(const ValueKey('scenes-back')), findsNothing);
    expect(find.text('1 change(s) no longer match the assembly'), findsOneWidget);
    await tester.tap(find.text('Exploded'));
    await tester.tap(find.byKey(const ValueKey('scenes-new')));
    expect(calls, ['show s1', 'new']);
  });

  testWidgets('a new scene: Save as new and Back to default, no Update', (tester) async {
    final calls = await _pump(tester, shownId: '', dirty: true);
    expect(find.textContaining('New scene from the default (changed)'), findsOneWidget);
    expect(find.byKey(const ValueKey('scenes-update')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('scenes-save-new')));
    await tester.tap(find.byKey(const ValueKey('scenes-back')));
    expect(calls, ['save new', 'back']);
  });

  testWidgets('a shown scene: Update, Save as new, Back to default; its row is marked; rename / delete from its menu', (tester) async {
    final calls = await _pump(tester, shownId: 's1', dirty: true);
    expect(find.textContaining('Showing "Exploded" (changed since shown)'), findsOneWidget);
    expect(tester.widget<ListTile>(find.byKey(const ValueKey('scene-row-s1'))).selected, isTrue);
    await tester.tap(find.byKey(const ValueKey('scenes-update')));
    await tester.tap(find.byKey(const ValueKey('scenes-use-viewpoint')));
    await tester.tap(find.byKey(const ValueKey('scene-menu-s2')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(calls, ['update', 'viewpoint false', 'delete s2']);
  });

  testWidgets('leaving asks Update / Discard / Stay; a new scene can only be discarded or kept on screen', (tester) async {
    late Future<SceneLeaveChoice> answer;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Column(children: [
          TextButton(onPressed: () => answer = askSceneLeave(context, canUpdate: true), child: const Text('shown')),
          TextButton(onPressed: () => answer = askSceneLeave(context, canUpdate: false), child: const Text('new')),
        ]),
      ),
    ));
    await tester.tap(find.text('shown'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('scene-leave-update')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('scene-leave-update')));
    await tester.pumpAndSettle();
    expect(await answer, SceneLeaveChoice.update);

    await tester.tap(find.text('new'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('scene-leave-update')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('scene-leave-discard')));
    await tester.pumpAndSettle();
    expect(await answer, SceneLeaveChoice.discard);

    await tester.tap(find.text('new'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5)); // dismissed: stay
    await tester.pumpAndSettle();
    expect(await answer, SceneLeaveChoice.stay);
  });
}
