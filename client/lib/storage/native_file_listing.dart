import '../assembly/relative_path.dart';
import 'project_root.dart';
import 'storage_service.dart';

/// Every native project file under [ProjectRoot] - current `.DIDSAprt` and legacy `.didsa` (see
/// [isNativeProjectFileName]). Lists unfiltered and filters here because [StorageService.listFiles] takes one
/// extension and its iOS implementation filters in native code.
extension NativeFileListing on StorageService {
  Future<List<String>> listNativeFiles(ProjectRoot root) async =>
      (await listFiles(root)).where(isNativeProjectFileName).toList();
}
