# Assemblies — Scoping Document

Companion to a feature request covering: NX/Siemens-style assemblies in the
same viewport and file type as part modelling — an assembly tree showing
parts/subassemblies/mates instead of features/bodies/surfaces, long-press
"make focus" to edit a part in the visual context of the assembly, a
move/rotate triad gizmo clamped by mates, basic mates (coincident/
concentric/parallel/distance/angle), linear/circular component pattern,
hide/show, isolate, and LLM-driven assembly authoring via the existing AI
plan pipeline. Same convention as `docs/pattern-mirror-scope.md`: broken
into phases against the *actual current implementation* (verified by
reading the code, not assumed), with the model decisions that were made,
what's implemented so far, and what's still planned.

Backend: `backend/app/document/*` (FastAPI + pythonocc-core/OCCT).
Client: `client/lib/viewport3d/*` (3D viewport/tree/tools, now including
`assembly_tree_panel.dart`), `client/lib/storage/*` (implemented),
`client/lib/assembly/*` (graph compose, document client, `AssemblyLens`,
`AssemblyFocusStack` - all implemented; screen/UI pieces beyond the lens
toggle itself, e.g. Make Focus and per-instance opacity, still planned).

**Status: Phase 0 (backend data model), Phase 1 (client storage
abstraction), Phase 2 (multi-file compose + recompute), and Phase 3
(lens toggle + focus-stack state, `AssemblyTreePanel`) implemented -
Phase 3's Make Focus wiring and viewport opacity/instance rendering are
explicitly deferred to Phases 4/5 (see §2d). Phases 4–9 are design-only.**

---

## 1. Model decisions (locked in, drive every phase below)

1. **Multi-file assemblies from v1** — an assembly file references separate
   part files (bottom-up *and* top-down authoring both in scope). Not an
   embedded/single-file "multi-body part" model.
2. **A `.didsa` file holds local Features and assembly structure
   *simultaneously*, not as two mutually-exclusive kinds of file.** This is
   the NX-style model directly: open one file, model or import local/
   reference geometry (a fixture, a mounting boss) via Features, and in the
   very same file place and mate other `.didsa` files' Parts as components
   via Occurrences/Mates - switching between a "feature tools + feature
   tree" lens and an "assembly tools + assembly tree" lens is a client-side
   mode toggle on the one open screen, never a different file, a different
   backend type, or a navigation away from the viewport (§2's "mode
   switching" note spells out exactly how). Realized as **one** dataclass,
   `Part` (see §2) - `occurrences: list[Occurrence]`/`mates: list[Mate]`
   added directly onto it alongside its existing `features: list[Feature]`
   - not a `Node = Part | Assembly` union of two exclusive types (an
   earlier, incorrect pass at this decision briefly existed in this
   codebase's history; corrected before any UI was built on top of it).
3. **In-context editing is visual-only** — no persistent associative links
   between parts. Preserves `Part`'s own documented invariant ("Parts never
   reference each other or share Features/Sketches/Points",
   `backend/app/document/models.py`'s `Part` docstring).
4. **Storage**: user-chosen project folder via Android/iOS Storage Access
   Framework (persisted URI permission) or a plain path on desktop.
   References store a relative path within the project root, never a raw
   absolute path/content-URI. Network storage = whatever the OS/SAF already
   exposes as a folder — no built-in SMB/WebDAV client.
5. **Reference staleness**: always try to resolve to the latest version of
   a referenced file; if unreachable, fall back to a cached last-known-good
   snapshot, flagged stale in the UI.
6. **The backend stays stateless** — it has no filesystem/SAF access at
   all. `Occurrence.external_ref` (§2) is an opaque, client-owned string
   this backend stores and echoes back verbatim and never parses or
   resolves. The client resolves every referenced file itself and ships a
   composed multi-file graph per request, the same shape as today's
   single-document requests.

Codebase investigation found the mate-solving primitive is unusually
de-risked: `backend/app/sketch/solver.py` already wraps `py_slvs.slvs.
System` (`py-slvs==1.0.6`, pinned in `backend/environment.yml`), a SWIG
binding over a fork of SolveSpace (`realthunder/solvespace` — the same fork
FreeCAD's Assembly3 workbench uses for real 3D assembly solving). Every
constraint method `solver.py` already calls takes `wrkpln` as a
**defaultable** parameter — omitting it yields a genuine free-3D
constraint with zero new library code, and the library additionally has
`addTransform`/`addSameOrientation`/`addPointPlaneDistance`/
`addPointInPlane` — exactly the rigid-body-placement and mate-alignment
primitives a mate solver needs. **No new 6-DOF solver needs to be built**
for Phase 6 (§3) — this is additive backend integration reusing an
existing dependency.

---

## 2. Phase 0 — unified Part data model (implemented)

### Mode switching, concretely (answers "how does the user get to assembly
mode without leaving the file")

A `.didsa` file is one `Part` (see below) that can hold both Features and
assembly structure at once. The client's build-tree/toolbar panel reads
from *the same open Part* in either lens - "Part mode" shows
`part.features` and the feature toolset (sketch/extrude/fillet/…); "Assembly
mode" shows `part.occurrences`/`part.mates` and the assembly toolset
(insert component/mate/pattern/…) over the *identical* viewport and file.
Switching is a client-side UI state toggle (Phase 3), not a save, not a
new file, not a navigation to a different screen - the backend has no
"mode" concept at all, since a `Part` always has both fields regardless of
which one the UI happens to be showing. Concretely, in the user's own
scenario: opening a new `.didsa` file starts in Part mode by default (an
empty `features` list, matching today's pre-assembly behavior exactly);
toggling to Assembly mode shows an empty `occurrences`/`mates` tree ready
for "insert component"; toggling back to Part mode to model or import a
local mount adds to `features` on that *same* Part; toggling to Assembly
mode again to insert and mate other `.didsa` files adds to `occurrences`/
`mates` on that *same* Part - nothing about switching modes touches which
file is open or creates/loads a different backend object.

### The data model

`backend/app/document/models.py`:

- `RigidTransform` (translation + axis-angle rotation, applied rotate-
  then-translate — the same composition order `MoveBodyFeature` already
  uses, for consistency across the codebase). Wire format is axis-angle,
  not a quaternion; the mate solver (Phase 6) converts to/from quaternion
  only at its own SolveSpace FFI boundary.
- `MateType` (`coincident`/`concentric`/`parallel`/`distance`/`angle`),
  `MateEntityRef` (an Occurrence id + one of `SubShapeRef`/`PlaneRef`/
  `PointRef`, reused verbatim from the existing Feature-reference types),
  `Mate` (a `MateType` + `references` + optional `value`/`flipped`).
- `Occurrence` — one placed instance of another Part (in another file):
  `id`, `part_id: str | None` (session-local, **never** persisted to disk —
  populated by whoever assembles a multi-file graph into a `Document`),
  `external_ref: str | None` (the portable, client-owned relative-path
  identity — the only thing `native_format.py` (de)serializes for an
  Occurrence's target), `transform`, `suppressed`, `hidden`.
- `Part` gains two new fields directly, alongside its existing `features`:
  `occurrences: list[Occurrence]` and `mates: list[Mate]`. **No new node
  type, no union** - a single Part can have a non-empty `features` list
  *and* a non-empty `occurrences`/`mates` list at the same time; nothing
  in the model forces "only features" or "only assembly structure". The
  existing "Parts never reference each other or share Features/Sketches/
  Points" invariant (decision #3) is unchanged and still enforced at the
  Feature level - `occurrences`/`mates` are a distinct, deliberately-added
  relationship (an opaque `external_ref` string, never a Feature/Sketch/
  Point reference), not an exception carved into that rule.
- `Document.parts: dict[str, Part]` is unchanged in shape from before
  assembly support - still a plain dict, no compatibility-view machinery
  needed, since there is no second node kind to filter out anymore.
  `Document.root_part_id: str | None` (new, optional) names which Part is
  the session's currently-open file, as opposed to one pulled in only
  because another Part's `Occurrence.external_ref` resolved to it
  (Phase 2's multi-file graph compose).

`backend/app/document/native_format.py`:

- `SCHEMA_VERSION` stays at **1** - unchanged. `occurrences`/`mates` are
  purely additive fields on a Part's existing dict shape
  (`_part_to_dict`/`_part_from_dict`), read back via `.get(key, [])`
  exactly like every other evolutionary field this file already added
  (e.g. Mirror/Pattern's `tool_feature_id`) - a file saved before assembly
  support existed simply lacks the keys and imports with empty lists, no
  version branch needed. `document_data`'s new `"root_part_id"` key is
  optional the same way, defaulting to `None`.
- `export_native(document, sketches, part_id=None)` — `part_id=None`
  exports every Part in the session (a full snapshot); `part_id=<id>`
  exports just that one Part's own data - its own `features` **and** its
  own `occurrences`/`mates` together (both coexist, per above) - which is
  what saving an individual file in a multi-file assembly needs, never the
  resolved subtree an Occurrence's `external_ref` points at, since that
  lives in its own separate file. `GET /export/native?part_id=<id>`
  (`backend/app/document/router.py`) wires this through, 404ing for an
  unknown `part_id`.
- An Occurrence's `part_id` is never written to or read from disk — only
  `external_ref` is (de)serialized. A freshly-imported Occurrence always
  has `part_id=None` until something resolves it (the client's compose
  step, once multi-file assembly loading exists — Phase 2, not yet built).

`backend/app/document/assembly.py` (new): pure vector/matrix math (no
OCCT dependency) for composing `RigidTransform`s down a nested Occurrence
tree (an Occurrence's target Part can itself have its own Occurrences) —
`compose(parent, child)` and `compose_chain(transforms)`. Uses the same
Rodrigues'-rotation-formula construction as the client's
`section_gizmo.dart`'s `rotateAroundAxis`, kept in matching form so backend
and client transform composition agree. Not yet consumed by any endpoint —
Phase 2's `GET /parts/{part_id}/assembly-mesh` is its first real caller.

**Verified**: standalone round-trip tests (Document/Part/Occurrence/Mate
construction, including a single Part with a local Feature *and*
Occurrences/Mates at once → `export_native` → real `json.dumps`/`loads` →
`import_native` → equivalence, both full-graph and single-part export,
plus pre-assembly-payload import) plus five permanent pytest tests in
`backend/tests/test_assembly_model.py`, and the **full backend test suite
run for real against a `pythonocc-core`/`py-slvs` environment** (a
`micromamba` env built from `backend/environment.yml` specifically to
make this possible): **2201/2201 passed** after the correction described
below (2206 including the 5 new tests). `assembly.py`'s transform
composition was separately verified (identity, pure translation,
rotated-parent-composes-child's-local-offset-correctly, axis-angle↔matrix
round-trip including the 180° edge case, chain-matches-nested-compose,
and rotation non-commutativity).

**History note**: the first pass at this phase modeled Part/Assembly as
two mutually-exclusive dataclasses under a `Node = Part | Assembly` union
(`Document.nodes`, `SCHEMA_VERSION` bumped to 2 for a `"node_kind"`
discriminator). A user walkthrough of the intended UX - modelling local
reference geometry and placing/mating components in the *same* open file,
switching lenses without navigating away - showed this was wrong: it made
"Part" and "Assembly" two different kinds of file rather than two views
over one. Corrected before any UI was built against it: `Assembly` and
`Node` were removed, `occurrences`/`mates` moved directly onto `Part`,
`Document.nodes`/`root_node_id` reverted to `Document.parts`/
`root_part_id`, and `SCHEMA_VERSION` reverted to 1 (the corrected shape
needed no version bump at all - see above). Getting the *original* Phase 0
verification run to pass for real (2201/2201 against real OCCT/py-slvs)
had already separately surfaced three genuine pre-existing-test
regressions unrelated to this correction - 11 test files reading a native
export's Part list via the JSON key `exported["document"]["parts"]`
(temporarily `"nodes"` mid-correction, now reverted back to `"parts"`)
rather than the `document.parts` Python attribute an initial grep
covered, and one session-isolation test hand-building an import payload
tied to the old shape - all fixed as straightforward, intent-preserving
edits, re-verified clean after the correction landed.

---

## 2b. Phase 1 — client storage abstraction layer (implemented)

`client/lib/storage/`:

- `ProjectRoot` (`project_root.dart`) — sealed, two variants:
  `DesktopProjectRoot` (a plain OS directory path) and `SafProjectRoot` (a
  granted Android SAF tree URI + display name). No iOS variant — iOS has
  no Storage Access Framework and needs its own security-scoped-bookmark
  mechanism, tracked as a known gap below, not guessed at here.
- `FileHandle` (`file_handle.dart`) — sealed the same way
  (`DesktopFileHandle`/`SafFileHandle`), always carrying `relativePath`
  (the portable identity that ends up in an `Occurrence.external_ref`)
  alongside the platform-specific locator (`path`/`uri`, a live-session
  convenience only, never persisted).
- `StorageService` (`storage_service.dart`) — the abstract interface:
  `pickOrCreateProjectRoot`, `lastUsedProjectRoot`, `resolve`, `readFile`,
  `writeFile`, `lastModified`, `exists`, all in terms of
  `ProjectRoot`/`FileHandle`/relative paths only, plus `StorageException`
  for anything unreadable/unreachable.
- `DesktopStorageService` (`desktop_storage_service.dart`) — a thin
  `dart:io` `File`/`Directory` wrapper; relocated from what used to be
  inlined directly in `part_screen.dart`'s save/load methods.
- `SafStorageService` (`saf_storage_service.dart`) — Android-only, backed
  by the `saf_util`/`saf_stream` packages (same maintainer, designed as a
  pair): `saf_util` for tree navigation (pick/mkdirp/child/stat/exists),
  `saf_stream` for file-byte I/O (`readFileBytes`,
  `writeFileUriBytes`/`writeFileBytes`). `writeFile` overwrites an
  existing file via its own URI (`writeFileUriBytes`) rather than the
  create-or-rename-on-conflict path, so a re-save keeps the same
  underlying SAF document identity. No `AndroidManifest.xml` or
  `build.gradle` changes were needed: neither plugin declares any Android
  permissions, and both require `minSdk 24`, which Flutter's own project
  template already defaults to for this Flutter version.
- `RecentProjectStore` (`recent_project_store.dart`) — persists
  `(persistedKey, displayName)` via `shared_preferences` so
  `lastUsedProjectRoot()` can reopen the last project without re-prompting
  the picker; shared by both `StorageService` implementations rather than
  each reimplementing it. Each implementation re-validates the persisted
  key is still reachable/granted before trusting it (`lastUsedProjectRoot`
  reads `null` for a revoked SAF permission or a deleted desktop
  directory, not a stale success).
- `FileCache` (`file_cache.dart`) — the "cached last-known-good snapshot"
  half of the reference-staleness policy (§1.5): `get`/`put`/`evict`
  keyed by a `sha256` hash of `(root.persistedKey, relativePath)`, backed
  by `path_provider`'s app-private cache directory. Pure store, not a
  decision-maker — the "try live, fall back to cache, flag stale" policy
  itself belongs to whichever caller needs it (Phase 2's multi-file graph
  composer, not yet built).
- `storage_service_factory.dart` — `createStorageService()` picks
  `SafStorageService` on Android, `DesktopStorageService` everywhere else
  this app currently runs; iOS falls back to the desktop implementation
  today, which will not actually work there (a known gap, not a real
  implementation).

New dependencies: `saf_util: ^3.1.0`, `saf_stream: ^4.0.1` (both actively
maintained, Dart-3-compatible — an earlier candidate, `shared_storage`,
was rejected for capping its SDK constraint below Dart 3.0), `path:
^1.9.1`, `crypto: ^3.0.7`.

**Verified**: a full `micromamba`-independent Flutter/Dart toolchain was
installed specifically to make this possible (`flutter analyze` clean
across the whole client; the full existing client test suite - 1684
passed, 12 GPU/Impeller tests gracefully self-skip in this headless
sandbox - confirmed as a pre-Phase-1 regression baseline). `Desktop
StorageService` is tested against a real temporary directory (genuine
`dart:io` I/O, no mocking). `SafStorageService` is tested against a fake
`SafUtil`/`SafStream` pair (an in-memory tree standing in for the real
Android platform channel, which is fundamentally untestable without a
device/emulator) built by subclassing the real plugin classes - the same
"inject the real dependency, substitute a fake for tests" convention this
codebase already uses (e.g. `PartScreen`'s injectable `documentApi`),
applied to third-party plugin classes. `FileCache` and
`RecentProjectStore` are tested against a real temp directory and
`SharedPreferences.setMockInitialValues` respectively. 47 new tests, all
passing; the full client suite was rerun afterward to confirm no
regressions.

**Known gap, not built**: iOS has no SAF equivalent implemented yet - it
needs its own security-scoped-bookmark mechanism
(`UIDocumentPickerViewController` + persisted bookmarks), currently just
silently falls back to the desktop implementation via
`createStorageService()`, which will not work on a real iOS sandbox.

---

## 2c. Phase 2 — multi-file compose + stateless recompute (implemented)

`backend/app/document/schemas.py`/`router.py`:

- New `GET /parts/{part_id}/assembly-mesh` endpoint
  (`AssemblyMeshResponse`: `geometry` + `instances`). Walks the Occurrence
  tree from `part_id` down (`app.document.assembly.compose_chain` for
  world transforms), computing each **unique** Part's own local bodies
  exactly once (`_assembly_body_mesh_responses`, the same
  `compute_part_bodies` path `GET /mesh` uses, reusing the existing
  per-Part body cache) regardless of how many Occurrences place it -
  `geometry` ships one entry per unique Part, `instances` ships one entry
  per placed Occurrence (plus the root's own content, `occurrence_path:
  []`), each carrying only its own `world_transform`. Confirmed correct
  even down a nested subassembly chain (a component inside a component)
  via a real `compose_chain` composition test. An Occurrence whose target
  hasn't been resolved into `document.parts` yet, or that would revisit a
  Part already on its own path (a cycle), is silently skipped rather than
  failing the whole response - every resolvable sibling still renders.
- **A real gap found and fixed while building this**: `Occurrence.part_id`
  (session-local, Phase 0) had no mechanism to ever become non-`None` from
  an import - `external_ref` alone can't be resolved by a backend with no
  filesystem access (decision #6), so every Occurrence would have stayed
  unresolved forever and `assembly-mesh` would never have shown a single
  component. Fixed with a `"resolved_part_id"` wire field
  (`_occurrence_to_dict`/`_occurrence_from_dict`) that `import_native`
  only trusts when it names another Part actually present in the *same*
  import payload (a two-pass build: every Part first, then every
  Occurrence's cross-reference validated against that set,
  `_resolve_occurrence_part_ids`) - exactly what lets the client's compose
  step bundle N resolved `.didsa` files into one `/import/native` call. A
  single-file save naturally loses this cross-reference on a later
  standalone reimport (the referenced Part isn't in that solo payload) -
  only `external_ref` survives a single-file round trip, matching the
  "never embed the resolved subtree" principle.

`client/lib/assembly/`:

- `AssemblyGraphComposer` (`assembly_graph_composer.dart`) - resolves a
  root `.didsa` file and everything it (transitively) references via
  `StorageService`, into one combined `/import/native`-ready payload. Each
  file's own persisted `id` is trusted as-is (not reassigned), which is
  what makes resolving the same file from two different Occurrences (a
  shared library part, or two paths converging on one sub-assembly) an
  ordinary dedup rather than something needing special handling - both
  resolve to the same relative path, hit the same cache entry, end up as
  one Part entry either way. Throws `AssemblyGraphCycleException` for a
  genuine reference cycle (including direct self-reference); a child file
  that can't be read at all (live or cached) leaves its Occurrence
  unresolved rather than failing the whole compose, mirroring the
  backend's own unresolved-Occurrence handling. Implements the staleness
  policy concretely (decision #5): tries a live read first, falls back to
  `FileCache` on failure, and reports every relative path that had to fall
  back via `staleRelativePaths`.
- `AssemblyDocumentClient` (`assembly_document_client.dart`) - ties the
  composer, `DocumentApiClient`, and `StorageService` together into the
  three operations a caller needs: `openAssembly` (compose + one
  `importNative` call), `fetchAssemblyMesh`, `savePart` (`exportNative
  (partId: ...)` + `StorageService.writeFile`). Deliberately thin - no
  dirty-tracking or UI state, that's Phase 3's screen to own.
- `DocumentApiClient.exportNative` gained an optional `partId`; new
  `getAssemblyMesh` plus `RigidTransformDto`/`AssemblyBodyGeometryDto`/
  `AssemblyOccurrenceInstanceDto`/`AssemblyMeshDto`.

**Verified**: full backend suite against real `pythonocc-core`/`py-slvs` -
**2211/2211 passed** (5 new integration tests in
`backend/tests/test_assembly_mesh.py`, covering a plain part, a root
Part's own bodies coexisting with a placed Occurrence, geometry dedup
across 3 occurrences of one Part, an unresolved-Occurrence no-op, and a
real `compose_chain` transform-composition check down a 3-level nested
chain with the exact expected coordinates asserted). Full client suite -
**1742/1742 passed**, 12 GPU-skips (9 new `AssemblyGraphComposer` tests
against a fake in-memory `StorageService` - dedup, direct and
self-referencing cycles, missing files, cache-fallback staleness, 3-level
nesting - plus 3 new `AssemblyDocumentClient` tests against a `MockClient`
confirming the composed payload/mesh-parsing/save-back wiring end to end).

---

## 2d. Phase 3 — unified screen architecture: lens toggle + focus stack (implemented, partial)

The foundational client-side piece everything else in this list sits on
top of, and the concrete answer to "does the viewport change between
modes?" (it doesn't). Two independent axes on **one continuous
screen/viewport** - neither ever pushes a new screen, resets the camera,
or re-fetches anything on its own:

- **Lens** (`AssemblyLens.part` ↔ `AssemblyLens.assembly`, new
  `client/lib/assembly/assembly_lens.dart`) - a pure UI-state toggle for
  whichever Part is currently primary. `PartScreen` now swaps the side
  panel between the existing `FeatureTreePanel` (reads `_features`) and a
  new `AssemblyTreePanel` (`viewport3d/assembly_tree_panel.dart`, reads
  new `_occurrences: List<OccurrenceDto>`/`_mates: List<MateDto>` fields
  fetched via `DocumentApiClient.listOccurrences`/`listMates` -
  `backend/app/document/router.py`'s new `GET /parts/{part_id}/
  occurrences`/`GET /parts/{part_id}/mates`, `OccurrenceResponse`/
  `MateResponse` schemas, `PartResponse.occurrence_ids`/`mate_ids`
  summary fields). A new small FAB (`assembly-lens-fab`, next to the
  existing feature-tree FAB) toggles `_lens` and its tooltip/icon; only
  one of `FeatureTreePanel`/`AssemblyTreePanel` is ever built into the
  widget tree at a time (not merely hidden via `visible: false`) - both
  carry their own "Close" button, and `AnimatedSlide`-hidden-but-mounted
  widgets duplicated it, which a real widget test caught (see
  `part_screen_test.dart`'s "dismissing the Feature tree cancels the
  pending Extrude creation" - `find.byTooltip('Close').tap()` became
  ambiguous with two matches). The accepted v1 cost: switching lens while
  the panel is open swaps content instantly rather than sliding, unlike
  toggling the panel open/closed within one lens (still animated).
  `AssemblyTreePanel` itself is deliberately simpler than
  `FeatureTreePanel` - no picker-mode machinery (nothing needs an in-tree
  picker yet) and no Bodies/Planes/Surfaces sections (those stay
  Part-lens-only) - just a Components section (occurrence rows, named via
  `nameOverride` → `external_ref` basename → "Component N", flagging
  hidden/suppressed/unresolved state) and a Mates section (mate rows named
  "Type N"), both fully covered by widget tests
  (`test/assembly_tree_panel_test.dart`).
- **Focus stack** (`AssemblyFocusStack`, new
  `client/lib/assembly/focus_stack.dart`) - a stack of "which Part is
  currently primary," reusing the `OverrideStack<T>` pattern already
  established in this codebase one level higher: `push`/`pop` a Part id,
  `current` defaulting to the root Part (unlike `OverrideStack.current`,
  never `null` - there is always a focused Part once an assembly is open).
  `PartScreen` now owns one (`_focusStack`, seeded with the opened Part's
  own id in `_loadPart`) and `_refreshAssemblyTree` reads
  `_focusStack.current` rather than assuming the root Part is always what
  the Assembly tree shows. Fully covered by unit tests
  (`test/focus_stack_test.dart`).

**Deferred, not yet wired**: "Make Focus"/"Exit Focus" actions that
actually `push`/`pop` the focus stack (`AssemblyTreePanel.
onOccurrenceLongPress` currently only selects a row, reserved for Phase
4's Component context menu), and the opacity/selectability split for
non-primary Parts described in the original brainstorm ("focus part and
its children opaque, peers and parents translucent"). That enforcement
needs `SelectionFilterState` to gain a `component` kind first - a real
dependency on Phase 4, not a sequencing choice - so it stays scoped there
rather than being claimed here. The 3D viewport itself does not yet
render every resolved Occurrence alongside the primary Part's own bodies
(consuming Phase 2's instanced `assembly-mesh` response is real
rendering-pipeline work in `mesh_geometry.dart`, flagged as its own risk
in the original plan) - today's viewport content is unchanged by the lens
toggle, matching the "lens never changes the viewport" principle for the
subset of scene content that already renders (this Part's own bodies),
but Occurrences are not yet drawn as placed instances. Both are called
out explicitly rather than silently assumed done.

**Verified**: full backend suite against real `pythonocc-core`/`py-slvs` -
**2214/2214 passed** (3 new tests in `test_assembly_tree_endpoints.py`: a
fresh Part has no occurrences/mates; occurrences+mates appear in both the
`PartResponse` summary and the full list endpoints with correct field
values; occurrences and features coexist on one Part's own response - the
exact model-correction scenario). Full client suite - **1762/1762
passed**, 12 GPU-skips (`flutter analyze` clean on every touched/new file;
20 new tests across `focus_stack_test.dart` and
`assembly_tree_panel_test.dart`, including the `AssemblyFocusStack`
push/pop/clear invariants and every `AssemblyTreePanel` display-name/
empty-state/hidden/unresolved/tap/long-press/suppressed case). The
`PartScreen` wiring itself caught one real regression before it shipped:
mounting both tree panels simultaneously (one merely `visible: false`
rather than absent from the tree) duplicated their "Close" buttons and
broke `part_screen_test.dart`'s existing "dismissing the Feature tree
cancels the pending Extrude creation" test via an ambiguous
`find.byTooltip('Close')` - fixed by gating each panel's presence in the
widget tree on `_lens` (an `if` in the `Stack`'s children, not just its
own `visible` param), confirmed by re-running that test in isolation
before the full re-run above went green.

---

## 3. Remaining phases (design-only)

4. **Whole-part selection + context menu** — extend
   `SelectionFilterState`/`select_other_sheet.dart` with a `component`
   kind, usable in either lens and regardless of focus depth (needed for
   Make Focus, mate-authoring, and Move/Rotate no matter which tree is
   currently shown); new component context menu (Make Focus/Move-Rotate/
   Hide/Isolate/Mate/Pattern), wiring Phase 3's `AssemblyFocusStack.push`/
   `pop` to "Make Focus"/"Exit Focus" for the first time. Per-instance
   opacity for non-primary Parts in the focus stack is built here, driven
   by this phase's new `component` selection-filter kind (Phase 3's
   `AssemblyFocusStack` only tracks *which* Part is primary - it has no
   opacity/selectability enforcement of its own yet).
5. **Move/Rotate gizmo + persisted placement + undo** — a new 6-handle
   `component_gizmo.dart` reusing `section_gizmo.dart`'s proven math
   (which itself never persists anything — the actual "drag commits a
   Feature" precedent is `MoveBodyPanel`'s create-then-update-in-place
   pattern). Local component-transform undo built in this phase, not
   deferred — no document-level undo exists anywhere in this app today.
6. **Mate system** (coincident/concentric/parallel/distance/angle) — new
   `assembly_solver.py` (mirrors `sketch/solver.py`'s structure). v1 only
   drives the actively-dragged Occurrence against fixed peers — coupled
   mechanisms (linkages) are a known v1 limitation, not a bug. Debounced
   backend-only solving (same latency-tolerance shape as `MoveBodyFeature`'s
   existing debounce); true low-latency client-side solving via
   `client/native/slvs/`'s FFI shim is possible (pinned to the identical
   fork commit) but needs new forwarding functions that don't exist yet —
   explicitly deferred past v1.
7. **Component pattern** (linear + circular) — a `ComponentPattern` on
   `Part` (not a separate `Assembly` type - see §1 decision #2), expanded
   via `assembly.py`'s transform math only (no OCCT work needed, unlike
   body-level `PatternFeature`).
8. **AI plan pipeline integration** — new `PlanStep` kinds (`mate`,
   `move_component`, `pattern_component`, `hide_component`,
   `isolate_component`) following `MoveBodyStep`'s exact existing template.
   `add_component` needs its own client-side file-discovery mechanism
   (the stateless backend can't enumerate the user's project files) and
   may ship as a later sub-phase.
9. **Hardening, migration, docs** — full `.didsacad` backward-compat test
   matrix; keep this document current as phases land.

## 4. Known v1 limitations (carried forward from the plan, restated so they
   don't get lost)

- Undo is scoped to component transforms only (Phase 5) — hide/show,
  occurrence insert/delete, and mate authoring remain un-undoable, matching
  the rest of the app's current lack of document-level undo.
- Mate solving in v1 only drives the actively-dragged Occurrence against
  fixed peers — no simultaneous multi-body solving (linkages).
- No real-time client-side (FFI) mate solving in v1 — debounced
  backend-only, same tolerated latency as `MoveBodyFeature` today.
- `add_component`'s AI step is gated on a file-discovery mechanism not yet
  designed.
- Composed multi-file graph `part_id`s are session-scoped, not persisted
  across app restarts.
