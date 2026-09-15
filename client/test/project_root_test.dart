import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/storage/project_root.dart';

void main() {
  group('DesktopProjectRoot', () {
    test('displayName is the last path segment', () {
      final root = DesktopProjectRoot('/home/user/didsa/projects');
      expect(root.displayName, 'projects');
    });

    test('displayName handles a trailing separator', () {
      final root = DesktopProjectRoot('/home/user/didsa/projects/');
      expect(root.displayName, 'projects');
    });

    test('displayName falls back to the whole path when there are no segments', () {
      final root = DesktopProjectRoot('/');
      expect(root.displayName, '/');
    });

    test('persistedKey is the raw path', () {
      final root = DesktopProjectRoot('/home/user/didsa/projects');
      expect(root.persistedKey, '/home/user/didsa/projects');
    });

    test('equality is by path', () {
      expect(DesktopProjectRoot('/a/b'), DesktopProjectRoot('/a/b'));
      expect(DesktopProjectRoot('/a/b'), isNot(DesktopProjectRoot('/a/c')));
    });
  });

  group('SafProjectRoot', () {
    test('displayName and persistedKey are independent', () {
      final root = SafProjectRoot(treeUri: 'content://tree/abc', displayName: 'projects');
      expect(root.displayName, 'projects');
      expect(root.persistedKey, 'content://tree/abc');
    });

    test('equality is by treeUri, not displayName', () {
      final a = SafProjectRoot(treeUri: 'content://tree/abc', displayName: 'projects');
      final b = SafProjectRoot(treeUri: 'content://tree/abc', displayName: 'renamed');
      expect(a, b);
    });

    test('a SafProjectRoot and a DesktopProjectRoot are never equal', () {
      final saf = SafProjectRoot(treeUri: '/a/b', displayName: 'x');
      final desktop = DesktopProjectRoot('/a/b');
      expect(saf == desktop, isFalse);
    });
  });
}
