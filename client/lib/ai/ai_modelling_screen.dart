import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../api/document_api_client.dart';
import '../api/sketch_api_client.dart' show ApiException, SketchApiClient;
import '../assembly/assembly_document_client.dart';
import '../assembly/assembly_graph_composer.dart' show AssemblyGraphCycleException;
import '../assembly/assembly_lens.dart';
import '../assembly/relative_path.dart';
import '../gear/gear_preset_store.dart';
import '../storage/project_root.dart';
import '../storage/storage_service.dart';
import '../viewport3d/part_screen.dart';
import '../viewport3d/relative_path_dialog.dart';
import 'ai_component_file_summary.dart';
import 'ai_existing_part_summary.dart';
import 'ai_generation_mode.dart';
import 'ai_part_manifest.dart';
import 'ai_part_naming.dart';
import 'ai_plan.dart';
import 'ai_plan_detection.dart';
import 'ai_plan_export.dart';
import 'ai_plan_summary.dart';
import 'ai_plan_translator.dart';
import 'ai_provider.dart';
import 'ai_provider_preferences.dart';
import 'ai_provider_settings_screen.dart';
import 'ai_scoping_prompt.dart';
import 'ai_system_prompt_preferences.dart';

/// `GearPresetStore`'s discriminator for a saved AI Modelling plan -
/// `02-scoping-conversation.md`'s "Bolt-on: save plan as preset" section.
const String aiModellingPlanPresetKind = 'ai_modelling_plan';

/// Workstream 10 (`10-image-input.md`): bounds an attached image's longest
/// edge before it's base64-encoded and sent to a provider - large enough to
/// keep real dimension callouts/small text legible, small enough to keep the
/// upload/resend cost (the image rides along on every future turn too, per
/// `AiChatMessage`'s own doc comment) reasonable.
const int aiImageMaxEdgePx = 1568;

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
///
/// **Existing-Part editing** (`docs/ai-modelling/09-existing-part-
/// editing.md`, the deferred follow-up `00-conventions.md`'s "v1 always
/// starts a fresh Part" section named): when [existingPartId] is given (the
/// "Continue with AI" entry point on `PartScreen`, as opposed to
/// `ToolChooserScreen`'s "AI Modelling" tile, which never sets it), this
/// screen fetches that Part's current Features once in [initState] and
/// threads a prompt-facing summary of them
/// (`ai_existing_part_summary.dart`) into every scoping turn, so the LLM
/// can reference them via the `existing:<id>` convention. **Generate** in
/// this mode reuses [existingPartId] directly for both the dry-run and real
/// execution - it must never call `startNewDocument`/`createPart` (that
/// would wipe or orphan the user's real Document/Part; see [_generate]'s
/// own doc comment for why this is the one thing this mode has to get
/// exactly right).
///
/// **Bug fix - stopped-run retry in plain fresh-Part mode**: a real step
/// failure's own chat message has always told the LLM its earlier steps
/// "are still in the Part... propose a revised plan for the remaining
/// steps" - but until this fix, the *next* Generate press still always
/// wiped the Document and started a genuinely empty Part, so that "revised
/// plan" (which necessarily references local_ids that only existed in the
/// *previous* turn's own plan) was essentially guaranteed to fail. Fixed by
/// reusing the exact same `existing:<id>` machinery existing-Part editing
/// already built: [_pendingRetryPartId] tracks the in-progress Part across
/// a stop, [_activePartId] is `existingPartId ?? _pendingRetryPartId`, and
/// [_generate] targets it exactly like [existingPartId] itself - see that
/// field's own doc comment for the full lifecycle (set on a stop, cleared
/// on Undo or once a retry finally succeeds).
class AiModellingScreen extends StatefulWidget {
  /// Overridable for tests, so a real call never hits the network.
  final AiProvider? provider;

  /// Overridable for tests, so "Generate" never talks to the real backend.
  final DocumentApiClient? documentApi;

  /// Overridable for tests, so [PlanTranslator]'s own sketch-entity calls
  /// never talk to the real backend either.
  final SketchApiClient? sketchApi;

  /// Existing-Part editing: when set, this conversation edits the real Part
  /// with this id instead of starting a brand-new one - see this class's
  /// own doc comment. Null (the default) is the original "start fresh"
  /// behaviour, unchanged - `ToolChooserScreen`'s "AI Modelling" tile never
  /// sets this.
  final String? existingPartId;

  /// Assembly support Phase 18 (`docs/assembly-scope.md` §6 `[2]`): both
  /// nullable - only needed for an `add_component` step to have anything to
  /// insert. `PartScreen`'s "Continue with AI" call site passes whatever it
  /// currently holds (possibly null); `ToolChooserScreen`'s fresh-Part entry
  /// point never sets either, since there is no `PartScreen` session yet to
  /// source a project root from - a deliberate, disclosed scope limit, not
  /// an oversight (see `PlanTranslator.storageService`/`.projectRoot`'s own
  /// doc comment for what happens if an `add_component` step is executed
  /// with neither available).
  final StorageService? storageService;
  final ProjectRoot? projectRoot;

  const AiModellingScreen({
    super.key,
    this.provider,
    this.documentApi,
    this.sketchApi,
    this.existingPartId,
    this.storageService,
    this.projectRoot,
  });

  @override
  State<AiModellingScreen> createState() => _AiModellingScreenState();
}

/// An image the user has picked but not yet sent - the client-side
/// counterpart to [AiImageAttachment] with the extra display-only
/// [fileName]. Widened from a single scalar to a list-backed pending
/// attachment strip in Phase B of the multi-part/assembly overhaul
/// (`docs/ai-modelling/13-multi-part-assembly-overhaul.md`).
class _PendingImage {
  final Uint8List bytes;
  final String mimeType;
  final String fileName;

  const _PendingImage({required this.bytes, required this.mimeType, required this.fileName});
}

/// Multi-part/assembly overhaul, Phase D: one part cycle's own successful
/// outcome - what the later assembly-authoring step (Phase E, gated on
/// Phase D2 - not attempted by this phase) will need to reference each
/// part by its real, now-on-disk `relativePath`.
class _SavedAssemblyPart {
  final String name;
  final String relativePath;
  final String partId;

  const _SavedAssemblyPart({required this.name, required this.relativePath, required this.partId});
}

class _AiModellingScreenState extends State<AiModellingScreen> {
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  List<AiChatMessage> _transcript = [];
  bool _sending = false;
  String? _sendError;

  // Multi-part/assembly overhaul, Phase A
  // (`docs/ai-modelling/13-multi-part-assembly-overhaul.md`): the per-
  // conversation mode toggle. Starts from whatever default the user last
  // set (`AiGenerationModePreferences.defaultMode`) - changing it here only
  // affects this conversation; persisting a new default is a separate,
  // explicit action (`_setMode`'s own `persistAsDefault` parameter).
  AiGenerationMode _mode = AiGenerationModePreferences.defaultMode;

  // Workstream 10 (image input): the picked-but-not-yet-sent image(s), shown
  // as a small preview strip above the input row. Cleared as soon as
  // `_send()` folds them into a real `AiChatMessage` (success or failure) -
  // re-attaching is how a user retries, matching `_sendError`'s own
  // "surfaced, not silently retried" posture. Widened from a single image to
  // a list in Phase B of the multi-part/assembly overhaul
  // (`docs/ai-modelling/13-multi-part-assembly-overhaul.md`) - one turn can
  // now carry more than one image (several distinct parts, or several views
  // of one assembly).
  List<_PendingImage> _pendingImages = [];
  bool _preparingImage = false;
  String? _imageError;

  // Workstream 11 (voice input, `11-voice-input.md`): fully decoupled from
  // the image-upload state above and from the network/provider layer
  // entirely - on-device transcription only, never sends audio anywhere.
  // `_speechToText` is created once and reused; `initialize()` is only ever
  // called lazily, on the first mic tap (see `_toggleListening`), never
  // eagerly in `initState` - `07-09`'s convention of doing real work only
  // when a user action asks for it, and this specifically avoids ever
  // touching the plugin's platform channel on a platform this screen has
  // already ruled out (see `_voiceInputPlatformSupported`).
  final SpeechToText _speechToText = SpeechToText();
  bool _listening = false;
  // Null until the first mic tap's `initialize()` call resolves - `true`/
  // `false` from then on, so a later tap skips re-initializing.
  bool? _speechAvailable;
  bool _initializingSpeech = false;
  String? _speechError;
  // Accumulated by `_speechToText.listen`'s own `onResult` callback while
  // `_listening` - only committed to `_inputController.text` once the
  // plugin itself reports listening has stopped (`_onSpeechStatus`, covers
  // both a user-initiated stop and the plugin's own silence-timeout
  // auto-stop with the same code path) - never auto-sent.
  String _lastRecognizedWords = '';

  AiGenerationPlan? _proposedPlan;

  // Multi-part/assembly overhaul, Phase D (`docs/ai-modelling/13-multi-
  // part-assembly-overhaul.md`): Assembly mode's own detected
  // part_manifest, awaiting the user's confirm - a sibling of
  // `_proposedPlan` one level up (a manifest names several parts;
  // `_proposedPlan` is always exactly one part's own real plan). Kept as a
  // separate field rather than folded into a union so every existing
  // `_proposedPlan == null` check elsewhere keeps meaning exactly what it
  // always did - a turn detects at most one of the two (`_send()`), never
  // both.
  AiPartManifest? _partManifest;
  List<TextEditingController> _manifestNameControllers = [];
  List<TextEditingController> _manifestPrefixControllers = [];

  // Gap-closure (`13-...md`'s own E-1): existing native files under the
  // project root, offered on the manifest-confirm panel as an "insert into
  // this existing assembly instead" choice - loaded once a manifest is
  // detected (`_loadExistingAssemblyFileOptions`, fired from `_send()`,
  // mirrors `_refreshAvailableComponentFiles`'s own best-effort fetch
  // pattern). Empty (the default) means either nothing's been loaded yet or
  // there's genuinely nothing to offer - either way the dropdown simply
  // doesn't show, so "always create a new assembly" (the pre-E-1 behavior)
  // is the correct fallback.
  List<String> _existingAssemblyFileOptions = [];
  // `null` (the default) means "create a new assembly file", matching this
  // workstream's original behavior - set from `_existingAssemblyFileOptions`
  // via the manifest-confirm panel's own dropdown. Read by `_runAssemblyCycle`
  // to open-and-merge-into that file (`AssemblyDocumentClient.openAssembly`)
  // instead of `DocumentApiClient.createPart('Assembly')`.
  String? _assemblyTargetRelativePath;

  // Set once "Confirm & Generate All" is pressed - drives which panel
  // `build()` shows in place of `_buildChat`/`_buildReviewAndGenerate`.
  bool _orchestrating = false;
  int _currentPartIndex = 0;
  List<_SavedAssemblyPart> _savedAssemblyParts = [];
  // Coarse, human-readable progress text for whichever part cycle is
  // currently in flight (e.g. "Requesting plan for 'Mounting Plate'...",
  // "Building step 3 of 7...", "Saving..."). Deliberately coarser than
  // `_stepStatuses`' own per-step list - see this workstream's own doc
  // Appendix for why a full per-step list wasn't duplicated here too.
  String? _orchestrationStatus;
  String? _orchestrationError;
  // Gap-closure (`13-...md`'s own D-1/E-2): the real Part a failed part
  // cycle was working on when it stopped, so "Retry" (`_retryOrchestration`)
  // can target the *same* Part - via the exact `existing:<id>`/
  // `_pendingRetryPartId` precedent the single-Part flow already built (see
  // that field's own doc comment) - instead of silently abandoning it and
  // starting a brand-new one. Only ever set once a real Part was actually
  // created for the in-flight attempt (never for a failure before that,
  // e.g. no plan detected) - `null` there is correct, not a gap: nothing
  // exists yet to retry into, a plain re-request is exactly right. Cleared
  // on a successful save for that part, or by `_dismissOrchestration`.
  String? _orchestrationRetryPartId;
  // Same as [_orchestrationRetryPartId], one level up, for the assembly
  // cycle (`_runAssemblyCycle`) - E-2's own half of the same gap.
  String? _assemblyRetryPartId;
  // Set on a cancelled save specifically (`_runPartCycle`/
  // `_runAssemblyCycle`'s own "Save cancelled" branch) - the Part/plan are
  // already real and valid, only the save-path prompt was dismissed, so
  // "Retry" here re-opens the save dialog directly rather than wastefully
  // asking the LLM for a plan it doesn't need to revise. `false` (ask the
  // LLM for a revised plan, the general case) otherwise.
  bool _orchestrationRetryIsSaveOnly = false;
  // Gap-closure (`13-...md`'s own D-2/E-3): per-step progress for whichever
  // part/assembly cycle is currently in flight, alongside the coarse
  // `_orchestrationStatus` text above - `PlanTranslator.execute`'s
  // `onStepStatusChanged` callback was already wired for the single-Part
  // Review & Generate panel's own `_stepStatuses` (see that field's doc
  // comment) but never passed at all in `_runPartCycle`/`_runAssemblyCycle`,
  // an omission rather than a harder problem. Reset to one
  // `TranslationStepStatus.pending` per step at the start of each
  // `translator.execute` call below (part cycle or assembly cycle, never
  // both in flight at once), `null` otherwise (between cycles, before a
  // plan is even known).
  List<TranslationStepStatus>? _orchestrationStepStatuses;

  // Multi-part/assembly overhaul, Phase E: set once every part above is
  // saved and `_runAssemblyCycle` starts its own plan/execute/save cycle
  // against a brand-new assembly Part - a sibling of `_orchestrating`, one
  // level further along, so `_buildOrchestrationProgress` can tell "still
  // saving parts" apart from "now building the assembly" without a new top-
  // level panel state. `_assemblyPartId`/`_assemblyRelativePath` are only
  // ever both set together, on a successful save - their non-null-ness is
  // what `_buildOrchestrationProgress`/`_openAssembly` treat as "the
  // assembly is ready to open".
  bool _buildingAssembly = false;
  String? _assemblyPartId;
  String? _assemblyRelativePath;

  bool _generating = false;
  // Set while `_generating`, one entry per `_proposedPlan.steps` - drives
  // the Review & Generate panel's pending -> in-progress -> done/failed
  // progress list (`04-translator-and-execution.md`'s own "Progress UI"
  // section).
  List<TranslationStepStatus>? _stepStatuses;
  // The pre-flight dry-run's own per-step report - always set once a
  // `_generate()` run finishes (`execute()` runs this one validate call
  // before doing anything else, regardless of outcome), shown the same
  // way the old validation-only "Generate" used to.
  List<AiPlanStepResultDto>? _preflightResults;
  // Set once a translation run actually finishes (success or a real step
  // failure) or the whole attempt errors out before a result even comes
  // back (e.g. a network failure creating the Part).
  PlanTranslationOutcome? _finishedOutcome;
  String? _generateError;

  // Fix 5 from the `02` doc's own real end-to-end exercise: only set on a
  // `PlanTranslationOutcome.success` run - the Part id "View Part" pushes
  // `PartScreen` onto, distinct from `_lastRunPartId` (which also stays set
  // through a stopped run purely to drive the "Undo this generation"
  // banner, and persists past `_adjust()`/back-to-chat - `_generatedPartId`
  // is Review & Generate-panel-only, like `_stepStatuses`/`_finishedOutcome`
  // above).
  String? _generatedPartId;

  // Persists across `_adjust()`/returning to chat mode (unlike the fields
  // above, which are Review & Generate-panel-only) - "Undo this
  // generation" (`04`'s own bolt-on) must stay offered even after a
  // stopped run's error gets surfaced back into the chat transcript and
  // the panel switches back to chatting.
  String? _lastRunPartId;
  List<String>? _lastRunCreatedFeatureIds;
  bool _undoing = false;
  String? _undoError;

  // Fix 1 from the `02` doc's own real end-to-end exercise: set once the
  // user dismisses the "no provider configured" dialog with "Not now" -
  // the belt-and-suspenders second layer (`_providerUnconfigured`) reads
  // this to grey out Send rather than letting a dismissed dialog mean
  // silent failure later.
  bool _providerConfigDialogDismissed = false;

  // Existing-Part context currently in effect for this conversation's next
  // scoping turn and next Generate press - populated by
  // `_refreshExistingPartContext`, either once in `initState` (when
  // `widget.existingPartId` is set - "Continue with AI") or after any
  // Generate attempt that touches `_activePartId` below (so a later message
  // in the same conversation sees what was actually built, not a stale
  // pre-Generate snapshot). `null` for the ordinary fresh-Part flow before
  // its first stop. Reused for both the prompt-facing summary
  // (`_existingPartSummary`, threaded into every `_send()` turn) and
  // `PlanTranslator.execute`'s own `existingFeatures` pre-seeding on
  // Generate.
  List<FeatureDto>? _existingFeatures;
  String? _existingPartSummary;
  String? _existingFeaturesError;

  // Assembly support Phase 8 (`docs/assembly-scope.md` §2k): the "Placed
  // Components" half of the existing-Part context, refreshed alongside
  // `_existingFeatures`/`_existingPartSummary` above by the same
  // `_refreshExistingPartContext` call. Defaults to `''` (no components /
  // not fetched yet) - `buildAiScopingSystemPrompt`'s own default, so a
  // failed or not-yet-run fetch degrades to "no Placed Components section"
  // rather than blocking the rest of the existing-Part context.
  String _existingOccurrencesSummary = '';

  // Assembly support Phase 18 (`docs/assembly-scope.md` §6 `[2]`): the
  // "Available Component Files" prompt section's own content - fetched once
  // in `initState` (independent of `widget.existingPartId`/`_activePartId`,
  // unlike `_existingFeatures`/`_existingOccurrencesSummary` above: files on
  // disk don't change the way this Part's own Features/Occurrences do over
  // the course of a conversation, so there's no need to refresh it on every
  // stop/Generate the way that context is). `''` (the default) when neither
  // `widget.storageService` nor `widget.projectRoot` is set, or the fetch
  // fails - no "Available Component Files" section is appended, and
  // `assemblyVocabularyText` tells the LLM to say so rather than invent a
  // path.
  String _availableComponentFilesSummary = '';

  /// Gap-closure (`13-...md`'s own E-1): best-effort fetch of every native
  /// file under the project root, offered on the manifest-confirm panel as
  /// an "insert into an existing assembly" target. Same degrade as
  /// `_refreshAvailableComponentFiles` - a failure just means the dropdown
  /// doesn't show, never blocks the manifest-confirm panel itself.
  Future<void> _loadExistingAssemblyFileOptions() async {
    final storage = widget.storageService;
    final root = widget.projectRoot;
    if (storage == null || root == null) return;
    try {
      final files = await storage.listFiles(root, extensionFilter: kNativeFileExtension);
      if (!mounted) return;
      setState(() => _existingAssemblyFileOptions = files..sort());
    } catch (_) {
      // Best-effort, same degrade as `_refreshAvailableComponentFiles` above.
    }
  }

  Future<void> _refreshAvailableComponentFiles() async {
    final storage = widget.storageService;
    final root = widget.projectRoot;
    if (storage == null || root == null) return;
    try {
      final summary = await summarizeAvailableComponentFilesForPrompt(storage, root);
      if (!mounted) return;
      setState(() => _availableComponentFilesSummary = summary);
    } catch (_) {
      // Best-effort, same degrade as `_refreshExistingPartContext`'s own
      // occurrences fetch.
    }
  }

  // Bug fix: a stopped run's own chat message (`_appendStoppedRunToTranscript`)
  // has always told the LLM "every step before this one was created
  // successfully and is still in the Part... propose a revised plan for the
  // remaining steps" - but `_generate()` used to always call
  // `startNewDocument`/`createPart` again on the very next press in
  // fresh-Part mode, wiping that Part and starting a genuinely empty one.
  // The "revised plan" the LLM had just been told to write - which
  // necessarily references earlier local_ids that only existed in the
  // *previous* turn's plan, not this new one - would then fail outright.
  // Set to the in-progress Part's real id on a stop (`_generate`'s own
  // stopped-run branch), so the *next* Generate press continues into the
  // same Part instead - the same `existing:<id>` machinery
  // `09-existing-part-editing.md` already built for "Continue with AI",
  // just also driving a plain fresh-Part conversation's own mid-conversation
  // retry. Cleared on "Undo this generation" (the partial build is gone, so
  // a genuinely fresh Part is correct again) or once a retry finally
  // succeeds (`00-conventions.md`'s "always fresh Part" rule should resume
  // governing any further, unrelated request in the same chat once this
  // cycle is done) - never read at all once `widget.existingPartId` is set,
  // since `_activePartId` prefers that unconditionally.
  String? _pendingRetryPartId;

  // Whichever real Part id this conversation's next Generate press should
  // target instead of creating a brand-new one - `widget.existingPartId`
  // ("Continue with AI", set once, for this screen's whole lifetime) takes
  // priority over `_pendingRetryPartId` (a plain fresh-Part conversation's
  // own mid-conversation retry state, which only exists at all because
  // `widget.existingPartId` was null to begin with, so the two can never
  // meaningfully conflict).
  String? get _activePartId => widget.existingPartId ?? _pendingRetryPartId;

  // Shared by `initState` (Continue with AI's own one-time fetch), a
  // stopped run (so the *next* prompt/Generate see what was actually
  // built), and a successful Continue-with-AI Generate (so a further
  // message in the same conversation isn't still working from the
  // pre-Generate snapshot) - one fetch-and-summarize path for every case
  // that needs `_existingFeatures`/`_existingPartSummary` to reflect
  // [partId]'s real, current state.
  Future<void> _refreshExistingPartContext(String partId) async {
    try {
      final features = await _documentApi.listFeatures(partId);
      final summary = await summarizeExistingPartForPrompt(_sketchApi, features);
      // Assembly support Phase 8 (`docs/assembly-scope.md` §2k): best-effort
      // - an occurrence-list fetch failure (e.g. this backend build predates
      // the Assembly endpoints, a test harness's own fake backend with no
      // `listOccurrences` route implemented - `part_screen_test.dart`'s own
      // long-documented `_FakeDocumentBackend` gap, §2e/§2f - or a transient
      // error) must not block the Feature-tree summary above, which every
      // existing-Part conversation has always depended on; it just means no
      // "Placed Components" section this time, the same degrade
      // `summarizeExistingOccurrencesForPrompt` itself already gives an
      // empty list. Caught broadly (not just `ApiException`) since an
      // unexpected response shape (e.g. a 404 body a stub backend returns as
      // a bare JSON object) throws a raw type-cast error inside DTO parsing,
      // before ever reaching an `ApiException` - still just a best-effort
      // fetch either way.
      var occurrencesSummary = '';
      try {
        final occurrences = await _documentApi.listOccurrences(partId);
        occurrencesSummary = await summarizeExistingOccurrencesForPrompt(_documentApi, occurrences);
      } catch (_) {
        // Leave occurrencesSummary as ''.
      }
      if (!mounted) return;
      setState(() {
        _existingFeatures = features;
        _existingPartSummary = summary;
        _existingOccurrencesSummary = occurrencesSummary;
        // Clears a previous call's failure - this is called repeatedly over
        // one conversation's lifetime now (every stop, every Continue-with-
        // AI success), not just once in `initState`, so a stale error from
        // an earlier transient failure must not keep showing once a later
        // call actually succeeds.
        _existingFeaturesError = null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _existingFeaturesError = e.message);
    }
  }

  DocumentApiClient get _documentApi => widget.documentApi ?? DocumentApiClient();
  SketchApiClient get _sketchApi => widget.sketchApi ?? SketchApiClient();

  // Deliberately skipped whenever `widget.provider` is overridden - that's
  // a caller (tests, or any future caller) supplying its own provider and
  // bypassing `AiProviderPreferences` entirely, same as `_send()` already
  // does via `widget.provider ?? AiProviderPreferences.active`.
  bool get _providerUnconfigured => widget.provider == null && !AiProviderPreferences.isActiveProviderConfigured;

  // Workstream 11 (voice input): `speech_to_text` has no Linux implementation
  // at all (confirmed via its own platform-support table - see `11-voice-
  // input.md`'s own "Spike" section) - checked statically, with no plugin
  // call at all, so the mic button is hidden outright rather than shown and
  // failing on tap. This app has no macOS/web targets, so "not Linux" here
  // means Android/iOS/Windows - all three genuinely build and ship speech
  // support per that same table (Windows flagged upstream-beta, still shown
  // rather than hidden - see the mic button's own tooltip).
  bool get _voiceInputPlatformSupported => !Platform.isLinux;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkProviderConfigured());
    if (widget.existingPartId != null) _refreshExistingPartContext(widget.existingPartId!);
    _refreshAvailableComponentFiles();
  }

  Future<void> _checkProviderConfigured() async {
    if (!mounted || !_providerUnconfigured) return;
    final openSettings = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('No AI provider configured yet'),
        content: const Text(
          'Pick a provider and test the connection in AI Provider Settings before starting a conversation.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Not now')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Open Settings')),
        ],
      ),
    );
    if (!mounted) return;
    if (openSettings == true) {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AiProviderSettingsScreen()));
      await AiProviderPreferences.load();
      await _checkProviderConfigured();
    } else {
      setState(() => _providerConfigDialogDismissed = true);
    }
  }

  @override
  void dispose() {
    // Only ever true once a real `listen()` call has succeeded, which
    // itself only ever happens after a successful `initialize()` - so this
    // never reaches the plugin's platform channel on a platform
    // `_voiceInputPlatformSupported` already ruled out (there is no
    // Linux implementation to call into at all).
    if (_listening) _speechToText.cancel();
    _inputController.dispose();
    _scrollController.dispose();
    for (final controller in _manifestNameControllers) {
      controller.dispose();
    }
    for (final controller in _manifestPrefixControllers) {
      controller.dispose();
    }
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

  /// Shared by `_send()`, `_shareExternalHandoff()`, and Phase D's own
  /// orchestration turns (`_runPartCycle`) - every real `sendScopingTurn`
  /// call this screen ever makes builds the system prompt exactly the same
  /// way, so it should never drift between call sites (a real risk before
  /// this was factored out: `_shareExternalHandoff` never threaded
  /// `multiBodyPartMode`/`assemblyMode` through at all until this refactor).
  String _buildSystemPrompt() => buildAiScopingSystemPrompt(
        assistantInstructionsOverride: AiSystemPromptPreferences.override,
        enabledAddOns: AiSystemPromptPreferences.enabledAddOns,
        disabledToolGroups: AiSystemPromptPreferences.disabledToolGroups,
        existingPartSummary: _existingPartSummary,
        existingOccurrencesSummary: _existingOccurrencesSummary,
        availableComponentFilesSummary: _availableComponentFilesSummary,
        multiBodyPartMode: _mode == AiGenerationMode.multiBodyPart,
        assemblyMode: _mode == AiGenerationMode.assembly,
      );

  Future<void> _send() async {
    final text = _inputController.text.trim();
    final hasImages = _pendingImages.isNotEmpty;
    if ((text.isEmpty && !hasImages) || _sending || (_providerConfigDialogDismissed && _providerUnconfigured)) {
      return;
    }

    final provider = widget.provider ?? AiProviderPreferences.active;
    final images = _pendingImages;
    final userMessage = AiChatMessage(
      role: AiMessageRole.user,
      text: text.isEmpty ? '(see attached image${images.length > 1 ? 's' : ''})' : text,
      images: [for (final image in images) AiImageAttachment(bytes: image.bytes, mimeType: image.mimeType)],
    );
    setState(() {
      _transcript = [..._transcript, userMessage];
      _sending = true;
      _sendError = null;
      // Cleared now, not only on success - re-attaching is how a user
      // retries after a failed send, see this field's own doc comment.
      _pendingImages = [];
    });
    _inputController.clear();
    _scrollToBottom();

    try {
      if (images.isNotEmpty) {
        // Divergence from `06-image-input-deferred.md`'s "dedicated OCR/CV
        // extraction step" lean - see `10-image-input.md`'s own "Design
        // choices" section: a narrowly-scoped, one-shot call against the
        // active provider's own vision capability, its own fixed prompt,
        // kept out of the main scoping transcript as a call (never sent as
        // a turn of its own). Only its text *output* is appended, as a new
        // `user`-role turn - same "real information fed to the LLM, not
        // something it said" reasoning `_appendStoppedRunToTranscript`
        // already established for a stopped-run error below. The raw
        // image(s) still ride along on `userMessage` above, so they stay
        // visible to the provider on every later turn too (the "pinned for
        // the whole conversation" requirement `06`'s own UX carryover
        // named), not just this one-shot extraction call. Widened to send
        // every pending image in one extraction call (not one call per
        // image) in Phase B of the multi-part/assembly overhaul
        // (`docs/ai-modelling/13-multi-part-assembly-overhaul.md`) - the
        // images likely relate to each other (several parts of one
        // assembly), so a single call that can reason across all of them at
        // once is both cheaper and more accurate than N independent calls.
        final extraction = await provider.extractImageDescription([
          for (final image in images) AiImageAttachment(bytes: image.bytes, mimeType: image.mimeType),
        ]);
        final extractionMessage = AiChatMessage(
          role: AiMessageRole.user,
          text: '[Automated analysis of the attached image${images.length > 1 ? 's' : ''}]\n$extraction',
        );
        if (!mounted) return;
        setState(() => _transcript = [..._transcript, extractionMessage]);
      }

      final systemPrompt = _buildSystemPrompt();
      final result = await provider.sendScopingTurn(_transcript, systemPrompt: systemPrompt);
      final assistantMessage = AiChatMessage(role: AiMessageRole.assistant, text: result.assistantText);
      final detectedPlan = detectPlanInAssistantText(result.assistantText);
      // Multi-part/assembly overhaul, Phase D: only meaningful in Assembly
      // mode - never attempted in Multi-body Part mode, which has no
      // manifest step at all in its own vocabulary.
      final detectedManifest =
          _mode == AiGenerationMode.assembly ? detectPartManifestInAssistantText(result.assistantText) : null;
      if (!mounted) return;
      setState(() {
        _transcript = [..._transcript, assistantMessage];
        _sending = false;
        if (detectedPlan != null) _proposedPlan = detectedPlan;
        if (detectedManifest != null) _setPartManifest(detectedManifest);
      });
      if (detectedManifest != null) unawaited(_loadExistingAssemblyFileOptions());
      _scrollToBottom();
    } on AiProviderException catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _sendError = e.message;
      });
    }
  }

  /// Workstream 10 (`10-image-input.md`): picks image(s) via `file_picker`
  /// (same `FileType`-driven, path-based pattern `mesh_viewer_screen.dart`'s
  /// own `_pickAndLoad` already established), downscales/compresses each to
  /// roughly [aiImageMaxEdgePx] on its longest edge via
  /// `flutter_image_compress`, and appends the results to the pending
  /// attachment strip shown above the input row. Widened from
  /// single-image-only (`result.files.single`) to `allowMultiple: true` in
  /// Phase B of the multi-part/assembly overhaul (`docs/ai-modelling/13-
  /// multi-part-assembly-overhaul.md`) - a request may show several
  /// distinct parts across several images, or a single image may show a
  /// whole assembly.
  ///
  /// `flutter_image_compress` has no Linux/Windows desktop implementation
  /// (Android/iOS/macOS/Web only, per its own platform support table) - on
  /// those two platforms this falls back to the picked file's raw bytes,
  /// unresized, read directly via `dart:io` from `file.path` rather than
  /// through `file_picker`'s own bytes channel (the same large-file-safety
  /// discipline `mesh_viewer_screen.dart`'s own `_pickAndLoad` doc comment
  /// established, for the same MethodChannel-heap reason), rather than
  /// crashing the attach flow outright.
  ///
  /// One file failing to process never aborts the others - each is
  /// processed independently and a per-file failure is folded into
  /// [_imageError] (the last failure's message, naming the failing file)
  /// without discarding whichever files already succeeded, matching this
  /// codebase's existing "one failure doesn't abort the rest" convention
  /// (e.g. `AssemblyDocumentClient.saveAll`).
  Future<void> _attachImage() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.image, allowMultiple: true);
    if (result == null || result.files.isEmpty) return;

    setState(() {
      _preparingImage = true;
      _imageError = null;
    });
    final prepared = <_PendingImage>[];
    String? error;
    for (final file in result.files) {
      final path = file.path;
      if (path == null) {
        error = 'Could not access "${file.name}" - no local file path was returned.';
        continue;
      }
      try {
        Uint8List bytes;
        String mimeType;
        try {
          final compressed = await FlutterImageCompress.compressWithFile(
            path,
            minWidth: aiImageMaxEdgePx,
            minHeight: aiImageMaxEdgePx,
            quality: 85,
            format: CompressFormat.jpeg,
          );
          if (compressed == null) throw StateError('compressWithFile returned null');
          bytes = compressed;
          mimeType = 'image/jpeg';
        } catch (_) {
          bytes = await File(path).readAsBytes();
          mimeType = _mimeTypeForExtension(file.extension ?? '');
        }
        final oriented = _bakeExifOrientation(bytes, mimeType);
        prepared.add(_PendingImage(bytes: oriented.$1, mimeType: oriented.$2, fileName: file.name));
      } catch (e) {
        error = 'Could not process "${file.name}": $e';
      }
    }
    if (!mounted) return;
    setState(() {
      _pendingImages = [..._pendingImages, ...prepared];
      _preparingImage = false;
      _imageError = error;
    });
  }

  /// Bakes a still-present EXIF orientation tag into the image's actual
  /// pixel data, returning (possibly re-encoded) bytes plus the mime type
  /// that now matches them. Needed because neither of this screen's two
  /// consumers of these bytes honour EXIF orientation on their own:
  /// `Image.memory` (the chat bubble/attachment preview below) always
  /// renders the stored pixel grid as-is, and a provider's vision call
  /// (`extractImageDescription`) isn't guaranteed to either - so a portrait
  /// phone photo saved with an EXIF "rotate 90"/"rotate 270" tag (rather
  /// than physically rotated pixels, the common camera convention) can show
  /// sideways in-app and get its geometry read with left/right or up/down
  /// swapped by the vision model. `flutter_image_compress`'s own
  /// `autoCorrectionAngle` (on by default) does this for the compressed
  /// path on Android/iOS, but inconsistently across its own versions/
  /// codecs (a known upstream flakiness, not this app's own bug) and not
  /// at all for the raw-bytes fallback path (desktop, or a failed
  /// compression) - so this runs unconditionally on every path instead of
  /// trusting either. HEIC/HEIF source bytes fail to decode here (the
  /// `image` package has no HEIC decoder) and are returned unchanged - no
  /// worse than before this fix, since nothing corrected them previously
  /// either.
  static (Uint8List, String) _bakeExifOrientation(Uint8List bytes, String mimeType) {
    try {
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return (bytes, mimeType);
      final oriented = img.bakeOrientation(decoded);
      if (mimeType == 'image/png') {
        return (Uint8List.fromList(img.encodePng(oriented)), mimeType);
      }
      return (Uint8List.fromList(img.encodeJpg(oriented, quality: 90)), 'image/jpeg');
    } catch (_) {
      return (bytes, mimeType);
    }
  }

  static String _mimeTypeForExtension(String extension) => switch (extension.toLowerCase()) {
        'png' => 'image/png',
        'webp' => 'image/webp',
        'heic' => 'image/heic',
        'heif' => 'image/heif',
        _ => 'image/jpeg',
      };

  void _removePendingImage(int index) {
    setState(() {
      _pendingImages = [..._pendingImages]..removeAt(index);
      _imageError = null;
    });
  }

  /// Multi-part/assembly overhaul, Phase A: switches this conversation's
  /// mode and persists it as the default the *next* fresh conversation
  /// starts from (`AiGenerationModePreferences.setDefaultMode`) - a
  /// deliberate "the toggle itself is the settings UI" choice, mirroring
  /// `AiSystemPromptPreferences.setAddOnEnabled`'s own immediate-write-
  /// through convention rather than adding a separate settings screen
  /// control for the same value.
  Future<void> _setMode(AiGenerationMode mode) async {
    if (mode == _mode) return;
    setState(() => _mode = mode);
    await AiGenerationModePreferences.setDefaultMode(mode);
  }

  /// Workstream 11 (`11-voice-input.md`): lazily initializes
  /// `speech_to_text` on the first mic tap - never in `initState`, so a
  /// platform/device with no real speech-recognition service installed
  /// never pays this cost (or shows any prompt) until the user actually
  /// asks for it. `initialize()` itself is what triggers the OS's native
  /// microphone/speech permission prompt (confirmed during this
  /// workstream's own spike - no separate `permission_handler` dependency
  /// needed), so no bespoke pre-permission dialog is built here.
  Future<bool> _initSpeech() async {
    setState(() {
      _initializingSpeech = true;
      _speechError = null;
    });
    var available = false;
    try {
      available = await _speechToText.initialize(
        onStatus: _onSpeechStatus,
        onError: (error) {
          if (!mounted) return;
          setState(() {
            _listening = false;
            _speechError = 'Speech recognition error: ${error.errorMsg}';
          });
        },
      );
    } catch (_) {
      // No platform implementation at all (shouldn't be reachable given
      // `_voiceInputPlatformSupported`'s own gating, but caught rather than
      // assumed - "disabled gracefully, not crashing" per this workstream's
      // own requirement) or a genuine device-level failure either way.
      available = false;
    }
    if (!mounted) return available;
    setState(() {
      _speechAvailable = available;
      _initializingSpeech = false;
      if (!available) _speechError = "Speech recognition isn't available on this device.";
    });
    return available;
  }

  /// Fires on every status change `speech_to_text` itself reports -
  /// covers both a user-initiated stop (`_toggleListening`'s own
  /// `_speechToText.stop()` call) and the plugin's own silence-timeout
  /// auto-stop, which `_toggleListening` never sees directly. One place to
  /// commit `_lastRecognizedWords` into the real input field, rather than
  /// duplicating that in both stop paths.
  void _onSpeechStatus(String status) {
    if (!mounted) return;
    if (status == 'notListening' || status == 'done') {
      if (_lastRecognizedWords.isNotEmpty) {
        _inputController.text = _lastRecognizedWords;
        _inputController.selection = TextSelection.collapsed(offset: _inputController.text.length);
      }
      setState(() => _listening = false);
    }
  }

  Future<void> _toggleListening() async {
    if (_listening) {
      await _speechToText.stop();
      return; // `_onSpeechStatus` commits the recognized text and flips `_listening` off once the plugin confirms the stop.
    }
    if (_speechAvailable == null) {
      final available = await _initSpeech();
      if (!available || !mounted) return;
    } else if (_speechAvailable == false) {
      return;
    }
    _lastRecognizedWords = '';
    try {
      await _speechToText.listen(onResult: (result) => _lastRecognizedWords = result.recognizedWords);
      if (!mounted) return;
      setState(() => _listening = true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _speechError = 'Could not start listening: $e');
    }
  }

  void _adjust() {
    setState(() {
      _proposedPlan = null;
      _stepStatuses = null;
      _preflightResults = null;
      _finishedOutcome = null;
      _generateError = null;
      _generatedPartId = null;
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
      _preflightResults = null;
      _finishedOutcome = null;
      _generatedPartId = null;
      _stepStatuses = List.filled(plan.steps.length, TranslationStepStatus.pending);
    });
    try {
      // Existing-Part editing / mid-conversation retry: reuse
      // `_activePartId` directly - CRITICAL that this branch never calls
      // `startNewDocument`/`createPart` (see this method's own doc comment
      // on the class): `startNewDocument` would reset the session's entire
      // Document, wiping the real Part this conversation is meant to be
      // continuing, and `createPart` would silently generate for an
      // orphaned, unrelated Part instead. Covers two cases identically:
      // `widget.existingPartId` ("Continue with AI") and `_pendingRetryPartId`
      // (a plain fresh-Part conversation retrying after a stopped run - see
      // that field's own doc comment for why this is a bug fix, not new
      // scope).
      final String partId;
      if (_activePartId != null) {
        partId = _activePartId!;
      } else {
        // Bug fix (on-device feedback): AI Modelling always starts a
        // brand-new Part (see this screen's own class doc comment) -
        // without resetting the session's Document first, this Part would
        // just pile onto whatever Document a previous tool-chooser entry
        // already created this session (see `DocumentApiClient.
        // startNewDocument`'s own doc comment). Skipped entirely whenever
        // `_activePartId` is set, above.
        await _documentApi.startNewDocument();
        final part = await _documentApi.createPart('AI Modelling Part');
        partId = part.id;
      }
      final translator = PlanTranslator(
        documentApi: _documentApi,
        sketchApi: _sketchApi,
        storageService: widget.storageService,
        projectRoot: widget.projectRoot,
      );
      final result = await translator.execute(
        plan: plan,
        partId: partId,
        existingFeatures: _existingFeatures ?? const [],
        disabledKinds: AiSystemPromptPreferences.disabledKinds,
        onStepStatusChanged: (index, status) {
          if (!mounted) return;
          setState(() => _stepStatuses![index] = status);
        },
      );
      if (!mounted) return;
      final isStopped = result.outcome == PlanTranslationOutcome.stepFailed ||
          result.outcome == PlanTranslationOutcome.gearRequestEncountered;
      setState(() {
        _generating = false;
        _finishedOutcome = result.outcome;
        _preflightResults = result.preflightResults;
        if (result.outcome == PlanTranslationOutcome.success) _generatedPartId = partId;
        if (result.createdFeatureIds.isNotEmpty) {
          _lastRunPartId = partId;
          _lastRunCreatedFeatureIds = result.createdFeatureIds;
        }
        if (isStopped) {
          _pendingRetryPartId = partId;
        } else if (result.outcome == PlanTranslationOutcome.success && widget.existingPartId == null) {
          // A fresh-Part retry that finally succeeded - see
          // `_pendingRetryPartId`'s own doc comment for why this resets
          // rather than keeps targeting the same Part indefinitely.
          _pendingRetryPartId = null;
        }
      });
      if (isStopped) {
        // So the *next* prompt/Generate see what was actually built before
        // this stop, not a stale snapshot - `_appendStoppedRunToTranscript`
        // itself doesn't need to be async, so this runs first.
        await _refreshExistingPartContext(partId);
        _appendStoppedRunToTranscript(plan, result);
      } else if (result.outcome == PlanTranslationOutcome.success) {
        if (widget.existingPartId != null) {
          // Continue with AI: refresh so a further message in this same
          // conversation sees what was just built, not the initState
          // snapshot from before this Generate.
          await _refreshExistingPartContext(partId);
        } else {
          // A fresh-Part retry that finally succeeded (or a plain first-
          // time success, where these were already null) - back to true
          // fresh-Part context for any further, unrelated request.
          setState(() {
            _existingFeatures = null;
            _existingPartSummary = null;
          });
        }
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
  ///
  /// This message's own "propose a revised plan for the remaining steps"
  /// promise only became true with the [_pendingRetryPartId] fix (see the
  /// class's own doc comment) - the caller (`_generate`) sets it and
  /// refreshes [_existingPartSummary] *before* calling this, so the next
  /// `_send()` call already carries the "Editing an existing Part" block
  /// naming this same in-progress Part's real current Features.
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

  /// Multi-part/assembly overhaul, Phase D
  /// (`docs/ai-modelling/13-multi-part-assembly-overhaul.md`): a
  /// `part_manifest` was just detected in `_send()` - stash it and build
  /// one editable `TextEditingController` pair per part (name/type prefix)
  /// for the confirm panel (`_buildManifestConfirm`). Called from inside
  /// `_send()`'s own `setState`, so this mutates fields directly rather
  /// than calling `setState` itself.
  void _setPartManifest(AiPartManifest manifest) {
    for (final controller in _manifestNameControllers) {
      controller.dispose();
    }
    for (final controller in _manifestPrefixControllers) {
      controller.dispose();
    }
    _partManifest = manifest;
    _manifestNameControllers = [for (final part in manifest.parts) TextEditingController(text: part.name)];
    _manifestPrefixControllers = [for (final part in manifest.parts) TextEditingController(text: part.typePrefix)];
  }

  /// "Back to chat" from the confirm-parts panel, before any generation has
  /// started - discards the manifest entirely; the conversation (already in
  /// `_transcript`) is untouched, so the user can ask the assistant to
  /// revise the breakdown and get a fresh manifest.
  void _cancelPartManifest() {
    for (final controller in _manifestNameControllers) {
      controller.dispose();
    }
    for (final controller in _manifestPrefixControllers) {
      controller.dispose();
    }
    setState(() {
      _partManifest = null;
      _manifestNameControllers = [];
      _manifestPrefixControllers = [];
      _existingAssemblyFileOptions = [];
      _assemblyTargetRelativePath = null;
    });
  }

  /// "Confirm & Generate All" - folds whatever edits were made to the
  /// name/type-prefix fields back into the manifest, then starts the N
  /// sequential single-Part cycles (this workstream's own Locked
  /// architecture decision) at part 0.
  Future<void> _confirmManifestAndGenerateAll() async {
    final manifest = _partManifest;
    if (manifest == null || _orchestrating) return;
    final edited = AiPartManifest(
      parts: [
        for (var i = 0; i < manifest.parts.length; i++)
          AiPartManifestEntry(
            name: _manifestNameControllers[i].text.trim().isEmpty
                ? manifest.parts[i].name
                : _manifestNameControllers[i].text.trim(),
            typePrefix: _manifestPrefixControllers[i].text.trim().isEmpty
                ? manifest.parts[i].typePrefix
                : _manifestPrefixControllers[i].text.trim(),
            summary: manifest.parts[i].summary,
          ),
      ],
    );
    setState(() {
      _partManifest = edited;
      _orchestrating = true;
      _currentPartIndex = 0;
      _savedAssemblyParts = [];
      _orchestrationError = null;
    });
    await _runPartCycle(0);
  }

  /// Gap-closure (`13-...md`'s own D-1): refreshes this Part's existing-
  /// Feature context (so the LLM's revised plan sees what's actually
  /// already there - same reasoning `_generate`'s own `_pendingRetryPartId`
  /// fix already established) and marks `partId` as the target for the
  /// *next* `_runPartCycle`/`_runAssemblyCycle` call, instead of creating a
  /// brand-new Part and silently orphaning this one. `saveOnly: true` for a
  /// cancelled save (the Part/plan are already valid - only the save-path
  /// prompt needs retrying, no LLM round-trip needed); `false` for every
  /// other failure (validation, a real step failure, a gear-request stop, a
  /// provider/API/storage error) - those need a revised plan first.
  Future<void> _prepareOrchestrationRetry({required String partId, required bool saveOnly, required bool isAssembly}) async {
    await _refreshExistingPartContext(partId);
    if (!mounted) return;
    setState(() {
      if (isAssembly) {
        _assemblyRetryPartId = partId;
      } else {
        _orchestrationRetryPartId = partId;
      }
      _orchestrationRetryIsSaveOnly = saveOnly;
    });
  }

  void _clearPartRetryState() {
    if (_orchestrationRetryPartId == null && !_orchestrationRetryIsSaveOnly) return;
    setState(() {
      _orchestrationRetryPartId = null;
      _orchestrationRetryIsSaveOnly = false;
    });
  }

  void _clearAssemblyRetryState() {
    if (_assemblyRetryPartId == null && !_orchestrationRetryIsSaveOnly) return;
    setState(() {
      _assemblyRetryPartId = null;
      _orchestrationRetryIsSaveOnly = false;
    });
  }

  /// Appends a `user`-role turn describing an orchestration failure that
  /// isn't a real step failure/gear-request stop (those reuse
  /// `_appendStoppedRunToTranscript` directly, unchanged) - a validation
  /// failure before anything was created, no plan detected, a cancelled
  /// save, or a provider/API/storage error. Same "real information fed to
  /// the LLM" framing `_appendStoppedRunToTranscript` already established.
  void _appendOrchestrationFailureToTranscript(String message) {
    setState(() => _transcript = [..._transcript, AiChatMessage(role: AiMessageRole.user, text: message)]);
    _scrollToBottom();
  }

  /// The "propose a filename -> human save-confirm -> save for real ->
  /// record and advance" tail shared by a part cycle's first attempt and a
  /// save-only retry (`_orchestrationRetryIsSaveOnly`) - factored out so
  /// both paths save identically rather than risk drifting apart.
  Future<void> _savePartAfterExecution({
    required int index,
    required AiPartManifestEntry entry,
    required String partId,
    required ProjectRoot root,
    required StorageService storage,
  }) async {
    if (!mounted) return;
    final existingFiles = await storage.listFiles(root, extensionFilter: kNativeFileExtension);
    final proposedName = nextAvailablePartName(existingFiles, typePrefix: entry.typePrefix);
    setState(() => _orchestrationStatus = null);
    if (!mounted) return;
    final confirmedPath = await showRelativePathPromptDialog(
      context,
      title: 'Save "${entry.name}" as…',
      initialValue: proposedName,
      storageService: storage,
      root: root,
    );
    if (confirmedPath == null) {
      await _prepareOrchestrationRetry(partId: partId, saveOnly: true, isAssembly: false);
      _appendOrchestrationFailureToTranscript(
        'Save cancelled for "${entry.name}" - the part itself is already built; retrying just re-opens '
        'the save prompt, no revised plan needed.',
      );
      _stopOrchestrationWithError(
        'Save cancelled for "${entry.name}" - stopping. Already-saved parts are untouched; this '
        "part's own Features were created in this session but never written to disk.",
      );
      return;
    }

    if (!mounted) return;
    setState(() => _orchestrationStatus = 'Saving "${entry.name}"...');
    final assemblyClient = AssemblyDocumentClient(storageService: storage, documentApiClient: _documentApi);
    await assemblyClient.savePart(root, partId, confirmedPath);

    if (!mounted) return;
    _clearPartRetryState();
    setState(() {
      _savedAssemblyParts = [
        ..._savedAssemblyParts,
        _SavedAssemblyPart(name: entry.name, relativePath: confirmedPath, partId: partId),
      ];
      _currentPartIndex = index + 1;
      _orchestrationStatus = null;
      _orchestrationStepStatuses = null;
    });
    await _runPartCycle(_currentPartIndex);
  }

  /// One full part cycle: ask the assistant for exactly this one part's
  /// plan (a synthetic, visible `user`-role turn - "real information fed
  /// to the LLM", the same framing `_appendStoppedRunToTranscript` already
  /// established), dry-run validate + execute it against a brand-new real
  /// Part (`PlanTranslator`, completely unchanged - this workstream's own
  /// Locked decision), propose a collision-free filename
  /// (`nextAvailablePartName`), get a human save-confirm
  /// (`showRelativePathPromptDialog`, Phase 15's own dialog, reused as-is),
  /// then save it for real (`AssemblyDocumentClient.savePart`) before
  /// recursing into the next part. Any failure at any point stops the
  /// whole orchestration rather than silently skipping ahead - matches
  /// `00-conventions.md`'s own no-auto-rollback posture: whatever was
  /// already saved stays saved, whatever this one cycle created but didn't
  /// reach a real save for stays only in the backend's in-memory session
  /// (never written to disk, so there's nothing on disk to clean up).
  ///
  /// Gap-closure (`13-...md`'s own D-1): a retry (`_orchestrationRetryPartId`
  /// set by `_retryOrchestration`) reuses the same in-progress Part instead
  /// of creating a new one, and - unless this is a save-only retry after a
  /// cancelled save, which needs no LLM round-trip at all - asks the LLM for
  /// a *revised* plan (the failure was already appended to `_transcript` as
  /// its own turn) rather than blindly re-running the identical steps that
  /// just failed.
  Future<void> _runPartCycle(int index) async {
    final manifest = _partManifest;
    if (manifest == null || !mounted) return;
    if (index >= manifest.parts.length) {
      _finishPartOrchestration();
      return;
    }
    final root = widget.projectRoot;
    final storage = widget.storageService;
    if (root == null || storage == null) {
      _stopOrchestrationWithError(
        'Assembly mode needs an open project folder to save parts - reopen AI Modelling from an '
        'entry point that provides one.',
      );
      return;
    }
    final entry = manifest.parts[index];
    final retryPartId = _orchestrationRetryPartId;

    if (retryPartId != null && _orchestrationRetryIsSaveOnly) {
      try {
        await _savePartAfterExecution(index: index, entry: entry, partId: retryPartId, root: root, storage: storage);
      } on ApiException catch (e) {
        _stopOrchestrationWithError('Error while saving "${entry.name}": ${e.message}');
      } on StorageException catch (e) {
        _stopOrchestrationWithError('Could not save "${entry.name}": ${e.message}');
      }
      return;
    }

    final provider = widget.provider ?? AiProviderPreferences.active;
    final requestMessage = AiChatMessage(
      role: AiMessageRole.user,
      text: retryPartId == null
          ? assemblyModePartRequestText(index: index, total: manifest.parts.length, name: entry.name, summary: entry.summary)
          : assemblyModePartRetryRequestText(name: entry.name),
    );
    setState(() {
      _transcript = [..._transcript, requestMessage];
      _orchestrationStatus =
          retryPartId == null ? 'Requesting the plan for "${entry.name}"...' : 'Requesting a revised plan for "${entry.name}"...';
      _orchestrationError = null;
    });
    _scrollToBottom();
    String? partId = retryPartId;
    try {
      final result = await provider.sendScopingTurn(_transcript, systemPrompt: _buildSystemPrompt());
      final assistantMessage = AiChatMessage(role: AiMessageRole.assistant, text: result.assistantText);
      if (!mounted) return;
      setState(() => _transcript = [..._transcript, assistantMessage]);
      _scrollToBottom();

      final plan = detectPlanInAssistantText(result.assistantText);
      if (plan == null) {
        _appendOrchestrationFailureToTranscript(
          'That reply was not a plan for "${entry.name}" - please reply with an ordinary plan for this '
          'part only, as described in the Assembly mode instructions.',
        );
        _stopOrchestrationWithError(
          'The assistant did not reply with a plan for "${entry.name}" - stopping. Press Retry to ask '
          'again, or continue this conversation manually.',
        );
        return;
      }

      if (partId == null) {
        if (!mounted) return;
        setState(() => _orchestrationStatus = 'Creating "${entry.name}"...');
        final part = await _documentApi.createPart(entry.name);
        partId = part.id;
      }

      if (!mounted) return;
      setState(() {
        _orchestrationStatus = 'Validating and building "${entry.name}"...';
        _orchestrationStepStatuses = List.filled(plan.steps.length, TranslationStepStatus.pending);
      });
      final translator = PlanTranslator(
        documentApi: _documentApi,
        sketchApi: _sketchApi,
        storageService: widget.storageService,
        projectRoot: widget.projectRoot,
      );
      final translation = await translator.execute(
        plan: plan,
        partId: partId,
        existingFeatures: retryPartId != null ? (_existingFeatures ?? const []) : const [],
        disabledKinds: AiSystemPromptPreferences.disabledKinds,
        onStepStatusChanged: (stepIndex, status) {
          if (!mounted) return;
          setState(() => _orchestrationStepStatuses![stepIndex] = status);
        },
      );
      if (translation.outcome != PlanTranslationOutcome.success) {
        final message = switch (translation.outcome) {
          PlanTranslationOutcome.validationFailed =>
            'Validation failed for "${entry.name}" - stopping before creating anything for this part.',
          PlanTranslationOutcome.stepFailed =>
            'Execution failed for "${entry.name}": ${translation.errorMessage}. Steps before the '
                'failure were created but never saved to disk.',
          PlanTranslationOutcome.gearRequestEncountered =>
            'The assistant proposed a gear step for "${entry.name}", which Assembly mode cannot '
                'create automatically yet - use the Gear Design tool separately for this part.',
          PlanTranslationOutcome.success => '',
        };
        await _prepareOrchestrationRetry(partId: partId, saveOnly: false, isAssembly: false);
        if (translation.outcome == PlanTranslationOutcome.stepFailed ||
            translation.outcome == PlanTranslationOutcome.gearRequestEncountered) {
          _appendStoppedRunToTranscript(plan, translation);
        } else {
          _appendOrchestrationFailureToTranscript(
            'Validation failed for "${entry.name}" before anything was created: please propose a '
            'revised plan for this part.',
          );
        }
        _stopOrchestrationWithError(message);
        return;
      }

      await _savePartAfterExecution(index: index, entry: entry, partId: partId, root: root, storage: storage);
    } on ApiException catch (e) {
      if (partId != null) await _prepareOrchestrationRetry(partId: partId, saveOnly: false, isAssembly: false);
      _appendOrchestrationFailureToTranscript(
        'Error while working on "${entry.name}": ${e.message}. Please propose a revised plan for this part.',
      );
      _stopOrchestrationWithError('Error while working on "${entry.name}": ${e.message}');
    } on AiProviderException catch (e) {
      _stopOrchestrationWithError('Provider error while requesting the plan for "${entry.name}": ${e.message}');
    } on StorageException catch (e) {
      if (partId != null) await _prepareOrchestrationRetry(partId: partId, saveOnly: false, isAssembly: false);
      _appendOrchestrationFailureToTranscript(
        'Could not save "${entry.name}": ${e.message}. Please propose a revised plan for this part.',
      );
      _stopOrchestrationWithError('Could not save "${entry.name}": ${e.message}');
    }
  }

  /// Every part saved successfully - stop advancing per-part and move
  /// straight into the assembly cycle (`_runAssemblyCycle`, Phase E). The
  /// orchestration panel itself (`_buildOrchestrationProgress`) detects
  /// "parts done" by `_currentPartIndex >= manifest.parts.length` and
  /// switches from the per-part list to the "Assembly" row; `unawaited`
  /// because this method itself stays synchronous (called unawaited from
  /// the tail of `_runPartCycle`) - `_runAssemblyCycle` drives its own
  /// `setState` calls exactly like `_runPartCycle` does.
  void _finishPartOrchestration() {
    if (!mounted) return;
    setState(() => _orchestrationStatus = null);
    unawaited(_runAssemblyCycle());
  }

  /// The assembly-cycle equivalent of `_savePartAfterExecution` - propose a
  /// filename, human save-confirm, save for real, record. Shared by the
  /// first attempt and a save-only retry after a cancelled save.
  ///
  /// Gap-closure (`13-...md`'s own E-1): [fixedRelativePath] is set when
  /// inserting into an already-existing assembly file
  /// (`_assemblyTargetRelativePath`) - the save-confirm dialog is still
  /// shown (this app's own "save gate" - a human always confirms/edits the
  /// path before anything real is written, even here), just pre-filled
  /// with the file being overwritten instead of a freshly proposed
  /// collision-free name; `showRelativePathPromptDialog`'s own existing
  /// collision-warning UI ("A file already exists at this path...") already
  /// covers making that overwrite visible, no separate confirmation needed.
  Future<void> _saveAssemblyAfterExecution({
    required String assemblyPartId,
    required ProjectRoot root,
    required StorageService storage,
    String? fixedRelativePath,
  }) async {
    if (!mounted) return;
    final proposedName = fixedRelativePath ??
        nextAvailablePartName(await storage.listFiles(root, extensionFilter: kNativeFileExtension), typePrefix: 'ASSEMBLY');
    setState(() => _orchestrationStatus = null);
    if (!mounted) return;
    final confirmedPath = await showRelativePathPromptDialog(
      context,
      title: 'Save assembly as…',
      initialValue: proposedName,
      storageService: storage,
      root: root,
    );
    if (confirmedPath == null) {
      await _prepareOrchestrationRetry(partId: assemblyPartId, saveOnly: true, isAssembly: true);
      _appendOrchestrationFailureToTranscript(
        'Save cancelled for the assembly - it is already built; retrying just re-opens the save '
        'prompt, no revised plan needed.',
      );
      _stopOrchestrationWithError(
        'Save cancelled for the assembly - stopping. Every part above is already saved; the '
        "assembly's own Features/Occurrences were created in this session but never written to disk.",
      );
      return;
    }

    if (!mounted) return;
    setState(() => _orchestrationStatus = 'Saving the assembly...');
    final assemblyClient = AssemblyDocumentClient(storageService: storage, documentApiClient: _documentApi);
    await assemblyClient.savePart(root, assemblyPartId, confirmedPath);

    if (!mounted) return;
    _clearAssemblyRetryState();
    setState(() {
      _assemblyPartId = assemblyPartId;
      _assemblyRelativePath = confirmedPath;
      _orchestrationStatus = null;
      _orchestrationStepStatuses = null;
    });
  }

  /// Phase E: the one further plan/execute/save cycle that runs once every
  /// part above is saved - authored by the LLM against a system prompt
  /// listing exactly the parts just saved (their real `relative_path`s,
  /// passed directly here rather than relying on `_availableComponentFilesSummary`,
  /// which is only ever refreshed once in `initState` and so could be stale
  /// by the time an orchestration run actually finishes saving new files -
  /// this workstream's own Phase D note on why a fresh disk scan can't be
  /// trusted for this). Creates a brand-new assembly Part the same way
  /// `_runPartCycle` creates each part's own Part - a dedicated
  /// new-or-reused assembly Part is a real product question this pass
  /// doesn't attempt (see the plan doc's own Phase E writeup); this always
  /// starts a fresh one. Mirrors `_runPartCycle`'s own
  /// plan-request/create/validate-execute/propose-name/confirm/save shape
  /// one level up (one assembly instead of one part), including its
  /// no-auto-rollback-on-failure posture and its retry behavior (E-2's own
  /// half of the same gap-closure as `_runPartCycle`'s own D-1 doc comment).
  Future<void> _runAssemblyCycle() async {
    final root = widget.projectRoot;
    final storage = widget.storageService;
    if (root == null || storage == null || _savedAssemblyParts.isEmpty || !mounted) return;
    final retryPartId = _assemblyRetryPartId;

    if (retryPartId != null && _orchestrationRetryIsSaveOnly) {
      setState(() => _orchestrationError = null);
      try {
        await _saveAssemblyAfterExecution(assemblyPartId: retryPartId, root: root, storage: storage, fixedRelativePath: _assemblyTargetRelativePath);
      } on ApiException catch (e) {
        _stopOrchestrationWithError('Error while saving the assembly: ${e.message}');
      } on StorageException catch (e) {
        _stopOrchestrationWithError('Could not save the assembly: ${e.message}');
      }
      return;
    }

    setState(() {
      _buildingAssembly = true;
      _orchestrationStatus = retryPartId == null ? 'Requesting the assembly plan...' : 'Requesting a revised assembly plan...';
      _orchestrationError = null;
    });
    _scrollToBottom();
    final partsListing = [
      for (var i = 0; i < _savedAssemblyParts.length; i++)
        '${i + 1}. ${_savedAssemblyParts[i].relativePath} - "${_savedAssemblyParts[i].name}"',
    ].join('\n');
    final targetPath = _assemblyTargetRelativePath;
    String? assemblyPartId = retryPartId;
    // Gap-closure (`13-...md`'s own E-1): when inserting into an existing
    // assembly file, open it *before* asking the LLM for a plan (not after,
    // like the brand-new-assembly path below) - the LLM needs to know which
    // components are already placed in it so its own `add_component`/`mate`
    // steps don't duplicate them, and the file to open is already known
    // (the user picked it on the manifest-confirm panel), so there's no
    // reason to wait for a plan first.
    var existingComponentsListing = '';
    if (assemblyPartId == null && targetPath != null) {
      try {
        setState(() => _orchestrationStatus = 'Opening "$targetPath"...');
        final assemblyClient = AssemblyDocumentClient(storageService: storage, documentApiClient: _documentApi);
        final opened = await assemblyClient.openAssembly(root, targetPath);
        assemblyPartId = opened.rootPartId;
        existingComponentsListing = opened.relativePathByPartId.entries
            .where((e) => e.key != opened.rootPartId)
            .map((e) => e.value)
            .join('\n');
      } on StorageException catch (e) {
        _stopOrchestrationWithError('Could not open "$targetPath": ${e.message}');
        return;
      } on ApiException catch (e) {
        _stopOrchestrationWithError('Could not open "$targetPath": ${e.message}');
        return;
      } on AssemblyGraphCycleException catch (e) {
        _stopOrchestrationWithError('Could not open "$targetPath": ${e.toString()}');
        return;
      }
    }
    final requestMessage = AiChatMessage(
      role: AiMessageRole.user,
      text: retryPartId != null
          ? assemblyModeAssemblyRetryRequestText()
          : targetPath == null
              ? assemblyModeAssemblyRequestText(partsListing)
              : assemblyModeAssemblyIntoExistingRequestText(
                  existingAssemblyPath: targetPath,
                  partsListing: partsListing,
                  existingComponentsListing: existingComponentsListing,
                ),
    );
    setState(() => _transcript = [..._transcript, requestMessage]);
    _scrollToBottom();
    try {
      final provider = widget.provider ?? AiProviderPreferences.active;
      final systemPrompt = buildAiScopingSystemPrompt(
        assistantInstructionsOverride: AiSystemPromptPreferences.override,
        enabledAddOns: AiSystemPromptPreferences.enabledAddOns,
        disabledToolGroups: AiSystemPromptPreferences.disabledToolGroups,
        existingPartSummary: _existingPartSummary,
        existingOccurrencesSummary: _existingOccurrencesSummary,
        availableComponentFilesSummary: partsListing,
        multiBodyPartMode: _mode == AiGenerationMode.multiBodyPart,
        assemblyMode: _mode == AiGenerationMode.assembly,
      );
      final result = await provider.sendScopingTurn(_transcript, systemPrompt: systemPrompt);
      final assistantMessage = AiChatMessage(role: AiMessageRole.assistant, text: result.assistantText);
      if (!mounted) return;
      setState(() => _transcript = [..._transcript, assistantMessage]);
      _scrollToBottom();

      final plan = detectPlanInAssistantText(result.assistantText);
      if (plan == null) {
        _appendOrchestrationFailureToTranscript(
          'That reply was not an assembly plan - please reply with an ordinary plan placing and mating '
          'the saved parts, as described in the Assembly mode instructions.',
        );
        _stopOrchestrationWithError(
          'The assistant did not reply with an assembly plan - stopping. Press Retry to ask again, or '
          'continue this conversation manually.',
        );
        return;
      }

      if (assemblyPartId == null) {
        if (!mounted) return;
        setState(() => _orchestrationStatus = 'Creating the assembly...');
        final assemblyPart = await _documentApi.createPart('Assembly');
        assemblyPartId = assemblyPart.id;
      }

      if (!mounted) return;
      setState(() {
        _orchestrationStatus = 'Validating and building the assembly...';
        _orchestrationStepStatuses = List.filled(plan.steps.length, TranslationStepStatus.pending);
      });
      final translator = PlanTranslator(
        documentApi: _documentApi,
        sketchApi: _sketchApi,
        storageService: storage,
        projectRoot: root,
      );
      final translation = await translator.execute(
        plan: plan,
        partId: assemblyPartId,
        existingFeatures: retryPartId != null ? (_existingFeatures ?? const []) : const [],
        disabledKinds: AiSystemPromptPreferences.disabledKinds,
        onStepStatusChanged: (stepIndex, status) {
          if (!mounted) return;
          setState(() => _orchestrationStepStatuses![stepIndex] = status);
        },
      );
      if (translation.outcome != PlanTranslationOutcome.success) {
        final message = switch (translation.outcome) {
          PlanTranslationOutcome.validationFailed =>
            'Validation failed for the assembly plan - stopping. Every part above is already saved.',
          PlanTranslationOutcome.stepFailed =>
            'Execution failed for the assembly: ${translation.errorMessage}. Steps before the failure '
                'were created but never saved to disk.',
          PlanTranslationOutcome.gearRequestEncountered =>
            'The assistant proposed a gear step for the assembly, which cannot be created '
                'automatically yet.',
          PlanTranslationOutcome.success => '',
        };
        await _prepareOrchestrationRetry(partId: assemblyPartId, saveOnly: false, isAssembly: true);
        if (translation.outcome == PlanTranslationOutcome.stepFailed ||
            translation.outcome == PlanTranslationOutcome.gearRequestEncountered) {
          _appendStoppedRunToTranscript(plan, translation);
        } else {
          _appendOrchestrationFailureToTranscript(
            'Validation failed for the assembly plan before anything was created: please propose a '
            'revised assembly plan.',
          );
        }
        _stopOrchestrationWithError(message);
        return;
      }

      await _saveAssemblyAfterExecution(assemblyPartId: assemblyPartId, root: root, storage: storage, fixedRelativePath: _assemblyTargetRelativePath);
    } on ApiException catch (e) {
      if (assemblyPartId != null) await _prepareOrchestrationRetry(partId: assemblyPartId, saveOnly: false, isAssembly: true);
      _appendOrchestrationFailureToTranscript(
        'Error while building the assembly: ${e.message}. Please propose a revised assembly plan.',
      );
      _stopOrchestrationWithError('Error while building the assembly: ${e.message}');
    } on AiProviderException catch (e) {
      _stopOrchestrationWithError('Provider error while requesting the assembly plan: ${e.message}');
    } on StorageException catch (e) {
      if (assemblyPartId != null) await _prepareOrchestrationRetry(partId: assemblyPartId, saveOnly: false, isAssembly: true);
      _appendOrchestrationFailureToTranscript(
        'Could not save the assembly: ${e.message}. Please propose a revised assembly plan.',
      );
      _stopOrchestrationWithError('Could not save the assembly: ${e.message}');
    }
  }

  /// "Open Assembly" - navigates into `PartScreen` for the just-saved
  /// assembly Part with `AssemblyLens.assembly` already active, the same
  /// "fresh screen, not a reload in place" shape every other multi-file
  /// navigation on `PartScreen` itself already uses (see
  /// `PartScreen._openComposedProject`'s own precedent). Carries `initialProjectRoot`/
  /// `initialRelativePathByPartId` through for every part this run saved
  /// (the assembly's own path included) so a subsequent "Save All" on the
  /// new screen already knows where each of them lives, instead of prompting
  /// again for files this same run just wrote.
  void _openAssembly() {
    final assemblyPartId = _assemblyPartId;
    final assemblyPath = _assemblyRelativePath;
    final root = widget.projectRoot;
    if (assemblyPartId == null || assemblyPath == null || root == null || !mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PartScreen(
          documentApi: widget.documentApi,
          storageService: widget.storageService,
          initialPartId: assemblyPartId,
          initialProjectRoot: root,
          initialRelativePathByPartId: {
            for (final part in _savedAssemblyParts) part.partId: part.relativePath,
            assemblyPartId: assemblyPath,
          },
          initialLens: AssemblyLens.assembly,
        ),
      ),
    );
  }

  /// Stops the orchestration on any failure - `_orchestrating` stays
  /// `true` so the panel keeps showing exactly where it stopped and why,
  /// rather than silently dropping back to chat. Gap-closure (`13-...md`'s
  /// own D-1/E-2): `_retryOrchestration` (wired to a "Retry" button in
  /// `_buildOrchestrationProgress`, enabled whenever `_canRetryOrchestration`
  /// is true) is now a real second way out from here, alongside
  /// `_dismissOrchestration`.
  void _stopOrchestrationWithError(String message) {
    if (!mounted) return;
    setState(() {
      _orchestrationStatus = null;
      _orchestrationError = message;
    });
  }

  /// Whether "Retry" can do anything useful right now - only once a real
  /// failure has actually stopped the run. Unlike the coarser
  /// `_orchestrationError != null` check, this doesn't gate on which Part
  /// the retry targets: `_runPartCycle`/`_runAssemblyCycle` correctly
  /// handle a `null` retry-part-id themselves (a plain fresh request, for
  /// failures that happened before any Part existed yet - "no plan
  /// detected", "no project folder").
  bool get _canRetryOrchestration => _orchestrationError != null;

  /// Gap-closure (`13-...md`'s own D-1/E-2): re-enters whichever cycle was
  /// in flight when it stopped - `_runAssemblyCycle` once every part is
  /// already saved (`_currentPartIndex >= manifest.parts.length`, the same
  /// condition `_buildOrchestrationProgress` already uses to switch to the
  /// "Assembly" row), `_runPartCycle` otherwise. Both methods already know
  /// how to resume a retry (`_orchestrationRetryPartId`/
  /// `_assemblyRetryPartId`/`_orchestrationRetryIsSaveOnly`, set by
  /// `_prepareOrchestrationRetry` just before the failure that led here) -
  /// this only needs to call back into the right one.
  Future<void> _retryOrchestration() async {
    if (!_canRetryOrchestration) return;
    final manifest = _partManifest;
    if (manifest == null) return;
    if (_currentPartIndex >= manifest.parts.length) {
      await _runAssemblyCycle();
    } else {
      await _runPartCycle(_currentPartIndex);
    }
  }

  /// "Back to chat" from either the finished or the stopped-with-error
  /// state - the transcript (every real turn exchanged, including
  /// whichever part-request turns actually ran) is left untouched, so the
  /// user can keep chatting normally afterward. Also clears any pending
  /// retry state (`_orchestrationRetryPartId`/`_assemblyRetryPartId`/
  /// `_orchestrationRetryIsSaveOnly`) - a genuine "give up" here must mean a
  /// later, unrelated Generate press starts a real fresh Part again, not
  /// silently reuse this abandoned one.
  void _dismissOrchestration() {
    for (final controller in _manifestNameControllers) {
      controller.dispose();
    }
    for (final controller in _manifestPrefixControllers) {
      controller.dispose();
    }
    setState(() {
      _orchestrating = false;
      _partManifest = null;
      _manifestNameControllers = [];
      _manifestPrefixControllers = [];
      _existingAssemblyFileOptions = [];
      _assemblyTargetRelativePath = null;
      _currentPartIndex = 0;
      _savedAssemblyParts = [];
      _orchestrationStatus = null;
      _orchestrationError = null;
      _orchestrationStepStatuses = null;
      _orchestrationRetryPartId = null;
      _assemblyRetryPartId = null;
      _orchestrationRetryIsSaveOnly = false;
      _buildingAssembly = false;
      _assemblyPartId = null;
      _assemblyRelativePath = null;
    });
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
        // The partial build this retry state pointed at is gone - a
        // genuinely fresh Part is correct again on the next Generate press
        // (see `_pendingRetryPartId`'s own doc comment). Never touched in
        // Continue-with-AI mode, where `_activePartId` always prefers
        // `widget.existingPartId` regardless.
        if (widget.existingPartId == null) _pendingRetryPartId = null;
      });
      if (widget.existingPartId != null) {
        // Continue with AI: the real Part still exists, just with fewer
        // Features now - refresh rather than clear.
        await _refreshExistingPartContext(widget.existingPartId!);
      } else {
        setState(() {
          _existingFeatures = null;
          _existingPartSummary = null;
        });
      }
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
      _preflightResults = null;
      _finishedOutcome = null;
      _generateError = null;
      _generatedPartId = null;
    });
  }

  /// External-LLM hand-off (outbound leg, `ai_plan_export.dart`): packages
  /// the same system prompt/schema the in-app assistant already sends
  /// (`buildAiScopingSystemPrompt`, identical to `_send()`'s own call) plus
  /// the conversation so far, then lets the user either copy it or hand it
  /// off via the OS share sheet - the same `path_provider`/`share_plus`
  /// temp-file pattern `mesh_viewer_screen.dart`'s own mesh export already
  /// established, so the user can send it straight to an installed chat
  /// app, AirDrop it, or save it to Files.
  Future<void> _shareExternalHandoff() async {
    final systemPrompt = _buildSystemPrompt();
    final package = buildExternalHandoffPackage(systemPrompt: systemPrompt, transcript: _transcript);
    if (!mounted) return;

    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Share with external AI'),
        content: const Text(
          'Send this conversation to another AI chat app (Claude, ChatGPT, Gemini, '
          'etc.) to use its own usage limits, then bring the finished plan back with '
          '"Import plan".',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(context).pop('copy'), child: const Text('Copy text')),
          FilledButton(onPressed: () => Navigator.of(context).pop('share'), child: const Text('Share / Save file')),
        ],
      ),
    );
    if (choice == null) return;

    if (choice == 'copy') {
      await Clipboard.setData(ClipboardData(text: package));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied to clipboard')));
      return;
    }

    try {
      final tempDir = await getTemporaryDirectory();
      final path = '${tempDir.path}/didsa-cad-ai-handoff.md';
      await File(path).writeAsString(package);
      if (!mounted) return;
      await Share.shareXFiles([XFile(path)], subject: 'DIDSA-CAD AI Modelling hand-off');
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not share: $error')));
    }
  }

  /// External-LLM hand-off (inbound leg): reads a plan JSON back in from a
  /// file - either a bare `.json` (parsed directly, for a precise error if
  /// it's malformed/truncated) or an `.md`/`.txt` export from a web LLM that
  /// wrapped the JSON in a fenced code block or surrounding prose (handled
  /// by the same `detectPlanInAssistantText` fallback the in-app chat
  /// response path already uses, `ai_plan_detection.dart`). On success this
  /// jumps straight to Review & Generate, exactly like a plan detected from
  /// a live chat turn - the same pre-flight validation gate
  /// (`PlanTranslator.execute`) runs before Generate does anything real
  /// either way. Unlike `_loadPreset`'s silent `catch (_) { return; }`, a
  /// failed import shows the real parse error - the file_picker call itself
  /// mirrors `_attachImage`'s pattern.
  Future<void> _importPlanFromFile() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['json', 'md', 'txt']);
    if (result == null) return;
    final path = result.files.single.path;
    if (path == null) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Could not import plan'),
          content: Text('Could not access "${result.files.single.name}" - no local file path was returned.'),
          actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK'))],
        ),
      );
      return;
    }

    final text = await File(path).readAsString();
    AiGenerationPlan? plan;
    String? parseError;
    try {
      final decoded = jsonDecode(text.trim());
      if (decoded is Map<String, dynamic> && decoded['steps'] is List) {
        plan = AiGenerationPlan.fromJson(decoded);
      }
    } catch (e) {
      parseError = e.toString();
    }
    plan ??= detectPlanInAssistantText(text);

    if (plan == null) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Could not import plan'),
          content: Text(
            parseError == null
                ? 'No valid plan JSON was found in this file.'
                : 'No valid plan JSON was found in this file: $parseError',
          ),
          actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK'))],
        ),
      );
      return;
    }

    final importedPlan = plan;
    if (!mounted) return;
    setState(() {
      _transcript = [..._transcript, AiChatMessage(role: AiMessageRole.assistant, text: text)];
      _proposedPlan = importedPlan;
      _stepStatuses = null;
      _preflightResults = null;
      _finishedOutcome = null;
      _generateError = null;
      _generatedPartId = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isFreshConversation = _transcript.isEmpty && _proposedPlan == null;
    // Multi-part/assembly overhaul, Phase D: neither the manifest-confirm
    // panel nor the orchestration-progress panel is "plain chat" - the
    // chat-only app-bar actions (preset load/share/import, all plan-JSON-
    // shaped) don't fit either state.
    final isPlainChat = _proposedPlan == null && _partManifest == null && !_orchestrating;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existingPartId != null ? 'Continue with AI' : 'AI Modelling'),
        actions: [
          if (isFreshConversation)
            IconButton(icon: const Icon(Icons.folder_open_outlined), tooltip: 'Load preset', onPressed: _loadPreset),
          if (isPlainChat) ...[
            IconButton(icon: const Icon(Icons.ios_share), tooltip: 'Share with external AI', onPressed: _shareExternalHandoff),
            IconButton(
              icon: const Icon(Icons.upload_file_outlined),
              tooltip: 'Import plan from file',
              onPressed: _importPlanFromFile,
            ),
          ],
        ],
      ),
      body: SafeArea(
        child: _proposedPlan != null
            ? _buildReviewAndGenerate(context, _proposedPlan!)
            : _orchestrating
                ? _buildOrchestrationProgress(context)
                : _partManifest != null
                    ? _buildManifestConfirm(context)
                    : _buildChat(context),
      ),
    );
  }

  Widget _buildChat(BuildContext context) {
    final provider = widget.provider ?? AiProviderPreferences.active;
    final visionSupported = provider.capabilities.supportsVision;
    return Column(
      children: [
        // Multi-part/assembly overhaul, Phase A
        // (`docs/ai-modelling/13-multi-part-assembly-overhaul.md`): only
        // shown for a fresh conversation - "Continue with AI"
        // (`widget.existingPartId != null`) already targets one specific
        // existing Part, which neither mode's own "recognize several
        // distinct parts" framing fits.
        if (widget.existingPartId == null) _buildModeToggle(),
        // Multi-part/assembly overhaul, Phases D/E: Assembly mode generates
        // and saves every recognized part as its own file, then
        // automatically builds, saves, and opens the mated assembly itself
        // (`_runAssemblyCycle`) - no manual "Insert Existing Component"/
        // "Add Mate" step required. Disclosed here so the user knows a
        // fresh assembly file is always created before they start (see
        // this workstream's own gap [E-1] for "insert into an existing
        // assembly instead").
        if (widget.existingPartId == null && _mode == AiGenerationMode.assembly)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: _Banner(
              key: const Key('aiModellingAssemblyModeBanner'),
              color: Colors.amber,
              text: 'Assembly mode generates and saves each recognized part as its own file, then '
                  'automatically builds, saves, and opens a new, real, mated assembly from them - no '
                  'manual insert/mate step needed.',
            ),
          ),
        if (_transcript.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              widget.existingPartId != null
                  ? 'Describe the change you want made to this Part. The AI can see its current '
                      'Features and can build on top of them - it never starts a new Part in this mode.'
                  : 'Describe the part you want to build. This always starts a brand-new '
                      'Part - it never modifies one that already exists.',
              style: const TextStyle(color: Colors.white54),
              textAlign: TextAlign.center,
            ),
          ),
        // Not gated on `widget.existingPartId` - `_refreshExistingPartContext`
        // can also fail during a plain fresh-Part conversation's own
        // mid-conversation retry (`_pendingRetryPartId`), and that failure
        // deserves the same visible banner.
        if (_existingFeaturesError != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              'Could not load this Part\'s current Features: $_existingFeaturesError',
              style: const TextStyle(color: Colors.redAccent),
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
        if (_providerConfigDialogDismissed && _providerUnconfigured)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              'No AI provider configured - open AI Provider Settings before sending a message.',
              style: TextStyle(color: Colors.white54),
            ),
          ),
        if (_pendingImages.isNotEmpty) _buildPendingImagePreview(),
        if (_imageError != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(_imageError!, style: const TextStyle(color: Colors.redAccent)),
          ),
        if (_speechError != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(_speechError!, style: const TextStyle(color: Colors.redAccent)),
          ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              // Workstream 10 (`10-image-input.md`): gated entirely on
              // `AiProviderCapabilities.supportsVision`, per
              // `06-image-input-deferred.md`'s own recorded decision - hidden
              // rather than shown-and-failing when the active provider isn't
              // vision-capable (the note below explains why, rather than the
              // button just silently not being there).
              if (visionSupported)
                IconButton(
                  key: const Key('aiModellingAttachImage'),
                  tooltip: 'Attach a hand sketch or engineering drawing',
                  onPressed: (_sending || _preparingImage) ? null : _attachImage,
                  icon: _preparingImage
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.image_outlined),
                ),
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
              // Workstream 11 (`11-voice-input.md`): hidden entirely on a
              // platform with no `speech_to_text` implementation at all
              // (Linux - see `_voiceInputPlatformSupported`'s own doc
              // comment), same "hidden, not shown-and-failing" gating
              // pattern the attach-image button above already established.
              // Shown (not hidden) on Windows despite that platform's own
              // upstream-beta status - its own tooltip says so instead.
              if (_voiceInputPlatformSupported)
                IconButton(
                  key: const Key('aiModellingMic'),
                  tooltip: _listening
                      ? 'Stop listening'
                      : (Platform.isWindows ? 'Voice input (Windows support is beta upstream)' : 'Voice input'),
                  onPressed: (_sending || _initializingSpeech || (_speechAvailable == false))
                      ? null
                      : _toggleListening,
                  icon: _initializingSpeech
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : Icon(_listening ? Icons.mic : Icons.mic_none, color: _listening ? Colors.redAccent : null),
                ),
              const SizedBox(width: 8),
              IconButton.filled(
                key: const Key('aiModellingSend'),
                onPressed: (_sending || (_providerConfigDialogDismissed && _providerUnconfigured)) ? null : _send,
                icon: const Icon(Icons.send),
              ),
            ],
          ),
        ),
        if (!visionSupported)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              'Image upload needs a vision-capable provider - not available for the active provider. '
              'Enable it in AI Provider Settings (OpenAI/Anthropic, or the "This model supports vision" '
              'checkbox for Local).',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ),
      ],
    );
  }

  /// A horizontal thumbnail strip, one entry per pending image - widened
  /// from a single fixed preview row in Phase B of the multi-part/assembly
  /// overhaul (`docs/ai-modelling/13-multi-part-assembly-overhaul.md`).
  /// Multi-part/assembly overhaul, Phase A
  /// (`docs/ai-modelling/13-multi-part-assembly-overhaul.md`): the
  /// per-conversation mode toggle. Assembly is rendered enabled (not
  /// hidden) despite being a stub this phase - selecting it is how the
  /// "coming soon" banner above gets shown at all, the same "let the user
  /// pick it and explain why it doesn't work yet" posture
  /// `showAssemblyAddMenu`'s own disabled-but-visible entries already use
  /// elsewhere in this app, rather than hiding a real, named capability.
  Widget _buildModeToggle() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: SegmentedButton<AiGenerationMode>(
          key: const Key('aiModellingModeToggle'),
          segments: const [
            ButtonSegment(
              value: AiGenerationMode.multiBodyPart,
              label: Text('Multi-body Part'),
              icon: Icon(Icons.view_in_ar_outlined),
            ),
            ButtonSegment(
              value: AiGenerationMode.assembly,
              label: Text('Assembly'),
              icon: Icon(Icons.account_tree_outlined),
            ),
          ],
          selected: {_mode},
          onSelectionChanged: (selection) => _setMode(selection.first),
        ),
      ),
    );
  }

  Widget _buildPendingImagePreview() {
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        itemCount: _pendingImages.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final image = _pendingImages[index];
          return Stack(
            clipBehavior: Clip.none,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Tooltip(
                  message: image.fileName,
                  child: Image.memory(image.bytes, width: 44, height: 44, fit: BoxFit.cover),
                ),
              ),
              Positioned(
                top: -8,
                right: -8,
                child: IconButton(
                  key: Key('aiModellingRemoveImage_$index'),
                  tooltip: 'Remove this image',
                  icon: const Icon(Icons.cancel, size: 18),
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(),
                  padding: EdgeInsets.zero,
                  onPressed: () => _removePendingImage(index),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Multi-part/assembly overhaul, Phase D: the pre-generation confirm
  /// panel, shown once a `part_manifest` is detected and before any
  /// generation cycle has started - `AiPartManifestEntry.name`/`typePrefix`
  /// are editable here (`_manifestNameControllers`/`_manifestPrefixControllers`,
  /// folded back in by `_confirmManifestAndGenerateAll`) since the LLM's
  /// own proposed breakdown is a starting point, not a final answer, the
  /// same "human confirms/edits before anything real happens" posture the
  /// save-gate itself uses one step later.
  Widget _buildManifestConfirm(BuildContext context) {
    final manifest = _partManifest!;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Found ${manifest.parts.length} part(s)', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          const Text(
            'Review and edit the name/type prefix for each part below, then confirm to generate and '
            'save every part in sequence.',
            style: TextStyle(color: Colors.white54),
          ),
          const SizedBox(height: 12),
          // Gap-closure (`13-...md`'s own E-1): only shown once there's
          // actually an existing file to offer - the dropdown's absence
          // itself communicates "a new assembly will be created", no extra
          // empty-state text needed.
          if (_existingAssemblyFileOptions.isNotEmpty) ...[
            DropdownButtonFormField<String?>(
              key: const Key('aiModellingManifestAssemblyTarget'),
              initialValue: _assemblyTargetRelativePath,
              decoration: const InputDecoration(labelText: 'Assembly'),
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('Create a new assembly file')),
                for (final path in _existingAssemblyFileOptions)
                  DropdownMenuItem<String?>(value: path, child: Text('Insert into "$path"')),
              ],
              onChanged: (value) => setState(() => _assemblyTargetRelativePath = value),
            ),
            const SizedBox(height: 12),
          ],
          Expanded(
            child: ListView.separated(
              itemCount: manifest.parts.length,
              separatorBuilder: (_, __) => const Divider(),
              itemBuilder: (context, index) {
                final entry = manifest.parts[index];
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              key: Key('aiModellingManifestName_$index'),
                              controller: _manifestNameControllers[index],
                              decoration: const InputDecoration(labelText: 'Name'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          SizedBox(
                            width: 130,
                            child: TextFormField(
                              key: Key('aiModellingManifestPrefix_$index'),
                              controller: _manifestPrefixControllers[index],
                              decoration: const InputDecoration(labelText: 'Type prefix'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(entry.summary, style: const TextStyle(color: Colors.white54, fontSize: 12)),
                    ],
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                key: const Key('aiModellingManifestCancel'),
                onPressed: _cancelPartManifest,
                child: const Text('Back to chat'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                key: const Key('aiModellingManifestConfirm'),
                onPressed: _confirmManifestAndGenerateAll,
                child: const Text('Confirm & Generate All'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Multi-part/assembly overhaul, Phases D+E: the per-part progress list
  /// shown once orchestration has started - one row per manifest entry
  /// (done/in-progress/pending/failed), plus a coarse status line for
  /// whichever part is currently in flight (`_orchestrationStatus`,
  /// deliberately not a full per-step list the way
  /// `_buildReviewAndGenerate`'s own `_stepStatuses` is - see this
  /// workstream's own doc Appendix for why), plus (Phase E) one more row
  /// for the assembly-creation cycle that starts automatically once every
  /// part is saved (`_finishPartOrchestration` -> `_runAssemblyCycle`).
  /// "Back to chat"/"Dismiss" only enables once the whole flow (every part,
  /// then the assembly) has finished or stopped on an error - there's
  /// nothing useful to do mid-flight except watch it work. "Open Assembly"
  /// appears only once the assembly itself is real and saved.
  /// Gap-closure (`13-...md`'s own D-2/E-3): when the part/assembly
  /// currently in flight has a real plan (`_orchestrationStepStatuses` set
  /// by `_runPartCycle`/`_runAssemblyCycle` right before `translator.
  /// execute`), render its own per-step dots via `_stepStatusIcon` -
  /// `_buildReviewAndGenerate`'s own single-Part progress, reused rather
  /// than reduced to the coarse `_orchestrationStatus` text alone.
  Widget _buildOrchestrationStepStatuses() {
    final statuses = _orchestrationStepStatuses;
    if (statuses == null || statuses.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(left: 16, bottom: 4),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [for (final status in statuses) _stepStatusIcon(status)],
      ),
    );
  }

  Widget _buildOrchestrationProgress(BuildContext context) {
    final manifest = _partManifest!;
    final total = manifest.parts.length;
    final assemblySaved = _assemblyRelativePath != null;
    final finished = assemblySaved || _orchestrationError != null;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            assemblySaved
                ? 'Assembly ready'
                : _buildingAssembly
                    ? 'Building the assembly'
                    : 'Generating part ${_currentPartIndex + 1} of $total',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          Expanded(
            child: ListView(
              children: [
                for (var i = 0; i < total; i++) ...[
                  ListTile(
                    leading: Icon(
                      i < _savedAssemblyParts.length
                          ? Icons.check_circle
                          : i == _currentPartIndex && _orchestrationError != null
                              ? Icons.error
                              : i == _currentPartIndex
                                  ? Icons.hourglass_top
                                  : Icons.circle_outlined,
                      color: i < _savedAssemblyParts.length
                          ? Colors.green
                          : (i == _currentPartIndex && _orchestrationError != null)
                              ? Colors.redAccent
                              : null,
                    ),
                    title: Text(manifest.parts[i].name),
                    subtitle: i < _savedAssemblyParts.length
                        ? Text(_savedAssemblyParts[i].relativePath)
                        : (i == _currentPartIndex && _orchestrationStatus != null)
                            ? Text(_orchestrationStatus!)
                            : null,
                  ),
                  if (i == _currentPartIndex && !_buildingAssembly) _buildOrchestrationStepStatuses(),
                ],
                if (_buildingAssembly || assemblySaved) ...[
                  ListTile(
                    key: const Key('aiModellingAssemblyRow'),
                    leading: Icon(
                      assemblySaved
                          ? Icons.check_circle
                          : _orchestrationError != null
                              ? Icons.error
                              : Icons.hourglass_top,
                      color: assemblySaved
                          ? Colors.green
                          : _orchestrationError != null
                              ? Colors.redAccent
                              : null,
                    ),
                    title: const Text('Assembly'),
                    subtitle: assemblySaved
                        ? Text(_assemblyRelativePath!)
                        : _orchestrationStatus != null
                            ? Text(_orchestrationStatus!)
                            : null,
                  ),
                  if (_buildingAssembly && !assemblySaved) _buildOrchestrationStepStatuses(),
                ],
              ],
            ),
          ),
          if (_orchestrationError != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(_orchestrationError!, style: const TextStyle(color: Colors.redAccent)),
            ),
          if (assemblySaved)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  key: const Key('aiModellingOpenAssembly'),
                  onPressed: _openAssembly,
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Open Assembly'),
                ),
              ),
            ),
          if (_canRetryOrchestration)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton.icon(
                  key: const Key('aiModellingOrchestrationRetry'),
                  onPressed: _retryOrchestration,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
              ),
            ),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              key: const Key('aiModellingOrchestrationDismiss'),
              onPressed: finished ? _dismissOrchestration : null,
              child: Text(finished ? 'Back to chat' : 'Dismiss'),
            ),
          ),
        ],
      ),
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
                if (_preflightResults != null) ...[
                  const SizedBox(height: 16),
                  Text('Validation results', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  for (final r in _preflightResults!)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(r.ok ? Icons.check_circle_outline : Icons.error_outline, color: r.ok ? Colors.green : Colors.redAccent, size: 18),
                          const SizedBox(width: 6),
                          Expanded(child: Text('${r.localId}: ${_validationResultText(r)}')),
                        ],
                      ),
                    ),
                ],
                if (_finishedOutcome != null) ...[
                  const SizedBox(height: 12),
                  _buildOutcomeBanner(_finishedOutcome!, _preflightResults),
                ],
                // Fix 5 from the `02` doc's own real end-to-end exercise:
                // `push` (not `pushReplacement`, unlike `GearDesignScreen`'s
                // own successful-creation navigation this otherwise copies)
                // so this screen stays underneath - the "Undo this
                // generation" banner below is meant to survive a look at the
                // result, not get torn down the instant Generate finishes.
                if (_finishedOutcome == PlanTranslationOutcome.success && _generatedPartId != null) ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => PartScreen(documentApi: widget.documentApi, initialPartId: _generatedPartId),
                      ),
                    ),
                    icon: const Icon(Icons.visibility_outlined),
                    label: const Text('View Part'),
                  ),
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

  /// Fixes 3a/3b from the `02` doc's own real end-to-end exercise. Both are
  /// shown as an annotation next to the existing per-step validation row
  /// (rendered for every run - `_preflightResults` is populated regardless
  /// of outcome, see `PlanTranslationResult.preflightResults`'s own doc
  /// comment, fix 6) rather than baked into `summarizeAiPlan`'s plan-only
  /// output, since only this validation response - not the plan itself -
  /// carries `resolvedEdges`/`holeCount` at all:
  /// - **3a**: a Fillet/Chamfer step's `resolvedEdges` was already fetched
  ///   but never shown - append the real resolved edge count. A Shell
  ///   step's `resolvedFaces` mirrors this exactly, one level down (faces
  ///   rather than edges).
  /// - **3b**: an Extrude/Revolve/Sweep step's `holeCount` (real backend
  ///   truth from `detect_profile`, never a client-side guess).
  String _validationResultText(AiPlanStepResultDto r) {
    if (!r.ok) return _formatStepError(r.error);
    final edgeCount = r.resolvedEdges?.length;
    if (edgeCount != null) return 'ok ($edgeCount edge${edgeCount == 1 ? '' : 's'})';
    final faceCount = r.resolvedFaces?.length;
    if (faceCount != null) return 'ok ($faceCount face${faceCount == 1 ? '' : 's'})';
    final holeCount = r.holeCount;
    if (holeCount != null && holeCount > 0) return 'ok — includes $holeCount hole${holeCount == 1 ? '' : 's'}';
    return 'ok';
  }

  /// The backend's own `error` map (`ai_plan.py`'s `_StepError`/
  /// `StepResult.error`, see `05-backend-plan-validation.md`) is always
  /// `{"type": "...", ...}` - `type` alone (the old behaviour here) is a
  /// bare machine code like "invalid_step_payload" that tells the user
  /// nothing about what to actually change. Most hand-raised errors also
  /// carry a human-readable `message` (e.g. "cut requires at least one
  /// target_body_ids entry") or, failing that, other detail keys (`field`,
  /// `local_id`, `body_id`, ...) worth surfacing instead of dropping them
  /// on the floor.
  String _formatStepError(Map<String, dynamic>? error) {
    if (error == null) return 'failed';
    final type = (error['type'] ?? 'failed').toString();
    final message = error['message'];
    if (message != null) return '$type: $message';
    final details = error.entries.where((e) => e.key != 'type').map((e) => '${e.key}=${e.value}').join(', ');
    return details.isEmpty ? type : '$type ($details)';
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

  Widget _buildOutcomeBanner(PlanTranslationOutcome outcome, List<AiPlanStepResultDto>? preflightResults) {
    switch (outcome) {
      case PlanTranslationOutcome.success:
        return const _Banner(color: Colors.green, text: 'Generated - every step created successfully.');
      case PlanTranslationOutcome.validationFailed:
        final failed = preflightResults?.where((r) => !r.ok).length ?? 0;
        final total = preflightResults?.length ?? 0;
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

  const _Banner({super.key, required this.color, required this.text});

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

  Future<void> _copyToClipboard(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: message.text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied to clipboard'), duration: Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == AiMessageRole.user;
    final images = message.images;
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
        // Workstream 10 (`10-image-input.md`): an image-aware variant - a
        // thumbnail strip above the text when this turn carries any.
        // Rendered here (not only on the turn it was attached on), so every
        // image stays visibly "pinned" in the scroll history for the rest
        // of the conversation, matching `06-image-input-deferred.md`'s "not
        // consumed after one turn" UX carryover. Widened from a single
        // fixed thumbnail to a horizontal strip in Phase B of the
        // multi-part/assembly overhaul (`docs/ai-modelling/13-multi-part-
        // assembly-overhaul.md`).
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (images.isNotEmpty) ...[
              SizedBox(
                height: 160,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final image in images)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.memory(image.bytes, fit: BoxFit.cover, height: 160),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
            ],
            // Selectable (rather than a plain Text) so the raw text - JSON
            // plans especially - can be selected and copied manually too,
            // not just via the button below.
            SelectableText(message.text),
            Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                icon: const Icon(Icons.copy, size: 16),
                tooltip: 'Copy to clipboard',
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(),
                padding: const EdgeInsets.only(top: 6),
                onPressed: () => _copyToClipboard(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
