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

  group('extension constants', () {
    test('.didsa is current; .DIDSAprt and .didsacad are legacy', () {
      expect(kNativeFileExtension, '.didsa');
      expect(kLegacyNativeFileExtensions, ['.DIDSAprt', '.didsacad']);
    });
  });

  group('withDefaultExtension', () {
    test('appends .didsa when no native extension is given', () {
      expect(withDefaultExtension('bracket'), 'bracket.didsa');
    });

    test('a dotted name still gets the native extension', () {
      expect(withDefaultExtension('Frame 1.5m'), 'Frame 1.5m.didsa');
      expect(withDefaultExtension('Bracket v2.1'), 'Bracket v2.1.didsa');
      expect(withDefaultExtension('bracket.txt'), 'bracket.txt.didsa');
    });

    test('leaves a typed native extension (current or legacy, any case) untouched', () {
      expect(withDefaultExtension('bracket.didsa'), 'bracket.didsa');
      expect(withDefaultExtension('bracket.DIDSAprt'), 'bracket.DIDSAprt');
      expect(withDefaultExtension('bracket.didsacad'), 'bracket.didsacad');
      expect(withDefaultExtension('Bracket.DIDSA'), 'Bracket.DIDSA');
    });

    test('only inspects the final path segment', () {
      expect(withDefaultExtension('sub.dir/bracket'), 'sub.dir/bracket.didsa');
    });
  });

  group('hasNativeExtension / stripNativeExtension', () {
    test('recognise all three extensions in any case', () {
      for (final name in ['a.didsa', 'a.DIDSAprt', 'a.didsacad', 'a.DIDSA', 'a.DidsaPrt', 'a.DIDSACAD']) {
        expect(hasNativeExtension(name), isTrue, reason: name);
        expect(stripNativeExtension(name), 'a', reason: name);
      }
    });

    test('leave other names alone', () {
      expect(hasNativeExtension('a.txt'), isFalse);
      expect(hasNativeExtension('a.didsa.bak'), isFalse);
      expect(stripNativeExtension('Frame 1.5m'), 'Frame 1.5m');
      expect(stripNativeExtension('sub/Frame_A.DIDSAprt'), 'sub/Frame_A');
    });
  });

  group('nativeBaseNameKey / findNativeNameCollision / nativeExtensionOf', () {
    test('X.didsa and X.DIDSAprt in one folder share a key', () {
      expect(nativeBaseNameKey('sub/Bracket.didsa'), nativeBaseNameKey('sub/bracket.DIDSAprt'));
      expect(nativeBaseNameKey('a/Bracket.didsa'), isNot(nativeBaseNameKey('b/Bracket.didsa')));
    });

    test('a collision names the existing file, whatever its extension', () {
      expect(findNativeNameCollision('Bracket.didsa', ['Other.didsa', 'Bracket.DIDSAprt']), 'Bracket.DIDSAprt');
      expect(findNativeNameCollision('Bracket.didsa', ['Other.didsa']), isNull);
    });

    test('nativeExtensionOf keeps an existing file\'s own extension', () {
      expect(nativeExtensionOf('sub/Bracket.DIDSAprt'), '.DIDSAprt');
      expect(nativeExtensionOf('Bracket.didsacad'), '.didsacad');
      expect(nativeExtensionOf('Bracket.didsa'), '.didsa');
      expect(nativeExtensionOf('Bracket'), '.didsa');
    });
  });

  group('isNativeProjectFileName', () {
    test('accepts the current and both legacy extensions, any case', () {
      expect(isNativeProjectFileName('bracket.DIDSAprt'), isTrue);
      expect(isNativeProjectFileName('parts/bracket.didsaprt'), isTrue);
      expect(isNativeProjectFileName('assembly.didsa'), isTrue);
      expect(isNativeProjectFileName('Frame_A.DIDSA'), isTrue);
      expect(isNativeProjectFileName('old.didsacad'), isTrue);
    });

    test('accepts the duplicate suffix a download or copy appends', () {
      expect(isNativeProjectFileName('x.didsa (1)'), isTrue);
      expect(isNativeProjectFileName('x.DIDSAprt_1'), isTrue);
      expect(isNativeProjectFileName('x.didsacad (2)'), isTrue);
      expect(isNativeProjectFileName('Frame_A.DIDSA_1'), isTrue);
      expect(isNativeProjectFileName('Frame_A.DIDSAprt (2)'), isTrue);
    });

    test('rejects other files', () {
      expect(isNativeProjectFileName('x.txt'), isFalse);
      expect(isNativeProjectFileName('x.didsa.bak'), isFalse);
      expect(isNativeProjectFileName('notes.txt'), isFalse);
      expect(isNativeProjectFileName('didsa'), isFalse);
      expect(isNativeProjectFileName('drawing.DIDSAsketch'), isFalse);
    });
  });
}
