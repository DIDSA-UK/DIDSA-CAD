import 'package:flutter/services.dart';

/// One folder-picker result: a persisted security-scoped bookmark plus the
/// picked folder's own display name, handed back by
/// [IosBookmarkChannel.pickFolder].
class IosPickedFolder {
  const IosPickedFolder({required this.bookmarkBase64, required this.displayName});

  final String bookmarkBase64;
  final String displayName;
}

/// One bookmark-resolution result: the folder's current filesystem path
/// for this session, plus whether the bookmark was stale (the OS still
/// resolved it, but the underlying folder moved/was renamed since the
/// bookmark was created - `URL(resolvingBookmarkData:...)`'s own
/// `bookmarkDataIsStale` out-parameter). A stale resolve still returns a
/// usable path for *this* session; callers that want to keep working
/// reliably across future launches should re-mint the bookmark, though
/// `IosStorageService` itself doesn't do that automatically - see its own
/// doc comment.
class IosResolvedBookmark {
  const IosResolvedBookmark({required this.path, required this.isStale});

  final String path;
  final bool isStale;
}

/// Thin, injectable wrapper over the
/// `uk.snail_shell.didsa_cad_client/ios_storage` `MethodChannel` (see
/// `client/ios/Runner/IosStoragePlugin.swift`) - matches this app's
/// existing channel-naming convention
/// (`TermuxController`'s `uk.snail_shell.didsa_cad_client/termux`).
///
/// Every method here is a direct one-to-one call across the platform
/// channel, with no policy of its own (retry, caching, scope bracketing
/// beyond what a single call needs) - that belongs to `IosStorageService`,
/// which is the thing actually implementing `StorageService`. Kept as a
/// separate injectable class, not inlined into `IosStorageService`
/// directly, so tests can substitute an in-memory fake the same way
/// `SafStorageService` is tested against a fake `SafUtil`/`SafStream`
/// pair (see `client/test/saf_storage_service_test.dart`) - a real
/// `MethodChannel` has nothing to call into outside a real iOS run, so
/// this class's methods are deliberately non-`final` (`@override`-able by
/// a test subclass) rather than calling `_channel.invokeMethod` being
/// hardcoded into every call site.
class IosBookmarkChannel {
  static const MethodChannel _channel = MethodChannel('uk.snail_shell.didsa_cad_client/ios_storage');

  /// Shows `UIDocumentPickerViewController(forOpeningContentTypes:
  /// [.folder])` and, once the user picks a folder, mints a persisted
  /// bookmark for it. Returns `null` if the user cancelled the picker.
  Future<IosPickedFolder?> pickFolder() async {
    final result = await _channel.invokeMapMethod<String, dynamic>('pickFolder');
    if (result == null) return null;
    return IosPickedFolder(
      bookmarkBase64: result['bookmarkBase64'] as String,
      displayName: result['displayName'] as String,
    );
  }

  /// Resolves a previously-persisted bookmark back to a filesystem path
  /// for this session, brackets nothing itself (the caller decides the
  /// scope of `start`/`stopAccessingSecurityScopedResource` around
  /// whatever it does with the returned path). Returns `null` if the
  /// bookmark can no longer be resolved at all (the folder was deleted, or
  /// access was revoked) - as opposed to merely stale, which still
  /// resolves (see [IosResolvedBookmark]).
  Future<IosResolvedBookmark?> resolveBookmark(String bookmarkBase64) async {
    final result = await _channel.invokeMapMethod<String, dynamic>('resolveBookmark', {
      'bookmarkBase64': bookmarkBase64,
    });
    if (result == null) return null;
    return IosResolvedBookmark(path: result['path'] as String, isStale: result['isStale'] as bool? ?? false);
  }

  /// Releases a security-scoped access grant previously obtained by
  /// resolving a bookmark to `path` - the ref-counted
  /// `stopAccessingSecurityScopedResource()` half of
  /// `IosStoragePlugin.swift`'s bracketing.
  Future<void> stopAccessing(String path) async {
    await _channel.invokeMethod<void>('stopAccessing', {'path': path});
  }

  Future<Uint8List> readFile(String path) async {
    final result = await _channel.invokeMethod<Uint8List>('readFile', {'path': path});
    if (result == null) {
      throw PlatformException(code: 'read_failed', message: 'readFile returned no data for $path');
    }
    return result;
  }

  Future<void> writeFile(String path, Uint8List bytes) async {
    await _channel.invokeMethod<void>('writeFile', {'path': path, 'bytes': bytes});
  }

  /// Save/project overhaul Phase 2 (`docs/save-project-overhaul-scope.md`
  /// §3.2): renames the file at `path` to `newFileName`, keeping it in the
  /// same directory - see `IosStoragePlugin.swift`'s own `renameFile` for
  /// the native `moveItem` call this wraps. Returns the renamed file's new
  /// full path.
  Future<String> renameFile(String path, String newFileName) async {
    final result = await _channel.invokeMethod<String>('renameFile', {'path': path, 'newFileName': newFileName});
    if (result == null) {
      throw PlatformException(code: 'rename_failed', message: 'renameFile returned no path for $path');
    }
    return result;
  }

  /// The file's last-modified time in epoch milliseconds, or `null` if it
  /// can't be determined (missing file, unreadable attributes).
  Future<int?> lastModifiedMs(String path) async {
    return _channel.invokeMethod<int>('lastModifiedMs', {'path': path});
  }

  Future<bool> exists(String path) async {
    final result = await _channel.invokeMethod<bool>('exists', {'path': path});
    return result ?? false;
  }

  /// Every file (never directories) under `rootPath`, walked recursively,
  /// as POSIX-relative paths from `rootPath`, optionally narrowed to names
  /// ending in `extensionFilter`.
  Future<List<String>> listFilesRecursive(String rootPath, {String? extensionFilter}) async {
    final result = await _channel.invokeListMethod<String>('listFilesRecursive', {
      'rootPath': rootPath,
      'extensionFilter': extensionFilter,
    });
    return result ?? const [];
  }
}
