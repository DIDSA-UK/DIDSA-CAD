/// Conflicts on a server project (`docs/shared-storage-scope.md` section 6): what the user is asked, the three choices, and the
/// exception a save throws when the store says its copy is out of date.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../../assembly/remint_identity.dart';
import '../storage_service.dart';
import 'sync_state.dart';

/// The three answers. Per file; nothing is merged.
enum ConflictChoice {
  /// Write mine as the next version over theirs (theirs stays in the store's history).
  keepMine,

  /// Drop my change, load theirs; my bytes are kept as a local copy until the next successful sync.
  takeTheirs,

  /// Write mine next to theirs as `<name> (<device>, <date>).didsa`, with a NEW Part id (the Save As remint).
  saveCopy,
}

/// One file whose save the store refused: [clash] says who changed it and when, [path] is where.
class SyncConflict {
  const SyncConflict({required this.path, required this.clash, required this.queuedAt});

  final String path;
  final SyncClash clash;
  final DateTime queuedAt;

  /// "Changed by Desktop on 2026-11-13 14:05", "Deleted by Quest 3", "Renamed to Shaft-v2.didsa by Desktop", "A file or folder is
  /// in the way": the sentence the dialog shows.
  String describe() {
    final by = clash.modifiedBy.isEmpty ? 'another device' : clash.modifiedBy;
    final when = clash.modifiedAt == null ? '' : ' on ${formatConflictDate(clash.modifiedAt!.toLocal(), withTime: true)}';
    if (clash.reason == 'path_conflict') return 'A file or folder is already in the way of $path';
    if (clash.deleted) {
      final moved = clash.movedTo;
      return moved == null ? 'Deleted by $by$when' : 'Renamed to $moved by $by$when';
    }
    if (clash.reason == 'exists') return 'A file with this name was added by $by$when';
    return 'Changed by $by$when';
  }
}

/// A save (or a commit) the store refused because the copy it was based on is out of date. Nothing was written to the store; every
/// refused save is queued with its bytes, flagged as a clash, until the user chooses ([RemoteStorageService.resolveConflicts]) and
/// the queue is sent again ([RemoteStorageService.sync]).
class SyncConflictException extends StorageException {
  SyncConflictException(this.conflicts)
      : super(
          conflicts.length == 1
              ? '${conflicts.single.path} changed on the server: ${conflicts.single.describe()}'
              : '${conflicts.length} files changed on the server since they were opened',
        );

  final List<SyncConflict> conflicts;
}

/// The store could not be reached and a save was kept in the queue: not a failure of the save, but the caller may want to say so.
/// (Thrown only by operations that cannot be queued, e.g. a rename.)
class StoreOfflineException extends StorageException {
  StoreOfflineException(super.message, {super.cause});
}

String formatConflictDate(DateTime time, {bool withTime = false}) {
  String two(int n) => n.toString().padLeft(2, '0');
  final date = '${time.year}-${two(time.month)}-${two(time.day)}';
  return withTime ? '$date ${two(time.hour)}:${two(time.minute)}' : date;
}

final _unsafeInName = RegExp(r'[\\/:*?"<>|\x00-\x1f]');

/// `parts/Shaft.didsa` -> `parts/Shaft (Desktop, 2026-11-13).didsa`. [taken] names paths already used (a number is added until it is
/// free). The copy is always `.didsa`; [device] is the device that makes the copy (this one).
String conflictCopyPath(String path, String device, DateTime date, bool Function(String candidate) taken) {
  final slash = path.lastIndexOf('/');
  final folder = slash < 0 ? '' : path.substring(0, slash + 1);
  var name = slash < 0 ? path : path.substring(slash + 1);
  for (final extension in const ['.didsa', '.DIDSAprt', '.didsacad', '.didsa.json']) {
    if (name.toLowerCase().endsWith(extension.toLowerCase())) {
      name = name.substring(0, name.length - extension.length);
      break;
    }
  }
  var who = device.replaceAll(_unsafeInName, '').trim();
  if (who.isEmpty) who = 'device';
  final base = '$folder$name ($who, ${formatConflictDate(date)})';
  var candidate = '$base.didsa';
  for (var n = 2; taken(candidate); n++) {
    candidate = '$base $n.didsa';
  }
  return candidate;
}

/// The bytes of a native file with a fresh document, Part and sketch identity (`remintNativeIdentity`, what Save As does), so the
/// copy never shares a Part id with the file it was copied from. Bytes that are not a native file are returned as they are.
Uint8List remintNativeBytes(Uint8List bytes) {
  try {
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic> || decoded['document'] is! Map) return bytes;
    return Uint8List.fromList(utf8.encode(jsonEncode(remintNativeIdentity(decoded))));
  } on FormatException {
    return bytes;
  }
}
