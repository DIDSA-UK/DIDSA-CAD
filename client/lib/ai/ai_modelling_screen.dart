import 'package:flutter/material.dart';

import '../api/document_api_client.dart';
import '../api/sketch_api_client.dart' show ApiException, SketchApiClient;
import '../gear/gear_preset_store.dart';
import 'ai_plan.dart';
import 'ai_plan_detection.dart';
import 'ai_plan_summary.dart';
import 'ai_plan_translator.dart';
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
/// **Generate**: creates a real, fresh Part (`00-conventions.md`'s "v1
/// always starts a fresh Part"), then hands it straight to workstream 4's
/// [PlanTranslator] - which runs workstream 5's dry-run validation itself
/// first, and only executes the plan for real once that passes. Reuses
/// this one Part id for both, rather than creating a second, orphaned one
/// - the exact gap this doc comment used to describe before workstream 4
/// was built.
class AiModellingScreen extends StatefulWidget {
  /// Overridable for tests, so a real call never hits the network.
  final AiProvider? provider;

  /// Overridable for tests, so "Generate" never talks to the real backend.
  final DocumentApiClient? documentApi;

  /// Overridable for tests, so [PlanTranslator]'s own sketch-entity calls
  /// never talk to the real backend either.
  final SketchApiClient? sketchApi;

  const AiModellingScreen({super.key, this.provider, this.documentApi, this.sketchApi});

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

  bool _generating = false;
  // Set while `_generating`, one entry per `_proposedPlan.steps` - drives
  // the Review & Generate panel's pending -> in-progress -> done/failed
  // progress list (`04-translator-and-execution.md`'s own "Progress UI"
  // section).
  List<TranslationStepStatus>? _stepStatuses;
  // Only set on a `validationFailed` outcome - the pre-flight dry-run's
  // own per-step report, shown the same way the old validation-only
  // "Generate" used to.
  List<AiPlanStepResultDto>? _validationFailureResults;
  // Set once a translation run actually finishes (success or a real step
  // failure) or the whole attempt errors out before a result even comes
  // back (e.g. a network failure creating the Part).
  PlanTranslationOutcome? _finishedOutcome;
  String? _generateError;

  // Persists across `_adjust()`/returning to chat mode (unlike the fields
  // above, which are Review & Generate-panel-only) - "Undo this
  // generation" (`04`'s own bolt-on) must stay offered even after a
  // stopped run's error gets surfaced back into the chat transcript and
  // the panel switches back to chatting.
  String? _lastRunPartId;
  List<String>? _lastRunCreatedFeatureIds;
  bool _undoing = false;
  String? _undoError;

  DocumentApiClient get _documentApi => widget.documentApi ?? DocumentApiClient();
  SketchApiClient get _sketchApi => widget.sketchApi ?? SketchApiClient();

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
      _stepStatuses = null;
      _validationFailureResults = null;
      _finishedOutcome = null;
      _generateError = null;
      // `_lastRunPartId`/`_lastRunCreatedFeatureIds`/undo state deliberately
      // NOT cleared here - see their own doc comment.
    });
  }

  Future<void> _generate() async {
    final plan = _proposedPlan;
    if (plan == null || _generating) return;
    setState(() {
      _generating = true;
      _generateError = null;
      _validationFailureResults = null;
      _finishedOutcome = null;
      _stepStatuses = List.filled(plan.steps.length, TranslationStepStatus.pending);
    });
    try {
      final part = await _documentApi.createPart('AI Modelling Part');
      final translator = PlanTranslator(documentApi: _documentApi, sketchApi: _sketchApi);
      final result = await translator.execute(
        plan: plan,
        partId: part.id,
        onStepStatusChanged: (index, status) {
          if (!mounted) return;
          setState(() => _stepStatuses![index] = status);
        },
      );
      if (!mounted) return;
      setState(() {
        _generating = false;
        _finishedOutcome = result.outcome;
        _validationFailureResults = result.validationResults;
        if (result.createdFeatureIds.isNotEmpty) {
          _lastRunPartId = part.id;
          _lastRunCreatedFeatureIds = result.createdFeatureIds;
        }
      });
      if (result.outcome == PlanTranslationOutcome.stepFailed ||
          result.outcome == PlanTranslationOutcome.gearRequestEncountered) {
        _appendStoppedRunToTranscript(plan, result);
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _generating = false;
        _generateError = e.message;
      });
    }
  }

  /// `04-translator-and-execution.md`'s own "Real execution and failure
  /// handling" section: on a real step failure (or a `gear_request` stop),
  /// the error is appended to the chat transcript as a new turn and the
  /// panel drops back into chat mode, so the user's next message resends
  /// this as context the LLM can revise a plan for the remaining steps
  /// against - same "next message replays the full transcript" mechanism
  /// `02-scoping-conversation.md`'s "Adjust" already relies on, no extra
  /// bookkeeping needed. Sent as a `user`-role turn (not `assistant`) since
  /// this is real information being fed *to* the LLM, not something it
  /// said - an `assistant`-role bubble here would misleadingly read as the
  /// model reporting on its own execution.
  void _appendStoppedRunToTranscript(AiGenerationPlan plan, PlanTranslationResult result) {
    final summary = summarizeAiPlan(plan);
    final nonPointSteps = plan.steps.where((s) => s is! AiSketchPointStep).toList();
    final stepPosition = nonPointSteps.indexWhere((s) => s.localId == result.stoppedAtLocalId);
    final description = stepPosition >= 0 && stepPosition < summary.length
        ? '${stepPosition + 1}. ${summary[stepPosition]}'
        : result.stoppedAtLocalId!;
    final String text;
    if (result.outcome == PlanTranslationOutcome.stepFailed) {
      text = 'Execution stopped at step $description: ${result.errorMessage}\n\n'
          'Every step before this one was created successfully and is still in the Part '
          '(no automatic rollback - use "Undo this generation" to remove them, or continue '
          'manually). Please propose a revised plan for the remaining steps.';
    } else {
      text = 'Execution stopped at step $description: this is a gear request, and AI '
          "Modelling can't create one automatically yet - please use the Gear Design tool "
          'separately for this part, or propose a revised plan that removes this step.\n\n'
          'Every step before this one was created successfully and is still in the Part.';
    }
    setState(() {
      _transcript = [..._transcript, AiChatMessage(role: AiMessageRole.user, text: text)];
      _proposedPlan = null;
      _stepStatuses = null;
      _finishedOutcome = null;
    });
    _scrollToBottom();
  }

  Future<void> _undo() async {
    final partId = _lastRunPartId;
    final createdFeatureIds = _lastRunCreatedFeatureIds;
    if (partId == null || createdFeatureIds == null || _undoing) return;
    setState(() {
      _undoing = true;
      _undoError = null;
    });
    try {
      final translator = PlanTranslator(documentApi: _documentApi, sketchApi: _sketchApi);
      await translator.undo(partId: partId, createdFeatureIds: createdFeatureIds);
      if (!mounted) return;
      setState(() {
        _undoing = false;
        _lastRunPartId = null;
        _lastRunCreatedFeatureIds = null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _undoing = false;
        _undoError = e.message;
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
      _stepStatuses = null;
      _validationFailureResults = null;
      _finishedOutcome = null;
      _generateError = null;
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
        if (_lastRunCreatedFeatureIds != null) _buildUndoBanner(),
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
    // `summarizeAiPlan` skips `sketch_point` steps (they carry no shape of
    // their own), but `_stepStatuses` is indexed against the raw,
    // unfiltered `plan.steps` (matching `PlanTranslator.execute`'s own
    // `onStepStatusChanged` callback, which walks every step for real
    // execution) - `nonPointStepIndices[i]` maps `summary[i]` back to its
    // real `plan.steps`/`_stepStatuses` index.
    final summary = summarizeAiPlan(plan);
    final statuses = _stepStatuses;
    final nonPointStepIndices = [
      for (var i = 0; i < plan.steps.length; i++)
        if (plan.steps[i] is! AiSketchPointStep) i,
    ];
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
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (statuses != null) ...[
                          _stepStatusIcon(statuses[nonPointStepIndices[i]]),
                          const SizedBox(width: 6),
                        ],
                        Expanded(child: Text('${i + 1}. ${summary[i]}')),
                      ],
                    ),
                  ),
                if (_validationFailureResults != null) ...[
                  const SizedBox(height: 16),
                  Text('Validation results', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  for (final r in _validationFailureResults!)
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
                ],
                if (_finishedOutcome != null) ...[
                  const SizedBox(height: 12),
                  _buildOutcomeBanner(_finishedOutcome!, _validationFailureResults),
                ],
                if (_lastRunCreatedFeatureIds != null) ...[
                  const SizedBox(height: 12),
                  _buildUndoBanner(),
                ],
                if (_generateError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(_generateError!, style: const TextStyle(color: Colors.redAccent)),
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
                  onPressed: _generating ? null : _generate,
                  child: _generating
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

  Widget _stepStatusIcon(TranslationStepStatus status) => switch (status) {
        TranslationStepStatus.pending => const SizedBox(
            width: 18,
            height: 18,
            child: Icon(Icons.circle_outlined, size: 14, color: Colors.white38),
          ),
        TranslationStepStatus.inProgress =>
          const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
        TranslationStepStatus.done => const Icon(Icons.check_circle, size: 18, color: Colors.green),
        TranslationStepStatus.failed => const Icon(Icons.error, size: 18, color: Colors.redAccent),
      };

  Widget _buildOutcomeBanner(PlanTranslationOutcome outcome, List<AiPlanStepResultDto>? validationResults) {
    switch (outcome) {
      case PlanTranslationOutcome.success:
        return const _Banner(color: Colors.green, text: 'Generated - every step created successfully.');
      case PlanTranslationOutcome.validationFailed:
        final failed = validationResults?.where((r) => !r.ok).length ?? 0;
        final total = validationResults?.length ?? 0;
        return _Banner(
          color: Colors.redAccent,
          text: '$failed of $total step(s) failed validation - nothing was created. See above.',
        );
      case PlanTranslationOutcome.stepFailed:
      case PlanTranslationOutcome.gearRequestEncountered:
        // Both of these switch the panel back to chat mode as soon as the
        // run finishes (see `_appendStoppedRunToTranscript`), so this
        // banner is never actually shown for them - kept exhaustive rather
        // than a default case so a future outcome value can't silently
        // fall through unbannered.
        return const SizedBox.shrink();
    }
  }

  Widget _buildUndoBanner() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _undoError ?? 'Undo removes every Feature this generation created.',
              style: TextStyle(color: _undoError != null ? Colors.redAccent : Colors.white54),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: _undoing ? null : _undo,
            child: _undoing
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Undo this generation'),
          ),
        ],
      ),
    );
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
