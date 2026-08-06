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
}
