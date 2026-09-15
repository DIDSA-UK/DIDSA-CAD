import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:didsa_cad_client/storage/recent_project_store.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('last is null before anything has been saved', () async {
    final store = RecentProjectStore();
    expect(await store.last(), isNull);
  });

  test('save then last round-trips the persistedKey and displayName', () async {
    final store = RecentProjectStore();
    await store.save(persistedKey: '/a/b/c', displayName: 'c');

    final last = await store.last();

    expect(last, isNotNull);
    expect(last!.persistedKey, '/a/b/c');
    expect(last.displayName, 'c');
  });

  test('a later save replaces the earlier one, not accumulates', () async {
    final store = RecentProjectStore();
    await store.save(persistedKey: '/first', displayName: 'first');
    await store.save(persistedKey: '/second', displayName: 'second');

    final last = await store.last();

    expect(last!.persistedKey, '/second');
  });

  test('clear removes the saved root so last becomes null again', () async {
    final store = RecentProjectStore();
    await store.save(persistedKey: '/a/b/c', displayName: 'c');
    await store.clear();

    expect(await store.last(), isNull);
  });

  test('a fresh store instance reads what an earlier instance saved', () async {
    await RecentProjectStore().save(persistedKey: '/a/b/c', displayName: 'c');

    final last = await RecentProjectStore().last();

    expect(last!.persistedKey, '/a/b/c');
  });
}
