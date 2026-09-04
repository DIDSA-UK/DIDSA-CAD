import 'package:flutter/material.dart';

import 'ai_prompt_addons.dart';
import 'ai_scoping_prompt.dart';
import 'ai_system_prompt_preferences.dart';
import 'ai_tool_groups.dart';

/// AI Modelling: lets the user see and edit the scoping conversation's
/// system prompt, and toggle manufacturing-process add-on blocks - reached
/// from a new list entry inside `AiProviderSettingsScreen`
/// (`00-conventions.md`'s own "CAD Settings" placement convention extends
/// naturally to this screen too).
///
/// Only the user-editable "assistant instructions" component
/// (`_defaultAssistantInstructions` in `ai_scoping_prompt.dart`) is ever
/// shown as editable text - the vocabulary reference, units convention,
/// few-shot examples, and final-reply-format footer are the LLM's only
/// source of schema truth and its structural contract with
/// `detectPlanInAssistantText`, so they're shown read-only, collapsed by
/// default, never editable here.
class AiSystemPromptSettingsScreen extends StatefulWidget {
  const AiSystemPromptSettingsScreen({super.key});

  @override
  State<AiSystemPromptSettingsScreen> createState() => _AiSystemPromptSettingsScreenState();
}

class _AiSystemPromptSettingsScreenState extends State<AiSystemPromptSettingsScreen> {
  final _instructionsController = TextEditingController();
  Set<String> _enabledAddOns = {};
  Set<String> _disabledToolGroups = {};
  bool _loaded = false;
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await AiSystemPromptPreferences.load();
    if (!mounted) return;
    setState(() {
      _instructionsController.text = AiSystemPromptPreferences.override ?? defaultAssistantInstructions;
      _enabledAddOns = Set<String>.from(AiSystemPromptPreferences.enabledAddOns);
      _disabledToolGroups = Set<String>.from(AiSystemPromptPreferences.disabledToolGroups);
      _loaded = true;
    });
  }

  @override
  void dispose() {
    _instructionsController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final text = _instructionsController.text;
    // Only stored as an override when it differs from the default - typing
    // back exactly the default text is indistinguishable from "Reset to
    // default" and should behave the same way (`setOverride`'s own
    // blank-means-default handling covers the empty-text case; this covers
    // the unmodified-default-text case).
    await AiSystemPromptPreferences.setOverride(
      text.trim() == defaultAssistantInstructions.trim() ? null : text,
    );
    if (!mounted) return;
    setState(() => _saved = true);
  }

  Future<void> _resetToDefault() async {
    await AiSystemPromptPreferences.resetToDefault();
    if (!mounted) return;
    setState(() {
      _instructionsController.text = defaultAssistantInstructions;
      _saved = true;
    });
  }

  Future<void> _toggleAddOn(String id, bool enabled) async {
    await AiSystemPromptPreferences.setAddOnEnabled(id, enabled);
    if (!mounted) return;
    setState(() {
      if (enabled) {
        _enabledAddOns.add(id);
      } else {
        _enabledAddOns.remove(id);
      }
      _saved = true;
    });
  }

  Future<void> _toggleToolGroup(String id, bool enabled) async {
    await AiSystemPromptPreferences.setToolGroupEnabled(id, enabled);
    if (!mounted) return;
    setState(() {
      if (enabled) {
        _disabledToolGroups.remove(id);
      } else {
        _disabledToolGroups.add(id);
      }
      _saved = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AI System Prompt')),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text('Assistant instructions', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  "The role/tone and conversation-style guidance sent to the AI at the start "
                  "of every AI Modelling chat. Edit this to change how the assistant behaves - "
                  "it does not change what it's able to build.",
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('aiSystemPromptInstructions'),
                  controller: _instructionsController,
                  minLines: 6,
                  maxLines: 16,
                  onChanged: (_) => setState(() => _saved = false),
                  decoration: const InputDecoration(border: OutlineInputBorder()),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    OutlinedButton(
                      key: const Key('aiSystemPromptReset'),
                      onPressed: _resetToDefault,
                      child: const Text('Reset to default'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      key: const Key('aiSystemPromptSave'),
                      onPressed: _save,
                      child: const Text('Save'),
                    ),
                    if (_saved) ...[
                      const SizedBox(width: 12),
                      const Icon(Icons.check_circle_outline, size: 18, color: Colors.green),
                    ],
                  ],
                ),
                const SizedBox(height: 24),
                Text('Design context add-ons', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  "Extra design-consideration guidance appended to the prompt when enabled. These "
                  "steer the AI's choices and clarifying questions (wall thickness, fillets, "
                  "overhangs, etc.) - this tool has no dedicated Sheet Metal/Weldment/Casting "
                  "feature, so an add-on never changes what can be generated, only how the AI "
                  "reasons about it.",
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                for (final entry in aiPromptAddOns.entries)
                  SwitchListTile(
                    key: Key('aiPromptAddOn_${entry.key}'),
                    title: Text(entry.value.label),
                    value: _enabledAddOns.contains(entry.key),
                    onChanged: (enabled) => _toggleAddOn(entry.key, enabled),
                  ),
                const SizedBox(height: 24),
                Text('Tools', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  "Which of this tool's features the AI is allowed to build a plan with. Turning "
                  "one off shrinks the prompt (fewer tokens per message) and tells the AI to leave "
                  "it out - if you then ask for something that needs it, the AI will say so and "
                  "point you at the manual tool instead of refusing outright or silently building "
                  "something else. Sketching and Extrude are always on - almost everything needs "
                  "them.",
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                for (final entry in aiToolGroups.entries)
                  SwitchListTile(
                    key: Key('aiToolGroup_${entry.key}'),
                    title: Text(entry.value.label),
                    value: !_disabledToolGroups.contains(entry.key),
                    onChanged: (enabled) => _toggleToolGroup(entry.key, enabled),
                  ),
                const SizedBox(height: 24),
                ExpansionTile(
                  title: const Text('Locked prompt content (not editable)'),
                  subtitle: const Text('Vocabulary reference, units, worked examples, reply format'),
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: SelectableText(
                        lockedSystemPromptContent(disabledToolGroups: _disabledToolGroups),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}
