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
        TermuxCommands.pullAndStart('main', 'key'),
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
      expect(script, contains('exec python -m uvicorn'));
    });

    test('startServer runs uvicorn in the foreground (exec), not backgrounded', () {
      // Regression guard for a real on-device bug: backgrounding uvicorn
      // (setsid/nohup/trailing "&") let the whole proot-distro process tree
      // exit immediately after backgrounding it, which killed the
      // "detached" uvicorn along with it - proot isn't a real container, it
      // has to stay running to keep servicing syscalls for anything inside
      // it via ptrace, so nothing can outlive it by backgrounding alone.
      // Confirmed via TermuxResultService's captured real result on-device
      // (exitCode 0, empty stdout/stderr - the dispatched script itself
      // completing instantly, exactly what backgrounding produces).
      final script = TermuxCommands.startServer('key').last;
      expect(script, isNot(contains('setsid')));
      expect(script, isNot(contains('nohup')));
      expect(script, isNot(contains(r'uvicorn app.main:app --host 127.0.0.1 --port 8000 > ~/didsa-backend.log 2>&1 < /dev/null &')));
      expect(script.trim(), isNot(endsWith('&')));
    });

    test('startServer kills any already-running instance before starting a new one', () {
      final script = TermuxCommands.startServer('key').last;
      expect(script, contains("pkill -f 'uvicorn app.main:app'"));
    });

    test('startServer normalizes pkill finding nothing to a real success, chained with &&', () {
      // Regression guard: this used to be a bare ";" before pkill, which
      // meant the start step ran *unconditionally* - even if an earlier
      // step in a chained command (e.g. pullAndStart's own git pull) had
      // already failed. Verified against real bash during development
      // (both the failure-still-blocks and success-still-proceeds paths).
      final script = TermuxCommands.startServer('key').last;
      expect(script, contains("(pkill -f 'uvicorn app.main:app' 2>/dev/null || true)"));
      expect(script, contains('|| true) && exec python -m uvicorn'));
      expect(script, isNot(contains('2>/dev/null; exec')));
    });

    test('stopServer reports whether anything was actually running', () {
      final script = TermuxCommands.stopServer().last;
      expect(script, contains("pkill -f 'uvicorn app.main:app' && echo stopped || echo not_running"));
    });

    test('restartServer both stops and starts in the one dispatched command', () {
      final script = TermuxCommands.restartServer('key').last;
      expect(script, contains("pkill -f 'uvicorn app.main:app'"));
      expect(script, contains('micromamba activate didsa'));
      expect(script, contains('exec python -m uvicorn'));
    });

    test('API key containing a single quote is escaped, not left to break the export', () {
      final script = TermuxCommands.startServer("k'ey").last;
      expect(script, contains(r"CAD_API_KEY='k'\''ey'"));
    });

    test('pullAndStart contains both the pull and the start scripts', () {
      final script = TermuxCommands.pullAndStart('claude/foo', 'super-secret').last;
      expect(script, contains("git fetch origin 'claude/foo'"));
      expect(script, contains("git checkout 'claude/foo'"));
      expect(script, contains('git reset --hard FETCH_HEAD'));
      expect(script, contains('micromamba activate didsa'));
      expect(script, contains("export CAD_API_KEY='super-secret'"));
      expect(script, contains('exec python -m uvicorn'));
    });

    test('pullAndStart joins pull and start with && (single command chain), not two dispatches', () {
      // The whole point of pullAndStart existing as its own command rather
      // than the caller just calling pullLatest then startServer
      // separately: RUN_COMMAND_BACKGROUND returns before the dispatched
      // command finishes, so two separate intents would race the pull
      // actually completing. Verified against real bash during development
      // that a failure partway through the pull genuinely prevents the
      // start step from running at all, not just that this text is present.
      final script = TermuxCommands.pullAndStart('main', 'key').last;
      final pullEnd = script.indexOf('git reset --hard FETCH_HEAD');
      final startBegin = script.indexOf('cd ~/DIDSA-CAD/backend');
      expect(pullEnd, greaterThanOrEqualTo(0));
      expect(startBegin, greaterThan(pullEnd));
      expect(script.substring(pullEnd, startBegin), contains('&&'));
    });

    test('pullAndStart is a single dispatched command, not two', () {
      expect(TermuxCommands.pullAndStart('main', 'key').length, 6);
    });
  });
}
