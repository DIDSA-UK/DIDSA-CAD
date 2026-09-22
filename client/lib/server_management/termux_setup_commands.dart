import 'termux_commands.dart';

/// Builds the exact Termux commands the First Installation screen dispatches
/// to take a brand-new device from "Termux installed" to "the Server
/// Management screen's buttons work" - installing `proot-distro`'s Debian,
/// `micromamba`, the `didsa` conda env (see `backend/environment.yml`), and
/// a clone of this repo, entirely on-device.
///
/// Pure string-building only, no platform-channel/Termux dependency here -
/// see [TermuxSetupController] for the dispatching side, and
/// client/test/server_management/termux_setup_commands_test.dart for what's
/// verified about the generated text without a device.
///
/// Unlike [TermuxCommands] (whose `executable` is `proot-distro` itself,
/// dispatched directly), every command here runs via [executable] - Termux's
/// own `bash` - because `termux-wake-lock`/`termux-wake-unlock` (this is the
/// concrete reason Termux:API, not just Termux, is required: without a wake
/// lock, Android's doze can kill a multi-minute `apt-get`/`micromamba
/// create` the moment the screen turns off) only exist in Termux's own
/// `$PREFIX/bin`, not inside the isolated Debian proot - so anything that
/// needs to run inside Debian is nested as a nested `proot-distro login
/// debian -- bash -lc <script>` invocation *within* a top-level Termux
/// script, rather than being the dispatched command itself.
class TermuxSetupCommands {
  TermuxSetupCommands._();

  /// The executable RUN_COMMAND_PATH points at for every command this class
  /// builds - Termux's own bash, not proot-distro (contrast
  /// [TermuxCommands.executable]) - since every script here needs
  /// termux-wake-lock/termux-wake-unlock, which only exist in Termux's own
  /// environment, and reaches into Debian itself (once installed) via a
  /// nested `proot-distro login` call rather than being dispatched inside it
  /// directly.
  static const String executable = '/data/data/com.termux/files/usr/bin/bash';

  /// Deliberately `/usr/local/bin`, not `~/.local/bin` (a first version of
  /// this class used that) - `/usr/local/bin` is part of bash's own
  /// compiled-in default `PATH`, so a bare `micromamba` command resolves
  /// even in a non-interactive `bash -lc` login shell that never sources
  /// `.bashrc`/`.profile` at all (see [_stage4Body]'s own doc comment on
  /// why this class itself never relies on that - `~/.local/bin` needs
  /// `.profile` to add it, which a non-interactive shell typically skips).
  /// [TermuxCommands]'s pre-existing start/restart scripts assume exactly
  /// this - a bare `micromamba shell hook`/`micromamba activate` with no
  /// path of its own - so this has to be somewhere already on `PATH` by
  /// default, not just a path this class's own scripts happen to know.
  static const String micromambaBin = '/usr/local/bin/micromamba';
  static const String setupLogFile = '~/didsa-setup.log';
  static const String repoUrl = 'https://github.com/DIDSA-UK/DIDSA-CAD.git';

  /// Default value of every install/remove method's own `marker` parameter
  /// - echoed to [setupLogFile] at the script's end (success or failure
  /// alike - see [_wrapTopLevel]) as a signal [TermuxSetupController
  /// .runAndWait] can watch for in the log tail, since a dispatched
  /// RUN_COMMAND has no live "still running"/"finished" signal of its own.
  /// Not a success marker - only that the dispatched script itself has
  /// reached its end; actual success is still confirmed separately via
  /// [checkStatus], same as everywhere else in this class.
  ///
  /// [setupLogFile] is append-only and shared across every run this class
  /// has ever dispatched, and [TermuxSetupCommands.tailLog] only ever shows
  /// its last N lines - so a *fixed* marker string is not safe to poll for:
  /// an earlier, already-completed dispatch's own marker can still be
  /// sitting inside that tail window when a *new* dispatch starts, and the
  /// window changing at all (even from unrelated new output) then reads as
  /// "the marker just appeared". This was a real, confirmed bug - a fast,
  /// wrong "done" reported for a stage 5 run that had barely started,
  /// because an earlier successful run's own marker was still in-window.
  /// [TermuxSetupController.runAndWait] instead builds a fresh,
  /// per-dispatch-unique marker (this value plus a timestamp) and passes it
  /// to whichever `installXxx`/`removeEverything` call it's driving, via
  /// each method's own `marker` parameter - this default is only for
  /// callers that don't care about polling at all (e.g. the copy/paste text
  /// shown for a user to run manually, or these classes' own tests).
  static const String doneMarker = '===DIDSA_SETUP_STAGE_DONE===';

  // Reused from TermuxCommands rather than redefined, so both command sets
  // agree on exactly where the distro/repo/env live.
  static const String repoDir = TermuxCommands.repoDir;
  static const String backendDir = TermuxCommands.backendDir;
  static const String condaEnv = TermuxCommands.condaEnv;

  /// A single `bash -lc` script, run directly in Termux (not nested inside
  /// Debian - proot-distro itself may not even be installed yet), that
  /// probes every stage below and prints one line of JSON to stdout. See
  /// [TermuxSetupController.checkSetupStatus] for how the result gets back
  /// to Dart (Termux's RUN_COMMAND is fire-and-forget - there is no direct
  /// return value from this dispatch, only whatever TermuxResultService
  /// later captures).
  static List<String> checkStatus() => ['-lc', _statusScript];

  /// The last [lines] lines of [setupLogFile] - lets the First Installation
  /// screen show real, live progress from a still-running install/remove
  /// dispatch (`apt-get`/`micromamba create` can genuinely take minutes,
  /// and RUN_COMMAND itself gives no other progress signal - see
  /// [TermuxSetupController.runAndWait]), rather than a bare spinner.
  static List<String> tailLog({int lines = 60}) =>
      ['-lc', 'tail -n $lines $setupLogFile 2>/dev/null || printf "(no setup log yet)"'];

  /// Stage 1: Termux-level only - installs `proot-distro` itself (plus
  /// keeping Termux's own package index current, since a stale index is a
  /// common cause of the later `apt-get`/`proot-distro install` steps
  /// failing with "package not found"). [marker] - see [doneMarker]'s own
  /// doc comment for why a caller polling for completion must pass its own
  /// unique value here rather than relying on the default.
  static List<String> installStage1({String marker = doneMarker}) => ['-lc', _wrapTopLevel(_stage1Body, marker)];

  /// Stage 2: installs the Debian proot itself. Idempotent - skips the
  /// (slow) install if a real login attempt shows it's already there and
  /// bootable (see [_debianLoginCheck]'s own doc comment).
  static List<String> installStage2({String marker = doneMarker}) => ['-lc', _wrapTopLevel(_stage2Body, marker)];

  /// Stage 3: inside Debian - the packages `git`/`curl`/`micromamba`'s own
  /// install step need, which a fresh `proot-distro install debian` doesn't
  /// include by default.
  static List<String> installStage3({String marker = doneMarker}) =>
      ['-lc', _wrapTopLevel(_nestInDebian(_stage3Body), marker)];

  /// Stage 4: inside Debian - installs the static `micromamba` binary to
  /// [micromambaBin]. Deliberately the static binary (arch-detected via
  /// `uname -m`), not the interactive `install.sh`, and installed to a
  /// directory already on a non-interactive shell's default `PATH` (see
  /// [micromambaBin]'s own doc comment) rather than relying on a
  /// `bash -lc` login shell actually sourcing whatever rc file
  /// `install.sh` would otherwise have edited - this is also exactly why
  /// [TermuxCommands]'s own pre-existing start/restart scripts (a bare
  /// `micromamba shell hook`/`micromamba activate`, no path of their own)
  /// work unmodified against whatever this stage installs.
  static List<String> installStage4({String marker = doneMarker}) =>
      ['-lc', _wrapTopLevel(_nestInDebian(_stage4Body), marker)];

  /// Stage 5: inside Debian - clones (or fast-forward-pulls, if already
  /// cloned) this repo to [repoDir], then creates the `didsa` conda env from
  /// `backend/environment.yml` if it doesn't already exist. `-n didsa`
  /// deliberately overrides that file's own internal `name: base` - see
  /// [condaEnv]'s own doc comment in [TermuxCommands] for why the name
  /// actually used here differs from the Dockerfile's.
  static List<String> installStage5({String branch = 'main', String marker = doneMarker}) =>
      ['-lc', _wrapTopLevel(_nestInDebian(_stage5Body(branch)), marker)];

  /// All five stages, `&&`-chained inside one dispatched command - the
  /// screen's "Run all remaining steps" convenience action. Each stage's own
  /// idempotency guard means re-running a stage already completed earlier in
  /// this same chain (or on a previous, partially-successful run) is a
  /// cheap no-op, not a repeated slow install.
  static List<String> installAllRemaining({String branch = 'main', String marker = doneMarker}) => [
        '-lc',
        _wrapTopLevel(
          '$_stage1Body && $_stage2Body && ${_nestInDebian('$_stage3Body\n$_stage4Body\n${_stage5Body(branch)}')}',
          marker,
        ),
      ];

  /// Removes the entire Debian proot in one shot - `micromamba`, the
  /// `didsa` env, and the cloned repo all live inside it, so this alone
  /// undoes every install stage above and brings status back to "nothing
  /// installed". Termux, Termux:API, `proot-distro` itself, and F-Droid are
  /// left alone - Android doesn't let one app silently uninstall another,
  /// and those are the user's own apps to remove if they want.
  static List<String> removeEverything({String marker = doneMarker}) =>
      ['-lc', _wrapTopLevel('proot-distro remove debian --yes', marker)];

  // DEBIAN_FRONTEND=noninteractive plus the explicit --force-confdef/
  // --force-confold dpkg options (not just apt's own -y) are required here
  // - a RUN_COMMAND dispatch has no TTY at all, so an ordinary conffile
  // prompt ("keep the locally modified version?") that -y alone doesn't
  // suppress just hangs forever waiting for input that can never arrive,
  // holding Termux's dpkg lock (`.../dpkg/lock-frontend`) until the
  // dispatch is killed - the actual, confirmed cause of a stuck
  // "Waiting for cache lock" seen running these steps manually alongside
  // an earlier, still-hung dispatch of this same stage.
  static const String _aptNonInteractiveFlags =
      '-o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"';

  static const String _stage1Body =
      'export DEBIAN_FRONTEND=noninteractive\n'
      'pkg update -y '
      '&& pkg upgrade -y $_aptNonInteractiveFlags '
      '&& pkg install -y $_aptNonInteractiveFlags proot-distro';

  // A real login attempt, not text-parsing `proot-distro list` (its table
  // formatting - column widths, a leading marker on the current entry,
  // exact section headers - isn't documented/stable enough to anchor a
  // grep against safely; a leading-whitespace/bullet mismatch there was
  // the actual, confirmed cause of Debian reporting "not installed" here
  // even right after a genuinely successful `proot-distro install debian`,
  // which then also skipped every later stage's own check, all of them
  // nested inside this same "if debianInstalled" guard). `login ... -- true`
  // is authoritative: it only succeeds if Debian is actually installed and
  // bootable, regardless of what the list command's own output looks like.
  static const String _debianLoginCheck = 'proot-distro login debian -- true >/dev/null 2>&1';

  static const String _stage2Body = '$_debianLoginCheck || proot-distro install debian';

  // Same reasoning as _debianLoginCheck above, for the exact same class of
  // bug: `micromamba env list`'s output is a human-formatted table (env
  // names indented, an inactive/active marker column, ...), not stable,
  // documented, machine-readable text - anchoring `grep -q "^didsa "`
  // against it (an earlier version of this class did exactly that, in both
  // this idempotency guard and the status check below) doesn't reliably
  // match, so a genuinely-created env still reported as not-created - a
  // real, confirmed on-device symptom: the checklist never showed the env
  // as created, even long after a manual run had visibly finished creating
  // it successfully. `micromamba run -n <env> python -c "import uvicorn"`
  // is authoritative instead: it only succeeds if the env exists *and* has
  // what this project's backend actually needs, which is the real thing
  // worth confirming here, not merely that some env named "didsa" exists.
  static const String _condaEnvReadyCheck =
      '$micromambaBin run -n $condaEnv python -c "import uvicorn" >/dev/null 2>&1';

  static const String _stage3Body =
      'export DEBIAN_FRONTEND=noninteractive\n'
      'apt-get update && apt-get install -y $_aptNonInteractiveFlags git curl ca-certificates bzip2';

  static const String _stage4Body =
      'set -e\n'
      'mkdir -p /usr/local/bin\n'
      'if [ ! -x $micromambaBin ]; then\n'
      // An earlier version of this class installed to ~/.local/bin instead
      // (not reliably on PATH for a non-interactive shell - see
      // [micromambaBin]'s own doc comment) - reuse it via a move, rather
      // than re-downloading, for anyone who already ran that version.
      '  if [ -x ~/.local/bin/micromamba ]; then\n'
      '    mv ~/.local/bin/micromamba $micromambaBin\n'
      '  else\n'
      '    arch=\$(uname -m)\n'
      '    case "\$arch" in\n'
      '      aarch64) mm_arch=linux-aarch64 ;;\n'
      '      x86_64) mm_arch=linux-64 ;;\n'
      '      *) echo "unsupported architecture: \$arch" >&2; exit 1 ;;\n'
      '    esac\n'
      '    cd /tmp\n'
      '    curl -Ls "https://micro.mamba.pm/api/micromamba/\$mm_arch/latest" | tar -xj bin/micromamba\n'
      '    mv bin/micromamba $micromambaBin\n'
      '  fi\n'
      '  chmod +x $micromambaBin\n'
      'fi\n'
      '$micromambaBin --version';

  static String _stage5Body(String branch) {
    final quotedBranch = _shellQuote(branch);
    return 'set -e\n'
        'if [ -d $repoDir/.git ]; then\n'
        '  git -C $repoDir fetch origin\n'
        '  git -C $repoDir checkout $quotedBranch\n'
        '  git -C $repoDir reset --hard FETCH_HEAD\n'
        'else\n'
        '  git clone --branch $quotedBranch $repoUrl $repoDir\n'
        'fi\n'
        'if ! $_condaEnvReadyCheck; then\n'
        '  $micromambaBin create -n $condaEnv -y -f $backendDir/environment.yml\n'
        'fi';
  }

  static const String _statusInnerBody =
      'mm=false; [ -x $micromambaBin ] && mm=true\n'
      'env=false\n'
      'if [ "\$mm" = true ]; then\n'
      '  $_condaEnvReadyCheck && env=true\n'
      'fi\n'
      'repo=false; [ -d ~/DIDSA-CAD/.git ] && repo=true\n'
      'branch=null\n'
      'if [ "\$repo" = true ]; then\n'
      '  branch=\$(git -C ~/DIDSA-CAD rev-parse --abbrev-ref HEAD 2>/dev/null)\n'
      '  [ -z "\$branch" ] && branch=null\n'
      'fi\n'
      'printf "%s|%s|%s|%s" "\$mm" "\$env" "\$repo" "\$branch"';

  static String get _statusScript =>
      'prootDistroInstalled=false\n'
      'command -v proot-distro >/dev/null 2>&1 && prootDistroInstalled=true\n'
      'debianInstalled=false\n'
      'if [ "\$prootDistroInstalled" = true ]; then\n'
      '  $_debianLoginCheck && debianInstalled=true\n'
      'fi\n'
      'micromambaInstalled=false\n'
      'condaEnvCreated=false\n'
      'repoCloned=false\n'
      'repoBranch=null\n'
      'if [ "\$debianInstalled" = true ]; then\n'
      '  inner=\$(proot-distro login debian -- bash -lc ${_shellQuote(_statusInnerBody)} 2>/dev/null)\n'
      '  micromambaInstalled=\$(printf \'%s\' "\$inner" | cut -d\'|\' -f1)\n'
      '  condaEnvCreated=\$(printf \'%s\' "\$inner" | cut -d\'|\' -f2)\n'
      '  repoCloned=\$(printf \'%s\' "\$inner" | cut -d\'|\' -f3)\n'
      '  repoBranch=\$(printf \'%s\' "\$inner" | cut -d\'|\' -f4)\n'
      'fi\n'
      'printf \'{"prootDistroInstalled":%s,"debianInstalled":%s,"micromambaInstalled":%s,"condaEnvCreated":%s,"repoCloned":%s,"repoBranch":"%s"}\\n\' '
      '"\$prootDistroInstalled" "\$debianInstalled" "\$micromambaInstalled" "\$condaEnvCreated" "\$repoCloned" "\$repoBranch"';

  /// Wraps [script] as `proot-distro login debian -- bash -lc <quoted>` -
  /// the one real nested shell parse in any composite command this class
  /// builds, so [script]'s own values need shell-quoting exactly once, here
  /// (see [_shellQuote]).
  static String _nestInDebian(String script) => 'proot-distro login debian -- bash -lc ${_shellQuote(script)}';

  /// Adds the wake-lock guard (held for the whole dispatched command, always
  /// released via `trap ... EXIT` even on failure) and tees output to
  /// [setupLogFile], the same "confirm via a real check afterward rather
  /// than trusting an exit code" posture [TermuxCommands] already uses for
  /// the server's own start/stop. [marker] - see [doneMarker]'s own doc
  /// comment for why this is a parameter, not always the same constant.
  static String _wrapTopLevel(String body, String marker) =>
      'termux-wake-lock; trap \'termux-wake-unlock\' EXIT\n'
      '{ $body ; echo $marker ; } 2>&1 | tee -a $setupLogFile';

  /// Standard POSIX single-quote escaping - identical to
  /// [TermuxCommands]'s own private helper of the same name and already
  /// verified against real bash there.
  static String _shellQuote(String value) => "'${value.replaceAll("'", r"'\''")}'";
}
