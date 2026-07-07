import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show TextInput;
import 'package:http/http.dart' as http;

import 'config.dart';
import 'mesh_viewer/mesh_viewer_screen.dart';
import 'viewport3d/part_screen.dart';

/// Stage 18's splash/connection screen - shown on cold launch before
/// [PartScreen], and again later from [PartScreen]'s File menu's "Connection
/// Settings" entry. Loads [ApiConfig]'s stored `server_url`/`api_key`
/// (pre-filling the fields once the async read completes, never blocking the
/// initial frame - see [_loadExisting]), and on Connect runs a `GET /health`
/// check before persisting anything, so a bad URL/key is never silently
/// saved.
class ConnectionScreen extends StatefulWidget {
  /// True when reached from [PartScreen]'s File menu rather than cold
  /// launch - a successful Connect then pops back to the [PartScreen]
  /// already underneath instead of pushing a brand new one.
  final bool isSettingsRevisit;

  /// Overridable for tests, so a health check doesn't hit the real network.
  final http.Client? httpClient;

  const ConnectionScreen({super.key, this.isSettingsRevisit = false, this.httpClient});

  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends State<ConnectionScreen> {
  final _serverUrlController = TextEditingController();
  final _apiKeyController = TextEditingController();

  bool _obscureApiKey = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _serverUrlController.addListener(() => setState(() {}));
    _apiKeyController.addListener(() => setState(() {}));
    _loadExisting();
  }

  /// Populates the fields from whatever [ApiConfig] already has stored -
  /// runs after the first frame, so a slow `shared_preferences` read never
  /// delays the splash itself from appearing.
  Future<void> _loadExisting() async {
    await ApiConfig.load();
    if (!mounted) return;
    setState(() {
      _serverUrlController.text = ApiConfig.baseUrl;
      _apiKeyController.text = ApiConfig.apiKey;
    });
  }

  @override
  void dispose() {
    _serverUrlController.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  bool get _canConnect =>
      !_busy && _serverUrlController.text.trim().isNotEmpty && _apiKeyController.text.trim().isNotEmpty;

  Future<void> _handleConnect() async {
    final url = _serverUrlController.text.trim();
    final key = _apiKeyController.text.trim();
    setState(() {
      _busy = true;
      _error = null;
    });

    final client = widget.httpClient ?? http.Client();
    try {
      final response = await client
          .get(Uri.parse('$url/health'), headers: {'X-API-Key': key})
          .timeout(ApiConfig.requestTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('health check returned ${response.statusCode}');
      }
      await ApiConfig.save(baseUrl: url, apiKey: key);
      TextInput.finishAutofillContext();
      if (!mounted) return;
      if (widget.isSettingsRevisit) {
        Navigator.of(context).pop();
      } else {
        Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const PartScreen()));
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Could not reach server — check the URL and API key');
    } finally {
      if (widget.httpClient == null) client.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    const backgroundColor = Color(0xFF1E1E2E);
    return Scaffold(
      backgroundColor: backgroundColor,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Image.asset(
                    'assets/images/didsa_logo.png',
                    width: 200,
                    errorBuilder: (context, error, stackTrace) => const Text(
                      'DIDSA',
                      style: TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'DIDSA-CAD',
                    style: TextStyle(color: Colors.white70, fontSize: 16),
                  ),
                  const SizedBox(height: 32),
                  // Stage 19a Item 7: grouped so the platform autofill
                  // service (Bitwarden, Android autofill, etc.) treats the
                  // URL/API-key pair as one related save/fill set rather
                  // than two unrelated fields.
                  AutofillGroup(
                    child: Column(
                      children: [
                        TextField(
                          controller: _serverUrlController,
                          keyboardType: TextInputType.url,
                          autofillHints: const [AutofillHints.url],
                          style: const TextStyle(color: Colors.white),
                          decoration: const InputDecoration(
                            labelText: 'Server URL',
                            labelStyle: TextStyle(color: Colors.white70),
                            enabledBorder: OutlineInputBorder(),
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: _apiKeyController,
                          obscureText: _obscureApiKey,
                          autofillHints: const [AutofillHints.password],
                          style: const TextStyle(color: Colors.white),
                          decoration: InputDecoration(
                            labelText: 'API Key',
                            labelStyle: const TextStyle(color: Colors.white70),
                            border: const OutlineInputBorder(),
                            suffixIcon: IconButton(
                              icon: Icon(
                                _obscureApiKey ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                                color: Colors.white70,
                              ),
                              onPressed: () => setState(() => _obscureApiKey = !_obscureApiKey),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _canConnect ? _handleConnect : null,
                      child: _busy
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Connect'),
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(_error!, style: const TextStyle(color: Colors.redAccent), textAlign: TextAlign.center),
                  ],
                  // On-device feedback: "View Complex Mesh" (see
                  // mesh_viewer/mesh_viewer_screen.dart) decodes and renders
                  // an STL/OBJ/glTF file entirely on-device, with no server
                  // round-trip at all - so it makes no sense to gate it
                  // behind a successful server Connect. Only shown on cold
                  // launch, not when this screen is reached as a mid-session
                  // "Connection Settings" revisit (there's already a working
                  // PartScreen underneath in that case).
                  if (!widget.isSettingsRevisit) ...[
                    const SizedBox(height: 24),
                    TextButton.icon(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const MeshViewerScreen()),
                      ),
                      icon: const Icon(Icons.view_in_ar_outlined, color: Colors.white70),
                      label: const Text(
                        'View a mesh file (no server needed)',
                        style: TextStyle(color: Colors.white70),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
