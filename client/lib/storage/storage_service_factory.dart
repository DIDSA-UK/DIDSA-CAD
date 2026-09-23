import 'dart:io';

import 'desktop_storage_service.dart';
import 'ios_storage_service.dart';
import 'saf_storage_service.dart';
import 'storage_service.dart';

/// Picks the right `StorageService` for the current platform -
/// `SafStorageService` on Android (scoped storage), `IosStorageService` on
/// iOS (security-scoped bookmarks), `DesktopStorageService` everywhere
/// else this app runs (Windows/Linux/macOS).
StorageService createStorageService() {
  if (Platform.isAndroid) return SafStorageService();
  if (Platform.isIOS) return IosStorageService();
  return DesktopStorageService();
}
