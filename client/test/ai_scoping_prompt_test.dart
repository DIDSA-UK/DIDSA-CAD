import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/ai/ai_plan_detection.dart';
import 'package:didsa_cad_client/ai/ai_prompt_addons.dart';
import 'package:didsa_cad_client/ai/ai_scoping_prompt.dart';

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
