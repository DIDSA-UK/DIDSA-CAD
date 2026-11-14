// An in-memory project store for the client's tests: the same HTTP surface as `project-store/` (statuses, headers, error bodies; see
// `project-store/README.md` and `app/api.py`), served through `package:http`'s MockClient so `RemoteStorageService` and `StoreClient`
// run unchanged against it. It is a model of the store, not the store: `test/live/server_store_live_test.dart` runs the same service
// against the real one.
import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _Version {
  _Version(this.version, this.bytes, this.by, this.at, {this.deleted = false, this.movedTo});

  final int version;
  final Uint8List? bytes;
  final String by;
  final DateTime at;
  final bool deleted;
  final String? movedTo;
}

class _Entry {
  final List<_Version> history = [];

  _Version get current => history.last;
  bool get live => history.isNotEmpty && !current.deleted;
}

class _Change {
  _Change(this.seq, this.path, this.op, this.version, this.device, this.at, {this.movedTo, this.movedFrom});

  final int seq;
  final String path;
  final String op;
  final int version;
  final String device;
  final DateTime at;
  final String? movedTo;
  final String? movedFrom;
}

class _Session {
  _Session(this.project, this.size, this.sha);

  final String project;
  final int size;
  final String sha;
  final BytesBuilder bytes = BytesBuilder(copy: false);
  bool complete = false;
}

class FakeProjectStore {
  FakeProjectStore({this.apiKey = 'store-key', DateTime Function()? clock}) : _clock = clock ?? DateTime.now {
    client = MockClient(_handle);
  }

  final String apiKey;
  final DateTime Function() _clock;
  late final MockClient client;

  /// While true every call fails the way an unreachable server does (a connection error, not an HTTP status).
  bool offline = false;

  /// Fail the next upload or PUT with a connection error while the store still answers (a tunnel resetting a big upload).
  bool dropNextWrite = false;

  /// A status to answer with instead of handling the next request: `{status: 413, body: ..., contentType: ...}`.
  final List<({int status, String body})> forcedAnswers = [];

  /// Chunked uploads (S4): advertised in `/health` and served as the real store does (in-order chunks, 409 `wrong_offset` with `received`, the
  /// declared SHA-256 checked at `complete`).
  bool chunked = true;

  /// A request body over this many bytes is refused the way a Cloudflare tunnel does (413, an HTML page, not the store's JSON). 0: no tunnel.
  int tunnelCapBytes = 0;

  /// Requests that are APPLIED and then answered with a connection error (the reply is lost). Matched by `METHOD /path` containing the text.
  final List<String> loseReplyFor = [];

  /// After this many more requests the store goes offline (null: never). `restart()` brings it back with its data.
  int? dieAfter;

  /// Answer the next `complete` with this instead (a store-side failure after the last chunk).
  ({int status, String body})? failNextComplete;

  /// Chunk requests that were applied.
  int chunksReceived = 0;

  void restart() {
    offline = false;
    dieAfter = null;
  }

  /// The store forgets its uploads and upload sessions (they expire after an hour).
  void expireUploads() {
    _uploads.clear();
    _sessions.clear();
  }

  /// Largest body the fake accepts (the real store's limit is 200 MB); a bigger one gets a 413.
  int maxFileBytes = 200 * 1024 * 1024;

  /// Everything the client asked, as `METHOD /path`.
  final List<String> requests = [];

  /// The `X-Device-Name` of each request.
  final List<String> devices = [];

  final Map<String, Map<String, _Entry>> _projects = {};
  final List<_Change> _changes = [];
  final Map<String, ({String project, Uint8List bytes})> _uploads = {};
  final Map<String, _Session> _sessions = {};
  int _seq = 0;
  int _uploadCounter = 0;

  int count(String prefix) => requests.where((r) => r.startsWith(prefix)).length;

  // ---------------------------------------------------------------------------- seeding and "another device" edits

  void createProject(String name) => _projects.putIfAbsent(name, () => {});

  /// Another device's write (or the owner copying a file in by hand): always succeeds, makes the next version.
  int write(String project, String path, List<int> bytes, {String device = 'Other device'}) {
    createProject(project);
    final entry = _projects[project]!.putIfAbsent(path, _Entry.new);
    final version = entry.history.isEmpty ? 1 : entry.current.version + 1;
    entry.history.add(_Version(version, Uint8List.fromList(bytes), device, _clock()));
    _changes.add(_Change(++_seq, path, 'put', version, device, _clock()));
    return version;
  }

  int writeJson(String project, String path, Map<String, dynamic> json, {String device = 'Other device'}) =>
      write(project, path, utf8.encode(jsonEncode(json)), device: device);

  void delete(String project, String path, {String device = 'Other device', String? movedTo}) {
    final entry = _projects[project]![path]!;
    final version = entry.current.version + 1;
    entry.history.add(_Version(version, null, device, _clock(), deleted: true, movedTo: movedTo));
    _changes.add(_Change(++_seq, path, 'delete', version, device, _clock(), movedTo: movedTo));
  }

  /// `old` renamed to `to` by another device.
  void move(String project, String old, String to, {String device = 'Other device'}) {
    final bytes = _projects[project]![old]!.current.bytes!;
    delete(project, old, device: device, movedTo: to);
    write(project, to, bytes, device: device);
  }

  Uint8List? bytesOf(String project, String path) {
    final entry = _projects[project]?[path];
    return entry != null && entry.live ? entry.current.bytes : null;
  }

  int? versionOf(String project, String path) {
    final entry = _projects[project]?[path];
    return entry == null || entry.history.isEmpty ? null : entry.current.version;
  }

  List<String> livePaths(String project) =>
      [for (final e in _projects[project]!.entries) if (e.value.live) e.key]..sort();

  int historyLength(String project, String path) => _projects[project]![path]?.history.length ?? 0;

  String? deviceOf(String project, String path) => _projects[project]?[path]?.current.by;

  // ---------------------------------------------------------------------------- the HTTP surface

  static String _sha(List<int> bytes) => sha256.convert(bytes).toString();

  static String? _partId(Uint8List? bytes) {
    if (bytes == null) return null;
    try {
      final doc = jsonDecode(utf8.decode(bytes));
      if (doc is Map && doc['document'] is Map) {
        final id = (doc['document'] as Map)['root_part_id'];
        if (id is String && id.isNotEmpty) return id;
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  Map<String, dynamic> _info(String path, _Entry entry) {
    final v = entry.current;
    return {
      'path': path,
      'size': v.bytes!.length,
      'sha256': _sha(v.bytes!),
      'version': v.version,
      'modified_at': v.at.toUtc().toIso8601String(),
      'modified_by': v.by,
      'part_id': _partId(v.bytes),
    };
  }

  Map<String, dynamic>? _current(Map<String, _Entry> files, String path) {
    final entry = files[path];
    if (entry == null || entry.history.isEmpty) return null;
    if (entry.live) return _info(path, entry);
    final v = entry.current;
    return {
      'path': path,
      'version': v.version,
      'deleted': true,
      'modified_at': v.at.toUtc().toIso8601String(),
      'modified_by': v.by,
      if (v.movedTo != null) 'moved_to': v.movedTo,
    };
  }

  http.Response _json(int status, Object body, {Map<String, String> headers = const {}}) => http.Response(
        jsonEncode(body),
        status,
        headers: {'content-type': 'application/json', ...headers},
      );

  http.Response _error(int status, String code, String detail, [Map<String, dynamic> extra = const {}]) =>
      _json(status, {'error': code, 'detail': detail, ...extra});

  Future<http.Response> _handle(http.Request request) async {
    if (dieAfter != null) {
      if (dieAfter == 0) {
        offline = true;
      } else {
        dieAfter = dieAfter! - 1;
      }
    }
    if (offline) throw const SocketException('Connection refused (fake store is offline)');
    if (tunnelCapBytes > 0 && request.bodyBytes.length > tunnelCapBytes) {
      return http.Response('<html>413 Request Entity Too Large</html>', 413, headers: {'content-type': 'text/html'});
    }
    final label = '${request.method} ${request.url.path}?${request.url.query}';
    final lose = loseReplyFor.indexWhere(label.contains);
    if (lose >= 0) {
      loseReplyFor.removeAt(lose);
      await _handleInner(request);
      throw const SocketException('Connection reset by peer (the reply was lost)');
    }
    return _handleInner(request);
  }

  Future<http.Response> _handleInner(http.Request request) async {
    final path = request.url.path;
    requests.add('${request.method} $path');
    devices.add(request.headers['X-Device-Name'] ?? request.headers['x-device-name'] ?? '');
    if (dropNextWrite && (request.method == 'PUT' || path.endsWith('/uploads'))) {
      dropNextWrite = false;
      throw const SocketException('Connection reset by peer (fake tunnel)');
    }
    if (forcedAnswers.isNotEmpty) {
      final forced = forcedAnswers.removeAt(0);
      return http.Response(forced.body, forced.status);
    }
    if ((request.headers['X-API-Key'] ?? request.headers['x-api-key']) != apiKey) {
      return _error(401, 'unauthorized', 'bad key');
    }
    final segments = request.url.pathSegments;
    if (path == '/health') {
      return _json(200, {'status': 'ok', 'api_features': ['files.if_match', 'commit.all_or_nothing', 'uploads', 'changes.cursor', 'parts.index', if (chunked) 'uploads.chunked'], 'version': 'fake'});
    }
    if (path == '/projects') {
      if (request.method == 'GET') {
        return _json(200, {
          'projects': [
            for (final e in _projects.entries)
              {
                'name': e.key,
                'file_count': e.value.values.where((f) => f.live).length,
                'total_size': e.value.values.where((f) => f.live).fold<int>(0, (a, f) => a + f.current.bytes!.length),
                'last_change': null,
                'last_device': null,
              },
          ],
        });
      }
      final name = (jsonDecode(request.body) as Map)['name'] as String;
      if (_projects.keys.any((k) => k.toLowerCase() == name.toLowerCase())) {
        return _error(409, 'conflict', 'a project named \'$name\' already exists');
      }
      _projects[name] = {};
      return _json(201, {'name': name, 'file_count': 0, 'total_size': 0, 'last_change': null, 'last_device': null});
    }
    if (segments.length < 3 || segments.first != 'projects') return _error(404, 'not_found', 'no such route');
    final project = segments[1];
    final files = _projects[project];
    if (files == null) return _error(404, 'not_found', 'no project $project');
    final rest = segments.sublist(2);
    final device = request.headers['X-Device-Name'] ?? request.headers['x-device-name'] ?? '';

    if (rest.first == 'tree') {
      return _json(200, {
        'project': project,
        'files': [for (final e in (files.entries.where((e) => e.value.live).toList()..sort((a, b) => a.key.compareTo(b.key)))) _info(e.key, e.value)],
        'cursor': '$_seq',
      });
    }
    if (rest.first == 'changes') {
      final since = int.tryParse(request.url.queryParameters['since'] ?? '0');
      if (since == null || since < 0 || since > _seq) {
        return _error(400, 'bad_cursor', 'the cursor is not one this store issued');
      }
      return _json(200, {
        'project': project,
        'changes': [
          for (final c in _changes.where((c) => c.seq > since && files.containsKey(c.path)))
            {
              'path': c.path,
              'op': c.op,
              'version': c.version,
              'device': c.device,
              'at': c.at.toUtc().toIso8601String(),
              if (c.movedTo != null) 'moved_to': c.movedTo,
              if (c.movedFrom != null) 'moved_from': c.movedFrom,
            },
        ],
        'cursor': '$_seq',
        'more': false,
      });
    }
    if (rest.first == 'parts' && rest.length == 2) {
      return _json(200, {
        'part_id': rest[1],
        'files': [for (final e in files.entries) if (e.value.live && _partId(e.value.current.bytes) == rest[1]) _info(e.key, e.value)],
      });
    }
    if (rest.first == 'uploads' && rest.length > 1) return _chunked(project, rest, request);
    if (rest.first == 'uploads') {
      if (request.bodyBytes.length > maxFileBytes) return _error(413, 'too_large', 'a file may be at most $maxFileBytes bytes');
      final id = 'up${++_uploadCounter}';
      _uploads[id] = (project: project, bytes: Uint8List.fromList(request.bodyBytes));
      return _json(201, {'upload_id': id, 'size': request.bodyBytes.length, 'sha256': _sha(request.bodyBytes)});
    }
    if (rest.first == 'commit') return _commit(project, files, request, device);
    if (rest.first == 'files') {
      final filePath = rest.sublist(1).join('/');
      return _file(project, files, filePath, request, device);
    }
    return _error(404, 'not_found', 'no such route');
  }

  http.Response _chunked(String project, List<String> rest, http.Request request) {
    if (!chunked) return _error(404, 'not_found', 'no such route');
    if (rest[1] == 'sessions' && request.method == 'POST') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final size = body['size'];
      final sha = body['sha256'];
      if (size is! int || size < 1 || sha is! String || sha.length != 64) return _error(400, 'bad_request', 'size and sha256 are needed');
      if (size > maxFileBytes) return _error(413, 'too_large', 'a file may be at most $maxFileBytes bytes');
      final id = 'up${++_uploadCounter}';
      _sessions[id] = _Session(project, size, sha);
      return _json(201, {'upload_id': id, 'size': size, 'received': 0, 'chunk_size': 32 * 1024 * 1024, 'complete': false});
    }
    final session = _sessions[rest[1]];
    if (session == null || session.project != project) {
      return _error(404, 'unknown_upload', 'upload ${rest[1]} is unknown, expired or belongs to another project');
    }
    Map<String, dynamic> info() => {
          'upload_id': rest[1],
          'size': session.size,
          'received': session.bytes.length,
          'complete': session.complete,
          'chunk_size': 32 * 1024 * 1024,
        };
    if (rest.length == 2 && request.method == 'GET') return _json(200, info());
    if (rest.length == 2 && request.method == 'PUT') {
      final offset = int.tryParse(request.url.queryParameters['offset'] ?? '');
      if (session.complete) return _error(409, 'upload_complete', 'this upload is already complete', info());
      if (offset != session.bytes.length) return _error(409, 'wrong_offset', 'expected offset ${session.bytes.length}, got $offset', info());
      if (session.bytes.length + request.bodyBytes.length > session.size) return _error(400, 'chunk_past_end', 'this chunk goes past the size the upload declared');
      session.bytes.add(request.bodyBytes);
      chunksReceived++;
      return _json(200, info());
    }
    if (rest.length == 3 && rest[2] == 'complete' && request.method == 'POST') {
      if (failNextComplete != null) {
        final forced = failNextComplete!;
        failNextComplete = null;
        return http.Response(forced.body, forced.status);
      }
      if (!session.complete) {
        if (session.bytes.length != session.size) return _error(409, 'incomplete', '${session.bytes.length} of ${session.size} bytes received', info());
        final all = session.bytes.toBytes();
        if (_sha(all) != session.sha) {
          _sessions.remove(rest[1]);
          return _error(400, 'checksum_mismatch', 'the bytes received do not match the declared SHA-256');
        }
        session.complete = true;
        _uploads[rest[1]] = (project: project, bytes: all);
      }
      return _json(200, {'upload_id': rest[1], 'size': session.size, 'sha256': session.sha});
    }
    return _error(404, 'not_found', 'no such route');
  }

  http.Response _commit(String project, Map<String, _Entry> files, http.Request request, String device) {
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    final changes = (body['changes'] as List).cast<Map<String, dynamic>>();
    final conflicts = <Map<String, dynamic>>[];
    for (final change in changes) {
      final path = change['path'] as String;
      final base = change['base_version'] as int?;
      final op = change['op'] as String;
      final upload = change['upload_id'];
      if (op == 'put' && (upload is! String || _uploads[upload]?.project != project)) {
        return _error(400, 'unknown_upload', 'upload $upload is unknown, expired or belongs to another project');
      }
      final entry = files[path];
      final live = entry != null && entry.live;
      if (op == 'put' && base == null) {
        if (live) conflicts.add({'path': path, 'op': op, 'base_version': base, 'reason': 'exists', 'current_version': entry.current.version, 'current': _current(files, path)});
      } else if (!live || entry.current.version != base) {
        final reason = entry != null && entry.history.isNotEmpty && !live ? 'deleted' : (entry == null ? 'missing' : 'changed');
        conflicts.add({'path': path, 'op': op, 'base_version': base, 'reason': reason, 'current_version': entry?.current.version, 'current': _current(files, path)});
      }
    }
    if (conflicts.isNotEmpty) {
      return _error(409, 'conflict', '${conflicts.length} change(s) clash with what is current; nothing was written', {'conflicts': conflicts});
    }
    final applied = <Map<String, dynamic>>[];
    for (final change in changes) {
      final path = change['path'] as String;
      final op = change['op'] as String;
      if (op == 'put') {
        final bytes = _uploads[change['upload_id']]!.bytes;
        final entry = files.putIfAbsent(path, _Entry.new);
        if (entry.live && _sha(entry.current.bytes!) == _sha(bytes)) {
          applied.add({..._info(path, entry), 'op': 'put', 'unchanged': true});
          continue;
        }
        final version = entry.history.isEmpty ? 1 : entry.current.version + 1;
        entry.history.add(_Version(version, bytes, device, _clock()));
        _changes.add(_Change(++_seq, path, 'put', version, device, _clock()));
        applied.add({..._info(path, entry), 'op': 'put', 'unchanged': false});
      } else if (op == 'move') {
        final to = change['to'] as String;
        final entry = files[path]!;
        final bytes = entry.current.bytes!;
        final oldVersion = entry.current.version + 1;
        entry.history.add(_Version(oldVersion, null, device, _clock(), deleted: true, movedTo: to));
        _changes.add(_Change(++_seq, path, 'delete', oldVersion, device, _clock(), movedTo: to));
        final target = files.putIfAbsent(to, _Entry.new);
        final version = target.history.isEmpty ? 1 : target.current.version + 1;
        target.history.add(_Version(version, bytes, device, _clock()));
        _changes.add(_Change(++_seq, to, 'put', version, device, _clock(), movedFrom: path));
        applied.add({'path': path, 'op': 'delete', 'version': oldVersion, 'deleted': true, 'moved_to': to});
        applied.add({..._info(to, target), 'op': 'move', 'moved_from': path});
      } else {
        final entry = files[path]!;
        final version = entry.current.version + 1;
        entry.history.add(_Version(version, null, device, _clock(), deleted: true));
        _changes.add(_Change(++_seq, path, 'delete', version, device, _clock()));
        applied.add({'path': path, 'op': 'delete', 'version': version, 'deleted': true});
      }
    }
    for (final change in changes) {
      _uploads.remove(change['upload_id']);
    }
    return _json(200, {'files': applied, 'cursor': '$_seq'});
  }

  http.Response _file(String project, Map<String, _Entry> files, String path, http.Request request, String device) {
    final entry = files[path];
    if (request.method == 'GET') {
      if (entry == null || !entry.live) return _error(404, 'not_found', 'no file \'$path\' in \'$project\'');
      return http.Response.bytes(
        entry.current.bytes!,
        200,
        headers: {'etag': '"${entry.current.version}"', 'x-sha256': _sha(entry.current.bytes!), 'content-type': 'application/octet-stream'},
      );
    }
    if (request.method == 'PUT') {
      final ifMatch = request.headers['If-Match'] ?? request.headers['if-match'];
      final ifNoneMatch = request.headers['If-None-Match'] ?? request.headers['if-none-match'];
      if (ifMatch == null && ifNoneMatch == null) {
        return _error(428, 'precondition_required', 'send If-Match: "<version>" to replace that version, or If-None-Match: * to create');
      }
      final live = entry != null && entry.live;
      if (ifNoneMatch != null) {
        if (live) return _error(412, 'precondition_failed', '\'$path\' already exists', {'current': _current(files, path)});
      } else {
        final version = int.parse(ifMatch!.replaceAll('"', ''));
        if (!live || entry.current.version != version) {
          return _error(412, 'precondition_failed', '\'$path\' is not at version $version', {'current': _current(files, path)});
        }
      }
      if (request.bodyBytes.length > maxFileBytes) return _error(413, 'too_large', 'a file may be at most $maxFileBytes bytes');
      final target = files.putIfAbsent(path, _Entry.new);
      if (target.live && _sha(target.current.bytes!) == _sha(request.bodyBytes)) {
        return _json(200, {..._info(path, target), 'op': 'put', 'unchanged': true}, headers: {'etag': '"${target.current.version}"'});
      }
      final created = target.history.isEmpty || !target.live;
      final version = target.history.isEmpty ? 1 : target.current.version + 1;
      target.history.add(_Version(version, Uint8List.fromList(request.bodyBytes), device, _clock()));
      _changes.add(_Change(++_seq, path, 'put', version, device, _clock()));
      return _json(created ? 201 : 200, {..._info(path, target), 'op': 'put', 'unchanged': false}, headers: {'etag': '"$version"'});
    }
    return _error(405, 'method_not_allowed', request.method);
  }
}
