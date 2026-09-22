import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/server_management/termux_setup_commands.dart';

/// Pure string-building logic, so these run with no platform channel, no
/// device, no Termux - same rationale as termux_commands_test.dart.
void main() {
  group('TermuxSetupCommands executable/argv shape', () {
    test('every command runs via bash -lc, not proot-distro directly', () {
      for (final argv in [
        TermuxSetupCommands.checkStatus(),
        TermuxSetupCommands.tailLog(),
        TermuxSetupCommands.installStage1(),
        TermuxSetupCommands.installStage2(),
        TermuxSetupCommands.installStage3(),
        TermuxSetupCommands.installStage4(),
        TermuxSetupCommands.installStage5(),
        TermuxSetupCommands.installAllRemaining(),
        TermuxSetupCommands.removeEverything(),
      ]) {
        expect(argv.length, 2);
        expect(argv.first, '-lc');
      }
      expect(TermuxSetupCommands.executable, isNot(contains('proot-distro')));
      expect(TermuxSetupCommands.executable, contains('/bash'));
    });

    test('tailLog reads the last lines of the setup log, falling back if it does not exist yet', () {
      final script = TermuxSetupCommands.tailLog().last;
      expect(script, contains('tail -n'));
      expect(script, contains(TermuxSetupCommands.setupLogFile));
      expect(script, contains('||'));
    });

    test('checkStatus does not itself hold a wake lock - it is quick, unlike the install stages', () {
      final script = TermuxSetupCommands.checkStatus().last;
      expect(script, isNot(contains('termux-wake-lock')));
      expect(script, contains('proot-distro list'));
      expect(script, contains('prootDistroInstalled'));
    });

    test('checkStatus only probes inside Debian when debianInstalled is true', () {
      final script = TermuxSetupCommands.checkStatus().last;
      final guardIndex = script.indexOf('if [ "\$debianInstalled" = true ]');
      final loginIndex = script.indexOf('proot-distro login debian');
      expect(guardIndex, greaterThanOrEqualTo(0));
      expect(loginIndex, greaterThan(guardIndex));
    });

    test('checkStatus prints exactly one JSON object with every expected field', () {
      final script = TermuxSetupCommands.checkStatus().last;
      for (final field in [
        'prootDistroInstalled',
        'debianInstalled',
        'micromambaInstalled',
        'condaEnvCreated',
        'repoCloned',
        'repoBranch',
      ]) {
        expect(script, contains('"$field"'));
      }
    });
  });

  group('install stages', () {
    test('stage 1 installs proot-distro at the Termux level', () {
      final script = TermuxSetupCommands.installStage1().last;
      expect(script, contains('pkg install -y'));
      expect(script, contains('proot-distro'));
      expect(script, contains('termux-wake-lock'));
      expect(script, contains("trap 'termux-wake-unlock' EXIT"));
    });

    test('stage 1 update/upgrade/install are all non-interactive, so a conffile prompt cannot hang '
        'forever with no TTY to answer it (the confirmed cause of a stuck dpkg lock)', () {
      final script = TermuxSetupCommands.installStage1().last;
      expect(script, contains('DEBIAN_FRONTEND=noninteractive'));
      expect(script, contains('--force-confdef'));
      expect(script, contains('--force-confold'));
      expect(script, contains('pkg upgrade -y'));
    });

    test('stage 2 installs debian only if not already installed', () {
      final script = TermuxSetupCommands.installStage2().last;
      expect(script, contains('proot-distro list'));
      expect(script, contains('proot-distro install debian'));
      expect(script, contains('||'));
    });

    test('stage 3 runs apt-get inside debian via a nested proot-distro login, non-interactively', () {
      final script = TermuxSetupCommands.installStage3().last;
      expect(script, contains('proot-distro login debian -- bash -lc'));
      expect(script, contains('apt-get install -y'));
      expect(script, contains('git curl ca-certificates bzip2'));
      expect(script, contains('DEBIAN_FRONTEND=noninteractive'));
    });

    test('stage 4 installs the static micromamba binary, arch-detected, to a fixed path', () {
      final script = TermuxSetupCommands.installStage4().last;
      expect(script, contains('uname -m'));
      expect(script, contains('linux-aarch64'));
      expect(script, contains('linux-64'));
      expect(script, contains('micro.mamba.pm/api/micromamba'));
      expect(script, contains('~/.local/bin/micromamba'));
    });

    test('stage 4 skips the download if micromamba is already installed', () {
      final script = TermuxSetupCommands.installStage4().last;
      expect(script, contains('if [ ! -x'));
    });

    // installStage5's output is quoted *twice*: once for the branch name
    // itself (embedded as a literal 'branch' argument to git), then again
    // because _nestInDebian shell-quotes the *whole* stage-5 script as the
    // argument to the nested `proot-distro login debian -- bash -lc`
    // invocation. So a bare `'claude/foo'` never appears verbatim in the
    // dispatched text - the branch's own quote characters get re-escaped
    // for that second, outer quoting layer, same as everything else in the
    // body that happens to contain a literal `'`. The surrounding text
    // (which has no quote characters of its own) passes through unchanged.

    test('stage 5 clones the given branch when the repo is not yet cloned', () {
      final script = TermuxSetupCommands.installStage5(branch: 'claude/foo').last;
      expect(script, contains('git clone --branch'));
      expect(script, contains('claude/foo'));
      expect(script, contains('https://github.com/DIDSA-UK/DIDSA-CAD.git ~/DIDSA-CAD'));
    });

    test('stage 5 updates in place (fetch + checkout + hard reset) when already cloned', () {
      final script = TermuxSetupCommands.installStage5(branch: 'main').last;
      expect(script, contains('git -C ~/DIDSA-CAD fetch origin'));
      expect(script, contains('git -C ~/DIDSA-CAD checkout'));
      expect(script, contains('git -C ~/DIDSA-CAD reset --hard FETCH_HEAD'));
    });

    test('stage 5 single-quote-escapes a branch name containing a literal quote', () {
      final script = TermuxSetupCommands.installStage5(branch: "o'brien").last;
      // Computed via the same standard POSIX escape applied twice (once for
      // the branch itself, once more for the outer nested-shell layer),
      // rather than hand-derived - see this group's own doc comment above.
      String shellQuote(String value) => "'${value.replaceAll("'", r"'\''")}'";
      final onceQuoted = shellQuote("o'brien");
      final twiceQuoted = shellQuote(onceQuoted);
      final expectedInner = twiceQuoted.substring(1, twiceQuoted.length - 1);
      expect(script, contains(expectedInner));
      // The raw, unescaped "o'brien" must never appear as a bare,
      // contiguous run - if it did, the branch's own quote would have
      // broken out of the surrounding shell string instead of staying
      // escaped, i.e. a real shell-injection bug.
      expect(script, isNot(contains("o'brien")));
    });

    test('stage 5 creates the didsa env (overriding environment.yml\'s own "base" name) only if missing', () {
      final script = TermuxSetupCommands.installStage5().last;
      expect(script, contains('micromamba env list'));
      expect(script, contains('grep -q "^didsa "'));
      expect(script, contains('micromamba create -n didsa -y -f ~/DIDSA-CAD/backend/environment.yml'));
    });

    test('installAllRemaining chains every stage in order inside one dispatched command', () {
      final script = TermuxSetupCommands.installAllRemaining(branch: 'main').last;
      final stage1 = script.indexOf('pkg install -y');
      final stage2 = script.indexOf('proot-distro install debian');
      final stage3 = script.indexOf('apt-get install -y');
      final stage4 = script.indexOf('micro.mamba.pm/api/micromamba');
      final stage5 = script.indexOf('micromamba create -n didsa');
      for (final index in [stage1, stage2, stage3, stage4, stage5]) {
        expect(index, greaterThanOrEqualTo(0));
      }
      expect(stage2, greaterThan(stage1));
      expect(stage3, greaterThan(stage2));
      expect(stage4, greaterThan(stage3));
      expect(stage5, greaterThan(stage4));
    });
  });

  group('removeEverything', () {
    test('removes the whole debian proot in one shot', () {
      final script = TermuxSetupCommands.removeEverything().last;
      expect(script, contains('proot-distro remove debian'));
    });
  });

  group('every install/remove stage holds a wake lock for its whole duration', () {
    test('wake-lock is acquired up front and always released via a trap, not just at the end', () {
      for (final argv in [
        TermuxSetupCommands.installStage1(),
        TermuxSetupCommands.installStage2(),
        TermuxSetupCommands.installStage3(),
        TermuxSetupCommands.installStage4(),
        TermuxSetupCommands.installStage5(),
        TermuxSetupCommands.installAllRemaining(),
        TermuxSetupCommands.removeEverything(),
      ]) {
        final script = argv.last;
        expect(script, contains('termux-wake-lock'));
        expect(script, contains("trap 'termux-wake-unlock' EXIT"));
        expect(script, contains(TermuxSetupCommands.setupLogFile));
      }
    });

    test('echoes the done marker to the log at the end regardless of success or failure', () {
      // Unconditional (";", not "&&") so it fires even if the body failed -
      // it only ever means "the dispatched script reached its end", not
      // "succeeded" (actual success is still confirmed by a real status
      // check - see TermuxSetupController.runAndWait's own doc comment).
      for (final argv in [
        TermuxSetupCommands.installStage1(),
        TermuxSetupCommands.installStage2(),
        TermuxSetupCommands.installStage3(),
        TermuxSetupCommands.installStage4(),
        TermuxSetupCommands.installStage5(),
        TermuxSetupCommands.installAllRemaining(),
        TermuxSetupCommands.removeEverything(),
      ]) {
        final script = argv.last;
        expect(script, contains('echo ${TermuxSetupCommands.doneMarker}'));
      }
      // checkStatus/tailLog are quick, single reads, not install/remove
      // scripts - they don't hold a wake lock or emit the marker at all.
      expect(TermuxSetupCommands.checkStatus().last, isNot(contains(TermuxSetupCommands.doneMarker)));
      expect(TermuxSetupCommands.tailLog().last, isNot(contains(TermuxSetupCommands.doneMarker)));
    });
  });
}
