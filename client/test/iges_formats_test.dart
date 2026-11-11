import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/viewport3d/export_format_dialog.dart';
import 'package:didsa_cad_client/viewport3d/import_format_dialog.dart';

// F-3: IGES in the import / export dialogs and the API client.
void main() {
  group('format lists', () {
    test('import offers IGES with .iges and .igs', () {
      final iges = importFormatOptions.firstWhere((o) => o.value == 'iges');
      expect(iges.label, 'IGES');
      expect(iges.extensions, ['iges', 'igs']);
    });

    test('export offers IGES and saves it as .igs, the others by their value', () {
      final iges = exportFormatOptions.firstWhere((o) => o.value == 'iges');
      expect(iges.extension, 'igs');
      expect(exportFormatOptions.firstWhere((o) => o.value == 'step').extension, 'step');
      expect(exportFormatOptions.firstWhere((o) => o.value == 'glb').extension, 'glb');
    });
  });

  testWidgets('the import and export dialogs list IGES and return its value', (tester) async {
    String? picked;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Column(children: [
          TextButton(onPressed: () async => picked = await showImportFormatDialog(context), child: const Text('imp')),
          TextButton(onPressed: () async => picked = await showExportFormatDialog(context), child: const Text('exp')),
        ]),
      ),
    ));
    await tester.tap(find.text('imp'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('IGES'));
    await tester.pumpAndSettle();
    expect(picked, 'iges');
    picked = null;
    await tester.tap(find.text('exp'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('IGES'));
    await tester.pumpAndSettle();
    expect(picked, 'iges');
  });

  group('DocumentApiClient with IGES', () {
    test('exportPart and exportAssemblyPart use the iges path segments', () async {
      final paths = <String>[];
      final client = DocumentApiClient(
        httpClient: MockClient((request) async {
          paths.add(request.url.path);
          return http.Response.bytes(Uint8List.fromList([1, 2]), 200);
        }),
      );
      await client.exportPart('p1', 'iges');
      await client.exportAssemblyPart('p1', 'iges');
      expect(paths, ['/document/parts/p1/export/iges', '/document/parts/p1/export/assembly-iges']);
    });

    test('createImportFeature posts source_format iges and reads the solid flag back', () async {
      Map<String, dynamic>? sent;
      final client = DocumentApiClient(
        httpClient: MockClient((request) async {
          sent = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({'type': 'import', 'id': 'f1', 'locked': false, 'produces': 'body', 'source_format': 'iges', 'source_byte_count': 3, 'solid': false}),
            201,
          );
        }),
      );
      final feature = await client.createImportFeature('p1', sourceFormat: 'iges', bytes: Uint8List.fromList([1, 2, 3]));
      expect(sent!['source_format'], 'iges');
      expect(sent!['data_base64'], base64Encode([1, 2, 3]));
      expect(feature.solid, isFalse);
    });

    test('a feature response without the flag has solid == null', () async {
      final client = DocumentApiClient(
        httpClient: MockClient((request) async =>
            http.Response(jsonEncode({'type': 'import', 'id': 'f1', 'locked': false, 'produces': 'body'}), 201)),
      );
      final feature = await client.createImportFeature('p1', sourceFormat: 'step', bytes: Uint8List(1));
      expect(feature.solid, isNull);
    });
  });
}
