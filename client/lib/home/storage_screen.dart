import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';

import '../config.dart';
import '../storage/server/store_client.dart';
import '../storage/storage_service.dart';
import '../storage/storage_service_factory.dart';
import 'home_theme.dart';

/// The home screen's Storage tile: where projects live. A **local folder** (the platform's own folder picker), and/or **cloud
/// storage** (the project store, `docs/shared-storage-scope.md`): its address, key and this device's name, entered once.
class StorageScreen extends StatefulWidget {
  const StorageScreen({super.key, this.httpClient, this.storageServiceFactory});

  /// Overridable for tests, so the check doesn't hit the real network.
  final http.Client? httpClient;

  /// Overridable for tests, so the local folder picker never touches a real platform picker.
  final StorageService Function()? storageServiceFactory;

  @override
  State<StorageScreen> createState() => _StorageScreenState();
}

class _StorageScreenState extends State<StorageScreen> {
  final _urlController = TextEditingController();
  final _keyController = TextEditingController();
  final _deviceController = TextEditingController();
  bool _obscureKey = true;
  bool _busy = false;
  String? _message;
  bool _messageIsError = false;
  String? _folderName;
  String? _folderError;

  StorageService get _storage => (widget.storageServiceFactory ?? createLocalStorageService)();

  @override
  void initState() {
    super.initState();
    _urlController.text = ApiConfig.storeUrl;
    _keyController.text = ApiConfig.storeApiKey;
    _deviceController.text = ApiConfig.deviceName;
    _loadFolder();
  }

  @override
  void dispose() {
    _urlController.dispose();
    _keyController.dispose();
    _deviceController.dispose();
    super.dispose();
  }

  Future<void> _loadFolder() async {
    try {
      final root = await _storage.lastUsedProjectRoot();
      if (mounted) setState(() => _folderName = root?.displayName);
    } on StorageException {
      // No remembered folder, or its grant is gone: shown as "none chosen".
    }
  }

  Future<void> _chooseFolder() async {
    setState(() => _folderError = null);
    try {
      final root = await _storage.pickOrCreateProjectRoot();
      if (mounted) setState(() => _folderName = root.displayName);
    } on StorageException catch (e) {
      // Cancelling the picker is silent; anything else (no folder dialog available, a lost grant) is told.
      if (mounted && !e.message.contains('No folder was selected')) setState(() => _folderError = e.message);
    }
  }

  Future<void> _saveStore() async {
    final url = _urlController.text.trim();
    final key = _keyController.text.trim();
    setState(() {
      _busy = true;
      _message = null;
    });
    await ApiConfig.saveStore(storeUrl: url, storeApiKey: key);
    await ApiConfig.saveDeviceName(_deviceController.text);
    String? problem;
    if (url.isNotEmpty && key.isNotEmpty) {
      final client = StoreClient(
        StoreSettings(url: url, apiKey: key, deviceName: ApiConfig.effectiveDeviceName),
        httpClient: widget.httpClient,
      );
      try {
        await client.health();
      } on StoreUnreachable {
        problem = 'Saved, but cloud storage could not be reached at $url.';
      } on StoreAuthError {
        problem = 'Saved, but cloud storage refused the key.';
      } on StoreError catch (error) {
        problem = 'Saved, but cloud storage answered: ${error.detail}';
      } finally {
        client.close();
      }
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _messageIsError = problem != null;
      _message = problem ?? (url.isEmpty ? 'Cloud storage cleared.' : 'Saved. Cloud storage answered.');
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final home = HomeTheme.of(HomePreferences.style.value);
    Widget heading(String text) => Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 10),
          child: Text(text.toUpperCase(), style: home.caption(color: home.accent, size: 11).copyWith(letterSpacing: 1.2)),
        );
    return Scaffold(
      appBar: AppBar(title: const Text('Storage')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
              children: [
                heading('Local folder'),
                Text(
                  _folderName == null ? 'No folder chosen yet. One is asked for the first time you save.' : _folderName!,
                  key: const ValueKey('local-folder-name'),
                  style: home.caption(size: 12, color: _folderName == null ? home.muted : home.foreground),
                ),
                if (_folderError != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(_folderError!, style: TextStyle(color: theme.colorScheme.error))),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    key: const ValueKey('choose-local-folder'),
                    onPressed: _chooseFolder,
                    icon: const Icon(Icons.folder_outlined, size: 18),
                    label: const Text('Choose folder…'),
                  ),
                ),
                const SizedBox(height: 28),
                Divider(color: home.line),
                heading('Cloud storage'),
                Text('Projects kept on your own server, shared between your devices, with a local copy for offline work.', style: home.caption(size: 12)),
                const SizedBox(height: 16),
                TextField(
                  key: const ValueKey('store-url-field'),
                  controller: _urlController,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(labelText: 'Address', hintText: 'https://storage.example.com'),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('store-key-field'),
                  controller: _keyController,
                  obscureText: _obscureKey,
                  decoration: InputDecoration(
                    labelText: 'Key',
                    suffixIcon: IconButton(
                      icon: Icon(_obscureKey ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                      onPressed: () => setState(() => _obscureKey = !_obscureKey),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('device-name-field'),
                  controller: _deviceController,
                  decoration: InputDecoration(labelText: "This device's name", hintText: ApiConfig.defaultDeviceName()),
                ),
                const SizedBox(height: 4),
                Text('Other devices see this name next to a change. It is a label, not a login.', style: home.caption(size: 11)),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: OutlinedButton(
                    key: const ValueKey('store-save-button'),
                    onPressed: _busy ? null : _saveStore,
                    child: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Save and check'),
                  ),
                ),
                if (_message != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(_message!, key: const ValueKey('store-message'), style: TextStyle(color: _messageIsError ? theme.colorScheme.error : home.muted)),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
