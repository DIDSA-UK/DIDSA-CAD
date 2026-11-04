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
String buildExternalHandoffPackage({
  required String systemPrompt,
  required List<AiChatMessage> transcript,
  bool assemblyMode = false,
}) {
  final buffer = StringBuffer()
    ..writeln(assemblyMode ? _assemblyHandoffPreamble : _handoffPreamble)
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

/// The Assembly-mode hand-off's own preamble: an external chat has no app to ask for each part in turn, so instead
/// of one `plan.json` the external AI is asked for the whole multi-part result as one zip, in exactly the shape
/// `AiPlanBundle.fromZipBytes` (`ai_plan_bundle.dart`) reads - which the plain preamble never described, so a zip
/// only ever arrived when an external AI happened to invent one.
const String _assemblyHandoffPreamble = '''
# DIDSA-CAD AI Modelling hand-off (Assembly mode)

Paste everything below into your AI chat of choice (Claude, ChatGPT, Gemini,
etc.) and continue the conversation there. If you have photos or drawings
of the parts, attach them directly in that chat - they do not travel with
this hand-off.

The instructions below describe a conversation in which the app asks for
each part's plan in turn. Here there is no app to ask, so work through the
same stages yourself: settle the parts and your assumptions with the user,
then write every plan. For your FINAL reply, deliver ONE .zip file (if your
chat app cannot create files, give each file's content in its own fenced
```json block, headed by its file name, and the user will zip them) holding
only these JSON files, each containing only JSON:

- `00_manifest.json` - the part_manifest exactly as described below
  ("kind": "part_manifest"), one entry per distinct part. Give every part a
  different "type_prefix".
- `01_<TYPE_PREFIX>.json`, `02_<TYPE_PREFIX>.json`, ... - one ordinary
  plan ({"version": 1, "steps": [...]}) per part, numbered in the same
  order as the manifest's parts: the app matches them to the manifest by
  that order. Each builds its part alone, in its own coordinates.
- `99_assembly.json` - the assembly plan: one add_component step per
  component, each with its own short local_id (the name you use for that
  component everywhere else in this file) and "relative_path" set to
  "<TYPE_PREFIX>_001.didsa" for that part (the app points it at the file it
  really saves); then a move_component step for every component but the
  first, which stays where it is as the assembly's reference frame; then,
  at the END, the mate steps. A mate names a component by its add_component
  local_id and each face with face_selector, in that part's own
  coordinates - the "Assembly mode" section below says exactly how, and
  where it differs from the "Assembly editing" section, follow Assembly
  mode. The app places the components first, then checks and builds the
  mates, so the faces do exist by then. Write enough mates that every
  component which should not move is held where you placed it. A component
  that is meant to move (a wheel spinning on its axle, say) stays free: add
  a top-level "intended_motion" to this file, next to "steps", one entry per
  such component - {"component": "<its local_id>", "motion": "spins about
  its axle"} - so the app does not report it as under-constrained.

Bring the zip back into DIDSA-CAD's AI Modelling screen, in Assembly mode,
and use "Import plan" to load it: the app shows the parts for you to
confirm, then builds and saves each one, the assembly and its mates.

Everything below this line is the same schema/instructions DIDSA-CAD's own
in-app assistant is given - follow it exactly so every plan you produce is
valid.''';
