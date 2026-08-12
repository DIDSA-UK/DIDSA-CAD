/// Builds the exact proot-distro/Termux commands the Server Management
/// screen dispatches to control an on-device standalone backend - see this
/// project's own manual walkthrough of setting one up (Termux +
/// `proot-distro install debian` + `backend/environment.yml`'s conda env,
/// named `didsa`, cloned to `~/DIDSA-CAD`).
///
/// Pure string-building only, no platform-channel/Termux dependency here -
/// [TermuxController] is what actually dispatches these. Kept separate
/// specifically so the command text itself is unit-testable without a
/// device (see client/test/server_management/termux_commands_test.dart).
class TermuxCommands {
  TermuxCommands._();

  static const String distroAlias = 'debian';
  static const String repoDir = '~/DIDSA-CAD';
  static const String backendDir = '$repoDir/backend';
  static const String condaEnv = 'didsa';
  static const String logFile = '~/didsa-backend.log';
  static const String processMatch = 'uvicorn app.main:app';

  /// The executable RUN_COMMAND_PATH points at - proot-distro itself, not
  /// bash directly, since every command here needs to run inside the
  /// Debian environment the real backend is installed in.
  static const String executable = '/data/data/com.termux/files/usr/bin/proot-distro';

  /// A conservative allowlist for a git branch name entered by the user -
  /// correct shell-quoting (see [_shellQuote]) already prevents shell
  /// injection on its own, but this is a second, independent guard against
  /// a value that's syntactically safe yet semantically wrong (e.g. a
  /// leading "-" being read as a git flag rather than a branch name).
  /// Deliberately conservative (matches most real branch names, including
  /// this project's own "claude/foo-bar" convention) rather than
  /// attempting to replicate git's full, more permissive ref-name rules.
  static final RegExp _validBranchName = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._/-]*$');

  static bool isValidBranchName(String branch) => _validBranchName.hasMatch(branch);

  /// `git fetch` + `checkout` + a hard reset to the fetched remote tip -
  /// deliberately discards any local drift in the Termux clone rather than
  /// merging/rebasing, since that clone exists purely to run whatever a
  /// branch currently contains, not to carry its own edits.
  static List<String> pullLatest(String branch) => _wrapInDistro(_pullScript(branch));

  /// [apiKey] should be [ApiConfig.apiKey] - the backend refuses to start
  /// without CAD_API_KEY set, and the client can only talk to it if that
  /// key matches what ConnectionScreen already has stored, so the caller
  /// must pass the same value rather than this screen collecting its own.
  static List<String> startServer(String apiKey) => _wrapInDistro(_startScript(apiKey));

  static List<String> stopServer() =>
      _wrapInDistro("pkill -f ${_shellQuote(processMatch)} && echo stopped || echo not_running");

  /// Stop then start in one dispatched command (rather than two separate
  /// RUN_COMMAND intents) so there's no window where the app could observe
  /// "not running" between them and no ordering dependency on Android's
  /// own intent delivery timing.
  static List<String> restartServer(String apiKey) =>
      _wrapInDistro("pkill -f ${_shellQuote(processMatch)} 2>/dev/null; sleep 1; ${_startScript(apiKey)}");

  /// Pull then start in *one* dispatched command, not two separate
  /// RUN_COMMAND intents - RUN_COMMAND_BACKGROUND returns as soon as
  /// Android hands the intent to Termux, not when the command inside it
  /// finishes (see MainActivity.kt's own doc comment), so firing a second
  /// intent right after the first would race the git pull actually
  /// finishing. Chaining both inside one `&&`-joined script guarantees the
  /// pull completes before the start script even begins - the whole point
  /// of this being one shell parse rather than an ordering assumption
  /// about two independent ones.
  static List<String> pullAndStart(String branch, String apiKey) =>
      _wrapInDistro('${_pullScript(branch)} && ${_startScript(apiKey)}');

  static String _pullScript(String branch) {
    final quotedBranch = _shellQuote(branch);
    return 'cd $repoDir '
        '&& git fetch origin $quotedBranch '
        '&& git checkout $quotedBranch '
        // FETCH_HEAD (not "origin/$branch" interpolated again) - avoids a
        // third, unquoted embedding of the branch name in this script.
        '&& git reset --hard FETCH_HEAD';
  }

  static String _startScript(String apiKey) =>
      'cd $backendDir '
      '&& eval "\$(micromamba shell hook --shell bash)" '
      '&& micromamba activate $condaEnv '
      '&& export CAD_API_KEY=${_shellQuote(apiKey)} '
      // (pkill ... || true): pkill legitimately exits nonzero when nothing
      // was running to kill - expected, not a real failure - but that
      // still has to be normalized to a real success (0) rather than
      // joined with a bare ";", or every step before this one (cd, the
      // conda activation, export) would silently stop gating whether the
      // server actually starts: a bare ";" runs the next command
      // unconditionally, regardless of the exit status of an entire
      // preceding "&&" chain, not just the one command right before it -
      // confirmed by testing the failure path directly during this
      // feature's own development, not just by inspection.
      "&& (pkill -f ${_shellQuote(processMatch)} 2>/dev/null || true) "
      // setsid + nohup + redirected stdin/stdout/stderr: the standard,
      // fully-detached-daemon pattern - survives this script's own exit
      // (and the RUN_COMMAND_BACKGROUND execution finishing) rather than
      // relying on job-control-only tricks like a bare "&"/disown, which
      // are best-effort at the interactive-shell level, not guaranteed
      // against a service tearing down its exec'd process tree.
      '&& setsid nohup python -m uvicorn app.main:app --host 127.0.0.1 --port 8000 '
      '> $logFile 2>&1 < /dev/null &';

  /// RUN_COMMAND_ARGUMENTS is delivered as a real argv array (see
  /// MainActivity.kt's own doc comment), never re-parsed as a shell string
  /// by Android or by proot-distro's own "-- " argument passthrough - so
  /// there is exactly one real shell parse in this whole chain (the final
  /// "bash -lc <script>"), not two. [script] only needs its own
  /// interpolated values ([_shellQuote]) escaped once, for that one parse -
  /// no separate escaping pass over the assembled script itself.
  static List<String> _wrapInDistro(String script) => ['login', distroAlias, '--', 'bash', '-lc', script];

  /// Standard POSIX single-quote escaping: close the quote, insert a
  /// literal quote via an adjacent escaped-quote sequence, reopen the
  /// quote. Verified against bash directly (not just by inspection) during
  /// this feature's own development - a value containing '/"/$ all
  /// round-tripped correctly.
  static String _shellQuote(String value) => "'${value.replaceAll("'", r"'\''")}'";
}
