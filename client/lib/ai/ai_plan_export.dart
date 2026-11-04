import 'ai_provider.dart';
import 'ai_scoping_prompt.dart' show assemblyModeExternalMatesGuidance;

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

SUB-ASSEMBLIES: if the user wants some parts grouped as a sub-assembly (a
wheel and its bush, say), keep it in this ONE zip - do not split it into
several zips:
- In `00_manifest.json`, next to "parts", add "sub_assemblies": [{"name":
  "Wheel and bush", "type_prefix": "WHEEL_ASM", "summary": "..."}], one
  entry per sub-assembly, in the order they are to be built. Its parts are
  still listed in "parts" and still get their own part plans. Every
  type_prefix, part or sub-assembly, is different.
- Add one assembly plan per sub-assembly, `90_<TYPE_PREFIX>.json`,
  `91_<TYPE_PREFIX>.json`, ... in the manifest's sub_assemblies order (the
  app matches them by that order). Each is written exactly like
  `99_assembly.json` - add_component, move_component, then mates - for that
  sub-assembly alone, in its own frame, with its own first component
  unmoved.
- In `99_assembly.json` (and in a later sub-assembly), place a
  sub-assembly with ONE add_component whose "relative_path" is
  "<ITS TYPE_PREFIX>_001.didsa"; do not add its parts again. It moves as one
  piece. To mate to a part inside it, write that part's path of local_ids
  as the occurrence_id: "<sub-assembly's local_id here>/<the part's
  local_id in the sub-assembly's plan>" (e.g. "castor/wheel"), with
  face_selector in that part's own coordinates as usual.

Bring the zip back into DIDSA-CAD's AI Modelling screen, in Assembly mode,
and use "Import plan" to load it: the app shows the parts for you to
confirm, then builds and saves each one, each sub-assembly, the assembly
and its mates.

Everything below this line is the same schema/instructions DIDSA-CAD's own
in-app assistant is given - follow it exactly so every plan you produce is
valid.''';

/// One component of an imported assembly, as the mates-fix package names it: the zip's own `add_component` `local_id`
/// (what `mates.json` must use), the part it is and the file it was saved from.
class ExternalMatesComponent {
  final String localId;
  final String partName;
  final String relativePath;

  const ExternalMatesComponent({required this.localId, required this.partName, required this.relativePath});
}

/// Why the app is asking for mates again (`16-assembly-mates-gaps-plan.md`, Phase 3).
enum ExternalMatesFixReason {
  /// The zip had no mate steps at all.
  noMates,

  /// The mates failed validation: none were built.
  failedValidation,

  /// Some mates were built, then one failed.
  partlyBuilt,

  /// The mates are built but components can still move.
  componentsFree,
}

/// The short "fix the mates" package for an assembly that was imported from an external AI's zip. It is pasted into the
/// same chat (or a new one) and answered with `mates.json`: a plan of `mate` steps only, by the zip's own `local_id`s,
/// which "Import mates" reads back (`AiModellingScreen._importMates`). It does not repeat the whole system prompt, only
/// the mates rules ([assemblyModeExternalMatesGuidance]) and the facts of this assembly: the components, why the
/// app is asking, and what already holds (so the reply adds, and does not repeat).
///
/// [problems] is the validation failure text or the mate-check report, whichever [reason] is about.
String buildExternalMatesFixPackage({
  required List<ExternalMatesComponent> components,
  required ExternalMatesFixReason reason,
  String problems = '',
}) {
  final buffer = StringBuffer()
    ..writeln('# DIDSA-CAD: mates for an imported assembly')
    ..writeln()
    ..writeln('You (or another chat) wrote the zip for a multi-part assembly: part plans and `99_assembly.json`.')
    ..writeln('DIDSA-CAD imported it, built every part and placed every component. This message is about the mates.')
    ..writeln('Use the part plans you wrote in that chat; if you do not have them, ask the user to paste the')
    ..writeln('zip\'s JSON files first, because every face has to be named from its part plan.')
    ..writeln()
    ..writeln('## The components')
    ..writeln()
    ..writeln('Name a component in "occurrence_id" by its local_id:');
  for (final c in components) {
    buffer.writeln('- `${c.localId}`: ${c.partName} (${c.relativePath})');
  }
  buffer
    ..writeln()
    ..writeln('## What the app found')
    ..writeln();
  switch (reason) {
    case ExternalMatesFixReason.noMates:
      buffer
        ..writeln('The assembly had no mate steps, so nothing holds the components where they were placed.')
        ..writeln('Reply with ALL the mates the assembly needs.');
    case ExternalMatesFixReason.failedValidation:
      buffer
        ..writeln('The mates did not validate, so NONE of them were built. Reply with ALL the mates, corrected:')
        ..writeln()
        ..writeln(problems);
    case ExternalMatesFixReason.partlyBuilt:
      buffer
        ..writeln('Some mates were built, then the app stopped at one that failed:')
        ..writeln()
        ..writeln(problems)
        ..writeln()
        ..writeln('The mates before it are built and stay. Reply with the failed mate, corrected, and every mate')
        ..writeln('after it; do not repeat the earlier ones.');
    case ExternalMatesFixReason.componentsFree:
      buffer
        ..writeln('The mates are built and stay. Checking them, these components can still move (slides and spins')
        ..writeln('are along and about that component\'s own part axes):')
        ..writeln()
        ..writeln(problems)
        ..writeln()
        ..writeln('Reply with ONLY the mates that are missing, so each one is held where it is; do not repeat the')
        ..writeln('mates that already hold. A component that is meant to move stays free: leave it out of the mates')
        ..writeln('and name it in intended_motion (below).');
  }
  buffer
    ..writeln()
    ..writeln('## How to write them')
    ..writeln()
    ..writeln(assemblyModeExternalMatesGuidance)
    ..writeln()
    ..writeln('A mate step looks like this (type is one of coincident, concentric, parallel, distance, angle; a')
    ..writeln('distance or angle mate also has "value", in mm or degrees):')
    ..writeln()
    ..writeln('```json')
    ..writeln('{"version": 1, "steps": [')
    ..writeln('  {"local_id": "m1", "kind": "mate", "type": "coincident", "references": [')
    ..writeln('    {"occurrence_id": "plate", "face_selector": {"direction": "+z"}},')
    ..writeln('    {"occurrence_id": "pin", "face_selector": {"direction": "-z", "near": [0, 0, 10]}}')
    ..writeln('  ]}')
    ..writeln('], "intended_motion": [{"component": "wheel", "motion": "spins about its axle"}]}')
    ..writeln('```')
    ..writeln()
    ..writeln('## Your reply')
    ..writeln()
    ..writeln('Reply with ONE file named `mates.json` (or, if your chat cannot create files, one fenced ```json')
    ..writeln('block) holding only that plan: mate steps only, no add_component or move_component, local_ids as')
    ..writeln('above, and `intended_motion` if any component is meant to move. In DIDSA-CAD, in the AI Modelling')
    ..writeln('screen where the assembly was built, press "Import mates" and pick the file. It only works in the')
    ..writeln('same session as the import.');
  return buffer.toString();
}
