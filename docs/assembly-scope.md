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
2. **Part and Assembly are one `Node` concept** — a Node is either a leaf
   (a Feature history, i.e. today's `Part`) or a composite (`Assembly`:
   Occurrences + Mates). Kept as two distinct dataclasses under one `Node =
   Part | Assembly` union (see §2) rather than one discriminated dataclass,
   so every existing Part-only Feature-handler module (`extrude.py`,
   `pattern.py`, `fillet.py`, …) keeps working completely unchanged.
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
for Phase 7 (§3) — this is additive backend integration reusing an
existing dependency.

---

## 2. Phase 0 — unified node data model (implemented)

`backend/app/document/models.py`:

- `RigidTransform` (translation + axis-angle rotation, applied rotate-
  then-translate — the same composition order `MoveBodyFeature` already
  uses, for consistency across the codebase). Wire format is axis-angle,
  not a quaternion; the mate solver (Phase 7) converts to/from quaternion
  only at its own SolveSpace FFI boundary.
- `MateType` (`coincident`/`concentric`/`parallel`/`distance`/`angle`),
  `MateEntityRef` (an Occurrence id + one of `SubShapeRef`/`PlaneRef`/
  `PointRef`, reused verbatim from the existing Feature-reference types),
  `Mate` (a `MateType` + `references` + optional `value`/`flipped`).
- `Occurrence` — one placed instance of another Node inside an `Assembly`:
  `id`, `node_id: str | None` (session-local, **never** persisted to disk —
  populated by whoever assembles a multi-node graph into a `Document`),
  `external_ref: str | None` (the portable, client-owned relative-path
  identity — the only thing `native_format.py` (de)serializes for an
  Occurrence's target), `transform`, `suppressed`, `hidden`.
- `Assembly` — `id`, `name`, `occurrences: list[Occurrence]`,
  `mates: list[Mate]`. `Node = Part | Assembly`.
- `Document.nodes: dict[str, Node]` + `root_node_id: str | None` replace
  the old `Document.parts: dict[str, Part]` field. `Document.parts` is now
  a read/write compatibility view (`_PartsView`, a `MutableMapping` proxy
  over `nodes` filtered to `Part` instances) so every pre-assembly call
  site — `native_format.py`'s import path, `store.py`'s part lookups, the
  existing test suite's `document.parts[id] = part` writes — keeps
  compiling *and* keeps actually mutating the real `nodes` dict, not a
  disposable copy. New code should use `nodes`/`add_part`/`add_assembly`
  directly.

`backend/app/document/native_format.py`:

- `SCHEMA_VERSION` 1 → 2. A v2 file's top-level shape is `{"document":
  {"id", "root_node_id", "nodes": [...]}}`, each node dict carrying a
  `"node_kind": "part" | "assembly"` discriminator (the same "one
  discriminator field, otherwise reuse the existing per-type dict shape"
  convention `_feature_to_dict` already uses for Feature's ~40 subtypes).
- `import_native` still reads v1 files (a flat `"parts"` list, no
  `node_kind`) by wrapping each Part as a `node_kind="part"` Node — a
  lossless wrap, not a best-effort guess, since a v1 file never had
  assemblies. `document.root_node_id` is left `None` for a v1 import (a v1
  Document could hold several unrelated Parts with no "root" concept;
  every existing caller already picks a specific Part by id rather than
  relying on a root).
- `export_native(document, sketches, node_id=None)` — `node_id=None`
  exports every Node in the session (a full snapshot); `node_id=<id>`
  exports just that one Node's own data, which is what saving an
  individual file in a multi-file assembly needs: a leaf Part's own
  features (+ only its own referenced sketches), or a composite Assembly's
  own occurrences/mates — never the resolved subtree those occurrences'
  `external_ref`s point at, since that lives in its own separate file.
  `GET /export/native?node_id=<id>` (`backend/app/document/router.py`)
  wires this through, 404ing for an unknown `node_id`.
- An Occurrence's `node_id` is never written to or read from disk — only
  `external_ref` is (de)serialized. A freshly-imported Occurrence always
  has `node_id=None` until something resolves it (the client's compose
  step, once multi-file assembly loading exists — Phase 2, not yet built).

`backend/app/document/assembly.py` (new): pure vector/matrix math (no
OCCT dependency) for composing `RigidTransform`s down a nested Occurrence
tree — `compose(parent, child)` and `compose_chain(transforms)`. Uses the
same Rodrigues'-rotation-formula construction as the client's
`section_gizmo.dart`'s `rotateAroundAxis`, kept in matching form so backend
and client transform composition agree. Not yet consumed by any endpoint —
Phase 2's `GET /nodes/{node_id}/assembly-mesh` is its first real caller.

**Verified**: standalone round-trip tests (Document/Part/Assembly/
Occurrence/Mate construction → `export_native` → real `json.dumps`/`loads`
→ `import_native` → equivalence, both full-graph and single-node export,
plus v1-legacy-payload import), and the **full backend test suite run for
real against a `pythonocc-core`/`py-slvs` environment** (a `micromamba`
env built from `backend/environment.yml` specifically to make this
possible): **2201/2201 passed**. Getting there surfaced three genuine
pre-existing-test regressions a sandbox without those dependencies
couldn't have caught: 11 test files read a native export's Part list via
the JSON key `exported["document"]["parts"]` (now `"nodes"`) rather than
the `document.parts` Python attribute my initial grep covered, and one
session-isolation test hand-built a v1-shaped import payload while
dynamically fetching the live (now v2) `schema_version` — all fixed as
straightforward key renames with no change in test intent. Two other
pre-existing tests that hardcoded `schema_version == 1` for their own
*current-export* assertions (not a v1-compat fixture) were updated to
assert against the live `SCHEMA_VERSION` constant instead.
`assembly.py`'s transform composition was separately verified (identity,
pure translation, rotated-parent-composes-child's-local-offset-correctly,
axis-angle↔matrix round-trip including the 180° edge case, chain-matches-
nested-compose, and rotation non-commutativity).

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
   composition (resolve N `.didsa` files, assign session-local `node_id`s,
   cycle-check), reusing `/import/native` for the composed payload, plus a
   new `GET /nodes/{node_id}/assembly-mesh` endpoint that walks the
   composite graph (via `assembly.py`'s `compose_chain`) and reuses the
   existing per-Part body cache unchanged — N occurrences of one
   definition trigger one recompute, not N.
3. **Assembly screen shell** — a new `AssemblyScreen` (not an extension of
   the already-18k-line `part_screen.dart`), reusing `PartViewport` and a
   new `AssemblyTreePanel`. Bottom-up insert, top-down create-in-place,
   hide/show, isolate.
4. **Whole-part selection, context menu, opacity tiers** — extend
   `SelectionFilterState`/`select_other_sheet.dart` with a `component`
   kind; new component context menu; per-instance opacity (nothing like
   this exists today — only one global `bodyOpacity` preference).
5. **Move/Rotate gizmo + persisted placement + undo** — a new 6-handle
   `component_gizmo.dart` reusing `section_gizmo.dart`'s proven math
   (which itself never persists anything — the actual "drag commits a
   Feature" precedent is `MoveBodyPanel`'s create-then-update-in-place
   pattern). Local component-transform undo built in this phase, not
   deferred — no document-level undo exists anywhere in this app today.
6. **In-context focus-mode editing** — "Make Focus" pushes `PartScreen` as
   a child screen (same pattern already used for Sketch mode) with
   read-only reference geometry from the rest of the assembly. No backend
   changes needed: per-part Feature endpoints already work against a
   session-local node id regardless of assembly context.
7. **Mate system** (coincident/concentric/parallel/distance/angle) — new
   `assembly_solver.py` (mirrors `sketch/solver.py`'s structure). v1 only
   drives the actively-dragged Occurrence against fixed peers — coupled
   mechanisms (linkages) are a known v1 limitation, not a bug. Debounced
   backend-only solving (same latency-tolerance shape as `MoveBodyFeature`'s
   existing debounce); true low-latency client-side solving via
   `client/native/slvs/`'s FFI shim is possible (pinned to the identical
   fork commit) but needs new forwarding functions that don't exist yet —
   explicitly deferred past v1.
8. **Component pattern** (linear + circular) — a `ComponentPattern` on
   `Assembly`, expanded via `assembly.py`'s transform math only (no OCCT
   work needed, unlike body-level `PatternFeature`).
9. **AI plan pipeline integration** — new `PlanStep` kinds (`mate`,
   `move_component`, `pattern_component`, `hide_component`,
   `isolate_component`) following `MoveBodyStep`'s exact existing template.
   `add_component` needs its own client-side file-discovery mechanism
   (the stateless backend can't enumerate the user's project files) and
   may ship as a later sub-phase.
10. **Hardening, migration, docs** — full `.didsacad` backward-compat test
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
- Composed multi-file graph `node_id`s are session-scoped, not persisted
  across app restarts.
