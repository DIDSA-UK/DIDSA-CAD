// The dimension catalogue (docs/sketch-dimension-catalogue.json, DIDSA-VR docs/dimension-constraint-parity-plan.md section 3.1) against
// the flat app's Dimension tool: for each entry, a selection is built in a real SketchController and its drawer options are compared with
// the entry - keys, order, labels, default, what each one creates, the pointer-chosen side, the cursor rule and the `when` conditions.
// The catalogue is the contract both apps test against; a change to the tool's options is a change to that file.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/sketch/dimension_types.dart';
import 'package:didsa_cad_client/sketch/sketch_controller.dart';

const String _cataloguePath = '../docs/sketch-dimension-catalogue.json';

const _whenVocabulary = {
  'lines_parallel',
  'lines_not_parallel',
  'point_not_on_line_end',
  'point_not_of_curve',
  'curves_apart',
  'line_misses_curve',
};

typedef XY = (double, double);

XY _on(XY c, double r, double degrees) => (c.$1 + r * math.cos(degrees * math.pi / 180), c.$2 + r * math.sin(degrees * math.pi / 180));

/// A sketch to pick in: Points (some pinned), Lines, Circles, Arcs, Ellipses and elliptical Arcs, and where to tap for each pick.
class _Fixture {
  final String name;
  final Map<String, XY> points;
  final Set<String> pinned;
  final Map<String, (String, String)> lines;
  final Map<String, (String, String)> circles;
  final Map<String, (String, String, String)> arcs;
  final bool ellipse;
  final bool ellipseArc;

  /// Taps, in pick order, with the selection kind each must pick (catalogue spelling).
  final List<(XY, String)> taps;

  /// The `when` conditions that hold for this geometry.
  final Set<String> facts;

  /// Two cursor positions in different sectors, for a pointer-sided option.
  final (XY, XY)? sectorProbe;

  /// Whether the taps may be made in the other order with the same result (two picks, unordered).
  final bool tryReversed;

  /// Expect nothing at all, whatever the catalogue says (a degenerate selection from the catalogue's notes).
  final bool expectNone;

  const _Fixture(
    this.name, {
    this.points = const {},
    this.pinned = const {},
    this.lines = const {},
    this.circles = const {},
    this.arcs = const {},
    this.ellipse = false,
    this.ellipseArc = false,
    required this.taps,
    this.facts = const {},
    this.sectorProbe,
    this.tryReversed = true,
    this.expectNone = false,
  });

  List<String> get picks => [for (final t in taps) t.$2];
}

final _fixtures = <_Fixture>[
  _Fixture(
    'one line',
    points: {'a': (0, 0), 'b': (10, 4)},
    lines: {'L': ('a', 'b')},
    taps: [((2.5, 1.0), 'line')],
    sectorProbe: ((-3, 3), (13, 2)),
  ),
  _Fixture(
    'one circle',
    points: {'c': (0, 0), 'r': (5, 0)},
    circles: {'C': ('c', 'r')},
    taps: [(_on((0, 0), 5, 45), 'circle')],
  ),
  _Fixture(
    'one arc',
    points: {'c': (0, 0), 's': (5, 0), 'e': (0, 5)},
    arcs: {'A': ('c', 's', 'e')},
    taps: [(_on((0, 0), 5, 45), 'arc')],
  ),
  _Fixture(
    'one ellipse',
    points: {'c': (0, 0), 'M': (6, 0), 'Mn': (-6, 0), 'm': (0, 3), 'mn': (0, -3)},
    ellipse: true,
    taps: [((6 * 0.5, 3 * 0.8660254037844386), 'ellipse')],
  ),
  _Fixture(
    'one elliptical arc',
    points: {'c': (0, 0), 'M': (6, 0), 'm': (0, 3), 's': (5.196152422706632, -1.5), 'e': (-3, 2.598076211353316)},
    ellipseArc: true,
    taps: [((6 * 0.7071067811865476, 3 * 0.7071067811865476), 'ellipse_arc')],
  ),
  _Fixture(
    'two points',
    points: {'p': (0, 0), 'q': (10, 5)},
    taps: [((0, 0), 'point'), ((10, 5), 'point')],
  ),
  _Fixture(
    'point and line',
    points: {'a': (0, 10), 'b': (20, 10), 'p': (8, 3)},
    lines: {'L': ('a', 'b')},
    taps: [((8, 3), 'point'), ((4, 10), 'line')],
    facts: {'point_not_on_line_end'},
  ),
  _Fixture(
    'an end of the line and the line',
    points: {'a': (0, 10), 'b': (20, 10)},
    lines: {'L': ('a', 'b')},
    taps: [((20, 10), 'point'), ((4, 10), 'line')],
  ),
  _Fixture(
    'two parallel lines',
    points: {'a': (0, 0), 'b': (10, 0), 'c': (0, 6), 'd': (10, 6)},
    lines: {'L1': ('a', 'b'), 'L2': ('c', 'd')},
    taps: [((8, 0), 'line'), ((8, 6), 'line')],
    facts: {'lines_parallel'},
  ),
  _Fixture(
    'two lines at an angle',
    points: {'a': (0, 0), 'b': (10, 0), 'c': (0, 2), 'd': (10, 8)},
    lines: {'L1': ('a', 'b'), 'L2': ('c', 'd')},
    taps: [((8, 0), 'line'), ((2.5, 3.5), 'line')],
    facts: {'lines_not_parallel'},
    // The lines meet at (-10/3, 0): one probe inside the angle they open into, one in the opposite sector.
    sectorProbe: ((8, 2), (-8, -1)),
  ),
  _Fixture(
    'a point and a circle',
    points: {'c': (20, 20), 'r': (24, 20), 'p': (2, 2)},
    circles: {'C': ('c', 'r')},
    taps: [((2, 2), 'point'), (_on((20, 20), 4, 45), 'circle')],
    facts: {'point_not_of_curve'},
  ),
  _Fixture(
    'the circle\'s rim Point and the circle',
    points: {'c': (20, 20), 'r': (24, 20)},
    circles: {'C': ('c', 'r')},
    taps: [((24, 20), 'point'), (_on((20, 20), 4, 45), 'circle')],
  ),
  _Fixture(
    'a point and an arc',
    points: {'c': (20, 20), 's': (24, 20), 'e': (20, 24), 'p': (2, 2)},
    arcs: {'A': ('c', 's', 'e')},
    taps: [((2, 2), 'point'), (_on((20, 20), 4, 45), 'arc')],
    facts: {'point_not_of_curve'},
  ),
  _Fixture(
    'the arc\'s end Point and the arc',
    points: {'c': (20, 20), 's': (24, 20), 'e': (20, 24)},
    arcs: {'A': ('c', 's', 'e')},
    taps: [((20, 24), 'point'), (_on((20, 20), 4, 45), 'arc')],
  ),
  _Fixture(
    'two circles apart',
    points: {'c1': (0, 0), 'r1': (3, 0), 'c2': (30, 10), 'r2': (34, 10)},
    circles: {'C1': ('c1', 'r1'), 'C2': ('c2', 'r2')},
    taps: [(_on((0, 0), 3, 45), 'circle'), (_on((30, 10), 4, 45), 'circle')],
    facts: {'curves_apart'},
  ),
  _Fixture(
    'two overlapping circles',
    points: {'c1': (0, 0), 'r1': (5, 0), 'c2': (6, 0), 'r2': (10, 0)},
    circles: {'C1': ('c1', 'r1'), 'C2': ('c2', 'r2')},
    taps: [(_on((0, 0), 5, 135), 'circle'), (_on((6, 0), 4, 45), 'circle')],
  ),
  _Fixture(
    'a circle and an arc apart',
    points: {'c1': (0, 0), 'r1': (3, 0), 'c2': (30, 10), 's2': (34, 10), 'e2': (30, 14)},
    circles: {'C1': ('c1', 'r1')},
    arcs: {'A2': ('c2', 's2', 'e2')},
    taps: [(_on((0, 0), 3, 135), 'circle'), (_on((30, 10), 4, 45), 'arc')],
    facts: {'curves_apart'},
  ),
  _Fixture(
    'two overlapping arcs',
    points: {'c1': (0, 0), 's1': (5, 0), 'e1': (0, 5), 'c2': (8, 0), 's2': (12, 0), 'e2': (8, 4)},
    arcs: {'A1': ('c1', 's1', 'e1'), 'A2': ('c2', 's2', 'e2')},
    taps: [(_on((0, 0), 5, 45), 'arc'), (_on((8, 0), 4, 45), 'arc')],
  ),
  _Fixture(
    'a line clear of a circle',
    points: {'a': (0, 0), 'b': (40, 0), 'c': (20, 15), 'r': (24, 15)},
    lines: {'L': ('a', 'b')},
    circles: {'C': ('c', 'r')},
    taps: [((5, 0), 'line'), (_on((20, 15), 4, 45), 'circle')],
    facts: {'line_misses_curve'},
  ),
  _Fixture(
    'a line through a circle',
    points: {'a': (0, 0), 'b': (40, 0), 'c': (20, 2), 'r': (24, 2)},
    lines: {'L': ('a', 'b')},
    circles: {'C': ('c', 'r')},
    taps: [((5, 0), 'line'), (_on((20, 2), 4, 45), 'circle')],
  ),
  _Fixture(
    'a line clear of an arc',
    points: {'a': (0, 0), 'b': (40, 0), 'c': (20, 15), 's': (24, 15), 'e': (20, 19)},
    lines: {'L': ('a', 'b')},
    arcs: {'A': ('c', 's', 'e')},
    taps: [((5, 0), 'line'), (_on((20, 15), 4, 45), 'arc')],
    facts: {'line_misses_curve'},
  ),
  _Fixture(
    'three points, the vertex first',
    points: {'v': (0, 0), 'p1': (10, 0), 'p2': (0, 10)},
    taps: [((0, 0), 'point'), ((10, 0), 'point'), ((0, 10), 'point')],
    tryReversed: false,
    sectorProbe: ((4, 4), (-4, 4)),
  ),
  // The catalogue's notes: selections that offer nothing although an entry matches their picks.
  _Fixture(
    'a circle\'s centre and the circle',
    points: {'c': (0, 0), 'r': (5, 0)},
    circles: {'C': ('c', 'r')},
    taps: [((0, 0), 'point'), (_on((0, 0), 5, 45), 'circle')],
    expectNone: true,
  ),
  _Fixture(
    'a line ending at a circle\'s centre',
    points: {'c': (0, 0), 'r': (5, 0), 'b': (20, 10)},
    lines: {'L': ('c', 'b')},
    circles: {'C': ('c', 'r')},
    taps: [((16, 8), 'line'), (_on((0, 0), 5, 120), 'circle')],
    expectNone: true,
  ),
  _Fixture(
    'two circles on one centre Point',
    points: {'c': (0, 0), 'r1': (3, 0), 'r2': (8, 0)},
    circles: {'C1': ('c', 'r1'), 'C2': ('c', 'r2')},
    taps: [(_on((0, 0), 3, 45), 'circle'), (_on((0, 0), 8, 45), 'circle')],
    expectNone: true,
  ),
  _Fixture(
    'a line between two pinned Points',
    points: {'a': (0, 0), 'b': (10, 4)},
    pinned: {'a', 'b'},
    lines: {'L': ('a', 'b')},
    taps: [((2.5, 1.0), 'line')],
    expectNone: true,
  ),
];

Map<String, dynamic> _loadCatalogue() {
  final f = File(_cataloguePath);
  if (!f.existsSync()) fail('$_cataloguePath not found (run `flutter test` from client/)');
  return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
}

String _kindName(SelectionKind kind) => switch (kind) {
      SelectionKind.point => 'point',
      SelectionKind.line => 'line',
      SelectionKind.circle => 'circle',
      SelectionKind.arc => 'arc',
      SelectionKind.ellipse => 'ellipse',
      SelectionKind.ellipseArc => 'ellipse_arc',
      _ => kind.name,
    };

/// What confirming [ghost] makes, in the catalogue's `creates` spelling.
String _creates(DimensionGhost ghost) => switch (ghost.kind) {
      GhostKind.length || GhostKind.linear => 'distance:linear',
      GhostKind.horizontal => 'distance:horizontal',
      GhostKind.vertical => 'distance:vertical',
      GhostKind.radius => 'radius',
      GhostKind.diameter => 'diameter',
      GhostKind.lineDistance => 'line_distance',
      GhostKind.angle => 'angle',
      GhostKind.pointLine => 'point_line_distance',
      GhostKind.typed => () {
          final body = dimensionCreateJson(ghost.template!, 1.0);
          final side = body['side'];
          return side == null ? body['type'] as String : '${body['type']}:$side';
        }(),
    };

/// The entries whose picks match [picks] and whose `when` holds for [facts].
List<Map<String, dynamic>> _matching(Map<String, dynamic> catalogue, List<String> picks, Set<String> facts) {
  bool samePicks(Map<String, dynamic> e) {
    final want = (e['picks'] as List).cast<String>();
    if (want.length != picks.length) return false;
    if (e['ordered'] == true) return _listEq(want, picks);
    final a = [...want]..sort();
    final b = [...picks]..sort();
    return _listEq(a, b);
  }

  return [
    for (final e in (catalogue['entries'] as List).cast<Map<String, dynamic>>())
      if (samePicks(e) && (e['when'] == null || facts.contains(e['when']))) e,
  ];
}

bool _listEq<T>(List<T> a, List<T> b) => a.length == b.length && [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((x) => x);

/// The options [entry] offers under [facts], in drawer order.
List<Map<String, dynamic>> _offered(Map<String, dynamic> entry, Set<String> facts) => [
      for (final o in (entry['options'] as List).cast<Map<String, dynamic>>())
        if (o['when'] == null || facts.contains(o['when'])) o,
    ];

Future<SketchController> _sketch(_Fixture f) async {
  final pointsJson = [
    for (final e in f.points.entries) {'id': e.key, 'x': e.value.$1, 'y': e.value.$2, 'is_locked': f.pinned.contains(e.key)},
  ];
  final controller = SketchController(
    api: SketchApiClient(
      httpClient: MockClient((request) async {
        if (request.method != 'GET') return http.Response('not expected: ${request.method} ${request.url.path}', 404);
        final path = request.url.path;
        if (path == '/sketch/sketches/s1') {
          return http.Response(jsonEncode({'id': 's1', 'plane': 'XY', 'origin_point_id': 'origin'}), 200);
        }
        if (path == '/sketch/sketches/s1/points') return http.Response(jsonEncode(pointsJson), 200);
        return http.Response('[]', 200);
      }),
    ),
  );
  await controller.adoptSketch('s1');
  expect(controller.errorMessage, isNull, reason: 'loading the fixture');
  // The sketch origin is a Point at (0, 0) the fixtures do not mean (several use (0, 0) for their own Points): out of the way.
  controller.points.remove('origin');
  for (final e in f.lines.entries) {
    controller.lines[e.key] = SketchLineView(id: e.key, startPointId: e.value.$1, endPointId: e.value.$2);
  }
  for (final e in f.circles.entries) {
    controller.circles[e.key] = SketchCircleView(id: e.key, centerPointId: e.value.$1, radiusPointId: e.value.$2);
  }
  for (final e in f.arcs.entries) {
    controller.arcs[e.key] = SketchArcView(id: e.key, centerPointId: e.value.$1, startPointId: e.value.$2, endPointId: e.value.$3);
  }
  if (f.ellipse) {
    controller.ellipses['E'] = const SketchEllipseView(
      id: 'E',
      centerPointId: 'c',
      majorPointId: 'M',
      majorPointNegId: 'Mn',
      minorPointId: 'm',
      minorPointNegId: 'mn',
      majorAxisLineId: 'axM',
      minorAxisLineId: 'axm',
      minorRadius: 3,
    );
  }
  if (f.ellipseArc) {
    controller.ellipseArcs['EA'] = const SketchEllipseArcView(
      id: 'EA',
      centerPointId: 'c',
      majorPointId: 'M',
      minorPointId: 'm',
      startPointId: 's',
      endPointId: 'e',
      majorAxisLineId: 'axM',
      minorAxisLineId: 'axm',
      minorRadius: 3,
    );
  }
  return controller;
}

Future<void> _pick(SketchController controller, List<(XY, String)> taps) async {
  controller.enterDimensionMode();
  for (final (xy, _) in taps) {
    await controller.handleCanvasTap(xy.$1, xy.$2);
  }
  expect(
    [for (final s in controller.dimensionSelection) _kindName(s.kind)],
    [for (final t in taps) t.$2],
    reason: 'the taps pick what the fixture means',
  );
}

/// The ids of the Points [f] declares (a picked Point must be one of them).
void _expectOwnPoints(SketchController controller, _Fixture f) {
  for (final s in controller.dimensionSelection.where((s) => s.kind == SelectionKind.point)) {
    expect(f.points.keys, contains(s.id));
  }
}

/// The quadrant (which of the angles it is) the previewed option would be made with: the sticky sector of a two-line angle, else the
/// typed constraint's own quadrant. Null for an option with no side to choose.
int? _sideNow(SketchController controller) {
  final ghost = controller.pendingDimensionGhost!;
  if (ghost.kind == GhostKind.angle) return controller.angleGhostQuadrant(ghost);
  final constraint = controller.ghostAsConstraint(ghost);
  return constraint == null ? null : dimensionQuadrant(constraint);
}

void main() {
  final catalogue = _loadCatalogue();
  final entries = (catalogue['entries'] as List).cast<Map<String, dynamic>>();

  test('the catalogue is well formed (section 3.1)', () {
    expect(catalogue['version'], 1);
    const pickWords = {'point', 'line', 'circle', 'arc', 'ellipse', 'ellipse_arc'};
    for (final e in entries) {
      final picks = (e['picks'] as List).cast<String>();
      expect(pickWords.containsAll(picks), isTrue, reason: '$picks');
      expect(e['ordered'], isA<bool>());
      expect(e['when'] == null || _whenVocabulary.contains(e['when']), isTrue, reason: '${e['when']}');
      expect(e['cursor_rule'], anyOf(isNull, 'point_pair_box'));
      final options = (e['options'] as List).cast<Map<String, dynamic>>();
      expect(options, isNotEmpty);
      final keys = [for (final o in options) o['key']];
      expect(keys.toSet().length, keys.length, reason: 'unique keys in $picks');
      expect(keys, contains(e['default']));
      for (final o in options) {
        expect(o['label'], isA<String>());
        expect(o['creates'], isA<String>());
        expect(o['side'], anyOf(isNull, 'pointer'));
        expect(o['when'] == null || _whenVocabulary.contains(o['when']), isTrue, reason: '${o['when']}');
      }
    }
  });

  test('every entry and every `when` condition (held and not held) is covered by a fixture', () {
    final covered = <Map<String, dynamic>>{};
    final held = <String>{};
    final notHeld = <String>{};
    for (final f in _fixtures.where((f) => !f.expectNone)) {
      covered.addAll(_matching(catalogue, f.picks, f.facts));
      held.addAll(f.facts);
      for (final e in entries) {
        final picks = (e['picks'] as List).cast<String>();
        if (!_listEq([...picks]..sort(), [...f.picks]..sort())) continue;
        for (final w in [e['when'], for (final o in (e['options'] as List)) (o as Map)['when']]) {
          if (w != null && !f.facts.contains(w)) notHeld.add(w as String);
        }
      }
    }
    expect(covered.length, entries.length, reason: 'an entry no fixture builds');
    final used = {
      for (final e in entries) ...[e['when'], for (final o in (e['options'] as List)) (o as Map)['when']],
    }.whereType<String>().toSet();
    expect(held.containsAll(used), isTrue, reason: 'held: $held, used: $used');
    expect(notHeld, used, reason: 'each condition is also seen not holding');
  });

  group('the Dimension tool offers what the catalogue lists', () {
    for (final f in _fixtures) {
      final orders = [
        f.taps,
        if (f.tryReversed && f.taps.length == 2) f.taps.reversed.toList(),
      ];
      for (final taps in orders) {
        final reversed = !identical(taps, f.taps);
        test('${f.name}${reversed ? ' (picked the other way round)' : ''}', () async {
          final controller = await _sketch(f);
          await _pick(controller, taps);
          _expectOwnPoints(controller, f);
          final picks = [for (final t in taps) t.$2];
          final options = controller.pendingDimensionOptions;

          if (f.expectNone) {
            expect(options, isEmpty);
            return;
          }
          final matched = _matching(catalogue, picks, f.facts);
          expect(matched.length, lessThanOrEqualTo(1), reason: 'the catalogue is ambiguous for $picks with ${f.facts}');
          if (matched.isEmpty) {
            expect(options, isEmpty, reason: 'no entry holds, so nothing is offered');
            return;
          }
          final entry = matched.single;
          final want = _offered(entry, f.facts);

          expect([for (final g in options) g.key], [for (final o in want) o['key']], reason: 'keys in drawer order');
          expect([for (final g in options) g.displayLabel], [for (final o in want) o['label']], reason: 'labels');
          expect([for (final g in options) _creates(g)], [for (final o in want) o['creates']], reason: 'what each creates');

          // The default: where the cursor goes does not matter, except under a cursor rule.
          final rule = entry['cursor_rule'];
          if (rule == null) {
            for (final probe in [(-50.0, -50.0), (50.0, 50.0)]) {
              controller.moveCursorToSketchPoint(probe.$1, probe.$2);
              expect(controller.pendingDimensionKey, entry['default'], reason: 'the cursor does not change the kind');
            }
          } else {
            // The pair: the picked Points, a circle or an arc standing in by its centre.
            final pairIds = {options.first.pointAId, options.first.pointBId};
            final wantIds = {
              for (final s in controller.dimensionSelection)
                switch (s.kind) {
                  SelectionKind.circle => controller.circles[s.id]!.centerPointId,
                  SelectionKind.arc => controller.arcs[s.id]!.centerPointId,
                  _ => s.id,
                },
            };
            expect(pairIds, wantIds, reason: 'the cursor rule\'s pair');
            final a = controller.points[options.first.pointAId]!, b = controller.points[options.first.pointBId]!;
            final mid = ((a.x + b.x) / 2, (a.y + b.y) / 2);
            final far = (math.max(a.x, b.x) + 20, math.max(a.y, b.y) + 20);
            controller.moveCursorToSketchPoint(mid.$1, far.$2);
            expect(controller.pendingDimensionKey, 'h', reason: 'above / below the pair\'s box');
            controller.moveCursorToSketchPoint(far.$1, mid.$2);
            expect(controller.pendingDimensionKey, 'v', reason: 'left / right of the box');
            controller.moveCursorToSketchPoint(mid.$1, mid.$2);
            expect(controller.pendingDimensionKey, entry['default'], reason: 'inside the box');
            controller.moveCursorToSketchPoint(far.$1, far.$2);
            expect(controller.pendingDimensionKey, entry['default'], reason: 'a corner region');
            // Once the drawer picks a kind it stays.
            expect(controller.selectPendingDimensionKind('v'), isTrue);
            controller.moveCursorToSketchPoint(mid.$1, far.$2);
            expect(controller.pendingDimensionKey, 'v');
          }

          // The pointer-chosen side: only the options marked `side: pointer` follow the pointer.
          for (final o in want) {
            expect(controller.selectPendingDimensionKind(o['key'] as String), isTrue);
            if (o['side'] == 'pointer') {
              final (s1, s2) = f.sectorProbe!;
              controller.moveCursorToSketchPoint(s1.$1, s1.$2);
              final first = _sideNow(controller);
              controller.moveCursorToSketchPoint(s2.$1, s2.$2);
              final second = _sideNow(controller);
              expect(first, isNotNull, reason: '${o['key']}: a side is chosen');
              expect(second, isNot(first), reason: '${o['key']}: the side follows the pointer');
            } else {
              expect(_sideNow(controller), isNull, reason: '${o['key']} has no side to choose');
            }
          }

          if (entry['ordered'] == true) {
            final template = options.single.template as PointAngleConstraintDto;
            expect(template.vertexPointId, controller.dimensionSelection.first.id, reason: 'the first pick is the vertex');
          }
        });
      }
    }
  });

  test('the three-point angle keeps the first pick as the vertex whichever Point it is', () async {
    final f = _fixtures.firstWhere((f) => f.name.startsWith('three points'));
    final controller = await _sketch(f);
    await _pick(controller, [((10, 0), 'point'), ((0, 0), 'point'), ((0, 10), 'point')]);
    final template = controller.pendingDimensionOptions.single.template as PointAngleConstraintDto;
    expect(template.vertexPointId, 'p1');
  });

  test('two Points on two different parallel lines are read as the two lines (the catalogue\'s notes)', () async {
    const f = _Fixture(
      'ends of two parallel lines',
      points: {'a': (0, 0), 'b': (10, 0), 'c': (0, 6), 'd': (10, 6)},
      lines: {'L1': ('a', 'b'), 'L2': ('c', 'd')},
      taps: [((10, 0), 'point'), ((0, 6), 'point')],
    );
    final controller = await _sketch(f);
    await _pick(controller, f.taps);
    final want = _offered(_matching(catalogue, ['line', 'line'], {'lines_parallel'}).single, const {});
    expect([for (final g in controller.pendingDimensionOptions) g.key], [for (final o in want) o['key']]);
  });

  group('pinned: the reference kinds per selection', () {
    final pinned = catalogue['pinned'] as Map<String, dynamic>;
    final kinds = (pinned['kinds'] as Map<String, dynamic>).map((k, v) => MapEntry(k, (v as List).cast<String>()));

    test('the block is well formed', () {
      expect(pinned['offer'], 'reference');
      const referenceKinds = {
        'distance', 'horizontal', 'vertical', 'radius', 'diameter', 'angle', //
        'arc_length', 'horizontal_angle', 'point_angle', 'min_distance', 'max_distance',
      };
      for (final list in kinds.values) {
        expect(referenceKinds.containsAll(list), isTrue, reason: '$list');
      }
    });

    for (final shape in kinds.keys) {
      test(shape, () async {
        final picks = shape.split('+');
        final f = _fixtures.firstWhere(
          (f) => !f.expectNone && _listEq(f.picks, picks),
          orElse: () => _fixtures.firstWhere((f) => _listEq([...f.picks]..sort(), [...picks]..sort())),
        );
        final controller = await _sketch(f);
        await _pick(controller, f.taps);
        expect(controller.referenceDimensionKinds, kinds[shape]);
      });
    }

    test('every Point of the picks pinned: no driving dimension is offered', () async {
      final f = _fixtures.firstWhere((f) => f.name == 'a line between two pinned Points');
      final controller = await _sketch(f);
      await _pick(controller, f.taps);
      expect(controller.pendingDimensionOptions, isEmpty);
      expect(controller.referenceDimensionKinds, isNotEmpty, reason: 'the reference kinds are still there for the bar');
    });
  });
}
