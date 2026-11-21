import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Remembered open rows of the Assembly tree (`docs/assembly-tree/spec.md` section 12): the open keys of one document's tree, per document, in
/// `shared_preferences`, beside [ViewPreferences] (which holds the grouping switch the same way).
///
/// The document key is the caller's choice (a file path, a project and file name); the stored keys are the spec's row keys. One entry per
/// document, and only the [maxDocuments] most recently used documents (read or written) are kept, so the preferences do not grow with every
/// file ever opened.
/// Every method is safe to call without a working store: a read that fails is "nothing stored", a write that fails is dropped.
class AssemblyTreeOpenStore {
  AssemblyTreeOpenStore._();

  static const String _entryPrefix = 'assembly_tree_open:';
  static const String _indexKey = 'assembly_tree_open_documents';

  /// Documents remembered at once (a test lowers it); the one used (read or stored) longest ago goes first.
  static int maxDocuments = 40;

  /// The keys stored for [documentKey], or null when there are none (a document never stored, or one whose entry cannot be read).
  static Future<List<String>?> read(String documentKey) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final text = prefs.getString('$_entryPrefix$documentKey');
      if (text == null) return null;
      final decoded = jsonDecode(text);
      // Using a document counts, but the bookkeeping failing must not take a good read away.
      await _touch(prefs, documentKey);
      return decoded is List
          ? [
              for (final k in decoded)
                if (k is String) k
            ]
          : null;
    } catch (_) {
      return null;
    }
  }

  /// Stores [keys] for [documentKey] (an empty list too: "everything collapsed" is a state worth remembering) and makes it the most recent.
  static Future<void> write(String documentKey, List<String> keys) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // The entry and the index are changed with no `await` between (the cache takes both synchronously): another document's update cannot
      // evict this entry in the gap, after it is written and before it counts as the newest.
      final entry = prefs.setString('$_entryPrefix$documentKey', jsonEncode(keys));
      final index = _touch(prefs, documentKey);
      await Future.wait([entry, index]);
    } catch (_) {
      // Remembering is a convenience: a store that does not work leaves the tree as it is.
    }
  }

  /// Copies what is stored for [from] to [to] (the document got another key while its own tree was not the one in the model). False when nothing
  /// is stored for [from].
  static Future<bool> copy(String from, String to) async {
    final keys = await read(from);
    if (keys == null) return false;
    await write(to, keys);
    return true;
  }

  /// Makes [documentKey] the most recently used, and drops the entries past [maxDocuments]. Never throws.
  ///
  /// The index is read, changed and written back with no `await` in between, and the preferences' cache takes `getStringList` / `setStringList` /
  /// `remove` synchronously, so two updates at once (a read and a write, two writes) cannot interleave and lose an entry. (A chain of futures
  /// would say the same, but a static one cannot be shared between the zones of different tests.)
  static Future<void> _touch(SharedPreferences prefs, String documentKey) {
    try {
      final index = prefs.getStringList(_indexKey) ?? <String>[];
      if (index.isNotEmpty && index.last == documentKey) return Future<void>.value();
      index
        ..remove(documentKey)
        ..add(documentKey);
      final pending = <Future<bool>>[];
      while (index.length > maxDocuments) {
        pending.add(prefs.remove('$_entryPrefix${index.removeAt(0)}'));
      }
      pending.add(prefs.setStringList(_indexKey, index));
      return Future.wait(pending).then<void>((_) {}).catchError((Object _) {});
    } catch (_) {
      return Future<void>.value();
    }
  }
}
