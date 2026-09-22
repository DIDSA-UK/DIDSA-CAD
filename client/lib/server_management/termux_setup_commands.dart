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

  static const String micromambaBin = '~/.local/bin/micromamba';
  static const String setupLogFile = '~/didsa-setup.log';
  static const String repoUrl = 'https://github.com/DIDSA-UK/DIDSA-CAD.git';

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

  /// Stage 1: Termux-level only - installs `proot-distro` itself (plus
  /// keeping Termux's own package index current, since a stale index is a
  /// common cause of the later `apt-get`/`proot-distro install` steps
  /// failing with "package not found").
  static List<String> installStage1() => ['-lc', _wrapTopLevel(_stage1Body)];

  /// Stage 2: installs the Debian proot itself. Idempotent - skips the
  /// (slow) install if `proot-distro list` already shows it.
  static List<String> installStage2() => ['-lc', _wrapTopLevel(_stage2Body)];

  /// Stage 3: inside Debian - the packages `git`/`curl`/`micromamba`'s own
  /// install step need, which a fresh `proot-distro install debian` doesn't
  /// include by default.
  static List<String> installStage3() => ['-lc', _wrapTopLevel(_nestInDebian(_stage3Body))];

  /// Stage 4: inside Debian - installs the static `micromamba` binary to
  /// [micromambaBin]. Deliberately the static binary (arch-detected via
  /// `uname -m`), not the interactive `install.sh`, and always referenced
  /// by this fixed full path elsewhere in this class (and in
  /// [TermuxCommands]'s own start/restart scripts would need updating to
  /// match) rather than relying on a `bash -lc` login shell actually
  /// sourcing whatever rc file `install.sh` would otherwise have edited.
  static List<String> installStage4() => ['-lc', _wrapTopLevel(_nestInDebian(_stage4Body))];

  /// Stage 5: inside Debian - clones (or fast-forward-pulls, if already
  /// cloned) this repo to [repoDir], then creates the `didsa` conda env from
  /// `backend/environment.yml` if it doesn't already exist. `-n didsa`
  /// deliberately overrides that file's own internal `name: base` - see
  /// [condaEnv]'s own doc comment in [TermuxCommands] for why the name
  /// actually used here differs from the Dockerfile's.
  static List<String> installStage5({String branch = 'main'}) =>
      ['-lc', _wrapTopLevel(_nestInDebian(_stage5Body(branch)))];

  /// All five stages, `&&`-chained inside one dispatched command - the
  /// screen's "Run all remaining steps" convenience action. Each stage's own
  /// idempotency guard means re-running a stage already completed earlier in
  /// this same chain (or on a previous, partially-successful run) is a
  /// cheap no-op, not a repeated slow install.
  static List<String> installAllRemaining({String branch = 'main'}) => [
        '-lc',
        _wrapTopLevel('$_stage1Body && $_stage2Body && ${_nestInDebian('$_stage3Body\n${_stage4Body}\n${_stage5Body(branch)}')}'),
      ];

  /// Removes the entire Debian proot in one shot - `micromamba`, the
  /// `didsa` env, and the cloned repo all live inside it, so this alone
  /// undoes every install stage above and brings status back to "nothing
  /// installed". Termux, Termux:API, `proot-distro` itself, and F-Droid are
  /// left alone - Android doesn't let one app silently uninstall another,
  /// and those are the user's own apps to remove if they want.
  static List<String> removeEverything() => ['-lc', _wrapTopLevel('proot-distro remove debian --yes')];

  static const String _stage1Body = 'pkg update -y && pkg upgrade -y && pkg install -y proot-distro';

  static const String _stage2Body = 'proot-distro list 2>/dev/null | grep -q "^debian" || proot-distro install debian';

  static const String _stage3Body =
      'export DEBIAN_FRONTEND=noninteractive\n'
      'apt-get update && apt-get install -y git curl ca-certificates bzip2';

  static const String _stage4Body =
      'set -e\n'
      'mkdir -p ~/.local/bin\n'
      'if [ ! -x $micromambaBin ]; then\n'
      '  arch=\$(uname -m)\n'
      '  case "\$arch" in\n'
      '    aarch64) mm_arch=linux-aarch64 ;;\n'
      '    x86_64) mm_arch=linux-64 ;;\n'
      '    *) echo "unsupported architecture: \$arch" >&2; exit 1 ;;\n'
      '  esac\n'
      '  cd /tmp\n'
      '  curl -Ls "https://micro.mamba.pm/api/micromamba/\$mm_arch/latest" | tar -xj bin/micromamba\n'
      '  mv bin/micromamba $micromambaBin\n'
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
        'if ! $micromambaBin env list 2>/dev/null | grep -q "^$condaEnv "; then\n'
        '  $micromambaBin create -n $condaEnv -y -f $backendDir/environment.yml\n'
        'fi';
  }

  static const String _statusInnerBody =
      'mm=false; [ -x ~/.local/bin/micromamba ] && mm=true\n'
      'env=false\n'
      'if [ "\$mm" = true ]; then\n'
      '  ~/.local/bin/micromamba env list 2>/dev/null | grep -q "^didsa " && env=true\n'
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
      '  proot-distro list 2>/dev/null | grep -q "^debian" && debianInstalled=true\n'
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
  /// the server's own start/stop.
  static String _wrapTopLevel(String body) =>
      'termux-wake-lock; trap \'termux-wake-unlock\' EXIT\n'
      '{ $body ; } 2>&1 | tee -a $setupLogFile';

  /// Standard POSIX single-quote escaping - identical to
  /// [TermuxCommands]'s own private helper of the same name and already
  /// verified against real bash there.
  static String _shellQuote(String value) => "'${value.replaceAll("'", r"'\''")}'";
}
