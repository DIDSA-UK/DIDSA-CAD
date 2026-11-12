import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../config.dart';
import 'mesh_data.dart' show MeshImportError;

/// F-5 (`docs/iges-jt-and-desktop-input-plan-2026-11-11.md`): the mesh viewer decodes STL / OBJ / glTF / PLY on the device with no server, but STEP and IGES are B-rep
/// and need OCCT to be tessellated. They go through the saved DIDSA-CAD server's stateless `POST /document/convert/mesh`, which answers a `.glb` the viewer then
/// decodes like any other (so decimation, up-axis, mirror and export keep working). Every mesh format keeps working with no server.

/// Extensions the viewer reads on the device.
const List<String> kDeviceMeshExtensions = ['stl', 'obj', 'gltf', 'glb', 'ply'];

/// Extensions that need the server.
const List<String> kServerMeshExtensions = ['step', 'stp', 'iges', 'igs'];

/// Everything the viewer's picker accepts.
const List<String> kViewerExtensions = [...kDeviceMeshExtensions, ...kServerMeshExtensions];

/// Whether [extension] (lower case, no dot) needs the server.
bool needsServer(String extension) => kServerMeshExtensions.contains(extension);

/// The backend's `source_format` for a B-rep extension (`stp` is `step`, `igs` is `iges`).
String sourceFormatFor(String extension) => switch (extension) {
      'step' || 'stp' => 'step',
      'iges' || 'igs' => 'iges',
      _ => throw MeshImportError('"$extension" is not a STEP or IGES file'),
    };

/// The message shown when no server is saved or it does not answer.
String serverNeededMessage(String extension) =>
    'Opening ${sourceFormatFor(extension) == 'step' ? 'STEP' : 'IGES'} files needs a DIDSA-CAD server: connect one first (the mesh formats work without).';

/// Converts a STEP / IGES file's [bytes] to `.glb` bytes on the saved server. Throws [MeshImportError] with a readable message when there is no server, it
/// is unreachable, or it refuses the file (too large, corrupt, ...).
Future<Uint8List> convertBrepToGlb({
  required Uint8List bytes,
  required String extension,
  http.Client? client,
  String? baseUrl,
  String? apiKey,
}) async {
  final url = baseUrl ?? ApiConfig.baseUrl;
  if (url.isEmpty) throw MeshImportError(serverNeededMessage(extension));
  final httpClient = client ?? http.Client();
  try {
    final response = await httpClient
        .post(
          Uri.parse('$url/document/convert/mesh'),
          headers: {'Content-Type': 'application/json', 'X-API-Key': apiKey ?? ApiConfig.apiKey},
          body: jsonEncode({'source_format': sourceFormatFor(extension), 'data_base64': base64Encode(bytes)}),
        )
        .timeout(const Duration(minutes: 2));
    if (response.statusCode == 200) return response.bodyBytes;
    var reason = 'the server answered ${response.statusCode}';
    try {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      final detail = body is Map ? body['detail'] : null;
      if (detail is Map && detail['detail'] != null) {
        reason = detail['detail'].toString();
      } else if (detail != null) {
        reason = detail.toString();
      }
    } on FormatException {
      // keep the status text
    }
    throw MeshImportError('The server could not convert the file: $reason');
  } on MeshImportError {
    rethrow;
  } on Exception catch (_) {
    throw MeshImportError(serverNeededMessage(extension));
  } finally {
    if (client == null) httpClient.close();
  }
}
