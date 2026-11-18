import 'dart:async';

import 'package:flutter/services.dart' show TextInput;
import 'package:material_ui/material_ui.dart';
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

  /// The browser relay to put in the code; default [ApiConfig.relayUrl] / [ApiConfig.relayApiKey]. [saveRelay] stores what is typed
  /// (default [ApiConfig.saveRelay]; tests replace it).
  final String? relayUrl;
  final String? relayApiKey;
  final Future<void> Function(String relayUrl, String relayApiKey)? saveRelay;

  /// The session hub to put in the code, so the headset can host a live session without typing (LS-11); default [ApiConfig.hubUrl] /
  /// [ApiConfig.hubApiKey]. [saveHub] stores what is typed (default [ApiConfig.saveHub]; tests replace it).
  final String? hubUrl;
  final String? hubApiKey;
  final Future<void> Function(String hubUrl, String hubApiKey)? saveHub;

  /// The cloud storage (project store) to put in the code, so the headset finds it without typing; default [ApiConfig.storeUrl] /
  /// [ApiConfig.storeApiKey]. Both are written only when both are set.
  final String? storeUrl;
  final String? storeApiKey;

  const HeadsetPairingScreen({
    super.key,
    this.baseUrl,
    this.apiKey,
    this.httpClient,
    this.showFor = const Duration(seconds: 60),
    this.localServerOnWifi,
    this.wifiAddresses,
    this.relayUrl,
    this.relayApiKey,
    this.saveRelay,
    this.hubUrl,
    this.hubApiKey,
    this.saveHub,
    this.storeUrl,
    this.storeApiKey,
  });

  @override
  State<HeadsetPairingScreen> createState() => _HeadsetPairingScreenState();
}

class _HeadsetPairingScreenState extends State<HeadsetPairingScreen> {
  PairingResult? _result;
  bool _shown = false;
  int _secondsLeft = 0;
  Timer? _timer;
  late final TextEditingController _relayUrlField;
  late final TextEditingController _relayKeyField;
  late String _relayUrl;
  late String _relayApiKey;
  late final TextEditingController _hubUrlField;
  late final TextEditingController _hubKeyField;
  late String _hubUrl;
  late String _hubApiKey;

  String get _baseUrl => widget.baseUrl ?? ApiConfig.baseUrl;
  String get _apiKey => widget.apiKey ?? ApiConfig.apiKey;

  bool get _compatible => _result?.compatible ?? false;

  bool get _storeInCode =>
      (widget.storeUrl ?? ApiConfig.storeUrl).trim().isNotEmpty && (widget.storeApiKey ?? ApiConfig.storeApiKey).trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    _relayUrl = widget.relayUrl ?? ApiConfig.relayUrl;
    _relayApiKey = widget.relayApiKey ?? ApiConfig.relayApiKey;
    _relayUrlField = TextEditingController(text: _relayUrl);
    _relayKeyField = TextEditingController(text: _relayApiKey);
    _hubUrl = widget.hubUrl ?? ApiConfig.hubUrl;
    _hubApiKey = widget.hubApiKey ?? ApiConfig.hubApiKey;
    _hubUrlField = TextEditingController(text: _hubUrl);
    _hubKeyField = TextEditingController(text: _hubApiKey);
    _runChecks();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _relayUrlField.dispose();
    _relayKeyField.dispose();
    _hubUrlField.dispose();
    _hubKeyField.dispose();
    super.dispose();
  }

  Future<void> _saveRelay() async {
    final url = _relayUrlField.text.trim();
    final key = _relayKeyField.text.trim();
    await (widget.saveRelay ?? (u, k) => ApiConfig.saveRelay(relayUrl: u, relayApiKey: k))(url, key);
    // Offers the address + key to the password manager.
    if (url.isNotEmpty && key.isNotEmpty) TextInput.finishAutofillContext();
    if (!mounted) return;
    setState(() {
      _relayUrl = url;
      _relayApiKey = key;
    });
    await _runChecks();
  }

  Future<void> _saveHub() async {
    final url = _hubUrlField.text.trim();
    final key = _hubKeyField.text.trim();
    await (widget.saveHub ?? (u, k) => ApiConfig.saveHub(hubUrl: u, hubApiKey: k))(url, key);
    if (url.isNotEmpty && key.isNotEmpty) TextInput.finishAutofillContext();
    if (!mounted) return;
    setState(() {
      _hubUrl = url;
      _hubApiKey = key;
    });
    await _runChecks();
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
        relayUrl: _relayUrl,
        relayApiKey: _relayApiKey,
        hubUrl: _hubUrl,
        hubApiKey: _hubApiKey,
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
                if (_compatible && _shown && result != null) ...[
                  Center(
                    child: Container(
                      color: Colors.white,
                      padding: const EdgeInsets.all(16),
                      child: Builder(builder: (context) {
                        final code = HeadsetPairing.payload(
                          name: result.name,
                          baseUrl: result.pairUrl!,
                          apiKey: _apiKey,
                          relayUrl: result.relayUrl,
                          relayApiKey: _relayApiKey,
                          hubUrl: result.hubUrl,
                          hubApiKey: _hubApiKey,
                          storeUrl: widget.storeUrl ?? ApiConfig.storeUrl,
                          storeApiKey: widget.storeApiKey ?? ApiConfig.storeApiKey,
                        );
                        // MetaData: lets a widget test read what the code says (QrImageView does not expose it); invisible.
                        return MetaData(
                          key: const ValueKey('headset-pairing-payload'),
                          metaData: code,
                          child: QrImageView(
                            key: const ValueKey('headset-pairing-qr'),
                            data: code,
                            size: 260,
                            backgroundColor: Colors.white,
                          ),
                        );
                      }),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(result.name, textAlign: TextAlign.center),
                  if (_storeInCode)
                    Text(
                      'The code includes your cloud storage address and key, so the headset can open server projects. Anyone who photographs it can read them.',
                      key: const ValueKey('headset-pairing-store-note'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 12),
                    ),
                  if (result.hubUrl != null)
                    const Text(
                      'The code includes your session hub address and key, so the headset can host live sessions. Anyone who photographs it can host on your hub.',
                      key: ValueKey('headset-pairing-hub-note'),
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12),
                    ),
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
                const SizedBox(height: 16),
                ExpansionTile(
                  key: const ValueKey('headset-pairing-relay'),
                  tilePadding: EdgeInsets.zero,
                  title: const Text('Browser relay (optional)'),
                  subtitle: Text(_relayUrl.isEmpty ? 'Not set: the headset\'s Browser window will not work.' : _relayUrl),
                  children: [
                    const Text(
                      'The headset\'s Browser window needs the browser-relay service (browser-relay/ in DIDSA-CAD; port 8100 by '
                      'default). Its address, for example ws://192.168.1.20:8100, and its own key (BROWSER_RELAY_API_KEY, not the '
                      'CAD key) go in the code with the server.',
                      style: TextStyle(fontSize: 12),
                    ),
                    // A password manager fills these as a username (the address) + password (the key) pair.
                    AutofillGroup(
                      child: Column(
                        children: [
                          TextField(
                            key: const ValueKey('headset-pairing-relay-url'),
                            controller: _relayUrlField,
                            decoration: const InputDecoration(labelText: 'Relay address (ws:// or wss://)'),
                            keyboardType: TextInputType.url,
                            autocorrect: false,
                            autofillHints: const [AutofillHints.username, AutofillHints.url],
                          ),
                          TextField(
                            key: const ValueKey('headset-pairing-relay-key'),
                            controller: _relayKeyField,
                            decoration: const InputDecoration(labelText: 'Relay key'),
                            obscureText: true,
                            autocorrect: false,
                            autofillHints: const [AutofillHints.password],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: OutlinedButton(onPressed: _saveRelay, child: const Text('Save relay and check again')),
                    ),
                  ],
                ),
                ExpansionTile(
                  key: const ValueKey('headset-pairing-hub'),
                  tilePadding: EdgeInsets.zero,
                  title: const Text('Live sessions (optional)'),
                  subtitle: Text(_hubUrl.isEmpty ? 'Not set: the headset cannot host a session until it is given the hub.' : _hubUrl),
                  children: [
                    const Text(
                      'Hosting a live session in the headset needs the session-hub service (session-hub/ in DIDSA-CAD; port 8300 by '
                      'default). Its address, for example wss://sessions.example.net, and its own key (SESSION_HUB_API_KEY, not the '
                      'CAD key) go in the code with the server. People who only join a session need neither: the join code carries the hub.',
                      style: TextStyle(fontSize: 12),
                    ),
                    AutofillGroup(
                      child: Column(
                        children: [
                          TextField(
                            key: const ValueKey('headset-pairing-hub-url'),
                            controller: _hubUrlField,
                            decoration: const InputDecoration(labelText: 'Hub address (ws:// or wss://)'),
                            keyboardType: TextInputType.url,
                            autocorrect: false,
                            autofillHints: const [AutofillHints.username, AutofillHints.url],
                          ),
                          TextField(
                            key: const ValueKey('headset-pairing-hub-key'),
                            controller: _hubKeyField,
                            decoration: const InputDecoration(labelText: 'Hub key'),
                            obscureText: true,
                            autocorrect: false,
                            autofillHints: const [AutofillHints.password],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: OutlinedButton(onPressed: _saveHub, child: const Text('Save hub and check again')),
                    ),
                  ],
                ),
                if (_compatible) ...[
                  const SizedBox(height: 16),
                  const Text(
                    'The code contains this server\'s API key (and the relay\'s, hub\'s and store\'s, when set). Anyone who photographs it can use your '
                    'server, so show it only to your own headset.',
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
