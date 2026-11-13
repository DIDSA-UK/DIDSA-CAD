import 'dart:io';

import 'desktop_storage_service.dart';
import 'ios_storage_service.dart';
import 'routing_storage_service.dart';
import 'saf_storage_service.dart';
import 'server/remote_storage_service.dart';
import 'storage_service.dart';

/// The one project store service for the app: the sync queue and the status chip are per process, so every screen shares it.
final RemoteStorageService sharedRemoteStorageService = RemoteStorageService();

/// The platform's own local-folder service: `SafStorageService` on Android (scoped storage), `IosStorageService` on iOS
/// (security-scoped bookmarks), `DesktopStorageService` everywhere else this app runs (Windows/Linux/macOS).
StorageService createLocalStorageService() {
  if (Platform.isAndroid) return SafStorageService();
  if (Platform.isIOS) return IosStorageService();
  return DesktopStorageService();
}

/// What every screen gets: the platform's local-folder service and the project store's behind one `StorageService`
/// (`RoutingStorageService`), so a server project opens, saves and composes exactly like a folder.
StorageService createStorageService() =>
    RoutingStorageService(local: createLocalStorageService(), remote: sharedRemoteStorageService);
