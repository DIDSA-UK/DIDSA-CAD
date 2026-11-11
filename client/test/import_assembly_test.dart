import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/api/sketch_api_client.dart' show ApiException;
import 'package:didsa_cad_client/viewport3d/import_assembly_dialog.dart';

// F-6: the import-as-assembly choice (dialog, defaults, wording) and the two API calls.
void main() {
  const assembly = ImportProbeDto(products: 37, assemblies: 6, instances: 120, hasStructure: true, mirroredInstances: 0, name: 'Gearbox');
  const single = ImportProbeDto(products: 1, assemblies: 0, instances: 0, hasStructure: false, mirroredInstances: 0, name: '');
  const solids = ImportProbeDto(products: 12, assemblies: 0, instances: 12, hasStructure: false, mirroredInstances: 0, name: '');

  test('the choice is offered for several products and defaults to an assembly; a single product is just imported', () {
    expect(offersAssemblyChoice(assembly), isTrue);
    expect(defaultImportChoice(assembly), ImportAssemblyChoice.assembly);
    expect(offersAssemblyChoice(single), isFalse);
    expect(defaultImportChoice(single), ImportAssemblyChoice.onePart);
    expect(offersAssemblyChoice(solids), isTrue);
  });

  test('the summary names the counts; IGES speaks of solids, and the option is worded per format', () {
    expect(importProbeSummary(assembly, 'step'), 'This file has 37 parts in 6 sub-assemblies.');
    expect(importProbeSummary(const ImportProbeDto(products: 5, assemblies: 0, instances: 5, hasStructure: false, mirroredInstances: 0, name: ''), 'step'), 'This file has 5 parts.');
    expect(importProbeSummary(solids, 'iges'), 'This file has 12 solids.');
    expect(assemblyOptionLabel('step'), 'As an assembly');
    expect(assemblyOptionLabel('iges'), 'One part per solid');
  });

  testWidgets('the dialog shows the counts, marks the suggested option and returns the choice', (tester) async {
    ImportAssemblyChoice? picked;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => picked = await showImportAssemblyDialog(context, assembly, 'step'),
          child: const Text('go'),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('This file has 37 parts in 6 sub-assemblies.'), findsOneWidget);
    expect(find.text('As an assembly  (suggested)'), findsOneWidget);
    expect(find.text('As one part'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('import-as-one-part')));
    await tester.pumpAndSettle();
    expect(picked, ImportAssemblyChoice.onePart);
  });

  group('DocumentApiClient', () {
    test('probeImport posts the file and reads the counts', () async {
      Map<String, dynamic>? sent;
      Uri? url;
      final client = DocumentApiClient(
        httpClient: MockClient((request) async {
          sent = jsonDecode(request.body) as Map<String, dynamic>;
          url = request.url;
          return http.Response(
              jsonEncode({'products': 37, 'assemblies': 6, 'instances': 120, 'has_structure': true, 'mirrored_instances': 2, 'name': 'Gearbox'}), 200);
        }),
      );
      final probe = await client.probeImport(sourceFormat: 'step', bytes: Uint8List.fromList([1, 2, 3]));
      expect(url?.path, '/document/import/probe');
      expect(sent!['source_format'], 'step');
      expect(sent!['data_base64'], base64Encode([1, 2, 3]));
      expect([probe.products, probe.assemblies, probe.instances, probe.hasStructure, probe.mirroredInstances, probe.name], [37, 6, 120, true, 2, 'Gearbox']);
    });

    test('importAssembly posts to the root part and reads the new parts, suggested files and report', () async {
      Uri? url;
      Map<String, dynamic>? sent;
      final client = DocumentApiClient(
        httpClient: MockClient((request) async {
          url = request.url;
          sent = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'document_id': 'd', 'part_ids': ['r', 'a', 'b'], 'new_part_ids': ['a', 'b'], 'root_part_id': 'a', 'occurrence_id': 'o1', 'folder': 'Gearbox',
              'suggested_files': {'a': 'Gearbox/Top.didsa', 'b': 'Gearbox/Pin.didsa'}, 'part_names': {'a': 'Top', 'b': 'Pin'},
              'report': {
                'imported': 35, 'total': 37, 'baked': 1,
                'skipped': [{'name': 'Ghost', 'reason': 'has no shape and no components'}, {'name': 'Mirror', 'reason': 'a mirrored sub-assembly cannot be placed'}],
              },
            }),
            201,
          );
        }),
      );
      final result = await client.importAssembly('r', sourceFormat: 'step', bytes: Uint8List(2), name: 'Gearbox');
      expect(url?.path, '/document/parts/r/import-assembly');
      expect(sent!['name'], 'Gearbox');
      expect(result.newPartIds, ['a', 'b']);
      expect(result.suggestedFiles['b'], 'Gearbox/Pin.didsa');
      expect(result.occurrenceId, 'o1');
      expect(result.report.summary,
          '35 of 37 parts imported; 2 skipped: Ghost (has no shape and no components), Mirror (a mirrored sub-assembly cannot be placed)');
    });

    test('a refusal (too many parts) surfaces as an ApiException', () async {
      final client = DocumentApiClient(
        httpClient: MockClient((request) async => http.Response(jsonEncode({'detail': {'type': 'import_too_large', 'detail': 'too many'}}), 422)),
      );
      await expectLater(() => client.probeImport(sourceFormat: 'step', bytes: Uint8List(1)), throwsA(isA<ApiException>()));
    });
  });
}
