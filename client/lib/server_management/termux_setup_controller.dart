import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import 'termux_setup_commands.dart';

/// One stage of the on-device install, in the order the First Installation
/// screen runs (and displays) them.
enum SetupStage { prootDistro, debianDistro, debianPackages, micromamba, repoAndEnv }

/// A single `checkSetupStatus()` result - either a real, parsed snapshot, or
/// [unknown] when no result arrived in time (most likely because step 3,
/// `allow-external-apps`, isn't actually set yet - see [SetupStatus.unknown]
/// itself for why this can't be confirmed more precisely).
class SetupStatus {
  const SetupStatus({
    required this.prootDistroInstalled,
    required this.debianInstalled,
    required this.micromambaInstalled,
    required this.condaEnvCreated,
    required this.repoCloned,
    this.repoBranch,
  });

  final bool prootDistroInstalled;
  final bool debianInstalled;
  final bool micromambaInstalled;
  final bool condaEnvCreated;
  final bool repoCloned;
  final String? repoBranch;

  /// Nothing confirmed either way - either this is the very first check, or
  /// the status script's dispatch produced no readable result at all. The
  /// single most likely cause of the latter is `allow-external-apps` still
  /// being `false` in `~/.termux/termux.properties` (Termux silently
  /// refuses to run anything dispatched by another app in that case) - but
  /// this can't be confirmed as *the* cause without a documented, stable
  /// Termux result schema to check against (same caveat
  /// TermuxResultService's own doc comment already makes about
  /// [dumpIntentExtras]), so this is surfaced to the user as a hint, not a
  /// diagnosis.
  static const unknown = SetupStatus(
    prootDistroInstalled: false,
    debianInstalled: false,
    micromambaInstalled: false,
    condaEnvCreated: false,
    repoCloned: false,
  );

  bool get isComplete => prootDistroInstalled && debianInstalled && micromambaInstalled && condaEnvCreated && repoCloned;

  bool isStageComplete(SetupStage stage) => switch (stage) {
        SetupStage.prootDistro => prootDistroInstalled,
        SetupStage.debianDistro => debianInstalled,
        SetupStage.debianPackages => debianInstalled, // no separate signal captured - folded into stage 2/4's own checks
        SetupStage.micromamba => micromambaInstalled,
        SetupStage.repoAndEnv => condaEnvCreated && repoCloned,
      };
}

/// Dispatches [TermuxSetupCommands] and reads the results back - the
/// installation counterpart to [TermuxController] (server start/stop/pull),
/// reusing the same platform channel since both talk to the same Android
/// side.
class TermuxSetupController {
  static const MethodChannel _channel = MethodChannel('uk.snail_shell.didsa_cad_client/termux');

  Future<bool> isTermuxInstalled() => _isPackageInstalled('com.termux');

  Future<bool> isTermuxApiInstalled() => _isPackageInstalled('com.termux.api');

  Future<bool> _isPackageInstalled(String packageName) async {
    final result = await _channel.invokeMethod<bool>('isPackageInstalled', {'packageName': packageName});
    return result ?? false;
  }

  Future<String?> _getLastCommandStdout() => _channel.invokeMethod<String>('getLastCommandStdout');

  Future<bool> _dispatch(List<String> arguments) async {
    final result = await _channel.invokeMethod<bool>('runCommand', {
      'executable': TermuxSetupCommands.executable,
      'arguments': arguments,
    });
    return result ?? false;
  }

  /// Dispatches the status-check script, then polls for its result - a
  /// dispatched RUN_COMMAND intent has no direct return value (see
  /// TermuxController.checkStatus's own doc comment on the same underlying
  /// fire-and-forget mechanism), so this waits up to [timeout] for
  /// TermuxResultService to capture a fresh stdout string that parses as
  /// the expected JSON shape, polling every [interval]. Returns
  /// [SetupStatus.unknown] if the dispatch itself couldn't even be sent, or
  /// if nothing parseable arrived within [timeout].
  Future<SetupStatus> checkSetupStatus({
    Duration timeout = const Duration(seconds: 15),
    Duration interval = const Duration(milliseconds: 500),
  }) async {
    final dispatched = await _dispatch(TermuxSetupCommands.checkStatus());
    if (!dispatched) return SetupStatus.unknown;

    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final stdout = await _getLastCommandStdout();
      final parsed = _tryParse(stdout);
      if (parsed != null) return parsed;
      await Future.delayed(interval);
    }
    return SetupStatus.unknown;
  }

  SetupStatus? _tryParse(String? stdout) {
    if (stdout == null || stdout.trim().isEmpty) return null;
    try {
      final json = jsonDecode(stdout.trim()) as Map<String, dynamic>;
      return SetupStatus(
        prootDistroInstalled: json['prootDistroInstalled'] == true,
        debianInstalled: json['debianInstalled'] == true,
        micromambaInstalled: json['micromambaInstalled'] == true,
        condaEnvCreated: json['condaEnvCreated'] == true,
        repoCloned: json['repoCloned'] == true,
        repoBranch: json['repoBranch'] as String?,
      );
    } catch (_) {
      // Not (yet) a parseable status line - e.g. still the stdout of some
      // earlier, unrelated dispatch, or truncated because Termux hasn't
      // finished writing it back yet. Treated as "not ready", not a hard
      // failure, so the polling loop above keeps trying.
      return null;
    }
  }

  Future<bool> runStage(SetupStage stage, {String branch = 'main'}) => _dispatch(switch (stage) {
        SetupStage.prootDistro => TermuxSetupCommands.installStage1(),
        SetupStage.debianDistro => TermuxSetupCommands.installStage2(),
        SetupStage.debianPackages => TermuxSetupCommands.installStage3(),
        SetupStage.micromamba => TermuxSetupCommands.installStage4(),
        SetupStage.repoAndEnv => TermuxSetupCommands.installStage5(branch: branch),
      });

  Future<bool> runAllRemaining({String branch = 'main'}) => _dispatch(TermuxSetupCommands.installAllRemaining(branch: branch));

  Future<bool> removeEverything() => _dispatch(TermuxSetupCommands.removeEverything());
}
