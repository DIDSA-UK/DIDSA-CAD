/// The project store's HTTP API (`project-store/README.md`, `docs/shared-storage-scope.md` section 5), one method per endpoint, with
/// every status the store gives turned into a typed error so no caller has to read a status code:
///
/// * 401 [StoreAuthError], 412 [StorePreconditionFailed] (a single write whose version is out of date; `current` says what is),
///   409 on a commit [StoreCommitConflict] (every clash, nothing written), 413 [StoreTooLarge], 400 / 422 [StoreBadRequest]
///   (the store's own message), 428 [StorePreconditionRequired] (a client bug: this client always sends a precondition), 404
///   [StoreNotFound], any other status [StoreError];
/// * a connection that fails or times out is [StoreUnreachable]: the caller queues the save, never loses it.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException, HandshakeException;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Where the store is and who is calling it. Read from the server settings each time (`ApiConfig`), never kept in a root.
class StoreSettings {
  const StoreSettings({required this.url, required this.apiKey, required this.deviceName});

  final String url;
  final String apiKey;

  /// Sent as `X-Device-Name`. Shown to other devices as "who changed it"; the store trusts it for nothing else.
  final String deviceName;

  bool get isConfigured => url.isNotEmpty && apiKey.isNotEmpty;
}

class StoreError implements Exception {
  StoreError(this.status, this.code, this.detail, {this.body = const {}});

  final int status;

  /// The store's `error` field ("precondition_failed", "too_large", ...), or '' when the answer was not the store's JSON.
  final String code;
  final String detail;
  final Map<String, dynamic> body;

  @override
  String toString() => 'StoreError($status${code.isEmpty ? '' : ' $code'}): $detail';
}

class StoreAuthError extends StoreError {
  StoreAuthError(String detail) : super(401, 'unauthorized', detail);
}

class StoreNotFound extends StoreError {
  StoreNotFound(String detail, {String code = 'not_found'}) : super(404, code, detail);
}

class StoreBadRequest extends StoreError {
  StoreBadRequest(super.status, super.code, super.detail, {super.body});
}

class StoreTooLarge extends StoreError {
  StoreTooLarge(String detail, {super.body}) : super(413, 'too_large', detail);

  /// The store's own JSON answered (its size limit); false for a 413 from something in front of it (a tunnel's HTML page).
  bool get fromStore => body['error'] != null;
}

class StorePreconditionRequired extends StoreError {
  StorePreconditionRequired(String detail) : super(428, 'precondition_required', detail);
}

/// 412: a single write's `If-Match` / `If-None-Match` did not hold. [current] is the store's description of what is current: the
/// live file (`version`, `sha256`, `modified_by`, `modified_at`), or `{deleted: true, version, moved_to?}`, or null (no such file).
class StorePreconditionFailed extends StoreError {
  StorePreconditionFailed(String detail, this.current, Map<String, dynamic> body) : super(412, 'precondition_failed', detail, body: body);

  final Map<String, dynamic>? current;
}

/// 409 on a commit: [conflicts] has every clash (`path`, `op`, `base_version`, `reason`, `current_version`, `current`).
class StoreCommitConflict extends StoreError {
  StoreCommitConflict(String detail, this.conflicts, Map<String, dynamic> body) : super(409, 'conflict', detail, body: body);

  final List<Map<String, dynamic>> conflicts;
}

/// The store could not be reached (no network, refused, timed out, TLS). Not a store answer.
class StoreUnreachable implements Exception {
  StoreUnreachable(this.cause);

  final Object cause;

  @override
  String toString() => 'StoreUnreachable: $cause';
}

class StoreFile {
  const StoreFile({
    required this.path,
    required this.version,
    required this.sha256,
    required this.size,
    this.modifiedAt,
    this.modifiedBy = '',
    this.partId,
  });

  factory StoreFile.fromJson(Map<String, dynamic> json) => StoreFile(
        path: json['path'] as String,
        version: json['version'] as int,
        sha256: (json['sha256'] as String?) ?? '',
        size: (json['size'] as int?) ?? 0,
        modifiedAt: DateTime.tryParse((json['modified_at'] as String?) ?? ''),
        modifiedBy: (json['modified_by'] as String?) ?? '',
        partId: json['part_id'] as String?,
      );

  final String path;
  final int version;
  final String sha256;
  final int size;
  final DateTime? modifiedAt;
  final String modifiedBy;
  final String? partId;

  Map<String, dynamic> toJson() => {
        'path': path,
        'version': version,
        'sha256': sha256,
        'size': size,
        'modified_at': modifiedAt?.toUtc().toIso8601String(),
        'modified_by': modifiedBy,
        'part_id': partId,
      };
}

class StoreProject {
  const StoreProject({required this.name, required this.fileCount, required this.totalSize, this.lastChange, this.lastDevice});

  factory StoreProject.fromJson(Map<String, dynamic> json) => StoreProject(
        name: json['name'] as String,
        fileCount: (json['file_count'] as int?) ?? 0,
        totalSize: (json['total_size'] as int?) ?? 0,
        lastChange: DateTime.tryParse((json['last_change'] as String?) ?? ''),
        lastDevice: json['last_device'] as String?,
      );

  final String name;
  final int fileCount;
  final int totalSize;
  final DateTime? lastChange;
  final String? lastDevice;
}

class StoreTree {
  const StoreTree({required this.files, required this.cursor});

  final List<StoreFile> files;
  final String cursor;
}

class StoreFetched {
  const StoreFetched({required this.bytes, required this.version, required this.sha256});

  final Uint8List bytes;
  final int version;
  final String sha256;
}

class StoreChange {
  const StoreChange({required this.path, required this.op, required this.version, required this.device, this.at, this.movedTo, this.movedFrom});

  final String path;

  /// `put`, `delete` or `move` (a move is a `delete` with [movedTo] and a `put` with [movedFrom] in the feed).
  final String op;
  final int version;
  final String device;
  final DateTime? at;
  final String? movedTo;
  final String? movedFrom;
}

class StoreChanges {
  const StoreChanges({required this.changes, required this.cursor, required this.more});

  final List<StoreChange> changes;
  final String cursor;
  final bool more;
}

/// One change of a commit: a `put` (with the id of an upload) or a `delete` / `move`; [baseVersion] null means "create".
class StoreCommitChange {
  const StoreCommitChange.put({required this.path, required this.uploadId, this.baseVersion})
      : op = 'put',
        to = null;
  const StoreCommitChange.delete({required this.path, required int this.baseVersion})
      : op = 'delete',
        uploadId = null,
        to = null;
  const StoreCommitChange.move({required this.path, required String this.to, required int this.baseVersion})
      : op = 'move',
        uploadId = null;

  final String op;
  final String path;
  final String? to;
  final int? baseVersion;
  final String? uploadId;

  Map<String, dynamic> toJson() => {
        'op': op,
        'path': path,
        if (to != null) 'to': to,
        'base_version': baseVersion,
        if (uploadId != null) 'upload_id': uploadId,
      };
}

class StoreCommitResult {
  const StoreCommitResult({required this.files, required this.cursor});

  /// The new version of each written file (`path`, `version`, `sha256`, `size`, `op`, ...), as the store returned them.
  final List<Map<String, dynamic>> files;
  final String cursor;
}

class StoreClient {
  StoreClient(this.settings, {http.Client? httpClient, this.timeout = const Duration(seconds: 30), this.uploadTimeout = const Duration(minutes: 10)})
      : _http = httpClient ?? http.Client(),
        _ownsClient = httpClient == null;

  final StoreSettings settings;
  final Duration timeout;
  final Duration uploadTimeout;
  final http.Client _http;
  final bool _ownsClient;

  void close() {
    if (_ownsClient) _http.close();
  }

  String get _base => settings.url.endsWith('/') ? settings.url.substring(0, settings.url.length - 1) : settings.url;

  Map<String, String> _headers([Map<String, String>? extra]) => {
        'X-API-Key': settings.apiKey,
        if (settings.deviceName.isNotEmpty) 'X-Device-Name': asciiHeaderValue(settings.deviceName),
        ...?extra,
      };

  Uri _uri(String path, [Map<String, String>? query]) => Uri.parse('$_base$path').replace(queryParameters: query);

  static String _enc(String segment) => Uri.encodeComponent(segment);

  /// `/projects/<project>/files/<a>/<b>`: each segment percent-encoded, the slashes kept.
  static String _filePath(String project, String path) =>
      '/projects/${_enc(project)}/files/${path.split('/').map(_enc).join('/')}';

  /// A header value the HTTP stack accepts: printable ASCII only (a device name may have any characters).
  static String asciiHeaderValue(String value) {
    final cleaned = value.runes.map((r) => r >= 0x20 && r < 0x7f ? String.fromCharCode(r) : '?').join().trim();
    return cleaned.isEmpty ? 'device' : cleaned;
  }

  Future<http.Response> _send(Future<http.Response> Function() call, {Duration? limit}) async {
    try {
      return await call().timeout(limit ?? timeout);
    } on TimeoutException catch (error) {
      throw StoreUnreachable(error);
    } on SocketException catch (error) {
      throw StoreUnreachable(error);
    } on HandshakeException catch (error) {
      throw StoreUnreachable(error);
    } on http.ClientException catch (error) {
      throw StoreUnreachable(error);
    }
  }

  Map<String, dynamic> _json(http.Response response) {
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic>) return decoded;
    } on FormatException {
      // Not JSON: a proxy's own error page, say.
    }
    return const {};
  }

  /// Throws the typed error for a non-2xx answer. [commit] is true for the commit call (its 409 lists clashes).
  Never _fail(http.Response response, {bool commit = false}) {
    final body = _json(response);
    final code = (body['error'] as String?) ?? '';
    var detail = (body['detail'] as String?) ?? '';
    final status = response.statusCode;
    if (detail.isEmpty) {
      detail = status == 413
          ? 'The server refused the upload as too large'
          : (response.reasonPhrase?.isNotEmpty ?? false) ? response.reasonPhrase! : 'HTTP $status';
    }
    switch (status) {
      case 401:
        throw StoreAuthError(detail.isEmpty ? 'The store refused the key' : detail);
      case 404:
        throw StoreNotFound(detail, code: code.isEmpty ? 'not_found' : code);
      case 412:
        final current = body['current'];
        throw StorePreconditionFailed(detail, current is Map<String, dynamic> ? current : null, body);
      case 413:
        throw StoreTooLarge(detail, body: body);
      case 428:
        throw StorePreconditionRequired(detail);
      case 400:
      case 422:
        throw StoreBadRequest(status, code, detail, body: body);
      case 409:
        final conflicts = body['conflicts'];
        if (commit && conflicts is List) {
          throw StoreCommitConflict(detail, [for (final c in conflicts) if (c is Map<String, dynamic>) c], body);
        }
        throw StoreError(409, code, detail, body: body);
    }
    throw StoreError(status, code, detail, body: body);
  }

  Future<List<String>> health() async {
    final response = await _send(() => _http.get(_uri('/health'), headers: _headers()));
    if (response.statusCode != 200) _fail(response);
    final features = _json(response)['api_features'];
    return [if (features is List) for (final f in features) f.toString()];
  }

  Future<List<StoreProject>> listProjects() async {
    final response = await _send(() => _http.get(_uri('/projects'), headers: _headers()));
    if (response.statusCode != 200) _fail(response);
    final projects = _json(response)['projects'];
    return [if (projects is List) for (final p in projects) if (p is Map<String, dynamic>) StoreProject.fromJson(p)];
  }

  Future<StoreProject> createProject(String name) async {
    final response = await _send(
      () => _http.post(_uri('/projects'), headers: _headers({'Content-Type': 'application/json'}), body: jsonEncode({'name': name})),
    );
    if (response.statusCode != 201 && response.statusCode != 200) _fail(response);
    return StoreProject.fromJson(_json(response));
  }

  Future<StoreTree> tree(String project) async {
    final response = await _send(() => _http.get(_uri('/projects/${_enc(project)}/tree'), headers: _headers()));
    if (response.statusCode != 200) _fail(response);
    final body = _json(response);
    return StoreTree(
      files: [for (final f in (body['files'] as List? ?? const [])) if (f is Map<String, dynamic>) StoreFile.fromJson(f)],
      cursor: (body['cursor'] ?? '0').toString(),
    );
  }

  Future<StoreFetched> getFile(String project, String path) async {
    final response = await _send(() => _http.get(_uri(_filePath(project, path)), headers: _headers()), limit: uploadTimeout);
    if (response.statusCode != 200) _fail(response);
    final etag = (response.headers['etag'] ?? '').replaceAll('"', '');
    return StoreFetched(
      bytes: response.bodyBytes,
      version: int.tryParse(etag) ?? 0,
      sha256: response.headers['x-sha256'] ?? '',
    );
  }

  /// One file's write. [ifMatch] replaces that version; null means create only (`If-None-Match: *`). Always one of the two:
  /// a write with neither is refused by the store (428).
  Future<StoreFile> putFile(String project, String path, Uint8List bytes, {int? ifMatch}) async {
    final response = await _send(
      () => _http.put(
        _uri(_filePath(project, path)),
        headers: _headers({
          'Content-Type': 'application/octet-stream',
          if (ifMatch == null) 'If-None-Match': '*' else 'If-Match': '"$ifMatch"',
        }),
        body: bytes,
      ),
      limit: uploadTimeout,
    );
    if (response.statusCode != 200 && response.statusCode != 201) _fail(response);
    return StoreFile.fromJson(_json(response));
  }

  /// The bytes of one file of a later commit; returns the upload id.
  Future<String> upload(String project, Uint8List bytes) async {
    final response = await _send(
      () => _http.post(_uri('/projects/${_enc(project)}/uploads'), headers: _headers({'Content-Type': 'application/octet-stream'}), body: bytes),
      limit: uploadTimeout,
    );
    if (response.statusCode != 201 && response.statusCode != 200) _fail(response);
    return _json(response)['upload_id'] as String;
  }

  Future<StoreCommitResult> commit(String project, List<StoreCommitChange> changes, {String? message}) async {
    final response = await _send(
      () => _http.post(
        _uri('/projects/${_enc(project)}/commit'),
        headers: _headers({'Content-Type': 'application/json'}),
        body: jsonEncode({if (message != null) 'message': message, 'changes': [for (final c in changes) c.toJson()]}),
      ),
    );
    if (response.statusCode != 200) _fail(response, commit: true);
    final body = _json(response);
    return StoreCommitResult(
      files: [for (final f in (body['files'] as List? ?? const [])) if (f is Map<String, dynamic>) f],
      cursor: (body['cursor'] ?? '').toString(),
    );
  }

  Future<StoreChanges> changes(String project, String since) async {
    final response = await _send(() => _http.get(_uri('/projects/${_enc(project)}/changes', {'since': since}), headers: _headers()));
    if (response.statusCode != 200) _fail(response);
    final body = _json(response);
    return StoreChanges(
      changes: [
        for (final c in (body['changes'] as List? ?? const []))
          if (c is Map<String, dynamic>)
            StoreChange(
              path: c['path'] as String,
              op: c['op'] as String,
              version: c['version'] as int,
              device: (c['device'] as String?) ?? '',
              at: DateTime.tryParse((c['at'] as String?) ?? ''),
              movedTo: c['moved_to'] as String?,
              movedFrom: c['moved_from'] as String?,
            ),
      ],
      cursor: (body['cursor'] ?? since).toString(),
      more: body['more'] == true,
    );
  }

  /// `GET .../parts/{part_id}`: the live files whose root Part id this is (an empty list when none; the store answers 200 for an
  /// unknown id).
  Future<List<StoreFile>> parts(String project, String partId) async {
    final response = await _send(() => _http.get(_uri('/projects/${_enc(project)}/parts/${_enc(partId)}'), headers: _headers()));
    if (response.statusCode != 200) _fail(response);
    final files = _json(response)['files'];
    return [if (files is List) for (final f in files) if (f is Map<String, dynamic>) StoreFile.fromJson(f)];
  }
}
