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
Client: `client/lib/viewport3d/*` (3D viewport/tree/tools),
`client/lib/storage/*` (implemented), `client/lib/assembly/*` (planned,
not yet built).

**Status: Phase 0 (backend data model) and Phase 1 (client storage
abstraction) implemented. Phases 2–9 are design-only.**

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

## 3. Remaining phases (design-only)

2. **Multi-file compose + stateless recompute** — client-side graph
   composition (resolve N `.didsa` files, assign session-local `part_id`s,
   cycle-check), reusing `/import/native` for the composed payload, plus a
   new `GET /parts/{part_id}/assembly-mesh` endpoint that walks the
   composite graph (via `assembly.py`'s `compose_chain`) and reuses the
   existing per-Part body cache unchanged — N occurrences of one
   definition trigger one recompute, not N. **Must return the target
   Part's own local bodies (its own `compute_part_bodies` result, exactly
   like today's plain `/mesh`) in addition to every resolved Occurrence's
   bodies** - an easy thing to under-scope now that a Part can have both
   local features and occurrences at once (§1 decision #2): the root
   Part's own geometry (e.g. a locally-modelled mount) is just as much
   part of the assembly-mesh response as anything it references.
3. **Unified screen architecture: lens toggle + focus stack** — the
   foundational client-side piece everything else in this list sits on
   top of, and the concrete answer to "does the viewport change between
   modes?" (it doesn't). Two independent axes on **one continuous
   screen/viewport** - neither ever pushes a new screen, resets the
   camera, or re-fetches anything on its own:
   - **Lens** (Part mode ↔ Assembly mode): a pure UI-state toggle for
     whichever Part is currently primary. Swaps the side panel between
     `FeatureTreePanel` (existing, reads `part.features`) and a new
     `AssemblyTreePanel` (reads `part.occurrences`/`part.mates`), and the
     toolbar between the existing feature toolset and a new assembly
     toolset (insert component/mate/pattern/hide/isolate). The 3D scene
     itself is identical in both lenses - always this Part's own bodies
     *and* every resolved Occurrence together, since both genuinely
     coexist in the same file (§1 decision #2). No opacity change, no
     selectability change, no backend call on a lens switch by itself.
   - **Focus stack** (Make Focus / Exit Focus): a stack of "which Part is
     currently primary" - "Make Focus" on a placed component pushes that
     component's own Part; "Exit Focus" (or back) pops it. Reuses the
     `OverrideStack` pattern already established in this codebase
     (`_planeSelectionModeStack`/`_selectionFilterOverrides` in
     `part_screen.dart`), just applied one level higher: a stack of
     primary-Part-id rather than only selection-filter state. Top-of-
     stack's own subtree (its own bodies plus its own resolved
     Occurrences) renders opaque and stays selectable/editable; every
     other Part in the stack renders translucent and becomes unselectable
     via the same `OverrideStack<SelectionFilterState>` mechanism - a
     clean 2-tier split that reproduces the original brainstorm's "focus
     part and its children opaque, peers and parents translucent" spec
     exactly, with no separate parent/peer/grandparent grading needed.
     Translucent context geometry stays visible and snappable but never
     produces a persistent Feature-level reference (decision #3 -
     visual-only in-context editing).

   Supersedes two originally-separate phases: the earlier "Part/Assembly
   mode toggle" (the lens, above) and the earlier "in-context focus-mode
   editing," which no longer pushes `PartScreen` as a child screen - focus
   changes now stay on the same continuous screen/viewport throughout,
   consistent with the lens toggle's own "never leave the viewport"
   principle. Bottom-up insert, top-down create-in-place, hide/show,
   isolate all build on this.
4. **Whole-part selection + context menu** — extend
   `SelectionFilterState`/`select_other_sheet.dart` with a `component`
   kind, usable in either lens and regardless of focus depth (needed for
   Make Focus, mate-authoring, and Move/Rotate no matter which tree is
   currently shown); new component context menu (Make Focus/Move-Rotate/
   Hide/Isolate/Mate/Pattern). Per-instance opacity itself now lives in
   Phase 3's focus stack above, not here - there is no "opacity for mode"
   concept anymore, only "opacity for focus depth."
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
