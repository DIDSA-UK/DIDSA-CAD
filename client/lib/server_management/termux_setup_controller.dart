import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import 'termux_setup_commands.dart';

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

  /// Whatever Termux itself reported as the reason the *last* dispatched
  /// command didn't run - e.g. "Termux error 2: RunCommandService requires
  /// `allow-external-apps`..." when that Termux property isn't set yet.
  /// Null whenever the last dispatch had no such error (including a
  /// perfectly successful one, or nothing dispatched yet at all) - callers
  /// use this to turn a bare "nothing happened" timeout into the actual,
  /// specific reason, when Termux provided one.
  Future<String?> lastCommandError() => _channel.invokeMethod<String>('getLastCommandError');

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

  /// Dispatches a `tail` of the setup log and returns whatever text comes
  /// back (or null if the dispatch itself failed, or nothing arrived within
  /// [timeout]) - a lightweight, near-instant read, safe to call repeatedly
  /// while a much longer install/remove script is still running in the
  /// background, for live progress feedback (see [runAndWait]).
  Future<String?> tailSetupLog({Duration timeout = const Duration(seconds: 8)}) async {
    final dispatched = await _dispatch(TermuxSetupCommands.tailLog());
    if (!dispatched) return null;
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final stdout = await _getLastCommandStdout();
      if (stdout != null && stdout.trim().isNotEmpty) return stdout;
      await Future.delayed(const Duration(milliseconds: 300));
    }
    return null;
  }

  /// Builds a fresh, per-call marker (see [TermuxSetupCommands.doneMarker]'s
  /// own doc comment for why a *fixed* one is unsafe to poll for) and
  /// dispatches whatever [buildArguments] returns for it, then repeatedly
  /// (every [pollInterval]) tails the setup log for live progress and checks
  /// whether *this* marker specifically has appeared - the "still
  /// running"/"finished" signal a bare RUN_COMMAND dispatch doesn't
  /// otherwise provide, so the First Installation screen isn't just a
  /// spinner for minutes at a time. [onProgress] is called with the latest
  /// non-null log tail on every poll. Always finishes with one more
  /// [checkSetupStatus] call (real confirmation, not the marker itself -
  /// same "confirm via a real check, not an exit code" posture as
  /// [checkStatus]/[checkSetupStatus] elsewhere), whether the marker was
  /// seen or [maxWait] was simply reached first. `dispatched: false` (with
  /// [SetupStatus.unknown], no polling attempted at all) means the
  /// RUN_COMMAND intent itself couldn't even be sent - distinct from a
  /// genuine timeout, so the caller can show "check the permission" rather
  /// than "done" for a run that never started.
  Future<({bool dispatched, SetupStatus status})> runAndWait(
    List<String> Function(String marker) buildArguments, {
    void Function(String tail)? onProgress,
    Duration maxWait = const Duration(minutes: 10),
    Duration pollInterval = const Duration(seconds: 5),
  }) async {
    final marker = '${TermuxSetupCommands.doneMarker}_${DateTime.now().microsecondsSinceEpoch}';
    final dispatched = await _dispatch(buildArguments(marker));
    if (!dispatched) return (dispatched: false, status: SetupStatus.unknown);

    final deadline = DateTime.now().add(maxWait);
    while (DateTime.now().isBefore(deadline)) {
      await Future.delayed(pollInterval);
      final tail = await tailSetupLog();
      if (tail != null) {
        onProgress?.call(tail);
        if (tail.contains(marker)) break;
      }
    }
    return (dispatched: true, status: await checkSetupStatus());
  }
}
