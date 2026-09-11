import 'package:shared_preferences/shared_preferences.dart';

/// Persists which project root (`ProjectRoot.persistedKey` +
/// `displayName`) was last used, so `StorageService.lastUsedProjectRoot()`
/// can reopen it on the next app launch without re-prompting the user's
/// folder picker. Shared by both `DesktopStorageService` and
/// `SafStorageService` rather than each reimplementing the same
/// `shared_preferences` read/write - same "load-then-read-getters" pattern
/// `view_preferences.dart` already establishes for this app's other
/// `shared_preferences`-backed state.
///
/// Deliberately dumb: this store only remembers *which* root was used
/// last, as an opaque key + a display label. It is each `StorageService`
/// implementation's own job to turn `persistedKey` back into a real,
/// validated `ProjectRoot` - re-checking a SAF grant is still held, or a
/// desktop directory still exists - since only the implementation knows
/// what its own kind of key means and how to confirm it's still usable.
class RecentProjectStore {
  static const _persistedKeyPrefKey = 'didsa.storage.last_project_root.key';
  static const _displayNamePrefKey = 'didsa.storage.last_project_root.display_name';

  Future<void> save({required String persistedKey, required String displayName}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_persistedKeyPrefKey, persistedKey);
    await prefs.setString(_displayNamePrefKey, displayName);
  }

  /// The last-saved `(persistedKey, displayName)` pair, or `null` if
  /// nothing has been saved yet.
  Future<({String persistedKey, String displayName})?> last() async {
    final prefs = await SharedPreferences.getInstance();
    final persistedKey = prefs.getString(_persistedKeyPrefKey);
    final displayName = prefs.getString(_displayNamePrefKey);
    if (persistedKey == null || displayName == null) return null;
    return (persistedKey: persistedKey, displayName: displayName);
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_persistedKeyPrefKey);
    await prefs.remove(_displayNamePrefKey);
  }
}
