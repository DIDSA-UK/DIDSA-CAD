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

  /// Documents remembered at once; the one used (read or stored) longest ago goes first.
  static const int maxDocuments = 40;

  /// The keys stored for [documentKey], or null when there are none (a document never stored, or one whose entry cannot be read).
  static Future<List<String>?> read(String documentKey) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final text = prefs.getString('$_entryPrefix$documentKey');
      if (text == null) return null;
      await _touch(prefs, documentKey);
      final decoded = jsonDecode(text);
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
      await prefs.setString('$_entryPrefix$documentKey', jsonEncode(keys));
      await _touch(prefs, documentKey);
    } catch (_) {
      // Remembering is a convenience: a store that does not work leaves the tree as it is.
    }
  }

  /// Makes [documentKey] the most recently used, and drops the entries past [maxDocuments].
  static Future<void> _touch(SharedPreferences prefs, String documentKey) async {
    final index = prefs.getStringList(_indexKey) ?? <String>[];
    if (index.isNotEmpty && index.last == documentKey) return;
    index
      ..remove(documentKey)
      ..add(documentKey);
    while (index.length > maxDocuments) {
      await prefs.remove('$_entryPrefix${index.removeAt(0)}');
    }
    await prefs.setStringList(_indexKey, index);
  }
}
