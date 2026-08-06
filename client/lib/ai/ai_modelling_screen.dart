import 'package:flutter/material.dart';

import '../api/document_api_client.dart';
import '../api/sketch_api_client.dart' show ApiException;
import '../gear/gear_preset_store.dart';
import 'ai_plan.dart';
import 'ai_plan_detection.dart';
import 'ai_plan_summary.dart';
import 'ai_provider.dart';
import 'ai_provider_preferences.dart';
import 'ai_scoping_prompt.dart';

/// `GearPresetStore`'s discriminator for a saved AI Modelling plan -
/// `02-scoping-conversation.md`'s "Bolt-on: save plan as preset" section.
const String aiModellingPlanPresetKind = 'ai_modelling_plan';

/// AI Modelling workstream 2: the scoping-conversation chat screen
/// (`docs/ai-modelling/02-scoping-conversation.md`). Reached from
/// `ToolChooserScreen`'s "AI Modelling" tile. Two states in one screen,
/// switched on whether [_proposedPlan] is non-null:
///
/// - **Chatting**: message list + text input + send button, calling the
///   active [AiProvider]'s `sendScopingTurn` with every turn's transcript
///   resent in full (conversation state lives entirely in this screen's
///   Dart state, never persisted server-side - `02`'s own note).
/// - **Review & Generate**: once a turn's response contains a detected
///   plan (`detectPlanInAssistantText`, the plan-detection fallback
///   `01-provider-abstraction.md` calls for) - a human-readable, literal-
///   value summary (`summarizeAiPlan`), plus Generate/Adjust/Save-as-preset.
///
/// **"Adjust" needs no special transcript handling**: the assistant turn
/// that produced [_proposedPlan] is already part of [_transcript] (it's
/// literally the raw response the plan was detected in) and stays there
/// when returning to chat mode - so the next `sendScopingTurn` call
/// automatically resends the proposed plan as context, satisfying `02`'s
/// "next user message is sent with ... the just-proposed plan included as
/// context" requirement without extra bookkeeping.
///
/// **Generate's real scope this session**: create a real, fresh Part
/// (`00-conventions.md`'s "v1 always starts a fresh Part") and run
/// workstream 5's real dry-run validation endpoint against it, showing
/// per-step results. It deliberately does **not** execute the plan for
/// real - that's workstream 4's translator, not built yet - so a fully
/// validated plan ends in an explicit "ready to generate once Part
/// generation lands" state rather than a fake success.
class AiModellingScreen extends StatefulWidget {
  /// Overridable for tests, so a real call never hits the network.
  final AiProvider? provider;

  /// Overridable for tests, so "Generate" never talks to the real backend.
  final DocumentApiClient? documentApi;

  const AiModellingScreen({super.key, this.provider, this.documentApi});

  @override
  State<AiModellingScreen> createState() => _AiModellingScreenState();
}

class _AiModellingScreenState extends State<AiModellingScreen> {
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  List<AiChatMessage> _transcript = [];
  bool _sending = false;
  String? _sendError;

  AiGenerationPlan? _proposedPlan;

  bool _validating = false;
  AiPlanValidateResultDto? _validationResult;
  String? _validationError;

  DocumentApiClient get _documentApi => widget.documentApi ?? DocumentApiClient();

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _send() async {
    final text = _inputController.text.trim();
    if (text.isEmpty || _sending) return;

    final provider = widget.provider ?? AiProviderPreferences.active;
    final userMessage = AiChatMessage(role: AiMessageRole.user, text: text);
    setState(() {
      _transcript = [..._transcript, userMessage];
      _sending = true;
      _sendError = null;
    });
    _inputController.clear();
    _scrollToBottom();

    try {
      final result = await provider.sendScopingTurn(_transcript, systemPrompt: buildAiScopingSystemPrompt());
      final assistantMessage = AiChatMessage(role: AiMessageRole.assistant, text: result.assistantText);
      final detectedPlan = detectPlanInAssistantText(result.assistantText);
      if (!mounted) return;
      setState(() {
        _transcript = [..._transcript, assistantMessage];
        _sending = false;
        if (detectedPlan != null) _proposedPlan = detectedPlan;
      });
      _scrollToBottom();
    } on AiProviderException catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _sendError = e.message;
      });
    }
  }

  void _adjust() {
    setState(() {
      _proposedPlan = null;
      _validationResult = null;
      _validationError = null;
    });
  }

  Future<void> _generate() async {
    final plan = _proposedPlan;
    if (plan == null || _validating) return;
    setState(() {
      _validating = true;
      _validationError = null;
      _validationResult = null;
    });
    try {
      final part = await _documentApi.createPart('AI Modelling Part');
      final result = await _documentApi.validateAiPlan(part.id, plan.toJson());
      if (!mounted) return;
      setState(() {
        _validating = false;
        _validationResult = result;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _validating = false;
        _validationError = e.message;
      });
    }
  }

  Future<void> _saveAsPreset() async {
    final plan = _proposedPlan;
    if (plan == null) return;
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save as preset'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Preset name'),
          onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(controller.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    if (name == null || name.isEmpty) return;
    await GearPresetStore.save(name, aiModellingPlanPresetKind, {
      'plan': plan.toJson(),
      'transcript': _transcript.map((m) => {'role': m.role == AiMessageRole.user ? 'user' : 'assistant', 'text': m.text}).toList(),
    });
  }

  /// Only offered while starting a fresh conversation (`02`'s own "a 'Load
  /// preset' entry point when starting a fresh conversation" wording) -
  /// jumps straight to the Review & Generate state, skipping the scoping
  /// conversation that would otherwise be needed to produce a plan.
  Future<void> _loadPreset() async {
    final presets = GearPresetStore.forKind(aiModellingPlanPresetKind);
    final selected = await showDialog<GearPreset>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Load preset'),
        content: SizedBox(
          width: 360,
          child: presets.isEmpty
              ? const Text('No presets saved yet.')
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: presets.length,
                  itemBuilder: (context, index) {
                    final preset = presets[index];
                    return ListTile(
                      title: Text(preset.name),
                      onTap: () => Navigator.of(context).pop(preset),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        tooltip: 'Delete preset',
                        onPressed: () async {
                          await GearPresetStore.delete(preset.id);
                          if (context.mounted) Navigator.of(context).pop();
                        },
                      ),
                    );
                  },
                ),
        ),
        actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel'))],
      ),
    );
    if (selected == null) return;

    final planJson = selected.fields['plan'];
    if (planJson is! Map) return;
    final AiGenerationPlan plan;
    try {
      plan = AiGenerationPlan.fromJson(Map<String, dynamic>.from(planJson));
    } catch (_) {
      return;
    }
    final rawTranscript = selected.fields['transcript'];
    final transcript = rawTranscript is List
        ? rawTranscript.map((m) {
            final map = Map<String, dynamic>.from(m as Map);
            return AiChatMessage(
              role: map['role'] == 'user' ? AiMessageRole.user : AiMessageRole.assistant,
              text: map['text'] as String? ?? '',
            );
          }).toList()
        : <AiChatMessage>[];

    setState(() {
      _transcript = transcript;
      _proposedPlan = plan;
      _validationResult = null;
      _validationError = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isFreshConversation = _transcript.isEmpty && _proposedPlan == null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Modelling'),
        actions: [
          if (isFreshConversation)
            IconButton(icon: const Icon(Icons.folder_open_outlined), tooltip: 'Load preset', onPressed: _loadPreset),
        ],
      ),
      body: SafeArea(
        child: _proposedPlan == null ? _buildChat(context) : _buildReviewAndGenerate(context, _proposedPlan!),
      ),
    );
  }

  Widget _buildChat(BuildContext context) {
    return Column(
      children: [
        if (_transcript.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Describe the part you want to build. This always starts a brand-new '
              'Part - it never modifies one that already exists.',
              style: TextStyle(color: Colors.white54),
              textAlign: TextAlign.center,
            ),
          ),
        Expanded(
          child: ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.all(12),
            itemCount: _transcript.length,
            itemBuilder: (context, index) => _ChatBubble(message: _transcript[index]),
          ),
        ),
        if (_sending) const Padding(padding: EdgeInsets.only(bottom: 8), child: CircularProgressIndicator()),
        if (_sendError != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(_sendError!, style: const TextStyle(color: Colors.redAccent)),
          ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('aiModellingInput'),
                  controller: _inputController,
                  minLines: 1,
                  maxLines: 4,
                  enabled: !_sending,
                  decoration: const InputDecoration(hintText: 'Describe the part...', border: OutlineInputBorder()),
                  onSubmitted: (_) => _send(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(key: const Key('aiModellingSend'), onPressed: _sending ? null : _send, icon: const Icon(Icons.send)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildReviewAndGenerate(BuildContext context, AiGenerationPlan plan) {
    final summary = summarizeAiPlan(plan);
    final results = _validationResult?.results;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Proposed plan', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Expanded(
            child: ListView(
              children: [
                for (var i = 0; i < summary.length; i++)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text('${i + 1}. ${summary[i]}'),
                  ),
                if (results != null) ...[
                  const SizedBox(height: 16),
                  Text('Validation results', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  for (final r in results)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(r.ok ? Icons.check_circle_outline : Icons.error_outline, color: r.ok ? Colors.green : Colors.redAccent, size: 18),
                          const SizedBox(width: 6),
                          Expanded(child: Text('${r.localId}: ${r.ok ? 'ok' : (r.error?['type'] ?? r.error ?? 'failed')}')),
                        ],
                      ),
                    ),
                  const SizedBox(height: 12),
                  _buildValidationBanner(results),
                ],
                if (_validationError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(_validationError!, style: const TextStyle(color: Colors.redAccent)),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(onPressed: _adjust, child: const Text('Adjust')),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(onPressed: _saveAsPreset, child: const Text('Save as preset')),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  onPressed: _validating ? null : _generate,
                  child: _validating
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Generate'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildValidationBanner(List<AiPlanStepResultDto> results) {
    final failed = results.where((r) => !r.ok).length;
    if (failed == 0) {
      return const _Banner(
        color: Colors.green,
        text: 'Validated - ready to generate once Part generation (workstream 4) lands. '
            'No Features have been created yet.',
      );
    }
    return _Banner(color: Colors.redAccent, text: '$failed of ${results.length} step(s) failed validation - see above.');
  }
}

class _Banner extends StatelessWidget {
  final Color color;
  final String text;

  const _Banner({required this.color, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
      child: Text(text, style: TextStyle(color: color)),
    );
  }
}

class _ChatBubble extends StatelessWidget {
  final AiChatMessage message;

  const _ChatBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == AiMessageRole.user;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.8),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isUser ? Theme.of(context).colorScheme.primaryContainer : Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(message.text),
      ),
    );
  }
}
