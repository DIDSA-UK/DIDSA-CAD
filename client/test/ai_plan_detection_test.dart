import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/ai/ai_plan.dart';
import 'package:didsa_cad_client/ai/ai_plan_detection.dart';

/// AI Modelling workstream 2: [detectPlanInAssistantText], the plan-
/// detection fallback `01-provider-abstraction.md`'s own section calls for
/// - not every provider/model reliably honours a "respond with only this
/// JSON" instruction, so this must find a plan regardless of what
/// surrounds it, and fall back to `null` (treated as an ordinary
/// conversational turn) when nothing valid is found.
void main() {
  const minimalPlanJson = '{"version": 1, "steps": [{"local_id": "g1", "kind": "gear_request", "module": 2}]}';

  test('detects a plan that is the entire response with no fence', () {
    final plan = detectPlanInAssistantText(minimalPlanJson);
    expect(plan, isNotNull);
    expect(plan!.steps.single.localId, 'g1');
  });

  test('detects a plan inside a fenced ```json code block surrounded by prose', () {
    final text = '''
Here is the plan we discussed:

```json
$minimalPlanJson
```

Let me know if you want any changes.''';

    final plan = detectPlanInAssistantText(text);
    expect(plan, isNotNull);
    expect(plan!.steps.single.localId, 'g1');
  });

  test('detects a plan preceded by an "Assumptions:" preamble (fix 4 - relaxed FINAL-reply rule)', () {
    final text = '''
Assumptions: hole goes all the way through; chamfer applies to every edge of the top face.

```json
$minimalPlanJson
```''';

    final plan = detectPlanInAssistantText(text);
    expect(plan, isNotNull);
    expect(plan!.steps.single.localId, 'g1');
  });

  test('detects a plan embedded mid-prose with no fence at all', () {
    final text = 'Sounds good, here is the plan: $minimalPlanJson - generated as requested.';

    final plan = detectPlanInAssistantText(text);
    expect(plan, isNotNull);
    expect(plan!.steps.single.localId, 'g1');
  });

  test('a brace inside a JSON string value does not prematurely close the candidate span', () {
    final text = '''
```json
{"version": 1, "steps": [{"local_id": "g1", "kind": "gear_request", "note": "a } inside a string"}]}
```''';

    final plan = detectPlanInAssistantText(text);
    expect(plan, isNotNull);
    expect((plan!.steps.single as AiGearRequestStep).parameters['note'], 'a } inside a string');
  });

  test('returns null for an ordinary conversational reply with no JSON at all', () {
    final plan = detectPlanInAssistantText('What thickness would you like the base plate to be?');
    expect(plan, isNull);
  });

  test('returns null for a JSON object that is not a plan (no "steps" key)', () {
    final plan = detectPlanInAssistantText('{"hello": "world"}');
    expect(plan, isNull);
  });

  test('returns null for a JSON object whose steps reference an unknown kind', () {
    final plan = detectPlanInAssistantText('{"version": 1, "steps": [{"local_id": "s1", "kind": "spline"}]}');
    expect(plan, isNull);
  });

  test('falls back past an earlier malformed candidate to a later valid one', () {
    final text = 'Almost: {"steps": "not a list"} but the real plan is $minimalPlanJson';
    final plan = detectPlanInAssistantText(text);
    expect(plan, isNotNull);
    expect(plan!.steps.single.localId, 'g1');
  });

  // Multi-part/assembly overhaul, Phase D
  // (`docs/ai-modelling/13-multi-part-assembly-overhaul.md`):
  // [detectPartManifestInAssistantText] - the manifest sibling of
  // [detectPlanInAssistantText], including the two never colliding on the
  // same text.
  group('detectPartManifestInAssistantText', () {
    const manifestJson = '{"kind": "part_manifest", "parts": ['
        '{"name": "Mounting Plate", "type_prefix": "PLATE", "summary": "a plate"},'
        '{"name": "Support Tube", "type_prefix": "TUBE", "summary": "a tube"}'
        ']}';

    test('detects a manifest fenced in prose', () {
      final text = 'Here is the breakdown:\n```json\n$manifestJson\n```\nDoes that look right?';
      final manifest = detectPartManifestInAssistantText(text);
      expect(manifest, isNotNull);
      expect(manifest!.parts, hasLength(2));
      expect(manifest.parts[0].name, 'Mounting Plate');
      expect(manifest.parts[0].typePrefix, 'PLATE');
      expect(manifest.parts[1].name, 'Support Tube');
    });

    test('returns null for an ordinary plan (no "kind": "part_manifest")', () {
      expect(detectPartManifestInAssistantText(minimalPlanJson), isNull);
    });

    test('detectPlanInAssistantText returns null for a manifest (no "steps" key)', () {
      expect(detectPlanInAssistantText(manifestJson), isNull);
    });

    test('returns null for prose with no JSON at all', () {
      expect(detectPartManifestInAssistantText('Sounds good, let me think about the parts involved.'), isNull);
    });

    test('a manifest with no parts is rejected (FormatException caught internally, returns null)', () {
      expect(detectPartManifestInAssistantText('{"kind": "part_manifest", "parts": []}'), isNull);
    });
  });
}
