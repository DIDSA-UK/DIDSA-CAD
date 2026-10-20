# Scenes (display states) — scope

**Status:** being built on branch `claude/appearance-and-scenes` (both repos), milestone by milestone; see Progress below. Written 18 Oct 2026 from the owner's design discussion in the DIDSA-VR "sandbox" work
(DIDSA-VR `CHANGELOG.md`, "Relax all mates is a sandbox"); revised the same day with the owner's answers. Decisions marked **Owner** are
settled; **Recommendation** marks the ones the owner accepted as proposed ("your offers work") or that are still open (section 9).

## Progress

| Phase | Summary | Status | Where |
|---|---|---|---|
| S1 | Backend: model, native format, validation (incl. `#pattern:` paths and body / face appearances), CRUD, delete cascade, unresolved report, composition reference + golden vectors | Done (M3; not merged) | CAD `claude/appearance-and-scenes` |
| S2 | DIDSA-VR: scenes on the sandbox | Done (M4; not merged) | VR `claude/appearance-and-scenes` |
| S3 | Flat app | Done (M5; not merged; unit, widget and screen tests; not tried on a device) | CAD `claude/appearance-and-scenes` (`client/lib/appearance/`) |
| S4 | Later | — | — |

The glb `instance_path` extra listed under S1 was built in the Appearance tool's V1 (the VR gun needed it first).

## S3 implementation notes (flat app)

- **Where:** `scene_compose.dart` (the composition, a copy of `scene_compose.py`; passes `docs/scenes/vectors.json`, read from
  the repo root by `test/scene_compose_test.dart`), `scene_display.dart` (the composition over `assembly-mesh`'s instances, and
  an on-screen move back to a scene override), `scenes_panel.dart` (the list and the actions), and the scene mode in
  `part_screen.dart`. Opened from the assembly lens's Add flyout (Scenes...).
- **The scene mode (D7):** Show (a row of the list) or New scene (from the default) enters it; while it shows the viewport draws
  the composed instances, and the Move/Rotate gizmo (drag or typed), Hide / Show and the Appearance panel change the scene
  being edited, not the model (nothing is sent; mates are not enforced, the gizmo has no constrained drag). A move is stored as
  the instance's local transform in the pose its parent shows at, so moving a sub-assembly carries its contents and a part
  inside it can move as well; a pattern copy is moved by its path like any other instance. Section planes: showing a scene puts
  its section planes in the Section tool (the ones you had come back on Back to default) and a save writes the current ones.
- **Update scene / Save as new** (named in a dialog) write what is on screen: transforms, hidden flags, appearance overrides
  (a paint on every copy / every placement has no scene form and is left out, with a note), the section planes and, with
  "Save my view" on, the camera as the viewpoint (`eye` = the camera, `target` = what it orbits, `up`). Show takes the scene's
  viewpoint when "Show takes the scene's viewpoint" is on (the camera turns to look from the eye at the target).
- **Back to default** (and showing another scene) asks Update / Discard / Stay when the scene on screen has changes (a move,
  a hide, a paint, a section plane changed); a new scene not yet saved offers Discard / Stay. Rename and Delete are in each row's
  menu. A scene's `unresolved` overrides are counted in the list and when shown.
- **Scope (D6):** the scenes are always the opened assembly's own; focusing into a sub-assembly does not switch to that
  sub-assembly's scenes (open its file on its own for those). Not tried on a device or a touch screen.

## S2 implementation notes (DIDSA-VR)

- **Where:** `scripts/scenes_tool.gd` (show / capture / save / update / back to default), `scripts/appearance/scene_compose.gd` (the
  composition, a copy of `scene_compose.py`, checked against `docs/scenes/vectors.json` by `tests/scene_vectors.gd`), the tablet's
  Assemble > Scenes page (`scripts/ui/scenes_page.gd`) and a Scenes sub-wheel on the tool wheel's root ring.
- **Show** relaxes the mates (the sandbox) with every part's real pose as its home, then poses every placed instance by the scene.
  The glb is flat (one node per instance at its pose in the root's frame), so a node's real local transform is read off the glb as
  its pose in its nearest loaded ancestor's pose. A sub-assembly with no geometry is a mesh-less glb node; the client tags it with
  its `instance_path` and poses it too. Hidden: only what the scene decides (a scene `hidden` on the node or above); a part the
  model hides is not in the glb unless the app loads hidden parts, and Show says how many it couldn't show. The scene's appearance
  overrides become the Appearance tool's temporary layer (the top layer, D5), so painting while a scene shows is temporary.
- **Capture** (Update scene / Save as new) walks the tree top down: a node's local transform now (its pose in its parent's pose
  now) against its real one; a different one is a transform override. A mesh-less sub-assembly moves with its parts when they all
  moved alike since the scene was shown (a group grab), else each part moved on its own. The root's own content can't take a
  transform (the backend's rule), so its moves are left out and counted; a temporary paint with `scope` (every copy of a pattern,
  every placement) has no scene form and is left out and counted. Hidden flags are kept from the shown scene; VR can't yet hide a
  part into a scene. Update never sends `section_planes` (kept as the flat app wrote them; VR does not draw them yet).
- **Back to default** is Return parts; it asks Update / Discard / Stay only when a scene shows and what is on screen differs from
  it (transforms within 0.01 mm / 1e-4), on the Scenes page, the Mates page's Return parts and the wheel's Return pill. The plain
  sandbox returns without asking, as before. Showing another scene asks the same way.
- **Viewpoint:** turns the model so the viewpoint's `up` is the world's up and the eye-to-target direction (made horizontal) is the
  way the head faces, and places it so the eye is at the head; the scale is the user's (D9). Save my view stores the head's eye, a
  target 1 m ahead and the world's up. Not applied to a room's scene.
- **Rooms:** an open room's Part is its own scope (D6): its scenes, its nodes.
- **Tests:** `tests/scenes_tool.gd` (headless, fake backends), `tests/scenes_ui.gd` (main scene, the wheel and the tablet's prompt),
  `tests/e2e_scenes.gd` (live backend).

## S1 implementation notes (what was built, and where it is more precise than the text)

- **Where:** `Scene`, `SceneOverride`, `SceneViewpoint` in `models.py`; `native_format` writes `scenes` only when a Part has one;
  routes, validation, the unresolved report and the cascade in `backend/app/document/scenes_routes.py`; path resolution shared with
  the Appearance tool (`occurrence_paths.py`).
- **Composition reference:** `backend/app/document/scene_compose.py` (pure Python; imports only `appearance.py`). Golden vectors:
  `tools/scene_vectors/generate.py` -> `docs/scenes/vectors.json` (6 cases over one tree: default, exploded, hidden, looks,
  everything, empty; tolerance 1e-4 for float32 clients); the backend's copy is `backend/tests/data/scene_vectors.json`. Its input is
  the list of placed instances (path, real local transform, real `hidden`, bodies to resolve) plus the appearance resolution model,
  so a client tests composition without expanding patterns itself.
- **The rule, made exact:** a node's local transform is the scene's transform for its path, else its real one, and world poses
  compose down the tree (D4). **Visibility:** the nearest scene `hidden` on the node or an ancestor decides, so hiding a
  sub-assembly hides its contents and a scene can show a part the model hides (`hidden: false`); with no scene `hidden` on the way
  up, the node's own real flag (as the glb walk uses it: a child keeps its own flag). **Appearance:** the scene's appearance
  overrides are the top layer of the Appearance tool's rule (its D3 step 1).
- **Validation (section 4) and two choices it implies:** every override sets at least one of transform / hidden / appearance; a
  body or face takes an appearance only; **the Part's own bodies (path `""`) take an appearance only** (they are the frame everything
  else is placed in); no `(path, body, face)` twice; a face is a face of an existing body of the Part its path names and is stored
  with its signature; the viewpoint's eye differs from its target. `section_planes` is stored as given (the flat app's JSON).
- **API:** `GET /parts/{id}/scenes` (each with `unresolved: [{path, body_id, reason}]`), `GET .../scenes/{scene_id}`, `POST`
  (the server mints the id), `PATCH` (rename / replace any field whole; `viewpoint: null` removes it), `DELETE`.
- **Cascade (D8):** deleting an occurrence drops every scene override (in any Part's scenes) whose path goes through it; deleting
  a component pattern, or the occurrence that is its source, drops its copies' overrides. A scene left empty is kept. A copy that
  a smaller count no longer derives, a body or face that can't be found, is kept and reported.
- **Tests:** `backend/tests/test_scenes.py`.

## 1. What a scene is

A **scene** is a named arrangement of an assembly that is stored with it but is *not* its real state: parts moved apart to show the
inside, a part lifted out for review, an exploded layout, a subset hidden or see-through, a section cut, a chosen viewpoint. Showing a
scene never changes the real positions, the mates or anything a solve, a STEP export or a BOM reads. It is the same idea as an exploded
view or a display state in desktop CAD.

- **Owner:** a scene is "like a configuration within a part, not the default view of a part". It belongs to the Part it was made in, next
  to its occurrences and mates, and the Part's real state (the **default**) is always there and is never itself a scene.
- **Owner:** a scene lives only in the assembly it was created in. When that assembly is placed inside a bigger one, its scenes don't
  apply there (D6).
- **Owner:** in DIDSA-VR, the sandbox is how scenes are made: relax mates, arrange the parts, save the arrangement as a scene. The sandbox
  was built first, with its snapshot already keyed by occurrence path (DIDSA-VR `mates_tool.gd`, `sandbox_snapshot()`).

The rule both apps keep: **a scene is a view of the model, never an edit of it.** Moving a part *in a scene* changes the scene; it never
changes `Occurrence.transform`.

### Parts that become assemblies

Nothing here assumes a Part is "a part" or "an assembly". In DIDSA-CAD every Part has `features`, `occurrences` and `mates` side by side
(`models.Part`, `docs/assembly-scope.md` Phase 0): a Part with no occurrences is simply one with nothing placed in it yet. `scenes` is one
more field on the same Part, so a Part that starts as a single body and later gains occurrences can have scenes from that moment, with no
conversion and no special case. A scene on a Part with no occurrences has nothing to override except its own viewpoint and section planes
(the Part's own bodies are the frame everything else is placed in, so they don't move).

## 2. What exists today to build on

| What | Where | Relevance |
|---|---|---|
| Occurrence ids and paths (`outer/inner/leaf`) | `Occurrence.id` (a UUID written in the file that places it); mate references (`assembly.top_level_occurrence_id`, `assembly.resolve_occurrence_target`), measure | The way a scene names a part at any depth (D3): one convention, already validated server-side (`router._check_mate_occurrence_path`). |
| Pattern-copy instance ids (`<source>#pattern:<pattern>:<index>`) | `router._walk_assembly_glb_instances`; the flat app reads them (`part_screen.dart`, `#pattern:`) | Lets a scene move one pattern copy on its own (D3). |
| Client-only extras at the top of the root file | flat app `_rootClientExtras()` (`hidden_feature_ids`, `section_planes`); DIDSA-VR `native_extras_to_add()` (also its own `vr_stale_mates`) | Both clients carry unknown top-level keys through a save (option A in D1). The flat app's `SectionPlane` JSON is the shape a scene's section planes reuse (D2). |
| Additive Part fields without a `SCHEMA_VERSION` bump | `native_format._part_to_dict` (`occurrences`, `mates`, `component_patterns` were added this way) | The precedent for a first-class `scenes` field (option B in D1). |
| Cascade on delete | `delete_occurrence` drops the Mates that reference it | The precedent for keeping scene overrides valid (D8). |
| The VR sandbox | DIDSA-VR `mates_tool.gd`: snapshot on Relax, on-screen-only moves, Return parts | Showing a scene in VR = entering the sandbox seeded with the scene (section 6). |
| Roadmap idea | `docs/roadmap.md`, "Exploded view / assembly animation" | Scenes are the static half of that; animating between scenes is a later phase. |

## 3. Decisions

### D1. Where scenes are stored — **Recommendation (accepted): on the Part**

- **A. Client-only extra** in the root file (`"scenes": [...]` next to `hidden_feature_ids`): no backend work, but the backend cannot keep
  scenes valid when an occurrence is deleted, each client parses and validates on its own, and the API can't see them.
- **B. A first-class field on `Part`** (`Part.scenes`), in the model, `native_format`, the schemas and a small REST surface: the backend
  validates paths and cascades deletes; both clients use one API.

B, matching "a configuration within a part". The cost is the same kind as the `component_patterns` addition (additive, no schema-version
bump). The Part holding a scene is the one it was made in: the session's root when made in the world, a room's Part when made in an
Assembly Room (that room's Part is the assembly being worked in).

### D2. What a scene holds — **Owner: more in v1**

The owner asked for more than poses in v1 (the work is done by an LLM, so the size is not the constraint). v1 holds, all optional and
all sparse (D5):

| Content | Per | Notes |
|---|---|---|
| **Pose** | occurrence or pattern copy (D3) | The arrangement: exploded, lifted out, turned. |
| **Hidden** | occurrence or pattern copy | Show only what matters. |
| **Appearance** | occurrence, pattern copy, or one body or face of either | The Appearance tool's record (`docs/appearance-tool-scope.md` section 2): colour, opacity, metal, shine, glow, each optional. A scene's appearance beats everything else for as long as it is shown (that doc's D3, step 1). |
| **Section planes** | the scene | The flat app's `SectionPlane` list (the same JSON as its `section_planes` extra), and DIDSA-VR's section tool reads the first one. |
| **Viewpoint** | the scene | Where the viewer looks from, in the assembly's own frame (mm): `eye`, `target`, `up`. The flat app sets its camera from it. **Owner:** DIDSA-VR keeps your current scale (the user controls scale, and a sudden change would be jarring) and only turns and places the model so you look from `eye` towards `target`. Optional: a scene without one leaves the view where it is. |

Not in v1: feature visibility inside a part (`hidden_feature_ids`), material, labels or markup, animation. These are later phases if
wanted.

### D3. How a scene names a part — **Recommendation: occurrence ids, not part ids or file paths**

The owner asked whether part ids are best, and what happens if a file moves. What CAD systems usually do, and why the answer here is the
**occurrence path**:

- **A part id says *what* is placed, not *which copy*.** `Frame_A.didsa` is placed twice in the Frame; both copies have the same Part id.
  A scene needs to move one of them, so it needs the id of the *placement*: the `Occurrence.id`. Every desktop CAD system does this.
  SolidWorks names a component instance (`Frame_A-1`, `Frame_A-2`), Inventor an occurrence, Onshape an instance id. The thing being moved
  is the instance.
- **Occurrence ids don't depend on files.** An occurrence's id is a UUID written in the parent assembly's own file. It doesn't change when
  the placed file is moved, renamed or swapped for another, or when the assembly itself moves. So scene overrides keyed by
  occurrence ids survive all of those without any search. A path (`outer/inner/leaf`) is just the chain of those ids from the scene's
  Part down, the same thing mates already use.
- **What file moves do break is the assembly itself**, not its scenes: `Occurrence.external_ref` is a relative path, so a moved
  sub-assembly file isn't found when the assembly opens. That is a real gap, but a separate one, covered in D11.
- **Pattern copies:** keyed by their instance id segment, `<source occurrence>#pattern:<pattern id>:<index>` (the id the mesh export
  already builds), so **every part, pattern copies included, can be moved in v1** (**Owner** asked for this). A copy inside a patterned
  sub-assembly is reached through that segment like any other: `S#pattern:p1:2/F/A`. If the pattern's count drops, a copy that no longer
  exists is handled like any missing path (D8). If the count grows, the new copies just show their real place.

### D4. The frame a pose override is stored in

An override is that occurrence's (or pattern copy's) **local transform at its own level**, the frame `Occurrence.transform` uses (relative
to the Part that places it, mm). For a pattern copy it replaces the copy's derived transform. Overrides compose down the tree as real
transforms do: moving a sub-assembly moves everything inside it, and a child can be moved as well. A client that works in flattened,
root-relative poses (DIDSA-VR's nodes) converts on save and on show: local = inverse(ancestors' chain) x flattened. DIDSA-VR's
`sandbox_snapshot()` keys already match; its poses are flattened and need this conversion.

### D5. Sparse — **Recommendation (accepted)**

A scene lists only what it changes; anything unlisted shows as it really is. A part added to the assembly later appears in its real place
in every existing scene, and a scene stays small and readable in a diff.

### D6. Scenes and sub-assemblies — **Owner: a scene lives only in its own assembly**

A scene belongs to the assembly it was made in. When that assembly is placed inside a bigger one, its scenes aren't offered and don't
apply; the bigger assembly's own scenes can still reach any depth by path (D3). Opened on its own (or in a VR Assembly Room) the
sub-assembly shows its own scenes again. There is no "use the child's scene" link (dropped from the earlier draft).

### D7. Showing and editing a scene — **Recommendation (accepted)**

- Showing a scene is a mode with one way out: **Back to default**. In VR it *is* the sandbox, entered with the scene applied; Return
  parts leaves it. In the flat app it is a scene mode of the assembly lens with the same rule: moves are on screen only.
- Mates are **not enforced** while a scene is shown; a scene is a free arrangement.
- Editing is explicit: changing things while a scene is shown changes what you see; **Update scene** writes it; leaving without updating
  asks (Update / Discard / Stay), like the unsaved-changes confirmation both apps already show. **Save as new scene** is always there.
- Real edits (a new mate, a feature change, adding a part) still work while a scene is shown and change the default, as in the VR sandbox
  today.

### D8. Overrides that no longer match the assembly — **Recommendation (accepted)**

`DELETE` of an occurrence drops every override whose path goes through it, in the same transaction (the Mate cascade). Deleting a
component pattern drops its copies' overrides. A path that can't be resolved on load (a sub-assembly file edited elsewhere, a pattern now
shorter) is **kept but ignored** and listed on the scene ("2 parts in this scene are no longer in the assembly"), so a temporary mismatch
never loses data. A scene left with no overrides is kept until deleted.

### D9. Saving — **Recommendation (accepted): always open in the default**

Scenes are saved in their Part's own file (per-file saves in the flat app's project mode; DIDSA-VR's whole-session save carries them all).
Which scene was showing is not saved.

### D10. What reads a scene, and what never does

Never: solves, mate preview, STEP / BOM / mass properties, `Occurrence.transform` / `.color` / `.hidden`, the AI plan's view of geometry.
Reads: the two clients' display, and (later) `assembly-mesh.glb?scene_id=`.

### D11. Finding moved files (a related gap, not part of scenes)

The owner's question about moved files points at a real weakness: `Occurrence.external_ref` is only a relative path, and the Part id it
resolved to is not trusted across a single-file reload (`native_format._occurrence_to_dict`), so a moved or renamed sub-assembly file is
simply not found. What CAD systems usually do:

- **Keep an id next to the path.** Store the placed file's own root Part id with the reference. The path is the fast route; the id is how
  you know you found the *right* file (a renamed copy, or a different file that happens to have the same name).
- **Search a known place when the path misses.** SolidWorks has search paths and a "find references" dialog; Inventor has project files
  listing folders. Here: index the project folder (DIDSA-VR's Settings project folder; the flat app's project mode) by root Part id and
  look the id up. One match: use it, tell the user, and offer to save the corrected path. Several, or a name-only match: ask.
- **Never guess silently.** Opening the wrong revision of a part is worse than reporting a missing one.

**Recommendation:** a short scope of its own (backend: an optional `ref_root_part_id` on `Occurrence`, written on save and checked on
resolve; both clients: a project-folder index and the lookup above, sharing one rule). It is independent of scenes and can go first,
after or alongside.

## 4. Data model sketch (D1 B)

```jsonc
// on a Part, next to "occurrences" / "mates" / "component_patterns"; absent = no scenes (older files load unchanged)
"scenes": [
  {
    "id": "6f1c…",
    "name": "Frame exploded",
    "overrides": [
      // path from THIS Part (D3); each field optional, at least one present
      {"path": "689e531a…/7214dfb8…", "transform": {"translation": [0, 0, 120], "rotation_axis": [0, 0, 1], "rotation_angle_degrees": 0}},
      {"path": "9f3c7747…", "hidden": true},
      {"path": "504857a3…#pattern:af676f33…:2", "transform": {…}, "appearance": {"colour": "#E8834A", "opacity": 0.3}},
      {"path": "689e531a…/7214dfb8…", "body_id": "e8d7bb68…", "appearance": {"metallic": 1.0}}  // one body
    ],
    "section_planes": [ /* the flat app's SectionPlane JSON */ ],
    "viewpoint": {"eye": [2400, 1500, 2400], "target": [0, 400, -780], "up": [0, 1, 0]}  // assembly frame, mm; optional
  }
]
```

- Validation (router): each path resolves from this Part (the mate path check, extended to accept a `#pattern:` segment that names an
  existing pattern, source and index), no `(path, body_id)` twice in a scene, a transform passes `_validate_occurrence_transform_payload`, an appearance
  passes the Appearance tool's checks, a transform or `hidden` is never on a body (bodies don't move on their own), a viewpoint's `eye` differs from its `target`.
- `Scene` / `SceneOverride` dataclasses in `models.py`; `_scene_to_dict` / `_scene_from_dict` in `native_format.py`, written only when
  the list is non-empty so files without scenes stay byte-identical.

## 5. API sketch

| Method | Path | Notes |
|---|---|---|
| GET | `/parts/{id}/scenes` | List, with each scene's unresolved paths (D8). |
| POST | `/parts/{id}/scenes` | Create `{name, overrides, section_planes?, viewpoint?}`. |
| PATCH | `/parts/{id}/scenes/{scene_id}` | Rename and / or replace any of the rest (Update scene). |
| DELETE | `/parts/{id}/scenes/{scene_id}` | |
| (later) GET | `/parts/{id}/assembly-mesh.glb?scene_id=` | Bake a scene into the mesh for a client that wants it. |

Composition is a client job in v1, since both clients already place instances themselves. A shared reference implementation of "scene +
real tree -> per-instance pose, colour, opacity, visibility" (Python, with golden vectors the Dart and GDScript copies are checked against,
as `tools/motion_vectors` does for constrained drag) keeps the three in step.

**One backend change DIDSA-VR needs for pattern copies:** the assembly glb tags a pattern copy with an empty `occurrence_id`, so VR can't
tell copies apart. Add an `instance_path` extra (the full path including the `#pattern:` segment, which the walk already builds) to every
instance node.

## 6. DIDSA-VR integration

Built on the sandbox:

- **Save as scene** (wheel and tablet, while relaxed): the sparse difference between what you see and the remembered homes (poses
  converted per D4; parts hidden, painted or made see-through meanwhile), plus the section plane if one is on, plus your viewpoint if you
  choose to keep it.
- **Show scene** (the tablet's Assemble page lists scenes; the wheel gets a Scenes sub-wheel): enter the sandbox with the scene applied.
  **Update scene** / **Save as new** while shown; **Return parts** = back to default (asking if there are unsaved scene changes, D7).
- In the sandbox, painting becomes temporary too (today a colour is saved on the occurrence straight away; hiding is already on screen
  only): needed so a scene's colours never leak into the model. The painting itself is the Appearance tool (`docs/appearance-tool-scope.md`),
  whose gun targets a face, a body, a part or its parent assembly.
- Pattern copies become movable (they aren't grabbable on their own today), using the glb's new `instance_path`.
- Rooms: a room's scenes are its Part's own (D6); a room can show them.

## 7. Flat app integration

Scene list in the assembly lens (create, rename, delete, show); scene mode with the gizmo moving parts on screen only, plus hide, colour,
opacity and sections; Update / Save as new / Back to default; the viewpoint taken from the current camera. Parity with VR is the
requirement, not identical UI.

## 8. Phases

| Phase | What | Repo |
|---|---|---|
| S0 | Settled (this revision), apart from section 9. | — |
| S1 | Backend (needs the Appearance tool's appearance record, its V1): model, native format round trip, validation (incl. `#pattern:` paths), CRUD endpoints, delete cascade, unresolved-path report; the glb `instance_path` extra; tests; the reference composition + golden vectors. | CAD |
| S2 | DIDSA-VR: Save as scene / Show / Update / Back to default on the sandbox; temporary colour and hide in the sandbox; movable pattern copies; viewpoint; composition against the vectors; headless tests + e2e. | VR |
| S3 | Flat app: scene list, scene mode, the same actions; widget tests. | CAD |
| S4 (later) | `assembly-mesh.glb?scene_id=`, animated transitions between scenes (the roadmap's exploded-view animation), feature visibility and markup in a scene. | both |
| R1 (separate) | Finding moved files (D11). | both |

## 9. Settled in the second revision

1. **Name: Scene** (Owner).
2. **Finding moved files (D11):** on the roadmap as its own item (Owner), `docs/roadmap.md`.
3. **Viewpoint in VR:** keep the current scale (Owner), see D2.
4. Colours and looks in a scene use the Appearance tool's appearance record (Owner asked for the Appearance tool, first called the Vision tool, in the same discussion).

## 10. Out of scope

Configurations in the CAD sense (different *dimensions* or suppressed features per variant); per-scene mates; driving mates through a
range (the animation idea in S4); multi-user scene sharing.
