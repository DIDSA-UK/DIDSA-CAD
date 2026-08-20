import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'ai_provider.dart';
import 'ai_provider_preferences.dart';
import 'ai_system_prompt_settings_screen.dart';
import 'anthropic_provider.dart';
import 'openai_compatible_provider.dart';

/// AI Modelling workstream 1: reachable from `SketcherSettingsScreen` ("CAD
/// Settings") per `docs/ai-modelling/00-conventions.md`'s placement
/// decision - provider picker, per-provider fields shown conditionally, and
/// a "Test connection" action mirroring `ConnectionScreen._handleConnect`'s
/// own health-check-before-save convention (here, a minimal real completion
/// call rather than a `/health` endpoint, since none of these providers
/// expose one uniformly).
class AiProviderSettingsScreen extends StatefulWidget {
  /// Overridable for tests, so "Test connection" never hits the real network.
  final http.Client? httpClient;

  const AiProviderSettingsScreen({super.key, this.httpClient});

  @override
  State<AiProviderSettingsScreen> createState() => _AiProviderSettingsScreenState();
}

class _AiProviderSettingsScreenState extends State<AiProviderSettingsScreen> {
  String _activeProvider = AiProviderPreferences.defaultActiveProvider;

  final _localBaseUrlController = TextEditingController();
  final _localApiKeyController = TextEditingController();
  final _localModelController = TextEditingController();

  final _openAiApiKeyController = TextEditingController();
  final _openAiModelController = TextEditingController();

  final _anthropicApiKeyController = TextEditingController();
  final _anthropicModelController = TextEditingController();

  bool _loaded = false;
  bool _testing = false;
  String? _testError;

  /// Null until a fetch against the current `_localBaseUrlController` text
  /// succeeds - `01`'s own "silent fallback to free text on failure"
  /// bolt-on, so a non-Ollama or unreachable local endpoint never blocks
  /// configuring the model field by hand.
  List<String>? _ollamaModels;
  Timer? _ollamaFetchDebounce;

  @override
  void initState() {
    super.initState();
    _load();
    _localBaseUrlController.addListener(_onLocalBaseUrlChanged);
  }

  Future<void> _load() async {
    await AiProviderPreferences.load();
    if (!mounted) return;
    setState(() {
      _activeProvider = AiProviderPreferences.activeProvider;
      _localBaseUrlController.text = AiProviderPreferences.localBaseUrl;
      _localApiKeyController.text = AiProviderPreferences.localApiKey ?? '';
      _localModelController.text = AiProviderPreferences.localModel;
      _openAiApiKeyController.text = AiProviderPreferences.openAiApiKey;
      _openAiModelController.text = AiProviderPreferences.openAiModel;
      _anthropicApiKeyController.text = AiProviderPreferences.anthropicApiKey;
      _anthropicModelController.text = AiProviderPreferences.anthropicModel;
      _loaded = true;
    });
    // No separate fetch call here: assigning a non-empty stored baseUrl to
    // the controller above already triggers `_onLocalBaseUrlChanged` (the
    // controller only notifies on an actual value change), which schedules
    // the same debounced fetch - one code path for "baseUrl changed",
    // whether that's the user typing or a fresh load populating it.
  }

  @override
  void dispose() {
    _localBaseUrlController.removeListener(_onLocalBaseUrlChanged);
    _ollamaFetchDebounce?.cancel();
    _localBaseUrlController.dispose();
    _localApiKeyController.dispose();
    _localModelController.dispose();
    _openAiApiKeyController.dispose();
    _openAiModelController.dispose();
    _anthropicApiKeyController.dispose();
    _anthropicModelController.dispose();
    super.dispose();
  }

  void _onLocalBaseUrlChanged() {
    setState(() => _ollamaModels = null);
    _ollamaFetchDebounce?.cancel();
    final baseUrl = _localBaseUrlController.text.trim();
    if (baseUrl.isEmpty) return;
    _ollamaFetchDebounce = Timer(const Duration(milliseconds: 500), () => _fetchOllamaModels(baseUrl));
  }

  /// Ollama's own native (non-OpenAI-compat) model-list endpoint lives at
  /// the server root, not under the `/v1` suffix the OpenAI-compatible chat
  /// endpoint uses - strip it if present before appending `/api/tags`.
  static String _ollamaTagsUrl(String baseUrl) {
    var trimmed = baseUrl.trim();
    if (trimmed.endsWith('/')) trimmed = trimmed.substring(0, trimmed.length - 1);
    if (trimmed.toLowerCase().endsWith('/v1')) trimmed = trimmed.substring(0, trimmed.length - 3);
    return '$trimmed/api/tags';
  }

  Future<void> _fetchOllamaModels(String baseUrl) async {
    final client = widget.httpClient ?? http.Client();
    try {
      final response = await client.get(Uri.parse(_ollamaTagsUrl(baseUrl))).timeout(const Duration(seconds: 5));
      if (response.statusCode < 200 || response.statusCode >= 300) return;
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final models = (decoded['models'] as List<dynamic>?)
          ?.cast<Map<String, dynamic>>()
          .map((m) => m['name'] as String?)
          .whereType<String>()
          .toList();
      if (models == null || models.isEmpty) return;
      if (!mounted) return;
      setState(() => _ollamaModels = models);
    } catch (_) {
      // Not Ollama, unreachable, or malformed response - silent fallback to
      // the free-text model field, per `01`'s own bolt-on section.
    } finally {
      if (widget.httpClient == null) client.close();
    }
  }

  Future<void> _handleTestAndSave() async {
    setState(() {
      _testing = true;
      _testError = null;
    });

    try {
      final AiProvider provider;
      switch (_activeProvider) {
        case 'openai':
          provider = OpenAiCompatibleProvider(
            baseUrl: AiProviderPreferences.openAiBaseUrl,
            apiKey: _openAiApiKeyController.text.trim(),
            model: _openAiModelController.text.trim(),
            httpClient: widget.httpClient,
          );
          break;
        case 'anthropic':
          provider = AnthropicProvider(
            apiKey: _anthropicApiKeyController.text.trim(),
            model: _anthropicModelController.text.trim(),
            httpClient: widget.httpClient,
          );
          break;
        case 'local':
        default:
          final apiKey = _localApiKeyController.text.trim();
          provider = OpenAiCompatibleProvider(
            baseUrl: _localBaseUrlController.text.trim(),
            apiKey: apiKey.isEmpty ? null : apiKey,
            model: _localModelController.text.trim(),
            httpClient: widget.httpClient,
          );
      }

      await provider.sendScopingTurn(const [AiChatMessage(role: AiMessageRole.user, text: 'Hi')]);

      switch (_activeProvider) {
        case 'openai':
          await AiProviderPreferences.saveOpenAi(
            apiKey: _openAiApiKeyController.text.trim(),
            model: _openAiModelController.text.trim(),
          );
          break;
        case 'anthropic':
          await AiProviderPreferences.saveAnthropic(
            apiKey: _anthropicApiKeyController.text.trim(),
            model: _anthropicModelController.text.trim(),
          );
          break;
        case 'local':
        default:
          final apiKey = _localApiKeyController.text.trim();
          await AiProviderPreferences.saveLocal(
            baseUrl: _localBaseUrlController.text.trim(),
            apiKey: apiKey.isEmpty ? null : apiKey,
            model: _localModelController.text.trim(),
          );
      }
      await AiProviderPreferences.setActiveProvider(_activeProvider);

      if (!mounted) return;
      Navigator.of(context).pop();
    } on AiProviderException catch (e) {
      if (!mounted) return;
      setState(() => _testError = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _testError = 'Could not reach provider: $e');
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  void _applyOllamaCloudPreset() {
    setState(() {
      _localBaseUrlController.text = 'https://ollama.com/v1';
    });
  }

  void _applyGeminiPreset() {
    setState(() {
      _localBaseUrlController.text = 'https://generativelanguage.googleapis.com/v1beta/openai';
    });
  }

  void _applyGroqPreset() {
    setState(() {
      _localBaseUrlController.text = 'https://api.groq.com/openai/v1';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AI Provider Settings')),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text('Active provider', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  "Which AI provider the scoping conversation sends requests to. Local "
                  "covers both a self-hosted Ollama-style endpoint and Ollama Cloud "
                  "(same OpenAI-compatible wire shape, just a different base URL/key).",
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'local', label: Text('Local')),
                    ButtonSegment(value: 'openai', label: Text('OpenAI')),
                    ButtonSegment(value: 'anthropic', label: Text('Anthropic')),
                  ],
                  selected: {_activeProvider},
                  onSelectionChanged: (selection) => setState(() => _activeProvider = selection.first),
                ),
                const SizedBox(height: 24),
                if (_activeProvider == 'local') ..._buildLocalFields(context),
                if (_activeProvider == 'openai') ..._buildOpenAiFields(context),
                if (_activeProvider == 'anthropic') ..._buildAnthropicFields(context),
                const SizedBox(height: 24),
                ListTile(
                  key: const Key('aiSystemPromptSettingsEntry'),
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.chat_bubble_outline),
                  title: const Text('AI System Prompt'),
                  subtitle: const Text('Edit the assistant instructions and manufacturing-process add-ons'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const AiSystemPromptSettingsScreen()),
                  ),
                ),
                const SizedBox(height: 12),
                if (_testError != null) ...[
                  Text(_testError!, style: const TextStyle(color: Colors.redAccent)),
                  const SizedBox(height: 12),
                ],
                FilledButton(
                  onPressed: _testing ? null : _handleTestAndSave,
                  child: _testing
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Test Connection & Save'),
                ),
              ],
            ),
    );
  }

  List<Widget> _buildLocalFields(BuildContext context) {
    return [
      Text(
        "Local covers any OpenAI-compatible HTTP endpoint - a self-hosted Ollama "
        "server, or a free-tier cloud option like Ollama Cloud, Google Gemini, or "
        "Groq (presets below). The client (not the CAD backend) makes this call "
        "directly, so a LAN-only address only works when the client itself is on "
        "that network - a real limitation when the client is used remotely, not a "
        "bug.",
        style: Theme.of(context).textTheme.bodySmall,
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _localBaseUrlController,
        keyboardType: TextInputType.url,
        decoration: const InputDecoration(labelText: 'Base URL', border: OutlineInputBorder()),
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          OutlinedButton(onPressed: _applyOllamaCloudPreset, child: const Text('Ollama Cloud')),
          OutlinedButton(onPressed: _applyGeminiPreset, child: const Text('Gemini')),
          OutlinedButton(onPressed: _applyGroqPreset, child: const Text('Groq')),
        ],
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _localApiKeyController,
        obscureText: true,
        decoration: const InputDecoration(labelText: 'API Key (optional)', border: OutlineInputBorder()),
      ),
      const SizedBox(height: 12),
      _buildModelField(controller: _localModelController, options: _ollamaModels),
      if (_ollamaModels == null) ...[
        const SizedBox(height: 4),
        Text(
          "Structured output not confirmed for this model - the scoping-turn parser "
          "falls back to treating the whole response as conversational if no plan is found.",
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    ];
  }

  List<Widget> _buildOpenAiFields(BuildContext context) {
    return [
      TextField(
        controller: _openAiApiKeyController,
        obscureText: true,
        decoration: const InputDecoration(labelText: 'API Key', border: OutlineInputBorder()),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _openAiModelController,
        decoration: const InputDecoration(labelText: 'Model', border: OutlineInputBorder()),
      ),
    ];
  }

  List<Widget> _buildAnthropicFields(BuildContext context) {
    return [
      TextField(
        controller: _anthropicApiKeyController,
        obscureText: true,
        decoration: const InputDecoration(labelText: 'API Key', border: OutlineInputBorder()),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _anthropicModelController,
        decoration: const InputDecoration(labelText: 'Model', border: OutlineInputBorder()),
      ),
    ];
  }

  /// Free-text by default; becomes a dropdown once [options] (an Ollama
  /// `/api/tags` fetch) has real values - `01`'s own bolt-on, convenience
  /// only, never a requirement to configure a non-Ollama local endpoint.
  Widget _buildModelField({required TextEditingController controller, required List<String>? options}) {
    if (options == null || options.isEmpty) {
      return TextField(
        controller: controller,
        decoration: const InputDecoration(labelText: 'Model', border: OutlineInputBorder()),
      );
    }
    final currentValue = options.contains(controller.text) ? controller.text : null;
    return DropdownButtonFormField<String>(
      initialValue: currentValue,
      decoration: const InputDecoration(labelText: 'Model', border: OutlineInputBorder()),
      items: [for (final option in options) DropdownMenuItem(value: option, child: Text(option))],
      onChanged: (value) {
        if (value != null) setState(() => controller.text = value);
      },
    );
  }
}
