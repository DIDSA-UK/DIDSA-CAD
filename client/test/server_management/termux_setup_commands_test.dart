import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/server_management/termux_setup_commands.dart';

/// Pure string-building logic, so these run with no platform channel, no
/// device, no Termux - same rationale as termux_commands_test.dart.
void main() {
  group('TermuxSetupCommands executable/argv shape', () {
    test('every command runs via bash -lc, not proot-distro directly', () {
      for (final argv in [
        TermuxSetupCommands.checkStatus(),
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
      expect(script, contains('pkg install -y proot-distro'));
      expect(script, contains('termux-wake-lock'));
      expect(script, contains("trap 'termux-wake-unlock' EXIT"));
    });

    test('stage 2 installs debian only if not already installed', () {
      final script = TermuxSetupCommands.installStage2().last;
      expect(script, contains('proot-distro list'));
      expect(script, contains('proot-distro install debian'));
      expect(script, contains('||'));
    });

    test('stage 3 runs apt-get inside debian via a nested proot-distro login', () {
      final script = TermuxSetupCommands.installStage3().last;
      expect(script, contains('proot-distro login debian -- bash -lc'));
      expect(script, contains('apt-get install -y git curl ca-certificates bzip2'));
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

    test('stage 5 clones the given branch when the repo is not yet cloned', () {
      final script = TermuxSetupCommands.installStage5(branch: 'claude/foo').last;
      expect(script, contains("git clone --branch 'claude/foo'"));
      expect(script, contains('~/DIDSA-CAD'));
    });

    test('stage 5 updates in place (fetch + checkout + hard reset) when already cloned', () {
      final script = TermuxSetupCommands.installStage5(branch: 'main').last;
      expect(script, contains('git -C ~/DIDSA-CAD fetch origin'));
      expect(script, contains("git -C ~/DIDSA-CAD checkout 'main'"));
      expect(script, contains('git -C ~/DIDSA-CAD reset --hard FETCH_HEAD'));
    });

    test('stage 5 single-quote-escapes a branch name containing a literal quote', () {
      final script = TermuxSetupCommands.installStage5(branch: "o'brien").last;
      expect(script, contains(r"'o'\''brien'"));
    });

    test('stage 5 creates the didsa env (overriding environment.yml\'s own "base" name) only if missing', () {
      final script = TermuxSetupCommands.installStage5().last;
      expect(script, contains('micromamba env list'));
      expect(script, contains('grep -q "^didsa "'));
      expect(script, contains('micromamba create -n didsa -y -f ~/DIDSA-CAD/backend/environment.yml'));
    });

    test('installAllRemaining chains every stage in order inside one dispatched command', () {
      final script = TermuxSetupCommands.installAllRemaining(branch: 'main').last;
      final stage1 = script.indexOf('pkg install -y proot-distro');
      final stage2 = script.indexOf('proot-distro install debian');
      final stage3 = script.indexOf('apt-get install -y git curl');
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
  });
}
