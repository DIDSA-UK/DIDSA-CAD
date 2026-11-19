// Bug report 2026-11-18 plan part C: the convert-entities answers can now carry the shapes a projection makes (an elliptical arc, a spline, a lone
// point, an ellipse, several splines for a closed edge), and `convert-entities/sketch` answers with a list of them. These tests parse those shapes as
// the HTTP API documents them, and check that an older answer (none of the new fields) still parses as before.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:didsa_cad_client/api/sketch_api_client.dart';

Map<String, dynamic> _point(String id, double x, double y, {bool locked = true, bool reference = false}) =>
    {'id': id, 'x': x, 'y': y, 'is_locked': locked, if (reference) 'is_reference': true};

Map<String, dynamic> _ellipseArc() => {
      'type': 'ellipse_arc',
      'id': 'ea',
      'structural_constraint_ids': <String>[],
      'center_point_id': 'c',
      'major_point_id': 'ma',
      'minor_point_id': 'mi',
      'start_point_id': 's',
      'end_point_id': 'e',
      'major_axis_line_id': 'la',
      'minor_axis_line_id': 'li',
      'major_radius': 5.0,
      'minor_radius': 4.33,
      'rotation': 0.0,
      'construction': false,
      'is_reference': true,
    };

Map<String, dynamic> _spline(String id, List<String> through, List<String> controls) => {
      'type': 'spline',
      'id': id,
      'through_point_ids': through,
      'control_point_ids': controls,
      'construction': true,
    };

void main() {
  group('ConvertEdgeResultDto', () {
    test('an answer from before part C (a line, no new fields) parses as it always did', () {
      final dto = ConvertEdgeResultDto.fromJson({
        'line': {'id': 'l', 'start_point_id': 'a', 'end_point_id': 'b', 'length': 3.0, 'construction': false},
        'arc': null,
        'circle': null,
        'start_point': _point('a', 0, 0),
        'end_point': _point('b', 3, 0),
      });
      expect(dto.line!.id, 'l');
      expect(dto.ellipse, isNull);
      expect(dto.ellipseArc, isNull);
      expect(dto.spline, isNull);
      expect(dto.point, isNull);
      expect(dto.more, isEmpty);
      expect(dto.sourceEntityId, isNull);
      expect(dto.madeId, 'l');
    });

    test('an elliptical arc (an arc edge seen at an angle) parses with its ends and centre', () {
      final dto = ConvertEdgeResultDto.fromJson({
        'line': null,
        'arc': null,
        'circle': null,
        'ellipse': null,
        'ellipse_arc': _ellipseArc(),
        'spline': null,
        'point': null,
        'more': null,
        'start_point': _point('s', 5, 0, reference: true),
        'end_point': _point('e', -5, 0),
        'center_point': _point('c', 0, 0),
      });
      final arc = dto.ellipseArc!;
      expect(arc.id, 'ea');
      expect(arc.minorRadius, closeTo(4.33, 1e-9));
      expect(arc.isReference, isTrue);
      expect(dto.startPoint.isReference, isTrue);
      expect(dto.centerPoint!.id, 'c');
      expect(dto.line, isNull);
      expect(dto.madeId, 'ea');
    });

    test('a closed free-form edge parses as a spline plus the rest in more', () {
      final dto = ConvertEdgeResultDto.fromJson({
        'spline': _spline('s1', ['a', 'm'], ['c1', 'c2']),
        'more': [
          {
            'spline': _spline('s2', ['m', 'a'], ['c3', 'c4']),
            'start_point': _point('m', 1, 1),
            'end_point': _point('a', 0, 0),
          }
        ],
        'start_point': _point('a', 0, 0),
        'end_point': _point('m', 1, 1),
      });
      expect(dto.spline!.throughPointIds, ['a', 'm']);
      expect(dto.spline!.construction, isTrue);
      expect(dto.spline!.isReference, isFalse);
      expect(dto.more.single.spline!.id, 's2');
      expect(dto.more.single.spline!.controlPointIds, ['c3', 'c4']);
    });

    test('a lone point (a straight edge along the normal) parses as point, start and end alike', () {
      final dto = ConvertEdgeResultDto.fromJson({
        'point': _point('p', 2, 3),
        'start_point': _point('p', 2, 3),
        'end_point': _point('p', 2, 3),
      });
      expect(dto.point!.id, 'p');
      expect(dto.startPoint.id, dto.endPoint.id);
      expect(dto.madeId, 'p');
    });

    test('a whole ellipse parses, its reference flag included', () {
      final dto = ConvertEdgeResultDto.fromJson({
        'ellipse': {
          'id': 'el',
          'center_point_id': 'c',
          'major_point_id': 'a',
          'major_point_neg_id': 'an',
          'minor_point_id': 'b',
          'minor_point_neg_id': 'bn',
          'major_axis_line_id': 'la',
          'minor_axis_line_id': 'lb',
          'major_radius': 4.0,
          'minor_radius': 3.46,
          'rotation': 0.0,
          'is_reference': true,
        },
        'start_point': _point('c', 0, 0),
        'end_point': _point('c', 0, 0),
        'center_point': _point('c', 0, 0),
      });
      expect(dto.ellipse!.id, 'el');
      expect(dto.ellipse!.isReference, isTrue);
      expect(dto.madeId, 'el');
    });
  });

  group('ConvertSketchResultDto', () {
    test('items carry their source entity and the skipped list parses', () {
      final dto = ConvertSketchResultDto.fromJson({
        'items': [
          {
            'line': {'id': 'l', 'start_point_id': 'a', 'end_point_id': 'b', 'length': 3.0, 'construction': false},
            'source_entity_id': 'src-line',
            'start_point': _point('a', 0, 0),
            'end_point': _point('b', 3, 0),
          },
          {
            'point': _point('p', 1, 1),
            'source_entity_id': 'src-point',
            'start_point': _point('p', 1, 1),
            'end_point': _point('p', 1, 1),
          },
        ],
        'skipped': [
          {'entity_id': 'txt', 'reason': 'text', 'message': 'Text is not converted.'}
        ],
      });
      expect(dto.items.map((i) => i.sourceEntityId), ['src-line', 'src-point']);
      expect(dto.items.map((i) => i.madeId), ['l', 'p']);
      expect(dto.skipped.single.entityId, 'txt');
      expect(dto.skipped.single.reason, 'text');
    });

    test('an answer with no skipped list parses as none skipped', () {
      final dto = ConvertSketchResultDto.fromJson({'items': <Object>[]});
      expect(dto.items, isEmpty);
      expect(dto.skipped, isEmpty);
    });
  });

  group('SketchApiClient.convertSketchEntities', () {
    test('posts the source and options to convert-entities/sketch and parses the answer', () async {
      late http.Request sent;
      final api = SketchApiClient(
        httpClient: MockClient((request) async {
          sent = request;
          return http.Response(
            jsonEncode({
              'items': [
                {
                  'ellipse_arc': _ellipseArc(),
                  'source_entity_id': 'src-arc',
                  'start_point': _point('s', 5, 0),
                  'end_point': _point('e', -5, 0),
                  'center_point': _point('c', 0, 0),
                }
              ],
              'skipped': <Object>[],
            }),
            201,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      final result = await api.convertSketchEntities('part', 'target', 'source', entityIds: ['src-arc'], includeConstruction: true);
      expect(sent.method, 'POST');
      expect(sent.url.path, endsWith('/document/parts/part/features/sketch/target/convert-entities/sketch'));
      expect(jsonDecode(sent.body), {
        'source_sketch_feature_id': 'source',
        'entity_ids': ['src-arc'],
        'construction': false,
        'include_construction': true,
      });
      expect(result.items.single.ellipseArc!.id, 'ea');
      expect(result.items.single.sourceEntityId, 'src-arc');
    });

    test('the whole sketch is asked for by leaving entity_ids out', () async {
      late http.Request sent;
      final api = SketchApiClient(
        httpClient: MockClient((request) async {
          sent = request;
          return http.Response(jsonEncode({'items': <Object>[], 'skipped': <Object>[]}), 201, headers: {'content-type': 'application/json'});
        }),
      );
      await api.convertSketchEntities('part', 'target', 'source', reference: true);
      final body = jsonDecode(sent.body) as Map<String, dynamic>;
      expect(body.containsKey('entity_ids'), isFalse);
      expect(body['reference'], isTrue);
    });
  });
}
