import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/server_management/termux_commands.dart';

/// Pure string-building logic, so these run with no platform channel, no
/// device, no Termux - the actual shell-quoting round-trip was separately
/// verified against real bash during development (single/double quotes,
/// `$`, spaces all reconstruct correctly); these tests check the generated
/// command *shape* stays correct as the source evolves.
void main() {
  group('TermuxCommands.isValidBranchName', () {
    test('accepts ordinary and this project\'s own branch-naming convention', () {
      expect(TermuxCommands.isValidBranchName('main'), isTrue);
      expect(TermuxCommands.isValidBranchName('claude/didsa-standalone-device-md3y80'), isTrue);
      expect(TermuxCommands.isValidBranchName('release-1.2.3'), isTrue);
    });

    test('rejects empty, shell-metacharacter, and leading-dash values', () {
      expect(TermuxCommands.isValidBranchName(''), isFalse);
      expect(TermuxCommands.isValidBranchName('-x'), isFalse);
      expect(TermuxCommands.isValidBranchName('main; rm -rf ~'), isFalse);
      expect(TermuxCommands.isValidBranchName(r'main$(whoami)'), isFalse);
      expect(TermuxCommands.isValidBranchName('main branch'), isFalse);
    });
  });

  group('TermuxCommands command shape', () {
    const executable = TermuxCommands.executable;

    test('every command routes through proot-distro into the debian distro via bash -lc', () {
      for (final argv in [
        TermuxCommands.pullLatest('main'),
        TermuxCommands.startServer('key'),
        TermuxCommands.stopServer(),
        TermuxCommands.restartServer('key'),
      ]) {
        expect(argv.take(4), ['login', 'debian', '--', 'bash']);
        expect(argv[4], '-lc');
        expect(argv.length, 6);
      }
      expect(executable, contains('proot-distro'));
    });

    test('pullLatest fetches/checks-out/hard-resets to the given branch, single-quoted', () {
      final script = TermuxCommands.pullLatest('claude/foo').last;
      expect(script, contains("git fetch origin 'claude/foo'"));
      expect(script, contains("git checkout 'claude/foo'"));
      expect(script, contains('git reset --hard FETCH_HEAD'));
      expect(script, contains('~/DIDSA-CAD'));
    });

    test('pullLatest single-quote-escapes a branch name containing a literal quote', () {
      final script = TermuxCommands.pullLatest("o'brien").last;
      expect(script, contains(r"'o'\''brien'"));
    });

    test('startServer activates the didsa conda env and exports the given API key', () {
      final script = TermuxCommands.startServer('super-secret').last;
      expect(script, contains('micromamba activate didsa'));
      expect(script, contains("export CAD_API_KEY='super-secret'"));
      expect(script, contains('uvicorn app.main:app --host 127.0.0.1 --port 8000'));
      expect(script, contains('setsid nohup'));
    });

    test('startServer kills any already-running instance before starting a new one', () {
      final script = TermuxCommands.startServer('key').last;
      expect(script, contains("pkill -f 'uvicorn app.main:app'"));
    });

    test('stopServer reports whether anything was actually running', () {
      final script = TermuxCommands.stopServer().last;
      expect(script, contains("pkill -f 'uvicorn app.main:app' && echo stopped || echo not_running"));
    });

    test('restartServer both stops and starts in the one dispatched command', () {
      final script = TermuxCommands.restartServer('key').last;
      expect(script, contains("pkill -f 'uvicorn app.main:app'"));
      expect(script, contains('micromamba activate didsa'));
      expect(script, contains('setsid nohup'));
    });

    test('API key containing a single quote is escaped, not left to break the export', () {
      final script = TermuxCommands.startServer("k'ey").last;
      expect(script, contains(r"CAD_API_KEY='k'\''ey'"));
    });
  });
}
