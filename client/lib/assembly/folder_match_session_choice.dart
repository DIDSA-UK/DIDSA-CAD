import 'package:flutter/foundation.dart';

/// The user's answer to "N files look like they moved with the project folder", kept for the life of this run of the app
/// (Flutter-testing feedback 2026-11-11, item 1b, Decision 1: advise and let the user accept or not, with a "Don't ask again this
/// session" checkbox). In memory only, never written to preferences, so a new session asks again. App-wide on purpose: Open
/// pushes a fresh `PartScreen`, so screen state would forget it on the next open.
class FolderMatchSessionChoice extends ChangeNotifier {
  FolderMatchSessionChoice._();

  static final FolderMatchSessionChoice instance = FolderMatchSessionChoice._();

  bool? _answer;

  /// `true`: use the matches without asking; `false`: leave them as suggestions without asking; `null`: ask.
  bool? get answer => _answer;

  void remember(bool useThem) {
    _answer = useThem;
    notifyListeners();
  }

  /// "Ask again".
  void clear() {
    if (_answer == null) return;
    _answer = null;
    notifyListeners();
  }
}
