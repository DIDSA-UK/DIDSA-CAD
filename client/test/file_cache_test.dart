import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/storage/file_cache.dart';
import 'package:didsa_cad_client/storage/project_root.dart';

void main() {
  late Directory tempDir;
  late FileCache cache;
  late ProjectRoot root;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('didsa_file_cache_test_');
    cache = FileCache(cacheDirectory: tempDir);
    root = const DesktopProjectRoot('/some/project');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('get returns null when nothing has been cached for this (root, relativePath)', () async {
    expect(await cache.get(root, 'part.didsa'), isNull);
  });

  test('put then get round-trips the exact bytes', () async {
    final bytes = Uint8List.fromList([1, 2, 3, 4]);
    await cache.put(root, 'part.didsa', bytes);

    final cached = await cache.get(root, 'part.didsa');

    expect(cached, isNotNull);
    expect(cached!.bytes, bytes);
  });

  test('put records cachedAt as roughly now', () async {
    final before = DateTime.now().subtract(const Duration(seconds: 5));
    await cache.put(root, 'part.didsa', Uint8List(0));

    final cached = await cache.get(root, 'part.didsa');

    expect(cached!.cachedAt.isAfter(before), isTrue);
  });

  test('put records the given lastKnownModified, defaulting to null when omitted', () async {
    await cache.put(root, 'a.didsa', Uint8List(0));
    expect((await cache.get(root, 'a.didsa'))!.lastKnownModified, isNull);

    final modified = DateTime(2026, 1, 1);
    await cache.put(root, 'b.didsa', Uint8List(0), lastKnownModified: modified);
    expect((await cache.get(root, 'b.didsa'))!.lastKnownModified, modified);
  });

  test('a later put overwrites an earlier one for the same key', () async {
    await cache.put(root, 'part.didsa', Uint8List.fromList([1]));
    await cache.put(root, 'part.didsa', Uint8List.fromList([2]));

    expect((await cache.get(root, 'part.didsa'))!.bytes, [2]);
  });

  test('different relativePaths under the same root are cached independently', () async {
    await cache.put(root, 'a.didsa', Uint8List.fromList([1]));
    await cache.put(root, 'b.didsa', Uint8List.fromList([2]));

    expect((await cache.get(root, 'a.didsa'))!.bytes, [1]);
    expect((await cache.get(root, 'b.didsa'))!.bytes, [2]);
  });

  test('the same relativePath under different roots is cached independently', () async {
    final otherRoot = const DesktopProjectRoot('/a/different/project');
    await cache.put(root, 'part.didsa', Uint8List.fromList([1]));
    await cache.put(otherRoot, 'part.didsa', Uint8List.fromList([2]));

    expect((await cache.get(root, 'part.didsa'))!.bytes, [1]);
    expect((await cache.get(otherRoot, 'part.didsa'))!.bytes, [2]);
  });

  test('evict removes a cached entry so get returns null again', () async {
    await cache.put(root, 'part.didsa', Uint8List.fromList([1]));
    await cache.evict(root, 'part.didsa');

    expect(await cache.get(root, 'part.didsa'), isNull);
  });

  test('evict on a never-cached key is a safe no-op', () async {
    await cache.evict(root, 'never-cached.didsa');
  });
}
