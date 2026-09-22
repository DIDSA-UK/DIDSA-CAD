import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/server_management/termux_setup_commands.dart';
import 'package:didsa_cad_client/server_management/termux_setup_controller.dart';

/// [TermuxSetupController] against a mocked
/// 'uk.snail_shell.didsa_cad_client/termux' MethodChannel - no real device,
/// no real Termux, same rationale as termux_controller_test.dart for the
/// server-management side of this platform channel.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('uk.snail_shell.didsa_cad_client/termux');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  group('isTermuxInstalled / isTermuxApiInstalled', () {
    test('delegate to isPackageInstalled with the right package name', () async {
      final requestedPackages = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'isPackageInstalled') {
          requestedPackages.add((call.arguments as Map)['packageName'] as String);
          return true;
        }
        return null;
      });
      final controller = TermuxSetupController();

      expect(await controller.isTermuxInstalled(), isTrue);
      expect(await controller.isTermuxApiInstalled(), isTrue);
      expect(requestedPackages, ['com.termux', 'com.termux.api']);
    });

    test('a null platform result reads as not installed, not a throw', () async {
      messenger.setMockMethodCallHandler(channel, (call) async => null);
      final controller = TermuxSetupController();

      expect(await controller.isTermuxInstalled(), isFalse);
    });
  });

  group('checkSetupStatus', () {
    test('parses a fully-installed JSON status line', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'runCommand') return true;
        if (call.method == 'getLastCommandStdout') {
          return jsonEncode({
            'prootDistroInstalled': true,
            'debianInstalled': true,
            'micromambaInstalled': true,
            'condaEnvCreated': true,
            'repoCloned': true,
            'repoBranch': 'main',
          });
        }
        return null;
      });
      final controller = TermuxSetupController();

      final status = await controller.checkSetupStatus();

      expect(status.isComplete, isTrue);
      expect(status.repoBranch, 'main');
    });

    test('returns unknown if the dispatch itself fails', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'runCommand') return false;
        return null;
      });
      final controller = TermuxSetupController();

      final status = await controller.checkSetupStatus();

      expect(status.isComplete, isFalse);
      expect(status.prootDistroInstalled, isFalse);
    });

    test('returns unknown (not a throw) if no readable stdout ever arrives within the timeout', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'runCommand') return true;
        if (call.method == 'getLastCommandStdout') return null;
        return null;
      });
      final controller = TermuxSetupController();

      final status = await controller.checkSetupStatus(
        timeout: const Duration(milliseconds: 50),
        interval: const Duration(milliseconds: 10),
      );

      expect(status.isComplete, isFalse);
    });

    test('tolerates stdout that is not (yet) valid JSON, polling until it becomes so', () async {
      var calls = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'runCommand') return true;
        if (call.method == 'getLastCommandStdout') {
          calls += 1;
          if (calls < 2) return 'not json yet';
          return jsonEncode({
            'prootDistroInstalled': true,
            'debianInstalled': false,
            'micromambaInstalled': false,
            'condaEnvCreated': false,
            'repoCloned': false,
            'repoBranch': null,
          });
        }
        return null;
      });
      final controller = TermuxSetupController();

      final status = await controller.checkSetupStatus(
        timeout: const Duration(seconds: 2),
        interval: const Duration(milliseconds: 5),
      );

      expect(status.prootDistroInstalled, isTrue);
      expect(status.isComplete, isFalse);
    });

    test('missing boolean fields default to false rather than throwing', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'runCommand') return true;
        if (call.method == 'getLastCommandStdout') return jsonEncode({'prootDistroInstalled': true});
        return null;
      });
      final controller = TermuxSetupController();

      final status = await controller.checkSetupStatus();

      expect(status.prootDistroInstalled, isTrue);
      expect(status.debianInstalled, isFalse);
      expect(status.repoBranch, isNull);
    });
  });

  group('tailSetupLog', () {
    test('returns whatever the dispatch reports back', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'runCommand') return true;
        if (call.method == 'getLastCommandStdout') return 'line1\nline2';
        return null;
      });
      final controller = TermuxSetupController();

      expect(await controller.tailSetupLog(), 'line1\nline2');
    });

    test('returns null if the dispatch itself fails', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'runCommand') return false;
        return null;
      });
      final controller = TermuxSetupController();

      expect(await controller.tailSetupLog(), isNull);
    });

    test('returns null (not a throw) if nothing arrives within the timeout', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'runCommand') return true;
        if (call.method == 'getLastCommandStdout') return null;
        return null;
      });
      final controller = TermuxSetupController();

      expect(await controller.tailSetupLog(timeout: const Duration(milliseconds: 50)), isNull);
    });
  });

  group('runAndWait', () {
    test('reports dispatched:false with an unknown status if the dispatch itself fails', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'runCommand') return false;
        return null;
      });
      final controller = TermuxSetupController();

      final result = await controller.runAndWait(['-lc', 'echo hi']);

      expect(result.dispatched, isFalse);
      expect(result.status.isComplete, isFalse);
    });

    test('polls progress until the done marker appears, then confirms via a real status check', () async {
      final progressUpdates = <String>[];
      var tailCalls = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'runCommand') return true;
        if (call.method == 'getLastCommandStdout') {
          tailCalls += 1;
          if (tailCalls <= 2) return 'still working...'; // baseline + one in-flight poll, no marker yet
          if (tailCalls == 3) return 'still working...\n${TermuxSetupCommands.doneMarker}';
          // The final checkSetupStatus dispatch's own result.
          return jsonEncode({
            'prootDistroInstalled': true,
            'debianInstalled': false,
            'micromambaInstalled': false,
            'condaEnvCreated': false,
            'repoCloned': false,
            'repoBranch': null,
          });
        }
        return null;
      });
      final controller = TermuxSetupController();

      final result = await controller.runAndWait(
        ['-lc', 'echo hi'],
        onProgress: progressUpdates.add,
        pollInterval: const Duration(milliseconds: 5),
        maxWait: const Duration(seconds: 2),
      );

      expect(result.dispatched, isTrue);
      expect(result.status.prootDistroInstalled, isTrue);
      expect(progressUpdates, isNotEmpty);
      expect(progressUpdates.last, contains(TermuxSetupCommands.doneMarker));
    });

    test('gives up after maxWait if the marker never appears, but still confirms via a real status check', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'runCommand') return true;
        if (call.method == 'getLastCommandStdout') {
          // No done marker ever appears in the log tail, but a real status
          // check (a different dispatch/parse path entirely) can still
          // succeed - runAndWait must not treat "marker never seen" as
          // "give up on the final check too".
          return jsonEncode({
            'prootDistroInstalled': true,
            'debianInstalled': true,
            'micromambaInstalled': true,
            'condaEnvCreated': true,
            'repoCloned': true,
            'repoBranch': 'main',
          });
        }
        return null;
      });
      final controller = TermuxSetupController();

      final result = await controller.runAndWait(
        ['-lc', 'echo hi'],
        pollInterval: const Duration(milliseconds: 5),
        maxWait: const Duration(milliseconds: 30),
      );

      expect(result.dispatched, isTrue);
      expect(result.status.isComplete, isTrue);
    });
  });
}
