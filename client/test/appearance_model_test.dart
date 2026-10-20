// The flat app's appearance model (`lib/appearance/appearance_model.dart`) against an in-memory backend: it reads every Part
// under the root, resolves looks with the rule, lists the paint rows (Face, Body, Part, Pattern (all N), Every <part> (N),
// sub-assemblies, Whole assembly), previews without sending, paints into the ROOT (merging into a level's paint, Clear
// removing it), keeps a shown scene's paint in its temporary layer, and follows the legacy Occurrence.color.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/appearance/appearance_model.dart';

Map<String, dynamic> _occ(String id, String partId, {String? color}) => {
      'id': id,
      'external_ref': null,
      'resolved_part_id': partId,
      'name_override': null,
      'transform': {
        'translation': [0.0, 0.0, 0.0],
        'rotation_axis': [0.0, 0.0, 1.0],
        'rotation_angle_degrees': 0.0,
      },
      'suppressed': false,
      'hidden': false,
      'fixed': false,
      'color': color,
    };

/// R places frame (F: barA, barB of A) and bolt (B, patterned by p1 into 2 copies).
class _Backend {
  final Map<String, Map<String, dynamic>> parts = {
    'R': {'name': 'Rig', 'occurrences': [_occ('frame', 'F'), _occ('bolt', 'B', color: '#00FF00')], 'patterns': [
      {'id': 'p1', 'source_occurrence_ids': ['bolt'], 'pattern_type': 'linear', 'direction': [1.0, 0.0, 0.0], 'count': 3, 'spacing': 10.0},
    ]},
    'F': {'name': 'Frame', 'occurrences': [_occ('barA', 'A'), _occ('barB', 'A')]},
    'A': {'name': 'Bar', 'appearance': {'roughness': 0.6}},
    'B': {'name': 'Bolt'},
  };
  final Map<String, List<Map<String, dynamic>>> overrides = {};
  final List<Map<String, dynamic>> puts = [];

  http.Response handle(http.Request request) {
    final bits = request.url.path.replaceFirst('/document/parts/', '').split('/');
    final part = parts[bits[0]];
    if (part == null) return http.Response('not found', 404);
    http.Response json(Object body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});
    if (bits.length == 1) return json({'id': bits[0], 'name': part['name'], 'appearance': part['appearance'], 'body_appearances': {}, 'face_appearances': []});
    switch (bits[1]) {
      case 'occurrences':
        return json(part['occurrences'] ?? []);
      case 'component-patterns':
        return json(part['patterns'] ?? []);
      case 'appearance-overrides':
        final list = overrides.putIfAbsent(bits[0], () => []);
        if (request.method == 'PUT') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          puts.add(body);
          list.removeWhere((r) => r['path'] == body['path'] && r['body_id'] == body['body_id'] && r['scope'] == body['scope']);
          if (body['appearance'] != null) list.add(body);
          // The backend mirrors a top-level occurrence's own colour into Occurrence.color, and clears it with the override.
          for (final o in (part['occurrences'] as List)) {
            if (o['id'] == body['path'] && body['body_id'] == null) o['color'] = (body['appearance'] as Map?)?['colour'];
          }
        }
        return json({
          'overrides': [for (final r in list) {...r, 'legacy': false, 'unresolved': null}],
        });
    }
    return http.Response('no route', 404);
  }
}

const _instances = [
  <String>[],
  ['frame'],
  ['frame', 'barA'],
  ['frame', 'barB'],
  ['bolt'],
  ['bolt#pattern:p1:1'],
  ['bolt#pattern:p1:2'],
];

void main() {
  late _Backend backend;
  late AppearanceModel model;

  setUp(() async {
    backend = _Backend();
    model = AppearanceModel(DocumentApiClient(httpClient: MockClient((r) async => backend.handle(r))));
    await model.ensureLoaded('R');
  });

  test('reads every Part under the root and resolves with the rule (legacy colour, the part\'s own look)', () {
    expect(model.partName('A'), 'Bar');
    expect(model.lookOf(['bolt'], const []).whole, {'colour': '#00FF00'});
    expect(model.lookOf(['frame', 'barA'], const []).whole, {'roughness': 0.6});
    expect(model.lookOf(['nowhere'], const []).isEmpty, isTrue);
  });

  test('the rows for a face of a bar: Face, Body, Part, Every Bar (2), Frame, Whole assembly', () {
    final rows = model.rowsFor(['frame', 'barA'], bodyId: 'b1', faceIndex: 4, instances: _instances);
    expect(rows.map((r) => r.id), ['face', 'body', 'part', 'same_part', 'sub_1', 'whole']);
    expect(rows.map((r) => r.label), ['Face', 'Body', 'Part · Bar', 'Every Bar (2)', 'Frame (3 parts)', 'Whole assembly']);
    expect(rows[3].record, {'path': '', 'scope': 'same_part', 'part_id': 'A'});
    expect(rows[3].members, ['frame/barA', 'frame/barB']);
    expect(rows[0].record['face'], {'body_id': 'b1', 'shape_type': 'face', 'index': 4});
  });

  test('a pattern copy has a Pattern (all 3) row on the source path', () {
    final rows = model.rowsFor(['bolt#pattern:p1:2'], instances: _instances);
    final pattern = rows.firstWhere((r) => r.id == 'pattern_p1');
    expect(pattern.label, 'Pattern (all 3)');
    expect(pattern.record, {'path': 'bolt', 'scope': 'pattern', 'pattern_id': 'p1'});
  });

  test('preview shows without sending; paint goes into the root and merges; Clear removes; the rows say "set here"', () async {
    final frame = model.rowsFor(['frame', 'barB'], instances: _instances).firstWhere((r) => r.id == 'sub_1');
    model.preview(frame, {'colour': '#2F6FD6'});
    expect(model.lookOf(['frame', 'barB'], const []).whole['colour'], '#2F6FD6');
    expect(backend.puts, isEmpty);
    model.endPreview();
    expect(model.lookOf(['frame', 'barB'], const []).whole.containsKey('colour'), isFalse);

    final before = await model.paint(frame, {'colour': '#2F6FD6'});
    expect(before, isNull);
    expect(backend.puts.single, {'path': 'frame', 'appearance': {'colour': '#2F6FD6'}});
    final again = model.rowsFor(['frame', 'barB'], instances: _instances).firstWhere((r) => r.id == 'sub_1');
    expect(again.setHere, isTrue);
    await model.paint(again, {'opacity': 0.5});
    expect(backend.puts.last['appearance'], {'colour': '#2F6FD6', 'opacity': 0.5}, reason: 'an opacity-only brush keeps the colour');
    expect(model.lookOf(['frame', 'barA'], const []).whole, {'colour': '#2F6FD6', 'opacity': 0.5, 'roughness': 0.6});
    await model.paint(again, const {});
    expect(backend.puts.last, {'path': 'frame', 'appearance': null});
  });

  test('a face paint splits the look of the instance', () async {
    final face = model.rowsFor(['frame', 'barA'], bodyId: 'b1', faceIndex: 2, instances: _instances).first;
    await model.paint(face, {'colour': '#FF0000'});
    final look = model.lookOf(['frame', 'barA'], [('b1', 1), ('b1', 2)]);
    expect(look.faces, isNotNull);
    expect(look.faces!['b1|2']!['colour'], '#FF0000');
    expect(look.faces!['b1|1']!.containsKey('colour'), isFalse);
    expect(model.lookOf(['frame', 'barB'], [('b1', 1), ('b1', 2)]).faces, isNull, reason: 'the other bar is unpainted');
  });

  test('clearing a top-level occurrence\'s colour clears the legacy alias too', () async {
    final bolt = model.rowsFor(['bolt'], instances: _instances).firstWhere((r) => r.id == 'part');
    await model.paint(bolt, {'colour': '#123456'});
    expect(model.lookOf(['bolt'], const []).whole['colour'], '#123456');
    await model.paint(bolt, const {});
    expect(model.lookOf(['bolt'], const []).whole, isEmpty);
  });

  test('a shown scene: its layer is on top and paint goes into it, nothing sent', () async {
    model.temporary = [
      {'path': 'frame', 'appearance': {'colour': '#D63A2F'}},
    ];
    expect(model.lookOf(['frame', 'barA'], const []).whole['colour'], '#D63A2F');
    final bolt = model.rowsFor(['bolt'], instances: _instances).firstWhere((r) => r.id == 'part');
    await model.paint(bolt, {'colour': '#FFFFFF'});
    expect(backend.puts, isEmpty);
    expect(model.temporary!.last, {'path': 'bolt', 'appearance': {'colour': '#FFFFFF'}});
    expect(model.lookOf(['bolt'], const []).whole['colour'], '#FFFFFF');
    model.temporary = null;
    expect(model.lookOf(['bolt'], const []).whole['colour'], '#00FF00');
  });

  test('recordFromWire takes a face at its current index', () {
    expect(
      AppearanceModel.recordFromWire({
        'path': 'frame/barA',
        'face': {'body_id': 'b1', 'shape_type': 'face', 'index': 3},
        'face_current_index': 7,
        'appearance': {'colour': '#FFFFFF'},
        'scope': null,
      }),
      {'path': 'frame/barA', 'appearance': {'colour': '#FFFFFF'}, 'face': {'body_id': 'b1', 'shape_type': 'face', 'index': 7}, 'body_id': 'b1'},
    );
  });
}
