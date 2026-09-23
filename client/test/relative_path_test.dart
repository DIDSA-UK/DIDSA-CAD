import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/assembly/relative_path.dart';

void main() {
  group('validateProjectRelativePath', () {
    test('rejects empty/whitespace-only', () {
      expect(validateProjectRelativePath(''), isNotNull);
      expect(validateProjectRelativePath('   '), isNotNull);
    });

    test('rejects a leading slash or backslash', () {
      expect(validateProjectRelativePath('/bracket.DIDSAprt'), isNotNull);
      expect(validateProjectRelativePath(r'\bracket.DIDSAprt'), isNotNull);
    });

    test('rejects a Windows drive-letter prefix', () {
      expect(validateProjectRelativePath(r'C:\bracket.DIDSAprt'), isNotNull);
    });

    test('rejects any ".." path segment', () {
      expect(validateProjectRelativePath('../bracket.DIDSAprt'), isNotNull);
      expect(validateProjectRelativePath('sub/../bracket.DIDSAprt'), isNotNull);
    });

    test('rejects an empty path segment', () {
      expect(validateProjectRelativePath('sub//bracket.DIDSAprt'), isNotNull);
    });

    test('accepts an ordinary relative path', () {
      expect(validateProjectRelativePath('bracket.DIDSAprt'), isNull);
      expect(validateProjectRelativePath('sub/bracket.DIDSAprt'), isNull);
    });
  });

  group('withDefaultExtension', () {
    test('appends the native extension when none is given', () {
      expect(withDefaultExtension('bracket'), 'bracket$kNativeFileExtension');
    });

    test('leaves an existing extension untouched, even an unusual one', () {
      expect(withDefaultExtension('bracket.didsa'), 'bracket.didsa');
      expect(withDefaultExtension('bracket.DIDSAprt'), 'bracket.DIDSAprt');
    });

    test('only inspects the final path segment', () {
      expect(withDefaultExtension('sub.dir/bracket'), 'sub.dir/bracket$kNativeFileExtension');
    });
  });
}
