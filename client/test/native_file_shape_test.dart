import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/assembly/native_file_shape.dart';

void main() {
  group('isBundleShapedNativeFile', () {
    test('a single-Part file is not Bundle-shaped', () {
      final decoded = {
        'schema_version': 1,
        'document': {
          'id': 'doc-1',
          'root_part_id': 'part-1',
          'parts': [
            {'id': 'part-1', 'name': 'Part 1'},
          ],
        },
        'sketches': <dynamic>[],
      };

      expect(isBundleShapedNativeFile(decoded), isFalse);
    });

    test('a multi-Part file (a legacy whole-session Bundle) is Bundle-shaped', () {
      final decoded = {
        'schema_version': 1,
        'document': {
          'id': 'doc-1',
          'root_part_id': 'part-1',
          'parts': [
            {'id': 'part-1', 'name': 'Part 1'},
            {'id': 'part-2', 'name': 'Bracket'},
          ],
        },
        'sketches': <dynamic>[],
      };

      expect(isBundleShapedNativeFile(decoded), isTrue);
    });

    test('a file with an empty parts list is not Bundle-shaped', () {
      final decoded = {
        'schema_version': 1,
        'document': {'id': 'doc-1', 'root_part_id': null, 'parts': <dynamic>[]},
        'sketches': <dynamic>[],
      };

      expect(isBundleShapedNativeFile(decoded), isFalse);
    });

    test('a document with no parts key at all is not Bundle-shaped', () {
      final decoded = {
        'schema_version': 1,
        'document': {'id': 'doc-1', 'root_part_id': null},
        'sketches': <dynamic>[],
      };

      expect(isBundleShapedNativeFile(decoded), isFalse);
    });

    test('a file with no document key at all is not Bundle-shaped', () {
      expect(isBundleShapedNativeFile({'schema_version': 1}), isFalse);
    });
  });
}
