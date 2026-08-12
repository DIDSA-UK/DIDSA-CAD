import 'package:flutter/material.dart';

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

  @override
  void initState() {
    super.initState();
    _branchController.addListener(() => setState(() {}));
    _refreshPermission();
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
    if (!mounted) return;
    setState(() {
      _busy = false;
      _reachability = result;
      _statusMessage = switch (result) {
        ServerReachability.reachable => '$label - server responding at $_localAddress.',
        ServerReachability.unreachable =>
          '$label - dispatched, but the server is not responding yet. Check ~/didsa-backend.log in Termux.',
        ServerReachability.unknown => '$label - dispatched.',
      };
    });
  }

  Future<void> _checkHealth() async {
    setState(() => _busy = true);
    final result = await _controller.check();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _reachability = result;
      _statusMessage = result == ServerReachability.reachable
          ? 'Server responding at $_localAddress.'
          : 'Server not responding at $_localAddress.';
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
          Text('On-device standalone backend', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            "Controls a backend running locally in Termux (proot-distro Debian + the "
            "backend/environment.yml conda env, cloned to ~/DIDSA-CAD) via Termux's RUN_COMMAND "
            "intent. Requires the F-Droid/GitHub build of Termux (not Play Store), Termux:API "
            "installed, and allow-external-apps=true set in ~/.termux/termux.properties.",
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          // Scope, stated plainly: this only ever reaches a backend on this
          // same device at a fixed address - it has no way to reach, and no
          // effect on, a remote server (the Pi, or any future cloud
          // deployment). A valid API key is still needed to actually talk
          // to a remote server, same as always - this screen just can't be
          // the thing that manages one.
          Text(
            "This only ever controls a backend on this device, at $_localAddress - it cannot reach, "
            "and has no effect on, any remote server (e.g. the Pi) you may have configured in "
            "Connection Settings.",
            style: Theme.of(context).textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic),
          ),
          if (ApiConfig.baseUrl.isNotEmpty && ApiConfig.baseUrl != _localAddress) ...[
            const SizedBox(height: 8),
            Text(
              "Connection Settings currently points at ${ApiConfig.baseUrl}, not $_localAddress - "
              "point it at $_localAddress to actually use the server controlled here.",
              style: Theme.of(context).textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic),
            ),
          ],
          if (ApiConfig.apiKey.isEmpty) ...[
            const SizedBox(height: 8),
            Text(
              "No API key set in Connection Settings yet - Start will still work, but you won't be "
              "able to Connect to this server until you set one there.",
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
                onPressed: _busy ? null : _checkHealth,
                icon: const Icon(Icons.favorite_border),
                label: const Text('Check health'),
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
