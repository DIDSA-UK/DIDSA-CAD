import 'dart:async' show unawaited;
import 'dart:convert';

import 'package:flutter/services.dart' show TextInput;
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';

import '../config.dart';
import '../server_management/server_management_screen.dart';
import '../server_management/termux_controller.dart';
import 'home_theme.dart';

/// The home screen's Server tile: define the CAD server (address and API key), connect to it, or use the on-device server. This is
/// the old connection screen's server half, unchanged in behaviour: **nothing is saved until a `GET /health` against the entered
/// address and key succeeds**. A successful Connect returns to the home screen (`true`), whose light turns green.
class ServerScreen extends StatefulWidget {
  const ServerScreen({super.key, this.httpClient, this.note});

  /// Overridable for tests, so a health check doesn't hit the real network.
  final http.Client? httpClient;

  /// Why the user was sent here ("Connect a server to use CAD tools"), shown at the top.
  final String? note;

  @override
  State<ServerScreen> createState() => _ServerScreenState();
}

class _ServerScreenState extends State<ServerScreen> {
  final _urlController = TextEditingController();
  final _keyController = TextEditingController();
  bool _obscureKey = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _urlController.addListener(() => setState(() {}));
    _keyController.addListener(() => setState(() {}));
    _urlController.text = ApiConfig.baseUrl;
    _keyController.text = ApiConfig.apiKey;
    unawaited(ApiConfig.load().then((_) {
      if (!mounted) return;
      setState(() {
        _urlController.text = ApiConfig.baseUrl;
        _keyController.text = ApiConfig.apiKey;
      });
    }));
  }

  @override
  void dispose() {
    _urlController.dispose();
    _keyController.dispose();
    super.dispose();
  }

  bool get _canConnect => !_busy && _urlController.text.trim().isNotEmpty && _keyController.text.trim().isNotEmpty;

  /// Fills the fields with the fixed local address plus the key Server Management last stamped; does not connect (so the
  /// "never save without a real health check" guarantee still applies), exactly as autofill would.
  void _useLocalServer() {
    if (ApiConfig.localApiKey.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No local server key recorded yet - start it once from Server Management first.')),
      );
      return;
    }
    setState(() {
      _urlController.text = TermuxController.localBaseUrl;
      _keyController.text = ApiConfig.localApiKey;
    });
  }

  Future<void> _connect() async {
    final url = _urlController.text.trim();
    final key = _keyController.text.trim();
    setState(() {
      _busy = true;
      _error = null;
    });
    final client = widget.httpClient ?? http.Client();
    try {
      final response = await client.get(Uri.parse('$url/health'), headers: {'X-API-Key': key}).timeout(ApiConfig.requestTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('health check returned ${response.statusCode}');
      }
      await ApiConfig.save(baseUrl: url, apiKey: key);
      await _offerStoreFromHealth(response.body);
      TextInput.finishAutofillContext();
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Could not reach server — check the URL and API key');
    } finally {
      if (widget.httpClient == null) client.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The backend's `/health` says where its project store is (`project_store`, never a key) when it was told: kept as the default
  /// cloud storage address when none is set. The key is still typed once, on the Storage screen.
  Future<void> _offerStoreFromHealth(String body) async {
    try {
      final decoded = jsonDecode(body);
      final offered = decoded is Map ? decoded['project_store'] : null;
      if (offered is String && offered.trim().isNotEmpty && ApiConfig.storeUrl.isEmpty) {
        await ApiConfig.saveStore(storeUrl: offered.trim(), storeApiKey: ApiConfig.storeApiKey);
      }
    } on FormatException {
      // An older backend, or a proxy page: nothing is offered.
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final home = HomeTheme.of(HomePreferences.style.value);
    return Scaffold(
      appBar: AppBar(title: const Text('Server')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
              children: [
                if (widget.note != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(widget.note!, key: const ValueKey('server-note'), style: home.caption(color: home.accent, size: 12)),
                  ),
                Text('The CAD server does the modelling. Enter its address and API key.', style: home.caption(size: 12)),
                const SizedBox(height: 16),
                AutofillGroup(
                  child: Column(
                    children: [
                      TextField(
                        key: const ValueKey('server-url-field'),
                        controller: _urlController,
                        keyboardType: TextInputType.url,
                        autofillHints: const [AutofillHints.url],
                        decoration: const InputDecoration(labelText: 'Server URL'),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        key: const ValueKey('server-key-field'),
                        controller: _keyController,
                        obscureText: _obscureKey,
                        autofillHints: const [AutofillHints.password],
                        decoration: InputDecoration(
                          labelText: 'API Key',
                          suffixIcon: IconButton(
                            icon: Icon(_obscureKey ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                            onPressed: () => setState(() => _obscureKey = !_obscureKey),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    key: const ValueKey('use-local-server'),
                    onPressed: _busy ? null : _useLocalServer,
                    icon: const Icon(Icons.smartphone, size: 18),
                    label: const Text('Use Local Server'),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 48,
                  child: FilledButton(
                    key: const ValueKey('server-connect'),
                    onPressed: _canConnect ? _connect : null,
                    child: _busy
                        ? SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: theme.colorScheme.onPrimary))
                        : const Text('Connect'),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Text(_error!, key: const ValueKey('server-error'), style: TextStyle(color: theme.colorScheme.error), textAlign: TextAlign.center),
                ],
                const SizedBox(height: 28),
                Divider(color: home.line),
                const SizedBox(height: 12),
                // Controls an on-device standalone backend (Termux + proot-distro) via Termux's RUN_COMMAND intent.
                SizedBox(
                  height: 44,
                  child: OutlinedButton.icon(
                    key: const ValueKey('server-management'),
                    onPressed: () => pushHomeRoute<void>(context, (_) => const ServerManagementScreen()),
                    icon: const Icon(Icons.dns_outlined, size: 20),
                    label: const Text('Server Management'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
