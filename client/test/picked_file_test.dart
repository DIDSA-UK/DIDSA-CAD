import 'dart:io';
import 'dart:typed_data';

import 'package:didsa_cad_client/storage/picked_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_plus/share_plus.dart' show XFile;

base class _FakePickedFile extends PlatformFile {
  _FakePickedFile(this.name, this.uri, this.data);

  @override
  final String name;
  @override
  final Uri uri;
  final List<int> data;

  @override
  XFile get xFile => throw UnimplementedError();
  @override
  int? lengthSync() => data.length;
  @override
  Future<int?> length() async => data.length;
  @override
  Future<Uint8List> readAsBytes() async => Uint8List.fromList(data);
  @override
  Stream<Uint8List> readAsByteStream() async* {
    yield Uint8List.fromList(data.sublist(0, data.length ~/ 2));
    yield Uint8List.fromList(data.sublist(data.length ~/ 2));
  }
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('picked_file_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('localPathForPickedFile', () {
    test('returns the file path as is when the file has one', () async {
      final file = _FakePickedFile('a.glb', Uri.file('/some/where/a.glb'), [1, 2, 3]);
      expect(await localPathForPickedFile(file, tempDir: tmp), Uri.file('/some/where/a.glb').toFilePath());
      expect(tmp.listSync(), isEmpty);
    });

    test('copies a content:// file into the temp directory, byte for byte', () async {
      final data = List<int>.generate(1000, (i) => i % 251);
      final file = _FakePickedFile('model.stl', Uri.parse('content://provider/doc/42'), data);
      final path = await localPathForPickedFile(file, tempDir: tmp);
      expect(path.startsWith(tmp.path), isTrue);
      expect(path.endsWith('model.stl'), isTrue);
      expect(File(path).readAsBytesSync(), data);
    });

    test('a name with path separators cannot escape the temp directory', () async {
      final file = _FakePickedFile('../x/evil.zip', Uri.parse('content://provider/doc/1'), [9, 9]);
      final path = await localPathForPickedFile(file, tempDir: tmp);
      expect(File(path).parent.path, tmp.path);
    });
  });

  group('savedFileNameFromUri', () {
    test('file URI gives the decoded file name', () {
      expect(savedFileNameFromUri(Uri.file('/home/me/My Part.DIDSAsketch')), 'My Part.DIDSAsketch');
    });
    test('content URI with a document id keeps what follows the colon', () {
      expect(
        savedFileNameFromUri(Uri.parse('content://com.android.providers.downloads.documents/document/primary%3ADownload%2Fcube.DIDSAsketch')),
        'cube.DIDSAsketch',
      );
    });
    test('an opaque numeric id comes back as is (callers check the extension)', () {
      expect(savedFileNameFromUri(Uri.parse('content://x/document/1234')), '1234');
    });
    test('empty path gives null', () {
      expect(savedFileNameFromUri(Uri.parse('content://x')), isNull);
    });
  });
}
