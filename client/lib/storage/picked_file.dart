import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

/// A local file-system path for a file the user picked with `file_picker`.
///
/// `file_picker` 13 returns `PlatformFile.path == null` unless the file has a
/// `file://` URI; on Android a pick can come back as a `content://` URI
/// instead. Callers that need a real path (the mesh viewer's isolate decode,
/// the plan-bundle zip reader) use this: the file's own path when it has one,
/// otherwise a copy written into the app's temporary directory.
///
/// The copy is streamed ([PlatformFile.readAsByteStream]), never read whole
/// into memory - the mesh viewer's files can be hundreds of MiB (see
/// `_pickAndLoad` in `mesh_viewer_screen.dart`). [tempDir] is for tests.
Future<String> localPathForPickedFile(PlatformFile file, {Directory? tempDir}) async {
  final existing = file.path;
  if (existing != null) return existing;
  final dir = tempDir ?? await getTemporaryDirectory();
  final safeName = file.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  final copy = File('${dir.path}${Platform.pathSeparator}picked_${DateTime.now().microsecondsSinceEpoch}_$safeName');
  final sink = copy.openWrite();
  try {
    await sink.addStream(file.readAsByteStream());
  } finally {
    await sink.close();
  }
  return copy.path;
}

/// The name part of a saved file's [Uri] (as returned by `FilePicker.saveFile`),
/// percent-decoded, or `null` when the URI has no usable last segment.
///
/// On Android the URI is a `content://` document URI whose last segment can be
/// a document id rather than a file name; callers that need a particular
/// extension should check it and keep their previous name when it is missing.
String? savedFileNameFromUri(Uri uri) {
  final segments = uri.pathSegments;
  if (segments.isEmpty) return null;
  final last = segments.last;
  if (last.isEmpty) return null;
  // A document id looks like "primary:Download/name.ext": keep what follows the last '/' or ':'.
  final cut = last.lastIndexOf(RegExp(r'[/:]'));
  return cut < 0 ? last : last.substring(cut + 1);
}
