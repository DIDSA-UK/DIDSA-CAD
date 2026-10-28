import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:qr_flutter/qr_flutter.dart';

import '../config.dart';
import 'headset_pairing.dart';
import '../layout/desktop_width.dart';

/// Connect a VR headset: checks that the headset could use this app's server ([HeadsetPairing.runChecks]), then shows a QR code
/// the headset app scans to add it. Reached from the connection screen and from File > Connect a VR headset.
///
/// The code carries the server's API key, so it is shown only on request and hides itself after [showFor].
class HeadsetPairingScreen extends StatefulWidget {
  /// The server to pair; default [ApiConfig.baseUrl] / [ApiConfig.apiKey], the server this app is connected to.
  final String? baseUrl;
  final String? apiKey;

  /// Overridable for tests, so the checks never hit the real network.
  final http.Client? httpClient;

  /// How long the code stays on screen before it hides itself.
  final Duration showFor;

  /// Overridable for tests: the on-phone server's Wi-Fi setting and this phone's Wi-Fi addresses (see
  /// [HeadsetPairing.runChecks]).
  final bool? localServerOnWifi;
  final Future<List<String>> Function()? wifiAddresses;

  const HeadsetPairingScreen({
    super.key,
    this.baseUrl,
    this.apiKey,
    this.httpClient,
    this.showFor = const Duration(seconds: 60),
    this.localServerOnWifi,
    this.wifiAddresses,
  });

  @override
  State<HeadsetPairingScreen> createState() => _HeadsetPairingScreenState();
}

class _HeadsetPairingScreenState extends State<HeadsetPairingScreen> {
  PairingResult? _result;
  bool _shown = false;
  int _secondsLeft = 0;
  Timer? _timer;

  String get _baseUrl => widget.baseUrl ?? ApiConfig.baseUrl;
  String get _apiKey => widget.apiKey ?? ApiConfig.apiKey;

  bool get _compatible => _result?.compatible ?? false;

  @override
  void initState() {
    super.initState();
    _runChecks();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _runChecks() async {
    _hide();
    setState(() => _result = null);
    final client = widget.httpClient ?? http.Client();
    try {
      final result = await HeadsetPairing.runChecks(
        client: client,
        baseUrl: _baseUrl,
        apiKey: _apiKey,
        localServerOnWifi: widget.localServerOnWifi,
        wifiAddresses: widget.wifiAddresses,
      );
      if (!mounted) return;
      setState(() => _result = result);
      if (_compatible) _show();
    } finally {
      if (widget.httpClient == null) client.close();
    }
  }

  void _show() {
    _timer?.cancel();
    setState(() {
      _shown = true;
      _secondsLeft = widget.showFor.inSeconds;
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() => _secondsLeft--);
      if (_secondsLeft <= 0) _hide();
    });
  }

  void _hide() {
    _timer?.cancel();
    _timer = null;
    if (mounted && _shown) setState(() => _shown = false);
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    final checks = result?.checks;
    return Scaffold(
      appBar: AppBar(title: const Text('Connect a VR headset')),
      body: DesktopMaxWidth(maxWidth: 560, child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                const Text(
                  'In DIDSA Design Tools VR, open Servers and choose Scan, then look at this code.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                if (checks == null)
                  const ListTile(
                    leading: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)),
                    title: Text('Checking the server...'),
                  )
                else
                  for (final check in checks) _CheckRow(check),
                const SizedBox(height: 16),
                if (checks != null && !_compatible)
                  FilledButton.icon(
                    onPressed: _runChecks,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Check again'),
                  ),
                if (_compatible && _shown) ...[
                  Center(
                    child: Container(
                      color: Colors.white,
                      padding: const EdgeInsets.all(16),
                      child: QrImageView(
                        key: const ValueKey('headset-pairing-qr'),
                        data: HeadsetPairing.payload(name: result!.name, baseUrl: result.pairUrl!, apiKey: _apiKey),
                        size: 260,
                        backgroundColor: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(result.name, textAlign: TextAlign.center),
                  Text('Hides in $_secondsLeft s', textAlign: TextAlign.center),
                  const SizedBox(height: 8),
                  OutlinedButton(onPressed: _hide, child: const Text('Hide now')),
                ],
                if (_compatible && !_shown)
                  FilledButton.icon(
                    onPressed: _show,
                    icon: const Icon(Icons.qr_code),
                    label: const Text('Show the code'),
                  ),
                if (_compatible) ...[
                  const SizedBox(height: 16),
                  const Text(
                    'The code contains this server\'s API key. Anyone who photographs it can use your server, so show it only '
                    'to your own headset.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
        ),
      )),
    );
  }
}

class _CheckRow extends StatelessWidget {
  final PairingCheck check;

  const _CheckRow(this.check);

  @override
  Widget build(BuildContext context) {
    final (icon, colour) = switch (check.state) {
      PairingCheckState.pass => (Icons.check_circle, Colors.green),
      PairingCheckState.warn => (Icons.warning_amber, Colors.orange),
      PairingCheckState.fail => (Icons.cancel, Colors.redAccent),
    };
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: colour),
      title: Text(check.title),
      subtitle: Text(check.message),
    );
  }
}
