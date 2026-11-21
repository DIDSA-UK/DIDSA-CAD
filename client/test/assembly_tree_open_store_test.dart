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

  test('writes and reads at the same time lose no document from the index', () async {
    await Future.wait([
      for (var i = 0; i < 10; i++) AssemblyTreeOpenStore.write('doc$i', ['k$i']),
      for (var i = 0; i < 10; i++) AssemblyTreeOpenStore.read('doc${i % 3}'),
    ]);
    final index = (await SharedPreferences.getInstance()).getStringList('assembly_tree_open_documents')!;
    expect(index.toSet(), {for (var i = 0; i < 10; i++) 'doc$i'}, reason: 'every document written is in the index');
    expect(index.length, 10, reason: 'and once');
  });

  test('a read whose bookkeeping fails still returns what was stored', () async {
    SharedPreferences.setMockInitialValues({
      'assembly_tree_open:a': '["x"]',
      'assembly_tree_open_documents': 'not a list', // the index cannot be read as a list: updating it throws
    });
    expect(await AssemblyTreeOpenStore.read('a'), ['x']);
  });

  test('an entry written while another document evicts the oldest is not the one evicted', () async {
    for (var i = 0; i < AssemblyTreeOpenStore.maxDocuments; i++) {
      await AssemblyTreeOpenStore.write('doc$i', ['k$i']);
    }
    // doc0 is the oldest. It is written again at the same moment another document comes in and has to evict someone.
    await Future.wait([AssemblyTreeOpenStore.write('doc0', ['again']), AssemblyTreeOpenStore.write('new', ['n'])]);
    expect(await AssemblyTreeOpenStore.read('doc0'), ['again']);
    expect(await AssemblyTreeOpenStore.read('new'), ['n']);
    expect(await AssemblyTreeOpenStore.read('doc1'), isNull, reason: 'the oldest after doc0 went');
  });

  test('copy puts what is stored for one key under another, and says when there was nothing', () async {
    expect(await AssemblyTreeOpenStore.copy('from', 'to'), isFalse);
    expect(await AssemblyTreeOpenStore.read('to'), isNull);
    await AssemblyTreeOpenStore.write('from', ['a', 'a/b']);
    expect(await AssemblyTreeOpenStore.copy('from', 'to'), isTrue);
    expect(await AssemblyTreeOpenStore.read('to'), ['a', 'a/b']);
    expect(await AssemblyTreeOpenStore.read('from'), ['a', 'a/b'], reason: 'the old key keeps its rows');
  });
}
