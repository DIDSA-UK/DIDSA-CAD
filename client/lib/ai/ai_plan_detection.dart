import 'dart:convert';

import 'ai_plan.dart';

/// AI Modelling workstream 2: the plan-detection fallback
/// `01-provider-abstraction.md`'s "Plan-detection fallback" section calls
/// for. Neither concrete [AiProvider] populates `AiTurnResult.plan` (their
/// job stops at the raw assistant text - see that interface's own doc
/// comment) - not every provider/model reliably honours a
/// "respond with only this JSON shape" instruction, especially weaker local
/// models, so this screen must not assume a turn's response is either
/// purely conversational or purely a plan.
///
/// Tries, in order, until one candidate substring parses as JSON *and*
/// matches [AiGenerationPlan]'s shape (has a `steps` list workstream 3's
/// schema can make sense of): the whole trimmed response, every fenced
/// code-block's contents, then every brace-balanced `{...}` span found
/// anywhere in the text (so a plan embedded mid-prose, with no fence at
/// all, is still found). Returns `null` - the caller then treats the whole
/// response as an ordinary conversational turn - when nothing valid is
/// found, matching `supportsStructuredOutput`'s "advisory, not a hard gate"
/// stance.
AiGenerationPlan? detectPlanInAssistantText(String text) {
  for (final candidate in _candidateJsonObjects(text)) {
    try {
      final decoded = jsonDecode(candidate);
      if (decoded is Map<String, dynamic> && decoded['steps'] is List) {
        return AiGenerationPlan.fromJson(decoded);
      }
    } catch (_) {
      // Not valid JSON, or valid JSON that doesn't parse against the plan
      // schema (e.g. an unknown `kind`) - try the next candidate.
      continue;
    }
  }
  return null;
}

final RegExp _fencedBlock = RegExp(r'```(?:json)?\s*([\s\S]*?)```', caseSensitive: false);

Iterable<String> _candidateJsonObjects(String text) sync* {
  final trimmed = text.trim();
  if (trimmed.isNotEmpty) yield trimmed;

  for (final match in _fencedBlock.allMatches(text)) {
    final inner = match.group(1)?.trim();
    if (inner != null && inner.isNotEmpty) yield inner;
  }

  yield* _balancedBraceSpans(text);
}

/// Every top-level `{...}` span in [text], skipping braces that appear
/// inside a double-quoted JSON string (so a plan step's own string field
/// containing a literal `}` doesn't prematurely close the span). A
/// heuristic, not a real parser - a genuinely malformed candidate simply
/// fails the `jsonDecode` attempt above and is skipped.
Iterable<String> _balancedBraceSpans(String text) sync* {
  var depth = 0;
  int? start;
  var inString = false;
  var escape = false;

  for (var i = 0; i < text.length; i++) {
    final char = text[i];
    if (inString) {
      if (escape) {
        escape = false;
      } else if (char == '\\') {
        escape = true;
      } else if (char == '"') {
        inString = false;
      }
      continue;
    }
    if (char == '"') {
      inString = true;
    } else if (char == '{') {
      if (depth == 0) start = i;
      depth++;
    } else if (char == '}') {
      if (depth > 0) {
        depth--;
        if (depth == 0 && start != null) {
          yield text.substring(start, i + 1);
          start = null;
        }
      }
    }
  }
}
