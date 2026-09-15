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

Backend: `backend/app/document/*` (FastAPI + pythonocc-core/OCCT) -
unchanged from Phase 2 through Phase 4 (see §2e/§2f for why), then Phase 5
added its own first-ever Occurrence mutation endpoint (§2g).
Client: `client/lib/viewport3d/*` (3D viewport/tree/tools, now including
`assembly_tree_panel.dart`, `action_sheet.dart`, `component_context_menu.dart`
(now with a real call site - see §2f), Phase 3b's own additions to
`add_button_menu.dart`/`part_toolbar.dart`, Phase 4's own additions to
`selection_filter.dart`/`selection_hit_test.dart`/`select_other_sheet.dart`/
`selection_list_drawer.dart`/`mesh_geometry.dart`/`part_viewport.dart`, and
Phase 5's own new `component_gizmo.dart` plus further `part_viewport.dart`/
`part_screen.dart` additions), `client/lib/storage/*` (implemented),
`client/lib/assembly/*` (graph compose, document client, `AssemblyLens`,
`AssemblyFocusStack`, `assembly_lens_theme.dart`, `add_component.dart`, and
`occurrence_visibility.dart` (Phase 4, extended in Phase 5) - all
implemented).

**Status: Phase 0 (backend data model), Phase 1 (client storage
abstraction), Phase 2 (multi-file compose + recompute), Phase 3 (lens
toggle + focus-stack state, `AssemblyTreePanel`), Phase 3b (lens
color/theme accent + Assembly-lens "Add" FAB/`PartToolbar` toolset), Phase
4 (whole-component selection + context menu, Make Focus/Exit Focus,
Hide/Isolate, per-instance opacity, instanced viewport rendering), and
Phase 5 (Move/Rotate gizmo, Occurrence transform persistence, local
component-transform undo) implemented. Assembly lens now has a working
in-UI way to add a first component (`Add Component` →
`mergeComponentIntoDocument`), a distinct visual identity, real Make
Focus/Exit Focus, placed Occurrences render and are selectable in the 3D
viewport, and a *top-level* selected component can be dragged (translate/
rotate, persisted, undoable) via a real 6-handle gizmo - see §2e for the
"Add Component" gap (no backend mutation endpoint existed for Occurrences
at all, until §2g's own PATCH endpoint closed that specific gap for
`transform` only), §2f for Phase 4's own real gaps (client-only Hide/
Isolate with no way to persist or override a backend-true `hidden`;
root-Part selectability isn't enforced while focused elsewhere, only
rendering opacity is - both still open, tracked in §5's appendix), and §2g
for Phase 5's own deliberate v1 scope limit (the gizmo only targets a
top-level Occurrence - editing one nested inside a focused sub-assembly
needs ancestor-transform composition this phase doesn't attempt). Phases
6–9 are design-only.**

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

**Also not yet wired, and not previously called out here (a real gap in
this writeup, not a deliberate deferral)**: the lens toggle only swaps the
*side panel*. The "Add" FAB (`_onAddPressed` → `add_button_menu.dart`'s
`showAddButtonMenu`) and `PartToolbar` are both still hardcoded to
Part-lens actions (New Sketch/Feature) regardless of `_lens`, and nothing
in the UI - no FAB/toolbar color, no chrome - signals which lens is active
beyond the tree panel's own content. Practically: Assembly lens is
**read/view-only** today - a user can browse an already-imported
assembly's occurrences/mates but has no in-UI way to add a first
component. See Phase 3b below, inserted directly ahead of Phase 4 to close
this before building further on top of it.

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

## 2e. Phase 3b — Assembly lens toolset + visual theming (implemented)

Closed the gap flagged at the end of §2d: a lens with no way to add
anything and no visual identity of its own wasn't yet a usable second
mode. Two pieces, both real:

### Lens color/theme accent

`client/lib/assembly/assembly_lens_theme.dart` (new) - two pure functions
taking a `ColorScheme` directly (not a `BuildContext`, so both are
directly unit-testable against a specific light/dark scheme with no
widget tree needed):

- `assemblyLensAccentColor(colorScheme, lens)` - `ColorScheme.tertiary`
  for `AssemblyLens.assembly` (Material 3's own dedicated "distinct but
  harmonious" accent slot, rather than a hand-picked hex value needing its
  own light/dark tuning), `ColorScheme.primary` (the app's existing
  default) for `AssemblyLens.part`.
- `assemblyLensContainerColors(colorScheme, lens)` - the matching
  container/on-container pair (`tertiaryContainer`/`onTertiaryContainer`
  vs. plain `surface`/`onSurface`) for a filled background rather than a
  foreground/icon color.

Applied in three places, exactly the set named in the original plan:

- **FAB row** (`part_screen.dart`) - the lens-toggle FAB
  (`assembly-lens-fab`) and the "Add" FAB (`add-fab`) both get
  `backgroundColor: assemblyLensAccentColor(...)` while `_lens ==
  AssemblyLens.assembly`, `null` (the FAB's own default) in Part lens. The
  hamburger/feature-tree FABs are left untinted - they open the same
  toolbar/no-panel-of-their-own regardless of lens, so tinting them would
  signal a distinction that isn't there.
- **`PartToolbar` chrome** - gained a `lens` parameter (defaulting to
  `AssemblyLens.part`, so every pre-Phase-3b call site keeps its exact
  prior look with no change required) that colors the panel's own
  `Material` border (`shape: RoundedRectangleBorder(side: ...)`,
  `BorderSide.none` in Part lens - the same no-border look it always had).
- **`AssemblyTreePanel` header** - always tinted with the Assembly
  accent unconditionally (no lens parameter needed on this one - the panel
  is only ever mounted while `_lens == AssemblyLens.assembly` in the first
  place, per §2d's own "only one of the two tree panels is ever built at a
  time" gate).

### Lens-aware "Add" FAB + `PartToolbar` swap

`client/lib/viewport3d/action_sheet.dart` (new) - the one
bottom-sheet-action-list shell (`ActionSheetEntry<T>`/`showActionSheet<T>`,
`isScrollControlled: true` + a `SingleChildScrollView` so a longer entry
list with two-line disabled subtitles doesn't overflow a constrained
viewport - a real `RenderFlex overflowed` failure the first version of
this widget's own tests caught) shared by both of the below, since both
are flat lists of the same kind of row with several actions in common.

- **`add_button_menu.dart`'s new `showAssemblyAddMenu`/
  `AssemblyAddMenuAction`** - the Assembly-lens branch of `_onAddPressed`
  (`part_screen.dart`): **Add Component** (real - see below),
  **Create Component…** (top-down, disabled), **Add Mate** (disabled),
  **Pattern Component** (disabled). Decomposed as four separate rows
  rather than one "Add Component" row with a bottom-up/top-down
  sub-choice - simpler to implement and test, and keeps the one real
  action unambiguous.
- **`component_context_menu.dart`'s new `showComponentContextMenu`/
  `ComponentContextMenuAction`** - built now (Make Focus/Exit Focus,
  Move/Rotate, Hide/Show, Isolate, Mate, Pattern) since Phase 4 needs the
  identical bottom-sheet-action-list shape and shares two entries
  (Mate/Pattern) with the menu above, but **not wired to any call site
  yet** - `AssemblyTreePanel.onOccurrenceLongPress` still only selects a
  row, exactly as §2d already documented; Phase 4 owns wiring this to that
  callback, since Make Focus/Exit Focus need `AssemblyFocusStack.push`/
  `pop` and the `component` selection-filter kind Phase 4 builds. Move/
  Rotate/Mate/Pattern render disabled (Phases 5-7); Make Focus/Exit Focus/
  Hide/Show/Isolate render enabled - each has a real, already-existing
  backing mechanism (`AssemblyFocusStack`, and the same client-only
  `Set`-based hide/isolate convention `_viewportHiddenFeatureIds` already
  uses for Features) even though nothing calls this function yet.
- **`PartToolbar`'s own Assembly-lens variant** - a new "Assembly"
  `ExpansionTile` (shown only while `lens == AssemblyLens.assembly`) with
  the same four rows as the FAB's own menu, giving toolbar-menu parity
  with the FAB the way File/View already do for Part-lens tools.

**A real gap found while building "Add Component"**: the plan's original
text claimed bottom-up insert and top-down create were "already fully
supported end-to-end by Phase 2's `AssemblyGraphComposer`/
`AssemblyDocumentClient`, only the UI entry point missing." Reading the
actual code before wiring anything showed this wasn't quite right:

- There is **no backend mutation endpoint for Occurrences at all** -
  `backend/app/document/router.py` only has `GET /parts/{part_id}/
  occurrences`/`GET /parts/{part_id}/mates` (Phase 3). The only existing
  way to establish an Occurrence is a full `import_native` replace
  (Phase 0/2) - there is no `POST`/`PATCH` to add one to an already-open
  session.
- `AssemblyGraphComposer`/`AssemblyDocumentClient` (Phase 2) support
  *opening* a whole multi-file assembly graph via `StorageService`/
  `ProjectRoot`, not incrementally adding one Occurrence to a session
  that's already open - and `PartScreen` has never adopted
  `StorageService`/`ProjectRoot` at all; `_openNativeFile`/
  `_saveNativeFile` still use `file_picker` directly with no project-root/
  relative-path concept whatsoever.

Given that, "Add Component" is implemented **without** a new backend
endpoint and **without** `StorageService`/`ProjectRoot`, reusing only
what already exists: `client/lib/assembly/add_component.dart` (new) -
a pure `mergeComponentIntoDocument` function that folds a picked file's
own `export_native` JSON (read via the same `file_picker`-based flow
`_openNativeFile` already uses) into the current session's own full
snapshot (`DocumentApiClient.exportNative()`, no `partId` - every Part
already live in the backend's in-memory session, reflecting every edit
made so far even if never saved to a file), adding one new Occurrence
onto the currently-open root Part. The merged payload goes straight back
through `DocumentApiClient.importNative` - a full replace, the exact same
semantics `_openNativeFile` already relies on, just staying on this
screen instead of pushing a new one (the Part's own id survives the
round trip unchanged - `native_format.py`'s `_part_from_dict` never
regenerates an id it's given). Dedups by the incoming Part's own
persisted id, mirroring Phase 2's "two Occurrences resolving to one Part
is an ordinary dedup" behaviour even with no `ProjectRoot`-relative-path
identity to key off. `externalRef` is only the picked file's own display
name (e.g. `"bracket.didsa"`), not a real project-relative path, for the
same reason.

This is genuinely real and tested end to end (client-side) - a user can
insert an existing `.didsa` file as a new component and see it appear as
an Occurrence in the Assembly tree. What it does **not** do: render the
inserted Occurrence in the 3D viewport (already a documented §2d gap,
unrelated to this phase) or support re-saving the now-multi-part session
back out to separate files (no multi-file save flow exists - this is why
top-down "Create Component" stays disabled: a brand-new in-session Part
is trivial to create, but there's nowhere yet to persist it).

**Verified**: no backend changes this phase (see the gap above - this
worked entirely with the client's existing endpoints), so the backend
suite was only re-confirmed at its pre-existing baseline, not re-verified
against new backend code - **2214/2214 passed** against real
`pythonocc-core`/`py-slvs`, unchanged from §2d. Full client suite -
**1762/1762 passed** before this phase's own new tests were added; after,
`flutter analyze` clean on every touched/new file, and 38 new tests:
9 `mergeComponentIntoDocument` unit tests (dedup, self-reference guard,
schema mismatch, missing root_part_id fallback, missing-Parts/missing-root
failures, nameOverride pass-through), 8 `assemblyLensAccentColor`/
`assemblyLensContainerColors` unit tests (light+dark, both lenses), 4
`showActionSheet` widget tests (enabled tap, disabled subtitle/no-op, no
subtitle when enabled), 7 `showComponentContextMenu` widget tests
(Focus/Hide label flips, Isolate, the disabled-vs-enabled split), 4
`showAssemblyAddMenu` widget tests (the same split), 5 `PartToolbar`
widget tests (border color under each lens, Assembly menu visibility/
enabled state), plus one new `AssemblyTreePanel` header-color test.
`action_sheet.dart`'s own first test revealed a real overflow bug
(`showComponentContextMenu`'s six rows didn't fit a constrained viewport,
`RenderFlex overflowed`) - fixed by wrapping the shared shell in
`isScrollControlled: true` + `SingleChildScrollView` before any of that
file's tests were counted as passing. The full `part_screen_test.dart`
suite (57 tests) was re-run after wiring `_onAddPressed`/the two FAB
colors/`PartToolbar`'s new params into that file and passed with zero
regressions - no new end-to-end test was added at that level for the FAB
colors specifically, since they're a one-line ternary reusing the same
`assemblyLensAccentColor` function already covered directly, and
`_FakeDocumentBackend` (`part_screen_test.dart`'s own test double) has no
`listOccurrences`/`listMates` route implemented, making a full lens-toggle
round trip through that harness a disproportionately large, fragile
addition for what it would actually catch beyond the existing coverage.

---

## 2f. Phase 4 — Whole-part selection + context menu (implemented)

Closed the two gaps §2d/§2e each flagged and deliberately left open:
`AssemblyTreePanel.onOccurrenceLongPress` had no real action behind it, and
the 3D viewport never rendered a placed Occurrence at all - only this
screen's own root Part ever showed. Both needed for the same reason: Make
Focus/Hide/Isolate/opacity are all about *which rendered instance* is
primary right now, and there was no rendered instance to be primary about
before this phase.

### `component` selection kind

`client/lib/viewport3d/selection_hit_test.dart` gains
`SelectionEntityKind.component` and `SelectionEntityRef.occurrenceId` (a
joined `occurrencePath`, not a bare Occurrence id - the same Part
definition can be placed more than once at different paths, Phase 2's own
dedup precedent, so the path is what's actually unique per rendered
instance). `client/lib/viewport3d/selection_filter.dart`'s
`SelectionFilterState` gains a matching `component` field - defaulting
`true` (unlike `body`, which started `false` with no hit-test to gate at
all until a later prompt gave it one - `component` has a real consumer
from this same phase). Every other exhaustive `switch` over
`SelectionEntityKind` the compiler flagged (`select_other_sheet.dart`,
`selection_list_drawer.dart`, and two in `part_viewport.dart` - one
accumulating every selected entity's highlight geometry, one building a
single hover/selection highlight Node) gained a `component` case, mirroring
each file's own existing `body` case (a whole-component highlight is every
one of its own Bodies' faces, the same "highlight everything, not just
one" treatment a whole-Body selection already gets).

### Instanced viewport rendering + hit-testing

The real, previously-deferred piece: `PartViewport` now actually renders
Phase 2's `assembly-mesh` response. `PartScreen._refreshAssemblyMesh` fetches
it (lazily, same "most sessions never open Assembly lens" cost-avoidance
`_refreshAssemblyTree` already established) and feeds two new
`PartViewport` fields - `assemblyGeometry` (the dedup'd per-Part geometry)
and `assemblyInstances` (every placed Occurrence's own world transform) -
into a new `_syncAssemblyInstanceNodes`, `_syncMeshNode`'s sibling for this
one job. Placement uses a new pure `mesh_geometry.dart` function,
`matrix4FromRigidTransform` (translation + axis-angle rotation, rotate-
then-translate via `vm.Matrix4.compose` - the client-side counterpart to
`backend/app/document/assembly.py`'s identical backend-side math, verified
against the same identity/pure-translation/known-angle/180°-edge-case
matrix `assembly.py`'s own tests already cover). Hit-testing gained a new
`selection_hit_test.dart` function, `hitTestComponentInstances` -
`hitTestBodies`' whole-instance sibling, wired into
`PartViewport._recomputeHover` as a third candidate competed by `rayT`
against the existing mesh/plane candidates exactly the way those two
already compete against each other.

An instance's own `occurrencePath` empty means the requested root Part's
own local content (Phase 2's convention) - skipped by both the render and
hit-test paths, since that content is already covered by the ordinary
`PartViewport.bodies` path; rendering/testing it a second time at the
identity transform would just double it.

### Make Focus / Exit Focus (real, for the first time)

`AssemblyTreePanel.onOccurrenceLongPress` → `PartScreen._onOccurrenceLongPress`
now calls `component_context_menu.dart`'s `showComponentContextMenu` (built
in Phase 3b with no caller until now) and acts on the result:

- **Make Focus** pushes the Occurrence's own `resolvedPartId` onto
  `AssemblyFocusStack` (Phase 3's `push`/`pop`'s first real call site) and
  re-fetches the Assembly tree, so the panel immediately shows the newly-
  focused Part's own Occurrences/Mates - exactly the "which Part is primary"
  question `_refreshAssemblyTree` already keyed off `AssemblyFocusStack.current`
  for, since Phase 3, with nothing ever pushing onto it until now. Disabled
  (surfaces an error rather than silently no-opping) for an unresolved
  Occurrence - there is no Part id to push.
- **Exit Focus** pops it and re-fetches the same way.
- **Hide/Show** toggle a new, purely client-side `_hiddenOccurrenceIds` set
  (mirrors `_hiddenFeatureIds`'s own convention exactly) - no backend
  mutation endpoint exists for Occurrences at all (§2e's own documented
  gap), so this can never be more than a session-only overlay.
- **Isolate** sets/clears a new `_isolatedOccurrenceId` (at most one at a
  time) - hides every *other* Occurrence. A toggle (Isolate again on the
  same Occurrence clears it), since the context menu has no separate
  "un-isolate"/"show all" action of its own yet.
- **Move/Rotate/Mate/Pattern** stay disabled in the menu itself (Phases
  5-7) and so never reach this `switch` - the same "picker already
  filtered to enabled entries" shape `_onAssemblyAddPressed` already uses
  for its own disabled entries.

Both overlays are combined with each Occurrence's own backend-reported
`hidden` via two new, standalone, directly-tested pure functions in
`client/lib/assembly/occurrence_visibility.dart` - rather than living only
as private getter logic, so both have real coverage independent of
`part_screen_test.dart`'s own backend-fake limitations (see below).
`applyOccurrenceVisibilityOverrides` feeds `PartScreen._displayOccurrences`
(the Assembly tree's own list, keyed by bare Occurrence id, since an
`OccurrenceDto` is only ever shown at one nesting level at a time);
`applyInstanceVisibilityOverrides` feeds `PartViewport.assemblyInstances`
directly (Phase 2's own placed-instance list, keyed by the *whole*
`occurrencePath` chain, since a nested instance's path can contain a
Hidden/Isolated Occurrence from any ancestor level - Hide/Isolate on a
sub-assembly must hide/isolate everything nested inside it too, the
standard CAD convention, which matching only the path's last segment would
miss). Without the second function, Hide/Isolate would only ever have
affected the tree panel's own rows, never what actually renders in the 3D
viewport - caught before this phase's own tests were considered complete,
not after. **Scope limit** (full write-up in §5, item 1): Hide/Show/
Isolate can only ever *OR* onto whatever the backend already reports,
never override it.

### Opacity/selectability split

`mesh_geometry.dart` gains `assemblyInstanceOpacity` (pure, tested) and
`buildAssemblyInstanceNode` (GPU-bound, builds the placed instance's own
Node at a given opacity/transform) plus the fixed
`kNonPrimaryAssemblyOpacity` translucency constant. The rule: while no
focus is active, every top-level instance renders fully opaque
(`PartViewport.focusedComponentPartId == null` - ordinary assembly
browsing); once a focus *is* pushed, only the one instance whose own
target Part matches `AssemblyFocusStack.current` stays opaque - every
other instance, **and the root Part's own local content** (`_syncMeshNode`
folds a matching dim factor into `widget.bodyOpacity`, composing with
rather than overriding the user's own Transparency slider), fades to
`kNonPrimaryAssemblyOpacity`. Selectability mirrors this exactly in
`PartViewport._hoverHitTestComponents`: an instance outside the focused
subtree is excluded from `hitTestComponentInstances`' own
`selectableOccurrencePaths` set entirely, never merely a losing candidate -
the same "hidden means genuinely untestable" contract
`PartViewport.bodiesHidden` already applies to a Part's own Bodies.

**Scope limits** (full write-up in §5, items 2-4): the root Part's own
Bodies stay selectable regardless of focus; `AssemblyFocusStack` tracks
*which Part* is focused, not *which Occurrence*; and - found on review
after this phase shipped, not caught by its own tests - a placed instance
*nested inside* the focused Occurrence (a "child" in the assembly-tree
sense) is **not** treated as part of the focused subtree by either
`assemblyInstanceOpacity` or `_hoverHitTestComponents`' own selectable-set
computation, both of which match only `instance.partId ==
AssemblyFocusStack.current` (an exact target-Part match), never occurrencePath
containment. §2d's own original "Deferred, not yet wired" language asked
for "focus part **and its children** opaque, peers and parents
translucent" - only the exact-match half of that was actually built.

**Verified**: no backend changes this phase (pure client work, reusing
Phase 2's existing `GET /parts/{part_id}/assembly-mesh` endpoint
end-to-end for the first time) - backend suite re-confirmed at its
pre-existing baseline against real `pythonocc-core`/`py-slvs` -
**2214/2214 passed**, unchanged from §2d/§2e. Full client suite -
**1800/1800 passed** before this phase's own new tests were added; after,
`flutter analyze` clean on every touched/new file, and **1833/1833
passed** (12 GPU-skips, unchanged), with new tests across:
`selection_filter_test.dart` (component defaults/copyWith/equality),
`selection_hit_test_test.dart` (two new `SelectionEntityRef` equality
cases for the `component` kind, plus `hitTestComponentInstances`'
selectable-instance hit, excluded-instance skip, root's-own-empty-path
skip, nearest-of-two-instances-wins, nested-path joining, and a genuine
miss), `mesh_geometry_test.dart` (`matrix4FromRigidTransform`'s identity/
pure-translation/known-angle/180°-edge-case/degenerate-axis cases -
loosened to a `1e-6` tolerance after a real, caught-before-commit failure:
`vm.Matrix4`/`vm.Vector3` store components as single-precision
`Float32List`, so a trig-derived result can land a few ULPs off an exact
integer value even though the maths itself is correct; `assemblyInstanceOpacity`'s
focus-active/focused-instance matrix), `occurrence_visibility_test.dart`
(new file - every
`applyOccurrenceVisibilityOverrides` combination: no override, hidden-set,
isolate, both composing, a backend-true `hidden` staying un-overridable,
non-mutation of the input, and the empty-list case; plus
`applyInstanceVisibilityOverrides`' own occurrencePath-prefix cases: hiding
a top-level Occurrence also hides its own nested instance, hiding a nested
one does *not* hide its parent, isolating a top-level Occurrence keeps its
own nested contents visible while hiding every peer, and the same backend-
true/empty-list cases), and two new
`part_screen_test.dart` cases confirming a `component`-kind
`onSelectionToggle` never lands in `PartViewport.selectedEntities` (the
generic accumulate-toggle every other kind shares) while an ordinary
`face` entity still does. A full end-to-end Make Focus/Hide/Isolate round
trip through `part_screen_test.dart` was **not** attempted -
`_FakeDocumentBackend` has no `listOccurrences`/`listMates`/
`getAssemblyMesh` route implemented (§2e's own already-documented reason
this stays out of scope for that harness) - mirroring exactly the same
cost/benefit call §2e already made for its own FAB-wiring tests.

---

## 2g. Phase 5 — Move/Rotate gizmo + persisted placement + undo (implemented)

Landed in two passes within the same phase: the backend/math foundation
first, then the interactive wiring - see the git history for the exact
split if it matters, but both are complete and this section covers the
whole thing as shipped.

### Persistence

`PATCH /parts/{part_id}/occurrences/{occurrence_id}` - the first mutation
endpoint an Occurrence has ever had (`OccurrenceTransformUpdate` schema,
whole-`transform` replace). No "create" step the way `MoveBodyFeature`
needs one - an Occurrence already exists and its placement is a plain
field, not a new history entry, so every drag (debounced client-side to
one PATCH per gesture, on drag-end only - see below) PATCHes this same
endpoint directly. `DocumentApiClient.updateOccurrenceTransform` +
`RigidTransformDto.toJson`/`==`/`hashCode` on the client (equality needed
for real: `PartViewport.didUpdateWidget`'s own change-detection convention
depends on it, the same way every other comparable prop on that widget
already does).

### `component_gizmo.dart`

The 6-handle (3 translate arrows + 3 rotate rings) sibling of
`section_gizmo.dart`, reusing that file's own `closestPointOnLineToRay`/
`angleOnRotationPlane` drag primitives rather than re-deriving equivalent
math: `ComponentGizmoBasis` (world-space origin + the Occurrence's own
current local axes, built from a placement `Matrix4` via
`matrix4FromRigidTransform`), `hitTestComponentGizmo`/
`buildComponentGizmoNode` (mirroring `hitTestSectionGizmo`/
`buildSectionGizmoNode` almost line for line, just with a third arrow/ring
pair - a component's placement has no "this axis doesn't matter" omission
the way a section plane's own normal-axis rotation does), and the drag-math
functions: `composeTranslation` (trivial - translations always commute),
`composeRotation` (composes a drag's own delta rotation *onto* the
Occurrence's existing rotation via quaternion multiplication - `q_current *
q_delta`, the delta expressed in the object's own already-rotated local
frame - then collapses back to a single axis-angle pair, since
`RigidTransform` has no quaternion field of its own), `translateDragDelta`/
`rotateDragDeltaRadians` (the absolute-delta-from-drag-start wrappers
`PartViewport`'s own drag state calls each pointer-move).

### Wiring into `PartViewport`

New `selectedOccurrenceTransform`/`onComponentGizmoDragUpdate`/
`onComponentGizmoDragEnd` props, plus a `_componentGizmoDrag*` field set and
`_tryBeginComponentGizmoDrag`/`_updateComponentGizmoDrag`/
`_syncComponentGizmoNode` methods - all structurally identical to the
section gizmo's own `_sectionDrag*`/`_tryBeginSectionGizmoDrag`/
`_updateSectionGizmoDrag` triplet, checked in `_onPointerDown`/
`_onPointerMove`/`_onPointerEnd` right after the section gizmo's own check
(a manipulator grab always wins over orbit/select/draw-cursor). Critically,
this includes the exact same per-pointer ownership gating
(`event.pointer == _componentGizmoDragPointerId`) the section gizmo needed
a real on-device bug report to discover it was missing - built in from the
start here rather than rediscovered, and directly regression-tested
(`component_gizmo_touch_test.dart`, mirroring `section_gizmo_touch_test.dart`'s
own stuck-touch-state scenario: a second finger touching down and lifting
mid-drag must never end or hijack the first finger's own drag, and
`_activeTouches` must never end up with an orphaned entry).

Live-drag feedback needs no new rendering code of its own for the moved
Body: `PartScreen._displayAssemblyInstances` (via the new
`overrideInstanceTransform`, `occurrence_visibility.dart`'s third pure
function) overrides the dragged Occurrence's own instance entry with the
live transform, and the *existing* `_syncAssemblyInstanceNodes` (Phase 4)
already re-renders whatever `PartViewport.assemblyInstances` says - the
gizmo overlay is the only genuinely new Node.

### `PartScreen` state + undo

`_gizmoTargetOccurrence` (the selection, scoped to a *top-level* Occurrence
only - see the scope-limit callout below), `_gizmoLiveTransform` (the
optimistic in-flight value, cleared only *after* the post-drag
PATCH+refetch completes, so there is never a stale-value flicker while
that request is in transit), and `_componentTransformUndoStack` (a plain
`List<(occurrenceId, previousTransform)>` - "local component-transform
undo built in this phase, not deferred," the *only* undo mechanism
anywhere in this app, surfaced as a small Undo FAB shown only in Assembly
lens and only once the stack is non-empty).

### A real, deliberate v1 scope limit: top-level Occurrences only

`Occurrence.transform` is relative to its own immediate parent, and only
the root Part's own frame is guaranteed world identity - so only a
top-level Occurrence's local and world transforms coincide without this
screen needing to convert between the two. `_gizmoTargetOccurrence` gates
on `!(_focusStack?.isFocused ?? false)`: the gizmo simply doesn't appear
for a selection made while focused into a sub-assembly. Real, undone
follow-up work, not an oversight - editing a nested Occurrence needs the
gizmo's own drag math to account for whatever rotation its ancestor chain
contributes, which this phase doesn't attempt. Worth revisiting once
there's real usage of nested assemblies to judge how much it's actually
missed.

**Verified**: backend - `test_occurrence_transform_update.py` (update/
re-fetch/re-export/404×2/sibling-isolation), full suite **2219/2219
passed** against real `pythonocc-core`/`py-slvs`, unchanged since (no
backend changes in the interactive-wiring pass). Client - `flutter
analyze` clean on every touched/new file throughout; full suite
**1865/1865 passed** (14 GPU-skips - two more than Phase 4's own 12, both
new: `component_gizmo_touch_test.dart`'s pair of pointer-ownership tests
join `section_gizmo_touch_test.dart`'s pre-existing single test in
gracefully self-skipping in this headless sandbox's own no-real-GPU
limitation, not a regression). New tests: `component_gizmo_test.dart` (16
- `ComponentGizmoBasis.fromMatrix`'s identity/translation/rotation cases,
`hitTestComponentGizmo`'s per-handle hits and a miss, `composeTranslation`,
`composeRotation`'s 90°-composition/180°-accumulation/exact-cancellation
cases, `translateDragDelta`/`rotateDragDeltaRadians`'s hit and miss
cases - one real caught-before-commit bug here: the first hit-test tests
fired rays straight through the shared origin every arrow starts from, an
ambiguous three-way tie the iteration order silently broke, fixed by
aiming at each arrow's own midpoint instead), `component_gizmo_touch_test.dart`
(2, the stuck-touch-state regression pair described above), and 5 new
`overrideInstanceTransform` cases in `occurrence_visibility_test.dart`
(exact-match override, a nested child left alone, a parent left alone,
no-match leaves everything untouched, empty list). A full end-to-end
drag-through-`PartScreen` test (real PATCH call, undo stack, live-preview
flicker-avoidance) was **not** attempted - same `_FakeDocumentBackend`
`listOccurrences`/`listMates`/`getAssemblyMesh` gap §2e/§2f already
documented, plus a real on-screen gizmo hit-test needs camera-dependent
screen coordinates this sandbox has no way to visually confirm; the
pointer-*ownership* correctness (the actual historical bug class) is
covered via `debugForceComponentGizmoDrag` instead, mirroring
`section_gizmo_touch_test.dart`'s own identical choice.

---

## 3. Remaining phases (design-only)

Phase 4 ("Whole-part selection + context menu") moved to §2f, and Phase 5
("Move/Rotate gizmo + persisted placement + undo") to §2g - both
implemented. Numbering below is otherwise unchanged from the original plan
(starts at 6 rather than being renumbered), so every existing cross-
reference elsewhere in this document (e.g. §4's own "Phase 5" undo note,
which still correctly points at what's now §2g) still points at the same
phase it always did.

5. **~~Move/Rotate gizmo + persisted placement + undo~~ — moved to §2g,
   implemented.**
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

## 5. Appendix — Phase 4 scope limits (evaluate after rollout)

Real, deliberately-scoped gaps Phase 4 (§2f) shipped with rather than
silently claiming done - pulled out of that section's own narrative into
one place specifically so they get a real look once the phase has been
used for a while, rather than staying buried in a "Verified" paragraph
nobody revisits. None of these block Phase 4's own stated goal (whole-
component selection + context menu); all are candidates for either a
follow-up fix inside a later phase or a deliberate "still fine, leave it"
call once there's real usage to judge them against.

**Update**: items 3 and 4 were fixed directly (same session, ahead of any
real rollout) rather than left for later - struck through in place, not
deleted, so the record of what shipped broken and why stays intact. Items
1-2 are still open and still genuinely await real usage before deciding
whether they're worth fixing at all.

1. **Hide/Show/Isolate can only ever *OR* onto the backend's own `hidden`
   flag, never override it.** No mutation endpoint exists for Occurrences
   at all (§2e), so an Occurrence whose `hidden` arrived from the backend
   as `true` (e.g. loaded from a file saved with it hidden) can never be
   un-hidden client-side - Show only ever clears *this session's own*
   override, not the backend's own value. Revisit once Phase 6+ (or
   whichever phase finally adds a real Occurrence-mutation endpoint) makes
   a true, persisted Show possible.
2. **The root Part's own Bodies stay selectable regardless of focus
   state.** Once a component is focused elsewhere, its opacity correctly
   fades (`_syncMeshNode`'s `effectiveBodyOpacity`), but the ordinary
   `hitTestBodies`/feature-editing hit-test path was deliberately left
   ungated - blocking it would mean touching the one hit-test every
   Part-lens feature tool in this app already depends on, unconditionally,
   for a selectability guarantee no bug report has asked for yet. Revisit
   if real usage shows someone accidentally editing/selecting root-Part
   geometry while intending to work inside a focused component.
3. **~~`AssemblyFocusStack` tracks *which Part* is focused, not *which
   Occurrence*~~ - resolved as a side effect of fixing item 4 below.**
   `AssemblyFocusStack.current` (bare Part id, used by `_refreshAssemblyTree`/
   `_onInsertComponentPressed` to know which Part's own Occurrences/Mates to
   fetch - a legitimate use of "just the Part id," since that answer really
   doesn't depend on *which* placed instance you're inside) is unchanged
   and still Part-id-keyed - that part of the original concern doesn't
   need fixing. What actually mattered - rendering opacity/selectability
   correctly telling two instances of the same shared Part apart - now
   works, since both key off the new `AssemblyFocusStack.currentOccurrencePath`
   (item 4's own fix) rather than `current`'s bare Part id.
4. **~~A placed instance nested *inside* the focused Occurrence is not
   treated as part of the focused subtree~~ - fixed.** `AssemblyFocusStack`
   gained `currentOccurrencePath` (the full Occurrence-id chain down to the
   focus, populated by `push`'s new `occurrenceId` parameter - a real,
   non-optional argument now, not a nullable add-on) and a new pure
   function, `client/lib/assembly/occurrence_visibility.dart`'s
   `isOccurrencePathWithinFocus`, replaces the old exact-`partId`-match
   check everywhere `PartViewport` decides opacity
   (`_syncAssemblyInstanceNodes`) or selectability
   (`_hoverHitTestComponents`) - both now correctly treat a nested child
   instance as part of the focused subtree, matching §2d's original
   "focus part **and its children** opaque, peers and parents translucent"
   language for the first time. `PartViewport.focusedComponentPartId` (a
   bare `String?`) was replaced outright by `focusedOccurrencePath` (a
   `List<String>`, `AssemblyFocusStack.currentOccurrencePath` piped
   straight through) rather than kept alongside it, so there is exactly
   one source of truth for "what's focused" feeding the viewport - not two
   fields that could drift apart. `AssemblyFocusStack.currentOccurrencePath`
   itself only ever reassigns its `List` on an actual `push`/`pop`/`clear`
   (never rebuilds one on a bare read), preserving the identity-based
   change-detection contract `PartViewport.didUpdateWidget`'s `!=` checks
   already rely on for every other `List`-typed field on that widget.
   Real tests added: `focus_stack_test.dart` (accumulates the full chain
   across nested pushes, not just the last one; pops remove only the last
   segment; stable `List` identity across bare reads) and
   `occurrence_visibility_test.dart` (`isOccurrencePathWithinFocus`'s own
   exact-match/nested-child/peer/parent/sibling/unrelated-path cases). No
   backend changes - client suite **1844/1844 passed** (up from 1833, 12
   GPU-skips unchanged), `flutter analyze` clean.
   **Noticed but out of scope for this fix**: `_onOccurrenceLongPress`'s
   own `isFocused` (which picks "Make Focus" vs "Exit Focus" in the menu
   label) still compares `focusStack.current == resolvedPartId` - since
   the Assembly tree only ever shows a Part's own *children*, this can
   only be true for a self-referencing Occurrence (which cycle detection
   already forbids), so in practice the label the menu ever shows may
   itself be a latent, likely-inconsequential quirk predating this fix -
   not touched here since it's a distinct concern from the rendering gap
   this item was actually about.
