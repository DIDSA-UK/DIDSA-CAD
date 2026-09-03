import 'ai_provider.dart';

/// External-LLM hand-off (the "Share" bolt-on): packages everything a web
/// LLM client (Claude.ai, ChatGPT, Gemini, etc.) needs to pick up an AI
/// Modelling conversation and finish it under that provider's own, usually
/// far more generous, consumer usage limits - as one plain-text block the
/// user pastes or uploads there. The counterpart to `ai_plan_detection.dart`
/// (which is what actually reads the JSON this hand-off eventually produces
/// back in).
///
/// Deliberately does not duplicate any schema/vocabulary content of its
/// own - [systemPrompt] is expected to be the exact same string
/// `buildAiScopingSystemPrompt` already builds for the in-app assistant
/// (`AiModellingScreen._send()`), so the external LLM is held to the
/// identical schema contract `detectPlanInAssistantText`/`AiGenerationPlan.
/// fromJson` already parse against - never a second, drifting copy.
String buildExternalHandoffPackage({required String systemPrompt, required List<AiChatMessage> transcript}) {
  final buffer = StringBuffer()
    ..writeln(_handoffPreamble)
    ..writeln()
    ..writeln('=' * 72)
    ..writeln(systemPrompt);

  if (transcript.isNotEmpty) {
    buffer
      ..writeln()
      ..writeln('=' * 72)
      ..writeln('## Conversation so far')
      ..writeln()
      ..writeln('This conversation already started in DIDSA-CAD - continue from here rather')
      ..writeln('than starting over.')
      ..writeln();
    for (final message in transcript) {
      final speaker = message.role == AiMessageRole.user ? 'User' : 'Assistant';
      buffer
        ..writeln('$speaker: ${message.text}')
        ..writeln();
    }
  }

  return buffer.toString();
}

const String _handoffPreamble = '''
# DIDSA-CAD AI Modelling hand-off

Paste everything below into your AI chat of choice (Claude, ChatGPT, Gemini,
etc.) and continue the conversation there - useful when you'd rather use
that provider's own, usually more generous, consumer chat limits than
DIDSA-CAD's in-app API access.

If you have a photo of the part (a hand sketch or engineering drawing),
attach it directly in that chat - it does not travel with this hand-off.

Have the conversation until you have a finished, complete plan. Then, for
your FINAL reply:
- If your chat app can create and offer a downloadable file (Claude
  Artifacts/file creation, ChatGPT's Code Interpreter, Gemini's file
  creation, etc.), PREFER that: write the plan to a file named `plan.json`
  containing ONLY the JSON, nothing else, and offer it for download. This
  avoids the chat window truncating or mangling a long JSON reply.
- Otherwise, reply with ONLY a single fenced ```json code block containing
  the plan - no other prose in that message.

Bring the resulting JSON (the downloaded file, or the fenced block saved to
a `.json`/`.md`/`.txt` file) back into DIDSA-CAD's AI Modelling screen and
use "Import plan" to load it.

Everything below this line is the same schema/instructions DIDSA-CAD's own
in-app assistant is given - follow it exactly so the plan you produce is
valid.''';
