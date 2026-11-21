import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:didsa_cad_client/viewport3d/assembly_tree_open_store.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('keys read back as stored; a document never stored reads as null; an empty list is a state', () async {
    expect(await AssemblyTreeOpenStore.read('a'), isNull);
    await AssemblyTreeOpenStore.write('a', ['x', 'x/y']);
    await AssemblyTreeOpenStore.write('b', []);
    expect(await AssemblyTreeOpenStore.read('a'), ['x', 'x/y']);
    expect(await AssemblyTreeOpenStore.read('b'), isEmpty);
  });

  test('past the limit the document used longest ago goes, and a read counts as a use', () async {
    for (var i = 0; i < AssemblyTreeOpenStore.maxDocuments; i++) {
      await AssemblyTreeOpenStore.write('doc$i', ['k$i']);
    }
    expect(await AssemblyTreeOpenStore.read('doc0'), ['k0'], reason: 'opened again: it is the most recently used now');
    await AssemblyTreeOpenStore.write('new', ['n']);
    expect(await AssemblyTreeOpenStore.read('doc0'), ['k0'], reason: 'kept: it was read after doc1 was written');
    expect(await AssemblyTreeOpenStore.read('doc1'), isNull, reason: 'the one used longest ago went');
    expect(await AssemblyTreeOpenStore.read('doc2'), ['k2']);
    expect(await AssemblyTreeOpenStore.read('new'), ['n']);
  });
}
