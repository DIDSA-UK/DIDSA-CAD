import 'dart:io';

import 'desktop_storage_service.dart';
import 'saf_storage_service.dart';
import 'storage_service.dart';

/// Picks the right `StorageService` for the current platform - `SafStorageService`
/// on Android (scoped storage), `DesktopStorageService` everywhere else this
/// app runs (Windows/Linux/macOS). iOS is a known gap
/// (`docs/assembly-scope.md`) and currently falls back to the desktop
/// implementation, which will not work there (no arbitrary filesystem
/// access) - calling code should not assume this works on iOS yet.
StorageService createStorageService() {
  if (Platform.isAndroid) return SafStorageService();
  return DesktopStorageService();
}
