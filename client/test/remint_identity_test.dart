import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/assembly/remint_identity.dart';

/// Bug report 2026-10-14, item 3: the tester's two real files. B is a Save As
/// copy of A (same document, Part and sketch ids) edited to 1600 mm.
Map<String, dynamic> _fixture(String name) =>
    jsonDecode(File('test/fixtures/$name').readAsStringSync()) as Map<String, dynamic>;

void main() {
  test('the fixtures really do share identity', () {
    final a = _fixture('frame_a_save_as_source.DIDSAprt');
    final b = _fixture('frame_b_save_as_copy.DIDSAprt');
    expect(collectNativeIdentityIds(a), collectNativeIdentityIds(b));
    expect(collectNativeIdentityIds(a), hasLength(5)); // document + 1 Part + 3 sketches
  });

  test('replaces every session-global id and every reference to it', () {
    final a = _fixture('frame_a_save_as_source.DIDSAprt');
    final oldIds = collectNativeIdentityIds(a);
    final before = jsonEncode(a);

    final minted = remintNativeIdentity(a);

    expect(jsonEncode(a), before, reason: 'input must not be mutated');
    final newIds = collectNativeIdentityIds(minted);
    expect(newIds, hasLength(oldIds.length));
    expect(newIds.intersection(oldIds), isEmpty);
    final serialised = jsonEncode(minted);
    for (final old in oldIds) {
      expect(serialised.contains(old), isFalse, reason: '$old still referenced');
    }
    final document = minted['document'] as Map<String, dynamic>;
    final part = (document['parts'] as List).single as Map<String, dynamic>;
    expect(document['root_part_id'], part['id']);
    final sketchIds = {for (final s in minted['sketches'] as List) (s as Map)['id']};
    final referenced = {
      for (final f in part['features'] as List)
        if ((f as Map)['type'] == 'sketch') f['sketch_id'],
    };
    expect(referenced, sketchIds);
  });

  test('keeps feature ids and all other content', () {
    final a = _fixture('frame_a_save_as_source.DIDSAprt');
    final minted = remintNativeIdentity(a);
    List<dynamic> features(Map<String, dynamic> p) =>
        (((p['document'] as Map)['parts'] as List).single as Map)['features'] as List;
    expect([for (final f in features(minted)) (f as Map)['id']], [for (final f in features(a)) (f as Map)['id']]);
    expect([for (final f in features(minted)) (f as Map)['end_distance']], [
      for (final f in features(a)) (f as Map)['end_distance'],
    ]);
  });

  test('onlyIds restricts the replacement', () {
    final a = _fixture('frame_a_save_as_source.DIDSAprt');
    final partId = (((a['document'] as Map)['parts'] as List).single as Map)['id'] as String;
    final minted = remintNativeIdentity(a, onlyIds: {partId});
    expect((((minted['document'] as Map)['parts'] as List).single as Map)['id'], isNot(partId));
    expect((minted['document'] as Map)['id'], (a['document'] as Map)['id']);
    expect([for (final s in minted['sketches'] as List) (s as Map)['id']], [
      for (final s in a['sketches'] as List) (s as Map)['id'],
    ]);
  });

  test('leaves map keys alone and distinct calls mint distinct ids', () {
    final payload = {
      'document': {
        'id': 'doc',
        'root_part_id': 'p1',
        'parts': [
          {
            'id': 'p1',
            'body_material_assignments': {'p1': 'steel'},
          },
        ],
      },
      'sketches': <dynamic>[],
    };
    final first = remintNativeIdentity(payload);
    final second = remintNativeIdentity(payload);
    final part = ((first['document'] as Map)['parts'] as List).single as Map;
    expect((part['body_material_assignments'] as Map).keys.single, 'p1');
    expect(collectNativeIdentityIds(first).intersection(collectNativeIdentityIds(second)), isEmpty);
  });
}
