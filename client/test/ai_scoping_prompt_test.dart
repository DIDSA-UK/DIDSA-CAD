import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/ai/ai_plan_detection.dart';
import 'package:didsa_cad_client/ai/ai_prompt_addons.dart';
import 'package:didsa_cad_client/ai/ai_scoping_prompt.dart';
import 'package:didsa_cad_client/ai/ai_tool_groups.dart';

/// AI Modelling: [buildAiScopingSystemPrompt] assembly - the locked/editable
/// split (`ai_system_prompt_settings_screen.dart`'s own doc comment) is a
/// real correctness requirement, not just a UI nicety: a user override must
/// never drop the plan-termination footer `detectPlanInAssistantText`
/// depends on, and add-on text must actually reach the assembled prompt.
void main() {
  test('with no override/add-ons, the prompt contains the default assistant instructions', () {
    final prompt = buildAiScopingSystemPrompt();
    expect(prompt, contains(defaultAssistantInstructions));
    expect(prompt, contains('## Final reply format'));
    expect(prompt, contains('## Plan shape'));
  });

  test('a custom override replaces the default assistant instructions but keeps the locked footer', () {
    final prompt = buildAiScopingSystemPrompt(assistantInstructionsOverride: 'Only ever speak in haiku.');

    expect(prompt, contains('Only ever speak in haiku.'));
    expect(prompt, isNot(contains(defaultAssistantInstructions)));
    // The mechanical termination instruction must survive any override -
    // `detectPlanInAssistantText` structurally depends on the model
    // honouring it.
    expect(prompt, contains('## Final reply format'));
    expect(prompt, contains('single fenced JSON code block'));
  });

  test('a blank override falls back to the default assistant instructions', () {
    final prompt = buildAiScopingSystemPrompt(assistantInstructionsOverride: '   ');
    expect(prompt, contains(defaultAssistantInstructions));
  });

  test('enabled add-ons are appended before the locked footer, unknown ids are silently skipped', () {
    final prompt = buildAiScopingSystemPrompt(enabledAddOns: {'sheet_metal', 'no_such_addon'});

    expect(prompt, contains(aiPromptAddOns['sheet_metal']!.text));
    expect(prompt.indexOf(aiPromptAddOns['sheet_metal']!.text), lessThan(prompt.indexOf('## Final reply format')));
  });

  test('no add-ons enabled means no add-on text appears', () {
    final prompt = buildAiScopingSystemPrompt();
    for (final addOn in aiPromptAddOns.values) {
      expect(prompt, isNot(contains(addOn.text)));
    }
  });

  test('with nothing disabled, every tool group\'s vocabulary is present and no "turned off" block appears', () {
    final prompt = buildAiScopingSystemPrompt();
    for (final group in aiToolGroups.values) {
      expect(prompt, contains(group.vocabularyText));
    }
    expect(prompt, isNot(contains('Tools currently turned off')));
  });

  test('a disabled tool group\'s vocabulary is absent and it is named in the "turned off" block', () {
    final prompt = buildAiScopingSystemPrompt(disabledToolGroups: {'loft', 'fillet_chamfer'});

    expect(prompt, isNot(contains(loftVocabularyText)));
    expect(prompt, isNot(contains(filletChamferVocabularyText)));
    expect(prompt, contains('Tools currently turned off in this app'));
    expect(prompt, contains(aiToolGroups['loft']!.label));
    expect(prompt, contains(aiToolGroups['fillet_chamfer']!.label));
    // Every other group's text is untouched.
    expect(prompt, contains(revolveVocabularyText));
    expect(prompt, contains(mirrorVocabularyText));
    expect(prompt, contains(directEditingBooleanVocabularyText));
  });

  test('an existingPartSummary appends the locked "Editing an existing Part" block, echoing the summary verbatim',
      () {
    final prompt = buildAiScopingSystemPrompt(existingPartSummary: '1. existing:feat-1 - sketch [Sketch - ...]');

    expect(prompt, contains('## Editing an existing Part'));
    expect(prompt, contains('existing:feat-1'));
    // Locked - appended after everything else but still before the
    // plan-termination footer, same placement `07`'s own locked add-ons use.
    expect(
      prompt.indexOf('## Editing an existing Part'),
      lessThan(prompt.indexOf('## Final reply format')),
    );
    // The default assistant instructions' fresh-Part sentence must not
    // contradict this mode.
    expect(prompt, isNot(contains('there is no "current part" for you to reason about')));
  });

  test('no existingPartSummary means no existing-Part block and the fresh-Part sentence stays', () {
    final prompt = buildAiScopingSystemPrompt();
    expect(prompt, isNot(contains('## Editing an existing Part')));
    expect(prompt, contains('there is no "current part" for you to reason about'));
  });

  test('a blank existingPartSummary is treated the same as none', () {
    final prompt = buildAiScopingSystemPrompt(existingPartSummary: '   ');
    expect(prompt, isNot(contains('## Editing an existing Part')));
  });

  test('an existingPartSummary still appends the block even under a custom assistant-instructions override', () {
    final prompt = buildAiScopingSystemPrompt(
      assistantInstructionsOverride: 'Only ever speak in haiku.',
      existingPartSummary: '1. existing:feat-1 - sketch [...]',
    );
    expect(prompt, contains('Only ever speak in haiku.'));
    expect(prompt, contains('## Editing an existing Part'));
    expect(prompt, contains('## Final reply format'));
  });

  test('the locked vocabulary reference tells the model to convert non-mm/degree units itself', () {
    final prompt = buildAiScopingSystemPrompt();
    expect(prompt, contains('convert it to mm/degrees yourself'));
    expect(prompt, contains('never mix units'));
  });

  test('the editable default instructions include a self-consistency check before finalizing', () {
    final prompt = buildAiScopingSystemPrompt();
    expect(prompt, contains('Before finalizing your plan, double-check'));
    expect(prompt, contains('dimensionally wrong'));
  });

  test('the worked examples cover a revolve (axis_ref + a construction line), not just extrude/gear', () {
    final prompt = buildAiScopingSystemPrompt();
    expect(prompt, contains('"kind": "revolve"'));
    expect(prompt, contains('"axis_ref": "axis"'));
    expect(prompt, contains('"construction": true'));
  });

  test('an existingPartSummary appends a worked existing:<id> example, not just the prose rules', () {
    final prompt = buildAiScopingSystemPrompt(existingPartSummary: '1. existing:feat-1 - sketch [Sketch - ...]');
    expect(prompt, contains('Worked example'));
    expect(prompt, contains('"of": "existing:feat-abc123"'));
  });

  test('the existing:<id> worked example is absent without an existingPartSummary (locked block is conditional)',
      () {
    final prompt = buildAiScopingSystemPrompt();
    expect(prompt, isNot(contains('"of": "existing:feat-abc123"')));
  });

  test('detectPlanInAssistantText still finds a plan in a reply produced under a custom override', () {
    // The system prompt itself is never sent to `detectPlanInAssistantText`
    // (only the assistant's own reply is) - this test exists to document
    // that an override changing the *system* prompt has no bearing on
    // detection, which only ever looks at the *reply* text.
    const reply = '''
Assumptions: hole goes all the way through.

```json
{"version": 1, "steps": [{"local_id": "sk1", "kind": "sketch", "plane": "XY"}]}
```
''';
    buildAiScopingSystemPrompt(assistantInstructionsOverride: 'Only ever speak in haiku.');
    final plan = detectPlanInAssistantText(reply);
    expect(plan, isNotNull);
    expect(plan!.steps, hasLength(1));
  });
}
