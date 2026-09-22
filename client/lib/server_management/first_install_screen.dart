import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'termux_commands.dart';
import 'termux_controller.dart';
import 'termux_setup_commands.dart';
import 'termux_setup_controller.dart';
import 'termux_urls.dart';

/// Guides a brand-new device from "just installed the DIDSA app" to "the
/// Server Management screen's buttons work" - installing F-Droid, Termux
/// and Termux:API, walking through the one step that genuinely can't be
/// automated (`allow-external-apps` in `~/.termux/termux.properties`, which
/// gates every later Termux-side automation), then either dispatching or
/// offering to copy/paste the shell commands that install `proot-distro`'s
/// Debian, `micromamba`, the `didsa` conda env (see
/// `backend/environment.yml`), and a clone of this repo.
///
/// Reachable from [ServerManagementScreen] - that screen assumes all of the
/// above already exists; this is what actually gets a new device there.
class FirstInstallScreen extends StatefulWidget {
  const FirstInstallScreen({super.key});

  @override
  State<FirstInstallScreen> createState() => _FirstInstallScreenState();
}

class _FirstInstallScreenState extends State<FirstInstallScreen> {
  final _termuxController = TermuxController();
  final _setupController = TermuxSetupController();
  final _branchController = TextEditingController(text: 'main');

  bool? _termuxInstalled;
  bool? _termuxApiInstalled;
  bool? _hasPermission;
  bool _checkingStatus = true;
  SetupStatus _status = SetupStatus.unknown;
  bool _busy = false;
  String? _statusMessage;

  @override
  void initState() {
    super.initState();
    _branchController.addListener(() => setState(() {}));
    _refreshAll();
  }

  @override
  void dispose() {
    _branchController.dispose();
    _termuxController.dispose();
    super.dispose();
  }

  bool get _branchValid => TermuxCommands.isValidBranchName(_branchController.text.trim());

  Future<void> _refreshAll() async {
    setState(() => _checkingStatus = true);
    final termuxInstalled = await _setupController.isTermuxInstalled();
    final termuxApiInstalled = await _setupController.isTermuxApiInstalled();
    final hasPermission = await _termuxController.hasPermission();
    // The Termux-side status probe only has anything to find once the app
    // can actually dispatch to it - skipping it otherwise avoids a pointless
    // ~15s poll-to-timeout on every screen open before permission exists.
    final status = hasPermission ? await _setupController.checkSetupStatus() : SetupStatus.unknown;
    // Android accepting a dispatch (the permission check above) doesn't
    // mean Termux itself ran it - e.g. `allow-external-apps` still being
    // false in termux.properties makes Termux refuse it outright, with its
    // own specific reason attached to the result. Surface that reason
    // directly instead of only ever showing a bare "status unknown".
    final lastError = hasPermission ? await _setupController.lastCommandError() : null;
    if (!mounted) return;
    setState(() {
      _termuxInstalled = termuxInstalled;
      _termuxApiInstalled = termuxApiInstalled;
      _hasPermission = hasPermission;
      _status = status;
      _checkingStatus = false;
      if (lastError != null) _statusMessage = lastError;
    });
  }

  Future<void> _grantPermission() async {
    setState(() => _busy = true);
    final granted = await _termuxController.requestPermission();
    if (!mounted) return;
    setState(() {
      _hasPermission = granted;
      _busy = false;
    });
    if (granted) unawaited(_refreshAll());
  }

  Future<void> _run(String label, List<String> Function(String marker) buildArguments, {Duration? maxWait}) async {
    setState(() {
      _busy = true;
      _statusMessage = '$label - sent to Termux, waiting for it to start...';
    });
    // Setup stages can genuinely take minutes (apt-get, a multi-hundred-MB
    // pythonocc-core download under proot's ptrace overhead) - runAndWait
    // polls the live setup log every few seconds so this shows real
    // progress instead of just a spinner, and only reports done once a
    // real status check confirms it, not just the dispatch finishing.
    final result = await _setupController.runAndWait(
      buildArguments,
      onProgress: (tail) {
        if (!mounted) return;
        setState(() => _statusMessage = '$label - still running...\n\n$tail');
      },
      maxWait: maxWait ?? const Duration(minutes: 10),
    );
    if (!mounted) return;
    // Android accepting the dispatch (result.dispatched) only means it
    // handed the intent to Termux, not that Termux actually ran it - e.g.
    // `allow-external-apps` still being false makes Termux refuse it
    // outright, with its own specific reason attached. Without this check,
    // that refusal would otherwise show as a misleading "done".
    final lastError = result.dispatched ? await _setupController.lastCommandError() : null;
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = result.status;
      _statusMessage = !result.dispatched
          ? '$label - could not reach Termux. Check the permission in Step 3.'
          : lastError != null
              ? '$label - $lastError'
              : '$label - done. See the checklist above for the current state.';
    });
    // runAndWait's own final check can race a still-settling filesystem
    // (a git clone/conda env registration that only just finished writing)
    // or simply give up at maxWait while the dispatched script is still
    // genuinely running in the background - a full, independent refresh
    // (not just trusting that one snapshot) is what actually keeps the
    // checklist above honest without the user having to tap Recheck
    // themselves every time.
    unawaited(_refreshAll());
  }

  Future<void> _removeEverything() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove everything?'),
        content: const Text(
          'This deletes the entire Debian environment - micromamba, the didsa conda env, and the '
          'cloned repo all go with it. Termux, Termux:API and F-Droid themselves are left installed. '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove everything'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _run('Remove everything', (marker) => TermuxSetupCommands.removeEverything(marker: marker));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('First-Time Setup')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Sets up an on-device backend under Termux - no separate server needed. Complete each step '
            'in order; later steps stay disabled until earlier ones are done.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          _StatusSummary(checking: _checkingStatus, status: _status, onRefresh: _refreshAll),
          const SizedBox(height: 24),
          _StepCard(
            number: '1',
            title: 'Install F-Droid',
            children: [
              Text(
                'Termux is no longer available on the Play Store - install it from F-Droid instead.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => launchUrl(Uri.parse(TermuxUrls.fdroid), mode: LaunchMode.externalApplication),
                icon: const Icon(Icons.open_in_new),
                label: const Text('Open F-Droid'),
              ),
            ],
          ),
          _StepCard(
            number: '2',
            title: 'Install Termux and Termux:API',
            children: [
              _CheckRow(label: 'Termux installed', value: _termuxInstalled),
              OutlinedButton.icon(
                onPressed: () => launchUrl(Uri.parse(TermuxUrls.termux), mode: LaunchMode.externalApplication),
                icon: const Icon(Icons.open_in_new),
                label: const Text('Open Termux on F-Droid'),
              ),
              const SizedBox(height: 8),
              _CheckRow(label: 'Termux:API installed', value: _termuxApiInstalled),
              OutlinedButton.icon(
                onPressed: () => launchUrl(Uri.parse(TermuxUrls.termuxApi), mode: LaunchMode.externalApplication),
                icon: const Icon(Icons.open_in_new),
                label: const Text('Open Termux:API on F-Droid'),
              ),
            ],
          ),
          _StepCard(
            number: '3',
            title: 'Allow external apps, then grant permission',
            children: [
              Text(
                'Open Termux and paste this to edit its properties file:',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const _CopyBlock('nano ~/.termux/termux.properties'),
              Text(
                'Find the line "# allow-external-apps = true", delete the leading "# " so it reads '
                '"allow-external-apps = true", then save and exit (Ctrl+O, Enter, Ctrl+X) and run:',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const _CopyBlock('termux-reload-settings'),
              Text('...then fully close and reopen Termux.', style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 8),
              Text(
                'Or paste this single line instead - it does the same edit without opening an editor:',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const _CopyBlock(
                'mkdir -p ~/.termux && touch ~/.termux/termux.properties && '
                "sed -i 's/^# *allow-external-apps *= *true/allow-external-apps = true/' "
                '~/.termux/termux.properties && grep -q "^allow-external-apps" '
                "~/.termux/termux.properties || printf '\\nallow-external-apps = true\\n' "
                '>> ~/.termux/termux.properties; termux-reload-settings',
              ),
              const SizedBox(height: 12),
              _CheckRow(label: 'DIDSA can dispatch commands to Termux', value: _hasPermission),
              FilledButton.icon(
                onPressed: _busy ? null : _grantPermission,
                icon: const Icon(Icons.security),
                label: const Text('Grant Termux permission'),
              ),
            ],
          ),
          _StepCard(
            number: '4',
            title: 'Install the backend environment',
            children: [
              TextField(
                controller: _branchController,
                decoration: InputDecoration(
                  labelText: 'Branch to clone',
                  border: const OutlineInputBorder(),
                  errorText: _branchController.text.isEmpty || _branchValid ? null : 'Invalid branch name',
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: (_hasPermission ?? false) && !_busy && _branchValid
                    ? () => _run(
                          'Run all remaining steps',
                          (marker) => TermuxSetupCommands.installAllRemaining(
                            branch: _branchController.text.trim(),
                            marker: marker,
                          ),
                          // Includes creating the didsa conda env, by far the
                          // slowest single step here (pythonocc-core is a
                          // large compiled geometry kernel) - the default
                          // 10-minute wait can be too short over a slow
                          // connection, which otherwise looks like this step
                          // "finished" when it's actually still downloading.
                          maxWait: const Duration(minutes: 25),
                        )
                    : null,
                icon: const Icon(Icons.rocket_launch),
                label: const Text('Run all remaining steps'),
              ),
              const SizedBox(height: 12),
              Text(
                "Don't paste these commands manually into Termux at the same time as tapping Run - "
                'running the same install twice at once can leave one copy stuck waiting for a lock the '
                'other is holding (e.g. "Waiting for cache lock").',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic),
              ),
              const SizedBox(height: 8),
              _StageRow(
                label: 'Install proot-distro',
                done: _status.prootDistroInstalled,
                enabled: (_hasPermission ?? false) && !_busy,
                onRun: () => _run('Install proot-distro', (marker) => TermuxSetupCommands.installStage1(marker: marker)),
                copyText: TermuxSetupCommands.installStage1().last,
              ),
              _StageRow(
                label: 'Install Debian (proot-distro)',
                done: _status.debianInstalled,
                enabled: (_hasPermission ?? false) && !_busy,
                onRun: () => _run('Install Debian', (marker) => TermuxSetupCommands.installStage2(marker: marker)),
                copyText: TermuxSetupCommands.installStage2().last,
              ),
              _StageRow(
                label: 'Install Debian packages (git, curl, ...)',
                done: _status.debianInstalled,
                enabled: (_hasPermission ?? false) && !_busy,
                onRun: () =>
                    _run('Install Debian packages', (marker) => TermuxSetupCommands.installStage3(marker: marker)),
                copyText: TermuxSetupCommands.installStage3().last,
              ),
              _StageRow(
                label: 'Install micromamba',
                done: _status.micromambaInstalled,
                enabled: (_hasPermission ?? false) && !_busy,
                onRun: () => _run('Install micromamba', (marker) => TermuxSetupCommands.installStage4(marker: marker)),
                copyText: TermuxSetupCommands.installStage4().last,
              ),
              _StageRow(
                label: 'Clone repo and create the didsa environment',
                done: _status.condaEnvCreated && _status.repoCloned,
                enabled: (_hasPermission ?? false) && !_busy && _branchValid,
                onRun: () => _run(
                  'Clone repo and create environment',
                  (marker) => TermuxSetupCommands.installStage5(branch: _branchController.text.trim(), marker: marker),
                  // See "Run all remaining steps"'s own comment - this is
                  // the same slow conda-env-creation step on its own.
                  maxWait: const Duration(minutes: 25),
                ),
                copyText: TermuxSetupCommands.installStage5(branch: _branchController.text.trim()).last,
              ),
            ],
          ),
          const SizedBox(height: 24),
          if (_statusMessage != null)
            Container(
              padding: const EdgeInsets.all(12),
              constraints: const BoxConstraints(maxHeight: 260),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_busy)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 8),
                      child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                    ),
                  // Scrollable and monospace - once a stage is running,
                  // this holds live tail output from ~/didsa-setup.log
                  // (see TermuxSetupController.runAndWait), which can run
                  // to many lines over a multi-minute install.
                  Flexible(
                    child: SingleChildScrollView(
                      child: SelectableText(
                        _statusMessage!,
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Unwind this device',
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(color: Theme.of(context).colorScheme.onErrorContainer),
                ),
                const SizedBox(height: 4),
                Text(
                  'Removes the whole Debian environment (micromamba, the didsa env, and the cloned repo) '
                  'in one go, so this device is back to step 4 above.',
                  style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: (_hasPermission ?? false) && !_busy ? _removeEverything : null,
                  style: OutlinedButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
                  icon: const Icon(Icons.delete_forever),
                  label: const Text('Remove everything'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusSummary extends StatelessWidget {
  const _StatusSummary({required this.checking, required this.status, required this.onRefresh});

  final bool checking;
  final SetupStatus status;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('Device status', style: Theme.of(context).textTheme.titleSmall)),
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'Recheck status',
                onPressed: checking ? null : onRefresh,
              ),
            ],
          ),
          if (checking)
            const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: LinearProgressIndicator())
          else ...[
            _CheckRow(label: 'proot-distro installed', value: status.prootDistroInstalled),
            _CheckRow(label: 'Debian installed', value: status.debianInstalled),
            _CheckRow(label: 'micromamba installed', value: status.micromambaInstalled),
            _CheckRow(label: 'didsa conda env created', value: status.condaEnvCreated),
            _CheckRow(
              label: status.repoBranch != null ? 'Repo cloned (branch: ${status.repoBranch})' : 'Repo cloned',
              value: status.repoCloned,
            ),
          ],
        ],
      ),
    );
  }
}

class _CheckRow extends StatelessWidget {
  const _CheckRow({required this.label, required this.value});

  final String label;
  final bool? value;

  @override
  Widget build(BuildContext context) {
    final (IconData icon, Color color) = switch (value) {
      true => (Icons.check_circle, Colors.green),
      false => (Icons.cancel_outlined, Colors.red),
      null => (Icons.help_outline, Colors.grey),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(label, style: Theme.of(context).textTheme.bodySmall)),
        ],
      ),
    );
  }
}

class _StepCard extends StatelessWidget {
  const _StepCard({required this.number, required this.title, required this.children});

  final String number;
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(radius: 12, child: Text(number, style: const TextStyle(fontSize: 12))),
                const SizedBox(width: 8),
                Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
              ],
            ),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// A monospace block of shell text with a copy-to-clipboard button - for
/// pasting into Termux by hand, as an alternative to the dispatched-command
/// buttons elsewhere on this screen.
class _CopyBlock extends StatelessWidget {
  const _CopyBlock(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: SelectableText(text, style: const TextStyle(fontFamily: 'monospace', fontSize: 12))),
            IconButton(
              icon: const Icon(Icons.copy, size: 18),
              tooltip: 'Copy',
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: text));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied')));
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// One installable stage in Step 4 - a status check, a "Run" button that
/// dispatches it directly, and a copyable fallback for pasting into Termux
/// by hand (per this feature's own requirement to offer both, not just one).
class _StageRow extends StatelessWidget {
  const _StageRow({required this.label, required this.done, required this.enabled, required this.onRun, required this.copyText});

  final String label;
  final bool done;
  final bool enabled;
  final VoidCallback onRun;
  final String copyText;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(done ? Icons.check_circle : Icons.radio_button_unchecked, size: 18, color: done ? Colors.green : Colors.grey),
              const SizedBox(width: 8),
              Expanded(child: Text(label, style: Theme.of(context).textTheme.bodyMedium)),
              TextButton(onPressed: enabled ? onRun : null, child: const Text('Run')),
            ],
          ),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text('Or copy the command', style: Theme.of(context).textTheme.bodySmall),
            children: [_CopyBlock(copyText)],
          ),
        ],
      ),
    );
  }
}
