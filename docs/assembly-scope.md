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
added its own first-ever Occurrence mutation endpoint (§2g); unchanged
again in Phase 6a (see §2h for why - a client-only prerequisite, no new
mate data to persist yet), then Phase 6 added `assembly_solver.py` and its
own mate CRUD/solve endpoints (§2i), then Phase 7 added `ComponentPattern`
and its own CRUD endpoints plus `assembly.py`'s expansion math (§2j) -
still no new OCCT work of its own, same "pure transform composition" shape
Phase 0's own `compose`/`compose_chain` already established.
Client: `client/lib/viewport3d/*` (3D viewport/tree/tools, now including
`assembly_tree_panel.dart`, `action_sheet.dart`, `component_context_menu.dart`
(now with a real call site - see §2f; its Move/Rotate entry fixed in §2h),
Phase 3b's own additions to `add_button_menu.dart`/`part_toolbar.dart`,
Phase 4's own additions to `selection_filter.dart`/`selection_hit_test.dart`/
`select_other_sheet.dart`/`selection_list_drawer.dart`/`mesh_geometry.dart`/
`part_viewport.dart`, Phase 5's own new `component_gizmo.dart` plus further
`part_viewport.dart`/`part_screen.dart` additions, Phase 6a's own further
`selection_hit_test.dart` addition, Phase 6/6b's own new
`mate_panel.dart`/`selection_breadcrumbs.dart` plus further
`part_viewport.dart`/`part_screen.dart` wiring, and Phase 7's own new
`component_pattern_panel.dart` plus further `add_button_menu.dart`/
`component_context_menu.dart`/`assembly_tree_panel.dart`/`part_screen.dart`
wiring - no new viewport rendering path needed, see §2j), `client/lib/
storage/*` (implemented), `client/lib/assembly/*` (graph compose, document
client, `AssemblyLens`, `AssemblyFocusStack`, `assembly_lens_theme.dart`,
`add_component.dart`, and `occurrence_visibility.dart` (Phase 4, extended
in Phase 5) - all implemented).

**Status: Phase 0 (backend data model), Phase 1 (client storage
abstraction), Phase 2 (multi-file compose + recompute), Phase 3 (lens
toggle + focus-stack state, `AssemblyTreePanel`), Phase 3b (lens
color/theme accent + Assembly-lens "Add" FAB/`PartToolbar` toolset), Phase
4 (whole-component selection + context menu, Make Focus/Exit Focus,
Hide/Isolate, per-instance opacity, instanced viewport rendering), Phase 5
(Move/Rotate gizmo, Occurrence transform persistence, local
component-transform undo), Phase 6a (occurrence-attributed selection -
Mate authoring's own prerequisite), Phase 6/6b (the mate solver and
the selection breadcrumbs UI), Phase 7 (linear/circular
`ComponentPattern`, §2j), and Phase 8 (AI plan pipeline integration - `mate`/
`move_component`/`hide_component`/`isolate_component` `PlanStep` kinds,
§2k) implemented. Assembly lens now has a
working in-UI way to add a first component (`Add Component` →
`mergeComponentIntoDocument`), a distinct visual identity, real Make
Focus/Exit Focus, placed Occurrences render and are selectable in the 3D
viewport, a *top-level* selected component can be dragged (translate/
rotate, persisted, undoable) via a real 6-handle gizmo, a
vertex/edge/face/body hit against *placed Occurrence-instance* geometry can
be tagged with which Occurrence it came from, mates (coincident/
concentric/parallel/distance/angle) can be authored between two selected
entities and solved against the dragged Occurrence, a selected
entity's own containment chain (face/edge/vertex → body → component) shows
as a tappable breadcrumb bar, and a top-level component can be patterned
(linear or circular) into N derived, rendered-but-not-persisted placed
instances - see §2e for the "Add Component" gap (no
backend mutation endpoint existed for Occurrences at all, until §2g's own
PATCH endpoint closed that specific gap for `transform` only), §2f for
Phase 4's own real gaps (client-only Hide/Isolate with no way to persist or
override a backend-true `hidden`; root-Part selectability isn't enforced
while focused elsewhere, only rendering opacity is - both still open,
tracked in §5's appendix), §2g for Phase 5's own deliberate v1 scope limit
(the gizmo only targets a top-level Occurrence - editing one nested inside
a focused sub-assembly needs ancestor-transform composition this phase
doesn't attempt), §2h for Phase 6a's own deliberate scope limit (the new
hit-test capability wasn't yet wired into any live picking mode - fixed by
Phase 6's own Mate picking mode, §2i), §2i for Phase 6/6b's own
deliberate v1 scope limits (single-Occurrence-against-fixed-peers solving,
no straight-edge axis reference, no feature-level breadcrumb tier, no live
breadcrumb hover-preview highlight), and §2j for Phase 7's own deliberate
v1 scope limits (top-level source Occurrences only, one source per
authored pattern in the UI even though the backend accepts several, no
arbitrary custom axis/direction in the panel, no pattern edit/delete UI
yet), §2k for Phase 8's own deliberate v1 scope limits (`pattern_component`
and `add_component` both still deferred, no assembly-level edge-selector
heuristic for a Mate's own geometry refs, the manual Hide/Show/Isolate UI
still uses the pre-existing session-only overlay rather than the newly-
widened `hidden` PATCH), and §2l for Phase 9 (hardening/migration/docs -
the full `.didsacad` backward-compat test matrix, plus this document's own
currency pass). Every phase §3 originally scoped is now implemented -
`pattern_component`/`add_component` are the only two deliberately deferred
pieces of the original brief, both tracked in §2k/§5, not silently dropped.**

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

## 2h. Phase 6a — occurrence-attributed selection (implemented)

The prerequisite half of §3's original 6a/6b split (surfaced by a user
request for SOLIDWORKS-style "selection breadcrumbs" while auditing Phases
0-5 for completeness, before either sub-item had a home of its own) - see
§3 below for 6b, the breadcrumb UI itself, still deliberately deferred.

### The gap this closes

Before this phase, `SelectionEntityRef.occurrenceId`
(`client/lib/viewport3d/selection_hit_test.dart`) was populated *only* for
a `SelectionEntityKind.component` hit (`hitTestComponentInstances`, Phase
4's whole-Occurrence-instance hit test) - a face/edge/vertex hit only ever
existed against the root Part's own Bodies (`hitTestBodies`), which has no
Occurrence concept at all, so there was no hit-test capability that could
even produce a face/edge/vertex hit *on placed Occurrence-instance
geometry* in the first place, let alone tag one with which Occurrence it
came from. That's fine for Phase 4/5 (whole-component selection, top-level
gizmo drag), but a mate needs "this face, on this *specific* Occurrence" -
the same Part placed twice (Phase 2's own dedup precedent) must resolve to
two distinct mate targets, not one ambiguous one.

### `hitTestComponentInstanceEntities`

New sibling of `hitTestComponentInstances` in `selection_hit_test.dart`,
mirroring `hitTestBodies`'s own vertex→edge→face priority hit-test exactly,
but run against placed Occurrence-instance geometry (`AssemblyMeshDto`'s
`geometry`/`instances`, the same inputs `hitTestComponentInstances` already
takes) instead of `PartViewport.bodies`. Reports a
`SelectionEntityKind.vertex`/`edge`/`face`/`body` hit - never `component` -
with `bodyId`/`id` scoped exactly the way a root-Part hit already is,
*plus* `SelectionEntityRef.occurrenceId` set to the hit instance's own
joined `occurrencePath` (the same convention `hitTestComponentInstances`
already established for its own whole-component kind). Mirrors that
function's transform/lookup machinery precisely: skips an empty
`occurrencePath` (the root Part's own content, already covered by the
ordinary `hitTestBodies` call), skips an instance outside
`selectableOccurrencePaths` entirely rather than merely deprioritizing it,
and transforms each instance's own local Body mesh into world space via
`matrix4FromRigidTransform` before ray-testing. Does not implement
`hitTestBodies`'s own `facesOccludeOtherHits`/Sketch-geometry handling -
neither concept exists for placed-instance geometry today (no Sketch is
ever rendered against another Part's own Occurrence, and
`hitTestComponentInstances` itself never occludes one instance's hit
against another's either), so the new function stays exactly as broad as
the capability actually needed.

`SelectionEntityRef.occurrenceId`'s own doc comment was updated to match -
no longer "meaningless for every other kind" (Phase 4's original claim,
true only until this phase), now documented as populated for a
vertex/edge/face/body kind too whenever the hit came from
`hitTestComponentInstanceEntities` rather than `hitTestBodies`.

### Appendix item 5 fixed in the same pass

While in this area of the codebase, also fixed the appendix's own item 5
(a real, already-open gap, not new to this phase):
`component_context_menu.dart`'s "Move/Rotate" entry was still hardcoded
`enabled: false` ("Coming soon - needs Phase 5's move/rotate gizmo") even
though Phase 5 shipped and the gizmo already works via plain tap-selection,
entirely independent of that menu entry - a discoverability/consistency
bug, not a functional blocker. Fixed as the one-line enable the appendix
item itself predicted would suffice: `part_screen.dart`'s
`_onOccurrenceLongPress` already selects the long-pressed row
(`_selectedOccurrenceId = occurrence.id`) before the context menu even
opens, which is exactly what `_gizmoTargetOccurrence` reads to show the
gizmo, so the `case ComponentContextMenuAction.moveRotate:` handler itself
needed no new logic - see §5's own appendix entry for the struck-through
record.

### Deliberately not wired into any live picking mode

`hitTestComponentInstanceEntities` has no caller in `part_viewport.dart`
today - no picking mode needs sub-entity granularity on assembly-instance
geometry until Mate authoring's own UI exists (Phase 6, out of scope for
this prerequisite-only pass), and wiring it into `_recomputeHover`'s
always-on default-browsing hover path (competing against the existing
whole-component `_hoverHitTestComponents`) would change Phase 4/5's
already-shipped default selection behavior for no consumer that exists
yet. Mirrors `assembly.py`'s own Phase 0 precedent ("pure vector/matrix
math ... not yet consumed by any endpoint") - verified directly via real
tests instead, ready for Phase 6's `assembly_solver.py`/mate-picking UI to
call once that phase actually builds a picking mode that needs it.

**Verified**: no backend changes (a client-only prerequisite - no new mate
data to persist yet), so the backend suite was only re-confirmed at its
pre-existing baseline, unchanged from §2g - **2219/2219 passed** against
real `pythonocc-core`/`py-slvs`. Full client suite - **1876/1876 passed**
(14 GPU-skips, unchanged from §2g - no new GPU-dependent test was added),
`flutter analyze` clean on every touched file. New tests: 9
`hitTestComponentInstanceEntities` cases in `selection_hit_test_test.dart`
(vertex/edge/face/body hits each tagged with `occurrenceId`; the same Part
definition placed twice resolving to two distinct `occurrenceId`s at the
identical local `bodyId`/`id` - the exact ambiguity this phase exists to
resolve; an unselectable instance excluded entirely; an empty
`occurrencePath` always skipped; a nested `occurrencePath` joined with
`/`; a ray missing every instance returns null) plus one
`SelectionEntityRef` equality case (two `face` refs with identical
`bodyId`/`id` but different `occurrenceId` are not equal). Appendix item
5's own fix is covered by `component_context_menu_test.dart`'s updated
"Make Focus, Move/Rotate, Hide, and Isolate render enabled" case (grown
from three entries to four) plus a new "tapping Move/Rotate resolves
moveRotate" case.

---

## 2i. Phase 6 & 6b — mate solver + selection breadcrumbs UI (implemented)

Both halves of the original §3 items 6 and 6b, landed in the same pass:
the mate solver itself (`assembly_solver.py` plus its CRUD/solve
endpoints and `MatePanel` authoring UI), and the breadcrumb UI that 6a
(§2h) existed to unblock.

### The solver: `assembly_solver.py`

New backend module mirroring `sketch/solver.py`'s own structure but built
on `py_slvs`'s C++ `System` directly rather than the 2D sketch solver's
own wrapper. Covers all five documented mate types
(coincident/concentric/parallel/distance/angle) against the same
vertex/circular-edge-axis/cylindrical-face-axis/planar-face-normal
geometry `measure.py`'s `single_shape_geometry` (promoted from
`_measure_single` for this reuse) already extracts for the Measure tool,
resolved per-Occurrence via `create_plane.py`'s `resolve_plane_ref` and
newly-promoted `resolve_point_ref_position`. `assembly.py` gained two
small pure helpers, `apply_transform_to_point`/`apply_transform_to_direction`,
used throughout to place locally-resolved geometry into world space.

Getting a numerically-stable solve out of `py_slvs` for this problem
needed real experimentation against the upstream C++ source
(`realthunder/solvespace`), not just its thin Python bindings - three
approaches were tried and rejected before landing on the final design,
each for a concrete, reproduced failure rather than a guess:

- `addSameOrientation` cannot express `flipped` at all - reading
  `constrainteq.cpp` directly confirmed its own equations are sign-
  agnostic ("allow either orientation... depending on how it was drawn").
- Chaining a second `addTransform` onto a first transform's own result
  (to compute an "expected tip" point) silently freezes - `entity.cpp`'s
  `EntityBase::Transform` snapshots its source point's value once, at
  entity-creation time, not live.
- A `addPointPlaneDistance`-as-sign-pick approach (target dot product of
  ±1) has a genuinely zero Jacobian exactly at its own target (0°/180°) -
  Newton's method can't climb out of a seed that's already sitting on the
  degenerate point.

The design that actually works: `addParallel` alone (sign-agnostic, so it
never hits the degenerate case) for every direction/orientation
constraint, combined with a **warm-start seed** - a closed-form
"rotate vector A onto vector B" quaternion (`_quaternion_aligning`)
computed from a first geometry-resolution pass and used as the Newton
solve's *initial guess*, resolving the sign ambiguity `addParallel` alone
leaves open by starting already on the correct branch rather than by
adding a constraint that can't express it. `solve_occurrence`'s own
two-pass structure (resolve all applicable mates' geometry, compute the
seed from that resolved geometry, *then* build the `py_slvs` system) is
required by this ordering, not incidental.

### API surface

`POST /parts/{part_id}/mates` (create), `PATCH .../mates/{mate_id}`
(update value/flipped/suppressed), `DELETE .../mates/{mate_id}`, and
`POST /parts/{part_id}/occurrences/{occurrence_id}/solve` - the last one
deliberately a separate endpoint from Phase 5's own
`update_occurrence_transform` PATCH, not folded into it: a drag on an
unmated Occurrence behaves exactly as before (no solve attempted, no new
failure mode introduced for the overwhelmingly common no-mates case), and
the client calls `solveForOccurrence` explicitly, only once a mate
actually exists, immediately after `createMate` succeeds.

### `MatePanel` + picking mode

New `mate_panel.dart` (Mate-type dropdown, conditional value/flipped
fields, selected-entity rows by body name - `ResizableToolPanel` shell
mirroring `MeasurementPanel`'s own shape) plus a new cap-at-2 picking mode
in `part_screen.dart` (`_mateActive`, mirroring Measure's own toggle
picker rather than Fillet's eager-create-on-open pattern, per this
phase's own research: a Mate, like a Measurement, is exactly "up to 2
entities then confirm," with no natural "created but incomplete" state a
Fillet-style immediate-open would need). Reuses Phase 6a's own
`hitTestComponentInstanceEntities` (§2h) for its very first live caller -
wired into `_recomputeHover` as a new candidate (gated on the mate/measure
picker's own filter, never affecting default browsing) so a Mate can
target a face/edge/vertex on a *placed Occurrence*, not just the root
Part's own geometry. "Add Mate" (the Assembly Add menu and the component
long-press menu) is enabled for the first time - both previously
hardcoded `enabled: false` placeholders.

### Selection breadcrumbs: `selection_breadcrumbs.dart`

`breadcrumbTiersFor(SelectionEntityRef)` - pure, no hit-testing - and
`SelectionBreadcrumbBar`, reusing `select_other_sheet.dart`'s own
hover-preview/tap-commit interaction grammar per §3's original 6b
proposal, but as a small persistent bar (not a modal sheet) so it stays
out of the way of the 3D view it annotates. Renders nothing for a
single-tier chain (nothing to disambiguate) or for a kind with no
containment concept at all (sketch entities, reference/created planes).
The real chain this app can support is entity (face/edge/vertex) → body →
component - the "feature that created this face" tier §3's own proposal
named is still absent, unchanged from that section's own finding that
no per-face OCCT history attribution exists anywhere in the backend.

Wired into `PartViewport` (`breadcrumbEntity`/`onBreadcrumbSelect`, a
bottom-center overlay, controlled-widget shape matching
`highlightOverride`/`selectedPlane`) and `PartScreen` (`_breadcrumbEntity`
shows only when exactly one entity is selected and no exclusive picking
session - Measure, Mate, any `_anyToolPanelOpen` tool, the Select Other
sheet - is currently repurposing `_selectedEntities` for its own
semantics; `_onBreadcrumbSelect` replaces the selection with the tapped
tier's target, special-casing a `component`-kind target into
`_selectedOccurrenceId` exactly like `_toggleSelectedEntity`'s own
existing component branch does). Deliberately **not** wired to a live 3D
highlight yet - `onPreview` exists on `SelectionBreadcrumbBar` itself, but
plumbing it back out to `PartViewport.highlightOverride` was left for a
follow-up rather than risking further changes to that gesture-sensitive
file's hover machinery in this same pass.

**Verified**: backend suite - **2241/2241 passed** against real
`pythonocc-core`/`py-slvs` (up from 2219 in §2h; 22 new tests: 6 in
`test_assembly_transform_apply.py`, 16 in `test_assembly_solver.py`, the
latter exercising all five mate types plus validation/no-op/update/delete
at the real HTTP layer via `TestClient`, building actual box/cylinder
Parts through Sketch+Extrude rather than asserting against hand-computed
matrices). Full client suite - **1914/1914 passed** (up from 1876 in §2h;
14 GPU-skips, unchanged), `flutter analyze` clean on every touched file.
New client tests: 9 `DocumentApiClient` Mate CRUD/solve cases, 15
`MatePanel` cases, 15 `selection_breadcrumbs_test.dart` cases (pure
`breadcrumbTiersFor` chains for every kind, plus `SelectionBreadcrumbBar`
render/tap/hover behavior), plus updates to `assembly_add_menu_test.dart`/
`component_context_menu_test.dart`'s own pre-existing "Add Mate/Mate
render disabled" cases (stale now that this phase enables them) - each
menu's own remaining placeholder (Create Component/Pattern Component,
Phase 7, still design-only) keeps its own disabled-state coverage.

### Known v1 limitations from this phase

- COINCIDENT plane-plane `flipped` orientation is resolved by warm-start
  seeding, not a hard constraint - Newton's method converges to whichever
  orientation branch the seed is closer to, which is normally the correct
  one (the seed is computed from the mate's own `flipped` flag) but is a
  probabilistic guarantee, not an algebraic one, for a starting transform
  very far from either valid solution.
- DISTANCE between two planes locks separation but not relative spin
  (`addPointPlaneDistance` + `addParallel`, deliberately not
  `addSameOrientation` - a distance mate shouldn't also lock orientation).
- CONCENTRIC/PARALLEL/ANGLE need axis geometry (a circular edge or
  cylindrical face) on both sides - no straight-edge axis reference, and
  no axis-to-axis DISTANCE variant.
- The breadcrumb bar has no feature-level tier (per §3's own original
  finding, restated above) and no live hover-preview highlight wired into
  the 3D view yet.

---

## 2j. Phase 7 — component pattern (implemented)

§3's original item 7: a linear or circular pattern of one or more
top-level Occurrences, expanded via `assembly.py`'s own pure transform math
- no OCCT work needed, unlike body-level `PatternFeature`'s real geometry
construction (`app.document.pattern`). Read `PatternFeature`'s own
docstring and `app.document.router`'s mate CRUD (§2i) first, before writing
any of this - both are the direct precedent this phase mirrors, one level
up (components instead of bodies) for the first, and "a new dataclass with
its own CRUD endpoints living directly on `Part`" for the second.

### The data model: `ComponentPattern`

`backend/app/document/models.py` gains three new types, and `Part` gains
one new field:

- `ComponentPatternType` (`LINEAR`/`CIRCULAR`) - named this way, not
  `RECTANGULAR`/`CIRCULAR` like the body-level `PatternType`, since a
  `ComponentPattern` only ever repeats along one direction (no
  `direction_2`/2D-grid equivalent - the original brief's own wording was
  "linear + circular", never "rectangular").
- `ComponentPatternAxis` (`origin` + `direction`, both free world-space
  vectors) - a `ComponentPattern`'s circular axis is never resolved from
  Body/Sketch geometry the way body-level `PatternAxisRef` is (an
  Occurrence has no sub-shape topology of its own to reference without
  resolving its target Part's Bodies, which would reintroduce the OCCT
  dependency this whole phase exists to avoid) - it mirrors
  `RigidTransform.rotation_axis`'s own "free unit-vector direction ...
  not resolved from any geometry" convention instead, the correct
  one-level-up precedent.
- `ComponentPattern` itself - `id`, `source_occurrence_ids: list[str]`
  (one or more, mirroring `PatternFeature.source_body_ids`'s own
  Phase-6-widened shape), `pattern_type`, Linear's own `direction`/`count`/
  `spacing`/`reverse`, Circular's own `axis`/`count_angular`/`angle_total`/
  `reverse_angular`, and `suppressed`. Every source's own existing
  placement is index 0 (untouched, never re-created - `PatternFeature`'s
  own "count includes the original" convention, restated for Occurrences).
  **Deliberately never persisted as new `Occurrence` entries** - there is
  no new solid geometry to instance, only an existing placement to repeat,
  so a derived instance is computed on demand (`GET /parts/{part_id}/
  assembly-mesh`, this pattern's own recompute-equivalent) the same way a
  body-level pattern's derived Bodies are computed by `compute_part_bodies`
  on every recompute rather than stored as their own Features.
- `Part.component_patterns: list[ComponentPattern]` - coexists with
  `occurrences`/`mates` the same way every assembly-structure field on
  `Part` already does (decision #2).

v1 scope, matching Phase 5/6's own identical limit (`Occurrence.transform`
is relative to its immediate parent, and only a top-level Occurrence's
local and world transforms coincide without needing ancestor-transform
composition): every `source_occurrence_ids` entry must name a top-level
Occurrence of the Part that owns the `ComponentPattern` - enforced simply
by only ever checking membership in that Part's own `occurrences` list,
the same restriction Mate's own `_validate_mate_entity_ref` already applies
to a mate reference's `occurrence_id`.

### Expansion math: `assembly.py`

Two new pure functions, reusing `compose`/`apply_transform_to_point`
directly rather than re-deriving equivalent math:

- `_linear_pattern_step(direction, distance)` - a pure-translation
  `RigidTransform` along `direction` (normalized) by `distance` (already
  signed by `reverse` and scaled by `spacing * index`).
- `_circular_pattern_step(axis, angle_degrees)` - a rotation about an
  *arbitrary* world-space line (`axis.origin` + `axis.direction`), built
  from the standard "translate origin to zero, rotate, translate back"
  decomposition, computed via `apply_transform_to_point` itself (a pure
  rotation applied to `axis.origin` gives the rotated origin; `origin -
  that` is exactly the translation term needed) rather than duplicating
  its rotation math a second time.
- `expand_component_pattern_instances(pattern, source_transform)` - folds
  either step function over `1..count-1`/`1..count_angular-1` (index 0
  excluded, the untouched seed) and returns each derived transform as
  `compose(step, source_transform)`. `compose(parent, child)`'s own
  "parent applied after child" semantics are exactly the extrinsic
  transform behavior wanted here (rotate/translate the *entire* existing
  placement - both position and orientation - around the fixed world
  reference) as long as `step` and `source_transform` share the same
  reference frame, true for any two top-level Occurrences (both relative
  to the same parent Part) - this phase's own v1 scope limit above is what
  makes that assumption safe.

Hand-verified against known rotations/translations (identity, pure
translation forward/reversed, a non-unit direction normalized, composing
onto an already-translated-and-rotated source transform, evenly-spaced
circular instances around the default and an off-origin axis, reverse
angular direction, composing rotation onto an already-rotated source,
count/count_angular of 1 deriving nothing) - see
`test_component_pattern_expand.py`.

### API surface

`GET`/`POST /parts/{part_id}/component-patterns`, `PATCH`/`DELETE .../
component-patterns/{pattern_id}` - CRUD only, mirroring Mate's own CRUD
shape (§2i) exactly: data in, data out, no expansion/geometry work happens
in these endpoints themselves. `pattern_type` is never revised by an
update (switching Linear <-> Circular is a delete+recreate, not an edit -
mirrors `PatternFeatureUpdate`'s identical convention for its own
`pattern_type`). Validation (`_validate_component_pattern_create`/
`_validate_component_pattern_payload`) mirrors the body-level Pattern
router's own checks almost exactly: `source_occurrence_ids` non-empty and
every entry a real Occurrence of this Part; Linear's `direction` non-zero
and `count >= 2` (a single-instance pattern derives nothing beyond the
untouched seed - the identical no-op guard `PatternFeature`'s own count
checks already use); Circular's `count_angular >= 2` and `angle_total` in
`(0, 360]`; both counts capped at the same `_PATTERN_MAX_TOTAL_INSTANCES`
(500) body-level patterns already share.

### Expansion wiring: `GET /parts/{part_id}/assembly-mesh`

The real integration point - `get_assembly_mesh`'s existing `_walk`
recursion (Phase 2) gains one more loop after its ordinary Occurrence
traversal: for every non-suppressed `ComponentPattern` on the Part
currently being walked, for every one of its `source_occurrence_ids` that
resolves to a real, non-suppressed, resolved-`part_id` Occurrence,
`expand_component_pattern_instances` computes each derived transform, and
`_walk` itself is called again - recursively - for each one, with a
synthetic `occurrence_path` segment (`"{source_occurrence_id}#pattern:
{pattern_id}:{index}"`, stable and unique per derived instance, since a
derived instance was never assigned a real Occurrence id of its own) and
the composed transform chain. Reusing `_walk` for the recursion, rather
than writing a separate flattening pass, is what makes a pattern of a
*sub-assembly* automatically repeat that sub-assembly's own nested content
too, at each derived placement - verified directly
(`test_component_pattern_of_a_nested_subassembly_repeats_its_own_children_too`).
Geometry is still deduplicated by Part id exactly as before (Phase 2's own
convention) - patterning a Part 5 times still ships that Part's geometry
once.

**This is also the client's entire rendering story** - no new viewport
code was needed. A `ComponentPattern`'s derived instances arrive in
`AssemblyMeshResponse.instances` shaped identically to any other
`AssemblyOccurrenceInstance` (a `part_id` + a fully-composed
`world_transform` + `occurrence_path`), so Phase 4's existing instanced
rendering/hit-testing pipeline (`_syncAssemblyInstanceNodes`,
`hitTestComponentInstances`, `AssemblyOccurrenceInstanceDto`) already
renders and hit-tests them with zero client-side changes - confirmed by
reading that pipeline before writing any client code for this phase,
exactly the check the original brief asked for ("reuse the existing
instanced-rendering pipeline ... if a derived pattern instance can be
shaped to fit it - check before inventing a parallel rendering path").

### Client: authoring UI

`client/lib/viewport3d/component_pattern_panel.dart` (new) -
`ComponentPatternPanel`, a plain-data-plus-callbacks `StatelessWidget`
mirroring `MatePanel`'s own shape, not `pattern_panel.dart`'s (the
body-level `PatternPanel` needs live viewport edge/face/Sketch-Line
picking for its direction/axis; a `ComponentPattern`'s direction/axis are
free vectors with nothing to pick in the viewport at all - see
`ComponentPatternAxis`'s own docstring). Linear/Circular toggled by a
`SegmentedButton`; direction/axis-direction picked via X/Y/Z quick-select
buttons (`ComponentPatternAxisPreset`) rather than arbitrary vector entry
- a known v1 UI limitation (the backend accepts any vector; this panel
only ever offers the three world axes); axis origin, count(s),
spacing/angle, and reverse toggle(s) are plain numeric fields/checkboxes.

`PartScreen` gains `_openComponentPattern`/`_closeComponentPattern`/
`_confirmComponentPattern` plus the panel's own field state, mirroring
`_openMate`/`_closeMate`/`_confirmMate`'s shape - but simpler, since a
`ComponentPattern` needs no picking mode at all: its source is whichever
single Occurrence is already selected (`_selectedOccurrenceId`) when the
panel opens. v1 UI scope: exactly **one** source Occurrence per
panel-authored pattern (the backend's own `source_occurrence_ids` accepts
several, for parity with `PatternFeature`'s own Phase-6-widened shape, but
authoring a multi-source pattern isn't exposed in this UI yet - a
straightforward follow-up once there's a multi-component selection
mechanism to drive it with, which doesn't exist anywhere in this app
today).

Both previously-disabled "Pattern Component" placeholders are now real:
`add_button_menu.dart`'s `AssemblyAddMenuAction.patternComponent` (the
Assembly Add menu; requires a pre-existing selection, surfacing an error
otherwise, since there is no dedicated picking mode for "select a whole
component" beyond the ordinary default-browsing tap Assembly lens already
supports) and `component_context_menu.dart`'s `ComponentContextMenuAction.
pattern` (the long-press menu; uses the long-pressed row's own selection
directly, the same way Move/Rotate already does). `assembly_tree_panel.dart`
gains a **Patterns** section (`componentPatternDisplayName`/
`componentPatternSummary`, "Linear N"/"Circular N" plus a "×5" or "×3
(270°)" instance-count summary) so an already-authored pattern is at least
visible in the tree - read-only for now, the same scope limit the Mates
section itself still has (no tap/long-press wired to editing or deleting
an existing entry from this panel; `updateComponentPattern`/
`deleteComponentPattern` exist on `DocumentApiClient` and are directly
tested, just not yet called from any UI).

**Verified**: full backend suite against real `pythonocc-core`/`py-slvs` -
**2269/2269 passed** (up from 2241 in §2i; 28 new tests: 11 in
`test_component_pattern_expand.py` covering the pure transform-expansion
math directly, 17 in `test_component_pattern_router.py` exercising CRUD,
every validation rejection, linear/circular/suppressed/multi-source/
nested-subassembly expansion into a real `assembly-mesh` response via
`TestClient`, and a native export/import round trip - all at the real HTTP
layer, building actual box Parts through Sketch+Extrude exactly like
`test_assembly_mesh.py`/`test_assembly_solver.py` already do). Full client
suite - **1940/1940 passed** (up from 1914 in §2i; 14 GPU-skips,
unchanged), `flutter analyze` clean on every touched/new file. New client
tests: 12 `ComponentPatternPanel`/`ComponentPatternMode`/
`componentPatternAxisPresetVector` cases, 6 `DocumentApiClient`
ComponentPattern CRUD cases (`document_api_client_test.dart`), 7 new
`assembly_tree_panel_test.dart` cases (`componentPatternDisplayName`/
`componentPatternSummary`'s own pure cases plus the Patterns section's
empty/populated/suppressed rendering), plus updated `assembly_add_menu_
test.dart`/`component_context_menu_test.dart` cases confirming Pattern
Component/Pattern now resolve their own action and render enabled (Create
Component alone remains the one disabled placeholder in the Add menu).
A full end-to-end pattern-authoring round trip through `part_screen_test.dart`
was **not** attempted - the same pre-existing `_FakeDocumentBackend`
`listOccurrences`/`listMates`/`getAssemblyMesh` gap §2e/§2f/§2g already
documented applies identically to the new `listComponentPatterns` call
`_refreshAssemblyTree` now also makes.

### Known v1 limitations from this phase

- Top-level source Occurrences only - patterning an Occurrence nested
  inside a focused sub-assembly isn't attempted (same limit Phase 5's
  gizmo and Phase 6's Mate references already carry).
- The authoring panel supports exactly one source Occurrence per pattern
  and only the three world axes for direction/axis-direction - the backend
  itself accepts several sources and any vector.
- No pattern edit/delete UI yet - `updateComponentPattern`/
  `deleteComponentPattern` exist and are tested at the API layer only.
- No `skip_indices`/fuse-into-one equivalent - unlike body-level
  `PatternFeature`, a `ComponentPattern` cannot suppress an individual
  derived instance or fuse instances together (fusing doesn't even apply
  here - these are placements, not Bodies).
- The AI plan pipeline's `pattern_component` step (§3 item 8) is not part
  of this phase - see that item's own note on why.

---

## 2k. Phase 8 — AI plan pipeline integration (implemented, partial)

§3's original item 8: new `PlanStep` kinds so the AI plan pipeline
(`backend/app/document/ai_plan.py`/`ai_plan_schemas.py`, workstreams 3/5 of
`docs/ai-modelling/`) can author assembly-level edits, mirroring
`MoveBodyStep`'s exact template one level up - Occurrences instead of
Bodies. Shipped four of the five originally-listed kinds
(`mate`/`move_component`/`hide_component`/`isolate_component`);
`pattern_component` is explicitly deferred - see its own note below, which
confirms exactly the blocker §3's own item 8 text already predicted.

### The real scope boundary this phase found

Read `ai_plan.py`/`ai_plan_schemas.py` before writing anything, per the
brief's own instruction, and confirmed a boundary condition the roadmap
text didn't spell out: `add_component` isn't part of this phase (its own
client-side file-discovery gap, unchanged), so **no `PlanStep` kind in this
app has ever placed a brand-new Occurrence**. Every one of this phase's four
new kinds can therefore only ever target an Occurrence a human already
placed by hand before asking the AI to mate/move/hide/isolate it - never one
the plan itself just created. This maps cleanly onto the existing-Part-
editing convention (`docs/ai-modelling/09-existing-part-editing.md`)
already built for Features: `occurrence_id` fields accept `existing:<id>`
(a real Occurrence already on the Part being edited) or, for a `mate`
reference only, the literal `""` (this Part's own root content, mirroring
`_validate_mate_entity_ref`'s identical convention) - never a plan-local id,
since no step produces one.

### The new `PlanStep` kinds

`backend/app/document/ai_plan_schemas.py` gains four new Pydantic models,
added to the `PlanStep` discriminated union:

- `MateStep` (`kind: "mate"`) - mirrors `MateCreate` almost exactly:
  `type` (`MateType`), `references` (exactly 2 `MateEntityRefStep` entries),
  `value`/`flipped`. `MateEntityRefStep` reuses `SubShapeRefSchema`/
  `PlaneRefSchema`/`PointRefSchema` verbatim for its own geometry field
  (`subshape_ref`/`plane_ref`/`point_ref`) - always a literal, already-real
  ref into the target Occurrence's own resolved Part (that Part's Bodies
  aren't built by this plan at all, so there's nothing plan-local to
  resolve there), while `occurrence_id` is the one field that *does* need
  existing-Part resolution.
- `MoveComponentStep` (`kind: "move_component"`) - follows `MoveBodyStep`'s
  template one level up but its own placement shape mirrors
  `RigidTransform`/`OccurrenceTransformUpdate` directly, not `MoveBodyStep`'s
  own delta+`PatternAxisStep`+`make_copy` shape: `occurrence_id`,
  `translation`, `rotation_axis` (a **free world-space vector**, never a
  `sketch_line_ref` - an Occurrence's placement has no sketch geometry of
  its own to derive an axis from, `RigidTransform.rotation_axis`'s own
  documented convention), `rotation_angle_degrees`. A whole-value replace
  (matching the real PATCH endpoint's own semantics), never a delta - and
  no `make_copy` concept, since patterning a component is `pattern_component`'s
  own, separately-scoped concern.
- `HideComponentStep`/`IsolateComponentStep` (`kind: "hide_component"`/
  `"isolate_component"`) - just `occurrence_id`. `isolate_component` hides
  every *other* top-level Occurrence of the same Part and un-hides
  `occurrence_id` itself - a plain one-shot mutation (unlike the client's
  own toggle-to-undo Isolate overlay), matching `hide_component`'s own
  shape.

### A real, previously-open gap closed as a side effect: persisted `hidden`

Before this phase, **no mutation endpoint existed for `Occurrence.hidden`
at all** (§5's appendix item 1) - Hide/Show/Isolate were purely a
client-side session overlay that could only ever OR onto a backend-reported
`hidden`, never truly clear it. `hide_component`/`isolate_component` need
somewhere real to persist to, so `OccurrenceTransformUpdate`
(`backend/app/document/schemas.py`) gained a `hidden: bool | None = None`
field alongside a now-optional `transform: RigidTransformResponse | None =
None` - both independently omittable (omitted means unchanged), so a
`hidden`-only PATCH (the AI steps' own call) never has to resupply a
transform it never computed, and the gizmo's own transform-only PATCH is
unaffected. `update_occurrence_transform`
(`backend/app/document/router.py`) applies whichever of the two fields is
given. This is a genuine, if narrow, fix to §5 item 1's own gap - a real
`Show` is now possible via this same endpoint, even though no UI wires it
up yet (the client's own Hide/Show/Isolate context-menu actions still use
the pre-existing session-only overlay - see "Known v1 limitations" below).

### Dry-run validation: `backend/app/document/ai_plan.py`

`_PlanValidator`'s scratch `Part` now also copies `occurrences`/`mates` (not
just `features`) - `Occurrence` is a **mutable** dataclass, so a bare
`list(part.occurrences)` would only copy the list, leaving every element
the same object the real Part's own list holds; `move_component`/
`hide_component`/`isolate_component` mutate their target Occurrence's own
fields directly, which would otherwise corrupt real, live state during a
*dry-run* validate call. Each Occurrence is copied via `dataclasses.replace`
instead (cheap - `RigidTransform` itself is frozen). A new
`_lookup_occurrence` method mirrors `_lookup_existing`'s shape but is
narrower: `existing:<id>` only (no plan-local Occurrence local_id can exist,
per the scope boundary above), resolved against the scratch Part's own
Occurrences by id - letting several such steps in one plan chain against
each other's own effect (e.g. `move_component` then `hide_component` on the
same Occurrence) without ever touching the real Part. `_handle_mate`
mirrors `_validate_mate_create`/`create_mate`'s own **structural-only**
validation exactly - no OCCT resolution happens at real Mate-creation time
either (solving is `assembly_solver`'s own lazy, separate concern), so this
dry run genuinely behaves the same as real execution would, the same
guarantee every other handler in this module already gives.

### Real execution: `client/lib/ai/ai_plan_translator.dart`

`PlanTranslator._executeStep` gained four new cases, each calling the exact
same `DocumentApiClient` methods a human-driven screen would call - never a
new code path into the backend, per this file's own standing convention:

- `move_component` → `updateOccurrenceTransform` (whole-value replace).
- `hide_component` → a new `DocumentApiClient.updateOccurrenceHidden`
  (`hidden`-only PATCH, the widened endpoint's other half).
- `isolate_component` → `listOccurrences` (to enumerate every top-level
  sibling) then `updateOccurrenceHidden` for whichever ones actually need
  to change (skips a no-op PATCH for an Occurrence already in its target
  state).
- `mate` → `createMate`, then `solveForOccurrence` for whichever reference
  actually names a real Occurrence - mirrors `MatePanel`'s own real-UI
  behavior (§2i: solve immediately after create so the mate visibly snaps
  into place). Which of the two references is "the one being moved" is
  genuinely ambiguous for a plan-authored Mate (unlike a human's own
  drag-then-mate gesture) - the second reference is used as a reasonable
  default (the first commonly names the fixed/anchor side), skipping `""`
  (root content, never a real Occurrence to solve). A non-converging solve
  surfaces as a real `ApiException`, the same `PlanTranslationOutcome.
  stepFailed` path every other genuine-geometry-error case already uses.

None of the four count as a "created Feature" (`_featureProducingKinds`
deliberately excludes them) - there is nothing for "Undo this generation"
to delete for a Mate/transform-mutation/hidden-flag change the way there is
for a Feature.

### System prompt / existing-Part context

`client/lib/ai/ai_scoping_prompt.dart` gains a new `'assembly'` tool group
(`ai_tool_groups.dart`) with its own locked vocabulary block
(`assemblyVocabularyText`), and the locked "Editing an existing Part" block
gained a fourth directly-referenceable thing (a placed component) plus an
optional "Placed Components" section, fed by a new
`summarizeExistingOccurrencesForPrompt` (`ai_existing_part_summary.dart`) -
the occurrence-level mirror of the existing `summarizeExistingPartForPrompt`,
giving the LLM each placed component's own `existing:<id>` token plus
(best-effort, degrading silently on failure) its resolved target Part's own
real Body Feature ids, since a Mate's `subshape_ref.body_id` names one of
those directly. `ai_modelling_screen.dart`'s `_refreshExistingPartContext`
fetches this alongside the existing Feature-tree summary. The locked
"Permanent limitations" text's previous flat claim ("no multi-Part
assembly") was corrected - it now states the real, narrower limitation
(no brand-new-component placement, but mate/move/hide/isolate of an
already-placed one is possible once "Editing an existing Part" lists at
least one).

### `pattern_component`: still deferred, confirmed why

Investigated directly rather than assumed: §3's own item 8 text predicted
the real blocker would be "the AI plan pipeline has no existing concept of
the Occurrence id an earlier step in this same plan just placed" - reading
the code confirmed this is exactly right, and the scope boundary this phase
found while implementing the other four kinds sharpens it further. Since
`add_component` still doesn't exist as a `PlanStep` kind, *every* Occurrence
a plan can reference in this phase is already a real, persisted top-level
Occurrence - one the real, already-shipped `POST /parts/{part_id}/
component-patterns` endpoint (Phase 7, §2j) can already pattern directly
today, with no AI-plan-authored `pattern_component` step needed to reach
it. Adding one now would need either (a) inventing a "the AI names an
existing, human-placed Occurrence to pattern" step - genuinely useful, but
a smaller, different feature than what item 8's own text described - or
(b) waiting for `add_component` to exist first, so a plan can legitimately
need to pattern something it just placed. Left for a future phase either
way, not folded into this one.

**Verified**: backend - full suite against real `pythonocc-core`/`py-slvs` -
**2285/2285 passed** (up from 2269 baseline: 16 new tests -
`tests/test_ai_plan_assembly_steps.py`'s own 14, covering `mate`/
`move_component`/`hide_component`/`isolate_component` at the real HTTP
`/ai-plan/validate` layer plus direct `_PlanValidator` runs confirming
dry-run non-persistence and scratch-copy isolation for `isolate_component`'s
own multi-occurrence mutation; 2 new hidden-only/transform-only PATCH cases
in `test_occurrence_transform_update.py` confirming the widened schema's
independent-omission behavior). Full client suite - **1960/1960 passed**
(up from 1940 baseline; 14 GPU-skips unchanged), `flutter analyze` clean on
every touched/new file (including catching, and fixing, one real gap this
phase's own new step classes exposed - see below). New client tests: 5
`PlanTranslator` Assembly cases in `ai_plan_translator_test.dart`
(move_component's PATCH body, hide_component's hidden-only PATCH,
isolate_component's multi-occurrence PATCH set including the no-op-skip
case, mate's create+solve happy path, mate's root-content `""` reference
never attempting to solve an empty id), 6 new `ai_scoping_prompt_test.dart`
cases (the assembly group's vocabulary presence/absence, the "Placed
Components" section's presence/absence, the corrected permanent-limitations
text), 7 new `summarizeExistingOccurrencesForPrompt`
cases in `ai_existing_part_summary_test.dart` (empty list, external_ref/
name_override display, hidden flag, unresolved-target degrade, real Body
id listing, listFeatures-failure degrade), and 2 new `ai_plan_summary_test.dart`
cases for the four new step kinds' own one-line summaries (a real gap the
Review & Generate panel would otherwise have hit as a compile error - Dart's
exhaustive-switch check on `AiPlanStep` caught the missing cases immediately
once the new step classes existed). A real pre-existing-test regression was
also caught and fixed before this count was final: `_refreshExistingPartContext`'s
new best-effort Occurrence fetch changed `ai_modelling_screen_test.dart`'s own
`gear_request`-only-plan test's exact expected request-path list (a real,
correct new `GET .../occurrences` call now happens on that same stopped-run
refresh) and, separately, surfaced that a non-`ApiException` parse failure
(this test's own stub backend has no real `listOccurrences` route, so the
fetch hits a differently-shaped JSON body) needs a broader `catch` than the
original `on ApiException` - both fixed before re-running the full suite.

### Known v1 limitations from this phase

- `pattern_component` is not implemented - see its own note above.
- `add_component` still has no `PlanStep` kind at all (unchanged from
  before this phase) - every kind this phase adds can only target an
  Occurrence a human already placed by hand.
- A `mate` step's `subshape_ref`/`plane_ref`/`point_ref` must already be
  real, literal ids on the target Occurrence's own resolved Part - there is
  no edge-selector-style heuristic (the kind Fillet/Chamfer/`ai_plan_edges`
  has for a Body's own not-yet-built topology) for assembly-level geometry;
  the LLM must be given real ids via the existing-Part context's own "Placed
  Components" Body-id listing (itself best-effort and only ever offers
  whole-Body ids, never a specific face/edge/vertex index - the AI must
  still guess or ask about which face of a listed Body it means).
- `move_component`'s widened `OccurrenceTransformUpdate` has no validation
  at all (mirrors the pre-existing real PATCH endpoint's own behavior
  exactly, including a degenerate zero-vector `rotation_axis` with a
  nonzero angle) - dry-run and real execution agree, but neither guards
  against nonsensical input the way `_validate_move_body_payload` guards
  `move_body`.
- The client's own Hide/Show/Isolate context-menu actions (§2f) still use
  the pre-existing session-only overlay, not the newly-widened `hidden`
  PATCH this phase added - only the AI plan pipeline calls it today. Wiring
  the manual UI to the same real persistence is a natural, small follow-up,
  not attempted here (out of this phase's own scope, which is the AI
  pipeline specifically).

---

## 2l. Phase 9 — Hardening, migration, docs (implemented)

§3's original item 9: the full `.didsacad` backward-compat test matrix, plus
keeping this document current as phases land. `SCHEMA_VERSION`
(`backend/app/document/native_format.py`) has never bumped across any of
Phases 0-8 - every field the assembly effort ever added is purely additive,
read back via `.get(key, default)` (Phase 0's own §2 already documents this
convention; every later phase followed it without exception) - so
"backward compat" here means confirming every one of those additive fields,
across every phase, actually degrades to a sensible default when an older
file's dict is missing it, not a version-branch migration.

### The test matrix: `backend/tests/test_didsacad_backward_compat.py`

A single Phase-0-vintage case (a file predating assembly support entirely -
no `occurrences`/`mates` keys at all) already existed
(`test_assembly_model.py`'s own `test_a_pre_assembly_file_with_no_
occurrences_or_mates_keys_imports_with_empty_lists`, not duplicated here).
This new file is the first place every *other* historically-real shape gets
its own dedicated coverage, built by hand-constructing native-format dicts
missing exactly the keys a file saved at that point in this feature's
history would actually be missing (never round-tripping today's
dataclasses through export first, which could never produce a dict lacking
a field the current model always populates):

- **Phase 0-1 vintage**: an Occurrence dict predating Phase 2's own
  `resolved_part_id` wire field (§2c) imports with `part_id=None`; an
  Occurrence dict with nothing but its own required `id` defaults every
  other field (`external_ref`/`name_override`/`part_id`/`suppressed`/
  `hidden`/`transform`) to exactly what a freshly-placed Occurrence already
  has.
- **Phase 0-6 vintage** (predates Phase 7): a Part dict with real
  `occurrences`/`mates` content but no `component_patterns` key at all
  imports that key as `[]`; a bare-minimum Mate dict (only `id`/`type`/
  `references`) defaults `value`/`flipped`/`suppressed`.
- **Phase 7 vintage**: a bare-minimum `ComponentPattern` dict defaults to a
  no-op Linear pattern (`direction=(1,0,0)`, `count=1`, ...); a Circular
  one with no `axis` key at all still imports *and* still expands safely
  via the real `assembly.expand_component_pattern_instances` (falls back to
  the world Z axis through the origin, per that function's own documented
  default - confirmed by actually calling it, not just asserting the
  imported dataclass shape); an `axis` dict missing its own `direction` key
  defaults to world Z.
- **Document-level**: a composed payload predating Phase 0's own optional
  `root_part_id` field imports with `root_part_id=None`.
- **`resolved_part_id`'s own real safety net** (not a historical-file case,
  but the same "don't trust blindly" property every other default here
  relies on): a `resolved_part_id` naming a Part not actually present in
  this import payload - the ordinary shape a single-file save/reload
  produces, per `Occurrence.part_id`'s own docstring - is cleared to
  `None`; one naming a Part that *is* present in the same payload is
  trusted, confirming both halves of `_resolve_occurrence_part_ids`'s own
  validation actually work, not just the failure half.
- **A mixed-vintage import**: one Document composed from three Parts at
  three different points in this feature's history (pre-assembly, pre-
  Phase-7, current) imported together in one call - confirms one Part's
  missing keys never leak a default into a sibling Part that actually has
  real data for that same field.

### Doc-currency pass

Read the whole document end to end (this session's own instruction, not
just a targeted diff) looking for anything a prior phase's own update left
stale. Found and fixed: §3's own heading ("Remaining phases (design-only)")
and its lead sentence were accurate through Phase 7 but became wrong the
moment Phase 8 implemented item 8 - nothing under §3 has been "design-only"
or "remaining" since then. Retitled to reflect that every phase §3
originally scoped is now implemented (see §3's own updated text below) -
the numbered list itself is left exactly as every prior phase already
struck it through in place, per this document's own established "strike
through, don't delete" convention, so the historical record of what each
item originally said stays intact.

**Verified**: backend - full suite against real `pythonocc-core`/`py-slvs`
- **2296/2296 passed** (up from 2285 after §2k: 11 new tests, all in
`test_didsacad_backward_compat.py`). No client changes this phase (a
backend-data-format concern only) - client suite unchanged from §2k's own
**1960/1960**.

---

## 2m. Phase 10 — Mechanical gap-closure sweep (implemented)

§6 roadmap's own Phase 10 entry: five independent, bounded fixes closing
gap-inventory items `[4]`/`[5]`/`[11]`/`[19]`/`[16a]`, bundled into one
verification pass the same way Phase 9 bundled its own backward-compat
matrix.

### `[4]` `_validate_occurrence_transform_payload`

`backend/app/document/router.py` gains a new validator, placed directly
after `_validate_move_body_payload` and mirroring its own shape one level
up: a `rotation_angle_degrees` that isn't `0.0` paired with a zero-length
`rotation_axis` (`_is_zero_vector`, the same helper `ComponentPattern`'s own
direction checks already share) is rejected with a 422 - a rotation with no
real axis to turn around would otherwise persist silently as a no-op that
still claims a value. `update_occurrence_transform` calls it before
constructing the replacement `RigidTransform`. `ai_plan.py`'s
`_handle_move_component` calls the exact same function via a deferred,
in-function `from app.document.router import ...` - the identical "leaf
validator lives in `router.py`, `ai_plan.py` imports it lazily to avoid a
module-load-time circular import" shape `_handle_move_body`/
`_validate_move_body_payload` already established, confirmed by reading
that precedent before writing this one rather than assuming a plain
module-level import would work (it would not: `router.py` imports
`ai_plan.validate_ai_plan_steps` at module scope, so the reverse import
must stay lazy). Real execution and the AI plan pipeline's own dry-run
validation now agree on this payload the same way they already agree on
every other assembly-mutation shape §2k's own module docstring promises.

### `[5]` Manual Hide/Show/Isolate now persist for real

`part_screen.dart`'s `_onOccurrenceLongPress` previously mutated a
client-only `_hiddenOccurrenceIds`/`_isolatedOccurrenceId` Set pair (§2f) -
the one remaining half of appendix item 1 Phase 8 (§2k) didn't close, since
that phase only wired the AI plan pipeline to the widened `hidden` PATCH,
not this screen's own menu. Hide/Show now call a new `_setOccurrenceHidden`
helper (`DocumentApiClient.updateOccurrenceHidden`, then
`_refreshAssemblyTree`/`_refreshAssemblyMesh` - the identical PATCH-then-
refetch shape `_onComponentGizmoDragEnd` already uses for the gizmo's own
transform persistence); Isolate calls a new `_isolateOccurrence` helper
mirroring `ai_plan.py`'s own `_handle_isolate_component` one level up
(client-side instead of a dry-run scratch mutation): hide every *other*
top-level Occurrence, show this one, toggled by re-detecting "was this
Occurrence already the only visible one" from the just-fetched
`_occurrences` list rather than a separate client-side flag.

Since `_onOccurrenceLongPress` was the *only* mutator of
`_hiddenOccurrenceIds`/`_isolatedOccurrenceId` (confirmed by a whole-repo
grep before removing them, not assumed), both fields - and the
`applyOccurrenceVisibilityOverrides`/`applyInstanceVisibilityOverrides`
calls in `_displayOccurrences`/`_displayAssemblyInstances` that combined
them with the backend's own `hidden` - are now genuinely dead once this
call site stops populating them, so both getters were simplified to read
`_occurrences`/`_assemblyMesh!.instances` directly (still backend-true
after every refetch, with no overlay left to fold in).
`occurrence_visibility.dart`'s own `applyOccurrenceVisibilityOverrides`/
`applyInstanceVisibilityOverrides` functions are untouched and still
directly unit-tested (`overrideInstanceTransform`, their third sibling, is
still a real call site - the gizmo's own live-drag overlay) - only their
`part_screen.dart` call sites for the *overlay* were removed, not the
functions themselves.

This is the real fix appendix item 1 asked for, not just a relocation: a
`hidden: true` Occurrence loaded from a file (never touched client-side
this session) can now genuinely be shown again, since Show PATCHes the
backend's own field directly rather than clearing a session-only mask that
could only ever hide "more," never override what the backend already said.

### `[11]` Reject a tap on a synthetic pattern-instance id

`_toggleSelectedEntity`'s `component` branch (`part_screen.dart`) now checks
`entity.occurrenceId.contains('#pattern:')` before setting
`_selectedOccurrenceId` - a derived `ComponentPattern` instance's own
synthetic `occurrencePath` segment always contains that substring
(`get_assembly_mesh`'s own `_walk`, §2j), and never names a real Occurrence.
Matched exactly against appendix item 8's own suggested smaller fix: instead
of letting the tap through and only failing later at
`createComponentPattern` with a generic `occurrence_not_found` 422, it's
rejected immediately with `_errorMessage` set to a clear, specific reason.
Item 8's larger question - whether a `ComponentPattern` can ever itself be
patterned - is unchanged and still open (see §5 item 8's own remaining
text); this closes only the "rougher than it should be" failure mode that
item flagged on review, not the underlying nesting limitation.

### `[19]` Fixed Focus/Exit-Focus label

`_onOccurrenceLongPress`'s `isFocused` used to compare
`focusStack.current == resolvedPartId` - appendix item 4's own "noticed but
out of scope" note already found this could only ever be true for a
self-referencing Occurrence (which cycle detection already forbids), so the
menu's label was a latent quirk that could never actually flip to "Exit
Focus" for a real nested focus. Now checks
`focusStack.currentOccurrencePath.contains(occurrence.id)` -
`AssemblyFocusStack.currentOccurrencePath` (added by the appendix item 4 fix
itself) already tracks exactly the "is this Occurrence currently on the
focused chain" question this label needs answered.

### `[16a]` Breadcrumb hover-preview highlight, wired additively

`SelectionBreadcrumbBar.onPreview` (built in Phase 6/6b, §2i, with no caller
- that phase's own doc comment explicitly left this for a follow-up rather
than risk further changes to `PartViewport`'s gesture-sensitive hover
machinery in the same pass) now has one: `PartViewport` gained a new
`onBreadcrumbPreview` field, plumbed straight from
`SelectionBreadcrumbBar(onPreview: ...)` with no other change to that
file's existing `_recomputeHover`/`_syncHoverNode` hover pipeline -
genuinely additive, exactly as this phase's brief required.
`part_screen.dart` gained `_breadcrumbPreviewHighlight`/
`_onBreadcrumbPreview`, fed into the same `highlightOverride` field the
"Select Other" sheet's own `_selectOtherHighlight` already uses
(`highlightOverride: _selectOtherHighlight ?? _breadcrumbPreviewHighlight`)
- the two never overlap in practice (`_breadcrumbEntity` already returns
`null` while the Select Other sheet is open, per that getter's own existing
guard), so a plain `??` combines them with no precedence ambiguity, no new
field needed on `PartViewport` beyond the existing single-slot override.

**Verified**: backend - full suite against real `pythonocc-core`/`py-slvs`
- **2301/2301 passed** (up from 2296 after §2l: 5 new tests -
3 in `test_occurrence_transform_update.py` covering the new validator's
zero-angle/nonzero-angle/zero-axis matrix at the real PATCH endpoint, 2 in
`test_ai_plan_assembly_steps.py` confirming the same rejection at the
`/ai-plan/validate` layer and that a rejected dry run still doesn't persist
against the real Part). Full client suite - **1966/1966 passed** (up from
1960 baseline; 14 GPU-skips, unchanged), `flutter analyze` clean on every
touched file. New client tests (6, all in `part_screen_test.dart`, built on
a `_FakeDocumentBackend` extension - a mutable `occurrences` list plus real
`GET .../occurrences`/`.../mates`/`.../component-patterns`/`.../assembly-
mesh` routes and a `PATCH .../occurrences/{id}` handler, keyed by `part_id`
so a "Make Focus" re-fetch against a different, focused-into Part id also
resolves - the one-time cost §2e/§2f/§2g/§2j each flagged as a recurring
gap, paid here so this harness can finally drive a real end-to-end
Hide/Show/Isolate/Focus round trip, not just the dispatch-only coverage
those phases fell back to): Hide persists and the tree reflects it after
refetch, Show truly clears a backend-`hidden: true` Occurrence (appendix
item 1's own real-fix proof, not just a relocation), Isolate hides every
sibling and shows the target, Isolate-again-on-the-same-Occurrence shows
every sibling, a synthetic pattern-instance tap surfaces the clear rejection
message, and the Focus/Exit-Focus label correctly flips to "Exit Focus" on a
second long-press of the just-focused Occurrence (the exact scenario the
old, always-false comparison could never get right).

### Remaining limitations after this phase

None of these five fixes touch each other's own remaining scope limits -
every "Known v1 limitation"/appendix item not explicitly named above is
unchanged. In particular: `[6]`/`[18]` (top-level-Occurrence-only across the
gizmo/Mate/ComponentPattern) and item 8's own larger "can a
`ComponentPattern` be patterned" question are both still open, scheduled
into later roadmap phases (11/12) as originally planned - this phase
deliberately stayed within the five small, independent fixes it bundled,
not a broader completeness pass.

## 2n. Phase 11 — ComponentPattern authoring & lifecycle completeness (implemented)

§6 roadmap's own Phase 11 entry: closes gap-inventory items `[7]`/`[8]`/
`[9]`/`[10]` - every still-open ComponentPattern authoring/UI gap §5 items
7-9 catalogued, all four independent of each other and of Phase 10's own
fixes.

### `[9]` `skip_indices`

`ComponentPattern` (`app.document.models`) gains `skip_indices: list[int] =
field(default_factory=list)`, mirroring `PatternFeature.skip_indices`
exactly - same field name, same "seed's own index 0 is never a valid entry"
convention. `app.document.assembly.expand_component_pattern_instances`
changed its own return type from a plain `list[RigidTransform]` to
`dict[int, RigidTransform]`, keyed by the same 1-based index the Linear/
Circular loops already enumerate internally - matching `app.document.
pattern._rectangular_instances`/`_circular_instances`'s own `dict[int,
TopoDS_Shape]` convention one level down, so a skipped index leaves every
surviving instance's own synthetic `occurrence_path` id (`get_assembly_mesh`'s
`_walk`) stable rather than shifting it - the "don't let a skip quietly
renumber its neighbors" guarantee `PatternFeature.skip_indices` already gives
Body-level Patterns. `router.py`'s `_validate_component_pattern_payload`
gained a `skip_indices` parameter and reuses `_validate_pattern_skip_indices`
verbatim (Pattern/Mirror scoping Phase 3's own validator), checked against
whichever of `count`/`count_angular` is this pattern_type's own real total -
both `create_component_pattern`/`update_component_pattern` call it with the
merged result, the same "revalidate everything, not just the touched fields"
discipline `update_pattern_feature` already follows.
`ComponentPatternUpdate.skip_indices` gets the identical `None`-leaves-
untouched-vs-`[]`-explicitly-clears distinction `PatternFeatureUpdate.
skip_indices` already establishes. `native_format.py`'s `_component_pattern_
to_dict`/`_component_pattern_from_dict` round-trip it (`.get(..., [])`
default, so an older `.didsacad` file with no `skip_indices` key at all still
imports cleanly).

### `[10]` `orient_with_rotation`

New Circular-only field, `orient_with_rotation: bool = True` (defaulting to
today's only behavior, so no existing pattern's meaning changes - the same
"additive, safe default" convention every other Phase-11-and-earlier new
field already follows). §5 item 9's own write-up had already spelled out the
exact change needed: `expand_component_pattern_instances`'s Circular branch
still computes `compose(step, source_transform)` unconditionally (the
correct *position* for every derived instance either way - `step`'s own
translation term already correctly carries the source's world position
around the axis, regardless of orientation mode), but when `orient_with_
rotation` is `False`, the composed result's rotation term is discarded and
replaced with `source_transform`'s own unchanged `rotation_axis`/
`rotation_angle_degrees` - "translate around the circle, don't also rotate
the instance's own local orientation," the Ferris-wheel-gondola behavior §5
item 9 named as the missing second mode (Fusion 360's Circular Pattern
"Orientation: Identical" option is the closest mainstream-tool analog).
Ignored for `pattern_type == LINEAR` (a pure translation has no rotation
term to begin with, so the field is simply absent from that branch's own
math). Threaded through the same schema/router/native-format surface as
`skip_indices` above - `ComponentPatternCreate`/`Update`/`Response` all gain
the field, `native_format.py` round-trips it (`.get(..., True)` default for
backward compat).

### `[8]` Pattern row tap-to-edit / long-press-to-delete

`AssemblyTreePanel` gains `onPatternTap`/`onPatternLongPress` (optional,
default `null`, the same purely-additive arrival `onMateTap`/`onMateLongPress`
themselves got, so a call site that doesn't wire them keeps the read-only
behavior this section always had). `part_screen.dart` wires both to two new
methods: `_openComponentPatternForEdit` (opens the same `ComponentPatternPanel`
`_openComponentPattern` does, but pre-filled from the tapped pattern's own
current values, with `_componentPatternEditingId` set so `_confirmComponentPattern`
calls `updateComponentPattern` instead of `createComponentPattern`) and
`_confirmDeleteComponentPattern` (an `AlertDialog` confirmation, then
`deleteComponentPattern` + tree/mesh refresh, the same "ask first" precedent
this screen's other destructive actions already follow). Both API methods
(`updateComponentPattern`/`deleteComponentPattern`) and their own backend
tests already existed since Phase 7 - only this row's own tap/long-press
were ever unwired, exactly as the roadmap entry predicted.
`ComponentPatternPanel` itself gained an `editingPatternId` field (title
reads "Edit Pattern" instead of "Pattern Component", Confirm reads "Save"
instead of "Confirm" - the only two visible differences between the create
and edit flows, everything else in the panel is shared).

### `[7]` Custom vector entry + multi-source chip authoring

`ComponentPatternAxisPreset` (`component_pattern_panel.dart`) gains a fourth
`custom` variant alongside `x`/`y`/`z`; selecting it reveals a free X/Y/Z
number-field row (`_vectorFields`, mirroring the circular-mode axis-origin
row's own per-component layout) instead of snapping to a world axis - closing
this file's own previously-noted v1 UI limitation verbatim. Two new pure
helpers make the mapping symmetric: `resolveComponentPatternVector(preset,
custom)` (what a confirm/save actually sends - the custom vector verbatim for
`custom`, else the preset's own unit vector) and `presetForVector(vector)`
(its inverse - what `_openComponentPatternForEdit` uses to decide whether an
already-authored pattern's own stored `direction`/`axis.direction` should
highlight `x`/`y`/`z` or fall back to `custom`, tolerant of the float
round-trip noise a value that has been through JSON/the API is never exactly
free of).

Multi-source authoring: `_componentPatternSourceOccurrenceIds` (`part_screen.
dart`) is now a real, growable list rather than a single `String?` - the
backend's own `source_occurrence_ids` already accepted more than one entry
since Phase 7 (parity with `PatternFeature.source_body_ids`'s own Phase-6
widening), only this panel's authoring UI was ever limited to one.
`ComponentPatternPanel` shows one removable `Chip` per current source name
(delete disabled on the last remaining one - `ComponentPatternCreate.
source_occurrence_ids` requires at least one) plus a "+ Add source"
`ChoiceChip` that toggles `_componentPatternPickingSources`. While that flag
is set, `_onOccurrenceTap` (`AssemblyTreePanel.onOccurrenceTap`'s real call
site) toggles the tapped Occurrence into/out of the source list instead of
its ordinary select/focus behavior - a deliberately panel-local mechanism
(the roadmap's own framing), not a second, general cross-app multi-select
system layered onto the existing single-selection model.

**Verified**: backend - full suite against real `pythonocc-core`/`py-slvs`
- **2311/2311 passed, 0 failed** (up from 2301 after §2m: 10 new tests - 4 in
`test_component_pattern_expand.py` (15 total in that file) covering
`skip_indices`/`orient_with_rotation` for both Linear and Circular, 6 in
`test_component_pattern_router.py` covering skip-index validation/expansion/
round-trip at the real API + assembly-mesh layer). Caught and fixed one real
regression from `expand_component_pattern_instances`'s own return-type change
(`list[RigidTransform]` -> `dict[int, RigidTransform]`, needed for `[9]`'s
stable-index guarantee): `test_didsacad_backward_compat.py::test_circular_
component_pattern_with_no_axis_key_imports_and_still_expands_safely` iterated
the old list return directly (`for transform in derived:`) - now iterates
`derived.values()`, the only other call site anywhere in the repo (confirmed
by a whole-repo grep) beyond this phase's own new/updated tests. Full client
suite - **1984/1984 passed** (up from 1966 baseline; 14 GPU-skips,
unchanged), `flutter analyze` clean on every touched file. New client tests
(18 total: 15 in `component_pattern_panel_test.dart` covering `resolveComponentPatternVector`/
`presetForVector`, the Custom segment/entry fields, source chips add/remove/
lone-chip-no-delete, the picking-mode hint text, and the create-vs-edit
title/button-label swap; 3 in `assembly_tree_panel_test.dart` covering
pattern-row tap/long-press dispatch and the still-inert-when-unwired case).

### Remaining limitations after this phase

`[6]`/`[18]` (top-level-Occurrence-only across the gizmo/Mate/
ComponentPattern) and §5 item 8's own "can a `ComponentPattern` be patterned"
question are both still open, unchanged by this phase and scheduled into
Phase 12 (`[18]`) - this phase stayed within the roadmap's own four
authoring/UI items, not a broader nesting redesign. `orient_with_rotation`
has no dedicated panel toggle yet (only the backend field/expansion branch
and the DTO's own round-trip fidelity) - the roadmap's own Phase 11 scoping
paragraph named the backend change only for `[10]`, deliberately leaving a
UI control for a later pass once real usage shows which default this app's
users actually want exposed.

## 2o. Phase 12 — Nested-Occurrence interaction (implemented)

§6 roadmap's own Phase 12 entry: closes `[18]` (gizmo/Mate/ComponentPattern
all top-level-Occurrence-only) and, as a near-free consequence, `[6]`
(ComponentPattern source Occurrences top-level-only - a `ComponentPattern`'s
own `source_occurrence_ids` were already validated only against `part.
occurrences`, i.e. whichever Part is currently open/focused, so once
`_confirmComponentPattern` itself routes through `focusPartId` (`[3]`
below), authoring a pattern *while focused inside a sub-assembly* already
targets that sub-assembly's own direct children correctly - no separate
change needed for `[6]` beyond `[18]`'s own fix).

Verified smaller than its own original framing, confirmed directly against
the real code rather than assumed: the gizmo's own PATCH call-sites
(`_onComponentGizmoDragEnd`/`_undoLastComponentTransform`) already routed
via `focusPartId = _focusStack?.current ?? _part?.id` since Phase 5/8, and
`get_assembly_mesh`'s own `_walk` already composes the full ancestor chain
for a nested ComponentPattern (`test_component_pattern_of_a_nested_
subassembly_repeats_its_own_children_too`, §2j). Three real gaps, all
client-only - no backend changes this phase:

### `[18]` (1 of 3) `_gizmoTargetOccurrence` widened to a direct child of focus

Used to blanket-return `null` under *any* active focus
(`!(_focusStack?.isFocused ?? false)`), even though [_occurrences] is
already scoped to exactly the currently-focused Part's own children
(`_refreshAssemblyTree` fetches `listOccurrences(focusPartId)`) - so a
selected Occurrence there always has a `.transform` relative to the
*currently-relevant* parent frame, the identical "local and world
transforms coincide for this frame" property a top-level Occurrence had
relative to the document root before this phase. New
`isDirectChildOfFocus(occurrencePath, focusedOccurrencePath)`
(`occurrence_visibility.dart`, alongside its existing sibling
`isOccurrencePathWithinFocus`) makes that "exactly one level below the
current frame" requirement explicit and directly testable, rather than
relying only on `_occurrences`' own implicit scoping - true for an empty
`focusedOccurrencePath` too (a top-level path is a direct child of the
document root's own implicit frame), matching Phase 5's original behavior
exactly when nothing is focused. A grandchild or deeper nested Occurrence
is still out of scope (the gizmo's own drag math would need to account for
more than one ancestor's rotation) - not reachable in practice anyway,
since `_occurrences` never lists anything deeper than a direct child.

### A fourth, necessary fix this phase's own roadmap entry didn't name: the gizmo's on-screen basis

Found while implementing `[18]`, not in the roadmap's own 3-item list:
`PartViewport.selectedOccurrenceTransform`'s own doc comment says this
widget "derives the gizmo's actual world-space placement" directly from
whatever it's given (via `matrix4FromRigidTransform`), with no
parent-transform conversion of its own - correct for a top-level
Occurrence (parent is the document root, always identity), but feeding it
a nested target's raw *local* `OccurrenceDto.transform` would render/
hit-test the gizmo handles at the wrong on-screen position the instant
`[18]`'s own fix let the gizmo target a nested Occurrence at all - a real,
visible bug (handles floating away from the actual Body), not merely a
missed convenience. Two new pure functions close this
(`mesh_geometry.dart`, mirroring `assembly.py`'s own `compose` one level
up): `composeRigidTransforms(parent, child)` (the client-side counterpart
to that backend function - `parentMatrix * childMatrix` via
`matrix4FromRigidTransform`, decomposed back to a `RigidTransformDto` via
`Matrix4.decompose`) and its exact inverse,
`localRigidTransformRelativeTo(parent, world)` (`inverse(parentMatrix) *
worldMatrix` - what converts the gizmo's own live-drag result, now
world-space, back to the *local* value `updateOccurrenceTransform` actually
persists). `_gizmoTargetWorldTransform` (new getter) composes through
`_gizmoParentInstance`'s own current `worldTransform` (found via a third
new pure helper, `findInstanceAtPath`, `occurrence_visibility.dart`) when
focused; `_gizmoDisplayTransform` now reads from it instead of the target
Occurrence's raw local transform. `_onComponentGizmoDragEnd` decomposes
`_gizmoLiveTransform` back to local via `localRigidTransformRelativeTo`
before PATCHing, whenever `_gizmoParentInstance` is non-null.

### `[18]` (2 of 3) `_displayAssemblyInstances`'s live-drag overlay

Used to assume a top-level `occurrencePath` (`overrideInstanceTransform`
called with `targetOccurrencePath: [targetId]` - always correct when the
only possible target was top-level) - now uses the full
`[...focusedOccurrencePath, targetOccurrencePath]` path
`_assemblyMesh.instances` actually key their nested entries by. No
*further* composition is needed here beyond that path widening -
`_gizmoTargetWorldTransform` (above) already does the one
`composeRigidTransforms` call this overlay needs, once, when the gizmo is
first given its starting basis; `_gizmoLiveTransform` stays world-space for
the rest of the drag, so recomposing a second time here would double-apply
the parent's own contribution.

### `[18]` (3 of 3) `_confirmMate`/`_confirmComponentPattern` routed through `focusPartId`

Both used to hardcode `_part!.id` for their own `createMate`/
`solveForOccurrence`/`createComponentPattern` calls - correct only while
browsing the root Part, and wrong the instant either is authored while
focused inside a sub-assembly (unlike the gizmo's own PATCH call-sites,
which already routed correctly since Phase 5/8). Both now resolve
`focusPartId = _focusStack?.current ?? part?.id` first, the identical
convention every other focus-aware call site in this screen already uses.

**Verified**: backend - full suite against real `pythonocc-core`/`py-slvs`
- **2301/2301 passed, 0 failed** (unchanged from §2m's own count - no
backend changes this phase). Full client suite - **1985/1985 passed** (up
from 1966 baseline; 14 GPU-skips, unchanged), `flutter analyze` clean on
every touched file. New client tests (19 total, all pure/directly testable
- none of this phase's own GPU-bound rendering code, `PartViewport`'s own
hit-testing/drag math, can be exercised in a headless `flutter test` run,
same limitation `matrix4FromRigidTransform`'s own tests already carry):
6 for `composeRigidTransforms` and 3 for `localRigidTransformRelativeTo`
(`mesh_geometry_test.dart`, hand-verified against known rotations, the same
style `matrix4FromRigidTransform`'s own tests use, plus a round-trip check
confirming the two are exact inverses of each other), 7 for
`isDirectChildOfFocus` and 3 for `findInstanceAtPath`
(`occurrence_visibility_test.dart`).

### Remaining limitations after this phase

A grandchild or deeper nested Occurrence is still out of scope for the
gizmo/Mate/ComponentPattern alike (unchanged - `[18]`'s own roadmap text
only ever scoped this phase to a *direct* child of focus). No on-device
visual confirmation of the gizmo rendering/dragging correctly at a nested
position exists yet (this sandbox has no real GPU/Impeller context - see
`matrix4FromRigidTransform`'s own tests for the same limitation) - the pure
composition/decomposition math is hand-verified against known rotations
and round-trip-checked, but the actual on-screen hit-testing/drag feel at a
nested position is real, undone follow-up verification once a real device
is available.
## 2p. Phase 13 — Mate solver: straight-edge axis + axis-to-axis DISTANCE (implemented)

§6 roadmap's own Phase 13 entry: closes `[15]` (no straight-edge axis
reference/axis-to-axis DISTANCE) - backend-only, no client changes needed
(the Mate authoring UI's own `_mateSelectionFilter` already allows picking
any Edge, circular or straight - the restriction was purely server-side, a
`_resolve_local_geometry` rejection at solve time).

### Straight-edge axis: `measure.py`

`single_shape_geometry`'s `EDGE` branch gains a `GeomAbs_Line` case
alongside its existing `GeomAbs_Circle` one - `curve.Line()` (the same
`gp_Lin`-shaped `Location()`/`Direction()` pair a circular edge's `gp_Ax1`
axis already reports, and the identical `BRepAdaptor_Curve`/`curve.Line()`
idiom `create_plane.py`/`pattern.py` already use elsewhere in this
codebase) reports a straight edge's own infinite-line direction + a point
on it into the exact same `axis_origin`/`axis_direction` fields a circular
edge's fitted axis already populates - no new `MeasurementResult` field
needed, and no new wire-schema field either (`AxisSchema` was already
generic).

### Mate solver: `assembly_solver.py`

`_resolve_local_geometry`'s `EDGE` branch widened from `curve_type ==
GeomAbs_Circle` to `curve_type in (GeomAbs_Circle, GeomAbs_Line)` - both
now resolve through the identical `single_shape_geometry` call and return
the identical `_ResolvedGeometry(axis_origin=..., direction=...)` shape, so
CONCENTRIC/PARALLEL/ANGLE's own dispatch (`_apply_mate_constraint`) needed
*zero* changes - confirmed directly (not just assumed from the docstring's
own "already direction-agnostic to circle-vs-line" claim) by the new
straight-edge CONCENTRIC/PARALLEL tests below passing against the exact
same code path the cylindrical-face tests already exercised.

New axis-to-axis DISTANCE variant (`[15]`'s other half - "these two
parallel shafts/dowel-pin axes are N mm apart," the "parallel-shaft
center-distance" case this module's own docstring used to list as
unsupported): checked `py_slvs`'s own primitives first, mirroring Phase 6's
own "three rejected approaches" process rather than inventing new math -
there is no direct line-to-line distance constraint, but
`system.addPointLineDistance` (already used elsewhere in this codebase,
`app.sketch.solver`) computes the true perpendicular point-to-line distance,
which *is* exactly the axis-to-axis distance as long as the two axes are
first forced parallel (`addParallel`, the identical call CONCENTRIC already
makes) - without that, point-line distance varies along the line and
wouldn't mean "the" distance at all. The new DISTANCE branch: `addParallel`
+ `addPointLineDistance(distance, driven_axis_origin_point, fixed_axis_line)`,
inserted ahead of the existing point-point fallback (never reachable by
axis geometry anyway, since `_ResolvedGeometry.point` is never set
alongside `axis_origin`) - the fallback's own error message widened from
"a point or plane on each side" to "a point, plane, or axis on each side"
to match.

Module docstring's "Known v1 scope limits" updated: the "straight (non-
circular) Edge is not a supported mate reference at all" and "DISTANCE ...
an axis-to-axis ... mate is not supported" bullets both removed (fixed);
CONCENTRIC's own bullet reworded to "a cylindrical Face, or a circular or
straight Edge" to describe the now-wider axis-reference set precisely.

**Verified**: backend - full suite against real `pythonocc-core`/`py-slvs`
- **2306/2306 passed, 0 failed** (up from 2301 after §2m: 5 new tests - 1 in
`test_measure_endpoint.py` confirming `single_shape_geometry` reports a
straight edge's own unit-length axis direction + a point on it; 4 in
`test_assembly_solver.py` - straight-edge CONCENTRIC and PARALLEL mirroring
the existing cylindrical-face tests exactly, plus two axis-to-axis DISTANCE
tests, one against cylindrical faces and one against straight edges, each
verifying *both* halves of what the constraint actually establishes: the
two axes end up genuinely parallel, not just coincidentally close, and the
true perpendicular axis-to-axis distance - not a raw point-to-point one -
equals the requested value). One transient, unrelated failure encountered
and confirmed *not* a regression before this count was finalized: an
`-n 4` xdist run hit 4 failures in `test_planetary_gear_jobs.py` (shared
`_running_job_id` global state racing across workers, nothing to do with
`measure.py`/`assembly_solver.py`) - confirmed pre-existing/unrelated by
(a) that file passing 8/8 in isolation, (b) the immediately-prior Phase 12
run of this same `-n 4` suite completing 2301/2301 clean, and (c) a full
rerun of this phase's own suite passing 2306/2306 clean with no
`test_planetary_gear_jobs.py` failures at all. No client changes this
phase - full client suite **1966/1966 passed** (unchanged baseline),
`flutter analyze` clean.

### Remaining limitations after this phase

The module docstring's remaining v1 scope limits are unchanged: CONCENTRIC
still only supports axis-to-axis (no "concentric to a point" variant), and
a COINCIDENT mate between two planar references still locks the full
relative orientation rather than only the 2 DOF a real flush-but-free-to-
spin mate should. The roadmap's own explicitly-deferred items (`[12]`
multi-body/linkage simultaneous solving, `[13]` real-time client-side FFI
solving, `[14]` algebraic COINCIDENT flip resolution) are all untouched by
this phase, as planned.

---

## 3. Phase history (every originally-scoped phase implemented)

Phase 4 ("Whole-part selection + context menu") moved to §2f, Phase 5
("Move/Rotate gizmo + persisted placement + undo") to §2g, Phase 6a
("occurrence-attributed selection") to §2h, Phase 6/6b (the mate
solver and the breadcrumb UI) to §2i, Phase 7 ("Component pattern") to
§2j, Phase 8 ("AI plan pipeline integration") to §2k, and Phase 9
("Hardening, migration, docs") to §2l - every phase originally scoped here
is now implemented (this section was titled "Remaining phases (design-only)"
through Phase 7; retitled once Phase 8 made that description wrong - see
§2l's own "Doc-currency pass"). The only pieces of the original brief left
open are `pattern_component`/`add_component`, both deliberately deferred
with a written reason (§2k), not silently dropped - anyone extending this
feature further should start there, not by re-scoping a "Phase 10" from
scratch. Numbering below is otherwise unchanged from the
original plan (starts at 8 rather than being renumbered), so every
existing cross-reference elsewhere in this document (e.g. §4's own "Phase
5" undo note, which still correctly points at what's now §2g) still points
at the same phase it always did.

5. **~~Move/Rotate gizmo + persisted placement + undo~~ — moved to §2g,
   implemented.**
6. **~~Mate system~~ (coincident/concentric/parallel/distance/angle) —
   moved to §2i, implemented.**

   **6a. ~~Prerequisite — occurrence-attributed selection.~~ — moved to
   §2h, implemented.**
   **6b. ~~Follow-on — selection breadcrumbs UI.~~ — moved to §2i,
   implemented.**
7. **~~Component pattern~~ (linear + circular) — moved to §2j,
   implemented.**
8. **~~AI plan pipeline integration~~ — moved to §2k, `mate`/`move_component`/
   `hide_component`/`isolate_component` implemented; `pattern_component` and
   `add_component` remain deferred, see §2k's own notes on why.**
9. **~~Hardening, migration, docs~~ — moved to §2l, implemented.**

## 4. Known v1 limitations (carried forward from the plan, restated so they
   don't get lost)

- Undo is scoped to component transforms only (Phase 5) — hide/show,
  occurrence insert/delete, and mate authoring remain un-undoable, matching
  the rest of the app's current lack of document-level undo.
- Mate solving in v1 only drives the actively-dragged Occurrence against
  fixed peers — no simultaneous multi-body solving (linkages).
- No real-time client-side (FFI) mate solving in v1 — debounced
  backend-only, same tolerated latency as `MoveBodyFeature` today.
- COINCIDENT plane-plane `flipped` orientation, and no straight-edge axis
  reference or axis-to-axis DISTANCE for CONCENTRIC/PARALLEL/ANGLE — see
  §2i's own "Known v1 limitations from this phase" for the full list.
- Selection breadcrumbs (§2i) have no feature-level tier - the live
  hover-preview highlight into the 3D view was added by Phase 10 (§2m,
  `[16a]`).
- Component patterns (§2j) only ever target top-level source Occurrences,
  the authoring panel supports one source and only the three world axes,
  and there is no edit/delete UI yet — see §2j's own "Known v1 limitations
  from this phase" for the full list.
- `add_component`'s AI step is gated on a file-discovery mechanism not yet
  designed; `pattern_component`'s AI step is gated on the plan pipeline
  having no way yet to reference an Occurrence id an earlier step in the
  same plan produced (§3 item 8).
- Composed multi-file graph `part_id`s are session-scoped, not persisted
  across app restarts.

## 5. Appendix — scope limits and follow-ups (evaluate after rollout)

Started as Phase 4 (§2f)'s own deliberately-scoped gaps, pulled out of that
section's own narrative into one place specifically so they get a real
look once the phase has been used for a while, rather than staying buried
in a "Verified" paragraph nobody revisits - since broadened to index every
open "shipped without" gap across the whole assembly effort, not just
Phase 4's. None of these block whichever phase shipped alongside them; all
are candidates for either a follow-up fix inside a later phase or a
deliberate "still fine, leave it" call once there's real usage to judge
them against.

**Update**: items 3, 4, 5, and 6 were fixed directly (each ahead of any
real rollout) rather than left for later - struck through in place, not
deleted, so the record of what shipped broken and why stays intact. Items
1-2 are still open and still genuinely await real usage before deciding
whether they're worth fixing at all. Items 7-9 were added during Phase 7
(§2j)'s own post-ship review, surfaced by direct user questions about the
new `ComponentPattern` rather than a bug report - all three are still
open.

1. **~~Hide/Show/Isolate can only ever *OR* onto the backend's own `hidden`
   flag, never override it.~~ - fixed.** No mutation endpoint existed for
   Occurrences at all (§2e); Phase 8 (§2k) added the widened `hidden` PATCH
   but wired it to the AI plan pipeline only, leaving the manual UI still on
   the old client-only overlay. Phase 10 (§2m, `[5]`) closed the remaining
   half: `part_screen.dart`'s Hide/Show/Isolate now PATCH the real field
   and re-fetch, so Show genuinely clears a backend-`hidden: true`
   Occurrence (e.g. loaded from a file saved with it hidden), not just this
   session's own override.
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
   this item was actually about. **~~Fixed by Phase 10, §2m (`[19]`)~~** -
   now checks `focusStack.currentOccurrencePath.contains(occurrence.id)`.
5. **~~`component_context_menu.dart`'s "Move/Rotate" entry is still
   hardcoded `enabled: false`~~ - fixed in §2h (Phase 6a's own pass, while
   already in this area of the codebase).** Was found during the
   post-Phase-5 completeness audit still hardcoded `enabled: false`
   ("Coming soon - needs Phase 5's move/rotate gizmo") with
   `part_screen.dart`'s own handler a no-op
   (`case ComponentContextMenuAction.moveRotate: break;`), even though
   Phase 5 *was* already implemented and the gizmo already appears
   automatically the moment a top-level component is tap-selected in
   Assembly lens (`_gizmoTargetOccurrence`), entirely independent of this
   long-press menu item - nobody had updated this Phase-3b-vintage stub
   when Phase 5 landed. Fixed exactly the one-line way this item itself
   predicted would suffice: the entry now renders enabled, and the
   `moveRotate` case needed no new logic since `_onOccurrenceLongPress`
   already selects the row (and so already targets the gizmo) before the
   menu even opens. See §2h for the full writeup and verification.
6. **~~Selection carries no occurrence attribution outside the dedicated
   `component` kind, and no feature-level face-history attribution exists
   anywhere~~ - fixed.** Surfaced by a user proposal for SOLIDWORKS-style
   "selection breadcrumbs," not by a bug report; resolved by Phase 6a
   (occurrence-attributed selection, §2h) and Phase 6b (the breadcrumb UI
   itself, §2i). The feature-level tier remains genuinely absent (no
   per-face OCCT history attribution exists anywhere in the backend, per
   6b's own original finding) - not a leftover bug, a follow-up that needs
   someone to first check what OCCT can actually report.
7. **~~`ComponentPattern` has no per-instance skip (§2j).~~ - fixed, Phase 11
   (§2n, `[9]`).** Unlike body-level
   `PatternFeature`'s `skip_indices` (Pattern/Mirror scoping Phase 3), a
   `ComponentPattern` is all-or-nothing - there is no way to suppress one
   derived instance (e.g. omitting a single bolt from an otherwise-regular
   bolt circle) while keeping the rest of the pattern. Both the model
   (`ComponentPattern` has no `skip_indices` field) and the expansion
   function (`app.document.assembly.expand_component_pattern_instances`
   always derives every index from 1 to `count`/`count_angular`) would
   need to grow one - straightforward to add later, mirroring
   `PatternFeature.skip_indices`'s own shape and
   `app.document.router._validate_pattern_skip_indices`'s own validation
   (every entry a real, would-otherwise-be-created index; the untouched
   seed's own index 0 rejected the same way), but deliberately left out of
   Phase 7's initial scope rather than assumed needed.
8. **A `ComponentPattern` cannot itself be patterned.** `source_occurrence_ids`
   is validated only against `part.occurrences`
   (`_validate_component_pattern_source_occurrence_ids`) - a derived
   pattern instance is never persisted as a real `Occurrence` (§2j's own
   "re-derive, don't cache" design), so there is structurally nothing for
   a second `ComponentPattern` to reference. This is intentional, not an
   oversight (nesting Occurrence patterns the way body-level Features can
   chain - a pattern of a pattern - was never part of Phase 7's scope), but
   the failure mode found on review is rougher than it should be: nothing
   stops a user from tap-selecting a derived instance directly in the 3D
   viewport (`PartScreen._toggleSelectedEntity`'s `component` branch sets
   `_selectedOccurrenceId` to that instance's own synthetic
   `occurrence_path`-derived id with no check that it names a real
   Occurrence), then opening "Pattern Component" against it - the panel
   opens normally, and only `createComponentPattern` at the backend fails,
   with a generic `occurrence_not_found` 422 surfaced as inline panel error
   text, rather than the selection or menu itself explaining "derived
   pattern instances can't be patterned." Long-press-menu access is safe
   from this (that menu only ever opens from a real Assembly-tree row, and
   derived instances never appear as tree rows - see the "where do new
   parts sit in the tree" question this item was raised alongside), only
   the plain-tap-in-viewport path reaches it. Revisit either by actually
   supporting nested/compound patterns, or - the smaller fix - rejecting a
   `component`-kind tap on a synthetic (non-`Occurrence`) id before it ever
   reaches `_selectedOccurrenceId`, with a clear user-facing reason.
   **The smaller fix: ~~done~~ by Phase 10, §2m (`[11]`)** - the plain-tap-
   in-viewport path now surfaces a clear rejection message instead of ever
   reaching `_selectedOccurrenceId`. The larger question this item opened -
   whether a `ComponentPattern` can ever be patterned at all - is unchanged
   and still open.
9. **~~No control over a Circular `ComponentPattern`'s own instance
   orientation - only one of the two standard behaviors is implemented,
   with no toggle for the other.~~ - fixed (backend), Phase 11 (§2n, `[10]`)
   - see that section's own "Remaining limitations" for the still-open
   panel-toggle UI gap.** Verified directly
   (`apply_transform_to_direction` against each derived instance): a
   Circular pattern's derived instances currently always **rotate as they
   go around** the axis - `expand_component_pattern_instances`'s
   `compose(step, source_transform)` composes the pattern step's own
   rotation *onto* the source's existing orientation (see
   `_circular_pattern_step`'s own docstring on why `compose`'s "parent
   applied after child" semantics give exactly this extrinsic-rotation
   behavior), so a local vector that points toward/away from the axis on
   the seed keeps pointing toward/away from the axis at every derived
   position - spokes-of-a-wheel behavior, matching what most mainstream
   CAD tools default to, and correctly the one this app should default to
   as well. There is no way to instead **keep each instance's original
   orientation** (translate-only around the circle, like gondolas on a
   Ferris wheel that stay upright rather than tipping over as the wheel
   turns) - a real, common second mode (e.g. Fusion 360's Circular
   Pattern "Orientation: Identical" option) that this phase never
   considered, let alone exposed a control for. Adding it needs: a new
   `ComponentPattern` field (e.g. `orient_with_rotation: bool = True`,
   defaulting to today's only behavior so no existing pattern's meaning
   changes), an `expand_component_pattern_instances` branch that composes
   only the step's *translation* onto `source_transform` when the flag is
   false (leaving `source_transform`'s own rotation untouched - `_circular_
   pattern_step`'s translation term already isolates cleanly from its
   rotation term, so this is a small, well-contained change, not a
   redesign), the matching schema/router/native-format plumbing Mate-CRUD-
   shaped fields already all have precedent for in this same phase, and a
   toggle in `ComponentPatternPanel` (Linear has no equivalent ambiguity -
   a translation-only pattern has no orientation question to begin with).

---

## 6. Follow-up roadmap (Phases 10–19, planned)

Produced by a dedicated planning pass over every still-open item in §4/§5
and each phase's own "Known v1 limitations" (Phases 6-8) once Phase 9
closed out §3's original list. Every item below was cross-checked against
the actual current code (not just this doc's own text) before being
scheduled - a few turned out smaller than their original write-up implied
(Phase 12 in particular). Continues this document's own Phase-N numbering
and one-phase-one-PR convention; each phase below should get its own
lettered section (§2m, §2n, ...) here once implemented, striking through
(never deleting) whichever §4/§5 item(s) it closes.

Bracketed `[N]` ids below are stable references into this roadmap's own
23-item gap inventory (grouped: AI plan pipeline 1-5, ComponentPattern
6-11, Mate solver 12-16, Selection/rendering/focus 17-19, Storage/
multi-file 20-22, Other 23) - listed in full at the end of this section.

**~~Phase 10 — Mechanical gap-closure sweep (small, low risk).~~ — moved to
§2m, implemented.** Bundled five independent, bounded fixes into one
verification pass: `[4]` added `_validate_occurrence_transform_payload`
(mirrors `_validate_move_body_payload`, `router.py`), reused by both the
real PATCH endpoint and `ai_plan.py`'s dry-run handler; `[5]` wired the
manual Hide/Show/Isolate context-menu actions (`part_screen.dart`'s
`_onOccurrenceLongPress`, previously a client-only `Set`) to the real
`updateOccurrenceHidden` persistence path Phase 8 added (only the AI plan
pipeline called it before) - closed appendix item 1's remaining manual-UI
half; `[11]` rejected a tap on a synthetic/derived pattern-instance id
(`"#pattern:"`) before it reaches `_selectedOccurrenceId`, per appendix item
8's own suggested smaller fix; `[19]` fixed the `isFocused` label's
always-false comparison while already in that method for `[5]`; `[16a]`
wired the breadcrumb bar's existing `onPreview` hook to
`PartViewport.highlightOverride` (additive-only).

**~~Phase 11 — ComponentPattern authoring & lifecycle completeness
(medium).~~ — moved to §2n, implemented.**
`[9]` `skip_indices`, mirroring `PatternFeature.skip_indices` exactly
(field + reuse of the already-generic `_validate_pattern_skip_indices` +
a skip check in `expand_component_pattern_instances`'s two loops); `[10]`
`orient_with_rotation: bool = True`, a new Circular-only branch composing
only the step's translation term when `False` (§5 item 9's own write-up
already spells out the exact change); `[8]` wire `assembly_tree_panel.dart`'s
Patterns rows to tap-to-edit/long-press-to-delete (the API methods already
exist and are tested, only the UI is missing); `[7]` a "Custom" arbitrary-
vector entry mode plus panel-local multi-source authoring via repeatable
tap-to-select chips (backend already accepts multiple `source_occurrence_ids` -
client-only UX addition, deliberately not a general cross-app multi-select
mechanism).

**~~Phase 12 — Nested-Occurrence interaction (medium, not large).~~ — moved
to §2o, implemented.** Closes
`[18]` and, as a near-free consequence, `[6]`. Verified smaller than its
own original framing: the gizmo's PATCH call-sites already route via
`focusPartId = _focusStack?.current ?? _part?.id`, and `get_assembly_mesh`'s
`_walk` already composes the full ancestor chain for patterns (confirmed by
the existing `test_component_pattern_of_a_nested_subassembly_repeats_its_
own_children_too`). Three real gaps: (1) `_gizmoTargetOccurrence`
blanket-returns `null` under any focus, even for a direct child of the
focused sub-assembly - needs a new `isDirectChildOfFocus` alongside
`occurrence_visibility.dart`'s existing `isOccurrencePathWithinFocus`; (2)
`_displayAssemblyInstances`'s live-drag overlay assumes a top-level
`occurrencePath` - a nested target needs composing through the parent
instance's own `world_transform` via the same `matrix4FromRigidTransform`/
`compose` convention `assembly.py`/`mesh_geometry.dart` already share; (3)
`_confirmMate`/`_confirmComponentPattern` both still hardcode `part.id`
(unlike the gizmo, which already routes correctly) - fix to match.

**~~Phase 13 — Mate solver: straight-edge axis + axis-to-axis DISTANCE
(medium).~~ — moved to §2p, implemented.** Closes `[15]`. Extend `measure.py`'s `single_shape_geometry` to
report a straight edge's line direction + point-on-line (the same
`BRepAdaptor_Curve` family already used for a circular edge's axis), wire
into `assembly_solver.py`'s CONCENTRIC/PARALLEL/ANGLE dispatch (already
direction-agnostic to circle-vs-line), add an axis-to-axis DISTANCE
variant. Check `py_slvs`'s own primitives before inventing new math,
mirroring Phase 6's own "three rejected approaches" process - budget real
experimentation time.

**Phase 14 — AI plan pipeline: Mate edge-selector heuristic + existing-only
`pattern_component` (medium).** Closes `[3]` and the achievable half of
`[1]`, independent of `[2]`. `[3]`: `resolve_edge_selector`
(`ai_plan_edges.py`) already takes a raw shape + `Part` and doesn't care
whether the Body predates this plan - add an optional `EdgeSelector` field
to `MateEntityRefStep`'s subshape variant, resolved via `_lookup_occurrence`
+ `compute_part_bodies`. `[1] partial`: new `PatternComponentStep`
mirroring `ComponentPatternCreate`, `source_occurrence_ids` as
`existing:<id>` only (matching `MateStep`'s own convention) - reuses
`_validate_component_pattern_source_occurrence_ids`/`_validate_component_
pattern_payload` directly.

**Phase 15 — Multi-file save flow (medium-large).** Closes `[21]`.
Deliberately sequenced before Phase 18: `add_component` as an AI step is
only genuinely useful once a multi-part session can be saved back out.
`AssemblyDocumentClient.savePart` already handles one Part; the gap is
`PartScreen` never adopting `StorageService`/`ProjectRoot` at all. Adds
`relativePathByPartId` session state, a relative-path prompt for a
brand-new in-session Part, a "Save All" action, and finally enables
`AssemblyAddMenuAction.createComponent`.

**Phase 16 — Multi-file part-id/path persistence: investigate first
(small, uncertain).** Closes `[22]` - but starts with a spike, not an
assumed fix. `AssemblyGraphComposer` already trusts each file's own
persisted `id` and re-derives a stable graph from `external_ref` on every
reopen; confirm precisely what's still session-scoped in practice before
designing anything. May close by correcting this doc rather than shipping
code.

**Phase 17 — iOS Storage Access Framework equivalent (medium, platform
risk).** Closes `[20]`. New `IosStorageService` sibling to
`SafStorageService`: `UIDocumentPickerViewController` + iOS
security-scoped bookmarks, mirroring that class's own reachability-
revalidation contract. Survey a maintained Dart bookmark plugin the way
Phase 1 evaluated `saf_util`/`saf_stream` vs. `shared_storage`.

**Phase 18 — AI plan pipeline: `add_component` + client file discovery
(large).** Closes `[2]`. Feasibility confirmed directly: `saf_util`
(already a dependency) exposes a real `Future<List<SafDocumentFile>>
list(String uri)`; `dart:io`'s `Directory.list(recursive: true)` covers
desktop - not blocked on a missing platform capability, just undesigned.
`StorageService` gains `listFiles` (ship/checkpoint first, independently
useful); a new `AddComponentStep` becomes the first `PlanStep` kind to
ever *produce* a plan-local Occurrence id, needing a genuinely new
execution path (`add_component.dart`'s `mergeComponentIntoDocument` reading
via `StorageService` instead of `file_picker`) and a new plan-local-
resolution branch in `_PlanValidator._lookup_occurrence` before its
`existing:` fallback. The largest, most genuinely-new-design phase here.

**Phase 19 — AI plan pipeline: `pattern_component` full version (small,
depends on 18).** Closes the remainder of `[1]`. Extends
`PatternComponentStep.source_occurrence_ids` to accept a plan-local
`local_id`, threading the real created Occurrence id through
`PlanTranslator.localIdToRealId` - the same mechanism every other step
already uses. Pure payoff once Phase 18 lands.

**Dependency summary**: Phases 10, 11, 12, 13, 14, and 17 are mutually
independent - resequence or parallelize freely. The one hard chain is
**15 → 18 → 19**. Phase 16 softly depends on 15.

**Explicitly deferred again** (recommend re-stating, not silently
dropping, if this roadmap is revisited): `[12]` multi-body/linkage
simultaneous solving - real solver-architecture redesign, wait for a
reported real use case; `[13]` real-time client-side FFI solving - would
mean maintaining two solver implementations for a UX gain nobody has asked
for; `[14]` algebraic (non-warm-start) COINCIDENT flip resolution - Phase 6
already rejected three approaches before landing on today's
correct-for-practical-cases seed; `[16b]` feature-level breadcrumb tier -
needs per-face OCCT history attribution that doesn't exist anywhere in the
backend, recommend a time-boxed spike first; `[17]` root Part's own Bodies
staying selectable regardless of focus - an explicit "real usage-judgment
call," touches `hitTestBodies` for a guarantee no bug report has asked
for; `[23]` general document-level undo - an app-wide pre-existing
limitation, not assembly-specific.

### The 23-item gap inventory this roadmap schedules against

**AI plan pipeline (§2k)**: `[1]` `pattern_component` PlanStep missing;
`[2]` `add_component` PlanStep missing (no client file-discovery
mechanism); `[3]` no edge-selector heuristic for a Mate's own geometry
refs; `[4]` ~~`move_component` has no payload validation~~ - **fixed,
Phase 10 §2m**; `[5]` ~~manual Hide/Show/Isolate UI still client-only~~ -
**fixed, Phase 10 §2m**.

**ComponentPattern (§2j/§5 items 7-9)**: `[6]` ~~top-level source
Occurrences only~~ - **fixed as a near-free consequence of `[18]`, Phase 12
§2o**; `[7]` ~~authoring panel: one source, X/Y/Z presets only~~ - **fixed,
Phase 11 §2n** (Custom vector entry + multi-source chips); `[8]` ~~no
pattern edit/delete UI~~ - **fixed, Phase 11 §2n**; `[9]` ~~no
`skip_indices`~~ - **fixed, Phase 11 §2n**; `[10]` ~~no
`orient_with_rotation` toggle~~ - **fixed (backend only), Phase 11 §2n** -
no dedicated panel UI control yet, see that section's own "Remaining
limitations"; `[11]` ~~a derived/synthetic pattern instance
can be re-selected and "Pattern Component"'d, failing with a generic 422~~ -
**fixed, Phase 10 §2m** (the smaller fix only - nested/compound patterns
remain unsupported).

**Mate solver (§2i)**: `[12]` single-Occurrence-against-fixed-peers solving
only; `[13]` no real-time client-side FFI solving; `[14]` COINCIDENT
plane-plane `flipped` resolved via warm-start seed only; `[15]` ~~no
straight-edge axis reference/axis-to-axis DISTANCE~~ - **fixed, Phase 13
§2p**; `[16]` no feature-level
breadcrumb tier (`[16b]`) and ~~no live hover-preview highlight
(`[16a]`)~~ - **`[16a]` fixed, Phase 10 §2m** (`[16b]` remains open).

**Selection, rendering & focus**: `[17]` root Part's own Bodies stay
selectable regardless of focus; `[18]` ~~gizmo/Mate/ComponentPattern all
still top-level-Occurrence-only~~ - **fixed (direct child of focus only,
not deeper nesting), Phase 12 §2o**; `[19]` ~~latent Focus/Exit-Focus label
quirk~~ - **fixed, Phase 10 §2m**.

**Storage & multi-file**: `[20]` no iOS SAF equivalent; `[21]` no
multi-file save flow; `[22]` composed multi-file `part_id`s are
session-scoped only.

**Other**: `[23]` undo scoped to component-transform drags only (app-wide
pre-existing limitation, not assembly-specific).
