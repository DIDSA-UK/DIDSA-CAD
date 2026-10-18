# Scenes (display states) — scope

**Status:** scope only; nothing is built. Written 18 Oct 2026 from the owner's design discussion in the DIDSA-VR "sandbox" work
(DIDSA-VR `CHANGELOG.md`, "Relax all mates is a sandbox"). Decisions marked **Owner** were made in that discussion; the rest are
recommendations waiting for the owner.

## 1. What a scene is

A **scene** is a named arrangement of an assembly that is stored with it but is *not* its real state: parts moved apart to show the
inside, a part lifted out for review, an exploded layout, a subset hidden. Showing a scene never changes the real positions, the
mates or anything a solve, a STEP export or a BOM reads. It is the same idea as an exploded view or a display state in desktop CAD.

- **Owner:** a scene is "like a configuration within a part, not the default view of a part". It belongs to an assembly Part, next to
  its occurrences and mates, and the Part's real state (the **default**) is always there and is never itself a scene.
- **Owner:** in DIDSA-VR, the sandbox is how scenes are made: relax mates, arrange the parts, save the arrangement as a scene. The sandbox
  was built first, with its snapshot already keyed the way a scene would be (DIDSA-VR `mates_tool.gd`, `sandbox_snapshot()`).

The rule both apps keep: **a scene is a view of the model, never an edit of it.** Moving a part *in a scene* changes the scene; it never
changes `Occurrence.transform`.

## 2. What exists today to build on

| What | Where | Relevance |
|---|---|---|
| Occurrence paths (`outer/inner/leaf`) | mate references (`assembly.top_level_occurrence_id`, `assembly.resolve_occurrence_target`), measure | The way a scene names a part at any depth: one convention, already validated server-side (`router._check_mate_occurrence_path`). |
| Pattern-copy instance ids (`<source>#pattern:<pattern>:<index>`) | `router._walk_assembly_glb_instances` | Pattern copies have no Occurrence; they can only follow their source (see D3). |
| Client-only extras at the top of the root file | flat app `_rootClientExtras()` (`hidden_feature_ids`, `section_planes`); DIDSA-VR `native_extras_to_add()` (also its own `vr_stale_mates`) | Both clients already carry unknown top-level keys through a save, so a client-only spike needs no backend change (option A in D1). |
| Additive Part fields without a `SCHEMA_VERSION` bump | `native_format._part_to_dict` (`occurrences`, `mates`, `component_patterns` were added this way) | The precedent for a first-class `scenes` field (option B in D1). |
| Cascade on delete | `delete_occurrence` drops the Mates that reference it | The precedent for keeping scene overrides valid (D8). |
| The VR sandbox | DIDSA-VR `mates_tool.gd`: snapshot on Relax, on-screen-only moves, Return parts | Showing a scene in VR = entering the sandbox seeded with the scene's poses (section 6). |
| Roadmap idea | `docs/roadmap.md`, "Exploded view / assembly animation" | Scenes are the static half of that; animating between scenes is a later phase. |

## 3. Decisions

Each has a recommendation. **Owner** marks what was already decided.

### D1. Where scenes are stored

- **A. Client-only extra** in the root file (`"scenes": [...]` next to `hidden_feature_ids`). No backend work; both clients already
  round-trip such keys. But: only the root file has them (a sub-assembly opened alone has none), the backend cannot keep them valid
  when an occurrence is deleted, each client writes its own parsing and validation, and the AI plan and other API users can't see them.
- **B. A first-class field on `Part`** (`Part.scenes`), in the model, `native_format`, the schemas and a small REST surface. Every
  assembly Part, at any level, owns its own scenes and saves them in its own file; the backend validates paths and cascades deletes; both
  clients use one API.

**Recommendation: B.** It matches the owner's "configuration within a part", and the costs are the same kind as the `component_patterns`
addition (additive, no schema-version bump). A is a fallback only if the backend work has to wait.

### D2. What a scene holds (v1)

**Recommendation:** v1 holds **poses** (per-occurrence transform overrides) and **hidden occurrences**. Not colours, section planes,
camera or feature visibility in v1: they are view states of their own, already stored elsewhere (colour on the Occurrence,
`section_planes` / `hidden_feature_ids` as client extras), and folding them in can be a later phase once the pose part has been used.

### D3. How a scene names a part

**Recommendation:** by **occurrence path from the scene's own Part** (`"outer/inner/leaf"`, the mate convention), real occurrences only.
A pattern copy has no Occurrence, so it follows its source: the copy's pose is the pattern applied to the source's *scene* pose. A scene
cannot move one pattern copy on its own in v1 (a later phase could key copies by their instance id).

### D4. The frame a pose override is stored in

**Recommendation:** an override is that occurrence's **local transform at its own level**, exactly what `Occurrence.transform` holds
(relative to the Part that places it, mm). Overrides then compose down the tree the same way real transforms do: overriding a
sub-assembly's occurrence carries everything inside it, and a child can be overridden as well. A client that works in flattened,
root-relative poses (DIDSA-VR's nodes) converts on save and on show: local = inverse(chain of the ancestors' scene-or-real transforms) x
flattened. (DIDSA-VR's `sandbox_snapshot()` keys already match; its poses are flattened and need this conversion.)

### D5. Sparse or full

**Recommendation: sparse.** A scene lists only the occurrences it moves or hides; anything unlisted shows its real pose. A part added to
the assembly later just appears where it really is in every existing scene, and a scene stays small and readable in a diff.

### D6. Scenes of sub-assemblies

A sub-assembly Part has scenes of its own (D1 B). **Recommendation:** in v1 a parent's scene does not *select* a child's scene; it can
override any depth by path instead. "Use the frame's 'Exploded' scene inside this one" is a later phase (a `child_scenes: {path: scene_id}`
map), once someone needs it.

### D7. What showing a scene means, and editing one

**Recommendation:**

- Showing a scene is a mode, with one way out: **Back to default**. In VR it *is* the sandbox: entering it seeded with the scene's poses,
  Return parts leaving it. In the flat app it is a "scene" mode of the assembly lens with the same rule: moves are on screen only.
- Mates are **not enforced** while a scene is shown; a scene is a free arrangement (that is the point of exploded views).
- Editing is explicit: moving parts while a scene is shown changes the shown arrangement; **Update scene** writes it to the scene; leaving
  without updating asks (Update / Discard / Stay), like the unsaved-changes confirmation both apps already show before a destructive Open or New. **Save as new scene** is always there.
- Real edits (a new mate, a feature change, adding a part) still work while a scene is shown and change the default, as in the VR sandbox
  today (a mate made while relaxed is solved when the parts return).

### D8. Overrides that no longer match the assembly

**Recommendation:** `DELETE` of an occurrence also drops every scene override whose path starts with it, in the same transaction, like the
Mate cascade. A path that can't be resolved on load (a sub-assembly file edited elsewhere) is **kept but ignored**, and listed on the
scene ("2 parts in this scene are no longer in the assembly"), so a temporary mismatch never loses data. A scene left with no overrides
is kept (it is still a name the user chose) until deleted.

### D9. Saving

With D1 B, scenes are in the Part, so per-file saves (the flat app's project mode) put each assembly's scenes in its own file, and
DIDSA-VR's whole-session save carries them all. No client extra is needed. Which scene was showing is **not** saved: a file always opens
in the default (**Recommendation**, matches "not the default view").

### D10. What reads a scene, and what never does

Never: solves, mate preview, STEP / BOM / mass properties, `Occurrence.transform`, the AI plan's view of geometry. Reads: the two clients'
display, and (if wanted, section 5) `assembly-mesh.glb?scene_id=` for a client that wants the backend to bake it.

## 4. Data model sketch (D1 B)

```jsonc
// on a Part, next to "occurrences" / "mates" / "component_patterns"; absent = no scenes (older files load unchanged)
"scenes": [
  {
    "id": "6f1c…",
    "name": "Frame exploded",
    "overrides": [
      // path from THIS Part; transform is the occurrence's local transform at its own level (D4), same shape as Occurrence.transform
      {"occurrence_path": "689e531a…/7214dfb8…", "transform": {"translation": [0, 0, 120], "rotation_axis": [0, 0, 1], "rotation_angle_degrees": 0}},
      {"occurrence_path": "9f3c7747…", "hidden": true}
    ]
  }
]
```

- An override has `transform`, `hidden`, or both. Validation (router): each path resolves from this Part (the mate path check), no path
  twice in one scene, a transform passes `_validate_occurrence_transform_payload`.
- `Scene` and `SceneOverride` dataclasses in `models.py`; `_scene_to_dict` / `_scene_from_dict` in `native_format.py`, written only when
  the list is non-empty so files without scenes stay byte-identical.

## 5. API sketch

| Method | Path | Notes |
|---|---|---|
| GET | `/parts/{id}/scenes` | List, with each scene's unresolved paths (D8). |
| POST | `/parts/{id}/scenes` | Create `{name, overrides}`. |
| PATCH | `/parts/{id}/scenes/{scene_id}` | Rename and / or replace `overrides` (Update scene). |
| DELETE | `/parts/{id}/scenes/{scene_id}` | |
| (later) GET | `/parts/{id}/assembly-mesh.glb?scene_id=` | Bake a scene's poses into the mesh; v1 clients compose it themselves from the overrides. |

Composition is a client job in v1, since both clients already place instances themselves (the flat app's instanced rendering; DIDSA-VR's
flattened nodes). A shared reference implementation of "scene overrides + real tree -> per-instance pose" (Python, with golden vectors the
Dart and GDScript copies are checked against, as `tools/motion_vectors` does for constrained drag) keeps the three in step.

## 6. DIDSA-VR integration

Built on the sandbox:

- **Save as scene** (wheel and tablet, while relaxed): the sparse diff between the current arrangement and the remembered homes,
  converted to per-level local transforms (D4), POSTed. Hidden-in-sandbox parts become `hidden` overrides.
- **Show scene** (tablet's Assemble page lists scenes; wheel: a Scenes sub-wheel): enter the sandbox with the scene's poses applied.
  **Update scene** / **Save as new** while shown; **Return parts** = back to default (asking if there are unsaved scene changes, D7).
- Nested parts: a scene can move a part inside a sub-assembly (the sandbox already moves nested nodes on screen).
- Rooms: a room shows its own Part; that Part's scenes are its own (D6). v1 can leave rooms on their default.

## 7. Flat app integration

Scene list in the assembly lens (create, rename, delete, show); scene mode with the gizmo moving parts on screen only; Update / Save as new /
Back to default. Hidden overrides use the existing per-occurrence hide. Parity with VR is the requirement, not identical UI.

## 8. Phases

| Phase | What | Repo |
|---|---|---|
| S0 | The owner settles the open decisions below. | — |
| S1 | Backend: model, native format round trip, validation, CRUD endpoints, delete cascade, unresolved-path report; tests; the reference composition + golden vectors. | CAD |
| S2 | DIDSA-VR: Save as scene / Show / Update / Back to default on the sandbox; composition against the vectors; headless tests + e2e. | VR |
| S3 | Flat app: scene list, scene mode, the same actions; widget tests. | CAD |
| S4 (later) | Scenes selecting child scenes (D6), pattern copies on their own (D3), colours / sections / camera in a scene (D2), `assembly-mesh.glb?scene_id=`, animated transitions between scenes (the roadmap's exploded-view animation). | both |

## 9. Open questions for the owner

1. D1: first-class on `Part` (recommended), or a client-only spike first?
2. D2: poses and hidden only in v1, or colours too?
3. D7: should editing a shown scene need the explicit **Update scene**, or update as you go?
4. D9: always open in the default (recommended), or remember the last-shown scene?
5. Naming: "Scene" (as discussed), "Display state" or "View"? It shows on the tablet, the wheel and the flat app.

## 10. Out of scope

Configurations in the CAD sense (different *dimensions* or suppressed features per variant); per-scene mates; driving mates through a
range (that is the animation idea in S4, not a scene); multi-user scene sharing.
