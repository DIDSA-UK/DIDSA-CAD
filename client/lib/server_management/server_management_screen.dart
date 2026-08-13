import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import 'termux_commands.dart';
import 'termux_controller.dart';

/// Lets the user control an on-device standalone backend (Termux +
/// proot-distro, see this project's own setup discussion) from inside the
/// app itself, via Termux's RUN_COMMAND intent - "which branch am I
/// testing", "pull it", "start/stop/restart the server", plus a real
/// /health check to confirm what actually happened, rather than trusting
/// that a dispatched command succeeded.
///
/// Reachable from [ConnectionScreen] - the natural home for anything about
/// where the backend the client talks to actually comes from.
class ServerManagementScreen extends StatefulWidget {
  const ServerManagementScreen({super.key});

  @override
  State<ServerManagementScreen> createState() => _ServerManagementScreenState();
}

class _ServerManagementScreenState extends State<ServerManagementScreen> {
  final _branchController = TextEditingController(text: 'main');
  final _controller = TermuxController();

  bool? _hasPermission;
  bool _busy = false;
  String? _statusMessage;
  ServerReachability _reachability = ServerReachability.unknown;

  // The top status pane's own state - independent of _reachability/
  // _statusMessage below, which track the result of a dispatched action
  // rather than "what's true on entering this screen".
  bool _checkingLiveStatus = true;
  ServerStatus _liveStatus = const ServerStatus(reachability: ServerReachability.unknown);

  @override
  void initState() {
    super.initState();
    _branchController.addListener(() => setState(() {}));
    _refreshPermission();
    _refreshLiveStatus();
  }

  @override
  void dispose() {
    _branchController.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _refreshPermission() async {
    final granted = await _controller.hasPermission();
    if (!mounted) return;
    setState(() => _hasPermission = granted);
  }

  Future<void> _refreshLiveStatus() async {
    setState(() => _checkingLiveStatus = true);
    final status = await _controller.checkStatus();
    if (!mounted) return;
    setState(() {
      _checkingLiveStatus = false;
      _liveStatus = status;
    });
  }

  Future<void> _grantPermission() async {
    setState(() => _busy = true);
    final granted = await _controller.requestPermission();
    if (!mounted) return;
    setState(() {
      _hasPermission = granted;
      _busy = false;
    });
  }

  bool get _branchValid => TermuxCommands.isValidBranchName(_branchController.text.trim());

  static const String _localAddress = TermuxController.localBaseUrl;

  Future<void> _run(String label, Future<bool> Function() dispatch, {ServerReachability? expect}) async {
    setState(() {
      _busy = true;
      _statusMessage = '$label - sent to Termux, waiting...';
    });
    final dispatched = await dispatch();
    if (!dispatched) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _statusMessage =
            '$label - could not reach Termux. Check the permission above, and that Termux (with Termux:API and '
            "allow-external-apps=true) is installed.";
      });
      return;
    }
    final result = expect == null
        ? await _controller.check()
        : await _controller.pollUntil(expect: expect);
    // On anything other than a clean success, also fetch whatever Termux
    // actually reported back for this dispatch (see TermuxResultService's
    // own doc comment) - a /health timeout alone doesn't say *why*, and the
    // raw result (or the lack of one) is the most direct diagnostic
    // available without a device debugger attached.
    final lastResult = result == ServerReachability.reachable ? null : await _controller.getLastCommandResult();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _reachability = result;
      _statusMessage = switch (result) {
        ServerReachability.reachable => '$label - server responding at $_localAddress.',
        ServerReachability.unreachable =>
          '$label - dispatched, but the server is not responding yet. Check ~/didsa-backend.log in Termux.\n\n'
              'Last Termux result:\n$lastResult',
        ServerReachability.unknown => '$label - dispatched.\n\nLast Termux result:\n$lastResult',
      };
    });
    // The action just changed what's actually running (or stopped it), so
    // the top status pane's own snapshot is now stale - refresh it too,
    // not just the action-result message below.
    unawaited(_refreshLiveStatus());
  }

  Future<void> _showLastResult() async {
    setState(() => _busy = true);
    final result = await _controller.getLastCommandResult();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _statusMessage = 'Last Termux result:\n$result';
    });
  }

  @override
  Widget build(BuildContext context) {
    final granted = _hasPermission ?? false;
    final canAct = granted && !_busy;

    return Scaffold(
      appBar: AppBar(title: const Text('Server Management')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _StatusPane(checking: _checkingLiveStatus, status: _liveStatus, onRefresh: _refreshLiveStatus),
          const SizedBox(height: 16),
          Text(
            "Controls a backend running locally on this device, via Termux - it cannot reach, and has "
            "no effect on, any remote server (e.g. the Pi) you may have configured in Connection "
            "Settings.",
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const _SetupInstructions(),
          if (ApiConfig.baseUrl.isNotEmpty && ApiConfig.baseUrl != _localAddress) ...[
            const SizedBox(height: 8),
            Text(
              "Connection Settings currently points at ${ApiConfig.baseUrl}, not $_localAddress - "
              "point it at $_localAddress to actually use the server controlled here.",
              style: Theme.of(context).textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic),
            ),
          ],
          if (ApiConfig.localApiKey.isEmpty) ...[
            const SizedBox(height: 8),
            Text(
              "First start on this device: a random API key will be generated automatically and used "
              "to start the server - use the \"Use Local Server\" button on Connection Settings "
              "afterward to pick it up and connect.",
              style: Theme.of(context).textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic),
            ),
          ],
          const SizedBox(height: 16),
          if (_hasPermission == null)
            const Center(child: CircularProgressIndicator())
          else if (!granted) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                'Termux permission not granted yet - every action below is disabled until this is allowed.',
                style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _busy ? null : _grantPermission,
              child: const Text('Grant Termux permission'),
            ),
            const SizedBox(height: 24),
          ],
          Text('Branch to test', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          TextField(
            controller: _branchController,
            decoration: InputDecoration(
              labelText: 'Branch name',
              border: const OutlineInputBorder(),
              errorText: _branchController.text.isEmpty || _branchValid ? null : 'Invalid branch name',
            ),
          ),
          const SizedBox(height: 16),
          // The main "test this branch" action - fetches it fresh and
          // boots it in one tap/one dispatched command (see
          // TermuxController.pullAndStart's own doc comment for why this
          // has to be one command, not Pull followed by a separate Start).
          FilledButton.icon(
            onPressed: canAct && _branchValid
                ? () => _run(
                      'Pull & start',
                      () => _controller.pullAndStart(_branchController.text.trim()),
                      expect: ServerReachability.reachable,
                    )
                : null,
            icon: const Icon(Icons.rocket_launch),
            label: const Text('Pull & start'),
          ),
          const SizedBox(height: 8),
          // Secondary: sync the clone without touching whatever's already
          // running - e.g. to inspect the pulled code before restarting.
          OutlinedButton.icon(
            onPressed: canAct && _branchValid
                ? () => _run('Pull latest', () => _controller.pullLatest(_branchController.text.trim()))
                : null,
            icon: const Icon(Icons.download),
            label: const Text('Pull latest changes only'),
          ),
          const SizedBox(height: 24),
          Text('Server', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: canAct
                    ? () => _run('Start server', _controller.startServer, expect: ServerReachability.reachable)
                    : null,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Start'),
              ),
              OutlinedButton.icon(
                onPressed: canAct
                    ? () => _run('Stop server', _controller.stopServer, expect: ServerReachability.unreachable)
                    : null,
                icon: const Icon(Icons.stop),
                label: const Text('Stop'),
              ),
              OutlinedButton.icon(
                onPressed: canAct
                    ? () => _run('Restart server', _controller.restartServer, expect: ServerReachability.reachable)
                    : null,
                icon: const Icon(Icons.refresh),
                label: const Text('Restart'),
              ),
              TextButton.icon(
                onPressed: _busy ? null : _showLastResult,
                icon: const Icon(Icons.receipt_long_outlined),
                label: const Text('Show last Termux result'),
              ),
            ],
          ),
          const SizedBox(height: 24),
          if (_statusMessage != null)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: switch (_reachability) {
                  ServerReachability.reachable => Colors.green.withValues(alpha: 0.15),
                  ServerReachability.unreachable => Colors.red.withValues(alpha: 0.1),
                  ServerReachability.unknown => Theme.of(context).colorScheme.surfaceContainerHighest,
                },
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  if (_busy)
                    const Padding(
                      padding: EdgeInsets.only(right: 12),
                      child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                    ),
                  Expanded(child: Text(_statusMessage!)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The always-visible top-of-screen pane: what's actually running right now
/// (a real /health round trip, not a remembered value) and which branch it
/// reports - reachability alone doesn't say *which* branch's code is
/// answering, and the whole point of this screen is testing branches, so
/// that's the one fact worth surfacing before scrolling to any button.
class _StatusPane extends StatelessWidget {
  const _StatusPane({required this.checking, required this.status, required this.onRefresh});

  final bool checking;
  final ServerStatus status;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final (Color color, IconData icon, String label) = switch ((checking, status.reachability)) {
      (true, _) => (Theme.of(context).colorScheme.surfaceContainerHighest, Icons.hourglass_empty, 'Checking...'),
      (false, ServerReachability.reachable) => (Colors.green, Icons.check_circle, 'Server running'),
      (false, ServerReachability.unreachable) => (Colors.red, Icons.error, 'Server not running'),
      (false, ServerReachability.unknown) => (Colors.grey, Icons.help_outline, 'Unknown'),
    };

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: Theme.of(context).textTheme.titleSmall),
                if (!checking && status.reachability == ServerReachability.reachable)
                  Text('Branch: ${status.branch ?? "unknown"}', style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh status',
            onPressed: checking ? null : onRefresh,
          ),
        ],
      ),
    );
  }
}

/// Collapsed-by-default setup instructions - the four things a user needs
/// to have done before this screen's buttons work at all. Kept out of the
/// way (an [ExpansionTile], not always-on text) since anyone who's already
/// set this up once shouldn't have to scroll past it every visit.
class _SetupInstructions extends StatelessWidget {
  const _SetupInstructions();

  static const _termuxUrl = 'https://f-droid.org/en/packages/com.termux/';
  static const _termuxApiUrl = 'https://f-droid.org/en/packages/com.termux.api/';

  @override
  Widget build(BuildContext context) {
    final bodyStyle = Theme.of(context).textTheme.bodySmall;
    final linkStyle = bodyStyle?.copyWith(decoration: TextDecoration.underline);

    Widget point(String number, Widget content) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('$number. ', style: bodyStyle),
              Expanded(child: content),
            ],
          ),
        );

    return Theme(
      // Removes the default ExpansionTile top/bottom divider lines so it
      // sits flush with the surrounding text instead of looking like a
      // separate card.
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 8),
        title: Text('Setup requirements', style: Theme.of(context).textTheme.bodySmall),
        children: [
          point('1', Text('This page controls a backend running locally on this device.', style: bodyStyle)),
          point(
            '2',
            GestureDetector(
              onTap: () => launchUrl(Uri.parse(_termuxUrl), mode: LaunchMode.externalApplication),
              child: Text('Termux must be installed (F-Droid, not Play Store).', style: linkStyle),
            ),
          ),
          point(
            '3',
            GestureDetector(
              onTap: () => launchUrl(Uri.parse(_termuxApiUrl), mode: LaunchMode.externalApplication),
              child: Text('Termux:API must be installed.', style: linkStyle),
            ),
          ),
          point(
            '4',
            Text(
              'In Termux, set allow-external-apps=true in ~/.termux/termux.properties.',
              style: bodyStyle,
            ),
          ),
        ],
      ),
    );
  }
}
