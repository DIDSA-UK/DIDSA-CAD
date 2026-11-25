import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('ProfileDetectionDto.fromJson', () {
    test('a single closed_loop with a hole becomes one fillableLoop with one innerLoop', () {
      final dto = ProfileDetectionDto.fromJson({
        'status': 'closed_loop',
        'detail': 'ok',
        'profile': {
          'point_ids': ['a', 'b', 'c', 'd'],
          'line_ids': ['l1', 'l2', 'l3', 'l4'],
          'inner_loops': [
            {
              'point_ids': ['e', 'f', 'g', 'h'],
              'line_ids': ['l5', 'l6', 'l7', 'l8'],
              'inner_loops': <Map<String, dynamic>>[],
            },
          ],
        },
        'branch_point_ids': <String>[],
        'loops': <Map<String, dynamic>>[],
      });

      expect(dto.isClosedLoop, isTrue);
      expect(dto.isExtrudable, isTrue);
      expect(dto.fillableLoops, hasLength(1));
      expect(dto.fillableLoops.single.pointIds, ['a', 'b', 'c', 'd']);
      expect(dto.fillableLoops.single.innerLoops, hasLength(1));
      expect(dto.fillableLoops.single.innerLoops.single.pointIds, ['e', 'f', 'g', 'h']);
    });

    test('a MultiProfile (multiple_loops) becomes one fillableLoop per outer loop', () {
      final dto = ProfileDetectionDto.fromJson({
        'status': 'multiple_loops',
        'detail': '2 disjoint outer profiles found in this sketch.',
        'profile': null,
        'branch_point_ids': <String>[],
        'loops': [
          {
            'point_ids': ['a', 'b', 'c', 'd'],
            'line_ids': ['l1', 'l2', 'l3', 'l4'],
            'inner_loops': [
              {
                'point_ids': ['e', 'f', 'g', 'h'],
                'line_ids': ['l5', 'l6', 'l7', 'l8'],
                'inner_loops': <Map<String, dynamic>>[],
              },
            ],
          },
          {
            'point_ids': ['i', 'j', 'k'],
            'line_ids': ['l9', 'l10', 'l11'],
            'inner_loops': <Map<String, dynamic>>[],
          },
        ],
      });

      expect(dto.isClosedLoop, isFalse);
      expect(dto.isExtrudable, isTrue);
      expect(dto.fillableLoops, hasLength(2));
      expect(dto.fillableLoops[0].innerLoops, hasLength(1));
      expect(dto.fillableLoops[1].innerLoops, isEmpty);
    });

    test('a status with no usable profile has no fillableLoops', () {
      final dto = ProfileDetectionDto.fromJson({
        'status': 'no_loop',
        'detail': 'Sketch has no connectable entities (e.g. lines or circles).',
        'profile': null,
        'branch_point_ids': <String>[],
        'loops': <Map<String, dynamic>>[],
      });

      expect(dto.isExtrudable, isFalse);
      expect(dto.fillableLoops, isEmpty);
    });
  });

  test('P3 review: an answer that cannot be read is an ApiException with the short message and its 2xx status code', () async {
    for (final body in ['<html>proxy error</html>', '[1, 2, 3]']) {
      final client = SketchApiClient(httpClient: MockClient((request) async => http.Response(body, 200)));
      final error = await client.getSketch('s1').then<Object?>((_) => null, onError: (Object e) => e);
      expect(error, isA<ApiException>(), reason: body);
      expect((error as ApiException).message, ApiException.unreadableAnswerMessage);
      expect(error.statusCode, 200);
    }
  });

  // B3 (P3's review): a decode failure of any shape kind was only mapped for FormatException and TypeError; a missing object (NoSuchMethodError)
  // or a missing list entry (RangeError, StateError) escaped the client raw.
  group('decodeOrUnreadable', () {
    ApiException? unreadable(Object Function() onSuccess) {
      try {
        decodeOrUnreadable<Object>('{}', (_) => onSuccess(), name: 'test', statusCode: 200);
      } on ApiException catch (e) {
        return e;
      }
      return null;
    }

    test('NoSuchMethodError, RangeError and StateError while decoding are the unreadable answer with the 2xx status', () {
      final cases = <String, Object Function()>{
        'a missing object': () => (null as dynamic).field as Object,
        'a missing list entry': () => <Object>[][0],
        'a list that is empty': () => <Object>[].first,
      };
      for (final entry in cases.entries) {
        final error = unreadable(entry.value);
        expect(error, isNotNull, reason: entry.key);
        expect(error!.message, ApiException.unreadableAnswerMessage, reason: entry.key);
        expect(error.statusCode, 200, reason: entry.key);
      }
    });

    // B4 (B3's review): mapping these three can hide a bug in a `fromJson`; the exception keeps what was raised and where.
    test('the unreadable answer keeps the error decoding raised and its stack', () {
      final error = unreadable(() => <Object>[].first)!;
      expect(error.cause, isA<StateError>());
      expect(error.causeStackTrace, isNotNull);
      final format = unreadable(() => throw const FormatException('bad'))!;
      expect(format.cause, isA<FormatException>());
    });

    test("an ApiException from the callback and an error that is not a decode failure go through (they are not the answer's fault)", () {
      expect(() => decodeOrUnreadable<Object>('{}', (_) => throw ApiException('own', statusCode: 409), name: 't', statusCode: 200),
          throwsA(isA<ApiException>().having((e) => e.message, 'message', 'own')));
      expect(() => decodeOrUnreadable<Object>('{}', (_) => throw UnimplementedError('bug'), name: 't', statusCode: 200),
          throwsA(isA<UnimplementedError>()));
    });
  });

  // B4 (P3's review): several failures joined into one kept no status code.
  test('ApiException.joined says each message once and keeps the first status code', () {
    final joined = ApiException.joined([
      ApiException('mesh failed'),
      ApiException('features failed', statusCode: 422),
      ApiException('mesh failed', statusCode: 500),
    ]);
    expect(joined.message, 'mesh failed\nfeatures failed');
    expect(joined.statusCode, 422);
    expect(ApiException.joined([ApiException('a'), ApiException('b')]).statusCode, isNull);
  });
}
